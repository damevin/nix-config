--!nonstrict
-- A compact snapshot of the window-only state panels need. The window writes
-- it for host blocks; unchanged state is sampled cheaply and only serialized
-- when it changes or once every ten seconds.
local util = require("./util")

local M = {}
M.PATH = tern.plugin.data .. "/facts.json"

local lastFingerprint: string? = nil
local lastWrite = 0

function M.publish(cx)
	local focused = cx.session:focused()
	local focusInfo = focused and cx.session:pane(focused)
	local panes = cx.session:panes()
	local agents = cx.agents:list()
	local layout = if focusInfo and focusInfo.tab then cx.session:layout(focusInfo.tab) else nil

	-- Fingerprint only the fields mod actions consume; avoid JSON encoding the
	-- whole snapshot every poll, especially when a busy window has many agents.
	local parts = { tostring(focused or ""), tostring(focusInfo and focusInfo.tab or "") }
	for _, p in panes do
		table.insert(parts, table.concat({
			tostring(p.pane), tostring(p.cwd), tostring(p.program), tostring(p.title),
			tostring(p.busy), tostring(p.kind), tostring(p.tab), tostring(p.block), tostring(p.parked),
			p.running and tostring(p.running.line) or "",
		}, "\31"))
	end
	for _, a in agents do
		table.insert(parts, table.concat({ tostring(a.pane), tostring(a.cwd), tostring(a.state),
			type(a.command) == "string" and a.command or "", type(a.model) == "string" and a.model or "" }, "\31"))
	end
	local signature = table.concat(parts, "\30")
	local now = os.time()
	if signature == lastFingerprint and now - lastWrite < 10 then return end

	local paneRows = {}
	for _, p in panes do
		table.insert(paneRows, {
			pane = p.pane, cwd = p.cwd, program = p.program, title = p.title, busy = p.busy,
			kind = p.kind, tab = p.tab, block = p.block, parked = p.parked,
			running = if p.running then p.running.line else nil,
		})
	end
	local agentRows = {}
	for _, a in agents do
		table.insert(agentRows, {
			pane = a.pane,
			command = if type(a.command) == "string" then a.command else nil,
			model = if type(a.model) == "string" then a.model else nil,
			cwd = a.cwd, state = a.state,
			last_message = if type(a.last_message) == "string" then util.truncate(a.last_message, 300) else nil,
		})
	end
	local sessions = {}
	for _, s in cx.sessions:list() do
		table.insert(sessions, { id = s.id, name = s.name, current = s.current, host = s.host })
	end
	local data = {
		at = now,
		window = cx:window_key(),
		focused = if focusInfo then {
			pane = focused, tab = focusInfo.tab, cwd = focusInfo.cwd, program = focusInfo.program,
		} else nil,
		layout = layout,
		panes = paneRows, agents = agentRows, sessions = sessions,
	}
	lastFingerprint, lastWrite = signature, now
	pcall(tern.fs.write, M.PATH, tern.json.encode(data))
end

local last = nil

-- Host half (or window): the latest facts, or an empty set.
function M.read()
	local text = util.readFile(M.PATH, 4 * 1024 * 1024)
	local data = util.decodeJson(text)
	if type(data) == "table" then last = data end
	return last or { at = 0, panes = {}, agents = {}, sessions = {} }
end

function M.focusedCwd(): string?
	local f = M.read().focused
	if f and f.cwd and f.cwd ~= "" then return f.cwd end
	return nil
end

return M
