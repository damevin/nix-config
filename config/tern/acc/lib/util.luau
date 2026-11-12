--!nonstrict
-- Small helpers shared by both halves and every mod.
local M = {}

M.HOME = tern.getenv("HOME") or ""
M.STATE = M.HOME .. "/.local/state"

function M.trim(s: string?): string
	return (string.gsub(s or "", "^%s+", ""):gsub("%s+$", ""))
end

function M.lines(s: string?): { string }
	local out = {}
	for line in string.gmatch((s or "") .. "\n", "([^\n]*)\n") do
		table.insert(out, (string.gsub(line, "\r$", "")))
	end
	if out[#out] == "" then table.remove(out) end
	return out
end

-- POSIX single-quote escaping for one shell word.
function M.shq(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- One shell command line from an argv.
function M.argvLine(argv: { string }): string
	local parts = {}
	for _, word in argv do table.insert(parts, M.shq(word)) end
	return table.concat(parts, " ")
end

function M.urlencode(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function M.decodeJson(text: string?): any
	if not text or text == "" then return nil end
	local ok, value = pcall(tern.json.decode, text)
	return if ok then value else nil
end

-- A small file's text, or nil when it is missing or unreadable.
function M.readFile(path: string, maxBytes: number?): string?
	local ok, text = pcall(tern.fs.read, path, maxBytes or 8 * 1024 * 1024)
	return if ok then text else nil
end

-- Writes through a temporary file and `mv`, so a reader never sees half a file.
-- `cb(ok, err)` is optional.
function M.writeAtomic(path: string, text: string, cb: ((boolean, string?) -> ())?)
	local tmp = path .. ".tmp-" .. tostring(math.floor(tern.now()))
	local ok, err = pcall(tern.fs.write, tmp, text)
	if not ok then
		if cb then cb(false, tostring(err)) end
		return
	end
	tern.process.run({ "/bin/mv", "-f", tmp, path }, { timeout_ms = 5000 }, function(r)
		if cb then cb(r.status == 0, if r.status == 0 then nil else r.stderr) end
	end)
end

function M.basename(path: string?): string
	return string.match(path or "", "([^/]+)/*$") or (path or "")
end

function M.dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

function M.shortenHome(path: string?): string
	if not path then return "" end
	if M.HOME ~= "" and string.sub(path, 1, #M.HOME) == M.HOME then
		return "~" .. string.sub(path, #M.HOME + 1)
	end
	return path
end

-- "3m", "2h", "5d" since `seconds` (unix time).
function M.ago(seconds: number?): string
	if not seconds then return "" end
	local d = os.time() - seconds
	if d < 60 then return "now" end
	if d < 3600 then return tostring(d // 60) .. "m" end
	if d < 86400 then return tostring(d // 3600) .. "h" end
	return tostring(d // 86400) .. "d"
end

-- Unix seconds from an ISO-8601 UTC timestamp ("2026-11-10T09:12:03Z").
function M.isoTime(iso: string?): number?
	if not iso then return nil end
	local y, mo, d, h, mi, s = string.match(iso, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	local t = os.time({
		year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
	})
	-- os.time reads the table as local time; correct by the UTC offset.
	local utc = os.date("!*t", t)
	local localT = os.date("*t", t)
	return t + (os.time(localT) - os.time(utc))
end

function M.plural(n: number, one: string, many: string?): string
	return tostring(n) .. " " .. (if n == 1 then one else (many or one .. "s"))
end

function M.truncate(s: string, max: number): string
	if utf8.len(s) and utf8.len(s) > max then
		return string.sub(s, 1, (utf8.offset(s, max) or (max + 1)) - 1) .. "…"
	end
	return s
end

function M.copy(t: { [any]: any }): { [any]: any }
	local out = {}
	for k, v in t do out[k] = v end
	return out
end

-- Number of UTF-16 code units in `s`.
function M.utf16len(s: string): number
	local n = 0
	for _, code in utf8.codes(s) do n += if code > 0xFFFF then 2 else 1 end
	return n
end

return M
