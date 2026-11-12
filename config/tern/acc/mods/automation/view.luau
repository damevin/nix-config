--!nonstrict
local ui = tern.ui
local util = require("../../lib/util")
local M = {}
function M.node(kind, key, part, children, props)
	local p = props or {}
	p.key, p.role = key, "acc.automation." .. part
	return ui.node(kind, p, children)
end
function M.text(text, part, props)
	local p = props or {}
	p.spans, p.role = { ui.span(tostring(text or "")) }, "acc.automation." .. (part or "text")
	return ui.node("text", p)
end
function M.row(children, props) return ui.node("row", props or { gap = "sm", wrap = false }, children) end
function M.button(label, action, value, variant)
	return ui.button(label, { size = "sm", variant = variant or "quiet", actions = { click = action .. (if value then "=" .. tostring(value) else "") } })
end
function M.card(key, children, tone, leaving)
	return M.node("col", key, if leaving then "leaving" else "card", children, { gap = "md", tone = tone })
end
function M.dot(tone, live)
	return ui.node("text", { spans = "", role = if live then "acc.automation.orb" else "acc.dot", tone = tone or "muted" })
end
function M.time(iso)
	local at = util.isoTime(iso)
	if not at or not iso then return at end
	local sign, hours, minutes = iso:match("([%+%-])(%d%d):?(%d%d)$")
	if sign then at -= (if sign == "+" then 1 else -1) * (tonumber(hours) * 3600 + tonumber(minutes) * 60) end
	return at
end
function M.ago(iso)
	local at = if type(iso) == "number" then iso / 1000 else M.time(iso)
	return if at then util.ago(at) .. " ago" else "never"
end
function M.one(s) return util.trim(tostring(s or ""):gsub("%s+", " ")) end
function M.clip(s, n) return util.truncate(M.one(s), n) end
function M.section(label, count, right)
	local c = { M.text(string.upper(label) .. (if count then "  " .. tostring(count) else ""), "section", { grow = 1 }) }
	if right then table.insert(c, right) end
	return M.node("row", "sec-" .. label, "section-row", c)
end
function M.token(n)
	n = tonumber(n) or 0
	return if n >= 1000000 then string.format("%.1fM", n / 1000000) elseif n >= 1000 then string.format("%.1fk", n / 1000) else tostring(math.floor(n))
end
function M.duration(s)
	s = math.max(0, math.floor(s))
	return if s >= 86400 then tostring(s // 86400) .. "d" elseif s >= 3600 then string.format("%dh %02dm", s // 3600, s % 3600 // 60) elseif s >= 60 then string.format("%dm %02ds", s // 60, s % 60) else tostring(s) .. "s"
end
return M
