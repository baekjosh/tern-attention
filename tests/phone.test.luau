local phone = require("../phone")
local view = require("../view")
local navigation = require("../navigation")
local census = require("./census")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function clone(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, field in pairs(value) do result[key] = clone(field) end
	return result
end

local function equal(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

local NOW = 1700000000

-- The census as the model and navigator would present it on the owner window, after the optional edits.
local function build(editRaw, editRows, options)
	local raw, rows = census.raw(), census.rows()
	for _, row in ipairs(rows) do
		if row.hostKey == "local" then row.sessionName, row.localHost = "Atlas", true end
	end
	if editRaw then editRaw(raw) end
	if editRows then editRows(rows) end
	local data = navigation.inventory(raw, census.options())
	local workspace = navigation.project(data, { rows = rows, identities = census.identities(), identityPending = {},
		window = "window", nowUtc = NOW })
	local presentation = { rows = rows }
	local snapshot = phone.snapshot(presentation, workspace, { nowUtc = NOW, hostName = "Workbench", revision = 7, view = view,
		status = options and options.status, reason = options and options.reason })
	return snapshot, rows, presentation, workspace
end

local function byTitle(snapshot, title)
	for _, row in ipairs(snapshot.rows) do
		if row.title == title then return row end
	end
	return nil
end

local function row(rows, title)
	for _, candidate in ipairs(rows) do
		if candidate.title == title then return candidate end
	end
	error("no census row " .. title)
end

local function paneOf(title) return census.agentPanes(title)[1] end

test("queue sections follow the desktop queue", function()
	local snapshot = build(nil, function(rows)
		row(rows, "Tide ledger").attention = true
		row(rows, "Buoy audit").attention = true
		row(rows, "Pier schedule").attention = true
		row(rows, "Pier schedule").priority = 0
	end)
	assert(snapshot.schema == 2 and snapshot.status == "ok" and snapshot.revision == 7 and snapshot.generatedUtc == NOW
		and snapshot.host == "Workbench", "header fields")
	assert(snapshot.reason == nil, "an ok snapshot carries no reason")
	assert(snapshot.counts.attention == 4 and snapshot.counts.working == 0 and snapshot.counts.later == nil, "counts are queue denominators")
	local sections = {}
	for _, published in ipairs(snapshot.rows) do table.insert(sections, published.section) end
	assert(table.concat(sections, ",") == "attention,attention,attention,attention", "only Attention rows are published")
	-- Desktop order: priority first, then creation order.
	assert(snapshot.rows[1].title == "Pier schedule", "priority orders the queue like the desktop")
	for _, title in ipairs({ "Vibration limits", "Bale counting", "Kettle seam", "omp" }) do
		assert(byTitle(snapshot, title) == nil, title .. " is in no queue, so it is not published")
	end
	assert(byTitle(snapshot, "Core samples") == nil, "an idle active conversation is not in the queue")
end)

test("rows carry what the desktop row shows", function()
	local snapshot = build(nil, function(rows)
		local charge = row(rows, "Charge sizing")
		charge.attention, charge.nativeState, charge.condition = true, "waiting_input", "waiting"
		charge.source = { lastFinal = { atUtc = NOW - 720, timeKind = "completed" } }
		charge.sourceObservation = { status = "ready" }
		row(rows, "Index rebuild").attention = true
		row(rows, "Index rebuild").stale = true
	end)
	local published = byTitle(snapshot, "Charge sizing")
	assert(published.session == "Atlas" and published.tab == "blast log", "session and native tab name")
	assert(published.state == "Waiting for input", "state words")
	assert(published.host == "Workbench" and published.localHost == true, "host")
	assert(published.workId == "work:" .. published.serial, "work id")
	assert(published.clock.kind == "asked" or published.clock.kind == "replied", "a clock kind")
	local chip = phone.clockText(published.clock, NOW)
	assert(chip ~= nil and string.sub(chip, 1, 1) ~= "≈", "a readable source is not marked recorded")
	local offline = byTitle(snapshot, "Index rebuild")
	assert(offline.state == "Offline · runtime unknown" and offline.host == "Remote Lab" and offline.localHost == false,
		"offline row states it is offline")
end)

test("jumpable only for open tiled or floating panes", function()
	local parked, floating = paneOf("Buoy audit"), paneOf("Pier schedule")
	local snapshot = build(function(raw)
		for _, pane in ipairs(raw.panes) do
			if pane.pane == parked then pane.parked = true end
			if pane.pane == floating then pane.floating = true end
		end
	end, function(rows)
		for _, title in ipairs({ "Tide ledger", "Buoy audit", "Pier schedule", "Index rebuild", "omp" }) do
			row(rows, title).attention = true
		end
		row(rows, "Index rebuild").stale = true
		-- A saved conversation whose pane is closed: the model drops its pane.
		local retained = row(rows, "Blossom watch")
		retained.attention, retained.pane, retained.noOpenPane, retained.retained = true, nil, true, true
	end)
	local open = byTitle(snapshot, "Tide ledger")
	assert(open.jumpable and open.placement == "tiled" and open.pane == paneOf("Tide ledger"), "tiled pane jumps")
	assert(open.paneTitle == "Tide ledger" and open.cwd == "/work/atlas" and open.program == "omp", "pane evidence")
	local float = byTitle(snapshot, "Pier schedule")
	assert(float.jumpable and float.placement == "floating", "floating pane jumps without docking")
	local park = byTitle(snapshot, "Buoy audit")
	assert(not park.jumpable and park.placement == "parked" and park.pane == parked, "parked pane never jumps")
	local offline = byTitle(snapshot, "Index rebuild")
	assert(not offline.jumpable and offline.pane == nil and offline.placement == nil, "offline row has no pane to jump to")
	local gone = byTitle(snapshot, "Blossom watch")
	assert(not gone.jumpable and gone.pane == nil, "a row with no open pane is not jumpable")
	assert(phone.jumpUrl(park) == nil and phone.jumpUrl(offline) == nil and phone.jumpUrl(gone) == nil, "no link for them")
	assert(phone.jumpUrl(open) ~= nil, "a link for the open one")
end)

test("a row not yet proven openable on the desktop is not jumpable", function()
	local snapshot = build(nil, function(rows)
		local unproven = row(rows, "Tide ledger")
		unproven.attention, unproven.navigable = true, false
	end)
	assert(not byTitle(snapshot, "Tide ledger").jumpable, "navigable is the desktop's own openability test")
end)

test("a pane is jumpable by its native title alone; cwd and program only ride along when known", function()
	local pane = paneOf("Tide ledger")
	local function published(strip)
		local snapshot = build(function(raw)
			for _, candidate in ipairs(raw.panes) do
				if candidate.pane == pane then strip(candidate) end
			end
		end, function(rows)
			row(rows, "Tide ledger").attention = true
		end)
		return byTitle(snapshot, "Tide ledger")
	end
	local untitled = published(function(raw) raw.title = "" end)
	assert(untitled.pane == pane and untitled.placement == "tiled", "the pane is still open without a native title")
	assert(not untitled.jumpable and phone.jumpUrl(untitled) == nil, "no jump without a native title")
	local bare = published(function(raw) raw.cwd, raw.program = "", nil end)
	assert(bare.pane == pane and bare.cwd == nil and bare.program == nil, "the pane has neither cwd nor program")
	assert(bare.jumpable, "a title is enough to find the conversation")
	local parsed = phone.parseJump(phone.jumpUrl(bare))
	assert(parsed.title == "Tide ledger" and parsed.cwd == "" and parsed.program == "" and parsed.session == "Atlas",
		"the link carries the title and the session, and no empty evidence")
	local blankProgram = published(function(raw) raw.program = nil end)
	assert(blankProgram.jumpable and blankProgram.cwd == "/work/atlas", "a missing program keeps the cwd evidence")
end)

test("rows are capped but counts still total", function()
	local template = row(census.rows(), "Tide ledger")
	local rows = {}
	for index = 1, 75 do
		local copy = clone(template)
		copy.serial, copy.workId, copy.attention, copy.nativeState = index, "work:" .. index, true, "working"
		copy.pane = paneOf("Tide ledger")
		table.insert(rows, copy)
	end
	local presentation = { rows = rows, attentionCount = 999, workingCount = 999 }
	local snapshot = phone.snapshot(presentation, nil, { nowUtc = NOW, hostName = "Workbench", view = view })
	assert(#snapshot.rows == 60 and phone.MAX_ROWS == 60, "at most 60 rows")
	assert(snapshot.counts.attention == 75 and snapshot.counts.working == 75,
		"uncapped queue totals ignore invented presentation counters even when no Working rows fit")
	assert(phone.validate(clone(snapshot)) ~= nil, "a capped snapshot validates")
end)

test("a snapshot without a navigation tree has no jumpable rows", function()
	local rows = census.rows()
	row(rows, "Tide ledger").attention = true
	local snapshot = phone.snapshot({ rows = rows }, nil, { nowUtc = NOW, hostName = "Workbench", view = view })
	assert(byTitle(snapshot, "Tide ledger") ~= nil, "the row is still published")
	for _, published in ipairs(snapshot.rows) do
		assert(not published.jumpable and published.pane == nil and published.placement == nil, "no tree, no jump")
	end
end)

test("disabled and unavailable snapshots carry no rows and a plain reason", function()
	local disabled = build(nil, function(rows) row(rows, "Tide ledger").attention = true end,
		{ status = "disabled", reason = "Attention is disabled" })
	assert(disabled.status == "disabled" and #disabled.rows == 0 and disabled.counts.attention == 0, "disabled has no rows")
	local unavailable = build(nil, nil, { status = "unavailable", reason = string.rep("a ", 200) })
	assert(unavailable.status == "unavailable" and utf8.len(unavailable.reason or "") <= 200, "reason bounded")
	assert(phone.validate(clone(disabled)) ~= nil and phone.validate(clone(unavailable)) ~= nil, "both validate")
end)

test("published fields are bounded", function()
	local long = string.rep("Ünï ", 100)
	local snapshot = build(nil, function(rows)
		local tide = row(rows, "Tide ledger")
		tide.attention, tide.title, tide.sessionName, tide.hostName = true, long, long, long
	end)
	local published = snapshot.rows[1]
	assert(utf8.len(published.title) <= 160 and utf8.len(published.session) <= 64 and utf8.len(published.host) <= 64,
		"display fields are cut to their limits")
	assert(phone.validate(clone(snapshot)) ~= nil, "bounded rows validate")
end)

test("sameContent ignores the write counter and the write time only", function()
	local first = build(nil, function(rows) row(rows, "Tide ledger").attention = true end)
	local second = clone(first)
	second.revision, second.generatedUtc = 99, NOW + 500
	assert(phone.sameContent(first, second), "revision and time are not content")
	local third = clone(first)
	third.rows[1].state = "Working"
	assert(not phone.sameContent(first, third), "a row change is content")
	local fourth = clone(first)
	fourth.counts.working = 3
	assert(not phone.sameContent(first, fourth), "a count change is content")
	local fifth = clone(first)
	fifth.status, fifth.rows = "disabled", {}
	assert(not phone.sameContent(first, fifth), "status is content")
	assert(not phone.sameContent(first, nil) and not phone.sameContent(nil, nil), "missing snapshots are never the same")
end)

local function valid()
	return (build(nil, function(rows)
		row(rows, "Tide ledger").attention = true
		row(rows, "Vibration limits").attention = false
	end))
end

test("validate accepts what snapshot produces, unchanged", function()
	local snapshot = valid()
	local accepted = phone.validate(clone(snapshot))
	assert(accepted ~= nil and equal(accepted, snapshot), "round trip")
	assert(equal(phone.validate(clone(accepted)), accepted), "idempotent")
end)

test("validate strips unknown fields", function()
	local raw = clone(valid())
	raw.extra, raw.counts.other, raw.rows[1].secret, raw.rows[1].clock.debug = "x", 1, { token = "t" }, true
	local accepted = phone.validate(raw)
	assert(accepted ~= nil and accepted.extra == nil and accepted.counts.other == nil
		and accepted.rows[1].secret == nil and accepted.rows[1].clock.debug == nil, "unknown fields are stripped")
	assert(equal(accepted, valid()), "everything else survives")
end)

test("validate rejects hostile, oversized and wrong-typed input without throwing", function()
	local function rejects(label, edit)
		local raw = clone(valid())
		edit(raw)
		local accepted, reason = phone.validate(raw)
		assert(accepted == nil and type(reason) == "string" and reason ~= "", label .. " must be rejected with a reason")
	end
	for _, hostile in ipairs({ "text", 42, true, {} }) do
		local accepted, reason = phone.validate(hostile)
		assert(accepted == nil and type(reason) == "string", "non-snapshot " .. type(hostile))
	end
	assert(phone.validate(nil) == nil, "nil")
	local booby = setmetatable({}, { __index = function() error("boom") end })
	assert(phone.validate(booby) == nil, "an erroring table never throws")
	local lying = setmetatable({}, { __len = function() error("boom") end, __index = function() error("boom") end })
	assert(phone.validate({ schema = 2, revision = 1, generatedUtc = 1, status = "ok", host = "m",
		counts = { attention = 0, working = 0 }, rows = lying }) == nil, "an erroring row list never throws")
	rejects("old schema", function(raw) raw.schema = 1 end)
	rejects("future schema", function(raw) raw.schema = 3 end)
	rejects("string revision", function(raw) raw.revision = "7" end)
	rejects("fractional revision", function(raw) raw.revision = 1.5 end)
	rejects("NaN time", function(raw) raw.generatedUtc = 0 / 0 end)
	rejects("infinite time", function(raw) raw.generatedUtc = math.huge end)
	rejects("status", function(raw) raw.status = "weird" end)
	rejects("empty host", function(raw) raw.host = "" end)
	rejects("long host", function(raw) raw.host = string.rep("h", 65) end)
	rejects("long reason", function(raw) raw.reason = string.rep("r", 201) end)
	rejects("missing counts", function(raw) raw.counts = nil end)
	rejects("negative count", function(raw) raw.counts.attention = -1 end)
	rejects("missing working count", function(raw) raw.counts.working = nil end)
	rejects("string working count", function(raw) raw.counts.working = "1" end)
	rejects("negative working count", function(raw) raw.counts.working = -1 end)
	rejects("fractional working count", function(raw) raw.counts.working = 0.5 end)
	rejects("rows type", function(raw) raw.rows = "many" end)
	rejects("too many rows", function(raw)
		for index = 1, 61 do raw.rows[index] = clone(valid().rows[1]) end
	end)
	rejects("row type", function(raw) raw.rows[1] = "row" end)
	rejects("serial type", function(raw) raw.rows[1].serial = "1" end)
	rejects("negative serial", function(raw) raw.rows[1].serial = -1 end)
	rejects("section", function(raw) raw.rows[1].section = "reference" end)
	rejects("long title", function(raw) raw.rows[1].title = string.rep("t", 161) end)
	rejects("huge title", function(raw) raw.rows[1].title = string.rep("t", 10000000) end)
	rejects("newline in title", function(raw) raw.rows[1].title = "a\nb" end)
	rejects("invalid utf-8", function(raw) raw.rows[1].session = "bad\255" end)
	rejects("long state", function(raw) raw.rows[1].state = string.rep("s", 41) end)
	rejects("long cwd", function(raw) raw.rows[1].cwd = string.rep("c", 201) end)
	rejects("pane type", function(raw) raw.rows[1].pane = "7" end)
	rejects("placement", function(raw) raw.rows[1].placement = "sideways" end)
	rejects("flag type", function(raw) raw.rows[1].jumpable = "yes" end)
	rejects("missing clock", function(raw) raw.rows[1].clock = nil end)
	rejects("clock kind", function(raw) raw.rows[1].clock.kind = "bogus" end)
	rejects("clock time", function(raw) raw.rows[1].clock.atUtc = "noon" end)
	rejects("recorded type", function(raw) raw.rows[1].clock.recorded = 1 end)
end)

test("validate never lets a row claim a jump it cannot make", function()
	local raw = clone(valid())
	raw.rows[1].jumpable, raw.rows[1].pane, raw.rows[1].placement = true, nil, nil
	assert(phone.validate(raw).rows[1].jumpable == false, "no pane, no jump")
	raw.rows[1].pane, raw.rows[1].placement = 5, "parked"
	assert(phone.validate(raw).rows[1].jumpable == false, "a parked pane is never jumped to")
	raw.rows[1].placement = "tiled"
	assert(phone.validate(raw).rows[1].jumpable == true, "an open pane may be")
	raw.rows[1].paneTitle = nil
	assert(phone.validate(raw).rows[1].jumpable == false, "a pane without a title cannot be found on the phone")
end)

local function jumpRow(title, cwd, program, host, session)
	return { jumpable = true, pane = 42, host = host or "Workbench", paneTitle = title, cwd = cwd, program = program,
		session = session }
end

test("jump links round trip hostile text exactly", function()
	local titles = {
		"plain", "two  spaces and\ttab", "ünï ☃ 日本語 🚀", "a&b=c?d#e/f", "100% sure %41 %zz %", "line\nbreak\r\n",
		"+plus+", "'quote\" and <tag>", string.rep("%", 160), string.rep("long title ", 14),
	}
	for _, title in ipairs(titles) do
		local url = phone.jumpUrl(jumpRow(title, "/work/my project/ü", "omp", "Ada's Mac & Co", "notes & co ü"))
		assert(url ~= nil and #url <= 1500, "link fits for " .. string.format("%q", title))
		assert(not string.find(url, "[^%w%-%._~%%&=:/?]"), "only URL-safe bytes appear: " .. url)
		local parsed = phone.parseJump(url)
		assert(parsed ~= nil and parsed.pane == 42 and parsed.host == "Ada's Mac & Co" and parsed.title == title
			and parsed.cwd == "/work/my project/ü" and parsed.program == "omp" and parsed.session == "notes & co ü",
			"round trip " .. string.format("%q", title))
	end
	local bare = phone.parseJump("attention://jump?p=0&h=M")
	assert(bare.pane == 0 and bare.title == "" and bare.cwd == "" and bare.program == "" and bare.session == "",
		"absent evidence is empty")
	local older = phone.parseJump("attention://jump?p=3&h=M&t=T&c=%2Fa&g=omp")
	assert(older and older.title == "T" and older.cwd == "/a" and older.program == "omp" and older.session == "",
		"a link made before the session name was added still parses")
	local ordered = phone.parseJump("attention://jump?s=ji&g=omp&c=%2Fa&t=T&h=M&p=3")
	assert(ordered and ordered.session == "ji" and ordered.pane == 3, "field order does not matter")
end)

test("the pane title is the only required evidence of a jump link", function()
	local titleOnly = phone.jumpUrl(jumpRow("t", nil, nil))
	assert(titleOnly == "attention://jump?p=42&h=Workbench&t=t", "no cwd, program or session adds nothing: " .. tostring(titleOnly))
	assert(phone.jumpUrl(jumpRow("t", "", "")) == titleOnly, "empty evidence is absent evidence")
	local parsed = phone.parseJump(phone.jumpUrl(jumpRow("t", "/c", nil, nil, "ji")))
	assert(parsed.cwd == "/c" and parsed.program == "" and parsed.session == "ji", "each optional part stands alone")
	assert(phone.jumpUrl(jumpRow("", "/c", "omp")) == nil, "no title")
	assert(phone.jumpUrl(jumpRow("\u{E743} \u{F009A}  ", "/c", "omp")) == nil, "a title that is only icon glyphs and spaces")
	assert(phone.jumpUrl(jumpRow(nil, "/c", "omp")) == nil, "absent title")
end)

test("optional link parts that do not fit are left out, never truncated", function()
	local title = string.rep("é", 160) -- 6 encoded bytes each: 960 bytes of the 1500
	local both = phone.jumpUrl(jumpRow(title, string.rep("é", 100), "omp", nil, "ji"))
	assert(both ~= nil and #both <= 1500, "the link still fits")
	local parsed = phone.parseJump(both)
	assert(parsed.title == title, "the title is whole")
	assert(parsed.cwd == "" or parsed.cwd == string.rep("é", 100), "an optional part is whole or absent")
	local crowded = phone.jumpUrl(jumpRow(title, string.rep("é", 200), "omp", nil, "ji"))
	assert(crowded ~= nil and #crowded <= 1500 and phone.parseJump(crowded).title == title, "crowding drops parts only")
end)

test("a jump link that cannot carry its evidence whole is not made", function()
	assert(phone.jumpUrl(jumpRow(string.rep("x", 161), "/c", "omp")) == nil, "title beyond its bound")
	assert(phone.jumpUrl(jumpRow(string.rep("🚀", 160), string.rep("🚀", 200), "omp")) == nil, "title beyond 1500 bytes")
	assert(phone.jumpUrl(jumpRow("t", string.rep("c", 201), "omp")) == nil, "cwd beyond its bound")
	assert(phone.jumpUrl(jumpRow("t", "/c", string.rep("p", 65))) == nil, "program beyond its bound")
	assert(phone.jumpUrl({ jumpable = false, pane = 1, host = "M" }) == nil, "not jumpable")
	assert(phone.jumpUrl({ jumpable = true, host = "M" }) == nil, "no pane")
	assert(phone.jumpUrl({ jumpable = true, pane = 1.5, host = "M" }) == nil, "fractional pane")
	assert(phone.jumpUrl({ jumpable = true, pane = 1, host = "M", paneTitle = "bad\255", cwd = "/c", program = "omp" }) == nil,
		"invalid text")
	assert(phone.jumpUrl(jumpRow("t", "bad\255", "omp")) == nil, "invalid cwd")
	assert(phone.jumpUrl(jumpRow("t", 5, "omp")) == nil, "wrong-typed cwd")
	assert(phone.jumpUrl(nil) == nil and phone.jumpUrl("x") == nil, "not a row")
	local unusable = phone.parseJump(phone.jumpUrl(jumpRow("t", "/c", "omp", nil, "bad\255")))
	assert(unusable and unusable.session == "", "an unusable session name is left out of the link")
end)

test("titles are normalized for matching", function()
	assert(phone.matchTitle("plain title") == "plain title", "ordinary text is unchanged")
	assert(phone.matchTitle("\u{E743} PLAN: beta \u{F009A}") == "PLAN: beta", "icon glyphs and the spaces they leave")
	assert(phone.matchTitle("  a \t\n b\u{A0}\u{3000}c  ") == "a b c", "whitespace collapses to one space")
	assert(phone.matchTitle("Case Matters") ~= phone.matchTitle("case matters"), "case is kept")
	assert(phone.matchTitle("ünï ☃ 日本語") == "ünï ☃ 日本語", "other text is untouched")
	assert(phone.matchTitle("\u{E000}\u{F8FF}\u{FFFFD}\u{10FFFF} ") == "", "only glyphs is empty")
	assert(phone.matchTitle("bad\255") == "" and phone.matchTitle(nil) == "" and phone.matchTitle(5) == "", "not text is empty")
	assert(phone.matchTitle("\u{F8FE}x") == "x" and phone.matchTitle("\u{F900}x") == "\u{F900}x", "the private-use range ends at F8FF")
end)

test("parseJump refuses anything but its own links", function()
	local good = phone.jumpUrl(jumpRow("t", "/c", "omp"))
	assert(phone.parseJump(good) ~= nil, "control")
	for label, url in pairs({
		scheme = "https://example.com/?p=1&h=M", ping = phone.PING, empty = "", prefix = "attention://jump",
		noPane = "attention://jump?h=M", noHost = "attention://jump?p=1", badPane = "attention://jump?p=x&h=M",
		fractional = "attention://jump?p=1.5&h=M", longPane = "attention://jump?p=1234567890123456&h=M",
		duplicate = "attention://jump?p=1&p=2&h=M", unknown = "attention://jump?p=1&h=M&z=1",
		truncatedEscape = "attention://jump?p=1&h=M%4", badEscape = "attention://jump?p=1&h=M%zz",
		invalidUtf8 = "attention://jump?p=1&h=M%FF", rawSpace = "attention://jump?p=1&h=M N",
		rawNewline = "attention://jump?p=1&h=M\n", fragment = "attention://jump?p=1&h=M#x", nested = "attention://jump?p=1&h=a=b",
		blankPart = "attention://jump?p=1&&h=M", longTitle = "attention://jump?p=1&h=M&t=" .. string.rep("a", 161),
		oversized = "attention://jump?p=1&h=M&t=" .. string.rep("a", 1500),
	}) do
		local parsed, reason = phone.parseJump(url)
		assert(parsed == nil and type(reason) == "string" and reason ~= "", label .. " must be rejected with a reason")
	end
	local parsed, reason = phone.parseJump(nil)
	assert(parsed == nil and reason ~= nil, "not a string")
end)

test("ages and clock chips use one wording", function()
	assert(phone.age(0) == "<1m" and phone.age(59) == "<1m", "under a minute")
	assert(phone.age(60) == "1m" and phone.age(719) == "11m" and phone.age(3599) == "59m", "minutes")
	assert(phone.age(3600) == "1h" and phone.age(86399) == "23h", "hours")
	assert(phone.age(86400) == "1d" and phone.age(3 * 86400 + 5) == "3d", "days")
	assert(phone.relative(NOW - 720, NOW) == "12m ago" and phone.relative(nil, NOW) == "time unknown"
		and phone.relative(NOW + 5, NOW) == "clock uncertain", "relative")
	local chip, tooltip = phone.clockText({ kind = "asked", atUtc = NOW - 720, recorded = false }, NOW)
	assert(chip == "Asked 12m ago" and tooltip == "The agent last asked a question 12 minutes ago.", "asked")
	assert(phone.clockText({ kind = "replied", atUtc = NOW - 3 * 86400, recorded = false }, NOW) == "Replied 3d ago", "replied")
	assert(phone.clockText({ kind = "updated", atUtc = NOW - 300, recorded = false }, NOW) == "Updated 5m ago", "updated")
	assert(phone.clockText({ kind = "updated", atUtc = NOW - 10, recorded = false }, NOW) == "Updated <1m ago", "under a minute")
	assert(phone.clockText({ kind = "replied", atUtc = NOW - 720, recorded = true }, NOW) == "≈ Replied 12m ago", "recorded prefix")
	assert(phone.clockText({ kind = "asked", recorded = false }, NOW) == "Asked · time unknown", "unknown time said")
	assert(phone.clockText({ recorded = false }, NOW) == nil and phone.clockText(nil, NOW) == nil, "no kind, no chip")
end)

test("working publishes live work after Attention with explicit overlapping row sections", function()
	local snapshot, rows, presentation, workspace = build(nil, function(items)
		for _, title in ipairs({ "Tide ledger", "Vibration limits", "Bale counting", "Kettle seam" }) do
			local item = row(items, title)
			item.nativeState = "working"
		end
		row(items, "Tide ledger").attention = true
		row(items, "Core samples").nativeState = "working"
		row(items, "Core samples").stale = true
	end)
	local working = view.queue(presentation, "working")
	-- Core samples is stale (its source proof is pending), but its pane is live, so it still works.
	assert(snapshot.counts.working == 5 and snapshot.counts.working == #working)
	assert(snapshot.counts.attention == #view.queue(presentation, "attention"), "existing queue counts stay unchanged")
	local rank, previous, tideSections = { attention = 1, working = 2 }, 0, {}
	local seenWorking = {}
	for _, published in ipairs(snapshot.rows) do
		assert(rank[published.section] >= previous, "Attention, then Working")
		previous = rank[published.section]
		if published.section == "working" then
			table.insert(seenWorking, published.workId)
			assert(published.state == "Working", "runtime stays live")
		end
		if published.title == "Tide ledger" then tideSections[published.section] = published end
		if published.title == "Vibration limits" or published.title == "Bale counting" or published.title == "Kettle seam" then
			assert(published.section == "working", "set-aside work is published only as live Working, never in Attention")
		end
	end
	for index, item in ipairs(working) do assert(seenWorking[index] == item.workId, "phone reuses desktop order") end
	assert(tideSections.attention and tideSections.working and tideSections.attention.workId == tideSections.working.workId
		and tideSections.attention.serial == tideSections.working.serial,
		"the same live attention conversation is deliberately present in both modes")
	assert(equal(phone.validate(clone(snapshot)), snapshot), "schema 2 round-trips overlapping identities across modes")
	local pending = row(rows, "Core samples")
	pending.identityKey, pending.navigable, pending.retryableHeaderRoute = nil, false, false
	local unproven = phone.snapshot(presentation, workspace, { nowUtc = NOW, hostName = "Workbench", view = view })
	assert(unproven.counts.working == #working and byTitle(unproven, "Core samples").jumpable == false,
		"missing source proof cannot hide live work or invent a jump")
	local old = clone(snapshot)
	old.schema = 1
	local accepted, reason = phone.validate(old)
	assert(accepted == nil and reason == "unsupported snapshot schema", "an old snapshot is unavailable, not zero Working")
end)

test("a Working-only cap keeps the full eligible total", function()
	local template, rows = row(census.rows(), "Tide ledger"), {}
	for index = 1, 75 do
		local item = clone(template)
		item.serial, item.workId, item.nativeState, item.attention = index, "work:" .. index, "working", false
		table.insert(rows, item)
	end
	rows[75].nativeState = "idle"
	rows[74].pane, rows[74].live = nil, false
	local snapshot = phone.snapshot({ rows = rows }, nil, { nowUtc = NOW, hostName = "Workbench", view = view })
	assert(#snapshot.rows == phone.MAX_ROWS and snapshot.counts.working == 73
		and snapshot.counts.attention == 0)
	assert(snapshot.rows[1].section == "working" and snapshot.rows[1].workId == "work:1"
		and snapshot.rows[60].workId == "work:60")
	assert(phone.validate(clone(snapshot)), "capped Working validates with honest totals")
end)

return true
