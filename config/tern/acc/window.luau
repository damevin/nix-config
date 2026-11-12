--!nonstrict
-- The window half: native panels, window actions for blocks (acc:// links),
-- facts for blocks, chrome, and each mod's window side.
local actions = require("./lib/actions")
local bridge = require("./lib/bridge")
local chrome = require("./lib/chrome")
local dock = require("./lib/dock")
local events = require("./lib/events")
local facts = require("./lib/facts")
local timer = require("./lib/timer")

bridge.install()
actions.install()

-- Each panel gets a sensible initial split; native controls own its layout.
dock.register({ id = "prs", kind = "acc.prs", title = "Pull requests", icon = "pull", share = 0.30 })
dock.register({ id = "review", kind = "acc.review", title = "Review", icon = "eye", share = 0.33 })
dock.register({ id = "today", kind = "acc.today", title = "Tasks", icon = "list-checks", share = 0.28 })
dock.register({ id = "automation", kind = "acc.automation", title = "Automation", icon = "bolt", share = 0.29 })
dock.register({ id = "routing", kind = "acc.routing", title = "Routing", icon = "flow", share = 0.30 })
dock.register({ id = "break", kind = "acc.break", title = "Break", icon = "play", share = 0.28 })

-- Mods' window sides; one failing to load leaves the others running.
for _, mod in { "tabs", "newmenu", "note", "usage" } do
	local ok, err = pcall(require, "./mods/" .. mod .. "/window")
	if not ok then tern.log.error("acc: window side of " .. mod .. " failed to load: " .. tostring(err)) end
end

chrome.install()

-- Facts for blocks: on every change worth knowing and every 2 s.
local publishQueued = false
local function publishSoon()
	if publishQueued then return end
	publishQueued = true
	timer.later("publish facts", 0, function(cx)
		publishQueued = false
		if cx then facts.publish(cx) end
	end)
end

for _, name in { "focus", "pane_created", "pane_closed", "tab_created", "tab_closed" } do
	events.on(name, function()
		publishSoon()
		dock.syncSoon()
	end)
end
for _, name in { "agent_state", "agent_finished", "cwd", "title", "command_started", "command_finished" } do
	events.on(name, function() publishSoon() end)
end

events.on("window_start", function()
	publishSoon()
	dock.syncSoon()
end)

-- At load, not in window_start: a reload doesn't run window_start again.
timer.every("facts", 2000, function(cx)
	if cx then facts.publish(cx) end
end, true)
dock.syncSoon()

events.on("budget", function(ev)
	tern.log.warn(timer.describe(ev))
end)
