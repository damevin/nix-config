--!nonstrict
-- Panels are ordinary native panes. Opening focuses an existing instance in
-- its own tab, or creates one beside the focused pane with an initial width.
-- Native layout controls own every subsequent move, resize, and close.
local timer = require("./timer")
local proc = require("./proc")

local M = {}

export type Panel = {
	id: string, kind: string, args: { string }?, title: string, icon: string?, share: number,
}

local panels: { [string]: Panel } = {}
local openCache: { [string]: boolean } = {} -- formatters have no WindowCx
local listeners: { (any) -> () } = {}

function M.register(panel: Panel)
	panels[panel.id] = panel
	tern.command({
		id = "toggle-" .. panel.id,
		title = "Show or hide " .. panel.title,
		icon = panel.icon,
		group = "Agent Command Center",
		run = function(cx) M.toggle(panel.id, cx) end,
	})
end

function M.panel(id: string): Panel? return panels[id] end

-- Whether the last native pane snapshot contained this panel, in any tab.
function M.isOpen(id: string): boolean return openCache[id] == true end

function M.onChange(fn: (any) -> ()) table.insert(listeners, fn) end

local syncQueued = false
-- Read native state after layout events have been applied. This only updates
-- indicators; it never changes the layout or recreates a closed pane.
function M.syncSoon()
	if syncQueued then return end
	syncQueued = true
	timer.later("panel indicators", 0, function(cx)
		syncQueued = false
		if not cx then return end
		local kinds = {}
		for _, pane in cx.session:panes() do
			if pane.block then kinds[pane.block] = true end
		end
		local changed = false
		for id, panel in panels do
			local isOpen = kinds[panel.kind] == true
			if openCache[id] ~= isOpen then changed = true end
			openCache[id] = isOpen
		end
		if changed then
			for _, fn in listeners do pcall(fn, cx) end
			tern.chrome.refresh()
		end
	end)
end

local function initialTarget(cx)
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local kinds = {}
	for _, panel in panels do kinds[panel.kind] = true end
	local projects = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == "overseer" then projects[canvas.pane] = true end
	end
	local function isWork(pane)
		return not kinds[pane.block] and not projects[pane.pane]
			and not (pane.block and string.sub(pane.block, 1, 9) == "overseer.")
	end
	local focusedInfo = focused and cx.session:pane(focused)
	if not focusedInfo or isWork(focusedInfo) then return focused end
	for _, pane in cx.session:panes() do
		if pane.tab == tab and isWork(pane) then return pane.pane end
	end
	return focused
end

function M.show(id: string, cx)
	local panel = panels[id]
	if not panel then return end
	for _, pane in cx.session:panes() do
		if pane.block == panel.kind then
			if pane.parked then
				cx.layout:unpark(pane.pane, { focus = true })
				cx.layout:focus(pane.pane)
			else
				local focused = cx.session:focused()
				local tab = focused and cx.session:tab_of(focused)
				if cx.session:tab_of(pane.pane) == tab then
					cx.layout:focus(pane.pane)
				else
					-- Native focus selects within a tab; the CLI also reveals that tab.
					proc.run("reveal panel", { "tern", "focus", tostring(pane.pane), "--window", cx:window_key() }, { timeout_ms = 5000 }, function(result, nextCx)
						if result.status ~= 0 then
							tern.log.warn("acc: couldn't reveal panel: " .. result.stderr)
							if nextCx then nextCx:toast("error", "Could not open " .. panel.title, result.stderr) end
						end
						M.syncSoon()
					end)
				end
			end
			M.syncSoon()
			return
		end
	end
	local pane = cx:new_block(panel.kind, panel.args or {}, "beside", {
		focus = true, target = initialTarget(cx), dir = "right", ratio = panel.share,
	})
	if not pane then cx:toast("error", "acc: couldn't open " .. panel.title) end
	M.syncSoon()
end

-- A visible panel closes on a second toolbar click. A hidden one is revealed
-- in its own tab first; opening never moves an existing pane.
function M.toggle(id: string, cx)
	local panel = panels[id]
	if not panel then return end
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	for _, pane in cx.session:panes() do
		if pane.block == panel.kind and not pane.parked and cx.session:tab_of(pane.pane) == tab then
			cx.layout:close(pane.pane)
			M.syncSoon()
			return
		end
	end
	M.show(id, cx)
end

return M
