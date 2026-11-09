import { View, div } from "gpui-kit";
import { exec, theme, layout, props, settings } from "herdr";
import { hueOf, alpha, RED, newBird, drawBird, AWAY_MS, disk, heldFade, wireBezier, viaBezier, pointAt, dashed, solid } from "./motion.js";
import { PathBuilder } from "gpui-kit";

const BASE = "http://127.0.0.1:3425";
const now = () => performance.now();
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const MAX_AGENTS = 4, MAX_PROVIDERS = 6, KEEP = 40;
const AW = 100, HW = 84, AH = 46, PH = 42, HH = 60, PAD = 14, TOP = 44;

export default class Routing extends View {
  init(_props, cx) {
    this.base = props()?.base ?? BASE;
    this.size = { width: 440, height: 520 };
    this.routes = new Map(); this.agents = []; this.providers = [];
    this.given = new Map(); this.trips = []; this.birds = new Set(); this.dots = new Set();
    this.waiters = []; this.flowing = new Map(); this.holds = new Set();
    this.ticks = new Map(); this.hits = new Map(); this.geo = null;
    this.cursor = null; this.offline = false; this.alive = true; this.shown = false; this.playing = new Set();
    cx.timer.every(33, (cx) => this.frame(cx));
    cx.spawn(async (cx) => this.feed(cx));
  }

  async close() { this.alive = false; }

  visible() { const n = find(layout(), "routing"); return Boolean(n) && !n.hidden; }

  async feed(cx) {
    while (this.alive) {
      if (!this.visible()) { await exec("sleep", ["1"]); continue; }
      try {
        if (this.cursor == null) await this.snapshot(cx);
        const r = await exec("curl", ["-sN", "--max-time", "0.45", "-H", "Accept: text/event-stream", `${this.base}/v1/magpie/route-events?after=${this.cursor}`], { timeout: 8000 });
        if (r.code !== 0 && r.code !== 28) throw new Error(`curl ${r.code}`);
        this.offline = false;
        this.parse(r.stdout, cx);
      } catch {
        if (!this.offline) { this.offline = true; cx.notify(); }
        this.cursor = null;
        await exec("sleep", ["2"]);
      }
    }
  }

  async snapshot(cx) {
    const r = await fetch(`${this.base}/v1/magpie/route-events/snapshot`);
    const s = JSON.parse(await r.text());
    this.cursor = s.cursor;
    for (const x of s.routes ?? []) this.ingest(x);
    this.offline = false; cx.notify();
  }

  parse(text, cx) {
    if (text.includes("snapshot_required") || text.includes("event: reset")) { this.cursor = null; return; }
    for (const block of text.split("\n\n")) {
      let id = null, data = "";
      for (const line of block.split("\n")) {
        if (line.startsWith("id:")) id = line.slice(3).trim();
        else if (line.startsWith("data:")) data += line.slice(5).trim();
      }
      if (!data) continue;
      try { const e = JSON.parse(data); this.ingest(e.route); this.cursor = id ?? e.cursor ?? this.cursor; } catch {}
    }
    cx.notify();
  }

  addAgent(id) {
    if (this.agents.includes(id)) return true;
    if (this.agents.length >= MAX_AGENTS) {
      const idle = this.agents.find((a) => ![...this.routes.values()].some((r) => r.agent === a && !r.done));
      if (!idle) return false;
      this.agents.splice(this.agents.indexOf(idle), 1);
    }
    this.agents.push(id);
    return true;
  }
  addProvider(id) {
    if (this.providers.includes(id)) return;
    if (this.providers.length >= MAX_PROVIDERS) this.providers.shift();
    this.providers.push(id);
  }

  ingest(x) {
    if (!x?.id) return;
    let R = this.routes.get(x.id);
    if (!R) {
      if (x.phase === "done" || x.phase === "dropped") return;
      R = { id: x.id, agent: x.agent || "agent", tries: [], done: false };
      this.routes.set(x.id, R);
      if (this.routes.size > KEEP) for (const [k, v] of this.routes) if (v.done && !this.playing.has(k)) { this.routes.delete(k); break; }
    }
    R.model = x.model || R.model;
    if (x.provider && ["attempt", "responding", "attempt_done"].includes(x.phase)) {
      const i = Math.max(0, (x.attempt || 1) - 1);
      const T = R.tries[i] ?? (R.tries[i] = { provider: x.provider, model: x.model, done: false, status: 0, failed: false });
      T.provider = x.provider; T.model = x.model;
      this.addProvider(x.provider);
      if (x.phase === "attempt_done") { T.done = true; T.status = x.status; T.failed = Boolean(x.failed) || x.status >= 400; }
    }
    if (x.phase === "done" || x.phase === "dropped") {
      R.done = true; R.gone = x.phase === "dropped"; R.status = x.status;
      const last = R.tries[R.tries.length - 1];
      if (last && !last.done) { last.done = true; last.status = x.status; last.failed = Boolean(x.failed) || x.status >= 400; }
    }
    if (!this.playing.has(x.id) && this.addAgent(R.agent)) { this.playing.add(x.id); this.play(x.id).finally(() => this.playing.delete(x.id)); }
    this.wake();
  }

