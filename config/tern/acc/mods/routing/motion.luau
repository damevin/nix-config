--!nonstrict
-- Geometry and SVG for the routing diagram. Tern draws an SVG blob as real
-- elements and animates them with the sheet's @keyframes, but a host half
-- can't add keyframes at run time. So every flight is built from keyframes
-- that are fixed in style.css and move a unit shape: the wires are cubic
-- beziers with horizontal tangents, whose x and y are each a polynomial in t,
-- so a group scaled by (dx, dy) with x and y keyframes eased by
-- cubic-bezier(1/3, .5, 2/3, .5) and (1/3, 0, 2/3, 1) rides the wire exactly.
-- Duration and delay come from the 50 ms classes `d<ms>` and `s<ms>`.
local util = require("../../lib/util")

local M = {}

M.PALETTE = { "#d97757", "#bd8638", "#a59234", "#849e4a", "#5aa66c", "#25a98f", "#00a6b0", "#2e9fc9", "#5e95d7", "#858ad7", "#a47fca", "#bb77b1" }
local HUES = { claude = 0, codex = 9, gemini = 7, copilot = 10, cursor = 5, opencode = 2, crush = 11, goose = 3, pi = 4, omp = 11, omo = 10, dsh = 6, commandcode = 1, mimocode = 8, deveco = 7 }
M.RED = "#e5534b"

M.AW, M.HW, M.AH, M.PH, M.HH, M.PAD, M.GH, M.CY = 118, 84, 46, 42, 60, 14, 170, 78
local AW, HW, AH, PH, HH, PAD, GH, CY = M.AW, M.HW, M.AH, M.PH, M.HH, M.PAD, M.GH, M.CY
local VIA_D, VIA_H = HW + 4, 30
M.VIA_D = VIA_D

function M.hueOf(id: string, given: { [string]: string }, near: { [string]: boolean }?): string
	local c = given[id]
	if c and not (near and near[c]) then return c end
	local h = HUES[id]
	if h == nil then
		h = 0
		for _, cp in utf8.codes(id) do h = (h * 31 + cp) % 4294967296 end
	end
	local had = {}
	for _, v in given do had[v] = true end
	local n = #M.PALETTE
	local function from(k) return M.PALETTE[(h + k) % n + 1] end
	local pick = nil
	for k = 0, n - 1 do
		if not had[from(k)] and not (near and near[from(k)]) then pick = k break end
	end
	if pick == nil then
		for k = 0, n - 1 do
			if not (near and near[from(k)]) then pick = k break end
		end
	end
	c = from(pick or 0)
	given[id] = c
	return c
end

local function wireLen(x1, y1, x2, y2): number
	local mx, len, px, py = (x1 + x2) / 2, 0, x1, y1
	for s = 1, 60 do
		local t = s / 60
		local u = 1 - t
		local x = u * u * u * x1 + 3 * u * u * t * mx + 3 * u * t * t * mx + t * t * t * x2
		local y = u * u * u * y1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y2
		len += math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
		px, py = x, y
	end
	return len
end

local function viaLen(): number
	local a1, a2 = 18 / VIA_D, (VIA_D - 18) / VIA_D
	local len, px, py = 0, 0, 0
	for s = 1, 24 do
		local t = s / 24
		local u = 1 - t
		local x = VIA_D * (3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t)
		local y = -4 * VIA_H * t * (1 - t)
		len += math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
		px, py = x, y
	end
	return len
end
M.VIA_LEN = viaLen()
M.wireLen = wireLen

local function stack(n: number, h: number, gap: number): ({ number }, number)
	local span = 2 * math.min(CY, GH - CY)
	local height = h
	if n * h + (n - 1) * gap > span then
		height = math.max(14, math.floor((span - (n - 1) * gap) / n))
	end
	local ys = {}
	for i = 1, n do
		ys[i] = CY - (n * height + (n - 1) * gap) / 2 + (i - 1) * (height + gap)
	end
	return ys, height
end

