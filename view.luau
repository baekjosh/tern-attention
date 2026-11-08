local phone = require("./phone")
local navigation = require("./navigation")

local view = {}
local PAGE_SIZE = 40
local SECTIONS = { "attention", "later", "working", "workspace" }
local MAX_UI_KEYS, MAX_UI_KEY = 512, 256

local function node(kind, props, children)
	return { k = kind, p = props, c = children }
end

local function text(key, role, value)
	return node("text", { key = key, role = role, text = value, wrap = "none", truncate = "middle" })
end

local function bounded(value, limit)
	if type(value) ~= "string" then return "" end
	local valid, cut = pcall(utf8.offset, value, limit + 1)
	if not valid then return "" end
	if cut and cut <= #value then value = string.sub(value, 1, cut - 1) .. "…" end
	if utf8.len(value) == nil then return "" end
	value = string.gsub(value, "[%c]", " ")
	value = string.gsub(value, "\226\128\168", " ")
	value = string.gsub(value, "\226\128\169", " ")
	return if string.find(value, "%S") then value else ""
end

local function label(value, fallback, limit)
	local result = bounded(value, limit or 160)
	return if result == "" then fallback else result
end

local modifierGlyphs = { "⌃", "⌥", "⇧", "⌘" }
local modifierOrder = {
	ctrl = 1, control = 1, alt = 2, opt = 2, option = 2,
	shift = 3, cmd = 4, command = 4, meta = 4, super = 4,
}
local function shortcutLabel(value)
	local chord = bounded(value, 100)
	if chord == "" then return "Shortcut unavailable" end
	local parts, modifiers = string.split(chord, "+"), {}
	for index, part in ipairs(parts) do
		part = string.match(part, "^%s*(.-)%s*$")
		if index < #parts then
			local order = modifierOrder[string.lower(part)]
			if not order then return chord end
			modifiers[order] = true
		elseif part == "" or modifierOrder[string.lower(part)] then return chord
		else parts[index] = if string.match(part, "^%a$") then string.upper(part) else part end
	end
	local glyphs = ""
	for index, glyph in ipairs(modifierGlyphs) do if modifiers[index] then glyphs ..= glyph end end
	return glyphs .. parts[#parts]
end

local function equal(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function condition(row)
	return row.condition or (if row.nativeState == "waiting_input" then "waiting" else nil)
end

local function inQueue(row, section)
	return (section == "later" and row.disposition == "later")
		or (section == "attention" and row.attention == true and row.disposition ~= "later")
		or (section == "working" and row.nativeState == "working" and row.pane ~= nil
			and not row.stale and not row.offline and not row.noOpenPane and not row.orphaned)
end

-- Presentation rows of one conversation queue; the Workspace tree comes from `navigation.rows`.
local function derive(presentation, section)
	local rows = {}
	for _, row in ipairs(presentation.rows) do
		if inQueue(row, section) then
			table.insert(rows, row)
		end
	end
	if section == "attention" then
		table.sort(rows, function(a, b)
			local ap, bp = a.priority or 4, b.priority or 4
			if ap ~= bp then return ap < bp end
			local ab, bb = condition(a) ~= nil, condition(b) ~= nil
			if ab ~= bb then return ab end
			local aq, bq = a.queueOrder or a.serial, b.queueOrder or b.serial
			return if aq ~= bq then aq < bq else a.serial < b.serial
		end)
	else
		table.sort(rows, function(a, b)
			if section == "later" then
				local ad, bd = if finite(a.untilUtc) then a.untilUtc else math.huge, if finite(b.untilUtc) then b.untilUtc else math.huge
				if ad ~= bd then return ad < bd end
			end
			local aq, bq = a.queueOrder or a.serial, b.queueOrder or b.serial
			return if aq ~= bq then aq < bq else a.serial < b.serial
		end)
	end
	return rows
end

-- Every row fact `derive` reads, projected to the exact values the filters and sorts consume, so equal facts
-- guarantee the identical list for every section.
local FACTS = 13
local function facts(item)
	return
		(if item.disposition == "later" then 1 else 0),
		(if item.attention == true then 1 else 0),
		(if item.nativeState == "working" then 1 else 0),
		(if item.pane ~= nil then 1 else 0),
		(if item.stale then 1 else 0),
		(if item.offline then 1 else 0),
		(if item.noOpenPane then 1 else 0),
		(if item.orphaned then 1 else 0),
		(if item.condition or item.nativeState == "waiting_input" then 1 else 0),
		(item.priority or 4),
		(item.queueOrder or item.serial),
		item.serial,
		(if finite(item.untilUtc) then item.untilUtc else math.huge)
end

local function stampRows(rows)
	local stamp = table.create(#rows * FACTS)
	for index, item in ipairs(rows) do
		local f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13 = facts(item)
		local at = (index - 1) * FACTS
		stamp[at + 1], stamp[at + 2], stamp[at + 3], stamp[at + 4] = f1, f2, f3, f4
		stamp[at + 5], stamp[at + 6], stamp[at + 7], stamp[at + 8] = f5, f6, f7, f8
		stamp[at + 9], stamp[at + 10], stamp[at + 11], stamp[at + 12], stamp[at + 13] = f9, f10, f11, f12, f13
	end
	return stamp
end

local function stampCurrent(stamp, rows)
	for index, item in ipairs(rows) do
		local f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13 = facts(item)
		local at = (index - 1) * FACTS
		if stamp[at + 1] ~= f1 or stamp[at + 2] ~= f2 or stamp[at + 3] ~= f3 or stamp[at + 4] ~= f4
			or stamp[at + 5] ~= f5 or stamp[at + 6] ~= f6 or stamp[at + 7] ~= f7 or stamp[at + 8] ~= f8
			or stamp[at + 9] ~= f9 or stamp[at + 10] ~= f10 or stamp[at + 11] ~= f11 or stamp[at + 12] ~= f12
			or stamp[at + 13] ~= f13
		then return false end
	end
	return true
end

-- Weak-keyed by presentation: publish retains the table while content is unchanged, and the facts stamp also
-- catches in-place row edits, so the phone, diagnostics, normalize and render calls of one pass reuse lists.
local queueMemo = setmetatable({}, { __mode = "k" })

local function ordered(presentation, section)
	local rows = presentation.rows
	local entry = queueMemo[presentation]
	if entry == nil or entry.count ~= #rows or not stampCurrent(entry.stamp, rows) then
		entry = { count = #rows, stamp = stampRows(rows), lists = {} }
		queueMemo[presentation] = entry
	end
	local cached = entry.lists[section]
	if cached == nil then
		cached = derive(presentation, section)
		entry.lists[section] = cached
	end
	return cached
end
view.queue = ordered

-- Every section paginates and anchors on row keys: conversation queues use "r"..serial, the Workspace tree its
-- navigation row keys, so a collapse or a membership change keeps the anchor on a surviving neighbor.
local function sectionItems(logical, presentation, options, section)
	local items = {}
	if section == "workspace" then
		local snapshot = if options then options.workspace else nil
		if snapshot then
			for _, navRow in ipairs(navigation.rows(snapshot, logical.workspace).rows) do
				table.insert(items, { key = navRow.key, navRow = navRow })
			end
		end
	else
		for _, row in ipairs(ordered(presentation, section)) do
			table.insert(items, { key = "r" .. row.serial, row = row })
		end
	end
	return items
end

function view.newState()
	return {
		section = "attention", settings = false,
		pages = { attention = 1, workspace = 1, later = 1, working = 1 }, starts = { attention = 1, workspace = 1, later = 1, working = 1 },
		anchors = {}, pendingPages = {}, workspace = { collapsed = {}, setAsideOpen = {} },
		revision = 1, intentRevision = 1,
	}
end

function view.newRenderer(epoch)
	return { epoch = epoch, counter = 0, bindings = {}, targets = {}, initialized = false }
end

function view.invalidate(renderer, retryPaint)
	renderer.previous, renderer.arrival, renderer.arrivalRevision = nil, nil, nil
	renderer.bindings, renderer.targets = {}, {}
	renderer.initialized = retryPaint == true and renderer.initialized == true
end

function view.section(logical, section)
	assert(section == "attention" or section == "workspace" or section == "later" or section == "working" or section == "settings", "Unknown Attention section")
	if section == "settings" then logical.settings = not logical.settings
	elseif logical.section == section and not logical.settings then return
	else logical.section, logical.settings = section, false end
	logical.revision += 1
	logical.intentRevision += 1
end

-- Explicit disclosure changes publish a new view and fence captured async actions, like any other intent.
function view.toggleGroup(logical, key)
	assert(type(key) == "string" and key ~= "", "Workspace group key unavailable")
	logical.workspace.collapsed[key] = if logical.workspace.collapsed[key] then nil else true
	logical.revision += 1
	logical.intentRevision += 1
end

function view.toggleAside(logical, tabKey)
	assert(type(tabKey) == "string" and tabKey ~= "", "Workspace tab key unavailable")
	logical.workspace.setAsideOpen[tabKey] = if logical.workspace.setAsideOpen[tabKey] then nil else true
	logical.revision += 1
	logical.intentRevision += 1
end

-- The only persisted navigator state (D3): the last section and the disclosure sets. Scroll anchors, pages,
-- search, expansion and the settings panel are memory-only.
function view.ui(logical)
	local ui = { section = logical.section, collapsed = {}, setAsideOpen = {} }
	for key in pairs(logical.workspace.collapsed) do ui.collapsed[key] = true end
	for key in pairs(logical.workspace.setAsideOpen) do ui.setAsideOpen[key] = true end
	return ui
end

local function restoredKeys(saved)
	local keys = {}
	if type(saved) == "table" then
		for key, open in pairs(saved) do
			if type(key) == "string" and key ~= "" and #key <= MAX_UI_KEY and open == true then table.insert(keys, key) end
		end
	end
	table.sort(keys)
	local kept = {}
	for index = 1, math.min(#keys, MAX_UI_KEYS) do kept[keys[index]] = true end
	return kept
end

local function countKeys(map)
	local count = 0
	for _ in pairs(map) do count += 1 end
	return count
end

-- A long-lived VM keeps every disclosure key ever toggled; the same cap restore and the persisted sanitizer
-- apply (512 sorted keys) bounds the live maps during normalization, with key order alone deciding eviction.
local function boundedKeys(map)
	if countKeys(map) <= MAX_UI_KEYS then return map, false end
	return restoredKeys(map), true
end

local function boundDisclosures(logical)
	local collapsed, collapsedOver = boundedKeys(logical.workspace.collapsed)
	local setAside, setAsideOver = boundedKeys(logical.workspace.setAsideOpen)
	if not collapsedOver and not setAsideOver then return false end
	logical.workspace.collapsed, logical.workspace.setAsideOpen = collapsed, setAside
	return true
end

-- Applies a persisted value to a fresh state; anything unrecognized falls back to Attention with no
-- disclosures, and nothing transient is ever restored.
function view.restore(logical, saved)
	local section, collapsed, setAsideOpen = "attention", {}, {}
	if type(saved) == "table" then
		for _, name in ipairs(SECTIONS) do
			if saved.section == name then section = name end
		end
		collapsed, setAsideOpen = restoredKeys(saved.collapsed), restoredKeys(saved.setAsideOpen)
	end
	logical.section, logical.settings = section, false
	logical.workspace = { collapsed = collapsed, setAsideOpen = setAsideOpen }
	logical.pages = { attention = 1, workspace = 1, later = 1, working = 1 }
	logical.starts = { attention = 1, workspace = 1, later = 1, working = 1 }
	logical.anchors, logical.pendingPages, logical.expandedWorkId = {}, {}, nil
	logical.revision += 1
	logical.intentRevision += 1
end

function view.page(logical, delta)
	if logical.settings or not finite(delta) then return end
	delta = math.floor(delta)
	if delta == 0 then return end
	local section = logical.section
	logical.pendingPages[section] = (logical.pendingPages[section] or 0) + delta
	logical.revision += 1
	logical.intentRevision += 1
end

function view.expand(logical, workId)
	local expandedWorkId = if logical.expandedWorkId == workId then nil else workId
	if logical.expandedWorkId == expandedWorkId then return end
	logical.expandedWorkId = expandedWorkId
	logical.revision += 1
	logical.intentRevision += 1
end

function view.normalize(logical, presentation, options)
	local changed, existing = false, {}
	-- Capping can re-expand groups, a visible change like a toggle, so it dirties the view revision.
	if boundDisclosures(logical) then changed = true end
	for _, row in ipairs(presentation.rows) do existing[row.workId] = true end
	if logical.expandedWorkId and not existing[logical.expandedWorkId] then
		logical.expandedWorkId, changed = nil, true
	end
	for _, section in ipairs(SECTIONS) do
		local rows, ids, positions = sectionItems(logical, presentation, options, section), {}, {}
		for index, item in ipairs(rows) do ids[index], positions[item.key] = item.key, index end
		local pages = math.max(1, math.ceil(#rows / PAGE_SIZE))
		local start = logical.starts[section] or 1
		local anchor = logical.anchors[section]
		if anchor then
			local found = positions[anchor.key]
			if not found then
				for index = anchor.index, #anchor.order do
					found = positions[anchor.order[index]]
					if found then break end
				end
			end
			if not found then
				for index = anchor.index - 1, 1, -1 do
					found = positions[anchor.order[index]]
					if found then break end
				end
			end
			if found then start = found end
		end
		start = math.clamp(start, 1, math.max(1, #rows))
		local delta = logical.pendingPages[section] or 0
		if delta > 0 then
			local finalStart = start + math.floor(math.max(0, #rows - start) / PAGE_SIZE) * PAGE_SIZE
			start = math.min(start + delta * PAGE_SIZE, finalStart)
		elseif delta < 0 then
			start = math.max(1, start + delta * PAGE_SIZE)
		end
		if pages == 1 then start = 1 end
		local page = math.min(pages, math.floor((start - 1) / PAGE_SIZE) + 1)
		local nextAnchor = if #rows > 0 then { key = ids[start], index = start, order = ids } else nil
		if logical.pages[section] ~= page or logical.starts[section] ~= start or not equal(anchor, nextAnchor) then changed = true end
		logical.pages[section], logical.starts[section], logical.anchors[section] = page, start, nextAnchor
		logical.pendingPages[section] = nil
	end
	if changed then logical.revision += 1 end
end

function view.resolve(renderer, action)
	local binding = if action then renderer.bindings[action] else nil
	return if binding then table.clone(binding) else nil
end

local function historyUnavailable(observation)
	if type(observation) ~= "table" then return false end
	local coverage = observation.coverage
	return observation.recordsComplete == false or observation.historyScope == "unavailable"
		or type(coverage) == "table" and (coverage.recordsComplete == false or coverage.historyScope == "unavailable")
end

local function sourceUnavailable(row)
	local observation = row.sourceObservation
	if observation == nil then return row.source ~= nil end
	local coverage = row.source and row.source.coverage
	return historyUnavailable(observation) or observation.selectionSupport == "unknown"
		or type(coverage) == "table" and coverage.selectionSupport == "unknown"
		or observation.status ~= "ready" and observation.status ~= "partial" and observation.status ~= "unchanged"
end

local function evidenceTitle(title, known)
	return if known then "Last known " .. string.lower(title) else title
end

local function sourceField(source, field, provenanceField)
	local current, prior = source[field], source.lastKnown
	local previous = if prior then prior[field] else nil
	local observation = if prior and prior.provenance then prior.provenance[provenanceField or field] else nil
	if current ~= nil and not historyUnavailable(source) then return current, false, source end
	return if historyUnavailable(observation) then nil else previous, true, observation
end

local function questionCoverageComplete(source)
	return type(source.questionCoverage) == "table" and source.questionCoverage.status == "complete"
end

local function sourceQuestions(source)
	local prior, entries, positions, omitted = source.lastKnown or {}, {}, {}, {}
	for _, question in ipairs(prior.omittedQuestions or {}) do omitted[question.id] = question end
	local complete = questionCoverageComplete(source)
	for index, question in ipairs(prior.questions or {}) do
		local observation = if prior.provenance and prior.provenance.questions then prior.provenance.questions[question.id] else nil
		if not historyUnavailable(observation) then
			table.insert(entries, { question = question, order = index, lastKnown = true, observation = observation })
			positions[question.id] = #entries
		end
	end
	local priorCount = #entries
	local unqualified = type(source.coverage) == "table" and source.coverage.selectionSupport == "unknown"
	if historyUnavailable(source) then return entries end
	for index, question in ipairs(source.questions or {}) do
		local position = positions[question.id]
		local previous = if position then entries[position].question else omitted[question.id]
		local resolved = previous and (previous.status == "answered" or previous.status == "cancelled" or previous.status == "failed")
		local uncertain = unqualified and previous ~= nil
			or not complete and (question.status == "unknown" or (resolved and question.status == "open"))
		-- Compact omitted IDs guard status but never expand into a second text projection.
		if not omitted[question.id] and (not previous or not uncertain) then
			local entry = { question = question, order = priorCount + index, lastKnown = unqualified, observation = source }
			if position then entries[position] = entry
			else
				table.insert(entries, entry)
				positions[question.id] = #entries
			end
		end
	end
	return entries
end

local monthDays = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local function availability(row)
	if row.untilUtc == nil and row.availableOn == nil and row.availableTime == nil then return "No return date" end
	if not finite(row.untilUtc) then return "Return time unknown" end
	local year, month, day = string.match(if type(row.availableOn) == "string" then row.availableOn else "", "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	local hour, minute = string.match(if type(row.availableTime) == "string" then row.availableTime else "", "^(%d%d):(%d%d)$")
	year, month, day, hour, minute = tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute)
	local leap = year and year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
	local days = if month == 2 and leap then 29 else monthDays[month]
	if year and year >= 1 and days and day and day >= 1 and day <= days
		and hour and hour < 24 and minute and minute < 60 and bounded(row.zone, 64) ~= "" then
		return row.availableOn .. " " .. row.availableTime .. " · " .. bounded(row.zone, 64)
	end
	if row.untilUtc >= -62135596800 and row.untilUtc <= 253402300799 then
		local ok, utc = pcall(os.date, "!%Y-%m-%d %H:%M:%S UTC", row.untilUtc)
		if ok and type(utc) == "string" and utc ~= "" then return utc end
	end
	return "Return time unknown"
end

-- What the chip says, as data: the clock of the agent's last ask, reply or update (`phone.clockText` words it).
-- `recorded` marks a time taken from a record rather than a readable source. A row that names a failure, or whose
-- history records no time at all, has a fixed chip instead: nil, the chip text, its tooltip.
local function primaryClock(row)
	local blocker = condition(row)
	local sourceQuestion = row.sourceQuestionCurrent == true and row.nativeState ~= "working"
	if blocker == "delivery" then return nil, "Delivery time unknown", "When the prompt delivery failed is not recorded." end
	if blocker == "startup" then return nil, "Startup time unknown", "When the agent startup failed is not recorded." end
	if row.nativeState == "working" and blocker ~= "waiting" then return nil end
	if blocker ~= "waiting" and row.reviewSuperseded == true and not sourceQuestion then return nil end
	local source = row.source
	if not source then
		return { kind = if blocker == "waiting" or sourceQuestion then "asked" else "updated", notRecorded = true, recorded = false }
	end
	local offline = row.stale == true
	if blocker == "waiting" or sourceQuestion then
		local newest, newestRank
		for _, entry in ipairs(sourceQuestions(source)) do
			local rank = if entry.lastKnown then 1 else 0
			if entry.question.status == "open" and (not newest or rank < newestRank
				or rank == newestRank and entry.order > newest.order) then newest, newestRank = entry, rank end
		end
		if newest then
			return { kind = "asked", atUtc = newest.question.askedAtUtc, offline = offline,
				recorded = offline or (newest.lastKnown or sourceUnavailable(row)) == true }
		end
		return { kind = "asked", notRecorded = true, recorded = false }
	end
	local final, finalKnown = sourceField(source, "lastFinal")
	if final then
		return { kind = "replied", atUtc = final.atUtc, completed = final.timeKind == "completed", offline = offline,
			recorded = offline or (finalKnown or sourceUnavailable(row)) == true }
	end
	local assistant, assistantKnown = sourceField(source, "lastAssistant")
	if assistant then
		return { kind = "updated", atUtc = assistant.atUtc, offline = offline,
			recorded = offline or (assistantKnown or sourceUnavailable(row)) == true }
	end
	return { kind = "updated", notRecorded = true, recorded = false }
end

-- The chip says when the agent last asked, replied or posted an update; the tooltip spells the same fact out and
-- says so when the source behind it is offline or unreadable. Returns the chip text, its tooltip and whether the
-- time is only recorded (offline or unreadable source).
local function primaryAge(row, nowUtc)
	local clock, fixed, tooltip = primaryClock(row)
	if clock == nil then return fixed, tooltip end
	local chip, sentence = phone.clockText(clock, nowUtc)
	return chip, sentence, clock.recorded
end

-- The chip's clock as data for the phone queue, or nil when the row shows no clock of this kind.
function view.clock(row)
	return (primaryClock(row))
end

local runtimeLabels = { idle = "Idle", working = "Working", waiting_input = "Waiting for input", exited = "Exited", unknown = "Runtime unknown" }
local conditionLabels = { waiting = "Waiting for input", delivery = "Delivery failed", startup = "Startup failed" }
local reviewLabels = {
	done = "Reply to review", failed = "Agent reported failure", exited = "Agent exited",
	manual = "Manual revisit", legacy = "Saved review", waiting = "Previous input request",
	delivery = "Previous delivery problem", startup = "Previous startup problem", update = "New update",
}
local friendlyUnavailable = {
	unverified = "Checking identity", ["identity proof pending"] = "Checking identity", missing = "Checking identity",
	["coverage unavailable"] = "Coverage unavailable", disconnected = "Host offline",
}

local function runtimeWords(row)
	return conditionLabels[condition(row)] or runtimeLabels[row.nativeState] or "Runtime unknown"
end

-- The state words a conversation row shows (`Waiting for input`, `Offline · idle`) and, when offline, why.
function view.stateText(row)
	local words = runtimeWords(row)
	if row.stale then
		return "Offline · " .. string.lower(words), "Offline: shown from the last recorded state, which cannot be refreshed right now."
	end
	return words
end

local function details(row, nowUtc)
	local diagnostics, tracking, replies, updates, requests, history = {}, {}, {}, {}, {}, {}
	local lines = diagnostics
	local requestFirst = condition(row) == "waiting" or row.sourceQuestionCurrent == true and row.nativeState ~= "working"
	local function add(key, value)
		table.insert(lines, node("text", { key = key, role = "attention.context", text = value }))
	end
	local function coverage(key, caption, value)
		value = if type(value) == "table" then value else {}
		local parts = {}
		for _, field in ipairs({ { "recordsComplete", "record scan" }, { "ancestryComplete", "selected ancestry" } }) do
			if value[field[1]] ~= nil then table.insert(parts, field[2] .. (if value[field[1]] then " complete" else " incomplete")) end
		end
		for _, field in ipairs({ { "writerSupport", "writer support" }, { "selectionSupport", "selection support" }, { "historyScope", "history" } }) do
			if value[field[1]] ~= nil then table.insert(parts, field[2] .. ": " .. label(value[field[1]], "unknown", 48)) end
		end
		for _, field in ipairs({
			{ "records", "records" }, { "offBranchEntries", "off-branch entries" }, { "controlsExcluded", "controls excluded" },
			{ "summariesExcluded", "summaries excluded" }, { "unmatchedAskResults", "unmatched question results" },
		}) do
			if finite(value[field[1]]) then table.insert(parts, field[2] .. ": " .. value[field[1]]) end
		end
		if type(value.controlRolesExcluded) == "table" then
			local roles = {}
			for role, count in pairs(value.controlRolesExcluded) do
				if type(role) == "string" and finite(count) then table.insert(roles, bounded(role, 24) .. ": " .. count) end
			end
			table.sort(roles)
			if #roles > 0 then table.insert(parts, "excluded control roles: " .. table.concat(roles, ", ")) end
		end
		add(key, caption .. ": " .. (if #parts > 0 then table.concat(parts, " · ") else "unknown"))
	end
	local function questionCoverage(key, caption, value)
		value = if type(value) == "table" then value else {}
		local parts = { label(value.status, "unknown", 24) }
		for _, field in ipairs({ { "knownTotal", "known attempts" }, { "included", "included" }, { "omitted", "omitted" } }) do
			table.insert(parts, (if finite(value[field[1]]) then tostring(value[field[1]]) else "unknown") .. " " .. field[2])
		end
		if value.textTruncated then table.insert(parts, "question text clipped") end
		add(key, caption .. ": " .. table.concat(parts, " · "))
	end
	add("context", label(row.context, "Context unknown", 256) .. " · " .. label(row.hostName, "unknown host", 100)
		.. " · " .. row.workId)
	lines = tracking
	add("tracking", "Tracking: " .. label(row.disposition, "unknown", 30)
		.. (if row.retained then " · explicitly retained" else " · live only")
		.. (if row.parked then " · parked" elseif row.floating then " · floating" else ""))
	if row.disposition == "later" or row.availableOn or row.untilUtc then
		add("later", "Available: " .. availability(row))
	end
	if row.stale then add("stale", "Last known evidence · refresh unavailable") end
	lines = diagnostics
	local function clock(key, title, atUtc)
		add(key, title .. ": " .. (if finite(atUtc) then tostring(atUtc) .. " UTC seconds · " else "") .. phone.relative(atUtc, nowUtc))
	end
	local observation = row.sourceObservation
	local unavailable = sourceUnavailable(row)
	if observation then
		add("source-availability", "Latest source availability: " .. label(observation.status, "unknown", 32))
		clock("source-observed", "Source availability observed", observation.capturedAtUtc)
		if observation.path then add("source-path", "Recorded locator: " .. label(observation.path, "unknown", 256)) end
	elseif row.source then
		add("source-availability", "Latest source availability: unknown · saved facts not refreshed in this owner")
	end
	local source = row.source
	if historyUnavailable(observation) or historyUnavailable(source) then
		add("source-history", "Source history unavailable · incomplete record scan; current source clocks unknown")
	end
	if not source then
		add("source", "Source unavailable · recorded event times unknown")
	else
		add("source", "Source: " .. label(source.status, "unknown", 32) .. " · " .. label(source.selection, "selection unknown", 32)
			.. (if source.complete then " · complete supported history" else " · coverage incomplete"))
		clock("source-captured", if unavailable then "Last known source snapshot captured" else "Source snapshot captured", source.capturedAtUtc)
		add("source-as-of", "Recorded as-of snapshot · not a live branch or current source-availability guarantee")
		add("source-identity", "Recorded session: " .. label(source.sessionId, "unknown", 100)
			.. (if historyUnavailable(source) then " · persisted leaf not established" else " · persisted leaf: " .. label(source.selectedLeafId, "unknown / none", 100))
			.. " · schema " .. tostring(source.schemaVersion or "unknown"))
		coverage("source-coverage", "Source coverage", source.coverage)
		questionCoverage("source-question-coverage", "Question coverage", source.questionCoverage)
		local retainedQuestions = source.lastKnown
		if retainedQuestions and (retainedQuestions.questionsKnown ~= nil or retainedQuestions.questionsOmitted ~= nil) then
			local function count(value)
				return if finite(value) then tostring(value) else "unknown"
			end
			add("retained-question-counts", "Known retained questions: " .. count(retainedQuestions.questionsKnown)
				.. " known · " .. count(retainedQuestions.questionsIncluded) .. " included · " .. count(retainedQuestions.questionsOmitted)
				.. " omitted · " .. count(retainedQuestions.openQuestionsOmitted) .. " open omitted · known ledger only, not full history")
		end
		local function historical(key, kind, observation)
			observation = observation or {}
			local content = lines
			lines = diagnostics
			clock(key .. "-observed", "Last known " .. kind .. " evidence observed", observation.capturedAtUtc)
			add(key .. "-provenance", "Last known " .. kind .. " source: " .. label(observation.selection, "selection unknown", 32)
				.. " · persisted leaf: " .. label(observation.selectedLeafId, "unknown / none", 100)
				.. (if observation.complete == true then " · complete at that observation"
					elseif observation.complete == false then " · partial at that observation" else " · completeness unknown"))
			coverage(key .. "-coverage", "Last known " .. kind .. " coverage", observation.coverage)
			if kind == "request" then
				questionCoverage(key .. "-question-coverage", "Last known request question coverage", observation.questionCoverage)
			end
			lines = content
		end
		local final, finalKnown, finalObservation = sourceField(source, "lastFinal")
		finalKnown = finalKnown or unavailable or row.stale
		lines = replies
		if final then
			add("final", (if finalKnown then "Last known · " else "") .. label(final.text, "Final text unavailable", 300))
			clock("final-time", evidenceTitle(if final.timeKind == "completed" then "Final completed" else "Final recorded", finalKnown), final.atUtc)
			if finalKnown then historical("final", "final", finalObservation) end
		end
		local assistant, assistantKnown, assistantObservation = sourceField(source, "lastAssistant")
		assistantKnown = assistantKnown or unavailable or row.stale
		lines = updates
		if assistant and (not final or assistant.id ~= final.id) then
			add("assistant", (if assistantKnown then "Last known · " else "") .. label(assistant.text, "Assistant text unavailable", 300))
			clock("assistant-time", evidenceTitle("Assistant recorded", assistantKnown), assistant.atUtc)
			if assistantKnown then historical("assistant", "assistant", assistantObservation) end
		end
		lines = history
		local terminal, terminalKnown, terminalObservation = sourceField(source, "lastTerminal")
		terminalKnown = terminalKnown or unavailable or row.stale
		if terminal then
			add("terminal", evidenceTitle("Terminal", terminalKnown) .. ": "
				.. label(terminal.stopReason, "unknown", 32) .. " · not whole-scope completion")
			clock("terminal-time", evidenceTitle("Terminal recorded", terminalKnown), terminal.atUtc)
			if terminalKnown then historical("terminal", "terminal", terminalObservation) end
		end
		local human, humanKnown, humanObservation = sourceField(source, "lastHuman")
		humanKnown = humanKnown or unavailable or row.stale
		if human then
			clock("human-time", evidenceTitle(if human.provenance == "user" then "Human input recorded" else "User-role input recorded · attribution unknown",
				humanKnown), human.atUtc)
			if humanKnown then historical("human", "human input", humanObservation) end
		end
		local interaction, interactionKnown, interactionObservation = sourceField(source, "lastInteractionAtUtc", "lastInteraction")
		interactionKnown = interactionKnown or unavailable or row.stale
		if interaction then
			clock("interaction-time", evidenceTitle("Human interaction recorded", interactionKnown), interaction)
			if interactionKnown then historical("interaction", "human interaction", interactionObservation) end
		end
		local questionOrder = sourceQuestions(source)
		table.sort(questionOrder, function(a, b)
			local ag = if a.question.status == "open" then (if a.lastKnown then 1 else 0)
				elseif a.question.status == "unknown" then 2 else 3
			local bg = if b.question.status == "open" then (if b.lastKnown then 1 else 0)
				elseif b.question.status == "unknown" then 2 else 3
			return if ag ~= bg then ag < bg else a.order > b.order
		end)
		for index, entry in ipairs(questionOrder) do
			entry.lastKnown = entry.lastKnown or unavailable or row.stale
				or row.nativeState == "working" or row.reviewSuperseded == true and not requestFirst
			local question = entry.question
			lines = if question.status == "open" or question.status == "unknown" then requests else history
			local automatic = question.answerProvenance == "automatic"
			local status = if automatic then "automatically resolved"
				elseif question.status == "answered" and question.answerProvenance == "user" then "answered by user"
				else label(question.status, "unknown", 24)
			local prefix = evidenceTitle("Request", entry.lastKnown) .. " "
			add("question-" .. index, prefix .. status .. (if automatic and question.timedOut then " · timeout" else "")
				.. ": " .. label(question.text, "Question unavailable", 2000))
			clock("question-time-" .. index, evidenceTitle("Question recorded", entry.lastKnown), question.askedAtUtc)
			if question.answer ~= nil then
				local caption = if automatic then "Automatic selection (not a human reply)"
					elseif question.answerProvenance == "user" then "Recorded user answer"
					else "Recorded answer · attribution unknown"
				add("answer-" .. index, evidenceTitle(caption, entry.lastKnown) .. ": " .. label(question.answer, "(empty recorded answer)", 2000))
			end
			if automatic then
				clock("resolution-time-" .. index, evidenceTitle("Automatic resolution recorded", entry.lastKnown), question.resolvedAtUtc)
			elseif question.answeredAtUtc then
				clock("answer-time-" .. index, evidenceTitle(if question.answerProvenance == "user" then "User answer recorded" else "Answer recorded · attribution unknown",
					entry.lastKnown), question.answeredAtUtc)
			end
			if question.cancelledAtUtc then clock("cancel-time-" .. index, evidenceTitle("Cancellation recorded", entry.lastKnown), question.cancelledAtUtc) end
			if entry.lastKnown then historical("question-" .. index, "request", entry.observation) end
		end
	end
	local orderedLines = {}
	local function append(group, decision)
		for _, line in ipairs(group) do
			if decision then line.p.role = "attention.evidence" end
			table.insert(orderedLines, line)
		end
	end
	if requestFirst then
		append(requests, true)
		append(tracking)
		append(replies)
		append(updates)
	elseif row.nativeState ~= "working" and row.reviewSuperseded ~= true then
		if row.reviewKind == "update" then append(updates, true); append(replies, true)
		else append(replies, true); append(updates, true) end
		append(tracking)
		append(requests)
	else
		append(tracking)
		append(replies)
		append(updates)
		append(requests)
	end
	append(history)
	append(diagnostics)
	return node("col", { key = "disclosure", role = "attention.disclosure", gap = "xs" }, orderedLines)
end

local function openable(row)
	return row.navigable == true or row.retryableHeaderRoute == true and row.pane ~= nil
end

-- Patches address keyed paths split on ".", so every byte outside [A-Za-z0-9] of a row key is escaped.
local function nodeKey(key)
	return (string.gsub(key, "[^%w]", function(char) return string.format("_%02x", string.byte(char)) end))
end

local function placesLabel(count)
	return count .. (if count == 1 then " place" else " places")
end

function view.render(renderer, logical, presentation, options)
	options = options or {}
	local section = logical.section
	local rows = sectionItems(logical, presentation, options, section)
	local first = logical.starts[section] or 1
	local last = math.min(#rows, first + PAGE_SIZE - 1)
	local page = logical.pages[section]
	local pages = math.max(1, math.ceil(#rows / PAGE_SIZE))
	local now = options.now or 0
	local selection = section .. ":" .. tostring(logical.settings) .. ":" .. first
		.. ":" .. tostring(logical.expandedWorkId)
	if renderer.arrival and (now >= renderer.arrival.untilTime or logical.settings or section ~= "attention"
		or renderer.selection ~= selection) then renderer.arrival = nil end
	if options.arrival and renderer.initialized and section == "attention" and not logical.settings
		and first <= last and renderer.selection == selection and not renderer.arrival
		and renderer.arrivalRevision ~= presentation.revision then
		renderer.arrivalAgain = not renderer.arrivalAgain
		renderer.arrival = { untilTime = now + 900,
			role = if renderer.arrivalAgain then "attention.rows-arrival" else "attention.rows-arrival-again" }
	end
	local bindings, targets = {}, {}
	local function bind(slot, binding)
		local previous = renderer.targets[slot]
		if not previous or not equal(previous.binding, binding) then
			renderer.counter += 1
			previous = { action = binding.op .. ":" .. renderer.epoch .. ":" .. renderer.counter, binding = binding }
		end
		targets[slot], bindings[previous.action] = previous, binding
		return previous.action
	end
	local function control(key, caption, binding, selected)
		return node("el", { key = key, role = if selected then "attention.selected" else "attention.control",
			tag = "button", text = caption, actions = { click = bind(key, binding) } })
	end
	local attentionCount, laterCount, workingCount = 0, 0, 0
	local reachable, retained, awaitingHeader = 0, 0, 0
	local collisions, byWorkId = {}, {}
	for _, row in ipairs(presentation.rows) do
		byWorkId[row.workId] = row
		if inQueue(row, "later") then laterCount += 1 end
		if inQueue(row, "attention") then attentionCount += 1 end
		if inQueue(row, "working") then workingCount += 1 end
		if row.attention == true and row.disposition ~= "later" then
			if row.navigable then reachable += 1 elseif openable(row) then awaitingHeader += 1 end
		end
		if not row.pane and row.retained then retained += 1 end
		local key = label(row.title, "Untitled conversation") .. "\n" .. label(row.sessionName, "Unknown session")
		collisions[key] = (collisions[key] or 0) + 1
	end

	-- One tracked conversation: an Attention, Later or Working queue row, a Workspace conversation leaf, or a saved
	-- conversation without an open pane. Only the Attention queue acknowledges review (`open`); every other
	-- activation is the navigation-only `route-open`.
	local function conversationNode(item, row, mode)
		local nav = item.navRow
		local queue = mode == "attention" or mode == "later" or mode == "working"
		local title, session = label(row.title, "Untitled conversation"), label(row.sessionName, "Unknown session")
		local host = label(row.hostName, "unknown host", 100)
		local currentCondition = condition(row)
		local runtime = runtimeWords(row)
		local settled = row.disposition == "later" or row.disposition == "reference" or row.disposition == "finished"
		local reason = if not queue or currentCondition or row.nativeState == "working" or settled then ""
			elseif row.sourceQuestionCurrent == true then label(row.reason, "Source question recorded", 90)
			elseif row.reviewSuperseded == true then "" else label(reviewLabels[row.reviewKind] or row.reason, "", 90)
		if reason == runtime or row.nativeState == "exited" and row.reviewKind == "exited" and row.sourceQuestionCurrent ~= true
			or row.attention ~= true and row.reviewRevision == nil then reason = "" end
		local runtimeTitle
		if row.stale then runtime, runtimeTitle = view.stateText(row) end
		local routePane = if nav then nav.ref.pane else row.pane
		local canOpen
		if queue then canOpen = openable(row)
		elseif mode == "leaf" then canOpen = nav.leaf.availability ~= "offline"
		else canOpen = false end
		local pending = options.navigation
		local navigationPhase = if pending and pending.workId == row.workId and pending.serial == row.serial
			and pending.pane == routePane and pending.identityKey == row.identityKey then pending.phase else nil
		local navigationTitle = if navigationPhase == "queued" then "Waiting for interactive verification before checking this target"
			elseif navigationPhase == "checking" then "Checking target identity and source header before opening"
			elseif navigationPhase == "opening" then "Opening the verified target"
			elseif navigationPhase == "confirming" then "Confirming the focused target with a fresh source header"
			else nil
		local navigationText = if navigationPhase == "queued" then "Waiting…"
			elseif navigationPhase == "checking" then "Checking…"
			elseif navigationPhase == "opening" then "Opening…"
			elseif navigationPhase == "confirming" then "Confirming…" else nil
		local unavailable = if mode == "leaf" then "Host offline"
			else friendlyUnavailable[row.unavailableReason] or label(row.unavailableReason, if not row.pane and row.retained then "No open pane" else "Target unavailable", 80)
		local qualifiers = {}
		if queue then
			if row.localHost ~= true or host == "unknown host" or (collisions[title .. "\n" .. session] or 0) > 1 then table.insert(qualifiers, host) end
			if (collisions[title .. "\n" .. session] or 0) > 1 then table.insert(qualifiers, "#" .. row.serial) end
			if not row.navigable then table.insert(qualifiers, unavailable) end
		end
		local identity = {
			workId = row.workId, serial = row.serial, pane = row.pane, identityKey = row.identityKey,
			reviewRevision = row.reviewRevision,
			sourceSessionId = row.sourceSessionId,
		}
		local function rowAction(op)
			local binding = table.clone(identity)
			if op == "route-open" then
				binding.reviewRevision = nil
				binding.pane = routePane
			end
			binding.op = op
			return bind(item.key .. ":" .. op, binding)
		end
		local dim = not queue and settled
		local wide = options.position == "bottom"
		local titleNode = text("title", if dim then "workspace.title-dim" else "attention.title", title)
		titleNode.p.truncate, titleNode.p.title = "end", title
		local summary = { titleNode }
		if navigationTitle then
			local pendingNode = text("navigation-pending", "attention.navigation-pending", navigationText)
			pendingNode.p.title, pendingNode.p.truncate, pendingNode.p.wrap = navigationTitle, nil, nil
			table.insert(summary, pendingNode)
		end
		-- Bottom strip: the session is a bold column spanning both lines, the title above the metadata beside it.
		-- A left or right rail is too narrow for a column, so the session stays the first item of line two.
		local summaryRow = node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, summary)
		local metadata = {}
		if queue and not wide then
			local sessionNode = text("session", "attention.session", session)
			sessionNode.p.title = session
			table.insert(metadata, sessionNode)
		end
		if reason ~= "" then
			local reasonNode = text("reason", "attention.reason", "(" .. reason .. ")")
			reasonNode.p.title = reason
			table.insert(metadata, reasonNode)
		end
		if nav and nav.context then
			local context = text("context", "workspace.context", label(nav.context, "", 160))
			context.p.title, context.p.truncate, context.p.wrap = context.p.text, nil, nil
			table.insert(metadata, context)
		end
		if #qualifiers > 0 then
			local qualifier = text("qualifiers", "attention.qualifiers", table.concat(qualifiers, " · "))
			qualifier.p.title = qualifier.p.text
			table.insert(metadata, qualifier)
		end
		local clock, clockTitle, clockRecorded
		if row.disposition == "later" then clock, clockTitle = availability(row), nil
		else clock, clockTitle, clockRecorded = primaryAge(row, options.nowUtc) end
		if finite(row.priority) and row.priority >= 0 and row.priority <= 3 and row.priority % 1 == 0 then
			table.insert(metadata, text("priority", "attention.priority", "P" .. row.priority))
		end
		if clock then
			local ageNode = text("age", if clockRecorded then "attention.age-recorded" else "attention.age", clock)
			ageNode.p.title, ageNode.p.truncate, ageNode.p.wrap = clockTitle or clock, nil, nil
			table.insert(metadata, ageNode)
		end
		local runtimeNode = text("runtime", "attention.runtime", runtime)
		runtimeNode.p.title, runtimeNode.p.truncate, runtimeNode.p.wrap = runtimeTitle, nil, nil
		table.insert(metadata, runtimeNode)
		local metadataRow = node("row", { key = "metadata", role = "attention.metadata", gap = "xs", wrap = true }, metadata)
		local baseline
		if wide then
			local sessionName = text("name", "attention.session-name", session)
			sessionName.p.truncate, sessionName.p.title = "end", session
			baseline = { node("row", { key = "cells", role = "attention.cells", gap = "sm", wrap = false }, {
				node("row", { key = "session-cell", role = "attention.session-cell", gap = "none", wrap = false }, { sessionName }),
				node("col", { key = "body", role = "attention.body", gap = "none" }, { summaryRow, metadataRow }),
			}) }
		else
			baseline = { summaryRow, metadataRow }
		end
		local openOp = if mode == "attention" then "open" else "route-open"
		local open = node("el", {
			key = "open", role = if navigationTitle then "attention.open-pending" elseif canOpen then "attention.open" else "attention.unavailable", tag = "button",
			title = (if navigationTitle then navigationTitle .. " · " elseif mode ~= "attention" and canOpen then "Go to · "
				elseif row.navigable then "Open · "
				elseif canOpen then "Verify header, then open · " else unavailable .. " · ")
				.. title .. " · " .. session .. " · " .. host .. " · " .. reason .. " · " .. label(row.context, "Context unknown", 256),
			actions = if canOpen and not navigationTitle then { click = rowAction(openOp) } else nil,
		}, baseline)
		local expanded = logical.expandedWorkId == row.workId and (mode ~= "leaf" or nav.leaf.conversation.preferred)
		local disclosure = node("el", { key = "details", role = "attention.triage", tag = "button",
			title = if expanded then "Collapse recorded facts" else "Inspect recorded facts · does not acknowledge or navigate",
			actions = { click = rowAction("details") } },
			{ node("icon", { key = "icon", role = "attention.triage-icon", name = if expanded then "chev" else "chev-r" }) })
		local menu = node("el", { key = "menu", role = "attention.triage", tag = "button",
			title = "Later, priority and explicit tracking disposition", actions = { click = rowAction("menu") } },
			{ node("icon", { key = "icon", role = "attention.triage-icon", name = "more" }) })
		local mainRole = if queue then "attention.row-main"
			elseif nav.leaf and nav.leaf.current then "workspace.main-current" else "workspace.main"
		local mainChildren = { open, disclosure, menu }
		if navigationTitle and type(pending.token) == "string" and pending.token ~= "" then
			table.insert(mainChildren, 2, node("el", {
				key = "cancel-navigation", role = "attention.cancel-navigation", tag = "button", text = "Cancel",
				title = "Cancel this request without acknowledging attention; an active helper may still finish",
				actions = { click = bind(item.key .. ":cancel-navigation", {
					op = "cancel-navigation", token = pending.token, workId = row.workId,
					serial = row.serial, pane = routePane, identityKey = row.identityKey,
				}) },
			}))
		end
		local children = { node("row", { key = "main", role = mainRole, gap = "none", wrap = false }, mainChildren) }
		if expanded then table.insert(children, details(row, options.nowUtc)) end
		return node("col", { key = nodeKey(item.key), role = if queue then "attention.row" else "workspace.row-" .. nav.depth,
			gap = "none" }, children)
	end

	-- A native destination that is not a tracked conversation: note, browser, shell, other pane kinds.
	local function paneNode(navRow)
		local leaf = navRow.leaf
		local title = label(navRow.title, "Pane")
		local canOpen = leaf.availability ~= "offline"
		local titleNode = text("title", "attention.title", title)
		titleNode.p.truncate, titleNode.p.title = "end", title
		local context = text("context", "workspace.context", label(navRow.context, "", 160))
		context.p.title, context.p.truncate, context.p.wrap = context.p.text, nil, nil
		local binding = { op = "workspace-open", key = navRow.ref.key, signature = navRow.signature,
			placement = leaf.placement }
		local open = node("el", {
			key = "open", role = if canOpen then "attention.open" else "attention.unavailable", tag = "button",
			title = (if canOpen then "Go to · " else "Host offline · ") .. title .. " · " .. label(navRow.context, "", 160),
			actions = if canOpen then { click = bind(navRow.key .. ":open", binding) } else nil,
		}, { node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, { titleNode }),
			node("row", { key = "metadata", role = "attention.metadata", gap = "xs", wrap = true }, { context }) })
		return node("col", { key = nodeKey(navRow.key), role = "workspace.row-" .. navRow.depth, gap = "none" }, {
			node("row", { key = "main", role = if leaf.current then "workspace.main-current" else "workspace.main",
				gap = "none", wrap = false }, { open }),
		})
	end

	-- Host, session, tab, section and `Set aside N` rows: a disclosure chevron, an activation target, and for
	-- tabs and sessions the native More menu. Counts are typed; an offline host shows none.
	local function groupNode(navRow)
		local kind = navRow.kind
		local key = nodeKey(navRow.key)
		local role = "workspace.row-" .. navRow.depth
		local title = label(navRow.title, "Untitled", 160)
		local chevron = node("icon", { key = "icon", role = "attention.triage-icon", name = if navRow.expanded then "chev" else "chev-r" })
		if kind == "aside" then
			return node("col", { key = key, role = role, gap = "none" }, {
				node("el", { key = "aside", role = "workspace.aside", tag = "button",
					title = (if navRow.expanded then "Hide set aside conversations" else "Show set aside conversations") .. " · " .. title,
					actions = { click = bind(navRow.key .. ":aside", { op = "workspace-aside", key = navRow.ref.key,
						logicalRevision = logical.revision }) },
				}, { chevron, text("label", "workspace.count", title) }),
			})
		end
		local count = nil
		if navRow.empty then count = "Empty"
		elseif navRow.count ~= nil then
			count = if kind == "section" and navRow.ref.hostKey == nil then navRow.count .. " saved" else placesLabel(navRow.count)
		end
		if kind == "section" then
			local children = { chevron, text("title", "workspace.title", title) }
			if count then table.insert(children, text("count", "workspace.count", count)) end
			return node("col", { key = key, role = role, gap = "none" }, {
				node("el", { key = "toggle", role = "workspace.section", tag = "button",
					title = (if navRow.expanded then "Collapse · " else "Expand · ") .. title,
					actions = { click = bind(navRow.key .. ":toggle", { op = "workspace-toggle", key = navRow.key,
						logicalRevision = logical.revision }) },
				}, children),
			})
		end
		local toggle
		if navRow.expandable then
			toggle = node("el", { key = "toggle", role = "workspace.toggle", tag = "button",
				title = (if navRow.expanded then "Collapse · " else "Expand · ") .. title,
				actions = { click = bind(navRow.key .. ":toggle", { op = "workspace-toggle", key = navRow.key,
					logicalRevision = logical.revision }) },
			}, { chevron })
		else
			toggle = node("el", { key = "toggle", role = "workspace.toggle-none", tag = "span" })
		end
		local summary = { text("title", "workspace.title", title) }
		if count then table.insert(summary, text("count", "workspace.count", count)) end
		if navRow.context then table.insert(summary, text("context", "workspace.context", label(navRow.context, "", 100))) end
		local open = node("el", { key = "open", role = "attention.open", tag = "button",
			title = "Go to · " .. title .. (if count then " · " .. count else ""),
			actions = { click = bind(navRow.key .. ":open", { op = "workspace-open", key = navRow.ref.key,
				signature = navRow.signature }) },
		}, { node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, summary) })
		local parts = { toggle, open }
		if kind == "tab" or kind == "session" then
			table.insert(parts, node("el", { key = "menu", role = "attention.triage", tag = "button",
				title = "Rename or add a tab · " .. title,
				actions = { click = bind(navRow.key .. ":menu", { op = "native-menu", key = navRow.ref.key,
					signature = navRow.signature }) },
			}, { node("icon", { key = "icon", role = "attention.triage-icon", name = "more" }) }))
		end
		return node("col", { key = key, role = role, gap = "none" }, {
			node("row", { key = "main", role = "workspace.main", gap = "none", wrap = false }, parts),
		})
	end

	local rowNodes = {}
	if not logical.settings then
		for index = first, last do
			local item = rows[index]
			local navRow = item.navRow
			if section ~= "workspace" then
				table.insert(rowNodes, conversationNode(item, item.row, section))
			elseif navRow.kind == "leaf" then
				local link = navRow.leaf.conversation
				local row = if link then byWorkId[link.workId] else nil
				table.insert(rowNodes, if row then conversationNode(item, row, "leaf") else paneNode(navRow))
			elseif navRow.kind == "retained" then
				local row = byWorkId[navRow.ref.workId]
				if row then
					table.insert(rowNodes, conversationNode(item, row, "retained"))
				else
					table.insert(rowNodes, node("col", { key = nodeKey(navRow.key), role = "workspace.row-" .. navRow.depth, gap = "none" }, {
						node("row", { key = "main", role = "workspace.main", gap = "none", wrap = false }, {
							node("el", { key = "open", role = "attention.unavailable", tag = "button" }, {
								text("title", "attention.title", label(navRow.title, "Saved conversation")),
								text("context", "workspace.context", label(navRow.context, "", 160)),
							}),
						}),
					}))
				end
			else
				table.insert(rowNodes, groupNode(navRow))
			end
		end
	end

	local queueLabels = { attention = "Attention", later = "Later", working = "Currently working", workspace = "Workspace" }
	local queueTitles = {
		attention = "Attention · " .. attentionCount .. " tracked conversations need attention",
		later = "Later · " .. laterCount .. " set-aside conversations",
		working = "Currently working · " .. workingCount .. " live conversations",
		workspace = "Workspace · every place in this window",
	}
	local counts = { attention = attentionCount, later = laterCount, working = workingCount }
	local queues = {}
	for _, name in ipairs(SECTIONS) do
		local caption = { text("label", "attention.queue-label", queueLabels[name]) }
		if counts[name] then table.insert(caption, text("count", "attention.queue-count", tostring(counts[name]))) end
		table.insert(queues, node("el", {
			key = name, role = if logical.section == name then "attention.queue-selected" else "attention.queue",
			tag = "button", title = queueTitles[name],
			actions = { click = bind("section:" .. name, { op = "section", section = name, logicalRevision = logical.revision }) },
		}, caption))
	end
	local settingsOptions, previous = options.settings or {}, options.previous or {}
	local searchAvailable = options.search ~= nil and options.search.available == true
	local utility = {}
	local tools = {}
	table.insert(tools, node("el", { key = "next", role = if reachable + awaitingHeader > 0 then "attention.next" else "attention.next-unavailable",
		tag = "button", title = "Next attention · " .. shortcutLabel(settingsOptions.shortcut) .. " · " .. reachable
			.. " reachable conversations · " .. awaitingHeader .. " awaiting header verification",
		actions = if reachable + awaitingHeader > 0 then { click = bind("next", { op = "next" }) } else nil,
	}, { node("icon", { key = "icon", role = "attention.next-icon", name = "fast-forward", size = 12 }), text("label", "attention.next-label", "Next") }))
	table.insert(tools, node("el", {
		key = "previous", role = if previous.available then "attention.previous" else "attention.previous-unavailable", tag = "button",
		title = if previous.available then "Previous · Return to " .. label(previous.title, "previous pane", 160) else "Previous · No previous pane yet",
		actions = if previous.available then { click = bind("previous", { op = "previous" }) } else nil,
	}, { node("icon", { key = "icon", role = "attention.previous-icon", name = "rewind", size = 12 }), text("label", "attention.previous-label", "Prev") }))
	table.insert(utility, node("el", { key = "search", role = if searchAvailable then "attention.search" else "attention.search-unavailable",
		tag = "button", title = if searchAvailable then "Search workspace" else "Search unavailable",
		actions = if searchAvailable then { click = bind("search", { op = "search", logicalRevision = logical.revision }) } else nil,
	}, { node("icon", { key = "icon", role = "attention.search-icon", name = "search", size = 16 }) }))
	table.insert(utility, node("el", { key = "settings", role = if logical.settings then "attention.gear-selected" else "attention.gear", tag = "button",
		title = if logical.settings then "Return to " .. queueLabels[logical.section] else "More · Settings",
		actions = { click = bind("settings", { op = "settings", logicalRevision = logical.revision }) },
	}, { node("icon", { key = "icon", role = "attention.gear-icon", name = "gear", size = 16 }) }))
	-- The current-location line belongs to Workspace alone; every other section keeps the keyed node but empty and hidden.
	local current = options.current
	local location
	if section ~= "workspace" or logical.settings then
		location = node("row", { key = "location", role = "attention.location-none", gap = "xs", wrap = false, hidden = true }, {})
	elseif current then
		local currentTitle = label(current.title, "Untitled", 160)
		local currentContext = label(current.context, "", 160)
		location = node("el", { key = "location", role = "attention.location", tag = "button",
			title = "Reveal in Workspace · " .. currentTitle .. (if currentContext ~= "" then " · " .. currentContext else ""),
			actions = { click = bind("reveal", { op = "reveal" }) },
		}, { text("title", "attention.location-title", currentTitle), text("context", "attention.location-context", currentContext) })
	else
		location = node("row", { key = "location", role = "attention.location-none", gap = "xs", wrap = false },
			{ text("title", "attention.location-title", "No current location") })
	end
	local function pageControl(key, caption, title, delta)
		return node("el", { key = key, role = "attention.page-control", tag = "button", text = caption, title = title,
			actions = { click = bind(key, { op = "page", delta = delta, section = section, logicalRevision = logical.revision }) } })
	end
	-- One fixed group above the scrolled list: the toolbar, the location line and, when more than one page exists,
	-- the pager. styles.css bounds the root and scrolls only the list, so none of it is sticky content (native sticky
	-- painting is culled once the scroll offset passes about a screen). The first row keeps its right edge free for
	-- the native pane grip.
	local footer = {}
	if (first > 1 or last < #rows) and not logical.settings then
		table.insert(footer, text("range", "attention.pager-range", first .. "–" .. last .. " of " .. #rows))
		if first > 1 then table.insert(footer, pageControl("page-prev", "‹ Prev", "Previous page · " .. PAGE_SIZE .. " per page", -1)) end
		if last < #rows then table.insert(footer, pageControl("page-next", "Next ›", "Next page · " .. PAGE_SIZE .. " per page", 1)) end
	end
	local pagination = node("row", { key = "pagination", role = "attention.pagination", gap = "sm", wrap = false, hidden = #footer == 0 }, footer)
	local header = node("col", { key = "header", role = "attention.header", gap = "none" }, {
		node("row", { key = "queues", role = "attention.queues", gap = "sm", wrap = true }, queues),
		node("row", { key = "tools", role = "attention.tools", gap = "sm", wrap = true }, tools),
		location,
		pagination,
		node("row", { key = "utility", role = "attention.utility", gap = "xs", wrap = false }, utility),
	})
	local settingsNodes = {}
	if logical.settings then
		local afterSeconds = settingsOptions.backlogAfterSeconds or 0
		local ageControls = { control("age-never", "Never", { op = "age", seconds = 0 }, afterSeconds == 0) }
		for _, hours in ipairs({ 3, 6, 12, 24 }) do
			table.insert(ageControls, control("age-" .. hours, hours .. "h", { op = "age", seconds = hours * 3600 }, afterSeconds == hours * 3600))
		end
		table.insert(settingsNodes, text("heading", "attention.settings-title", "Settings"))
		table.insert(settingsNodes, node("row", { key = "aging", role = "attention.setting", gap = "md", wrap = true }, {
			node("col", { key = "info", role = "attention.setting-info", gap = "xs" }, {
				text("label", "attention.setting-label", "Automatic age-to-Later"),
				text("description", "attention.explanation", "Legacy observation age · not source age or a deadline. Applies globally."),
			}), node("row", { key = "options", role = "attention.setting-options", gap = "none", wrap = false }, ageControls),
		}))
		local defaultPosition = settingsOptions.defaultPosition or "bottom"
		local defaultLabel = defaultPosition:sub(1, 1):upper() .. defaultPosition:sub(2)
		table.insert(settingsNodes, node("row", { key = "placement", role = "attention.setting", gap = "md", wrap = true }, {
			node("col", { key = "info", role = "attention.setting-info", gap = "xs" }, {
				text("label", "attention.setting-label", "Rail placement"),
				text("state", "attention.explanation", "Default for new tabs: " .. defaultLabel .. "."),
				text("description", "attention.explanation",
					"One tab elsewhere? The palette's Use … in this tab relayouts just that tab. Nothing moves on its own."),
			}), node("row", { key = "options", role = "attention.placement-controls", gap = "sm", wrap = true }, {
				control("default-bottom", "Bottom", { op = "default", position = "bottom" }, defaultPosition == "bottom"),
				control("default-right", "Right", { op = "default", position = "right" }, defaultPosition == "right"),
				control("default-left", "Left", { op = "default", position = "left" }, defaultPosition == "left"),
			}),
		}))
		table.insert(settingsNodes, text("tracking-note", "attention.explanation", "More offers Later/date, priority, reference and Finished for now. Reference and Finished stay until Resume tracking."))
		table.insert(settingsNodes, text("open-note", "attention.explanation", "Open clears only the displayed new-update revision after navigation. It does not answer a request or prove reading or completion."))
		table.insert(settingsNodes, text("shortcut", "attention.explanation", "Next attention · " .. shortcutLabel(settingsOptions.shortcut) .. " · skips Later; leaves this view unchanged"))
	end
	local settings = node("col", { key = "settings", role = "attention.settings", gap = "none", hidden = not logical.settings }, settingsNodes)
	local coverageLines = {}
	local function coverageLine(key, value)
		if value and value ~= "" then table.insert(coverageLines, text(key, "attention.context", bounded(value, 260))) end
	end
	local status = presentation.status
	if status == "loading" then coverageLine("status", "Loading conversation state · total unknown")
	elseif status == "unsaved" then coverageLine("status", "Attention changes not saved")
	elseif status == "unavailable" then coverageLine("status", "Conversation state unavailable · last known evidence only") end
	coverageLine("message", presentation.message)
	coverageLine("notice", options.notice)
	local coverage = node("col", { key = "coverage", role = "attention.coverage", gap = "xs", hidden = #coverageLines == 0 }, coverageLines)
	local rowsNode = node("col", { key = "rows", role = if renderer.arrival then renderer.arrival.role
		elseif section == "attention" and #rowNodes > 0 then "attention.rows-occupied" else "attention.rows", gap = "none", hidden = logical.settings }, rowNodes)
	-- Only Workspace explains an empty list (missing inventory); empty conversation queues show nothing at all.
	local empty = text("empty", "attention.empty", if section == "workspace" then "No workspace places" else "")
	empty.p.hidden = section ~= "workspace" or #rows > 0 or logical.settings or status == "unavailable" or status == "loading"
	local root = node("col", { role = "attention.root", gap = "none" }, { header, coverage, rowsNode, empty, settings })
	local nextScreen = { view = root }
	local previousScreen = renderer.previous
	renderer.previous, renderer.bindings, renderer.targets = nextScreen, bindings, targets
	renderer.initialized, renderer.logicalRevision, renderer.selection = true, logical.revision, selection
	if options.arrival or not previousScreen then renderer.arrivalRevision = presentation.revision end
	local info = { page = page, pages = pages, shown = #rowNodes, total = presentation.count,
		section = section, settings = logical.settings, sectionCount = #rows,
		attentionCount = attentionCount, laterCount = laterCount, workingCount = workingCount, reachableCount = reachable,
		awaitingHeaderCount = awaitingHeader }
	if not previousScreen then return nextScreen, bindings, info end
	local patches = {}
	for _, index in ipairs({ 1, 2, 4, 5 }) do
		if not equal(previousScreen.view.c[index], root.c[index]) then patches[root.c[index].p.key] = root.c[index] end
	end
	local oldRows, oldKeys = previousScreen.view.c[3].c, {}
	for _, oldRow in ipairs(oldRows) do oldKeys[oldRow.p.key] = oldRow end
	local newKeys, surviving, appended = {}, {}, 0
	local appendStarted, needsOrder = false, false
	for _, rowNode in ipairs(rowNodes) do
		local key = rowNode.p.key
		newKeys[key] = rowNode
		if oldKeys[key] then
			table.insert(surviving, key)
			if appendStarted then needsOrder = true end
		else appendStarted, appended = true, appended + 1 end
	end
	local survivorIndex = 0
	for _, oldRow in ipairs(oldRows) do
		if newKeys[oldRow.p.key] then
			survivorIndex += 1
			if surviving[survivorIndex] ~= oldRow.p.key then needsOrder = true end
		end
	end
	if appended > 1 or needsOrder or not equal(previousScreen.view.c[3].p, rowsNode.p) then patches.rows = rowsNode
	else
		for key, oldRow in pairs(oldKeys) do
			if not newKeys[key] then patches["rows." .. key] = false
			elseif not equal(oldRow, newKeys[key]) then patches["rows." .. key] = newKeys[key] end
		end
		for key, rowNode in pairs(newKeys) do if not oldKeys[key] then patches["rows." .. key] = rowNode end end
	end
	return if next(patches) then { set = patches } else nil, bindings, info
end

return view
