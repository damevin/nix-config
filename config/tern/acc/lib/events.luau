--!nonstrict
-- Window events fanned out to every mod: `tern.on` is registered once per
-- event here. Handlers should only queue work (see timer.later); a hook that
-- runs over 50 ms pauses for every mod.
local M = {}

local handlers: { [string]: { (any, any) -> () } } = {}

function M.on(name: string, fn: (any, any) -> ())
	local list = handlers[name]
	if not list then
		list = {}
		handlers[name] = list
		tern.on(name, function(a, b)
			for _, h in list do
				local ok, err = pcall(h, a, b)
				if not ok then tern.log.warn("acc: " .. name .. " handler failed: " .. tostring(err)) end
			end
		end)
	end
	table.insert(list, fn)
end

return M
