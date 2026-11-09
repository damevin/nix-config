import { div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, notify, spaces, run, home, appHome, terminals } from "herdr";

const BASE = "http://127.0.0.1:4000";
const ROOT = "~/Documents/symphony-workspaces/entropy";
const DIR = "~/Documents/livestorm/symphony-local";
const REPO = "livestorm/entropy";
const LAUNCHER = "symphony-livestorm";
const FLAG = "--i-understand-that-this-will-be-running-without-the-usual-guardrails";
const MAX_TURNS = 20;
const STAGES = ["Plan", "Build", "PR & CI", "Handoff"];
const SPIN = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const one = (s) => String(s ?? "").replace(/\s+/g, " ").trim();
const tok = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(n >= 1e4 ? 0 : 1)}k` : `${Math.round(n ?? 0)}`);
const span = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return s >= 86400 ? `${Math.floor(s / 86400)}d` : s >= 3600 ? `${Math.floor(s / 3600)}h ${String(Math.floor(s % 3600 / 60)).padStart(2, "0")}m` : s >= 60 ? `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s` : `${s}s`; };
const short = (ms) => { const s = Math.max(0, Math.floor(ms / 1000)); return s >= 86400 ? `${Math.floor(s / 86400)}d` : s >= 3600 ? `${Math.floor(s / 3600)}h` : s >= 60 ? `${Math.floor(s / 60)}m` : `${s}s`; };
const ago = (iso) => (iso ? `${short(Date.now() - (typeof iso === "number" ? iso : Date.parse(iso)))} ago` : "");
const until = (iso) => (iso ? (Date.parse(iso) > Date.now() ? `in ${span(Date.parse(iso) - Date.now())}` : "now") : "");
const human = (ev) => one(ev).replace(/^codex\//, "").replace(/[/_]/g, " ").replace(/\bitem\b/g, "").trim() || "working";
const idOf = (r) => r.issue_identifier ?? r.issue_id;
// bg() takes plain colours only: a gradient is a row of strips whose alpha steps up (and back down).
const ramp = (c, alphas, w, h) => h_flex().h(h).flex_none().children(alphas.map((a) => div().w(w).h(h).flex_none().bg(c + a)));

// Every check on a PR, down to one word.
function ci(rollup) {
  const s = (rollup ?? []).map((c) => String(c.conclusion || c.state || c.status || "").toUpperCase());
  if (!s.length) return "none";
  if (s.some((x) => ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].includes(x))) return "failing";
  if (s.some((x) => ["PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", "WAITING", ""].includes(x))) return "running";
  return "green";
}

// Where a ticket is, from what exists: commits on its branches, its PRs, its Linear state.
function stageOf(st, linearState) {
  const prs = st?.prs ?? [], open = prs.filter((p) => p.state === "OPEN" || p.state === "MERGED");
  if (/review|done|merged|closed/i.test(linearState ?? "")) return { i: 3, note: linearState };
  if (open.length) {
    const p = open[0], c = p.ci;
    return { i: 2, note: `#${p.number}${p.draft ? " draft" : ""} · ${c === "none" ? "no checks yet" : `CI ${c}`}${open.length > 1 ? ` · ${open.length} PRs` : ""}`, ci: c };
  }
  if ((st?.commits ?? 0) > 0) return { i: 1, note: `${st.commits} commit${st.commits > 1 ? "s" : ""}` };
  return { i: 0, note: st ? "reading the ticket, planning PRs" : "" };
}

