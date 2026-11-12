--!nonstrict
-- The node trees of the pull request and review panels. Ids matter here: the
-- comment editors are addressed by their full node id (`main.body.tab.cm-<i>.ed`).
local data = require("./data")
local field = require("../../lib/field")
local model = require("./model")
local util = require("../../lib/util")

local ui = tern.ui
local N = ui.node
local span = ui.span

local M = {}

local ROLE = "acc.review."

local function text(str: string, role: string?, props: { [string]: any }?)
	local p = props or {}
	p.text, p.role = str, role
	return N("text", p)
end

local function spans(list, props: { [string]: any }?)
	local p = props or {}
	p.spans = list
	return N("text", p)
end

local function el(tag: string, props: { [string]: any }, children: { any }?)
	return ui.el(tag, props, children)
end

local function badge(label: string, tone: string?, key: string)
	return N("badge", { text = label, tone = tone, key = key })
end

local function button(label: string, act: string, key: string, opts: { [string]: any }?)
	local p = { text = label, key = key, size = "sm", actions = { click = act } }
	for k, v in (opts or {}) do p[k] = v end
	return N("button", p)
end

local function ghost(label: string, act: string, key: string, opts: { [string]: any }?)
	local p = { variant = "quiet" }
	for k, v in (opts or {}) do p[k] = v end
	return button(label, act, key, p)
end

local function dot(tone: string?, pulse: boolean?)
	return el("span", { role = "acc.dot", tone = if pulse then "pending" else tone })
end

local function sizeBar(pr, wide: boolean?)
	return el("div", { role = ROLE .. "bar", class = if wide then "wide" else "" }, {
		el("div", { role = ROLE .. "bar-add", grow = math.max(pr.additions, 0), basis = 0 }),
		el("div", { role = ROLE .. "bar-del", grow = math.max(pr.deletions, 0), basis = 0 }),
	})
end

local function sizeLine(pr, wide: boolean?)
	return N("row", { role = ROLE .. "size", gap = "sm" }, {
		spans({ span("+" .. pr.additions, "success mono") }, { shrink = 0 }),
		spans({ span("−" .. pr.deletions, "error mono") }, { shrink = 0 }),
		sizeBar(pr, wide),
	})
end

