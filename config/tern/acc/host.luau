--!nonstrict
-- The host half: every panel is a block. Each mod's host module returns
-- `{ [blockId] = BlockDef }`. A mod that fails to load gets an error panel in
-- place of its blocks, so one broken mod never fails the others.
local ui = tern.ui

local MODS = { "review", "today", "automation", "routing", "break", "md", "note", "newmenu" }
local BLOCKS = { "prs", "review", "today", "automation", "routing", "break", "md", "note", "newmenu" }

local defs, failures = {}, {}
for _, mod in MODS do
	local ok, result = pcall(require, "./mods/" .. mod .. "/host")
	if ok and type(result) == "table" then
		for id, def in result do defs[id] = def end
	else
		failures[mod] = tostring(result)
		tern.log.error("acc: mod " .. mod .. " failed to load: " .. tostring(result))
	end
end

local OWNER = { prs = "review" }

local function broken(id: string)
	local mod = OWNER[id] or id
	local reason = string.match(failures[mod] or "", "^[^\n]*") or "not loaded"
	return {
		font = "sans",
		init = function() return {} end,
		view = function()
			return { main = ui.col({ ui.card("Couldn't load " .. id, { ui.code(reason) }, { tone = "error", icon = "warn" }) }) }
		end,
	}
end

for _, id in BLOCKS do
	tern.block.define(id, defs[id] or broken(id))
end
