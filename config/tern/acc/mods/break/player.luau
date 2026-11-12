--!nonstrict
-- Break's engine, one per plugin load (not per panel): the mpv player and its
-- queue, the Twitch checks, the agent watcher that pauses music and the game
-- clock. Panels only draw its state, so music, agents and output keep going
-- while the panel is closed.
local util = require("../../lib/util")
local proc = require("../../lib/proc")
local timer = require("../../lib/timer")
local facts = require("../../lib/facts")
local Field = require("../../lib/field")
local Game = require("./game")
local M = {}

local DIR = util.STATE .. "/acc-break"
local SOCK = DIR .. "/mpv.sock"
local LOG = DIR .. "/mpv.log"
local HELPERS = tern.plugin.dir .. "/mods/break"
local MPV_PY = HELPERS .. "/mpv.py"
local FRAME_JS = HELPERS .. "/frame.js"
local KEY = "break:state"

M.RADIO = { { name = "Lofi Girl", sub = "live radio to focus", url = "https://www.youtube.com/@LofiGirl/live" } }
M.TABS = { { "listen", "Listen" }, { "play", "Play" } }

local FORMAT = { audio = "bestaudio/best", video = "bestvideo[height<=?720]+bestaudio/best" }

-- Where the video lands, in the window's px: the shown tab's tree fills the area below the tab strip
-- (3px frame; panes 13px inside it), and the panel draws a 44px head and 10px margin above the video.
local CONTENT = { left = 3, top = 37, right = 3, bottom = 3 }
local PANE_INSET, HEAD, INSET = 13, 44, 10
local DOCK_REFRESH_MS = 3000

M.data = { favorites = {}, queue = {}, tab = "listen", auto = { pause = true, resume = true } }
M.live = {}
M.player = nil
M.reason = nil
M.loading, M.loadingAudio = nil, false
M.fields = { link = Field.new(""), chan = Field.new("") }
M.focused = nil
M.working = 0

local blocks: { { cx: any, pane: number } } = {}
local autoPaused, autoAt = false, 0
local lastStatus = nil
local nextPoll, liveNext, dockNext = 0, 0, 0
local wasShown, docked = false, nil
local lastShared = nil
local lastPlayerJson = ""
local lastGeometry = nil
local pendingToasts = {}
local game

local function isNull(v): boolean
	return v == nil or v == tern.json.null
end

-- ---- panels

function M.attach(cx)
	table.insert(blocks, { cx = cx, pane = cx.pane })
	for _, t in pendingToasts do pcall(function() cx:toast("info", t[1], t[2]) end) end
	pendingToasts = {}
end

local function liveBlocks()
	local out = {}
	for _, b in blocks do
		if timer.alive(b.pane) then table.insert(out, b) end
	end
	blocks = out
	return out
end

function M.render()
	for _, b in liveBlocks() do pcall(function() b.cx:render() end) end
end

function M.toast(text: string, sub: string?)
	local live = liveBlocks()
	if #live == 0 then
		table.insert(pendingToasts, { text, sub })
		return
	end
	pcall(function() live[1].cx:toast("info", text, sub) end)
end

local function treeHas(tree, pane: number): boolean
	if type(tree) ~= "table" then return false end
	if tree.pane then return tree.pane == pane end
	return treeHas(tree[1] or tree["1"], pane) or treeHas(tree[2] or tree["2"], pane)
end

-- The pane of a panel in the tab being shown, or nil when none is.
local function shownPane(fx): number?
	local layout = fx.layout
	if type(layout) ~= "table" then return nil end
	for _, b in liveBlocks() do
		if treeHas(layout.root, b.pane) and (not layout.zoomed or layout.focus == b.pane) then return b.pane end
	end
	return nil
end

-- ---- persistence

local function save()
	tern.kv.set(KEY, M.data)
end
M.save = save

local function load()
	local saved = tern.kv.get(KEY)
	if type(saved) ~= "table" then
		-- First run on Tern: carry the herdr favorites and queue over.
		saved = util.decodeJson(util.readFile(DIR .. "/state.json", 1024 * 1024))
	end
	if type(saved) ~= "table" then return end
	local d = M.data
	if type(saved.favorites) == "table" then d.favorites = saved.favorites end
	if type(saved.queue) == "table" then d.queue = saved.queue end
	if saved.tab == "listen" or saved.tab == "play" then d.tab = saved.tab end
	if type(saved.auto) == "table" then
		for k, v in saved.auto do d.auto[k] = v end
	end
	for _, it in d.queue do
		if not it.id then it.id = string.format("%s-%d", tostring(it.added or os.time()), math.random(1, 1e6)) end
	end
