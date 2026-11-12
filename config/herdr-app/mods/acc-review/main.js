import { View, div } from "gpui-kit";
import { v_flex, h_flex, TextView, TextareaState, Textarea } from "gpui-base";
import { exec, theme, layout, notify, readTextFile, writeTextFile, home, spaces, panes, focused, terminals, agents, setShared, settings, run, props } from "herdr";

const REPO = "livestorm/entropy";
const DIR = "~/nix-config/config/herdr-app/automation";
const OUT = "~/.local/state/acc-automation/reviews";
const STALE_DAYS = 21;
const FIELDS = "number,title,author,additions,deletions,changedFiles,isDraft,mergeable,mergeStateStatus,reviewDecision,updatedAt,createdAt,headRefOid,headRefName,baseRefName,url,body,statusCheckRollup";
const CHECKOUT = "~/Documents/livestorm/entropy";
const WRITE = new Set(["WRITE", "MAINTAIN", "ADMIN"]);
const DETAIL = `query($url: URI!) { resource(url: $url) { ... on PullRequest {
  reviewThreads(first: 80) { nodes { isResolved isOutdated path line comments(first: 1) { nodes { author { login } body url } } } } } } }`;
const TABS = {
  review: [["eli5", "ELI5"], ["desc", "Description"], ["checks", "Checks"], ["convo", "Comments"], ["comments", "Drafts"]],
  mine: [["desc", "Description"], ["checks", "Checks"], ["convo", "Comments"], ["threads", "Threads"], ["comments", "Self-review"]],
};
const BOTS = /(\[bot\]|-apps|-?bot)$|^app\/|^(livestorm-entropy|linear|codecov|github-actions|sentry-io|vercel|greptile|amazon-inspector|sonarcloud|snyk|dependabot|renovate)/i;
const slug = (b) => b.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
const oneLine = (s) => String(s ?? "").replace(/\s+/g, " ").trim();

function where() {
  const space = spaces().find((x) => x.active), f = focused();
  const pane = f?.pane ? panes().find((x) => x.pane === f.pane) : null;
  return { cwd: pane?.cwd || f?.cwd || space?.folder || null, machine: space?.machine ?? null };
}

