--!nonstrict
-- Timers. `tern.timer` fires once; `every` re-arms itself. In the window half
-- a callback gets 50 ms of Lua, so window work stays in labelled callbacks and
-- other hooks only queue it.
local M = {}

local lastStarted: string? = nil

-- Runs fn(cx) once after `ms`; errors are logged under `label`, never raised.
function M.later(label: string, ms: number, fn: (any) -> ())
	return tern.timer(ms, function(cx)
		lastStarted = label
		local ok, err = pcall(fn, cx)
		if not ok then tern.log.warn("acc: " .. label .. " failed: " .. tostring(err)) end
	end)
end

-- Runs fn(cx) every `ms` (first run after `ms`, or at once with `now`) until
-- `stop()` is called or fn returns false. Returns { stop = fn }.
function M.every(label: string, ms: number, fn: (any) -> boolean?, now: boolean?)
	local handle = { stopped = false, timer = nil }
	local function tick(cx)
		if handle.stopped then return end
		lastStarted = label
		local ok, result = pcall(fn, cx)
		if not ok then tern.log.warn("acc: " .. label .. " failed: " .. tostring(result)) end
		if handle.stopped or result == false then return end
		handle.timer = tern.timer(ms, tick)
	end
	handle.timer = tern.timer(if now then 0 else ms, tick)
	function handle.stop()
		handle.stopped = true
		if handle.timer then handle.timer:cancel() end
	end
	return handle
end

-- Host half: whether block pane `pane` still runs.
function M.alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then return true end
	end
	return false
end

-- Host half: `every` that stops when the block's pane is gone.
function M.blockEvery(label: string, cx: any, ms: number, fn: () -> boolean?, now: boolean?)
	return M.every(label, ms, function()
		if not M.alive(cx.pane) then return false end
		return fn()
	end, now)
end

-- The `budget` event's text for the log.
function M.describe(ev): string
	if ev.state ~= "paused" then return "acc: Tern resumed its " .. ev.hook .. " hook." end
	local culprit = if ev.hook == "timer" and lastStarted then " (" .. lastStarted .. ")" else ""
	return string.format("acc: Tern paused its %s hook for %.0f s after a callback%s ran over %.0f ms.",
		ev.hook, (ev.paused_ms or 0) / 1000, culprit, ev.ms or 0)
end

return M
