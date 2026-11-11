local bootstrap = require("../host")
local phone = require("../phone")

local NOW = 1_800_000_000
local PATH = "/data/" .. phone.FILE

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = copy(item) end
	return result
end

local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in a do if not equal(value, b[key]) then return false end end
	for key in b do if a[key] == nil then return false end end
	return true
end

-- A field value that removes the field (Lua tables cannot hold nil).
local NONE = {}

-- Rows and snapshots as the owner window publishes them (phone-contract.md, "Snapshot file").
local function row(serial, section, fields)
	local base = { serial = serial, workId = "work-" .. serial, section = section, session = "app", tab = "release prep",
		title = "Review the API " .. serial, state = "Waiting for input", clock = { kind = "asked", atUtc = NOW - 720, recorded = true },
		host = "Ada's MacBook Pro", localHost = true, pane = 40 + serial, paneTitle = "Review the API " .. serial,
		cwd = "/work/api", program = "omp", placement = "tiled", jumpable = true }
	for key, value in fields or {} do base[key] = if value == NONE then nil else value end
	return base
end

local function snapshot(rows, fields)
	local result = { schema = 2, revision = 1, generatedUtc = NOW, status = "ok", host = "Ada's MacBook Pro", rows = rows }
	local counts = { attention = 0, working = 0 }
	for _, item in rows do counts[item.section] += 1 end
	result.counts = counts
	for key, value in fields or {} do result[key] = value end
	return result
end

-- The fake host: only the `tern` boundary is fake; the block definition runs unchanged.
local function newWorld()
	local world = { utc = NOW, ms = 0, files = {}, docs = {}, timers = {}, panes = { [7] = true }, opened = {}, toasts = {},
		renders = 0, reads = 0, published = 0, warnings = {} }
	local sdk = { plugin = { data = "/data" }, fs = {}, json = {}, log = {}, pane = {}, block = {}, ui = {} }
	function sdk.now() return world.ms end
	function sdk.timer(ms, fn)
		local timer = { due = world.ms + ms, fn = fn, live = true }
		table.insert(world.timers, timer)
		return { cancel = function() timer.live = false end }
	end
	function sdk.fs.exists(path) return world.files[path] ~= nil end
	function sdk.fs.read(path, limit)
		world.reads += 1
		local text = world.files[path]
		assert(text ~= nil, "read of a missing file")
		if limit and #text > limit then error("file exceeds max_bytes") end
		return text
	end
	function sdk.json.decode(text)
		local document = world.docs[text]
		if document == nil then error("invalid JSON") end
		return copy(document)
	end
	function sdk.log.warn(...) table.insert(world.warnings, table.concat({ ... }, " ")) end
	function sdk.pane.list()
		local list = {}
		for pane in world.panes do table.insert(list, { pane = pane }) end
		return list
	end
	function sdk.block.define(id, def) world.id, world.def = id, def end
	local ui = sdk.ui
	function ui.span(text, style)
		local span = { t = text }
		if style ~= nil then span.s = style end
		return span
	end
	function ui.node(kind, props, children)
		local node = { k = kind }
		if props and next(props) then node.p = props end
		if children and #children > 0 then node.c = children end
		return node
	end
	function ui.badge(text, tone) return { k = "badge", p = { text = text, tone = tone } } end

	function world:publish(document)
		self.published += 1
		local token = "snapshot:" .. self.published
		self.docs[token] = copy(document)
		self.files[PATH] = token
	end
	-- Text that decodes to nothing: a partial or corrupt write.
	function world:publishText(text) self.files[PATH] = text end
	function world:heartbeat()
		local current = copy(self.docs[self.files[PATH]])
		current.generatedUtc = self.utc
		self:publish(current)
	end
	function world:advance(ms)
		local target = self.ms + ms
		while true do
			local next_ = nil
			for _, timer in self.timers do
				if timer.live and timer.due <= target and (next_ == nil or timer.due < next_.due) then next_ = timer end
			end
			if next_ == nil then break end
			self.utc += (next_.due - self.ms) / 1000
			self.ms = next_.due
			next_.live = false
			next_.fn()
		end
		self.utc += (target - self.ms) / 1000
		self.ms = target
	end
	function world:liveTimers()
		local count = 0
		for _, timer in self.timers do if timer.live then count += 1 end end
		return count
	end
	bootstrap(sdk, function() return world.utc end)
	assert(world.id == "queue" and world.def, "the block must define manifest block `queue`")
	return world
end

local function spansText(spans)
	if type(spans) == "string" then return spans end
	if type(spans) ~= "table" then return "" end
	if spans.t then return spans.t end
	local parts = {}
	for _, span in spans do table.insert(parts, spansText(span)) end
	return table.concat(parts)
end

