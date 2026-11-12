--!nonstrict
-- Routing: magpie's mode switch, the live request diagram and the task tree.
-- The diagram is a stack of SVG layers (see motion.luau): one static base and
-- one short-lived layer per flight, flowing wire, pulse and failure.
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local util = require("../../lib/util")
local motion = require("./motion")
local tasks = require("./tasks")

local ui = tern.ui

local BASE = "http://127.0.0.1:3425"
local MAX_AGENTS, MAX_PROVIDERS, KEEP = 4, 6, 40
local MODE_GROUP = "omp"
local MODES = {
	{ id = "group/auto", label = "Auto", hint = "classifier" },
	{ id = "group/heavy", label = "Max", hint = "Opus · Astra" },
	{ id = "group/eco", label = "Eco", hint = "Sol · Sonnet · Luna" },
}
local PX_PER_COL, PANEL_PAD = 7.96, 24

local function widthOf(cols: number): number
	return math.max(300, math.min(560, math.floor((cols * PX_PER_COL - PANEL_PAD) / 10) * 10))
end

local function alive(st): boolean
	if not st.alive then return false end
	if not timer.alive(st.cx.pane) then
		st.alive = false
		return false
	end
	return true
end

local function agentIndex(st, id: string): number?
	return table.find(st.agents, id)
end

local function providerIndex(st, id: string): number?
	return table.find(st.providers, id)
end

local function updateGeo(st)
	st.geo = motion.layout(st.W, st.agents, st.providers)
end

local function inflight(st, agent: string?): number
	local n = 0
	for _, r in st.routes do
		if not r.done and (agent == nil or r.agent == agent) then n += 1 end
	end
	return n
end

local function currentModel(st, provider: string): string
	for _, r in st.routes do
		if not r.done then
			for _, T in r.tries do
				if T.provider == provider and not T.done then return T.model or "" end
			end
		end
	end
	return ""
end

-- The color of the agent whose request is flying through `provider` now.
local function lastAgentColor(st, provider: string): string
	for i = #st.order, 1, -1 do
		local r = st.routes[st.order[i]]
		if r and not r.done then
			for _, T in r.tries do
				if T.provider == provider then return motion.hueOf(r.agent, st.given) end
			end
		end
	end
	return "#888888"
end

-- Builds the base blob when anything it shows changed.
local function refreshBase(st)
	local agents, providers, flowing = {}, {}, {}
	local nowMs = os.time() * 1000
	for _, id in st.agents do
		table.insert(agents, { id = id, color = motion.hueOf(id, st.given), n = inflight(st, id), task = tasks.agentTask(st.taskList, id, nowMs) })
	end
	for _, id in st.providers do
		table.insert(providers, { id = id, model = currentModel(st, id) })
	end
	local keys = {}
	for key in st.flowCount do table.insert(keys, key) flowing[key] = true end
	table.sort(keys)
	local hint = if #agents == 0 and not st.offline then "No request yet. Send one through magpie and it flies here." else nil
	local sig = { st.W, hint or "", table.concat(keys, ",") }
	for _, a in agents do table.insert(sig, `{a.id}|{a.color}|{a.n}|{a.task or ""}`) end
	for _, p in providers do table.insert(sig, `{p.id}|{p.model}`) end
	local joined = table.concat(sig, "\n")
	if joined ~= st.baseSig then
		st.baseSig = joined
		st.baseId = st.cx:blob(motion.base(st.geo, agents, providers, flowing, hint), "image/svg+xml")
	end
end

local function redraw(st)
	if not alive(st) then return end
	refreshBase(st)
	st.cx:render()
end

local function queueRedraw(st)
	if st.redrawQueued then return end
	st.redrawQueued = true
	tern.timer(0, function()
		st.redrawQueued = false
		redraw(st)
	end)
end

-- Layers ---------------------------------------------------------------------

local function removeLayer(st, key: string)
	for i, l in st.layers do
		if l.key == key then
			table.remove(st.layers, i)
			return true
		end
	end
	return false
end

local function addLayer(st, key: string, svg: string, life: number?, group: string?)
	if group then
		for i = #st.layers, 1, -1 do
			if st.layers[i].group == group then table.remove(st.layers, i) end
		end
	end
	table.insert(st.layers, { key = key, id = st.cx:blob(svg, "image/svg+xml"), group = group, life = life })
	if life then
		timer.later("routing layer", life, function()
			if removeLayer(st, key) then queueRedraw(st) end
		end)
	end
	queueRedraw(st)
