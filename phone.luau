-- Attention on the phone: the snapshot the Mac window publishes, its strict reader, the jump link, and the one
-- wording of ages and clock chips shared with the desktop rows. Pure data: this module never touches `tern`.
local phone = {}

phone.SCHEMA = 2
phone.FILE = "phone.json"
phone.MAX_ROWS = 60
phone.STALE_SECONDS = 120
phone.HEARTBEAT_SECONDS = 30
phone.PING = "attention://ping"

local JUMP_PREFIX = "attention://jump?"
local JUMP_LIMIT = 1500
local MAX_COUNT = 1000000
local MAX_INTEGER = 9007199254740991

local STATUSES = { ok = true, disabled = true, unavailable = true }
local SECTIONS = { attention = true, working = true }
local PLACEMENTS = { tiled = true, floating = true, parked = true, unattached = true }
local CLOCK_KINDS = { asked = true, replied = true, updated = true }
local JUMPABLE_PLACEMENTS = { tiled = true, floating = true }

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function integer(value, low, high)
	return finite(value) and value % 1 == 0 and value >= low and value <= high
end

-- Ages ------------------------------------------------------------------------------------------------

-- A duration in seconds as the shortest unit that fits: `<1m`, `12m`, `3h`, `3d`.
function phone.age(seconds)
	if not finite(seconds) or seconds < 60 then return "<1m" end
	if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
	if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
	return math.floor(seconds / 86400) .. "d"
end

-- How long ago `atUtc` was; an unusable time is said, never guessed.
function phone.relative(atUtc, nowUtc)
	if not finite(atUtc) or not finite(nowUtc) then return "time unknown" end
	local seconds = nowUtc - atUtc
	if seconds < 0 then return "clock uncertain" end
	return phone.age(seconds) .. " ago"
end

-- The same age as a sentence fragment for tooltips (`12 minutes ago`).
function phone.relativeLong(atUtc, nowUtc)
	if not finite(atUtc) or not finite(nowUtc) then return "at an unknown time" end
	local seconds = nowUtc - atUtc
	if seconds < 0 then return "at an uncertain time (clock mismatch)" end
	local function unit(count, name) return count .. " " .. name .. (if count == 1 then "" else "s") .. " ago" end
	if seconds < 60 then return "less than a minute ago" end
	if seconds < 3600 then return unit(math.floor(seconds / 60), "minute") end
	if seconds < 86400 then return unit(math.floor(seconds / 3600), "hour") end
	return unit(math.floor(seconds / 86400), "day")
end

local VERBS = { asked = "Asked", replied = "Replied", updated = "Updated" }

-- The chip (`Asked 12m ago`) and its tooltip for one clock. A clock is `{ kind, atUtc, recorded }`; the desktop adds
-- `offline` (the source's host is offline), `completed` (a reply with a completion time) and `notRecorded` (the
-- record has no time at all) so its tooltips keep their exact sentences. `recorded` marks a time taken from a
-- record rather than a readable source: the chip carries `≈ ` itself, never only the tooltip.
function phone.clockText(clock, nowUtc)
	if type(clock) ~= "table" then return nil end
	local verb = VERBS[clock.kind]
	if verb == nil then return nil end
	local short = phone.relative(clock.atUtc, nowUtc)
	local chip = if short == "time unknown" or short == "clock uncertain" then verb .. " · " .. short else verb .. " " .. short
	local sentence
	if clock.notRecorded == true then
		sentence = if clock.kind == "asked" then "When the agent asked is not recorded." else "No agent reply or update time is recorded."
	else
		local long = phone.relativeLong(clock.atUtc, nowUtc)
		if clock.kind == "asked" then sentence = "The agent last asked a question " .. long .. "."
		elseif clock.kind == "replied" then
			sentence = (if clock.completed == true then "The agent last replied " else "The agent's last reply was recorded ") .. long .. "."
		else sentence = "The agent last posted an update " .. long .. "." end
	end
	if clock.recorded == true then
		chip = "≈ " .. chip
		sentence ..= if clock.offline == true then " Offline: this is the last recorded time."
			else " The source cannot be read right now, so this is the last recorded time."
	end
	return chip, sentence