function fixPrompt(p, threads) {
  const c = checks(p), todo = [];
  if (p.mergeable === "CONFLICTING") todo.push(`Conflicts: the branch conflicts with ${p.baseRefName}. Merge origin/${p.baseRefName} into it (merge, not rebase) and resolve every conflict, keeping the intent of both sides.`);
  if (c.fail.length) todo.push(`Red CI: failing checks are ${c.fail.map((f) => `"${f.name}"`).join(", ")}. Find the cause with \`gh pr checks ${p.number}\` and \`gh run view <run-id> --log-failed\`, reproduce locally where possible, and fix the code (or the test if the test is wrong).`);
  if (threads.length) todo.push(`Review comments: address each unresolved thread below. If a comment is wrong or not worth acting on, say why in your summary instead of changing code.\n${threads.slice(0, 12).map((t, i) => `   ${i + 1}) [${t.who}] ${t.path}${t.line ? ":" + t.line : ""}: ${clip(oneLine(t.body), 600)}`).join("\n")}`);
  return [`Fix pull request #${p.number} "${p.title}" (${REPO}, branch ${p.headRefName}). You are in a git worktree of that branch.`, "", "What to do:",
    ...todo.map((x, i) => `${i + 1}. ${x}`), "",
    "Rules: follow this repository's own instructions (AGENTS.md / CLAUDE.md). Stay on this branch. Commit your work locally in small commits.",
    "Do NOT push, force-push, resolve review threads, or merge: stop after committing and give me a short summary of what you changed, what you chose not to change and why, and anything still failing."].join("\n");
}
const ENTER = { duration: 260, easing: "ease-out" };
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const ago = (iso) => {
  const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  return s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d`;
};

function checks(pr) {
  const all = (pr.statusCheckRollup ?? []).map((c) => {
    const state = (c.conclusion || c.state || c.status || "PENDING").toUpperCase();
    const kind = ["SUCCESS", "NEUTRAL", "SKIPPED"].includes(state) ? "ok" : ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].includes(state) ? "fail" : "run";
    return { name: c.name || c.context || "check", kind, state, url: c.detailsUrl || c.targetUrl };
  });
  const fail = all.filter((c) => c.kind === "fail"), runn = all.filter((c) => c.kind === "run");
  return { all, fail, run: runn, summary: !all.length ? "none" : fail.length ? "failing" : runn.length ? "running" : "green" };
}

export default class Review extends View {
  init(_p, cx) {
    this.dir = DIR.replace(/^~/, home()); this.out = OUT.replace(/^~/, home());
    this.prs = []; this.files = { eli5: {}, review: {} }; this.open = null; this.tab = "eli5"; this.showStale = false;
    this.cache = {}; this.explaining = new Set(); this.seen = new Map(); this.pending = []; this.next = 0; this.error = null; this.copied = null; this.edits = {}; this.posting = new Set();
    this.mode = props()?.mode === "mine" ? "mine" : "review"; this.tab = this.mode === "mine" ? "desc" : "eli5";
    this.checkout = CHECKOUT.replace(/^~/, home()); this.threads = new Map(); this.convo = new Map(); this.showBots = false; this.width = 440; this.armed = null; this.busy = null; this.merge = null;
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

  visible() { const n = find(layout(), this.mode === "mine" ? "prs" : "review"); return Boolean(n) && !n.hidden; }

  tick(cx) {
    const t = Date.now(), vis = this.visible();
    if (this.pending.length) this.settle(cx); // blocks that arrived from async loads, not a click, would stay at opacity 0
    if (vis) {
      const sig = (panes() ?? []).filter((p) => p.status && p.branch).map((p) => `${p.branch}:${p.status}`).sort().join("|");
      if (sig !== this.agentSig) { this.agentSig = sig; cx.notify(); }
    }
    if (vis && !this.shown) this.next = 0;
    this.shown = vis;
    if (t >= this.next) { this.next = t + (vis ? 60000 : 300000); this.load(cx); }
    else if (vis && Math.floor(t / 1000) % 4 === 0) this.scan(cx);
  }

  settle(cx) {
    cx.timer.after(50, (cx) => {
      if (!this.pending.length) return;
      this.pending.forEach((k, i) => this.seen.set(k, Math.min(i * 35, 280)));
      this.pending = []; cx.notify();
    });
  }
  appear(key, el) {
    const d = this.seen.get(key);
    if (d === undefined && !this.pending.includes(key)) this.pending.push(key);
    return el.relative().opacity(d === undefined ? 0 : 1).top(d === undefined ? 8 : 0)
      .transition("opacity", { ...ENTER, delay: d ?? 0 }).transition("top", { ...ENTER, delay: d ?? 0 });
  }

  load(cx) {
    cx.spawn(async (cx) => {
      try {
        const q = (search) => exec("gh", ["pr", "list", "-R", REPO, "--state", "open", "--search", search, "--json", FIELDS, "--limit", "60"], { timeout: 30000 });
        const [a, b] = this.mode === "mine" ? [await q("author:@me"), { code: 1 }] : await Promise.all([q("review-requested:@me"), q("assignee:@me -author:@me")]);
        if (this.mode === "mine" && this.merge === null) {
          const r = await exec("gh", ["repo", "view", REPO, "--json", "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,viewerPermission"], { timeout: 20000 });
          const m = r.code === 0 ? JSON.parse(r.stdout) : {};
          this.merge = WRITE.has(m.viewerPermission) ? (m.squashMergeAllowed ? "--squash" : m.mergeCommitAllowed ? "--merge" : m.rebaseMergeAllowed ? "--rebase" : "") : "";
        }
        if (a.code !== 0) throw new Error(a.stderr.trim().slice(0, 160));
        const map = new Map();
        for (const pr of [...JSON.parse(a.stdout), ...(b.code === 0 ? JSON.parse(b.stdout) : [])]) map.set(pr.number, pr);
        this.prs = [...map.values()].sort((x, y) => String(x.createdAt).localeCompare(String(y.createdAt)));
        this.error = null;
        if (this.mode === "review") setShared("review.count", this.active().length);
      } catch (e) { this.error = String(e.message ?? e); }
      await this.scan(cx);
      cx.notify(); this.settle(cx);
    });
  }

  async scan(cx) {
    try {
      const r = await exec("sh", ["-c", `cd "${this.out}" 2>/dev/null && ls *.eli5.md 2>/dev/null; for f in *.review.json; do [ -f "$f" ] && jq -c '{pr, sha, status, n: ((.comments // []) | length), blockers: ([.comments[]? | select(.label == "blocker")] | length)}' "$f"; done`], { timeout: 5000 });
      const eli5 = {}, review = {};
      for (const line of r.stdout.split("\n").filter(Boolean)) {
        if (line.endsWith(".eli5.md")) eli5[line.replace(".eli5.md", "")] = true;
        else try { const x = JSON.parse(line); review[`${x.pr}-${x.sha.slice(0, 7)}`] = x; } catch {}
      }
      const changed = JSON.stringify([eli5, review]) !== JSON.stringify([this.files.eli5, this.files.review]);
      this.files = { eli5, review };
      if (changed) {
        this.cache = {};
        const pr = this.prs.find((p) => p.number === this.open);
        if (pr) await this.loadFiles(pr);
        cx.notify(); this.settle(cx);
      }
    } catch {}
  }

  stale(pr) {
    if (this.mode === "mine") return Date.now() - Date.parse(pr.updatedAt) > STALE_DAYS * 864e5;
    return pr.isDraft || /^app\/|\[bot\]$/.test(pr.author?.login ?? "") || pr.author?.is_bot || Date.now() - Date.parse(pr.updatedAt) > STALE_DAYS * 864e5;
  }
  active() { return this.prs.filter((p) => !this.stale(p)); }
  id(pr) { return `${pr.number}-${pr.headRefOid.slice(0, 7)}`; }
  // The terminal stays live on "Press Enter to close", so the review file's status says when it is really over.
  reviewing(pr) { const tm = this.term(pr), st = this.files.review[this.id(pr)]?.status; return tm && (!st || st === "running") ? tm : null; }
  async loadFiles(pr) { for (const kind of ["eli5.md", "review.json"]) await this.text(`${this.out}/${this.id(pr)}.${kind}`); }
  term(pr) { return (terminals() ?? []).find((x) => x.state === "live" && (x.foreground?.argv ?? x.argv ?? []).join(" ").includes(`review.py review ${pr.number}`)); }

  async text(path) {
    if (!(path in this.cache)) this.cache[path] = await readTextFile(path).catch(() => null);
    return this.cache[path];
  }

  explain(pr, cx) {
    const key = this.id(pr);
    if (this.files.eli5[key] || this.explaining.has(key)) return;
    this.explaining.add(key); cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("python3", [`${this.dir}/review.py`, "eli5", String(pr.number)], { cwd: this.dir, timeout: 180000 });
        if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim().slice(-200));
      } catch (e) { notify({ title: `ELI5 failed for #${pr.number}`, body: String(e.message ?? e), level: "error" }); }
      this.explaining.delete(key); await this.scan(cx); cx.notify();
    });
  }

  select(pr, cx) {
    this.open = pr.number; this.tab = this.mode === "mine" ? "desc" : "eli5"; cx.notify(); this.settle(cx);
    if (this.mode === "mine") this.loadThreads(pr, cx); else this.explain(pr, cx);
    this.loadConvo(pr, cx);
    cx.spawn(async (cx) => { await this.loadFiles(pr); cx.notify(); });
  }

  loadConvo(pr, cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("gh", ["pr", "view", String(pr.number), "-R", REPO, "--json", "comments,reviews"], { timeout: 30000 });
        if (r.code !== 0) throw new Error(r.stderr.trim().split("\n")[0]);
        const d = JSON.parse(r.stdout);
        const items = [
          ...(d.comments ?? []).map((c) => ({ who: c.author?.login ?? "?", at: c.createdAt, body: c.body ?? "", url: c.url })),
          ...(d.reviews ?? []).filter((v) => v.body?.trim() || v.state !== "COMMENTED").map((v) => ({ who: v.author?.login ?? "?", at: v.submittedAt, body: v.body ?? "", state: v.state, url: pr.url })),
        ].map((x) => ({ ...x, bot: BOTS.test(x.who) })).sort((a, b) => String(a.at).localeCompare(String(b.at)));
        this.convo.set(pr.number, items);
      } catch (e) { this.convo.set(pr.number, { error: String(e.message ?? e).slice(0, 160) }); }
      cx.notify();
    });
  }

  loadThreads(pr, cx) {
    cx.spawn(async (cx) => {
      try {
        const r = await exec("gh", ["api", "graphql", "-f", `query=${DETAIL}`, "-f", `url=${pr.url}`], { timeout: 45000 });
        if (r.code !== 0) throw new Error(r.stderr.trim().split("\n")[0]);
        const nodes = JSON.parse(r.stdout).data.resource.reviewThreads.nodes ?? [];
        this.threads.set(pr.number, nodes.filter((x) => !x.isResolved && !x.isOutdated && x.comments?.nodes?.[0]).map((x) => {
          const c = x.comments.nodes[0], who = c.author?.login ?? "unknown";
          return { path: x.path, line: x.line, who, bot: /greptile|\[bot\]/i.test(who), body: c.body ?? "", url: c.url };
        }));
      } catch (e) { this.threads.set(pr.number, { error: String(e.message ?? e).slice(0, 160) }); }
      cx.notify();
    });
  }

  async worktree(pr) {
    const git = (args, timeout = 120000) => exec("git", ["-C", this.checkout, ...args], { timeout });
    const f = await git(["fetch", "origin", pr.headRefName]);
    if (f.code !== 0) throw new Error(f.stderr.trim().slice(0, 240));
    let path = null, cur = null;
    for (const l of (await git(["worktree", "list", "--porcelain"])).stdout.split("\n")) {
      if (l.startsWith("worktree ")) cur = l.slice(9);
      else if (l === `branch refs/heads/${pr.headRefName}`) path = cur;
    }
    if (path) return path;
    path = `${home()}/.herdr/worktrees/entropy/${slug(pr.headRefName)}`;
    const local = (await git(["show-ref", "--verify", "--quiet", `refs/heads/${pr.headRefName}`])).code === 0;
    const add = await git(local ? ["worktree", "add", path, pr.headRefName] : ["worktree", "add", "--track", "-b", pr.headRefName, path, `origin/${pr.headRefName}`]);
    if (add.code !== 0) throw new Error(add.stderr.trim().slice(0, 240));
    return path;
  }

  openWorktree(pr, cx, then) {
    if (this.busy) return;
    this.busy = `wt-${pr.number}`; cx.notify();
    cx.spawn(async (cx) => {
      try {
        const path = await this.worktree(pr), known = spaces().find((s) => s.folder === path && !s.machine);
        if (then) then(path, known);
        else if (known) run("space.select", { id: known.id });
        else run("space.new", { name: pr.headRefName.replace(/^liv-\d+-/, ""), folder: path });
      } catch (e) { notify({ title: `Cannot open #${pr.number}`, body: String(e.message ?? e), level: "error" }); }
      this.busy = null; cx.notify();
    });
  }

  checkoutHere(pr, cx) {
    const w = where();
    if (!w.cwd || w.machine) { notify({ title: "No local folder", body: "Focus a terminal inside a checkout of entropy first.", level: "error" }); return; }
    this.busy = `co-${pr.number}`; cx.notify();
    cx.spawn(async (cx) => {
      const r = await exec("gh", ["pr", "checkout", String(pr.number), "-R", REPO], { cwd: w.cwd, timeout: 120000 }).catch((e) => ({ code: 1, stderr: String(e) }));
      notify(r.code === 0 ? { title: `Checked out #${pr.number}`, body: `${pr.headRefName} in ${w.cwd.replace(home(), "~")}`, level: "success", timeout: 3000 }
        : { title: "Checkout failed", body: (r.stderr || r.stdout).trim().slice(0, 240), level: "error" });
      this.busy = null; cx.notify();
    });
  }

  fix(pr, cx) {
    const threads = Array.isArray(this.threads.get(pr.number)) ? this.threads.get(pr.number) : [];
    this.openWorktree(pr, cx, (path, known) => {
      const args = { name: `fix #${pr.number}`, folder: path, argv: ["omp"], task: fixPrompt(pr, threads) };
      if (known) run("tab.new", { space: known.id, ...args }); else run("space.new", args);
      notify({ title: `Fix started on #${pr.number}`, body: path.replace(home(), "~"), level: "success", timeout: 3000 });
    });
  }

  mergePr(pr, cx) {
    if (this.armed !== pr.number) { this.armed = pr.number; cx.notify(); cx.timer.after(6000, (cx) => { if (this.armed === pr.number) { this.armed = null; cx.notify(); } }); return; }
    this.armed = null; this.busy = `mg-${pr.number}`; cx.notify();
    cx.spawn(async (cx) => {
      const r = await exec("gh", ["pr", "merge", String(pr.number), "-R", REPO, this.merge], { timeout: 60000 }).catch((e) => ({ code: 1, stderr: String(e) }));
      notify(r.code === 0 ? { title: `Merged #${pr.number}`, body: pr.title, level: "success", timeout: 4000 } : { title: `Merge #${pr.number} failed`, body: (r.stderr || r.stdout).trim().slice(0, 300), level: "error" });
      this.busy = null; this.next = 0; cx.notify();
    });
  }

  toggleDraft(pr, cx) {
    const key = `rd-${pr.number}`;
    if (this.armed !== key) { this.armed = key; cx.notify(); cx.timer.after(6000, (cx) => { if (this.armed === key) { this.armed = null; cx.notify(); } }); return; }
    this.armed = null; this.busy = key; cx.notify();
    const toReady = pr.isDraft;
    cx.spawn(async (cx) => {
      const r = await exec("gh", ["pr", "ready", String(pr.number), "-R", REPO, ...(toReady ? [] : ["--undo"])], { timeout: 30000 }).catch((e) => ({ code: 1, stderr: String(e) }));
      if (r.code === 0) {
        pr.isDraft = !toReady;
        notify({ title: toReady ? `#${pr.number} is ready for review` : `#${pr.number} is back to draft`, body: pr.title, level: "success", timeout: 3000 });
      } else notify({ title: "Could not change the draft state", body: (r.stderr || r.stdout).trim().slice(0, 240), level: "error" });
      this.busy = null; this.next = Date.now() + 3000; cx.notify();
    });
  }

  ready(pr) { return Boolean(this.merge) && !pr.isDraft && pr.mergeStateStatus === "CLEAN"; }

  stacks(list) {
    const byHead = new Map(list.map((p) => [p.headRefName, p])), kids = new Map();
    const parent = (p) => (p.baseRefName !== p.headRefName ? byHead.get(p.baseRefName) : null);
    for (const p of list) { const par = parent(p); if (par) kids.set(par.number, [...(kids.get(par.number) ?? []), p]); }
    return list.filter((p) => !parent(p)).map((root) => {
      const out = [], walk = (p) => { out.push(p); for (const k of kids.get(p.number) ?? []) walk(k); };
      walk(root); return out;
    }).sort((a, b) => Math.max(...b.map((p) => Date.parse(p.updatedAt))) - Math.max(...a.map((p) => Date.parse(p.updatedAt))));
  }

  stackOf(pr) { return this.stacks(this.prs).find((g) => g.some((p) => p.number === pr.number)) ?? [pr]; }

  diff(pr) {
    const cmd = `gh pr diff ${pr.number} -R ${REPO} | (command -v diffnav >/dev/null && diffnav || delta --paging=always)`;
    run("pane.split", { direction: "right", argv: ["sh", "-c", cmd] });
  }

  startReview(pr) {
    const tm = this.reviewing(pr);
    if (tm) return run("agent.focus", { terminal: tm.address });
    const argv = ["python3", `${this.dir}/review.py`, "review", String(pr.number)], known = spaces().find((s) => s.name === "review" && !s.machine);
    if (known) run("tab.new", { space: known.id, name: `review #${pr.number}`, folder: this.dir, argv });
    else run("space.new", { name: "review", folder: this.dir, argv });
    notify({ title: `Reviewing #${pr.number}`, body: "Frontend files only. Drafts land in the Comments tab.", level: "info", timeout: 3000 });
  }

  copy(text, key, cx) {
    exec("python3", ["-c", "import subprocess,sys; subprocess.run(['pbcopy'], input=sys.argv[1].encode())", text]).then((r) => {
      if (r.code !== 0) return notify({ title: "Copy failed", level: "error" });
      this.copied = key; cx.notify();
      cx.timer.after(1500, (cx) => { if (this.copied === key) { this.copied = null; cx.notify(); } });
    });
  }

  button(t, id, label, onClick, tone) {
    const solid = tone === "primary";
    return div().id(id).h(26).px(11).flex().items_center().rounded(7).flex_none().text_size(11.5).font_semibold()
      .bg(solid ? t.solid : t.raised).text_color(solid ? t.solid_foreground : t.foreground).border_1().border_color(solid ? t.solid : t.border)
      .hover((s) => s.opacity(.9)).on_click(onClick).child(label);
  }
  ghost(t, id, label, onClick) {
    return div().id(id).h(24).px(8).flex().items_center().rounded(7).flex_none().text_size(11).font_semibold().text_color(t.muted)
      .hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(onClick).child(label);
  }
  chip(t, text, color, bg) { return div().px(7).h(18).flex().items_center().rounded(9).text_size(10.5).font_semibold().text_color(color).bg(bg ?? t.raised).flex_none().child(text); }
  dot(t, color, pulse) { const d = div().size(7).rounded(4).bg(color).flex_none(); return pulse ? d.loop("opacity", { from: .35, to: 1, period: 1100 }) : d; }

  ciChip(t, pr) {
    const c = checks(pr);
    if (c.summary === "failing") return this.chip(t, `✕ ${c.fail.length} failing`, t.ansi1);
    if (c.summary === "running") return this.chip(t, `● ${c.run.length} running`, t.ansi3);
    if (c.summary === "green") return this.chip(t, "✓ CI", t.ansi2);
    return null;
  }

  sizeBar(t, pr, w) {
    const total = Math.max(1, pr.additions + pr.deletions), add = Math.round(w * pr.additions / total);
    return h_flex().w(w).h(4).rounded(2).overflow_hidden().bg(t.raised).flex_none()
      .child(div().h(4).w(add).bg(t.ansi2)).child(div().h(4).w(w - add).bg(t.ansi1));
  }

  agentOn(pr) {
    const rank = { blocked: 0, working: 1, done: 2, idle: 3 };
    const on = (panes() ?? []).filter((p) => p.status && p.terminal && p.branch === pr.headRefName).sort((a, b) => (rank[a.status] ?? 9) - (rank[b.status] ?? 9));
    return on.length ? { status: on[0].status, terminal: on[0].terminal, count: on.length } : null;
  }

  agentChip(t, pr) {
    const a = this.agentOn(pr);
    if (!a) return null;
    const look = { working: ["agent working", t.working, true], blocked: ["agent needs you", t.blocked, false], done: ["agent done", t.done, false], idle: ["agent idle", t.muted, false] }[a.status] ?? ["agent", t.muted, false];
    return h_flex().id(`ag-${pr.number}`).h(18).px(7).gap(5).items_center().rounded(9).flex_none().bg(t.raised).border_1().border_color(a.status === "blocked" ? t.blocked : t.raised)
      .cursor_pointer().hover((s) => s.border_color(look[1]))
      .on_click((_e, cx) => { cx.stop_propagation(); run("agent.focus", { terminal: a.terminal }); })
      .child(this.dot(t, look[1], look[2]))
      .child(div().text_size(10.5).font_semibold().text_color(look[1]).child(a.count > 1 ? `${look[0]} · ${a.count}` : look[0]));
  }

  stateChips(t, pr) {
    const ci = this.ciChip(t, pr), out = [], ag = this.agentChip(t, pr);
    if (ag) out.push(ag);
    if (pr.isDraft) out.push(this.chip(t, "draft", t.muted));
    if (ci) out.push(ci);
    if (pr.mergeable === "CONFLICTING") out.push(this.chip(t, "⚠ conflicts", t.ansi1));
    else if (this.mode === "mine" && pr.mergeStateStatus === "BEHIND") out.push(this.chip(t, "behind base", t.ansi3));
    if (pr.reviewDecision === "APPROVED") out.push(this.chip(t, "approved", t.ansi2));
    if (pr.reviewDecision === "CHANGES_REQUESTED") out.push(this.chip(t, "changes requested", t.ansi3));
    if (this.mode === "mine" && this.ready(pr)) out.push(this.chip(t, "ready to merge", t.ansi2, t.selected));
    const rv = this.files.review[this.id(pr)], tm = this.reviewing(pr);
    if (tm) out.push(h_flex().gap(5).items_center().child(this.dot(t, t.working, true)).child(div().text_size(10.5).text_color(t.working).child("reviewing")));
    else if (rv?.status === "ok") out.push(this.chip(t, rv.n ? `${rv.n} ${this.mode === "mine" ? "notes" : "drafts"}${rv.blockers ? ` · ${rv.blockers} blocker` : ""}` : "review clean", rv.blockers ? t.ansi1 : t.accent));
    return out;
  }

  sizeLine(t, pr, w) {
    return h_flex().gap(6).items_center().flex_none()
      .child(div().text_size(11).font_semibold().text_color(t.ansi2).child(`+${pr.additions}`))
      .child(div().text_size(11).font_semibold().text_color(t.ansi1).child(`−${pr.deletions}`))
      .child(this.sizeBar(t, pr, w));
  }

  row(t, pr) {
    const who = this.mode === "mine" ? `#${pr.number} · ${pr.headRefName.replace(/^liv-\d+-/, "")}` : `#${pr.number} · @${pr.author.login} · ${ago(pr.createdAt)}`;
    return this.appear(`pr-${pr.number}`, v_flex().id(`pr-${pr.number}`).mx(10).mb(8).p(12).gap(8).rounded(10).bg(t.surface).border_1().border_color(t.border)
      .cursor_pointer().hover((s) => s.border_color(t.input)).on_click((_e, cx) => this.select(pr, cx))
      .child(div().text_size(13).font_semibold().line_height(1.4).whitespace_normal().text_color(t.foreground).child(clip(pr.title, 120)))
      .child(h_flex().gap(8).items_center()
        .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.muted).child(who))
        .child(this.sizeLine(t, pr, 44)))
      .child(h_flex().gap(6).items_center().flex_wrap().children(this.stateChips(t, pr).concat(this.chip(t, `${pr.changedFiles} files`, t.muted)))));
  }

  stackCard(t, group) {
    const top = [...group].reverse(), base = group[0].baseRefName;
    return this.appear(`stack-${group[0].number}`, v_flex().id(`stack-${group[0].number}`).mx(10).mb(8).rounded(10).bg(t.surface).border_1().border_color(t.border).overflow_hidden()
      .child(h_flex().px(12).h(30).gap(8).items_center().border_b(1).border_color(t.border)
        .child(div().text_size(10).font_semibold().text_color(t.dim).child("STACK"))
        .child(div().text_size(11).text_color(t.muted).child(`${group.length} PRs on ${base}`))
        .child(div().flex_1())
        .child(div().text_size(11).text_color(t.muted).child(`+${group.reduce((a, p) => a + p.additions, 0)} −${group.reduce((a, p) => a + p.deletions, 0)}`)))
      .children(top.map((pr, i) => h_flex().id(`sk-${pr.number}`).gap(10).px(12).items_stretch().cursor_pointer().hover((s) => s.bg(t.hover))
        .on_click((_e, cx) => this.select(pr, cx))
        .child(v_flex().w(10).items_center().flex_none()
          .child(div().w(2).h(14).bg(i === 0 ? t.surface : t.input))
          .child(div().size(10).rounded(5).border_2().border_color(this.ready(pr) ? t.ansi2 : checks(pr).summary === "failing" ? t.ansi1 : t.input).bg(t.background).flex_none())
          .child(div().w(2).flex_1().bg(i === top.length - 1 ? t.surface : t.input)))
        .child(v_flex().flex_1().min_w(0).py(10).gap(5)
          .child(h_flex().gap(8).items_center()
            .child(div().flex_1().min_w(0).truncate().text_size(12.5).font_semibold().text_color(t.foreground).child(`#${pr.number} ${pr.title}`))
            .child(this.sizeLine(t, pr, 32)))
          .child(h_flex().gap(6).items_center().flex_wrap().children(this.stateChips(t, pr)))))));
  }

  listView(t) {
    const act = this.active(), stale = this.prs.filter((p) => this.stale(p)), out = [], mine = this.mode === "mine";
    if (this.error) out.push(div().px(14).py(10).text_size(11).text_color(t.blocked).child(this.error));
    if (!act.length && !this.error) out.push(this.appear("empty", v_flex().mx(10).mt(12).p(20).gap(6).items_center().rounded(10).border_1().border_color(t.border)
      .child(div().text_size(13).font_semibold().text_color(t.foreground).child(mine ? "No open PR" : "Nothing to review"))
      .child(div().text_size(11.5).text_color(t.muted).child(mine ? "Your open PRs on entropy show up here, grouped by stack." : "Active PRs where you are a reviewer or assignee show up here."))));
    if (mine) out.push(...this.stacks(act).map((g) => (g.length > 1 ? this.stackCard(t, g) : this.row(t, g[0]))));
    else out.push(...act.map((p) => this.row(t, p)));
    if (stale.length) {
      out.push(h_flex().px(14).pt(10).pb(6).justify_between().items_center()
        .child(div().text_size(10).font_semibold().text_color(t.dim).child(`${mine ? "QUIET FOR 3 WEEKS" : "STALE OR DRAFT"}  ${stale.length}`))
        .child(this.ghost(t, "stale-fold", this.showStale ? "Hide" : "Show", (_e, cx) => { this.showStale = !this.showStale; cx.notify(); this.settle(cx); })));
      if (this.showStale) out.push(...stale.map((p) => this.row(t, p)));
    }
    return out;
  }

  md(t, id, text) {
    return TextView.markdown(id, text).selectable(true).text_size(12.5).text_color(t.foreground).on_link_click((url) => exec("open", [url]));
  }

  tabBody(t, pr) {
    const key = this.id(pr);
    if (this.tab === "eli5") {
      const text = this.cache[`${this.out}/${key}.eli5.md`];
      if (text) return this.appear(`eli5-${key}`, v_flex().p(14).rounded(10).bg(t.surface).border_1().border_color(t.border).child(this.md(t, `eli5-md-${key}`, text)));
      if (this.explaining.has(key)) return v_flex().p(14).gap(8).rounded(10).bg(t.surface).border_1().border_color(t.border)
        .child(div().text_size(11.5).text_color(t.muted).child("Sonnet is reading the diff, about 30 seconds…"))
        .children([0.9, 0.75, 0.82, 0.6].map((w, i) => div().h(10).rounded(5).bg(t.raised).w(Math.round(w * 300)).loop("opacity", { from: .35, to: .9, period: 1300 + i * 120 })));
      return v_flex().p(14).gap(8).items_start().child(div().text_size(12).text_color(t.muted).child("No explanation yet."))
        .child(this.button(t, "eli5-go", "Explain this PR", (_e, cx) => this.explain(pr, cx)));
    }
    if (this.tab === "desc") return v_flex().p(14).rounded(10).bg(t.surface).border_1().border_color(t.border)
      .child(pr.body?.trim() ? this.md(t, `desc-${key}`, pr.body) : div().text_size(12).text_color(t.muted).child("The author wrote no description."));
    if (this.tab === "checks") {
      const c = checks(pr), order = [...c.fail, ...c.run, ...c.all.filter((x) => x.kind === "ok")];
      return v_flex().rounded(10).bg(t.surface).border_1().border_color(t.border).overflow_hidden()
        .child(h_flex().px(12).h(34).gap(8).items_center().border_b(1).border_color(t.border)
          .child(div().text_size(12).font_semibold().text_color(t.foreground).child(`${c.fail.length} failing · ${c.run.length} running · ${c.all.length - c.fail.length - c.run.length} passed`))
          .when(pr.mergeable === "CONFLICTING", (el) => el.child(this.chip(t, "⚠ merge conflicts", t.ansi1))))
        .children(order.slice(0, 40).map((x, i) => h_flex().id(`ck-${i}`).px(12).h(28).gap(8).items_center().hover((s) => s.bg(t.hover))
          .when(Boolean(x.url), (el) => el.cursor_pointer().on_click(() => exec("open", [x.url])))
          .child(this.dot(t, x.kind === "fail" ? t.ansi1 : x.kind === "run" ? t.ansi3 : t.ansi2, x.kind === "run"))
          .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(x.kind === "ok" ? t.muted : t.foreground).child(x.name))
          .child(div().text_size(10.5).text_color(t.dim).child(x.state.toLowerCase()))));
    }
    if (this.tab === "convo") {
      const all = this.convo.get(pr.number);
      if (!all) return div().p(14).text_size(12).text_color(t.muted).child("Loading comments…");
      if (all.error) return div().p(14).text_size(12).text_color(t.blocked).child(all.error);
      const people = all.filter((x) => !x.bot), bots = all.filter((x) => x.bot), shown = this.showBots ? all : people;
      const verdict = { APPROVED: ["approved", t.ansi2], CHANGES_REQUESTED: ["changes requested", t.ansi1], DISMISSED: ["dismissed", t.muted] };
      return v_flex().gap(8)
        .when(!people.length && !this.showBots, (el) => el.child(div().p(14).text_size(12).text_color(t.muted).child("No comment from people yet.")))
        .children(shown.map((x, i) => this.appear(`cv-${pr.number}-${x.at}-${i}`, v_flex().id(`cv-${i}`).p(12).gap(6).rounded(10)
          .bg(x.bot ? t.chrome : t.surface).border_1().border_color(x.who === pr.author?.login ? t.input : t.border)
          .child(h_flex().gap(8).items_center()
            .child(div().text_size(11.5).font_semibold().text_color(x.bot ? t.muted : t.foreground).child(`@${x.who}`))
            .when(x.who === pr.author?.login, (el) => el.child(this.chip(t, "author", t.muted)))
            .when(Boolean(verdict[x.state]), (el) => el.child(this.chip(t, verdict[x.state][0], verdict[x.state][1])))
            .child(div().flex_1())
            .child(div().text_size(10.5).text_color(t.dim).child(x.at ? `${ago(x.at)} ago` : ""))
            .child(this.ghost(t, `cvo-${i}`, "↗", () => exec("open", [x.url]))))
          .when(Boolean(x.body.trim()), (el) => el.child(x.bot
            ? div().text_size(11).line_height(1.45).whitespace_normal().text_color(t.muted).child(clip(oneLine(x.body.replace(/<[^>]+>/g, " ")), 280))
            : this.md(t, `cvb-${pr.number}-${i}`, x.body))))))
        .when(bots.length > 0, (el) => el.child(h_flex().px(4).pt(2).child(this.ghost(t, "bots", this.showBots ? `Hide ${bots.length} bot comments` : `Show ${bots.length} bot comments`,
          (_e, cx) => { this.showBots = !this.showBots; cx.notify(); this.settle(cx); }))));
    }
    if (this.tab === "threads") {
      const th = this.threads.get(pr.number);
      if (!th) return div().p(14).text_size(12).text_color(t.muted).child("Loading threads…");
      if (th.error) return div().p(14).text_size(12).text_color(t.blocked).child(th.error);
      if (!th.length) return div().p(14).text_size(12).text_color(t.muted).child("No unresolved review thread.");
      return v_flex().gap(8).children(th.map((x, i) => this.appear(`th-${pr.number}-${i}`, v_flex().id(`th-${i}`).p(12).gap(6).rounded(10).bg(t.surface).border_1().border_color(t.border)
        .cursor_pointer().hover((s) => s.border_color(t.input)).on_click(() => exec("open", [x.url]))
        .child(h_flex().gap(8).items_center()
          .child(this.chip(t, x.bot ? "bot" : `@${x.who}`, x.bot ? t.muted : t.accent))
          .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.muted).child(`${x.path.split("/").slice(-2).join("/")}${x.line ? ":" + x.line : ""}`)))
        .child(div().text_size(12).line_height(1.45).whitespace_normal().text_color(t.foreground).child(clip(oneLine(x.body), 400))))));
    }
    const raw = this.cache[`${this.out}/${key}.review.json`];
    let rv = null; try { rv = raw ? JSON.parse(raw) : null; } catch {}
    if (this.reviewing(pr)) return v_flex().p(14).gap(10).rounded(10).bg(t.surface).border_1().border_color(t.border)
      .child(h_flex().gap(8).items_center().child(this.dot(t, t.working, true)).child(div().text_size(12).text_color(t.foreground).child("The reviewer is reading the frontend diff…")))
      .child(this.button(t, "rv-open", "Open the review terminal", () => run("agent.focus", { terminal: this.reviewing(pr).address })));
    if (!rv) return v_flex().p(14).gap(8).items_start().child(div().text_size(12).text_color(t.muted).child(this.mode === "mine" ? "No self-review for this commit yet. It reads your frontend diff like a reviewer would, nothing gets posted." : "No review draft for this commit yet."))
      .child(this.button(t, "rv-go", this.mode === "mine" ? "Self-review" : "Review frontend", () => this.startReview(pr), "primary"));
    if (rv.status === "error") return v_flex().p(14).gap(8).child(div().text_size(12).text_color(t.blocked).child(rv.error ?? "The review failed."))
      .child(this.button(t, "rv-retry", "Try again", () => this.startReview(pr)));
    const color = { blocker: t.ansi1, suggestion: t.accent, question: t.ansi3, nit: t.muted };
    const all = rv.comments.map((c) => `${c.path}:${c.line}\n${this.text0(c)}`).join("\n\n");
    return v_flex().gap(8)
      .child(this.appear(`sum-${key}`, v_flex().p(12).gap(8).rounded(10).bg(t.surface).border_1().border_color(t.input)
        .child(div().text_size(12).line_height(1.5).whitespace_normal().text_color(t.foreground).child(rv.summary))
        .child(h_flex().gap(6)
          .child(this.button(t, "rv-copy-all", this.copied === "all" ? "Copied ✓" : "Copy all", (_e, cx) => this.copy(all, "all", cx)))
          .child(this.button(t, "rv-md", "Open as page", () => run("pane.split", { direction: "right", mod: "acc-md", props: { file: `${this.out}/${key}.review.md` } })))
          .child(div().flex_1())
          .child(this.ghost(t, "rv-rerun", "Re-run", () => this.startReview(pr))))))
      .children(rv.comments.map((c, i) => this.commentCard(t, pr, key, rv, c, i, color)))
      .when(Boolean(rv.checked?.length), (el) => el.child(v_flex().px(4).pt(4).gap(3)
        .child(div().text_size(10).font_semibold().text_color(t.dim).child("WHAT IT CHECKED"))
        .children(rv.checked.map((x, i) => div().id(`chk-${i}`).text_size(11).line_height(1.45).whitespace_normal().text_color(t.muted).child(`· ${x}`)))));
  }

  reviewFile(key) { return `${this.out}/${key}.review.json`; }
  text0(c) { return c.edited ?? `${c.label}: ${c.body}`; }

  startEdit(key, c, i, cx) {
    const st = TextareaState.new({ value: this.text0(c), rows: 5 });
    st.set_auto_grow(3, 14);
    this.edits[`${key}-${i}`] = st; cx.notify();
    cx.timer.after(60, () => st.focus());
  }

  async patchComment(key, i, patch, cx) {
    const file = this.reviewFile(key), raw = await readTextFile(file);
    const data = JSON.parse(raw);
    Object.assign(data.comments[i], patch);
    await writeTextFile(file, JSON.stringify(data, null, 2), raw);
    this.cache[file] = JSON.stringify(data); cx.notify();
  }

  saveEdit(key, c, i, cx) {
    const st = this.edits[`${key}-${i}`], value = st.value().trim();
    cx.spawn(async (cx) => {
      try { await this.patchComment(key, i, { edited: value && value !== `${c.label}: ${c.body}` ? value : undefined }, cx); delete this.edits[`${key}-${i}`]; }
      catch (e) { notify({ title: "Could not save the comment", body: String(e.message ?? e).slice(0, 200), level: "error" }); }
      cx.notify();
    });
  }

  post(key, i, cx) {
    const k = `${key}-${i}`;
    if (this.posting.has(k)) return;
    this.posting.add(k); cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("python3", [`${this.dir}/review.py`, "post", this.reviewFile(key), String(i)], { cwd: this.dir, timeout: 60000 });
        if (r.code !== 0) throw new Error((r.stderr || r.stdout).trim().split("\n").pop().slice(0, 220));
        delete this.cache[this.reviewFile(key)]; await this.text(this.reviewFile(key));
        notify({ title: "Added to your pending review", body: "Submit it on GitHub when you are done.", level: "success", timeout: 3000 });
      } catch (e) { notify({ title: "Post failed", body: String(e.message ?? e), level: "error" }); }
      this.posting.delete(k); cx.notify();
    });
  }

  commentCard(t, pr, key, rv, c, i, color) {
    const k = `${key}-${i}`, editing = this.edits[k], posted = c.posted, busy = this.posting.has(k);
    return this.appear(`c-${k}`, v_flex().id(`cm-${i}`).p(12).gap(8).rounded(10).bg(t.surface).border_1().border_color(editing ? t.accent : t.border)
      .transition("opacity", 200).opacity(posted ? .72 : 1)
      .child(h_flex().gap(8).items_center()
        .child(this.chip(t, c.label, color[c.label] ?? t.muted))
        .child(div().flex_1().min_w(0).truncate().text_size(11).text_color(t.muted).child(`${c.path.split("/").length > 2 ? "…/" : ""}${c.path.split("/").slice(-2).join("/")}:${c.line}`))
        .when(Boolean(c.edited) && !editing, (el) => el.child(div().text_size(10.5).text_color(t.dim).child("edited"))))
      .child(editing
        ? div().id(`ed-${i}`).w_full().px(10).py(8).rounded(8).border_1().border_color(t.input).bg(t.background).cursor_text()
          .on_mouse_down("left", (_e, cx) => cx.stop_propagation()).child(Textarea.new(editing).text_size(12.5).text_color(t.foreground))
        : this.md(t, `cb-${k}`, c.edited ?? c.body))
      .child(h_flex().gap(6).items_center()
        .when(Boolean(editing), (el) => el
          .child(this.button(t, `sv-${i}`, "Save", (_e, cx) => this.saveEdit(key, c, i, cx), "primary"))
          .child(this.ghost(t, `cn-${i}`, "Cancel", (_e, cx) => { delete this.edits[k]; cx.notify(); })))
        .when(!editing && !posted && this.mode === "review", (el) => el
          .child(this.button(t, `po-${i}`, busy ? "Posting…" : "Post", (_e, cx) => this.post(key, i, cx), "primary"))
          .child(this.button(t, `eb-${i}`, "Edit", (_e, cx) => this.startEdit(key, c, i, cx))))
        .when(Boolean(posted), (el) => el.child(this.chip(t, "✓ in your pending review", t.ansi2))
          .child(this.ghost(t, `gh-${i}`, "Submit on GitHub ↗", () => exec("open", [`${pr.url}/files`]))))
        .child(div().flex_1())
        .child(this.ghost(t, `cp-${i}`, this.copied === k ? "Copied ✓" : "Copy", (_e, cx) => this.copy(this.text0(c), k, cx)))));
  }

  actions(t, pr) {
    const rv = this.files.review[this.id(pr)], tm = this.reviewing(pr), b = this.busy;
    const review = tm ? this.button(t, "rv-watch", "Reviewing…", () => run("agent.focus", { terminal: tm.address }))
      : this.button(t, "rv", this.mode === "mine" ? (rv?.status === "ok" ? "Self-review again" : "Self-review") : (rv?.status === "ok" ? "Review again" : "Review frontend"), () => this.startReview(pr));
    if (this.mode === "review") return h_flex().gap(6).flex_wrap().child(this.button(t, "diff", "View diff", () => this.diff(pr), "primary")).child(review);
    const th = this.threads.get(pr.number), problems = (pr.mergeable === "CONFLICTING" ? 1 : 0) + checks(pr).fail.length + (Array.isArray(th) ? th.length : 0);
    return v_flex().gap(6)
      .child(h_flex().gap(6).flex_wrap()
        .child(this.button(t, "wt", b === `wt-${pr.number}` ? "Opening…" : "Open worktree", (_e, cx) => this.openWorktree(pr, cx), "primary"))
        .child(this.button(t, "co", b === `co-${pr.number}` ? "Checking out…" : "Checkout here", (_e, cx) => this.checkoutHere(pr, cx)))
        .child(this.button(t, "diff", "View diff", () => this.diff(pr))))
      .child(h_flex().gap(6).flex_wrap()
        .when(pr.isDraft, (el) => el.child(div().id("ready").h(26).px(11).flex().items_center().rounded(7).flex_none().text_size(11.5).font_semibold()
          .bg(this.armed === `rd-${pr.number}` ? t.ansi3 : t.accent).text_color(t.accent_foreground).hover((s) => s.opacity(.9))
          .transition("opacity", 160).on_click((_e, cx) => this.toggleDraft(pr, cx))
          .child(b === `rd-${pr.number}` ? "Marking ready…" : this.armed === `rd-${pr.number}` ? "Confirm: notify reviewers" : "Ready for review")))
        .child(review)
        .when(problems > 0, (el) => el.child(this.button(t, "fix", `Fix ${problems} issue${problems > 1 ? "s" : ""}`, (_e, cx) => this.fix(pr, cx))))
        .when(this.ready(pr), (el) => el.child(div().id("merge").h(26).px(11).flex().items_center().rounded(7).flex_none().text_size(11.5).font_semibold()
          .bg(this.armed === pr.number ? t.ansi1 : t.ansi2).text_color("#ffffff").hover((s) => s.opacity(.9))
          .on_click((_e, cx) => this.mergePr(pr, cx)).child(b === `mg-${pr.number}` ? "Merging…" : this.armed === pr.number ? "Confirm merge" : "Merge")))
        .when(!pr.isDraft, (el) => el.child(this.ghost(t, "undraft", b === `rd-${pr.number}` ? "Moving…" : this.armed === `rd-${pr.number}` ? "Confirm back to draft" : "Back to draft", (_e, cx) => this.toggleDraft(pr, cx)))));
  }

  stackTrail(t, pr) {
    const g = this.stackOf(pr);
    if (g.length < 2) return null;
    return h_flex().gap(4).items_center().flex_wrap()
      .child(div().text_size(10.5).font_semibold().text_color(t.dim).child(`STACK on ${g[0].baseRefName}`))
      .children(g.flatMap((p, i) => [
        ...(i ? [div().text_size(11).text_color(t.dim).child("›")] : []),
        div().id(`trail-${p.number}`).px(7).h(20).flex().items_center().rounded(10).text_size(11).font_semibold()
          .bg(p.number === pr.number ? t.selected : t.raised).text_color(p.number === pr.number ? t.foreground : t.muted)
          .border_1().border_color(p.number === pr.number ? t.accent : t.raised).hover((s) => s.text_color(t.foreground))
          .on_click((_e, cx) => this.select(p, cx)).child(`#${p.number}`),
      ]));
  }

  detailView(t, pr) {
    const rv = this.files.review[this.id(pr)], tabs = TABS[this.mode], seg = Math.max(64, Math.floor((this.width - 30) / tabs.length)), trail = this.stackTrail(t, pr);
    const idx = Math.max(0, tabs.findIndex(([k]) => k === this.tab)), th = this.threads.get(pr.number);
    const cv = this.convo.get(pr.number), humans = Array.isArray(cv) ? cv.filter((x) => !x.bot).length : 0;
    const label = (k, l) => (k === "comments" && rv?.status === "ok" ? `${l} ${rv.n}` : k === "threads" && Array.isArray(th) && th.length ? `${l} ${th.length}` : k === "convo" && humans ? `${l} ${humans}` : l);
    return [
      v_flex().px(12).pt(10).gap(10)
        .child(h_flex().gap(8).items_center()
          .child(this.ghost(t, "back", this.mode === "mine" ? "← My PRs" : "← All PRs", (_e, cx) => { this.open = null; cx.notify(); this.settle(cx); }))
          .child(div().flex_1())
          .child(this.ghost(t, "gh", "GitHub ↗", () => exec("open", [pr.url]))))
        .child(this.appear(`hd-${pr.number}`, v_flex().gap(6)
          .child(div().text_size(15).font_semibold().line_height(1.35).whitespace_normal().text_color(t.foreground).child(pr.title))
          .child(h_flex().gap(8).items_center()
            .child(div().flex_1().min_w(0).truncate().text_size(11.5).text_color(t.muted).child(this.mode === "mine" ? `#${pr.number} · ${pr.headRefName} → ${pr.baseRefName}` : `#${pr.number} by @${pr.author.login} · opened ${ago(pr.createdAt)} ago`))
            .child(this.sizeLine(t, pr, 60))
            .child(div().text_size(11.5).text_color(t.muted).child(`${pr.changedFiles} files`)))
          .child(h_flex().gap(6).flex_wrap().children(this.stateChips(t, pr)))))
        .when(Boolean(trail), (el) => el.child(trail))
        .child(this.actions(t, pr))
        .child(div().id("seg").relative().w(seg * tabs.length + 6).h(30).p(3).rounded(9).bg(t.surface).border_1().border_color(t.border)
          .child(div().id("seg-ind").absolute().top(2).left(2 + idx * seg).w(seg).h(24).rounded(7).bg(t.raised).border_1().border_color(t.input).spring("left", { response: 300, damping: .78 }))
          .child(h_flex().relative().size_full().children(tabs.map(([k, l]) => h_flex().id(`tab-${k}`).w(seg).h_full().items_center().justify_center()
            .text_size(seg < 84 ? 10.5 : 11.5).font_semibold().text_color(this.tab === k ? t.foreground : t.muted).hover((s) => s.text_color(t.foreground))
            .on_click((_e, cx) => { this.tab = k; cx.notify(); this.settle(cx); }).child(label(k, l)))))),
      v_flex().px(10).pt(10).pb(12).child(this.tabBody(t, pr)),
    ];
  }

  render() {
    const t = theme(), pr = this.prs.find((p) => p.number === this.open);
    const act = this.active().length;
    const zoom = Number(settings().zoom ?? 1) || 1;
    return v_flex().id("rv-root").size_full().bg(t.chrome).on_size_change((sz) => { this.width = sz.width / zoom; })
      .child(h_flex().h(44).px(14).gap(8).items_center().border_b(1).border_color(t.border).flex_none()
        .child(div().text_size(13).font_semibold().text_color(t.foreground).child(this.mode === "mine" ? "My PRs" : "Review"))
        .child(div().px(7).h(18).flex().items_center().rounded(9).text_size(10.5).font_semibold().bg(act ? t.accent : t.raised).text_color(act ? t.accent_foreground : t.muted).child(String(act)))
        .child(div().flex_1())
        .child(this.ghost(t, "refresh", "↻", (_e, cx) => { this.next = 0; this.tick(cx); })))
      .child(v_flex().id(`rv-scroll-${pr ? pr.number : "list"}`).flex_1().min_h(0).overflow_y_scrollbar().pt(pr ? 0 : 10)
        .children(pr ? this.detailView(t, pr) : this.listView(t)));
  }
}