  wake() {
    const w = this.waiters; this.waiters = [];
    for (const x of w) if (x.f()) x.res(); else this.waiters.push(x);
  }
  until(f) { return f() ? Promise.resolve() : new Promise((res) => this.waiters.push({ f, res })); }

  wire(key) { return this.geo?.wires.get(key); }
  tipOf(key, atEnd) { const w = this.wire(key); if (!w) return null; return { x: w.xs[atEnd ? w.xs.length - 1 : 0], y: w.ys[atEnd ? w.ys.length - 1 : 0] }; }
  via(a, b) { return a && b && this.geo ? viaBezier(a, b, this.geo.hub.y) : null; }
  tick(k) { this.ticks.set(k, now()); }
  live(key, d) { this.flowing.set(key, (this.flowing.get(key) ?? 0) + d); if (this.flowing.get(key) <= 0) this.flowing.delete(key); }

  fly(dot, bird, legs, ms) {
    return new Promise((res) => {
      if (!this.visible()) { res(); return; }
      const tr = { dot, bird, legs, t0: now(), ms, res };
      this.pose(tr, 0);
      this.trips.push(tr);
    });
  }

  legPath(l) { return l.v ?? this.wire(l.w); }

  pose(tr, e) {
    const paths = tr.legs.map((l) => this.legPath(l)), lens = paths.map((p) => p?.L ?? 0), total = lens.reduce((a, b) => a + b, 0);
    if (!total) return;
    const point = (d) => {
      d = Math.max(0, Math.min(total, d));
      let i = 0;
      while (i < lens.length - 1 && (d > lens[i] || !lens[i])) { d -= lens[i]; i++; }
      return pointAt(paths[i], tr.legs[i].rev ? lens[i] - d : d);
    };
    const edge = Math.min(6, total / 4), d = edge + e * (total - 2 * edge), pt = point(d);
    tr.dot.x = pt.x; tr.dot.y = pt.y; tr.dot.visible = true;
    const b = tr.bird;
    if (!b) return;
    const p0 = point(d - 3), p1 = point(d + 3);
    let vx = p1.x - p0.x, vy = p1.y - p0.y;
    if (Math.abs(vx) + Math.abs(vy) < .01) { vx = b.vx ?? (tr.legs[0].rev ? -1 : 1); vy = 0; }
    b.vx = vx;
    const aim = Math.max(-24, Math.min(24, Math.atan2(vy, Math.abs(vx)) * 180 / Math.PI)), fl = vx < 0;
    b.a = b.a === undefined || b.flip !== fl ? aim : b.a + (aim - b.a) * .12;
    b.flip = fl; b.x = pt.x; b.y = pt.y; b.placed = true;
  }

  mkBird(kind) { const b = newBird(kind, now()); this.birds.add(b); return b; }
  away(b) { if (b && b.awayAt == null) { b.awayAt = now(); } }
  mkDot(color) { const d = { color, x: 0, y: 0, visible: false, back: false, err: false, held: false }; this.dots.add(d); return d; }

