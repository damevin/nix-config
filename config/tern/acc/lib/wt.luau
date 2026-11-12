--!nonstrict
-- Worktrees through Worktrunk, so Overseer lists them. Creation runs `wt
-- switch` in a visible terminal (hooks and their approval prompts need one).
local proc = require("./proc")
local util = require("./util")

local M = {}

-- The repository's main checkout and Overseer's project id (the physical path
-- of the shared Git directory): cb({root, name, id} | nil, err).
function M.project(path: string, cb: (any, string?) -> ())
	proc.run("git common dir", { "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir" }, nil,
		function(r)
			if r.status ~= 0 then cb(nil, util.trim(r.stderr)); return end
			local common = util.trim(r.stdout)
			proc.sh("pwd -P", 'cd "$1" && pwd -P', { common }, nil, function(p)
				if p.status ~= 0 then cb(nil, util.trim(p.stderr)); return end
				local id = util.trim(p.stdout)
				-- The main checkout is the common dir's parent for a normal repository.
				local root = string.match(id, "^(.*)/%.git$") or id
				cb({ root = root, name = util.basename(root), id = id }, nil)
			end)
		end)
end

-- Every worktree of the repository at `path`: cb({ {path, branch, head} } | nil, err).
function M.list(path: string, cb: (any, string?) -> ())
	proc.run("git worktree list", { "git", "-C", path, "worktree", "list", "--porcelain" }, nil, function(r)
		if r.status ~= 0 then cb(nil, util.trim(r.stderr)); return end
		local trees, current = {}, nil
		for _, line in util.lines(r.stdout) do
			local p = string.match(line, "^worktree (.+)$")
			if p then
				current = { path = p }
				table.insert(trees, current)
			elseif current then
				local branch = string.match(line, "^branch refs/heads/(.+)$")
				if branch then current.branch = branch end
				local head = string.match(line, "^HEAD (%x+)$")
				if head then current.head = head end
			end
		end
		cb(trees, nil)
	end)
end

-- The worktree path of `branch`, or nil.
function M.pathOf(repo: string, branch: string, cb: (string?) -> ())
	M.list(repo, function(trees)
		for _, t in (trees or {}) do
			if t.branch == branch then cb(t.path); return end
		end
		cb(nil)
	end)
end

-- The shell line that switches to (creating if asked) `branch` and then runs
-- `command` with `args` there. `branch` may be `pr:<N>`.
function M.switchLine(opts): string
	local parts = { "wt", "switch" }
	if opts.create then table.insert(parts, "--create") end
	table.insert(parts, util.shq(opts.branch))
	if opts.base and opts.base ~= "" then
		table.insert(parts, "--base")
		table.insert(parts, util.shq(opts.base))
	end
	if opts.command and opts.command ~= "" then
		table.insert(parts, "--execute")
		table.insert(parts, util.shq(opts.command))
		if opts.args and #opts.args > 0 then
			table.insert(parts, "--")
			for _, a in opts.args do table.insert(parts, util.shq(a)) end
		end
	end
	return table.concat(parts, " ")
end

-- Records in Overseer's store that `session` belongs to the worktree at
-- `path`, so clicking its row switches there instead of opening another
-- session. Overseer 2.4 keeps `sessions[path] = {id, host, project}` in its kv.
function M.bindOverseer(path: string, session, projectId: string)
	local store = util.dirname(tern.plugin.data) .. "/overseer/kv.json"
	if not tern.fs.exists(store) then return end
	local data = util.decodeJson(util.readFile(store))
	if type(data) ~= "table" then return end
	local sessions = if type(data.sessions) == "table" then data.sessions else {}
	sessions[path] = { id = session.id, host = session.host, project = projectId }
	data.sessions = sessions
	util.writeAtomic(store, tern.json.encode(data, true), function(ok, err)
		if not ok then tern.log.warn("acc: couldn't bind the session in Overseer: " .. tostring(err)) end
	end)
end

return M
