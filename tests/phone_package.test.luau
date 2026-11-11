local bootstrap = require("../phone-package/attention-phone/window")
local phone = require("../phone")

-- The phone package is a window half that cannot require anything outside its folder. These tests drive
-- it only through what Tern calls: the registered `tern.route.link` handler, the palette commands and the timers
-- it arms, against a fake `tern`/`cx` that records every toast, focus, session switch, copy and block.

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local TAG = 17592186044416 -- 2^44, the host-tag unit; the tests build ids with it, the package must not need us

local function pane(id, title, cwd, program, extra)
	local value = { pane = id, title = title, cwd = cwd, program = program, kind = "terminal", tab = 1,
		parked = false, floating = false }
	for key, field in pairs(extra or {}) do value[key] = field end
	return value
end

-- Percent-encodes everything outside the unreserved set, written independently of the package.
local function enc(text)
	return (string.gsub(text, "[^%w%-%._~]", function(char) return string.format("%%%02X", string.byte(char)) end))
end

local function jumpUrl(fields)
	local url = "attention://jump?p=" .. tostring(fields.p) .. "&h=" .. enc(fields.h or "forge")
		.. "&t=" .. enc(fields.t or "")
	if fields.c ~= nil then url ..= "&c=" .. enc(fields.c) end
	if fields.g ~= nil then url ..= "&g=" .. enc(fields.g) end
	if fields.s ~= nil then url ..= "&s=" .. enc(fields.s) end
	return url
end

-- `options`: focused (initial), focusFails, blockTypes, newBlockFails, panesFail, copyFails, os, hosts, sessions,
-- inventory. With `sessions` (ManagedSession-like rows; the one with `current = true` is shown first) and
-- `inventory` (session id -> the panes that session shows) a session switch really changes what `panes()` lists,
-- so a test can make panes appear between timer ticks. `new_block` really adds the pane to the inventory and
-- focuses it, so a second run sees what the first one made. Timers run only when the test advances the clock.
local function world(panes, options)
	options = options or {}
	local record = { toasts = {}, focuses = {}, blocks = {}, focused = options.focused, switches = {}, copies = {},
		now = 0, timers = {}, scheduled = 0, current = nil }
	for _, session in ipairs(options.sessions or {}) do
		if session.current then record.current = session.id end
	end
	local handler, commands, handlers = nil, {}, {}
	local tern = {
		route = { link = function(fn) handler = fn end },
		command = function(def) commands[def.id] = def end,
		on = function(name, fn) handlers[name] = fn end,
		runtime = { os = options.os or "ios", jit = false },
	}
	function tern.timer(ms, fn)
		local timer = { due = record.now + ms, fn = fn, live = true }
		table.insert(record.timers, timer)
		record.scheduled += 1
		return { cancel = function() timer.live = false end }
	end
	bootstrap(tern)
	local session, layout, sessions, hosts = {}, {}, {}, {}
	function session:panes()
		if options.panesFail then error("inventory exploded") end
		if options.inventory then return options.inventory[record.current] end
		return panes
	end
	function session:focused() return record.focused end
	function session:block_types() return options.blockTypes or {} end
	function layout:focus(id)
		table.insert(record.focuses, id)
		if not options.focusFails then record.focused = id end
	end
	function sessions:list()
		local list = {}
		for _, entry in ipairs(options.sessions or {}) do
			local copy = {}
			for key, value in pairs(entry) do copy[key] = value end
			copy.current = entry.id == record.current
			table.insert(list, copy)
		end
		return list
	end
	function sessions:current()
		for _, entry in ipairs(self:list()) do
			if entry.current then return entry end
		end
		error("no current session")
	end
	function sessions:switch(id)
		table.insert(record.switches, id)
		record.current = id
	end
	function hosts:list()
		return options.hosts or { { id = 0, name = "iPhone", kind = "local", state = "connected", current = true } }
	end
	local cx = { session = session, layout = layout, sessions = sessions, hosts = hosts }
	function cx:toast(level, text, sub) table.insert(record.toasts, { level = level, text = text, sub = sub }) end
	function cx:copy(text)
		if options.copyFails then error("clipboard unavailable") end
		table.insert(record.copies, text)
	end
	function cx:new_block(kind, args, how)
		table.insert(record.blocks, { kind = kind, args = args, how = how })
		if options.newBlockFails then return nil end
		table.insert(panes, { pane = 99, kind = "plugin", block = kind, title = "Attention queue", cwd = "", tab = 7,
			parked = false, floating = false })
		record.focused = 99
		return 99
	end
	record.cx, record.commands, record.handlers = cx, commands, handlers
	function record.click(url)
		local decision = handler({ url = url, pane = 1, mods = {} }, cx)
		return decision
	end
	function record.canvasAction(ev)
		return handlers.canvas_action(ev, cx)
	end
	-- Runs every live timer that falls due within `ms` milliseconds, in order, with a fresh cx like Tern's.
	function record.advance(ms)
		local target = record.now + ms
		while true do
			local next = nil
			for _, timer in ipairs(record.timers) do
				if timer.live and timer.due <= target and (next == nil or timer.due < next.due) then next = timer end
			end
			if next == nil then break end
			record.now, next.live = next.due, false
			next.fn(cx)
		end
		record.now = target
	end
	function record.live()
		local count = 0
		for _, timer in ipairs(record.timers) do if timer.live then count += 1 end end
		return count
	end
	return record
end

