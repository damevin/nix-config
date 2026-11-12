--!nonstrict
-- Block `acc.today`: today's tasks, notes and weekly goals from the Obsidian
-- vault, Linear tickets on the tasks, and "Tackle" to hand a task to an agent.
local ui = tern.ui
local bridge = require("../../lib/bridge")
local facts = require("../../lib/facts")
local Field = require("../../lib/field")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local util = require("../../lib/util")
local wt = require("../../lib/wt")
local V = require("./vault")

local LINEAR_SCRIPT = tern.plugin.dir .. "/mods/today/linear-issue.sh"
local LINEAR_TTL = 15 * 60
local LOAD_MS, PREV_MS, BACKOFF_MS = 3000, 20000, 5 * 60 * 1000
local RUN_TTL = 2 * 86400

local MODES = {
	{ id = "do", label = "Do it", desc = "Implement it end to end", icon = "play",
		ask = "Do this end to end. Keep changes focused, run the relevant checks, and commit locally only if you changed code." },
	{ id = "investigate", label = "Investigate", desc = "Read-only, report findings", icon = "search",
		ask = "Investigate and report back. Read-only: do not edit files or run anything that changes state." },
	{ id = "plan", label = "Plan", desc = "Propose a plan, wait for my go", icon = "list",
		ask = "Do not change anything yet. Write a short plan (steps, files involved, risks, open questions) and wait for my go before editing." },
}
local MODE = {}
for _, m in MODES do MODE[m.id] = m end

local KINDS = {
	{ id = "task", label = "Task", placeholder = "Add a task for today…" },
	{ id = "note", label = "Note", placeholder = "Jot something to think about…" },
	{ id = "goal", label = "Goal", placeholder = "Add a goal for this week…" },
}
local KIND = {}
for _, k in KINDS do KIND[k.id] = k end

local DAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

local COMPOSER_ID = "dock.input"

-- ——— small helpers ———

