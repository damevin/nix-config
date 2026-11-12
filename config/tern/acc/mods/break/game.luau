--!nonstrict
-- Break's idle clicker: tokens, buildings, upgrades, lucky tokens. Output keeps
-- running while the panel is closed (the controller ticks it once a second).
local util = require("../../lib/util")

local ui = tern.ui

local BUILDINGS = {
	{ id = "prompt", name = "Prompt", sub = "a well-worded ask", base = 15, rate = 0.1 },
	{ id = "script", name = "Script", sub = "bash that works first try", base = 100, rate = 1 },
	{ id = "agent", name = "Agent", sub = "works while you sleep", base = 1100, rate = 8 },
	{ id = "swarm", name = "Sub-agents", sub = "agents spawning agents", base = 12000, rate = 47 },
	{ id = "gpu", name = "GPU rack", sub = "warm to the touch", base = 130000, rate = 260 },
	{ id = "dc", name = "Datacenter", sub = "has its own weather", base = 1.4e6, rate = 1400 },
	{ id = "model", name = "Frontier model", sub = "prompts you back", base = 2e7, rate = 7800 },
	{ id = "agi", name = "AGI", sub = "asks for a raise", base = 3.3e8, rate = 44000 },
}
-- { owned needed, cost as a multiple of the building's base price }
local TIERS = { { 1, 10 }, { 5, 50 }, { 25, 500 }, { 50, 5000 }, { 100, 50000 } }
local CLICKS = {
	{ id = "click-0", name = "Mechanical keyboard", cost = 100 },
	{ id = "click-1", name = "Vim motions", cost = 500 },
	{ id = "click-2", name = "Macros", cost = 10000 },
	{ id = "click-3", name = "Second monitor", cost = 100000 },
	{ id = "click-4", name = "Telepathy", cost = 1e7 },
}
local FEEDS = {
	{ id = "feed-0", name = "Pair programming", cost = 50000, pct = 0.01 },
	{ id = "feed-1", name = "Flow state", cost = 5e6, pct = 0.04 },
}
local BOOST = 0.5 -- extra output per agent working
local OFFLINE = 0.5 -- share of output earned while the panel's host was down
local SUFFIX = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc" }
local KEY = "break:game"
local HERDR_FILE = util.STATE .. "/acc-break/game.json"
local SAVE_EVERY_MS = 20000

local M = {}
M.__index = M

local function fmt(n: number): string
	if n ~= n or n == math.huge then return "∞" end
	if n < 1000 then
		if n < 10 and n % 1 ~= 0 then return string.format("%.1f", n) end
		return tostring(math.floor(n))
	end
	local i = math.min(#SUFFIX - 1, math.floor(math.log10(n) / 3))
	local v = n / 10 ^ (i * 3)
	return string.format(if v < 10 then "%.2f" elseif v < 100 then "%.1f" else "%.0f", v) .. SUFFIX[i + 1]
end
M.fmt = fmt

local function cost(b, n: number): number
	return math.ceil(b.base * 1.15 ^ n)
end

local function freshState()
	return { tokens = 0, earned = 0, clicks = 0, lucky = 0, owned = {}, ups = {}, last = os.time() }
end

local function gap(): number
	return (120 + math.random() * 180) * 1000
end

-- Host callbacks: { render = fn(), later = fn(ms, fn), toast = fn(text, sub?) }.
function M.new(host)
	local self = setmetatable({ host = host }, M)
	self.s = freshState()
	self.pops, self.seq = {}, 0
	self.dirty, self.savedAt = false, tern.now()
	self.luck, self.frenzy, self.working = nil, 0, 0
	self.mono = tern.now()
	self.luckNext = self.mono + gap()

	local saved = tern.kv.get(KEY)
	if type(saved) ~= "table" then
		-- First run on Tern: carry the herdr game over.
		local old = util.decodeJson(util.readFile(HERDR_FILE, 1024 * 1024))
		if type(old) == "table" then
			if (old.last or 0) > 1e11 then old.last = old.last / 1000 end
			saved = old
		end
	end
	if type(saved) == "table" then
		for k, v in saved do self.s[k] = v end
		self.s.owned = if type(self.s.owned) == "table" then self.s.owned else {}
		self.s.ups = if type(self.s.ups) == "table" then self.s.ups else {}
	end

	local away = math.min(86400, os.time() - (self.s.last or os.time()))
	local gain = self:rate(0) * away * OFFLINE
	self.s.last = os.time()
	if away > 60 and gain >= 1 then
		self:earn(gain)
		host.toast("+" .. fmt(gain) .. " tokens while you were away", "Your farm kept going at half speed.")
	end
	return self
end

function M:has(id: string): boolean
	return table.find(self.s.ups, id) ~= nil
end

function M:owned(b): number
	return self.s.owned[b.id] or 0
end

function M:each(b): number
	local doubled = 0
	for i in TIERS do
		if self:has(b.id .. "-" .. (i - 1)) then doubled += 1 end
	end
	return b.rate * 2 ^ doubled
end

function M:base(): number
	local sum = 0
	for _, b in BUILDINGS do sum += self:each(b) * self:owned(b) end
	return sum
end

function M:boosted(): boolean
	return self.frenzy > tern.now()
end

function M:rate(working: number?): number
	return self:base() * (1 + BOOST * (working or self.working)) * (if self:boosted() then 7 else 1)
end

function M:click(): number
	local doubled, feed = 0, 0
	for _, u in CLICKS do
		if self:has(u.id) then doubled += 1 end
	end
	for _, u in FEEDS do
		if self:has(u.id) then feed += u.pct end
	end
	return 2 ^ doubled + self:rate() * feed
end

function M:earn(n: number)
	self.s.tokens += n
	self.s.earned += n
	self.dirty = true
end

-- Only the next step of each ladder, so the shelf never shows two "Agent ×2".
function M:upgrades()
	local out = {}
	for _, b in BUILDINGS do
		local step = nil
		for i in TIERS do
			if not self:has(b.id .. "-" .. (i - 1)) then
				step = i
				break
			end
		end
		if step and self:owned(b) >= TIERS[step][1] then
			table.insert(out, {
				id = b.id .. "-" .. (step - 1), name = b.name .. " ×2", sub = b.name .. " output doubles",
				cost = b.base * TIERS[step][2],
			})
		end
	end
	local click, feed = nil, nil
	for _, u in CLICKS do
		if not self:has(u.id) then click = u break end
	end
	for _, u in FEEDS do
		if not self:has(u.id) then feed = u break end
	end
	if click and self.s.earned >= click.cost / 2 then
		table.insert(out, { id = click.id, name = click.name, cost = click.cost, sub = "Clicks are worth twice as much" })
	end
	if feed and self.s.earned >= feed.cost / 2 then
		table.insert(out, {
			id = feed.id, name = feed.name, cost = feed.cost,
			sub = "Clicks add " .. string.format("%g", feed.pct * 100) .. "% of your output",
		})
	end
	table.sort(out, function(a, b) return a.cost < b.cost end)
	while #out > 8 do table.remove(out) end
	return out
end

function M:save()
	self.dirty = false
	self.savedAt = tern.now()
	tern.kv.set(KEY, self.s)
end

-- Called every second by the controller, shown or not: output depends on time, not on redraws.
-- Returns true when the view should redraw.
function M:tick(working: number, shown: boolean): boolean
	local now = tern.now()
	self.working = working
	local dt = math.max(0, (now - self.mono) / 1000)
	self.mono = now
	self.s.last = os.time()
	if dt > 0 then self:earn(self:rate() * dt) end
	local changed = false
	if self.luck and now > self.luck.until_ then
		self.luck = nil
		changed = true
	end
	if shown and not self.luck and now > self.luckNext and self.s.earned > 50 then
		self.luck = { x = 0.15 + math.random() * 0.7, y = 12 + math.random() * 120, until_ = now + 13000 }
		self.luckNext = now + gap()
		changed = true
	end
	if self.dirty and now - self.savedAt > SAVE_EVERY_MS then self:save() end
	return changed
end

function M:pop(text: string, x: number, y: number)
	self.seq += 1
	local id = self.seq
	table.insert(self.pops, { id = id, text = text, x = x, y = y })
	self.host.later(900, function()
		for i, p in self.pops do
			if p.id == id then
				table.remove(self.pops, i)
				break
			end
		end
		self.host.render()
	end)
end

function M:press()
	local n = self:click()
	self:earn(n)
	self.s.clicks += 1
	self:pop("+" .. fmt(n), 0.5 + (math.random() - 0.5) * 0.45, 40 + math.random() * 30)
end

function M:catchLuck()
	local l = self.luck
	if not l then return end
	self.luck = nil
	self.s.lucky += 1
	if math.random() < 0.5 and self:base() > 0 then
		self.frenzy = tern.now() + 30000
		self:pop("Frenzy ×7 for 30s", l.x, l.y)
	else
		local n = math.max(13, math.min(self.s.tokens * 0.15, self:rate() * 900))
		self:earn(n)
		self:pop("Lucky! +" .. fmt(n), l.x, l.y)
	end
	self:save()
end

function M:buy(id: string, many: boolean)
	for _, b in BUILDINGS do
		if b.id == id then
			for _ = 1, if many then 10 else 1 do
				local c = cost(b, self:owned(b))
				if self.s.tokens < c then break end
				self.s.tokens -= c
				self.s.owned[b.id] = self:owned(b) + 1
			end
			break
		end
	end
	self:save()
end

function M:upgrade(id: string)
	for _, u in self:upgrades() do
		if u.id == id then
			if self.s.tokens < u.cost or self:has(u.id) then return end
			self.s.tokens -= u.cost
			table.insert(self.s.ups, u.id)
			self:save()
			return
		end
	end
end

function M:reset()
	self.s = freshState()
	self.frenzy, self.luck = 0, nil
	self:save()
end

-- Handles an action event from the view; returns true when it was the game's.
function M:event(act: string, value: string?, mods): boolean
	if act == "press" then self:press()
	elseif act == "luck" then self:catchLuck()
	elseif act == "buy" then
		local shift = false
		for _, m in (mods or {}) do
			if m == "shift" then shift = true end
		end
		self:buy(value, shift)
	elseif act == "upgrade" then self:upgrade(value)
	elseif act == "reset" then self:reset()
	elseif act == "reset-hint" then self.host.toast("Double-click to start over")
	else return false end
	return true
end

-- ---- view

local function div(role: string, props: { [string]: any }?, children: { any }?, text: string?)
	local p = props or {}
	p.tag, p.role = p.tag or "div", role
	if text then p.text = text end
	return ui.node("el", p, children)
end

-- Blob ids of the SVG icons, set by the panel (`cx:blob` ids are content hashes, the same everywhere).
M.blobs = {}

local function token(size: number, tone: string)
	return ui.node("image", { blob = M.blobs.token, role = "acc.break.token", w = size, h = size, tone = tone, alt = "" })
end

local function section(text: string, right: string?)
	return div("acc.break.section", nil, {
		div("acc.break.section-t", nil, nil, text),
		if right then div("acc.break.section-r", nil, nil, right) else nil,
	})
end

local function bucket(v: number, step: number): number
	return math.floor(v / step + 0.5)
end

function M:view(working: number)
	local now = tern.now()
	local rate, frenzy, ups = self:rate(), self:boosted(), self:upgrades()
	local shown = {}
	for i, b in BUILDINGS do
		if self:owned(b) > 0 or self.s.earned >= b.base * 0.4 or i == 1 then table.insert(shown, b) end
	end
	local nextB = BUILDINGS[#shown + 1]

	local score = div("acc.break.score", nil, {
		div("acc.break.score-row", nil, {
			token(22, "accent"),
			div("acc.break.score-num", nil, nil, fmt(self.s.tokens)),
		}),
		div("acc.break.score-sub", nil, nil, "tokens · " .. fmt(rate) .. " per second"),
		div("acc.break.agents", { class = if working > 0 then "on" else "" }, {
			div("acc.break.agents-dot"),
			div("acc.break.agents-t", nil, nil, if working > 0
				then string.format("%d agent%s working · ×%g output", working, if working > 1 then "s" else "", 1 + BOOST * working)
				else "Start an agent: each one working adds ×0.5"),
		}),
		if frenzy then div("acc.break.frenzy", nil, nil, string.format("Frenzy ×7 · %ds", math.ceil((self.frenzy - now) / 1000))) else nil,
	})

	local field = {
		div("acc.break.ring", { class = if frenzy then "frenzy" else "" }),
		div("acc.break.core", { key = "core", class = if frenzy then "frenzy" else "", actions = { click = "press" } }, {
			div("acc.break.core-t", nil, { token(76, "accent") }),
		}),
	}
	for _, p in self.pops do
		table.insert(field, div("acc.break.pop", {
			key = "pop-" .. p.id, class = "x" .. bucket(p.x, 0.05) .. " y" .. bucket(p.y, 8),
		}, nil, p.text))
	end
	if self.luck then
		table.insert(field, div("acc.break.luck", {
			key = "luck", class = "x" .. bucket(self.luck.x, 0.05) .. " y" .. bucket(self.luck.y, 8),
			actions = { click = "luck" },
		}, { token(20, "warning") }))
	end

	local upNodes = {}
	local ready = 0
	for _, u in ups do
		local ok = self.s.tokens >= u.cost
		if ok then ready += 1 end
		table.insert(upNodes, div("acc.break.up", {
			key = "up-" .. u.id, class = if ok then "ok" else "no",
			actions = if ok then { click = "upgrade=" .. u.id } else nil,
		}, {
			div("acc.break.up-name", nil, nil, u.name),
			div("acc.break.up-sub", nil, nil, fmt(u.cost) .. " · " .. u.sub),
		}))
	end

	local rows = {}
	local base = self:base()
	for _, b in shown do
		local n = self:owned(b)
		local c = cost(b, n)
		local ok = self.s.tokens >= c
		local share = if base > 0 then math.floor(self:each(b) * n / base * 100 + 0.5) else 0
		table.insert(rows, div("acc.break.bd", {
			key = "bd-" .. b.id, class = if ok then "ok" else "no",
			actions = if ok then { click = "buy=" .. b.id } else nil,
		}, {
			div("acc.break.bd-n", { class = if n > 0 then "has" else "" }, nil, tostring(n)),
			div("acc.break.bd-text", nil, {
				div("acc.break.bd-name", nil, nil, b.name),
				div("acc.break.bd-sub", nil, nil, if n > 0
					then fmt(self:each(b)) .. "/s each · " .. share .. "% of output"
					else b.sub .. " · " .. fmt(self:each(b)) .. "/s"),
			}),
			div("acc.break.bd-cost", { class = if ok then "ok" else "no" }, {
				token(11, if ok then "accent" else "muted"),
				div("acc.break.bd-cost-n", nil, nil, fmt(c)),
			}),
		}))
	end
	if nextB then
		table.insert(rows, div("acc.break.locked", { key = "locked" }, {
			div("acc.break.bd-n", nil, nil, "?"),
			div("acc.break.locked-t", nil, nil, "Unlocks at " .. fmt(nextB.base * 0.4) .. " tokens earned"),
		}))
	end

	return div("acc.break.game", { key = "game" }, {
		score,
		div("acc.break.field", { key = "field" }, field),
		section("Upgrades", if #ups > 0 then ready .. " ready" else nil),
		if #ups > 0 then div("acc.break.ups", { key = "ups" }, upNodes)
			else div("acc.break.ups-empty", nil, nil, "Keep building: upgrades unlock as you grow."),
		section("Build", "shift-click buys 10"),
		div("acc.break.rows", { key = "rows" }, rows),
		div("acc.break.foot", nil, {
			div("acc.break.foot-t", nil, nil, string.format("%s earned · %s clicks · %d lucky",
				fmt(self.s.earned), fmt(self.s.clicks), self.s.lucky)),
			div("acc.break.reset", { actions = { click = "reset-hint", dblclick = "reset" } }, nil, "Start over"),
		}),
	})
end

M.div = div
M.section = section

return M
