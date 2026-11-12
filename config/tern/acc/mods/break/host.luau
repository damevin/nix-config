--!nonstrict
-- Break: music and streams for the wait between agents, and an idle clicker.
-- The engine (player.luau) lives once per plugin load; this block draws it.
local Field = require("../../lib/field")
local bridge = require("../../lib/bridge")
local util = require("../../lib/util")
local Game = require("./game")
local Break = require("./player")

local ui = tern.ui
local div, section = Game.div, Game.section
local ICONS = { "token", "speaker", "muted" }

local SOURCES = {
	twitch = { name = "Twitch" },
	youtube = { name = "YouTube" },
	stream = { name = "Stream" },
}

local function source(url: string?): string
	if url and string.find(url, "twitch.tv", 1, true) then return "twitch" end
	if url and string.find(url, "youtu", 1, true) then return "youtube" end
	return "stream"
end

local function clock(s: number?): string
	s = math.max(0, math.floor(s or 0))
	local h, m, x = s // 3600, (s % 3600) // 60, string.format("%02d", s % 60)
	return if h > 0 then string.format("%d:%02d:%s", h, m, x) else string.format("%d:%s", m, x)
end

local function host(url: string): string
	local h = string.gsub(url, "^https?://[w%.]*", "")
	return (string.match(h, "^[^/?#]*") or h)
end

local function icon(name: string, role: string?)
	return ui.node("icon", { name = name, role = role })
end

-- A small round action inside a row.
local function act(key: string, action: string, content, props)
	local p = props or {}
	p.key, p.actions = key, { click = action }
	if type(content) == "string" then return div("acc.break.act", p, nil, content) end
	return div("acc.break.act", p, { content })
end

local function lead(text: string, tone: string?, round: boolean?)
	return div("acc.break.lead", { class = (if round then "round " else "") .. (tone or "") }, nil, text)
end

local function row(key: string, o)
	local children = {
		o.lead,
		div("acc.break.row-text", nil, {
			div("acc.break.row-title", { class = if o.dim then "dim" else "" }, nil, o.title),
			div("acc.break.row-sub", nil, nil, o.sub),
		}),
		div("acc.break.row-acts", nil, o.acts or {}),
	}
	return div("acc.break.row", {
		key = key, class = (if o.active then "active " else "") .. (if o.onRow then "act" else ""),
		actions = if o.onRow then { click = o.onRow } else nil,
	}, children)
end

local function segmented(data, playing: boolean)
	local items = {}
	for _, t in Break.TABS do
		local on = data.tab == t[1]
		table.insert(items, div("acc.break.seg-item", {
			key = t[1], class = if on then "on" else "", actions = { click = "tab=" .. t[1] },
		}, {
			if t[1] == "listen" and not on and playing then div("acc.break.seg-dot") else nil,
		}, t[2]))
	end
	return div("acc.break.seg", { class = if data.tab == "play" then "i1" else "i0" }, {
		div("acc.break.seg-ind"),
		items[1],
		items[2],
	})
end

local function playPause(key: string, paused: boolean, size: string)
	return div("acc.break.pp", { key = key, class = size .. (if paused then " paused" else ""), actions = { click = "pp" } }, {
		icon("play", "acc.break.pp-play"),
		icon("pause", "acc.break.pp-pause"),
	})
end

