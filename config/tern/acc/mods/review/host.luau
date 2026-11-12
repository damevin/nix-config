--!nonstrict
-- Pull request panels. `prs` lists your PRs grouped into stacks; `review` lists
-- the PRs waiting on you. Both run the same code, as herdr's acc-review did.
local bridge = require("../../lib/bridge")
local data = require("./data")
local facts = require("../../lib/facts")
local field = require("../../lib/field")
local model = require("./model")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local util = require("../../lib/util")
local view = require("./view")
local wt = require("../../lib/wt")

local REPO = data.REPO

local PATCH_COMMENT = [[
import json, os, sys
file, index, value = sys.argv[1], int(sys.argv[2]), sys.argv[3]
d = json.load(open(file))
c = d["comments"][index]
if value:
    c["edited"] = value
else:
    c.pop("edited", None)
tmp = file + ".tmp"
json.dump(d, open(tmp, "w"), indent=2, ensure_ascii=False)
os.replace(tmp, file)
]]

local SCAN = [[cd "$1" 2>/dev/null && ls *.eli5.md 2>/dev/null; for f in *.review.json; do [ -f "$f" ] && jq -c '{pr, sha, status, n: ((.comments // []) | length), blockers: ([.comments[]? | select(.label == "blocker")] | length)}' "$f"; done]]

local function alive(S): boolean
	return timer.alive(S.cx.pane)
end

local function render(S)
	if alive(S) then S.cx:render() end
end

local function toast(S, level: string, title: string, sub: string?)
	S.cx:toast(level, title, sub)
end

local function failure(r): string
	local out = util.trim(if r.stderr ~= "" then r.stderr else r.stdout)
	return util.truncate(out, 240)
end

local function cached(S, path: string): string?
	if S.cache[path] == nil then S.cache[path] = util.readFile(path) or false end
	return S.cache[path] or nil
end

local function loadFiles(S, pr)
	local id = data.idOf(pr)
	cached(S, data.OUT .. "/" .. id .. ".eli5.md")
	cached(S, data.OUT .. "/" .. id .. ".review.json")
end

-- Facts come from the window; a changed set of agents asks for a render.
local function refreshFacts(S): boolean
	local f = facts.read()
	S.panes, S.agents, S.focused = f.panes or {}, f.agents or {}, f.focused
	local sig = {}
	for _, a in S.agents do table.insert(sig, tostring(a.cwd) .. ":" .. tostring(a.state)) end
	for _, p in S.panes do
		if p.running and string.find(p.running, "review.py", 1, true) then table.insert(sig, "r" .. p.pane) end
	end
	table.sort(sig)
	local joined = table.concat(sig, "|")
	local changed = joined ~= S.factsSig
	S.factsSig = joined
	return changed
end

-- Whether this panel is on the shown tab (an unknown pane counts as shown).
local function visible(S): boolean
	for _, p in S.panes do
		if p.pane == S.cx.pane and p.block == S.kind then
			if p.parked then return false end
			return S.focused == nil or S.focused.tab == nil or p.tab == S.focused.tab
		end
	end
	return true
end

local function scan(S)
	proc.sh("review files", SCAN, { data.OUT }, { timeout_ms = 5000 }, function(r)
		if not alive(S) or r.status ~= 0 and r.stdout == "" then return end
		local eli5, review, lines = {}, {}, {}
		for _, line in util.lines(r.stdout) do
			table.insert(lines, line)
			if string.sub(line, -8) == ".eli5.md" then
				eli5[string.sub(line, 1, -9)] = true
			else
				local x = util.decodeJson(line)
				if x and x.pr and x.sha then review[x.pr .. "-" .. string.sub(x.sha, 1, 7)] = x end
			end
		end
		table.sort(lines)
		local sig = table.concat(lines, "\n")
		S.files = { eli5 = eli5, review = review }
		if sig ~= S.filesSig then
			S.filesSig = sig
			S.cache = {}
			local pr = model.find(S, S.open)
			if pr then loadFiles(S, pr) end
			render(S)
		end
	end)
end

