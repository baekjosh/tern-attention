local phone = require("./phone")

-- Block `attention.queue`: Attention, Later and Currently working as a touch-sized list for the iOS client, which mirrors
-- host blocks. The owner window on the Mac publishes `phone.json`; this block only reads it and, on a tap, asks the
-- attached windows to open the row's jump URL (the phone's window half claims it).
local function bootstrap(tern, clockUtc)
local ui = tern.ui
local utcNow = clockUtc or os.time

local POLL_MS = 2000
local REFRESH_MS = 30000
local MAX_BYTES = 1048576
-- A snapshot that fails to read once is most likely caught mid-write; two failures in a row are shown.
local SHOWN_AFTER_FAILURES = 2
local SECTIONS = { attention = "Attention", later = "Later", working = "Currently working" }
local SECTION_ORDER = { "attention", "later", "working" }

local function blankCodepoint(cp)
	return cp <= 0x20 or (cp >= 0x7F and cp <= 0xA0) or cp == 0x2028 or cp == 0x2029
end

-- Nerd-Font icon glyphs live in the private-use planes; a phone without the font draws them as empty boxes.
local function privateUseCodepoint(cp)
	return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or (cp >= 0x100000 and cp <= 0x10FFFD)
end

-- Zero-width and bidirectional-control characters would let a hostile title reorder or hide what follows it.
local function invisibleCodepoint(cp)
	return (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x2064)
		or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xFEFF
end

-- Display text for an untrusted string (session, tab, title, host, status words): one line, no whitespace runs,
-- no direction or zero-width characters, no icon glyphs. Length is bounded by `phone.validate`, which every
-- snapshot passes before it reaches a view. Match evidence (`paneTitle`) is never passed through here.
local function clean(value)
	if type(value) ~= "string" or not utf8.len(value) then return "" end
	local chars, count, gap = {}, 0, false
	for _, cp in utf8.codes(value) do
		if blankCodepoint(cp) then
			gap = count > 0
		elseif not invisibleCodepoint(cp) and not privateUseCodepoint(cp) then
			if gap then count += 1; chars[count] = " "; gap = false end
			count += 1
			chars[count] = utf8.char(cp)
		end
	end
	return table.concat(chars)
end


local function running(pane)
	for _, entry in tern.pane.list() do
		if entry.pane == pane then return true end
	end
	return false
end

local function snapshotAge(state, nowUtc)
	return math.max(0, nowUtc - state.snapshot.generatedUtc)
end

local function isStale(state, nowUtc)
	return state.snapshot ~= nil and snapshotAge(state, nowUtc) > phone.STALE_SECONDS
end

-- Keep a row's action stable across clock/status updates. Only changed, removed or reappearing routes get a new token.
local function updateRoutes(state, snapshot)
	local routes = {}
	if snapshot.status == "ok" then
		for _, row in snapshot.rows do
			local key = row.section .. ":" .. tostring(row.serial)
			local url = phone.jumpUrl(row)
			local previous = state.rowRoutes[key]
			if previous == nil or previous.url ~= url then
				state.actionGeneration += 1
				previous = { token = state.actionGeneration, url = url }
			end
			routes[key] = previous
		end
	end
	state.rowRoutes = routes
end

-- Reads phone.json. Returns true when what the view shows may have changed. A missing, partial or invalid file
-- keeps the last good snapshot; its age then says so.
local function read(state)
	local path = tern.plugin.data .. "/" .. phone.FILE
	local okExists, exists = pcall(tern.fs.exists, path)
	if not okExists then
		state.failures, state.problem = state.failures + 1, "storage is unavailable"
		return state.failures == SHOWN_AFTER_FAILURES
	end
	if not exists then
		local changed = state.failures >= SHOWN_AFTER_FAILURES
		state.failures, state.problem = 0, nil
		return changed
	end
	local okRead, raw = pcall(tern.fs.read, path, MAX_BYTES)
	if not okRead then
		state.failures, state.problem = state.failures + 1, "the file can't be read"
		return state.failures == SHOWN_AFTER_FAILURES
	end
	if raw ~= state.raw then
		state.raw = raw
		local okDecode, decoded = pcall(tern.json.decode, raw)
		if okDecode then
			state.verdict, state.verdictReason = phone.validate(decoded)
		else
			state.verdict, state.verdictReason = nil, "the file isn't valid JSON"
		end
	end
	if state.verdict == nil then
		if state.verdictReason == "unsupported snapshot schema" then
			local changed = state.snapshot ~= nil or state.problem ~= state.verdictReason
			state.rowRoutes = {}
			state.snapshot = nil
			state.failures, state.problem = SHOWN_AFTER_FAILURES, state.verdictReason
			return changed
		end
		state.failures, state.problem = state.failures + 1, state.verdictReason or "the file isn't valid"
		return state.failures == SHOWN_AFTER_FAILURES
	end
	local previous, changed = state.snapshot, state.failures >= SHOWN_AFTER_FAILURES
	state.failures, state.problem = 0, nil
	state.snapshot = state.verdict
	if previous == nil or previous.revision ~= state.verdict.revision or not phone.sameContent(previous, state.verdict) then
		updateRoutes(state, state.verdict)
		changed = true
	end
	return changed