end

-- ---- mpv

local function q(s: string): string
	return util.shq(tostring(s))
end

local function tool(bin: string, args: string): string
	return string.format(
		"if command -v mpv >/dev/null && command -v yt-dlp >/dev/null; then %s %s; else nix shell nixpkgs#mpv nixpkgs#yt-dlp -c %s %s; fi",
		bin, args, bin, args)
end

-- mpv per-file options; %n% quotes a value so its own `=`, `[` and `/` stay literal.
local function fileOpts(audio: boolean, start: number?): string
	local fmt = if audio then FORMAT.audio else FORMAT.video
	local parts = {
		if audio then "vid=no,force-window=no" else "vid=auto,force-window=immediate",
		string.format("ytdl-format=%%%d%%%s", #fmt, fmt),
	}
	if start and start > 0 then table.insert(parts, "start=" .. math.floor(start)) end
	return table.concat(parts, ",")
end

-- cb(replies | nil): one reply per command; nil when mpv isn't running.
local function ipc(cmds, cb)
	proc.run("break mpv ipc", { "python3", MPV_PY, "ipc", SOCK, tern.json.encode(cmds) }, { timeout_ms = 4000 }, function(r)
		local replies = if r.status == 0 then util.decodeJson(r.stdout) else nil
		if cb then cb(if type(replies) == "table" then replies else nil) end
	end)
end

local function control(cmds)
	ipc(cmds, function()
		nextPoll = 0
	end)
end
M.control = control

local function clean(title: string): string
	local t = string.gsub(title, "%s%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$", "")
	t = string.gsub(t, "%s*%([Ll][Ii][Vv][Ee]%)%s*$", "")
	return t
end

local function parsePlayer(r)
	if not r then return nil end
	local any = false
	for i = 1, #r do
		if not isNull(r[i]) then any = true end
	end
	if not any then return nil end
	local path = if isNull(r[4]) then nil else tostring(r[4])
	local duration = if type(r[7]) == "number" and r[7] > 0
			and not (path and (string.find(path, "twitch.tv", 1, true) or string.find(path, "/live", 1, true)))
		then r[7] else nil
	return {
		title = clean(tostring(if not isNull(r[1]) then r[1] elseif path then path else "Loading…")),
		paused = r[2] == true,
		volume = math.floor((if type(r[3]) == "number" then r[3] else 60) + 0.5),
		path = path,
		audio = r[5] == false or r[5] == "no",
		pos = if type(r[6]) == "number" then r[6] else 0,
		duration = duration,
		mute = r[8] == true,
		count = if type(r[9]) == "number" then r[9] else 1,
		index = if type(r[10]) == "number" then r[10] else 0,
	}
end

local function publishState()
	local p = M.player
	local state = if p then (if p.paused then "paused" else "playing") else nil
	if state ~= lastShared then
		lastShared = state
		tern.kv.set("shared:break.state", state)
	end
end

local function poll()
	ipc({
		{ "get_property", "media-title" }, { "get_property", "pause" }, { "get_property", "volume" },
		{ "get_property", "path" }, { "get_property", "vid" }, { "get_property", "time-pos" },
		{ "get_property", "duration" }, { "get_property", "mute" }, { "get_property", "playlist-count" },
		{ "get_property", "playlist-pos" },
	}, function(r)
		local nextPlayer = parsePlayer(r)
		if nextPlayer then
			-- Played again from elsewhere (media keys, the mpv window): no longer ours to resume.
			if not nextPlayer.paused and autoPaused and tern.now() - autoAt > 3000 then
				autoPaused, M.reason = false, nil
			end
			M.loading = nil
		else
			M.reason, autoPaused = nil, false
		end
		M.player = nextPlayer
		publishState()
		local json = tern.json.encode(nextPlayer or {})
		if json ~= lastPlayerJson then
			lastPlayerJson = json
			M.syncDock(shownPane(facts.read()) ~= nil)
			M.render()
		end
	end)
end

-- ---- window geometry

-- cb(frame | nil): the Tern window hosting the panel, in screen points.
local function frameInfo(cb)
	local script = 'daemon=$PPID; app=$(ps -o ppid= -p "$daemon" | tr -d " "); exec osascript -l JavaScript "$1" "$app"'
	proc.sh("break frame", script, { FRAME_JS }, { timeout_ms = 5000 }, function(r)
		cb(if r.status == 0 then util.decodeJson(r.stdout) else nil)
	end)
end

local function paneRect(tree, pane: number, rect)
	if type(tree) ~= "table" then return nil end
	if tree.pane then return if tree.pane == pane then rect else nil end
	local ratio = tree.ratio or 0.5
	local first, second
	if tree.split == "down" then
		first = { x = rect.x, y = rect.y, w = rect.w, h = rect.h * ratio }
		second = { x = rect.x, y = rect.y + first.h, w = rect.w, h = rect.h - first.h }
	else
		first = { x = rect.x, y = rect.y, w = rect.w * ratio, h = rect.h }
		second = { x = rect.x + first.w, y = rect.y, w = rect.w - first.w, h = rect.h }
	end
	return paneRect(tree[1] or tree["1"], pane, first) or paneRect(tree[2] or tree["2"], pane, second)
end

-- The video's rectangle in window px (origin: window's top-left), or nil.
local function videoRect(layout, pane: number, frame)
	local content = {
		x = CONTENT.left, y = CONTENT.top,
		w = frame.w - CONTENT.left - CONTENT.right, h = frame.h - CONTENT.top - CONTENT.bottom,
	}
	local rect = if layout.zoomed and layout.focus == pane then content else paneRect(layout.root, pane, content)
	if not rect then return nil end
	local w = math.max(240, rect.w - 2 * PANE_INSET - 2 * INSET)
	return {
		x = rect.x + PANE_INSET + INSET, y = rect.y + PANE_INSET + HEAD + INSET,
		w = w, h = math.floor(w * 9 / 16),
	}
