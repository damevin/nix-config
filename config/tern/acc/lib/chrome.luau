--!nonstrict
-- One plugin gets one status formatter, so mods add segment providers here and
-- window.luau registers the formatter once. Providers are formatters: no cx,
-- 4 ms shared budget, only upvalues and cheap reads. Call `tern.chrome.refresh()`
-- (from a timer or event, never from a provider) when their data changes.
local M = {}

type Provider = { order: number, fn: (any) -> { any }? }
local providers: { Provider } = {}

function M.status(order: number, fn: (any) -> { any }?)
	table.insert(providers, { order = order, fn = fn })
	table.sort(providers, function(a, b) return a.order < b.order end)
end

function M.install()
	tern.chrome.status(function(pane)
		local out = {}
		for _, p in providers do
			local ok, segs = pcall(p.fn, pane)
			if ok and segs then
				for _, s in segs do table.insert(out, s) end
			end
		end
		return if #out > 0 then out else nil
	end)
end

return M
