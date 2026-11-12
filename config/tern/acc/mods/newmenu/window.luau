--!nonstrict
local bridge = require("../../lib/bridge")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local events = require("../../lib/events")
local menuPane = nil
local function clearShell()
	menuPane = nil
	tern.css("newmenu-shell", "")
end
local function sizeShell(mode)
	local width = if mode == "usage" then 380 elseif mode == "create" or mode == "open" then 460 else 260
	tern.css("newmenu-shell", ".tn-pane.glimpse{width:" .. tostring(width) .. "px!important;height:543px!important;max-width:95vw!important;max-height:85vh!important;left:auto!important;right:12px!important;top:38px!important;bottom:auto!important}")
end
clearShell()
events.on("window_start", clearShell)
events.on("pane_closed", function(ev) if ev.pane == menuPane then clearShell() end end)

local function open(cx, mode)
	local focus = cx.session:focused()
	local info = focus and cx.session:pane(focus)
	for _, pane in cx.session:panes() do
		if pane.block == "acc.newmenu" then cx.layout:close(pane.pane) end
	end
	menuPane = cx:new_block("acc.newmenu", { mode or "menu", info and info.cwd or "" }, "glimpse", { focus = true })
	if menuPane then sizeShell(mode) end
end
tern.command({ id = "new", title = "New…", icon = "plus", group = "Agent Command Center", keys = { "cmd+alt+shift+n", "ctrl+alt+shift+j" }, run = function(cx) open(cx) end })

bridge.on("newmenu.resize", function(args) sizeShell(args.mode) end)
bridge.on("newmenu.launch", function(args, cx)
	local source = args.from_pane or menuPane
	if source then cx.layout:close(source) end
	clearShell()
	if args.kind == "space" then
		cx.sessions:create({ cwd = args.cwd })
	elseif args.kind == "note" then
		bridge.call("block", { kind = "acc.note", dir = "down", how = "below" }, cx)
	elseif args.kind == "agent" then
		local binary = proc.which(args.program)
		if not binary then cx:toast("error", args.program .. " is not installed"); return end
		bridge.call("tab", { cwd = args.cwd, argv = { binary } }, cx)
	else
		bridge.call("tab", { cwd = args.cwd }, cx)
	end
end)
bridge.on("newmenu.worktree", function(args, cx)
	if args.from_pane or menuPane then cx.layout:close(args.from_pane or menuPane) end
	clearShell()
	bridge.call("worktree", args, cx)
end)
bridge.on("newmenu.dismiss", function(args, cx)
	if args.from_pane or menuPane then cx.layout:close(args.from_pane or menuPane) end
	clearShell()
end)
bridge.on("newmenu.usage", function(_, cx) open(cx, "usage") end)

-- The native + button and Cmd-T share new_tab. Keep that direct path instant;
-- New… gets a separate free chord and a palette row.
return {}
