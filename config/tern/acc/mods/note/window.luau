--!nonstrict
local timer = require("../../lib/timer")

local DOCK = {
	["acc.prs"] = true, ["acc.review"] = true, ["acc.today"] = true,
	["acc.automation"] = true, ["acc.routing"] = true, ["acc.break"] = true,
}

local function workPane(cx)
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	local skip = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == "overseer" then skip[canvas.pane] = true end
	end
	local function work(p)
		return not skip[p.pane] and not p.parked and not DOCK[p.block] and not (p.block and p.block:sub(1, 9) == "overseer.")
	end
	if info and work(info) then return focused end
	local tab = focused and cx.session:tab_of(focused)
	for _, p in cx.session:panes() do
		if work(p) and p.tab == tab then return p.pane end
	end
	return nil
end

tern.command({
	id = "quick-note", title = "Quick note", icon = "note", group = "Agent Command Center",
	keys = { "cmd+shift+n", "ctrl+alt+shift+n" },
	run = function()
		timer.later("quick note", 0, function(cx)
			if not cx then return end
			local pane = cx:new_block("acc.note", {}, "default", { dir = "down", target = workPane(cx) })
			if not pane then cx:toast("error", "Couldn't open Quick note") end
		end)
	end,
})

return {}