end

local function layerSeq(st): number
	st.seq += 1
	return st.seq
end

-- A card's outline pulses (a request arrived or came home).
local function tick(st, kind: string, id: string?)
	local index = if kind == "agent" then agentIndex(st, id) else nil
	if kind == "agent" and not index then return end
	addLayer(st, "pulse:" .. layerSeq(st), motion.pulse(st.geo, kind, index), 450)
end

local function hit(st, provider: string, status: string)
	local index = providerIndex(st, provider)
	if not index then return end
	local model = currentModel(st, provider)
	addLayer(st, "hit:" .. layerSeq(st), motion.hit(st.geo, index, provider, model, status), 1900, "hit:" .. provider)
end

-- Counts requests flowing on a wire; dashes run while it's above zero.
local function live(st, key: string, d: number)
	local n = (st.flowCount[key] or 0) + d
	if n <= 0 then
		if st.flowCount[key] then
			st.flowCount[key] = nil
			removeLayer(st, "flow:" .. key)
		end
	else
		if not st.flowCount[key] then
			local color
			if string.sub(key, 1, 2) == "a:" then
				color = motion.hueOf(string.sub(key, 3), st.given)
			else
				color = lastAgentColor(st, string.sub(key, 3))
			end
			if st.geo.wires[key] then
				table.insert(st.layers, { key = "flow:" .. key, id = st.cx:blob(motion.flow(st.geo, key, color), "image/svg+xml") })
			end
		end
		st.flowCount[key] = n
	end
	queueRedraw(st)
end

-- Playback: one coroutine per request -------------------------------------------

local function resume(co)
	local ok, err = coroutine.resume(co)
	if not ok then tern.log.warn("acc: routing playback failed: " .. tostring(err)) end
end

local function wake(st)
	if st.waking then return end
	st.waking = true
	for _ = 1, 6 do
		local pending = st.waiters
		st.waiters = {}
		local ran = false
		for _, w in pending do
			if not alive(st) then break end
			if w.cond() then
				ran = true
				resume(w.co)
			else
				table.insert(st.waiters, w)
			end
		end
		if not ran then break end
	end
	st.waking = false
end

local function waitUntil(st, cond: () -> boolean)
	if cond() then return end
	table.insert(st.waiters, { co = coroutine.running(), cond = cond })
	coroutine.yield()
end

local function sleep(st, ms: number)
	local t = tern.now() + ms
	tern.timer(ms + 5, function() wake(st) end)
	waitUntil(st, function() return tern.now() >= t end)
end

local function wireLeg(st, key: string, rev: boolean)
	local w = st.geo.wires[key]
	if rev then return { kind = "wire", sx = w.x2, sy = w.y2, ex = w.x1, ey = w.y1 } end
	return { kind = "wire", sx = w.x1, sy = w.y1, ex = w.x2, ey = w.y2 }
end

local function tipOf(st, key: string, atEnd: boolean)
	local w = st.geo.wires[key]
	if not w then return nil end
	return if atEnd then { x = w.x2, y = w.y2 } else { x = w.x1, y = w.y1 }
end

-- The hop over the hub between the agent wire's end and the provider wire's start.
local function viaLeg(a, b)
	if a and b and math.abs(b.x - a.x) >= 1 then
		return { kind = "via", sx = a.x, sy = a.y, ex = b.x, ey = b.y }
	end
	return nil
end

local function legsOf(...)
	local out = {}
	for i = 1, select("#", ...) do
		local l = select(i, ...)
		if l then table.insert(out, l) end
	end
	return out
end

local function fly(st, id: string, legs, ms: number, opts)
	if #legs == 0 then return end
	local svg, life = motion.trip(st.geo, legs, ms, opts)
	addLayer(st, `t:{id}:{layerSeq(st)}`, svg, life, "trip:" .. id)
	sleep(st, ms)
end

