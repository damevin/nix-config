--!nonstrict
local ui = tern.ui
local bridge = require("../../lib/bridge")
local facts = require("../../lib/facts")
local field = require("../../lib/field")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local util = require("../../lib/util")
local wt = require("../../lib/wt")
local CATALOG = {
	{ "claude", "Claude Code", "app-claude" }, { "codex", "Codex", "app-codex" },
	{ "omp", "ᴏᴍᴘ", "app-omp" }, { "gemini", "Gemini", "sparkle" },
	{ "opencode", "OpenCode", "code" }, { "aider", "Aider", "terminal" },
	{ "amp", "Amp", "bolt" }, { "cursor-agent", "Cursor", "cursor" },
	{ "copilot", "Copilot", "user" }, { "goose", "Goose", "user" }, { "hermes", "Hermes", "app-hermes" },
}
local function detect()
	local installed, absent, omp = {}, {}, nil
	for _, item in CATALOG do
		local a = { key = item[1], name = item[2], icon = item[3], installed = proc.which(item[1]) ~= nil }
		if a.installed then
			if a.key == "omp" then omp = a else table.insert(installed, a) end
		else table.insert(absent, a) end
	end
	if omp then table.insert(installed, math.min(3, #installed + 1), omp) end
	local choices = table.clone(installed)
	for i = 1, math.min(2, #absent) do table.insert(choices, absent[i]) end
	tern.kv.set("newmenu:agents", choices)
	return choices
end
local function row(key, text, icon, action, hint, disabled)
	return ui.node("row", { key = key, role = if disabled then "acc.newmenu.uninstalled" else "acc.newmenu.row", actions = if disabled then nil else { click = action } }, {
		ui.node("icon", { name = icon, role = if key == "omp" then "acc.newmenu.omp" else "acc.newmenu.icon" }),
		ui.node("text", { text = text, grow = 1 }),
		ui.node("text", { text = hint or "", role = "acc.newmenu.hint" }),
	})
end
local function dismiss(cx) bridge.send(cx, "newmenu.dismiss", {}) end
local function launch(state, cx, kind, program)
	bridge.send(cx, "newmenu.launch", { kind = kind, program = program, cwd = state.cwd })
end
local function beginForm(state, cx, mode)
	state.mode, state.focus = mode, "repo"
	bridge.send(cx, "newmenu.resize", { mode = mode })
	field.focus(cx, "main.body.repo.input")
	if mode == "open" then
		wt.list(state.fields.repo.text, function(list)
			if timer.alive(cx.pane) then state.worktrees = list or {}; cx:render() end
		end)
	end
end
local function submit(state, cx)
	local repo, branch = util.trim(state.fields.repo.text), util.trim(state.fields.branch.text)
	if repo == "" or branch == "" then state.error = "Enter a repository and branch."; return end
	bridge.send(cx, "newmenu.worktree", {
		repo = repo, branch = branch, create = state.mode == "create",
		base = if util.trim(state.fields.base.text) ~= "" then util.trim(state.fields.base.text) else nil,
		command = if util.trim(state.fields.command.text) ~= "" then state.fields.command.text else "omp",
		prompt = state.fields.prompt.text,
	})
end
local function preference(key, item)
	local p = tern.kv.get("usage:prefs") or {}
	if item then
		local values = p[key] or {}
		local at = table.find(values, item)
		if at then table.remove(values, at) else table.insert(values, item) end
		p[key] = tern.json.array(values)
	else p[key] = not (if key == "showBars" then p[key] ~= false else p[key] == true) end
	tern.kv.set("usage:prefs", p)
end
local function usageView(state)
	local model = tern.kv.get("usage:card") or { groups = {} }
	local prefs = tern.kv.get("usage:prefs") or {}
	local children = {
		ui.node("text", { text = if state.settings then "Usage settings" else "Usage limits", role = "acc.newmenu.heading" }),
	}
	if state.settings then
		for _, id in { "claude", "codex" } do
			local on = not table.find(prefs.hidden or {}, id)
			table.insert(children, row(id, (if on then "✓ " else "○ ") .. (if id == "claude" then "Claude" else "Codex"), if id == "claude" then "app-claude" else "app-codex", "pref-provider=" .. id))
			for _, g in model.groups or {} do
				if g.providerId ~= id then continue end
				for _, r in g.rows or {} do
					local key = id .. ":" .. r.id
					local shown = not table.find(prefs.hiddenWindows or {}, key)
					table.insert(children, row(key, (if shown then "✓ " else "○ ") .. r.long, "gauge", "pref-window=" .. key))
				end
			end
		end
		table.insert(children, ui.rule())
		table.insert(children, row("reset", (if prefs.showResetTime then "✓ " else "○ ") .. "Always show time to reset", "clock", "pref=showResetTime"))
		table.insert(children, row("bars", (if prefs.showBars ~= false then "✓ " else "○ ") .. "Show bars", "gauge", "pref=showBars"))
		table.insert(children, ui.rule("This session"))
		for _, name in { "context", "calls", "compactions" } do
			local on = table.find(prefs.sessionOnBar or {}, name) ~= nil
			table.insert(children, row("session-" .. name, (if on then "✓ " else "○ ") .. name, "gauge", "pref-session=" .. name))
		end
		table.insert(children, row("back", "Back to limits", "back", "usage-back"))
	else
		if type(model.session) == "table" then
			local s = model.session
			table.insert(children, ui.text({ ui.span("This session", "strong"), ui.span(" · " .. (s.title or ""), "muted") }))
			local context = { ui.node("text", { text = "ctx " .. s.context.text, grow = 1 }) }
			if type(s.context.fill) == "number" then table.insert(context, ui.node("meter", { value = s.context.fill, thresholds = { warn = 0.7, bad = 0.9 } })) end
			table.insert(children, ui.row(context))
			local details = {}
			for _, text in { s.context.detail, s.calls, s.compactions, s.last } do if type(text) == "string" then table.insert(details, text) end end
			table.insert(children, ui.node("text", { text = table.concat(details, " · "), tone = "muted" }))
			table.insert(children, ui.rule())
		end
		for _, g in model.groups or {} do
			local nodes = { ui.text({ ui.span(g.name, "strong"), ui.span(if g.plan and g.plan ~= tern.json.null then " · " .. g.plan else "", "muted") }), ui.node("text", { text = g.status or "loading…", tone = if g.failed then "error" else "muted" }) }
			if type(g.age) == "string" then table.insert(nodes, ui.node("text", { text = g.age, tone = "muted" })) end
			for _, r in g.rows or {} do
				table.insert(nodes, ui.node("row", { role = "acc.newmenu.limit" }, {
					ui.node("text", { text = r.long, grow = 1 }),
					ui.node("meter", { value = r.fill, label = r.percent, thresholds = { warn = 0.7, bad = 0.9 }, marks = if type(r.tick) == "number" then { { at = r.tick, title = r.hint } } else nil, title = r.hint }),
					ui.node("text", { text = r.left or "", tone = "muted" }),
				}))
				if r.detail and r.detail ~= "" then table.insert(nodes, ui.node("text", { text = r.detail, tone = "muted" })) end
			end
			table.insert(children, ui.node("col", { key = g.providerId, role = "acc.newmenu.provider", gap = "sm" }, nodes))
		end
		if #(model.groups or {}) == 0 then table.insert(children, ui.node("text", { text = "No usage limits available. Install Claude Code or Codex to show limits.", tone = "muted" })) end
		table.insert(children, ui.rule())
		table.insert(children, row("refresh", "Refresh now", "repeat", "usage-refresh", "30s cooldown"))
		table.insert(children, row("settings", "Settings", "gear", "usage-settings"))
	end
	table.insert(children, ui.node("text", { text = "Data: Claude and Codex CLIs. Percentages show quota used. Dated readings stay marked when a provider fails.", tone = "muted", role = "acc.newmenu.foot" }))
	return ui.node("col", { role = "acc.newmenu.usage", gap = "sm" }, children)
end
return { newmenu = {
	font = "sans", features = { "edit", "undo" },
	init = function(cx, args, saved)
		local cwd = if args[2] and args[2] ~= "" then args[2] else facts.focusedCwd() or cx.cwd or util.HOME
		local state = { cwd = cwd, mode = args[1] or "menu", agents = tern.kv.get("newmenu:agents") or {}, focus = "repo", fields = { repo = field.new(cwd), branch = field.new(), base = field.new(), command = field.new("omp"), prompt = field.new() } }
		timer.later("new menu installed agents", 0, function()
			if not timer.alive(cx.pane) then return end
			state.agents = detect(); cx:render()
		end)
		timer.blockEvery("new menu usage detail", cx, 1000, function() if state.mode == "usage" then cx:render() end end)
		return state
	end,
	title = function(state) return if state.mode == "usage" then "Usage limits" else "New…" end,
	view = function(state)
		if state.mode == "usage" then return { main = ui.col({ usageView(state) }) } end
		if state.mode == "create" or state.mode == "open" then
			local children = { row("back", "New…", "back", "menu"), ui.node("text", { text = if state.mode == "create" then "New worktree" else "Open worktree", role = "acc.newmenu.heading" }) }
			for _, name in (if state.mode == "create" then { "repo", "branch", "base", "command", "prompt" } else { "repo", "branch", "command", "prompt" }) do
				local labels = { repo = "Repository", branch = "Branch or pr:123", base = "Base branch (optional)", command = "Program", prompt = "Prompt (optional)" }
				table.insert(children, ui.node("field", { key = name, label = labels[name] }, { ui.node("input", field.props(state.fields[name], { key = "input", role = "acc.newmenu.input", placeholder = if name == "repo" then "/path/to/repository" else labels[name] })) }))
			end
			if state.mode == "open" then
				for i, tree in state.worktrees or {} do
					if i > 5 then break end
					if tree.branch then table.insert(children, row("tree" .. tostring(i), tree.branch, "branch", "choose=" .. tree.branch)) end
				end
			end
			if state.error then table.insert(children, ui.node("text", { text = state.error, tone = "error" })) end
			table.insert(children, ui.button(if state.mode == "create" then "Create worktree" else "Open worktree", { icon = "branch", variant = "primary", keys = { "enter" }, actions = { click = "submit" } }))
			return { main = ui.col({ ui.node("col", { key = "body", role = "acc.newmenu.form", gap = "sm" }, children) }) }
		end
		local children = { row("terminal", "Terminal", "terminal", "terminal", "⌘T"), ui.node("text", { text = "Start an agent", role = "acc.newmenu.section" }) }
		local n = 0
		for _, a in state.agents do
			if a.installed then n += 1 end
			table.insert(children, row(a.key, a.name, a.icon, "agent=" .. a.key, if not a.installed then "not installed" elseif n <= 9 then tostring(n) else "", not a.installed))
		end
		if #state.agents == 0 then table.insert(children, ui.node("text", { text = "Checking installed agents…", tone = "muted" })) end
		table.insert(children, ui.rule())
		table.insert(children, row("note", "Quick note", "pen", "note", "⌘⇧N"))
		table.insert(children, row("space", "New space", "plus", "space"))
		table.insert(children, row("worktree", "New worktree…", "branch", "create"))
		table.insert(children, row("worktree-open", "Open worktree…", "branch", "open"))
		return { main = ui.col({ ui.node("col", { role = "acc.newmenu.menu", gap = "none" }, children) }) }
	end,
	key = function(state, key, cx)
		if key.name == "escape" then
			if state.mode == "create" or state.mode == "open" then state.mode = "menu"; bridge.send(cx, "newmenu.resize", { mode = "menu" }) else dismiss(cx) end
			return true
		end
		if state.mode == "create" or state.mode == "open" then
			if key.name == "enter" then submit(state, cx); return true end
			if key.name == "tab" then
				local names = if state.mode == "create" then { "repo", "branch", "base", "command", "prompt" } else { "repo", "branch", "command", "prompt" }
				local at = table.find(names, state.focus) or 1
				state.focus = names[(at - 1 + (if key.shift then -1 else 1)) % #names + 1]
				field.focus(cx, "main.body." .. state.focus .. ".input")
				return true
			end
			return field.key(state.fields[state.focus], key)
		end
		if state.mode == "menu" and not (key.ctrl or key.meta or key.alt) then
			local digit = tonumber(key.text or key.name)
			if digit and digit >= 1 and digit <= 9 then
				local n = 0
				for _, a in state.agents do
					if a.installed then n += 1; if n == digit then launch(state, cx, "agent", a.key); return true end end
				end
			end
		end
		return false
	end,
	event = function(state, ev, cx)
		if ev.ev == "focus" or ev.ev == "edit" or ev.ev == "undo" then
			local name = string.match(ev.id or "", "%.([%w]+)%.input$")
			if name and state.fields[name] then
				state.focus = name; field.focus(cx, ev.id)
				if ev.ev ~= "focus" then field.edit(state.fields[name], ev) end
			end
			return
		end
		local act = ev.act
		if act == "terminal" or act == "note" or act == "space" then launch(state, cx, act)
		elseif act == "agent" then launch(state, cx, "agent", ev.value)
		elseif act == "create" or act == "open" then beginForm(state, cx, act)
		elseif act == "menu" then state.mode = "menu"; bridge.send(cx, "newmenu.resize", { mode = "menu" })
		elseif act == "submit" then submit(state, cx)
		elseif act == "choose" then field.set(state.fields.branch, ev.value); state.focus = "branch"; field.focus(cx, "main.body.branch.input")
		elseif act == "usage-settings" then state.settings = true
		elseif act == "usage-back" then state.settings = false
		elseif act == "usage-refresh" then tern.kv.set("usage:refresh", os.time())
		elseif act == "pref" then preference(ev.value)
		elseif act == "pref-provider" then preference("hidden", ev.value)
		elseif act == "pref-session" then preference("sessionOnBar", ev.value)
		elseif act == "pref-window" then preference("hiddenWindows", ev.value) end
	end,
} }