end

local function markRendered(state)
	local nowUtc = utcNow()
	state.renderedAt, state.renderedStale = tern.now(), isStale(state, nowUtc)
end

local function poll(cx, state)
	local changed = read(state)
	local stale = isStale(state, utcNow())
	if changed or stale ~= state.renderedStale or tern.now() - state.renderedAt >= REFRESH_MS then
		markRendered(state)
		cx:render()
	end
end

-- The next tick is armed before the work, so one failing read cannot end the loop; the loop ends only with the pane.
local function arm(cx, state)
	tern.timer(POLL_MS, function()
		if state.stopped then return end
		if not running(cx.pane) then
			state.stopped = true
			return
		end
		arm(cx, state)
		local ok, failure = pcall(poll, cx, state)
		if not ok then tern.log.warn("attention.queue: " .. tostring(failure)) end
	end)
end

-- Plain element labels avoid `text` fitting, which measures/clamps styled spans in terminal cells.
-- Let ordinary layout wrap the complete label in the scoped system sans face instead.
local function line(text, tone)
	return ui.node("el", { tag = "div", text = text, class = "queue-label", tone = tone })
end

local function sectionTabs(state)
	local counts = state.snapshot.counts
	local items = {}
	for _, id in SECTION_ORDER do
		table.insert(items, { id = id, label = SECTIONS[id] .. " " .. tostring(counts[id]) })
	end
	return ui.node("tabs", { key = "section", variant = "segmented", active = state.section, items = items })
end

-- An open pane the phone has nothing to find it by: the phone matches on the pane's title (cwd and program only
-- narrow a tie), and a title that is blank once icon glyphs and spaces are gone is no title.
local function unmatchable(row)
	if row.pane == nil or (row.placement ~= "tiled" and row.placement ~= "floating") then return false end
	return phone.matchTitle(row.paneTitle) == ""
end

-- Why a row cannot be opened from the phone: the chip words and the toast sentence.
local function blocked(row)
	if row.placement == "parked" then return "Parked", "That conversation is parked on your Mac" end
	if unmatchable(row) then
		return "Open from tab list",
			"This conversation has no title to match on your phone. Open it from the tab list."
	end
	if row.pane == nil then
		if type(row.state) == "string" and string.find(string.lower(row.state), "offline", 1, true) then
			return "Offline", "That conversation is offline"
		end
		return "No open pane", "That conversation has no open pane"
	end
	return "Can't open", "That conversation can't be opened from here"
end

local function rowNode(row, key, nowUtc, actionGeneration)
	local session, tab = clean(row.session), clean(row.tab)
	local title = clean(row.title)
	if title == "" then title = clean(row.paneTitle) end
	if title == "" then title = "Untitled conversation" end
	local who = line(if session ~= "" then session else "Conversation")
	who.p.key, who.p.class, who.p.grow = "who", "queue-label queue-session", 1
	if tab ~= "" and tab ~= session and tab ~= title then
		who.c = { ui.node("el", { tag = "span", text = "  " .. tab, class = "queue-tab" }) }
	end
	local top = { who }
	if row.jumpable then table.insert(top, ui.node("icon", { key = "go", name = "chev-r", tone = "muted" })) end
	local meta = {}
	local clockText, tooltip = phone.clockText(row.clock, nowUtc)
	if clockText then
		local chip = ui.badge(clockText, "neutral")
		if tooltip then chip.p.title = tooltip end
		chip.p.key = "clock"
		table.insert(meta, chip)
	end
	local stateText = clean(row.state)
	if stateText ~= "" then
		local waiting = string.find(string.lower(stateText), "waiting", 1, true) ~= nil
		local label = line(stateText, if waiting then "warning" else "muted")
		label.p.key = "state"
		table.insert(meta, label)
	end
	if not row.jumpable then
		local chip = ui.badge((blocked(row)), "muted")
		chip.p.key = "off"
		table.insert(meta, chip)
	end
	-- Only rows that are really unavailable are dimmed; one the phone merely cannot match keeps normal contrast.
	local dimmed = not row.jumpable and not unmatchable(row)
	local titleLabel = line(title)
	titleLabel.p.key, titleLabel.p.title = "title", title
	return ui.node("col", { key = key, role = if dimmed then "attention.queue.row-off" else "attention.queue.row", gap = "xs",
		actions = { click = "jump=" .. row.section .. ":" .. tostring(row.serial) .. ":" .. tostring(actionGeneration) } }, {
		ui.node("row", { key = "top", gap = "sm" }, top),
		titleLabel,
		ui.node("row", { key = "meta", gap = "sm", role = "attention.queue.meta" }, meta),
	})
end

