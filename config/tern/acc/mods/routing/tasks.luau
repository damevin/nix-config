--!nonstrict
-- The task tree: magpie's routing log grouped by omp root session and subagent.
local proc = require("../../lib/proc")
local util = require("../../lib/util")

local ui = tern.ui
local M = {}

local ACTIVE_MS, MAX_TASKS = 90000, 10

-- One slim row per finished request from magpie's routing log (it writes a request once it ends).
local SLIM = "{id,time,agent,session,asked:.model,group:(.group.ref // null),provider,served:((((.tries // [])|last)|.served?) // .served),tries:((.tries // [])|length),status,ms,tokens,out,ttft}"
local ROWS = `f="$HOME/.config/magpie/routing/$(date +%F).jsonl"; [ -f "$f" ] && tail -n 250 "$f" | jq -c '{SLIM}'`
local SESSIONS = [[find "$HOME/.omp/agent/sessions" -name '*.jsonl' -mtime -2 | while IFS= read -r f; do head -n 2 "$f" | jq -c -s --arg f "$f" '{f:$f,title:(.[0].title // ""),id:(.[1].id // null),parent:(.[1].parentSession // null),cwd:(.[1].cwd // "")}' 2>/dev/null; done]]

local function daysFromCivil(y: number, m: number, d: number): number
	if m <= 2 then y -= 1 end
	local era = y // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (if m > 2 then -3 else 9)) + 2) // 5 + d - 1
	return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end

-- Unix milliseconds of an ISO-8601 timestamp with fraction and offset.
function M.at(iso: string?): number
	if not iso then return 0 end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return 0 end
	local secs = daysFromCivil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
	local sign, oh, om = string.match(iso, "([+-])(%d%d):?(%d%d)$")
	if sign then
		local off = tonumber(oh) * 3600 + tonumber(om) * 60
		secs -= if sign == "+" then off else -off
	end
	local frac = string.match(iso, "T%d+:%d+:%d+%.(%d+)")
	return secs * 1000 + (if frac then math.floor(tonumber("0." .. frac) * 1000) else 0)
end

local function tok(n: number?): string
	n = n or 0
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e3 then return string.format("%dk", math.floor(n / 1e3 + 0.5)) end
	return tostring(math.floor(n))
end

local function secs(ms: number?): string
	return string.format("%.1fs", (ms or 0) / 1000)
end

-- Output speed after the first token; nil when the stream was too short to say.
local function rate(x): number?
	local out, ms, ttft = x.out, x.ms or 0, x.ttft or 0
	if out and out > 0 and ms - ttft > 300 then
		return math.floor(out / ((ms - ttft) / 1000) + 0.5)
	end
	return nil
end

local function idOfFile(p: string?): string?
	local id = string.match(p or "", "_([0-9a-f%-]+)%.jsonl$")
	return if id and #id == 36 then id else nil
end

-- cb(rows): today's finished requests, newest last, magpie's own calls dropped.
function M.loadRows(cb: ({ any }) -> ())
	proc.sh("routing rows", ROWS, nil, { timeout_ms = 8000 }, function(r)
		local rows = {}
		for _, line in util.lines(r.stdout) do
			local x = util.decodeJson(line)
			if type(x) == "table" and x.agent ~= "magpie" then table.insert(rows, x) end
		end
		cb(rows)
	end)
end

-- cb(sessions): omp session files of the last two days by session id.
function M.loadSessions(cb: ({ [string]: any }) -> ())
	proc.sh("routing sessions", SESSIONS, nil, { timeout_ms = 20000 }, function(r)
		local sess = {}
		for _, line in util.lines(r.stdout) do
			local s = util.decodeJson(line)
			if type(s) == "table" and s.id then sess[s.id] = s end
		end
		cb(sess)
	end)
end

-- Whether some row's session isn't known yet.
function M.hasUnknown(rows, sess): boolean
	for _, x in rows do
		if x.session and not sess[x.session] then return true end
	end
	return false
end

-- The root omp session a request belongs to, and the subagent name when it came from one.
local function taskOf(x, sess)
	local s = sess[x.session]
	-- No session file: omp's side calls (titles, thinking-level judge) or a client like curl. One bucket per agent.
	if not s then
		local title = if x.agent == "omp" then "omp · side calls (titles, classifier)" else tostring(x.agent) .. " · no session"
		return { key = "aux:" .. tostring(x.agent), title = title, sub = nil }
	end
	local sub = if s.parent and s.parent ~= "" then string.gsub(util.basename(s.f), "%.jsonl$", "") else nil
	local i = 0
	while s.parent and s.parent ~= "" and i < 4 do
		local p = sess[idOfFile(s.parent)]
		if not p then break end
		s = p
		i += 1
	end
	local title = if s.title and s.title ~= "" then s.title elseif util.basename(s.cwd) ~= "" then util.basename(s.cwd) else string.sub(s.id, 1, 8)
	return { key = s.id, title = title, sub = sub }
