--!nonstrict
local util = require("../../lib/util")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local facts = require("../../lib/facts")
local bridge = require("../../lib/bridge")
local v = require("./view")
local ui = tern.ui
local M = {}
local BASE = "http://127.0.0.1:4000"
local ROOT = util.HOME .. "/Documents/symphony-workspaces/entropy"
local DIR = util.HOME .. "/Documents/livestorm/symphony-local"
local STAGES = { "Plan", "Build", "PR & CI", "Handoff" }
local function idOf(r) return r.issue_identifier or r.issue_id end
local function kv(key) return tern.kv.get("automation:sym-" .. key) or {} end
local function save(s, key) tern.kv.set("automation:sym-" .. key, s[key]) end
local function live(s)
	local out = {}
	for _, group in { "running", "retrying", "blocked" } do for _, r in (s.state and s.state[group] or {}) do table.insert(out, r) end end
	return out
end
local function exists(list, id)
	for _, r in list or {} do if idOf(r) == id then return true end end
	return false
end
local function term()
	for _, p in facts.read().panes do
		if (p.running and p.running:find("symphony-livestorm", 1, true)) or p.title == "symphony" then return p end
	end
	return nil
end
local function ping(s, title, body, level)
	if not timer.alive(s.cx.pane) then return end
	s.cx:toast(level or "info", "Symphony · " .. title, body)
	proc.run("Symphony notification", { "osascript", "-e", 'on run argv\ndisplay notification (item 2 of argv) with title "Symphony" subtitle (item 1 of argv)\nend run', title, body }, { timeout_ms = 5000 })
end
local function ci(checks)
	if not checks or #checks == 0 then return "none" end
	local pending = false
	for _, c in checks do
		local value = string.upper(c.conclusion or c.state or c.status or "")
		if table.find({ "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED" }, value) then return "failing" end
		if table.find({ "PENDING", "IN_PROGRESS", "QUEUED", "EXPECTED", "WAITING", "" }, value) then pending = true end
	end
	return if pending then "running" else "green"
end
local function stage(s, id)
	local st, linear = s.stages[id], s.linear[id] or {}
	local state = string.lower(linear.state or "")
	if state:find("review") or state:find("done") or state:find("merged") or state:find("closed") then return 4, linear.state end
	if st then
		for _, p in st.prs or {} do if p.state == "OPEN" or p.state == "MERGED" then return 3, "#" .. tostring(p.number) .. (if p.draft then " draft" else "") .. " · " .. (if p.ci == "none" then "no checks yet" else "CI " .. p.ci) end end
		if st.commits > 0 then return 2, util.plural(st.commits, "commit") end
	end
	return 1, if st then "reading the ticket, planning PRs" else "Looking at the workspace…"