-- Card and wire positions for a diagram W units wide.
function M.layout(W: number, agents: { string }, providers: { string })
	local pw = math.max(80, math.min(150, W - 2 * PAD - AW - HW - 80))
	local gap = math.max(24, (W - 2 * PAD - AW - HW - pw) / 2)
	local ax = PAD
	local hx = ax + AW + gap
	local px = hx + HW + gap
	local ays, ah = stack(#agents, AH, 10)
	local pys, ph = stack(#providers, PH, 8)
	local wires = {}
	for i, id in agents do
		local w = { x1 = ax + AW + 3, y1 = ays[i] + ah / 2, x2 = hx - 2, y2 = CY }
		w.L = wireLen(w.x1, w.y1, w.x2, w.y2)
		wires["a:" .. id] = w
	end
	for i, id in providers do
		local w = { x1 = hx + HW + 2, y1 = CY, x2 = px - 3, y2 = pys[i] + ph / 2 }
		w.L = wireLen(w.x1, w.y1, w.x2, w.y2)
		wires["p:" .. id] = w
	end
	return { W = W, ax = ax, hx = hx, px = px, pw = pw, ays = ays, ah = ah, pys = pys, ph = ph, wires = wires, agents = agents, providers = providers }
end

local function esc(s: string): string
	return (string.gsub(string.gsub(string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"), '"', "&quot;"))
end

local function f(x: number): string
	local s = string.format("%.2f", x)
	s = string.gsub(s, "%.?0+$", "")
	return if s == "-0" or s == "" then "0" else s
end

local function f6(x: number): string
	return string.format("%.6f", x)
end

local function wireD(w): string
	local mx = (w.x1 + w.x2) / 2
	return string.format("M%s %s C%s %s %s %s %s %s", f(w.x1), f(w.y1), f(mx), f(w.y1), f(mx), f(w.y2), f(w.x2), f(w.y2))
end

local function head(W: number): string
	return string.format('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">', W, GH, W, GH)
end

-- Width of the first `max` characters' worth of room: 13px semibold glyphs average about 7px.
local function fit(s: string, width: number, px: number): string
	return util.truncate(s, math.max(3, math.floor(width / (px * 0.56))))
end

-- The static diagram: wires that aren't flowing, the cards and their text.
-- agents: { {id, color, n, task} }, providers: { {id, model} }.
function M.base(geo, agents, providers, flowing: { [string]: boolean }, hint: string?): string
	local out = { head(geo.W) }
	for key, w in geo.wires do
		if not flowing[key] then
			table.insert(out, '<path class="rt-wire" d="' .. wireD(w) .. '"/>')
		end
	end
	for i, a in agents do
		local y, h = geo.ays[i], geo.ah
		local cx = geo.ax + AW / 2
		table.insert(out, string.format('<rect class="rt-card" x="%s" y="%s" width="%d" height="%s" rx="10"/>', f(geo.ax), f(y), AW, f(h)))
		local label = fit(if a.n > 0 then a.id .. " · " .. a.n else a.id, AW - 22, 13)
		local gw = 12 + #label * 7.2
		local two = h >= 34
		local ny = if two then y + h / 2 - 3 else y + h / 2 + 4.5
		table.insert(out, string.format('<circle cx="%s" cy="%s" r="3.5" fill="%s"/>', f(cx - gw / 2 + 3.5), f(ny - 4.5), a.color))
		table.insert(out, string.format('<text class="rt-name" x="%s" y="%s">%s</text>', f(cx - gw / 2 + 12), f(ny), esc(label)))
		if two then
			table.insert(out, string.format('<text class="rt-sub" x="%s" y="%s" text-anchor="middle">%s</text>', f(cx), f(y + h / 2 + 11), esc(fit(a.task or "idle", AW - 10, 10.5))))
		end
	end
	local hy = CY - HH / 2
	table.insert(out, string.format('<rect class="rt-card rt-hub" x="%s" y="%s" width="%d" height="%d" rx="10"/>', f(geo.hx), f(hy), HW, HH))
	table.insert(out, string.format('<text class="rt-name" x="%s" y="%s" text-anchor="middle">magpie</text>', f(geo.hx + HW / 2), f(CY - 3)))
	table.insert(out, string.format('<text class="rt-sub" x="%s" y="%s" text-anchor="middle">:3425</text>', f(geo.hx + HW / 2), f(CY + 11)))
	for i, p in providers do
		local y, h = geo.pys[i], geo.ph
		local cx = geo.px + geo.pw / 2
		table.insert(out, string.format('<rect class="rt-card" x="%s" y="%s" width="%s" height="%s" rx="10"/>', f(geo.px), f(y), f(geo.pw), f(h)))
		local two = h >= 34
		table.insert(out, string.format('<text class="rt-name" x="%s" y="%s" text-anchor="middle">%s</text>', f(cx), f(if two then y + h / 2 - 3 else y + h / 2 + 4.5), esc(fit(p.id, geo.pw - 12, 13))))
		if two then
			table.insert(out, string.format('<text class="rt-sub rt-model" x="%s" y="%s" text-anchor="middle">%s</text>', f(cx), f(y + h / 2 + 12), esc(fit(if p.model ~= "" then p.model else "—", geo.pw - 12, 11))))
		end
	end
	if hint then
		table.insert(out, string.format('<text class="rt-sub" x="%d" y="%d">%s</text>', PAD, 14, esc(hint)))
	end
	table.insert(out, "</svg>")
	return table.concat(out)
end

-- A flowing wire: dashes in the agent's color running toward the end.
function M.flow(geo, key: string, color: string): string
	return head(geo.W) .. '<path class="rt-flow" stroke="' .. color .. '" d="' .. wireD(geo.wires[key]) .. '"/></svg>'
end

-- A card's outline pulsing once (herdr scaled the card by 4% over 400 ms).
function M.pulse(geo, kind: string, index: number?): string
	local x, y, w, h
	if kind == "hub" then
		x, y, w, h = geo.hx, CY - HH / 2, HW, HH
	else
		x, y, w, h = geo.ax, geo.ays[index], AW, geo.ah
	end
	return head(geo.W) .. string.format('<g transform="translate(%s %s)"><rect class="rt-pulse" x="%s" y="%s" width="%s" height="%s" rx="10"/></g></svg>',
		f(x + w / 2), f(y + h / 2), f(-w / 2), f(-h / 2), f(w), f(h))
end

-- A failing provider: its card shakes in red for 450 ms and keeps the red ring
-- and the status badge until the layer is removed (1.8 s).
function M.hit(geo, index: number, provider: string, model: string, status: string): string
	local y, h, w = geo.pys[index], geo.ph, geo.pw
	local cx = geo.px + w / 2
	local two = h >= 34
	local out = { head(geo.W), '<g class="rt-shake">' }
	table.insert(out, string.format('<rect class="rt-card rt-hit" x="%s" y="%s" width="%s" height="%s" rx="10"/>', f(geo.px), f(y), f(w), f(h)))
	table.insert(out, string.format('<text class="rt-name" x="%s" y="%s" text-anchor="middle">%s</text>', f(cx), f(if two then y + h / 2 - 3 else y + h / 2 + 4.5), esc(fit(provider, w - 12, 13))))
	if two then
		table.insert(out, string.format('<text class="rt-sub rt-model" x="%s" y="%s" text-anchor="middle">%s</text>', f(cx), f(y + h / 2 + 12), esc(fit(if model ~= "" then model else "—", w - 12, 11))))
	end
	table.insert(out, "</g>")
	local bw = #status * 6.4 + 14
	table.insert(out, string.format('<rect x="%s" y="%s" width="%s" height="16" rx="6" fill="%s"/>', f(geo.px + w - 44), f(y - 9), f(bw), M.RED))
	table.insert(out, string.format('<text class="rt-badge" x="%s" y="%s" text-anchor="middle">%s</text>', f(geo.px + w - 44 + bw / 2), f(y + 2.5), esc(status)))
	table.insert(out, "</svg>")
	return table.concat(out)
end

local BIRD = table.concat({
	'<path class="rt-wf rt-wing" d="M-14.5 -3.4C-16.5 -9.5 -14.2 -15 -8.6 -18.6C-9.4 -12.6 -9.6 -7.4 -9.2 -3.2Z"/>',
	'<path class="rt-ink" d="M-31.5 3.1L-18.6 -1.8L-17.4 1.2L-30.8 4.6Z"/>',
	'<path class="rt-ink" d="M-19.8 -1.4a7.6 3.9 0 1 0 15.2 0a7.6 3.9 0 1 0 -15.2 0Z"/>',
	'<path class="rt-belly" d="M-17.1 .4a4.3 1.6 0 1 0 8.6 0a4.3 1.6 0 1 0 -8.6 0Z"/>',
	'<path class="rt-ink" d="M-8 -3.7a3.1 3.1 0 1 0 6.2 0a3.1 3.1 0 1 0 -6.2 0Z"/>',
	'<path class="rt-ink" d="M-2.3 -4.8L1.4 -3.3L-2.3 -2.2Z"/>',
	'<path class="rt-ink rt-wn rt-wing" d="M-15.6 -3.2C-17.8 -10.2 -15.2 -16.4 -8.4 -20.4C-9.3 -13.6 -9.4 -7.8 -8.8 -2.8Z"/>',
	'<path class="rt-bar rt-wn rt-wing" d="M-14.6 -5.6C-15.4 -10.4 -13.8 -14.4 -10.4 -17.2"/>',
})
local BIRD_G = '<g transform="scale(1.2) translate(-6.5 3.2)">' .. BIRD .. "</g>"

local function dotGlyph(color: string, style: string): string
	if style == "back" then
		return '<circle class="rt-ring" r="4" fill="' .. color .. '" stroke="' .. color .. '"/>'
	elseif style == "err" then
		return '<circle class="rt-ring rt-err" r="4" fill="' .. color .. '" stroke="' .. M.RED .. '"/>'
	end
	return '<circle r="7.5" fill="' .. color .. '" fill-opacity=".22"/><circle r="4.5" fill="' .. color .. '"/>'
end

local function q(ms: number, max: number): number
	return math.max(0, math.min(max, math.floor(ms / 50 + 0.5) * 50))
end

local function aimClass(peak: number): string
	local b = math.floor(math.abs(peak) / 6 + 0.5) * 6
	if b == 0 then return "" end
	return (if peak < 0 then " a-m" else " a-p") .. b
end

-- One flight: a dot (and a bird) along legs = { {kind = "wire"|"via", sx, sy, ex, ey} },
-- ms in all, then a resting dot / bird or a bird flying off. opts: color, dot
-- ("out"|"back"|"err"), bird ("new"|"cont"|"none"), endBird ("away"|"rest"|"none"),
-- endDot ("hold"|"rest"|"none"). Returns svg, lifetime in ms (nil: until replaced).
function M.trip(geo, legs, ms: number, opts): (string, number?)
	local total = 0
	for _, l in legs do
		l.len = if l.kind == "via" then M.VIA_LEN else wireLen(l.sx, l.sy, l.ex, l.ey)
		total += l.len
	end
	total = math.max(total, 1)
	local out = { head(geo.W) }
	local at = 0
	local last = nil
	for i, l in legs do
		local dur = ms * l.len / total
		local s, d = q(at, 6000), math.max(50, q(dur, 3000))
		local cls = " s" .. s .. " d" .. d
		local dx, dy = l.ex - l.sx, l.ey - l.sy
		local sx, sy
		if l.kind == "via" then
			sx, sy = dx, VIA_H
		else
			sx = if math.abs(dx) < 0.01 then 0.01 else dx
			sy = if math.abs(dy) < 0.01 then 0.01 else dy
		end
		local flip = if dx < 0 then -1 else 1
		local aim
		if l.kind == "via" then
			aim = " a-via"
		else
			aim = aimClass(math.min(24, math.deg(math.atan(2 * math.abs(dy) / math.max(math.abs(dx), 1)))) * (if dy < 0 then -1 else 1))
		end
		local xk, yk = if l.kind == "via" then "rt-vx" else "rt-wx", if l.kind == "via" then "rt-vy" else "rt-wy"
		table.insert(out, string.format('<g class="rt-leg%s"><g transform="matrix(%s 0 0 %s %s %s)"><g class="%s%s"><g class="%s%s"><g transform="matrix(%s 0 0 %s 0 0)">',
			cls, f6(sx), f6(sy), f(l.sx), f(l.sy), xk, cls, yk, cls, f6(1 / sx), f6(1 / sy)))
		table.insert(out, dotGlyph(opts.color, opts.dot))
		if opts.bird ~= "none" then
			local come = if i == 1 and opts.bird == "new" then " rt-come" else ""
			table.insert(out, string.format('<g transform="scale(%d 1)"><g class="rt-aim%s%s"><g class="%s">%s</g></g></g>', flip, aim, cls, string.sub(come, 2), BIRD_G))
		end
		table.insert(out, "</g></g></g></g></g>")
		at += dur
		last = { x = l.ex, y = l.ey, flip = flip }
	end
	local e = q(at, 6000)
	local ecls = " s" .. e
	if last and (opts.endDot ~= "none" or opts.endBird == "rest") then
		table.insert(out, string.format('<g class="rt-rest%s" transform="translate(%s %s)">', ecls, f(last.x), f(last.y)))
		if opts.endDot == "hold" then
			table.insert(out, '<g class="rt-held">' .. dotGlyph(opts.color, "out") .. "</g>")
		elseif opts.endDot == "rest" then
			table.insert(out, dotGlyph(opts.color, "out"))
		end
		if opts.endBird == "rest" then
			table.insert(out, string.format('<g transform="scale(%d 1)">%s</g>', last.flip, BIRD_G))
		end
		table.insert(out, "</g>")
	end
	if last and opts.endBird == "away" then
		table.insert(out, string.format('<g class="rt-awaywin%s" transform="translate(%s %s)"><g transform="scale(%d 1)"><g class="rt-away%s">%s</g></g></g>',
			ecls, f(last.x), f(last.y), last.flip, ecls, BIRD_G))
	end
	table.insert(out, "</svg>")
	local life = nil
	if opts.endDot == "none" and opts.endBird ~= "rest" then
		life = math.floor(at + (if opts.endBird == "away" then 450 else 0) + 250)
	end
	return table.concat(out), life
end

return M