local function rowsNode(state, nowUtc)
	local rows, seen = {}, {}
	for _, row in state.snapshot.rows do
		if row.section == state.section then
			-- A repeated key would make the whole view invalid.
			local key = "r" .. string.gsub(tostring(row.serial), "[^%w]", "_")
			if seen[key] then key = key .. "_" .. #rows end
			seen[key] = true
			local action = state.rowRoutes[row.section .. ":" .. tostring(row.serial)]
			table.insert(rows, rowNode(row, key, nowUtc, action.token))
		end
	end
	if #rows == 0 then return nil end
	return ui.node("col", { key = "rows", gap = "none" }, rows)
end

local function statusLine(state, nowUtc)
	local snapshot = state.snapshot
	local age = snapshotAge(state, nowUtc)
	if age > phone.STALE_SECONDS then
		return line("Your Mac hasn't updated this for " .. phone.age(age), "warning")
	end
	local host = clean(snapshot.host)
	local updated = if age < 60 then "Updated just now" else "Updated " .. phone.age(age) .. " ago"
	return line(if host ~= "" then updated .. " · " .. host else updated, "muted")
end

local function main(state)
	local nowUtc = utcNow()
	local children = {}
	local snapshot = state.snapshot
	if snapshot == nil then
		local text = "Waiting for your Mac's Attention window"
		if state.problem == "unsupported snapshot schema" then
			text = "Attention is unavailable until your Mac publishes snapshot schema " .. tostring(phone.SCHEMA)
		elseif state.problem and state.failures >= SHOWN_AFTER_FAILURES then
			text = "Your Mac's Attention snapshot can't be read: " .. state.problem
		end
		local status = line(text, "muted")
		status.p.key = "status"
		table.insert(children, status)
		return ui.node("col", { gap = "md" }, children)
	end
	if snapshot.status == "ok" then table.insert(children, sectionTabs(state)) end
	local status = statusLine(state, nowUtc)
	status.p.key = "status"
	if snapshot.status == "disabled" and not isStale(state, nowUtc) then
		status = line("Attention is disabled on your Mac")
		status.p.key = "status"
	elseif snapshot.status == "unavailable" and not isStale(state, nowUtc) then
		local detail = clean(snapshot.reason)
		status = line("Attention is unavailable on your Mac" .. (if detail ~= "" then ": " .. detail else ""), "warning")
		status.p.key = "status"
	end
	table.insert(children, status)
	if state.problem and state.failures >= SHOWN_AFTER_FAILURES then
		local problem = line("The latest snapshot can't be read: " .. state.problem, "muted")
		problem.p.key = "problem"
		table.insert(children, problem)
	end
	if snapshot.status == "ok" then
		local rows = rowsNode(state, nowUtc)
		if rows then table.insert(children, rows) end
	end
	return ui.node("col", { gap = "md" }, children)
end

local function dock()
	return ui.node("col", { gap = "sm" }, {
		ui.node("row", { key = "tools", gap = "sm" }, {
			ui.node("button", { key = "ping", text = "Test phone link", icon = "link", variant = "quiet",
				actions = { click = "ping" } }),
		}),
	})
end

local queue = {
	font = "sans",

	init = function(cx, _args, saved)
		local state = { section = "attention", failures = 0, renderedAt = 0, renderedStale = false,
			actionGeneration = 0, rowRoutes = {} }
		if type(saved) == "table" and SECTIONS[saved.section] then state.section = saved.section end
		read(state)
		markRendered(state)
		arm(cx, state)
		return state
	end,

	title = function(state)
		if state.snapshot and state.snapshot.status == "ok" then
			return "Attention " .. tostring(state.snapshot.counts.attention)
		end
		return nil
	end,

	view = function(state, _cx)
		return { main = main(state), dock = dock() }
	end,

	event = function(state, ev, cx)
		if ev.ev == "select" and SECTIONS[ev.item] then
			state.section = ev.item
		elseif ev.ev == "action" and ev.act == "ping" then
			cx:open(phone.PING)
		elseif ev.ev == "action" and ev.act == "jump" then
			-- Reconcile before opening: a queued tap must not route to replacement pane evidence or another section.
			if read(state) then markRendered(state); cx:render() end
			local section, serial, generation = string.match(ev.value or "", "^([%a]+):(%d+):(%d+)$")
			local target
			local offered = if section and serial then state.rowRoutes[section .. ":" .. serial] else nil
			if section == state.section and offered and tonumber(generation) == offered.token
				and state.snapshot and state.snapshot.status == "ok" then
				for _, row in state.snapshot.rows do
					if row.section == section and tostring(row.serial) == serial then
						if target ~= nil then target = nil; break end
						target = row
					end
				end
			end
			if target == nil then
				cx:toast("info", "That conversation is no longer in the queue")
				return
			end
			local url = if target.jumpable then phone.jumpUrl(target) else nil
			if url then
				cx:open(url)
			else
				local _, sentence = blocked(target)
				cx:toast("info", sentence)
			end
		end
	end,

	save = function(state)
		return { section = state.section }
	end,
}

tern.block.define("queue", queue)
end

if tern ~= nil then bootstrap(tern) end
return bootstrap
