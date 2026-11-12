--!nonstrict
-- The Obsidian vault side of the Tasks panel: dates, note paths, the Tasks
-- plugin's inline fields, and every text edit the panel makes. Lines are
-- 1-based; dates are { y, m, d } in local time.
local util = require("../../lib/util")

local M = {}

M.VAULT = util.HOME .. "/Documents/observatory"
M.VAULT_NAME = "observatory"
M.DAILY = "12. journal/daily"
M.WEEKLY = "12. journal/weekly"
M.DAILY_TPL = "06. templates/Daily note.md"
M.WEEKLY_TPL = "06. templates/Weekly note.md"

local STOP = { "📅", "✅", "⏳", "🛫", "➕", "⏫", "🔼", "🔽" }
local DATED = { "📅", "⏳", "🛫", "➕", "✅" }
local PRIORITY = { "⏫", "🔼", "🔽" }
local RECUR = "🔁"

local function p2(n: number): string return string.format("%02d", n) end

-- ——— dates ———

function M.today()
	local t = os.date("*t")
	return { y = t.year, m = t.month, d = t.day }
end

local function stamp(d, offset: number?): number
	return os.time({ year = d.y, month = d.m, day = d.d + (offset or 0), hour = 12 })
end

function M.addDays(d, n: number)
	local t = os.date("*t", stamp(d, n))
	return { y = t.year, m = t.month, d = t.day }
end

function M.weekday(d): number
	return os.date("*t", stamp(d)).wday - 1
end

function M.ymd(d): string
	return string.format("%04d-%02d-%02d", d.y, d.m, d.d)
end

local function saturday(d)
	return M.addDays(d, 6 - M.weekday(d))
end

local function weekOfYear(d): number
	local doy = os.date("*t", stamp(saturday(d))).yday
	return (doy - 1) // 7 + 1
end

function M.weekName(d): string
	return saturday(d).y .. "-W" .. p2(weekOfYear(d))
end

local TOKENS = { "gggg", "YYYY", "MM", "DD", "ww" }