local function lastToast(record)
	return record.toasts[#record.toasts]
end

local function assertClaimed(decision)
	assert(type(decision) == "table" and decision.handled == true, "an attention:// link is always claimed")
end

local NOT_FOUND, NOT_FOUND_SUB = "Couldn't find that conversation on this phone", "Run Attention: Copy phone diagnostics"
local SEVERAL = "Several panes match — open it from the tab list"

local function assertNotFound(record)
	assert(#record.toasts == 1, "exactly one toast, got " .. #record.toasts)
	assert(lastToast(record).level == "info" and lastToast(record).text == NOT_FOUND and lastToast(record).sub == NOT_FOUND_SUB,
		"the two-line not-found toast")
end

local TITLE, CWD, PROGRAM = "Fix the build · omp", "/Users/me/work/app", "omp"
local GLYPH, GLYPH2 = utf8.char(0xE743), utf8.char(0xF009A)

test("a unique title match is focused and confirmed without a toast", function()
	local record = world({ pane(7, TITLE, CWD, PROGRAM), pane(8, "Other", CWD, PROGRAM) })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#record.focuses == 1 and record.focuses[1] == 7)
	assert(#record.toasts == 0)
	assert(#record.switches == 0 and record.scheduled == 0, "no session switch and no timer for an immediate match")
end)

test("a remote pane id is focused unchanged, never recomputed", function()
	local remote = 3 * TAG + 41
	local record = world({ pane(remote, TITLE, CWD, PROGRAM) })
	-- The URL carries the Mac's own daemon id; the phone sees the host-tagged one.
	record.click(jumpUrl({ p = 41, t = TITLE, c = CWD, g = PROGRAM }))
	assert(record.focuses[1] == remote)
	local other = world({ pane(remote, TITLE, CWD, PROGRAM) })
	other.click(jumpUrl({ p = 9999, t = TITLE, c = CWD, g = PROGRAM }))
	assert(other.focuses[1] == remote, "the modulo never gates a unique title match")
end)

test("the real iPhone shapes: blank cwd, another program, still found by title", function()
	-- Remote panes the phone lists: no cwd, and the shell path where the Mac's evidence says `omp`.
	local record = world({ pane(2 * TAG + 12, "Task: restore the bottom rail", "", "/bin/zsh"),
		pane(2 * TAG + 13, "Task: complete the release checklist", "", "/bin/zsh") })
	record.click(jumpUrl({ p = 13, t = "Task: complete the release checklist", c = "/Users/me/notes", g = "omp",
		s = "notes" }))
	assert(record.focuses[1] == 2 * TAG + 13 and #record.focuses == 1 and #record.toasts == 0)
	local reversed = world({ pane(5, TITLE, "/somewhere/else", "node") })
	reversed.click(jumpUrl({ p = 5, t = TITLE }))
	assert(reversed.focuses[1] == 5, "a link with a title and nothing else finds it")
	local missing = world({ pane(5, TITLE, nil, nil) })
	missing.click(jumpUrl({ p = 5, t = TITLE, c = CWD, g = PROGRAM }))
	assert(missing.focuses[1] == 5, "a pane with no cwd or program fields at all")
end)

test("icon glyphs and spacing in either title do not matter", function()
	local plain = "Task: complete the release checklist"
	local function found(paneTitle, wantedTitle)
		local record = world({ pane(7, paneTitle, "", "") })
		record.click(jumpUrl({ p = 7, t = wantedTitle }))
		return record.focuses[1] == 7 and #record.toasts == 0
	end
	assert(found(plain, plain), "identical")
	assert(found(plain, GLYPH .. " " .. plain), "the Mac's title has a glyph prefix the phone's lacks")
	assert(found(GLYPH .. " " .. plain, plain), "the phone's title has a glyph prefix the Mac's lacks")
	assert(found(GLYPH .. " " .. plain, GLYPH2 .. "  " .. plain), "different glyphs on both sides")
	assert(found("  Task:  complete the release\tchecklist ", plain), "whitespace runs and ends")
	assert(found(plain .. " " .. GLYPH, plain), "a trailing glyph")
	assert(not found(plain:lower(), plain), "case is compared")
	assert(not found("Task: complete the release", plain), "a prefix of the title is another title")
	assert(not found(plain, GLYPH .. " " .. GLYPH2), "a title of only glyphs matches nothing")
	assert(not found(GLYPH .. " " .. GLYPH2, GLYPH), "nor does a pane whose title is only glyphs")
	assert(not found("", ""), "empty never equals empty")
end)

test("duplicate titles are told apart by the host-tag modulo", function()
	local record = world({
		pane(5 * TAG + 9, TITLE, CWD, PROGRAM), pane(5 * TAG + 12, TITLE, CWD, PROGRAM),
	})
	record.click(jumpUrl({ p = 12, t = TITLE, c = CWD, g = PROGRAM }))
	assert(record.focuses[1] == 5 * TAG + 12 and #record.focuses == 1 and #record.toasts == 0)
	local again = world({
		pane(5 * TAG + 9, TITLE, CWD, PROGRAM), pane(5 * TAG + 12, TITLE, CWD, PROGRAM),
	})
	again.click(jumpUrl({ p = 2 * TAG + 9, t = TITLE, c = CWD, g = PROGRAM }))
	assert(again.focuses[1] == 5 * TAG + 9, "only the low 44 bits matter, the url's host slot is ignored")
end)

test("duplicate titles the id cannot separate fall back to cwd, then program", function()
	-- No pane has the wanted id: the working directory decides.
	local byCwd = world({ pane(5 * TAG + 9, TITLE, "/other", PROGRAM), pane(6 * TAG + 9, TITLE, CWD, PROGRAM) })
	byCwd.click(jumpUrl({ p = 77, t = TITLE, c = CWD, g = PROGRAM }))
	assert(byCwd.focuses[1] == 6 * TAG + 9 and #byCwd.toasts == 0)
	-- Same cwd everywhere: the program decides.
	local byProgram = world({ pane(5 * TAG + 9, TITLE, CWD, "zsh"), pane(6 * TAG + 9, TITLE, CWD, "omp") })
	byProgram.click(jumpUrl({ p = 77, t = TITLE, c = CWD, g = "omp" }))
	assert(byProgram.focuses[1] == 6 * TAG + 9 and #byProgram.toasts == 0)
	-- The id narrows first, then cwd breaks what is left.
	local both = world({ pane(5 * TAG + 9, TITLE, "/a", PROGRAM), pane(6 * TAG + 9, TITLE, CWD, PROGRAM),
		pane(6 * TAG + 10, TITLE, CWD, PROGRAM) })
	both.click(jumpUrl({ p = 9, t = TITLE, c = CWD, g = PROGRAM }))
	assert(both.focuses[1] == 6 * TAG + 9)
	-- A blank cwd on either side is not evidence either way.
	local blank = world({ pane(5 * TAG + 9, TITLE, "", PROGRAM), pane(6 * TAG + 9, TITLE, "", PROGRAM) })
	blank.click(jumpUrl({ p = 77, t = TITLE, g = PROGRAM }))
	assert(#blank.focuses == 0 and lastToast(blank).text == SEVERAL)
	-- A stage nobody passes changes nothing (the Mac's cwd is not the phone's).
	local nobody = world({ pane(5 * TAG + 9, TITLE, "/a", "zsh"), pane(6 * TAG + 9, TITLE, "/b", "zsh") })
	nobody.click(jumpUrl({ p = 77, t = TITLE, c = CWD, g = PROGRAM }))
	assert(#nobody.focuses == 0 and lastToast(nobody).text == SEVERAL)
	-- The cwd narrows, the program then separates the rest.
	local chain = world({ pane(1, TITLE, CWD, "zsh"), pane(2, TITLE, CWD, "omp"), pane(3, TITLE, "/x", "omp") })
	chain.click(jumpUrl({ p = 99, t = TITLE, c = CWD, g = "omp" }))
	assert(chain.focuses[1] == 2)
end)

test("duplicates nothing can separate are reported, never guessed", function()
	local none = world({ pane(5 * TAG + 9, TITLE, CWD, PROGRAM), pane(5 * TAG + 12, TITLE, CWD, PROGRAM) })
	assertClaimed(none.click(jumpUrl({ p = 77, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#none.focuses == 0)
	assert(#none.toasts == 1 and lastToast(none).text == SEVERAL)
	local both = world({ pane(5 * TAG + 9, TITLE, CWD, PROGRAM), pane(6 * TAG + 9, TITLE, CWD, PROGRAM) })
	both.click(jumpUrl({ p = 9, t = TITLE, c = CWD, g = PROGRAM }))
	assert(#both.focuses == 0 and #both.toasts == 1)
	assert(lastToast(both).text == SEVERAL)
	assert(#both.switches == 0 and both.scheduled == 0, "an ambiguous title never switches session")
end)

test("no title match is one two-line toast; the id, cwd and program alone never pick a pane", function()
	local record = world({ pane(7, "Something else", CWD, PROGRAM), pane(8, TITLE .. " 2", CWD, PROGRAM),
		pane(41, "Third", CWD, PROGRAM) })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#record.focuses == 0)
	assertNotFound(record)
	local byId = world({ pane(41, "Unrelated", "/x", "zsh") })
	byId.click(jumpUrl({ p = 41, t = TITLE, c = "/x", g = "zsh" }))
	assert(#byId.focuses == 0)
	assertNotFound(byId)
	local empty = world({})
	empty.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM }))
	assert(#empty.focuses == 0)
	assertNotFound(empty)
	local untitled = world({ pane(7, "", CWD, PROGRAM) })
	untitled.click("attention://jump?p=7&h=forge&c=" .. enc(CWD) .. "&g=omp")
	assert(#untitled.focuses == 0)
	assertNotFound(untitled)
end)

test("the queue block itself is never the target", function()
	local record = world({ pane(40, TITLE, "", nil, { kind = "plugin", block = "attention.queue" }) })
	record.click(jumpUrl({ p = 40, t = TITLE }))
	assert(#record.focuses == 0)
	assertNotFound(record)
end)

test("a pane on another host with the same title is still the one when nothing else has it", function()
	local record = world({
		pane(2 * TAG + 7, TITLE, "/home/other/app", PROGRAM), pane(3 * TAG + 7, TITLE, CWD, PROGRAM),
	})
	record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM }))
	assert(#record.focuses == 1 and record.focuses[1] == 3 * TAG + 7, "same id on both hosts: the cwd decides")
	local only = world({ pane(2 * TAG + 7, TITLE, "/home/other/app", PROGRAM) })
	only.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM }))
	assert(only.focuses[1] == 2 * TAG + 7 and #only.toasts == 0, "a different cwd does not make it another conversation")
end)

test("a parked match is reported and never focused", function()
	local record = world({ pane(7, TITLE, CWD, PROGRAM, { parked = true, tab = nil }) })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#record.focuses == 0)
	assert(#record.toasts == 1 and lastToast(record).text == "That conversation is parked")
	assert(lastToast(record).sub == "Unpark it from the tab list")
	assert(record.scheduled == 0 and #record.switches == 0, "a parked match ends the jump")
	-- Disambiguated onto the parked twin by the modulo: still no focus.
	local twins = world({
		pane(5 * TAG + 9, TITLE, CWD, PROGRAM, { parked = true, tab = nil }), pane(5 * TAG + 12, TITLE, CWD, PROGRAM),
	})
	twins.click(jumpUrl({ p = 9, t = TITLE, c = CWD, g = PROGRAM }))
	assert(#twins.focuses == 0 and lastToast(twins).text == "That conversation is parked")
	-- The visible twin wins when the modulo points at it.
	local visible = world({
		pane(5 * TAG + 9, TITLE, CWD, PROGRAM, { parked = true, tab = nil }), pane(5 * TAG + 12, TITLE, CWD, PROGRAM),
	})
	visible.click(jumpUrl({ p = 12, t = TITLE, c = CWD, g = PROGRAM }))
	assert(visible.focuses[1] == 5 * TAG + 12)
end)

test("a floating pane is focused as it is", function()
	local record = world({ pane(7, TITLE, CWD, PROGRAM, { floating = true }) })
	record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM }))
	assert(record.focuses[1] == 7 and #record.toasts == 0)
end)

test("a focus that does not stick is reported as an error", function()
	local record = world({ pane(7, TITLE, CWD, PROGRAM) }, { focusFails = true, focused = 3 })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#record.focuses == 1)
	assert(lastToast(record).level == "error")
end)

test("an inventory that raises never escapes the route", function()
	local record = world({}, { panesFail = true })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM })))
	assert(#record.focuses == 0 and lastToast(record).level == "error")
end)

-- Cross-session: the conversation is in another session of this window, so the phone switches to it and looks again.
local function sessionsWorld(inventory, extra)
	local options = { sessions = {
		{ id = 1, name = "app", host = 0, current = true, locked = false, tabs = 1 },
		{ id = 2, name = "notes", host = 0, current = false, locked = false, tabs = 1 },
	}, inventory = inventory, focused = 3 }
	for key, value in pairs(extra or {}) do options[key] = value end
	return world(nil, options)
end

test("a conversation in another session is found after switching, on the second attempt", function()
	local target = {}
	local record = sessionsWorld({ [1] = { pane(3, "zsh", "/", "zsh") }, [2] = target })
	assertClaimed(record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM, s = "notes" })))
	assert(#record.switches == 1 and record.switches[1] == 2, "switched to the named session")
	assert(#record.toasts == 0 and #record.focuses == 0, "nothing is claimed before the panes are looked at again")
	record.advance(300)
	assert(#record.focuses == 0 and #record.toasts == 0, "the first look finds the new session still empty")
	table.insert(target, pane(7, TITLE, CWD, PROGRAM))
	record.advance(300)
	assert(#record.focuses == 1 and record.focuses[1] == 7, "the second look focuses it")
	assert(#record.toasts == 0, "success is silent")
	record.advance(5000)
	assert(#record.switches == 1 and #record.focuses == 1 and #record.toasts == 0 and record.live() == 0,
		"the jump is over: no more timers, switches or toasts")
end)

test("a conversation that never appears gives exactly one final toast after three more looks", function()
	local record = sessionsWorld({ [1] = {}, [2] = {} })
	record.click(jumpUrl({ p = 7, t = TITLE, c = CWD, g = PROGRAM, s = "notes" }))
	assert(#record.switches == 1 and #record.toasts == 0)
	record.advance(299)
	assert(#record.toasts == 0, "nothing before the first timer")
	record.advance(1)
	assert(#record.toasts == 0, "after look 1")
	record.advance(300)
	assert(#record.toasts == 0, "after look 2")
	record.advance(300)
	assertNotFound(record)
	record.advance(10000)
	assertNotFound(record)
	assert(#record.switches == 1 and #record.focuses == 0 and record.live() == 0 and record.scheduled == 3,
		"three timers in all, one switch, no focus")
end)

test("the switch is made only to one unambiguous other session", function()
	-- No session name in the link: nothing to switch to.
	local bare = sessionsWorld({ [1] = {}, [2] = {} })
	bare.click(jumpUrl({ p = 7, t = TITLE }))
	assert(#bare.switches == 0 and bare.scheduled == 0)
	assertNotFound(bare)
	-- The named session is the current one, or unknown.
	local current = sessionsWorld({ [1] = {}, [2] = {} })
	current.click(jumpUrl({ p = 7, t = TITLE, s = "app" }))
	assert(#current.switches == 0)
	assertNotFound(current)
	local unknown = sessionsWorld({ [1] = {}, [2] = {} })
	unknown.click(jumpUrl({ p = 7, t = TITLE, s = "nothing" }))
	assert(#unknown.switches == 0)
	assertNotFound(unknown)
	-- Two other sessions with that name on hosts the link cannot tell apart.
	local twins = sessionsWorld({ [1] = {}, [2] = {}, [3] = {} }, { sessions = {
		{ id = 1, name = "app", host = 0, current = true }, { id = 2, name = "notes", host = 1 },
		{ id = 3, name = "notes", host = 2 } }, hosts = { { id = 0, name = "iPhone" }, { id = 1, name = "forge" },
		{ id = 2, name = "silver" } } })
	twins.click(jumpUrl({ p = 7, t = TITLE, h = "bronze", s = "notes" }))
	assert(#twins.switches == 0 and twins.scheduled == 0)
	assertNotFound(twins)
	-- The link's host picks one of them.
	local picked = sessionsWorld({ [1] = {}, [2] = {}, [3] = { pane(7, TITLE, "", "") } }, { sessions = {
		{ id = 1, name = "app", host = 0, current = true }, { id = 2, name = "notes", host = 1 },
		{ id = 3, name = "notes", host = 2 } }, hosts = { { id = 0, name = "iPhone" }, { id = 1, name = "Forge" },
		{ id = 2, name = "SILVER" } } })
	picked.click(jumpUrl({ p = 7, t = TITLE, h = "silver", s = "notes" }))
	assert(picked.switches[1] == 3)
	picked.advance(300)
	assert(picked.focuses[1] == 7)
	-- Otherwise the host that has the queue block does.
	local queue = pane(1 * TAG + 40, "Attention queue", "", nil, { kind = "plugin", block = "attention.queue" })
	local viaQueue = sessionsWorld({ [1] = { queue }, [2] = {}, [3] = { pane(7, TITLE, "", "") } }, { sessions = {
		{ id = 1, name = "app", host = 0, current = true }, { id = 2, name = "notes", host = 2 },
		{ id = 3, name = "notes", host = 1 } }, hosts = { { id = 0, name = "iPhone" }, { id = 1, name = "a" }, { id = 2, name = "b" } } })
	viaQueue.click(jumpUrl({ p = 7, t = TITLE, h = "unknown", s = "notes" }))
	assert(viaQueue.switches[1] == 3, "the queue block's host slot picks the session")
	-- Glyphs and spacing in the session name do not matter either.
	local glyph = sessionsWorld({ [1] = {}, [2] = { pane(7, TITLE, "", "") } })
	glyph.click(jumpUrl({ p = 7, t = TITLE, s = GLYPH .. "  notes " }))
	assert(glyph.switches[1] == 2)
end)

test("a failing session switch or lookup ends in the one not-found toast", function()
	local record = sessionsWorld({ [1] = {}, [2] = {} })
	function record.cx.sessions:switch() error("no such session") end
	record.click(jumpUrl({ p = 7, t = TITLE, s = "notes" }))
	assertNotFound(record)
	assert(record.scheduled == 0)
	local broken = sessionsWorld({ [1] = {}, [2] = {} })
	function broken.cx.sessions:list() error("listing exploded") end
	broken.click(jumpUrl({ p = 7, t = TITLE, s = "notes" }))
	assertNotFound(broken)
end)

test("a match found after the switch that is parked or ambiguous is reported once", function()
	local parked = sessionsWorld({ [1] = {}, [2] = { pane(7, TITLE, CWD, PROGRAM, { parked = true, tab = nil }) } })
	parked.click(jumpUrl({ p = 7, t = TITLE, s = "notes" }))
	parked.advance(300)
	assert(#parked.focuses == 0 and #parked.toasts == 1 and lastToast(parked).text == "That conversation is parked")
	parked.advance(5000)
	assert(#parked.toasts == 1 and parked.live() == 0)
	local several = sessionsWorld({ [1] = {}, [2] = { pane(1, TITLE, "", ""), pane(2, TITLE, "", "") } })
	several.click(jumpUrl({ p = 7, t = TITLE, s = "notes" }))
	several.advance(300)
	assert(#several.focuses == 0 and #several.toasts == 1 and lastToast(several).text == SEVERAL)
end)

test("a newer tap supersedes a jump that is still waiting", function()
	local target = {}
	local record = sessionsWorld({ [1] = { pane(7, "Here", "", "") }, [2] = target })
	record.click(jumpUrl({ p = 9, t = "Elsewhere", s = "notes" }))
	assert(#record.switches == 1 and record.live() == 1)
	record.advance(300)
	-- A tap on a conversation the current (switched-to) session shows decides the outcome alone.
	table.insert(target, pane(5, "Here too", "", ""))
	record.click(jumpUrl({ p = 5, t = "Here too" }))
	assert(record.focuses[1] == 5 and #record.focuses == 1, "the newer tap focuses at once")
	assert(record.live() == 0, "the older jump's timer is cancelled")
	record.advance(10000)
	assert(#record.toasts == 0 and #record.focuses == 1, "the older jump never speaks again")
	-- A newer cross-session tap replaces the older one's retries.
	local again = sessionsWorld({ [1] = {}, [2] = {} })
	again.click(jumpUrl({ p = 1, t = "First", s = "notes" }))
	again.advance(300)
	again.click(jumpUrl({ p = 2, t = "Second", s = "app" }))
	again.advance(10000)
	assert(#again.toasts == 1 and lastToast(again).text == NOT_FOUND, "only the newest jump reports, once")
end)

test("a timer fired for a superseded jump does nothing even when not cancelled", function()
	local record = sessionsWorld({ [1] = {}, [2] = { pane(5, "Here", "", "") } })
	record.click(jumpUrl({ p = 9, t = "Elsewhere", s = "notes" }))
	local stale = record.timers[1]
	record.click(jumpUrl({ p = 5, t = "Here" }))
	stale.fn(record.cx)
	assert(#record.focuses == 1 and #record.toasts == 0 and record.live() == 0)
end)

test("a timer without a window context ends the jump quietly", function()
	local record = sessionsWorld({ [1] = {}, [2] = {} })
	record.click(jumpUrl({ p = 9, t = TITLE, s = "notes" }))
	record.timers[1].fn(nil)
	assert(#record.toasts == 0 and record.scheduled == 1, "no toast and no further look")
end)

-- Hostile links. A pane that would match a well-formed link is on screen so a parser that guessed
-- instead of refusing would focus it.
local GOOD = { pane(7, TITLE, CWD, PROGRAM), pane(0, "x", "y", "z") }
local function good(replace)
	local fields = { p = "7", h = "forge", t = enc(TITLE), c = enc(CWD), g = enc(PROGRAM) }
	for key, value in pairs(replace or {}) do fields[key] = value end
	local parts = {}
	for _, key in ipairs({ "p", "h", "t", "c", "g", "s" }) do
		if fields[key] ~= nil and fields[key] ~= false then table.insert(parts, key .. "=" .. fields[key]) end
	end
	return "attention://jump?" .. table.concat(parts, "&")
end

local HOSTILE = {
	{ "huge", "attention://jump?p=7&h=forge&t=" .. string.rep("a", 20000) .. "&c=" .. enc(CWD) .. "&g=omp" },
	{ "huge title that would match", good({ t = string.rep("%41", 600) }) },
	{ "bare percent", good({ t = "%" }) },
	{ "half escape", good({ t = "ab%4" }) },
	{ "non-hex escape", good({ t = "%zz" }) },
	{ "escape of escape", good({ t = "%2%35" }) },
	{ "missing pane", good({ p = false }) },
	{ "missing host", good({ h = false }) },
	{ "missing title", good({ t = false }) },
	{ "empty title", good({ t = "" }) },
	{ "alpha pane", good({ p = "abc" }) },
	{ "negative pane", good({ p = "-7" }) },
	{ "float pane", good({ p = "7.5" }) },
	{ "exponent pane", good({ p = "7e0" }) },
	{ "hex pane", good({ p = "0x7" }) },
	{ "spaced pane", good({ p = "%207" }) },
	{ "17 digit pane", good({ p = "12345678901234567" }) },
	{ "past 2^53 pane", good({ p = "9007199254740993" }) },
	{ "empty pane", good({ p = "" }) },
	{ "nul in title", good({ t = "%00" }) },
	{ "newline in title", good({ t = enc("a\nb") }) },
	{ "invalid utf8", good({ t = "%ff%fe" }) },
	{ "invalid utf8 in cwd", good({ c = "%ff" }) },
	{ "invalid utf8 in session", good({ s = "%ff" }) },
	{ "raw newline", good() .. "\n" },
	{ "raw space", good({ t = "a b" }) },
	{ "raw control", good({ t = "a\1b" }) },
	{ "raw non-ascii", good({ t = "é" }) },
	{ "duplicate pane", good() .. "&p=8" },
	{ "duplicate session", good({ s = "a" }) .. "&s=b" },
	{ "fragment", good() .. "#x" },
	{ "field without equals", good() .. "&junk" },
	{ "no query", "attention://jump" },
	{ "empty query", "attention://jump?" },
	{ "unknown path", "attention://nothing?p=7" },
	{ "path traversal", "attention://jump/../ping?p=7" },
	{ "scheme only", "attention://" },
	{ "ping with query", "attention://ping?x=1" },
	{ "uppercase path", "ATTENTION://JUMP?p=7&h=forge&t=a&c=b&g=c" },
	{ "encoded pane digits", good({ p = "%37" }) },
	{ "unknown field", good() .. "&z=1" },
	{ "empty field part", good() .. "&&" },
	{ "equals inside a value", good({ t = "a=b" }) },
	{ "raw plus", good({ t = "a+b" }) },
	{ "raw colon and slash", good({ c = "/tmp/a:b" }) },
	{ "long title", good({ t = string.rep("a", 161) }) },
	{ "long cwd", good({ c = string.rep("a", 201) }) },
	{ "long program", good({ g = string.rep("a", 65) }) },
	{ "long session", good({ s = string.rep("a", 65) }) },
}

-- Some hostile samples are refused as malformed, others parse but carry no usable title; none of them may focus
-- anything or switch session.
test("hostile links are claimed, never throw and never focus", function()
	for _, case in ipairs(HOSTILE) do
		local record = world(GOOD)
		local ok, decision = pcall(record.click, case[2])
		assert(ok, case[1] .. " threw: " .. tostring(decision))
		assertClaimed(decision)
		assert(#record.focuses == 0, case[1] .. " must not focus")
		assert(#record.switches == 0 and record.scheduled == 0, case[1] .. " must not switch session")
		assert(#record.toasts >= 1 and lastToast(record).level ~= "success", case[1] .. " must be reported")
	end
end)

test("the same panes accept the well-formed twin of every hostile case", function()
	local record = world(GOOD)
	record.click(good())
	assert(record.focuses[1] == 7, "the control link focuses; the hostile ones above differ only in their defect")
end)

test("garbage in the optional evidence is tolerated, the title still decides", function()
	for label, url in pairs({
		["control characters in cwd"] = good({ c = "%1b%5b31m" }), ["del in program"] = good({ g = "%7f" }),
		["no cwd"] = good({ c = false }), ["no program"] = good({ g = false }), ["empty program"] = good({ g = "" }),
		["no cwd or program"] = good({ c = false, g = false }), ["a session name"] = good({ s = "app" }),
		["an empty session name"] = good({ s = "" }),
	}) do
		local record = world(GOOD)
		assertClaimed(record.click(url))
		assert(record.focuses[1] == 7 and #record.toasts == 0, label .. " must still find the pane by its title")
	end
end)

test("a link that is not an object or has no text is left to Tern", function()
	local record = world(GOOD)
	assert(record.click(nil) == nil)
	assert(#record.toasts == 0 and #record.focuses == 0)
end)

test("ping toasts that the link path works and focuses nothing", function()
	local record = world(GOOD)
	assertClaimed(record.click(phone.PING))
	assert(#record.focuses == 0)
	assert(#record.toasts == 1 and lastToast(record).text == "Attention phone link works")
	assert(lastToast(record).level == "success")
end)

test("other schemes and plain links are not claimed", function()
	for _, url in ipairs({ "https://example.com/attention://jump?p=7", "http://x", "file:///tmp/a", "/tmp/a",
			"mailto:a@b.c", "attention:ping", "attentions://ping", "xattention://ping", "", "ATTENTION" }) do
		local record = world(GOOD)
		assert(record.click(url) == nil, url .. " must fall through to Tern")
		assert(#record.toasts == 0 and #record.focuses == 0)
	end
end)

test("registers the queue and diagnostics palette commands in the Attention group", function()
	local record = world({})
	local command = record.commands.queue
	assert(command and command.title == "Attention queue" and command.group == "Attention")
	local diagnostics = record.commands.diagnostics
	assert(diagnostics and diagnostics.title == "Copy phone diagnostics" and diagnostics.group == "Attention")
	local count = 0
	for _ in pairs(record.commands) do count += 1 end
	assert(count == 2)
	assert(type(record.handlers.canvas_action) == "function")
end)

test("Attention queue opens the block in a tab when the host has it", function()
	local record = world({}, { blockTypes = { { kind = "omp.chat" }, { kind = "attention.queue" } } })
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 1 and record.blocks[1].kind == "attention.queue" and record.blocks[1].how == "tab")
	assert(#record.blocks[1].args == 0 and #record.toasts == 0)
end)

test("Attention queue explains a host without the block", function()
	local record = world({}, { blockTypes = { { kind = "omp.chat" } } })
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 0)
	assert(lastToast(record).text == "This host has no Attention queue block")
	local silent = world({}, { blockTypes = { { kind = "attention.queue" } }, newBlockFails = true })
	silent.commands.queue.run(silent.cx)
	assert(lastToast(silent).level == "error")
end)

local QUEUE_TYPES = { { kind = "omp.chat" }, { kind = "attention.queue" } }

local function queuePane(id, extra)
	local fields = { kind = "plugin", block = "attention.queue" }
	for key, field in pairs(extra or {}) do fields[key] = field end
	return pane(id, "Attention queue", "", nil, fields)
end

test("running the command again reuses the queue block it made", function()
	local record = world({}, { blockTypes = QUEUE_TYPES, focused = 3 })
	record.commands.queue.run(record.cx)
	record.commands.queue.run(record.cx)
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 1, "exactly one block is ever created")
	assert(#record.focuses == 2 and record.focuses[1] == 99 and record.focuses[2] == 99)
	assert(record.focused == 99 and #record.toasts == 0)
end)

test("an open queue block is focused, not duplicated", function()
	local record = world({ pane(3, "zsh", CWD, "zsh"), queuePane(40) }, { blockTypes = QUEUE_TYPES, focused = 3 })
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 0)
	assert(#record.focuses == 1 and record.focuses[1] == 40 and record.focused == 40)
	assert(#record.toasts == 0, "the palette command is silent on success")
	-- Reuse does not depend on the host listing the type any more.
	local bare = world({ queuePane(40) }, { blockTypes = {}, focused = 3 })
	bare.commands.queue.run(bare.cx)
	assert(#bare.blocks == 0 and bare.focused == 40 and #bare.toasts == 0)
end)

test("other plugin blocks and plain panes are never mistaken for the queue", function()
	local record = world({
		pane(5, "Attention queue", "", nil, { kind = "plugin", block = "omp.chat" }),
		pane(6, "Attention queue", "", nil, { kind = "terminal" }),
		pane(7, "attention.queue", "", nil, { kind = "plugin" }),
	}, { blockTypes = QUEUE_TYPES, focused = 5 })
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 1 and #record.focuses == 0)
end)

test("the queue on the host being viewed is preferred", function()
	local record = world({
		pane(3 * TAG + 5, "zsh", CWD, "zsh"), queuePane(2 * TAG + 40), queuePane(3 * TAG + 41), queuePane(4 * TAG + 42),
	}, { blockTypes = QUEUE_TYPES, focused = 3 * TAG + 5 })
	record.commands.queue.run(record.cx)
	assert(#record.blocks == 0 and #record.focuses == 1 and record.focuses[1] == 3 * TAG + 41)
	-- With none on this host, a queue elsewhere is reused rather than a second one created.
	local elsewhere = world({ pane(3 * TAG + 5, "zsh", CWD, "zsh"), queuePane(2 * TAG + 40) },
		{ blockTypes = QUEUE_TYPES, focused = 3 * TAG + 5 })
	elsewhere.commands.queue.run(elsewhere.cx)
	assert(#elsewhere.blocks == 0 and elsewhere.focuses[1] == 2 * TAG + 40)
	-- A visible queue elsewhere beats a parked one on this host.
	local mixed = world({
		pane(3 * TAG + 5, "zsh", CWD, "zsh"), queuePane(3 * TAG + 41, { parked = true, tab = nil }), queuePane(2 * TAG + 40),
	}, { blockTypes = QUEUE_TYPES, focused = 3 * TAG + 5 })
	mixed.commands.queue.run(mixed.cx)
	assert(#mixed.blocks == 0 and mixed.focuses[1] == 2 * TAG + 40 and #mixed.toasts == 0)
end)

test("a parked queue is reported and neither focused nor replaced", function()
	local record = world({ queuePane(40, { parked = true, tab = nil }) }, { blockTypes = QUEUE_TYPES, focused = 3 })
	record.commands.queue.run(record.cx)
	assert(#record.focuses == 0 and #record.blocks == 0)
	assert(#record.toasts == 1)
	assert(lastToast(record).level == "info"
		and lastToast(record).text == "The Attention queue is parked on your Mac. Restore it from Parked panes.")
	local tapped = world({ queuePane(40, { parked = true, tab = nil }) }, { blockTypes = QUEUE_TYPES, focused = 3 })
	assert(tapped.canvasAction({ owner = "attention", act = "section:attention", pane = 12, node = "n" }) == true)
	assert(#tapped.focuses == 0 and #tapped.blocks == 0)
	assert(lastToast(tapped).text == "The Attention queue is parked on your Mac. Restore it from Parked panes.")
end)

test("a focus that does not stick on the queue is an error", function()
	local record = world({ queuePane(40) }, { blockTypes = QUEUE_TYPES, focused = 3, focusFails = true })
	record.commands.queue.run(record.cx)
	assert(#record.focuses == 1 and #record.blocks == 0)
	assert(lastToast(record).level == "error")
end)

test("a tap on the mirrored rail opens the working queue and is consumed", function()
	local record = world({ queuePane(40) }, { blockTypes = QUEUE_TYPES, focused = 3 })
	local taken = record.canvasAction({ owner = "attention", act = "section:working", pane = 12, node = "rail.working",
		text = "Working 2", mods = {} })
	assert(taken == true)
	assert(#record.focuses == 1 and record.focuses[1] == 40 and record.focused == 40 and #record.blocks == 0)
	assert(#record.toasts == 1 and lastToast(record).level == "info" and lastToast(record).text == "Attention queue")
	local fresh = world({}, { blockTypes = QUEUE_TYPES, focused = 3 })
	assert(fresh.canvasAction({ owner = "attention", act = "x", pane = 1, node = "n" }) == true)
	assert(fresh.canvasAction({ owner = "attention", act = "y", pane = 1, node = "n" }) == true)
	assert(#fresh.blocks == 1, "repeated taps create one block at most")
	local without = world({}, { blockTypes = { { kind = "omp.chat" } }, focused = 3 })
	assert(without.canvasAction({ owner = "attention", act = "x", pane = 1, node = "n" }) == true)
	assert(#without.blocks == 0 and lastToast(without).text == "This host has no Attention queue block")
end)

test("clicks owned by another plugin are left alone", function()
	for _, owner in ipairs({ "carly", "attention-phone", "Attention", "attention ", "" }) do
		local record = world({ queuePane(40) }, { blockTypes = QUEUE_TYPES, focused = 3 })
		assert(record.canvasAction({ owner = owner, act = "go", pane = 1, node = "n" }) == false, owner)
		assert(#record.focuses == 0 and #record.blocks == 0 and #record.toasts == 0, owner)
	end
end)

test("hostile canvas events never throw and do nothing", function()
	local hostile = { "attention", 5, true, {}, { owner = 5 }, { owner = {} }, { owner = true }, { act = "x" },
		{ owner = "attention", [1] = 2 } }
	for index, ev in ipairs(hostile) do
		local record = world({ queuePane(40) }, { blockTypes = QUEUE_TYPES, focused = 3 })
		local ok, taken = pcall(record.canvasAction, ev)
		assert(ok, "event " .. index .. " threw: " .. tostring(taken))
		if type(ev) == "table" and ev.owner == "attention" then
			assert(taken == true)
		else
			assert(taken == false and #record.focuses == 0 and #record.blocks == 0 and #record.toasts == 0,
				"event " .. index .. " must be ignored")
		end
	end
	local ok, taken = pcall(world({}).handlers.canvas_action, nil, nil)
	assert(ok and taken == false, "a nil event is ignored")
	-- Even a broken inventory on a genuine tap is contained and still consumes the click.
	local broken = world({}, { panesFail = true, blockTypes = QUEUE_TYPES })
	local fine, consumed = pcall(broken.canvasAction, { owner = "attention", act = "x", pane = 1, node = "n" })
	assert(fine and consumed == true and lastToast(broken).level == "error")
	local noCx = world({}).handlers.canvas_action
	local safe, answer = pcall(noCx, { owner = "attention", act = "x", pane = 1, node = "n" }, nil)
	assert(safe and answer == true, "a missing cx is contained")
end)

test("a very large inventory still resolves one pane", function()
	local panes = {}
	for index = 1, 3000 do panes[index] = pane(4 * TAG + index, "Chat " .. index, CWD, PROGRAM) end
	local record = world(panes)
	record.click(jumpUrl({ p = 1234, t = "Chat 1234", c = CWD, g = PROGRAM }))
	assert(record.focuses[1] == 4 * TAG + 1234)
end)

-- Diagnostics: what the phone sees, as plain text on the clipboard.
local function report(record)
	record.commands.diagnostics.run(record.cx)
	assert(#record.copies >= 1, "the report was copied")
	return record.copies[#record.copies]
end

local function hasPrivateUse(text)
	for _, cp in utf8.codes(text) do
		if (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000 then return true end
	end
	return false
end

local function paneLines(text)
	local count = 0
	for line in string.gmatch(text, "[^\n]+") do
		if string.find(line, "^  %d+ %d+ ") then count += 1 end
	end
	return count
end

test("diagnostics copies a report and says so", function()
	local record = sessionsWorld({ [1] = { pane(3, "zsh", "/", "/bin/zsh"), pane(2 * TAG + 12, GLYPH .. " " .. TITLE, "", "omp") },
		[2] = {} }, { hosts = { { id = 0, name = "iPhone", kind = "local", state = "connected", current = true },
		{ id = 2, name = "forge", kind = "remote", state = "connected" } } })
	local text = report(record)
	assert(#record.copies == 1 and #record.toasts == 1, "one copy, one toast")
	assert(lastToast(record).level == "success" and lastToast(record).text == "Diagnostics copied")
	assert(#text <= 8192, "within 8 KB")
	assert(string.find(text, "package %d+%.%d+%.%d+"), "the package version")
	assert(string.find(text, 'os "ios"', 1, true), "the operating system")
	assert(string.find(text, 'name "iPhone"', 1, true) == nil and string.find(text, 'name="iPhone"', 1, true), "host names")
	assert(string.find(text, 'name="forge"', 1, true) and string.find(text, 'name="notes"', 1, true), "remote host and sessions")
	assert(string.find(text, "current session id=1", 1, true), "the current session")
	assert(string.find(text, "panes: 2 total; per host slot (pane // 2^44): 0=1 2=1", 1, true), "pane totals per host slot")
	assert(string.find(text, "last jump: none", 1, true), "no jump yet")
	assert(string.find(text, '"\\uE743 ' .. TITLE .. '"', 1, true), "the glyph is escaped, the rest of the title is readable")
	assert(not hasPrivateUse(text), "no private-use character survives into the report")
end)

test("diagnostics shows both private-use planes escaped", function()
	local record = world({ pane(7, GLYPH .. GLYPH2 .. " x", "/c" .. GLYPH, "p") })
	local text = report(record)
	assert(string.find(text, "\\uE743\\uF009A x", 1, true) and string.find(text, "/c\\uE743", 1, true))
	assert(not hasPrivateUse(text))
end)

test("diagnostics records the last jump: wanted evidence and counts at every stage", function()
	local record = sessionsWorld({
		[1] = { pane(5 * TAG + 9, TITLE, "/a", "zsh"), pane(6 * TAG + 9, TITLE, "/b", "zsh"), pane(7, "Other", "", "") },
		[2] = {} })
	record.click(jumpUrl({ p = 77, h = "Ada's Mac", t = GLYPH .. " " .. TITLE, c = CWD, g = PROGRAM, s = "app" }))
	local text = report(record)
	assert(string.find(text, "last jump: wanted pane=77 (id 77, slot 0)", 1, true), "the wanted pane")
	assert(string.find(text, 'host="Ada\'s Mac"', 1, true) and string.find(text, 'session="app"', 1, true), "host and session")
	assert(string.find(text, 'title="\\uE743 ' .. TITLE .. '"', 1, true), "the wanted title, escaped")
	assert(string.find(text, 'normalized="' .. TITLE .. '"', 1, true), "and as it was compared")
	assert(string.find(text, 'cwd="' .. CWD .. '" program="omp"', 1, true), "the optional evidence")
	assert(string.find(text, "title-matches=2 after-id=2 after-cwd=2 after-program=2 -> several", 1, true), "counts per stage")
	assert(string.find(text, "result: several panes match", 1, true), "the outcome")
	local found = world({ pane(7, TITLE, CWD, PROGRAM) })
	found.click(jumpUrl({ p = 7, t = TITLE }))
	local foundText = report(found)
	assert(string.find(foundText, "title-matches=1 after-id=1 after-cwd=1 after-program=1 -> match", 1, true))
	assert(string.find(foundText, "result: focused", 1, true))
	local crossed = sessionsWorld({ [1] = {}, [2] = {} })
	crossed.click(jumpUrl({ p = 7, t = TITLE, s = "notes" }))
	crossed.advance(2000)
	local crossedText = report(crossed)
	assert(string.find(crossedText, 'session switch: to session id 2 "notes"', 1, true), "the switch")
	assert(string.find(crossedText, "attempt 4:", 1, true) and not string.find(crossedText, "attempt 5:", 1, true),
		"one look at the tap and three after the switch")
	assert(string.find(crossedText, "result: not found after switching session", 1, true))
end)

test("diagnostics stays within 8 KB and 120 characters per string however much there is", function()
	local panes = {}
	for index = 1, 3000 do
		panes[index] = pane(4 * TAG + index, string.rep("a", 500), string.rep("b", 500), string.rep("c", 500))
	end
	local record = world(panes, { sessions = { { id = 1, name = string.rep("s", 400), host = 0, current = true } },
		hosts = { { id = 0, name = string.rep("h", 400), kind = "local" } } })
	record.click(jumpUrl({ p = 1, t = "Nothing", s = string.rep("s", 64) }))
	local text = report(record)
	assert(#text <= 8192, "the report is " .. #text .. " bytes")
	assert(not string.find(text, string.rep("a", 121)) and not string.find(text, string.rep("b", 121))
		and not string.find(text, string.rep("c", 121)) and not string.find(text, string.rep("s", 121))
		and not string.find(text, string.rep("h", 121)), "every string is cut at 120 characters")
	assert(string.find(text, "…", 1, true), "a cut string says so")
	assert(paneLines(text) <= 60, "at most 60 panes are listed")
	assert(string.find(text, "panes: 3000 total", 1, true), "the real total is still reported")
	local wide = {}
	for index = 1, 40 do wide[index] = pane(4 * TAG + index, "Chat " .. index, "/Users/me/work/app", "/bin/zsh") end
	local roomy = report(world(wide))
	assert(#roomy <= 8192 and paneLines(roomy) == 40, "ordinary panes are all listed")
end)

test("diagnostics lists the panes closest to the wanted title first", function()
	local panes = {}
	for index = 1, 200 do panes[index] = pane(index, "Chat " .. index, "/", "zsh") end
	panes[150] = pane(150, GLYPH .. " " .. TITLE, "", "")
	panes[170] = pane(170, TITLE .. " (old)", "", "")
	local record = world(panes)
	record.click(jumpUrl({ p = 1, t = TITLE }))
	local text = report(record)
	local first, second = string.find(text, TITLE .. "\"", 1, true), string.find(text, TITLE .. " (old)", 1, true)
	assert(first and second and first < second, "the exact title leads, the near one follows")
	assert(string.find(text, "Chat 1\"", 1, true) == nil or string.find(text, "Chat 1\"", 1, true) > second,
		"unrelated panes come after")
	assert(paneLines(text) == 60)
end)

test("diagnostics escapes control characters so a title cannot forge report lines", function()
	local record = world({ pane(7, "x\nlast jump: none\27[31m", "/c\r\nhosts: 9", "p") })
	local text = report(record)
	assert(not string.find(text, "\27", 1, true) and not string.find(text, "\r", 1, true), "no control bytes")
	local count = 0
	for line in string.gmatch(text, "[^\n]+") do
		if string.find(line, "^last jump: none") then count += 1 end
		assert(not string.find(line, "^hosts: 9"), "a forged line")
	end
	assert(count == 1, "only the real last-jump line")
	assert(string.find(text, "x\\x0Alast jump: none\\x1B[31m", 1, true), "the title shows escaped")
end)

test("diagnostics survives odd inventory entries and unavailable facilities", function()
	local record = world({ "junk", 5, { pane = "x" }, { pane = 6 }, { pane = 7, title = 5, cwd = {}, program = true },
		{ pane = 8, title = "bad\255" .. string.rep("z", 300) }, pane(9, TITLE, CWD, PROGRAM) })
	function record.cx.hosts:list() error("no hosts here") end
	function record.cx.sessions:list() error("no sessions here") end
	local text = report(record)
	assert(string.find(text, "hosts: unavailable", 1, true) and string.find(text, "sessions: unavailable", 1, true))
	assert(string.find(text, "\\xFF", 1, true), "bytes that are not text show as hex")
	assert(string.find(text, TITLE, 1, true), "the ordinary pane is still listed")
	local broken = world({}, { panesFail = true })
	assert(string.find(report(broken), "panes: unavailable", 1, true), "an inventory that raises is reported, not thrown")
	assert(lastToast(broken).text == "Diagnostics copied")
end)

test("diagnostics that cannot reach the clipboard say so", function()
	local record = world({ pane(7, TITLE, CWD, PROGRAM) }, { copyFails = true })
	record.commands.diagnostics.run(record.cx)
	assert(#record.copies == 0 and #record.toasts == 1 and lastToast(record).level == "error")
	assert(lastToast(record).text == "Couldn't copy the diagnostics" and lastToast(record).sub ~= nil)
end)

-- Cross-check with the host side: phone.jumpUrl and the package's own parser must agree on every
-- sample, including text that needs escaping.
local function loaded()
	return bootstrap({ route = { link = function() end }, command = function() end, on = function() end })
end

local function parseWith(url)
	return loaded().parseJump(url)
end

local function same(a, b)
	return a.pane == b.pane and a.host == b.host and a.title == b.title and a.cwd == b.cwd and a.program == b.program
		and a.session == b.session
end

local function row(fields)
	local value = { serial = 1, workId = "w", section = "attention", session = "notes", title = "t", host = "forge",
		localHost = false, pane = 41, paneTitle = TITLE, cwd = CWD, program = PROGRAM, placement = "tiled",
		jumpable = true, clock = { recorded = false } }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

test("phone.jumpUrl output parses identically in the package and in phone.parseJump", function()
	local samples = {
		row(), row({ paneTitle = "a&b=c#d?e%f+g h/i" }), row({ cwd = "/Users/me/My Projects/ünï cödé/日本語" }),
		row({ paneTitle = "🚀 deploy ✅" }), row({ paneTitle = "tab\tinside" }), row({ paneTitle = "%41%zz%" }),
		row({ host = "Ada's MacBook Pro" }), row({ program = "node 22" }), row({ pane = 3 * TAG + 41 }),
		row({ pane = 9007199254740991 }), row({ cwd = "/" }), row({ paneTitle = string.rep("x", 160) }),
		row({ paneTitle = "line\nbreak" }), row({ paneTitle = "nul\0byte" }), row({ paneTitle = "\27[31mred" }),
		row({ session = "Ada's ünï session & co" }), row({ session = "" }), row({ cwd = "", program = "" }),
		row({ paneTitle = "\u{E743} Task: complete the release checklist" }),
	}
	local compared = 0
	for _, sample in ipairs(samples) do
		local url = phone.jumpUrl(sample)
		if url ~= nil then
			assert(#url <= 1500)
			local mine, theirs = parseWith(url), phone.parseJump(url)
			assert((mine == nil) == (theirs == nil), "parsers disagree on acceptance of " .. url)
			if mine ~= nil then
				assert(same(mine, theirs), "parsers disagree on fields of " .. url)
				assert(mine.pane == sample.pane and mine.title == sample.paneTitle and mine.cwd == sample.cwd
					and mine.program == sample.program and mine.host == sample.host and mine.session == sample.session,
					"round trip lost data for " .. url)
			end
			compared += 1
		end
	end
	assert(compared >= 15, "most samples must be jumpable so the check is not vacuous")
end)

test("the package and phone.parseJump agree on every hostile link", function()
	local accepted = 0
	for _, case in ipairs(HOSTILE) do
		local mine, theirs = parseWith(case[2]), phone.parseJump(case[2])
		assert((mine == nil) == (theirs == nil), case[1] .. ": parsers disagree on acceptance")
		if mine ~= nil then
			assert(same(mine, theirs), case[1] .. ": parsers disagree on fields")
			accepted += 1
		end
	end
	assert(accepted >= 3, "samples that only lack evidence still parse, so agreement covers the accept path too")
	for _, url in ipairs({ good({ s = "app" }), good({ s = false }), good({ s = "a%20b" }), good({ s = string.rep("s", 65) }),
			good({ s = "%ff" }), good({ s = "a" }) .. "&s=b", good({ t = false, c = false, g = false }) }) do
		local mine, theirs = parseWith(url), phone.parseJump(url)
		assert((mine == nil) == (theirs == nil), url .. ": parsers disagree on acceptance")
		if mine ~= nil then assert(same(mine, theirs), url .. ": parsers disagree on fields") end
	end
	assert(parseWith(good()) ~= nil and phone.parseJump(good()) ~= nil)
	assert(parseWith(phone.PING) == nil and phone.parseJump(phone.PING) == nil)
end)

test("the package and phone.matchTitle normalize every sample alike", function()
	local api = loaded()
	local samples = {
		"", " ", "plain", " lead", "trail ", "two  spaces", "a\tb\nc", "\u{E743} glyph", "glyph \u{F009A}", "\u{E000}", "\u{F8FF}x",
		"\u{F900}x", "\u{FFFFD}", "\u{10FFFF}y", "\u{A0}nbsp\u{A0}", "日本語 \u{F009A}x", "\0", "bad\255", "\u{3000}x\u{3000}y",
		"\u{2028}a\u{2029}b", "\u{200B}zero", string.rep("é", 300), "Case", "case", "a \u{E743} b", "\127del",
	}
	for _, sample in ipairs(samples) do
		assert(api.normalize(sample) == phone.matchTitle(sample), "normalizers disagree on " .. string.format("%q", sample))
	end
	assert(api.normalize(nil) == "" and phone.matchTitle(nil) == "", "not text")
	assert(api.normalize("a \u{E743} b") == "a b", "a glyph between spaces leaves one space")
end)

print("Attention phone package checks passed")
return true
