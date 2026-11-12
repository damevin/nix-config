--!nonstrict
-- Text fields for blocks. Tern draws `input` and `editor` nodes but never edits
-- them: keys reach the block, which answers with new `text`, `cursor` and
-- `anchor`. Positions here are code points; the view speaks UTF-16.
-- Blocks that set `features = { "edit", "undo" }` also get native `edit`
-- events (clicks, drags, selections), applied with `Field.edit`.
local M = {}

export type Field = { text: string, cursor: number, anchor: number?, multiline: boolean }

local function byteAt(text: string, position: number): number
	return utf8.offset(text, position + 1) or (#text + 1)
end

local function len(text: string): number
	return utf8.len(text) or #text
end

function M.new(text: string?, multiline: boolean?): Field
	text = text or ""
	if not utf8.len(text) then text = "" end
	return { text = text, cursor = len(text), anchor = nil, multiline = multiline == true }
end

function M.set(field: Field, text: string)
	field.text = text
	field.cursor = len(text)
	field.anchor = nil
end

local function toUtf16(text: string, position: number): number
	local units, count = 0, 0
	for _, code in utf8.codes(text) do
		if count >= position then break end
		units += if code > 0xFFFF then 2 else 1
		count += 1
	end
	return units
end

local function fromUtf16(text: string, units: number): number
	local u, count = 0, 0
	for _, code in utf8.codes(text) do
		if u >= units then break end
		u += if code > 0xFFFF then 2 else 1
		count += 1
	end
	return count
end

-- Props for an `input` or `editor` node: merge your own (key, placeholder…).
function M.props(field: Field, extra: { [string]: any }?): { [string]: any }
	local p = {
		text = field.text,
		cursor = toUtf16(field.text, field.cursor),
		anchor = if field.anchor ~= nil then toUtf16(field.text, field.anchor) else nil,
	}
	for k, v in (extra or {}) do p[k] = v end
	return p
end

local function bounds(field: Field): (number, number)
	local anchor = field.anchor or field.cursor
	return math.min(anchor, field.cursor), math.max(anchor, field.cursor)
end

function M.selection(field: Field): string
	local first, last = bounds(field)
	return string.sub(field.text, byteAt(field.text, first), byteAt(field.text, last) - 1)
end

local function replace(field: Field, text: string)
	local first, last = bounds(field)
	field.text = string.sub(field.text, 1, byteAt(field.text, first) - 1)
		.. text .. string.sub(field.text, byteAt(field.text, last))
	field.cursor = first + len(text)
	field.anchor = nil
end

local function move(field: Field, position: number, shift: boolean?)
	if shift then
		field.anchor = field.anchor or field.cursor
	else
		field.anchor = nil
	end
	field.cursor = position
end

-- Code-point index of the start of the line holding `position`, and its column.
local function lineOf(text: string, position: number): (number, number)
	local start, i = 0, 0
	for _, code in utf8.codes(text) do
		if i >= position then break end
		i += 1
		if code == 10 then start = i end
	end
	return start, position - start
end

local function lineEnd(text: string, from: number): number
	local i = 0
	for _, code in utf8.codes(text) do
		if i >= from and code == 10 then return i end
		i += 1
	end
	return i
end

-- Applies an editing key. Returns true when it changed the field or the caret.
-- Enter inserts a newline only in a multiline field; intercept your submit
-- chords before calling this.
function M.key(field: Field, key): boolean
	local length = len(field.text)
	local name = key.name
	if key.meta and string.lower(name) == "a" then
		field.anchor, field.cursor = 0, length
	elseif name == "home" or (key.meta and name == "left") then
		local start = if field.multiline then (lineOf(field.text, field.cursor)) else 0
		move(field, start, key.shift)
	elseif name == "end" or (key.meta and name == "right") then
		local stop = if field.multiline then lineEnd(field.text, field.cursor) else length
		move(field, stop, key.shift)
	elseif name == "left" or name == "right" then
		local first, last = bounds(field)
		local position
		if not key.shift and first ~= last then
			position = if name == "left" then first else last
		elseif key.alt then
			-- Word jump.
			local bytes = byteAt(field.text, field.cursor)
			if name == "left" then
				local before = string.sub(field.text, 1, bytes - 1)
				local cut = string.find(before, "[%w_]*[^%w_]*$") or 1
				position = len(string.sub(field.text, 1, cut - 1))
			else
				local _, stop = string.find(field.text, "^[^%w_]*[%w_]*", bytes)
				position = len(string.sub(field.text, 1, stop or #field.text))
			end
		else
			position = math.clamp(field.cursor + (if name == "left" then -1 else 1), 0, length)
		end
		move(field, position, key.shift)
	elseif field.multiline and (name == "up" or name == "down") then
		local start, column = lineOf(field.text, field.cursor)
		local target
		if name == "up" then
			if start == 0 then return false end
			local prevStart = (lineOf(field.text, start - 1))
			target = math.min(prevStart + column, start - 1)
		else
			local stop = lineEnd(field.text, field.cursor)
			if stop >= length then return false end
			local nextStop = lineEnd(field.text, stop + 1)
			target = math.min(stop + 1 + column, nextStop)
		end
		move(field, target, key.shift)
	elseif name == "backspace" or name == "delete" then
		local first, last = bounds(field)
		if first == last then
			if key.meta and name == "backspace" then
				field.anchor = if field.multiline then (lineOf(field.text, field.cursor)) else 0
			elseif key.alt and name == "backspace" then
				local before = string.sub(field.text, 1, byteAt(field.text, field.cursor) - 1)
				local cut = string.find(before, "[%w_]*[^%w_]*$") or 1
				field.anchor = len(string.sub(field.text, 1, cut - 1))
			else
				field.anchor = if name == "backspace" then math.max(0, field.cursor - 1)
					else math.min(length, field.cursor + 1)
			end
		end
		replace(field, "")
	elseif name == "enter" and field.multiline and not (key.meta or key.ctrl) then
		replace(field, "\n")
	elseif name == "paste" and key.text then
		local text = key.text
		if not field.multiline then text = string.gsub(text, "[\r\n]+", " ") end
		replace(field, text)
	elseif key.text and key.text ~= "" and not (key.ctrl or key.meta) and name ~= "enter" and name ~= "tab"
		and name ~= "escape" then
		replace(field, key.text)
	else
		return false
	end
	return true
end

-- Applies a native `edit` event; false when it was computed against other text.
function M.edit(field: Field, ev): boolean
	if ev.len ~= nil and ev.len ~= toUtf16(field.text, len(field.text)) then return false end
	local from = fromUtf16(field.text, ev.from or 0)
	local to = fromUtf16(field.text, ev.to or ev.from or 0)
	local text = ev.text or ""
	if not field.multiline then text = string.gsub(text, "[\r\n]+", " ") end
	field.text = string.sub(field.text, 1, byteAt(field.text, from) - 1) .. text
		.. string.sub(field.text, byteAt(field.text, to))
	field.cursor = fromUtf16(field.text, ev.cursor or toUtf16(field.text, from + len(text)))
	field.anchor = nil
	return true
end

-- Gives node `id` (a full node id such as "main.form.title") the caret.
function M.focus(cx, id: string)
	pcall(function() cx:frame({ { "focus", id } }) end)
end

return M
