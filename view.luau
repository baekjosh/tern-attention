local phone = require("./phone")
local navigation = require("./navigation")

local view = {}
-- One canvas emits at most MAX_CANVAS_ROWS rows across every section, and its whole update stays under
-- MAX_CANVAS_NODES native nodes (the native cap is 2000; CHROME_NODES is reserved for the toolbar, headers, section
-- heads, notices and the footer, which together build well under it). Whatever does not fit is counted in one footer
-- row, never dropped silently.
local MAX_CANVAS_ROWS = 200
local MAX_CANVAS_NODES = 1500
local CHROME_NODES = 150
local SECTIONS = { "attention", "working", "workspace" }
local MAX_UI_KEYS, MAX_UI_KEY = 512, 256
-- Left/right rails are a two-region stack (attention stack above, Workspace below) in one native `split`. Each
-- region keeps at least a section header and three rows; the divider between them is dragged natively.
local REGION_MIN = 140
-- The top share at rest (the queues a third) and while the Workspace tree is minimized to its header.
local DEFAULT_SHARE, MINIMIZED_SHARE = 1 / 3, 0.9
local LOCAL_HOST_KEY = "local"
-- Native keeps a user-dragged fraction until the program sends a DIFFERENT `sizes` array, so a share change that
-- lands on the value already sent would be ignored after a drag. Every change flips this nudge to differ.
local SHARE_NUDGE = 0.0001
local QUEUE_SECTIONS = { "attention", "working" }
local QUEUE_SECTION_SET = { attention = true, working = true }
-- When a Working row's second line speaks, by what its agent waits on (measured over a month of omp sessions:
-- model calls reach 13.9m at p99.9; `wait` runs to its 30m cap and bash to its own timeout, so a long tool is
-- normal and a stall only far past those). A tool shows by name after toolShown; Stalled after model/tool.
local STALL = { modelSeconds = 900, toolSeconds = 3600, toolShownSeconds = 60 }

-- The stored queue order, or the default when absent/foreign: exactly the two queues, each once.
-- Preferences are validated at parse; this only guarantees the renderer a complete order.
local function queueOrderOf(value)
	local order = {}
	if type(value) == "table" then
		for _, name in ipairs(value) do
			if QUEUE_SECTION_SET[name] and not table.find(order, name) then table.insert(order, name) end
		end
	end
	for _, name in ipairs(QUEUE_SECTIONS) do
		if not table.find(order, name) then table.insert(order, name) end
	end
	return order
end

local function node(kind, props, children)
	return { k = kind, p = props, c = children }
end

local function text(key, role, value)
	return node("text", { key = key, role = role, text = value, wrap = "none", truncate = "end" })
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

-- A stale row with no live pane has lost its source: its runtime and clock are the last recorded ones and say so.
-- A stale row whose pane is still live only awaits proof, so it keeps its runtime words and its Open waits.
local function offlineRow(row)
	return row.stale == true and row.live ~= true
end

local function inQueue(row, section)
	-- A set-aside conversation (kept as reference, finished) or a record with no live route sits in no queue:
	-- Search and the Workspace tree's saved conversations still reach it.
	return (section == "attention" and row.attention == true)
		-- A usage or rate limit with a known end rests out of Attention, folded at its bottom, until it passes.
		or (section == "resting" and row.resting ~= nil and row.attention ~= true)
		-- A pane matched to the live inventory is working. Its source or identity proof gates Open, not membership.
		or (section == "working" and row.nativeState == "working" and row.live == true
			and not row.offline and not row.noOpenPane and not row.orphaned)
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
			local aq, bq = a.queueOrder or a.serial, b.queueOrder or b.serial
			return if aq ~= bq then aq < bq else a.serial < b.serial
		end)
	end
	return rows
end

-- Every row fact `derive` reads, projected to the exact values the filters and sorts consume, so equal facts
-- guarantee the identical list for every section.
local FACTS = 10
local function facts(item)
	return
		(if item.attention == true then 1 else 0),
		(if item.nativeState == "working" then 1 else 0),
		(if item.live == true then 1 else 0),
		(if item.offline then 1 else 0),
		(if item.noOpenPane then 1 else 0),
		(if item.orphaned then 1 else 0),
		(if item.condition or item.nativeState == "waiting_input" then 1 else 0),
		(item.priority or 4),
		(item.queueOrder or item.serial),
		item.serial
end

local function stampRows(rows)
	local stamp = table.create(#rows * FACTS)
	for index, item in ipairs(rows) do
		local f1, f2, f3, f4, f5, f6, f7, f8, f9, f10 = facts(item)
		local at = (index - 1) * FACTS
		stamp[at + 1], stamp[at + 2], stamp[at + 3], stamp[at + 4] = f1, f2, f3, f4
		stamp[at + 5], stamp[at + 6], stamp[at + 7], stamp[at + 8] = f5, f6, f7, f8
		stamp[at + 9], stamp[at + 10] = f9, f10
	end
	return stamp
end

local function stampCurrent(stamp, rows)
	for index, item in ipairs(rows) do
		local f1, f2, f3, f4, f5, f6, f7, f8, f9, f10 = facts(item)
		local at = (index - 1) * FACTS
		if stamp[at + 1] ~= f1 or stamp[at + 2] ~= f2 or stamp[at + 3] ~= f3 or stamp[at + 4] ~= f4
			or stamp[at + 5] ~= f5 or stamp[at + 6] ~= f6 or stamp[at + 7] ~= f7 or stamp[at + 8] ~= f8
			or stamp[at + 9] ~= f9 or stamp[at + 10] ~= f10
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
view.inQueue = inQueue

local function stackedPlacement(options)
	return options ~= nil and (options.position == "left" or options.position == "right")
end

-- Navigation reads `collapsed[key] == true` as closed and anything else as open. A left/right rail starts with its
-- sessions collapsed, except this Mac's, which open in full (sessions and tabs). A stored value (true
-- collapsed, false opened) always wins over these defaults, so only never-toggled session keys are filled in.
local function workspaceUi(logical, snapshot, stacked)
	if not stacked then return logical.workspace end
	local collapsed = table.clone(logical.workspace.collapsed)
	for _, host in ipairs(snapshot.hosts) do
		local localOpen = host.hostKey == LOCAL_HOST_KEY
		for _, session in ipairs(host.sessions) do
			if collapsed[session.key] == nil and not localOpen then collapsed[session.key] = true end
		end
	end
	return { collapsed = collapsed }
end

-- Every section's rows, keyed for the canvas: conversation queues use "r"..serial, the Workspace tree its
-- navigation row keys. Nothing pages; render emits them all, up to the canvas row and node budget.
local function sectionItems(logical, presentation, options, section)
	local items = {}
	if section == "workspace" then
		local snapshot = if options then options.workspace else nil
		if snapshot then
			local ui = workspaceUi(logical, snapshot, stackedPlacement(options))
			for _, navRow in ipairs(navigation.rows(snapshot, ui).rows) do
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
		workspace = { collapsed = {} },
		-- Top share of the left/right two-region divider; `nonce` makes every share change send a different array.
		divider = { share = DEFAULT_SHARE, nonce = 0 },
		revision = 1, intentRevision = 1,
	}
end

function view.newRenderer(epoch)
	return { epoch = epoch, counter = 0, bindings = {}, targets = {}, initialized = false }
end

function view.invalidate(renderer, retryPaint)
	renderer.previous, renderer.arrival, renderer.arrivalRevision, renderer.inputs = nil, nil, nil, nil
	renderer.bindings, renderer.targets = {}, {}
	renderer.initialized = retryPaint == true and renderer.initialized == true
end

function view.section(logical, section)
	assert(section == "attention" or section == "workspace" or section == "working" or section == "settings", "Unknown Attention section")
	if section == "settings" then logical.settings = not logical.settings
	elseif logical.section == section and not logical.settings then return
	else logical.section, logical.settings = section, false end
	logical.revision += 1
	logical.intentRevision += 1
end

-- Explicit disclosure changes publish a new view and fence captured async actions, like any other intent.
-- `collapsed[key]`: true closed, false opened, nil the key's default (expanded, except sessions in a left/right
-- rail). A caller that knows the state the user saw passes it as `expanded`, so the toggle always flips what was
-- displayed; without it the key flips between closed and its default.
function view.toggleGroup(logical, key, expanded)
	assert(type(key) == "string" and key ~= "", "Workspace group key unavailable")
	assert(expanded == nil or type(expanded) == "boolean", "Workspace group state unavailable")
	local collapsed = logical.workspace.collapsed
	if expanded == nil then collapsed[key] = if collapsed[key] then nil else true
	else collapsed[key] = expanded end
	logical.revision += 1
	logical.intentRevision += 1
end

