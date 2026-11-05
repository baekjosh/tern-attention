--!nonstrict
-- Attention phone: the window half that turns a tapped `attention://jump?...` link into a focused pane.
-- Self-contained on purpose: iOS loads this folder alone, so nothing here may require another file.
-- It never calls tern.process (raises on iOS) or anything desktop-only.

local SCHEME = "attention://"
local JUMP = "attention://jump?"
local PING = "attention://ping"
local VERSION = "0.3.0" -- keep equal to plugin.toml
local MAX_URL = 1500
local MAX_PANE_DIGITS = 15
local LIMITS = { h = 64, t = 160, c = 200, g = 64, s = 64 } -- characters, not bytes
local NAMES = { p = "pane", h = "host", t = "title", c = "cwd", g = "program", s = "session" }
-- A pane on a remote host is packed as `slot << 44 | daemonId`; the low 44 bits are the Mac's own id.
local HOST_TAG_MODULUS = 17592186044416 -- 2^44
local QUEUE_KIND = "attention.queue"
local OWNER = "attention" -- this package's plugin id, and the id of the Mac plugin whose canvas the phone mirrors
local RETRY_MS = 300 -- between the matching passes that follow a session switch
local RETRIES = 3 -- passes after the switch before the conversation is called not found
local REPORT_LIMIT = 8192 -- bytes of the diagnostics report
local REPORT_PANES = 60
local FIELD_LIMIT = 120 -- characters of any one string in the report