local function ownText(node)
	local p = node.p or {}
	if node.k == "tabs" then
		local parts = {}
		for _, item in p.items do table.insert(parts, spansText(item.label)) end
		return table.concat(parts, "  ")
	end
	if p.spans then return spansText(p.spans) end
	if p.text then return p.text end
	return nil
end

local function textBelow(node)
	local parts = { ownText(node) or "" }
	for _, item in node.c or {} do table.insert(parts, textBelow(item)) end
	return table.concat(parts)
end

local function walk(node, visit)
	visit(node)
	for _, child in node.c or {} do walk(child, visit) end
end

local function child(node, key)
	for _, item in node.c or {} do
		if item.p and item.p.key == key then return item end
	end
	return nil
end

-- Node ids as the block worker names them: the region's name, then `<parent>.<key or 0-based index>`.
-- Two siblings with one key make the worker reject the whole view, so this raises on them too.
local function index(root, id, out)
	out[id] = root
	local seen = {}
	for position, item in root.c or {} do
		local key = if item.p and item.p.key ~= nil then tostring(item.p.key) else tostring(position - 1)
		assert(not seen[key], "duplicate child key " .. key .. " under " .. id)
		seen[key] = true
		index(item, id .. "." .. key, out)
	end
	return out
end

local function depth(node)
	local deepest = 0
	for _, item in node.c or {} do deepest = math.max(deepest, depth(item)) end
	return deepest + 1
end

-- Approximate wire size: enough to hold the whole tree against the 256 KiB cap.
local function weigh(value)
	if type(value) == "table" then
		local total = 2
		for key, item in value do total += #tostring(key) + 3 + weigh(item) end
		return total
	end
	return #tostring(value) + 2
end

local function start(world, saved)
	local cx = { pane = 7 }
	function cx:render() world.renders += 1 end
	function cx:open(target) table.insert(world.opened, target) end
	function cx:toast(level, text, sub) table.insert(world.toasts, { level = level, text = text, sub = sub }) end
	local block = { world = world, cx = cx }
	block.state = world.def.init(cx, {}, saved)
	function block:view()
		local view = world.def.view(self.state, cx)
		local ids = index(view.main, "main", {})
		if view.dock then index(view.dock, "dock", ids) end
		return view, ids
	end
	function block:event(ev) world.def.event(self.state, ev, cx) end
	function block:title() return world.def.title(self.state) end
	function block:save() return world.def.save(self.state) end
	-- A pointer click on a node: the node's `actions.click` arrives as an action event.
	function block:click(id)
		local _, ids = self:view()
		local node = assert(ids[id], "no node " .. id)
		local click = assert(node.p and node.p.actions and node.p.actions.click, "node " .. id .. " is not clickable")
		local act, value = string.match(click, "^([^=]+)=(.*)$")
		self:event({ ev = "action", id = id, act = act or click, value = value })
	end
	function block:select(item) self:event({ ev = "select", id = "main.section", item = item }) end
	function block:texts()
		local view = self:view()
		local texts = {}
		for _, region in { view.main, view.dock } do
			walk(region, function(node)
				local text = ownText(node)
				if text then table.insert(texts, text) end
			end)
		end
		return texts
	end
	function block:allText() return table.concat(self:texts(), "\n") end
	function block:rows()
		local view = self:view()
		local list = child(view.main, "rows")
		local result = {}
		for _, node in (list and list.c) or {} do
			local top, meta = child(node, "top"), child(node, "meta")
			local who, clock, stateText, off = child(top, "who"), child(meta, "clock"), child(meta, "state"), child(meta, "off")
			table.insert(result, { node = node, serial = tonumber(string.match(node.p.actions.click, "^[^=]+=.-:(%d+):")),
				who = textBelow(who), title = ownText(child(node, "title")), clock = clock and ownText(clock),
				state = stateText and ownText(stateText), off = off and ownText(off), chevron = child(top, "go") ~= nil })
		end
		return result
	end
	function block:tabs()
		local view = self:view()
		local tabs = child(view.main, "section")
		return tabs
	end
	return block
end

local function rowNumbers(block)
	local serials = {}
	for _, item in block:rows() do table.insert(serials, item.serial) end
	return serials
end

local function sameList(a, b)
	if #a ~= #b then return false end
	for position, value in a do if b[position] ~= value then return false end end
	return true
end

local function contains(text, needle) return string.find(text, needle, 1, true) ~= nil end

local function containsInsensitive(text, needle)
	return string.find(string.lower(text), string.lower(needle), 1, true) ~= nil
end