end
local function say(raw)
	local message = v.one(raw)
	local lower = message:lower()
	if message == "" or lower:find("token usage updated", 1, true) or lower:find("rate limits updated", 1, true) or lower:match("^account ") or lower:find("auth token", 1, true) or lower:match("^[a-z]+/[a-zA-Z/]+$") then return nil end
	local action, kind = lower:match("^item (started): ([a-z ]+)")
	if not action then action, kind = lower:match("^item (completed): ([a-z ]+)") end
	if action then
		local running = action == "started"
		for _, item in { { "command", "Running a command", "Ran a command" }, { "reasoning", "Thinking", "Thought it through" }, { "file change", "Editing files", "Edited files" }, { "agent message", "Writing", "Wrote an update" }, { "tool", "Using a tool", "Used a tool" }, { "web search", "Searching the web", "Searched the web" }, { "todo", "Planning", "Updated the plan" }, { "plan", "Planning", "Updated the plan" }, { "compaction", "Compacting its context", "Compacted its context" } } do
			if kind:find(item[1], 1, true) then return { text = if running then item[2] else item[3], live = running } end
		end
		return { text = (if running then "Started " else "Finished ") .. kind, live = running }
	end
	if lower:find("streaming") or lower:find(" update") or lower:find("section added") then
		for _, item in { { "agent message", "Writing" }, { "reasoning", "Thinking" }, { "command output", "Running a command" }, { "file change", "Editing files" }, { "plan", "Planning" } } do
			if lower:sub(1, #item[1]) == item[1] then return { text = item[2], live = true, detail = message:match(":%s*(.*)$") } end
		end
	end
	if lower:match("^turn diff updated") then local n = message:match("%((%d+) lines%)"); return { text = if n then "Diff at " .. n .. " lines" else "Diff updated" } end
	if lower:match("^plan updated") then local n = message:match("%((%d+) steps%)"); return { text = "Plan updated" .. (if n then " · " .. n .. " steps" else "") } end
	if lower:match("^turn started") then return { text = "Started a turn", live = true } end
	if lower:match("^turn completed") then return { text = "Finished the turn" } end
	if lower:match("^thread started") or lower:match("^session started") or lower:match("^task started") then return { text = "Session started" } end
	if lower:match("^mcp startup") then return { text = "Starting its tools", live = true } end
	if lower:find("approval requested") or lower:find("requires user input") or lower:find("waiting for user input") then return { text = "Needs you", detail = message, tone = "warning" } end
	local plain = message:gsub("%s*%([^)]*%)", "")
	return { text = plain:sub(1, 1):upper() .. plain:sub(2), tone = if lower:find("failed") or lower:find("error") or lower:find("cancelled") then "error" else nil }
end
local function record(s, st)
	for _, r in st.running or {} do
		local id, event = idOf(r), say(r.last_message)
		if not id or not event or not r.last_event_at then continue end
		local feed = s.feed[id] or {}; s.feed[id] = feed
		local key = r.last_event_at .. "|" .. v.one(r.last_message)
		if feed[1] and feed[1].key == key then continue end
		if feed[1] and feed[1].text == event.text then
			local top = feed[1]; top.key, top.at, top.live, top.detail, top.n = key, r.last_event_at, event.live, event.detail or top.detail, top.n + 1
		else
			s.seq += 1; event.key, event.at, event.n, event.seq = key, r.last_event_at, 1, s.seq
			table.insert(feed, 1, event); if #feed > 30 then table.remove(feed) end
		end
	end
end
local function transitions(s, before, after)
	if not before then return end
	for _, r in before.running or {} do
		local id = idOf(r)
		if exists(after.running, id) then continue end
		local outcome = if exists(after.blocked, id) then "blocked" elseif exists(after.retrying, id) then "retrying" else "finished"
		s.history[id] = { id = id, ended = os.time() * 1000, started = r.started_at, turns = r.turn_count or 0, tokens = r.tokens and r.tokens.total_tokens or 0, outcome = outcome, workspace = r.workspace_path }
		save(s, "history")
		if outcome == "finished" then local i, note = stage(s, id); ping(s, id .. " finished", v.clip((s.linear[id] or {}).title or id, 70) .. " · " .. STAGES[i] .. " (" .. note .. ") · " .. v.token(s.history[id].tokens) .. " tokens", "success") end
	end
	for _, r in after.blocked or {} do if not exists(before.blocked, idOf(r)) then ping(s, idOf(r) .. " is blocked", v.clip(r.error or r.last_message or "It needs you.", 140), "warning") end end
end
local function syncLinear(s)
	if s.fetching or tern.now() < s.linearRetry then return end
	local ids, seen = {}, {}
	for _, r in live(s) do seen[idOf(r)] = true end
	local function add(id, isLive)
		if not id:match("^LIV%-%d+$") or table.find(ids, id) then return end
		if not s.linear[id] or os.time() * 1000 - (s.linear[id].at or 0) > (if isLive then 300000 else 3600000) then table.insert(ids, id) end
	end
	for id in seen do add(id, true) end
	for _, id in s.disk do add(id, false); if #ids >= 40 then break end end
	if #ids == 0 then return end
	s.fetching = true
	local argv = { "/bin/sh", util.HOME .. "/nix-config/config/herdr-app/mods/acc-today/linear-issue.sh" }
	for _, id in ids do table.insert(argv, id) end
	proc.json("Symphony Linear", argv, { timeout_ms = 60000 }, function(result, err)
		if not timer.alive(s.cx.pane) then return end
		s.fetching = false
		if err or not result.data or not result.data.issues then s.linearRetry = tern.now() + 300000 else
			for _, id in ids do s.linear[id] = { missing = true, at = os.time() * 1000 } end
			for _, issue in result.data.issues.nodes or {} do s.linear[issue.identifier] = { title = issue.title, state = issue.state and issue.state.name or "", url = issue.url, at = os.time() * 1000 } end
			save(s, "linear")
		end
		s.cx:render()
	end)
end
local function prsOf(s, id, callback)
	proc.json("Symphony PRs", { "gh", "pr", "list", "--repo", "livestorm/entropy", "--state", "all", "--search", id .. " in:title", "--limit", "10", "--json", "number,title,url,state,isDraft,statusCheckRollup" }, { timeout_ms = 20000 }, function(result, err)
		if not timer.alive(s.cx.pane) then return end
		if err then callback(nil); return end
		local out = {}
		for _, p in result do
			if p.title:upper():find("%f[%w]" .. id:gsub("%-", "%%-") .. "%f[^%w]") then table.insert(out, { number = p.number, title = p.title, url = p.url, state = p.state, draft = p.isDraft, ci = ci(p.statusCheckRollup) }) end
		end
		callback(out)
	end)
end
local function loadStages(s)
	if s.stageBusy then return end
	local items = live(s); if #items == 0 then return end
	s.stageBusy = true
	local index = 0
	local function nextItem()
		if not timer.alive(s.cx.pane) then return end
		index += 1
		local r = items[index]
		if not r then s.stageBusy = false; save(s, "prs"); s.cx:render(); return end
		local id = idOf(r); local ws = r.workspace_path or ROOT .. "/" .. id
		local before = s.stages[id]
		proc.run("Symphony commits", { "git", "-C", ws, "rev-list", "--count", "--branches", "--not", "origin/main" }, { timeout_ms = 8000 }, function(g)
			if not timer.alive(s.cx.pane) then return end
			proc.sh("Symphony diff", 'base=$(git -C "$1" merge-base origin/main HEAD) && git -C "$1" diff --shortstat "$base"', { ws }, { timeout_ms = 8000 }, function(d)
				if not timer.alive(s.cx.pane) then return end
				prsOf(s, id, function(prs)
					prs = prs or (before and before.prs) or {}
					local diff = if d.status == 0 then { files = tonumber(d.stdout:match("(%d+) files? changed")) or 0, add = tonumber(d.stdout:match("(%d+) insertions?")) or 0, del = tonumber(d.stdout:match("(%d+) deletions?")) or 0 } else nil
					s.stages[id] = { commits = tonumber(util.trim(g.stdout)) or 0, diff = diff, prs = prs, at = os.time() * 1000 }
					s.prs[id] = { list = prs, at = os.time() * 1000 }
					if before then
						for _, p in prs do
							local old; for _, previous in before.prs or {} do if previous.number == p.number then old = previous; break end end
							if not old then ping(s, id .. " opened #" .. tostring(p.number), v.clip(p.title, 120), "success") elseif old.ci ~= "failing" and p.ci == "failing" then ping(s, "CI failing on #" .. tostring(p.number), id .. " · " .. v.clip(p.title, 100), "error") end
						end
					end
					nextItem()
				end)
			end)
		end)
	end
	nextItem()
end
local function loadPast(s)
	if s.pastBusy then return end
	s.pastBusy = true
	local ids = {}; for _, id in s.disk do if id:match("^LIV%-%d+$") and not exists(live(s), id) and (not s.prs[id] or os.time() * 1000 - s.prs[id].at >= 1800000) then table.insert(ids, id) end end
	local i = 0
	local function nextItem()
		i += 1; local id = ids[i]
		if not id then s.pastBusy = false; save(s, "prs"); s.cx:render(); return end
		prsOf(s, id, function(prs)
			if prs then s.prs[id] = { list = prs, at = os.time() * 1000 }; nextItem() else s.pastBusy = false end
		end)
	end
	nextItem()
end
local function scan(s)
	proc.json("Symphony workspaces", { "python3", tern.plugin.dir .. "/mods/automation/files.py", "scan" }, { stdin = tern.json.encode({ root = ROOT }), timeout_ms = 8000 }, function(result)
		if not timer.alive(s.cx.pane) then return end
		s.disk = result or {}; syncLinear(s); s.cx:render()
	end)
end
local function poll(s)
	if s.polling then return end
	s.polling = true
	tern.fetch(BASE .. "/api/v1/state", { timeout_ms = 6000 }, function(r)
		if not timer.alive(s.cx.pane) then return end
		s.polling = false
		local st = if not r.error and r.status == 200 then util.decodeJson(r.body) else nil
		if st and not st.error then
			transitions(s, s.state, st); s.state, s.offline = st, false; record(s, st)
			local total = 0; for _, run in st.running or {} do total += run.tokens and run.tokens.total_tokens or 0 end
			local now = tern.now()
			if s.lastTotal and now > s.lastAt and total >= s.lastTotal then s.rate = s.rate * 0.6 + (total - s.lastTotal) / ((now - s.lastAt) / 1000) * 0.4 end
			s.lastAt, s.lastTotal = now, total
			syncLinear(s)
		else s.state, s.offline, s.rate, s.lastTotal = nil, true, 0, nil end
		s.cx:render()
	end)
end
function M.new(cx, shown)
	local s = { cx = cx, shown = shown, offline = nil, disk = {}, feed = {}, seq = 0, rate = 0, lastAt = 0, linear = kv("linear"), history = kv("history"), prs = kv("prs"), stages = {}, linearRetry = 0, next = 0, diskNext = 0, stageNext = 0, pastNext = 0, showAll = false }
	timer.blockEvery("Symphony poll", cx, 500, function()
		local now, visible = tern.now(), shown()
		if visible and not s.wasShown then s.next = 0 end
		s.wasShown = visible
		if s.armed and now > s.armed.expires then s.armed = nil; cx:render() end
		if now >= s.next then s.next = now + (if visible then (if s.offline then 5000 else 2500) else 15000); poll(s) end
		if visible and now >= s.diskNext then s.diskNext = now + 30000; scan(s) end
		if now >= s.stageNext and #live(s) > 0 then s.stageNext = now + (if visible then 30000 else 60000); loadStages(s) end
		if visible and now >= s.pastNext and #s.disk > 0 then s.pastNext = now + 600000; loadPast(s) end
	end, true)
	return s
end
local function prChip(p)
	local tone = if p.state == "MERGED" then "accent" elseif p.state == "CLOSED" then "muted" elseif p.ci == "failing" then "error" elseif p.ci == "green" then "success" else "warning"
	local label = "#" .. tostring(p.number) .. " " .. (if p.state == "MERGED" then "merged" elseif p.state == "CLOSED" then "closed" elseif p.draft then "draft" else "open") .. (if p.state == "OPEN" and p.ci ~= "none" then " · CI " .. p.ci else "")
	return ui.node("button", { text = label, size = "sm", variant = "quiet", tone = tone, actions = { click = "sy-url=" .. p.url } })
end
local function linearButton(s, id) return v.button(id, "sy-url", (s.linear[id] or {}).url or "https://linear.app/issue/" .. id) end
local function prRow(prs)
	local out = {}; for i = 1, math.min(3, #prs) do table.insert(out, prChip(prs[i])) end
	return v.row(out)
end
local function stepper(index)
	local out = {}
	for i, label in STAGES do table.insert(out, v.node("col", label, "stage", { v.text("", if i < index then "stage-done" elseif i == index then "stage-current" else "stage-future"), v.text((if i < index then "✓ " else "") .. label, "stage-label") }, { grow = 1, basis = 0.25, gap = "sm" })) end
	return v.row(out, { gap = "sm" })
end
local function activity(s, id, quiet)
	local out = {}; local feed = s.feed[id] or {}
	if #feed == 0 then return v.row({ v.dot("pending", true), v.text("Waiting for its first move…", "meta") }) end
	for i = 1, math.min(5, #feed) do
		local e = feed[i]
		local children = { v.row({ v.dot(e.tone or (if i == 1 then "pending" else "muted"), i == 1 and e.live and not quiet), v.text(e.text, if i == 1 then "activity-head" else "summary", { grow = 1 }), v.text((if e.n > 1 then "×" .. tostring(e.n) .. " · " else "") .. v.ago(e.at), "meta") }) }
		if i == 1 and e.detail then table.insert(children, v.text(v.clip(e.detail, 180), "summary")) end
		table.insert(out, v.node("col", tostring(e.seq), "activity", children, { gap = "xs" }))
	end
	return v.node("col", "feed", "feed", out, { gap = "sm" })
end
local function hero(s, r)
	local id = idOf(r); local linear, st = s.linear[id] or {}, s.stages[id]
	local index, note = stage(s, id)
	local diff = st and st.diff
	local age = os.time() - (v.time(r.last_event_at) or os.time())
	local elapsed = os.time() - (v.time(r.started_at) or os.time())
	local children = {
		v.row({ linearButton(s, id), v.text(linear.state or "", "meta", { grow = 1 }), v.text(v.duration(elapsed), "meta") }),
		v.text(linear.title or (if s.fetching then "Loading the ticket…" else id), "hero-title"), stepper(index),
		if st and #st.prs > 0 then prRow(st.prs) else v.text(note, "summary"),
		v.node("col", "now", "now", { v.row({ v.text("NOW", "section", { grow = 1 }), v.text(if age > 90 then "quiet for " .. v.duration(age) else "", "meta") }), activity(s, id, age > 90) }, { gap = "md" }),
		v.row({ v.text("Turn  " .. tostring(math.min(r.turn_count or 0, 20)) .. "/20", "stat"), v.text("Tokens  " .. v.token(r.tokens and r.tokens.total_tokens), "stat"), v.text("Rate  " .. (if s.rate >= 1 then v.token(s.rate) .. "/s" else "–"), "stat"), v.text("Changes  " .. (if diff then "+" .. v.token(diff.add) .. " −" .. v.token(diff.del) else "–"), "stat") }),
		v.row({ v.button("Open workspace", "sy-workspace", id), v.text(if diff and diff.files > 0 then util.plural(diff.files, "file") .. " · " .. util.plural(st.commits, "commit") else "", "meta") }),
	}
	return v.card("run-" .. id, children, "pending")
end
local function issueCard(s, r, blocked)
	local id = idOf(r); local linear = s.linear[id] or {}; local index = stage(s, id)
	local due = (v.time(r.due_at) or os.time()) - os.time()
	local label = if blocked then "blocked" else "attempt " .. tostring(r.attempt or "?") .. " · " .. (if due > 0 then "in " .. v.duration(due) else "now")
	local children = { v.row({ linearButton(s, id), v.text(label, "meta", { grow = 1 }), v.button("Workspace", "sy-workspace", id) }) }
	if linear.title then table.insert(children, v.text(linear.title, "title")) end
	if r.error or (blocked and r.last_message) then table.insert(children, v.text(v.clip(r.error or r.last_message, 220), "summary")) end
	if s.stages[id] then table.insert(children, v.text(STAGES[index], "meta")); table.insert(children, prRow(s.stages[id].prs)) end
	return v.card((if blocked then "blocked-" else "retry-") .. id, children, "warning")
end
function M.view(s)
	local st, tm = s.state, term()
	local mode = if s.offline ~= false or not st then (if s.offline == nil then "loading" else "offline") elseif #(st.running or {}) > 0 then "work" elseif #(st.blocked or {}) > 0 then "blocked" elseif #(st.retrying or {}) > 0 then "wait" else "idle"
	local first = st and ((st.retrying or {})[1] or (st.blocked or {})[1])
	local title = ({ work = "Working", wait = "Retrying " .. (first and idOf(first) or ""), blocked = (first and idOf(first) or "") .. " is blocked", idle = "Watching Linear", offline = "Symphony is off", loading = "Connecting…" })[mode]
	local retryIn = first and (v.time(first.due_at) or os.time()) - os.time() or 0
	local subtitle = ({ work = tostring(st and #(st.running or {}) or 0) .. " tickets in flight" .. (if s.rate >= 1 then " · " .. v.token(s.rate) .. " tokens/s" else ""), wait = "attempt " .. tostring(first and first.attempt or "?") .. " · next " .. (if retryIn > 0 then "in " .. v.duration(retryIn) else "now"), blocked = "It needs you before it can go on", idle = "Picks up LIV tickets labelled symphony and assigned to you", offline = "Nothing is polling Linear", loading = "" })[mode]
	local controls = {}
	if s.offline == true and not tm then table.insert(controls, v.button(if s.armed and s.armed.key == "start" then "Confirm" else "Start", "sy-start")) end
	if s.offline == false then table.insert(controls, v.button(if s.busy then "…" else "Poll", "sy-refresh")) end
	if tm then table.insert(controls, v.button(if s.armed and s.armed.key == "stop" then "Confirm" else "Stop", "sy-stop")) end
	local out = { v.card("sym-header", { v.row({ v.dot(if mode == "work" then "pending" elseif mode == "wait" or mode == "blocked" then "warning" elseif mode == "idle" then "success" else "muted", mode == "work" or mode == "wait"), v.text(title, "title", { grow = 1 }), v.row(controls) }), v.text(subtitle, "summary") }) }
	for _, r in st and st.running or {} do table.insert(out, hero(s, r)) end
	if st then
		local totals, limits = st.codex_totals, st.rate_limits
		if totals or limits then
			local children = { v.row({ v.text("Usage", "title", { grow = 1 }), v.text("since Symphony started", "meta") }) }
			if totals then table.insert(children, v.row({ v.text("Tokens  " .. v.token(totals.total_tokens), "stat"), v.text("In / out  " .. v.token(totals.input_tokens) .. " / " .. v.token(totals.output_tokens), "stat"), v.text("Agent time  " .. v.duration(totals.seconds_running or 0), "stat") })) end
			for _, pair in { { "Codex 5h", limits and limits.primary }, { "Week", limits and limits.secondary } } do
				if pair[2] then local pct = tonumber(pair[2].usedPercent) or 0; table.insert(children, v.row({ v.text(pair[1], "meta"), ui.node("meter", { value = math.clamp(pct / 100, 0, 1), label = { ui.span(tostring(math.floor(pct + 0.5)) .. "%") }, tone = if pct > 85 then "error" elseif pct > 60 then "warning" else "success", grow = 1 }) })) end
			end
			table.insert(out, v.card("usage", children))
		end
		for _, pair in { { "Blocked", st.blocked or {}, true }, { "Retrying", st.retrying or {}, false } } do
			if #pair[2] > 0 then table.insert(out, v.section(pair[1], #pair[2])); for _, r in pair[2] do table.insert(out, issueCard(s, r, pair[3])) end end
		end
	end
	local past, history, seen = {}, {}, {}
	for _, h in s.history do table.insert(history, h) end
	table.sort(history, function(a, b) return (a.ended or 0) > (b.ended or 0) end)
	for _, h in history do if not exists(live(s), h.id) and not seen[h.id] then table.insert(past, h.id); seen[h.id] = true end end
	for _, id in s.disk do if not exists(live(s), id) and not seen[id] then table.insert(past, id); seen[id] = true end end
	if #past > 0 then
		table.insert(out, v.section("Recent runs", #past))
		for i = 1, (if s.showAll then #past else math.min(5, #past)) do
			local id = past[i]; local l, h, prs = s.linear[id] or {}, s.history[id], s.prs[id]
			local chips = { linearButton(s, id) }; if l.state then table.insert(chips, v.text(l.state, "meta")) end
			for p = 1, math.min(3, prs and #prs.list or 0) do table.insert(chips, prChip(prs.list[p])) end
			if prs and #prs.list == 0 then table.insert(chips, v.text("no PR", "meta")) end
			local children = { v.text(l.title or (if l.missing then "Ticket not found" else "…"), "title"), v.row(chips), v.button("Open workspace", "sy-workspace", id) }
			if h then table.insert(children, v.text((if h.outcome == "blocked" then "blocked " else "ended ") .. v.ago(h.ended) .. (if h.started then " · " .. v.duration(h.ended / 1000 - (v.time(h.started) or h.ended / 1000)) else "") .. " · " .. v.token(h.tokens) .. " tokens · " .. tostring(h.turns or 0) .. " turns", "meta")) end
			table.insert(out, v.card("past-" .. id, children))
		end
		if #past > 5 then table.insert(out, v.button(if s.showAll then "Show fewer" else "Show " .. tostring(#past - 5) .. " more", "sy-more")) end
	end
	return out
end
function M.event(s, act, id, cx)
	local function arm(key)
		if not s.armed or s.armed.key ~= key then s.armed = { key = key, expires = tern.now() + 5000 }; return false end
		s.armed = nil; return true
	end
	if act == "sy-start" then
		if term() or s.offline == false or not arm("start") then return end
		bridge.send(cx, "tab", { cwd = DIR, argv = { DIR .. "/symphony-livestorm", "--i-understand-that-this-will-be-running-without-the-usual-guardrails" }, name = "symphony" })
		cx:toast("info", "Symphony starting", "It shows up here once its API answers."); s.next = 0
	elseif act == "sy-stop" then
		local tm = term(); if not tm or not arm("stop") then return end
		bridge.send(cx, "run", { pane = tm.pane, text = "\3" }); cx:toast("info", "Symphony: stop requested"); s.next = 0
	elseif act == "sy-refresh" then
		if s.busy then return end
		s.busy = true
		tern.fetch(BASE .. "/api/v1/refresh", { method = "POST", timeout_ms = 6000 }, function(r)
			if not timer.alive(cx.pane) then return end
			if r.error or r.status < 200 or r.status >= 300 then cx:toast("error", "Symphony refresh failed", r.error or "HTTP " .. tostring(r.status)) end
			s.busy, s.next = false, 0; cx:render()
		end)
	elseif act == "sy-url" then bridge.send(cx, "open", { url = id })
	elseif act == "sy-workspace" then
		local workspace = s.history[id] and s.history[id].workspace
		for _, r in live(s) do if idOf(r) == id then workspace = r.workspace_path; break end end
		workspace = workspace or ROOT .. "/" .. id
		for _, p in facts.read().panes do if p.cwd == workspace then bridge.send(cx, "focus", { pane = p.pane }); return end end
		bridge.send(cx, "tab", { cwd = workspace, name = id })
	elseif act == "sy-more" then s.showAll = not s.showAll end
end
return M