local function finishLoad(S, listA, listB, errA)
	S.loading, S.refreshing = false, false
	if errA then
		S.error = util.truncate(errA, 160)
	else
		local byNumber = {}
		for _, list in { listA or {}, listB or {} } do
			for _, pr in list do byNumber[pr.number] = pr end
		end
		local prs = {}
		for _, pr in byNumber do table.insert(prs, pr) end
		table.sort(prs, function(x, y) return (x.createdAt or "") < (y.createdAt or "") end)
		S.prs = prs
		S.error = nil
		if S.mode == "review" then tern.kv.set("shared:review.count", #model.active(S)) end
		pcall(tern.kv.set, "review:" .. S.mode, { prs = prs, merge = S.merge })
	end
	S.loaded = true
	wt.list(data.CHECKOUT, function(trees)
		local map = {}
		for _, t in (trees or {}) do
			if t.branch then map[t.branch] = t.path end
		end
		S.trees = map
		if alive(S) then
			scan(S)
			render(S)
		end
	end)
end

local function ghList(search: string, cb)
	proc.json("gh pr list", {
		"gh", "pr", "list", "-R", REPO, "--state", "open", "--search", search, "--json", data.FIELDS, "--limit", "60",
	}, { timeout_ms = 30000 }, cb)
end

local function load(S)
	if S.loading then return end
	S.loading = true
	local a, b, errA, pending = nil, nil, nil, 0
	local function done()
		pending -= 1
		if pending == 0 and alive(S) then finishLoad(S, a, b, errA) end
	end
	if S.mode == "mine" then
		pending = 1
		ghList("author:@me", function(list, err)
			a, errA = list, err
			done()
		end)
		if S.merge == nil then
			pending += 1
			proc.json("gh repo view", {
				"gh", "repo", "view", REPO, "--json", "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,viewerPermission",
			}, { timeout_ms = 20000 }, function(m)
				m = m or {}
				if data.WRITE[m.viewerPermission] then
					S.merge = if m.squashMergeAllowed then "--squash"
						elseif m.mergeCommitAllowed then "--merge"
						elseif m.rebaseMergeAllowed then "--rebase" else ""
				else
					S.merge = ""
				end
				done()
			end)
		end
	else
		pending = 2
		ghList("review-requested:@me", function(list, err)
			a, errA = list, err
			done()
		end)
		ghList("assignee:@me -author:@me", function(list)
			b = list
			done()
		end)
	end
end

local function explain(S, pr)
	local key = data.idOf(pr)
	if S.files.eli5[key] or S.explaining[key] then return end
	S.explaining[key] = true
	render(S)
	proc.run("eli5", { "python3", data.DIR .. "/review.py", "eli5", tostring(pr.number) },
		{ cwd = data.DIR, timeout_ms = 180000 }, function(r)
			if r.status ~= 0 then
				toast(S, "error", "ELI5 failed for #" .. pr.number, util.truncate(util.trim(if r.stderr ~= "" then r.stderr else r.stdout), 200))
			end
			S.explaining[key] = nil
			if alive(S) then scan(S) end
			render(S)
		end)
end

local function loadConvo(S, pr)
	proc.json("pr comments", { "gh", "pr", "view", tostring(pr.number), "-R", REPO, "--json", "comments,reviews" },
		{ timeout_ms = 30000 }, function(d, err)
			if not alive(S) then return end
			if not d then
				S.convo[pr.number] = { error = util.truncate((string.match(err or "", "^[^\n]*")) or "", 160) }
			else
				local items = {}
				for _, c in (d.comments or {}) do
					table.insert(items, {
						who = if c.author then c.author.login else "?", at = c.createdAt, body = c.body or "", url = c.url,
					})
				end
				for _, v in (d.reviews or {}) do
					if util.trim(v.body or "") ~= "" or v.state ~= "COMMENTED" then
						table.insert(items, {
							who = if v.author then v.author.login else "?", at = v.submittedAt, body = v.body or "",
							state = v.state, url = pr.url,
						})
					end
				end
				for _, x in items do x.bot = data.isBot(x.who) end
				table.sort(items, function(x, y) return (x.at or "") < (y.at or "") end)
				S.convo[pr.number] = items
			end
			render(S)
		end)
end

local function loadThreads(S, pr)
	proc.json("pr threads", {
		"gh", "api", "graphql", "-f", "query=" .. data.THREADS_QUERY, "-f", "url=" .. pr.url,
	}, { timeout_ms = 45000 }, function(d, err)
		if not alive(S) then return end
		local nodes = d and d.data and d.data.resource and d.data.resource.reviewThreads and d.data.resource.reviewThreads.nodes
		if not nodes then
			S.threads[pr.number] = { error = util.truncate((string.match(err or "no threads", "^[^\n]*")) or "", 160) }
		else
			local out = {}
			for _, x in nodes do
				local c = x.comments and x.comments.nodes and x.comments.nodes[1]
				if not x.isResolved and not x.isOutdated and c then
					local who = if c.author then c.author.login else "unknown"
					local lower = string.lower(who)
					table.insert(out, {
						path = x.path or "", line = x.line, who = who,
						bot = string.find(lower, "greptile", 1, true) ~= nil or string.find(lower, "[bot]", 1, true) ~= nil,
						body = c.body or "", url = c.url,
					})
				end
			end
			S.threads[pr.number] = out
		end
		render(S)
	end)
end

local function openPr(S, pr)
	S.open = pr.number
	S.tab = if S.mode == "mine" then "desc" else "eli5"
	loadFiles(S, pr)
	render(S)
	if S.mode == "mine" then loadThreads(S, pr) else explain(S, pr) end
	loadConvo(S, pr)
end

-- A panel restored with a PR open (a plugin reload) refetches that PR's detail.
local function resume(S)
	local pr = model.find(S, S.open)
	if not pr then return end
	loadFiles(S, pr)
	if S.mode == "mine" and S.threads[pr.number] == nil then loadThreads(S, pr) end
	if S.convo[pr.number] == nil then loadConvo(S, pr) end
end

local function busy(S, key: string?, ms: number?)
	S.busy = key
	render(S)
	if key and ms then
		timer.later("review busy", ms, function()
			if S.busy == key then
				S.busy = nil
				render(S)
			end
		end)
	end
end

local function arm(S, key)
	S.armed = key
	render(S)
	timer.later("review disarm", 6000, function()
		if S.armed == key then
			S.armed = nil
			render(S)
		end
	end)
end

local function copy(S, text: string, key: string)
	S.cx:copy(text)
	S.copied = key
	render(S)
	timer.later("review copied", 1500, function()
		if S.copied == key then
			S.copied = nil
			render(S)
		end
	end)
end

local function openWorktree(S, pr)
	if S.busy then return end
	busy(S, "wt-" .. pr.number, 2500)
	bridge.send(S.cx, "worktree", { repo = data.CHECKOUT, branch = pr.headRefName, command = "" })
end

local function fix(S, pr)
	if S.busy then return end
	local th = S.threads[pr.number]
	busy(S, "wt-" .. pr.number, 2500)
	bridge.send(S.cx, "worktree", {
		repo = data.CHECKOUT, branch = pr.headRefName, command = "omp",
		prompt = data.fixPrompt(pr, if th and not th.error then th else {}),
	})
	toast(S, "success", "Fix started on #" .. pr.number, pr.headRefName)
end

local function checkoutHere(S, pr)
	local cwd = facts.focusedCwd()
	if not cwd then
		toast(S, "error", "No local folder", "Focus a terminal inside a checkout of entropy first.")
		return
	end
	S.busy = "co-" .. pr.number
	render(S)
	proc.run("pr checkout", { "gh", "pr", "checkout", tostring(pr.number), "-R", REPO }, { cwd = cwd, timeout_ms = 120000 },
		function(r)
			if r.status == 0 then
				toast(S, "success", "Checked out #" .. pr.number, pr.headRefName .. " in " .. util.shortenHome(cwd))
			else
				toast(S, "error", "Checkout failed", failure(r))
			end
			S.busy = nil
			render(S)
		end)
end

local function mergePr(S, pr)
	if S.armed ~= pr.number then
		arm(S, pr.number)
		return
	end
	S.armed, S.busy = nil, "mg-" .. pr.number
	render(S)
	proc.run("pr merge", { "gh", "pr", "merge", tostring(pr.number), "-R", REPO, S.merge }, { timeout_ms = 60000 }, function(r)
		if r.status == 0 then
			toast(S, "success", "Merged #" .. pr.number, pr.title)
		else
			toast(S, "error", "Merge #" .. pr.number .. " failed", util.truncate(failure(r), 300))
		end
		S.busy, S.next = nil, 0
		render(S)
	end)
end

local function toggleDraft(S, pr)
	local key = "rd-" .. pr.number
	if S.armed ~= key then
		arm(S, key)
		return
	end
	S.armed, S.busy = nil, key
	render(S)
	local toReady = pr.isDraft
	local argv = { "gh", "pr", "ready", tostring(pr.number), "-R", REPO }
	if not toReady then table.insert(argv, "--undo") end
	proc.run("pr ready", argv, { timeout_ms = 30000 }, function(r)
		if r.status == 0 then
			pr.isDraft = not toReady
			toast(S, "success", if toReady then "#" .. pr.number .. " is ready for review" else "#" .. pr.number .. " is back to draft", pr.title)
		else
			toast(S, "error", "Could not change the draft state", failure(r))
		end
		S.busy, S.next = nil, tern.now() + 3000
		render(S)
	end)
end

local function diff(S, pr)
	local cmd = "gh pr diff " .. pr.number .. " -R " .. REPO
		.. " | (command -v diffnav >/dev/null && diffnav || delta --paging=always)"
	bridge.send(S.cx, "split", { dir = "right", command = cmd })
end

local function startReview(S, pr)
	local pane = model.reviewing(S, pr)
	if pane then
		bridge.send(S.cx, "focus", { pane = pane })
		return
	end
	bridge.request(S.cx, "tab", {
		cwd = data.DIR, argv = { "python3", data.DIR .. "/review.py", "review", tostring(pr.number) },
		name = "review #" .. pr.number,
	}, function(newPane)
		if newPane then S.reviewPanes[pr.number] = newPane end
	end)
	toast(S, "info", "Reviewing #" .. pr.number, "Frontend files only. Drafts land in the Drafts tab.")
end

local function focusReviewer(S, pr)
	local pane = model.reviewing(S, pr)
	if pane then bridge.send(S.cx, "focus", { pane = pane }) end
end

local function openPage(S, pr, how)
	bridge.send(S.cx, "markdown", { path = data.OUT .. "/" .. data.idOf(pr) .. ".review.md", how = how })
end

local function currentComment(S, pr, i: number)
	local raw = cached(S, data.OUT .. "/" .. data.idOf(pr) .. ".review.json")
	local rv = raw and util.decodeJson(raw)
	return rv and rv.comments and rv.comments[i]
end

local function startEdit(S, pr, i: number)
	local c = currentComment(S, pr, i)
	if not c then return end
	local k = data.idOf(pr) .. "-" .. i
	S.edits[k] = field.new(view.text0(c), true)
	S.focusKey = k
	render(S)
	tern.timer(60, function()
		if alive(S) then field.focus(S.cx, view.editorId(i)) end
	end)
end

local function reloadReview(S, pr)
	S.cache[data.OUT .. "/" .. data.idOf(pr) .. ".review.json"] = nil
	loadFiles(S, pr)
	scan(S)
end

local function saveEdit(S, pr, i: number)
	local k = data.idOf(pr) .. "-" .. i
	local f, c = S.edits[k], currentComment(S, pr, i)
	if not f or not c then return end
	local value = util.trim(f.text)
	if value == c.label .. ": " .. c.body then value = "" end
	proc.run("save comment", {
		"python3", "-c", PATCH_COMMENT, data.OUT .. "/" .. data.idOf(pr) .. ".review.json", tostring(i - 1), value,
	}, { timeout_ms = 10000 }, function(r)
		if r.status == 0 then
			S.edits[k] = nil
			if S.focusKey == k then S.focusKey = nil end
			reloadReview(S, pr)
		else
			toast(S, "error", "Could not save the comment", util.truncate(failure(r), 200))
		end
		render(S)
	end)
end

local function post(S, pr, i: number)
	local k = data.idOf(pr) .. "-" .. i
	if S.posting[k] then return end
	S.posting[k] = true
	render(S)
	local file = data.OUT .. "/" .. data.idOf(pr) .. ".review.json"
	proc.run("post comment", { "python3", data.DIR .. "/review.py", "post", file, tostring(i - 1) },
		{ cwd = data.DIR, timeout_ms = 60000 }, function(r)
			if r.status == 0 then
				reloadReview(S, pr)
				toast(S, "success", "Added to your pending review", "Submit it on GitHub when you are done.")
			else
				local lines = util.lines(util.trim(if r.stderr ~= "" then r.stderr else r.stdout))
				toast(S, "error", "Post failed", util.truncate(lines[#lines] or "", 220))
			end
			S.posting[k] = nil
			render(S)
		end)
end

local function tick(S)
	local changed = refreshFacts(S)
	local vis = visible(S)
	local now = tern.now()
	if vis and changed then render(S) end
	if vis and not S.shown then S.next = 0 end
	S.shown = vis
	if S.loaded and not S.resumed then
		S.resumed = true
		resume(S)
	end
	if now >= S.next then
		S.next = now + (if vis then 60000 else 300000)
		load(S)
	elseif vis and math.floor(now / 1000) % 4 == 0 then
		scan(S)
	end
end

local function act(S, name: string, value: string?)
	local pr = model.find(S, S.open)
	local n = tonumber(value)
	if name == "refresh" then
		S.refreshing, S.next = true, 0
		tick(S)
	elseif name == "pick" then
		local target = model.find(S, n)
		if target then openPr(S, target) end
	elseif name == "back" then
		S.open = nil
		render(S)
	elseif name == "fold" then
		S.showStale = not S.showStale
		render(S)
	elseif name == "bots" then
		S.showBots = not S.showBots
		render(S)
	elseif name == "agent" then
		if n then bridge.send(S.cx, "focus", { pane = n }) end
	elseif not pr then
		return
	elseif name == "eli5-go" then explain(S, pr)
	elseif name == "rv-go" then startReview(S, pr)
	elseif name == "rv-open" then focusReviewer(S, pr)
	elseif name == "rv-md" then openPage(S, pr)
	elseif name == "rv-md-beside" then openPage(S, pr, "beside")
	elseif name == "wt" then openWorktree(S, pr)
	elseif name == "co" then checkoutHere(S, pr)
	elseif name == "diff" then diff(S, pr)
	elseif name == "fix" then fix(S, pr)
	elseif name == "merge" then mergePr(S, pr)
	elseif name == "ready" then toggleDraft(S, pr)
	elseif name == "copy-all" then
		local raw = cached(S, data.OUT .. "/" .. data.idOf(pr) .. ".review.json")
		local rv = raw and util.decodeJson(raw)
		local parts = {}
		for _, c in (rv and rv.comments or {}) do table.insert(parts, c.path .. ":" .. c.line .. "\n" .. view.text0(c)) end
		copy(S, table.concat(parts, "\n\n"), "all")
	elseif name == "copy" and n then
		local c = currentComment(S, pr, n)
		if c then copy(S, view.text0(c), data.idOf(pr) .. "-" .. n) end
	elseif name == "edit" and n then startEdit(S, pr, n)
	elseif name == "save" and n then saveEdit(S, pr, n)
	elseif name == "cancel" and n then
		local k = data.idOf(pr) .. "-" .. n
		S.edits[k] = nil
		if S.focusKey == k then S.focusKey = nil end
		render(S)
	elseif name == "post" and n then post(S, pr, n)
	end
end

local function editKey(S, id: string?): string?
	local pr = model.find(S, S.open)
	local i = id and string.match(id, "%.cm%-(%d+)%.ed$")
	if not pr or not i then return nil end
	return data.idOf(pr) .. "-" .. i
end

local function define(mode: string, kind: string)
	return {
		font = "sans",
		features = { "edit", "undo" },
		init = function(cx, _args, saved)
			local S = {
				cx = cx, mode = mode, kind = kind, prs = {}, files = { eli5 = {}, review = {} }, cache = {},
				explaining = {}, convo = {}, threads = {}, edits = {}, posting = {}, reviewPanes = {},
				trees = {}, panes = {}, agents = {}, open = nil, showStale = false, showBots = false, next = 0,
				tab = if mode == "mine" then "desc" else "eli5",
			}
			local known = tern.kv.get("review:" .. mode)
			if type(known) == "table" and type(known.prs) == "table" then
				S.prs, S.merge, S.loaded = known.prs, known.merge, true
			end
			if type(saved) == "table" then
				if type(saved.open) == "number" then S.open = saved.open end
				if type(saved.tab) == "string" then S.tab = saved.tab end
				S.showStale = saved.showStale == true
			end
			timer.blockEvery("review tick", cx, 1000, function() tick(S) end, true)
			return S
		end,
		title = function(S) return if S.mode == "mine" then "My PRs" else "Review" end,
		view = function(S) return view.build(S) end,
		save = function(S) return { open = S.open, tab = S.tab, showStale = S.showStale } end,
		key = function(S, key, _cx)
			local k = S.focusKey
			local f = k and S.edits[k]
			if not f then return false end
			local i = tonumber(string.match(k, "%-(%d+)$"))
			local pr = model.find(S, S.open)
			if key.name == "escape" then
				S.edits[k], S.focusKey = nil, nil
				return true
			elseif (key.meta or key.ctrl) and key.name == "enter" then
				if pr and i then saveEdit(S, pr, i) end
				return true
			end
			return field.key(f, key)
		end,
		event = function(S, ev, _cx)
			if ev.ev == "action" then
				act(S, ev.act, ev.value)
			elseif ev.ev == "select" and ev.item and string.match(ev.id or "", "%.tabs$") then
				S.tab = ev.item
			elseif ev.ev == "focus" then
				local k = editKey(S, ev.id)
				if k and S.edits[k] then S.focusKey = k end
			elseif ev.ev == "edit" then
				local k = editKey(S, ev.id)
				local f = k and S.edits[k]
				if f then
					S.focusKey = k
					field.edit(f, ev)
				end
			end
		end,
	}
end

return { prs = define("mine", "acc.prs"), review = define("review", "acc.review") }
