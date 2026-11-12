--!nonstrict
-- The window actions every mod can ask for through the bridge. Each handler
-- gets (args, cx); `args.from_pane` is the block pane that asked, when known.
local bridge = require("./bridge")
local dock = require("./dock")
local timer = require("./timer")
local util = require("./util")
local wt = require("./wt")

local M = {}

local function target(cx, spec): number?
	if type(spec) == "number" then return spec end
	if type(spec) == "string" then return cx.session:resolve(spec) end
	return cx.session:focused()
end

-- The focused pane that isn't one of our blocks or Overseer's panel, so a
-- split lands beside real work.
local function workPane(cx): number?
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	if info and not (info.block and (string.sub(info.block, 1, 4) == "acc." or string.sub(info.block, 1, 9) == "overseer."))
		and info.kind ~= "canvas" then
		return focused
	end
	local tab = focused and cx.session:tab_of(focused)
	for _, p in cx.session:panes() do
		if p.tab == tab and p.kind == "terminal" then return p.pane end
	end
	return focused
end

-- Opens a tab. args: {cwd?, command?, argv?, block?, args?, name?, focus?}
local function newTab(args, cx): number?
	local command = args.command or (if args.argv then util.argvLine(args.argv) else nil)
	local pane = cx.layout:new_tab({ cwd = args.cwd, command = command, block = args.block, args = args.args },
		{ focus = args.focus ~= false })
	if pane and args.name then
		local tab = cx.session:tab_of(pane)
		if tab then cx.layout:name_tab(tab, args.name) end
	end
	return pane
end

local function isMarkdown(path)
	local ext = string.lower(path):match("%.([^./]+)$")
	return ext == "md" or ext == "markdown"
end

function M.install()
	-- Keep the native file viewer, but give default Markdown opens a whole tab.
	-- Explicit beside/below/preview requests retain their chosen placement.
	tern.route.open(function(req)
		if req.how == "default" and isMarkdown(req.path) then
			return { path = req.path, how = "tab" }
		end
		return nil
	end)
	bridge.on("tab", function(args, cx) return newTab(args, cx) end)

	-- args: {dir?, cwd?, command?, argv?, block?, args?, target?, focus?}
	bridge.on("split", function(args, cx)
		local at = if args.target then target(cx, args.target) else workPane(cx)
		if not at then return end
		local command = args.command or (if args.argv then util.argvLine(args.argv) else nil)
		return cx.layout:split(at, args.dir or "right",
			{ cwd = args.cwd, command = command, block = args.block, args = args.args }, { focus = args.focus ~= false })
	end)

	-- args: {prompt, cwd, command?, how? ("tab" | "split")}
	bridge.on("agent", function(args, cx)
		return cx.agents:start({ prompt = args.prompt, cwd = args.cwd, command = args.command, how = args.how or "tab" })
	end)

	bridge.on("focus", function(args, cx)
		local pane = target(cx, args.pane)
		if pane then cx.layout:focus(pane) end
	end)

	-- args: {url? | path?, how?}
	bridge.on("open", function(args, cx)
		if args.path then
			cx:open(args.path, args.how or (if isMarkdown(args.path) then "tab" else "beside"))
		elseif args.url then
			if string.match(args.url, "^https?://") then
				-- Web links go to the system browser, as herdr's `open` did.
				tern.process.run({ "/usr/bin/open", args.url }, { timeout_ms = 10000 }, function() end)
			else
				cx:open(args.url)
			end
		end
	end)

	-- args: {id}; an existing panel is focused in its current native location.
	bridge.on("panel", function(args, cx)
		if dock.panel(args.id) then dock.show(args.id, cx) end
	end)

	-- args: {kind, args?, how?, dir?, ratio?, focus?}
	bridge.on("block", function(args, cx)
		local opts = { focus = args.focus ~= false }
		if args.dir then
			opts.target = workPane(cx)
			opts.dir = args.dir
		end
		if args.ratio then opts.ratio = args.ratio end
		return cx:new_block(args.kind, args.args or {}, args.how or "default", opts)
	end)

	-- Markdown page. args: {path, how? = "tab" (default, dedicated tab) | "beside"}
	bridge.on("markdown", function(args, cx)
		if not args.path or args.path == "" then return end
		if args.how == "beside" then
			return cx:new_block("acc.md", { args.path }, "default", { target = workPane(cx), dir = "right", focus = true })
		end
		return newTab({ block = "acc.md", args = { args.path }, name = util.basename(args.path) }, cx)
	end)

	-- Types into a pane. args: {pane, text}
	bridge.on("run", function(args, cx)
		local pane = target(cx, args.pane)
		if pane then cx:run(pane, args.text or "") end
	end)

	bridge.on("close", function(args, cx)
		local pane = target(cx, args.pane or args.from_pane)
		if pane then cx.layout:close(pane) end
	end)

	bridge.on("interrupt", function(args, cx)
		local pane = target(cx, args.pane)
		if pane then pcall(function() cx.agents:interrupt(pane) end) end
	end)

	bridge.on("toast", function(args, cx)
		cx:toast(args.level or "info", args.text or "", args.sub)
	end)

	-- A worktree's own session, Overseer-style, running a command there.
	-- args: {repo, branch, create?, base?, command? ("omp"), prompt?, args?}
	-- The session is "<checkout> / <branch>"; `wt switch` runs in its first tab,
	-- creating the worktree (hooks run visibly), then execs the command with the
	-- prompt. Once the worktree exists, Overseer learns the session is its.
	bridge.on("worktree", function(args, cx)
		if not args.repo or not args.branch then
			cx:toast("error", "acc: a worktree needs a repository and a branch")
			return
		end
		wt.project(args.repo, function(project, err, _)
			timer.later("worktree session", 0, function(wcx)
				if not project then
					wcx:toast("error", "Not a Git repository", tostring(err))
					return
				end
				local display = string.match(args.branch, "^pr:(%d+)$") and ("PR #" .. string.match(args.branch, "^pr:(%d+)$"))
					or args.branch
				local name = project.name .. " / " .. display
				local cmdArgs = args.args or (if args.prompt and args.prompt ~= "" then { args.prompt } else nil)
				local line = wt.switchLine({
					branch = args.branch, create = args.create, base = args.base,
					command = args.command or "omp", args = cmdArgs,
				})
				local session = nil
				for _, s in wcx.sessions:list() do
					if s.name == name then session = s end
				end
				if session then
					wcx.sessions:switch(session.id)
					local pane = wcx.layout:new_tab({ cwd = project.root })
					if pane then wcx:run(pane, line .. "\r") end
				else
					session = wcx.sessions:create({ name = name, cwd = project.root })
					local pane = wcx.session:focused()
					if pane then wcx:run(pane, line .. "\r") end
				end
				-- Bind once the worktree appears (setup can take minutes). A PR
				-- checkout's branch isn't known up front, so it stays unbound.
				if string.match(args.branch, "^pr:%d+$") then return end
				local tries, bound = 0, false
				timer.every("worktree bind", 3000, function()
					tries += 1
					if bound or tries > 100 then return false end
					wt.pathOf(project.root, args.branch, function(path)
						if path and not bound then
							bound = true
							wt.bindOverseer(path, session, project.id)
						end
					end)
					return true
				end)
			end)
		end)
	end)
end

return M