-- Moment-style formatting for the tokens the templates use; [text] is literal.
local function fmt(d, pattern: string): string
	local out, i = {}, 1
	while i <= #pattern do
		local lit = if string.sub(pattern, i, i) == "[" then string.find(pattern, "]", i, true) else nil
		if lit then
			table.insert(out, string.sub(pattern, i + 1, lit - 1))
			i = lit + 1
		else
			local hit = nil
			for _, token in TOKENS do
				if string.sub(pattern, i, i + #token - 1) == token then hit = token break end
			end
			if hit == "gggg" then table.insert(out, tostring(saturday(d).y))
			elseif hit == "YYYY" then table.insert(out, tostring(d.y))
			elseif hit == "MM" then table.insert(out, p2(d.m))
			elseif hit == "DD" then table.insert(out, p2(d.d))
			elseif hit == "ww" then table.insert(out, p2(weekOfYear(d)))
			end
			if hit then
				i += #hit
			else
				table.insert(out, string.sub(pattern, i, i))
				i += 1
			end
		end
	end
	return table.concat(out)
end

-- Fills `<% tp.date.now("fmt", offset) %>`; nil when other Templater code remains.
function M.render(template: string, d): string?
	local out = string.gsub(template, '<%%%s*tp%.date%.now%("([^"]+)"%s*,%s*(%-?%d+)%)%s*%%>', function(pattern, offset)
		return fmt(M.addDays(d, tonumber(offset)), pattern)
	end)
	out = string.gsub(out, '<%%%s*tp%.date%.now%("([^"]+)"%)%s*%%>', function(pattern)
		return fmt(d, pattern)
	end)
	if string.find(out, "<%", 1, true) then return nil end
	return out
end

function M.dayPath(vault: string, d): string return vault .. "/" .. M.DAILY .. "/" .. M.ymd(d) .. ".md" end
function M.weekPath(vault: string, d): string return vault .. "/" .. M.WEEKLY .. "/" .. M.weekName(d) .. ".md" end

-- ——— lines ———

local function split(text: string): { string }
	local out, pos = {}, 1
	while true do
		local nl = string.find(text, "\n", pos, true)
		if not nl then
			table.insert(out, string.sub(text, pos))
			return out
		end
		table.insert(out, string.sub(text, pos, nl - 1))
		pos = nl + 1
	end
end

local function join(lines: { string }): string return table.concat(lines, "\n") end

local function trim(s: string): string return util.trim(s) end

local function taskOf(line: string)
	return string.match(line, "^(%s*)%- %[([ xX])%] ?(.*)$")
end

local function headOf(line: string): string?
	local hashes, rest = string.match(line, "^(#+)%s+(.-)%s*$")
	if hashes and #hashes <= 6 then return rest end
	return nil
end

local function startsWith(s: string, at: number, lit: string): boolean
	return string.sub(s, at, at + #lit - 1) == lit
end

local function anyAt(s: string, at: number, list: { string }): string?
	for _, e in list do
		if startsWith(s, at, e) then return e end
	end
	return nil
end

-- Last byte of the Tasks-plugin token that begins exactly at `at`, or nil.
local function tokenAt(s: string, at: number): number?
	local dated = anyAt(s, at, DATED)
	if dated then
		local _, ws = string.find(s, "^%s*", at + #dated)
		local k = ws + 1
		if string.match(string.sub(s, k, k + 9), "^%d%d%d%d%-%d%d%-%d%d$") then return k + 9 end
		return nil
	end
	if startsWith(s, at, RECUR) then
		local j = at + #RECUR
		while j <= #s and not anyAt(s, j, STOP) do j += 1 end
		return j - 1
	end
	local p = anyAt(s, at, PRIORITY)
	if p then return at + #p - 1 end
	return nil
end

-- Every inline field token with the whitespace before it: { first, last }.
local function tokens(s: string)
	local out, pos = {}, 1
	while pos <= #s do
		local _, ws = string.find(s, "^%s*", pos)
		local last = tokenAt(s, ws + 1)
		if last then
			table.insert(out, { first = pos, last = last })
			pos = last + 1
		else
			pos += 1
		end
	end
	return out
end

function M.parse(text: string)
	local lines, tasks = split(text), {}
	local section, fence, front = "", false, lines[1] == "---"
	for i, l in lines do
		if front then
			if i > 1 and l == "---" then front = false end
			continue
		end
		if string.match(l, "^%s*```") then
			fence = not fence
			continue
		end
		if fence then continue end
		local h = headOf(l)
		if h then
			section = h
			continue
		end
		local _, mark, rest = taskOf(l)
		if mark then
			table.insert(tasks, { i = i, raw = l, done = mark ~= " ", text = trim(rest), section = section })
		end
	end
	return { lines = lines, tasks = tasks }
end

function M.isToday(section: string): boolean
	return string.match(string.lower(section), "^today'?s tasks$") ~= nil
end

function M.isGoals(section: string): boolean
	return string.find(string.lower(section), "goals", 1, true) ~= nil
end

-- Due date, recurrence rule, the text without inline fields and the Linear key.
function M.meta(text: string)
	local due = string.match(text, "📅%s*(%d%d%d%d%-%d%d%-%d%d)")
	local rule = nil
	local at = string.find(text, RECUR, 1, true)
	if at then
		local from, stop = at + #RECUR, #text + 1
		for _, e in STOP do
			local hit = string.find(text, e, from, true)
			if hit and hit < stop then stop = hit end
		end
		rule = trim(string.sub(text, from, stop - 1))
	end
	local clean, pos = {}, 1
	for _, t in tokens(text) do
		table.insert(clean, string.sub(text, pos, t.first - 1))
		pos = t.last + 1
	end
	table.insert(clean, string.sub(text, pos))
	local linear = string.match(string.upper(text), "%f[%w_](LIV%-%d+)%f[^%w_]")
	return { due = due, clean = trim(table.concat(clean)), rule = rule, linear = linear, recurring = at ~= nil }
end

function M.keyOf(task): string
	local clean = M.meta(task.text).clean
	return if clean ~= "" then clean else task.text
end

-- Rewrites a task line with a new title; `due`: nil keeps it, false clears it, a date sets it.
function M.rebuild(raw: string, title: string, due)
	local indent, mark, rest = taskOf(raw)
	if not mark then return nil end
	local list = {}
	for _, t in tokens(rest) do table.insert(list, trim(string.sub(rest, t.first, t.last))) end
	if due ~= nil then
		local kept = {}
		for _, t in list do
			if not startsWith(t, 1, "📅") then table.insert(kept, t) end
		end
		list = kept
		if due then
			local at = #list + 1
			for i, t in list do
				if startsWith(t, 1, "✅") then at = i break end
			end
			table.insert(list, at, "📅 " .. due)
		end
	end
	return indent .. "- [" .. mark .. "] " .. title .. (if #list > 0 then " " .. table.concat(list, " ") else "")
end

function M.toggled(raw: string, today: string)
	local indent, mark, rest = taskOf(raw)
	if not mark then return nil end
	if mark == " " then
		return indent .. "- [x] " .. string.gsub(rest, "%s+$", "") .. " ✅ " .. today
	end
	local open = string.gsub(rest, "%s*✅%s*%d%d%d%d%-%d%d%-%d%d", "")
	return indent .. "- [ ] " .. string.gsub(open, "%s+$", "")
end

-- ——— inserting ———

local function insertAfterHeading(text: string, headTest, fallback: string, line: string): string
	local lines = split(text)
	local idx
	for i, l in lines do
		local h = headOf(l)
		if h and headTest(h) then idx = i break end
	end
	if not idx then
		return string.gsub(text, "\n+$", "") .. "\n\n" .. fallback .. "\n\n" .. line .. "\n"
	end
	local stop = #lines + 1
	for i = idx + 1, #lines do
		if headOf(lines[i]) then stop = i break end
	end
	local range, blank = {}, nil
	for i = idx + 1, stop - 1 do
		local _, mark, rest = taskOf(lines[i])
		if mark then
			table.insert(range, i)
			if not blank and mark == " " and trim(rest) == "" then blank = i end
		end
	end
	if blank then
		lines[blank] = line
	elseif #range > 0 then
		table.insert(lines, range[#range] + 1, line)
	else
		table.insert(lines, idx + 1, "")
		table.insert(lines, idx + 2, line)
	end
	return join(lines)
end

function M.withTask(text: string, task: string): string
	return insertAfterHeading(text, M.isToday, "#### Today's tasks", "- [ ] " .. task)
end

function M.withGoal(text: string, goal: string): string
	return insertAfterHeading(text, M.isGoals, "#### Weekly focus and goals", "- [ ] " .. goal)
end

local function isNotesHead(line: string): boolean
	local h = headOf(line)
	return h ~= nil and string.lower(h) == "notes"
end

function M.withNote(text: string, note: string): string
	local lines = split(text)
	local idx
	for i, l in lines do
		if isNotesHead(l) then idx = i break end
	end
	if not idx then
		return string.gsub(text, "\n+$", "") .. "\n\n##### Notes\n\n- " .. note .. "\n"
	end
	local at = idx + 1
	while at <= #lines do
		local blank = trim(lines[at]) == ""
		local ok = if blank then at == idx + 1 else string.match(lines[at], "^%s*[-*] ") ~= nil
		if not ok then break end
		at += 1
	end
	table.insert(lines, at, "- " .. note)
	if at == idx + 1 then table.insert(lines, idx + 1, "") end
	return join(lines)
end

function M.parseNotes(text: string)
	local lines, out = split(text), {}
	local idx
	for i, l in lines do
		if isNotesHead(l) then idx = i break end
	end
	if not idx then return out end
	for i = idx + 1, #lines do
		local l = lines[i]
		if headOf(l) or string.match(l, "^%-%-%-%s*$") then break end
		local note = string.match(l, "^%s*[-*] (.*%S)%s*$")
		if note and not string.match(note, "^%[[ xX]%]") then table.insert(out, { i = i, text = note }) end
	end
	return out
end

-- ——— keys ———

local function hash(s: string): string
	local h = 5381
	for i = 1, #s do h = (h * 33 + string.byte(s, i)) % 4294967296 end
	return string.format("%08x", h)
end

-- Stable node keys: a prefix, a hash of the title and the occurrence number.
function M.keyed(prefix: string, list, of)
	local seen, out = {}, {}
	for _, x in list do
		local k = prefix .. "-" .. hash(of(x))
		seen[k] = (seen[k] or 0) + 1
		table.insert(out, { k .. "-" .. seen[k], x })
	end
	return out
end

return M