-- Going to a session restores it: a minimized session you open (by name, its tab count, its +, or No tabs) comes
-- back to its place. Layout only, like revealQueue. Returns whether anything changed.
-- Stored as an explicit false: a left/right rail minimizes other hosts' sessions by default (workspaceUi), and
-- only a stored value overrides that.
function view.restoreGroup(logical, key)
	if string.sub(key, 1, 8) ~= "session:" or logical.workspace.collapsed[key] == false then return false end
	logical.workspace.collapsed[key] = false
	logical.revision += 1
	return true
end

-- A conversation arrived in queue section `name` (Working or Attention): a folded section opens so the arrival is
-- seen without a click. The user can fold it again; the next arrival reopens it. Layout only, like the divider: it
-- publishes a new view without fencing captured navigation intents. Returns whether anything changed.
function view.revealQueue(logical, name)
	local key = "queue:" .. name
	if logical.workspace.collapsed[key] ~= true then return false end
	logical.workspace.collapsed[key] = nil
	logical.revision += 1
	return true
end

-- Sets the left/right divider's top share. Layout only, so it publishes a new view without fencing captured
-- navigation intents.
function view.divider(logical, share)
	assert(finite(share) and share > 0 and share < 1, "Divider share unavailable")
	logical.divider = { share = share, nonce = logical.divider.nonce + 1 }
	logical.revision += 1
end

-- Folds the Workspace tree into its header (the top share moves to MINIMIZED_SHARE and the rows hide), or restores
-- the share that was showing. The flag rides on divider state, so any share change clears it.
function view.minimizeWorkspace(logical)
	local divider = logical.divider
	if divider.minimized == true then
		view.divider(logical, divider.restore or DEFAULT_SHARE)
	else
		view.divider(logical, MINIMIZED_SHARE)
		logical.divider.minimized, logical.divider.restore = true, divider.share
	end
end

-- The only persisted navigator state (D3): the last section and the disclosure set. Search, expansion and the
-- settings panel are memory-only.
function view.ui(logical)
	local ui = { section = logical.section, collapsed = {} }
	for key, closed in pairs(logical.workspace.collapsed) do ui.collapsed[key] = closed end
	return ui
end

-- `tri` keeps explicit `false` (opened against a closed default) as well as `true`.
local function restoredKeys(saved, tri)
	local keys = {}
	if type(saved) == "table" then
		for key, open in pairs(saved) do
			if type(key) == "string" and key ~= "" and #key <= MAX_UI_KEY and (open == true or tri and open == false) then
				table.insert(keys, key)
			end
		end
	end
	table.sort(keys)
	local kept = {}
	for index = 1, math.min(#keys, MAX_UI_KEYS) do kept[keys[index]] = saved[keys[index]] end
	return kept
end

local function countKeys(map)
	local count = 0
	for _ in pairs(map) do count += 1 end
	return count
end

-- A long-lived VM keeps every disclosure key ever toggled; the same cap restore and the persisted sanitizer
-- apply (512 sorted keys) bounds the live maps during normalization, with key order alone deciding eviction.
local function boundedKeys(map, tri)
	if countKeys(map) <= MAX_UI_KEYS then return map, false end
	return restoredKeys(map, tri), true
end

local function boundDisclosures(logical)
	local collapsed, over = boundedKeys(logical.workspace.collapsed, true)
	if not over then return false end
	logical.workspace.collapsed = collapsed
	return true
end

-- Applies a persisted value to a fresh state; anything unrecognized falls back to Attention with no
-- disclosures, and nothing transient is ever restored.
function view.restore(logical, saved)
	local section, collapsed = "attention", {}
	if type(saved) == "table" then
		for _, name in ipairs(SECTIONS) do
			if saved.section == name then section = name end
		end
		collapsed = restoredKeys(saved.collapsed, true)
	end
	logical.section, logical.settings = section, false
	logical.workspace = { collapsed = collapsed }
	logical.expandedWorkId = nil
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

function view.normalize(logical, presentation)
	local changed, existing = false, {}
	-- Capping can re-expand groups, a visible change like a toggle, so it dirties the view revision.
	if boundDisclosures(logical) then changed = true end
	for _, row in ipairs(presentation.rows) do existing[row.workId] = true end
	if logical.expandedWorkId and not existing[logical.expandedWorkId] then
		logical.expandedWorkId, changed = nil, true
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
	-- Only a clock the reader cannot support is recorded; a newer omp writer alone never qualifies the time.
	return historyUnavailable(observation) or observation.clockSupport == "unknown"
		or type(coverage) == "table" and type(coverage.fields) == "table" and coverage.fields.clock == "unknown"
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
	local fields = if type(source.coverage) == "table" then source.coverage.fields else nil
	local unqualified = type(fields) == "table" and fields.questions == "unknown"
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
	local offline = offlineRow(row)
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
	["source header proof pending"] = "Checking identity",
	["coverage unavailable"] = "Coverage unavailable", disconnected = "Host offline",
}

local function runtimeWords(row)
	return conditionLabels[condition(row)] or runtimeLabels[row.nativeState] or "Runtime unknown"
end

-- The state words a conversation row shows (`Waiting for input`, `Offline · idle`) and, when offline, why. A stale row
-- whose pane is still live is not offline: its words are the last runtime the model observed, and Open waits for proof.
function view.stateText(row)
	local words = runtimeWords(row)
	if offlineRow(row) then
		return "Offline · " .. string.lower(words), "Offline: shown from the last recorded state, which cannot be refreshed right now."
	end
	return words
end

-- A rail row's state marker says only what is abnormal, in one short word; the full runtime sentence moves to
-- the row's tooltip. Working and Idle are normal and render no marker. A stale row with no live pane is Offline.
local conditionMarkers = { waiting = "Waiting", delivery = "Undelivered", startup = "Failed" }
local runtimeMarkers = { waiting_input = "Waiting", exited = "Exited", unknown = "Unknown" }
local priorityNames = { "P0 Now", "P1 Next", "P2 Planned", "P3 Optional" }

local function stateMarker(row)
	if offlineRow(row) then return "Offline" end
	local blocker = conditionMarkers[condition(row)]
	if blocker then return blocker end
	local state = row.nativeState
	if state == "idle" or state == "working" then return nil end
	return runtimeMarkers[state] or "Unknown"
end

-- Line two of a rail queue row: model · need · age, with a separator only between present parts. The need is the
-- model's own worded phrase (`row.need`, model.luau); the view decides only whether a Working row has stalled. CSS
-- truncates the need first, then the model; the age never truncates and keeps its full sentence in its tooltip.
local function railDetail(row, model, ageNode, nowUtc)
	local parts = {}
	local function add(item)
		if #parts > 0 then
			local separator = text("sep-" .. item.p.key, "attention.detail-sep", "·")
			separator.p.truncate = nil
			table.insert(parts, separator)
		end
		item.p.truncate, item.p.wrap = nil, nil
		table.insert(parts, item)
	end
	if model ~= "" then
		local modelNode = text("model", "attention.model-line", model)
		modelNode.p.title = model
		add(modelNode)
	end
	local need = row.need
	if type(need) == "table" then
		local phrase, tip = label(need.text, "", 80), nil
		-- An ordinary Working row says nothing here: it already sits under the Working header. A tool running past a
		-- minute is named; Stalled only past the bound for what it waits on, and never when that is unknown.
		if need.kind == "working" then
			local idle = if finite(need.sinceUtc) and finite(nowUtc) then nowUtc - need.sinceUtc else nil
			local since = if idle then phone.relativeLong(need.sinceUtc, nowUtc) else nil
			phrase = ""
			if idle and need.wait == "model" and idle >= STALL.modelSeconds then
				phrase, tip = "Stalled " .. phone.age(idle), "No reply from the model · asked " .. since
			elseif idle and need.wait == "tool" and idle >= STALL.toolShownSeconds then
				local doing = if need.tool == "wait" then "Waiting on jobs" else "Running " .. label(need.tool, "tool", 40)
				phrase = if idle >= STALL.toolSeconds then "Stalled · " .. doing .. " " .. phone.age(idle)
					else doing .. " " .. phone.age(idle)
				tip = doing .. " · started " .. since
			end
		elseif need.kind == "resting" and finite(need.untilUtc) and finite(nowUtc) then
			-- Every account of the provider is blocked: say when the first frees, as time left.
			local left = math.max(need.untilUtc - nowUtc, 0)
			phrase = phrase .. " · back in " .. phone.age(left)
			tip = phrase .. " · every account of this provider is blocked; it returns to Attention by itself"
		end
		if phrase ~= "" then
			local needNode = text("need", "attention.need", phrase)
			needNode.p.title = tip or label(need.text, phrase, 160)
			add(needNode)
		end
	end
	local clock = if ageNode then primaryClock(row) else nil
	-- The short age ("2m", "≈ 3h"); a row with a fixed chip (no clock) leaves its sentence to the row tooltip.
	if clock then
		local elapsed = if finite(clock.atUtc) and finite(nowUtc) and nowUtc >= clock.atUtc
			then phone.age(nowUtc - clock.atUtc) else "?"
		ageNode.p.text = (if clock.recorded == true then "≈ " else "") .. elapsed
		add(ageNode)
	end
	return node("row", { key = "detail", role = "attention.detail-line", gap = "none", wrap = false }, parts)
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
		for _, field in ipairs({ { "writerSupport", "writer support" }, { "historyScope", "history" } }) do
			if value[field[1]] ~= nil then table.insert(parts, field[2] .. ": " .. label(value[field[1]], "unknown", 48)) end
		end
		local fields = if type(value.fields) == "table" then value.fields else {}
		for _, field in ipairs({ { "clock", "clock support" }, { "questions", "question support" } }) do
			if fields[field[1]] ~= nil then table.insert(parts, field[2] .. ": " .. label(fields[field[1]], "unknown", 48)) end
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
	if row.stale then add("stale", "Last known evidence · refresh unavailable") end
	lines = diagnostics
	local function clock(key, title, atUtc)
		add(key, title .. ": " .. (if finite(atUtc) then tostring(atUtc) .. " UTC seconds · " else "") .. phone.relative(atUtc, nowUtc))
	end
	local observation = row.sourceObservation
	local unavailable = sourceUnavailable(row)
	if observation then
		add("source-availability", "Latest source availability: " .. label(observation.status, "unknown", 32))
		clock("source-observed", "Source availability unchanged since", observation.capturedAtUtc)
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