  async play(id) {
    let R = this.routes.get(id);
    const color = hueOf(R.agent, this.given), A = `a:${R.agent}`;
    const dot = this.mkDot(color);
    let carrier = this.mkBird("req"), from = null, back = null;
    this.live(A, 1);
    try {
      this.tick(A);
      await this.until(() => this.wire(A));
      if (!R.tries.length) {
        await this.fly(dot, carrier, [{ w: A }], 620);
        from = this.tipOf(A, true);
        this.tick("hub");
      }
      for (let i = 0; ;) {
        if (i >= R.tries.length) {
          if (R.done) break;
          await this.until(() => R.tries.length > i || R.done);
          continue;
        }
        const T = R.tries[i], P = `p:${T.provider}`;
        await this.until(() => this.wire(P));
        if (!carrier) carrier = this.mkBird("req");
        if (from) this.tick("hub");
        this.live(P, 1);
        const out = [{ v: this.via(from || this.tipOf(A, true), this.tipOf(P, false)) }, { w: P }].filter((l) => l.v !== null);
        await this.fly(dot, carrier, from ? out : [{ w: A }, ...out], from ? 900 : 1400);
        this.away(carrier); carrier = null;
        dot.held = true; this.holds.add(dot); dot.at = { x: dot.x, y: dot.y }; dot.provider = T.provider;
        await this.until(() => T.done);
        this.holds.delete(dot); dot.held = false;
        const ok = !T.failed;
        const home = [{ w: P, rev: true }, { v: this.via(this.tipOf(P, false), this.tipOf(A, true)) }, { w: A, rev: true }].filter((l) => l.rev || l.v !== null);
        if (ok) {
          await this.until(() => R.done);
          dot.back = true; back = this.mkBird("res");
          await this.fly(dot, back, home, 1400);
          this.away(back); this.live(P, -1); this.tick(A);
          break;
        }
        this.hits.set(P, { at: now(), text: `${T.status || "err"}` });
        dot.back = true; dot.err = true; back = this.mkBird("res");
        const final = R.done && i >= R.tries.length - 1;
        if (final) {
          await this.fly(dot, back, home, 1350);
          this.away(back); this.live(P, -1); this.tick(A);
          break;
        }
        await this.fly(dot, back, [{ w: P, rev: true }], 620);
        this.away(back); this.live(P, -1);
        dot.back = false; dot.err = false;
        from = this.tipOf(P, false);
        i++;
        if (i >= R.tries.length) await this.until(() => R.tries.length > i || R.done);
        if (i >= R.tries.length && R.done) break;
      }
    } finally {
      this.live(A, -1);
      this.away(carrier); this.away(back);
      this.dots.delete(dot); this.holds.delete(dot);
    }
  }

  busy(t) {
    return this.trips.length > 0 || this.flowing.size > 0 || this.holds.size > 0 || this.birds.size > 0
      || [...this.ticks.values()].some((v) => t - v < 450) || [...this.hits.values()].some((v) => t - v.at < 1900);
  }

  frame(cx) {
    if (!this.visible()) { this.shown = false; return; }
    const t = now();
    if (!this.shown) { this.shown = true; cx.notify(); }
    const going = [];
    for (const tr of this.trips) {
      const k = tr.ms ? Math.min(1, Math.max(0, (t - tr.t0) / tr.ms)) : 1;
      try { this.pose(tr, (1 - Math.cos(Math.PI * k)) / 2); } catch { tr.res(); continue; }
      if (k >= 1) tr.res(); else going.push(tr);
    }
    this.trips = going;
    for (const b of this.birds) if (b.awayAt != null && t - b.awayAt > AWAY_MS) this.birds.delete(b);
    this.wake();
    if (this.busy(t)) cx.notify();
  }

  layoutGeo() {
    const z = settings().zoom || 1, W = this.size.width / z, H = this.size.height / z, ag = this.agents, pr = this.providers;
    const pw = Math.max(80, Math.min(150, W - 2 * PAD - AW - HW - 80)), gap = Math.max(24, (W - 2 * PAD - AW - HW - pw) / 2);
    const ax = PAD, hx = ax + AW + gap, px = hx + HW + gap, cy = TOP + (H - TOP - 14) / 2;
    const stack = (n, h, g) => Array.from({ length: n }, (_, i) => cy - (n * h + (n - 1) * g) / 2 + i * (h + g));
    const ays = stack(ag.length, AH, 10), pys = stack(pr.length, PH, 8);
    const wires = new Map();
    ag.forEach((id, i) => wires.set(`a:${id}`, wireBezier(ax + AW + 3, ays[i] + AH / 2, hx - 2, cy)));
    pr.forEach((id, i) => wires.set(`p:${id}`, wireBezier(hx + HW + 2, cy, px - 3, pys[i] + PH / 2)));
    return { ax, hx, px, pw, cy, ays, pys, wires, hub: { x: hx, y: cy - HH / 2 } };
  }

  card(t, x, y, w, h, kids, extra = {}) {
    return div().absolute().left(x).top(y).w(w).h(h).rounded(10).bg(t.surface).border(1).border_color(extra.border ?? t.border)
      .flex().flex_col().items_center().justify_center().gap(1).overflow_hidden().children(kids);
  }

