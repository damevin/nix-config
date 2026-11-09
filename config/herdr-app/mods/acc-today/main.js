import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex, InputState, Input } from "gpui-base";
import { exec, theme, layout, notify, readTextFile, writeTextFile, home, appHome, props, spaces, panes, focused, agents, terminals, run, openOverlay, closeOverlay } from "herdr";


const VAULT = "~/Documents/observatory";
const DAILY = "12. journal/daily";
const WEEKLY = "12. journal/weekly";
const DAILY_TPL = "06. templates/Daily note.md";
const WEEKLY_TPL = "06. templates/Weekly note.md";
const VAULT_NAME = "observatory";
const TASK = /^(\s*)- \[( |x|X)\] ?(.*)$/;
const HEAD = /^#{1,6}\s+(.*?)\s*$/;
const META = /\s*(?:[📅⏳🛫➕✅]\s*\d{4}-\d{2}-\d{2}|🔁\s*[^📅✅⏳🛫➕⏫🔼🔽]*|[⏫🔼🔽])/gu;
const find = (n, id) => (n?.id === id ? n : (n?.children ?? []).map((c) => find(c, id)).find(Boolean) ?? null);
const p2 = (n) => String(n).padStart(2, "0");
const ymd = (d) => `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())}`;
const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

const MODES = {
  do: { label: "Do it", desc: "Implement it end to end", ask: "Do this end to end. Keep changes focused, run the relevant checks, and commit locally only if you changed code." },
  investigate: { label: "Investigate", desc: "Read-only, report findings", ask: "Investigate and report back. Read-only: do not edit files or run anything that changes state." },
  plan: { label: "Plan", desc: "Propose a plan, wait for my go", ask: "Do not change anything yet. Write a short plan (steps, files involved, risks, open questions) and wait for my go before editing." },
};

function where() {
  const space = spaces().find((x) => x.active), f = focused();
  const pane = f?.pane ? panes().find((x) => x.pane === f.pane) : null;
  return { folder: pane?.cwd || f?.cwd || space?.folder || null, machine: space?.machine ?? null };
}

function weekOfYear(d) {
  const sat = addDays(d, 6 - d.getDay());
  const doy = Math.round((new Date(sat.getFullYear(), sat.getMonth(), sat.getDate()) - new Date(sat.getFullYear(), 0, 1)) / 864e5) + 1;
  return Math.floor((doy - 1) / 7) + 1;
}
const weekName = (d) => `${addDays(d, 6 - d.getDay()).getFullYear()}-W${p2(weekOfYear(d))}`;
function fmt(d, pattern) {
  return pattern.replace(/\[([^\]]*)\]|gggg|YYYY|MM|DD|ww/g, (m, lit) => (lit !== undefined ? lit : m === "gggg" ? addDays(d, 6 - d.getDay()).getFullYear() : m === "YYYY" ? d.getFullYear() : m === "MM" ? p2(d.getMonth() + 1) : m === "DD" ? p2(d.getDate()) : p2(weekOfYear(d))));
}
function render(template, d) {
  const out = template.replace(/<%\s*tp\.date\.now\("([^"]+)"(?:\s*,\s*(-?\d+))?\)\s*%>/g, (_m, pat, off) => fmt(addDays(d, Number(off ?? 0)), pat));
  return /<%/.test(out) ? null : out;
}