local function tabsLabel(count)
	return count .. (if count == 1 then " tab" else " tabs")
end

-- Keyed native patches turning `old` into `new` at `path` (dot-joined node keys; every key is alphanumeric or an
-- escape, never a dot). Equal subtrees send nothing and nodes whose own props or kind changed are replaced whole.
-- Among keyed siblings a patch can remove a child or append ONE new child at the end; any other membership or
-- order change replaces the container, exactly as the bottom strip's row list does.
local function diffNodes(patches, path, old, new)
	if equal(old, new) then return end
	local oldKids, newKids = old.c or {}, new.c or {}
	if old.k ~= new.k or not equal(old.p, new.p) or #oldKids == 0 and #newKids == 0 then
		patches[path] = new
		return
	end
	local sameKeys = #oldKids == #newKids
	if sameKeys then
		for index, kid in ipairs(newKids) do
			if oldKids[index].p.key ~= kid.p.key then sameKeys = false; break end
		end
	end
	if sameKeys then
		for index, kid in ipairs(newKids) do diffNodes(patches, path .. "." .. kid.p.key, oldKids[index], kid) end
		return
	end
	local oldByKey, newByKey, surviving, appended, appendStarted, needsOrder = {}, {}, {}, 0, false, false
	for _, kid in ipairs(oldKids) do oldByKey[kid.p.key] = kid end
	for _, kid in ipairs(newKids) do
		newByKey[kid.p.key] = kid
		if oldByKey[kid.p.key] then
			table.insert(surviving, kid.p.key)
			if appendStarted then needsOrder = true end
		else appendStarted, appended = true, appended + 1 end
	end
	local survivorIndex = 0
	for _, kid in ipairs(oldKids) do
		if newByKey[kid.p.key] then
			survivorIndex += 1
			if surviving[survivorIndex] ~= kid.p.key then needsOrder = true end
		end
	end
	if appended > 1 or needsOrder then
		patches[path] = new
		return
	end
	for key, kid in pairs(oldByKey) do
		if not newByKey[key] then patches[path .. "." .. key] = false
		else diffNodes(patches, path .. "." .. key, kid, newByKey[key]) end
	end
	for key, kid in pairs(newByKey) do
		if not oldByKey[key] then patches[path .. "." .. key] = kid end
	end
end

