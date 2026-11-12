--!nonstrict
local ui = tern.ui
local util = require("../../lib/util")
local timer = require("../../lib/timer")
local proc = require("../../lib/proc")

local function short(url)
	if string.find(url, "slack.com/archives/", 1, true) then return "thread" end
	local pr = string.match(url, "github%.com/[^/]+/[^/]+/pull/(%d+)")
	if pr then return "PR #" .. pr end
	local issue = string.match(url, "linear%.app/.*/issue/([A-Z]+%-%d+)")
	if issue then return issue end
	return (url:gsub("^https?://", ""):gsub("^www%.", ""):match("^[^/]*"))
end

local SPACE = {
	[" "] = true, [" "] = true, [" "] = true, [" "] = true, [" "] = true,
	[" "] = true, [" "] = true, [" "] = true, [" "] = true, [" "] = true,
	[" "] = true, [" "] = true, [" "] = true, [" "] = true, [" "] = true,
	[" "] = true, [" "] = true, ["　"] = true, ["﻿"] = true,
}

local function whitespace(text, at)
	if text:sub(at, at):match("%s") then return 1 end
	if SPACE[text:sub(at, at + 1)] then return 2 end
	if SPACE[text:sub(at, at + 2)] then return 3 end
	return 0
end

local function spaceBefore(text, at)
	for size = 1, 3 do
		if at > size and whitespace(text, at - size) == size then return true end
	end
	return false
end

local function lineStart(text, at)
	local previous = text:sub(at - 1, at - 1)
	return at == 1 or previous == "\n" or previous == "\r"
		or text:sub(at - 3, at - 1) == " " or text:sub(at - 3, at - 1) == " "
end

local function word(c)
	return c ~= "" and string.match(c, "[%w_]") ~= nil
end

-- Preserve JavaScript's multiline anchors, consumed prefixes and bold lookahead.
local function headings(text)
	local out, i, mark = {}, 1, 1
	while i <= #text do
		if lineStart(text, i) and text:sub(i, i) == "*" then
			local close = text:find("*", i + 1, true)
			if close and close > i + 1 and not text:sub(i + 1, close - 1):find("\n", 1, true) then
				local tail, finish = close + 1, nil
				while tail <= #text and whitespace(text, tail) > 0 do
					if lineStart(text, tail + whitespace(text, tail)) then finish = tail end
					tail += whitespace(text, tail)
				end
				if tail > #text then finish = tail end
				if finish then
					table.insert(out, text:sub(mark, i - 1))
					table.insert(out, "### " .. text:sub(i + 1, close - 1))
					i, mark = finish, finish
					continue
				end
			end
		end
		i += 1
	end
	table.insert(out, text:sub(mark))
	return table.concat(out)
end

local function bold(text)
	local out, i, mark = {}, 1, 1
	while i <= #text do
		local before = text:sub(i - 1, i - 1)
		if text:sub(i, i) == "*" and (i == 1 or (i > mark and before ~= "*" and not word(before))) then
			local close = text:find("*", i + 1, true)
			if close and close > i + 1 and not text:sub(i + 1, close - 1):find("\n", 1, true) then
				local after = text:sub(close + 1, close + 1)
				if after ~= "*" and not word(after) then
					table.insert(out, text:sub(mark, i - 1))
					table.insert(out, "**" .. text:sub(i + 1, close - 1) .. "**")
					i, mark = close + 1, close + 1
					continue
				end
			end
		end
		i += 1
	end
	table.insert(out, text:sub(mark))
	return table.concat(out)
end

local function bullets(text)
	local out, i, mark = {}, 1, 1
	while i <= #text do
		if lineStart(text, i) then
			local first = i
			while whitespace(text, first) > 0 do first += whitespace(text, first) end
			local bullet = text:sub(first, first + 2)
			if (bullet == "•" or bullet == "◦" or bullet == "▪") and whitespace(text, first + 3) > 0 then
				local finish = first + 3
				while whitespace(text, finish) > 0 do finish += whitespace(text, finish) end
				table.insert(out, text:sub(mark, first - 1))
				table.insert(out, "- ")
				i, mark = finish, finish
				continue
			end
		end
		i += 1
	end
	table.insert(out, text:sub(mark))
	return table.concat(out)