local function ciChip(pr)
	local c = data.checks(pr)
	if c.summary == "failing" then return badge("✕ " .. #c.fail .. " failing", "error", "ci") end
	if c.summary == "running" then return badge("● " .. #c.run .. " running", "warning", "ci") end
	if c.summary == "green" then return badge("✓ CI", "success", "ci") end
	return nil
end

local AGENT_LOOK = {
	working = { "agent working", "pending", "accent", true },
	blocked = { "agent needs you", "warning", "warning", false },
	done = { "agent done", "success", "success", false },
}

local function agentChip(S, pr)
	local a = model.agentOn(S, pr)
	if not a then return nil end
	local look = AGENT_LOOK[a.status] or AGENT_LOOK.done
	local label = if a.count > 1 then look[1] .. " · " .. a.count else look[1]
	return N("row", {
		key = "agent", role = ROLE .. "agent", tone = look[3], gap = "xs",
		actions = { click = "agent=" .. a.pane }, title = "Go to the agent",
	}, { dot(look[2], look[4]), spans({ span(label, look[3]) }) })
end

local function stateChips(S, pr)
	local out = {}
	local function add(node) if node then table.insert(out, node) end end
	add(agentChip(S, pr))
	if pr.isDraft then add(badge("draft", "muted", "draft")) end
	add(ciChip(pr))
	if pr.mergeable == "CONFLICTING" then
		add(badge("⚠ conflicts", "error", "conflicts"))
	elseif S.mode == "mine" and pr.mergeStateStatus == "BEHIND" then
		add(badge("behind base", "warning", "behind"))
	end
	if pr.reviewDecision == "APPROVED" then add(badge("approved", "success", "approved")) end
	if pr.reviewDecision == "CHANGES_REQUESTED" then add(badge("changes requested", "warning", "changes")) end
	if S.mode == "mine" and model.ready(S, pr) then add(badge("ready to merge", "success", "ready")) end
	local rv = S.files.review[data.idOf(pr)]
	if model.reviewing(S, pr) then
		add(N("row", { key = "reviewing", gap = "xs" }, { dot(nil, true), spans({ span("reviewing", "accent") }) }))
	elseif rv and rv.status == "ok" then
		local label
		if rv.n and rv.n > 0 then
			label = rv.n .. " " .. (if S.mode == "mine" then "notes" else "drafts")
			if rv.blockers and rv.blockers > 0 then label ..= " · " .. rv.blockers .. " blocker" end
		else
			label = "review clean"
		end
		add(badge(label, if rv.blockers and rv.blockers > 0 then "error" else "accent", "review"))
	end
	return out
end

local function chipRow(S, pr, withFiles: boolean?)
	local chips = stateChips(S, pr)
	if withFiles then table.insert(chips, badge(pr.changedFiles .. " files", "muted", "files")) end
	return N("row", { key = "chips", role = ROLE .. "chips", gap = "sm", wrap = true }, chips)
end

local function authorLine(S, pr): string
	if S.mode == "mine" then return "#" .. pr.number .. " · " .. data.shortBranch(pr.headRefName) end
	local login = if pr.author then pr.author.login else "?"
	return "#" .. pr.number .. " · @" .. login .. " · " .. util.ago(util.isoTime(pr.createdAt))
end

local function prRow(S, pr)
	return N("col", {
		key = "pr-" .. pr.number, role = ROLE .. "card", actions = { click = "pick=" .. pr.number },
	}, {
		text(data.clip(pr.title, 120), ROLE .. "title", { key = "title" }),
		N("row", { key = "meta", gap = "md" }, {
			spans({ span(authorLine(S, pr), "muted") }, { grow = 1, truncate = "end" }),
			sizeLine(pr),
		}),
		chipRow(S, pr, true),
	})
end

local function stackCard(S, group)
	local top = {}
	for i = #group, 1, -1 do table.insert(top, group[i]) end
	local added, removed = 0, 0
	for _, p in group do
		added += p.additions
		removed += p.deletions
	end
	local rows = {
		N("row", { key = "head", role = ROLE .. "stack-head", gap = "md" }, {
			text("STACK", ROLE .. "kicker"),
			spans({ span(#group .. " PRs on " .. group[1].baseRefName, "muted") }),
			N("row", { grow = 1 }),
			spans({ span("+" .. added .. " −" .. removed, "muted mono") }),
		}),
	}
	for i, pr in top do
		local c = data.checks(pr)
		local tone = if model.ready(S, pr) then "success" elseif c.summary == "failing" then "error" else nil
		table.insert(rows, N("row", {
			key = "sk-" .. pr.number, role = ROLE .. "stack-row", gap = "md", align = "stretch",
			actions = { click = "pick=" .. pr.number },
		}, {
			el("div", {
				role = ROLE .. "rail", tone = tone,
				class = (if i == 1 then "first " else "") .. (if i == #top then "last" else ""),
			}, { el("span", { role = ROLE .. "rail-dot" }) }),
			N("col", { grow = 1, role = ROLE .. "stack-body" }, {
				N("row", { gap = "md" }, {
					spans({ span("#" .. pr.number .. " " .. pr.title, "strong") }, { grow = 1, truncate = "end", role = ROLE .. "stack-title" }),
					sizeLine(pr),
				}),
				chipRow(S, pr),
			}),
		}))
	end
	return N("col", { key = "stack-" .. group[1].number, role = ROLE .. "stack" }, rows)
end

local function placeholder(i: number)
	return N("col", { key = "ph-" .. i, role = ROLE .. "placeholder" }, {
		el("div", { key = "a", role = ROLE .. "skel", class = "w1" }),
		el("div", { key = "b", role = ROLE .. "skel", class = "w3" }),
	})
end

local function listView(S)
	local act, stale = model.active(S), model.staleList(S)
	local mine = S.mode == "mine"
	local out = {}
	if S.error then
		table.insert(out, spans({ span(S.error, "error") }, { key = "error", role = ROLE .. "error" }))
	end
	if not S.loaded and not S.error then
		for i = 1, 3 do table.insert(out, placeholder(i)) end
		return out
	end
	if #act == 0 and not S.error then
		table.insert(out, N("col", { key = "empty", role = ROLE .. "empty" }, {
			text(if mine then "No open PR" else "Nothing to review", ROLE .. "empty-title"),
			spans({ span(
				if mine then "Your open PRs on entropy show up here, grouped by stack."
					else "Active PRs where you are a reviewer or assignee show up here.",
				"muted"
			) }),
		}))
	end
	if mine then
		for _, g in data.stacks(act) do
			table.insert(out, if #g > 1 then stackCard(S, g) else prRow(S, g[1]))
		end
	else
		for _, p in act do table.insert(out, prRow(S, p)) end
	end
	if #stale > 0 then
		table.insert(out, N("row", { key = "stale-head", role = ROLE .. "fold", justify = "between" }, {
			text((if mine then "QUIET FOR 3 WEEKS" else "STALE OR DRAFT") .. "  " .. #stale, ROLE .. "kicker"),
			ghost(if S.showStale then "Hide" else "Show", "fold", "fold"),
		}))
		if S.showStale then
			for _, p in stale do table.insert(out, prRow(S, p)) end
		end
	end
	return out
end

local function card(key: string, children, role: string?)
	return N("col", { key = key, role = role or ROLE .. "panel" }, children)
end

local function muted(str: string, key: string, tone: string?)
	return spans({ span(str, tone or "muted") }, { key = key, role = ROLE .. "note" })
end

local function md(str: string, key: string)
	return N("md", { text = str, key = key, role = ROLE .. "md" })
end

local function reviewFile(S, key: string): string
	return data.OUT .. "/" .. key .. ".review.json"
end

local function reviewData(S, key: string)
	local raw = S.cache[reviewFile(S, key)]
	return if raw then util.decodeJson(raw) else nil
end

local function text0(c): string
	return c.edited or (c.label .. ": " .. c.body)
end

M.text0 = text0

local LABEL_TONE = { blocker = "error", suggestion = "accent", question = "warning", nit = "muted" }

local function commentCard(S, pr, key: string, c, i: number)
	local k = key .. "-" .. i
	local editing = S.edits[k]
	local posted = c.posted ~= nil
	local busy = S.posting[k] == true
	local parts = string.split(c.path, "/")
	local short = table.concat(table.move(parts, math.max(1, #parts - 1), #parts, 1, {}), "/")
	local where = (if #parts > 2 then "…/" else "") .. short .. ":" .. c.line
	local head = {
		badge(c.label, LABEL_TONE[c.label] or "muted", "label"),
		spans({ span(where, "muted mono") }, { grow = 1, truncate = "middle", key = "where" }),
	}
	if c.edited and not editing then table.insert(head, spans({ span("edited", "dim") }, { key = "edited" })) end
	local body
	if editing then
		body = N("editor", field.props(editing, {
			key = "ed", role = ROLE .. "editor", maxLines = 14, variant = "well",
		}))
	else
		body = md(c.edited or c.body, "body")
	end
	local foot = {}
	if editing then
		table.insert(foot, button("Save", "save=" .. i, "save", { variant = "primary", keys = { "cmd", "enter" } }))
		table.insert(foot, ghost("Cancel", "cancel=" .. i, "cancel", { keys = { "esc" } }))
	elseif not posted and S.mode == "review" then
		table.insert(foot, button(if busy then "Posting…" else "Post", "post=" .. i, "post", { variant = "primary", busy = busy }))
		table.insert(foot, button("Edit", "edit=" .. i, "edit"))
	end
	if posted then
		table.insert(foot, badge("✓ in your pending review", "success", "posted"))
		table.insert(foot, ghost("Submit on GitHub ↗", "open", "submit", { href = pr.url .. "/files" }))
	end
	table.insert(foot, N("row", { key = "sp", grow = 1 }))
	table.insert(foot, ghost(if S.copied == k then "Copied ✓" else "Copy", "copy=" .. i, "copy"))
	return N("col", {
		key = "cm-" .. i, role = ROLE .. "comment", mark = if editing then "editing" elseif posted then "posted" else nil,
	}, {
		N("row", { key = "head", gap = "md" }, head),
		body,
		N("row", { key = "foot", gap = "sm" }, foot),
	})
end

local function draftsTab(S, pr)
	local key = data.idOf(pr)
	local rv = reviewData(S, key)
	if model.reviewing(S, pr) then
		return card("tab", {
			N("row", { key = "line", gap = "md" }, {
				dot(nil, true), text("The reviewer is reading the frontend diff…", ROLE .. "reading"),
			}),
			button("Open the review terminal", "rv-open", "rv-open"),
		})
	end
	local mine = S.mode == "mine"
	if not rv then
		return card("tab", {
			text(if mine then "No self-review for this commit yet. It reads your frontend diff like a reviewer would, nothing gets posted."
				else "No review draft for this commit yet.", ROLE .. "note"),
			button(if mine then "Self-review" else "Review frontend", "rv-go", "rv-go", { variant = "primary" }),
		}, ROLE .. "panel-plain")
	end
	if rv.status == "error" then
		return card("tab", {
			spans({ span(rv.error or "The review failed.", "error") }, { key = "err" }),
			button("Try again", "rv-go", "retry"),
		})
	end
	local nodes = {
		card("sum", {
			text(rv.summary or "", ROLE .. "summary", { key = "summary" }),
			N("row", { key = "buttons", gap = "sm" }, {
				button(if S.copied == "all" then "Copied ✓" else "Copy all", "copy-all", "copy-all"),
				button("Open as page", "rv-md", "rv-md"),
				button("Open beside", "rv-md-beside", "rv-md-beside"),
				N("row", { key = "sp", grow = 1 }),
				ghost("Re-run", "rv-go", "rerun"),
			}),
		}, ROLE .. "panel-accent"),
	}
	for i, c in (rv.comments or {}) do table.insert(nodes, commentCard(S, pr, key, c, i)) end
	if rv.checked and #rv.checked > 0 then
		local lines = { text("WHAT IT CHECKED", ROLE .. "kicker", { key = "head" }) }
		for i, x in rv.checked do
			table.insert(lines, spans({ span("· " .. x, "muted") }, { key = "chk-" .. i, role = ROLE .. "checked" }))
		end
		table.insert(nodes, N("col", { key = "checked", role = ROLE .. "checked-list" }, lines))
	end
	return N("col", { key = "tab", role = ROLE .. "stack-col" }, nodes)
end

local function eli5Tab(S, pr)
	local key = data.idOf(pr)
	local body = S.cache[data.OUT .. "/" .. key .. ".eli5.md"]
	if body then return card("tab", { md(body, "eli5-" .. key) }) end
	if S.explaining[key] then
		local bars = {}
		for i, w in { "w1", "w2", "w3", "w4" } do
			table.insert(bars, el("div", { key = "b" .. i, role = ROLE .. "skel", class = w }))
		end
		return card("tab", {
			muted("Sonnet is reading the diff, about 30 seconds…", "wait"),
			N("col", { key = "bars", role = ROLE .. "skels" }, bars),
		})
	end
	return card("tab", {
		muted("No explanation yet.", "none"),
		button("Explain this PR", "eli5-go", "eli5-go"),
	}, ROLE .. "panel-plain")
end

local function descTab(S, pr)
	local body = pr.body
	return card("tab", {
		if body and util.trim(body) ~= "" then md(body, "desc-" .. data.idOf(pr))
			else muted("The author wrote no description.", "none"),
	})
end

local function checksTab(S, pr)
	local c = data.checks(pr)
	local order = {}
	for _, x in c.fail do table.insert(order, x) end
	for _, x in c.run do table.insert(order, x) end
	for _, x in c.all do
		if x.kind == "ok" then table.insert(order, x) end
	end
	local head = {
		text(#c.fail .. " failing · " .. #c.run .. " running · " .. (#c.all - #c.fail - #c.run) .. " passed", ROLE .. "check-head", { key = "sum" }),
	}
	if pr.mergeable == "CONFLICTING" then table.insert(head, badge("⚠ merge conflicts", "error", "conflict")) end
	local rows = { N("row", { key = "head", role = ROLE .. "check-top", gap = "md" }, head) }
	for i, x in order do
		if i > 40 then break end
		local tone = if x.kind == "fail" then "error" elseif x.kind == "run" then "warning" else "success"
		table.insert(rows, N("row", {
			key = "ck-" .. i, role = ROLE .. "check", gap = "md", href = x.url,
			actions = if x.url then { click = "open" } else nil,
		}, {
			dot(tone, x.kind == "run"),
			spans({ span(x.name, if x.kind == "ok" then "muted" else nil) }, { grow = 1, truncate = "end" }),
			spans({ span(string.lower(x.state), "dim") }),
		}))
	end
	return N("col", { key = "tab", role = ROLE .. "list-panel" }, rows)
end

local VERDICT = {
	APPROVED = { "approved", "success" }, CHANGES_REQUESTED = { "changes requested", "error" },
	DISMISSED = { "dismissed", "muted" },
}

local function convoTab(S, pr)
	local all = S.convo[pr.number]
	if not all then return muted("Loading comments…", "tab") end
	if all.error then return muted(all.error, "tab", "error") end
	local people, bots = 0, 0
	for _, x in all do
		if x.bot then bots += 1 else people += 1 end
	end
	local nodes = {}
	if people == 0 and not S.showBots then
		table.insert(nodes, muted("No comment from people yet.", "none"))
	end
	for i, x in all do
		if S.showBots or not x.bot then
			local mineAuthor = pr.author and x.who == pr.author.login
			local head = { spans({ span("@" .. x.who, if x.bot then "muted strong" else "strong") }, { key = "who" }) }
			if mineAuthor then table.insert(head, badge("author", "muted", "author")) end
			local verdict = x.state and VERDICT[x.state]
			if verdict then table.insert(head, badge(verdict[1], verdict[2], "verdict")) end
			table.insert(head, N("row", { key = "sp", grow = 1 }))
			table.insert(head, spans({ span(if x.at then util.ago(util.isoTime(x.at)) .. " ago" else "", "dim") }, { key = "at" }))
			table.insert(head, ghost("↗", "open", "go", { href = x.url, title = "Open on GitHub" }))
			local children = { N("row", { key = "head", gap = "md" }, head) }
			if util.trim(x.body) ~= "" then
				if x.bot then
					local plain = data.oneLine((string.gsub(x.body, "<[^>]+>", " ")))
					table.insert(children, spans({ span(data.clip(plain, 280), "muted") }, { key = "body", role = ROLE .. "bot-body" }))
				else
					table.insert(children, md(x.body, "body"))
				end
			end
			table.insert(nodes, N("col", {
				key = "cv-" .. i, role = ROLE .. "comment", mark = if x.bot then "bot" elseif mineAuthor then "author" else nil,
			}, children))
		end
	end
	if bots > 0 then
		table.insert(nodes, N("row", { key = "bots" }, {
			ghost(if S.showBots then "Hide " .. bots .. " bot comments" else "Show " .. bots .. " bot comments", "bots", "toggle"),
		}))
	end
	return N("col", { key = "tab", role = ROLE .. "stack-col" }, nodes)
end

local function threadsTab(S, pr)
	local th = S.threads[pr.number]
	if not th then return muted("Loading threads…", "tab") end
	if th.error then return muted(th.error, "tab", "error") end
	if #th == 0 then return muted("No unresolved review thread.", "tab") end
	local nodes = {}
	for i, x in th do
		local parts = string.split(x.path, "/")
		local short = table.concat(table.move(parts, math.max(1, #parts - 1), #parts, 1, {}), "/")
		table.insert(nodes, N("col", {
			key = "th-" .. i, role = ROLE .. "comment", mark = "link", href = x.url, actions = { click = "open" },
		}, {
			N("row", { key = "head", gap = "md" }, {
				badge(if x.bot then "bot" else "@" .. x.who, if x.bot then "muted" else "accent", "who"),
				spans({ span(short .. (if x.line then ":" .. x.line else ""), "muted mono") }, { grow = 1, truncate = "middle" }),
			}),
			text(data.clip(data.oneLine(x.body), 400), ROLE .. "thread-body", { key = "body" }),
		}))
	end
	return N("col", { key = "tab", role = ROLE .. "stack-col" }, nodes)
end

local function tabBody(S, pr)
	local tab = S.tab
	if tab == "eli5" then return eli5Tab(S, pr) end
	if tab == "desc" then return descTab(S, pr) end
	if tab == "checks" then return checksTab(S, pr) end
	if tab == "convo" then return convoTab(S, pr) end
	if tab == "threads" then return threadsTab(S, pr) end
	return draftsTab(S, pr)
end

local function actionRows(S, pr)
	local rv = S.files.review[data.idOf(pr)]
	local reviewing = model.reviewing(S, pr)
	local busy = S.busy
	local mine = S.mode == "mine"
	local review
	if reviewing then
		review = button("Reviewing…", "rv-open", "rv", { size = "md" })
	else
		local label
		if mine then
			label = if rv and rv.status == "ok" then "Self-review again" else "Self-review"
		else
			label = if rv and rv.status == "ok" then "Review again" else "Review frontend"
		end
		review = button(label, "rv-go", "rv", { size = "md" })
	end
	if not mine then
		return N("row", { key = "actions", gap = "sm", wrap = true }, {
			button("View diff", "diff", "diff", { variant = "primary", size = "md" }), review,
		})
	end
	local th = S.threads[pr.number]
	local problems = (if pr.mergeable == "CONFLICTING" then 1 else 0) + #data.checks(pr).fail + (if th and not th.error then #th else 0)
	local draftKey = "rd-" .. pr.number
	local second = {}
	if pr.isDraft then
		local armed = S.armed == draftKey
		table.insert(second, button(
			if busy == draftKey then "Marking ready…" elseif armed then "Confirm: notify reviewers" else "Ready for review",
			"ready", "ready", { size = "md", variant = if armed then "danger" else "primary", busy = busy == draftKey }
		))
	end
	table.insert(second, review)
	if problems > 0 then
		table.insert(second, button("Fix " .. problems .. " issue" .. (if problems > 1 then "s" else ""), "fix", "fix", { size = "md" }))
	end
	if model.ready(S, pr) then
		local armed = S.armed == pr.number
		table.insert(second, button(
			if busy == "mg-" .. pr.number then "Merging…" elseif armed then "Confirm merge" else "Merge",
			"merge", "merge", { size = "md", variant = if armed then "danger" else "primary", busy = busy == "mg-" .. pr.number }
		))
	end
	if not pr.isDraft then
		table.insert(second, ghost(
			if busy == draftKey then "Moving…" elseif S.armed == draftKey then "Confirm back to draft" else "Back to draft",
			"ready", "undraft", { size = "md" }
		))
	end
	return N("col", { key = "actions", role = ROLE .. "actions" }, {
		N("row", { key = "first", gap = "sm", wrap = true }, {
			button(if busy == "wt-" .. pr.number then "Opening…" else "Open worktree", "wt", "wt", { variant = "primary", size = "md", busy = busy == "wt-" .. pr.number }),
			button(if busy == "co-" .. pr.number then "Checking out…" else "Checkout here", "co", "co", { size = "md", busy = busy == "co-" .. pr.number }),
			button("View diff", "diff", "diff", { size = "md" }),
		}),
		N("row", { key = "second", gap = "sm", wrap = true }, second),
	})
end

local function trail(S, pr)
	local g = model.stackOf(S, pr)
	if #g < 2 then return nil end
	local kids = { text("STACK on " .. g[1].baseRefName, ROLE .. "kicker", { key = "label" }) }
	for i, p in g do
		if i > 1 then table.insert(kids, spans({ span("›", "dim") }, { key = "sep-" .. p.number })) end
		table.insert(kids, el("div", {
			key = "t-" .. p.number, role = ROLE .. "pill", text = "#" .. p.number,
			mark = if p.number == pr.number then "current" else nil,
			actions = { click = "pick=" .. p.number },
		}))
	end
	return N("row", { key = "trail", role = ROLE .. "trail", gap = "xs", wrap = true }, kids)
end

local function detailHead(S, pr)
	local mine = S.mode == "mine"
	local rv = S.files.review[data.idOf(pr)]
	local meta = if mine then "#" .. pr.number .. " · " .. pr.headRefName .. " → " .. pr.baseRefName
		else "#" .. pr.number .. " by @" .. (if pr.author then pr.author.login else "?") .. " · opened " .. util.ago(util.isoTime(pr.createdAt)) .. " ago"
	local th, cv = S.threads[pr.number], S.convo[pr.number]
	local humans = 0
	if cv and not cv.error then
		for _, x in cv do
			if not x.bot then humans += 1 end
		end
	end
	local items = {}
	for _, t in data.TABS[S.mode] do
		local id, label = t[1], t[2]
		local count = if id == "comments" and rv and rv.status == "ok" then rv.n
			elseif id == "threads" and th and not th.error and #th > 0 then #th
			elseif id == "convo" and humans > 0 then humans else nil
		table.insert(items, { id = id, label = if count then { span(label .. " "), span(tostring(count), "muted") } else label })
	end
	local nodes = {
		N("row", { key = "nav", gap = "md" }, {
			ghost(if mine then "← My PRs" else "← All PRs", "back", "back"),
			N("row", { grow = 1 }),
			ghost("GitHub ↗", "open", "gh", { href = pr.url }),
		}),
		N("col", { key = "head", role = ROLE .. "head" }, {
			text(pr.title, ROLE .. "head-title", { key = "title" }),
			N("row", { key = "meta", gap = "md" }, {
				spans({ span(meta, "muted") }, { grow = 1, truncate = "end" }),
				sizeLine(pr, true),
				spans({ span(pr.changedFiles .. " files", "muted") }, { shrink = 0 }),
			}),
			chipRow(S, pr),
		}),
	}
	local t = trail(S, pr)
	if t then table.insert(nodes, t) end
	table.insert(nodes, actionRows(S, pr))
	table.insert(nodes, N("tabs", { key = "tabs", variant = "segmented", active = S.tab, items = items, role = ROLE .. "tabs" }))
	return N("col", { key = "detail", role = ROLE .. "detail" }, nodes)
end

-- The full id of comment `i`'s editor.
function M.editorId(i: number): string
	return "main.body.tab.cm-" .. i .. ".ed"
end

function M.build(S)
	local pr = model.find(S, S.open)
	local act = #model.active(S)
	local top = N("row", { key = "top", role = ROLE .. "top", gap = "md" }, {
		text(if S.mode == "mine" then "My PRs" else "Review", ROLE .. "name"),
		N("badge", { key = "count", text = tostring(act), tone = if act > 0 then "accent" else "muted" }),
		N("row", { grow = 1 }),
		button("", "refresh", "refresh", { variant = "quiet", icon = "repeat", title = "Refresh", busy = S.refreshing }),
	})
	local body
	if pr then
		body = N("col", { key = "body", role = ROLE .. "body" }, { detailHead(S, pr), tabBody(S, pr) })
	else
		body = N("col", { key = "body", role = ROLE .. "body" }, {
			N("col", { key = "list", role = ROLE .. "list" }, listView(S)),
		})
	end
	return { main = N("col", { role = ROLE .. "root" }, { top, body }) }
end

return M