function parse(text) {
  const lines = text.split("\n"), tasks = [];
  let section = "", fence = false, front = lines[0] === "---";
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (front) { if (i > 0 && l === "---") front = false; continue; }
    if (/^\s*```/.test(l)) { fence = !fence; continue; }
    if (fence) continue;
    const h = HEAD.exec(l);
    if (h) { section = h[1]; continue; }
    const m = TASK.exec(l);
    if (m) tasks.push({ i, raw: l, done: m[2] !== " ", text: m[3].trim(), section });
  }
  return { lines, tasks };
}
const isToday = (s) => /^today'?s tasks$/i.test(s);
const isGoals = (s) => /goals/i.test(s);

function meta(text) {
  const due = /📅\s*(\d{4}-\d{2}-\d{2})/.exec(text)?.[1] ?? null;
  const rule = /🔁\s*([^📅✅⏳🛫➕⏫🔼🔽]*)/u.exec(text)?.[1]?.trim() ?? null;
  const clean = text.replace(META, "").trim();
  return { due, clean, rule, linear: /\b(LIV-\d+)\b/i.exec(text)?.[1]?.toUpperCase() ?? null, recurring: text.includes("🔁") };
}
function rebuild(raw, title, due) {
  const m = TASK.exec(raw);
  if (!m) return null;
  let tokens = (m[3].match(META) ?? []).map((s) => s.trim());
  if (due !== undefined) {
    tokens = tokens.filter((x) => !x.startsWith("📅"));
    if (due) { const at = tokens.findIndex((x) => x.startsWith("✅")); tokens.splice(at < 0 ? tokens.length : at, 0, `📅 ${due}`); }
  }
  return `${m[1]}- [${m[2]}] ${title}${tokens.length ? " " + tokens.join(" ") : ""}`;
}

function insertAfterHeading(text, headTest, fallbackHeading, line) {
  const lines = text.split("\n");
  const idx = lines.findIndex((l) => { const h = HEAD.exec(l); return h && headTest(h[1]); });
  if (idx < 0) return text.replace(/\n*$/, "") + `\n\n${fallbackHeading}\n\n${line}\n`;
  let end = lines.length;
  for (let i = idx + 1; i < lines.length; i++) if (HEAD.exec(lines[i])) { end = i; break; }
  const range = [];
  for (let i = idx + 1; i < end; i++) { const m = TASK.exec(lines[i]); if (m) range.push([i, m]); }
  const blank = range.find(([, m]) => m[2] === " " && !m[3].trim());
  if (blank) { lines[blank[0]] = line; return lines.join("\n"); }
  if (range.length) { lines.splice(range[range.length - 1][0] + 1, 0, line); return lines.join("\n"); }
  lines.splice(idx + 1, 0, "", line);
  return lines.join("\n");
}
const withTask = (text, task) => insertAfterHeading(text, isToday, "#### Today's tasks", `- [ ] ${task}`);
const withGoal = (text, goal) => insertAfterHeading(text, isGoals, "#### Weekly focus and goals", `- [ ] ${goal}`);

function withNote(text, note) {
  const lines = text.split("\n");
  const idx = lines.findIndex((l) => /^#{1,6}\s+Notes\s*$/i.test(l));
  if (idx < 0) return text.replace(/\n*$/, "") + `\n\n##### Notes\n\n- ${note}\n`;
  let at = idx + 1;
  while (at < lines.length && (lines[at].trim() === "" ? at === idx + 1 : /^\s*[-*] /.test(lines[at]))) at++;
  lines.splice(at, 0, `- ${note}`);
  if (lines[idx + 1] !== "" && at === idx + 1) lines.splice(idx + 1, 0, "");
  return lines.join("\n");
}

function toggled(raw, today) {
  const m = TASK.exec(raw);
  if (!m) return null;
  if (m[2] === " ") return `${m[1]}- [x] ${m[3].replace(/\s+$/, "")} ✅ ${today}`;
  return `${m[1]}- [ ] ${m[3].replace(/\s*✅\s*\d{4}-\d{2}-\d{2}/g, "").replace(/\s+$/, "")}`;
}

function brief(task, path, mode, folder, d, issue) {
  const m = meta(task.text), weekly = path.includes(`/${WEEKLY}/`);
  const ticket = issue ? [`Linear ticket ${issue.identifier}: ${issue.title}`, `${issue.url} · ${issue.state}${issue.priority ? ` · ${issue.priority}` : ""}${issue.assignee ? ` · ${issue.assignee}` : ""}`,
    issue.description ? `\nTicket description:\n${clip(issue.description, 6000)}\n` : null, "Read the ticket's comments in Linear too if you can."].filter(Boolean).join("\n") : null;
  return [`${weekly ? `Weekly goal (${weekName(d)})` : `Task from my daily note (${ymd(d)})`}: ${m.clean || task.text}`,
    ticket ?? (m.linear ? `Related Linear ticket: ${m.linear} (https://linear.app/issue/${m.linear})` : null),
    m.due ? `Due: ${m.due}` : null,
    `You are working in ${folder}.`, "", MODES[mode].ask,
    "Never push, force-push or merge. When you finish, reply with a short summary of what you did and what is left."].filter((x) => x !== null).join("\n");
}

function parseNotes(text) {
  const lines = text.split("\n"), out = [];
  const idx = lines.findIndex((l) => /^#{1,6}\s+Notes\s*$/i.test(l));
  if (idx < 0) return out;
  for (let i = idx + 1; i < lines.length; i++) {
    if (HEAD.exec(lines[i]) || /^---\s*$/.test(lines[i])) break;
    const m = /^\s*[-*] (?!\[[ xX]\])(.*\S)\s*$/.exec(lines[i]);
    if (m) out.push({ i, text: m[1] });
  }
  return out;
}

const keyOf = (task) => meta(task.text).clean || task.text;
function keyed(prefix, list, of) {
  const seen = {};
  return list.map((x) => { const k = `${prefix}:${of(x)}`; seen[k] = (seen[k] ?? 0) + 1; return [`${k}#${seen[k]}`, x]; });
}

const KINDS = [
  { id: "task", label: "Task", placeholder: "Add a task for today…" },
  { id: "note", label: "Note", placeholder: "Jot something to think about…" },
  { id: "goal", label: "Goal", placeholder: "Add a goal for this week…" },
];
const SEG = 62;
const EASE = { duration: 260, easing: "ease-out" };

export default class Tasks extends View {
  init(_props, cx) {
    this.vault = (props()?.vault ?? VAULT).replace(/^~/, home());
    try { this.linear = JSON.parse(localStorage.getItem("linear") ?? "{}"); } catch { this.linear = {}; }
    this.fetching = false; this.linearRetry = 0;
    this.d = new Date(); this.text = null; this.exists = null; this.week = null; this.weekExists = null; this.prev = null;
    this.busy = false; this.error = null; this.next = 0; this.prevNext = 0;
    this.fold = { done: true, week: false, prev: false };
    this.editing = null; this.hover = null; this.starting = null;
    this.kind = localStorage.getItem("kind") ?? "task"; if (!KINDS.some((k) => k.id === this.kind)) this.kind = "task";
    this.known = null; this.entering = new Set(); this.linger = new Map();
    try { this.runs = JSON.parse(localStorage.getItem("runs") ?? "{}"); } catch { this.runs = {}; }
    this.mode = localStorage.getItem("mode") ?? "do"; if (!MODES[this.mode]) this.mode = "do";
    if (props()?.menu) return;
    this.inputs = {};
    for (const k of KINDS) {
      const s = InputState.new({ placeholder: k.placeholder });
      s.on("submit", (_e, cx) => this.add(k.id, cx));
      s.on("focus", (_e, cx) => { this.typing = true; cx.notify(); });
      s.on("blur", (_e, cx) => { this.typing = false; cx.notify(); });
      this.inputs[k.id] = s;
    }
    this.edit = InputState.new({ placeholder: "Task title" });
    this.edit.on("submit", (_e, cx) => this.saveEdit(undefined, cx));
    cx.timer.every(1000, (cx) => this.tick(cx));
  }

  visible() { const n = find(layout(), "today"); return Boolean(n) && !n.hidden; }
  dayPath(d) { return `${this.vault}/${DAILY}/${ymd(d)}.md`; }
  weekPath(d) { return `${this.vault}/${WEEKLY}/${weekName(d)}.md`; }

  tick(cx) {
    if (!this.visible()) { this.shown = false; return; }
    const t = Date.now(), now = new Date();
    if (ymd(now) !== ymd(this.d)) { this.d = now; this.text = null; this.week = null; this.known = null; this.next = 0; this.prevNext = 0; }
    if (!this.shown) { this.shown = true; this.next = 0; this.prevNext = 0; }
    if (t >= this.next && !this.busy && !this.editing) { this.next = t + 3000; this.load(cx); }
    if (t >= this.prevNext) { this.prevNext = t + 20000; this.loadPrev(cx); }
    this.syncLinear(cx);
  }

  // One secretspec + Linear call for every ticket on screen that is new or older than 15 min.
  // The first read unlocks Proton Pass (~10 s); rows show the cached ticket meanwhile.
  syncLinear(cx) {
    if (this.fetching || Date.now() < this.linearRetry) return;
    const texts = [this.text, this.week].filter(Boolean).flatMap((x) => parse(x).tasks.map((y) => y.text)).concat((this.prev?.open ?? []).map((y) => y.text));
    const ids = [...new Set(texts.map((x) => meta(x).linear).filter(Boolean))];
    const stale = ids.filter((id) => !this.linear[id] || Date.now() - this.linear[id].at > 15 * 60e3);
    if (!stale.length) return;
    this.fetching = true;
    cx.spawn(async (cx) => {
      try {
        const r = await exec("sh", [`${appHome()}/mods/acc-today/linear-issue.sh`, ...stale], { timeout: 60000 });
        const d = JSON.parse(r.stdout);
        if (!d?.data?.issues) throw new Error(d?.errors?.[0]?.message ?? (r.stderr || "no answer").trim().slice(0, 160));
        const at = Date.now();
        for (const id of stale) this.linear[id] = { missing: true, at };
        for (const i of d.data.issues.nodes) this.linear[i.identifier] = { identifier: i.identifier, title: i.title, url: i.url, description: i.description ?? "",
          state: i.state?.name ?? "", stateType: i.state?.type ?? "", priority: i.priorityLabel === "No priority" ? "" : i.priorityLabel, assignee: i.assignee?.name ?? "", at };
        localStorage.setItem("linear", JSON.stringify(this.linear));
      } catch (e) {
        this.linearRetry = Date.now() + 5 * 60e3;
        notify({ title: "Linear tickets not loaded", body: String(e.message ?? e).slice(0, 200), level: "warning", timeout: 5000 });
      }
      this.fetching = false; cx.notify();
    });
  }

  issueOf(task) { const id = meta(task.text).linear, i = id && this.linear[id]; return i && !i.missing ? i : null; }

  rowKeys(day, week) {
    const keys = new Set();
    if (day) {
      for (const [k] of keyed("t", parse(day).tasks.filter((x) => x.text), keyOf)) keys.add(k);
      for (const [k] of keyed("n", parseNotes(day), (x) => x.text)) keys.add(k);
    }
    if (week) for (const [k] of keyed("w", parse(week).tasks.filter((x) => x.text && isGoals(x.section)), keyOf)) keys.add(k);
    return keys;
  }

  // Rows that weren't there on the last read start shifted and transparent, then settle.
  arrive(keys, cx) {
    const fresh = this.known ? [...keys].filter((k) => !this.known.has(k)) : [];
    this.known = keys;
    if (!fresh.length) return;
    for (const k of fresh) this.entering.add(k);
    cx.timer.after(34, (cx) => { for (const k of fresh) this.entering.delete(k); cx.notify(); });
  }

  load(cx) {
    cx.spawn(async (cx) => {
      try {
        const [day, week] = [await readTextFile(this.dayPath(this.d)), await readTextFile(this.weekPath(this.d))];
        const changed = day !== this.text || week !== this.week;
        this.exists = day !== null; this.text = day; this.weekExists = week !== null; this.week = week; this.error = null;
        if (changed) { this.arrive(this.rowKeys(day, week), cx); cx.notify(); }
      } catch (e) { this.error = String(e.message ?? e).slice(0, 100); cx.notify(); }
    });
  }

  loadPrev(cx) {
    cx.spawn(async (cx) => {
      try {
        for (let k = 1; k <= 7; k++) {
          const d = addDays(this.d, -k), text = await readTextFile(this.dayPath(d));
          if (text !== null) { this.prev = { date: ymd(d), d, open: parse(text).tasks.filter((x) => !x.done && x.text) }; cx.notify(); return; }
        }
        this.prev = null; cx.notify();
      } catch {}
    });
  }

  async mutate(path, build, label, cx) {
    if (this.busy) return false;
    this.busy = true; cx.notify();
    let ok = false;
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        const text = await readTextFile(path);
        if (text === null) throw new Error("note not found");
        const next = build(text);
        if (next === null || next === text) { notify({ title: "Nothing changed", body: "The note changed under us. Reloaded.", level: "info", timeout: 2500 }); break; }
        try { await writeTextFile(path, next, text); ok = true; break; }
        catch (e) { if (attempt === 1) throw e; }
      }
    } catch (e) { notify({ title: `${label} failed`, body: String(e.message ?? e).slice(0, 200), level: "error" }); }
    this.busy = false; this.next = 0; this.prevNext = 0; this.load(cx); cx.notify();
    return ok;
  }

  // Checking a task keeps it in place, ticked, then fades it out before it moves to Done.
  toggle(path, task, key, cx) {
    if (meta(task.text).recurring) { notify({ title: "Recurring task", body: "Complete it in Obsidian so the next occurrence is created.", level: "info", timeout: 3500 }); return; }
    const closing = !task.done;
    if (closing) {
      this.linger.set(key, "checked"); cx.notify();
      cx.timer.after(620, (cx) => { if (this.linger.has(key)) { this.linger.set(key, "leaving"); cx.notify(); } });
      cx.timer.after(900, (cx) => { this.linger.delete(key); cx.notify(); });
    } else this.known?.delete(key.replace(/^d:/, "t:"));
    this.mutate(path, (text) => {
      const lines = text.split("\n");
      if (lines[task.i] !== task.raw) return null;
      const next = toggled(task.raw, ymd(new Date()));
      if (next === null) return null;
      lines[task.i] = next;
      return lines.join("\n");
    }, "Toggle", cx).then((ok) => { if (!ok) { this.linger.delete(key); cx.notify(); } });
  }

  add(kind, cx) {
    const input = this.inputs[kind], value = input.value().trim();
    if (!value) return;
    if (kind === "goal" && !this.weekExists) { notify({ title: "No weekly note yet", body: "Create it from the Weekly goals section first.", level: "info", timeout: 3000 }); return; }
    if (kind !== "goal" && this.text === null) return;
    input.set_value("");
    const path = kind === "goal" ? this.weekPath(this.d) : this.dayPath(this.d);
    this.mutate(path, (text) => (kind === "note" ? withNote(text, value) : kind === "goal" ? withGoal(text, value) : withTask(text, value)), `Add ${kind}`, cx);
  }

  setKind(id, cx) {
    this.kind = id; localStorage.setItem("kind", id); cx.notify();
    cx.timer.after(16, () => this.inputs[id].focus());
  }

  startEdit(path, task, key, cx) {
    this.editing = { path, task, key };
    this.edit.set_value(meta(task.text).clean);
    cx.notify();
    cx.timer.after(60, () => this.edit.focus());
  }
  saveEdit(due, cx) {
    const e = this.editing;
    if (!e) return;
    const title = this.edit.value().trim();
    if (!title) { notify({ title: "The title cannot be empty", level: "info", timeout: 2000 }); return; }
    const cur = meta(e.task.text);
    if (title === cur.clean && due === undefined) { this.editing = null; cx.notify(); return; }
    this.mutate(e.path, (text) => {
      const lines = text.split("\n");
      if (lines[e.task.i] !== e.task.raw) return null;
      const next = rebuild(e.task.raw, title, due);
      if (next === null) return null;
      lines[e.task.i] = next;
      return lines.join("\n");
    }, "Edit", cx).then((ok) => { if (ok) { this.editing = null; cx.notify(); } });
  }

  runKey(path, task) { return `${path}|${task.text}`; }
  agentOf(path, task) {
    try { this.runs = JSON.parse(localStorage.getItem("runs") ?? "{}"); } catch {}
    const addr = this.runs[this.runKey(path, task)];
    if (!addr) return null;
    if (!(terminals() ?? []).some((x) => x.address === addr && x.state === "live")) return null;
    return { addr, status: (agents() ?? []).find((x) => x.address === addr)?.status ?? "starting" };
  }

  tackle(path, task, mode, cx, then) {
    const w = where();
    if (!w.folder || w.machine) { notify({ title: "No local folder", body: "Focus a local terminal first: the agent starts there.", level: "error" }); then?.(); return; }
    this.mode = mode; localStorage.setItem("mode", mode); this.starting = mode; cx.notify();
    const key = this.runKey(path, task), m = meta(task.text), issue = this.issueOf(task);
    const label = issue ? `${issue.identifier} ${issue.title}` : m.clean || task.text;
    cx.spawn(async (cx) => {
      try {
        const args = { name: `${MODES[mode].label.toLowerCase()}: ${clip(label, 22)}`, folder: w.folder, argv: ["omp"], task: brief(task, path, mode, w.folder.replace(home(), "~"), this.d, issue) };
        const r = await exec("herdr-app", ["do", "tab.new", JSON.stringify(args)], { timeout: 15000 });
        const addr = /"terminal"\s*:\s*"([^"]+)"/.exec(r.stdout)?.[1];
        if (r.code !== 0 || !addr) throw new Error((r.stderr || r.stdout).trim().slice(0, 160) || "could not start the agent");
        this.runs[key] = addr; localStorage.setItem("runs", JSON.stringify(this.runs));
        notify({ title: `${MODES[mode].label}: agent started`, body: clip(label, 60), level: "success", timeout: 3000 });
      } catch (e) { notify({ title: "Cannot start the agent", body: String(e.message ?? e).slice(0, 200), level: "error" }); }
      this.starting = null; cx.notify(); then?.();
    });
  }

  create(kind, cx) {
    if (this.busy) return;
    this.busy = true; cx.notify();
    cx.spawn(async (cx) => {
      try {
        const weekly = kind === "week", tpl = await readTextFile(`${this.vault}/${weekly ? WEEKLY_TPL : DAILY_TPL}`);
        if (tpl === null) throw new Error("template not found");
        const out = render(tpl, this.d);
        if (out === null) throw new Error("the template uses Templater features I cannot render. Create the note from Obsidian.");
        await writeTextFile(weekly ? this.weekPath(this.d) : this.dayPath(this.d), out, null);
        notify({ title: weekly ? "Weekly note created" : "Daily note created", body: weekly ? weekName(this.d) : ymd(this.d), level: "success", timeout: 3000 });
      } catch (e) { notify({ title: "Cannot create the note", body: String(e.message ?? e).slice(0, 240), level: "error" }); }
      this.busy = false; this.next = 0; cx.notify();
    });
  }

  openInObsidian() { exec("open", [`obsidian://open?vault=${VAULT_NAME}&file=${encodeURIComponent(`${DAILY}/${ymd(this.d)}`)}`]); }

  // ——— pieces ———

  hoverable(el, key) {
    return el.on_hover((h, cx) => { if (h) this.hover = key; else if (this.hover === key) this.hover = null; cx.notify(); });
  }

  // A row that just arrived sits 6px low and transparent for one frame, then settles.
  arriving(el, key, extraOpacity = 1) {
    const fresh = this.entering.has(key);
    return el.relative().top(fresh ? 6 : 0).opacity(fresh ? 0 : extraOpacity)
      .transition("top", { duration: 300, easing: "ease-out" }).transition("opacity", EASE);
  }

  ghost(t, id, label, onClick, icon) {
    return h_flex().id(id).h(26).px(9).gap(6).items_center().rounded(7).flex_none().text_size(11.5).font_medium()
      .text_color(t.muted).hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(onClick)
      .when(Boolean(icon), (el) => el.child(svg(`mods/workspace-chrome/${icon}.svg`).size(13)))
      .child(label);
  }
  solid(t, id, label, onClick) {
    return div().id(id).h(26).px(11).flex().items_center().rounded(7).flex_none().text_size(11.5).font_semibold()
      .bg(t.solid).text_color(t.solid_foreground).hover((s) => s.opacity(.88)).on_click(onClick).child(label);
  }
  chip(t, text, color) { return div().px(7).h(18).flex().items_center().rounded(6).text_size(10.5).font_medium().text_color(color).bg(t.raised).flex_none().child(text); }

  // The box springs its fill out from the centre: the one place with a little overshoot, since you pressed it.
  checkbox(t, key, done, onClick) {
    const S = 18, f = done ? S : 0;
    return div().id(`box-${key}`).size(22).flex().items_center().justify_center().flex_none().cursor_pointer().on_click(onClick)
      .child(div().relative().size(S).rounded(6).border_1().border_color(done ? t.ansi2 : t.input).bg(t.surface)
        .hover((s) => s.border_color(done ? t.ansi2 : t.muted))
        .child(div().absolute().rounded(6).bg(t.ansi2).w(f).h(f).left((S - f) / 2 - 1).top((S - f) / 2 - 1)
          .spring("width", { response: 280, damping: .62 }).spring("height", { response: 280, damping: .62 })
          .spring("left", { response: 280, damping: .62 }).spring("top", { response: 280, damping: .62 }))
        .child(div().absolute().left(0).top(0).size(S - 2).flex().items_center().justify_center().opacity(done ? 1 : 0)
          .transition("opacity", { duration: 160, delay: done ? 60 : 0, easing: "ease-out" })
          .child(svg("mods/workspace-chrome/check.svg").size(12).text_color("#ffffff"))));
  }

  statusChip(t, key, a) {
    const color = a.status === "working" ? t.working : a.status === "blocked" ? t.blocked : a.status === "done" ? t.done : t.muted;
    const dot = div().size(6).rounded(3).bg(color).flex_none();
    return h_flex().id(`ag-${key}`).h(24).px(9).gap(6).items_center().rounded(7).flex_none().bg(t.raised).text_size(11).font_medium().text_color(color)
      .hover((s) => s.opacity(.85)).on_click(() => run("agent.focus", { terminal: a.addr }))
      .child(a.status === "working" ? dot.loop("opacity", { from: .3, to: 1, period: 900 }) : dot).child(a.status);
  }

  tackleButton(t, path, task, key, shown) {
    const live = (el, f) => (shown ? el.cursor_pointer().hover((s) => s.bg(t.hover).text_color(t.foreground)).on_click(f) : el);
    return h_flex().h(24).rounded(7).flex_none().overflow_hidden().border_1().border_color(t.border).bg(t.chrome).text_size(11).font_medium().text_color(t.muted)
      .opacity(shown ? 1 : 0).transition("opacity", { duration: 140, easing: "ease-out" })
      .child(live(div().id(`go-${key}`).px(9).h_full().flex().items_center(), (_e, cx) => this.tackle(path, task, this.mode, cx)).child(`▶ ${MODES[this.mode].label}`))
      .child(div().w(1).h_full().bg(t.border))
      .child(live(div().id(`dd-${key}`).px(6).h_full().flex().items_center(), () => openOverlay({ mod: "acc-today", kind: "popup", width: 264, height: Object.keys(MODES).length * 46 + 10,
        props: { menu: { path, raw: task.raw, i: task.i, text: task.text, done: task.done, section: task.section } } }))
        .child(svg(`mods/workspace-chrome/chevron-down.svg`).size(12)));
  }

  menuPopup(t) {
    const { path, ...task } = props().menu, done = () => closeOverlay(props().overlay);
    return v_flex().size_full().p(5).gap(1).bg(t.raised)
      .children(Object.entries(MODES).map(([k, v]) => h_flex().id(`mi-${k}`).h(44).px(10).gap(10).rounded(7).items_center().cursor_pointer()
        .bg(this.starting === k ? t.hover : t.raised).hover((s) => s.bg(t.hover))
        .on_click((_e, cx) => { if (!this.starting) this.tackle(path, task, k, cx, done); })
        .child(div().w(14).text_size(11).text_color(this.mode === k ? t.accent : t.dim).child(this.mode === k ? "●" : ""))
        .child(v_flex().flex_1().min_w(0).gap(1)
          .child(div().text_size(12.5).font_medium().text_color(t.foreground).child(this.starting === k ? `${v.label}…` : v.label))
          .child(div().truncate().text_size(11).text_color(t.muted).child(v.desc)))));
  }

  editor(t, key) {
    const today = new Date(), mon = addDays(today, ((8 - today.getDay()) % 7) || 7);
    const quick = [["Today", ymd(today)], ["Tomorrow", ymd(addDays(today, 1))], ["Next Mon", ymd(mon)], ["No date", null]];
    return v_flex().gap(8).w_full()
      .child(div().id(`edit-box-${key}`).w_full().h(30).px(9).flex().items_center().rounded(7).border_1().border_color(t.accent).bg(t.surface).cursor_text()
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation()).child(Input.new(this.edit).h_full().text_size(13).text_color(t.foreground)))
      .child(h_flex().gap(4).flex_wrap().items_center()
        .child(div().text_size(10.5).text_color(t.dim).mr(2).child("Due"))
        .children(quick.map(([label, val]) => div().id(`due-${key}-${label}`).px(7).h(20).flex().items_center().rounded(6).text_size(10.5).font_medium().bg(t.raised).text_color(t.muted)
          .hover((s) => s.text_color(t.foreground)).on_click((_e, cx) => this.saveEdit(val, cx)).child(label))))
      .child(h_flex().gap(6)
        .child(this.solid(t, `save-${key}`, "Save", (_e, cx) => this.saveEdit(undefined, cx)))
        .child(this.ghost(t, `cancel-${key}`, "Cancel", (_e, cx) => { this.editing = null; cx.notify(); })));
  }

  row(t, path, task, key) {
    const m = meta(task.text), today = ymd(this.d), linger = this.linger.get(key);
    const done = task.done || Boolean(linger), editing = this.editing?.key === key, hovered = this.hover === key;
    const ag = done ? null : this.agentOf(path, task);
    const dueColor = !m.due || done ? t.dim : m.due < today ? t.ansi1 : m.due === today ? t.ansi3 : t.muted;
    const tags = [];
    if (m.due) tags.push(this.chip(t, `${m.due < today && !done ? "overdue · " : m.due === today ? "today · " : ""}${m.due}`, dueColor));
    if (m.recurring) tags.push(this.chip(t, m.rule ? `↻ ${m.rule}` : "↻ recurring", t.muted));
    const issue = this.issueOf(task), cached = m.linear && this.linear[m.linear];
    if (m.linear) {
      const sc = !issue ? t.dim : issue.stateType === "started" ? t.ansi3 : issue.stateType === "completed" ? t.ansi2 : issue.stateType === "canceled" ? t.dim : t.muted;
      tags.push(h_flex().id(`lin-${key}`).px(7).h(18).gap(6).items_center().rounded(6).text_size(10.5).font_medium().bg(t.raised).flex_none().cursor_pointer()
        .hover((s) => s.opacity(.8)).on_click(() => exec("open", [issue?.url ?? `https://linear.app/issue/${m.linear}`]))
        .child(div().text_color(t.accent).child(m.linear))
        .when(Boolean(issue), (el) => el.child(div().size(6).rounded(3).bg(sc)).child(div().text_color(sc).child(issue.state)))
        .when(!cached && this.fetching, (el) => el.child(div().text_color(t.dim).child("loading…").loop("opacity", { from: .4, to: 1, period: 1100 })))
        .when(Boolean(cached?.missing), (el) => el.child(div().text_color(t.dim).child("not found"))));
    }
    const own = (m.clean || task.text).replace(/\bLIV-\d+\b/i, "").replace(/^[\s:·—–-]+|[\s:·—–-]+$/g, "");
    const title = issue && own.length < 3 ? issue.title : m.clean || task.text;
    const el = h_flex().id(`row-${key}`).gap(8).px(8).py(7).items_start().rounded(9).when(hovered && !editing, (e) => e.bg(t.hover))
      .child(this.checkbox(t, key, done, (_e, cx) => this.toggle(path, task, key, cx)))
      .child(editing ? v_flex().flex_1().min_w(0).pt(1).child(this.editor(t, key))
        : v_flex().flex_1().min_w(0).gap(5).pt(2)
          .child(div().id(`title-${key}`).w_full().min_w(0).line_height(1.45).whitespace_normal().text_size(13)
            .text_color(done ? t.muted : t.foreground).when(done, (e) => e.line_through())
            .cursor_text().on_click((_e, cx) => this.startEdit(path, task, key, cx)).child(clip(title, 220)))
          .when(tags.length > 0, (e) => e.child(h_flex().gap(5).flex_wrap().children(tags)))
          )
      .when(!editing && !done, (e) => e.child(h_flex().flex_none().h(22).items_center()
        .child(ag ? this.statusChip(t, key, ag) : this.tackleButton(t, path, task, key, hovered))));
    return this.arriving(this.hoverable(el, key), key, linger === "leaving" ? 0 : 1);
  }

  noteRow(t, note, key) {
    const el = h_flex().id(`note-${key}`).gap(10).px(8).py(6).items_start().rounded(9)
      .child(div().w(22).h(19).flex().items_center().justify_center().flex_none().child(div().size(5).rounded(3).bg(t.ansi4 ?? t.accent)))
      .child(div().flex_1().min_w(0).line_height(1.5).whitespace_normal().text_size(13).text_color(t.foreground).child(note.text));
    return this.arriving(el, key);
  }

  section(t, id, title, count, rows, fold) {
    const folded = fold ? this.fold[fold] : false;
    return v_flex().gap(2).px(8).pt(14)
      .child(h_flex().id(`h-${id}`).h(24).px(8).gap(7).items_center().rounded(7)
        .when(Boolean(fold), (el) => el.cursor_pointer().hover((s) => s.bg(t.hover)).on_click((_e, cx) => { this.fold[fold] = !this.fold[fold]; cx.notify(); }))
        .child(div().text_size(11.5).font_semibold().text_color(t.muted).child(title))
        .when(count !== null, (el) => el.child(div().text_size(11).text_color(t.dim).child(String(count))))
        .child(div().flex_1())
        .when(Boolean(fold), (el) => el.child(svg(`mods/workspace-chrome/chevron-${folded ? "right" : "down"}.svg`).size(12).text_color(t.dim))))
      .when(!folded, (el) => el.children(rows));
  }

  empty(t, text, action) {
    return v_flex().gap(10).px(16).py(14).items_start()
      .child(div().text_size(12.5).line_height(1.5).text_color(t.dim).child(text))
      .when(Boolean(action), (el) => el.child(action));
  }

  composer(t) {
    const idx = KINDS.findIndex((k) => k.id === this.kind), input = this.inputs[this.kind];
    const seg = div().relative().h(26).w(SEG * KINDS.length + 4).rounded(8).bg(t.surface).border_1().border_color(t.border).flex_none()
      .child(div().absolute().top(2).left(2 + idx * SEG).w(SEG).h(20).rounded(6).bg(t.raised)
        .spring("left", { response: 300, damping: .78 }))
      .child(h_flex().absolute().top(0).left(2).h(24).children(KINDS.map((k) => div().id(`kind-${k.id}`).w(SEG).h_full().flex().items_center().justify_center()
        .text_size(11.5).font_medium().text_color(k.id === this.kind ? t.foreground : t.dim).cursor_pointer()
        .hover((s) => s.text_color(t.foreground)).on_click((_e, cx) => this.setKind(k.id, cx)).child(k.label))));
    return v_flex().gap(8).px(12).pt(10).pb(12).border_t(1).border_color(t.border)
      .child(h_flex().items_center().justify_between()
        .child(seg)
        .child(div().text_size(10.5).text_color(t.dim).child(this.kind === "goal" ? weekName(this.d) : "↵ to add")))
      .child(div().id("tasks-input").w_full().h(34).px(11).flex().items_center().rounded(9).border_1()
        .border_color(this.typing ? t.accent : t.border).bg(t.surface).cursor_text()
        .on_mouse_down("left", (_e, cx) => cx.stop_propagation())
        .child(Input.new(input).h_full().text_size(13).text_color(t.foreground)));
  }

  render() {
    if (props()?.menu) return this.menuPopup(theme());
    const t = theme(), dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    const body = [];
    let total = 0, doneN = 0;
    if (this.error) body.push(div().px(16).pt(10).text_size(11.5).text_color(t.blocked).child(this.error));

    if (this.exists === false) {
      body.push(this.empty(t, `No daily note for ${ymd(this.d)} yet.`, this.solid(t, "create", this.busy ? "Creating…" : "Create today's note", (_e, cx) => this.create("day", cx))));
    } else if (this.text !== null) {
      const path = this.dayPath(this.d), all = parse(this.text).tasks.filter((x) => x.text);
      const today = keyed("t", all.filter((x) => isToday(x.section)), keyOf);
      const open = today.filter(([k, x]) => !x.done || this.linger.has(k)), done = today.filter(([k, x]) => x.done && !this.linger.has(k));
      const other = keyed("o", all.filter((x) => !isToday(x.section) && !x.done), keyOf);
      const notes = keyed("n", parseNotes(this.text), (x) => x.text);
      total = today.length; doneN = today.filter(([, x]) => x.done).length;

      body.push(this.section(t, "today", "Today", open.length, open.length ? open.map(([k, x]) => this.row(t, path, x, k))
        : [this.empty(t, done.length ? "All clear. Nice work." : "Nothing planned yet.")]));
      if (other.length) body.push(this.section(t, "other", "Elsewhere in the note", other.length, other.map(([k, x]) => this.row(t, path, x, k))));
      if (this.prev?.open.length) {
        const pp = this.dayPath(this.prev.d);
        body.push(this.section(t, "prev", `Left from ${this.prev.date}`, this.prev.open.length, keyed("p", this.prev.open, keyOf).map(([k, x]) => this.row(t, pp, x, k)), "prev"));
      }
      body.push(this.section(t, "notes", "Notes", notes.length || null, notes.length ? notes.map(([k, x]) => this.noteRow(t, x, k))
        : [this.empty(t, "Things to think about land here, in today's note.")]));
      if (this.week !== null) {
        const wp = this.weekPath(this.d), goals = parse(this.week).tasks.filter((x) => x.text && isGoals(x.section));
        const g = keyed("w", [...goals.filter((x) => !x.done), ...goals.filter((x) => x.done)], keyOf);
        body.push(this.section(t, "week", `This week · ${weekName(this.d)}`, goals.filter((x) => !x.done).length,
          g.length ? g.map(([k, x]) => this.row(t, wp, x, k)) : [this.empty(t, "No goals yet. Switch to Goal below to add one.")], "week"));
      } else if (this.weekExists === false) {
        body.push(this.section(t, "week", `This week · ${weekName(this.d)}`, null,
          [this.empty(t, "No weekly note yet.", this.solid(t, "create-week", this.busy ? "Creating…" : "Create weekly note", (_e, cx) => this.create("week", cx)))], "week"));
      }
      if (done.length) body.push(this.section(t, "done", "Done", done.length, done.map(([k, x]) => this.row(t, path, x, k.replace(/^t:/, "d:"))), "done"));
    } else body.push(div().px(16).py(14).text_size(12).text_color(t.dim).child("Loading…"));

    const BAR = 132, pct = total ? doneN / total : 0;
    return v_flex().size_full().bg(t.chrome)
      .child(v_flex().gap(10).px(16).pt(14).pb(10)
        .child(h_flex().items_start().justify_between()
          .child(v_flex().gap(1)
            .child(div().text_size(19).font_semibold().text_color(t.foreground).child(dayNames[this.d.getDay()]))
            .child(div().text_size(12).text_color(t.dim).child(`${this.d.getDate()} ${months[this.d.getMonth()]}`)))
          .child(this.ghost(t, "obs", "Obsidian", () => this.openInObsidian(), "file-text")))
        .when(total > 0, (el) => el.child(h_flex().gap(10).items_center()
          .child(div().relative().w(BAR).h(4).rounded(2).bg(t.raised)
            .child(div().absolute().left(0).top(0).h(4).rounded(2).bg(t.ansi2).w(Math.max(4, BAR * pct)).transition("width", { duration: 420, easing: "ease-out" })))
          .child(div().text_size(11).text_color(t.dim).child(`${doneN} of ${total}`)))))
      .child(v_flex().id("tasks-scroll").flex_1().min_h(0).overflow_y_scrollbar().pb(12).children(body))
      .when(this.exists === true, (el) => el.child(this.composer(t)));
  }
}
