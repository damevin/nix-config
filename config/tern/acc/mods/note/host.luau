--!nonstrict
local ui = tern.ui
local util = require("../../lib/util")
local field = require("../../lib/field")
local timer = require("../../lib/timer")
local proc = require("../../lib/proc")

local INBOX = "00. inbox"
local DIR = util.HOME .. "/Documents/observatory/" .. INBOX
local INVALID = '*"\\/<>:|?#^[]'

local function clean(text)
	local out, units = {}, 0
	text = text:gsub(".", function(c) return if INVALID:find(c, 1, true) then " " else c end)
	text = util.trim(text:gsub("%s+", " "))
	for _, code in utf8.codes(text) do
		units += if code > 0xFFFF then 2 else 1
		if units > 120 then break end
		table.insert(out, utf8.char(code))
	end
	return table.concat(out)
end

-- Tern's fs.write replaces files. O_EXCL keeps the collision check and create atomic.
local CREATE = [[
import os, sys
root, base = sys.argv[1:]
text = sys.stdin.buffer.read()
for suffix in range(1, 50):
    name = base if suffix == 1 else f"{base} {suffix}"
    path = os.path.join(root, name + ".md")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        continue
    try:
        with os.fdopen(fd, "wb") as note:
            note.write(text)
    except BaseException:
        os.unlink(path)
        raise
    sys.stdout.write(name)
    break
else:
    sys.exit("All 49 note names already exist")
]]

local function close(state, cx)
	state.closed = true
	cx:exit(0)
end

local function save(state, cx, open)
	if state.saving or state.closed then return end
	local text = state.body.text:gsub("%s+$", "") .. "\n"
	if util.trim(text) == "" then close(state, cx); return end
	local first = ""
	for line in string.gmatch(text, "[^\n]+") do
		if util.trim(line) ~= "" then first = line:gsub("^#+%s*", ""); break end
	end
	local base = clean(state.title.text)
	if base == "" then base = clean(first) end
	if base == "" then base = os.date("%Y-%m-%d %Hh%M") end
	state.saving, state.error = true, nil
	proc.run("note save", { "python3", "-c", CREATE, DIR, base }, { stdin = text, timeout_ms = 10000 }, function(r)
		if state.closed or not timer.alive(cx.pane) then return end
		if r.status ~= 0 then
			state.saving = false
			state.error = "Could not write to " .. DIR
			cx:toast("error", "Note not saved", state.error)
			cx:render()
			return
		end
		local name = r.stdout
		cx:toast("success", "Note saved", INBOX .. "/" .. name)
		if open then
			proc.run("note Obsidian", { "/usr/bin/open", "obsidian://open?vault=observatory&file=" .. util.urlencode(INBOX .. "/" .. name) })
		end
		close(state, cx)
	end)
end

local function focus(state, cx, name)
	state.focus = name
	field.focus(cx, "main." .. name)
end

local function change(state, operation)
	local current = state[state.focus]
	local previous = util.copy(current)
	local changed = operation(current)
	if changed and previous.text ~= current.text then
		table.insert(state.undo[state.focus], previous)
		state.redo[state.focus] = {}
	end
	return changed
end

local function undo(state, redo)
	local from = if redo then state.redo[state.focus] else state.undo[state.focus]
	local to = if redo then state.undo[state.focus] else state.redo[state.focus]
	local previous = table.remove(from)
	if not previous then return false end
	table.insert(to, util.copy(state[state.focus]))
	state[state.focus] = previous
	return true
end

return {
	note = {
		font = "sans",
		features = { "edit", "undo" },
		init = function(cx, _args, saved)
			local state = {
				title = field.new(saved and saved.title or ""), body = field.new(saved and saved.body or "", true),
				focus = "title", saving = false, closed = false, error = nil,
				undo = { title = {}, body = {} }, redo = { title = {}, body = {} },
			}
			timer.later("note focus", 0, function()
				if timer.alive(cx.pane) then focus(state, cx, state.focus) end
			end)
			return state
		end,
		title = function() return "Quick note" end,
		save = function(state) return { title = state.title.text, body = state.body.text } end,
		view = function(state)
			return { main = ui.node("col", { role = "acc.note.main", gap = "md" }, {
				ui.node("input", field.props(state.title, { key = "title", role = "acc.note.title", placeholder = "Title (empty = first line or date)", aria = "Note title", disabled = state.saving })),
				ui.node("editor", field.props(state.body, { key = "body", role = "acc.note.body", placeholder = "Capture a note…", aria = "Note Markdown", lang = "markdown", grow = 1, disabled = state.saving })),
				ui.node("text", { key = "error", role = "acc.note.error", text = state.error or "", hidden = state.error == nil }),
				ui.node("row", { key = "footer", role = "acc.note.footer", gap = "sm" }, {
					ui.node("text", { key = "destination", role = "acc.note.destination", text = "→ " .. INBOX .. "/", grow = 1 }),
					ui.button("Save and open", { key = "open", role = "acc.note.open", keys = { "cmd", "shift", "enter" }, actions = { click = "save-open" }, disabled = state.saving }),
					ui.button(if state.saving then "Saving…" else "Save", { key = "save", role = "acc.note.save", keys = { "cmd", "enter" }, actions = { click = "save-note" }, disabled = state.saving }),
				}),
			}) }
		end,
		key = function(state, key, cx)
			if key.name == "escape" then close(state, cx); return true end
			if state.saving then return false end
			if key.name == "enter" and key.meta then save(state, cx, key.shift); return true end
			if key.name == "tab" or (key.name == "enter" and state.focus == "title") then
				focus(state, cx, if state.focus == "title" then "body" else "title")
				return true
			end
			if (key.meta or key.ctrl) and key.name == "z" then return undo(state, key.shift) end
			return change(state, function(current) return field.key(current, key) end)
		end,
		event = function(state, ev, cx)
			if ev.ev == "action" then
				if ev.act == "save-note" then save(state, cx, false)
				elseif ev.act == "save-open" then save(state, cx, true) end
				return
			end
			if state.saving then return end
			local name = if ev.id == "main.title" then "title" elseif ev.id == "main.body" then "body" else nil
			if not name then return end
			if ev.ev == "focus" then focus(state, cx, name)
			elseif ev.ev == "edit" then
				state.focus = name
				change(state, function(current) return field.edit(current, ev) end)
			elseif ev.ev == "undo" then state.focus = name; undo(state, false) end
		end,
	},
}