-- No snapshot yet: one waiting line, no controls, the test button still there.
do
	local world = newWorld()
	local block = start(world)
	local text = block:allText()
	assert(contains(text, "Waiting for your Mac's Attention window"), "a missing snapshot must say what it waits for")
	assert(block:tabs() == nil and #block:rows() == 0, "no queue controls or rows before the first snapshot")
	assert(block:title() == nil, "an untitled block keeps the manifest title")
	assert(world.def.font == "sans", "the queue is an app surface and draws in the UI face")
	local _, ids = block:view()
	assert(ids["dock.tools.ping"], "the link test stays available before any snapshot")
	assert(#world.opened == 0 and #world.toasts == 0, "starting the block must not open anything")

	world:publish(snapshot({ row(1, "attention") }))
	world:advance(2000)
	assert(#block:rows() == 1 and world.renders == 1, "the first snapshot must render within one poll")
	assert(not contains(block:allText(), "Waiting for your Mac"), "the waiting line goes away with the snapshot")
end

-- Header, ordering and row facts: counts are the snapshot's denominators, not the row count.
do
	local world = newWorld()
	local rows = {
		row(3, "attention", { session = "app", tab = "release prep", title = "Fix the install" }),
		row(1, "attention", { session = "sori", tab = "sori", title = "Draft the changelog", state = "Idle",
			clock = { kind = "replied", atUtc = NOW - 90000, recorded = false } }),
		row(2, "working", { title = "Working thing", state = "Working" }),
	}
	world:publish(snapshot(rows, { counts = { attention = 4, working = 3 } }))
	local block = start(world)
	local tabs = block:tabs()
	assert(tabs and tabs.p.variant == "segmented" and tabs.p.active == "attention", "a segmented control starts on Attention")
	assert(ownText(tabs) == "Attention 4  Currently working 3", "tabs show both full conversation counts, not capped row counts")
	assert(block:title() == "Attention 4", "the pane title carries the Attention count")
	local shown = block:rows()
	assert(sameList(rowNumbers(block), { 3, 1 }), "Attention rows keep the desktop queue order and hide Working rows")
	assert(contains(shown[1].who, "app") and contains(shown[1].who, "release prep"), "a row names its session and tab")
	assert(shown[1].title == "Fix the install", "a row shows the conversation title")
	assert(shown[1].clock == phone.clockText(rows[1].clock, world.utc), "the clock chip uses the shared desktop wording")
	assert(shown[2].clock == phone.clockText(rows[2].clock, world.utc), "an estimated clock keeps its marker")
	assert(shown[1].state == "Waiting for input" and shown[2].state == "Idle", "a row carries its state words")
	assert(shown[1].chevron and shown[1].off == nil, "a jumpable row shows a jump affordance and no reason")
	assert(string.match(shown[1].node.p.actions.click, "^jump=attention:3:%d+$"), "a row tap identifies its displayed section and generation")
	assert(contains(block:allText(), "Ada's MacBook Pro"), "the header names the Mac")
	assert(contains(block:allText(), "Updated"), "the header says when the Mac last updated")
	assert(equal(block:view(), block:view()), "an unchanged state must produce an identical view")

	-- Section switch, saved state, restore.
	block:select("working")
	assert(sameList(rowNumbers(block), { 2 }) and block:rows()[1].title == "Working thing", "Currently working shows only its live rows")
	assert(equal(block:save(), { section = "working" }), "Currently working selection is saved")
	local restored = start(world, block:save())
	assert(restored:tabs().p.active == "working" and sameList(rowNumbers(restored), { 2 }), "a restart returns to the saved section")
	for _, bad in { { section = "reference" }, { section = 7 }, { section = "later" }, "working", 5 } do
		assert(start(world, bad):tabs().p.active == "attention", "unusable saved state falls back to Attention")
	end
	block:select("not-a-section")
	assert(block:tabs().p.active == "working", "an unknown section id must not change the selection")
end

-- Taps: jumpable rows open the jump URL; the others explain why not.
do
	local world = newWorld()
	local rows = {
		row(1, "attention", { title = "Open me" }),
		row(2, "attention", { title = "Parked one", placement = "parked", jumpable = false }),
		row(3, "attention", { title = "Closed one", pane = NONE, paneTitle = NONE, cwd = NONE, program = NONE, placement = NONE,
			state = "Offline · waiting for input", localHost = false, jumpable = false }),
		row(4, "attention", { title = "Paneless one", pane = NONE, paneTitle = NONE, cwd = NONE, program = NONE, placement = NONE,
			state = "Idle", jumpable = false }),
	}
	world:publish(snapshot(rows))
	local block = start(world)
	local shown = block:rows()
	assert(shown[1].chevron and not shown[2].chevron and not shown[3].chevron and not shown[4].chevron,
		"only openable rows carry the jump affordance")
	assert(containsInsensitive(shown[2].off, "parked") and containsInsensitive(shown[3].off, "offline")
		and containsInsensitive(shown[4].off, "pane"), "an unopenable row states why on its face")

	block:click("main.rows.r1")
	assert(#world.opened == 1 and world.opened[1] == phone.jumpUrl(rows[1]), "tapping a row opens its jump URL")
	local parsed = phone.parseJump(world.opened[1])
	assert(parsed and parsed.pane == rows[1].pane and parsed.title == rows[1].paneTitle and parsed.cwd == rows[1].cwd
		and parsed.program == rows[1].program and parsed.session == rows[1].session,
		"the opened URL carries the row's pane evidence and its session")
	assert(#world.toasts == 0, "a successful tap needs no toast")

	block:click("main.rows.r2")
	block:click("main.rows.r3")
	block:click("main.rows.r4")
	assert(#world.opened == 1, "unopenable rows must not open anything")
	assert(#world.toasts == 3, "each unopenable tap explains itself")
	for _, toast in world.toasts do assert(toast.level == "info", "the explanation is informational") end
	assert(containsInsensitive(world.toasts[1].text, "parked") and containsInsensitive(world.toasts[2].text, "offline")
		and containsInsensitive(world.toasts[3].text, "no open pane"), "each toast names its own reason")

	-- A row that left the queue between draw and tap.
	local before = #world.opened
	block:event({ ev = "action", id = "main.rows.r9", act = "jump", value = "attention:9:1" })
	assert(#world.opened == before and #world.toasts == 4 and world.toasts[4].level == "info",
		"a tap on a vanished row explains instead of opening")

	-- The dock button proves the effect path without any row.
	block:click("dock.tools.ping")
	assert(world.opened[#world.opened] == phone.PING, "Test phone link opens the ping URL")
end

-- An open pane with no title to match on: explained, tappable, and not dimmed like an offline row. A missing folder
-- or program is no obstacle: the phone finds the pane by its title.
do
	local world = newWorld()
	local rows = {
		row(1, "attention", { title = "Untitled pane", paneTitle = NONE, jumpable = false }),
		row(2, "attention", { title = "Floating untitled", paneTitle = NONE, jumpable = false, placement = "floating" }),
		row(3, "attention", { title = "Glyph title", paneTitle = "\u{E743}  \u{F009A}", jumpable = false }),
		row(4, "attention", { title = "Closed one", pane = NONE, paneTitle = NONE, cwd = NONE, program = NONE, placement = NONE,
			state = "Offline · waiting for input", localHost = false, jumpable = false }),
		row(5, "attention", { title = "Parked one", paneTitle = NONE, placement = "parked", jumpable = false }),
		row(6, "attention", { title = "Open me" }),
		row(7, "attention", { title = "No folder", cwd = NONE }),
		row(8, "attention", { title = "No program", program = NONE, placement = "floating" }),
		row(9, "attention", { title = "Title only", cwd = NONE, program = NONE }),
	}
	world:publish(snapshot(rows))
	local block = start(world)
	local shown = block:rows()
	for position = 1, 3 do
		assert(shown[position].off == "Open from tab list", "an untitled open pane points at the tab list")
		assert(not shown[position].chevron, "an untitled row has no jump affordance")
		assert(shown[position].node.p.role == shown[6].node.p.role, "an untitled row keeps normal contrast")
	end
	assert(shown[4].node.p.role ~= shown[6].node.p.role, "an offline row is dimmed")
	assert(shown[5].node.p.role ~= shown[6].node.p.role and shown[5].off == "Parked", "a parked row stays dimmed")
	assert(shown[4].off == "Offline", "an offline row keeps its chip")
	for position = 7, 9 do
		assert(shown[position].chevron and shown[position].off == nil, "a titled pane is openable without a folder or program")
	end

	for serial = 1, 3 do block:click("main.rows.r" .. serial) end
	assert(#world.opened == 0, "an untitled row opens nothing")
	for position = 1, 3 do
		assert(world.toasts[position].level == "info" and world.toasts[position].text
			== "This conversation has no title to match on your phone. Open it from the tab list.",
			"the tap says why and what to do")
	end
	block:click("main.rows.r9")
	local parsed = phone.parseJump(world.opened[1])
	assert(parsed and parsed.title == "Review the API 9" and parsed.cwd == "" and parsed.program == "",
		"a title-only row opens with the title as its evidence")
end

-- Nerd-Font icon glyphs (private-use codepoints) are drawn as empty boxes on a phone without the font: they are
-- dropped from what a row shows, while the jump link keeps the pane's evidence byte for byte.
do
	local bmp, plane15 = utf8.char(0xE743), utf8.char(0xF009A)
	local function privateUse(text)
		for _, cp in utf8.codes(text) do
			if (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000 then return true end
		end
		return false
	end
	local world = newWorld()
	local evidence = bmp .. " PLAN: beta " .. plane15
	local rows = {
		row(1, "attention", { session = plane15 .. " app", tab = bmp .. "  release prep", title = bmp .. "  " .. plane15 .. " PLAN: polish",
			paneTitle = evidence, cwd = "/work/" .. bmp .. "api", program = "omp" }),
		row(2, "attention", { session = bmp, tab = NONE, title = plane15 .. bmp, paneTitle = NONE, jumpable = false }),
	}
	world:publish(snapshot(rows, { host = bmp .. " Ada's MacBook Pro" }))
	local block = start(world)
	local shown = block:rows()
	assert(shown[1].title == "PLAN: polish", "a glyph prefix and the spaces after it leave no trace in the title")
	assert(shown[1].who == "app  release prep", "session and tab are shown without icon glyphs")
	assert(not privateUse(block:allText()), "no private-use character reaches any text of the block")
	assert(contains(block:allText(), "Ada's MacBook Pro"), "the host name survives without its glyph")

	block:click("main.rows.r1")
	local parsed = phone.parseJump(world.opened[1])
	assert(parsed and parsed.title == evidence and parsed.cwd == "/work/" .. bmp .. "api" and parsed.program == "omp",
		"the jump link carries the raw match evidence")

	assert(shown[2].who == "Conversation", "a session that is only glyphs falls back to a plain label")
	assert(shown[2].title == "Untitled conversation", "a title that is only glyphs falls back to a plain label")
end

-- Staleness and status messages.
do
	local function line(world)
		return start(world):allText()
	end

	local world = newWorld()
	world:publish(snapshot({ row(1, "attention") }, { generatedUtc = NOW - phone.STALE_SECONDS }))
	assert(not contains(line(world), "hasn't updated"), "a snapshot exactly at the threshold is not stale yet")

	world = newWorld()
	world:publish(snapshot({ row(1, "attention") }, { generatedUtc = NOW - phone.STALE_SECONDS - 1 }))
	local block = start(world)
	assert(contains(block:allText(), "Your Mac hasn't updated this for " .. phone.age(phone.STALE_SECONDS + 1)),
		"a stale snapshot says how long the Mac has been silent")
	assert(not contains(block:allText(), "Updated "), "the stale warning replaces the updated line")
	assert(#block:rows() == 1, "stale rows stay visible under the warning")

	-- Fresh at start; nothing writes again: the warning must appear within a poll of the threshold, not before.
	world = newWorld()
	world:publish(snapshot({ row(1, "attention") }))
	block = start(world)
	local warnedAt
	for _ = 1, 100 do
		world:advance(2000)
		local warned = contains(block:allText(), "hasn't updated")
		local age = world.utc - NOW
		if warned then warnedAt = age; break end
		assert(age <= phone.STALE_SECONDS + 2, "the warning is overdue at age " .. age)
	end
	assert(warnedAt and warnedAt > phone.STALE_SECONDS and warnedAt <= phone.STALE_SECONDS + 2 + 1,
		"staleness must render by the first poll past the threshold")

	-- A heartbeat clears it again with no revision change.
	world:heartbeat()
	world:advance(2000)
	assert(not contains(block:allText(), "hasn't updated") and contains(block:allText(), "Updated"),
		"a fresh heartbeat clears the warning")

	world = newWorld()
	world:publish(snapshot({}, { status = "disabled", reason = "Attention is off in this window" }))
	block = start(world)
	assert(contains(block:allText(), "Attention is disabled on your Mac"), "a disabled snapshot says so")
	assert(block:tabs() == nil and #block:rows() == 0, "a disabled Attention offers no queue")
	assert(block:title() == nil, "no count is claimed while disabled")

	world = newWorld()
	world:publish(snapshot({}, { status = "unavailable", reason = "The tab list can't be read right now" }))
	block = start(world)
	assert(containsInsensitive(block:allText(), "unavailable") and contains(block:allText(), "The tab list can't be read right now"),
		"an unavailable snapshot names the reason in plain words")
	assert(block:tabs() == nil and #block:rows() == 0, "an unavailable Attention offers no queue")

	world = newWorld()
	world:publish(snapshot({}, { status = "disabled", generatedUtc = NOW - 3600 }))
	block = start(world)
	assert(contains(block:allText(), "hasn't updated this for"), "an old disabled snapshot is not presented as current")
end

-- An empty section renders no filler text.
do
	local world = newWorld()
	world:publish(snapshot({ row(1, "working", { state = "Working" }) }))
	local block = start(world)
	local function textNodes()
		local nodes = {}
		local view = block:view()
		walk(view.main, function(node) if ownText(node) then table.insert(nodes, node) end end)
		return nodes
	end
	assert(#block:rows() == 0, "Attention is empty")
	assert(#textNodes() == 2, "an empty section shows only the control and the updated line")
	block:select("working")
	assert(#block:rows() == 1)
	world = newWorld()
	world:publish(snapshot({ row(1, "attention") }))
	block = start(world)
	block:select("working")
	assert(#block:rows() == 0 and #textNodes() == 2, "an empty Currently working section has no filler")
	world = newWorld()
	world:publish(snapshot({}))
	block = start(world)
	assert(#textNodes() == 2, "an empty queue shows only the control and the updated line")
end

-- The poll loop: one timer, no churn, stops with the pane.
do
	local world = newWorld()
	world:publish(snapshot({ row(1, "attention", { clock = { kind = "asked", atUtc = NOW - 3500, recorded = true } }) }))
	local block = start(world)
	assert(world:liveTimers() == 1, "exactly one poll timer runs")
	local firstClock = block:rows()[1].clock
	local readsBefore = world.reads
	for _ = 1, 14 do
		world:advance(2000)
		world:heartbeat()
	end
	assert(world.reads > readsBefore, "the file is re-read while the pane lives")
	assert(world.renders == 0, "heartbeats with unchanged revision must not re-render before the refresh interval")
	assert(world:liveTimers() == 1, "polling must not pile up timers")
	assert(#world.warnings == 0, "a clean poll logs nothing")

	for _ = 1, 3 do
		world:advance(2000)
		world:heartbeat()
	end
	assert(world.renders == 1, "relative times refresh once per interval")
	for _ = 1, 30 do
		world:advance(2000)
		world:heartbeat()
	end
	assert(world.renders >= 2 and world.renders <= 3, "refreshes keep to the 30 s cadence")
	local shown = block:rows()[1].clock
	assert(shown == phone.clockText({ kind = "asked", atUtc = NOW - 3500, recorded = true }, world.utc),
		"the refreshed chip reflects the current time")
	assert(shown ~= firstClock, "relative time actually moved")

	-- A new revision renders at once.
	local current = copy(world.docs[world.files[PATH]])
	current.revision = current.revision + 1
	current.rows[1].title = "Renamed on the Mac"
	world:publish(current)
	local rendersBefore = world.renders
	world:advance(2000)
	assert(world.renders == rendersBefore + 1 and block:rows()[1].title == "Renamed on the Mac", "a new revision renders within a poll")

	-- Same revision, different content (an owner that restarted its counter) is still shown.
	current = copy(world.docs[world.files[PATH]])
	current.rows[1].title = "Counter restarted"
	world:publish(current)
	rendersBefore = world.renders
	world:advance(2000)
	assert(world.renders == rendersBefore + 1 and block:rows()[1].title == "Counter restarted", "changed content renders even when the revision repeats")

	-- The pane goes away: the loop ends and nothing else happens.
	world.panes[7] = nil
	local reads, renders = world.reads, world.renders
	world:advance(2000)
	assert(world:liveTimers() == 0, "no timer survives the pane")
	world:advance(60000)
	assert(world.reads == reads, "no read after the pane is gone")
	assert(world.renders == renders, "no render after the pane is gone")
end

-- Partial, corrupt, and oversized files keep the last good snapshot; a persistent fault is shown.
do
	local world = newWorld()
	world:publish(snapshot({ row(1, "attention") }))
	local block = start(world)
	world:publishText("{ \"schema\": 1, \"rev")
	world:advance(2000)
	assert(#block:rows() == 1 and world.renders == 0, "one unreadable read (a write in flight) changes nothing")
	assert(not contains(block:allText(), "can't be read"), "a single failure is not announced")
	world:advance(2000)
	assert(#block:rows() == 1, "the last good rows stay while the file is unreadable")
	assert(world.renders == 1 and contains(block:allText(), "can't be read"), "a persistent fault is shown")
	world:publish(snapshot({ row(1, "attention"), row(2, "attention") }, { revision = 2 }))
	world:advance(2000)
	assert(#block:rows() == 2 and not contains(block:allText(), "can't be read"), "recovery clears the fault line")

	-- Unknown schemas remove old rows and counts instead of presenting a stale compatible queue.
	world:publish(snapshot({ row(1, "attention") }, { schema = 99, revision = 3 }))
	world:advance(2000)
	assert(#block:rows() == 0 and block:tabs() == nil and block:title() == nil, "an unknown schema makes the queue unavailable")
	assert(contains(block:allText(), "unavailable") and contains(block:allText(), "schema 2"), "the unavailable state names the required publisher schema")

	-- Oversized files are refused by the read bound.
	world:publish(snapshot({ row(1, "attention"), row(2, "attention") }, { revision = 4 }))
	world:advance(2000)
	world:publishText(string.rep("x", 2_000_000))
	world:advance(2000)
	world:advance(2000)
	assert(#block:rows() == 2, "an oversized file must not replace the last good snapshot")

	-- Never any good snapshot: waiting first, then the fault.
	world = newWorld()
	world:publishText("not json")
	block = start(world)
	assert(contains(block:allText(), "Waiting for your Mac"), "the first failed read is not announced")
	world:advance(2000)
	assert(contains(block:allText(), "can't be read"), "a file that never parses is called out")
	assert(block:tabs() == nil and #block:rows() == 0)
end

-- Sixty rows stay far below the surface limits.
do
	local world = newWorld()
	local rows = {}
	for serial = 1, 60 do
		table.insert(rows, row(serial, if serial % 3 == 0 then "working" else "attention", {
			title = string.rep("t", 160), tab = string.rep("b", 64), session = string.rep("s", 64),
			state = "Offline · waiting for input", cwd = string.rep("/c", 100) }))
	end
	world:publish(snapshot(rows))
	local block = start(world)
	local view = block:view()
	local nodes = 0
	walk(view.main, function() nodes += 1 end)
	walk(view.dock, function() nodes += 1 end)
	assert(#block:rows() == 40, "Attention shows its 40 rows")
	assert(nodes <= 1000, "sixty rows must stay far below the 2000-node cap, got " .. nodes)
	assert(weigh(view) <= 256 * 1024 / 2, "the view must stay well below 256 KiB")
	assert(depth(view.main) <= 12, "row nesting must stay far below the depth cap")
	block:select("working")
	assert(#block:rows() == 20, "Currently working shows its 20 rows")
end

-- Serials are the owner's; a repeat (validation does not forbid one) must not make the worker reject the view.
do
	local world = newWorld()
	world:publish(snapshot({ row(5, "attention", { title = "First" }), row(5, "attention", { title = "Second" }),
		row(6, "attention", { title = "Third" }) }))
	local block = start(world)
	local shown = block:rows()
	assert(#shown == 3 and shown[1].title == "First" and shown[2].title == "Second" and shown[3].title == "Third",
		"every row is shown even when serials repeat")
	block:click("main.rows.r6")
	assert(#world.opened == 1, "a unique serial still opens its row")
end

-- Hostile text: what the snapshot reader refuses never reaches a view, and what it lets through is shown plain.
do
	local function checkPlain(block)
		for _, text in block:texts() do
			assert(utf8.len(text) ~= nil, "displayed text must stay valid UTF-8")
			assert(not string.find(text, "[%c]"), "displayed text must not carry control characters: " .. string.format("%q", text))
			for _, hidden in { "\u{202E}", "\u{2066}", "\u{200B}", "\u{FEFF}", "\u{85}" } do
				assert(not string.find(text, hidden, 1, true), "displayed text must not carry direction, zero-width or NEL characters")
			end
		end
	end

	-- Control characters, invalid UTF-8 and over-long fields are refused as a whole: the last good rows stay.
	local good = snapshot({ row(1, "attention", { title = "Known good" }) })
	for label, fields in {
		controls = { title = "Line one\nLine two\27[31mred\27[0m" },
		escape = { session = "ji\27]0;pwned\7" },
		nul = { tab = "a\0b" },
		invalid = { title = "\255\254broken" },
		long = { title = string.rep("字", 400) },
		longSession = { session = string.rep("s", 400) },
		separator = { state = "Waiting\u{2028}for input" },
	} do
		local world = newWorld()
		world:publish(good)
		local block = start(world)
		world:publish(snapshot({ row(1, "attention", fields) }, { revision = 2 }))
		world:advance(2000)
		world:advance(2000)
		assert(#block:rows() == 1 and block:rows()[1].title == "Known good", label .. ": a refused snapshot must not replace the rows")
		assert(contains(block:allText(), "can't be read"), label .. ": the refusal is visible")
		checkPlain(block)
	end

	-- What validation allows but a view must still neutralize.
	local world = newWorld()
	world:publish(snapshot({
		row(1, "attention", { title = "Left\u{202E}evil\u{200B}zero\u{FEFF}width\u{2066}isolate", session = "ex\u{85}\u{A0}x",
			tab = "  spaced   out  ", state = "Waiting\u{85}for input" }),
		row(2, "attention", { title = string.rep("字", 160), session = string.rep("s", 64), tab = string.rep("b", 64) }),
		row(3, "attention", { title = "", paneTitle = "Pane header" }),
		row(4, "attention", { title = "", paneTitle = NONE }),
	}))
	local block = start(world)
	checkPlain(block)
	local shown = block:rows()
	assert(shown[1].title == "LeftevilzerowidthIsolate" or shown[1].title == "Leftevilzerowidthisolate",
		"direction and zero-width characters are removed, the text survives, got " .. shown[1].title)
	assert(not contains(shown[1].who, "  x") and contains(shown[1].who, "spaced out"), "whitespace runs collapse")
	assert(shown[1].state == "Waiting for input", "a next-line character becomes a space")
	assert(utf8.len(shown[2].title) == 160 and utf8.len(shown[2].who) == 64 + 2 + 64, "text at the bound is shown whole")
	assert(shown[3].title == "Pane header", "an empty title falls back to the pane header")
	assert(shown[4].title ~= "", "a row with no title at all still has a readable line")
end

-- Clock/status changes and activity on another row do not invalidate a tap on an unchanged route.
do
	local world = newWorld()
	local rows = { row(1, "working", { state = "Working" }), row(2, "working", { state = "Working" }) }
	world:publish(snapshot(rows))
	local block = start(world)
	block:select("working")
	local click = block:rows()[1].node.p.actions.click
	local captured = { ev = "action", id = "main.rows.r1", act = "jump", value = string.match(click, "^jump=(.*)$") }
	rows[1].clock.atUtc += 1
	rows[1].state = "Working · compiling"
	rows[2].paneTitle = "Another conversation's new title"
	world:publish(snapshot(rows, { revision = 2 }))
	world:advance(2000)
	block:event(captured)
	assert(#world.opened == 1 and world.opened[1] == phone.jumpUrl(rows[1]),
		"an unchanged route remains tappable across its clock and another row's changes")
	world:publish(snapshot({ rows[2] }, { revision = 3 }))
	world:advance(2000)
	world:publish(snapshot(rows, { revision = 4 }))
	world:advance(2000)
	block:event(captured)
	assert(#world.opened == 1, "a removed and reappearing route does not revive an old tap")
end

-- Every displayed section owns its action, even when one conversation appears in Attention and Working.
do
	local world = newWorld()
	local rows = {
		row(7, "attention", { paneTitle = "Attention target" }),
		row(7, "working", { paneTitle = "Working target", state = "Working" }),
	}
	world:publish(snapshot(rows))
	local block = start(world)
	local function action()
		local click = block:rows()[1].node.p.actions.click
		return { ev = "action", id = "main.rows.r7", act = "jump", value = string.match(click, "^jump=(.*)$") }
	end
	local old = action()
	for position, section in { "attention", "working" } do
		block:select(section)
		block:click("main.rows.r7")
		assert(world.opened[position] == phone.jumpUrl(rows[position]), section .. " must open its own row, not the first equal serial")
	end
	block:event(old)
	assert(#world.opened == 2, "an action from another displayed section is stale")
	local stale = action()
	local changed = copy(rows)
	changed[2].paneTitle = "Replacement target"
	world:publish(snapshot(changed))
	-- No poll yet: a tap must validate against the latest snapshot, not cached pane evidence.
	block:event(stale)
	assert(#world.opened == 2 and #world.toasts == 2, "a stale action cannot open replacement evidence even with the same revision")
	block:click("main.rows.r7")
	assert(world.opened[3] == phone.jumpUrl(changed[2]), "a newly rendered action opens the current evidence")
	local live = action()
	world:publish(snapshot({}, { status = "disabled" }))
	block:event(live)
	assert(#world.opened == 3, "an action cannot open after the owner disables Attention")
end

-- Whole Unicode labels survive updates and section switches; a repeated tab/title is only shown once.
do
	local world = newWorld()
	local title = "修復 café — 전체 제목 🚀 preserve every word"
	local rows = {
		row(1, "attention", { title = title, tab = title, session = "세션 café", paneTitle = title }),
		row(2, "working", { title = "Working — 실행 중", tab = "Build", state = "Working" }),
	}
	world:publish(snapshot(rows))
	local block = start(world)
	assert(block:rows()[1].title == title and block:rows()[1].who == "세션 café", "whole Unicode title is visible without duplicating it as the tab")
	block:click("main.rows.r1")
	assert(phone.parseJump(world.opened[1]).title == title, "matching evidence retains the original whole title")
	for position, section in { "attention", "working" } do
		block:select(section)
		assert(block:rows()[1].title == rows[position].title, "section changes preserve the entire title")
	end
	world:advance(60000)
	assert(contains(block:allText(), "Updated 1m ago"), "the complete status label updates over time")
	rows[2].title = "Renamed — 変更済み café"
	rows[2].state = "Working · compiling"
	world:publish(snapshot(rows, { revision = 2, generatedUtc = world.utc }))
	world:advance(2000)
	assert(block:rows()[1].title == rows[2].title and block:rows()[1].state == rows[2].state,
		"changed Unicode title and state replace the prior full labels")
	assert(contains(block:allText(), "Updated just now"), "the heartbeat restores the complete updated label")
end

-- A v1 owner cannot fabricate a zero working count; schema 2 recovers on the next poll.
do
	local world = newWorld()
	local old = snapshot({}, { schema = 1 })
	old.counts.working = nil
	world:publish(old)
	local block = start(world)
	assert(block:tabs() == nil and block:title() == nil and contains(block:allText(), "unavailable"),
		"an old snapshot is explicitly unavailable without a made-up count")
	world:publish(snapshot({ row(1, "working", { state = "Working" }) }))
	world:advance(2000)
	block:select("working")
	assert(#block:rows() == 1 and contains(ownText(block:tabs()), "Currently working 1"), "the current publisher restores the queue")
end

do
	local world = newWorld()
	world:publish(snapshot({}, { counts = { attention = 100001, working = 300003 } }))
	local block = start(world)
	assert(ownText(block:tabs()) == "Attention 100001  Currently working 300003",
		"validated full counts are never truncated to a smaller number")
	assert(block:title() == "Attention 100001", "the title also preserves the full count")
end

print("Attention host block checks passed")
return true