function view.render(renderer, logical, presentation, options)
	options = options or {}
	local section = logical.section
	-- The bottom strip keeps its two-line session-column rows and one-line wide toolbar. A left or right rail is a
	-- two-region stack: every section at once, the attention stack above Workspace, with single-line rows.
	local stacked = stackedPlacement(options)
	local wide = not stacked
	local queueOrder = queueOrderOf(options.queueOrder)
	-- One section's rows. Every row is emitted (up to the canvas row and node budget); nothing pages.
	local lists = {}
	local function listOf(name)
		local list = lists[name]
		if list == nil then
			list = sectionItems(logical, presentation, options, name)
			lists[name] = list
		end
		return list
	end
	local rows = listOf(section)
	local now = options.now or 0
	local attentionOpen = not stacked or logical.workspace.collapsed["queue:attention"] ~= true
	-- The one queue whose arrival highlight can show: the selected one in the strip, Attention in the stack.
	local focus = if stacked then "attention" else section
	local focusList = listOf(focus)
	-- Opening Attention is not a selection change: an arrival opens a folded Attention itself, in the same pass that
	-- plays its cue, so no arrival can wait behind a folded section to replay when it is opened by hand.
	local selection = focus .. ":" .. tostring(logical.settings) .. ":" .. tostring(logical.expandedWorkId)
	if renderer.arrival and (now >= renderer.arrival.untilTime or logical.settings or focus ~= "attention"
		or renderer.selection ~= selection) then renderer.arrival = nil end
	if options.arrival and renderer.initialized and focus == "attention" and not logical.settings
		and #focusList > 0 and attentionOpen and renderer.selection == selection and not renderer.arrival
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
	local attentionCount, workingCount = 0, 0
	local reachable, retained, awaitingHeader = 0, 0, 0
	local collisions, byWorkId = {}, {}
	for _, row in ipairs(presentation.rows) do
		byWorkId[row.workId] = row
		if inQueue(row, "attention") then attentionCount += 1 end
		if inQueue(row, "working") then workingCount += 1 end
		if row.attention == true then
			if row.navigable then reachable += 1 elseif openable(row) then awaitingHeader += 1 end
		end
		if not row.pane and row.retained then retained += 1 end
		local key = label(row.title, "Untitled conversation") .. "\n" .. label(row.sessionName, "Unknown session")
		collisions[key] = (collisions[key] or 0) + 1
	end

	-- Display-only model. A Workspace leaf shows its conversation's model; a queue row shows the model of its pane.
	-- It is shown whenever it is known, so two rows on one model still say which model runs them.
	local destinationsByPane = if options.workspace then options.workspace.byPane else nil
	local function modelOfPane(hostKey, pane)
		local destination = if destinationsByPane ~= nil and pane ~= nil then destinationsByPane[pane] else nil
		if destination == nil or destination.hostKey ~= hostKey then return "" end
		return label(destination.model, "", 160)
	end
	local function leafModel(nav)
		if nav.kind ~= "leaf" or nav.leaf == nil then return "" end
		return label(nav.leaf.model, "", 160)
	end

	-- Saved-conversations nodes by work id: a conversation with no open pane is listed there, once.
	local savedNodes = {}
	if options.workspace ~= nil then
		for _, saved in ipairs(options.workspace.retained) do savedNodes[saved.workId] = saved end
	end
	-- Every Workspace row at depth 1 or deeper reserves the toggle column; a row with nothing to open leaves it empty.
	local function toggleSpacer()
		return node("el", { key = "toggle", role = "workspace.toggle-none", tag = "span" })
	end

	-- One tracked conversation: an Attention or Working queue row, or a Workspace conversation leaf. Only the
	-- Attention queue acknowledges review (`open`); every other activation is the navigation-only `route-open`.
	local function conversationNode(item, row, mode)
		local nav = item.navRow
		local queue = mode == "attention" or mode == "working" or mode == "resting"
		-- Stack sections can list the same conversation twice; their binding slots stay apart per section.
		local slotPrefix = if stacked then (if queue then mode else "workspace") .. ":" else ""
		local title, session = label(row.title, "Untitled conversation"), label(row.sessionName, "Unknown session")
		local host = label(row.hostName, "unknown host", 100)
		local currentCondition = condition(row)
		local runtime = runtimeWords(row)
		local settled = row.disposition == "reference" or row.disposition == "finished"
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
		-- A conversation with no open pane is listed once under Saved conversations. Its row never dead-ends: it
		-- reveals that entry.
		local saved = if canOpen then nil else savedNodes[row.workId]
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
			return bind(slotPrefix .. item.key .. ":" .. op, binding)
		end
		local dim = not queue and settled
		local titleNode = text("title", if dim then "workspace.title-dim" else "attention.title", title)
		titleNode.p.truncate, titleNode.p.title = "end", title
		-- A rail queue title wraps to at most two lines (CSS clamps it): the queues are short and each item matters.
		if queue and stacked then titleNode.p.wrap, titleNode.p.truncate = nil, nil end
		local pendingNode
		if navigationTitle then
			pendingNode = text("navigation-pending", "attention.navigation-pending", navigationText)
			pendingNode.p.title, pendingNode.p.truncate, pendingNode.p.wrap = navigationTitle, nil, nil
		end
		local clock, clockTitle, clockRecorded = primaryAge(row, options.nowUtc)
		local ageNode
		if clock then
			ageNode = text("age", if clockRecorded then "attention.age-recorded" else "attention.age", clock)
			ageNode.p.title, ageNode.p.truncate, ageNode.p.wrap = clockTitle or clock, nil, nil
		end
		local priority = if finite(row.priority) and row.priority >= 0 and row.priority <= 3 and row.priority % 1 == 0
			then row.priority else nil
		local expanded = logical.expandedWorkId == row.workId and (mode ~= "leaf" or nav.leaf.conversation.preferred)
		local tooltip = (if navigationTitle then navigationTitle .. " · " elseif mode ~= "attention" and canOpen then "Go to · "
			elseif row.navigable then "Open · "
			elseif canOpen then "Verify header, then open · " else unavailable .. " · ")
			.. title .. " · " .. session .. " · " .. host .. " · " .. reason .. " · " .. label(row.context, "Context unknown", 256)
		local function openButton(tip, content)
			return node("el", {
				key = "open", role = if navigationTitle then "attention.open-pending" elseif canOpen or saved then "attention.open" else "attention.unavailable", tag = "button",
				title = tip,
				actions = if navigationTitle then nil
					elseif canOpen then { click = rowAction(if mode == "attention" then "open" else "route-open") }
					elseif saved then { click = bind(slotPrefix .. item.key .. ":workspace-open",
						{ op = "workspace-open", key = saved.key, signature = saved.signature }) }
					else nil,
			}, content)
		end
		local currentRow = queue and options.current ~= nil and options.current.workId == row.workId
		local mainRole = if currentRow then "attention.row-main-current" elseif queue then "attention.row-main"
			elseif nav.leaf and nav.leaf.current then "workspace.main-current" else "workspace.main"
		local model = if nav then leafModel(nav) else modelOfPane(row.hostKey, row.pane)
		local mainChildren
		if wide then
			-- Bottom strip: the session is a bold column spanning both lines, the title above the metadata beside it.
			local summary = { titleNode }
			if pendingNode then table.insert(summary, pendingNode) end
			local summaryRow = node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, summary)
			local metadata = {}
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
			if model ~= "" then
				local modelNode = text("model", "workspace.model", model)
				modelNode.p.title, modelNode.p.truncate, modelNode.p.wrap = model, nil, nil
				table.insert(metadata, modelNode)
			end
			if #qualifiers > 0 then
				local qualifier = text("qualifiers", "attention.qualifiers", table.concat(qualifiers, " · "))
				qualifier.p.title = qualifier.p.text
				table.insert(metadata, qualifier)
			end
			if priority then table.insert(metadata, text("priority", "attention.priority", "P" .. priority)) end
			if ageNode then table.insert(metadata, ageNode) end
			local runtimeNode = text("runtime", "attention.runtime", runtime)
			runtimeNode.p.title, runtimeNode.p.truncate, runtimeNode.p.wrap = runtimeTitle, nil, nil
			table.insert(metadata, runtimeNode)
			local metadataRow = node("row", { key = "metadata", role = "attention.metadata", gap = "xs", wrap = true }, metadata)
			local sessionName = text("name", "attention.session-name", session)
			sessionName.p.truncate, sessionName.p.title = "end", session
			local open = openButton(tooltip, { node("row", { key = "cells", role = "attention.cells", gap = "sm", wrap = false }, {
				node("row", { key = "session-cell", role = "attention.session-cell", gap = "none", wrap = false }, { sessionName }),
				node("col", { key = "body", role = "attention.body", gap = "none" }, { summaryRow, metadataRow }),
			}) })
			local disclosure = node("el", { key = "details", role = "attention.triage", tag = "button",
				title = if expanded then "Collapse recorded facts" else "Inspect recorded facts · does not acknowledge or navigate",
				actions = { click = rowAction("details") } },
				{ node("icon", { key = "icon", role = "attention.triage-icon", name = if expanded then "chev" else "chev-r" }) })
			local menu = node("el", { key = "menu", role = "attention.more", tag = "button",
				title = "Priority and explicit tracking disposition", actions = { click = rowAction("menu") } },
				{ node("icon", { key = "icon", role = "attention.triage-icon", name = "more" }) })
			mainChildren = { open, disclosure, menu }
		else
			-- Rail rows: the owning session in a fixed-width ALL-CAPS column, then two lines: [title … | priority] over
			-- [model · need · age]. More opens the recorded facts. Host, reason, context and the full runtime and clock
			-- sentences live in the tooltip. A Workspace leaf has no session column (its tree shows the session): line
			-- one carries its abnormal-state marker, line two its model.
			local runtimeFull = if runtimeTitle then runtime .. ". " .. runtimeTitle else runtime
			local priorityName = if priority then priorityNames[priority + 1] else nil
			local line = { titleNode }
			if pendingNode then table.insert(line, pendingNode) end
			local lines = { node("row", { key = "line", role = "attention.line", gap = "xs", wrap = false }, line) }
			local content = lines
			if queue then
				if priority then
					local chip = text("priority", "attention.priority", "P" .. priority)
					chip.p.title, chip.p.truncate, chip.p.wrap = priorityName, nil, nil
					table.insert(line, chip)
				end
				table.insert(lines, railDetail(row, model, ageNode, options.nowUtc))
				local sessionName = text("name", "attention.rail-session", string.upper(session))
				sessionName.p.truncate, sessionName.p.title = "end", session
				content = { node("row", { key = "cells", role = "attention.cells", gap = "sm", wrap = false }, {
					node("row", { key = "session-cell", role = "attention.rail-session-cell", gap = "none", wrap = false }, { sessionName }),
					node("col", { key = "body", role = "attention.body", gap = "none" }, lines),
				}) }
			else
				local marker, markerTitle = stateMarker(row), runtimeFull
				if marker == nil and nav.leaf.availability == "offline" then marker, markerTitle = "Offline", unavailable end
				if marker then
					local state = text("state", "attention.state", marker)
					state.p.title, state.p.truncate, state.p.wrap = markerTitle, nil, nil
					table.insert(line, node("row", { key = "chips", role = "attention.chips", gap = "xs", wrap = false }, { state }))
				end
				if model ~= "" then
					local modelNode = text("model", "workspace.model", model)
					modelNode.p.title, modelNode.p.truncate, modelNode.p.wrap = model, nil, nil
					table.insert(lines, modelNode)
				end
			end
			if nav and nav.context then tooltip ..= " · " .. label(nav.context, "", 160) end
			if priorityName then tooltip ..= " · " .. priorityName end
			tooltip ..= " · " .. runtimeFull
			if clock then tooltip ..= " · " .. (clockTitle or clock) end
			local menu = node("el", { key = "menu", role = "attention.more", tag = "button",
				title = "Priority and explicit tracking disposition", actions = { click = rowAction("menu") } },
				{ node("icon", { key = "icon", role = "attention.more-icon", name = "more" }) })
			mainChildren = { openButton(tooltip, content), menu }
		end
		if navigationTitle and type(pending.token) == "string" and pending.token ~= "" then
			table.insert(mainChildren, 2, node("el", {
				key = "cancel-navigation", role = "attention.cancel-navigation", tag = "button", text = "Cancel",
				title = "Cancel this request without acknowledging attention; an active helper may still finish",
				actions = { click = bind(slotPrefix .. item.key .. ":cancel-navigation", {
					op = "cancel-navigation", token = pending.token, workId = row.workId,
					serial = row.serial, pane = routePane, identityKey = row.identityKey,
				}) },
			}))
		end
		if not queue and nav.depth >= 1 then table.insert(mainChildren, 1, toggleSpacer()) end
		local children = { node("row", { key = "main", role = mainRole, gap = "none", wrap = false }, mainChildren) }
		if expanded then
			-- A rail row has no chevron; the opened facts carry their own way to close.
			if not wide then
				table.insert(children, node("el", { key = "collapse", role = "attention.collapse", tag = "button",
					text = "Hide recorded facts", title = "Collapse recorded facts · does not acknowledge or navigate",
					actions = { click = rowAction("details") } }))
			end
			table.insert(children, details(row, options.nowUtc))
		end
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
		local content
		if wide then
			content = { node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, { titleNode }),
				node("row", { key = "metadata", role = "attention.metadata", gap = "xs", wrap = true }, { context }) }
		else
			-- Rail: the title on one line, the pane kind on the reserved muted sub-line.
			content = { node("row", { key = "line", role = "attention.line", gap = "xs", wrap = false }, { titleNode }) }
			if context.p.text ~= "" then
				context.p.role = "workspace.model"
				table.insert(content, context)
			end
		end
		local open = node("el", {
			key = "open", role = if canOpen then "attention.open" else "attention.unavailable", tag = "button",
			title = (if canOpen then "Go to · " else "Host offline · ") .. title .. " · " .. label(navRow.context, "", 160),
			actions = if canOpen then { click = bind(navRow.key .. ":open", binding) } else nil,
		}, content)
		local main = { open }
		if navRow.depth >= 1 then table.insert(main, 1, toggleSpacer()) end
		return node("col", { key = nodeKey(navRow.key), role = "workspace.row", gap = "none" }, {
			node("row", { key = "main", role = if leaf.current then "workspace.main-current" else "workspace.main",
				gap = "none", wrap = false }, main),
		})
	end