end

-- Text -------------------------------------------------------------------------------------------------

-- A display string of at most `limit` characters: control characters become spaces, an invalid string is empty,
-- and a longer one ends in `…`. Nil when nothing readable is left.
local function bounded(input, limit)
	if type(input) ~= "string" then return nil end
	local value = tostring(input)
	local cut = #value > limit * 4
	if cut then value = string.sub(value, 1, limit * 4) end
	local length, trimmed = utf8.len(value), 0
	-- A byte cut can split the last character; at most three bytes belong to it.
	while length == nil and cut and trimmed < 3 do
		value, trimmed = string.sub(value, 1, -2), trimmed + 1
		length = utf8.len(value)
	end
	if length == nil then return nil end
	value = string.gsub(value, "[%c]", " ")
	value = string.gsub(value, "\226\128\168", " ")
	value = string.gsub(value, "\226\128\169", " ")
	if not string.find(value, "%S") then return nil end
	if cut or length > limit then value = string.sub(value, 1, utf8.offset(value, limit) - 1) .. "…" end
	return value
end

-- Evidence the phone matches exactly: kept whole or dropped, never truncated.
local function exact(input, limit)
	if type(input) ~= "string" or input == "" or #input > limit * 8 then return nil end
	local value = tostring(input)
	local length = utf8.len(value)
	if length == nil or length > limit then return nil end
	return value
end

-- Jump links -------------------------------------------------------------------------------------------

local function within(value, limit)
	if #value > limit * 4 then return false end
	local length = utf8.len(value)
	return length ~= nil and length <= limit
end

local function encode(value)
	return (string.gsub(value, "[^%w%-%._~]", function(char) return string.format("%%%02X", string.byte(char)) end))
end

-- Nerd-Font icon glyphs live in the private-use planes; the phone may not see them, or see different ones.
local function privateUse(cp)
	return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0x10FFFF)
end

local function blank(cp)
	return cp <= 0x20 or (cp >= 0x7F and cp <= 0xA0) or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028
		or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000
end

-- A title as the phone compares it: private-use codepoints removed, whitespace runs collapsed to one space, ends
-- trimmed, everything else (case included) untouched. Empty for anything that is not valid text. The phone package
-- carries its own copy of this function; the two are tested against each other.
function phone.matchTitle(value)
	if type(value) ~= "string" then return "" end
	-- Plain printable ASCII with single inner spaces is already normal.
	if not string.find(value, "[^\32-\126]") and not string.find(value, "  ", 1, true)
			and string.sub(value, 1, 1) ~= " " and string.sub(value, -1) ~= " " then
		return value
	end
	if utf8.len(value) == nil then return "" end
	local chars, count, gap = {}, 0, false
	for _, cp in utf8.codes(value) do
		if blank(cp) then
			gap = count > 0
		elseif not privateUse(cp) then
			if gap then count += 1; chars[count] = " "; gap = false end
			count += 1
			chars[count] = utf8.char(cp)
		end
	end
	return table.concat(chars)
end

-- Optional evidence: nil and "" are absent, anything else must be text that fits.
local function optionalFits(value, limit)
	if value == nil or value == "" then return true, nil end
	if type(value) ~= "string" or not within(value, limit) then return false, nil end
	return true, value
end