local function decode(text)
	local rest = string.gsub(text, "%%%x%x", "")
	if string.find(rest, "%", 1, true) then return nil end
	local value = string.gsub(text, "%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
	if utf8.len(value) == nil then return nil end
	return value
end

-- Parses `attention://jump?p=<pane>&h=<host>&t=<title>&c=<cwd>&g=<program>&s=<session>`: every value
-- percent-encoded, no other characters, no repeated or unknown fields; values are valid UTF-8 within their limits.
-- Title, cwd, program and session are optional (an older link lacks some). Returns nil and a reason for anything
-- else. Never throws, whatever the input is.
local function parseJump(url)
	if type(url) ~= "string" then return nil, "not text" end
	if #url > MAX_URL then return nil, "link too long" end
	if string.sub(url, 1, #JUMP) ~= JUMP then return nil, "not a jump link" end
	local query = string.sub(url, #JUMP + 1)
	if string.find(query, "[^%w%-%._~%%&=]") then return nil, "malformed link" end
	local fields = {}
	for part in string.gmatch(query .. "&", "([^&]*)&") do
		local key, raw = string.match(part, "^(%a)=(.*)$")
		local name = if key then NAMES[key] else nil
		if name == nil or fields[key] ~= nil or string.find(raw, "=", 1, true) then return nil, "malformed link" end
		if key == "p" then
			if #raw > MAX_PANE_DIGITS or string.find(raw, "^%d+$") == nil then return nil, "malformed pane" end
			fields.p = tonumber(raw)
		else
			local value = decode(raw)
			if value == nil then return nil, "malformed " .. name end
			if utf8.len(value) > LIMITS[key] then return nil, name .. " too long" end
			fields[key] = value
		end
	end
	if fields.p == nil or fields.h == nil then return nil, "incomplete link" end
	return { pane = fields.p, host = fields.h, title = fields.t or "", cwd = fields.c or "", program = fields.g or "",
		session = fields.s or "" }
end

local function isPrivateUse(cp)
	return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0x10FFFF)
end

local function isBlank(cp)
	return cp <= 0x20 or (cp >= 0x7F and cp <= 0xA0) or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028
		or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000
end

-- A title or name as it is compared: private-use codepoints (Nerd-Font icon glyphs, which the Mac's titles carry
-- and this phone may not) removed, whitespace runs collapsed to one space, ends trimmed, case kept. Empty for
-- anything that is not valid text. phone.luau on the Mac has the same function (`phone.matchTitle`); a test
-- holds the two together.
local function normalize(value)
	if type(value) ~= "string" then return "" end
	-- Plain printable ASCII with single inner spaces is already normal.
	if not string.find(value, "[^\32-\126]") and not string.find(value, "  ", 1, true)
			and string.sub(value, 1, 1) ~= " " and string.sub(value, -1) ~= " " then
		return value
	end
	if utf8.len(value) == nil then return "" end
	local chars, count, gap = {}, 0, false
	for _, cp in utf8.codes(value) do
		if isBlank(cp) then
			gap = count > 0
		elseif not isPrivateUse(cp) then
			if gap then count += 1; chars[count] = " "; gap = false end
			count += 1
			chars[count] = utf8.char(cp)
		end
	end
	return table.concat(chars)
end

-- Chooses the pane this phone should focus. The conversation's title is the evidence: candidates are the panes
-- whose normalized title equals the wanted one (never the queue block itself, never a pane without a title).
-- Several candidates are narrowed, in order, to those whose pane id modulo 2^44 is the wanted id (Tern packs a
-- remote pane id as `slot << 44 | daemonId`), then to those with the same cwd, then the same program, each time
-- only when both sides know the value and at least one candidate agrees; a stage nobody passes changes nothing.
-- The id, cwd and program never select a pane on their own.
-- Returns pane | nil, nil | "none" | "several", and the candidate count after each stage (for the diagnostics).
local function match(panes, wanted)
	local stages = { titles = 0, id = 0, cwd = 0, program = 0 }
	local wantedTitle = normalize(wanted.title)
	if wantedTitle == "" then return nil, "none", stages end
	local found = {}
	for _, candidate in ipairs(panes) do
		if type(candidate) == "table" and type(candidate.pane) == "number" and candidate.block ~= QUEUE_KIND
				and normalize(candidate.title) == wantedTitle then
			table.insert(found, candidate)
		end
	end
	stages.titles = #found
	if #found == 0 then return nil, "none", stages end
	local function narrow(agrees)
		if #found <= 1 then return end
		local kept = {}
		for _, candidate in ipairs(found) do
			if agrees(candidate) then table.insert(kept, candidate) end
		end
		if #kept >= 1 then found = kept end
	end
	narrow(function(candidate) return candidate.pane % HOST_TAG_MODULUS == wanted.pane % HOST_TAG_MODULUS end)
	stages.id = #found
	narrow(function(candidate)
		return wanted.cwd ~= "" and type(candidate.cwd) == "string" and candidate.cwd ~= "" and candidate.cwd == wanted.cwd
	end)
	stages.cwd = #found
	narrow(function(candidate)
		return wanted.program ~= "" and type(candidate.program) == "string" and candidate.program ~= ""
			and candidate.program == wanted.program
	end)
	stages.program = #found
	if #found == 1 then return found[1], nil, stages end
	return nil, "several", stages
end

-- The other session of this window the link's session name points at, or nil: sessions are only ever switched to
-- when exactly one remains. Of the sessions with that name (the current one is where we already looked), those
-- on the link's host (matched by name) are preferred, then those on the host the queue block lives on.
local function pickSession(cx, wanted)
	local name = normalize(wanted.session)
	if name == "" then return nil end
	local found = {}
	for _, session in ipairs(cx.sessions:list()) do
		if type(session) == "table" and session.current ~= true and normalize(session.name) == name then
			table.insert(found, session)
		end
	end
	local function prefer(agrees)
		if #found <= 1 then return end
		local kept = {}
		for _, session in ipairs(found) do
			if agrees(session) then table.insert(kept, session) end
		end
		if #kept >= 1 then found = kept end
	end
	local hostNames = {}
	-- The host preferences are a refinement: a host listing that fails only leaves them out.
	local listed, hosts = pcall(function() return cx.hosts:list() end)
	if listed and type(hosts) == "table" then
		for _, host in ipairs(hosts) do
			if type(host) == "table" then hostNames[host.id] = string.lower(normalize(host.name)) end
		end
	end
	local wantedHost = string.lower(normalize(wanted.host))
	prefer(function(session) return wantedHost ~= "" and hostNames[session.host] == wantedHost end)
	local queueSlots = {}
	for _, candidate in ipairs(cx.session:panes()) do
		if type(candidate) == "table" and candidate.block == QUEUE_KIND and type(candidate.pane) == "number" then
			queueSlots[math.floor(candidate.pane / HOST_TAG_MODULUS)] = true
		end
	end
	prefer(function(session) return queueSlots[session.host] == true end)
	if #found == 1 then return found[1] end
	return nil
end

-- The queue block already open in this window, if any: `{ pane = id, parked = bool }`. A pane on the host the
-- user is looking at (same host slot as the focused pane) wins over one on another host, and a visible pane
-- wins over a parked one, so a parked queue is only reported when nothing visible exists. The host slot is a
-- preference only: any open queue block is reused rather than creating a second one.
local function findQueue(session)
	local focused = session:focused()
	local hostSlot = if type(focused) == "number" then math.floor(focused / HOST_TAG_MODULUS) else nil
	local best, bestRank = nil, nil
	for _, candidate in ipairs(session:panes()) do
		if candidate.block == QUEUE_KIND and type(candidate.pane) == "number" then
			local rank
			if candidate.parked then
				rank = 3
			elseif hostSlot ~= nil and math.floor(candidate.pane / HOST_TAG_MODULUS) == hostSlot then
				rank = 1
			else
				rank = 2
			end
			if bestRank == nil or rank < bestRank then
				best, bestRank = candidate, rank
			end
		end
	end
	if best == nil then return nil end
	return { pane = best.pane, parked = best.parked == true }
end

-- Takes the user to the working queue block: reuses an open one, never creates a second, never unparks.
-- `redirected` is true when a tap on the mirrored desktop rail brought the user here.
local function openQueue(cx, redirected)
	local existing = findQueue(cx.session)
	if existing ~= nil then
		if existing.parked then
			cx:toast("info", "The Attention queue is parked on your Mac. Restore it from Parked panes.")
			return
		end
		cx.layout:focus(existing.pane)
		if cx.session:focused() ~= existing.pane then
			cx:toast("error", "Couldn't open the Attention queue")
			return
		end
	else
		local present = false
		for _, blockType in ipairs(cx.session:block_types()) do
			if blockType.kind == QUEUE_KIND then present = true; break end
		end
		if not present then
			cx:toast("info", "This host has no Attention queue block")
			return
		end
		if cx:new_block(QUEUE_KIND, {}, "tab") == nil then
			cx:toast("error", "Couldn't open the Attention queue")
			return
		end
	end
	if redirected then cx:toast("info", "Attention queue") end
end

local function openQueueSafely(cx, redirected)
	local ok, failure = pcall(openQueue, cx, redirected)
	if not ok then pcall(function() cx:toast("error", "Couldn't open the Attention queue", tostring(failure)) end) end
end

-- The phone mirrors the Mac's desktop rail, a canvas owned by the plugin `attention`; no plugin with that id
-- runs on the phone for it, so a tap would end in "Nothing handles ...". This package carries the id, takes the
-- tap and shows the working queue instead. The mirrored action itself is never forwarded or run.
local function canvasAction(ev, cx)
	if type(ev) ~= "table" or ev.owner ~= OWNER then return false end
	openQueueSafely(cx, true)
	return true
end

local function fmt(number)
	if type(number) ~= "number" or number ~= number or math.abs(number) == math.huge then return tostring(number) end
	return string.format("%.0f", number)
end

-- Any value as one quoted, escaped, bounded token of the report. Private-use codepoints (the icon glyphs the Mac's
-- titles carry) show as \uXXXX so the report says exactly which ones the phone sees; control characters and bytes
-- that are not text show as \xNN. At most FIELD_LIMIT characters survive.
local function show(value)
	if value == nil then return "nil" end
	if type(value) ~= "string" then return tostring(value) end
	local text, cut = value, #value > FIELD_LIMIT * 4
	if cut then
		text = string.sub(value, 1, FIELD_LIMIT * 4)
		local trimmed = 0
		while utf8.len(text) == nil and trimmed < 3 do text, trimmed = string.sub(text, 1, -2), trimmed + 1 end
	end
	local out, count = {}, 0
	if utf8.len(text) == nil then
		for index = 1, #text do
			if count >= FIELD_LIMIT then cut = true; break end
			local byte = string.byte(text, index)
			out[#out + 1] = if byte >= 0x20 and byte < 0x7F then string.char(byte) else string.format("\\x%02X", byte)
			count += 1
		end
	else
		for _, cp in utf8.codes(text) do
			if count >= FIELD_LIMIT then cut = true; break end
			if isPrivateUse(cp) then
				out[#out + 1] = string.format("\\u%04X", cp)
			elseif cp < 0x20 or cp == 0x7F then
				out[#out + 1] = string.format("\\x%02X", cp)
			else
				out[#out + 1] = utf8.char(cp)
			end
			count += 1
		end
	end
	return '"' .. table.concat(out) .. (if cut then "…" else "") .. '"'
end

local function safe(fn)
	local ok, value = pcall(fn)
	if ok then return value, nil end
	return nil, tostring(value)
end

-- The panes worth listing first: those whose title is, or contains, the wanted one.
local function relevance(entry, wantedTitle)
	if wantedTitle == "" then return 3 end
	local title = normalize(entry.title)
	if title == "" then return 3 end
	if title == wantedTitle then return 1 end
	if string.find(title, wantedTitle, 1, true) or string.find(wantedTitle, title, 1, true) then return 2 end
	return 3
end

-- Plain text report of what this phone sees and what the last jump tried; never more than REPORT_LIMIT bytes.
-- `last` is the record the jump keeps (nil before any jump).
local function buildReport(cx, tern, last)
	local lines, size, full = {}, 0, false
	local function add(line)
		if full then return end
		if size + #line + 1 > REPORT_LIMIT - 48 then
			full = true
			return
		end
		lines[#lines + 1] = line
		size += #line + 1
	end
	add("Attention phone diagnostics")
	add("package " .. VERSION .. ", os " .. show(if type(tern.runtime) == "table" then tern.runtime.os else nil))

	local hosts, hostFailure = safe(function() return cx.hosts:list() end)
	if hosts == nil then
		add("hosts: unavailable " .. show(hostFailure))
	else
		add("hosts: " .. #hosts)
		for _, host in ipairs(hosts) do
			if type(host) == "table" then
				add("  host id=" .. fmt(host.id) .. " name=" .. show(host.name) .. " kind=" .. show(host.kind)
					.. " state=" .. show(host.state) .. (if host.current == true then " current" else ""))
			end
		end
	end
	local sessions, sessionFailure = safe(function() return cx.sessions:list() end)
	if sessions == nil then
		add("sessions: unavailable " .. show(sessionFailure))
	else
		add("sessions: " .. #sessions)
		for _, session in ipairs(sessions) do
			if type(session) == "table" then
				add("  session id=" .. fmt(session.id) .. " name=" .. show(session.name) .. " host=" .. fmt(session.host)
					.. " tabs=" .. fmt(session.tabs) .. (if session.current == true then " current" else ""))
			end
		end
	end
	local current = safe(function() return cx.sessions:current() end)
	if type(current) == "table" then
		add("current session id=" .. fmt(current.id) .. " name=" .. show(current.name) .. " host=" .. fmt(current.host))
	end

	if last == nil then
		add("last jump: none since this plugin loaded")
	else
		local wanted = last.wanted
		add("last jump: wanted pane=" .. fmt(wanted.pane) .. " (id " .. fmt(wanted.pane % HOST_TAG_MODULUS) .. ", slot "
			.. fmt(math.floor(wanted.pane / HOST_TAG_MODULUS)) .. ") host=" .. show(wanted.host) .. " session=" .. show(wanted.session))
		add("  title=" .. show(wanted.title) .. " normalized=" .. show(normalize(wanted.title)))
		add("  cwd=" .. show(wanted.cwd) .. " program=" .. show(wanted.program))
		for index, attempt in ipairs(last.attempts) do
			add("  attempt " .. index .. ": session=" .. show(attempt.session) .. " panes=" .. fmt(attempt.panes)
				.. " title-matches=" .. attempt.stages.titles .. " after-id=" .. attempt.stages.id
				.. " after-cwd=" .. attempt.stages.cwd .. " after-program=" .. attempt.stages.program .. " -> " .. attempt.result)
		end
		add("  session switch: " .. last.switch)
		add("  result: " .. last.result)
	end

	local panes, paneFailure = safe(function() return cx.session:panes() end)
	if panes == nil then
		add("panes: unavailable " .. show(paneFailure))
	else
		local slots, order, listed = {}, {}, {}
		for _, entry in ipairs(panes) do
			if type(entry) == "table" and type(entry.pane) == "number" then
				local slot = math.floor(entry.pane / HOST_TAG_MODULUS)
				if slots[slot] == nil then slots[slot] = 0; order[#order + 1] = slot end
				slots[slot] += 1
				listed[#listed + 1] = entry
			end
		end
		table.sort(order)
		local counts = {}
		for _, slot in ipairs(order) do counts[#counts + 1] = fmt(slot) .. "=" .. slots[slot] end
		add("panes: " .. #panes .. " total; per host slot (pane // 2^44): " .. (if #counts > 0 then table.concat(counts, " ") else "none"))
		local wantedTitle = if last ~= nil then normalize(last.wanted.title) else ""
		local ranked = {}
		for index, entry in ipairs(listed) do ranked[index] = { entry = entry, rank = relevance(entry, wantedTitle), index = index } end
		table.sort(ranked, function(a, b)
			if a.rank ~= b.rank then return a.rank < b.rank end
			return a.index < b.index
		end)
		local shown = math.min(#ranked, REPORT_PANES)
		add("pane list (" .. shown .. " of " .. #ranked .. ", closest titles first): slot id kind block title cwd program tab flags")
		for index = 1, shown do
			local entry = ranked[index].entry
			add("  " .. fmt(math.floor(entry.pane / HOST_TAG_MODULUS)) .. " " .. fmt(entry.pane % HOST_TAG_MODULUS)
				.. " " .. show(entry.kind) .. " " .. show(entry.block) .. " " .. show(entry.title) .. " " .. show(entry.cwd)
				.. " " .. show(entry.program) .. " tab=" .. fmt(entry.tab)
				.. (if entry.parked == true then " parked" else "") .. (if entry.floating == true then " floating" else ""))
		end
	end
	if full then lines[#lines + 1] = "… report cut at the 8 KB limit" end
	return table.concat(lines, "\n")
end

local function bootstrap(tern)
	-- A jump may outlive the tap: after a session switch the panes appear a moment later, so the match is retried
	-- on timers. `generation` names the newest jump; an older one stops the moment it sees a newer one.
	local generation, pending, last = 0, nil, nil

	local function notFound(cx)
		cx:toast("info", "Couldn't find that conversation on this phone", "Run Attention: Copy phone diagnostics")
	end

	-- Focuses the pane the evidence chose and reads the focus back. Returns what happened, for the diagnostics.
	local function focusPane(cx, pane)
		-- Focusing a parked pane would deal it into the current tab, so a parked match is reported instead.
		if pane.parked then
			cx:toast("info", "That conversation is parked", "Unpark it from the tab list")
			return "found but parked"
		end
		cx.layout:focus(pane.pane)
		if cx.session:focused() ~= pane.pane then
			cx:toast("error", "Couldn't switch to that conversation", "It may have moved or closed")
			return "focus did not stick"
		end
		return "focused"
	end

	-- One matching pass over this window's panes. True when the jump is over (focused, parked, or ambiguous).
	local function resolve(cx, wanted)
		local panes = cx.session:panes()
		local pane, reason, stages = match(panes, wanted)
		local attempt = { session = nil, panes = #panes, stages = stages, result = "no match" }
		local currentSession = safe(function() return cx.sessions:current() end)
		if type(currentSession) == "table" then attempt.session = currentSession.name end
		table.insert(last.attempts, attempt)
		if pane ~= nil then
			attempt.result = "match"
			last.result = focusPane(cx, pane)
			return true
		end
		if reason == "several" then
			attempt.result = "several"
			last.result = "several panes match"
			cx:toast("info", "Several panes match — open it from the tab list")
			return true
		end
		return false
	end

	local function step(cx, wanted, token, number)
		if token ~= generation then return end
		if resolve(cx, wanted) then return end
		if number == 0 then
			-- Nothing here by that title: the conversation may live in another session of this window.
			local target, lookupFailure = nil, nil
			if normalize(wanted.title) ~= "" then
				target, lookupFailure = safe(function() return pickSession(cx, wanted) end)
			end
			if target == nil then
				last.switch = if lookupFailure then "none (session lookup failed: " .. show(lookupFailure) .. ")"
					else "none (no other session of that name)"
				last.result = "not found"
				notFound(cx)
				return
			end
			local _, failure = safe(function() cx.sessions:switch(target.id) end)
			last.switch = "to session id " .. fmt(target.id) .. " " .. show(target.name) .. (if failure then " failed: " .. show(failure) else "")
			if failure ~= nil then
				last.result = "not found"
				notFound(cx)
				return
			end
		elseif number >= RETRIES then
			last.result = "not found after switching session"
			notFound(cx)
			return
		end
		pending = tern.timer(RETRY_MS, function(timerCx)
			if token ~= generation then return end
			pending = nil
			if timerCx == nil then return end
			local ok, failure = pcall(step, timerCx, wanted, token, number + 1)
			if not ok then
				last.result = "error: " .. show(failure)
				pcall(function() timerCx:toast("error", "Attention couldn't open that link", tostring(failure)) end)
			end
		end)
	end

	local function jump(cx, wanted)
		generation += 1
		if pending ~= nil then
			pcall(function() pending:cancel() end)
			pending = nil
		end
		last = { wanted = wanted, attempts = {}, switch = "not needed", result = "running" }
		step(cx, wanted, generation, 0)
	end

	-- Claims every attention:// URL (so the system never sees it) and leaves other links to Tern.
	local function route(link, cx)
		if type(link) ~= "table" or type(link.url) ~= "string" then return nil end
		local url = link.url
		if string.lower(string.sub(url, 1, #SCHEME)) ~= SCHEME then return nil end
		local ok, failure = pcall(function()
			if #url <= #PING and string.lower(url) == PING then
				cx:toast("success", "Attention phone link works")
				return
			end
			local wanted, reason = parseJump(url)
			if wanted == nil then
				cx:toast("error", "That Attention link isn't valid", reason)
				return
			end
			jump(cx, wanted)
		end)
		if not ok then pcall(function() cx:toast("error", "Attention couldn't open that link", tostring(failure)) end) end
		return { handled = true }
	end

	local function copyDiagnostics(cx)
		local report, failure = safe(function() return buildReport(cx, tern, last) end)
		if report == nil then
			cx:toast("error", "Couldn't build the diagnostics", failure)
			return
		end
		local _, copyFailure = safe(function() cx:copy(report) end)
		if copyFailure ~= nil then
			cx:toast("error", "Couldn't copy the diagnostics", copyFailure)
			return
		end
		cx:toast("success", "Diagnostics copied")
	end

	tern.route.link(route)
	tern.on("canvas_action", canvasAction)
	tern.command({
		id = "queue", title = "Attention queue", group = "Attention", icon = "bell",
		run = function(cx) openQueueSafely(cx, false) end,
	})
	tern.command({
		id = "diagnostics", title = "Copy phone diagnostics", group = "Attention", icon = "copy",
		run = function(cx) copyDiagnostics(cx) end,
	})
	return { parseJump = parseJump, match = match, normalize = normalize, route = route }
end

if tern ~= nil then bootstrap(tern) end
return bootstrap
