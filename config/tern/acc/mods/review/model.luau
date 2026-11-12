--!nonstrict
-- Questions the views ask of a panel's state.
local data = require("./data")

local M = {}

function M.stale(S, pr): boolean
	return data.isStale(pr, S.mode)
end

function M.active(S)
	local out = {}
	for _, p in S.prs do
		if not M.stale(S, p) then table.insert(out, p) end
	end
	return out
end

function M.staleList(S)
	local out = {}
	for _, p in S.prs do
		if M.stale(S, p) then table.insert(out, p) end
	end
	return out
end

function M.find(S, number: number?)
	if not number then return nil end
	for _, p in S.prs do
		if p.number == number then return p end
	end
	return nil
end

function M.ready(S, pr): boolean
	return S.merge ~= nil and S.merge ~= "" and not pr.isDraft and pr.mergeStateStatus == "CLEAN"
end

function M.stackOf(S, pr)
	for _, g in data.stacks(S.prs) do
		for _, p in g do
			if p.number == pr.number then return g end
		end
	end
	return { pr }
end

local RANK = { blocked = 0, working = 1, done = 2, idle = 3 }
local STATUS = { waiting_input = "blocked", working = "working", idle = "done" }

-- The agent working in the PR branch's worktree: { status, pane, count }.
function M.agentOn(S, pr)
	local root = S.trees[pr.headRefName]
	if not root then return nil end
	local best, count = nil, 0
	for _, a in S.agents do
		local status = STATUS[a.state]
		local cwd = a.cwd or ""
		if status and (cwd == root or string.sub(cwd, 1, #root + 1) == root .. "/") then
			count += 1
			if not best or RANK[status] < RANK[best.status] then best = { status = status, pane = a.pane } end
		end
	end
	if not best then return nil end
	best.count = count
	return best
end

-- The terminal running the reviewer. It stays alive on "Press Enter to close",
-- so the review file's status says when the review is really over.
function M.reviewing(S, pr): number?
	local rv = S.files.review[data.idOf(pr)]
	if rv and rv.status and rv.status ~= "running" then return nil end
	local needle = "review%.py review " .. pr.number .. "%f[%D]"
	for _, p in S.panes do
		if p.running and string.find(p.running, needle) then return p.pane end
		if S.reviewPanes[pr.number] == p.pane and p.running then return p.pane end
	end
	return nil
end

return M