-- `attention://jump?p=<pane>&h=<host>&t=<title>&c=<cwd>&g=<program>&s=<session>`, every value percent-encoded. The
-- pane's title is the one required piece of evidence (a conversation always has one); the working directory, the
-- program and the session name are added when the row has them and the link still fits in 1500 bytes. Nil when
-- the row is not jumpable, has no usable title, or the link could not carry its required parts.
function phone.jumpUrl(row)
	if type(row) ~= "table" or row.jumpable ~= true or not integer(row.pane, 0, MAX_INTEGER) then return nil end
	local host, title = row.host, row.paneTitle
	if type(host) ~= "string" or type(title) ~= "string" or phone.matchTitle(title) == "" then return nil end
	if not within(host, 64) or not within(title, 160) then return nil end
	local fitsCwd, cwd = optionalFits(row.cwd, 200)
	local fitsProgram, program = optionalFits(row.program, 64)
	if not fitsCwd or not fitsProgram then return nil end
	local url = JUMP_PREFIX .. "p=" .. string.format("%d", row.pane) .. "&h=" .. encode(host) .. "&t=" .. encode(title)
	if #url > JUMP_LIMIT then return nil end
	-- The session name is a display string that may be unusable; it is simply left out then.
	local _, session = optionalFits(row.session, 64)
	for _, part in ipairs({ { "c", cwd }, { "g", program }, { "s", session } }) do
		if part[2] ~= nil then
			local extended = url .. "&" .. part[1] .. "=" .. encode(part[2])
			if #extended <= JUMP_LIMIT then url = extended end
		end
	end
	return url
end

