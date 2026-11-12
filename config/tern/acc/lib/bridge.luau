--!nonstrict
-- Window actions for both halves. Blocks run in the host half, which can't
-- open tabs, start agents or move panes. A block calls `bridge.send(cx, name,
-- args)`: that opens `acc://<name>?<base64url json>` through the window's
-- `tern.route.link`, where the handler registered with `bridge.on` runs with a
-- window cx. Window code calls `bridge.call(name, args, cx)` directly.
-- `bridge.request` also returns what the handler returned, through tern.kv.
local M = {}

local SCHEME = "acc://"
local handlers: { [string]: (any, any) -> any } = {}

function M.url(name: string, args: any?): string
	local payload = tern.base64.encode(tern.json.encode(args or {}), { url = true })
	return SCHEME .. name .. "?" .. payload
end

-- Host or window: asks the window to run action `name` with `args`.
function M.send(cx, name: string, args: any?)
	cx:open(M.url(name, args))
end

-- Host: like `send`, then cb(result) with what the handler returned (a pane id
-- for tab, split, agent and block), or cb(nil) after `timeout_ms` (default 10 s).
function M.request(cx, name: string, args: any?, cb: (any) -> (), timeout_ms: number?)
	local token = tostring(math.floor(tern.now())) .. "-" .. tostring(math.random(1, 1e9))
	local payload = if args then table.clone(args) else {}
	payload.reply = token
	M.send(cx, name, payload)
	local key = "reply:" .. token
	local deadline = tern.now() + (timeout_ms or 10000)
	local function poll()
		local value = tern.kv.get(key)
		if value ~= nil then
			tern.kv.set(key, nil)
			cb(if type(value) == "table" then value.value else nil)
		elseif tern.now() > deadline then
			cb(nil)
		else
			tern.timer(200, poll)
		end
	end
	tern.timer(100, poll)
end

-- Window: registers the handler of action `name`; what it returns answers a request.
function M.on(name: string, fn: (any, any) -> any)
	handlers[name] = fn
end

function M.call(name: string, args: any?, cx): any
	local fn = handlers[name]
	local result = nil
	if not fn then
		cx:toast("error", "acc: unknown action " .. name)
	else
		local ok, value = pcall(fn, args or {}, cx)
		if ok then
			result = value
		else
			tern.log.warn("acc: action " .. name .. " failed: " .. tostring(value))
			cx:toast("error", "acc: " .. name .. " failed", tostring(value))
		end
	end
	if args and type(args.reply) == "string" then
		tern.kv.set("reply:" .. args.reply, { value = result, at = os.time() })
	end
	return result
end

-- Window: claims acc:// links. Call once from window.luau.
function M.install()
	tern.route.link(function(link, cx)
		if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
			-- Web links clicked in our panels (md nodes route natively) go to the
			-- system browser, as herdr's `open` did.
			local info = link.pane and cx.session:pane(link.pane)
			if info and info.block and string.sub(info.block, 1, 4) == "acc." and string.match(link.url, "^https?://") then
				tern.process.run({ "/usr/bin/open", link.url }, { timeout_ms = 10000 }, function() end)
				return { handled = true }
			end
			return nil
		end
		local name, payload = string.match(link.url, "^acc://([%w%-_%.]+)%??(.*)$")
		if not name then return { handled = true } end
		local args = {}
		if payload and payload ~= "" then
			local ok, decoded = pcall(function()
				return tern.json.decode(tern.base64.decode(payload))
			end)
			if ok and type(decoded) == "table" then args = decoded end
		end
		args.from_pane = link.pane
		M.call(name, args, cx)
		return { handled = true }
	end)
end

return M