end

-- cb(mpv geometry string, frame | nil)
local function geometry(cb)
	frameInfo(function(f)
		local fx = facts.read()
		local pane = shownPane(fx)
		local rect = if f and pane then videoRect(fx.layout, pane, f) else nil
		if not rect then
			cb("760x428-40-40", f)
			return
		end
		local s = f.scale or 1
		cb(string.format("%dx%d+%d+%d", math.floor(rect.w * s + 0.5), math.floor(rect.h * s + 0.5),
			math.floor((f.x + rect.x) * s + 0.5), math.floor((f.y + rect.y - (f.top or 0)) * s + 0.5)), f)
	end)
end

-- The mpv window sits over the panel while a video shows on the Listen tab and hides otherwise.
local function dock(show: boolean)
	proc.run("break aerospace", {
		"aerospace", "list-windows", "--all", "--format", "%{window-id}|%{app-name}|%{window-title}|%{workspace}",
	}, { timeout_ms = 4000 }, function(list)
		if list.status ~= 0 then return end
		geometry(function(g, f)
			local mpv, tern_ws = nil, nil
			for _, line in util.lines(list.stdout) do
				local id, app, title, ws = string.match(line, "^([^|]*)|([^|]*)|(.*)|([^|]*)$")
				if id then
					if string.find(string.lower(app), "mpv", 1, true) and title == "Break" then mpv = { id = id, ws = ws } end
					if f and tostring(f.id) == id then tern_ws = ws end
				end
			end
			if not mpv then return end
			local target = if show then tern_ws else "break-hidden"
			local function place()
				if show then
					lastGeometry = g
					ipc({ { "set_property", "geometry", g } })
				end
			end
			if target and mpv.ws ~= target then
				proc.run("break aerospace move", { "aerospace", "move-node-to-workspace", "--window-id", mpv.id, target },
					{ timeout_ms = 4000 }, place)
			else
				place()
			end
		end)
	end)
end

function M.syncDock(shown: boolean)
	local video = M.player ~= nil and not M.player.audio
	local want = shown and video and M.data.tab == "listen"
	if not video then
		docked = nil
		return
	end
	if want ~= docked then
		docked = want
		dockNext = tern.now() + DOCK_REFRESH_MS
		dock(want)
	end
end

local function refreshGeometry()
	geometry(function(g)
		if g ~= lastGeometry then
			lastGeometry = g
			ipc({ { "set_property", "geometry", g } })
		end
	end)
end

-- ---- playback