-- Hosts, sessions and tabs are three species, not one indented list. A host is a full-width disclosure row —
-- the queue sections' group language — whose chevron and count say a world opens. A session or section opens
-- a ledger block: its name in a fixed label column is the toggle, and its rows stand to the right of a
-- hairline. Collapsed, a block is its name and an "N tabs ▾" chip; the accent marks only the current
-- session's dot, the current tab's row, and the place card. A session label carries no menu: renaming and
-- new tabs live on the tab rows and in the command palette. A tab row is the target and its ⋯ the menu.
local function hostRowNode(navRow)
	local title = label(navRow.title, "Host", 160)
	local suffix = if navRow.count ~= nil then " (" .. tostring(navRow.count) .. ")"
		elseif navRow.context then " · " .. label(navRow.context, "", 60)
		else ""
	local name = text("title", "workspace.host-title", title)
	name.p.truncate, name.p.title = "end", title
	local children = {
		node("icon", { key = "chev", role = "attention.triage-icon", name = if navRow.expanded then "chev" else "chev-r" }),
		name,
	}
	if suffix ~= "" then
		local tail = text("suffix", "workspace.host-suffix", suffix)
		tail.p.title = suffix
		table.insert(children, tail)
	end
	return node("el", { key = nodeKey(navRow.key), role = "workspace.host-row", tag = "button",
		title = (if navRow.expanded then "Collapse · " else "Expand · ") .. title .. suffix,
		actions = { click = bind(navRow.key .. ":toggle", { op = "workspace-toggle", key = navRow.key,
			expanded = if stacked then navRow.expanded else nil }) },
	}, children)
end

-- A session's label: its name jumps to the session (native restores its last tab there); an empty one is plain text.
-- Parked/Unattached sections keep the name as their own disclosure with a count chip.
local function ledgerLabel(navRow)
	local title = label(navRow.title, "Untitled", 160)
	local nameChildren = {}
	if navRow.current then table.insert(nameChildren, text("dot", "workspace.ledger-dot", "\u{25CF}")) end
	local nameText = text("name", "workspace.title", title)
	nameText.p.truncate, nameText.p.title = "end", title
	table.insert(nameChildren, nameText)
	local nameNode
	if navRow.kind == "section" then
		nameNode = node("el", { key = "toggle", role = "workspace.ledger-name", tag = "button",
			title = (if navRow.expanded then "Collapse · " else "Expand · ") .. title,
			actions = { click = bind(navRow.key .. ":toggle", { op = "workspace-toggle", key = navRow.key,
				expanded = if stacked then navRow.expanded else nil }) },
		}, nameChildren)
	elseif navRow.empty then
		nameNode = node("el", { key = "name", role = "workspace.ledger-name", title = title }, nameChildren)
	else
		nameNode = node("el", { key = "name", role = "workspace.ledger-name", tag = "button", title = "Jump to · " .. title,
			actions = { click = bind(navRow.key .. ":open", { op = "workspace-open", key = navRow.ref.key,
				signature = navRow.signature }) },
		}, nameChildren)
	end
	local labelChildren = { nameNode }
	if navRow.kind == "section" and navRow.count ~= nil then
		local chip = text("chip", "workspace.ledger-chip", tostring(navRow.count) .. " \u{25BE}")
		chip.p.title = "Expand · " .. title
		table.insert(labelChildren, chip)
	end
	return node("col", { key = "label", role = "workspace.ledger-label" }, labelChildren)
end

-- The full-height strip at a session box's left edge: − minimizes the session into its host's Minimized group, +
-- goes to it, which restores it to its place (both lists keep native session order). Empty sessions and sections
-- have none.
local function ledgerEdge(navRow)
	if navRow.kind ~= "session" or navRow.empty then return nil end
	local title = label(navRow.title, "Untitled", 160)
	local action = if navRow.expanded
		then bind(navRow.key .. ":toggle", { op = "workspace-toggle", key = navRow.key, expanded = true })
		else bind(navRow.key .. ":restore", { op = "workspace-open", key = navRow.ref.key, signature = navRow.signature })
	return node("el", { key = "edge", role = "workspace.ledger-edge", tag = "button",
		text = if navRow.expanded then "\u{2212}" else "+",
		title = (if navRow.expanded then "Minimize · " else "Restore and go to · ") .. title,
		actions = { click = action },
	})
end

-- One host's empty sessions under a centred "No tabs (N)" disclosure (folded under `empties:<host>` in the Workspace
-- disclosure map): each name a small box of its own, the button that opens a tab there, in one row that scrolls
-- sideways when it outgrows the pane.
local function emptyNameNode(navRow)
	local title = label(navRow.title, "Session", 160)
	return node("el", { key = nodeKey(navRow.key), role = "workspace.empty-name", tag = "button", text = title,
		title = "New tab in · " .. title,
		actions = { click = bind(navRow.key .. ":open", { op = "workspace-open", key = navRow.ref.key,
			signature = navRow.signature }) },
	})
end

-- The one row of an empty session's block: native's "No tabs", as the button that opens a tab there.
local function emptySessionNode(navRow)
	local title = label(navRow.title, "Session", 160)
	local open = node("el", { key = "open", role = "attention.open", tag = "button", title = "New tab in · " .. title,
		actions = { click = bind(navRow.key .. ":open", { op = "workspace-open", key = navRow.ref.key,
			signature = navRow.signature }) },
	}, { node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, {
		text("title", "workspace.empty-session", "No tabs · New tab"),
	}) })
	return node("col", { key = nodeKey(navRow.key .. ":empty"), role = "workspace.row" }, {
		node("row", { key = "main", role = "workspace.main", gap = "none", wrap = false }, { open }),
	})
end

local function tabRowNode(navRow)
	local title = label(navRow.title, "Untitled", 160)
	local summary = { text("title", "workspace.title-tab", title) }
	-- The native sidebar's tile: Tern's icon for the tab's focused program. A title glyph takes the program icon's
	-- place on a plain plate, as native draws a session's own icon instead of omp's.
	if navRow.glyph then
		local glyph = text("glyph", "workspace.tile-glyph", navRow.glyph)
		glyph.p.truncate = nil
		table.insert(summary, 1, node("el", { key = "tile", role = "workspace.tile-plate", tag = "span" }, { glyph }))
	elseif navRow.icon then
		table.insert(summary, 1, node("el", { key = "tile", role = "workspace.tile", tag = "span" },
			{ node("icon", { key = "icon", role = "workspace.tile-icon", name = navRow.icon }) }))
	end
	if navRow.context then table.insert(summary, text("context", "workspace.context", label(navRow.context, "", 100))) end
	local open = node("el", { key = "open", role = "attention.open", tag = "button",
		title = "Go to · " .. title,
		actions = { click = bind(navRow.key .. ":open", { op = "workspace-open", key = navRow.ref.key,
			signature = navRow.signature }) },
	}, { node("row", { key = "summary", role = "attention.summary", gap = "xs", wrap = false }, summary) })
	local parts = { open }
	if navRow.kind == "tab" then
		table.insert(parts, node("el", { key = "menu", role = "attention.more", tag = "button",
			title = "More · " .. title,
			actions = { click = bind(navRow.key .. ":menu", { op = "native-menu", key = navRow.ref.key,
				signature = navRow.signature }) },
		}, { node("icon", { key = "icon", role = "attention.triage-icon", name = "more" }) }))
	end
	return node("col", { key = nodeKey(navRow.key), role = "workspace.row" }, {
		node("row", { key = "main", role = if navRow.current then "workspace.main-current" else "workspace.main",
			gap = "none", wrap = false }, parts),
	})
