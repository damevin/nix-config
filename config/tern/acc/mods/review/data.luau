--!nonstrict
-- What the review panels know about pull requests: check rollups, stacks,
-- staleness, bots and the fix prompt. Pure functions over `gh` JSON.
local util = require("../../lib/util")

local M = {}

M.REPO = "livestorm/entropy"
M.DIR = util.HOME .. "/nix-config/config/herdr-app/automation"
M.OUT = util.STATE .. "/acc-automation/reviews"
M.CHECKOUT = util.HOME .. "/Documents/livestorm/entropy"
M.STALE_DAYS = 21
M.FIELDS = "number,title,author,additions,deletions,changedFiles,isDraft,mergeable,mergeStateStatus,reviewDecision,updatedAt,createdAt,headRefOid,headRefName,baseRefName,url,body,statusCheckRollup"
M.WRITE = { WRITE = true, MAINTAIN = true, ADMIN = true }
M.THREADS_QUERY = [[query($url: URI!) { resource(url: $url) { ... on PullRequest {
  reviewThreads(first: 80) { nodes { isResolved isOutdated path line comments(first: 1) { nodes { author { login } body url } } } } } } }]]

M.TABS = {
	review = {
		{ "eli5", "ELI5" }, { "desc", "Description" }, { "checks", "Checks" }, { "convo", "Comments" }, { "comments", "Drafts" },
	},
	mine = {
		{ "desc", "Description" }, { "checks", "Checks" }, { "convo", "Comments" }, { "threads", "Threads" },
		{ "comments", "Self-review" },
	},
}

local OK = { SUCCESS = true, NEUTRAL = true, SKIPPED = true }
local FAIL = {
	FAILURE = true, ERROR = true, TIMED_OUT = true, CANCELLED = true, ACTION_REQUIRED = true, STARTUP_FAILURE = true,
}

function M.oneLine(s: string?): string
	return util.trim((string.gsub(s or "", "%s+", " ")))
end

function M.clip(s: string, n: number): string
	return util.truncate(s, n)
end

function M.idOf(pr): string
	return tostring(pr.number) .. "-" .. string.sub(pr.headRefOid, 1, 7)
end

function M.shortBranch(name: string): string
	return (string.gsub(name, "^liv%-%d+%-", ""))
end

function M.checks(pr)
	local all, fail, running = {}, {}, {}
	for _, c in (pr.statusCheckRollup or {}) do
		local state = "PENDING"
		for _, v in { c.conclusion, c.state, c.status } do
			if type(v) == "string" and v ~= "" then
				state = string.upper(v)
				break
			end
		end
		local kind = if OK[state] then "ok" elseif FAIL[state] then "fail" else "run"
		local check = {
			name = c.name or c.context or "check", kind = kind, state = state, url = c.detailsUrl or c.targetUrl,
		}
		table.insert(all, check)
		if kind == "fail" then table.insert(fail, check) elseif kind == "run" then table.insert(running, check) end
	end
	local summary = if #all == 0 then "none" elseif #fail > 0 then "failing" elseif #running > 0 then "running" else "green"
	return { all = all, fail = fail, run = running, summary = summary }
end

local BOT_NAMES = {
	"livestorm-entropy", "linear", "codecov", "github-actions", "sentry-io", "vercel", "greptile",
	"amazon-inspector", "sonarcloud", "snyk", "dependabot", "renovate",
}

function M.isBot(who: string): boolean
	local lower = string.lower(who)
	if string.find(lower, "%[bot%]$") or string.find(lower, "%-apps$") or string.find(lower, "bot$")
		or string.sub(lower, 1, 4) == "app/" then
		return true
	end
	for _, name in BOT_NAMES do
		if string.sub(lower, 1, #name) == name then return true end
	end
	return false
end

function M.isStale(pr, mode: string): boolean
	local updated = util.isoTime(pr.updatedAt)
	local old = updated ~= nil and os.time() - updated > M.STALE_DAYS * 86400
	if mode == "mine" then return old end
	local login = pr.author and pr.author.login or ""
	return pr.isDraft == true or string.find(login, "^app/") ~= nil or string.find(login, "%[bot%]$") ~= nil
		or (pr.author and pr.author.is_bot == true) or old
end

-- PRs chained by base branch, root first, newest-touched stack first.
function M.stacks(list)
	local byHead, kids = {}, {}
	for _, p in list do byHead[p.headRefName] = p end
	local function parent(p)
		if p.baseRefName ~= p.headRefName then return byHead[p.baseRefName] end
		return nil
	end
	for _, p in list do
		local par = parent(p)
		if par then
			kids[par.number] = kids[par.number] or {}
			table.insert(kids[par.number], p)
		end
	end
	local groups, newest = {}, {}
	for _, root in list do
		if not parent(root) then
			local out = {}
			local function walk(p)
				table.insert(out, p)
				for _, k in (kids[p.number] or {}) do walk(k) end
			end
			walk(root)
			local latest = 0
			for _, p in out do latest = math.max(latest, util.isoTime(p.updatedAt) or 0) end
			newest[out] = latest
			table.insert(groups, out)
		end
	end
	table.sort(groups, function(a, b) return newest[a] > newest[b] end)
	return groups
end

function M.fixPrompt(p, threads): string
	local c, todo = M.checks(p), {}
	if p.mergeable == "CONFLICTING" then
		table.insert(todo, "Conflicts: the branch conflicts with " .. p.baseRefName .. ". Merge origin/" .. p.baseRefName
			.. " into it (merge, not rebase) and resolve every conflict, keeping the intent of both sides.")
	end
	if #c.fail > 0 then
		local names = {}
		for _, f in c.fail do table.insert(names, '"' .. f.name .. '"') end
		table.insert(todo, "Red CI: failing checks are " .. table.concat(names, ", ") .. ". Find the cause with `gh pr checks "
			.. p.number .. "` and `gh run view <run-id> --log-failed`, reproduce locally where possible, and fix the code (or the test if the test is wrong).")
	end
	if #threads > 0 then
		local lines = {}
		for i, t in threads do
			if i > 12 then break end
			local where = t.path .. (if t.line then ":" .. t.line else "")
			table.insert(lines, "   " .. i .. ") [" .. t.who .. "] " .. where .. ": " .. M.clip(M.oneLine(t.body), 600))
		end
		table.insert(todo, "Review comments: address each unresolved thread below. If a comment is wrong or not worth acting on, say why in your summary instead of changing code.\n"
			.. table.concat(lines, "\n"))
	end
	local numbered = {}
	for i, x in todo do table.insert(numbered, i .. ". " .. x) end
	local parts = {
		"Fix pull request #" .. p.number .. ' "' .. p.title .. '" (' .. M.REPO .. ", branch " .. p.headRefName
			.. "). You are in a git worktree of that branch.",
		"",
		"What to do:",
	}
	for _, line in numbered do table.insert(parts, line) end
	table.insert(parts, "")
	table.insert(parts, "Rules: follow this repository's own instructions (AGENTS.md / CLAUDE.md). Stay on this branch. Commit your work locally in small commits.")
	table.insert(parts, "Do NOT push, force-push, resolve review threads, or merge: stop after committing and give me a short summary of what you changed, what you chose not to change and why, and anything still failing.")
	return table.concat(parts, "\n")
end

return M