function M.play(url: string, audio: boolean, label: string)
	M.loading, M.loadingAudio, M.reason, autoPaused = label, audio, nil, false
	M.render()
	local function begin(g)
		local cmds = { { "loadfile", url, "replace", -1, fileOpts(audio) }, { "set_property", "pause", false } }
		if not audio then table.insert(cmds, { "set_property", "geometry", g }) end
		ipc(cmds, function(r)
			if not r or (isNull(r[1]) and not M.player) then
				local args = {
					"--input-ipc-server=" .. q(SOCK), "--ontop", "--no-border", "--title=Break",
					"--auto-window-resize=no", "--keepaspect-window=yes", "--geometry=" .. g,
					"--force-window=immediate", "--keep-open=no", "--volume=60",
					"--ytdl-format=" .. q(if audio then FORMAT.audio else FORMAT.video),
				}
				if audio then
					table.insert(args, "--no-video")
					table.insert(args, "--force-window=no")
				end
				table.insert(args, q(url))
				local command = "rm -f " .. q(SOCK) .. "; " .. tool("mpv", table.concat(args, " "))
				proc.run("break mpv launch", { "python3", MPV_PY, "launch", LOG, command }, { timeout_ms = 5000 })
			end
			nextPoll = tern.now() + 1500
			M.render()
			timer.later("break loading", 25000, function()
				if M.loading == label then
					M.loading = nil
					M.render()
				end
			end)
		end)
	end
	if audio then begin("760x428-40-40") else geometry(begin) end
end

-- Video → audio keeps the stream (and its playlist) and drops the picture. Audio → video turns the
-- picture back on when the stream has one, else reloads the track with video at the same spot.
function M.switchMode()
	local p = M.player
	if not p then return end
	if not p.audio then
		docked = false
		dock(false)
		ipc({ { "set_property", "vid", "no" }, { "set_property", "force-window", "no" } }, function()
			nextPoll = 0
		end)
		return
	end
	ipc({ { "get_property", "track-list" } }, function(r)
		local tracks = if r and type(r[1]) == "table" then r[1] else {}
		local hasVideo = false
		for _, t in tracks do
			if t.type == "video" and not t.albumart then hasVideo = true end
		end
		geometry(function(g)
			if hasVideo then
				control({ { "set_property", "force-window", "immediate" }, { "set_property", "geometry", g }, { "set_property", "vid", "auto" } })
			else
				control({ { "loadfile", p.path, "replace", -1, fileOpts(false, if p.duration then p.pos else 0) }, { "set_property", "geometry", g } })
			end
		end)
	end)
end

function M.setPaused(v: boolean)
	ipc({ { "set_property", "pause", v } })
	if M.player then M.player.paused = v end
end

function M.togglePause()
	M.reason, autoPaused = nil, false
	control({ { "cycle", "pause" } })
end

function M.stop()
	control({ { "quit" } })
	M.player, M.reason, autoPaused = nil, nil, false
	publishState()
	M.render()
end

function M.setVolume(v: number)
	if M.player then M.player.volume = v end
	ipc({ { "set_property", "volume", v } })
end

function M.seek(v: number)
	control({ { "seek", v, "absolute" } })
end

function M.switchTab(k: string)
	if M.data.tab == k then return end
	M.data.tab = k
	save()
	M.syncDock(shownPane(facts.read()) ~= nil)
	if k == "listen" then liveNext = 0 end
	M.render()
end

function M.flip(key: string, on: boolean)
	M.data.auto[key] = on
	if key == "resume" and not on then autoPaused = false end
	save()
	M.render()
end

-- ---- links, channels, live checks

function M.addChannel()
	local f = M.fields.chan
	local name = string.lower(util.trim(f.text))
	name = string.gsub(name, "^https?://[w%.]*twitch%.tv/", "")
	name = string.gsub(name, "/.*$", "")
	if name == "" or table.find(M.data.favorites, name) then return end
	Field.set(f, "")
	table.insert(M.data.favorites, name)
	save()
	liveNext = 0
	M.render()
end

-- --no-playlist: a link from a YouTube mix (list=RD…) would otherwise list the whole mix and time out.
local function fetchMeta(item)
	item.failed = false
	local args = "--skip-download --no-warnings --no-playlist --playlist-items 1 --print '%(title)s|%(uploader)s|%(duration_string)s' "
		.. q(item.url)
	proc.sh("break meta", tool("yt-dlp", args), nil, { timeout_ms = 90000 }, function(r)
		local line = ""
		for _, l in util.lines(r.stdout) do
			if string.find(l, "|", 1, true) then
				line = l
				break
			end
		end
		local title, by, dur = string.match(line, "^([^|]*)|([^|]*)|(.*)$")
		local function some(v) return if v and v ~= "" and v ~= "NA" then v else nil end
		item.title, item.by, item.duration = some(title), some(by), some(dur)
		item.failed = item.title == nil
		save()
		M.render()
	end)
