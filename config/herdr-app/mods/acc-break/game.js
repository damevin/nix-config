import { div, PathBuilder } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, readTextFile, notify } from "herdr";

const BUILDINGS = [
  { id: "prompt", name: "Prompt", sub: "a well-worded ask", base: 15, rate: 0.1 },
  { id: "script", name: "Script", sub: "bash that works first try", base: 100, rate: 1 },
  { id: "agent", name: "Agent", sub: "works while you sleep", base: 1100, rate: 8 },
  { id: "swarm", name: "Sub-agents", sub: "agents spawning agents", base: 12000, rate: 47 },
  { id: "gpu", name: "GPU rack", sub: "warm to the touch", base: 130000, rate: 260 },
  { id: "dc", name: "Datacenter", sub: "has its own weather", base: 1.4e6, rate: 1400 },
  { id: "model", name: "Frontier model", sub: "prompts you back", base: 2e7, rate: 7800 },
  { id: "agi", name: "AGI", sub: "asks for a raise", base: 3.3e8, rate: 44000 },
];
// [owned needed, cost as a multiple of the building's base price]
const TIERS = [[1, 10], [5, 50], [25, 500], [50, 5000], [100, 50000]];
const CLICKS = [
  { id: "click-0", name: "Mechanical keyboard", cost: 100 },
  { id: "click-1", name: "Vim motions", cost: 500 },
  { id: "click-2", name: "Macros", cost: 10000 },
  { id: "click-3", name: "Second monitor", cost: 100000 },
  { id: "click-4", name: "Telepathy", cost: 1e7 },
];
const FEEDS = [
  { id: "feed-0", name: "Pair programming", cost: 50000, pct: 0.01 },
  { id: "feed-1", name: "Flow state", cost: 5e6, pct: 0.04 },
];
const BOOST = 0.5; // extra output per real agent working in Herdr
const OFFLINE = 0.5; // share of output earned while Herdr is closed
const SUFFIX = ["", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc"];

export const fmt = (n) => {
  if (!Number.isFinite(n)) return "∞";
  if (n < 1000) return n < 10 && n % 1 ? n.toFixed(1) : String(Math.floor(n));
  const i = Math.min(SUFFIX.length - 1, Math.floor(Math.log10(n) / 3)), v = n / 10 ** (i * 3);
  return `${v.toFixed(v < 10 ? 2 : v < 100 ? 1 : 0)}${SUFFIX[i]}`;
};
const cost = (b, n) => Math.ceil(b.base * 1.15 ** n);

function token(size, fill, line) {
  const k = size / 24, hex = (r) => Array.from({ length: 6 }, (_, i) => [12 + r * Math.cos(Math.PI / 3 * i - Math.PI / 2), 12 + r * Math.sin(Math.PI / 3 * i - Math.PI / 2)].map((v) => v * k));
  const outer = PathBuilder.fill(); outer.add_polygon(hex(11), true);
  const inner = PathBuilder.stroke(Math.max(1.5, size / 28)); const h = hex(6.5); inner.move_to(...h[0]); for (const p of [...h.slice(1), h[0]]) inner.line_to(...p);
  const dot = PathBuilder.fill(); dot.add_polygon(hex(2.4), true);
  return div().relative().size(size).flex_none()
    .child(globalThis.window.paint_path(outer.build(), fill))
    .child(globalThis.window.paint_path(inner.build(), line))
    .child(globalThis.window.paint_path(dot.build(), line));
}

export class Game {
  constructor(file, cx) {
    this.file = file;
    this.s = { tokens: 0, earned: 0, clicks: 0, lucky: 0, owned: {}, ups: [], last: Date.now() };
    this.pops = []; this.seq = 0; this.bump = false; this.dirty = false; this.savedAt = Date.now();
    this.luck = null; this.luckNext = Date.now() + this.gap(); this.frenzy = 0; this.working = 0;
    cx.spawn(async (cx) => {
      try { this.s = { ...this.s, ...JSON.parse(await readTextFile(this.file) ?? "{}") }; } catch {}
      const away = Math.min(86400, (Date.now() - this.s.last) / 1000), gain = this.rate(0) * away * OFFLINE;
      this.s.last = Date.now();
      if (away > 60 && gain >= 1) {
        this.earn(gain);
        notify({ title: `+${fmt(gain)} tokens while you were away`, body: "Your farm kept going at half speed.", level: "info", timeout: 4000 });
      }
      cx.notify();
    });
  }

  gap() { return (120 + Math.random() * 180) * 1000; }
  has(id) { return this.s.ups.includes(id); }
  owned(b) { return this.s.owned[b.id] ?? 0; }
  each(b) { return b.rate * 2 ** TIERS.filter((_, i) => this.has(`${b.id}-${i}`)).length; }
  base() { return BUILDINGS.reduce((sum, b) => sum + this.each(b) * this.owned(b), 0); }
  rate(working = this.working) { return this.base() * (1 + BOOST * working) * (this.frenzy > Date.now() ? 7 : 1); }
  click() { return 2 ** CLICKS.filter((u) => this.has(u.id)).length + this.rate() * FEEDS.filter((u) => this.has(u.id)).reduce((s, u) => s + u.pct, 0); }
  earn(n) { this.s.tokens += n; this.s.earned += n; this.dirty = true; }

  upgrades() {
    const out = [];
    // Only the next step of each ladder, so the shelf never shows two "Agent ×2".
    for (const b of BUILDINGS) {
      const i = TIERS.findIndex((_, i) => !this.has(`${b.id}-${i}`));
      if (i >= 0 && this.owned(b) >= TIERS[i][0]) out.push({ id: `${b.id}-${i}`, name: `${b.name} ×2`, sub: `${b.name} output doubles`, cost: b.base * TIERS[i][1] });
    }
    const click = CLICKS.find((u) => !this.has(u.id)), feed = FEEDS.find((u) => !this.has(u.id));
    if (click && this.s.earned >= click.cost / 2) out.push({ ...click, sub: "Clicks are worth twice as much" });
    if (feed && this.s.earned >= feed.cost / 2) out.push({ ...feed, sub: `Clicks add ${feed.pct * 100}% of your output` });
    return out.sort((a, b) => a.cost - b.cost).slice(0, 8);
  }

  // Called every second by the pane, shown or not: output depends on time, not on redraws.
  tick(now, working, shown) {
    this.working = working;
    const dt = Math.max(0, (now - this.s.last) / 1000);
    this.s.last = now;
    if (dt > 0) this.earn(this.rate() * dt);
    if (this.luck && now > this.luck.until) this.luck = null;
    if (shown && !this.luck && now > this.luckNext && this.s.earned > 50) {
      this.luck = { x: 0.15 + Math.random() * 0.7, y: 12 + Math.random() * 120, until: now + 13000 };
      this.luckNext = now + this.gap();
    }
    if (this.dirty && now - this.savedAt > 20000) this.save();
  }

  save() {
    this.dirty = false; this.savedAt = Date.now();
    return exec("python3", ["-c", "import sys; open(sys.argv[1], 'w').write(sys.argv[2])", this.file, JSON.stringify(this.s)]);
  }

  pop(text, x, y, cx) {
    const id = ++this.seq;
    this.pops.push({ id, text, x, y, flying: false });
    cx.timer.after(20, (cx) => { const p = this.pops.find((q) => q.id === id); if (p) { p.flying = true; cx.notify(); } });
    cx.timer.after(900, (cx) => { this.pops = this.pops.filter((q) => q.id !== id); cx.notify(); });
  }

  press(cx) {
    const n = this.click();
    this.earn(n); this.s.clicks++;
    this.pop(`+${fmt(n)}`, 0.5 + (Math.random() - 0.5) * 0.45, 40 + Math.random() * 30, cx);
    this.bump = true; cx.timer.after(70, (cx) => { this.bump = false; cx.notify(); });
    cx.notify();
  }

  catchLuck(cx) {
    const l = this.luck; if (!l) return;
    this.luck = null; this.s.lucky++;
    if (Math.random() < 0.5 && this.base() > 0) { this.frenzy = Date.now() + 30000; this.pop("Frenzy ×7 for 30s", l.x, l.y, cx); }
    else { const n = Math.max(13, Math.min(this.s.tokens * 0.15, this.rate() * 900)); this.earn(n); this.pop(`Lucky! +${fmt(n)}`, l.x, l.y, cx); }
    this.save(); cx.notify();
  }

  buy(b, many, cx) {
    for (let i = 0; i < (many ? 10 : 1); i++) {
      const c = cost(b, this.owned(b));
      if (this.s.tokens < c) break;
      this.s.tokens -= c; this.s.owned[b.id] = this.owned(b) + 1;
    }
    this.save(); cx.notify();
  }

  upgrade(u, cx) {
    if (this.s.tokens < u.cost || this.has(u.id)) return;
    this.s.tokens -= u.cost; this.s.ups.push(u.id); this.save(); cx.notify();
  }

  reset(cx) {
    this.s = { tokens: 0, earned: 0, clicks: 0, lucky: 0, owned: {}, ups: [], last: Date.now() };
    this.frenzy = 0; this.luck = null; this.save(); cx.notify();
  }

  section(t, text, right) {
    return h_flex().px(14).pt(16).pb(6).items_center()
      .child(div().flex_1().text_size(10).font_semibold().text_color(t.dim).child(text.toUpperCase()))
      .when(Boolean(right), (el) => el.child(div().text_size(10).text_color(t.dim).child(right ?? "")));
  }

  view(t, width) {
    const now = Date.now(), rate = this.rate(), frenzy = this.frenzy > now, ups = this.upgrades();
    const shownB = BUILDINGS.filter((b, i) => this.owned(b) > 0 || this.s.earned >= b.base * 0.4 || i === 0);
    const next = BUILDINGS[shownB.length];
    const zone = Math.max(240, width - 20);

    const score = v_flex().items_center().pt(18).gap(3)
      .child(h_flex().gap(8).items_center()
        .child(token(22, t.accent, t.background))
        .child(div().text_size(30).font_semibold().text_color(t.foreground).child(fmt(this.s.tokens))))
      .child(div().text_size(11.5).text_color(t.muted).child(`tokens · ${fmt(rate)} per second`))
      .child(h_flex().mt(6).h(22).px(9).gap(6).items_center().rounded(11).border_1()
        .border_color(this.working ? t.working : t.border).bg(t.surface)
        .child(div().size(6).rounded(3).flex_none().bg(this.working ? t.working : t.dim)
          .when(this.working > 0, (d) => d.loop("opacity", { from: 0.35, to: 1, period: 1200 })))
        .child(div().text_size(10.5).text_color(this.working ? t.foreground : t.muted)
          .child(this.working ? `${this.working} agent${this.working > 1 ? "s" : ""} working · ×${1 + BOOST * this.working} output` : "Start an agent: each one working adds ×0.5")))
      .when(frenzy, (el) => el.child(div().mt(4).text_size(10.5).font_semibold().text_color(t.ansi3)
        .child(`Frenzy ×7 · ${Math.ceil((this.frenzy - now) / 1000)}s`)));

    const button = div().id("tk-core").size(132).rounded(66).flex().items_center().justify_center().cursor_pointer()
      .bg(t.surface).border_1().border_color(frenzy ? t.ansi3 : t.input)
      .hover((s) => s.bg(t.raised)).active((s) => s.bg(t.hover))
      .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
      .on_click((_e, cx) => this.press(cx))
      .child(div().relative().top(this.bump ? 4 : 0).spring("top", { response: 220, damping: 0.45 }).child(token(76, t.accent, t.background)));

    const field = div().relative().w_full().h(190).flex().items_center().justify_center()
      .child(div().absolute().size(160).rounded(80).border_1().border_color(t.border)
        .loop("opacity", { from: 0.25, to: 0.8, period: frenzy ? 600 : 2800 }))
      .child(button)
      .children(this.pops.map((p) => div().id(`pop-${p.id}`).absolute().left(10 + p.x * zone - 40).w(80).flex().justify_center()
        .top(p.flying ? p.y - 48 : p.y).opacity(p.flying ? 0 : 1)
        .transition("top", { duration: 850, easing: "ease-out" }).transition("opacity", { duration: 850, easing: "ease-in" })
        .text_size(13).font_semibold().text_color(t.accent).whitespace_nowrap().child(p.text)))
      .when(Boolean(this.luck), (el) => el.child(div().id("tk-luck").absolute().left(10 + this.luck.x * zone - 16).top(this.luck.y)
        .size(32).rounded(16).flex().items_center().justify_center().cursor_pointer().bg(t.raised).border_1().border_color(t.ansi3)
        .loop("top", { from: this.luck.y - 4, to: this.luck.y + 4, period: 1600 })
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .on_click((_e, cx) => this.catchLuck(cx)).child(token(20, t.ansi3, t.background))));

    const upgrades = ups.length ? h_flex().flex_wrap().gap(6).mx(10).children(ups.map((u) => {
      const ok = this.s.tokens >= u.cost;
      return v_flex().id(`up-${u.id}`).px(10).py(6).gap(1).rounded(8).bg(t.surface).border_1().border_color(ok ? t.accent : t.border)
        .when(ok, (el) => el.cursor_pointer().hover((s) => s.bg(t.raised)).on_click((_e, cx) => this.upgrade(u, cx)))
        .when(!ok, (el) => el.opacity(0.55))
        .child(div().text_size(11.5).font_semibold().text_color(t.foreground).child(u.name))
        .child(div().text_size(10).text_color(t.muted).child(`${fmt(u.cost)} · ${u.sub}`));
    })) : div().mx(14).text_size(11).text_color(t.dim).child("Keep building: upgrades unlock as you grow.");

    const row = (b) => {
      const n = this.owned(b), c = cost(b, n), ok = this.s.tokens >= c, out = this.each(b) * n, share = this.base() ? Math.round(out / this.base() * 100) : 0;
      return h_flex().id(`bd-${b.id}`).mx(10).mb(6).px(10).py(8).gap(10).items_center().rounded(10).bg(t.surface).border_1()
        .border_color(ok ? t.input : t.border).when(!ok, (el) => el.opacity(0.6))
        .when(ok, (el) => el.cursor_pointer().hover((s) => s.bg(t.raised)).on_click((e, cx) => this.buy(b, Boolean(e?.modifiers?.shift), cx)))
        .child(div().size(30).rounded(8).flex().items_center().justify_center().flex_none().bg(n ? t.selected : t.raised)
          .text_size(12).font_semibold().text_color(n ? t.foreground : t.dim).child(String(n)))
        .child(v_flex().flex_1().min_w(0).gap(2)
          .child(div().truncate().text_size(12.5).font_semibold().text_color(t.foreground).child(b.name))
          .child(div().truncate().text_size(10.5).text_color(t.muted)
            .child(n ? `${fmt(this.each(b))}/s each · ${share}% of output` : `${b.sub} · ${fmt(this.each(b))}/s`)))
        .child(h_flex().gap(4).items_center().flex_none()
          .child(token(11, ok ? t.accent : t.dim, t.surface))
          .child(div().text_size(12).font_semibold().text_color(ok ? t.foreground : t.dim).child(fmt(c))));
    };

    return v_flex()
      .child(score)
      .child(field)
      .child(this.section(t, "Upgrades", ups.length ? `${ups.filter((u) => this.s.tokens >= u.cost).length} ready` : null))
      .child(upgrades)
      .child(this.section(t, "Build", "shift-click buys 10"))
      .children(shownB.map(row))
      .when(Boolean(next), (el) => el.child(h_flex().mx(10).px(10).py(8).gap(10).items_center().rounded(10).border_1().border_color(t.border)
        .child(div().size(30).rounded(8).flex().items_center().justify_center().flex_none().bg(t.raised).text_size(12).text_color(t.dim).child("?"))
        .child(div().text_size(11).text_color(t.dim).child(`Unlocks at ${fmt(next.base * 0.4)} tokens earned`))))
      .child(h_flex().mx(14).mt(14).gap(8).items_center()
        .child(div().flex_1().text_size(10.5).text_color(t.dim)
          .child(`${fmt(this.s.earned)} earned · ${fmt(this.s.clicks)} clicks · ${this.s.lucky} lucky`))
        .child(div().id("tk-reset").px(6).h(20).flex().items_center().rounded(6).text_size(10.5).text_color(t.dim).cursor_pointer()
          .hover((s) => s.bg(t.hover).text_color(t.foreground))
          .on_click((e, cx) => { if (e?.click_count >= 2) this.reset(cx); else notify({ title: "Double-click to start over", level: "info", timeout: 2000 }); })
          .child("Start over")));
  }
}
