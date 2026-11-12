import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { exec, theme, layout, notify, spaces, panes, focused, run, home } from "herdr";

const PR = `number title url isDraft reviewDecision mergeStateStatus headRefName
  repository { nameWithOwner viewerPermission squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed }
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`;
const query = (repo) => {
  const scope = repo ? ` repo:${repo}` : "";
  return `query { mine: search(query: "is:pr is:open author:@me archived:false sort:updated-desc${scope}", type: ISSUE, first: 25) { nodes { ... on PullRequest { ${PR} } } }
  review: search(query: "is:pr is:open review-requested:@me archived:false sort:updated-desc${scope}", type: ISSUE, first: 15) { nodes { ... on PullRequest { ${PR} } } } }`;
};
const DETAIL = `query($url: URI!) { resource(url: $url) { ... on PullRequest {
  baseRefName headRefName mergeStateStatus
  commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
    __typename ... on CheckRun { name conclusion status detailsUrl } ... on StatusContext { context state targetUrl } } } } } } }
  reviewThreads(first: 60) { nodes { isResolved isOutdated path line comments(first: 1) { nodes { author { login } body url } } } }
} } }`;
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const WRITE = new Set(["WRITE", "MAINTAIN", "ADMIN"]);
const BAD = new Set(["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]);
const slug = (b) => b.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
const oneLine = (s) => s.replace(/\s+/g, " ").trim();

function shape(n) {
  const ci = n.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? "NONE";
  const linear = /\b([a-z]{2,6})-(\d+)\b/i.exec(n.headRefName ?? "") ?? /\b([A-Z]{2,6})-(\d+)\b/.exec(n.title ?? "");
  const r = n.repository, state = n.mergeStateStatus;
  const blocked = n.isDraft ? "draft" : state === "DIRTY" ? "conflicts" : state === "BEHIND" ? "behind" : state === "UNSTABLE" ? "checks failing" : state === "BLOCKED" ? "blocked" : state === "UNKNOWN" ? "computing" : null;
  const method = r.squashMergeAllowed ? "--squash" : r.mergeCommitAllowed ? "--merge" : r.rebaseMergeAllowed ? "--rebase" : null;
  return {
    id: n.url, number: n.number, title: n.title, url: n.url, draft: n.isDraft, ci, review: n.reviewDecision, branch: n.headRefName,
    full: r.nameWithOwner, repo: r.nameWithOwner.split("/")[1], linear: linear ? `${linear[1].toUpperCase()}-${linear[2]}` : null,
    blocked, ready: !blocked && state === "CLEAN" && WRITE.has(r.viewerPermission) && Boolean(method), method,
  };
}

function shapeDetail(d) {
  const ctx = d.commits?.nodes?.[0]?.commit?.statusCheckRollup?.contexts?.nodes ?? [];
  const failing = ctx.filter((c) => (c.__typename === "CheckRun" ? BAD.has(c.conclusion) : BAD.has(c.state)))
    .map((c) => ({ name: c.name ?? c.context, url: c.detailsUrl ?? c.targetUrl }));
  const threads = (d.reviewThreads?.nodes ?? []).filter((t) => !t.isResolved && !t.isOutdated && t.comments?.nodes?.[0])
    .map((t) => {
      const c = t.comments.nodes[0], who = c.author?.login ?? "unknown";
      return { path: t.path, line: t.line, who, bot: /greptile/i.test(who), body: c.body ?? "", url: c.url };
    });
  const state = d.mergeStateStatus;
  return { base: d.baseRefName, conflicts: state === "DIRTY", behind: state === "BEHIND", failing, threads, at: Date.now() };
}

function prompt(p, d) {
  const todo = [];
  if (d.conflicts) todo.push(`1. Conflicts: the branch conflicts with ${d.base}. Merge origin/${d.base} into it (merge, not rebase) and resolve every conflict, keeping the intent of both sides.`);
  if (d.failing.length) todo.push(`${todo.length + 1}. Red CI: failing checks are ${d.failing.map((f) => `"${f.name}"`).join(", ")}. Find the cause with \`gh pr checks ${p.number}\` and \`gh run view <run-id> --log-failed\`, reproduce locally where possible, and fix the code (or the test if the test is wrong).`);
  if (d.threads.length) todo.push(`${todo.length + 1}. Review comments: address each unresolved thread below. If a comment is wrong or not worth acting on, say why in your summary instead of changing code.\n${d.threads.slice(0, 12).map((t, i) => `   ${i + 1}) [${t.who}] ${t.path}${t.line ? ":" + t.line : ""} — ${clip(oneLine(t.body), 600)}`).join("\n")}`);
  return [
    `Fix pull request #${p.number} "${p.title}" (${p.full}, branch ${p.branch}). You are in a git worktree of that branch.`,
    "", "What to do:", ...todo, "",
    "Rules: follow this repository's own instructions (AGENTS.md / CLAUDE.md). Stay on this branch. Commit your work locally in small commits.",
    "Do NOT push, force-push, resolve review threads, or merge: stop after committing and give me a short summary of what you changed, what you chose not to change and why, and anything still failing.",
  ].join("\n");
}

function where() {
  const space = spaces().find((x) => x.active), f = focused();
  const pane = f?.pane ? panes().find((x) => x.pane === f.pane) : null;
  return { cwd: pane?.cwd || f?.cwd || space?.folder || null, machine: space?.machine ?? null };
}
const parseRemote = (u) => /github\.com[:/]([^/\s]+\/[^/\s]+?)(?:\.git)?\s*$/.exec(u.trim())?.[1] ?? null;

export default class Prs extends View {
  init(_props, cx) {
    this.mine = []; this.review = []; this.error = null; this.loading = false;
    this.armed = null; this.merging = null; this.loaded = false;
    this.open = null; this.details = new Map(); this.fixing = null;
    this.scope = "repo"; this.cwd = undefined; this.repo = null; this.fetched = null;
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

  visible() { const n = find(layout(), "prs"); return Boolean(n) && !n.hidden; }

  tick(cx) {
    if (!this.visible()) { this.shown = false; return; }
    const t = Date.now();
    if (this.armed && t > this.armed.until) { this.armed = null; cx.notify(); }
    if (!this.shown) { this.shown = true; this.next = 0; this.cwd = undefined; }
    const w = where();
    if (w.cwd !== this.cwd) { this.cwd = w.cwd; this.detect(w, cx); }
    if (t >= (this.next ?? 0)) { this.next = t + 60000; this.refresh(cx); }
  }

  detect(w, cx) {
    if (!w.cwd || w.machine) { this.setRepo(null, cx); return; }
    cx.spawn(async (cx) => {
      let repo = null;
      try {
        const r = await exec("git", ["-C", w.cwd, "remote", "get-url", "origin"], { timeout: 8000 });
        if (r.code === 0) repo = parseRemote(r.stdout);
      } catch {}
      if (w.cwd === this.cwd) this.setRepo(repo, cx);
    });
  }

  setRepo(repo, cx) {
    if (repo === this.repo) return;
    this.repo = repo; this.open = null; this.mine = []; this.review = []; this.loaded = false;
    this.next = 0; cx.notify();
  }

  active() { return this.scope === "repo" ? this.repo : null; }

  refresh(cx) {
    if (this.loading) return;
    this.loading = true; cx.notify();
    const key = this.active() ?? "";
    cx.spawn(async (cx) => {
      try {
        const r = await exec("gh", ["api", "graphql", "-f", `query=${query(key || null)}`], { timeout: 45000 });
        if (r.code !== 0) throw new Error(r.stderr.trim().split("\n")[0] || `gh exit ${r.code}`);
        if (key !== (this.active() ?? "")) { this.loading = false; this.next = 0; cx.notify(); return; }
        const d = JSON.parse(r.stdout).data;
        this.mine = d.mine.nodes.filter((n) => n?.url).map(shape);
        const mine = new Set(this.mine.map((p) => p.id));
        this.review = d.review.nodes.filter((n) => n?.url).map(shape).filter((p) => !mine.has(p.id));
        this.error = null; this.loaded = true;
        if (this.open) this.loadDetail(this.all().find((p) => p.id === this.open), cx, true);
      } catch (e) {
        this.error = String(e.message ?? e).slice(0, 120);
      }
      this.loading = false; cx.notify();
    });
  }

  all() { return [...this.mine, ...this.review]; }

  toggle(p, cx) {
    this.open = this.open === p.id ? null : p.id;
    if (this.open) this.loadDetail(p, cx, false);
    cx.notify();
  }

  loadDetail(p, cx, force) {
    if (!p) return;
    const have = this.details.get(p.id);
    if (have?.loading || (!force && have?.at && Date.now() - have.at < 60000)) return;
    this.details.set(p.id, { ...(have ?? {}), loading: true });
    cx.spawn(async (cx) => {
      try {
        const r = await exec("gh", ["api", "graphql", "-f", `query=${DETAIL}`, "-f", `url=${p.url}`], { timeout: 45000 });
        if (r.code !== 0) throw new Error(r.stderr.trim().split("\n")[0] || `gh exit ${r.code}`);
        this.details.set(p.id, shapeDetail(JSON.parse(r.stdout).data.resource));
      } catch (e) {
        this.details.set(p.id, { error: String(e.message ?? e).slice(0, 120), at: Date.now() });
      }
      cx.notify();
    });
  }

  merge(p, cx) {
    if (this.armed?.id !== p.id) { this.armed = { id: p.id, until: Date.now() + 6000 }; cx.notify(); return; }
    this.armed = null; this.merging = p.id; cx.notify();
    cx.spawn(async (cx) => {
      try {
        const r = await exec("gh", ["pr", "merge", p.url, p.method], { timeout: 60000 });
        if (r.code === 0) notify({ title: `Merged #${p.number}`, body: p.title, level: "success", timeout: 4000 });
        else notify({ title: `Merge #${p.number} failed`, body: (r.stderr || r.stdout).trim().slice(0, 300), level: "error" });
      } catch (e) {
        notify({ title: `Merge #${p.number} failed`, body: String(e), level: "error" });
      }
      this.merging = null; this.next = 0; cx.notify();
    });
  }

  async localRepo(p) {
    const cands = [...new Set([...spaces().map((s) => s.folder).filter(Boolean), `${home()}/Documents/livestorm/${p.repo}`, `${home()}/Documents/${p.repo}`, `${home()}/${p.repo}`])];
    for (const dir of cands) {
      try {
        const r = await exec("git", ["-C", dir, "remote", "get-url", "origin"], { timeout: 8000 });
        if (r.code === 0 && r.stdout.trim().replace(/\.git$/, "").endsWith(p.full)) return dir;
      } catch {}
    }
    return null;
  }

  fix(p, cx) {
    const d = this.details.get(p.id);
    if (!d || d.error || this.fixing) return;
    this.fixing = p.id; cx.notify();
    cx.spawn(async (cx) => {
      const fail = (body) => notify({ title: `Cannot prepare #${p.number}`, body, level: "error" });
      try {
        const repo = await this.localRepo(p);
        if (!repo) { fail(`No local checkout of ${p.full} found. Open it as a space first.`); return; }
        const git = (args, timeout = 120000) => exec("git", ["-C", repo, ...args], { timeout });
        const f = await git(["fetch", "origin", p.branch]);
        if (f.code !== 0) { fail(f.stderr.trim().slice(0, 300)); return; }
        const list = await git(["worktree", "list", "--porcelain"]);
        let path = null, cur = null;
        for (const l of list.stdout.split("\n")) {
          if (l.startsWith("worktree ")) cur = l.slice(9);
          else if (l === `branch refs/heads/${p.branch}`) path = cur;
        }
        const reused = Boolean(path);
        if (!path) {
          path = `${home()}/.herdr/worktrees/${p.repo}/${slug(p.branch)}`;
          const local = (await git(["show-ref", "--verify", "--quiet", `refs/heads/${p.branch}`])).code === 0;
          const add = await git(local ? ["worktree", "add", path, p.branch] : ["worktree", "add", "-b", p.branch, path, `origin/${p.branch}`]);
          if (add.code !== 0) { fail(add.stderr.trim().slice(0, 300)); return; }
        }
        const known = spaces().find((s) => s.folder === path && !s.machine);
        if (known) run("tab.new", { space: known.id, name: `fix #${p.number}`, folder: path, argv: ["omp"], task: prompt(p, d) });
        else run("space.new", { name: `fix #${p.number}`, folder: path, argv: ["omp"], task: prompt(p, d) });
        notify({ title: `Fix started on #${p.number}`, body: `${path.replace(home(), "~")}${reused ? " (existing worktree)" : ""}`, level: "success", timeout: 4000 });
      } catch (e) {
        fail(String(e).slice(0, 300));
      } finally {
        this.fixing = null; cx.notify();
      }
    });
  }

  chip(t, text, color) {
    return div().px(6).h(16).flex().items_center().rounded(5).text_size(10.5).font_semibold().text_color(color).bg(t.raised).flex_none().child(text);
  }

  button(t, id, label, onClick, { primary, danger, disabled } = {}) {
    return div().id(id).h(22).px(9).flex().items_center().rounded(6).flex_none().text_size(11).font_semibold()
      .bg(danger ? t.ansi1 : primary ? t.solid : t.raised).text_color(danger ? "#ffffff" : primary ? t.solid_foreground : t.foreground)
      .when(Boolean(disabled), (el) => el.opacity(.45)).when(!disabled, (el) => el.hover((s) => s.opacity(.85)).on_click(onClick)).child(label);
  }

  detail(t, p) {
    const d = this.details.get(p.id), line = (text, color, id, url) => div().id(id).text_size(11).text_color(color ?? t.muted).truncate()
      .when(Boolean(url), (el) => el.on_click(() => exec("open", [url])).hover((s) => s.text_color(t.foreground))).child(text);
    if (!d || d.loading && !d.at) return v_flex().px(2).pt(4).child(line("loading details…", t.muted, `d-${p.id}`));
    if (d.error) return v_flex().px(2).pt(4).child(line(d.error, t.blocked, `d-${p.id}`));
    const bots = d.threads.filter((x) => x.bot).length, people = d.threads.length - bots;
    const problems = (d.conflicts ? 1 : 0) + d.failing.length + d.threads.length, busy = this.fixing === p.id;
    return v_flex().gap(3).pt(4).pb(2)
      .child(line(d.conflicts ? `Conflicts with ${d.base}` : d.behind ? `Behind ${d.base}` : `Up to date with ${d.base}`, d.conflicts ? t.ansi1 : d.behind ? t.ansi3 : t.ansi2, `c-${p.id}`))
      .child(line(d.failing.length ? `Failing checks (${d.failing.length})` : "No failing checks", d.failing.length ? t.ansi1 : t.ansi2, `f-${p.id}`))
      .children(d.failing.slice(0, 6).map((f, i) => line(`   ✕ ${f.name}`, t.muted, `fc-${p.id}-${i}`, f.url)))
      .child(line(d.threads.length ? `Unresolved threads (${d.threads.length}): ${bots} greptile, ${people} human` : "No unresolved threads", d.threads.length ? t.ansi3 : t.ansi2, `t-${p.id}`))
      .children(d.threads.slice(0, 5).map((x, i) => line(`   ${x.bot ? "●" : "○"} ${x.path.split("/").pop()}${x.line ? ":" + x.line : ""}  ${clip(oneLine(x.body), 70)}`, t.muted, `tc-${p.id}-${i}`, x.url)))
      .child(h_flex().gap(6).pt(4)
        .child(this.button(t, `fix-${p.id}`, busy ? "preparing…" : problems ? `Fix (${problems})` : "Nothing to fix", (_e, cx) => this.fix(p, cx), { primary: true, disabled: busy || !problems }))
        .child(this.button(t, `ext-${p.id}`, "Open on GitHub", () => exec("open", [p.url]))));
  }

  row(t, p) {
    const ciColor = p.ci === "SUCCESS" ? t.ansi2 : p.ci === "FAILURE" || p.ci === "ERROR" ? t.ansi1 : p.ci === "PENDING" || p.ci === "EXPECTED" ? t.ansi3 : t.dim;
    const ciText = p.ci === "SUCCESS" ? "CI ✓" : p.ci === "FAILURE" || p.ci === "ERROR" ? "CI ✕" : p.ci === "PENDING" || p.ci === "EXPECTED" ? "CI …" : "CI –";
    const rv = p.review === "APPROVED" ? ["approved", t.ansi2] : p.review === "CHANGES_REQUESTED" ? ["changes", t.ansi1] : p.review === "REVIEW_REQUIRED" ? ["review", t.ansi3] : null;
    const armed = this.armed?.id === p.id, busy = this.merging === p.id, open = this.open === p.id;
    return v_flex().id(`pr-${p.id}`).gap(4).px(10).py(8).border_b(1).border_color(t.border).when(open, (el) => el.bg(t.surface))
      .child(h_flex().gap(8).items_center()
        .child(div().id(`t-${p.id}`).flex_1().min_w(0).truncate().text_size(12.5).text_color(t.foreground).hover((s) => s.text_color(t.accent))
          .on_click((_e, cx) => this.toggle(p, cx)).child(`${open ? "▾" : "▸"} #${p.number}  ${p.title}`))
        .when(p.ready || busy, (el) => el.child(this.button(t, `m-${p.id}`, busy ? "merging…" : armed ? "Confirm merge" : "Merge", (_e, cx) => { if (!busy) this.merge(p, cx); }, { primary: !armed, danger: armed }))))
      .child(h_flex().gap(5).items_center().flex_wrap()
        .child(div().text_size(11).text_color(t.muted).child(p.repo))
        .when(Boolean(p.linear), (el) => el.child(div().id(`l-${p.id}`).px(6).h(16).flex().items_center().rounded(5).text_size(10.5).font_semibold().text_color(t.accent).bg(t.raised)
          .on_click(() => exec("open", [`https://linear.app/issue/${p.linear}`])).child(p.linear)))
        .when(p.draft, (el) => el.child(this.chip(t, "draft", t.muted)))
        .child(this.chip(t, ciText, ciColor))
        .when(Boolean(rv), (el) => el.child(this.chip(t, rv[0], rv[1])))
        .when(Boolean(p.blocked) && !p.draft, (el) => el.child(this.chip(t, p.blocked, t.ansi3)))
        .when(p.ready, (el) => el.child(this.chip(t, "ready", t.ansi2))))
      .when(open, (el) => el.child(this.detail(t, p)));
  }

  section(t, title, list) {
    return v_flex().child(h_flex().px(10).h(26).items_center().text_size(10).font_semibold().text_color(t.dim).child(`${title.toUpperCase()}  ${list.length}`))
      .children(list.length ? list.map((p) => this.row(t, p)) : [div().px(10).py(6).text_size(11).text_color(t.muted).child(this.active() ? `None in ${this.active()}` : "None")]);
  }

  render() {
    const t = theme();
    return v_flex().size_full().bg(t.chrome)
      .child(h_flex().h(36).px(10).items_center().justify_between()
        .child(h_flex().gap(8).items_center()
          .child(div().text_size(12).font_semibold().text_color(t.foreground).child("Pull requests"))
          .when(Boolean(this.repo), (el) => el.child(div().id("pr-scope").px(7).h(18).flex().items_center().rounded(5).text_size(10.5).font_semibold()
            .bg(this.scope === "repo" ? t.selected : t.raised).text_color(this.scope === "repo" ? t.foreground : t.muted).hover((s) => s.opacity(.85))
            .on_click((_e, cx) => { this.scope = this.scope === "repo" ? "all" : "repo"; this.open = null; this.mine = []; this.review = []; this.loaded = false; this.next = 0; cx.notify(); })
            .child(this.scope === "repo" ? this.repo.split("/")[1] : "all repos"))))
        .child(div().id("pr-refresh").px(6).h(22).flex().items_center().rounded(5).text_size(11).text_color(t.muted).hover((s) => s.bg(t.hover))
          .on_click((_e, cx) => this.refresh(cx)).child(this.loading ? "refreshing…" : "↻ refresh")))
      .when(Boolean(this.error), (el) => el.child(div().px(10).pb(6).text_size(11).text_color(t.blocked).child(this.error)))
      .child(v_flex().id("pr-scroll").flex_1().overflow_y_scrollbar()
        .when(!this.loaded && !this.error, (el) => el.child(div().px(10).py(8).text_size(11).text_color(t.muted).child("Loading…")))
        .when(this.loaded, (el) => el.child(this.section(t, "My pull requests", this.mine)).child(this.section(t, "To review", this.review))));
  }
}