end

local function fromSlack(text)
	text = bullets(bold(headings(text)))
	text = text:gsub("<(https?:[^|>]+)|([^>]+)>", "[%2](%1)")
	local out, i, mark = {}, 1, 1
	while i <= #text do
		local scheme = if text:sub(i, i + 6) == "http://" then 7 elseif text:sub(i, i + 7) == "https://" then 8 else nil
		local first = if scheme then text:sub(i + scheme, i + scheme) else ""
		if scheme and first ~= "" and first ~= ")" and whitespace(text, i + scheme) == 0 and (i == 1 or (i > mark and spaceBefore(text, i))) then
			local stop = i
			while stop <= #text and whitespace(text, stop) == 0 and text:sub(stop, stop) ~= ")" do stop += 1 end
			local url = text:sub(i, stop - 1)
			table.insert(out, text:sub(mark, i - 1))
			table.insert(out, "[" .. short(url) .. "](" .. url .. ")")
			i, mark = stop, stop
		else
			i += 1
		end
	end
	table.insert(out, text:sub(mark))
	return table.concat(out)
end

local function load(state)
	local text = if state.path ~= "" then util.readFile(state.path) else nil
	if text == state.text then return false end
	state.text = text
	state.markdown = if text then fromSlack(text) else nil
	return true
end

return {
	md = {
		font = "sans",
		init = function(cx, args, saved)
			local path = tostring(args[1] or (saved and saved.path) or ""):gsub("^~", util.HOME)
			local state = { path = path, copied = false, text = nil, markdown = nil, copyVersion = 0 }
			load(state)
			timer.blockEvery("md reload", cx, 2000, function()
				if load(state) then cx:render() end
			end)
			return state
		end,
		title = function(state) return if state.path ~= "" then util.basename(state.path) else "Markdown" end,
		save = function(state) return { path = state.path } end,
		view = function(state)
			local name = if state.path ~= "" then util.basename(util.dirname(state.path)) .. " / " .. util.basename(state.path) else "No file"
			return { main = ui.node("col", { role = "acc.md.main", gap = "none" }, {
				ui.node("row", { key = "header", role = "acc.md.header", gap = "sm" }, {
					ui.node("text", { key = "name", role = "acc.md.name", text = name, overflow = "ellipsis", grow = 1 }),
					ui.button("Edit", { key = "edit", role = "acc.md.edit", actions = { click = "edit-file" }, disabled = state.path == "" }),
					ui.button(if state.copied then "Copied ✓" else "Copy", { key = "copy", role = "acc.md.copy", variant = "primary", actions = { click = "copy-file" }, disabled = state.text == nil }),
				}),
				ui.node("scroll", { key = "scroll", role = "acc.md.scroll", grow = 1, min = { h = 0 } }, {
					if state.markdown then ui.node("md", { key = "body", role = "acc.md.body", text = state.markdown })
					else ui.node("text", { key = "unavailable", role = "acc.md.unavailable", text = "This file is not available." }),
				}),
			}) }
		end,
		event = function(state, ev, cx)
			if ev.ev ~= "action" then return end
			if ev.act == "edit-file" and state.path ~= "" then
				proc.run("md edit", { "/usr/bin/open", "-t", state.path })
			elseif ev.act == "copy-file" then
				local text = util.readFile(state.path)
				if not text then cx:toast("error", "Copy failed"); return end
				cx:copy(text)
				state.copied = true
				state.copyVersion += 1
				local version = state.copyVersion
				timer.later("md copied", 1600, function()
					if timer.alive(cx.pane) and version == state.copyVersion then state.copied = false; cx:render() end
				end)
			end
		end,
	},
}