local function play(st, id: string)
	local R = st.routes[id]
	local color = motion.hueOf(R.agent, st.given)
	local A = "a:" .. R.agent
	local held = {}
	local function up(key)
		held[key] = (held[key] or 0) + 1
		live(st, key, 1)
	end
	local function down(key)
		if held[key] and held[key] > 0 then
			held[key] -= 1
			live(st, key, -1)
		end
	end
	up(A)
	local function run()
		local from = nil
		local resting = false
		tick(st, "agent", R.agent)
		if #R.tries == 0 then
			fly(st, id, { wireLeg(st, A, false) }, 620, { color = color, dot = "out", bird = "new", endBird = "rest", endDot = "rest" })
			from = tipOf(st, A, true)
			resting = true
			tick(st, "hub")
		end
		local i = 1
		while true do
			if i > #R.tries then
				if R.done then break end
				waitUntil(st, function() return #R.tries >= i or R.done end)
			else
				local T = R.tries[i]
				local P = "p:" .. T.provider
				waitUntil(st, function() return st.geo.wires[P] ~= nil end)
				if from then tick(st, "hub") end
				up(P)
				local legs = legsOf(
					if from then nil else wireLeg(st, A, false),
					viaLeg(from or tipOf(st, A, true), tipOf(st, P, false)),
					wireLeg(st, P, false)
				)
				fly(st, id, legs, if from then 900 else 1400, {
					color = color, dot = "out", bird = if resting then "cont" else "new", endBird = "away", endDot = "hold",
				})
				resting = false
				waitUntil(st, function() return T.done end)
				local home = legsOf(
					wireLeg(st, P, true),
					viaLeg(tipOf(st, P, false), tipOf(st, A, true)),
					wireLeg(st, A, true)
				)
				if not T.failed then
					waitUntil(st, function() return R.done end)
					fly(st, id, home, 1400, { color = color, dot = "back", bird = "new", endBird = "away", endDot = "none" })
					down(P)
					tick(st, "agent", R.agent)
					break
				end
				hit(st, T.provider, if (T.status or 0) > 0 then tostring(T.status) else "err")
				if R.done and i >= #R.tries then
					fly(st, id, home, 1350, { color = color, dot = "err", bird = "new", endBird = "away", endDot = "none" })
					down(P)
					tick(st, "agent", R.agent)
					break
				end
				fly(st, id, { wireLeg(st, P, true) }, 620, { color = color, dot = "err", bird = "new", endBird = "away", endDot = "rest" })
				down(P)
				from = tipOf(st, P, false)
				i += 1
			end
		end
	end
	local ok, err = pcall(run)
	if not ok then tern.log.warn("acc: routing play failed: " .. tostring(err)) end
	down(A)
	for key in held do
		while held[key] > 0 do down(key) end
	end
	for i = #st.layers, 1, -1 do
		local l = st.layers[i]
		if l.group == "trip:" .. id and not l.life then table.remove(st.layers, i) end
	end
	st.playing[id] = nil
	queueRedraw(st)
end

-- Feed ---------------------------------------------------------------------------

local function addAgent(st, id: string): boolean
	if table.find(st.agents, id) then return true end
	if #st.agents >= MAX_AGENTS then
		local idle = nil
		for _, a in st.agents do
			if inflight(st, a) == 0 then idle = a break end
		end
		if not idle then return false end
		table.remove(st.agents, table.find(st.agents, idle))
	end
	table.insert(st.agents, id)
	updateGeo(st)
	return true
end

local function addProvider(st, id: string)
	if table.find(st.providers, id) then return end
	if #st.providers >= MAX_PROVIDERS then table.remove(st.providers, 1) end
	table.insert(st.providers, id)
	updateGeo(st)
end

local function failed(x): boolean
	return x.failed == true or (x.status or 0) >= 400
end

local function ingest(st, x)
	if type(x) ~= "table" or not x.id then return end
	local R = st.routes[x.id]
	local phase = x.phase
	if not R then
		if phase == "done" or phase == "dropped" then return end
		R = { id = x.id, agent = if x.agent and x.agent ~= "" then x.agent else "agent", tries = {}, done = false }
		st.routes[x.id] = R
		table.insert(st.order, x.id)
		if #st.order > KEEP then
			for i, k in st.order do
				if st.routes[k].done and not st.playing[k] then
					st.routes[k] = nil
					table.remove(st.order, i)
					break
				end
			end
		end
	end
	if x.provider and (phase == "attempt" or phase == "responding" or phase == "attempt_done") then
		local i = math.min(math.max(1, x.attempt or 1), #R.tries + 1)
		local T = R.tries[i]
		if not T then
			T = { provider = x.provider, model = x.model, done = false, status = 0, failed = false }
			R.tries[i] = T
		end
		T.provider, T.model = x.provider, x.model
		addProvider(st, x.provider)
		if phase == "attempt_done" then
			T.done, T.status, T.failed = true, x.status or 0, failed(x)
		end
	end
	if phase == "done" or phase == "dropped" then
		R.done, R.gone, R.status = true, phase == "dropped", x.status
		local last = R.tries[#R.tries]
		if last and not last.done then
			last.done, last.status, last.failed = true, x.status or 0, failed(x)
		end
	end
	if not st.playing[x.id] and addAgent(st, R.agent) then
		st.playing[x.id] = true
		resume(coroutine.create(function() play(st, x.id) end))
	end
	wake(st)
	queueRedraw(st)
end

local function parseEvents(st, text: string)
	if string.find(text, "snapshot_required", 1, true) or string.find(text, "event: reset", 1, true) then
		st.cursor = nil
		return
	end
	for block in string.gmatch(text .. "\n\n", "(.-)\n\n") do
		local id, data = nil, ""
		for line in string.gmatch(block, "[^\n]+") do
			if string.sub(line, 1, 3) == "id:" then
				id = util.trim(string.sub(line, 4))
			elseif string.sub(line, 1, 5) == "data:" then
				data ..= util.trim(string.sub(line, 6))
			end
		end
		if data ~= "" then
			local e = util.decodeJson(data)
			if type(e) == "table" then
				ingest(st, e.route)
				st.cursor = id or e.cursor or st.cursor
			end
		end
	end
end

local function goOffline(st)
	if not st.offline then
		st.offline = true
		queueRedraw(st)
	end
	st.cursor = nil
	timer.later("routing feed", 2000, function() feedStep(st) end)
end

local feedStep

local function snapshot(st)
	tern.fetch(st.base .. "/v1/magpie/route-events/snapshot", { timeout_ms = 5000 }, function(r)
		if not alive(st) then return end
		local s = if r.error or r.status ~= 200 then nil else util.decodeJson(r.body)
		if type(s) ~= "table" then
			goOffline(st)
			return
		end
		st.cursor = s.cursor
		for _, x in (s.routes or {}) do ingest(st, x) end
		st.offline = false
		queueRedraw(st)
		feedStep(st)
	end)
end

-- tern.fetch and tern.process.run return whole results, so the SSE stream is
-- read in short curl windows resumed from the cursor.
function feedStep(st)
	if not alive(st) then return end
	if st.cursor == nil then
		snapshot(st)
		return
	end
	proc.run("routing feed", {
		"curl", "-sN", "--max-time", "0.4", "-H", "Accept: text/event-stream",
		st.base .. "/v1/magpie/route-events?after=" .. st.cursor,
	}, { timeout_ms = 4000 }, function(r)
		if not alive(st) then return end
		if r.status ~= 0 and r.status ~= 28 then
			goOffline(st)
			return
		end
		if st.offline then
			st.offline = false
			queueRedraw(st)
		end
		parseEvents(st, r.stdout)
		feedStep(st)
	end)
end

-- Mode ---------------------------------------------------------------------------

local function readMode(cb: (string?) -> ())
	proc.run("routing mode", { "magpie", "group", MODE_GROUP }, { timeout_ms = 8000 }, function(r)
		local mode = nil
		for _, line in util.lines(r.stdout) do
			if string.find(line, "●", 1, true) then
				mode = string.match(line, "group/[%w_%-]+")
				break
			end
		end
		cb(mode)
	end)
end

local function pick(st, id: string)
	if st.pending or id == st.mode then return end
	st.pending = id
	queueRedraw(st)
	proc.run("routing pick", { "magpie", "group", "pick", MODE_GROUP, id }, { timeout_ms = 15000 }, function()
		readMode(function(mode)
			st.mode = mode or st.mode
			st.pending = nil
			queueRedraw(st)
		end)
	end)
end

-- Tasks --------------------------------------------------------------------------

local function refreshTasks(st)
	tasks.loadRows(function(rows)
		if not alive(st) then return end
		st.rows = rows
		local nowMs = os.time() * 1000
		local function done()
			st.taskList = tasks.tasks(st.rows, st.sess)
			queueRedraw(st)
		end
		if (tasks.hasUnknown(rows, st.sess) and nowMs - st.sessAt > 15000) or nowMs - st.sessAt > 60000 then
			st.sessAt = nowMs
			tasks.loadSessions(function(sess)
				if not alive(st) then return end
				for id, s in sess do st.sess[id] = s end
				done()
			end)
		else
			done()
		end
	end)
end

-- View ---------------------------------------------------------------------------

local function modeButtons(st)
	local nodes = {}
	for _, m in MODES do
		local on = (st.pending or st.mode) == m.id
		local label = if st.pending == m.id then m.label .. "…" else m.label
		table.insert(nodes, ui.el("button", {
			class = if on then "rt-mode on" else "rt-mode",
			key = m.id,
			role = "acc.routing.mode",
			actions = { click = "mode=" .. m.id },
		}, {
			ui.el("div", { class = "rt-mode-label", text = label }),
			ui.el("div", { class = "rt-mode-hint", text = m.hint }),
		}))
	end
	return ui.el("div", { class = "rt-modes" }, nodes)
end

local function stage(st)
	local size = { w = st.W, h = motion.GH }
	local kids = {
		ui.node("image", {
			blob = st.baseId, key = "base", role = "acc.routing.base", alt = "Routing diagram",
			w = size.w, h = size.h, actions = { click = "noop" },
		}),
	}
	for _, l in st.layers do
		table.insert(kids, ui.node("image", {
			blob = l.id, key = l.key, role = "acc.routing.layer", alt = "Routing animation",
			w = size.w, h = size.h, actions = { click = "noop" },
		}))
	end
	return ui.el("div", { class = "rt-stage" }, kids)
end

local def = {
	font = "sans",
	init = function(cx, args)
		local function baseOf(list)
			for _, a in list or {} do
				if string.match(a, "^https?://") then return a end
			end
			return BASE
		end
		local st = {
			cx = cx, alive = true, base = baseOf(args), W = widthOf(cx.cols),
			routes = {}, order = {}, agents = {}, providers = {}, given = {}, playing = {},
			flowCount = {}, layers = {}, seq = 0, cursor = nil, offline = false,
			mode = nil, pending = nil, rows = {}, sess = {}, sessAt = 0, taskList = {},
			baseSig = "", baseId = nil, waiters = {},
		}
		updateGeo(st)
		refreshBase(st)
		timer.later("routing start", 0, function()
			feedStep(st)
			refreshTasks(st)
			readMode(function(mode)
				st.mode = mode
				queueRedraw(st)
			end)
		end)
		timer.blockEvery("routing tasks", cx, 3000, function()
			refreshTasks(st)
			return true
		end)
		timer.blockEvery("routing mode", cx, 4000, function()
			if not st.pending then
				readMode(function(mode)
					if mode ~= st.mode and not st.pending then
						st.mode = mode
						queueRedraw(st)
					end
				end)
			end
			return true
		end)
		return st
	end,
	title = function()
		return "Routing"
	end,
	resize = function(st, cols, _rows, _cx)
		local W = widthOf(cols)
		if W ~= st.W then
			st.W = W
			updateGeo(st)
			refreshBase(st)
		end
	end,
	event = function(st, ev, _cx)
		if ev.act == "mode" and ev.value then pick(st, ev.value) end
	end,
	view = function(st, _cx)
		local nowMs = os.time() * 1000
		local n = inflight(st, nil)
		local status = if st.offline then "gateway offline" elseif n > 0 then n .. " in flight" else "idle"
		return {
			main = ui.col({
				ui.el("div", { class = "rt-root" }, {
					ui.el("div", { class = "rt-head" }, {
						ui.el("span", { class = "rt-title", text = "Routing" }),
						ui.el("span", { class = if st.offline then "rt-status rt-warn" else "rt-status", text = status }),
					}),
					modeButtons(st),
					stage(st),
					tasks.tree(st.taskList, nowMs),
				}),
			}),
		}
	end,
}

return { routing = def }