  render() {
    const t = theme(), tNow = now();
    const g = this.geo = this.layoutGeo();
    const fg = { fg: t.foreground, card: t.surface };
    const root = div().id("rt-root").relative().size_full().bg(t.chrome)
      .on_size_change((s, cx) => { this.size = s; cx.notify(); });
    const live = [...this.routes.values()].filter((r) => !r.done).length;
    root.child(div().absolute().left(PAD).top(12).text_size(12).font_semibold().text_color(t.foreground).child("Routing"))
      .child(div().absolute().right(PAD).top(13).text_size(11).text_color(this.offline ? t.blocked : t.muted)
        .child(this.offline ? "gateway offline" : live ? `${live} in flight` : "idle"));

    const out = [];
    for (const [key, p] of g.wires) {
      const on = this.flowing.has(key);
      const col = key.startsWith("a:") ? this.given.get(key.slice(2)) ?? t.muted : this.lastAgentColor(key);
      if (on) { const d = dashed(p, (tNow % 700) / 700 * 8, 3, 5, 1.5, col); if (d) out.push(d); }
      else out.push(solid(p, 1.5, t.border));
    }

    g.ays.forEach((y, i) => {
      const id = this.agents[i], k = `a:${id}`, col = hueOf(id, this.given);
      const tk = this.ticks.get(k), s = tk && tNow - tk < 400 ? 1 + .04 * Math.sin(Math.PI * (tNow - tk) / 400) : 1;
      const n = [...this.routes.values()].filter((r) => r.agent === id && !r.done).length;
      root.child(this.card(t, g.ax - AW * (s - 1) / 2, y - AH * (s - 1) / 2, AW * s, AH * s, [
        div().flex().items_center().gap(5).max_w(AW - 10).child(div().size(7).rounded(4).bg(col).flex_none()).child(div().text_size(13).font_semibold().text_color(t.foreground).truncate().child(id)),
        div().text_size(11).text_color(t.muted).child(n ? `${n} live` : "idle"),
      ]));
    });
    const tk = this.ticks.get("hub"), hs = tk && tNow - tk < 400 ? 1 + .04 * Math.sin(Math.PI * (tNow - tk) / 400) : 1;
    root.child(this.card(t, g.hx - HW * (hs - 1) / 2, g.hub.y - HH * (hs - 1) / 2, HW * hs, HH * hs, [
      div().text_size(13).font_semibold().text_color(t.foreground).child("magpie"),
      div().text_size(10).text_color(t.muted).child(":3425"),
    ], { border: t.foreground }));

    g.pys.forEach((y, i) => {
      const id = this.providers[i], k = `p:${id}`, hit = this.hits.get(k);
      const age = hit ? tNow - hit.at : 9e9, shake = age < 450 ? [-5, 4, -2, 1][Math.min(3, Math.floor(age / 112))] : 0;
      const cur = [...this.routes.values()].find((r) => !r.done && r.tries.some((T) => T.provider === id && !T.done));
      const model = cur?.tries.find((T) => T.provider === id && !T.done)?.model ?? "";
      root.child(this.card(t, g.px + shake, y, g.pw, PH, [
        div().text_size(13).font_semibold().text_color(t.foreground).max_w(g.pw - 12).truncate().child(id),
        div().text_size(11).text_color(t.muted).max_w(g.pw - 12).truncate().child(model || "—"),
      ], { border: age < 1800 ? RED : t.border }));
      if (age < 1800) root.child(div().absolute().left(g.px + g.pw - 44).top(y - 9).px(7).rounded(6).bg(RED).text_size(10.5).font_semibold().text_color("#ffffff").child(hit.text));
    });

    if (!this.agents.length && !this.offline) root.child(div().absolute().left(PAD).right(PAD).top(TOP + 4).text_size(11).text_color(t.muted).child("No request yet. Send one through magpie and it flies here."));

    for (const d of this.dots) {
      if (!d.visible) continue;
      const op = d.held ? heldFade(tNow) : 1;
      const c = d.color;
      if (!d.back) {
        out.push(window.paint_path(PathBuilder.fill().add_polygon(disk(d.x, d.y, 7.5), true).build(), alpha(c, .22 * op)));
        out.push(window.paint_path(PathBuilder.fill().add_polygon(disk(d.x, d.y, 4.5), true).build(), alpha(c, op)));
      } else {
        out.push(window.paint_path(PathBuilder.fill().add_polygon(disk(d.x, d.y, 4), true).build(), d.err ? c : t.surface));
        out.push(window.paint_path(PathBuilder.stroke(2.25).add_polygon(disk(d.x, d.y, 4), true).build(), d.err ? RED : c));
      }
    }
    for (const b of this.birds) out.push(...drawBird(b, tNow, fg));
    for (const e of out) root.child(e);
    return root;
  }

  lastAgentColor(key) {
    const prov = key.slice(2);
    for (const r of [...this.routes.values()].reverse()) if (r.tries.some((T) => T.provider === prov) && !r.done) return this.given.get(r.agent) ?? "#888888";
    return "#888888";
  }
}
