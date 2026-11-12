--!nonstrict
-- Child processes. Tern's daemon and windows inherit launchd's bare PATH, so
-- every process gets the login PATH herdr's launchd jobs use, and programs are
-- resolved to absolute paths before they start.
local util = require("./util")

local M = {}

local HOME = util.HOME
M.DIRS = {
	HOME .. "/.local/bin",
	HOME .. "/.nix-profile/bin",
	"/etc/profiles/per-user/" .. (tern.getenv("USER") or "") .. "/bin",
	"/run/current-system/sw/bin",
	"/nix/var/nix/profiles/default/bin",
	"/opt/homebrew/bin",
	"/usr/local/bin",
	HOME .. "/.bun/bin",
	"/usr/bin",
	"/bin",
	"/usr/sbin",
	"/sbin",
}
M.PATH = table.concat(M.DIRS, ":")

local found: { [string]: string | false } = {}

-- The absolute path of `name` on the login PATH, or nil.
function M.which(name: string): string?
	if string.find(name, "/", 1, true) then return name end
	local hit = found[name]
	if hit ~= nil then return hit or nil end
	for _, dir in M.DIRS do
		local path = dir .. "/" .. name
		if tern.fs.exists(path) then
			found[name] = path
			return path
		end
	end
	found[name] = false
	return nil
end

local function options(opts)
	local o = if opts then util.copy(opts) else {}
	local env = if o.env then util.copy(o.env) else {}
	env.PATH = env.PATH or M.PATH
	env.HOME = env.HOME or HOME
	o.env = env
	o.cwd = o.cwd or HOME
	return o
end

-- Runs argv and calls cb(result, cx) (cx: a window cx in the window half, nil
-- in the host half). A program that isn't installed, or a failure to start,
-- arrives as a result with status 127 and the reason in stderr. Errors raised
-- by cb are logged under `label`.
function M.run(label: string, argv: { string }, opts: { [string]: any }?, cb: ((any, any) -> ())?)
	local function deliver(result, cx)
		if not cb then return end
		local ok, err = pcall(cb, result, cx)
		if not ok then tern.log.warn("acc: " .. label .. " failed: " .. tostring(err)) end
	end
	local program = M.which(argv[1])
	if not program then
		deliver({ status = 127, stdout = "", stderr = argv[1] .. " is not installed", timed_out = false }, nil)
		return
	end
	local resolved = util.copy(argv)
	resolved[1] = program
	local ok, err = pcall(tern.process.run, resolved, options(opts), deliver)
	if not ok then
		deliver({ status = 127, stdout = "", stderr = tostring(err), timed_out = false }, nil)
	end
end

-- Runs a /bin/sh script with positional arguments ($1, $2, …).
function M.sh(label: string, script: string, args: { string }?, opts: { [string]: any }?, cb: ((any, any) -> ())?)
	local argv = { "/bin/sh", "-c", script, "acc" }
	for _, a in (args or {}) do table.insert(argv, a) end
	M.run(label, argv, opts, cb)
end

-- Runs argv and decodes its stdout as JSON: cb(value | nil, err | nil, cx).
function M.json(label: string, argv: { string }, opts: { [string]: any }?, cb: (any, string?, any) -> ())
	M.run(label, argv, opts, function(r, cx)
		if r.status ~= 0 then
			cb(nil, util.trim(r.stderr ~= "" and r.stderr or r.stdout), cx)
			return
		end
		local value = util.decodeJson(r.stdout)
		if value == nil then
			cb(nil, label .. ": unreadable JSON", cx)
		else
			cb(value, nil, cx)
		end
	end)
end

return M