local function decode(value)
	if string.find(value, "%%", 1, false) == nil then return value end
	if string.find(value, "%%%x?$") or string.find(value, "%%%x?[^%x]") then return nil end
	local decoded = string.gsub(value, "%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	if utf8.len(decoded) == nil then return nil end
	return decoded
end

local JUMP_FIELDS = { p = "pane", h = "host", t = "title", c = "cwd", g = "program", s = "session" }
local JUMP_LIMITS = { host = 64, title = 160, cwd = 200, program = 64, session = 64 }

-- The pane evidence in a jump link, or nil and why. Strict: unknown, repeated or malformed parts reject the link;
-- a link without title, cwd, program or session (an older link) parses with those empty.
function phone.parseJump(url)
	if type(url) ~= "string" then return nil, "not a link" end
	if #url > JUMP_LIMIT then return nil, "link too long" end
	if string.sub(url, 1, #JUMP_PREFIX) ~= JUMP_PREFIX then return nil, "not an Attention jump link" end
	local query = string.sub(url, #JUMP_PREFIX + 1)
	if string.find(query, "[^%w%-%._~%%&=]") then return nil, "malformed link" end
	local result, seen = { title = "", cwd = "", program = "", session = "" }, {}
	for part in string.gmatch(query .. "&", "([^&]*)&") do
		local key, value = string.match(part, "^(%a)=(.*)$")
		local field = if key then JUMP_FIELDS[key] else nil
		if field == nil or seen[field] or string.find(value, "=", 1, true) then return nil, "malformed link" end
		seen[field] = true
		if field == "pane" then
			if not string.match(value, "^%d+$") or #value > 15 then return nil, "malformed pane" end
			result.pane = tonumber(value)
		else
			local text = decode(value)
			if text == nil then return nil, "malformed text" end
			if utf8.len(text) > JUMP_LIMITS[field] then return nil, field .. " too long" end
			result[field] = text
		end
	end
	if result.pane == nil or not seen.host then return nil, "incomplete link" end
	return result
end

-- Snapshot ---------------------------------------------------------------------------------------------

local function clockFor(view, row, nowUtc)
	local clock = view.clock(row, nowUtc)
	if type(clock) ~= "table" or CLOCK_KINDS[clock.kind] ~= true then return { recorded = false } end
	return { kind = clock.kind, atUtc = if finite(clock.atUtc) then clock.atUtc else nil, recorded = clock.recorded == true }
end

-- Tab nodes by host key and id, so a row finds the tab its pane lives in.
local function tabIndex(workspace)
	local tabs = {}
	for _, host in ipairs(if workspace then workspace.hosts else {}) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do tabs[host.hostKey .. "\n" .. tostring(tab.id)] = tab end
		end
	end
	return tabs
end

local function buildRow(row, section, workspace, tabs, options)
	local destination = if workspace and row.pane ~= nil and workspace.byPane then workspace.byPane[row.pane] else nil
	if destination ~= nil and destination.hostKey ~= row.hostKey then destination = nil end
	local tab = if destination and destination.tabId ~= nil then tabs[destination.hostKey .. "\n" .. tostring(destination.tabId)] else nil
	local result = {
		serial = row.serial, workId = bounded(tostring(row.workId), 128) or ("work:" .. tostring(row.serial)),
		section = section,
		session = bounded(row.sessionName, 64) or "Unknown session",
		tab = if tab then bounded(tab.name or tab.title, 64) else nil,
		title = bounded(row.title, 160) or "Untitled conversation",
		state = bounded((options.view.stateText(row)), 40),
		clock = clockFor(options.view, row, options.nowUtc),
		host = bounded(row.hostName, 64) or "Unknown host", localHost = row.localHost == true,
		jumpable = false,
	}
	if destination ~= nil then
		result.pane, result.placement = destination.pane, destination.placement
		local nativeTitle = if destination.titleSource == "native" then destination.title else nil
		result.paneTitle, result.cwd, result.program = exact(nativeTitle, 160), exact(destination.cwd, 200), exact(destination.program, 64)
		local openable = row.navigable == true or (row.retryableHeaderRoute == true and row.pane ~= nil)
		-- The phone finds a pane by its native title (cwd and program only narrow a tie), so a pane without one
		-- (or whose title was too long to carry whole) can never be found there.
		result.jumpable = openable and row.stale ~= true and JUMPABLE_PLACEMENTS[destination.placement] == true
			and phone.jumpUrl({ jumpable = true, pane = result.pane, host = result.host, paneTitle = result.paneTitle,
				cwd = result.cwd, program = result.program, session = result.session }) ~= nil
	end
	return result
end

-- The snapshot of one pass. `presentation` is the model's rows, `workspace` the navigation snapshot of the same
-- pass (tab, pane and placement facts), `options` = `{ nowUtc, hostName, revision, status?, reason?, view }` where
-- `view` supplies the desktop's own queue order (`queue`), clock (`clock`) and state words (`stateText`). A status
-- other than `ok` carries no rows.
function phone.snapshot(presentation, workspace, options)
	local status = options.status or "ok"
	assert(STATUSES[status], "Unknown phone snapshot status")
	local snapshot = {
		schema = phone.SCHEMA, revision = options.revision or 0, generatedUtc = math.floor(options.nowUtc), status = status,
		reason = if status == "ok" then nil else bounded(options.reason, 200),
		host = bounded(options.hostName, 64) or "Mac",
		counts = { attention = 0, working = 0 }, rows = {},
	}
	if status ~= "ok" then return snapshot end
	local tabs = tabIndex(workspace)
	for _, section in ipairs({ "attention", "working" }) do
		local listed = options.view.queue(presentation, section)
		snapshot.counts[section] = #listed
		for _, row in ipairs(listed) do
			if #snapshot.rows >= phone.MAX_ROWS then break end
			table.insert(snapshot.rows, buildRow(row, section, workspace, tabs, options))
		end
	end
	return snapshot
end

local function same(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for key, value in pairs(a) do if not same(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

-- Whether two snapshots say the same thing: the write counter and the write time are not content.
function phone.sameContent(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for _, key in ipairs({ "schema", "status", "reason", "host", "counts", "rows" }) do
		if not same(a[key], b[key]) then return false end
	end
	return true
end

-- Validation -------------------------------------------------------------------------------------------

local function text(input, limit)
	if type(input) ~= "string" or #input > limit * 8 then return nil end
	local value = tostring(input)
	local length = utf8.len(value)
	if length == nil or length > limit or string.find(value, "[%c]") or string.find(value, "\226\128[\168\169]") then return nil end
	return value
end

local function checkRow(raw)
	if type(raw) ~= "table" then return nil, "row is not a table" end
	if not integer(raw.serial, 0, MAX_INTEGER) then return nil, "row serial" end
	local workId, session, title, host = text(raw.workId, 128), text(raw.session, 64), text(raw.title, 160), text(raw.host, 64)
	if not workId or workId == "" or not session or not title or not host then return nil, "row text" end
	if not SECTIONS[raw.section] then return nil, "row section" end
	local tab, state = nil, nil
	if raw.tab ~= nil then tab = text(raw.tab, 64); if not tab then return nil, "row tab" end end
	if raw.state ~= nil then state = text(raw.state, 40); if not state then return nil, "row state" end end
	if type(raw.localHost) ~= "boolean" or type(raw.jumpable) ~= "boolean" then return nil, "row flags" end
	local clock = raw.clock
	if type(clock) ~= "table" or type(clock.recorded) ~= "boolean" then return nil, "row clock" end
	if clock.kind ~= nil and not CLOCK_KINDS[clock.kind] then return nil, "row clock kind" end
	if clock.atUtc ~= nil and not finite(clock.atUtc) then return nil, "row clock time" end
	local row = { serial = raw.serial, workId = workId, section = raw.section, session = session, tab = tab, title = title,
		state = state, clock = { kind = clock.kind, atUtc = clock.atUtc, recorded = clock.recorded },
		host = host, localHost = raw.localHost }
	if raw.pane ~= nil then
		if not integer(raw.pane, 0, MAX_INTEGER) then return nil, "row pane" end
		row.pane = raw.pane
	end
	if raw.paneTitle ~= nil then row.paneTitle = text(raw.paneTitle, 160); if not row.paneTitle then return nil, "row pane title" end end
	if raw.cwd ~= nil then row.cwd = text(raw.cwd, 200); if not row.cwd then return nil, "row cwd" end end
	if raw.program ~= nil then row.program = text(raw.program, 64); if not row.program then return nil, "row program" end end
	if raw.placement ~= nil then
		if not PLACEMENTS[raw.placement] then return nil, "row placement" end
		row.placement = raw.placement
	end
	-- A row can only be jumped to when it names an open pane the phone may focus and can find by its evidence.
	row.jumpable = raw.jumpable and JUMPABLE_PLACEMENTS[row.placement] == true
		and phone.jumpUrl({ jumpable = true, pane = row.pane, host = row.host, paneTitle = row.paneTitle, cwd = row.cwd,
			program = row.program, session = row.session }) ~= nil
	return row
end

local function check(raw)
	if type(raw) ~= "table" then return nil, "snapshot is not a table" end
	if raw.schema ~= phone.SCHEMA then return nil, "unsupported snapshot schema" end
	if not integer(raw.revision, 0, MAX_INTEGER) then return nil, "snapshot revision" end
	if not integer(raw.generatedUtc, 0, MAX_INTEGER) then return nil, "snapshot time" end
	if not STATUSES[raw.status] then return nil, "snapshot status" end
	local snapshot = { schema = phone.SCHEMA, revision = raw.revision, generatedUtc = raw.generatedUtc, status = raw.status }
	if raw.reason ~= nil then
		snapshot.reason = text(raw.reason, 200)
		if not snapshot.reason then return nil, "snapshot reason" end
	end
	snapshot.host = text(raw.host, 64)
	if not snapshot.host or snapshot.host == "" then return nil, "snapshot host" end
	local counts = raw.counts
	if type(counts) ~= "table" or not integer(counts.attention, 0, MAX_COUNT) or not integer(counts.working, 0, MAX_COUNT) then
		return nil, "snapshot counts"
	end
	snapshot.counts = { attention = counts.attention, working = counts.working }
	local rows = raw.rows
	if type(rows) ~= "table" then return nil, "snapshot rows" end
	if #rows > phone.MAX_ROWS then return nil, "too many rows" end
	snapshot.rows = {}
	for index = 1, #rows do
		local row, reason = checkRow(rows[index])
		if not row then return nil, "row " .. index .. ": " .. reason end
		snapshot.rows[index] = row
	end
	return snapshot
end

-- The snapshot a reader may trust, rebuilt from known fields only, or nil and why. Never throws.
function phone.validate(raw)
	local ok, snapshot, reason = pcall(check, raw)
	if not ok then return nil, "unreadable snapshot" end
	return snapshot, reason
end

return phone
