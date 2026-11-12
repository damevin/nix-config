--!nonstrict
local chrome = require("../../lib/chrome")
local events = require("../../lib/events")
local dock = require("../../lib/dock")
local timer = require("../../lib/timer")
local proc = require("../../lib/proc")
local util = require("../../lib/util")

local labels = { claude = "Claude", codex = "Codex", omp = "ᴏᴍᴘ", gemini = "Gemini", opencode = "OpenCode", aider = "Aider", amp = "Amp", ["cursor-agent"] = "Cursor", hermes = "Hermes" }
local shells = { zsh = true, bash = true, fish = true, sh = true, nu = true, shell = true }
local zoomed = {}
local snapshot = ""
local segments = {}
local branches = tern.kv.get("tabs:branches") or {}
local pending = {}

local function programOf(tab)
	local program = string.lower(util.basename(tab.program or ""))
	if program == "secretspec" then return "omp" end
	return program
end

local function cleanTitle(title)
	local first = 1
	for at, code in utf8.codes(title or "") do
		if code >= 0x2800 and code <= 0x28ff or code == 32 or code == 9 then
			first = at + #utf8.char(code)
		else break end
	end
	return util.trim(string.sub(title or "", first))
end

tern.chrome.tab_title(function(tab)
	if tab.name and tab.name ~= "" and not string.match(tab.name, "^tb%d+$") then return nil end
	local program = programOf(tab)
	local title = cleanTitle(tab.title)
	local name
	if labels[program] then
		name = if title ~= "" and title ~= tab.program and string.lower(title) ~= program then title else labels[program]
	elseif shells[program] or program == "" then name = "Terminal"
	else name = if title ~= "" then title else program end
	return name .. (if zoomed[tab.id] then " Z" else "")
end)
tern.chrome.program_icon("omp", "app-omp")
tern.chrome.program_icon("secretspec", "app-omp")

-- Match the panel buttons: a second click closes Changes in this tab.
tern.command({ id = "toggle-changes", title = "Show or hide Changes", icon = "diff", group = "Agent Command Center", run = function(cx)
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	for _, pane in cx.session:panes() do
		if pane.kind == "git" and pane.tab == tab then
			cx.layout:close(pane.pane)
			return
		end
	end
	cx:command("new_git_block")
end })

local panels = {
	{ "routing", "Routing", "flow" }, { "prs", "PRs", "merge" },
	{ "review", "Review", "eye" }, { "today", "Tasks", "list-checks" },
	{ "automation", "Automation", "bolt" }, { "break", "Break", "play" },
}
local function refresh()
	local parts = {}
	for _, p in panels do table.insert(parts, tostring(dock.isOpen(p[1]))) end
	local nextSnapshot = table.concat(parts, "|")
	if nextSnapshot == snapshot then return end
	snapshot = nextSnapshot
	segments = {
		{ text = "Files", icon = "files", tone = "acc-files", command = "files" },
		{ text = "Changes", icon = "diff", tone = "acc-changes", command = "plugin.acc.toggle-changes" },
	}
	for _, p in panels do
		local id, text, icon = p[1], p[2], p[3]
		local tone = "acc-" .. id .. (if dock.isOpen(id) then "-on" else "")
		table.insert(segments, { text = text, icon = icon, tone = tone, command = "plugin.acc.toggle-" .. id })
	end
	tern.chrome.refresh()
end
chrome.status(10, function() return segments end)
dock.onChange(refresh)
refresh()

-- The status line hosts the title-bar panel buttons and bottom-right usage meters,
-- positioned by style.css, so it must stay on.
local function keepStatusLine(cx)
	if cx and cx.settings:get("status_bar") ~= true then cx.settings:set("status_bar", true) end
end
events.on("window_start", function() timer.later("tabs status line", 0, keepStatusLine) end)
timer.later("tabs status line", 0, keepStatusLine)


local function renameSessions(cx)
	if not cx then return end
	local tabs = {}
	for _, tab in cx.session:tabs() do tabs[tab.id] = tab end
	local localHosts = {}
	for _, host in cx.hosts:list() do if host.kind == "local" then localHosts[host.id] = true end end
	local remote = {}
	for _, session in cx.sessions:list() do if not localHosts[session.host] then remote[session.id] = true end end
	local nextZoom = {}
	for _, session in cx.session:sessions() do
		for _, id in session.tabs do
			local layout = cx.session:layout(id)
			if layout and layout.zoomed then nextZoom[id] = true end
		end
		if remote[session.id] or pending[session.id] then continue end
		local tab = tabs[session.tabs[1]]
		if not tab or tab.cwd == "" then continue end
		pending[session.id] = true
		proc.run("tab branch rename", { "git", "-C", tab.cwd, "branch", "--show-current" }, { timeout_ms = 3000 }, function(r, wcx)
			pending[session.id] = nil
			local branch = util.trim(r.stdout)
			local key = tostring(session.id)
			if r.status ~= 0 or branch == "" or branch == "main" or branch == "master" or branches[key] == branch or not wcx then return end
			local name = branch:gsub("^.*/", ""):gsub("^[Ll][Ii][Vv]%-%d+[-_]?", ""):gsub("[-_]+", " ")
			name = util.trim(name)
			if name == "" then name = string.upper(string.match(string.lower(branch), "liv%-%d+") or branch) end
			local ok = pcall(function() wcx.sessions:rename(session.id, name) end)
			if ok then branches[key] = branch; tern.kv.set("tabs:branches", branches) end
		end)
	end
	local changed = false
	for id in nextZoom do if not zoomed[id] then changed = true end end
	for id in zoomed do if not nextZoom[id] then changed = true end end
	zoomed = nextZoom
	if changed then tern.chrome.refresh() end
end

timer.every("tabs branch names", 4000, renameSessions, true)
for _, name in { "focus", "cwd", "pane_created", "pane_closed" } do
	events.on(name, function() timer.later("tabs title state", 0, renameSessions) end)
end
return {}