end

	-- One canvas-wide budget of rows and nodes: sections draw from it in canvas order, the first row that does not fit
	-- closes the budget for every later row, and what was not emitted is counted so the footer can say so.
	local budget = { rows = MAX_CANVAS_ROWS, nodes = MAX_CANVAS_NODES - CHROME_NODES, omitted = 0 }
	local function countNodes(item)
		local total = 1
		for _, child in ipairs(item.c or {}) do total += countNodes(child) end
		return total
	end
	local function moreNode()
		local more = text("more", "workspace.more", budget.omitted .. " more not shown · Search reaches them")
		more.p.truncate, more.p.title = "end", more.p.text
		return more
	end

	local function rowNodeOf(name, item)
		local navRow = item.navRow
		if name ~= "workspace" then return conversationNode(item, item.row, name) end
		if navRow.kind == "leaf" then
			local link = navRow.leaf.conversation
			local row = if link then byWorkId[link.workId] else nil
			return if row then conversationNode(item, row, "leaf") else paneNode(navRow)
		end
	if navRow.kind == "host" then return hostRowNode(navRow) end
	return tabRowNode(navRow)
	end

	-- The row nodes of one section, within what is left of the canvas budget.
	local function rowNodesOf(name)
		local nodes, list, emitted = {}, listOf(name), 0
		-- The workspace list is a ledger: hosts are full-width disclosure rows, and a session (or section) opens
		-- a block whose rows collect until the next boundary. Retained records are not tree rows: Search and the
		-- queues reach them. Other sections stay flat.
	local block -- { key, edge, label, rows, current }
	local currentKey -- the key of the direct child of `nodes` that holds the current session's box (or its Minimized group)
	local minimized -- this host's minimized session boxes so far, emitted under one disclosure at the host's end
	local empties -- this host's empty-session buttons so far, emitted as one line at the host's end
	-- A half-width labelled divider that folds what follows it under `foldKey` in the Workspace disclosure map.
	local function subToggle(foldKey, label, open)
		return node("el", { key = "toggle", role = "workspace.sub-toggle", tag = "button",
			title = (if open then "Collapse · " else "Expand · ") .. label,
			actions = { click = bind(foldKey .. ":toggle", { op = "workspace-toggle", key = foldKey, expanded = open }) },
		}, { node("icon", { key = "chev", role = "attention.triage-icon", name = if open then "chev" else "chev-r" }),
			text("label", "workspace.sub-label", label) })
	end
	local function flushMinimized()
		if minimized == nil then return end
		local key = "min:" .. nodeKey(minimized.host)
		local foldKey = "minimized:" .. minimized.host
		local open = logical.workspace.collapsed[foldKey] ~= true
		local children = { subToggle(foldKey, "Minimized (" .. #minimized.boxes .. ")", open) }
		if open then
			table.insert(children, node("col", { key = "boxes", role = "workspace.minimized-boxes", gap = "none" }, minimized.boxes))
		end
		table.insert(nodes, node("col", { key = key, role = "workspace.minimized-line", gap = "none" }, children))
		minimized = nil
	end
	local function flushEmpties()
		if empties == nil then return end
		local foldKey = "empties:" .. empties.host
		local open = logical.workspace.collapsed[foldKey] ~= true
		local children = { subToggle(foldKey, "No tabs (" .. #empties.names .. ")", open) }
		if open then
			table.insert(children, node("row", { key = "names", role = "workspace.empty-names", gap = "xs", wrap = false }, empties.names))
		end
		table.insert(nodes, node("col", { key = "empty:" .. empties.key, role = "workspace.empty-line", gap = "none" }, children))
		empties = nil
	end
	-- A host ends: its Minimized group, then its No tabs line.
	local function flushHostTail()
		flushMinimized()
		flushEmpties()
	end
	local function ledgerNode(key, edge, labelNode, rows, current)
		local children = {}
		if edge then table.insert(children, edge) end
		table.insert(children, labelNode)
		table.insert(children, node("col", { key = "rows", role = "workspace.ledger-rows" }, rows))
		return node("row", { key = key, role = if current then "workspace.ledger-current" else "workspace.ledger" }, children)
	end
	local function closeBlock()
		if block == nil then return end
		table.insert(nodes, ledgerNode(block.key, block.edge, block.label, block.rows, block.current))
		block = nil
	end
	local function startBlock(key, edge, label, current)
		closeBlock()
		block = { key = key, edge = edge, label = label, rows = {}, current = current }
	end
		while emitted < #list and budget.rows > 0 do
			local item = list[emitted + 1]
			local navRow = item.navRow
			local cost
			if name == "workspace" and navRow.kind == "session" and not navRow.empty and not navRow.expanded
				and minimized == nil then
				minimized = { host = navRow.ref.hostKey or "local", boxes = {} }
			end
			if name == "workspace" and navRow.kind == "host" then
				local hostRow = hostRowNode(navRow)
				cost = countNodes(hostRow)
				if cost > budget.nodes then budget.rows = 0 break end
				closeBlock()
				flushHostTail()
				budget.rows, budget.nodes = budget.rows - 1, budget.nodes - cost
				table.insert(nodes, hostRow)
			elseif name == "workspace" and navRow.kind == "session" and navRow.empty and not navRow.current then
				-- The current session keeps its box even when empty: the accent ring is where you are.
				local nameNode = emptyNameNode(navRow)
				cost = 1 + (if empties then 0 else 5)
				if cost > budget.nodes then budget.rows = 0 break end
				closeBlock()
				if empties == nil then
					empties = { key = nodeKey(navRow.key), host = navRow.ref.hostKey or "local", names = {} }
				end
				table.insert(empties.names, nameNode)
				budget.rows, budget.nodes = budget.rows - 1, budget.nodes - cost
			elseif name == "workspace" and navRow.kind == "session" and not navRow.empty and not navRow.expanded then
				-- A minimized session: one short box ("N tabs") in its host's Minimized group, + at its edge.
				local count = node("el", { key = "count", role = "workspace.ledger-count", tag = "button",
					text = tostring(navRow.count or 0) .. (if navRow.count == 1 then " tab" else " tabs"),
					title = "Restore and go to · " .. label(navRow.title, "Untitled", 160),
					actions = { click = bind(navRow.key .. ":count", { op = "workspace-open", key = navRow.ref.key,
						signature = navRow.signature }) } })
				local box = ledgerNode(nodeKey(navRow.key), ledgerEdge(navRow), ledgerLabel(navRow), { count }, navRow.current)
				cost = countNodes(box) + (if #minimized.boxes > 0 then 0 else 5)
				if cost > budget.nodes then budget.rows = 0 break end
				closeBlock()
				table.insert(minimized.boxes, box)
				budget.rows, budget.nodes = budget.rows - 1, budget.nodes - cost
				if navRow.current then currentKey = "min:" .. nodeKey(minimized.host) end
			elseif name == "workspace" and (navRow.kind == "session" or navRow.kind == "section") then
				local edgeNode, labelNode = ledgerEdge(navRow), ledgerLabel(navRow)
				local emptyNode = if navRow.empty then emptySessionNode(navRow) else nil
				cost = countNodes(labelNode) + (if edgeNode then 1 else 0) + (if emptyNode then countNodes(emptyNode) else 0)
				if cost > budget.nodes then budget.rows = 0 break end
				-- A section ends its host's sessions: close the last session's box before the host's tail.
				if navRow.kind == "section" then closeBlock(); flushHostTail() end
				startBlock(nodeKey(navRow.key), edgeNode, labelNode, navRow.current)
				budget.rows, budget.nodes = budget.rows - 1, budget.nodes - cost
				if navRow.current then currentKey = nodeKey(navRow.key) end
				if emptyNode then table.insert(block.rows, emptyNode) end
			else
				local built = rowNodeOf(name, item)
				cost = countNodes(built)
				if cost > budget.nodes then budget.rows = 0 break end
				budget.rows, budget.nodes = budget.rows - 1, budget.nodes - cost
				if block then table.insert(block.rows, built) else table.insert(nodes, built) end
			end
			emitted += 1
		end
		closeBlock()
		flushHostTail()
		budget.omitted += #list - emitted
		return nodes, emitted, currentKey
	end
	local rowNodes, rowNodesShown = {}, 0
	if not (logical.settings or stacked) then rowNodes, rowNodesShown = rowNodesOf(section) end

	local queueLabels = { attention = "Attention", working = if wide then "Currently working" else "Working", workspace = "Workspace" }
	local queueTitles = {
		attention = "Attention · " .. attentionCount .. " tracked conversations need attention",
		working = "Currently working · " .. workingCount .. " live conversations",
		workspace = "Workspace · every tab in this window",
	}
	local counts = { attention = attentionCount, working = workingCount }
	local queues = {}
	-- The stack shows every section at once, so it has no section tabs. The strip's tabs follow the stored
	-- queue order (Workspace stays last).
	local tabs = if options.workspace and options.workspace.counts then options.workspace.counts.tabs else nil
	local sectionOrder = table.clone(queueOrder)
	table.insert(sectionOrder, "workspace")
	for _, name in ipairs(sectionOrder) do
		local caption = { text("label", "attention.queue-label", queueLabels[name]) }
		if counts[name] then table.insert(caption, text("count", "attention.queue-count", tostring(counts[name]))) end
		-- The strip's Workspace mode carries the tree's count, the same as the stacked Workspace header.
		if name == "workspace" and tabs ~= nil then table.insert(caption, text("count", "attention.queue-count", "· " .. tabsLabel(tabs))) end
		table.insert(queues, node("el", {
			key = name, role = if logical.section == name then "attention.queue-selected" else "attention.queue",
			tag = "button", title = queueTitles[name],
			actions = { click = bind("section:" .. name, { op = "section", section = name }) },
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
	}, if wide then { node("icon", { key = "icon", role = "attention.next-icon", name = "fast-forward", size = 12 }), text("label", "attention.next-label", "Next") }
		else { node("icon", { key = "icon", role = "attention.next-icon", name = "fast-forward", size = 16 }) }))
	table.insert(tools, node("el", {
		key = "previous", role = if previous.available then "attention.previous" else "attention.previous-unavailable", tag = "button",
		title = if previous.available then "Previous · Return to " .. label(previous.title, "previous pane", 160) else "Previous · No previous pane yet",
		actions = if previous.available then { click = bind("previous", { op = "previous" }) } else nil,
	}, if wide then { node("icon", { key = "icon", role = "attention.previous-icon", name = "rewind", size = 12 }), text("label", "attention.previous-label", "Prev") }
		else { node("icon", { key = "icon", role = "attention.previous-icon", name = "rewind", size = 16 }) }))
	table.insert(utility, node("el", { key = "search", role = if searchAvailable then "attention.search" else "attention.search-unavailable",
		tag = "button", title = if searchAvailable then "Search workspace" else "Search unavailable",
		actions = if searchAvailable then { click = bind("search", { op = "search" }) } else nil,
	}, { node("icon", { key = "icon", role = "attention.search-icon", name = "search", size = 16 }) }))
	table.insert(utility, node("el", { key = "settings", role = if logical.settings then "attention.gear-selected" else "attention.gear", tag = "button",
		title = if logical.settings then "Back to " .. queueLabels[logical.section] else "More · Settings",
		actions = { click = bind("settings", { op = "settings" }) },
	}, { node("icon", { key = "icon", role = "attention.gear-icon", name = "gear", size = 16 }) }))
	-- The current-location line belongs to the bottom strip alone; on a rail the Workspace header is the place
	-- line itself, so no second line is built.
	local current = options.current
	local location
	if not stacked then
		if section ~= "workspace" or logical.settings then
			location = node("row", { key = "location", role = "attention.location-none", gap = "xs", wrap = false, hidden = true }, {})
		elseif current then
			local currentTitle = label(current.title, "Untitled", 160)
			local currentContext = label(current.context, "", 160)
			-- The model is display-only: it is named when the place is a conversation with a known model, and it never enters a key.
			local currentModel = label(current.model, "", 48)
			local details = { text("title", "attention.location-title", currentTitle),
				text("context", "attention.location-context", currentContext) }
			if currentModel ~= "" then table.insert(details, text("model", "attention.location-model", currentModel)) end
			location = node("el", { key = "location", role = "attention.location", tag = "button",
				title = "Reveal in Workspace · " .. currentTitle .. (if currentContext ~= "" then " · " .. currentContext else "") .. (if currentModel ~= "" then " · " .. currentModel else ""),
				actions = { click = bind("reveal", { op = "reveal" }) },
			}, details)
		else
			location = node("row", { key = "location", role = "attention.location-none", gap = "xs", wrap = false },
				{ text("title", "attention.location-title", "No current location") })
		end
	end
	-- Bottom strip: one fixed group above the scrolled list: the toolbar and the location line. styles.css bounds
	-- the root and scrolls only the list, so none of it is sticky content (native sticky painting is culled once
	-- the scroll offset passes about a screen).
	local header = nil
	if not stacked then
		header = node("col", { key = "header", role = "attention.header", gap = "none" }, {
			node("row", { key = "queues", role = "attention.queues", gap = "sm", wrap = true }, queues),
			node("row", { key = "tools", role = "attention.tools", gap = "sm", wrap = true }, tools),
			location,
			node("row", { key = "utility", role = "attention.utility", gap = "xs", wrap = false }, utility),
		})
	end
	local settingsNodes = {}
	if logical.settings then
		table.insert(settingsNodes, node("row", { key = "heading", role = "attention.settings-head", gap = "sm", wrap = false }, {
			text("title", "attention.settings-title", "Settings"),
			node("el", { key = "back", role = "attention.settings-back", tag = "button", text = "Back to " .. queueLabels[logical.section],
				title = "Back to " .. queueLabels[logical.section] .. " · closes Settings",
				actions = { click = bind("settings-back", { op = "settings" }) } }),
		}))
		local defaultPosition = settingsOptions.defaultPosition or "bottom"
		local defaultLabel = defaultPosition:sub(1, 1):upper() .. defaultPosition:sub(2)
		table.insert(settingsNodes, node("row", { key = "placement", role = "attention.setting", gap = "md", wrap = true }, {
			node("col", { key = "info", role = "attention.setting-info", gap = "xs" }, {
				text("label", "attention.setting-label", "Rail placement"),
				text("state", "attention.explanation", "Default for new tabs: " .. defaultLabel .. "."),
				text("description", "attention.explanation",
					"Pressing a position moves every rail there — this tab now, the rest on their next visit — and sets the default. One tab elsewhere? The palette's Use … in this tab relayouts just that tab."),
			}), node("row", { key = "options", role = "attention.placement-controls", gap = "sm", wrap = true }, {
				control("default-bottom", "Bottom", { op = "default", position = "bottom" }, defaultPosition == "bottom"),
				control("default-right", "Right", { op = "default", position = "right" }, defaultPosition == "right"),
				control("default-left", "Left", { op = "default", position = "left" }, defaultPosition == "left"),
			}),
		}))
		table.insert(settingsNodes, text("tracking-note", "attention.explanation", "More offers priority, reference and Finished for now. Reference and Finished leave the queues until Resume tracking; Search still finds them."))
		table.insert(settingsNodes, text("open-note", "attention.explanation", "Open clears only the displayed new-update revision after navigation. It does not answer a request or prove reading or completion."))
		table.insert(settingsNodes, text("shortcut", "attention.explanation", "Next attention · " .. shortcutLabel(settingsOptions.shortcut) .. " · leaves this view unchanged"))
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
	local root, shown, rowsNode
	if stacked then
		-- Left and right rails: one native split, the attention stack over Workspace. The root is the canvas root
		-- (a nested split collapses). Native keeps a dragged divider by key until `sizes` differs, so the sizes
		-- are re-derived from view state on every render: equal while the share is unchanged, different on each change.
		local top = logical.divider.share + (if logical.divider.nonce % 2 == 1 then SHARE_NUDGE else 0)
		shown = 0
		local toolsLine = node("row", { key = "tools", role = "attention.tools-line", gap = "xs", wrap = false }, {
			node("row", { key = "buttons", role = "attention.tools", gap = "xs", wrap = false }, tools),
			node("row", { key = "utility", role = "attention.utility", gap = "xs", wrap = false }, utility),
		})
		-- A queue section: the workspace-group header (chevron, title, count beside it, More menu) over its
		-- rows. Collapse state rides the Workspace disclosure map under `queue:<name>`, and the sections follow
		-- the stored queue order.
		local function queueSection(name)
			local open = logical.workspace.collapsed["queue:" .. name] ~= true
			local rowNodesOfSection, sectionShown = {}, 0
			if open and not logical.settings then rowNodesOfSection, sectionShown = rowNodesOf(name) end
			shown += sectionShown
			local toggle = node("el", { key = "toggle", role = "workspace.section", tag = "button",
				title = (if open then "Hide · " else "Show · ") .. queueTitles[name],
				actions = { click = bind("toggle:" .. name, { op = "workspace-toggle", key = "queue:" .. name, expanded = open }) },
			}, { node("icon", { key = "icon", role = "attention.triage-icon", name = if open then "chev" else "chev-r" }),
				text("title", "workspace.title", queueLabels[name]), text("count", "workspace.count", tostring(counts[name])) })
			local headParts = { toggle }
			if not logical.settings then
				table.insert(headParts, node("el", { key = "menu", role = "attention.more", tag = "button",
					title = "More · " .. queueLabels[name],
					actions = { click = bind("queue-menu:" .. name, { op = "queue-menu", name = name }) },
				}, { node("icon", { key = "icon", role = "attention.triage-icon", name = "more" }) }))
			end
			local rowsRole = if name == "attention" and renderer.arrival then renderer.arrival.role
				elseif name == "attention" and #rowNodesOfSection > 0 then "attention.rows-occupied" else "attention.rows"
			-- A section is as tall as its rows: an empty one is just its header with the count.
			local rowLines = rowNodesOfSection
			-- Rows waiting on a usage or rate limit's reset fold under one line at Attention's bottom (closed unless
			-- opened); each returns to Attention by itself when its reset passes.
			local restingRows = if name == "attention" and open and not logical.settings then listOf("resting") else {}
			if #restingRows > 0 then
				local restOpen = logical.workspace.collapsed["queue:resting"] == false
				local restLabel = "Waiting on reset (" .. #restingRows .. ")"
				rowLines = table.clone(rowNodesOfSection)
				table.insert(rowLines, node("el", { key = "resting-toggle", role = "workspace.sub-toggle", tag = "button",
					title = (if restOpen then "Collapse · " else "Expand · ") .. restLabel,
					actions = { click = bind("queue:resting:toggle", { op = "workspace-toggle", key = "queue:resting", expanded = restOpen }) },
				}, { node("icon", { key = "chev", role = "attention.triage-icon", name = if restOpen then "chev" else "chev-r" }),
					text("label", "workspace.sub-label", restLabel) }))
				if restOpen then
					local restNodes, restShown = rowNodesOf("resting")
					shown += restShown
					table.insert(rowLines, node("col", { key = "resting", role = "attention.rows", gap = "none" }, restNodes))
				end
			end
			return node("col", { key = name, role = "attention.section", gap = "none" }, {
				node("row", { key = "head", role = "attention.section-head", gap = "xs", wrap = false }, headParts),
				node("col", { key = "rows", role = rowsRole, gap = "none", hidden = not open or logical.settings }, rowLines),
			})
		end
		local sections = {}
		for _, name in ipairs(queueOrder) do table.insert(sections, queueSection(name)) end
		local topRegion = node("col", { key = "top", role = "attention.region", gap = "none", min = REGION_MIN }, {
			toolsLine, coverage, settings,
			node("col", { key = "stack", role = "attention.stack", gap = "none", hidden = logical.settings }, sections),
		})
		-- Workspace region: its head is the place line itself — the current tab · its session, revealing the
		-- focused place on click, with the fold icon at the end. The head renders last, so it hugs the region's
		-- bottom edge in both states: minimized it is the whole region; expanded, the tree fills above it and the
		-- fold icon flips +/− in place. Without a current place the header falls back to the region's name and
		-- nothing reveals.
		local workspaceRows, workspaceShown, workspaceCurrentKey = rowNodesOf("workspace")
		shown += workspaceShown
		if budget.omitted > 0 then table.insert(workspaceRows, moreNode()) end
		local headLine
		local minimized = logical.divider.minimized == true
		local foldTitle = if minimized then "Show the Workspace tree" else "Minimize the Workspace tree"
		if current then
			local placeTitle = label(current.tab or current.title, "Untitled", 160)
			local currentTitle = label(current.title, "Untitled", 160)
			local currentContext = label(current.context, "", 160)
			-- The model is display-only, so it is named in the tooltip and never enters a key.
			local currentModel = label(current.model, "", 48)
			local titleText = text("title", "workspace.title", placeTitle)
			titleText.p.truncate, titleText.p.title = "end", placeTitle
			-- The place card reads like a rail queue row: the session in the shared caps column on the left, then the
			-- accent dot ("you are here") and the tab's name, on one line. The whole card folds the tree, like the
			-- icon beside it: one affordance for one region.
			local placeLine = {}
			local sessionName = label(current.session, "", 96)
			if sessionName ~= "" then
				local sessionText = text("session", "attention.rail-session", string.upper(sessionName))
				sessionText.p.title = sessionName
				table.insert(placeLine, node("row", { key = "session-cell", role = "attention.rail-session-cell", gap = "none",
					wrap = false }, { sessionText }))
			end
			table.insert(placeLine, text("dot", "workspace.place-dot", "\u{25CF}"))
			table.insert(placeLine, titleText)
			local placeParts = { node("row", { key = "line", role = "attention.line", gap = "xs", wrap = false }, placeLine) }
			headLine = node("el", { key = "location", role = "attention.location", tag = "button",
				title = foldTitle .. " · " .. currentTitle
					.. (if currentContext ~= "" then " · " .. currentContext else "")
					.. (if currentModel ~= "" then " · " .. currentModel else ""),
				actions = { click = bind("minimize-place", { op = "workspace-minimize" }) },
			}, placeParts)
		else
			-- No current place: the region's name itself folds the tree, keeping one affordance either way.
			local plain = text("title", "workspace.title", queueLabels.workspace)
			plain.p.truncate, plain.p.title = "end", queueLabels.workspace
			headLine = node("el", { key = "title", role = "attention.location", tag = "button",
				title = foldTitle,
				actions = { click = bind("minimize-title", { op = "workspace-minimize" }) },
			}, { node("row", { key = "line", role = "attention.line", gap = "xs", wrap = false }, { plain }) })
		end
		-- The fold control is an icon: its tooltip carries the state, so the header's width stays with the place name.
		local minimizeControl = node("el", { key = "minimize", role = "attention.region-toggle", tag = "button",
			title = if minimized then "Show the Workspace tree" else "Minimize the Workspace tree",
			actions = { click = bind("minimize", { op = "workspace-minimize" }) },
		}, { node("icon", { key = "icon", role = "attention.region-toggle-icon",
			name = if minimized then "plus" else "minus", size = 16 }) })
		local workspaceHead = node("col", { key = "head", role = "attention.region-head", gap = "none" }, {
			node("row", { key = "line", role = "attention.section-head", gap = "xs", wrap = false }, {
				headLine,
				minimizeControl,
			}),
		})
		local workspaceEmpty = text("empty", "attention.empty", "No workspace tabs")
		workspaceEmpty.p.hidden = minimized or #listOf("workspace") > 0 or status == "unavailable" or status == "loading"
		-- The rows are a native list so the current place's box stays scrolled into view: the host keeps one scroll
		-- offset per tab's canvas, so `selected` is what lands a freshly shown rail on where you are. The id is the
		-- full rendered node id: the region name "main", then every key from the canvas root down to the child.
		-- Only the keys below may name the path, so the nodes and the id cannot drift.
		local regionsKey, bottomKey, rowsKey = "regions", "bottom", "rows"
		local rowsIdPrefix = "main." .. regionsKey .. "." .. bottomKey .. "." .. rowsKey .. "."
		-- The head renders last: the tree grows above a footer pinned to the bottom edge, so expanding never
		-- moves the fold control out from under the pointer.
		local bottomRegion = node("col", { key = bottomKey,
			role = if minimized then "attention.region-docked" else "attention.workspace-region", gap = "none",
			min = if minimized then nil else REGION_MIN }, {
			node("list", { key = rowsKey, role = "attention.workspace-rows", hidden = minimized, max = { lines = 400 },
				selected = if workspaceCurrentKey then rowsIdPrefix .. workspaceCurrentKey else nil }, workspaceRows),
			workspaceEmpty,
			workspaceHead,
		})
		root = node("split", { key = regionsKey, role = "attention.regions", dir = "col", grow = 1, sizes = { top, 1 - top } },
			{ topRegion, bottomRegion })
	else
		shown = rowNodesShown
		if budget.omitted > 0 then table.insert(rowNodes, moreNode()) end
		rowsNode = node("col", { key = "rows", role = if renderer.arrival then renderer.arrival.role
			elseif section == "attention" and #rowNodes > 0 then "attention.rows-occupied" else "attention.rows", gap = "none", hidden = logical.settings }, rowNodes)
		-- Only Workspace explains an empty list (missing inventory); empty conversation queues show nothing at all.
		local empty = text("empty", "attention.empty", if section == "workspace" then "No workspace tabs" else "")
		empty.p.hidden = section ~= "workspace" or #rows > 0 or logical.settings or status == "unavailable" or status == "loading"
		root = node("col", { role = "attention.root", gap = "none" }, { header, coverage, rowsNode, empty, settings })
	end
	local nextScreen = { view = root }
	local previousScreen = renderer.previous
	renderer.previous, renderer.bindings, renderer.targets = nextScreen, bindings, targets
	renderer.initialized, renderer.selection = true, selection
	if options.arrival or not previousScreen then renderer.arrivalRevision = presentation.revision end
	local info = { shown = shown, total = presentation.count, omitted = budget.omitted,
		section = section, settings = logical.settings, sectionCount = #rows,
		attentionCount = attentionCount, workingCount = workingCount, reachableCount = reachable,
		awaitingHeaderCount = awaitingHeader }
	if not previousScreen then return nextScreen, bindings, info end
	-- Switching between the strip and the stack (a rail moved) shares no node paths: send the whole view.
	if (previousScreen.view.k == "split") ~= stacked then return nextScreen, bindings, info end
	if stacked then
		-- A changed split (sizes after a snap) can only be sent whole; otherwise patch the keyed regions.
		if not equal(previousScreen.view.p, root.p) then return nextScreen, bindings, info end
		local patches = {}
		for index, region in ipairs(root.c) do diffNodes(patches, region.p.key, previousScreen.view.c[index], region) end
		return if next(patches) then { set = patches } else nil, bindings, info
	end
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

view.MAX_CANVAS_ROWS, view.MAX_CANVAS_NODES = MAX_CANVAS_ROWS, MAX_CANVAS_NODES

return view