end

function M.addLink()
	local f = M.fields.link
	local url = util.trim(f.text)
	if not string.match(url, "^https?://") then
		M.toast("That is not a link")
		return
	end
	Field.set(f, "")
	local item = { url = url, id = string.format("%d-%d", os.time(), math.random(1, 1e6)), added = os.date("!%Y-%m-%dT%H:%M:%SZ") }
	table.insert(M.data.queue, item)
	save()
	M.render()
	fetchMeta(item)
end

function M.remove(list: string, i: number)
	table.remove(M.data[list], i)
	save()
	M.render()
end

function M.removeFavorite(name: string)
	local i = table.find(M.data.favorites, name)
	if i then table.remove(M.data.favorites, i) end
	save()
	M.render()
end

local function checkLive()
	for _, name in M.data.favorites do
		local args = "--skip-download --no-warnings --print '%(is_live)s|%(title)s' " .. q("https://www.twitch.tv/" .. name)
		proc.sh("break live", tool("yt-dlp", args), nil, { timeout_ms = 60000 }, function(r)
			local last = ""
			for _, l in util.lines(r.stdout) do last = l end
			local live, title = string.match(last, "^([^|]*)|?(.*)$")
			M.live[name] = if live == "True" then { on = true, title = clean(title or "") } else { on = false }
			M.render()
		end)
	end
end

-- ---- agents

local function who(a): string
	local base = util.basename(a.cwd)
	return if base ~= "" then base else "An agent"
end

-- Pauses when an agent needs you or finishes; resumes, if it paused itself, once an agent works again and none is waiting.
local function watchAgents(fx)
	local now, waiting, working = {}, false, 0
	for _, a in fx.agents or {} do
		if a.state == "waiting_input" then waiting = true end
		if a.state == "working" then working += 1 end
	end
	M.working = working
	for _, a in fx.agents or {} do
		now[a.pane] = a.state
		local before = if lastStatus then (lastStatus[a.pane] or "idle") else nil
		if not lastStatus or before == a.state then continue end
		local p, auto = M.player, M.data.auto
		local finished = a.state == "idle" and (before == "working" or before == "waiting_input")
		if auto.pause and (a.state == "waiting_input" or finished) and p and not p.paused then
			M.setPaused(true)
			autoPaused, autoAt = true, tern.now()
			M.reason = { pane = a.pane, text = who(a) .. (if a.state == "waiting_input" then " needs you" else " is done") }
			M.toast("Paused: " .. M.reason.text,
				if auto.resume then "It plays again when an agent gets back to work." else "Your music is waiting for you.")
			M.render()
		elseif a.state == "waiting_input" and autoPaused then
			M.reason = { pane = a.pane, text = who(a) .. " needs you" }
			M.render()
		elseif auto.resume and a.state == "working" and autoPaused and p and p.paused and not waiting then
			M.setPaused(false)
			autoPaused, M.reason = false, nil
			M.toast("Music back on", who(a) .. " is working again.")
			M.render()
		end
	end
	lastStatus = now
end

-- ---- clock

local function tick()
	local t = tern.now()
	local fx = facts.read()
	local shown = shownPane(fx) ~= nil
	local gaming = shown and M.data.tab == "play"
	watchAgents(fx)
	if game:tick(M.working, gaming) or gaming then M.render() end
	if shown and not wasShown then nextPoll, liveNext = 0, 0 end
	wasShown = shown
	M.syncDock(shown)
	if docked and t >= dockNext then
		dockNext = t + DOCK_REFRESH_MS
		refreshGeometry()
	end
	if t >= nextPoll and (shown or M.player) then
		nextPoll = t + (if shown then 1500 else 4000)
		poll()
	end
	if shown and M.data.tab == "listen" and t >= liveNext and #M.data.favorites > 0 then
		liveNext = t + 180000
		checkLive()
	end
end

function M.start()
	pcall(tern.fs.mkdir, DIR)
	load()
	game = Game.new({
		render = M.render,
		toast = M.toast,
		later = function(ms, fn) timer.later("break game", ms, fn) end,
	})
	M.game = game
	timer.every("break tick", 1000, tick)
	for _, it in M.data.queue do
		if not it.title or it.title == it.url then fetchMeta(it) end
	end
end

return M