export class Symphony {
  constructor(cx) {
    this.base = BASE; this.root = ROOT.replace(/^~/, home()); this.dir = DIR.replace(/^~/, home());
    this.state = null; this.offline = null; this.open = null; this.details = new Map(); this.disk = [];
    this.armed = null; this.rate = 0; this.lastTotal = null; this.lastAt = 0; this.busy = false;
    this.next = 0; this.diskNext = 0; this.fetching = false; this.linearRetry = 0; this.showAll = false;
    this.entering = new Set(); this.present = new Set(); this.seen = new Set(); this.primed = false;
    this.stages = {}; this.stageBusy = false; this.stageNext = 0; this.pastNext = 0; this.prev = null; this.width = 420;
    const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k) ?? d); } catch { return JSON.parse(d); } };
    this.linear = load("sym-linear", "{}"); this.history = load("sym-history", "{}"); this.prs = load("sym-prs", "{}");
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

  tick(cx) {
    const t = Date.now(), shown = this.shown?.() ?? false;
    if (this.armed && t > this.armed.until) this.armed = null;
    if (t >= this.next) { this.next = t + (shown ? (this.offline ? 5000 : 2500) : 15000); this.poll(cx); }
    if (shown && t >= this.diskNext) { this.diskNext = t + 30000; this.scan(cx); }
    if (t >= this.stageNext && this.live().length) { this.stageNext = t + (shown ? 30000 : 60000); this.loadStages(this.live().map(idOf), cx); }
    if (shown && t >= this.pastNext && this.disk.length) { this.pastNext = t + 10 * 60e3; this.loadPast(cx); }
  }

  running() { return this.state?.running ?? []; }
  live() { const s = this.state ?? {}; return [...(s.running ?? []), ...(s.retrying ?? []), ...(s.blocked ?? [])]; }
  mode() {
    if (this.offline !== false || !this.state) return this.offline === null ? "loading" : "offline";
    if (this.running().length) return "work";
    if ((this.state.blocked ?? []).length) return "blocked";
    return (this.state.retrying ?? []).length ? "wait" : "idle";
  }
  save(k, v) { localStorage.setItem(k, JSON.stringify(v)); }

  poll(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await fetch(`${this.base}/api/v1/state`);
        if (r.status !== 200) throw new Error(`HTTP ${r.status}`);
        const st = JSON.parse(await r.text());
        if (st.error) throw new Error(st.error.message);
        this.transitions(this.state, st);
        this.state = st; this.offline = false;
        this.sample();
        if (this.open) this.loadDetail(this.open, cx);
        this.syncLinear(cx);
      } catch { this.state = null; this.offline = true; this.rate = 0; this.lastTotal = null; }
      cx.notify();
      cx.timer.after(20, (cx) => this.settle(cx));
    });
  }

  // Runs that leave the running list go to history; the moments worth a ping are announced.
  transitions(before, after) {
    if (!before) return;
    const ids = (l) => new Set((l ?? []).map(idOf)), nowRunning = ids(after.running), blocked = ids(after.blocked), retrying = ids(after.retrying);
    for (const r of before.running ?? []) {
      const id = idOf(r);
      if (nowRunning.has(id)) continue;
      const outcome = blocked.has(id) ? "blocked" : retrying.has(id) ? "retrying" : "finished";
      this.history[id] = { ...(this.history[id] ?? {}), id, ended: Date.now(), started: r.started_at, turns: r.turn_count ?? 0,
        tokens: r.tokens?.total_tokens ?? 0, outcome, workspace: r.workspace_path };
      this.save("sym-history", this.history);
      const title = this.linear[id]?.title ?? id, st = stageOf(this.stages[id], this.linear[id]?.state);
      if (outcome === "finished") this.ping(`${id} finished`, `${clip(title, 70)} · ${STAGES[st.i]}${st.note ? ` (${st.note})` : ""} · ${tok(r.tokens?.total_tokens ?? 0)} tokens`, "success");
    }
    const was = ids(before.blocked);
    for (const r of after.blocked ?? []) if (!was.has(idOf(r))) this.ping(`${idOf(r)} is blocked`, clip(one(r.error ?? r.last_message ?? "It needs you."), 140), "warning");
  }

  ping(title, body, level) {
    notify({ title: `Symphony · ${title}`, body, level, timeout: 8000 });
    exec("osascript", ["-e", "on run argv\ndisplay notification (item 2 of argv) with title \"Symphony\" subtitle (item 1 of argv)\nend run", title, body]).catch(() => null);
  }

  sample() {
    const now = Date.now(), total = this.running().reduce((a, r) => a + (r.tokens?.total_tokens ?? 0), 0);
    if (this.lastTotal != null && now > this.lastAt && total >= this.lastTotal) this.rate = this.rate * .6 + (total - this.lastTotal) / ((now - this.lastAt) / 1000) * .4;
    this.lastTotal = total; this.lastAt = now;
  }

  syncLinear(cx) {
    if (this.fetching || Date.now() < this.linearRetry) return;
    const ids = [...new Set([...this.live().map(idOf), ...this.disk])].filter((x) => /^LIV-\d+$/.test(x ?? ""));
    const liveIds = new Set(this.live().map(idOf));
    const stale = ids.filter((id) => !this.linear[id] || Date.now() - this.linear[id].at > (liveIds.has(id) ? 5 : 60) * 60e3).slice(0, 40);
    if (!stale.length) return;
    this.fetching = true;
    cx.spawn(async (cx) => {
      try {
        const r = await exec("sh", [`${appHome()}/mods/acc-today/linear-issue.sh`, ...stale], { timeout: 60000 });
        const d = JSON.parse(r.stdout);
        if (!d?.data?.issues) throw new Error("no answer");
        const at = Date.now();
        for (const id of stale) this.linear[id] = { missing: true, at };
        for (const i of d.data.issues.nodes) this.linear[i.identifier] = { title: i.title, state: i.state?.name ?? "", url: i.url, at };
        this.save("sym-linear", this.linear);
      } catch { this.linearRetry = Date.now() + 5 * 60e3; }
      this.fetching = false; cx.notify();
    });
  }

  async prsOf(id) {
    const r = await exec("gh", ["pr", "list", "--repo", REPO, "--state", "all", "--search", `${id} in:title`, "--limit", "10",
      "--json", "number,title,url,state,isDraft,statusCheckRollup"], { timeout: 20000 });
    if (r.code !== 0) throw new Error(r.stderr);
    return JSON.parse(r.stdout).filter((p) => new RegExp(`\\b${id}\\b`, "i").test(p.title))
      .map((p) => ({ number: p.number, title: p.title, url: p.url, state: p.state, draft: p.isDraft, ci: ci(p.statusCheckRollup) }));
  }

  loadStages(ids, cx) {
    if (this.stageBusy) return;
    this.stageBusy = true;
    cx.spawn(async (cx) => {
      for (const id of ids) {
        const ws = this.live().find((r) => idOf(r) === id)?.workspace_path ?? `${this.root}/${id}`;
        const before = this.stages[id];
        try {
          const g = await exec("git", ["-C", ws, "rev-list", "--count", "--branches", "--not", "origin/main"], { timeout: 8000 });
          const prs = await this.prsOf(id).catch(() => before?.prs ?? []);
          const st = { commits: Number(g.stdout.trim()) || 0, prs, at: Date.now() };
          if (before) {
            const had = new Set((before.prs ?? []).map((p) => p.number));
            for (const p of prs) if (!had.has(p.number)) this.ping(`${id} opened #${p.number}`, clip(p.title, 120), "success");
            for (const p of prs) { const o = (before.prs ?? []).find((x) => x.number === p.number); if (o && o.ci !== "failing" && p.ci === "failing") this.ping(`CI failing on #${p.number}`, `${id} · ${clip(p.title, 100)}`, "error"); }
          }
          this.stages[id] = st; this.prs[id] = { list: prs, at: Date.now() };
        } catch {}
      }
      this.save("sym-prs", this.prs);
      this.stageBusy = false; cx.notify();
    });
  }

  // Past workspaces: their PRs, so each line says what came out of it.
  loadPast(cx) {
    cx.spawn(async (cx) => {
      const live = new Set(this.live().map(idOf));
      for (const id of this.disk.filter((d) => !live.has(d) && /^LIV-\d+$/.test(d))) {
        if (this.prs[id] && Date.now() - this.prs[id].at < 30 * 60e3) continue;
        try { this.prs[id] = { list: await this.prsOf(id), at: Date.now() }; } catch { break; }
      }
      this.save("sym-prs", this.prs); cx.notify();
    });
  }

  scan(cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("sh", ["-c", 'ls -t "$1" 2>/dev/null | head -20', "sh", this.root], { timeout: 8000 });
        this.disk = r.stdout.split("\n").map((l) => l.trim()).filter(Boolean);
        if (this.pastNext === 0) this.pastNext = Date.now();
      } catch { this.disk = []; }
      cx.notify();
    });
  }

  loadDetail(id, cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await fetch(`${this.base}/api/v1/${encodeURIComponent(id)}`);
        this.details.set(id, r.status === 200 ? JSON.parse(await r.text()) : { error: `HTTP ${r.status}` });
      } catch { this.details.set(id, { error: "unreachable" }); }
      cx.notify();
    });
  }

  term() { return (terminals() ?? []).find((x) => x.state === "live" && (x.argv ?? []).join(" ").includes(LAUNCHER)); }
  arm(key, cx) {
    if (this.armed?.key !== key) { this.armed = { key, until: Date.now() + 5000 }; cx.notify(); return false; }
    this.armed = null; return true;
  }
  start(cx) {
    if (this.term() || this.offline === false || !this.arm("start", cx)) return;
    const argv = [`${this.dir}/${LAUNCHER}`, FLAG], known = spaces().find((x) => x.name === "symphony");
    if (known) run("tab.new", { space: known.id, name: "symphony", folder: this.dir, argv });
    else run("space.new", { name: "symphony", folder: this.dir, argv });
    notify({ title: "Symphony starting", body: "In the symphony space. It shows up here once its API answers.", level: "info", timeout: 4000 });
    this.next = 0;
  }
  stop(cx) {
    const tm = this.term();
    if (!tm || !this.arm("stop", cx)) return;
    cx.spawn(async (cx) => {
      const r = await exec("hc", ["send", tm.address, "\u0003", "--force"], { timeout: 8000 }).catch((e) => ({ code: 1, stderr: String(e) }));
      notify(r.code === 0 ? { title: "Symphony: stop requested", level: "info", timeout: 2500 } : { title: "Stop failed", body: String(r.stderr).slice(0, 200), level: "error" });
      this.next = 0; cx.notify();
    });
  }
  refresh(cx) {
    if (this.busy) return;
    this.busy = true; cx.notify();
    cx.spawn(async (cx) => {
      const r = await exec("curl", ["-s", "-m", "6", "-X", "POST", "-o", "/dev/null", "-w", "%{http_code}", `${this.base}/api/v1/refresh`], { timeout: 10000 }).catch(() => ({ stdout: "" }));
      if (!r.stdout.trim().startsWith("2")) notify({ title: "Symphony refresh failed", body: `HTTP ${r.stdout.trim() || "?"}`, level: "error" });
      this.busy = false; this.next = 0; cx.notify();
    });
  }
  openWorkspace(id, path) {
    const dir = path ?? `${this.root}/${id}`, known = spaces().find((s) => s.folder === dir && !s.machine);
    if (known) run("space.select", { id: known.id }); else run("space.new", { name: id, folder: dir });
  }
  openUrl(url) { exec("open", [url]); }
  openLinear(id) { this.openUrl(this.linear[id]?.url ?? `https://linear.app/issue/${id}`); }

  // ——— pieces ———

  color(t, mode) { return { work: t.working, wait: t.ansi3, blocked: t.blocked, idle: t.ansi2 }[mode] ?? t.dim; }
  ghost(t, id, label, onClick, tone) {
    return h_flex().id(id).h(26).px(9).gap(6).items_center().rounded(7).flex_none().text_size(11.5).font_medium()
      .bg(tone ? tone + "22" : t.raised).text_color(tone ?? t.muted).hover((s) => s.bg(tone ? tone + "33" : t.hover).text_color(tone ?? t.foreground))
      .on_click(onClick).child(label);
  }
  chip(t, text, color, id, onClick) {
    const c = div().px(7).h(18).flex().items_center().rounded(6).text_size(10.5).font_medium().text_color(color).bg(t.raised).flex_none().child(text);
    return onClick ? c.id(id).cursor_pointer().hover((s) => s.opacity(.8)).on_click(onClick) : c;
  }
  prChip(t, p, key) {
    const color = p.state === "MERGED" ? t.ansi5 ?? t.accent : p.state === "CLOSED" ? t.dim : p.ci === "failing" ? t.ansi1 : p.ci === "green" ? t.ansi2 : t.ansi3;
    const label = `#${p.number} ${p.state === "MERGED" ? "merged" : p.state === "CLOSED" ? "closed" : p.draft ? "draft" : "open"}${p.state === "OPEN" && p.ci !== "none" ? ` · CI ${p.ci}` : ""}`;
    return this.chip(t, label, color, `pr-${key}-${p.number}`, () => this.openUrl(p.url));
  }
  meter(t, label, pct) {
    const W = 64, p = Math.max(0, Math.min(1, (pct ?? 0) / 100));
    return h_flex().gap(7).items_center()
      .child(div().text_size(10.5).text_color(t.dim).child(label))
      .child(div().relative().w(W).h(4).rounded(2).bg(t.raised)
        .child(div().absolute().left(0).top(0).h(4).rounded(2).bg(p > .85 ? t.ansi1 : p > .6 ? t.ansi3 : t.ansi2).w(Math.max(3, W * p)).transition("width", { duration: 500, easing: "ease-out" })))
      .child(div().text_size(10.5).text_color(t.muted).child(`${Math.round(pct ?? 0)}%`));
  }
  stat(t, label, value, accent) {
    return v_flex().flex_1().min_w(0).gap(2)
      .child(div().text_size(10.5).text_color(t.dim).child(label))
      .child(div().text_size(14).font_semibold().text_color(accent ?? t.foreground).child(value));
  }

  // A ring that breathes out of a dot: width, height, left, top and opacity on one period stay centred.
  ripple(color, from, to, period) {
    const off = (to - from) / 2;
    return div().absolute().rounded_full().border_1().border_color(color)
      .loop("width", { from, to, period, easing: "ease-out" }).loop("height", { from, to, period, easing: "ease-out" })
      .loop("left", { from: off, to: 0, period, easing: "ease-out" }).loop("top", { from: off, to: 0, period, easing: "ease-out" })
      .loop("opacity", { from: .8, to: 0, period, easing: "ease-out" });
  }

  orb(t, mode) {
    const c = this.color(t, mode), S = 28, live = mode === "work" || mode === "wait";
    return div().relative().size(S).flex_none()
      .when(live, (el) => el.child(div().absolute().left(0).top(0).size(S).child(this.ripple(c, 8, S, 2200))))
      .child(div().absolute().left((S - 10) / 2).top((S - 10) / 2).size(10).rounded_full().bg(c).when(live, (e) => e.loop("opacity", { from: .55, to: 1, period: 1100 })));
  }

  // The pipeline: done steps are filled, the current one glows and a comet of light keeps running into it.
  pipeline(t, stage, W, live) {
    const N = STAGES.length, NODE = 22, step = (W - NODE) / (N - 1), c = t.working, H = 54;
    const el = div().relative().w(W).h(H);
    for (let i = 0; i < N - 1; i++) {
      const x = i * step + NODE, w = step - NODE, done = i < stage.i, into = i === stage.i - 1;
      el.child(div().absolute().left(x + 3).top(NODE / 2 - 1).w(w - 6).h(2).rounded(1).bg(done ? c : t.border).overflow_hidden()
        .when(into && live, (e) => e.bg(c + "40").child(div().absolute().top(0).h(2).w(48)
          .child(ramp(c, ["10", "30", "60", "a0", "d0", "ff"], 8, 2))
          .loop("left", { from: -48, to: w - 6, period: 1500, easing: "ease-in" }))));
    }
    STAGES.forEach((label, i) => {
      const x = i * step, done = i < stage.i, cur = i === stage.i;
      const node = div().absolute().left(x).top(0).size(NODE).rounded_full().flex().items_center().justify_center()
        .bg(done ? c : cur ? c + "26" : t.chrome).border_1().border_color(done || cur ? c : t.border)
        .when(done, (e) => e.child(svg("mods/workspace-chrome/check.svg").size(12).text_color(t.chrome)))
        .when(cur, (e) => e.child(div().size(8).rounded_full().bg(c).when(live, (d) => d.loop("opacity", { from: .45, to: 1, period: 900 }))));
      if (cur && live) el.child(div().absolute().left(x - 9).top(-9).size(NODE + 18).child(this.ripple(c, NODE, NODE + 18, 1800)));
      el.child(node);
      const LW = 76, lx = i === 0 ? 0 : i === N - 1 ? W - LW : x + NODE / 2 - LW / 2;
      el.child(div().absolute().left(lx).top(NODE + 8).w(LW).text_size(10.5).font_medium()
        .when(i === 0, (e) => e.text_left()).when(i === N - 1, (e) => e.text_right()).when(i > 0 && i < N - 1, (e) => e.text_center())
        .text_color(cur ? t.foreground : done ? t.muted : t.dim).child(label));
    });
    return el;
  }

  // A soft band of light that sweeps across the card while it works.
  sheen(t, W) {
    const c = t.working;
    return div().absolute().top(0).left(0).w(W + 28).h_full().overflow_hidden()
      .child(h_flex().absolute().top(0).h_full().w(180).loop("left", { from: -180, to: W + 28, period: 4200, easing: "ease-in-out" })
        .children(["03", "05", "08", "0b", "0e", "11", "13", "13", "11", "0e", "0b", "08", "05", "03"].map((a) => div().h_full().w(13).flex_none().bg(c + a))));
  }

  header(t) {
    const mode = this.mode(), retry = this.state?.retrying?.[0], blocked = this.state?.blocked?.[0];
    const title = { wait: `Retrying ${retry ? idOf(retry) : ""}`, blocked: `${blocked ? idOf(blocked) : ""} is blocked`,
      idle: "Watching Linear", offline: "Symphony is off", loading: "Connecting…" }[mode];
    const sub = { wait: `attempt ${retry?.attempt ?? "?"} · next ${until(retry?.due_at)}`, blocked: "It needs you before it can go on",
      idle: "Picks up LIV tickets labelled symphony and assigned to you", offline: "Nothing is polling Linear", loading: "" }[mode];
    return h_flex().gap(12).items_center().p(14).mx(12).mt(12).rounded(12).bg(t.surface).border_1().border_color(t.border)
      .child(this.orb(t, mode))
      .child(v_flex().flex_1().min_w(0).gap(2)
        .child(div().truncate().text_size(14).font_semibold().text_color(t.foreground).child(title))
        .child(div().truncate().text_size(11.5).text_color(t.muted).child(sub)))
      .child(this.controls(t));
  }

  controls(t) {
    const term = this.term();
    return h_flex().gap(4).flex_none()
      .when(this.offline === true && !term, (el) => el.child(this.ghost(t, "sy-start", this.armed?.key === "start" ? "Confirm" : "Start", (_e, cx) => this.start(cx), this.armed?.key === "start" ? t.ansi2 : null)))
      .when(this.offline === false, (el) => el.child(this.ghost(t, "sy-refresh", this.busy ? "…" : "Poll", (_e, cx) => this.refresh(cx))))
      .when(Boolean(term), (el) => el.child(this.ghost(t, "sy-stop", this.armed?.key === "stop" ? "Confirm" : "Stop", (_e, cx) => this.stop(cx), this.armed?.key === "stop" ? t.ansi1 : null)));
  }

  // The running ticket, as the hero of the tab.
  hero(t, r) {
    const id = idOf(r), L = this.linear[id], st = this.stages[id], stage = stageOf(st, L?.state), tokens = r.tokens ?? {}, open = this.open === id;
    const W = Math.max(200, this.width - 24 - 34), evAge = r.last_event_at ? Date.now() - Date.parse(r.last_event_at) : null, quiet = evAge != null && evAge > 90e3;
    return v_flex().id(`run-${id}`).relative().mx(12).mt(12).rounded(14).bg(t.surface).border_1().border_color(t.working + "55").overflow_hidden()
      .child(this.sheen(t, W))
      .child(v_flex().relative().gap(16).p(16)
        .child(h_flex().gap(10).items_start()
          .child(this.orb(t, "work"))
          .child(v_flex().flex_1().min_w(0).gap(5)
            .child(h_flex().gap(6).items_center()
              .child(div().text_size(11).text_color(t.working).font_medium().child("Working on"))
              .child(this.chip(t, id, t.accent, `rl-${id}`, () => this.openLinear(id)))
              .when(Boolean(L?.state), (el) => el.child(this.chip(t, L.state, t.muted))))
            .child(div().text_size(14).font_semibold().line_height(1.4).whitespace_normal().text_color(t.foreground).child(L?.title ?? (this.fetching ? "Loading the ticket…" : id))))
          .child(this.controls(t)))
        .child(v_flex().gap(4)
          .child(this.pipeline(t, stage, W, true))
          .child(h_flex().gap(6).items_center().flex_wrap()
            .child(div().text_size(11).text_color(t.muted).child(st ? stage.note : "Looking at the workspace…"))
            .children((st?.prs ?? []).slice(0, 3).map((p) => this.prChip(t, p, id)))))
        .child(h_flex().gap(10).items_start().p(11).rounded(10).bg(t.chrome)
          .child(div().w(12).flex_none().text_size(12).text_color(quiet ? t.ansi3 : t.working).child(quiet ? "◌" : "").when(!quiet, (e) => e.frames(SPIN, 80)))
          .child(v_flex().flex_1().min_w(0).gap(3)
            .child(h_flex().gap(6).items_center()
              .child(div().text_size(11.5).font_medium().text_color(t.foreground).child(human(r.last_event)))
              .child(div().text_size(10.5).text_color(quiet ? t.ansi3 : t.dim).child(evAge == null ? "" : quiet ? `quiet for ${span(evAge)}` : ago(r.last_event_at))))
            .when(Boolean(r.last_message), (el) => el.child(div().text_size(11.5).line_height(1.45).whitespace_normal().text_color(t.muted).child(clip(one(r.last_message), 200))))))
        .child(h_flex().gap(10)
          .child(this.stat(t, "Turn", `${Math.min(r.turn_count ?? 0, MAX_TURNS)}/${MAX_TURNS}`))
          .child(this.stat(t, "Time", span(Date.now() - Date.parse(r.started_at ?? Date.now()))))
          .child(this.stat(t, "Tokens", tok(tokens.total_tokens)))
          .child(this.stat(t, "Now", this.rate >= 1 ? `${tok(this.rate)}/s` : "–", this.rate >= 1 ? t.working : t.dim)))
        .child(h_flex().gap(6)
          .child(this.ghost(t, `ow-${id}`, "Open workspace", () => this.openWorkspace(id, r.workspace_path)))
          .child(this.ghost(t, `ev-${id}`, open ? "Hide events" : "Events", (_e, cx) => { this.open = open ? null : id; if (this.open) this.loadDetail(id, cx); cx.notify(); })))
        .when(open, (el) => el.child(this.events(t, id))));
  }

  events(t, id) {
    const d = this.details.get(id);
    if (!d) return div().text_size(11).text_color(t.dim).child("Loading…");
    if (d.error) return div().text_size(11).text_color(t.blocked).child(d.error);
    return v_flex().gap(4).children((d.recent_events ?? []).slice(-8).reverse().map((e, i) => h_flex().id(`e-${id}-${i}`).gap(8).items_start()
      .child(div().w(54).flex_none().text_size(10.5).text_color(t.dim).child(ago(e.at)))
      .child(div().flex_1().min_w(0).text_size(11).line_height(1.4).whitespace_normal().text_color(t.muted)
        .child(`${human(e.event)}${e.message ? " — " + clip(one(e.message), 120) : ""}`))));
  }

  issueCard(t, r, tone, label, detail) {
    const id = idOf(r), L = this.linear[id], stage = stageOf(this.stages[id], L?.state);
    return v_flex().id(`iss-${id}`).gap(7).p(12).mx(12).mt(8).rounded(10).bg(t.surface).border_1().border_color(tone + "55")
      .child(h_flex().gap(6).items_center()
        .child(this.chip(t, id, t.accent, `il-${id}`, () => this.openLinear(id)))
        .child(this.chip(t, label, tone)).child(div().flex_1())
        .child(this.ghost(t, `iw-${id}`, "Workspace", () => this.openWorkspace(id, r.workspace_path))))
      .when(Boolean(L?.title), (el) => el.child(div().text_size(12.5).line_height(1.4).whitespace_normal().text_color(t.foreground).child(L.title)))
      .when(Boolean(detail), (el) => el.child(div().text_size(11).line_height(1.45).whitespace_normal().text_color(t.muted).child(clip(one(detail), 220))))
      .when(Boolean(this.stages[id]), (el) => el.child(h_flex().gap(6).items_center().flex_wrap()
        .child(this.chip(t, STAGES[stage.i], t.muted)).children((this.stages[id].prs ?? []).slice(0, 3).map((p) => this.prChip(t, p, `i${id}`)))));
  }

  // One finished or past ticket: what it was, what came out, what it cost.
  pastRow(t, id) {
    const L = this.linear[id], H = this.history[id], prs = this.prs[id]?.list ?? [];
    const meta = [H?.ended ? `${H.outcome === "blocked" ? "blocked" : "ended"} ${ago(H.ended)}` : null,
      H?.started && H?.ended ? span(H.ended - Date.parse(H.started)) : null, H?.tokens ? `${tok(H.tokens)} tokens` : null, H?.turns ? `${H.turns} turns` : null].filter(Boolean).join(" · ");
    return v_flex().id(`past-${id}`).gap(6).px(12).py(10).mx(12).rounded(10).cursor_pointer().hover((s) => s.bg(t.hover))
      .on_click(() => this.openWorkspace(id, H?.workspace))
      .child(div().text_size(12.5).line_height(1.4).whitespace_normal().text_color(L?.title ? t.foreground : t.muted).child(L?.title ?? (L?.missing ? "Ticket not found" : "…")))
      .child(h_flex().gap(5).items_center().flex_wrap()
        .child(this.chip(t, id, t.accent, `pl-${id}`, () => this.openLinear(id)))
        .when(Boolean(L?.state), (el) => el.child(this.chip(t, L.state, /done|closed/i.test(L.state) ? t.ansi2 : /review/i.test(L.state) ? t.ansi3 : t.muted)))
        .children(prs.slice(0, 3).map((p) => this.prChip(t, p, `p${id}`)))
        .when(!prs.length && Boolean(this.prs[id]), (el) => el.child(this.chip(t, "no PR", t.dim))))
      .when(Boolean(meta), (el) => el.child(div().text_size(10.5).text_color(t.dim).child(meta)));
  }

  section(t, text, n, onClick, open) {
    return h_flex().id(`sec-${text}`).px(20).pt(18).pb(4).gap(7).items_center().when(Boolean(onClick), (e) => e.cursor_pointer().on_click(onClick))
      .child(div().text_size(11.5).font_semibold().text_color(t.muted).child(text))
      .when(n != null, (el) => el.child(div().text_size(11).text_color(t.dim).child(String(n))))
      .when(Boolean(onClick), (el) => el.child(div().flex_1()).child(svg(`mods/workspace-chrome/chevron-${open ? "down" : "right"}.svg`).size(12).text_color(t.dim)));
  }

  usage(t) {
    const tot = this.state?.codex_totals, rl = this.state?.rate_limits;
    if (!tot && !(rl?.primary || rl?.secondary)) return null;
    return this.fade("usage", v_flex().gap(12).px(14).py(12).mx(12).mt(10).rounded(12).bg(t.surface).border_1().border_color(t.border)
      .child(h_flex().items_center()
        .child(div().text_size(11.5).font_semibold().text_color(t.muted).child("Usage"))
        .child(div().flex_1())
        .child(div().text_size(10.5).text_color(t.dim).child("since Symphony started")))
      .when(Boolean(tot), (el) => el.child(h_flex().gap(10)
        .child(this.stat(t, "Tokens", tok(tot.total_tokens)))
        .child(this.stat(t, "In / out", `${tok(tot.input_tokens)} / ${tok(tot.output_tokens)}`))
        .child(this.stat(t, "Agent time", span((tot.seconds_running ?? 0) * 1000)))))
      .when(Boolean(rl?.primary || rl?.secondary), (el) => el.child(h_flex().gap(18).flex_wrap().pt(10).border_t(1).border_color(t.border)
        .when(Boolean(rl.primary), (e) => e.child(this.meter(t, "Codex 5h", rl.primary.usedPercent)))
        .when(Boolean(rl.secondary), (e) => e.child(this.meter(t, "Week", rl.secondary.usedPercent))))));
  }

  // A block that wasn't on screen at the last poll starts 6px low and transparent, then settles.
  fade(key, el) {
    const fresh = this.entering.has(key);
    this.present.add(key);
    return el.relative().top(fresh ? 6 : 0).opacity(fresh ? 0 : 1)
      .transition("top", { duration: 320, easing: "ease-out" }).transition("opacity", { duration: 280, easing: "ease-out" });
  }

  // Called after each poll: whatever is new since the last frame gets the entrance.
  settle(cx) {
    if (!(this.shown?.() ?? false)) { this.primed = false; this.present = new Set(); return; }
    const fresh = [...this.present].filter((k) => !this.seen.has(k));
    this.seen = new Set(this.present); this.present = new Set();
    if (!this.primed) { this.primed = true; return; }
    if (!fresh.length) return;
    for (const k of fresh) this.entering.add(k);
    cx.notify();
    cx.timer.after(40, (cx) => { for (const k of fresh) this.entering.delete(k); cx.notify(); });
  }

  view(t) {
    const s = this.state, running = this.running(), out = running.length ? running.map((r) => this.hero(t, r)) : [this.header(t)];
    const u = s ? this.usage(t) : null;
    if (u) out.push(u);
    if (s) {
      if ((s.blocked ?? []).length) { out.push(this.section(t, "Blocked", s.blocked.length)); out.push(...s.blocked.map((r) => this.fade(`b-${idOf(r)}`, this.issueCard(t, r, t.blocked, "blocked", r.error ?? r.last_message)))); }
      if ((s.retrying ?? []).length) { out.push(this.section(t, "Retrying", s.retrying.length)); out.push(...s.retrying.map((r) => this.fade(`r-${idOf(r)}`, this.issueCard(t, r, t.ansi3, `attempt ${r.attempt ?? "?"} · ${until(r.due_at)}`, r.error)))); }
    }
    const live = new Set(this.live().map(idOf));
    const past = [...new Set([...Object.values(this.history).sort((a, b) => b.ended - a.ended).map((h) => h.id), ...this.disk])].filter((id) => !live.has(id));
    if (past.length) {
      const shown = this.showAll ? past : past.slice(0, 5);
      out.push(this.section(t, "Recent runs", past.length));
      out.push(v_flex().gap(2).children(shown.map((id) => this.fade(`p-${id}`, this.pastRow(t, id)))));
      if (past.length > 5) out.push(h_flex().id("sy-more").mx(24).mt(4).text_size(11.5).text_color(t.dim).cursor_pointer().hover((x) => x.text_color(t.foreground))
        .on_click((_e, cx) => { this.showAll = !this.showAll; cx.notify(); }).child(this.showAll ? "Show fewer" : `Show ${past.length - 5} more`));
    }
    return out;
  }
}
