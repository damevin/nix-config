--!nonstrict
local chrome = require("../../lib/chrome")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local bridge = require("../../lib/bridge")
local util = require("../../lib/util")
local events = require("../../lib/events")
local session, sessionPane, sessionTitle = nil, nil, nil
local sessionBusy = false
local ROOT = tern.plugin.dir .. "/mods/usage"
local states = tern.kv.get("usage:state") or {}
local lastFetch, busy = {}, {}
local segments = { { text = "Usage …", icon = "gauge", tone = "muted", command = "plugin.acc.usage" } }
local modelBusy, modelAgain = false, false
local prefsText = ""
local refreshSeen = 0
local refreshedAt = 0
local helpers = { claude = "claude-usage.sh", codex = "codex-limits.sh" }
local runtime = proc.which("node") or proc.which("bun")

local function runModel(payload, cb)
	if not runtime then cb(nil, "Install Node.js or Bun to read CLI usage"); return end
	proc.run("usage model", { runtime, ROOT .. "/model.mjs" }, { stdin = tern.json.encode(payload), timeout_ms = 10000 }, function(r)
		cb(if r.status == 0 then util.decodeJson(r.stdout) else nil, r.stderr)
	end)
end
local updateModel
updateModel = function()
	if modelBusy then modelAgain = true; return end
	modelBusy = true
	local prefs = tern.kv.get("usage:prefs") or {}
	runModel({ mode = "model", states = states, prefs = prefs, session = session, title = sessionTitle }, function(model, err)
		modelBusy = false
		local nextSegments = {}
		if model then
			tern.kv.set("usage:card", model.card)
			for _, number in model.numbers or {} do
				table.insert(nextSegments, { text = number.text, tone = "usage-number lvl-" .. (number.level or "ok"), command = "plugin.acc.usage" })
			end
			for _, g in model.bar.groups do
				local providerTone = "usage-provider p-" .. g.providerId .. (if g.dim then " stale" else "")
				local providerText = if type(g.mark) == "string" then g.mark else g.name
				table.insert(nextSegments, { text = providerText, tone = providerTone, command = "plugin.acc.usage" })
				for _, s in g.segments do
					local fill = math.clamp(math.floor((s.fill or 0) * 20 + 0.5) * 5, 0, 100)
					local tone = "usage-meter lvl-" .. (s.level or "ok") .. " f" .. fill
					if g.dim then tone ..= " stale" end
					if prefs.showBars == false then tone ..= " nobar" end
					table.insert(nextSegments, { text = s.short .. " " .. s.text, tone = tone, command = "plugin.acc.usage" })
				end
			end
			if #nextSegments == 0 then table.insert(nextSegments, { text = "Usage —", icon = "gauge", tone = "muted", command = "plugin.acc.usage" }) end
		else
			table.insert(nextSegments, { text = "Usage !", icon = "gauge", tone = "muted", command = "plugin.acc.usage" })
			tern.kv.set("usage:card", { groups = { { providerId = "runtime", name = "Usage", status = err or "Usage unavailable", failed = true, rows = {} } } })
		end
		if tern.json.encode(nextSegments) ~= tern.json.encode(segments) then segments = nextSegments; tern.chrome.refresh() end
		if modelAgain then modelAgain = false; updateModel() end
	end)
end
local function fetch(id)
	if busy[id] then return end
	busy[id], lastFetch[id] = true, os.time()
	proc.run("usage " .. id, { "/bin/sh", ROOT .. "/helpers/" .. helpers[id] }, { timeout_ms = 20000 }, function(result)
		runModel({ mode = "parse", id = id, text = result.stdout, status = result.status, prev = states[id] or {} }, function(nextState)
			busy[id] = false
			if nextState then states[id] = nextState; tern.kv.set("usage:state", states) end
			updateModel()
		end)
	end)
end
local function readSession(cx)
	if not cx then return end
	local pane = cx.session:focused()
	local info = pane and cx.session:pane(pane)
	local app = info and string.lower(util.basename(info.program or ""))
	if app == "claude-code" then app = "claude" end
	local localHost = false
	local current = cx.sessions:current()
	for _, host in cx.hosts:list() do if host.id == current.host and host.kind == "local" then localHost = true end end
	if not localHost or app ~= "claude" and app ~= "codex" then
		if sessionPane then session, sessionPane, sessionTitle = nil, nil, nil; updateModel() end
		return
	end
	if sessionPane ~= pane then session = nil; sessionPane = pane; sessionTitle = util.basename(info.cwd); updateModel() end
	if sessionBusy then return end
	sessionBusy = true
	local cli = proc.which("tern") or "/Applications/Tern.app/Contents/MacOS/tern"
	proc.json("usage pane process", { cli, "process", tostring(pane), "--json", "--window", cx:window_key() }, { timeout_ms = 5000 }, function(process)
		local foreground = process and process.foreground
		if not foreground or not foreground.pid then sessionBusy = false; return end
		proc.run("usage session numbers", { "/bin/sh", ROOT .. "/helpers/session.sh", app, tostring(foreground.pid) }, { timeout_ms = 5000 }, function(result)
			runModel({ mode = "session", app = app, text = if result.status == 0 then result.stdout else "" }, function(nextSession)
				sessionBusy = false
				if sessionPane ~= pane then return end
				session = if type(nextSession) == "table" then nextSession else nil
				updateModel()
			end)
		end)
	end)
end
local function tick(force)
	for id in helpers do
		local every = if states[id] and states[id].installed == false then 3600 else 300
		if force or os.time() - (lastFetch[id] or 0) >= every then fetch(id) end
	end
	updateModel()
end
chrome.status(20, function() return segments end)
tern.command({ id = "usage", title = "Usage limits…", icon = "gauge", group = "Agent Command Center", run = function(cx)
	bridge.call("newmenu.usage", {}, cx)
end })
tern.command({ id = "usage-refresh", title = "Refresh usage limits", icon = "repeat", group = "Agent Command Center", run = function()
	tern.kv.set("usage:refresh", os.time())
end })
timer.every("usage cadence", 60000, function() tick(false) end, true)
timer.every("usage settings", 1000, function()
	local prefs = tern.json.encode(tern.kv.get("usage:prefs") or {})
	if prefs ~= prefsText then prefsText = prefs; updateModel() end
	local asked = tonumber(tern.kv.get("usage:refresh")) or 0
	if asked ~= refreshSeen then
		refreshSeen = asked
		if os.time() - refreshedAt >= 30 then refreshedAt = os.time(); tick(true) end
	end
end)
timer.every("usage focused session", 10000, readSession, true)
events.on("focus", function() timer.later("usage session focus", 0, readSession) end)
return {}