local function clip(s: string, n: number): string
	if (utf8.len(s) or #s) <= n then return s end
	return string.sub(s, 1, (utf8.offset(s, n) or (n + 1)) - 1) .. "…"
end

local SEPARATORS = { "·", "—", "–", ":", "-" }

-- Strips whitespace and separator punctuation from both ends (multi-byte separators match whole).
local function trimSeparators(s: string): string
	local changed = true
	while changed do
		changed = false
		s = util.trim(s)
		for _, sep in SEPARATORS do
			if string.sub(s, 1, #sep) == sep then
				s = string.sub(s, #sep + 1)
				changed = true
			end
			if #s >= #sep and string.sub(s, -#sep) == sep then
				s = string.sub(s, 1, #s - #sep)
				changed = true
			end
		end
	end
	return s
end

local function el(props, children)
	return ui.el(props.tag or "div", props, children)
end

local function kvTable(key: string)
	local v = tern.kv.get(key)
	return if type(v) == "table" then v else {}
end

local function text(v): string
	return if type(v) == "string" then v else ""
end

local function nowSecs(): number return os.time() end

local function runKey(path: string, task): string return path .. "|" .. task.text end

local function replaceFile(path: string, content: string, cb: (boolean, string?) -> ())
	local tmp = tern.plugin.data .. "/today-write.tmp"
	local ok, err = pcall(tern.fs.write, tmp, content)
	if not ok then cb(false, tostring(err)) return end
	tern.process.run({ "/bin/mv", "-f", tmp, path }, { timeout_ms = 5000 }, function(r)
		cb(r.status == 0, if r.status == 0 then nil else util.trim(r.stderr))
	end)
end

local function persistRuns(state)
	local out = {}
	for key, run in state.runs do
		out[key] = {
			pane = run.pane, cwd = run.cwd, repo = run.repo, branch = run.branch, at = run.at,
			before = tern.json.array(run.before or {}),
		}
	end
	tern.kv.set("today:runs", out)
end

-- ——— reading ———

local function rowKeys(day: string?, week: string?)
	local keys = {}
	if day then
		local tasks = {}
		for _, t in V.parse(day).tasks do
			if t.text ~= "" then table.insert(tasks, t) end
		end
		for _, pair in V.keyed("t", tasks, V.keyOf) do keys[pair[1]] = true end
		for _, pair in V.keyed("n", V.parseNotes(day), function(n) return n.text end) do keys[pair[1]] = true end
	end
	if week then
		local goals = {}
		for _, t in V.parse(week).tasks do
			if t.text ~= "" and V.isGoals(t.section) then table.insert(goals, t) end
		end
		for _, pair in V.keyed("w", goals, V.keyOf) do keys[pair[1]] = true end
	end
	return keys
end

-- Rows that weren't there on the last read rise in; the class stays only as long as the animation.
local function arrive(state, cx, keys)
	local fresh = {}
	if state.known then
		for k in keys do
			if not state.known[k] then
				table.insert(fresh, k)
				state.entering[k] = true
			end
		end
	end
	state.known = keys
	if #fresh == 0 then return end
	timer.later("today enter", 700, function()
		for _, k in fresh do state.entering[k] = nil end
		if timer.alive(cx.pane) then cx:render() end
	end)
end

local function readNote(path: string): (string?, string?)
	local content = util.readFile(path)
	if content ~= nil then return content, nil end
	if tern.fs.exists(path) then return nil, "couldn't read " .. util.shortenHome(path) end
	return nil, nil
end

local function load(state, cx)
	local day, dayErr = readNote(V.dayPath(state.vault, state.d))
	local week, weekErr = readNote(V.weekPath(state.vault, state.d))
	local err = dayErr or weekErr
	local changed = day ~= state.text or week ~= state.week or err ~= state.error
	state.exists, state.text = day ~= nil, day
	state.weekExists, state.week = week ~= nil, week
	state.error = err
	if changed then
		arrive(state, cx, rowKeys(day, week))
		cx:render()
	end
end

local function loadPrev(state, cx)
	for k = 1, 7 do
		local d = V.addDays(state.d, -k)
		local content = util.readFile(V.dayPath(state.vault, d))
		if content ~= nil then
			local open = {}
			for _, t in V.parse(content).tasks do
				if not t.done and t.text ~= "" then table.insert(open, t) end
			end
			state.prev = { date = V.ymd(d), d = d, open = open }
			cx:render()
			return
		end
	end
	if state.prev then
		state.prev = nil
		cx:render()
	end
end

-- Reads the note again right before writing and gives up (or retries) when it
-- moved since `build` saw it; the write itself replaces the file atomically.
local function commit(state, cx, path: string, build, label: string, done: ((boolean) -> ())?)
	if state.busy then return end
	state.busy = true
	cx:render()
	local function finish(ok: boolean)
		state.busy = false
		state.nextLoad, state.nextPrev = 0, 0
		load(state, cx)
		cx:render()
		if done then done(ok) end
	end
	local function attempt(n: number)
		local current = util.readFile(path)
		if current == nil then
			cx:toast("error", label .. " failed", "note not found")
			finish(false)
			return
		end
		local nextText = build(current)
		if nextText == nil or nextText == current then
			cx:toast("info", "Nothing changed", "The note changed under us. Reloaded.")
			finish(false)
			return
		end
		if util.readFile(path) ~= current then
			if n >= 2 then
				cx:toast("error", label .. " failed", "the note keeps changing")
				finish(false)
			else
				attempt(n + 1)
			end
			return
		end
		replaceFile(path, nextText, function(ok, err)
			if not ok then cx:toast("error", label .. " failed", tostring(err)) end
			finish(ok)
		end)
	end
	attempt(1)
end

-- ——— Linear ———

local function issueOf(state, task)
	local id = V.meta(task.text).linear
	local issue = id and state.linear[id]
	if issue and not issue.missing then return issue end
	return nil
end

-- One call for every ticket on screen that is new or older than 15 minutes.
-- The first read unlocks the secret store (~10 s); rows show the cached ticket meanwhile.
local function syncLinear(state, cx)
	if state.fetching or tern.now() < state.linearRetry then return end
	local texts = {}
	for _, note in { state.text, state.week } do
		if note then
			for _, t in V.parse(note).tasks do table.insert(texts, t.text) end
		end
	end
	if state.prev then
		for _, t in state.prev.open do table.insert(texts, t.text) end
	end
	local seen, stale = {}, {}
	for _, t in texts do
		local id = V.meta(t).linear
		if id and not seen[id] then
			seen[id] = true
			local cached = state.linear[id]
			if not cached or nowSecs() - (cached.at or 0) > LINEAR_TTL then table.insert(stale, id) end
		end
	end
	if #stale == 0 then return end
	state.fetching = true
	local argv = { "sh", LINEAR_SCRIPT }
	for _, id in stale do table.insert(argv, id) end
	proc.run("linear issues", argv, { timeout_ms = 60000 }, function(r)
		state.fetching = false
		local reply = util.decodeJson(r.stdout)
		local nodes = type(reply) == "table" and type(reply.data) == "table" and type(reply.data.issues) == "table"
			and reply.data.issues.nodes
		if type(nodes) ~= "table" then
			state.linearRetry = tern.now() + BACKOFF_MS
			local why = if type(reply) == "table" and type(reply.errors) == "table" and type(reply.errors[1]) == "table"
				then text(reply.errors[1].message) else ""
			if why == "" then why = util.trim(if r.stderr ~= "" then r.stderr else "no answer") end
			if timer.alive(cx.pane) then
				cx:toast("error", "Linear tickets not loaded", string.sub(why, 1, 200))
				cx:render()
			end
			return
		end
		local at = nowSecs()
		for _, id in stale do state.linear[id] = { missing = true, at = at } end
		for _, i in nodes do
			local stateInfo = if type(i.state) == "table" then i.state else {}
			local assignee = if type(i.assignee) == "table" then i.assignee else {}
			local priority = text(i.priorityLabel)
			state.linear[text(i.identifier)] = {
				identifier = text(i.identifier), title = text(i.title), url = text(i.url),
				description = text(i.description), state = text(stateInfo.name), stateType = text(stateInfo.type),
				priority = if priority == "No priority" then "" else priority, assignee = text(assignee.name), at = at,
			}
		end
		tern.kv.set("today:linear", state.linear)
		if timer.alive(cx.pane) then cx:render() end
	end)
end

-- ——— agents ———

local STATUS = { working = "working", waiting_input = "blocked", idle = "done" }

local function under(cwd: string, root: string): boolean
	return cwd == root or string.sub(cwd, 1, #root + 1) == root .. "/"
end

-- Binds each recorded run to the agent it started (a new agent in its folder or
-- worktree) and recomputes which tasks have a live agent. True when that changed.
local function refreshAgents(state, f): boolean
	local alive, byPane = {}, {}
	for _, p in f.panes do alive[p.pane] = true end
	for _, a in f.agents do byPane[a.pane] = a end
	local claimed = {}
	for _, run in state.runs do
		if run.pane then claimed[run.pane] = true end
	end
	local now, dirty, live = nowSecs(), false, {}
	for key, run in state.runs do
		if not run.pane and run.repo and run.branch and not run.cwd and not state.resolving[key] and tern.now() >= (state.resolveAt[key] or 0) then
			state.resolving[key] = true
			wt.pathOf(run.repo, run.branch, function(path)
				state.resolving[key] = nil
				state.resolveAt[key] = tern.now() + 4000
				if path and state.runs[key] then
					state.runs[key].cwd = path
					persistRuns(state)
				end
			end)
		end
		if not run.pane and run.cwd then
			local before = {}
			for _, p in (run.before or {}) do before[p] = true end
			for _, a in f.agents do
				if not before[a.pane] and not claimed[a.pane] and under(a.cwd or "", run.cwd) then
					run.pane = a.pane
					claimed[a.pane] = true
					dirty = true
					break
				end
			end
		end
		if run.pane and alive[run.pane] then
			local a = byPane[run.pane]
			if a then
				local status = STATUS[a.state]
				if status then live[key] = { pane = run.pane, status = status } end
			elseif now - run.at < 120 then
				live[key] = { pane = run.pane, status = "starting" }
			end
		elseif not run.pane and now - run.at < 120 then
			live[key] = { status = "starting" }
		end
	end
	if dirty then persistRuns(state) end
	local before = tern.json.encode(state.live)
	state.live = live
	return tern.json.encode(live) ~= before
end

-- The folder a task is started in: the focused work pane, not this panel.
local function workCwd(state, f): string?
	local focused = f.focused
	if focused then
		for _, p in f.panes do
			if p.pane == focused.pane and not p.block and p.cwd and p.cwd ~= "" then return p.cwd end
		end
	end
	if state.lastWork and state.lastWork ~= "" then return state.lastWork end
	if focused then
		for _, p in f.panes do
			if p.tab == focused.tab and p.kind == "terminal" and not p.block and p.cwd and p.cwd ~= "" then return p.cwd end
		end
		if focused.cwd and focused.cwd ~= "" then return focused.cwd end
	end
	return nil
end

local function brief(state, task, path: string, mode: string, folder: string, issue)
	local m = V.meta(task.text)
	local weekly = string.find(path, "/" .. V.WEEKLY .. "/", 1, true) ~= nil
	local ticket = nil
	if issue then
		local head = "Linear ticket " .. issue.identifier .. ": " .. issue.title
		local line = issue.url .. " · " .. issue.state
			.. (if issue.priority ~= "" then " · " .. issue.priority else "")
			.. (if issue.assignee ~= "" then " · " .. issue.assignee else "")
		local parts = { head, line }
		if issue.description ~= "" then
			table.insert(parts, "\nTicket description:\n" .. clip(issue.description, 6000) .. "\n")
		end
		table.insert(parts, "Read the ticket's comments in Linear too if you can.")
		ticket = table.concat(parts, "\n")
	elseif m.linear then
		ticket = "Related Linear ticket: " .. m.linear .. " (https://linear.app/issue/" .. m.linear .. ")"
	end
	local lines = {
		(if weekly then "Weekly goal (" .. V.weekName(state.d) .. ")" else "Task from my daily note (" .. V.ymd(state.d) .. ")")
			.. ": " .. (if m.clean ~= "" then m.clean else task.text),
	}
	if ticket then table.insert(lines, ticket) end
	if m.due then table.insert(lines, "Due: " .. m.due) end
	table.insert(lines, "You are working in " .. folder .. ".")
	table.insert(lines, "")
	table.insert(lines, MODE[mode].ask)
	table.insert(lines, "Never push, force-push or merge. When you finish, reply with a short summary of what you did and what is left.")
	return table.concat(lines, "\n")
end

local function slug(s: string, max: number): string
	local out = string.gsub(string.gsub(string.lower(s), "[^%w]+", "-"), "^%-+", "")
	if #out > max then
		out = string.sub(out, 1, max)
		out = string.gsub(out, "%-[^%-]*$", "")
	end
	return (string.gsub(out, "%-+$", ""))
end

-- liv-12345-short-slug for a task with a Linear key, else a slug of its title.
local function branchOf(state, task): string
	local m = V.meta(task.text)
	local issue = issueOf(state, task)
	if m.linear then
		local key = string.lower(m.linear)
		local rest = if issue then issue.title else (string.gsub(m.clean, "%f[%w_]%a+%-%d+%f[^%w_]", ""))
		local tail = slug(rest, 40)
		return if tail ~= "" then key .. "-" .. tail else key
	end
	local s = slug(if m.clean ~= "" then m.clean else task.text, 48)
	return if s ~= "" then s else "task-" .. V.ymd(state.d)
end

local function recordRun(state, key: string, run)
	run.at = nowSecs()
	state.runs[key] = run
	state.resolveAt[key] = nil
	persistRuns(state)
end

local function agentPanes(f): { number }
	local out = {}
	for _, a in f.agents do table.insert(out, a.pane) end
	return out
end

local function tackle(state, cx, ref, mode: string)
	if state.starting then return end
	local f = facts.read()
	local folder = workCwd(state, f)
	if not folder then
		cx:toast("error", "No local folder", "Focus a local terminal first: the agent starts there.")
		return
	end
	state.mode = mode
	tern.kv.set("today:mode", mode)
	state.starting = mode
	cx:render()
	local task, path = ref.task, ref.path
	local key = runKey(path, task)
	local issue = issueOf(state, task)
	local m = V.meta(task.text)
	local label = if issue then issue.identifier .. " " .. issue.title else (if m.clean ~= "" then m.clean else task.text)
	local prompt = brief(state, task, path, mode, util.shortenHome(folder), issue)
	local before = agentPanes(f)
	local function finish(ok: boolean)
		state.starting = nil
		if ok then cx:toast("success", MODE[mode].label .. ": agent started", clip(label, 60)) end
		cx:render()
	end
	local function inFolder()
		bridge.request(cx, "agent", { prompt = prompt, cwd = folder, command = "omp", how = "tab" }, function(pane)
			if not pane then
				cx:toast("error", "Cannot start the agent", "could not start the agent")
				finish(false)
				return
			end
			recordRun(state, key, { pane = pane, cwd = folder, before = before })
			refreshAgents(state, facts.read())
			finish(true)
		end)
	end
	proc.run("git root", { "git", "-C", folder, "rev-parse", "--show-toplevel" }, nil, function(r)
		if r.status ~= 0 then
			inFolder()
			return
		end
		local repo = util.trim(r.stdout)
		local branch = branchOf(state, task)
		proc.run("branch exists", { "git", "-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, nil, function(b)
			bridge.send(cx, "worktree", {
				repo = repo, branch = branch, create = b.status ~= 0, command = "omp", prompt = prompt,
			})
			recordRun(state, key, { repo = repo, branch = branch, before = before })
			finish(true)
		end)
	end)
end

-- ——— editing ———

local function startEdit(state, cx, ref, key: string)
	state.editing = { key = key, path = ref.path, task = ref.task }
	Field.set(state.edit, V.meta(ref.task.text).clean)
	state.focus = "edit"
	timer.later("today focus edit", 60, function()
		if state.editId then Field.focus(cx, state.editId) end
	end)
end

local function stopEdit(state)
	state.editing = nil
	if state.focus == "edit" then state.focus = nil end
end

local function saveEdit(state, cx, due)
	local e = state.editing
	if not e then return end
	local title = util.trim(state.edit.text)
	if title == "" then
		cx:toast("info", "The title cannot be empty")
		return
	end
	if title == V.meta(e.task.text).clean and due == nil then
		stopEdit(state)
		return
	end
	commit(state, cx, e.path, function(content)
		local parsed = V.parse(content)
		local lines = parsed.lines
		if lines[e.task.i] ~= e.task.raw then return nil end
		local rebuilt = V.rebuild(e.task.raw, title, due)
		if rebuilt == nil then return nil end
		lines[e.task.i] = rebuilt
		return table.concat(lines, "\n")
	end, "Edit", function(ok)
		if ok then stopEdit(state) end
	end)
end

local function toggle(state, cx, ref, key: string)
	local task = ref.task
	if V.meta(task.text).recurring then
		cx:toast("info", "Recurring task", "Complete it in Obsidian so the next occurrence is created.")
		return
	end
	if not task.done then
		-- Ticked rows stay in place a moment, then fade before moving to Done.
		state.linger[key] = "checked"
		timer.later("today linger leave", 620, function()
			if state.linger[key] then
				state.linger[key] = "leaving"
				if timer.alive(cx.pane) then cx:render() end
			end
		end)
		timer.later("today linger end", 900, function()
			state.linger[key] = nil
			if timer.alive(cx.pane) then cx:render() end
		end)
	elseif state.known then
		state.known[(string.gsub(key, "^d%-", "t-"))] = nil
	end
	commit(state, cx, ref.path, function(content)
		local lines = V.parse(content).lines
		if lines[task.i] ~= task.raw then return nil end
		local nextLine = V.toggled(task.raw, V.ymd(V.today()))
		if nextLine == nil then return nil end
		lines[task.i] = nextLine
		return table.concat(lines, "\n")
	end, "Toggle", function(ok)
		if not ok then
			state.linger[key] = nil
			cx:render()
		end
	end)
end

local function addEntry(state, cx, kind: string)
	local field = state.fields[kind]
	local value = util.trim(field.text)
	if value == "" then return end
	if kind == "goal" and not state.weekExists then
		cx:toast("info", "No weekly note yet", "Create it from the Weekly goals section first.")
		return
	end
	if kind ~= "goal" and state.text == nil then return end
	Field.set(field, "")
	local path = if kind == "goal" then V.weekPath(state.vault, state.d) else V.dayPath(state.vault, state.d)
	commit(state, cx, path, function(content)
		if kind == "note" then return V.withNote(content, value) end
		if kind == "goal" then return V.withGoal(content, value) end
		return V.withTask(content, value)
	end, "Add " .. kind)
end

local function createNote(state, cx, kind: string)
	if state.busy then return end
	local weekly = kind == "week"
	local tpl = util.readFile(state.vault .. "/" .. (if weekly then V.WEEKLY_TPL else V.DAILY_TPL))
	if tpl == nil then
		cx:toast("error", "Cannot create the note", "template not found")
		return
	end
	local out = V.render(tpl, state.d)
	if out == nil then
		cx:toast("error", "Cannot create the note", "the template uses Templater features I cannot render. Create the note from Obsidian.")
		return
	end
	local path = if weekly then V.weekPath(state.vault, state.d) else V.dayPath(state.vault, state.d)
	if tern.fs.exists(path) then
		state.nextLoad = 0
		return
	end
	state.busy = true
	cx:render()
	pcall(tern.fs.mkdir, util.dirname(path))
	replaceFile(path, out, function(ok, err)
		state.busy = false
		state.nextLoad = 0
		if ok then
			cx:toast("success", if weekly then "Weekly note created" else "Daily note created",
				if weekly then V.weekName(state.d) else V.ymd(state.d))
			load(state, cx)
		else
			cx:toast("error", "Cannot create the note", tostring(err))
		end
		cx:render()
	end)
end

local function openUrl(url: string)
	tern.process.run({ "/usr/bin/open", url }, { timeout_ms = 10000 }, function() end)
end

local function openInObsidian(state)
	openUrl("obsidian://open?vault=" .. V.VAULT_NAME .. "&file=" .. util.urlencode(V.DAILY .. "/" .. V.ymd(state.d)))
end

-- ——— ticking ———

local function hidden(f, pane: number): boolean
	for _, p in f.panes do
		if p.pane == pane then return p.parked == true end
	end
	return false
end

local function tick(state, cx)
	local f = facts.read()
	if hidden(f, cx.pane) then
		state.shown = false
		return
	end
	local focused = f.focused
	if focused then
		for _, p in f.panes do
			if p.pane == focused.pane and not p.block and p.cwd and p.cwd ~= "" then state.lastWork = p.cwd end
		end
	end
	local today = V.today()
	if V.ymd(today) ~= V.ymd(state.d) then
		state.d, state.text, state.week, state.known = today, nil, nil, nil
		state.nextLoad, state.nextPrev = 0, 0
	end
	if not state.shown then
		state.shown = true
		state.nextLoad, state.nextPrev = 0, 0
	end
	local now = tern.now()
	if now >= state.nextLoad and not state.busy and not state.editing then
		state.nextLoad = now + LOAD_MS
		load(state, cx)
	end
	if now >= state.nextPrev then
		state.nextPrev = now + PREV_MS
		loadPrev(state, cx)
	end
	syncLinear(state, cx)
	if refreshAgents(state, f) then cx:render() end
end

-- ——— view ———

local function chip(props, children)
	props.class = "td-chip" .. (if props.class then " " .. props.class else "")
	return el(props, children)
end

local function emptyBlock(key: string, message: string, action)
	local children = { el({ key = "text", class = "td-empty-text", text = message }) }
	if action then table.insert(children, action) end
	return el({ key = key, class = "td-empty" }, children)
end

local function agentChip(live)
	local tone = if live.status == "working" then "pending" elseif live.status == "blocked" then "warning"
		elseif live.status == "done" then "success" else nil
	return el({
		key = "tail", class = "td-agent st-" .. live.status, role = "acc.today.agent",
		title = if live.pane then "Focus the agent" else "Agent starting",
		actions = if live.pane then { click = "agent=" .. tostring(live.pane) } else nil,
	}, {
		el({ key = "dot", role = "acc.dot", tone = tone }),
		el({ key = "label", tag = "span", text = live.status }),
	})
end

local function tackleControl(state, key: string)
	local items = {}
	for _, m in MODES do
		table.insert(items, {
			id = "tackle=" .. m.id .. ":" .. key, label = m.label, detail = m.desc, icon = m.icon,
		})
	end
	return el({ key = "tail", class = "td-tackle", role = "acc.hover" }, {
		ui.node("buttons", { key = "split", variant = "split", size = "sm" }, {
			ui.button(MODE[state.mode].label, {
				key = "go", icon = "play", size = "sm", busy = state.starting ~= nil, title = "Tackle with an agent",
				actions = { click = "tackle=" .. state.mode .. ":" .. key },
			}),
			ui.node("menu", {
				key = "more", icon = "chev", size = "sm", align = "end", title = "Tackle…", items = items,
			}),
		}),
	})
end

local function checkbox(key: string, done: boolean)
	return el({
		key = "box", class = "td-box" .. (if done then " on" else ""), role = "acc.today.box",
		actions = { click = "toggle=" .. key },
	}, { el({ key = "fill", class = "td-fill" }) })
end

local function editor(state, key: string)
	local today = V.today()
	local weekdayOffset = (8 - V.weekday(today)) % 7
	local mon = V.addDays(today, if weekdayOffset == 0 then 7 else weekdayOffset)
	local quick = {
		{ "Today", V.ymd(today) }, { "Tomorrow", V.ymd(V.addDays(today, 1)) },
		{ "Next Mon", V.ymd(mon) }, { "No date", "none" },
	}
	local buttons = { el({ key = "label", tag = "span", class = "td-due-label", text = "Due" }) }
	for _, q in quick do
		table.insert(buttons, ui.button(q[1], { key = "due-" .. q[2], size = "sm", variant = "quiet", actions = { click = "due=" .. q[2] } }))
	end
	return {
		ui.node("input", Field.props(state.edit, { key = "edit", placeholder = "Task title", aria = "Task title" })),
		el({ key = "due", class = "td-due" }, buttons),
		el({ key = "save", class = "td-save" }, {
			ui.button("Save", { key = "ok", size = "sm", variant = "primary", actions = { click = "saveedit" } }),
			ui.button("Cancel", { key = "cancel", size = "sm", variant = "quiet", actions = { click = "canceledit" } }),
		}),
	}
end

local function row(state, section: string, path: string, task, key: string)
	state.index[key] = { path = path, task = task }
	local m = V.meta(task.text)
	local today = V.ymd(state.d)
	local linger = state.linger[key]
	local done = task.done or linger ~= nil
	local editing = state.editing ~= nil and state.editing.key == key
	local live = if done then nil else state.live[runKey(path, task)]

	local tags = {}
	if m.due then
		local tone = if done then "dim" elseif m.due < today then "bad" elseif m.due == today then "warn" else "muted"
		local prefix = if not done and m.due < today then "overdue · " elseif m.due == today then "today · " else ""
		table.insert(tags, chip({ key = "due", class = "due-" .. tone, text = prefix .. m.due }))
	end
	if m.recurring then
		table.insert(tags, chip({ key = "recur", class = "muted", text = if m.rule and m.rule ~= "" then "↻ " .. m.rule else "↻ recurring" }))
	end
	local issue = issueOf(state, task)
	local cached = m.linear and state.linear[m.linear]
	if m.linear then
		local kind = if not issue then "dim" elseif issue.stateType == "started" then "warn"
			elseif issue.stateType == "completed" then "ok" elseif issue.stateType == "canceled" then "dim" else "muted"
		local parts = { el({ key = "id", tag = "span", class = "td-lin-id", text = m.linear }) }
		if issue then
			table.insert(parts, el({ key = "dot", class = "td-dot st-" .. kind }))
			table.insert(parts, el({ key = "state", tag = "span", class = "st-" .. kind, text = issue.state }))
		elseif not cached and state.fetching then
			table.insert(parts, el({ key = "loading", tag = "span", class = "td-loading", text = "loading…" }))
		elseif cached and cached.missing then
			table.insert(parts, el({ key = "missing", tag = "span", class = "dim", text = "not found" }))
		end
		table.insert(tags, chip({ key = "lin", class = "td-lin", actions = { click = "lin=" .. key }, title = "Open in Linear" }, parts))
	end

	local own = trimSeparators(string.gsub(if m.clean ~= "" then m.clean else task.text, "%f[%w_][Ll][Ii][Vv]%-%d+%f[^%w_]", "", 1))
	local title = if issue and (utf8.len(own) or #own) < 3 then issue.title else (if m.clean ~= "" then m.clean else task.text)

	local body
	if editing then
		state.editId = "main." .. section .. "." .. key .. ".body.edit"
		body = el({ key = "body", class = "td-body editing" }, editor(state, key))
	else
		local content = {
			el({
				key = "title", class = "td-title", text = clip(title, 220),
				actions = { click = "edit=" .. key },
			}),
		}
		if #tags > 0 then table.insert(content, el({ key = "tags", class = "td-tags" }, tags)) end
		body = el({ key = "body", class = "td-body" }, content)
	end

	local children = { checkbox(key, done), body }
	if not editing and not done then
		table.insert(children, if live then agentChip(live) else tackleControl(state, key))
	end
	local class = "td-row"
	if done then class ..= " done" end
	if linger == "leaving" then class ..= " leaving" end
	if editing then class ..= " editing" end
	if state.entering[key] then class ..= " td-enter" end
	return el({ key = key, class = class, role = "acc.row" }, children)
end

local function noteRow(state, note, key: string)
	local class = "td-note" .. (if state.entering[key] then " td-enter" else "")
	return el({ key = key, class = class }, {
		el({ key = "dot", class = "td-note-dot" }),
		el({ key = "text", class = "td-note-text", text = note.text }),
	})
end

local function section(state, id: string, title: string, count, rows, fold: string?)
	local folded = fold ~= nil and state.fold[fold]
	local head = {
		el({ key = "title", tag = "span", class = "td-sec-title", text = title }),
	}
	if count ~= nil then table.insert(head, el({ key = "count", tag = "span", class = "td-sec-count", text = tostring(count) })) end
	table.insert(head, el({ key = "grow", class = "td-grow" }))
	if fold then table.insert(head, ui.node("icon", { key = "chev", name = if folded then "chev-r" else "chev" })) end
	local children = {
		el({
			key = "head", class = "td-sec-head" .. (if fold then " foldable" else ""), role = "acc.today.sechead",
			actions = if fold then { click = "fold=" .. fold } else nil,
		}, head),
	}
	if not folded then
		for _, r in rows do table.insert(children, r) end
	end
	return el({ key = "sec-" .. id, class = "td-sec" }, children)
end

local function view(state, cx)
	state.index = {}
	state.editId = nil
	local body = {}
	local total, doneN = 0, 0

	if state.error then
		table.insert(body, el({ key = "error", class = "td-error", text = state.error }))
	end

	if state.exists == false then
		table.insert(body, emptyBlock("none", "No daily note for " .. V.ymd(state.d) .. " yet.",
			ui.button(if state.busy then "Creating…" else "Create today's note", {
				key = "create", size = "sm", variant = "primary", busy = state.busy, actions = { click = "create=day" },
			})))
	elseif state.text ~= nil then
		local path = V.dayPath(state.vault, state.d)
		local all = {}
		for _, t in V.parse(state.text).tasks do
			if t.text ~= "" then table.insert(all, t) end
		end
		local todays, others, doneRows = {}, {}, {}
		for _, t in all do
			if V.isToday(t.section) then table.insert(todays, t) elseif not t.done then table.insert(others, t) end
		end
		local openToday, doneToday = {}, {}
		for _, pair in V.keyed("t", todays, V.keyOf) do
			if not pair[2].done or state.linger[pair[1]] then table.insert(openToday, pair) else table.insert(doneToday, pair) end
		end
		total = #todays
		for _, t in todays do
			if t.done then doneN += 1 end
		end

		local rows = {}
		for _, pair in openToday do table.insert(rows, row(state, "sec-today", path, pair[2], pair[1])) end
		if #rows == 0 then
			table.insert(rows, emptyBlock("none", if #doneToday > 0 then "All clear. Nice work." else "Nothing planned yet."))
		end
		table.insert(body, section(state, "today", "Today", #openToday, rows))

		if #others > 0 then
			local list = {}
			for _, pair in V.keyed("o", others, V.keyOf) do table.insert(list, row(state, "sec-other", path, pair[2], pair[1])) end
			table.insert(body, section(state, "other", "Elsewhere in the note", #others, list))
		end

		if state.prev and #state.prev.open > 0 then
			local pp = V.dayPath(state.vault, state.prev.d)
			local list = {}
			for _, pair in V.keyed("p", state.prev.open, V.keyOf) do table.insert(list, row(state, "sec-prev", pp, pair[2], pair[1])) end
			table.insert(body, section(state, "prev", "Left from " .. state.prev.date, #state.prev.open, list, "prev"))
		end

		local notes = V.keyed("n", V.parseNotes(state.text), function(n) return n.text end)
		local noteRows = {}
		for _, pair in notes do table.insert(noteRows, noteRow(state, pair[2], pair[1])) end
		if #noteRows == 0 then noteRows = { emptyBlock("none", "Things to think about land here, in today's note.") } end
		table.insert(body, section(state, "notes", "Notes", if #notes > 0 then #notes else nil, noteRows))

		if state.week ~= nil then
			local wp = V.weekPath(state.vault, state.d)
			local goals, openGoals = {}, {}
			for _, t in V.parse(state.week).tasks do
				if t.text ~= "" and V.isGoals(t.section) then
					if not t.done then table.insert(openGoals, t) end
					table.insert(goals, t)
				end
			end
			local ordered = {}
			for _, t in goals do
				if not t.done then table.insert(ordered, t) end
			end
			for _, t in goals do
				if t.done then table.insert(ordered, t) end
			end
			local list = {}
			for _, pair in V.keyed("w", ordered, V.keyOf) do table.insert(list, row(state, "sec-week", wp, pair[2], pair[1])) end
			if #list == 0 then list = { emptyBlock("none", "No goals yet. Switch to Goal below to add one.") } end
			table.insert(body, section(state, "week", "This week · " .. V.weekName(state.d), #openGoals, list, "week"))
		elseif state.weekExists == false then
			table.insert(body, section(state, "week", "This week · " .. V.weekName(state.d), nil, {
				emptyBlock("none", "No weekly note yet.", ui.button(if state.busy then "Creating…" else "Create weekly note", {
					key = "create", size = "sm", variant = "primary", busy = state.busy, actions = { click = "create=week" },
				})),
			}, "week"))
		end

		if #doneToday > 0 then
			for _, pair in doneToday do
				table.insert(doneRows, row(state, "sec-done", path, pair[2], (string.gsub(pair[1], "^t%-", "d-"))))
			end
			table.insert(body, section(state, "done", "Done", #doneToday, doneRows, "done"))
		end
	else
		table.insert(body, el({ key = "loading", class = "td-loading-note", text = "Loading…" }))
	end

	local head = {
		el({ key = "head", class = "td-head" }, {
			el({ key = "titles", class = "td-titles" }, {
				el({ key = "day", class = "td-day", text = DAY_NAMES[V.weekday(state.d) + 1] }),
				el({ key = "date", class = "td-date", text = state.d.d .. " " .. MONTHS[state.d.m] }),
			}),
			ui.button("Obsidian", { key = "obsidian", icon = "doc", size = "sm", variant = "quiet", actions = { click = "obsidian" } }),
		}),
	}
	if total > 0 then
		table.insert(head, el({ key = "prog", class = "td-prog" }, {
			ui.node("progress", {
				key = "bar", value = doneN / total, tone = "success", label = doneN .. " of " .. total, role = "acc.today.bar",
			}),
		}))
	end
	local children = {}
	for _, n in head do table.insert(children, n) end
	for _, n in body do table.insert(children, n) end

	local out = { main = ui.node("col", { role = "acc.today.main" }, children) }
	if state.exists == true then
		local items = {}
		for _, k in KINDS do table.insert(items, { id = k.id, label = k.label }) end
		out.dock = ui.node("col", { role = "acc.today.composer" }, {
			ui.node("row", { key = "bar", justify = "between" }, {
				ui.node("tabs", { key = "kind", variant = "segmented", active = state.kind, items = items }),
				el({ key = "hint", tag = "span", class = "td-hint", text = if state.kind == "goal" then V.weekName(state.d) else "↵ to add" }),
			}),
			ui.node("input", Field.props(state.fields[state.kind], {
				key = "input", placeholder = KIND[state.kind].placeholder, aria = KIND[state.kind].label,
			})),
		})
	end
	return out
end

-- ——— events ———

local function focusField(state, cx, which: string, id: string)
	state.focus = which
	Field.focus(cx, id)
end

local function blur(state, cx)
	state.focus = nil
	pcall(function() cx:frame({ { "focus", tern.json.null } }) end)
end

local function onAction(state, cx, act: string, value: string?)
	local function ref(key)
		return state.index[key]
	end
	if act == "toggle" then
		local r = ref(value)
		if r then toggle(state, cx, r, value) end
	elseif act == "edit" then
		local r = ref(value)
		if r and not state.busy then startEdit(state, cx, r, value) end
	elseif act == "saveedit" then
		saveEdit(state, cx, nil)
	elseif act == "canceledit" then
		stopEdit(state)
	elseif act == "due" then
		saveEdit(state, cx, if value == "none" then false else value)
	elseif act == "tackle" then
		local mode, key = string.match(value or "", "^(%w+):(.+)$")
		local r = key and ref(key)
		if r and MODE[mode] then tackle(state, cx, r, mode) end
	elseif act == "agent" then
		local pane = tonumber(value)
		if pane then bridge.send(cx, "focus", { pane = pane }) end
	elseif act == "lin" then
		local r = ref(value)
		if r then
			local m = V.meta(r.task.text)
			local issue = issueOf(state, r.task)
			openUrl(if issue and issue.url ~= "" then issue.url else "https://linear.app/issue/" .. tostring(m.linear))
		end
	elseif act == "fold" then
		state.fold[value] = not state.fold[value]
	elseif act == "obsidian" then
		openInObsidian(state)
	elseif act == "create" then
		createNote(state, cx, value)
	end
end

local def = {
	font = "sans",
	features = { "edit", "undo" },

	init = function(cx, _args, saved)
		local kind = tern.kv.get("today:kind")
		local mode = tern.kv.get("today:mode")
		local state = {
			vault = V.VAULT, d = V.today(), text = nil, week = nil, exists = nil, weekExists = nil, prev = nil,
			busy = false, error = nil, nextLoad = 0, nextPrev = 0, shown = false,
			fold = {
				done = if type(saved) == "table" and saved.done ~= nil then saved.done == true else true,
				week = type(saved) == "table" and saved.week == true,
				prev = type(saved) == "table" and saved.prev == true,
			},
			editing = nil, focus = "composer", editId = nil, starting = nil, lastWork = nil,
			kind = if type(kind) == "string" and KIND[kind] then kind else "task",
			mode = if type(mode) == "string" and MODE[mode] then mode else "do",
			fields = { task = Field.new(), note = Field.new(), goal = Field.new() },
			edit = Field.new(),
			linear = kvTable("today:linear"), fetching = false, linearRetry = 0,
			known = nil, entering = {}, linger = {}, index = {},
			runs = {}, live = {}, resolving = {}, resolveAt = {},
		}
		local cutoff = nowSecs() - RUN_TTL
		for key, run in kvTable("today:runs") do
			if type(run) == "table" and (run.at or 0) > cutoff then state.runs[key] = run end
		end
		timer.blockEvery("today tick", cx, 1000, function() tick(state, cx) end, true)
		return state
	end,

	title = function() return "Tasks" end,

	save = function(state)
		return { done = state.fold.done, week = state.fold.week, prev = state.fold.prev }
	end,

	view = view,

	key = function(state, key, cx)
		local field
		if state.focus == "composer" and state.exists == true then
			field = state.fields[state.kind]
		elseif state.focus == "edit" and state.editing then
			field = state.edit
		else
			return false
		end
		if key.name == "escape" then
			if state.focus == "edit" then stopEdit(state) else blur(state, cx) end
		elseif key.name == "enter" then
			if state.focus == "edit" then saveEdit(state, cx, nil) else addEntry(state, cx, state.kind) end
		elseif key.meta and string.lower(key.name) == "c" then
			local selection = Field.selection(field)
			if selection == "" then return false end
			cx:copy(selection)
		elseif not Field.key(field, key) then
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" then
			if ev.id == COMPOSER_ID then
				focusField(state, cx, "composer", COMPOSER_ID)
			elseif ev.id == state.editId then
				focusField(state, cx, "edit", state.editId)
			end
		elseif ev.ev == "edit" then
			if ev.id == COMPOSER_ID then
				Field.edit(state.fields[state.kind], ev)
			elseif ev.id == state.editId and state.editing then
				Field.edit(state.edit, ev)
			end
		elseif ev.ev == "select" and string.match(ev.id or "", "%.kind$") then
			if KIND[ev.item] then
				state.kind = ev.item
				tern.kv.set("today:kind", ev.item)
				timer.later("today focus composer", 16, function() focusField(state, cx, "composer", COMPOSER_ID) end)
			end
		elseif ev.ev == "action" then
			local act, value = ev.act, ev.value
			if value == nil then
				local a, v = string.match(act or "", "^([^=]+)=(.*)$")
				if a then act, value = a, v end
			end
			onAction(state, cx, act, value)
		end
	end,
}

return { today = def }