end

-- The ten most recent root tasks, each with its latest request and its subagents.
function M.tasks(rows, sess)
	local map, list = {}, {}
	for _, x in rows do
		local k = taskOf(x, sess)
		local T = map[k.key]
		if not T then
			T = { key = k.key, title = k.title, agent = x.agent, lastAt = 0, n = 0, subs = {}, subList = {} }
			map[k.key] = T
			table.insert(list, T)
		end
		local when = M.at(x.time) + (x.ms or 0)
		T.n += 1
		if when > T.lastAt then T.lastAt = when end
		if k.sub then
			local S = T.subs[k.sub]
			if not S then
				S = { name = k.sub, n = 0 }
				T.subs[k.sub] = S
				table.insert(T.subList, S)
			end
			S.n += 1
			S.last = x
			S.lastAt = when
		else
			T.last = x
		end
	end
	table.sort(list, function(a, b) return a.lastAt > b.lastAt end)
	while #list > MAX_TASKS do table.remove(list) end
	for _, T in list do
		table.sort(T.subList, function(a, b) return a.lastAt > b.lastAt end)
	end
	return list
end

-- The title of the task `agent` is working on, if it sent a request in the last five minutes.
function M.agentTask(list, agent: string, nowMs: number): string?
	for _, T in list do
		if T.agent == agent and string.sub(T.key, 1, 4) ~= "aux:" and nowMs - T.lastAt < 300000 then return T.title end
	end
	return nil
end

function M.activeCount(list, nowMs: number): number
	local n = 0
	for _, T in list do
		if nowMs - T.lastAt < ACTIVE_MS then n += 1 end
	end
	return n
end

local function el(tag: string, class: string, text: string?, children: { any }?, props: { [string]: any }?)
	local p = props or {}
	p.class = class
	if text then p.text = text end
	return ui.el(tag, p, children)
end

local function reqLine(x)
	local err = (x.status or 0) >= 400
	local bits = {}
	if err then table.insert(bits, tostring(x.status)) end
	if (x.tries or 0) > 1 then table.insert(bits, x.tries .. " tries") end
	table.insert(bits, secs(x.ms))
	table.insert(bits, tok(x.tokens))
	local r = rate(x)
	if r then table.insert(bits, r .. " tok/s") end
	return el("div", "rt-req", nil, {
		el("span", "rt-arrow", "→"),
		el("span", "rt-chip", x.group or x.asked or "?"),
		el("span", if err then "rt-prov rt-bad" else "rt-prov", x.provider or "?"),
		el("span", "rt-served", x.served or ""),
		el("span", "rt-meta", table.concat(bits, " · ")),
	})
end

-- The nodes of the TASKS section: a heading and the scrolling tree.
function M.tree(list, nowMs: number)
	local rows = {}
	for _, T in list do
		local active = nowMs - T.lastAt < ACTIVE_MS
		local err = T.last and (T.last.status or 0) >= 400
		local kids = {
			el("div", "rt-task-head", nil, {
				ui.el("span", { role = "acc.dot", tone = if err then "error" elseif active then "warning" else "success" }),
				el("span", "rt-task-title", T.title),
				el("span", "rt-task-meta", string.format("%s · %d req · %s", T.agent, T.n, os.date("%H:%M:%S", math.floor(T.lastAt / 1000)))),
			}),
		}
		if T.last then table.insert(kids, el("div", "rt-indent", nil, { reqLine(T.last) })) end
		local shown = math.min(#T.subList, 4)
		for j = 1, shown do
			local S = T.subList[j]
			table.insert(kids, el("div", "rt-sub-block", nil, {
				el("div", "rt-sub-head", nil, {
					el("span", "rt-branch", if j == shown then "└" else "├"),
					el("span", "rt-sub-name", S.name),
					el("span", "rt-sub-n", S.n .. " req"),
				}),
				el("div", "rt-indent2", nil, { reqLine(S.last) }),
			}, { key = "s" .. S.name }))
		end
		if #T.subList > 4 then
			table.insert(kids, el("div", "rt-more", "+" .. (#T.subList - 4) .. " subagents"))
		end
		table.insert(rows, el("div", "rt-task", nil, kids, { key = T.key }))
	end
	if #rows == 0 then
		table.insert(rows, el("div", "rt-empty", "No requests today."))
	end
	return el("div", "rt-tasks", nil, {
		el("div", "rt-tasks-head", "TASKS · " .. M.activeCount(list, nowMs) .. " active"),
		el("div", "rt-tasks-scroll", nil, rows),
	})
end

return M