local function nowPlaying()
	local p, auto = Break.player, Break.data.auto
	if not p and not Break.loading then
		return div("acc.break.np", { key = "np", class = "empty" }, {
			div("acc.break.np-empty-t", nil, nil, "Nothing playing"),
			div("acc.break.np-empty-s", nil, nil,
				"Press ♪ on a link to just hear it, ▶ to watch. Music pauses when an agent needs you and comes back when they get to work."),
		})
	end
	local src = source(if p then p.path else nil)
	local live = p ~= nil and p.duration == nil
	local paused = p ~= nil and p.paused
	local metaParts = {}
	if p then
		table.insert(metaParts, SOURCES[src].name)
		table.insert(metaParts, if p.audio then "audio only" else "video")
		if live then table.insert(metaParts, "live") end
		if p.count > 1 then table.insert(metaParts, string.format("%d of %d", p.index + 1, p.count)) end
	else
		table.insert(metaParts, if Break.loadingAudio then "audio only" else "video")
	end

	local children = {
		div("acc.break.np-top", { key = "top" }, {
			div("acc.break.np-dot", { class = "src-" .. src .. (if live then " live" else "") .. (if live and not paused then " pulse" else "") }),
			div("acc.break.np-text", nil, {
				div("acc.break.np-title", { class = if p and not paused then "" else "dim" }, nil,
					if p then p.title else "Opening " .. (Break.loading or "") .. "…"),
				div("acc.break.np-meta", nil, nil, table.concat(metaParts, " · ")),
			}),
			if p then act("stop", "stop", icon("stop")) else nil,
		}),
	}
	if p and p.duration then
		table.insert(children, div("acc.break.np-seek", { key = "seek-row" }, {
			div("acc.break.time", nil, nil, clock(p.pos)),
			ui.node("slider", {
				key = "seek", role = "acc.break.seek", min = 0, max = math.max(1, math.floor(p.duration + 0.5)), step = 1,
				value = math.min(math.floor(p.duration + 0.5), math.floor(p.pos + 0.5)), grow = 1,
			}),
			div("acc.break.time end", nil, nil, clock(p.duration)),
		}))
	end
	if p then
		local controls = {}
		if p.count > 1 then table.insert(controls, act("prev", "prev", icon("rewind"))) end
		table.insert(controls, playPause("pp", paused, "lg"))
		if p.count > 1 then table.insert(controls, act("next", "next", icon("fast-forward"))) end
		table.insert(controls, div("acc.break.mode", { key = "mode", actions = { click = "mode" } }, nil,
			if p.audio then "▶ Show video" else "♪ Audio only"))
		table.insert(controls, div("acc.break.grow"))
		table.insert(controls, act("mute", "mute", ui.node("image", {
			blob = if p.mute then Game.blobs.muted else Game.blobs.speaker,
			role = "acc.break.vol-ic", w = 13, h = 13, alt = "",
		})))
		table.insert(controls, div("acc.break.vol", { class = if p.mute then "muted" else "" }, {
			ui.node("slider", { key = "vol", role = "acc.break.volume", min = 0, max = 100, step = 1, value = p.volume }),
		}))
		table.insert(children, div("acc.break.np-controls", { key = "controls" }, controls))
	end
	if Break.reason then
		local sub = if auto.resume and p and p.paused then "Plays again when an agent gets back to work" else nil
		table.insert(children, div("acc.break.reason", { key = "reason" }, {
			div("acc.break.reason-dot"),
			div("acc.break.reason-text", nil, {
				div("acc.break.reason-t", nil, nil, "Paused: " .. Break.reason.text),
				if sub then div("acc.break.reason-s", nil, nil, sub) else nil,
			}),
			div("acc.break.ghost", { key = "go-agent", actions = { click = "agent" } }, nil, "Go to agent"),
		}))
	end
	return div("acc.break.np", { key = "np", class = if Break.reason then "reason" else "" }, children)
end

local function miniPlayer()
	local p = Break.player
	local children = {
		div("acc.break.mini-note", { class = if p.paused then "paused" else "" }, nil, "♪"),
		div("acc.break.mini-title", { class = if p.paused then "dim" else "" }, nil,
			if Break.reason then "Paused: " .. Break.reason.text else p.title),
	}
	if p.count > 1 then table.insert(children, act("mini-next", "next", icon("fast-forward"))) end
	table.insert(children, playPause("mini-pp", p.paused, "sm"))
	return div("acc.break.mini", { key = "mini", class = if Break.reason then "reason" else "" }, children)
end

local function field(name: string, id: string, placeholder: string, action: string)
	local f = Break.fields[name]
	local p = Field.props(f, {
		key = name, role = "acc.break.input", placeholder = placeholder,
		buttons = { { act = action, text = "Add" } },
	})
	return ui.node("input", p)
end

local function listenView(): { any }
	local data, player = Break.data, Break.player
	local path = if player then player.path else nil
	local out = {}
	table.insert(out, nowPlaying())

	table.insert(out, section("Links", if #data.queue > 0 then tostring(#data.queue) else nil))
	for i, it in data.queue do
		local src = source(it.url)
		table.insert(out, row("q-" .. it.id, {
			lead = lead(if src == "youtube" then "▶" elseif src == "twitch" then "T" else "•", src),
			title = it.title or (if it.failed then host(it.url) else "Fetching title…"),
			sub = (function()
				local parts = {}
				for _, v in { it.by, it.duration, if it.failed then "title not found" else nil } do
					if v then table.insert(parts, v) end
				end
				return if #parts > 0 then table.concat(parts, " · ") else SOURCES[src].name
			end)(),
			active = path == it.url,
			onRow = "q-listen=" .. i,
			acts = {
				act("listen", "q-listen=" .. i, "♪"),
				act("watch", "q-watch=" .. i, icon("play")),
				act("rm", "q-rm=" .. i, "×"),
			},
		}))
	end
	table.insert(out, field("link", "link", "Paste a YouTube or Twitch link", "add-link"))

	local live = {}
	for _, name in data.favorites do
		if Break.live[name] and Break.live[name].on then table.insert(live, name) end
	end
	table.insert(out, section("Twitch", if #live > 0 then #live .. " live" else nil))
	local ordered = {}
	for _, name in live do table.insert(ordered, name) end
	for _, name in data.favorites do
		if not (Break.live[name] and Break.live[name].on) then table.insert(ordered, name) end
	end
	for _, name in ordered do
		local l = Break.live[name]
		local on = l ~= nil and l.on
		local url = "https://www.twitch.tv/" .. name
		local acts = {}
		if on then
			table.insert(acts, act("listen", "f-listen=" .. name, "♪"))
			table.insert(acts, act("watch", "f-watch=" .. name, icon("play")))
		end
		table.insert(acts, act("rm", "f-rm=" .. name, "×"))
		table.insert(out, row("fav-" .. name, {
			lead = lead(string.upper(string.sub(name, 1, 1)), if on then "live" else nil, true),
			title = if on then name .. " · live" else name,
			sub = if on then l.title elseif l then "offline" else "checking…",
			dim = not on, active = path == url,
			onRow = if on then "f-watch=" .. name else nil,
			acts = acts,
		}))
	end
	table.insert(out, field("chan", "chan", "Add a Twitch channel", "add-chan"))

	table.insert(out, section("Radio"))
	for i, r in Break.RADIO do
		table.insert(out, row("radio-" .. i, {
			lead = lead("♪", nil, true), title = r.name, sub = r.sub, active = path == r.url,
			onRow = "r-listen=" .. i,
			acts = { act("listen", "r-listen=" .. i, "♪"), act("watch", "r-watch=" .. i, icon("play")) },
		}))
	end

	table.insert(out, section("Agents"))
	table.insert(out, ui.node("switch", {
		key = "auto-pause", role = "acc.break.switch", label = "Pause when an agent needs you",
		hint = "Also when one finishes while you listen.", on = data.auto.pause,
	}))
	table.insert(out, ui.node("switch", {
		key = "auto-resume", role = "acc.break.switch", label = "Play again when agents get to work",
		hint = "Only after a pause it made itself, and while no agent is waiting on you.", on = data.auto.resume,
	}))
	return out
end

local function view(_state, _cx)
	local data, player = Break.data, Break.player
	local tab = data.tab
	local video = (player ~= nil and not player.audio) or (Break.loading ~= nil and not Break.loadingAudio)
	local playing = player ~= nil and not player.paused

	local body
	if tab == "listen" then
		body = listenView()
	else
		body = {}
		if player then table.insert(body, miniPlayer()) end
		table.insert(body, Break.game:view(Break.working))
	end

	local top = {
		div("acc.break.head", { key = "head" }, {
			div("acc.break.title", nil, nil, "Break"),
			div("acc.break.grow"),
			segmented(data, playing),
		}),
	}
	if tab == "listen" and video then
		table.insert(top, div("acc.break.video", { key = "video" }, {
			div("acc.break.video-box", nil, {
				div("acc.break.video-t", nil, nil, if player then "" else "Opening the stream…"),
			}),
		}))
	end
	-- `main` scrolls as a whole: the head and the video slot stay put (the mpv window sits over the slot).
	return {
		main = ui.node("col", { role = "acc.break.root" }, {
			div("acc.break.top", { key = "top" }, top),
			ui.node("col", { key = "body-" .. tab, role = "acc.break.body" }, body),
		}),
	}
end

local function submit(name: string)
	if name == "link" then Break.addLink() else Break.addChannel() end
end

local function bodyId(name: string): string
	return "main.body-listen." .. name
end

local function actionEvent(ev, cx)
	local a, v = ev.act, ev.value
	local i = tonumber(v)
	local data = Break.data
	if a == "tab" then Break.switchTab(v)
	elseif a == "pp" then Break.togglePause()
	elseif a == "stop" then Break.stop()
	elseif a == "prev" then Break.control({ { "playlist-prev" } })
	elseif a == "next" then Break.control({ { "playlist-next" } })
	elseif a == "mute" then Break.control({ { "cycle", "mute" } })
	elseif a == "mode" then Break.switchMode()
	elseif (a == "q-listen" or a == "q-watch") and i and data.queue[i] then
		local item = data.queue[i]
		Break.play(item.url, a == "q-listen", item.title or host(item.url))
	elseif a == "q-rm" and i then Break.remove("queue", i)
	elseif a == "f-listen" then Break.play("https://www.twitch.tv/" .. v, true, v)
	elseif a == "f-watch" then Break.play("https://www.twitch.tv/" .. v, false, v)
	elseif a == "f-rm" then Break.removeFavorite(v)
	elseif a == "r-listen" and i and Break.RADIO[i] then Break.play(Break.RADIO[i].url, true, Break.RADIO[i].name)
	elseif a == "r-watch" and i and Break.RADIO[i] then Break.play(Break.RADIO[i].url, false, Break.RADIO[i].name)
	elseif a == "add-link" then
		Break.focused = "link"
		submit("link")
	elseif a == "add-chan" then
		Break.focused = "chan"
		submit("chan")
	elseif a == "agent" then
		if Break.reason then bridge.send(cx, "focus", { pane = Break.reason.pane }) end
	else
		Break.game:event(a, v, ev.mods)
	end
end

local def = {
	font = "sans",
	init = function(cx, _args, _saved)
		for _, name in ICONS do
			local svg = tern.fs.read(tern.plugin.dir .. "/mods/break/icons/" .. name .. ".svg")
			Game.blobs[name] = cx:blob(svg, "image/svg+xml")
		end
		Break.attach(cx)
		return {}
	end,
	view = view,
	title = function()
		return "Break"
	end,
	key = function(_state, key, cx)
		local name = Break.focused
		if Break.data.tab ~= "listen" or not name then return false end
		local f = Break.fields[name]
		if key.name == "enter" then
			submit(name)
		elseif key.name == "tab" then
			Break.focused = if name == "link" then "chan" else "link"
			Field.focus(cx, bodyId(Break.focused))
		elseif key.meta and string.lower(key.name) == "c" then
			local selection = Field.selection(f)
			if selection == "" then return false end
			cx:copy(selection)
		elseif not Field.key(f, key) then
			return false
		end
		Break.render()
		return true
	end,
	event = function(_state, ev, cx)
		if ev.ev == "focus" then
			local name = string.match(ev.id, "%.(%a+)$")
			if Break.fields[name] then
				Break.focused = name
				Field.focus(cx, ev.id)
			end
		elseif ev.ev == "action" then
			actionEvent(ev, cx)
		elseif ev.ev == "change" then
			local key = string.match(ev.id, "%.([%w%-]+)$")
			if key == "vol" then Break.setVolume(ev.value)
			elseif key == "seek" then Break.seek(ev.value)
			elseif key == "auto-pause" then Break.flip("pause", ev.value == true)
			elseif key == "auto-resume" then Break.flip("resume", ev.value == true) end
		end
	end,
}

Break.start()

return { ["break"] = def }
