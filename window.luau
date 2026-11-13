local model, layout, view, identity, installTitles, navigation, phone
-- Load leaves before their consumers so each native callback compiles only one module.
local loaders = {
	function() identity = require("./identity") end,
	function() model = require("./model") end,
	function() layout = require("./layout") end,
	function() navigation = require("./navigation") end,
	function() phone = require("./phone") end,
	function() view = require("./view") end,
	function() installTitles = require("./titles") end,
}

-- `bootstrap` sits at Luau's 200-local limit, so pure helpers live here at module scope.
local function dropInstanceTab(prefs, key, tab)
	local bucket = prefs.instances[key]
	if bucket == nil then return end
	bucket[tostring(tab)] = nil
	if next(bucket) == nil then prefs.instances[key] = nil end
end

local function requestTargetsKey(request, key)
	if request == nil then return false end
	if request.routes ~= nil and request.routes[key] ~= nil then return true end
	local targets = if request.payload then request.payload.targets else nil
	if type(targets) ~= "table" then return false end
	for _, target in ipairs(targets) do
		if type(target) == "table" and target.key == key then return true end
	end
	return false
end

local function countKeys(map)
	local count = 0
	for _ in pairs(map) do count += 1 end
	return count
end

-- The all-tabs toast body: this tab, the rails that move on their next visit, and every kept rail by its reason.
local function markSummary(movesNow, queued, kept)
	local parts = {}
	if movesNow then table.insert(parts, "This tab moves now") end
	if queued > 0 then table.insert(parts, queued .. (if queued == 1 then " tab moves" else " tabs move") .. " on their next visit") end
	local reasons = {}
	if kept.hidden > 0 then table.insert(reasons, kept.hidden .. " hidden") end
	if kept.parked > 0 then table.insert(reasons, kept.parked .. " parked or floating") end
	if kept.elsewhere > 0 then table.insert(reasons, kept.elsewhere .. " not open in this tab") end
	-- Disconnected hosts are marked like any other, so no reason names them.
	if #reasons > 0 then table.insert(parts, "left as they are: " .. table.concat(reasons, ", ")) end
	if #parts == 0 then return "Every tab is already there" end
	return table.concat(parts, " · ")
end

-- Immutable vocabulary tables live at module scope; `bootstrap` sits at Luau's 200-local limit.
local MARKER = "attention:rail:v1"
local PREFS = "preferences"
local INITIAL_SHARE = 0.25
local states = { idle = true, working = true, waiting_input = true, exited = true }
local UI_SECTIONS = { attention = true, workspace = true, working = true }
local MAX_UI_KEYS, MAX_UI_KEY, MAX_UI_WINDOWS = 512, 256, 32
local MAX_REMNANTS, REMNANT_ATTEMPTS, REMNANT_RETRY_MS, CAPTURE_LIMIT = 8, 3, 5000, 65536
local results = { done = true, failed = true, exited = true, closed = true }

local function bootstrap(tern, clockUtc)
if tern.runtime.os == "ios" then return end
installTitles(tern)
local utcNow = clockUtc or os.time
local hydrated, savedRevision, storageProblem, projection = false, nil, nil, nil
-- Identity proof is per pane: `identityPending` holds every pane whose conversation key is not freshly proven.
local identities, identityReady, identityRequest, identityPending = {}, false, nil, {}
local identityNeeded, identityUrgent, identityMembership, identitySignals = true, false, {}, {}
local identityRetryAt, identityRetryDelay, identityFailure = nil, nil, nil
local knownHostKeys = {}
local observedAttention, observedProjection, arrivalQuietUntil = nil, nil, 0
local pendingArrival = nil
-- Host-side capture evidence for metadata-less canvas panes, keyed by pane; at most one probe runs.
local remnantProbe, remnantEvidence, remnantCloses = nil, {}, {}
-- True when the current pass failed inside a native canvas write; such failures retry,
-- they are not a stopped state, so no degraded line is painted for them.
local canvasWriteFailed = nil
local store = model.new()
local rails = {}
local logical = view.newState()
local sourceLocators, sourceFacts, sourceDirty, sourcePollPending = {}, {}, {}, {}
local sourceObservations, sourceHeaders, helperActions = {}, {}, {}
local enqueueHelperAction, pumpHelperActions, withHeaderProof
local sourceRequest, sourceRetryAt, sourceRetryDelay, sourcePollAt = nil, 0, 0, 0
local sourceSequence, sourceFailure, sourceCursor = 0, nil, 0
local sourceLocatorEpochs, sourceProofAfter, identitySourceObservedAt = {}, nil, nil
local acquireSources
local owned = {}
local events = {}
local closedPanes, closedTabs = {}, {}
-- `cx.agents:list()` is the costliest native read (8.6 ms mean, 21 ms worst in a live window), so a pass re-reads it only
-- when an agent event, a pane appearing or closing, or the refresh age says it may have changed. Model and delivery
-- error have no event; REFRESH_MS bounds how stale they can be.
local agentCensus = { list = nil, readAt = nil, dirty = true, REFRESH_MS = 5000 }
local snapshot = nil
local ownerActive = false
local ownerKey = nil
local epoch = 0
local viewEpoch = 0
local generation = 0
local notice = nil
local lastError = nil
local inventoryError = nil
local budgetNotice = nil
local pendingVisit, pendingNavigation = nil, nil
local navigationLive, pruneNavigationJobs
-- The navigator tree of the current pass (`navigation.project`) and whether this VM restored the saved UI.
local workspace, uiRestored = nil, false
-- Navigation intents (see `intents.install`): exported entry points live here to spare `bootstrap` local registers.
local intents = {}
-- One header child independent of the ordinary source/date/mutation lane. Cancellation fences
-- consumers, never pretends a launched child stopped; the slot survives until completion/expiry.
intents.interactive = { queue = {}, sequence = 0 }
-- Focus history backs the Previous control: ordered content-pane transitions only.
-- Attention's own canvases are never destinations or departures.
local focusHistory = { stack = {}, current = nil, pendingBack = nil }
-- The last focused content destination of this window: the rail is not a destination, so the location line
-- and Reveal current keep naming it while the rail itself holds focus. Cleared when that pane disappears.
local contentPane = nil
local coalesced, heartbeat, arrivalRetirement = nil, nil, nil
local busy = false
local eventOverflow = false
local shortcutChecked = false
local nextChord = nil
local counters = { passes = 0, inventories = 0, canvasWrites = 0, layoutWrites = 0,
	focusWrites = 0, kvWrites = 0, events = 0, errors = 0, budgetPauses = 0, renders = 0 }
-- Diagnostics-only firsts for agent panes, in this VM's monotonic ms: when a pane first joined a session inventory
-- (`membershipAt`), when the native agent census first named its model (`modelAt`), when its recorded source was
-- first read (`sourceAt`), and when its identity was first proven (`identityAt`). They ride on `counters` because
-- the main chunk is at its local-register limit; no behavior reads them, the diagnostics command reports them
-- (oldest first, bounded by `max`). Firsts survive an ownership epoch change: a reused pane id keeps its earlier
-- first, which the diagnostics `allPanes` list makes visible when reading them.
counters.stages = { panes = {}, order = {}, max = 64 }
function counters.stage(pane, field)
	local stages = counters.stages
	if type(pane) ~= "number" then return end
	local entry = stages.panes[pane]
	if entry == nil then
		if #stages.order >= stages.max then stages.panes[table.remove(stages.order, 1)] = nil end
		entry = {}
		stages.panes[pane], stages.order[#stages.order + 1] = entry, pane
	end
	if entry[field] == nil then entry[field] = tern.now() end
end
local durations, durationIndex = {}, 0
-- Background-rail catch-up (see `render`): one lagging non-visible rail is painted per pass, round-robin by instance key.
-- `after` is the last key painted, `passStartedAt` the current pass start and `budgetEventAt` the last native budget report.
local catchup = { after = "", passStartedAt = nil, budgetEventAt = nil, PASS_MS = 25, PAUSE_MS = 5000, BACKOFF_MS = 2000,
	BACKOFF_MAX_MS = 30000, REFRESH_MS = 10000, OVER_BUDGET_RETRY_MS = 250, timer = nil, pending = nil }
local schedule, runPass, armHeartbeat, resetOwnedTitles

local function id(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge and value % 1 == 0
end

local function text(value, fallback)
	return if type(value) == "string" then value else fallback
end

local function optionalText(value)
	if value == nil or value == tern.json.null then return nil end
	assert(type(value) == "string", "Unsupported native text field")
	return if value == "" then nil else value
end

local function flag(value)
	if value == nil or value == tern.json.null then return false end
	assert(type(value) == "boolean", "Unsupported native boolean field")
	return value
end

local function optionalId(value)
	if value == nil or value == tern.json.null then return nil end
	assert(id(value), "Unsupported native identity")
	return value
end

local function array(value, label)
	assert(type(value) == "table" and value ~= tern.json.null, label .. " unavailable")
	local count = 0
	for key in pairs(value) do
		assert(type(key) == "number" and key >= 1 and key % 1 == 0, label .. " has unsupported shape")
		count += 1
	end
	assert(count == #value, label .. " is not a contiguous list")
	return value
end

local SCHEMA = 4
-- Rail placement vocabulary and pure helpers share one table: `bootstrap` sits at Luau's 200-local limit.
-- A position is the user's word for an edge; the layout engine's name for bottom is "down".
local placement = {
	positions = { left = true, bottom = true, right = true },
	edges = { left = "left", bottom = "down", right = "right" },
	positionOf = { left = "left", down = "bottom", right = "right" },
	default = "left",
	-- Delay before the next pass while a rail is placing: a tab the user is waiting on must not idle between batches.
	PASS_MS = 8,
	-- Two observed rail widths closer than this are the same width.
	SHARE_EPSILON = 0.000001,
	-- Tabs this window saw created (`tab_created`), until their rail is created or the tab closes. Such a tab cannot hold a
	-- restored canvas, so its rail skips the restore grace. Bounded: entries past the cap are not recorded (they keep the grace).
	createdTabs = {},
	MAX_CREATED_TABS = 64,
	-- Stored fields this version reads or validates. Legacy fields it drops on load (`share`, `shares`, `relocate`, the retired
	-- Later age `backlogAfterSeconds`) are listed too, so `carry` never forwards them. Anything else belongs to a newer or
	-- foreign writer and is carried through.
	known = {
		top = { schema = true, enabled = true, owner = true, backlogAfterSeconds = true, defaults = true,
			instances = true, uiByWindow = true, queueOrder = true, sessionOrder = true },
		defaults = { position = true, shares = true, share = true, hidden = true },
		entry = { tab = true, session = true, pane = true, userHidden = true, position = true, shares = true,
			share = true, creating = true, retiring = true, closeAccepted = true, placement = true, remnants = true,
			moveTo = true, relocate = true },
	},
}

local function fraction(value)
	return type(value) == "number" and value == value and value > 0 and value < 1
end

local function deepEqual(a, b)
	-- Equal primitives and shared references are equal without the recursive walk.
	if a == b then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, item in pairs(a) do if not deepEqual(item, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

function placement.clone(value)
	if type(value) ~= "table" or value == tern.json.null then return value end
	local result = {}
	for key, item in pairs(value) do result[key] = placement.clone(item) end
	return result
end

function placement.carry(target, source, known)
	for key, item in pairs(source) do
		if not known[key] then target[key] = placement.clone(item) end
	end
end

-- The rail's share of the tab along its edge: the root ratio for a left rail, the remainder for the others.
function placement.share(edge, root)
	local ratio = root.ratio or 0.5
	return if edge == "left" then ratio else 1 - ratio
end

-- Persisted navigator state for one window (D3): an unknown or transient section falls back to Attention and
-- only bounded string keys survive, so a hand-edited or foreign value can never wedge the view.
local function sanitizeUi(saved)
	local ui = { section = "attention", collapsed = {} }
	if UI_SECTIONS[saved.section] then ui.section = saved.section end
	local keys = {}
	if type(saved.collapsed) == "table" then
		for key, open in pairs(saved.collapsed) do
			-- `collapsed` is tri-state (false = opened against a closed default).
			if type(key) == "string" and #key <= MAX_UI_KEY and (open == true or open == false) then
				table.insert(keys, key)
			end
		end
	end
	table.sort(keys)
	for index = 1, math.min(#keys, MAX_UI_KEYS) do ui.collapsed[keys[index]] = saved.collapsed[keys[index]] end
	return ui
end


-- Parses any stored preferences into one schema-4 value and reports whether the stored copy must be rewritten.
-- Schema 2/3 migrate on read (their in-flight placement checkpoints are dropped unreplayed). A schema-4 store
-- written before placement was per-tab keeps its instances without a position: each is adopted at its physical
-- edge on first observation, never moved. The obsolete `relocate` flag is stripped, unknown fields survive, and
-- a newer schema raises, so nothing here can ever write it back downgraded.
local function parsePreferences(raw, checkMigration)
	-- The queue sections' display order: both queue names, once each. The retired `later` queue is dropped from a stored
	-- order; anything that is not then exactly the two queues falls back to the default.
	local function parseQueueOrder(value)
		local default = { "attention", "working" }
		if value == nil then return default end
		array(value, "Attention queue order")
		local queueOrder = {}
		for _, name in ipairs(value) do
			if name ~= "later" then table.insert(queueOrder, name) end
		end
		local permutation = #queueOrder == 2 and queueOrder[1] ~= queueOrder[2]
			and table.find(default, queueOrder[1]) ~= nil and table.find(default, queueOrder[2]) ~= nil
		return if permutation then queueOrder else default
	end

	-- Per-host session display order: string host key → unique positive session ids, capped per host and in
	-- total; ids with no live session are ignored on read in navigation.
	local function parseSessionOrder(value)
		local order = {}
		if value == nil then return order end
		assert(type(value) == "table" and value ~= tern.json.null, "Attention session order unavailable")
		local maxPerHost, maxHosts, maxEntries = 256, 64, 1024
		local entries = 0
		for hostKey, ids in pairs(value) do
			assert(type(hostKey) == "string" and #hostKey <= MAX_UI_KEY, "Attention session order host unavailable")
			array(ids, "Attention session order")
			assert(#ids > 0 and #ids <= maxPerHost, "Attention session order length unavailable")
			local seen = {}
			for _, sessionId in ipairs(ids) do
				assert(id(sessionId) and sessionId > 0 and not seen[sessionId], "Attention session order unavailable")
				seen[sessionId] = true
			end
			-- Stored ids carry Tern's protected metatable; copy into a plain table.
			local stored = {}
			for _, sessionId in ipairs(ids) do table.insert(stored, sessionId) end
			order[hostKey] = stored
			entries += #ids
		end
		assert(countKeys(order) <= maxHosts and entries <= maxEntries, "Attention session order is too large")
		return order
	end
	if raw == nil then
		return { schema = SCHEMA, enabled = false,
			defaults = { position = placement.default, shares = { left = {}, bottom = {}, right = {} }, hidden = {} },
			instances = {}, uiByWindow = {}, queueOrder = parseQueueOrder(nil), sessionOrder = parseSessionOrder(nil) }, false
	end
	assert(type(raw) == "table" and type(raw.enabled) == "boolean", "Attention preferences unavailable")
	local schema = raw.schema
	assert(not (type(schema) == "number" and schema > SCHEMA),
		"Attention preferences were written by a newer version; they are left unchanged")
	assert(schema == nil or schema == 2 or schema == 3 or schema == SCHEMA, "Unsupported Attention preferences schema")
	assert(raw.owner == nil or type(raw.owner) == "string", "Attention owner selector unavailable")
	assert(not raw.enabled or type(raw.owner) == "string", "Attention needs Enable here")
	local defaults = if schema == 3 or schema == SCHEMA then raw.defaults else
		{ position = raw.position or placement.default, shares = if schema == 2 then raw.shares
			else { bottom = {}, right = raw.shares }, hidden = raw.suppressed }
	assert(type(defaults) == "table", "Attention defaults unavailable")
	local position = defaults.position or placement.default
	assert(placement.positions[position], "Attention placement unavailable")
	local value = { schema = SCHEMA, enabled = raw.enabled, owner = raw.owner,
		defaults = { position = position, shares = { left = {}, bottom = {}, right = {} }, hidden = {} },
		instances = {}, uiByWindow = {}, queueOrder = parseQueueOrder(raw.queueOrder),
		sessionOrder = parseSessionOrder(raw.sessionOrder) }
	if schema == SCHEMA then
		placement.carry(value, raw, placement.known.top)
		placement.carry(value.defaults, defaults, placement.known.defaults)
	end
	assert(defaults.shares == nil or type(defaults.shares) == "table", "Attention size preference unavailable")
	for axis in pairs(placement.positions) do
		local sizes = if defaults.shares then defaults.shares[axis] else nil
		assert(sizes == nil or type(sizes) == "table", "Attention size preference unavailable")
		for key, share in pairs(sizes or {}) do
			assert(type(key) == "string" and fraction(share), "Attention size preference unavailable")
			value.defaults.shares[axis][key] = share
		end
	end
	for key, hidden in pairs(defaults.hidden or {}) do
		assert(type(key) == "string" and type(hidden) == "boolean", "Attention visibility preference unavailable")
		if hidden then value.defaults.hidden[key] = true end
	end
	for key, entries in pairs(if schema == 3 or schema == SCHEMA then raw.instances or {} else {}) do
		assert(type(key) == "string" and type(entries) == "table", "Attention tab registry unavailable")
		value.instances[key] = {}
		for tabKey, entry in pairs(entries) do
			assert(type(entry) == "table" and id(entry.tab) and tabKey == tostring(entry.tab) and id(entry.session),
				"Attention tab identity unavailable")
			assert(entry.pane == nil or id(entry.pane), "Attention pane identity unavailable")
			assert(type(entry.userHidden) == "boolean", "Attention tab preferences unavailable")
			assert(entry.position == nil or placement.positions[entry.position], "Attention tab placement unavailable")
			assert(schema ~= 3 or entry.position ~= nil, "Attention tab placement unavailable")
			assert(entry.moveTo == nil or placement.positions[entry.moveTo], "Attention tab move request unavailable")
			assert(entry.creating == nil or type(entry.creating) == "boolean", "Attention creation state unavailable")
			assert(entry.retiring == nil or type(entry.retiring) == "boolean", "Attention retirement state unavailable")
			assert(entry.closeAccepted == nil or type(entry.closeAccepted) == "boolean", "Attention close state unavailable")
			local remnants = nil
			if entry.remnants ~= nil then
				remnants = {}
				for _, pane in ipairs(array(entry.remnants, "Attention restored canvas list")) do
					assert(id(pane) and pane ~= entry.pane and not table.find(remnants, pane),
						"Attention restored canvas identity unavailable")
					table.insert(remnants, pane)
				end
				assert(#remnants > 0 and #remnants <= MAX_REMNANTS, "Attention restored canvas list unavailable")
			end
			if schema == SCHEMA and entry.placement ~= nil then
				assert(type(entry.placement) == "table" and (entry.placement.status == "placing" or entry.placement.status == "failed")
					and type(entry.placement.checkpoint) == "table", "Attention placement recovery unavailable")
				assert(entry.placement.reason == nil or (type(entry.placement.reason) == "string"
					and #entry.placement.reason <= 512), "Attention placement failure unavailable")
				assert(entry.placement.generation == nil or (id(entry.placement.generation)
					and entry.placement.generation >= 0), "Attention placement request unavailable")
			end
			local saved = {}
			if schema == SCHEMA then placement.carry(saved, entry, placement.known.entry) end
			saved.tab, saved.session, saved.pane, saved.userHidden = entry.tab, entry.session, entry.pane, entry.userHidden
			saved.position, saved.creating = entry.position, entry.creating
			saved.retiring, saved.closeAccepted, saved.remnants = entry.retiring, entry.closeAccepted, remnants
			saved.moveTo = if schema == SCHEMA then entry.moveTo else nil
			saved.placement = if schema == 3 then nil else entry.placement
			value.instances[key][tabKey] = saved
		end
	end
	for window, saved in pairs(if schema == SCHEMA then raw.uiByWindow or {} else {}) do
		assert(type(window) == "string" and type(saved) == "table", "Attention window state unavailable")
		value.uiByWindow[window] = sanitizeUi(saved)
	end
	-- Only load-time callers need the migration flag; skipping the deep comparison keeps hot parses cheap.
	if checkMigration then return value, not deepEqual(value, raw) end
	return value
end

local function preferences(checkMigration)
	return parsePreferences(tern.kv.get(PREFS), checkMigration)
end

local function isOwner(cx)
	local prefs, migrate = preferences(true)
	return prefs.enabled and prefs.owner == cx:window_key(), prefs, migrate
end

local function requireOwner(cx)
	local active, prefs = isOwner(cx)
	assert(prefs.enabled, "Attention is disabled; use Attention: Enable here")
	assert(active, "Attention is controlled by another window; use Attention: Enable here")
end

-- STATE-05 custody. Every preference write validates the whole candidate, writes once and reads the store
-- back; a failure raises into the caller's visible report. Native visibility settings are never written.
local function commitPreferences(candidate)
	local value = parsePreferences(candidate)
	tern.kv.set(PREFS, value)
	counters.kvWrites += 1
	assert(deepEqual(parsePreferences(tern.kv.get(PREFS)), value), "Attention preferences did not persist; the saved copy differs")
	return value
end

local function savePreferences(cx, prefs)
	requireOwner(cx)
	commitPreferences(prefs)
end

-- The width a rail on `rail`'s host takes at `position`: one share per host and position, 0.25 until the user drags.
function placement.shareFor(rail, position)
	return preferences().defaults.shares[position][rail.key] or INITIAL_SHARE
end

-- Persists a settled drag as that host's width for `position`; an unchanged width writes nothing.
function placement.recordShare(cx, rail, position, share)
	local prefs = preferences()
	local sizes = prefs.defaults.shares[position]
	if math.abs((sizes[rail.key] or INITIAL_SHARE) - share) <= placement.SHARE_EPSILON then return end
	sizes[rail.key] = share
	savePreferences(cx, prefs)
end

-- Writes one rail's saved instance immediately; write-ahead placement checkpoints use this directly.
local function commitInstance(cx, rail)
	local prefs = preferences()
	prefs.instances[rail.key] = prefs.instances[rail.key] or {}
	prefs.instances[rail.key][tostring(rail.tab)] = rail.saved
	savePreferences(cx, prefs)
end

-- Pass-scoped accumulator: observational instance updates collect here and commit once at the pass's end.
-- Observations are idempotent (the next pass re-observes native state), so a failed pass may drop them.
local instanceBatch = nil

local function saveInstance(cx, rail)
	if instanceBatch then
		table.insert(instanceBatch, { key = rail.key, tab = rail.tab, saved = rail.saved })
		return
	end
	commitInstance(cx, rail)
end

local function removeInstance(cx, rail)
	if instanceBatch then
		table.insert(instanceBatch, { key = rail.key, tab = rail.tab, remove = true })
		return
	end
	local current = preferences()
	dropInstanceTab(current, rail.key, rail.tab)
	savePreferences(cx, current)
end

local function commitInstanceBatch(cx)
	local batch = instanceBatch
	instanceBatch = nil
	if not batch or #batch == 0 then return end
	local prefs = preferences()
	for _, op in ipairs(batch) do
		if op.remove then
			dropInstanceTab(prefs, op.key, op.tab)
		else
			prefs.instances[op.key] = prefs.instances[op.key] or {}
			prefs.instances[op.key][tostring(op.tab)] = op.saved
		end
	end
	savePreferences(cx, prefs)
end

local function savePlacement(cx, rail, status)
	rail.saved.placement = { status = status, checkpoint = layout.checkpoint(rail.layout),
		generation = rail.generation or rail.layout.generation or 0,
		reason = if rail.error then string.sub(tostring(rail.error), 1, 512) else nil }
	-- Placement checkpoints are write-ahead: they always commit now, never behind the observational batch.
	commitInstance(cx, rail)
end

-- Saved navigator state for one window, or nil before its first activation (which starts in Attention).
local function uiFor(prefs, windowKey)
	return prefs.uiByWindow[windowKey]
end

-- Persists the owner window's navigator state (`view.ui(logical)`); returns whether anything was written.
local function saveUi(cx, ui)
	requireOwner(cx)
	local prefs, window = preferences(), cx:window_key()
	local candidate = sanitizeUi(ui)
	if deepEqual(prefs.uiByWindow[window], candidate) then return false end
	prefs.uiByWindow[window] = candidate
	local others = {}
	for key in pairs(prefs.uiByWindow) do if key ~= window then table.insert(others, key) end end
	table.sort(others)
	for index = 1, #others - (MAX_UI_WINDOWS - 1) do prefs.uiByWindow[others[index]] = nil end
	commitPreferences(prefs)
	return true
end


-- Native failures carry `source.luau:line:` prefixes, Lua tracebacks and filesystem paths; user-facing text keeps
-- only the first line's words.
local function humanize(message)
	local value = string.match(string.sub(tostring(message), 1, 512), "^%s*([^\n]*)")
	while true do
		local stripped = string.gsub(value, "^%S+:%d+: ", "", 1)
		if stripped == value then break end
		value = stripped
	end
	value = string.gsub(value, "%S*%.luau:%d+: ", "")
	-- An absolute path (and the slash-bearing words of a spaced directory name after it) goes; `America/New_York` stays.
	value = string.gsub(" " .. value, "%s~?/%S*", " \1")
	repeat
		local more
		value, more = string.gsub(value, "\1 %S*/%S*", "\1")
	until more == 0
	value = string.gsub(value, "\1", "")
	value = string.gsub(value, "%s+", " ")
	value = string.gsub(value, "^ ", "")
	return (string.gsub(value, " $", ""))
end

local function report(cx, message, toast)
	message = string.sub(tostring(message), 1, 512)
	local shown = humanize(message)
	notice = shown
	if lastError ~= shown then
		lastError = shown
		counters.errors += 1
		tern.log.warn("Attention:", message)
		if toast then cx:toast("error", "Attention", shown) end
	end
end

local function invalidate()
	if arrivalRetirement then arrivalRetirement:cancel(); arrivalRetirement = nil end
	epoch += 1
	generation += 1
	store = model.new()
	hydrated, savedRevision, storageProblem, projection = false, nil, nil, nil
	identities, identityReady, identityRequest, identityPending = {}, false, nil, {}
	identityNeeded, identityMembership, identitySignals = true, {}, {}
	identityRetryAt, identityRetryDelay, identityFailure = nil, nil, nil
	logical = view.newState()
	sourceLocators, sourceFacts, sourceDirty, sourcePollPending = {}, {}, {}, {}
	sourceObservations, sourceHeaders, helperActions = {}, {}, {}
	intents.interactive.queue = {}
	if intents.interactive.timer then intents.interactive.timer:cancel(); intents.interactive.timer = nil end
	placement.observations, placement.projections = nil, nil
	instanceBatch = nil
	sourceRetryAt, sourceRetryDelay, sourcePollAt = 0, 0, 0
	sourceCursor, sourceFailure = 0, nil
	sourceLocatorEpochs, sourceProofAfter, identitySourceObservedAt = {}, nil, nil
	knownHostKeys = {}
	observedAttention, observedProjection, arrivalQuietUntil = nil, nil, 0
	pendingArrival = nil
	remnantProbe, remnantEvidence, remnantCloses = nil, {}, {}
	rails, owned, events = {}, {}, {}
	closedPanes, closedTabs = {}, {}
	placement.createdTabs = {}
	snapshot, pendingVisit, pendingNavigation = nil, nil, nil
	workspace, uiRestored = nil, false
	focusHistory, contentPane = { stack = {}, current = nil, pendingBack = nil }, nil
	eventOverflow = false
end

local function syncOwnership(cx, shared, sharedMigrate)
	local active, prefs, migrate
	if shared then
		-- The heartbeat's own validated parse: reuse it instead of reading the store again.
		prefs, migrate = shared, sharedMigrate
		active = prefs.enabled and prefs.owner == cx:window_key()
	else
		active, prefs, migrate = isOwner(cx)
	end
	local key = cx:window_key()
	assert(type(key) == "string", "Native window selector unavailable")
	if active and migrate then
		requireOwner(cx)
		commitPreferences(prefs)
	end
	if active ~= ownerActive or ownerKey ~= prefs.owner then
		local lost = ownerActive and not active
		invalidate()
		ownerActive, ownerKey = active, prefs.owner
		notice = if active then nil elseif prefs.enabled then "Controlled in another window · use Enable here" else "Attention is disabled"
		if lost then resetOwnedTitles(cx) end
		-- A window that loses ownership because Attention was disabled says so; another window taking over publishes itself.
		if lost and not prefs.enabled then intents.publishDisabled(cx) end
	end
	if active then
		for _, entries in pairs(prefs.instances) do
			for _, saved in pairs(entries) do if saved.retiring then closedTabs[saved.tab] = true end end
		end
	end
	return active, prefs
end

local function markerIdentity(about)
	if type(about) ~= "string" or #about > 128 then return nil end
	local session, tab = string.match(about, "^attention:tab:v1:(%d+):(%d+)$")
	session, tab = tonumber(session), tonumber(tab)
	if id(session) and id(tab) then return session, tab end
	return nil
end

local function canvasOwned(value)
	return type(value) == "table" and id(value.pane) and value.owner == "attention"
		and (value.about == MARKER or markerIdentity(value.about) ~= nil)
end

resetOwnedTitles = function(cx)
	local listed, canvases = pcall(function() return array(cx.canvas:list(), "Canvases") end)
	if not listed then return end
	for _, canvas in ipairs(canvases) do
		if canvasOwned(canvas) then pcall(cx.canvas.set, cx.canvas, canvas.pane, { title = "Attention" }) end
	end
end

local statePainted = nil
-- A pass that cannot observe or render paints one honest line everywhere it owns instead of stale content.
local function paintState(cx, line)
	if statePainted == line then return end
	local listed, canvases = pcall(function() return array(cx.canvas:list(), "Canvases") end)
	if not listed then return end
	-- The next healthy pass must repaint fully, so no rail view may consider itself current.
	for _, rail in pairs(rails) do view.invalidate(rail.view) end
	for _, canvas in ipairs(canvases) do
		if canvasOwned(canvas) then
			local painted = pcall(cx.canvas.set, cx.canvas, canvas.pane, { view = { k = "col",
				p = { role = "attention.root" }, c = { { k = "text", p = { text = line } } } } })
			if painted then counters.canvasWrites += 1 end
		end
	end
	statePainted = line
end

local function pausedLine(reason)
	local words = humanize(reason)
	words = string.gsub(words, "%S*/%S*", " ")
	words = string.gsub(words, "%s+", " ")
	words = string.gsub(string.gsub(words, "^%s", ""), "%s+$", "")
	return string.sub("Attention paused · " .. string.gsub(words, ":$", ""), 1, 160)
end

local function treeHas(tree, pane)
	if type(tree) ~= "table" then return false end
	if tree.pane ~= nil then return tree.pane == pane end
	return treeHas(tree[1], pane) or treeHas(tree[2], pane)
end

local function treeLeaf(tree, excluded)
	if type(tree) ~= "table" then return nil end
	if tree.pane ~= nil then return if not excluded[tree.pane] then tree.pane else nil end
	return treeLeaf(tree[1], excluded) or treeLeaf(tree[2], excluded)
end

local function inventory(cx)
	counters.inventories += 1
	local hosts, sessions, tabs = cx.hosts:list(), cx.sessions:list(), cx.session:tabs()
	local panes = cx.session:panes()
	local now = tern.now()
	if agentCensus.dirty or agentCensus.list == nil or now - agentCensus.readAt >= agentCensus.REFRESH_MS then
		agentCensus.list, agentCensus.readAt, agentCensus.dirty = cx.agents:list(), now, false
	end
	local agents = agentCensus.list
	if agentCensus.readAt ~= now then
		-- A reused census never names a pane that has since left; that agent is gone, not pending.
		local present, kept = {}, {}
		for _, source in ipairs(panes) do
			if type(source) == "table" and type(source.pane) == "number" then present[source.pane] = true end
		end
		for _, source in ipairs(agents) do
			if type(source) ~= "table" or present[source.pane] then table.insert(kept, source) end
		end
		agents = kept
	end
	local raw = { hosts = hosts, sessions = sessions, tabs = tabs,
		panes = panes, agents = agents, canvases = cx.canvas:list(), focused = cx.session:focused() }
	if #raw.agents > 0 then
		-- Stage firsts (diagnostics only): this is where the census and pane membership are read.
		local member = {}
		for _, source in ipairs(raw.panes) do
			local pane = if type(source) == "table" then source.pane else source
			if type(pane) == "number" then member[pane] = true end
		end
		for _, source in ipairs(raw.agents) do
			local pane = if type(source) == "table" then source.pane else nil
			if type(pane) == "number" then
				if member[pane] then counters.stage(pane, "membershipAt") end
				if type(source.model) == "string" and source.model ~= "" then counters.stage(pane, "modelAt") end
			end
		end
	end
	local data = navigation.inventory(raw, { canvasOwned = canvasOwned, closedTabs = closedTabs, now = tern.now(),
		states = states, null = tern.json.null })
	if data.panes[data.focused] ~= nil then contentPane = data.focused
	elseif contentPane ~= nil and data.panes[contentPane] == nil then contentPane = nil end
	data.content = contentPane
	return data
end

local function observationContext(cx, data, prefs, coherent)
	local connected = {}
	for _, host in pairs(if data then data.hosts else {}) do connected[host.key] = host.connected end
	return { window = cx:window_key(), hostKeys = knownHostKeys, connected = connected,
		coherent = coherent, nowUtc = utcNow() }
end

local function hydrate(cx)
	if hydrated then return true end
	local ok, failure = pcall(function()
		local saved = tern.kv.get("triage")
		store = model.new(saved)
		-- model.new starts at revision 0; any bump during load is a migration (later → finished, retired fields) to write.
		savedRevision = if saved == nil or saved.schema == 3 then 0 else nil
		hydrated = true
		for _, record in ipairs(if saved and saved.schema == 3 then saved.items else {}) do
			if record.identityKey and record.source then sourceFacts[record.identityKey] = record.source end
		end
	end)
	if not ok then
		storageProblem = "Saved attention is unavailable: " .. humanize(failure)
		report(cx, storageProblem, false)
	end
	return ok
end

local acquireIdentity

-- A signal on a pane makes its proof pending; an in-flight inspection cannot prove it, so exactly one
-- follow-up inspection runs after the current one completes. Structural inputs (`structural`: a pane
-- appeared or moved, navigation, a disproven header) re-prove immediately even during failure backoff;
-- content signals (title/agent state) ride the next admitted inspection instead of re-arming the storm.
local function invalidateIdentity(pane, structural)
	identityPending[pane], identityNeeded = true, true
	if structural then identityUrgent = true end
	if identityRequest then identityRequest.dirty[pane] = true end
	sourceDirty[pane] = true
	if sourceRequest then sourceRequest.dirty[pane] = true end
	if intents.interactive.request then intents.interactive.request.dirty[pane] = true end
end

-- In-flight helper results pin their identity key until the request settles (module-scope requestTargetsKey).

local function sourceKeyTargeted(key)
	return requestTargetsKey(sourceRequest, key) or requestTargetsKey(intents.interactive.request, key)
end

local function refresh(cx, deferSources, acceptIdentity, shared)
	if not hydrate(cx) then return nil end
	intents.expireNavigation(cx)
	-- `shared` is a validated snapshot from the same synchronous callback; other callers re-read.
	local prefs = shared or preferences()
	local ok, value = pcall(inventory, cx)
	local pending = events
	events = {}
	if not ok or eventOverflow then
		local reason = if eventOverflow then "Native event burst exceeded the current observation window" else tostring(value)
		eventOverflow = false
		inventoryError = humanize(reason)
		identityReady, identityNeeded = false, true
		report(cx, reason, false)
		model.reconcile(store, { now = tern.now(), ok = false, error = reason, agents = {}, panes = {}, hosts = {},
			identities = identities, identityReady = false }, pending, observationContext(cx, nil, prefs, false))
		return nil
	end
	if inventoryError and notice == inventoryError then notice, lastError = nil, nil end
	inventoryError = nil
	if pendingNavigation and value.panes[value.focused] and owned[value.focused] == nil
		and value.focused ~= pendingNavigation.focused then
		pendingNavigation = nil
	end
	for host, info in pairs(value.hosts) do knownHostKeys[host] = info.key end
	local membership, signals = {}, {}
	for pane, info in pairs(value.panes) do
		membership[pane] = tostring(info.host) .. ":" .. tostring(info.session) .. ":" .. tostring(info.tab)
		if info.alert or info.startupError then signals[pane] = true end
	end
	for _, agent in ipairs(value.agents) do
		if agent.state == "waiting_input" or agent.deliveryError then signals[agent.pane] = true end
	end
	for pane, member in pairs(membership) do
		-- A pane that moved or appeared has no usable key until a fresh inspection proves one; that is
		-- structural, so it re-proves even while a failing inspection's backoff is armed.
		if identityMembership[pane] ~= member then identities[pane] = nil; invalidateIdentity(pane, true) end
	end
	for pane in pairs(signals) do if not identitySignals[pane] then invalidateIdentity(pane) end end
	for pane in pairs(identityPending) do if membership[pane] == nil then identityPending[pane] = nil end end
	for pane in pairs(sourceLocators) do if membership[pane] == nil then sourceLocators[pane] = nil end end
	-- Dead panes leave no stale source flags or locator epochs behind; a closed pane is never a candidate again.
	for pane in pairs(sourceDirty) do if membership[pane] == nil then sourceDirty[pane] = nil end end
	for pane in pairs(sourcePollPending) do if membership[pane] == nil then sourcePollPending[pane] = nil end end
	for pane in pairs(sourceLocatorEpochs) do if membership[pane] == nil then sourceLocatorEpochs[pane] = nil end end
	identityMembership, identitySignals = membership, signals
	if identityRequest and tern.now() > identityRequest.deadline + 1000 then
		local expired = identityRequest
		identityRequest, identityReady, identityNeeded = nil, false, false
		identityRetryDelay = if identityRetryDelay == nil then 2000 else math.min(identityRetryDelay * 2, 60000)
		identityRetryAt = tern.now() + identityRetryDelay
		if pendingNavigation and pendingNavigation.request == expired then
			intents.endNavigation(pendingNavigation, cx, "Opening expired · try again")
			pendingNavigation = nil
		end
		report(cx, "Native identity inspection expired; retrying with current locator proof", false)
		identityFailure = notice
	end
	if identityRetryAt and not identityRequest and tern.now() >= identityRetryAt then
		identityRetryAt, identityNeeded = nil, true
	end
	-- Membership/signals have invalidated proof immediately. Accept the inspection before
	-- the single reconcile consumes that new identity together with this exact event batch.
	if acceptIdentity then acceptIdentity(value) end
	value.identities, value.identityReady, value.identityPending = identities, identityReady, table.clone(identityPending)
	value.sourceFacts, value.sources = sourceFacts, sourceLocators
	value.sourceObservations, value.sourceHeaders = sourceObservations, sourceHeaders
	snapshot = value
	model.reconcile(store, value, pending, observationContext(cx, value, prefs, true))
	-- Stage firsts (diagnostics only): the pass where a tracking record first claims an agent pane (native pane
	-- authority, navigation's preferred route). The scan builds the presentation only while a member pane is
	-- still unclaimed, so a settled pass costs one table walk.
	for pane, entry in pairs(counters.stages.panes) do
		if entry.membershipAt ~= nil and entry.claimedAt == nil then
			for _, row in ipairs(model.current(store).rows) do
				if row.pane == pane then counters.stage(pane, "claimedAt") end
			end
			break
		end
	end
	-- Identity-keyed source caches outlive their panes only while a current locator names the key or a retained
	-- record still holds it: its recorded fact resumes incremental capture when the conversation reopens, so an
	-- evicted key is simply re-read in full if it ever returns. Eviction waits for this VM's identity picture to
	-- settle, so facts hydration seeded are not dropped before the first locator proof arrives.
	if identityReady then
		local located = {}
		for _, locator in pairs(sourceLocators) do located[locator.key] = true end
		local retained = nil
		local function keep(key)
			if located[key] or sourceKeyTargeted(key) then return true end
			if retained == nil then
				retained = {}
				for _, row in ipairs(model.current(store).rows) do
					if row.identityKey ~= nil and (row.retained == true or row.pane == nil) then retained[row.identityKey] = true end
				end
			end
			return retained[key] == true
		end
		for key in pairs(sourceFacts) do if not keep(key) then sourceFacts[key] = nil end end
		for key in pairs(sourceObservations) do if not keep(key) then sourceObservations[key] = nil end end
		for key in pairs(sourceHeaders) do if not keep(key) then sourceHeaders[key] = nil end end
	end
	intents.expireNavigation(cx)
	if pendingNavigation and not navigationLive(pendingNavigation) then pendingNavigation = nil end
	-- Content signals respect the failure backoff; structural inputs (a new pane, navigation, a disproven
	-- header) bypass it, because a delay only ever withholds proof that is failing to arrive anyway.
	if identityNeeded and (identityUrgent or identityRetryAt == nil or tern.now() >= identityRetryAt) then
		acquireIdentity(cx)
	end
	if acquireSources and not deferSources then acquireSources(cx, value) end
	return value
end

local function project(cx, _data, _prefs, _coherent)
	local native = model.current(store)
	local ok, failure = pcall(function()
		assert(hydrated, storageProblem or "Saved attention is unavailable")
		if savedRevision ~= store.persistenceRevision then
			local saved = model.snapshot(store)
			saved.items = tern.json.array(saved.items)
			requireOwner(cx)
			tern.kv.set("triage", saved)
			counters.kvWrites += 1
			savedRevision = store.persistenceRevision
		end
	end)
	projection = native
	if ok then
		if storageProblem and notice == storageProblem then notice, lastError = nil, nil end
		storageProblem = nil
	else
		if hydrated then storageProblem = "Attention changes are not saved: " .. humanize(failure) end
		report(cx, storageProblem or failure, false)
		projection = table.clone(native)
		projection.status, projection.message = if hydrated then "unsaved" else "unavailable", storageProblem
		if not hydrated then projection.count = nil end
	end
	return projection, ok
end

-- Returns whether a conversation newly needs attention, and whether one newly entered Working.
local function observeArrivals()
	if projection == observedProjection then return false, false end
	local observed, arrived, started = {}, false, false
	for _, row in ipairs(projection.rows) do
		local previous = observedAttention and observedAttention[row.serial]
		local changed = not previous or previous.pane ~= row.pane or previous.revision ~= row.attentionRevision
			or (row.attention and not previous.eligible)
		if observedAttention and not row.stale and row.attention and changed then
			arrived = true
		end
		local working = view.inQueue(row, "working")
		if observedAttention and not row.stale and working and not (previous and previous.working) then started = true end
		observed[row.serial] = if row.stale and previous and previous.pane == row.pane then previous
			else { pane = row.pane, revision = row.attentionRevision, eligible = row.attention == true, working = working }
	end
	observedAttention, observedProjection = observed, projection
	return arrived, started
end

local function railVisible(rail, data, activeHost, activeTab)
	local native = rail.pane and data and data.allPanes[rail.pane]
	local host = data and data.hosts[rail.host]
	return activeTab and activeHost and activeHost.state == "connected"
		and native and data.canvases[rail.pane] and host and host.key == "local" and host.connected and rail.host == activeHost.id
		and native.tab == activeTab and not native.parked and not rail.saved.userHidden
end

local function reserveArrival(cx, data, arrived)
	if not arrived and not pendingArrival then return end
	local focused = cx.session:focused()
	local activeTab = if focused then cx.session:tab_of(focused) else nil
	local activeHost, target = cx.hosts:current(), nil
	local now = tern.now()
	if not inventoryError and not storageProblem then
		for _, rail in pairs(rails) do
			if railVisible(rail, data, activeHost, activeTab) and logical.section == "attention" and not logical.settings then
				target = rail
				break
			end
		end
	end
	if pendingArrival and (now >= pendingArrival.untilTime or not target
		or pendingArrival.view ~= target.view or pendingArrival.pane ~= target.pane
		or pendingArrival.tab ~= target.tab or pendingArrival.revision ~= logical.revision) then
		pendingArrival = nil
	end
	if arrived and not pendingArrival and now >= arrivalQuietUntil
		and target and target.view.previous
		and (not target.view.arrival or now >= target.view.arrival.untilTime) then
		pendingArrival = { view = target.view, pane = target.pane, tab = target.tab,
			revision = logical.revision, untilTime = now + 3000 }
	end
end

local function boundedText(value, limit)
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

-- A live content pane: inventory panes exclude every Attention-owned canvas, so presence
-- plus not parked is exactly the set Previous may target or record.
local function focusTarget(data, pane)
	if pane == nil then return false end
	local native = data.panes[pane]
	return native ~= nil and not native.parked
end

local function previousProjection(history, data)
	local found = nil
	for index = #history.stack, 1, -1 do
		if focusTarget(data, history.stack[index]) then found = history.stack[index]; break end
	end
	return { available = found ~= nil, title = if found then boundedText(data.panes[found].title, 160) else "" }
end

-- Observations are shared only inside runPass. Mutation preconditions and focused-visit
-- confirmation continue reading native layouts directly, never through this cache.
function placement.observe(cx, tab)
	local cache = placement.observations
	if cache and cache[tab] ~= nil then return cache[tab] or nil end
	local value = cx.session:layout(tab)
	if cache then cache[tab] = value or false end
	return value
end

function placement.changed()
	if placement.observations then table.clear(placement.observations) end
end

local function viewOptions(prefs, rail, data)
	local shared = placement.projections
	if not shared then
		local pending = pendingVisit or pendingNavigation
		local active = pending and (pending.navigation or pending)
		shared = { previous = previousProjection(focusHistory, data) }
		if active and (pendingVisit ~= nil or navigationLive(active)) then
			shared.navigation = { workId = active.workId, serial = active.binding.serial, pane = active.binding.pane,
				identityKey = active.identityKey, token = active.token,
				phase = if pendingVisit then "confirming" else active.phase }
		end
		if placement.observations then placement.projections = shared end
	end
	local counts = if workspace then workspace.counts else nil
	local position = rail.saved.position or prefs.defaults.position
	return { now = tern.now(), nowUtc = utcNow(), notice = rail.error or notice, position = position,
		navigation = shared.navigation, previous = shared.previous, queueOrder = prefs.queueOrder,
		workspace = workspace, current = if workspace then intents.currentLocation(workspace, data.content) else nil,
		search = { available = counts ~= nil and counts.sessions + counts.destinations + counts.retained > 0 },
		settings = { position = position, defaultPosition = prefs.defaults.position, shortcut = nextChord } }
end

local function ownedCanvas(cx, pane)
	requireOwner(cx)
	for _, value in ipairs(array(cx.canvas:list(), "Canvases")) do
		if value.pane == pane then
			assert(canvasOwned(value), "Owned Attention canvas is not available yet")
			return value
		end
	end
	error("Owned Attention canvas is not available yet")
end

local function setCanvas(cx, pane, change, data)
	-- The pass inventory already read the canvas replica ownedCanvas would list again.
	if data == nil or data.canvases[pane] == nil then ownedCanvas(cx, pane) end
	requireOwner(cx)
	local written, failure = pcall(cx.canvas.set, cx.canvas, pane, change)
	if not written then canvasWriteFailed = true; error(failure) end
	counters.canvasWrites += 1
end


local function guardedLayout(cx, rail)
	local methods = {}
	for _, name in ipairs({ "move", "move_to_tab", "resize", "dock", "park", "unpark" }) do
		methods[name] = function(_, ...)
			ownedCanvas(cx, rail.pane)
			savePlacement(cx, rail, "placing")
			requireOwner(cx)
			local called, changed, reason = pcall(cx.layout[name], cx.layout, ...)
			placement.changed()
			if not called then error(changed) end
			if changed then counters.layoutWrites += 1 end
			return changed, reason
		end
	end
	return { session = cx.session, layout = methods }
end

local function freshView(host)
	viewEpoch += 1
	return view.newRenderer(tostring(tern.now()) .. ":" .. tostring(epoch) .. ":" .. tostring(host) .. ":" .. tostring(viewEpoch))
end

local function instanceKey(hostKey, tab)
	return tostring(#hostKey) .. ":" .. hostKey .. ":" .. tostring(tab)
end

local function newRail(host, tab, prefs)
	local entries = prefs.instances[host.key]
	local saved = entries and entries[tostring(tab.id)]
	if not saved or saved.session ~= tab.session then
		saved = { tab = tab.id, session = tab.session, userHidden = prefs.defaults.hidden[host.key] == true,
			position = prefs.defaults.position }
	elseif saved.position == nil and saved.pane == nil then
		-- Nothing is mounted to adopt, so the tab follows the default.
		saved.position = prefs.defaults.position
	end
	local restored = layout.new()
	local requestGeneration = nil
	local discarded = false
	if saved.placement then
		restored = layout.restore(saved.placement.checkpoint)
		if restored then
			assert(restored.tab == tab.id and (restored.pane == nil or restored.pane == saved.pane),
				"Attention placement recovery belongs to another instance")
			requestGeneration = saved.placement.generation or restored.generation or 0
			assert(requestGeneration >= (restored.generation or 0), "Attention placement request is stale")
			generation = math.max(generation, requestGeneration)
		else
			-- An older or unreadable checkpoint is never replayed: it is dropped and the rail stays where it is.
			restored, saved.placement, discarded = layout.new(), nil, true
		end
	end
	return { host = host.id, key = host.key, tab = tab.id, session = tab.session, saved = saved, pane = saved.pane,
		view = freshView(instanceKey(host.key, tab.id)), layout = restored, generation = requestGeneration,
		pending = saved.creating == true, firstMissing = tern.now(), discoveries = 0, absentPasses = 0,
		absentSince = nil,
		phase = if saved.retiring then "closing" elseif saved.placement and saved.placement.status == "failed" then "failed"
			elseif saved.pane then (if saved.placement or saved.creating then "placing" else "ready") else "unmounted",
		error = saved.placement and saved.placement.reason,
		status = if saved.placement and saved.placement.status == "failed" then "Placement unfinished · use Reset placement"
			elseif saved.creating then "Creation outcome unknown · waiting for native metadata"
			elseif discarded then "Earlier placement attempt discarded · kept where it is"
			elseif saved.pane and not saved.retiring and not saved.placement then "Ready in this tab"
			else "Waiting for eligible tab" }
end

local function ensureRail(data, prefs, host, tab)
	local key = instanceKey(host.key, tab.id)
	local rail = rails[key]
	if not rail or rail.session ~= tab.session then
		rail = newRail(host, tab, prefs)
		rails[key] = rail
	end
	rail.host = host.id
	return rail
end

-- Follows where the rail physically is: its canonical edge is recorded per tab, and its width once the user's drag has
-- settled. Width is one share per host and position (`defaults.shares[position][hostKey]`), never per tab. A rail's
-- first observation, or its first at a new edge, is a baseline; a drag is settled when two consecutive observations
-- agree, so one gesture is one write. A rail found at a different edge than it was recorded at was moved by hand,
-- and a pending all-tabs move for it is dropped rather than undoing that.
local function observeShare(cx, rail)
	if rail.phase ~= "ready" or not rail.pane then return end
	local arrangement = placement.observe(cx, rail.tab)
	if not arrangement then return end
	local edge = layout.edgeOf(arrangement.root, rail.pane)
	if not edge then return end
	local position, share = placement.positionOf[edge], placement.share(edge, arrangement.root)
	if share <= 0 or share >= 1 then return end
	local saved = rail.saved
	if saved.position ~= position then
		saved.moveTo, saved.position = nil, position
		saveInstance(cx, rail)
	end
	local seen = rail.divider
	if seen == nil or seen.position ~= position then
		rail.divider = { position = position, share = share, settled = true }
	elseif math.abs(seen.share - share) > placement.SHARE_EPSILON then
		rail.divider = { position = position, share = share, settled = false }
	elseif not seen.settled then
		seen.settled = true
		placement.recordShare(cx, rail, position, share)
	end
end

-- A mounted rail whose store never recorded a position is adopted exactly where it is: its canonical edge when the
-- tab's root is an outer rail, otherwise the default. It never moves anything. Returns the position it was adopted at
-- and the physical width it was found at (nil when it has no edge); discover() records that width once per host and
-- position in the same write as the adoption.
function placement.adopt(cx, rail, native, prefs)
	local position, share = prefs.defaults.position, nil
	if native.tab == rail.tab and not native.parked and not native.floating then
		local arrangement = placement.observe(cx, rail.tab)
		if not arrangement then return nil end
		local edge = layout.edgeOf(arrangement.root, rail.pane)
		if edge then position, share = placement.positionOf[edge], placement.share(edge, arrangement.root) end
	end
	rail.saved.position = position
	if share and (share <= 0 or share >= 1) then share = nil end
	return position, share
end

local function retire(cx, rail, data)
	if not rail.saved.retiring then rail.saved.retiring = true; saveInstance(cx, rail) end
	rail.phase, rail.status = "closing", "Waiting for owned Attention closure"
	local pane = rail.pane

	if pane then
		if not closedPanes[pane] then
			if data.canvases[pane] and not rail.saved.closeAccepted then
				ownedCanvas(cx, pane)
				local actualTab = cx.session:tab_of(pane)
				assert(actualTab == nil or actualTab == rail.tab, "Attention moved to another tab; retirement deferred")
				cx.layout:close(pane)
				placement.changed()
				counters.layoutWrites += 1
				rail.saved.closeAccepted = true
				saveInstance(cx, rail)
			end
			if not closedPanes[pane] and (not rail.saved.closeAccepted or cx.session:pane(pane) ~= nil) then return false end
		end
	elseif rail.saved.creating then
		rail.status = "Waiting for accepted canvas metadata before retirement"
		return false
	end
	rail.pane, rail.saved.pane, rail.saved.creating, rail.pending = nil, nil, nil, false
	rail.saved.placement, rail.saved.closeAccepted = nil, nil

	rail.phase, rail.status = "retired", "Content tab closed"
	return true

end

-- GUI-launched Tern does not resolve bare `tern` through PATH, so inspection spawns an absolute executable:
-- the version-matched app bundle first on macOS, then absolute PATH entries. A found path is reused for the VM.
local ternExecutable
local function resolveTernExecutable()
	if ternExecutable then return ternExecutable end
	local candidates = {}
	if tern.runtime.os == "macos" then table.insert(candidates, "/Applications/Tern.app/Contents/MacOS/tern") end
	for entry in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
		if string.sub(entry, 1, 1) == "/" then table.insert(candidates, entry .. "/tern") end
	end
	for _, candidate in candidates do
		if tern.fs.exists(candidate) then
			ternExecutable = candidate
			return candidate
		end
	end
	return nil
end
local pythonExecutable
local function helperCommand()
	if not pythonExecutable then
		local candidates = { "/usr/bin/python3" }
		for entry in string.gmatch(tern.getenv("PATH") or "", "[^:]+") do
			if string.sub(entry, 1, 1) == "/" then table.insert(candidates, entry .. "/python3") end
		end
		for _, path in ipairs(candidates) do
			if tern.fs.exists(path) then pythonExecutable = path; break end
		end
	end
	assert(pythonExecutable, "Python 3 unavailable for recorded source")
	assert(type(tern.plugin.dir) == "string" and string.sub(tern.plugin.dir, 1, 1) == "/",
		"Installed Attention asset directory unavailable")
	local helper = tern.plugin.dir .. "/source_facts.py"
	assert(tern.fs.exists(helper), "Installed recorded-source helper unavailable")
	return { pythonExecutable, helper }
end
pumpHelperActions = function(cx)
	if pruneNavigationJobs then pruneNavigationJobs() end
	for laneIndex = 1, 2 do
		local interactive = laneIndex == 1
		local lane = intents.interactive
		local queue = if interactive then lane.queue else helperActions
		if (if interactive then lane.request else sourceRequest) then continue end
		while #queue > 0 do
			local job = table.remove(queue, 1)
			if job.epoch ~= epoch or job.live and not job.live() then continue end
			if job.navigation and pendingNavigation == job.navigation then job.navigation.phase = "checking" end
			job.startedAtUtc, job.deadline = utcNow(), tern.now() + job.timeout
			job.payload.nowUtc = job.startedAtUtc
			if interactive then lane.request = job else sourceRequest = job end
			local function release()
				if interactive then
					if lane.request == job then lane.request = nil end
				elseif sourceRequest == job then sourceRequest = nil end
			end
			local function completed(result, fresh, failure)
				if (if interactive then lane.request else sourceRequest) ~= job then return end
				if epoch ~= job.epoch then release(); schedule(32); return end
				intents.expireNavigation(fresh)
				if job.live and not job.live(fresh) then release(); schedule(32); return end
				if not fresh then
					if job.failed then job.failed(nil, "Current window unavailable") end
					release()
					report(nil, "Local verification returned without a current window", false)
					schedule(32)
					return
				end
				-- Keep ownership until the continuation returns. A hard interruption leaves
				-- this job visible to expiry, and the independent click deadline survives it.
				local ok, problem = pcall(function()
					assert(fresh:window_key() == job.window and syncOwnership(fresh) and epoch == job.epoch,
						"Local verification owner changed")
					if job.live and not job.live(fresh) then return end
					assert(not failure, failure)
					assert(tern.now() <= job.deadline and type(result) == "table" and result.status == 0
						and not result.timed_out and type(result.stdout) == "string" and #result.stdout <= 65536,
						"Local verification failed or expired")
					local response = tern.json.decode(result.stdout)
					assert(response.protocol == 1 and response.requestId == job.payload.requestId,
						"Local verification response identity changed")
					job.callback(response, fresh, job)
				end)
				if not ok and epoch == job.epoch then
					if job.failed then job.failed(fresh, problem) end
					report(fresh, if job.navigation then humanize(problem) .. " · try again" else problem, true)
				end
				release()
				schedule(32)
			end
			job.completed = completed
			local launched, failure = pcall(function()
				tern.process.run(helperCommand(), { timeout_ms = job.timeout, stdin = tern.json.encode(job.payload) }, completed)
			end)
			if not launched then
				release()
				if job.failed then job.failed(cx, failure) end
				report(cx, "Local verification unavailable · " .. humanize(failure), true)
				schedule(32)
			end
			break
		end
	end
end

enqueueHelperAction = function(cx, payload, timeout, callback, failed, live, navigation)
	if pruneNavigationJobs then pruneNavigationJobs() end
	local queue = if navigation then intents.interactive.queue else helperActions
	assert(#queue < 16, "Local verification is busy; choose the action again")
	sourceSequence += 1
	payload.protocol, payload.requestId = 1, (if navigation then "interactive:" else "") .. payload.op .. ":" .. epoch .. ":" .. sourceSequence
	local job = { action = true, epoch = epoch, window = cx:window_key(), payload = payload, timeout = timeout,
		callback = callback, failed = failed, live = live, navigation = navigation, dirty = {} }
	table.insert(queue, job)
	pumpHelperActions(cx)
	return job
end


local function currentSource(pane, target, request)
	local locator = sourceLocators[pane]
	return locator and locator.localSource and locator.key == target.key and locator.path == target.path
		and request.locatorEpochs[pane] == sourceLocatorEpochs[pane]
		and identities[pane] == target.key and not identityPending[pane]
		and not request.dirty[pane] and request.membership[pane] == identityMembership[pane]
end

acquireSources = function(cx, data)
	local now = tern.now()
	local interactive = intents.interactive.request
	if interactive and now > interactive.deadline + 1000 then
		-- Native execution has a finite timeout. Do not replay a possibly interrupted
		-- continuation: abandon its navigation and release only this expired slot.
		if interactive.epoch == epoch then
			intents.endNavigation(interactive.navigation, cx, "Opening expired · try again")
		end
		if intents.interactive.request == interactive then intents.interactive.request = nil end
	end
	pumpHelperActions(cx)
	if sourceRequest then
		if now > sourceRequest.deadline + 1000 then
			if sourceRequest.epoch ~= epoch then sourceRequest = nil; schedule(32); return end
			if sourceRequest.action then
				local job = sourceRequest
				sourceRequest = nil
				if job.failed then job.failed(cx, "Local verification request expired") end
				report(cx, "Local verification request expired", false)
				schedule(32)
			else
				-- Native timeout kills the finite helper even if its callback was budget-interrupted.
				sourceRequest, sourceRetryAt = nil, now + 2000
				sourceFailure = "Recorded source request expired"
			end
		end
		return
	end
	if #helperActions > 0 then return end
	if pendingVisit or pendingNavigation then return end
	if now < sourceRetryAt then return end
	local poll = now >= sourcePollAt
	if poll then
		for pane, locator in pairs(sourceLocators) do
			sourcePollPending[pane] = true
			if locator.localSource then sourceProofAfter = now end
		end
		sourcePollAt = now + 30000
	end
	if sourceProofAfter ~= nil then
		if identitySourceObservedAt == nil or identitySourceObservedAt < sourceProofAfter then
			if not identityRequest and (identityRetryAt == nil or now >= identityRetryAt) then
				identityNeeded = true
				acquireIdentity(cx)
			end
			return
		end
		sourceProofAfter = nil
	end
	local targets, routes, candidates = {}, {}, {}
	for pane in pairs(sourceLocators) do table.insert(candidates, pane) end
	table.sort(candidates)
	local start = 1
	for index, pane in ipairs(candidates) do
		if pane > sourceCursor then start = index; break end
	end
	for offset = 0, #candidates - 1 do
		local pane = candidates[(start + offset - 1) % #candidates + 1]
		local locator = sourceLocators[pane]
		if data.panes[pane] and locator.localSource and not identityPending[pane]
			and identities[pane] == locator.key
			and (sourceDirty[pane] or sourceObservations[locator.key] == nil or sourcePollPending[pane]) then
			local previous = sourceFacts[locator.key]
			local target = { key = locator.key, path = locator.path,
				previousRevision = if previous and previous.reusable == true
					and (sourceObservations[locator.key] == nil or sourceObservations[locator.key].reusable == true)
					and (sourceHeaders[locator.key] == nil or (sourceHeaders[locator.key].status == "ready"
						and sourceHeaders[locator.key].sessionId == previous.sessionId)) then previous.revision else nil }
			table.insert(targets, target)
			routes[locator.key] = pane
			sourceCursor = pane
			-- Yield the shared helper slot after this target so queued header/date actions go first.
			break
		end
	end
	if #targets == 0 then return end
	sourceSequence += 1
	local request = { epoch = epoch, window = cx:window_key(), membership = identityMembership,
		dirty = {}, targets = targets, routes = routes, id = "source:" .. epoch .. ":" .. sourceSequence,
		deadline = now + 8000 }
	request.locatorEpochs = table.clone(sourceLocatorEpochs)
	request.capturedAtUtc = utcNow()
	sourceRequest = request
	local function failed(message)
		if sourceRequest ~= request then return end
		sourceRequest = nil
		if epoch ~= request.epoch then schedule(32); return end
		sourceRetryDelay = math.min(if sourceRetryDelay == 0 then 2000 else sourceRetryDelay * 2, 60000)
		sourceRetryAt = tern.now() + sourceRetryDelay
		sourceFailure = "Recorded source unavailable · " .. humanize(message)
		schedule(32)
	end
	local launched, failure = pcall(function()
		tern.process.run(helperCommand(), { timeout_ms = 8000,
			stdin = tern.json.encode({ protocol = 1, requestId = request.id, nowUtc = request.capturedAtUtc,
				targets = tern.json.array(targets) }) }, function(result, fresh)
			if sourceRequest ~= request then return end
			if epoch ~= request.epoch then sourceRequest = nil; schedule(32); return end
			local accepted, problem = pcall(function()
				assert(fresh and fresh:window_key() == request.window, "Recorded source returned without its owner window")
				assert(syncOwnership(fresh) and epoch == request.epoch, "Recorded source owner changed")
				assert(not request.expired and tern.now() <= request.deadline, "Recorded source request expired")
				assert(type(result) == "table" and result.status == 0 and result.timed_out == false
					and type(result.stdout) == "string" and #result.stdout <= 8 * 1024 * 1024,
					"Recorded source helper failed or exceeded limits")
				local response = tern.json.decode(result.stdout)
				assert(response.protocol == 1 and response.requestId == request.id, "Recorded source response identity changed")
				local facts = {}
				for _, fact in ipairs(array(response.results, "Recorded source facts")) do
					assert(type(fact) == "table" and type(fact.key) == "string" and facts[fact.key] == nil,
						"Recorded source result identity unavailable")
					facts[fact.key] = fact
				end
				local current = inventory(fresh)
				for _, target in ipairs(targets) do
					local pane, fact = routes[target.key], facts[target.key]
					local native = current.panes[pane]
					if native and currentSource(pane, target, request) then
						assert(fact and fact.path == target.path and type(fact.capturedAtUtc) == "number"
							and fact.capturedAtUtc >= request.capturedAtUtc and fact.capturedAtUtc <= utcNow(),
							"Recorded source result is missing or stale")
					end
					if native and fact and currentSource(pane, target, request)
						and fact.path == target.path and type(fact.capturedAtUtc) == "number"
						and fact.capturedAtUtc >= request.capturedAtUtc and fact.capturedAtUtc <= utcNow() then
						local member = tostring(native.host) .. ":" .. tostring(native.session) .. ":" .. tostring(native.tab)
						if member == request.membership[pane] then
							assert(fact.status == "ready" or fact.status == "partial" or fact.status == "missing"
								or fact.status == "unsupported" or fact.status == "malformed" or fact.status == "unchanged",
								"Unsupported recorded source status")
							if fact.status == "ready" or fact.status == "partial" then
								assert(type(fact.sessionId) == "string" and fact.sessionId ~= ""
									and type(fact.revision) == "string" and type(fact.complete) == "boolean"
									and type(fact.coverage) == "table" and type(fact.writerVersions) == "table"
									and type(fact.schemaVersion) == "number", "Recorded source qualification unavailable")
								if fact.selection ~= "disk-replayed" then
									assert(fact.status == "partial" and fact.selection == "unknown" and not fact.complete
										and fact.reusable == false and fact.questions == nil and fact.lastHuman == nil
										and fact.lastAssistant == nil and fact.lastFinal == nil and fact.lastTerminal == nil
										and fact.lastInteractionAtUtc == nil, "Unqualified history must remain metadata-only")
								end
							elseif fact.status == "unchanged" then
								assert(target.previousRevision ~= nil and fact.revision == target.previousRevision,
									"Recorded source continuity changed")
							end
							sourceObservations[target.key] = fact
							sourceHeaders[target.key] = nil
							if fact.status ~= "unchanged" then
								if fact.status == "ready" or (fact.status == "partial" and fact.selection == "disk-replayed") then
									sourceFacts[target.key] = fact
								end
							end
							sourceDirty[pane], sourcePollPending[pane] = nil, nil
							counters.stage(pane, "sourceAt")
						end
					end
				end
			end)
			if not accepted then failed(problem); return end
			sourceRequest, sourceRetryAt, sourceRetryDelay = nil, 0, 0
			sourceFailure = nil
			schedule(32)
		end)
	end)
	if not launched then failed(failure) end
end


-- A Tern daemon restart restores canvas panes blank: the session still reports a tern.canvas plugin pane,
-- but its owner, marker and content are gone host-side, so cx.canvas:set can never repaint it. The window's
-- canvas list and lookup read one replica, so their joint absence cannot distinguish that remnant from
-- delayed replication. Only a host-side capture of an empty owner, empty marker and no body proves blank.
local function canvasCandidate(data, rail, pane)
	local native, host = data.allPanes[pane], data.hosts[rail.host]
	return native ~= nil and host ~= nil and host.connected and native.host == rail.host and native.tab == rail.tab
		and not native.parked and native.kind == "plugin" and native.block == "tern.canvas"
		and data.canvasMetadata[pane] == nil and not closedPanes[pane]
end

local function without(list, pane)
	if not list then return nil end
	local kept = {}
	for _, value in ipairs(list) do if value ~= pane then table.insert(kept, value) end end
	return if #kept > 0 then kept else nil
end

local function selectedTab(data)
	local focused = data.focused and data.allPanes[data.focused]
	if focused and focused.tab and focused.host == data.currentHost then return focused.host, focused.tab end
	return nil, nil
end

-- blank: empty owner and marker with nothing after the header line; owned: Attention's own canvas whose
-- window metadata has not replicated; content: anything else. Every other outcome is unknown, never blank.
local function captureState(result)
	if type(result) ~= "table" or result.status ~= 0 or result.timed_out ~= false or type(result.stdout) ~= "string"
		or #result.stdout > CAPTURE_LIMIT then return "unknown" end
	local newline = string.find(result.stdout, "\n", 1, true)
	if not newline then return "unknown" end
	local decoded, header = pcall(tern.json.decode, string.sub(result.stdout, 1, newline - 1))
	if not decoded or type(header) ~= "table" or header.v ~= 1 or type(header.owner) ~= "string"
		or type(header.about) ~= "string" then return "unknown" end
	if header.owner == "attention" then return "owned" end
	if header.owner ~= "" or header.about ~= "" or newline ~= #result.stdout then return "content" end
	return "blank"
end

-- One bounded host-side capture of a metadata-less canvas pane in the rail's own selected tab. The result
-- applies only while owner, window, epoch, the rail's recorded pane and the pane's tab are unchanged.
local function probeCanvas(cx, rail, pane, recorded)
	-- A callback lost to a hard budget interruption frees the slot only after the process deadline has passed.
	if remnantProbe and tern.now() < remnantProbe.deadline then return end
	if remnantProbe then
		local stale = remnantProbe
		remnantProbe = nil
		remnantEvidence[stale.pane] = { host = stale.host, tab = stale.tab, state = "unknown", failures = stale.failures + 1,
			retryAt = tern.now() + REMNANT_RETRY_MS * (stale.failures + 1) }
	end
	local prior = remnantEvidence[pane]
	if prior and (prior.state ~= "unknown" or prior.failures >= REMNANT_ATTEMPTS or tern.now() < prior.retryAt) then return end
	local request = { epoch = epoch, window = cx:window_key(), pane = pane, host = rail.host, tab = rail.tab, rail = rail,
		key = instanceKey(rail.key, rail.tab), recorded = recorded, failures = if prior then prior.failures else 0,
		deadline = tern.now() + 5000 }
	remnantProbe = request
	local function settle(state)
		if remnantProbe ~= request or epoch ~= request.epoch then return end
		remnantProbe = nil
		local failures = if state == "unknown" then request.failures + 1 else 0
		remnantEvidence[pane] = { host = request.host, tab = request.tab, state = state, failures = failures,
			retryAt = tern.now() + REMNANT_RETRY_MS * failures }
		schedule(32)
	end
	local function completed(result, fresh)
		if remnantProbe ~= request or epoch ~= request.epoch then return end
		local ok, state = pcall(function()
			assert(fresh and fresh:window_key() == request.window, "Canvas capture returned to another window")
			assert(syncOwnership(fresh) and epoch == request.epoch, "Attention ownership changed during canvas capture")
			local current = request.rail
			assert(rails[request.key] == current and current.host == request.host and current.tab == request.tab
				and (if request.recorded then current.pane == pane or table.find(current.saved.remnants or {}, pane) ~= nil
					else current.pane == nil), "Attention instance changed during canvas capture")
			local native = fresh.session:pane(pane)
			assert(type(native) == "table" and native.pane == pane and optionalId(native.tab) == request.tab
				and not flag(native.parked) and native.kind == "plugin" and native.block == "tern.canvas",
				"Canvas moved during capture")
			return captureState(result)
		end)
		settle(if ok then state else "unknown")
	end
	local resolved, executable = pcall(resolveTernExecutable)
	if not resolved or executable == nil then settle("unknown"); return end
	local launched = pcall(tern.process.run, { executable, "capture", "--window", request.window,
		string.format("%.0f", pane), "--surfaces" }, { timeout_ms = 3000 }, completed)
	if not launched then settle("unknown") end
end

-- Returns the pane's capture verdict and whether unknown attempts are exhausted; probes only in the
-- selected tab, so startup never fans captures out across every restored tab.
local function confirmation(cx, data, rail, pane, recorded)
	local evidence = remnantEvidence[pane]
	if not evidence or evidence.state == "unknown" then
		local host, tab = selectedTab(data)
		if host == rail.host and tab == rail.tab then probeCanvas(cx, rail, pane, recorded) end
		evidence = remnantEvidence[pane]
	end
	if evidence and evidence.state ~= "unknown" then return evidence.state, false end
	return "unknown", evidence ~= nil and evidence.failures >= REMNANT_ATTEMPTS
end

-- Closes each recorded remnant only after the replacement is an accepted owned canvas and the remnant is
-- still a capture-confirmed blank pane in this tab; anything changed or unconfirmable is left in place.
local function settleRemnants(cx, rail, data)
	local remnants = rail.saved.remnants
	if not remnants then return end
	local kept, changed = {}, false
	local replaced = rail.pane ~= nil and data.canvases[rail.pane] ~= nil
	for _, pane in ipairs(remnants) do
		if data.allPanes[pane] == nil then
			changed = true
		elseif remnantCloses[pane] or closedPanes[pane] then
			table.insert(kept, pane)
		elseif not canvasCandidate(data, rail, pane) then
			changed, rail.status = true, "Restored blank canvas changed · left in place"
		elseif not replaced then
			table.insert(kept, pane)
		else
			local state, exhausted = confirmation(cx, data, rail, pane, true)
			if state == "blank" then
				requireOwner(cx)
				local closed, failure = pcall(function() cx.layout:close(pane) end)
				placement.changed()
				if closed then
					counters.layoutWrites += 1
					remnantCloses[pane] = true
					table.insert(kept, pane)
				else
					changed, rail.status = true, "Could not close restored blank canvas · left in place"
					report(cx, rail.status .. ": " .. tostring(failure), false)
				end
			elseif state == "unknown" and not exhausted then
				table.insert(kept, pane)
				rail.status = "Confirming restored blank canvas before closing it"
			else
				changed = true
				rail.status = if state == "unknown" then "Restored canvas could not be confirmed blank · left in place"
					else "Restored canvas is not blank · left in place"
			end
		end
	end
	if changed then
		rail.saved.remnants = if #kept > 0 then kept else nil
		saveInstance(cx, rail)
	end
end
local function adoptManualMoves(cx, data)
	local moves = {}
	-- A manual move replaces saved records outright, so any batched observation of those entries is stale.
	local function supersede(key, tab)
		if not instanceBatch then return end
		for index = #instanceBatch, 1, -1 do
			local op = instanceBatch[index]
			if op.key == key and op.tab == tab then table.remove(instanceBatch, index) end
		end
	end
	for key, rail in pairs(rails) do
		local native = rail.pane and data.allPanes[rail.pane]
		if native and native.tab and native.tab ~= rail.tab
			and native.host == rail.host and data.tabs[native.tab] and not closedTabs[native.tab] and not native.parked then
			table.insert(moves, { key = key, rail = rail, tab = data.tabs[native.tab] })
		end
	end
	for _, move in ipairs(moves) do
		local rail, tab = move.rail, move.tab
		if rails[move.key] == rail then
			local destinationKey = instanceKey(rail.key, tab.id)
			local displaced = rails[destinationKey]
			if displaced and displaced.pane then
				local native = data.allPanes[displaced.pane]
				assert(native and data.canvases[displaced.pane] and native.host == rail.host
					and (native.parked or native.tab == tab.id), "Destination Attention membership is unconfirmed")
				if not native.parked then
					ownedCanvas(cx, displaced.pane)
					local parked, reason = cx.layout:park(displaced.pane)
					placement.changed()
					assert(parked, reason or "Could not preserve displaced Attention")
					counters.layoutWrites += 1
				end
			end
			local prefs = preferences()
			local sourceSaved = { tab = rail.tab, session = rail.session, userHidden = true,
				position = rail.saved.position,
				pane = displaced and displaced.pane, retiring = rail.saved.retiring, remnants = rail.saved.remnants }
			local source = displaced or newRail(data.hosts[rail.host], { id = rail.tab, session = rail.session }, prefs)
			source.tab, source.session, source.saved, source.pane = rail.tab, rail.session, sourceSaved, sourceSaved.pane
			source.phase, source.status, source.layout, source.pending = "ready", "Moved out · hidden in this tab", layout.new(), false
			rail.tab, rail.session = tab.id, tab.session
			rail.saved = { tab = tab.id, session = tab.session, pane = rail.pane, userHidden = false,
				position = rail.saved.position }
			rail.layout, rail.status, rail.phase, rail.error, rail.pending = layout.new(), "Manually moved · adopted in place", "ready", nil, false
			rails[move.key], rails[destinationKey] = source, rail
			prefs.instances[rail.key] = prefs.instances[rail.key] or {}
			prefs.instances[rail.key][tostring(source.tab)] = source.saved
			prefs.instances[rail.key][tostring(rail.tab)] = rail.saved
			-- The move's immediate compound write supersedes any batched observation of these two entries.
			supersede(rail.key, source.tab)
			supersede(rail.key, rail.tab)
			savePreferences(cx, prefs)
		end
	end
end


local function discover(cx, data, prefs)
	owned = {}
	for pane in pairs(data.canvases) do owned[pane] = true end
	-- Any fresh membership, parking or metadata mismatch invalidates earlier capture evidence.
	for pane, evidence in pairs(remnantEvidence) do
		local native = data.allPanes[pane]
		if not native or native.host ~= evidence.host or native.tab ~= evidence.tab or native.parked
			or data.canvasMetadata[pane] or closedPanes[pane] then remnantEvidence[pane] = nil end
	end
	for hostKey, entries in pairs(prefs.instances) do
		for _, saved in pairs(entries) do
			local host = nil
			for _, candidate in pairs(data.hosts) do if candidate.key == hostKey then host = candidate; break end end
			if host then ensureRail(data, prefs, host, { id = saved.tab, session = saved.session }) end
		end
	end
	for pane, metadata in pairs(data.canvases) do
		local native = data.allPanes[pane]
		local host = native and data.hosts[native.host]
		-- Canvases belong to the host's shared session, not this window. Never publish the
		-- private cross-host workspace there; remove old remote rails, including parked ones.
		if host and host.key ~= "local" then
			ownedCanvas(cx, pane)
			cx.layout:close(pane)
			placement.changed()
			counters.layoutWrites += 1
			for _, rail in pairs(rails) do
				if rail.pane == pane then
					rail.saved.closeAccepted = true
					saveInstance(cx, rail)
				end
			end
			continue
		end
		local assigned = false
		for _, rail in pairs(rails) do if rail.pane == pane then assigned = true; break end end
		if host and not assigned and not closedPanes[pane] then
			local session, tabId = markerIdentity(metadata.about)
			if not session then tabId = native.tab end
			local tab = tabId and data.tabs[tabId]
			local retiring = session and tabId and rails[instanceKey(host.key, tabId)]
			if retiring and retiring.saved.retiring and retiring.session == session and retiring.pane == nil then
				retiring.pane, retiring.saved.pane, retiring.pending = pane, pane, false
				saveInstance(cx, retiring)
				continue
			end
			if tab and not closedTabs[tab.id] and (session == nil or session == tab.session)
				and data.sessions[tab.session].host == host.id then
				local rail = ensureRail(data, prefs, host, tab)
				if rail.pane == nil and not rail.saved.userHidden then
					local recovering = rail.saved.placement ~= nil or rail.saved.creating == true
					rail.pane, rail.saved.pane, rail.pending = pane, pane, false
					rail.saved.remnants = without(rail.saved.remnants, pane)
					rail.phase = if rail.saved.placement and rail.saved.placement.status == "failed" then "failed"
						elseif recovering and native.tab == rail.tab and not native.parked and not native.floating then "placing" else "ready"
					rail.status = "Adopted in place"
					saveInstance(cx, rail)
				end
			end
		end
	end
	adoptManualMoves(cx, data)
	local adopted = {}
	for key, rail in pairs(rails) do
		local host, tab = data.hosts[rail.host], data.tabs[rail.tab]
		local native = rail.pane and data.allPanes[rail.pane]
		-- Runtime only: a pane counts as functioning Attention once this VM opened it or saw it as an owned canvas.
		if rail.pane and data.canvases[rail.pane] then rail.livePane = rail.pane end
		-- A closed tab or pane can miss its native event; only sustained absence on a connected
		-- host proves it closed, because replica metadata can lag by seconds.
		if host and host.connected and tab == nil and native == nil then
			rail.absentPasses += 1
			if rail.absentSince == nil then rail.absentSince = tern.now() end
		else
			rail.absentPasses, rail.absentSince = 0, nil
		end
		if (host and host.key ~= "local") or rail.saved.retiring or closedTabs[rail.tab] or (tab and tab.session ~= rail.session)
			or (rail.absentPasses >= 3 and host and host.connected) then
			if rail.pane and data.allPanes[rail.pane] == nil and rail.absentPasses >= 3
				and rail.absentSince and tern.now() - rail.absentSince >= 30000 then
				closedPanes[rail.pane] = true
			end
			if not rail.saved.retiring then rail.saved.retiring = true; saveInstance(cx, rail) end
			if host and host.connected then
				if retire(cx, rail, data) then
					removeInstance(cx, rail)
					rails[key] = nil
				end
			else
				rail.phase, rail.status = "closing", "Waiting for host to retire closed tab Attention"
			end
		elseif rail.pane and closedPanes[rail.pane] then
			local live = rail.livePane == rail.pane
			rail.pane, rail.saved.pane, rail.saved.creating, rail.pending, rail.livePane = nil, nil, nil, false, nil
			rail.saved.placement = nil
			rail.view = freshView(key)
			if live then
				rail.saved.userHidden, rail.phase, rail.status = true, "hidden", "Hidden in this tab · use Open Attention"
			else
				-- A restored leftover that never rendered Attention in this VM: closing it is not hiding Attention.
				rail.layout, rail.generation, rail.error = layout.new(), nil, nil
				rail.firstMissing, rail.discoveries = tern.now(), 0
				rail.phase = if rail.saved.userHidden then "hidden" else "unmounted"
				rail.status = if rail.saved.userHidden then "Hidden in this tab · use Open Attention"
					else "Restored canvas closed · replacing in this tab"
			end
			saveInstance(cx, rail)
		elseif native and data.canvases[rail.pane] then
			rail.pending = false
			local position, physical = nil, nil
			if rail.saved.position == nil then position, physical = placement.adopt(cx, rail, native, prefs) end
			if position then
				table.insert(adopted, { rail = rail, position = position, share = physical })
				-- Adopted means found where it is: an interrupted creation or placement is dropped, not finished, so the
				-- host's width never resizes a rail nobody asked to move.
				if rail.phase == "placing" then rail.phase = "ready" end
			end
			-- Accepted and owned: from here a later restart can blank it like any other recorded canvas.
			if rail.saved.creating then rail.saved.creating = nil; saveInstance(cx, rail) end
			if native.tab and native.tab ~= rail.tab then
				rail.phase, rail.status = "ready", "Manually moved · placement left unchanged"
			elseif native.parked or native.floating then
				if rail.phase ~= "recovering" then rail.phase = "ready" end
				rail.status = if native.parked then "Manually parked · use Open Attention" else "Floating Attention"
			end
			if rail.phase == "ready" and (rail.saved.creating or rail.saved.placement) then
				rail.saved.creating, rail.saved.placement = nil, nil
				saveInstance(cx, rail)
			end
			if rail.phase == "ready" and native.tab == rail.tab and not native.parked and not native.floating then
				observeShare(cx, rail)
			end
		elseif rail.pane and native and not rail.saved.creating and canvasCandidate(data, rail, rail.pane) then
			-- An accepted creation still awaiting metadata is never a remnant; only a recorded, settled pane is.
			local state, exhausted = confirmation(cx, data, rail, rail.pane, true)
			local remnants = rail.saved.remnants or {}
			if state == "blank" and rail.saved.userHidden then
				rail.status = "Restored blank canvas left in place · hidden in this tab"
			elseif state == "blank" and #remnants >= MAX_REMNANTS then
				rail.status = "Restored blank canvas left in place · earlier restored canvases are still open"
			elseif state == "blank" then
				table.insert(remnants, rail.pane)
				rail.saved.remnants = remnants
				rail.pane, rail.saved.pane, rail.saved.creating, rail.saved.placement, rail.pending = nil, nil, nil, nil, false
				rail.layout, rail.generation, rail.error = layout.new(), nil, nil
				rail.phase, rail.status = "unmounted", "Restored blank canvas · replacing in this tab"
				rail.firstMissing, rail.discoveries = tern.now(), 0
				rail.view = freshView(key)
				saveInstance(cx, rail)
			elseif state == "owned" then
				rail.status = "Canvas metadata replicating · identity retained"
			elseif state == "content" then
				rail.status = "Canvas metadata unavailable and canvas is not blank · left in place"
			elseif exhausted then
				rail.status = "Restored canvas state unconfirmed · left in place; use Open Attention to retry"
			else
				rail.status = "Canvas metadata unavailable · confirming restored state when this tab is selected"
			end
		elseif rail.pane or rail.saved.creating then
			rail.status = "Native pane unavailable · identity retained; waiting for metadata"
		end
		if rails[key] == rail and not rail.saved.retiring then settleRemnants(cx, rail, data) end
	end
	if #adopted > 0 then
		local fresh, changed = preferences(), false
		for _, adoption in ipairs(adopted) do
			local rail = adoption.rail
			if rails[instanceKey(rail.key, rail.tab)] == rail and not rail.saved.retiring then
				fresh.instances[rail.key] = fresh.instances[rail.key] or {}
				fresh.instances[rail.key][tostring(rail.tab)] = rail.saved
				-- One width per host and position: the first adopted width is recorded, and a stored width is never replaced.
				local sizes = fresh.defaults.shares[adoption.position]
				if adoption.share and sizes[rail.key] == nil then sizes[rail.key] = adoption.share end
				changed = true
			end
		end
		if changed then savePreferences(cx, fresh) end
	end
	for _, rail in pairs(rails) do
		for _, pane in ipairs(rail.saved.remnants or {}) do owned[pane] = true end
	end
	for pane in pairs(remnantCloses) do if data.allPanes[pane] == nil then remnantCloses[pane] = nil end end
	for pane in pairs(closedPanes) do if data.allPanes[pane] == nil then closedPanes[pane] = nil end end
	for tab in pairs(closedTabs) do
		local pending = false
		for _, rail in pairs(rails) do if rail.tab == tab then pending = true; break end end
		if data.tabs[tab] == nil and not pending then closedTabs[tab] = nil end
	end
end

local function selectedContent(cx, data)
	local focused = data.focused and data.allPanes[data.focused]
	if not focused or not focused.tab or focused.host ~= data.currentHost then return nil end
	local arrangement = cx.session:layout(focused.tab)
	if type(arrangement) ~= "table" then return nil end
	local target = if not owned[focused.pane] and treeHas(arrangement.root, focused.pane) then focused.pane
		else treeLeaf(arrangement.root, owned)
	local host = data.hosts[focused.host]
	-- The one visit-eligibility predicate (placement, discovery and the all-tabs consume): a mounted, unzoomed, nonfloating
	-- tab on the local host. Remote canvases are shared with that host's other clients.
	return { host = focused.host, tab = focused.tab, target = target, arrangement = arrangement,
		eligible = host ~= nil and host.key == "local" and host.connected and not focused.floating and not focused.parked and not arrangement.zoomed }
end

local function prepareLayout(cx, rail)
	local arrangement = cx.session:layout(rail.tab)
	assert(arrangement and not arrangement.zoomed, "Tab is unavailable or zoomed; placement deferred")
	local floats = {}
	for _, floating in ipairs(arrangement.floats) do
		if floating.pane ~= rail.pane and not table.find(rail.saved.remnants or {}, floating.pane) then
			table.insert(floats, floating)
		end
	end
	local root = layout.strip(arrangement.root, rail.pane)
	for _, remnant in ipairs(rail.saved.remnants or {}) do root = layout.strip(root, remnant) end
	rail.layout = layout.new({ tab = rail.tab, root = root, floats = floats })
	generation += 1
	rail.generation = generation
end

local function createRail(cx, rail, data, selected, prefs)
	rail.discoveries += 1
	-- The restore grace waits out canvases a restarted window is still replicating; a tab this window saw created has none.
	local created = placement.createdTabs[rail.tab] == true
	if rail.pending or rail.saved.creating
		or (not created and (tern.now() - rail.firstMissing < 2000 or rail.discoveries < 2)) then return end
	-- A metadata-less canvas here may be this tab's own accepted canvas awaiting replication; only a
	-- host-side capture showing it blank or someone else's content lets creation proceed.
	for pane in pairs(data.allPanes) do
		if canvasCandidate(data, rail, pane) then
			local state, exhausted = confirmation(cx, data, rail, pane, false)
			if state ~= "blank" and state ~= "content" then
				rail.status = if state == "owned" then "Waiting for canvas ownership metadata"
					elseif exhausted then "Canvas state unconfirmed · use Open Attention to retry"
					else "Confirming canvas state before creation"
				return
			end
		end
	end
	local current = cx.hosts:current()
	assert(current and current.kind == "local" and current.id == rail.host and current.state == "connected",
		"Attention stays on the local host; remote canvases are shared")
	assert(cx.session:tab_of(cx.session:focused()) == rail.tab, "Tab selection changed")
	if rail.saved.position == nil then rail.saved.position = prefs.defaults.position end
	prepareLayout(cx, rail)
	-- A tab marked by an all-tabs action that had no rail yet opens one straight at the marked position.
	if rail.saved.moveTo then rail.saved.position, rail.saved.moveTo = rail.saved.moveTo, nil end
	rail.view = freshView(instanceKey(rail.key, rail.tab))
	local options = viewOptions(prefs, rail, data)
	local initial = view.render(rail.view, logical, projection, options)
	rail.pending, rail.saved.creating = true, true
	local persisted, persistenceError = pcall(savePlacement, cx, rail, "placing")
	if not persisted then
		rail.pending, rail.saved.creating, rail.phase = false, nil, "failed"
		rail.error, rail.status = tostring(persistenceError), "Cannot save placement before canvas creation"
		cx:toast("error", "Attention", rail.status .. ": " .. rail.error)
		return
	end
	local sessionId: number, tabId: number = rail.session, rail.tab
	local position = rail.saved.position
	local share = placement.shareFor(rail, position)
	local spec = { title = "Attention", about = string.format("attention:tab:v1:%.0f:%.0f", sessionId, tabId),
		view = initial.view, focus = false }
	if position == "left" then
		spec.target, spec.dir, spec.ratio = treeLeaf(selected.arrangement.root, owned) or selected.target, "left", share
	else
		spec.how = "beside"
	end
	local ok, pane, reason = pcall(function()
		requireOwner(cx)
		return cx.canvas:open(spec)
	end)
	placement.changed()
	if not ok then
		rail.phase, rail.status = "unknown", "Creation outcome unknown · waiting for native metadata"
		rail.error = "Creation outcome unknown: " .. tostring(pane)
		cx:toast("error", "Attention", rail.error .. " · waiting for metadata; no duplicate will be opened")
		return
	elseif not id(pane) then
		rail.pending, rail.saved.creating, rail.phase = false, nil, "failed"
		rail.error = reason or "Native canvas creation rejected"
		rail.status = if rail.saved.remnants then rail.error .. " · restored blank canvas left in place" else rail.error
		cx:toast("error", "Attention", rail.error)
		savePlacement(cx, rail, "failed")
		return
	end
	counters.canvasWrites += 1
	rail.publishedBindings = table.clone(rail.view.bindings)
	rail.publishedLogicalRevision = logical.revision
	rail.pane, rail.saved.pane, rail.livePane = pane, pane, pane
	rail.phase, rail.status = "placing", "Waiting for created canvas replica"
	placement.createdTabs[rail.tab] = nil
	savePlacement(cx, rail, "placing")
	owned[pane] = true
	schedule(placement.PASS_MS)
end

local function placeRail(cx, rail, data, selected)
	local native = rail.pane and data.allPanes[rail.pane]
	if not native or not data.canvases[rail.pane] then return end
	for _, remnant in ipairs(rail.saved.remnants or {}) do
		if data.allPanes[remnant] then
			rail.status = "Waiting for restored blank canvas closure"
			return
		end
	end
	if native.host ~= rail.host or (native.tab and native.tab ~= rail.tab) then
		rail.phase, rail.error = "failed", "Attention was manually moved; placement stopped"
		savePlacement(cx, rail, "failed")
		return
	end
	-- discover() adopts a position for every observed rail before it can be placed; without one, wait.
	local position = rail.saved.position
	if position == nil then return end
	local edge = placement.edges[position]
	local arrangement = cx.session:layout(rail.tab)
	if not arrangement or arrangement.zoomed then return end
	local target = treeLeaf(arrangement.root, owned)
	if not target then return end
	if native.parked or native.floating then
		if rail.phase ~= "recovering" then rail.phase = "ready"; return end
		if native.parked and (not selected or selected.tab ~= rail.tab or not selected.eligible) then return end
		local guarded = guardedLayout(cx, rail)
		local ok, reason
		if native.parked then ok, reason = guarded.layout:unpark(rail.pane, { focus = false })
		else ok, reason = guarded.layout:dock(rail.pane, target, edge, { focus = false }) end
		if not ok then
			rail.phase, rail.error = "failed", reason or "Could not restore Attention"
			savePlacement(cx, rail, "failed")
			return
		end
		rail.phase = "placing"
		schedule(placement.PASS_MS)
		return
	end
	local outcome = layout.reconcile(rail.layout, guardedLayout(cx, rail), {
		pane = rail.pane, target = target, tab = rail.tab, edge = edge,
		share = placement.shareFor(rail, position), now = tern.now(), generation = rail.generation or 0,
	})
	rail.status = outcome.reason or (if outcome.settled then "Ready in this tab" else "Placing in this tab")
	if outcome.settled then
		rail.phase, rail.error = "ready", nil
		rail.saved.creating, rail.saved.placement, rail.divider = nil, nil, nil
		saveInstance(cx, rail)
	elseif not outcome.again then
		rail.phase, rail.error = "failed", outcome.reason or "Placement stopped · use Reset placement"
		rail.saved.creating = nil
		savePlacement(cx, rail, "failed")
	end
	if outcome.again then savePlacement(cx, rail, "placing") end
	if outcome.again then schedule(placement.PASS_MS) end
end

local function maintainInstances(cx, data, prefs)
	local selected = selectedContent(cx, data)
	for _, rail in pairs(rails) do
		local host = data.hosts[rail.host]
		if host and host.key == "local" and host.connected then
			local arrangement = data.tabs[rail.tab] and placement.observe(cx, rail.tab)
			if arrangement and treeLeaf(arrangement.root, owned) == nil then
				-- A cached observation can nominate retirement, never authorize a close.
				arrangement = cx.session:layout(rail.tab)
				if not arrangement or treeLeaf(arrangement.root, owned) ~= nil then continue end
				local hasContent = false
				for _, floating in ipairs(arrangement.floats) do if not owned[floating.pane] then hasContent = true end end
				if not hasContent and rail.phase ~= "retired" then
					retire(cx, rail, data)
					saveInstance(cx, rail)
				end
			end
			if rail.phase == "placing" or rail.phase == "recovering" then
				local ok, failure = pcall(placeRail, cx, rail, data, selected)
				if not ok then
					rail.phase, rail.error, rail.status = "failed", tostring(failure), tostring(failure)
					rail.saved.creating = nil
					savePlacement(cx, rail, "failed")
				end
			end
			if rail.saved.moveTo and not rail.saved.retiring then
				local ok, failure = pcall(placement.consume, cx, rail, data, selected)
				if not ok then
					rail.status = humanize(failure)
					report(cx, failure, false)
				end
			end
		end
	end
	if not selected or not selected.target or not selected.eligible then return end
	local host, tab = data.hosts[selected.host], data.tabs[selected.tab]
	if not tab or closedTabs[selected.tab] then return end
	local rail = ensureRail(data, prefs, host, tab)
	if rail.saved.userHidden or rail.phase ~= "unmounted" then return end
	createRail(cx, rail, data, selected, prefs)
end

-- What a background rail's paint depends on besides the clock: canvases built from equal keys are equal. Where the user
-- is (the current location, the Previous target, the focused-pane part of a tab row) is deliberately not in it: a focus
-- change repaints the active rail only, and a background rail catches up when it becomes active or its own content
-- changes. Any other input (a title, a relative time) reaches it through the slower `REFRESH_MS` re-render.
function catchup.key(options)
	local active = options.navigation
	return table.concat({ logical.revision, projection.revision or 0, projection.status or "", projection.message or "",
		if workspace then workspace.signature else "", options.notice or "", options.position,
		if active then tostring(active.workId) .. "|" .. tostring(active.serial) .. "|" .. tostring(active.pane) .. "|"
			.. tostring(active.phase) .. "|" .. tostring(active.token) else "",
		tostring(options.search.available),
		tostring(options.settings.shortcut) }, "\30")
end

-- Everything `view.render` reads besides its renderer, as one string, or nil when it cannot be encoded (the rail then
-- renders as before). The presentation is copy-on-change, so its revision and status stand for its rows; the workspace is
-- rebuilt every pass, so its rendered tree is encoded (its `byKey`/`byPane` indexes repeat that tree). The clock enters
-- only as a clock bucket, so an age chip advances at most that late: RENDER_CLOCK_S on the rail in view, and
-- HIDDEN_CLOCK_S (ages are minute-granular) on a background rail a viewer may mirror. A pass that would rebuild an
-- identical tree, then diff it to nothing, costs one native encode instead.
local RENDER_CLOCK_S, HIDDEN_CLOCK_S = 10, 60
local function renderInputs(options, clockSeconds)
	local rest = {}
	for key, value in pairs(options) do
		if key ~= "now" and key ~= "nowUtc" and key ~= "workspace" and key ~= "arrival" then rest[key] = value end
	end
	local ws = options.workspace
	local encoded, text = pcall(tern.json.encode, {
		logical = logical, options = rest,
		workspace = if ws then { hosts = ws.hosts, retained = ws.retained, counts = ws.counts, currentPane = ws.currentPane,
			coverage = ws.coverage } else nil,
	})
	if not encoded then return nil end
	return table.concat({ projection.revision or 0, projection.status or "", projection.message or "", projection.count or -1,
		math.floor((options.nowUtc or 0) / clockSeconds), text }, "\30")
end

-- One paint of one rail: renders, writes the change and records what the canvas now shows. Returns whether the native
-- write was accepted, its failure, and the options used. A rejected write leaves the renderer to resend in full.
local function paintRail(cx, data, prefs, rail, arrival, hidden)
	assert(data.hosts[rail.host] and data.hosts[rail.host].key == "local",
		"Attention cannot publish private navigation to a remote host")
	local options = viewOptions(prefs, rail, data)
	options.arrival = arrival
	local inputs = renderInputs(options, if hidden then HIDDEN_CLOCK_S else RENDER_CLOCK_S)
	local renderer = rail.view
	-- Unchanged inputs, a settled previous screen and no arrival starting or running: the render would be a no-op.
	if inputs ~= nil and renderer.inputs == inputs and renderer.previous ~= nil and renderer.initialized
		and not options.arrival and not renderer.arrival then
		rail.painted = { renderer = renderer, key = catchup.key(options), at = tern.now() }
		return true, nil, options
	end
	counters.renders += 1
	renderer.inputs = nil
	local change = view.render(renderer, logical, projection, options)
	if options.arrival and not renderer.arrival then pendingArrival = nil end
	local accepted, failure = true, nil
	if change then
		accepted, failure = pcall(setCanvas, cx, rail.pane, change, data)
		if not accepted then view.invalidate(renderer, true) end
	end
	-- A revision-only change sends no patch, but the renderer now carries the new revision's bindings for the same screen.
	-- Record them either way, or a click on the screen the user sees is refused as stale and nothing responds.
	if accepted then
		rail.publishedBindings = table.clone(renderer.bindings)
		rail.publishedLogicalRevision = logical.revision
		renderer.inputs = inputs
	end
	rail.painted = if accepted then { renderer = renderer, key = catchup.key(options), at = tern.now() } else nil
	return accepted, failure, options
end

-- A mounted, ready rail that a viewer could be mirroring while its tab is not the Mac's active one.
function catchup.ready(rail, data)
	local native = if rail.pane then data.allPanes[rail.pane] else nil
	local host = data.hosts[rail.host]
	return rail.phase == "ready" and not rail.saved.userHidden and not rail.saved.retiring and not closedTabs[rail.tab]
		and data.tabs[rail.tab] ~= nil and native ~= nil and data.canvases[rail.pane] ~= nil and host ~= nil
		and host.key == "local" and host.connected
		and native.tab == rail.tab and not native.parked and not native.floating
end

-- Repaints at most one non-visible rail per pass, in instance-key round-robin order, so a mirror of a tab the Mac is not
-- showing converges instead of freezing on its last frame. A rail lags when its renderer or inputs changed since its
-- last paint; one painted long ago is re-rendered too (a diff, so no write when nothing changed). Returns nothing.
function catchup.run(cx, data, prefs, activeHost, activeTab)
	local now = tern.now()
	if catchup.budgetEventAt ~= nil and now - catchup.budgetEventAt < catchup.PAUSE_MS then return end
	if catchup.passStartedAt ~= nil and now - catchup.passStartedAt >= catchup.PASS_MS then
		schedule(catchup.OVER_BUDGET_RETRY_MS)
		return
	end
	local pending = {}
	for key, rail in pairs(rails) do
		if not railVisible(rail, data, activeHost, activeTab) and catchup.ready(rail, data) then
			table.insert(pending, { key = key, rail = rail })
		end
	end
	local total = #pending
	if total == 0 then return end
	table.sort(pending, function(a, b) return a.key < b.key end)
	local start = 1
	for index, entry in ipairs(pending) do
		if entry.key > catchup.after then start = index; break end
	end
	local chosen, aged, waiting = nil, nil, 0
	for offset = 0, total - 1 do
		local entry = pending[(start + offset - 1) % total + 1]
		local rail = entry.rail
		local painted = rail.painted
		local backedOff = rail.catchupRetryAt ~= nil and now < rail.catchupRetryAt
		if not backedOff then
			local options = viewOptions(prefs, rail, data)
			if painted == nil or painted.renderer ~= rail.view or not rail.view.initialized
				or painted.key ~= catchup.key(options) then
				if chosen == nil then chosen = entry else waiting += 1 end
			elseif aged == nil and now - painted.at >= catchup.REFRESH_MS then
				aged = entry
			end
		end
	end
	chosen = chosen or aged
	if chosen == nil then return end
	if tern.now() - now >= catchup.PASS_MS then
		schedule(catchup.OVER_BUDGET_RETRY_MS)
		return
	end
	local rail = chosen.rail
	catchup.after = chosen.key
	local writeFailed = canvasWriteFailed
	local ran, accepted, failure = pcall(paintRail, cx, data, prefs, rail, false, true)
	if not ran then
		failure, accepted = accepted, false
		view.invalidate(rail.view, true)
		rail.painted = nil
	end
	if accepted then
		rail.catchupFailures, rail.catchupRetryAt = nil, nil
	else
		-- A background rail is not the user's rail: its failure never touches the shared notice, the toast, or the
		-- pass health. It is logged once per streak and retried on a growing delay.
		canvasWriteFailed = writeFailed
		rail.catchupFailures = (rail.catchupFailures or 0) + 1
		rail.catchupRetryAt = now + math.min(catchup.BACKOFF_MS * 2 ^ (rail.catchupFailures - 1), catchup.BACKOFF_MAX_MS)
		if rail.catchupFailures == 1 then
			counters.errors += 1
			tern.log.warn("Attention:", "Background rail update failed: " .. string.sub(tostring(failure), 1, 512))
		end
	end
	if waiting > 0 then catchup.followUp(data, prefs) end
end

-- The next lagging background rail is painted from the same pass data, not by a full pass: one visible change can stale
-- every hidden rail, and a full pass per rail (inventory, reconcile, render) ran a dozen of them back to back on the UI
-- thread. The timer always paints from the latest pass's data; a pass running when it fires does its own catch-up.
function catchup.followUp(data, prefs)
	catchup.pending = { data = data, prefs = prefs }
	if catchup.timer then return end
	catchup.timer = tern.timer(32, function(cx)
		local pending = catchup.pending
		catchup.timer, catchup.pending = nil, nil
		if busy or pending == nil or snapshot ~= pending.data then return end
		local ok, failure = pcall(function()
			if not isOwner(cx) then return end
			local focused = cx.session:focused()
			catchup.run(cx, pending.data, pending.prefs, cx.hosts:current(), if focused then cx.session:tab_of(focused) else nil)
		end)
		if not ok then report(cx, failure, false) end
	end)
end

local function render(cx, data, prefs)
	reserveArrival(cx, data, false)
	local focused = cx.session:focused()
	local activeTab = if focused then cx.session:tab_of(focused) else nil
	local activeHost = cx.hosts:current()
	local now = tern.now()
	local activeArrival, healthy = nil, true
	for _, rail in pairs(rails) do
		if railVisible(rail, data, activeHost, activeTab) then
			local accepted, failure, options = paintRail(cx, data, prefs, rail,
				pendingArrival ~= nil and pendingArrival.view == rail.view)
			if not accepted then
				report(cx, failure, false)
				healthy = false
			end
			if accepted and options.arrival and rail.view.arrival then
				arrivalQuietUntil = now + 3000
				pendingArrival = nil
			end
			activeArrival = rail.view.arrival or activeArrival
		else
			rail.view.arrival = nil
		end
	end
	if not activeArrival then
		if arrivalRetirement then arrivalRetirement:cancel(); arrivalRetirement = nil end
	elseif not arrivalRetirement then
		arrivalRetirement = tern.timer(math.max(0, activeArrival.untilTime - tern.now()), function(fresh)
			arrivalRetirement = nil
			runPass(fresh)
		end)
	end
	catchup.run(cx, data, prefs, activeHost, activeTab)
	return healthy
end

local function currentRow(pane, serial)
	for _, row in ipairs(model.current(store).rows) do
		if row.pane == pane and row.serial == serial then return row end
	end
	return nil
end

local function workRow(workId)
	for _, row in ipairs(model.current(store).rows) do
		if row.workId == workId then return row end
	end
	return nil
end

local function rowVersion(row)
	return table.concat({ row.workId, tostring(row.serial), tostring(row.identityKey), tostring(row.sourceSessionId), tostring(row.pane),
		tostring(row.attentionRevision), tostring(row.reviewRevision), row.disposition, tostring(row.priority) }, "|")
end

local function intentVersion(row)
	return table.concat({ row.workId, tostring(row.serial), tostring(row.identityKey), tostring(row.pane),
		tostring(row.attentionRevision), tostring(row.reviewRevision), row.disposition, tostring(row.priority) }, "|")
end

local function captureOrigin(cx, rail, row)
	return { epoch = epoch, window = cx:window_key(), renderer = rail.view, rail = rail,
		pane = rail.pane, tab = rail.tab, session = rail.session, host = rail.host, hostKey = rail.key,
		intentRevision = logical.intentRevision,
		workId = row and row.workId, rowVersion = row and rowVersion(row),
		sourceSessionId = row and row.sourceSessionId, intentVersion = row and intentVersion(row),
		locatorPath = if row and row.pane and sourceLocators[row.pane] then sourceLocators[row.pane].path else nil,
		targetMember = if row and row.pane then identityMembership[row.pane] else nil }
end
navigationLive = function(navigation, cx)
	if not navigation or navigation.cancelled or tern.now() >= navigation.deadline then return false end
	local origin = navigation.binding.origin
	local valid = navigation.epoch == epoch and navigation.intentRevision == logical.intentRevision
	local row = currentRow(navigation.binding.pane, navigation.binding.serial)
	local locator = sourceLocators[navigation.binding.pane]
	valid = valid and row ~= nil and row.workId == navigation.workId and row.identityKey == navigation.identityKey
		and (navigation.sourceSessionId == nil or row.sourceSessionId == navigation.sourceSessionId)
		and identityMembership[navigation.binding.pane] == navigation.targetMember
		and (navigation.locatorPath == nil or locator and locator.path == navigation.locatorPath
			and sourceLocatorEpochs[navigation.binding.pane] == navigation.locatorEpoch)
	if valid and cx and pendingNavigation == navigation then
		local focused = cx.session:focused()
		if snapshot and snapshot.panes[focused] and owned[focused] == nil and focused ~= navigation.focused then valid = false end
	end
	if valid and origin then
		local rail = origin.rail
		valid = rail.view == origin.renderer and rail.pane == origin.pane and rail.tab == origin.tab
			and rail.session == origin.session and rail.host == origin.host
			and rails[instanceKey(origin.hostKey, origin.tab)] == rail
	end
	return valid
end

function intents.endNavigation(navigation, cx, message)
	if not navigation then return end
	local current = pendingNavigation == navigation or pendingVisit and pendingVisit.navigation == navigation
	navigation.cancelled = true
	if not current then return end
	pendingNavigation, pendingVisit = nil, nil
	if intents.interactive.timer then intents.interactive.timer:cancel(); intents.interactive.timer = nil end
	if message then report(cx, message, false) end
	schedule(32)
end

function intents.expireNavigation(cx)
	local navigation = if pendingVisit then pendingVisit.navigation else pendingNavigation
	if navigation and tern.now() >= navigation.deadline then
		intents.endNavigation(navigation, cx, "Opening expired · try again")
	end
end

pruneNavigationJobs = function()
	for laneIndex = 1, 2 do
		local queue = if laneIndex == 1 then helperActions else intents.interactive.queue
		for index = #queue, 1, -1 do
			local job = queue[index]
			if job.navigation and not job.live() then table.remove(queue, index) end
		end
	end
end

local function repeatedNavigation(origin, command)
	local navigation = if pendingVisit then pendingVisit.navigation else pendingNavigation
	if not navigation or not navigationLive(navigation) then return false end
	local accepted = navigation.binding.origin
	return if origin then accepted == origin or accepted ~= nil and origin.action ~= nil
		and accepted.renderer == origin.renderer and accepted.rail == origin.rail
		and accepted.pane == origin.pane and accepted.action == origin.action
		else accepted == nil and navigation.binding.command == command
end

local function validateOrigin(cx, origin, data, navigation)
	assert(syncOwnership(cx) and origin.epoch == epoch and cx:window_key() == origin.window,
		"Attention owner changed; choose the current action")
	local rail = origin.rail
	assert(rail.view == origin.renderer and rail.pane == origin.pane and rail.tab == origin.tab
		and rails[instanceKey(origin.hostKey, origin.tab)] == rail
		and logical.intentRevision == origin.intentRevision,
		"Attention selection changed; choose the current action")
	data = data or refresh(cx, navigation)
	assert(data, "Native attention inventory unavailable")
	local native, host = data.allPanes[origin.pane], data.hosts[origin.host]
	assert(native and data.canvases[origin.pane] and native.tab == origin.tab and native.session == origin.session
		and native.host == origin.host and host and host.connected and host.key == origin.hostKey,
		"Attention moved or closed; choose the current action")
	local row = origin.workId and workRow(origin.workId)
	if row and origin.sourceSessionId == nil and row.sourceSessionId ~= nil
		and origin.intentVersion == intentVersion(row) and row.pane and sourceLocators[row.pane]
		and sourceLocators[row.pane].path == origin.locatorPath and identityMembership[row.pane] == origin.targetMember then
		origin.sourceSessionId, origin.rowVersion = row.sourceSessionId, rowVersion(row)
	end
	assert(not origin.workId or (row and rowVersion(row) == origin.rowVersion),
		"This conversation menu is no longer current")
	return data, row
end

local function completedAction(origin, callback, navigation)
	return function(result, err, fresh)
		if result == nil and err == nil then return end
		if not fresh then tern.log.warn("Attention:", "Action returned without its current window"); return end
		local ok, failure = pcall(function()
			assert(not err, err)
			local data, row = validateOrigin(fresh, origin, nil, navigation)
			callback(fresh, result, row, data)
		end)
		if not ok then report(fresh, failure, true) end
		schedule(32)
	end
end

withHeaderProof = function(cx, row, callback, failed, live, navigation)
	if row.pane == nil or row.orphaned or row.sourceSessionId == nil then callback(cx, row, snapshot); return end
	local locator = sourceLocators[row.pane]
	assert(locator and locator.localSource and locator.key == row.identityKey and not identityPending[row.pane],
		"Live conversation header is not locally verifiable; no change was made")
	local capture = { pane = row.pane, serial = row.serial, workId = row.workId, key = row.identityKey,
		path = locator.path, header = row.sourceSessionId, member = identityMembership[row.pane],
		locatorEpoch = sourceLocatorEpochs[row.pane] }
	enqueueHelperAction(cx, { op = "header", targets = tern.json.array({ {
		key = capture.key, path = capture.path, expectedSessionId = capture.header,
	} }) }, 3000, function(response, fresh, job)
		local currentLocator = sourceLocators[capture.pane]
		assert(currentLocator and currentLocator.localSource and currentLocator.key == capture.key
			and currentLocator.path == capture.path and sourceLocatorEpochs[capture.pane] == capture.locatorEpoch
			and identityMembership[capture.pane] == capture.member and identities[capture.pane] == capture.key
			and not identityPending[capture.pane] and not job.dirty[capture.pane],
			"Conversation moved while verifying its header; no change was made")
		local proofs = array(response.results, "Local conversation header")
		local proof = proofs[1]
		assert(#proofs == 1 and type(proof) == "table" and proof.key == capture.key and proof.path == capture.path
			and proof.historyRead == false and type(proof.capturedAtUtc) == "number"
			and proof.capturedAtUtc >= job.startedAtUtc and proof.capturedAtUtc <= utcNow(),
			"Local conversation header proof is missing or stale")
		assert(proof.status == "ready" or proof.status == "changed" or proof.status == "missing"
			or proof.status == "unsupported" or proof.status == "malformed", "Unsupported header proof status")
		sourceHeaders[capture.key] = proof
		if sourceFacts[capture.key] and proof.revision ~= sourceFacts[capture.key].revision then sourceDirty[capture.pane] = true end
		if proof.status ~= "ready" or proof.sessionId ~= capture.header then
			invalidateIdentity(capture.pane, true)
			-- A disproven header is structural: the recorded identity is wrong right now, not merely stale.
			identityNeeded = true
			schedule(32)
			error("Conversation header changed or could not be verified; action cancelled without acknowledgment")
		end
		local data = refresh(fresh, navigation ~= nil)
		local current = workRow(capture.workId)
		assert(data and current and current.serial == capture.serial and current.pane == capture.pane
			and current.identityKey == capture.key and current.sourceSessionId == capture.header
			and sourceLocatorEpochs[capture.pane] == capture.locatorEpoch,
			"Conversation changed after header verification; no change was made")
		if live and not live(fresh) then return end
		callback(fresh, current, data)
	end, failed, live, navigation)
end

local function completedMutation(origin, callback)
	return completedAction(origin, function(cx, result, row)
		withHeaderProof(cx, row, function(fresh)
			local data, current = validateOrigin(fresh, origin)
			callback(fresh, result, current, data)
		end)
	end)
end

local function saveAction(cx, data)
	project(cx, data, preferences(), true)
	schedule(32)
end

-- Applies one native tab move for the reorder intent: the session's tabs by current position, the moved tab
-- spliced ahead of `beforeId` (nil = end), one order_tab call at the dense one-based position, then a readback
-- that proves native accepted it — the native sidebar ends in exactly this order.
function intents.orderSessionTab(cx, sessionId, tabId, beforeId)
	local ordered, index, positionOf = {}, {}, {}
	for listed, tab in ipairs(array(cx.session:tabs(), "Tabs")) do
		if tab.session == sessionId then
			table.insert(ordered, tab.id)
			index[tab.id], positionOf[tab.id] = listed, tab.position
		end
	end
	table.sort(ordered, function(a, b)
		if positionOf[a] ~= positionOf[b] then return positionOf[a] < positionOf[b] end
		return index[a] < index[b]
	end)
	local movingAt = table.find(ordered, tabId)
	if movingAt == nil then return nil, "Target changed" end
	table.remove(ordered, movingAt)
	local insertAt = if beforeId == nil then #ordered + 1 else table.find(ordered, beforeId)
	if insertAt == nil then return nil, "Target changed" end
	table.insert(ordered, insertAt, tabId)
	local position = table.find(ordered, tabId)
	cx.layout:order_tab(tabId, position)
	counters.layoutWrites += 1
	placement.changed()
	local readback, readbackIndex, readbackPosition = {}, {}, {}
	for listed, tab in ipairs(array(cx.session:tabs(), "Tabs")) do
		if tab.session == sessionId then
			table.insert(readback, tab.id)
			readbackIndex[tab.id], readbackPosition[tab.id] = listed, tab.position
		end
	end
	table.sort(readback, function(a, b)
		if readbackPosition[a] ~= readbackPosition[b] then return readbackPosition[a] < readbackPosition[b] end
		return readbackIndex[a] < readbackIndex[b]
	end)
	if #readback ~= #ordered then error("Native tab order did not change", 0) end
	for at, id in ipairs(ordered) do
		if readback[at] ~= id then error("Native tab order did not change", 0) end
	end
	return true
end

-- Navigation intents (D4): the navigator tree, search, creation and navigation-only activation. They live in their
-- own function scope because `bootstrap` is at Luau's limit of 200 local registers; only the entry points are
-- exported on `intents`. Everything here moves native focus or the view only: nothing acknowledges review,
-- skips, or advances the Next attention round, and a pending review navigation is dropped, never completed.
intents.install = function()
	-- One navigator tree per observation: conversation tracking rows joined onto the native destinations.
	local function projectWorkspace(cx, data, rows, sessionOrder)
		-- The hot pass hands in the prefs it already parsed; an intent without them reads the store, where a
		-- just-written order is already visible.
		return navigation.project(data, { rows = rows, identities = data.identities, identityPending = data.identityPending,
			window = cx:window_key(), nowUtc = utcNow(),
			sessionOrder = if sessionOrder ~= nil then sessionOrder else preferences().sessionOrder })
	end

	-- A fresh inventory and tree for an intent that must re-resolve its target; never a cached pass.
	local function freshWorkspace(cx, data)
		data = data or refresh(cx, true)
		assert(data, "Native inventory is unavailable")
		return projectWorkspace(cx, data, model.current(store).rows), data
	end

	-- The last active content destination for the permanent location line: its title and where it lives. `pane` is
	-- the window's tracked content pane, so it survives the rail itself holding focus. Nil when there is none.
	local function currentLocation(space, pane)
		local key = if pane ~= nil then navigation.locate(space, pane) else nil
		local destination = if key then navigation.resolve(space, key) else nil
		if destination == nil then return nil end
		local chain = navigation.ancestors(space, key)
		local context, tabTitle, sessionName = {}, nil, nil
		if destination.placement == "parked" then table.insert(context, "Parked")
		elseif destination.placement == "unattached" then table.insert(context, "Unattached") end
		for index = #chain, 1, -1 do
			local ancestor = navigation.resolve(space, chain[index])
			if ancestor ~= nil and ancestor.kind == "tab" then
				tabTitle = ancestor.title
				if ancestor.title ~= destination.title then table.insert(context, ancestor.title) end
			elseif ancestor ~= nil and ancestor.kind == "session" then
				sessionName = ancestor.name
				table.insert(context, ancestor.name)
			elseif ancestor ~= nil and ancestor.kind == "host" and #space.hosts > 1 then table.insert(context, ancestor.name) end
		end
		-- The model is display-only: named only for a conversation, as its rail row is, and it never enters the key above.
		local model = if destination.conversation ~= nil then destination.model else nil
		-- `tab` and `session` name the place itself (the owning tab and its session) for the Workspace region header,
		-- structured rather than re-parsed from `context`.
		-- `workId` names the conversation shown there, so its queue rows can mark themselves current too.
		return { key = key, title = destination.title, context = table.concat(context, " · "), model = model,
			tab = tabTitle, session = sessionName,
			workId = if destination.conversation ~= nil then destination.conversation.workId else nil }
	end

	-- Saved navigator state (D3) is restored once per ownership epoch, before an intent or render first uses `logical`.
	local function ensureUi(cx, prefs)
		if uiRestored then return end
		uiRestored = true
		local saved = uiFor(prefs, cx:window_key())
		if saved then view.restore(logical, saved) end
	end

	local function refuse(cx, message)
		cx:toast("info", "Attention", message)
	end

	local function hostNode(space, hostKey)
		for _, host in ipairs(space.hosts) do
			if host.hostKey == hostKey then return host end
		end
		return nil
	end

	local function destinationOf(space, pane)
		local key = if pane ~= nil then navigation.locate(space, pane) else nil
		return if key then navigation.resolve(space, key) else nil
	end

	-- Content-pane transitions feed Previous. Every native focus event reduces here, and so does a focus this plugin
	-- made once it was read back, so one transition is recorded once whichever arrives first.
	local function noteFocus(paneId)
		if paneId == nil or owned[paneId] ~= nil then return end
		-- A new content destination supersedes only the not-yet-focused intent. This is not a failed visit:
		-- leave the round and unread review untouched, including for queued proofs.
		if pendingNavigation and paneId ~= pendingNavigation.focused then pendingNavigation = nil end
		local history = focusHistory
		if history.pendingBack and history.pendingBack.pane == paneId then
			history.current, history.pendingBack = paneId, nil
		elseif paneId ~= history.current then
			if history.pendingBack ~= nil then table.insert(history.stack, history.pendingBack.pane) end
			if history.current ~= nil then table.insert(history.stack, history.current) end
			history.current, history.pendingBack = paneId, nil
			if #history.stack > 50 then table.remove(history.stack, 1) end
		end
	end

	local function showHost(cx, data, host)
		if data.currentHost == host.id then return end
		cx.hosts:switch(host.id)
		counters.focusWrites += 1
		local current = cx.hosts:current()
		assert(current and current.id == host.id and current.state == "connected", "Host could not be shown")
	end

	local function showSession(cx, data, host, sessionId)
		showHost(cx, data, host)
		cx.sessions:switch(sessionId)
		counters.focusWrites += 1
		local shown = false
		for _, listed in ipairs(array(cx.sessions:list(), "Sessions")) do
			if listed.id == sessionId and listed.current == true then shown = true end
		end
		assert(shown, "Session could not be shown")
	end

	local function activateDestination(cx, space, data, destination)
		local host = hostNode(space, destination.hostKey)
		if host == nil or not host.connected then refuse(cx, "Host is offline · nothing changed"); return end
		local native = data.panes[destination.pane]
		if native == nil or native.host ~= host.id or native.parked ~= (destination.placement == "parked") then
			refuse(cx, "Target changed")
			return
		end
		requireOwner(cx)
		pendingVisit, pendingNavigation = nil, nil
		showHost(cx, data, host)
		if destination.placement == "parked" then
			-- Focusing or unparking a parked pane deals it into the current tab; the native chooser restores it on purpose.
			refuse(cx, "Parked — restore it from Parked panes")
			cx.actions:run("parked_panes")
			return
		end
		cx.layout:focus(destination.pane)
		placement.changed()
		counters.focusWrites += 1
		assert(cx.session:focused() == destination.pane, "Target could not be shown")
		noteFocus(destination.pane)
		schedule(32)
	end

	-- Opens every ancestor of the row that represents `key` (a pane inside a tab is represented by its tab row), explicitly,
	-- so a stacked rail's collapsed default cannot hide it, and selects Workspace; view state only. A row past the
	-- canvas cap is covered by the canvas footer ("N more not shown · Search reaches them").
	local function revealNode(cx, space, key)
		local rowKey = navigation.rowKey(space, key)
		view.section(logical, "workspace")
		for _, ancestor in ipairs(navigation.ancestors(space, rowKey)) do
			logical.workspace.collapsed[ancestor] = false
		end
		local listed = false
		for _, row in ipairs(navigation.rows(space, logical.workspace).rows) do
			if row.ref.key == rowKey then listed = true; break end
		end
		assert(listed, "That place is not listed in Workspace")
		logical.revision += 1
		logical.intentRevision += 1
		saveUi(cx, view.ui(logical))
	end

	-- Activates one navigator node. The target is re-resolved in a fresh snapshot and must still carry the signature
	-- the user saw; anything else is "Target changed", never a title or position fallback.
	local function openWorkspaceKey(cx, key, signature, data)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to navigate from this window")
		ensureUi(cx, prefs)
		local space, current = freshWorkspace(cx, data)
		local node = navigation.resolve(space, key)
		if node == nil or not navigation.signatureMatches(space, key, signature) then refuse(cx, "Target changed"); return end
		if node.kind == "pane" then
			activateDestination(cx, space, current, node)
		elseif node.kind == "tab" then
			-- The tab's target pane is what a pane click would open; a tab with none is refused, never guessed.
			if node.target == nil then refuse(cx, "Tab has no open pane · nothing changed"); return end
			activateDestination(cx, space, current, node.target)
		elseif node.kind == "session" or node.kind == "host" then
			local host = hostNode(space, node.hostKey)
			if host == nil or not host.connected then refuse(cx, "Host is offline · nothing changed"); return end
			requireOwner(cx)
			pendingVisit, pendingNavigation = nil, nil
			if node.kind == "session" then showSession(cx, current, host, node.id) else showHost(cx, current, host) end
			-- An empty session has nothing to show Attention in: opening it opens its first tab, as native's New tab would.
			if node.kind == "session" and node.empty then
				cx.layout:new_tab({})
				placement.changed()
				counters.layoutWrites += 1
			end
			schedule(32)
		elseif node.kind == "retained" then
			-- A saved conversation has no open pane to go to; it is not a tree row, so Search and queue rows
			-- resolve here and are told so plainly.
			refuse(cx, "No open pane")
		else
			error("Unknown Workspace target")
		end
	end

	-- Closing the last tab of the current session leaves no tab for Attention to live in, so the window goes back to
	-- where you were before, like closing a browser's last tab: the newest live pane of the focus history. The empty
	-- session stays listed. A session you switch to while empty is left alone; only a close lands here.
	intents.leaveEmptySession = function(cx)
		local space, data = freshWorkspace(cx)
		local sessionId = data.currentSession
		if sessionId == nil or data.sessions[sessionId] == nil then return end
		for _, tab in pairs(data.tabs) do
			if tab.session == sessionId and not closedTabs[tab.id] then return end
		end
		local stack = focusHistory.stack
		while #stack > 0 do
			local pane = table.remove(stack)
			local destination = if focusTarget(data, pane) then destinationOf(space, pane) else nil
			if destination ~= nil and destination.placement ~= "parked" then
				activateDestination(cx, space, data, destination)
				return
			end
		end
	end

	-- Navigation-only conversation open: the pane must still be a route of the same record and identity. No header
	-- is read and nothing is acknowledged, so a stale proof can at worst show the user a pane, never clear a cue.
	local function routeOpen(cx, binding, data)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to navigate from this window")
		ensureUi(cx, prefs)
		local space, current = freshWorkspace(cx, data)
		local row = workRow(binding.workId)
		local destination = destinationOf(space, binding.pane)
		local link = if destination then destination.conversation else nil
		if not (row and link and link.workId == binding.workId and link.serial == binding.serial
			and link.identityKey == binding.identityKey and row.identityKey == binding.identityKey
			and (binding.sourceSessionId == nil or row.sourceSessionId == binding.sourceSessionId)) then
			refuse(cx, "Target changed")
			return
		end
		local proven = current.identities[binding.pane]
		if proven ~= nil and not current.identityPending[binding.pane] and proven ~= binding.identityKey then
			refuse(cx, "Target changed")
			return
		end
		activateDestination(cx, space, current, destination)
	end

	local function captureIntent(cx)
		return { epoch = epoch, window = cx:window_key(), intentRevision = logical.intentRevision }
	end

	-- Completion of a native picker or prompt: cancel is inert, and an answer acts only while the owner, epoch and
	-- the user's selection are exactly those the question was asked in.
	local function completedIntent(intent, callback)
		return function(result, err, fresh)
			if result == nil and err == nil then return end
			if not fresh then tern.log.warn("Attention:", "Answer returned without its current window"); return end
			local ok, failure = pcall(function()
				assert(not err, err)
				assert(syncOwnership(fresh) and intent.epoch == epoch and fresh:window_key() == intent.window
					and logical.intentRevision == intent.intentRevision, "Attention selection changed; choose the action again")
				callback(fresh, result)
			end)
			if not ok then report(fresh, failure, true) end
			schedule(32)
		end
	end

	-- Search: the native picker filters its labels over the complete inventory. Cancel changes nothing.
	local function searchWorkspace(cx, data)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to search from this window")
		ensureUi(cx, prefs)
		local space = freshWorkspace(cx, data)
		local found = navigation.searchItems(space)
		assert(#found > 0, "Nothing to search in this window")
		local choices = {}
		for _, item in ipairs(found) do
			table.insert(choices, { id = item.id, label = item.label, detail = item.detail, signature = item.signature })
		end
		local intent = captureIntent(cx)
		cx:pick({ items = choices, placeholder = "Search workspace" }):next(completedIntent(intent, function(fresh, selected)
			assert(type(selected) == "table" and type(selected.id) == "string" and type(selected.signature) == "string",
				"Search result unavailable")
			openWorkspaceKey(fresh, selected.id, selected.signature)
		end))
	end

	local function revealCurrent(cx, data)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to reveal from this window")
		ensureUi(cx, prefs)
		local space, data = freshWorkspace(cx, data)
		local key = if data.content ~= nil then navigation.locate(space, data.content) else nil
		if key == nil then refuse(cx, "No current location to reveal"); return end
		revealNode(cx, space, key)
		schedule(32)
	end

	-- Creation. Native replies are not proof: each effect is confirmed by reading the native state back.
	local function trimmed(value)
		assert(type(value) == "string", "Entry unavailable")
		local stripped = string.gsub(string.gsub(value, "^%s+", ""), "%s+$", "")
		return stripped
	end

	local function paneSet(cx)
		local set = {}
		for _, pane in ipairs(array(cx.session:panes(), "Panes")) do set[pane.pane] = true end
		return set
	end

	local function confirmCreated(cx, before, returned, what)
		for _, pane in ipairs(array(cx.session:panes(), "Panes")) do
			if before[pane.pane] == nil and (not id(returned) or pane.pane == returned) then return pane.pane end
		end
		error(what .. " was not created")
	end

	local function createTab(cx, cwd)
		requireOwner(cx)
		local before = paneSet(cx)
		local returned = cx.layout:new_tab(if cwd then { cwd = cwd } else {})
		placement.changed()
		counters.layoutWrites += 1
		confirmCreated(cx, before, returned, "New tab")
	end

	-- The current session and host a creation would land in, re-read at commit time.
	local function checkTarget(cx, target)
		local data = refresh(cx, true)
		assert(data and data.currentHost == target.host.id and data.currentSession == target.session.id
			and data.hosts[target.host.id].connected, "The current session changed; open New… again")
		return data
	end

	local function ask(cx, intent, placeholder, action)
		cx:prompt({ placeholder = placeholder }):next(completedIntent(intent, function(owner, value)
			action(owner, trimmed(value))
		end))
	end

	local function createKind(cx, intent, target, op)
		checkTarget(cx, target)
		if op == "tab" then
			createTab(cx, target.cwd)
		elseif op == "note" then
			ask(cx, intent, "Note title", function(owner, title)
				assert(title ~= "", "A note needs a title")
				checkTarget(owner, target)
				requireOwner(owner)
				local before = paneSet(owner)
				confirmCreated(owner, before, owner.docs:new_note(title, ""), "Note")
			end)
		elseif op == "file" then
			ask(cx, intent, "File path · relative to the focused directory", function(owner, path)
				assert(path ~= "", "A file path is required")
				checkTarget(owner, target)
				requireOwner(owner)
				local pane = owner.docs:open(path)
				assert(id(pane) and owner.session:pane(pane) ~= nil, "File was not opened")
			end)
		elseif op == "url" then
			ask(cx, intent, "URL to open in a browser", function(owner, url)
				assert(url ~= "", "A URL is required")
				checkTarget(owner, target)
				requireOwner(owner)
				local before = paneSet(owner)
				owner.browser:call({ op = "open", url = url, owner = "attention" }):next(
					completedIntent(intent, function(fresh, result)
						local failure = if type(result) ~= "table" then "Browser did not open"
							elseif result.error ~= nil then text(result.error.message, "Browser did not open") else nil
						assert(failure == nil, failure)
						confirmCreated(fresh, before, nil, "Browser")
					end))
			end)
		elseif op == "session" then
			ask(cx, intent, "Session name · on " .. target.host.name, function(owner, name)
				assert(name ~= "", "A session name is required")
				checkTarget(owner, target)
				requireOwner(owner)
				local known = {}
				for _, listed in ipairs(array(owner.sessions:list(), "Sessions")) do known[listed.id] = true end
				owner.sessions:create({ name = name, cwd = target.cwd })
				counters.focusWrites += 1
				local created = false
				for _, listed in ipairs(array(owner.sessions:list(), "Sessions")) do
					if not known[listed.id] and listed.name == name then created = true end
				end
				assert(created, "Session was not created")
			end)
		else
			error("Unknown creation kind")
		end
	end

	-- New…: creation kinds with the destination named before anything is committed.
	local function newMenu(cx)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to create from this window")
		ensureUi(cx, prefs)
		local data = refresh(cx, true)
		assert(data, "Native inventory is unavailable")
		local host, session = data.hosts[data.currentHost], data.sessions[data.currentSession]
		assert(host and host.connected and session, "No current session to create in")
		local focused = if data.focused then data.allPanes[data.focused] else nil
		local target = { host = host, session = session, cwd = if focused then focused.cwd else nil }
		local directory = target.cwd or "default directory"
		local where = host.name .. " › " .. session.name .. " · " .. directory
		local items = {
			{ label = "New tab", detail = "Shell tab in " .. where, op = "tab" },
			{ label = "New note…", detail = "Note in " .. where, op = "note" },
			{ label = "Open file…", detail = "Opens in " .. where, op = "file" },
			{ label = "Open URL…", detail = "Browser in " .. where, op = "url" },
			{ label = "New session…", detail = "Session on " .. host.name .. " · " .. directory, op = "session" },
		}
		local intent = captureIntent(cx)
		cx:pick({ items = items, placeholder = "New in " .. host.name .. " › " .. session.name }):next(
			completedIntent(intent, function(fresh, selected) createKind(fresh, intent, target, selected.op) end))
	end

	-- The panes a tab row owns, read live. Empty when the lookup fails, so a tab whose panes cannot be read simply
	-- offers no Park or Close.
	local function tabPanes(cx, tabId)
		local listed, panes = pcall(function() return array(cx.session:panes(), "Panes") end)
		if not listed then return {} end
		local found = {}
		for _, info in ipairs(panes) do
			if info.tab == tabId then table.insert(found, info.pane) end
		end
		return found
	end

	-- A conversation's tracking choices. Its own More menu and the More menu of the tab row whose target it is (the
	-- conversation the row is titled with) both list these, so the labels and ops live in one place. Open existing pane
	-- is added by the conversation's own menu only: a tab row already opens its tab.
	function intents.trackingItems(row)
		local items = {}
		table.insert(items, { label = "Set priority · P0–P3 or unset", op = "priority" })
		table.insert(items, { label = "Keep as reference", op = "reference" })
		table.insert(items, { label = "Finished for now · current scope", op = "finished" })
		if row.disposition == "reference" or row.disposition == "finished" then
			table.insert(items, { label = "Resume tracking · does not run agent", op = "active" })
			table.insert(items, { label = "Bring back now", op = "bring-back" })
		end
		if row.pane == nil and row.retained then table.insert(items, { label = "Remove retained row · no open pane", op = "remove" }) end
		if row.pane ~= nil and row.orphaned and not row.navigable then
			table.insert(items, { label = "Remove unavailable tracking · no verified route", op = "remove-unavailable" })
		end
		table.insert(items, { label = "Inspect recorded facts · does not navigate or acknowledge", op = "inspect" })
		return items
	end

	-- The dispatch of one tracking choice, shared by a conversation's More menu and its tab row's More menu. The origin
	-- pins the window, rail and conversation version the menu was built from; completion goes through validateOrigin, so a
	-- conversation that changed since the menu opened refuses and nothing is written.
	function intents.workChoice(origin)
		return function(fresh, selected, current, data)
			if selected.op == "inspect" then
				if logical.expandedWorkId ~= current.workId then view.expand(logical, current.workId) end
				return
			end
			if selected.op == "open-pane" then
				intents.routeOpen(fresh, { workId = current.workId, serial = current.serial, pane = current.pane,
					identityKey = current.identityKey, sourceSessionId = current.sourceSessionId }, data)
				return
			end
			if selected.op == "priority" then
				local choices = { { label = "Unset", current = current.priority == nil } }
				for priority, label in ipairs({ "P0 Now", "P1 Next", "P2 Planned", "P3 Optional" }) do
					table.insert(choices, { label = label, priority = priority - 1, current = current.priority == priority - 1 })
				end
				fresh:pick({ placeholder = "Explicit priority · not inferred urgency", items = choices }):next(
					completedMutation(origin, function(owner, choice, selectedRow, selectedData)
						model.setPriority(store, selectedRow.workId, choice.priority)
						saveAction(owner, selectedData)
					end))
				return
			end
			withHeaderProof(fresh, current, function(owner)
				local currentData, rowValue = validateOrigin(owner, origin)
				if selected.op == "remove" then assert(model.removeRetained(store, rowValue.workId), "Only retained work without an open pane may be removed")
				elseif selected.op == "remove-unavailable" then
					assert(model.removeUnavailable(store, rowValue.pane, rowValue.serial), "Live or offline conversations cannot be removed")
				elseif selected.op == "bring-back" then model.setDisposition(store, rowValue.workId, "active", utcNow(), { bringBack = true })
				else model.setDisposition(store, rowValue.workId, selected.op, utcNow()) end
				saveAction(owner, currentData)
			end)
		end
	end

	-- Manual reorder (D6) from a ⋯ menu: Move up, down, to top or to bottom among the target's siblings (queue
	-- sections; one host's sessions; one session's tabs). Only moves that change the order are offered.
	local MOVE_LABELS = { up = "up", down = "down", top = "to top", bottom = "to bottom" }

	-- The moves that change `current`'s place among `ids`, in menu order.
	local function movesFor(ids, current)
		local at, count = table.find(ids, current), #ids
		if at == nil then return {} end
		local moves = {}
		if at > 1 then table.insert(moves, "up") end
		if at < count then table.insert(moves, "down") end
		if at > 2 then table.insert(moves, "top") end
		if at < count - 1 then table.insert(moves, "bottom") end
		return moves
	end

	-- `ids` with `current` moved `to`, or nil when that move no longer changes the order.
	local function movedOrder(ids, current, to)
		local at = table.find(ids, current)
		if at == nil or table.find(movesFor(ids, current), to) == nil then return nil end
		local order = table.clone(ids)
		table.remove(order, at)
		table.insert(order, if to == "top" then 1 elseif to == "bottom" then #ids elseif to == "up" then at - 1 else at + 1, current)
		return order
	end

	-- The listed (non-empty) sessions of a host, and one session's tabs, in display order.
	local function listedSessionIds(host)
		local ids = {}
		for _, session in ipairs(host.sessions) do
			if #session.tabs > 0 then table.insert(ids, session.id) end
		end
		return ids
	end
	local function sessionTabIds(host, sessionId)
		for _, session in ipairs(host.sessions) do
			if session.id == sessionId then
				local ids = {}
				for _, tab in ipairs(session.tabs) do table.insert(ids, tab.id) end
				return ids, session
			end
		end
		return {}, nil
	end

	-- Applies one chosen move against a fresh snapshot. A session or tab target must still carry the signature
	-- the user saw, and the move must still change the order, else it refuses rather than moves something else.
	-- Tabs order natively (`order_tab`), so the native sidebar matches; queue and session order are Attention's
	-- own preferences.
	local function applyMove(cx, target, to)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to reorder from this window")
		ensureUi(cx, prefs)
		if target.scope == "queue" then
			local order = movedOrder(prefs.queueOrder, target.name, to)
			if order == nil then refuse(cx, "Target changed"); return end
			prefs.queueOrder = order
			savePreferences(cx, prefs)
			return
		end
		local space = freshWorkspace(cx)
		local host = hostNode(space, target.hostKey)
		if host == nil or navigation.resolve(space, target.key) == nil
			or not navigation.signatureMatches(space, target.key, target.signature) then
			refuse(cx, "Target changed")
			return
		end
		if target.scope == "session" then
			local order = movedOrder(listedSessionIds(host), target.sessionId, to)
			if order == nil then refuse(cx, "Target changed"); return end
			-- Empty sessions are not listed; they keep their place after the listed ones.
			for _, session in ipairs(host.sessions) do
				if not table.find(order, session.id) then table.insert(order, session.id) end
			end
			prefs.sessionOrder[target.hostKey] = order
			savePreferences(cx, prefs)
			return
		end
		assert(target.scope == "tab", "Unknown move target")
		local order = movedOrder((sessionTabIds(host, target.sessionId)), target.tabId, to)
		if order == nil then refuse(cx, "Target changed"); return end
		requireOwner(cx)
		local applied, reason = intents.orderSessionTab(cx, target.sessionId, target.tabId, order[table.find(order, target.tabId) + 1])
		if not applied then refuse(cx, reason or "Target changed") end
	end

	-- A queue section's ⋯ menu: its moves among the queue sections.
	local QUEUE_NAMES = { attention = "Attention", working = "Working" }
	local function queueMenu(cx, binding)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to reorder from this window")
		ensureUi(cx, prefs)
		local name = assert(QUEUE_NAMES[binding.name] and binding.name, "Unknown queue")
		local items = {}
		for _, to in ipairs(movesFor(prefs.queueOrder, name)) do
			table.insert(items, { label = "Move " .. MOVE_LABELS[to], detail = QUEUE_NAMES[name], to = to })
		end
		local choose = completedIntent(captureIntent(cx), function(fresh, selected)
			applyMove(fresh, { scope = "queue", name = name }, selected.to)
		end)
		cx:pick({ items = items, placeholder = QUEUE_NAMES[name] }):next(choose)
	end

	-- The native More menu of a tab row: the row's target conversation's tracking items first, then the tab
	-- actions: rename, add a tab, and move the tab or its session. A tab that owns panes also offers Park
	-- (detach them, programs keep running) and Close (end them) for every one of its panes. Close is destructive by
	-- design, so it is deliberate (open the menu, choose Close) and never asks again.
	local function nativeMenu(cx, rail, binding)
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here to manage tabs from this window")
		ensureUi(cx, prefs)
		local space, data = freshWorkspace(cx)
		local node = navigation.resolve(space, binding.key)
		if node == nil or node.kind ~= "tab"
			or not navigation.signatureMatches(space, binding.key, binding.signature) then
			refuse(cx, "Target changed")
			return
		end
		local host = hostNode(space, node.hostKey)
		if host == nil or not host.connected then refuse(cx, "Host is offline · nothing changed"); return end
		local title = node.title
		-- A tab row whose target is a conversation with a current work row (the conversation the row is titled with)
		-- offers that conversation's tracking choices first. They are pinned to the conversation's version as the menu
		-- opens, so a change before a choice refuses.
		local conversation = if node.kind == "tab" and node.target ~= nil and node.target.conversation ~= nil
			then workRow(node.target.conversation.workId) else nil
		local origin = if conversation then captureOrigin(cx, rail, conversation) else nil
		local items = if conversation then intents.trackingItems(conversation) else {}
		for _, item in ipairs(items) do item.work = true end
		table.insert(items, { label = "Rename tab…", detail = title, op = "rename" })
		table.insert(items, { label = "New tab here", detail = "Shell tab in " .. title, op = "new" })
		-- Tab moves change native order, so they are offered only on the host this window shows.
		local tabIds, session = sessionTabIds(host, node.sessionId)
		if data.currentHost == host.id then
			for _, to in ipairs(movesFor(tabIds, node.id)) do
				table.insert(items, { label = "Move tab " .. MOVE_LABELS[to], detail = title, op = "move", to = to,
					target = { scope = "tab", key = node.key, signature = node.signature, hostKey = node.hostKey,
						sessionId = node.sessionId, tabId = node.id } })
			end
		end
		if session ~= nil then
			for _, to in ipairs(movesFor(listedSessionIds(host), session.id)) do
				table.insert(items, { label = "Move session " .. MOVE_LABELS[to], detail = session.name, op = "move", to = to,
					target = { scope = "session", key = session.key, signature = session.signature, hostKey = session.hostKey,
						sessionId = session.id } })
			end
		end
		local paneCount = if data.currentHost == host.id then #tabPanes(cx, node.id) else 0
		if paneCount > 0 then
			local suffix = if paneCount > 1 then " · " .. paneCount .. " panes" else ""
			table.insert(items, { label = "Park (keep program alive)" .. suffix, detail = "Detaches the panes of " .. title, op = "park" })
			table.insert(items, { label = "Close" .. suffix, detail = "Ends the programs in " .. title, op = "close" })
		end
		local intent = captureIntent(cx)
		local chooseTab = completedIntent(intent, function(fresh, selected)
			local freshSpace, data = freshWorkspace(fresh)
			if not navigation.signatureMatches(freshSpace, node.key, node.signature) then refuse(fresh, "Target changed"); return end
			if selected.op == "move" then
				applyMove(fresh, selected.target, selected.to)
				return
			end
			if selected.op == "new" then
				requireOwner(fresh)
				pendingVisit, pendingNavigation = nil, nil
				showSession(fresh, data, host, node.sessionId)
				createTab(fresh, nil)
				return
			end
			if selected.op == "park" or selected.op == "close" then
				requireOwner(fresh)
				assert(data.currentHost == host.id, "Open " .. host.name .. " first to " .. selected.op .. " here")
				local targets = tabPanes(fresh, node.id)
				assert(#targets > 0, "This tab has no panes to " .. selected.op)
				local failure = nil
				-- Close events can arrive inside this loop; a pass then would retire the rail it is about to close itself.
				local outer = busy
				busy = true
				for _, pane in ipairs(targets) do
					local done, reason = pcall(function()
						if selected.op == "park" then
							local accepted, why = fresh.layout:park(pane)
							assert(accepted ~= false, why or "Pane was not parked")
						else
							fresh.layout:close(pane)
						end
					end)
					counters.layoutWrites += 1
					if not done and failure == nil then failure = tostring(reason) end
				end
				busy = outer
				if not outer then schedule(32) end
				if selected.op == "close" and not outer then intents.leaveEmptySession(fresh) end
				placement.changed()
				assert(failure == nil, failure)
				return
			end
			assert(data.currentHost == host.id, "Open " .. host.name .. " first to rename here")
			local placeholder = if node.kind == "tab" then "Tab name · blank restores the pane label" else "Session name"
			ask(fresh, intent, placeholder, function(owner, name)
				local current, currentData = freshWorkspace(owner)
				if not navigation.signatureMatches(current, node.key, node.signature) then refuse(owner, "Target changed"); return end
				assert(currentData.currentHost == host.id, "Open " .. host.name .. " first to rename here")
				requireOwner(owner)
				if node.kind == "tab" then
					local expected = if name == "" then nil else name
					owner.layout:name_tab(node.id, expected)
					counters.layoutWrites += 1
					local renamed = false
					for _, tab in ipairs(array(owner.session:tabs(), "Tabs")) do
						if tab.id == node.id and optionalText(tab.name) == expected then renamed = true end
					end
					assert(renamed, "Tab was not renamed")
				else
					assert(name ~= "", "A session needs a name")
					local accepted, reason = owner.layout:rename_session(node.id, name)
					counters.layoutWrites += 1
					assert(accepted ~= false, reason or "Session was not renamed")
					local renamed = false
					for _, listed in ipairs(array(owner.sessions:list(), "Sessions")) do
						if listed.id == node.id and listed.name == name then renamed = true end
					end
					assert(renamed, "Session was not renamed")
				end
			end)
		end)
		local chooseWork = if origin then completedAction(origin, intents.workChoice(origin)) else nil
		cx:pick({ items = items, placeholder = title }):next(function(result, err, fresh)
			if result ~= nil and result.work then chooseWork(result, err, fresh) else chooseTab(result, err, fresh) end
		end)
	end


	intents.projectWorkspace, intents.currentLocation = projectWorkspace, currentLocation
	intents.queueMenu = queueMenu
	intents.ensureUi, intents.refuse, intents.noteFocus = ensureUi, refuse, noteFocus
	intents.hostNode, intents.destinationOf, intents.routeOpen = hostNode, destinationOf, routeOpen
	intents.openWorkspaceKey, intents.searchWorkspace, intents.revealCurrent = openWorkspaceKey, searchWorkspace, revealCurrent
	intents.newMenu, intents.nativeMenu = newMenu, nativeMenu
end
intents.install()
intents.install = nil

-- Attention on the phone (phone.luau). Only the owner window publishes its queue to `phone.json` in the plugin data
-- folder; a write happens when the content changed or the heartbeat is due, and a failed write is reported once and
-- retried by the next pass. Every window swallows `attention://` links so the Mac never tries to open one.
intents.installPhone = function()
	local state = { revision = 0, last = nil, writtenAt = nil, seeded = false, reported = nil }
	-- The skip cache names the inputs of one built snapshot. A hit with `state.last` still holding that exact
	-- table proves the rows unchanged without building or comparing them; it lives here, so a reload never
	-- trusts an older VM's build.
	local cache = { presentation = nil, revision = 0, fingerprint = nil, bucket = 0, snapshot = nil }

	-- A restarted window continues the revision counter of the file it finds.
	local function seed()
		if state.seeded then return end
		state.seeded = true
		pcall(function()
			local file = tern.plugin.data .. "/" .. phone.FILE
			if not tern.fs.exists(file) then return end
			local old = phone.validate(tern.json.decode(tern.fs.read(file, 1048576)))
			if old then state.last, state.revision = old, old.revision end
		end)
	end

	local function failed(cx, failure)
		local shown = humanize(failure)
		if state.reported ~= shown then
			state.reported = shown
			report(cx, "Phone queue not published: " .. shown, false)
		end
	end

	-- Every workspace fact `phone.snapshot` consumes: each host's key and name (the local one names the
	-- queue), each tab's identity and title, and each destination's pane, placement and title evidence.
	-- Equal fingerprints guarantee identical rows; O(places) concatenation with no per-row work.
	local function destinationPart(destination)
		return table.concat({ "pane", tostring(destination.pane), tostring(destination.hostKey), tostring(destination.tabId),
			tostring(destination.placement), tostring(destination.titleSource), tostring(destination.title),
			tostring(destination.cwd), tostring(destination.program) }, "\t")
	end

	local function fingerprint(space)
		local parts = {}
		for _, host in ipairs(if space then space.hosts else {}) do
			table.insert(parts, table.concat({ "host", tostring(host.hostKey), tostring(host.name) }, "\t"))
			for _, session in ipairs(host.sessions) do
				for _, tab in ipairs(session.tabs) do
					table.insert(parts, table.concat({ "tab", tostring(tab.hostKey), tostring(tab.id), tostring(tab.name),
						tostring(tab.title), tostring(#tab.destinations) }, "\t"))
					for _, destination in ipairs(tab.destinations) do
						table.insert(parts, destinationPart(destination))
					end
				end
			end
			for _, destination in ipairs(host.parked) do table.insert(parts, destinationPart(destination)) end
			for _, destination in ipairs(host.unattached) do table.insert(parts, destinationPart(destination)) end
		end
		return table.concat(parts, "\n")
	end

	local function build(status, reason, presentation, space)
		local host = nil
		for _, node in ipairs(if space then space.hosts else {}) do
			if node.hostKey == "local" then host = node.name end
		end
		if host == nil and state.last then host = state.last.host end
		return phone.snapshot(presentation, space, { nowUtc = utcNow(), hostName = host, revision = 0, status = status,
			reason = if reason then humanize(reason) else nil, view = view })
	end

	local function emit(cx, snapshot, heartbeatDue, unchanged)
		seed()
		local now = tern.now()
		-- A cache hit already proved this table's rows equal to `state.last`, so nothing is compared again.
		local changed = if unchanged then false else state.last == nil or not phone.sameContent(state.last, snapshot)
		local due = heartbeatDue and (state.writtenAt == nil or now - state.writtenAt >= phone.HEARTBEAT_SECONDS * 1000)
		if not changed and not due then return end
		snapshot.revision = if changed then state.revision + 1 else state.revision
		local ok, failure = pcall(function()
			local directory = tern.plugin.data
			if not tern.fs.exists(directory) then tern.fs.mkdir(directory) end
			local encoded = table.clone(snapshot)
			encoded.rows = tern.json.array(table.clone(snapshot.rows))
			tern.fs.write(directory .. "/" .. phone.FILE, tern.json.encode(encoded))
		end)
		if ok then
			state.last, state.revision, state.writtenAt, state.reported = snapshot, snapshot.revision, now, nil
		else
			failed(cx, failure)
		end
	end

	local function attempt(cx, make, heartbeatDue)
		local ok, failure = pcall(function()
			local snapshot, unchanged = make()
			emit(cx, snapshot, heartbeatDue, unchanged)
		end)
		if not ok then failed(cx, failure) end
	end

	-- The pass's queue: `saved` is false when the tracking store cannot be saved, which the phone is told plainly.
	intents.publish = function(cx, saved)
		attempt(cx, function()
			if saved ~= true then return build("unavailable", storageProblem or "Saved attention is unavailable") end
			local now = utcNow()
			-- The bucket rolls with the ages the phone renders from row clock timestamps, so a hit can never
			-- reuse rows more than a minute older than the ones it would build now.
			local bucket = math.floor(now / 60000)
			if cache.snapshot ~= nil and cache.snapshot == state.last and cache.presentation == projection
				and cache.revision == projection.revision and cache.bucket == bucket
				and cache.fingerprint == fingerprint(workspace) then
				-- Quiet pass: the written snapshot already carries these exact rows; only its time moves, and
				-- the ordinary changed/heartbeat gate below decides the rewrite exactly as a built one would.
				cache.snapshot.generatedUtc = math.floor(now)
				return cache.snapshot, true
			end
			local snapshot = build("ok", nil, projection, workspace)
			cache.presentation, cache.revision, cache.fingerprint, cache.bucket = projection, projection.revision,
				fingerprint(workspace), bucket
			cache.snapshot = snapshot
			return snapshot
		end, true)
	end
	intents.publishUnavailable = function(cx, reason)
		attempt(cx, function() return build("unavailable", reason) end, true)
	end
	-- Written once: the owner left, so there is no heartbeat to keep alive.
	intents.publishDisabled = function(cx)
		attempt(cx, function() return build("disabled", "Attention is disabled") end, false)
	end

	tern.route.link(function(link)
		if type(link) == "table" and type(link.url) == "string" and string.lower(string.sub(link.url, 1, 12)) == "attention://" then
			return { handled = true }
		end
		return nil
	end)
end
intents.installPhone()
intents.installPhone = nil

local function workMenu(cx, rail, binding)
	local row = workRow(binding.workId)
	assert(row and row.serial == binding.serial and row.identityKey == binding.identityKey
		and row.pane == binding.pane and row.reviewRevision == binding.reviewRevision
		and (binding.sourceSessionId == nil or row.sourceSessionId == binding.sourceSessionId),
		"This conversation menu is no longer current")
	local origin = captureOrigin(cx, rail, row)
	validateOrigin(cx, origin)
	local items = intents.trackingItems(row)
	-- Opening an existing pane is availability-derived: only a live, reachable route is offered, and a parked,
	-- floating or unattached pane says so (a parked pane is restored through the native chooser, never unparked here).
	local destination = if row.pane ~= nil and workspace ~= nil then intents.destinationOf(workspace, row.pane) else nil
	local destinationHost = if destination then intents.hostNode(workspace, destination.hostKey) else nil
	if destination and destinationHost and destinationHost.connected then
		local where = if destination.placement == "parked" then " · parked, restore it from Parked panes"
			elseif destination.placement == "floating" then " · floating, shown without docking"
			elseif destination.placement == "unattached" then " · not in a tab"
			else ""
		table.insert(items, { label = "Open existing pane" .. where, op = "open-pane" })
	end
	cx:pick({ placeholder = row.title, action = "update tracking", items = items }):next(completedAction(origin, intents.workChoice(origin)))
end

local function finishVisit(cx, data, headerVerified)
	local visit = pendingVisit
	if not visit then return end
	local navigation = visit.navigation
	if navigation.cancelled or navigation.epoch ~= epoch or tern.now() >= navigation.deadline then
		intents.endNavigation(navigation, cx, "Opening expired · try again")
		return
	end
	local row = currentRow(visit.pane, visit.serial)
	local locator = sourceLocators[visit.pane]
	local sameEpisode = row ~= nil and row.workId == navigation.workId and row.serial == visit.serial
		and identityMembership[visit.pane] == navigation.targetMember
		and (navigation.locatorPath == nil or locator and locator.path == navigation.locatorPath
			and sourceLocatorEpochs[visit.pane] == navigation.locatorEpoch)
		and (visit.identityKey == nil or row.identityKey == visit.identityKey)
		and (visit.sourceSessionId == nil or row.sourceSessionId == visit.sourceSessionId)
	if sameEpisode and visit.sourceSessionId == nil and row.sourceSessionId ~= nil then
		local locator = sourceLocators[visit.pane]
		if row.reviewRevision == visit.reviewRevision and locator and locator.path == visit.locatorPath then
			visit.sourceSessionId = row.sourceSessionId
		else sameEpisode = false end
	end
	local proven = data.identityReady and not data.identityPending[visit.pane]
	local proofReady = visit.identityKey == nil or (proven and identityReady and not identityPending[visit.pane]
		and data.identities[visit.pane] == visit.identityKey)
	local identityMismatch = visit.identityKey ~= nil and proven and data.identities[visit.pane] ~= visit.identityKey
	local proofPending = visit.identityKey ~= nil and not proofReady and identityRequest ~= nil
		and tern.now() < identityRequest.deadline
	local native = data.allPanes[visit.pane]
	local host = native and data.hosts[native.host]
	local usable = false
	if sameEpisode and proofReady and row.navigable and native and host and host.connected and native.host == visit.host and native.tab
		and data.focused == visit.pane and data.currentHost == visit.host and data.currentSession == native.session and not native.parked then
		local arrangement = cx.session:layout(native.tab)
		if arrangement and arrangement.focus == visit.pane then
			usable = treeHas(arrangement.root, visit.pane)
			if not usable then
				for _, floating in ipairs(arrangement.floats) do if floating.pane == visit.pane then usable = true; break end end
			end
		end
	end
	if usable then
		if visit.sourceSessionId ~= nil and not headerVerified then
			if visit.ackChecking then return end
			visit.ackChecking = true
			local function failed()
				intents.endNavigation(navigation)
			end
			local launched, problem = pcall(withHeaderProof, cx, row, function(fresh, _, currentData)
				if pendingVisit ~= visit then return end
				visit.ackChecking = false
				finishVisit(fresh, currentData, true)
			end, failed, function()
				return pendingVisit == visit and not navigation.cancelled and navigation.epoch == epoch
					and tern.now() < navigation.deadline
			end, navigation)
			if not launched then failed(); report(cx, problem, true) end
			return
		end
		requireOwner(cx)
		if tern.now() >= navigation.deadline or navigation.cancelled or pendingVisit ~= visit then
			intents.expireNavigation(cx)
			return
		end
		-- Next chooses speculatively. A newer review keeps both its cue and the
		-- existing round: even model.visit's rejected acknowledgment consumes a turn.
		if row.reviewRevision == visit.reviewRevision then
			local binding = navigation.binding
			if binding.round and store.round == binding.initialRound then
				if store.round == nil or store.round.entries ~= binding.round.entries then store.round = binding.round
				else
					for serial in pairs(binding.round.finished) do store.round.finished[serial] = true end
				end
			end
			model.visit(store, visit.pane, visit.reviewRevision, visit.serial)
		end
		if intents.interactive.timer then intents.interactive.timer:cancel(); intents.interactive.timer = nil end
		notice, pendingVisit = nil, nil
	elseif not native or not sameEpisode or identityMismatch
		or (tern.now() >= visit.deadline and not proofPending) then
		intents.endNavigation(navigation)
		report(cx, "Target could not be shown; attention was not acknowledged", true)
	elseif not proofPending then
		schedule(32)
	end
end

local function navigate(cx, binding, data, verified, headerVerified, navigation)
	requireOwner(cx)
	intents.expireNavigation(cx)
	if binding.origin then data = validateOrigin(cx, binding.origin, data, true) end
	if navigation and not navigationLive(navigation) then return end
	local row = currentRow(binding.pane, binding.serial)
	local native = data.panes[binding.pane]
	assert(row and native, "This attention target is no longer available")
	assert(not binding.requireAttention or row.attention, "The captured Attention target changed")
	assert(binding.sourceSessionId == nil or row.sourceSessionId == binding.sourceSessionId,
		"The recorded conversation header changed; choose its current row")
	if binding.sourceSessionId == nil and row.sourceSessionId ~= nil then
		assert(row.reviewRevision == binding.reviewRevision, "Initial header proof changed the displayed review; choose its current row")
	end
	if not verified then
		local accepted = if pendingVisit then pendingVisit.navigation else pendingNavigation
		if accepted and navigationLive(accepted) and accepted.workId == row.workId
			and accepted.binding.pane == binding.pane and accepted.binding.serial == binding.serial
			and accepted.identityKey == row.identityKey and accepted.binding.reviewRevision == binding.reviewRevision
			and accepted.sourceSessionId == row.sourceSessionId then return end
	end
	if not verified then
		intents.endNavigation(if pendingVisit then pendingVisit.navigation else pendingNavigation)
		intents.interactive.sequence += 1
		navigation = { binding = binding, epoch = epoch, intentRevision = logical.intentRevision,
			token = tostring(epoch) .. ":" .. tostring(intents.interactive.sequence),
			deadline = (binding.acceptedAt or tern.now()) + 10000,
			workId = row.workId, identityKey = row.identityKey, sourceSessionId = row.sourceSessionId,
			targetMember = identityMembership[row.pane], locatorEpoch = sourceLocatorEpochs[row.pane],
			locatorPath = if sourceLocators[row.pane] then sourceLocators[row.pane].path else nil,
			attempts = 0, phase = "checking",
			focused = if owned[data.focused] then focusHistory.current else data.focused }
		pendingVisit, pendingNavigation = nil, navigation
		if intents.interactive.timer then intents.interactive.timer:cancel() end
		intents.interactive.timer = tern.timer(math.max(0, navigation.deadline - tern.now()), function(fresh)
			if navigation.epoch ~= epoch or (pendingNavigation ~= navigation
				and not (pendingVisit and pendingVisit.navigation == navigation)) then return end
			if fresh and (not syncOwnership(fresh) or navigation.epoch ~= epoch) then return end
			intents.expireNavigation(fresh)
		end)
		pruneNavigationJobs()
		schedule(32)
		intents.expireNavigation(cx)
		if pendingNavigation ~= navigation then return end
		if identityRequest then
			if row.identityKey ~= nil then navigation.request, navigation.attempts = identityRequest, 1 end
		else
			-- Navigation is a user action: structural, so it proofs even during failure backoff.
			identityNeeded, identityUrgent = true, true
			acquireIdentity(cx)
		end
		if row.identityKey ~= nil then return end
	end
	if row.sourceSessionId ~= nil and not headerVerified then
		navigation.header, navigation.phase = true, "queued"
		local function failed()
			intents.endNavigation(navigation)
		end
		local launched, problem = pcall(withHeaderProof, cx, row, function(fresh, _, currentData)
			if pendingNavigation ~= navigation or not navigationLive(navigation) then return end
			navigate(fresh, binding, currentData, true, true, navigation)
		end, failed, function(fresh) return pendingNavigation == navigation and navigationLive(navigation, fresh) end, navigation)
		if not launched then failed(); error(problem) end
		return
	end
	local focused, problem = pcall(function()
	navigation.phase = "opening"
	assert(row.navigable, "This attention target is no longer available")
	assert(data.hosts[native.host] and data.hosts[native.host].connected, "Target host is unavailable")
	if native.parked then
		if data.currentHost ~= native.host then
			requireOwner(cx)
			cx.hosts:switch(native.host)
			counters.focusWrites += 1
		end
		local host = cx.hosts:current()
		local focused = cx.session:focused()
		local pane = if focused then cx.session:pane(focused) else nil
		assert(host and host.id == native.host and host.state == "connected" and pane and optionalId(pane.tab),
			"No current content tab on the target host; parked target was not moved")
		local arrangement = cx.session:layout(pane.tab)
		assert(arrangement and treeLeaf(arrangement.root, owned),
			"No current content tab on the target host; parked target was not moved")
	end
	local live = cx.session:pane(binding.pane)
	assert(type(live) == "table" and live.pane == binding.pane, "Target closed before navigation")
	requireOwner(cx)
	assert(navigationLive(navigation, cx), "Opening expired or changed · try again")
	pendingNavigation = nil
	local visit = { pane = binding.pane, serial = binding.serial, host = native.host,
		navigation = navigation, reviewRevision = binding.reviewRevision, identityKey = row.identityKey,
		sourceSessionId = row.sourceSessionId,
		locatorPath = if sourceLocators[row.pane] then sourceLocators[row.pane].path else nil,
		headerProof = if row.identityKey then sourceHeaders[row.identityKey] else nil, deadline = tern.now() + 1000 }
	pendingVisit = visit
	cx.layout:focus(binding.pane)
	placement.changed()
	counters.focusWrites += 1
	end)
	if not focused then
		if pendingNavigation == navigation then pendingNavigation = nil end
		if pendingVisit and pendingVisit.navigation == navigation then pendingVisit = nil end
		error(problem)
	end
	schedule(32)
end

acquireIdentity = function(cx)
	if identityRequest then return end
	identityNeeded, identityUrgent = false, false
	-- The request captures membership at its start; dirty collects panes signalled while it runs.
	local request = { epoch = epoch, membership = identityMembership, dirty = {}, window = cx:window_key(), startedAt = tern.now(),
		deadline = tern.now() + 3000 }
	identityRequest, identityRetryAt = request, nil
	-- Every unresolved proof retries on a capped exponential backoff; a successful proof resets it.
	local function unresolved(stale)
		-- A structural input suppresses the backoff: it has earned one immediate fresh attempt. A stale
		-- response (valid data that dirty panes raced) is not failure: pending content gets its one
		-- follow-up now, and only a real failure arms the delay against content signals.
		if identityUrgent or (stale and identityNeeded) then return end
		identityRetryDelay = if identityRetryDelay == nil then 2000 else math.min(identityRetryDelay * 2, 60000)
		identityRetryAt = tern.now() + identityRetryDelay
	end
	-- Every failed proof, launched or not, leaves identity unverified, releases the navigation it gated,
	-- and republishes so retained rows are shown as unverified rather than as the last verified render.
	local function fail(failure)
		identityRequest, identityReady = nil, false
		local navigation = pendingNavigation
		if navigation and navigation.request == request then
			intents.endNavigation(navigation)
			failure = humanize(failure) .. " · try again"
		end
		report(cx, failure, false)
		identityFailure = notice
		unresolved()
		schedule(32)
	end
	if pendingNavigation and not pendingNavigation.header then
		pendingNavigation.request = request
		pendingNavigation.attempts += 1
	end
	local resolved, executable = pcall(resolveTernExecutable)
	if not resolved or executable == nil then
		fail("Tern CLI not found for identity inspection" .. (if resolved then "" else ": " .. tostring(executable)))
		return
	end
	local launched, launchError = pcall(function()
		tern.process.run({ executable, "inspect", "--json", "--window", request.window }, { timeout_ms = 3000 },
			function(result, fresh)
				if identityRequest ~= request or epoch ~= request.epoch then return end
				if not fresh then
					fail("Identity inspection returned without a current window")
					return
				end
				local accepted = false
				local ok, failure = pcall(function()
					if fresh:window_key() ~= request.window then
						if pendingNavigation and pendingNavigation.request == request then pendingNavigation = nil end
						return
					end
					local active = syncOwnership(fresh)
					if not active or epoch ~= request.epoch then return end
					assert(tern.now() <= request.deadline and type(result) == "table" and result.status == 0 and result.timed_out == false,
						"Native identity inspection failed or timed out")
					assert(type(result.stdout) == "string" and #result.stdout <= 4 * 1024 * 1024
						and type(result.stderr) == "string" and #result.stderr <= 65536,
						"Native identity inspection exceeded output limits")
					local document = tern.json.decode(result.stdout)
					local locators = identity.sources(document)
					local data = refresh(fresh, true, function(currentData)
						if identityRequest ~= request or epoch ~= request.epoch then return end
						-- The refreshed membership/signals already dirtied moved targets; the
						-- same reconciliation consumes accepted identities and queued events.
						local current = {}
						for pane in pairs(currentData.panes) do
							if not request.dirty[pane] and request.membership[pane] == identityMembership[pane] then
								local locator = locators[pane]
								current[pane], identityPending[pane] = if locator then locator.key else nil, nil
								local previous = sourceLocators[pane]
								if (previous == nil) ~= (locator == nil) or previous and locator
									and (previous.key ~= locator.key or previous.path ~= locator.path
										or previous.localSource ~= locator.localSource) then
									sourceLocatorEpochs[pane] = (sourceLocatorEpochs[pane] or 0) + 1
								end
								sourceLocators[pane] = locator
							else
								current[pane], identityPending[pane], identityNeeded = identities[pane], true, true
							end
						end
						identities, identityReady, accepted = current, true, true
						for pane, key in pairs(current) do
							if key ~= nil then counters.stage(pane, "identityAt") end
						end
						identitySourceObservedAt = request.startedAt
					end)
					if identityRequest ~= request or epoch ~= request.epoch then return end
					assert(data, "Identity membership is unavailable")
					local navigation = pendingNavigation
					if not navigation or navigation.request ~= request or not navigationLive(navigation) then return end
					local binding = navigation.binding
					local unmoved = request.membership[binding.pane] == identityMembership[binding.pane]
					-- A target signalled during its proof rides one follow-up inspection; a moved target or a
					-- second unproven attempt releases the navigation without acknowledgement.
					if identityPending[binding.pane] and unmoved and navigation.attempts < 2 then
						navigation.request = nil
						return
					end
					local routed, problem = pcall(function()
						assert(unmoved and not identityPending[binding.pane],
							"Attention identity changed during proof; attention was not acknowledged")
						local row = currentRow(binding.pane, binding.serial)
						if row and navigation.sourceSessionId == nil and row.sourceSessionId ~= nil then
							local locator = sourceLocators[binding.pane]
							assert(row.reviewRevision == binding.reviewRevision and locator and locator.path == navigation.locatorPath,
								"Initial header proof changed the captured work or review; choose its current row")
							navigation.sourceSessionId, binding.sourceSessionId = row.sourceSessionId, row.sourceSessionId
						end
						assert(row and row.identityKey == navigation.identityKey
							and identities[binding.pane] == navigation.identityKey
							and (navigation.sourceSessionId == nil or row.sourceSessionId == navigation.sourceSessionId),
							"Attention identity changed; attention was not acknowledged")
						navigate(fresh, binding, data, true, nil, navigation)
					end)
					if not routed then
						intents.endNavigation(navigation)
						report(fresh, problem, false)
					end
				end)
				if identityRequest ~= request then return end
				if not ok then
					fail(failure)
					return
				end
				identityRequest = nil
				if accepted then
					if identityFailure and notice == identityFailure then notice, lastError = nil, nil end
					identityFailure, identityRetryDelay = nil, nil
				else
					unresolved(true)
				end
				schedule(32)
			end)
	end)
	if not launched then fail("Native identity inspection unavailable: " .. tostring(launchError)) end
end

local function nextAttention(cx, origin, data)
	local acceptedAt = if origin and origin.acceptedAt then origin.acceptedAt else tern.now()
	local active, prefs = syncOwnership(cx)
	assert(active, "Use Attention: Enable here to navigate from this window")
	data = data or refresh(cx, true)
	if repeatedNavigation(origin, "next") then return end
	assert(data, "Native attention inventory is unavailable")
	local current = project(cx, data, prefs, true)
	assert(hydrated, storageProblem or "Saved attention is unavailable")
	local initialRound = store.round
	local selection = table.clone(store)
	if initialRound then selection.round = { entries = initialRound.entries, finished = table.clone(initialRound.finished) } end
	local pane, reason, serial = model.next(selection, data.focused, current.attentionTargets)
	local selectedRound = selection.round
	if pane == nil then
		if current.attentionCount > 0 then acquireIdentity(cx) end
		cx:toast("info", "Attention", reason)
		schedule(32)
		return
	end
	local row = currentRow(pane, serial)
	assert(row, "Attention target changed")
	local ok, failure = pcall(navigate, cx, { pane = pane, serial = row.serial,
		reviewRevision = row.reviewRevision, sourceSessionId = row.sourceSessionId, origin = origin,
		round = selectedRound, initialRound = initialRound, acceptedAt = acceptedAt,
		command = if origin == nil then "next" else nil, requireAttention = true }, data)
	if not ok then error(failure) end
end

-- Previous returns to the last content pane before any jump. It is location restore only:
-- no model visit, skip, or next runs, so the attention round stays untouched.
local function previousPane(cx, data)
	local active = syncOwnership(cx)
	assert(active, "Use Attention: Enable here to navigate from this window")
	if focusHistory.pendingBack then return end
	data = data or refresh(cx)
	assert(data, "Native attention inventory is unavailable")
	while #focusHistory.stack > 0 do
		if focusTarget(data, focusHistory.stack[#focusHistory.stack]) then break end
		table.remove(focusHistory.stack)
	end
	local target = focusHistory.stack[#focusHistory.stack]
	if target == nil then
		report(cx, "No previous pane to return to", true)
		return
	end
	pendingVisit, pendingNavigation = nil, nil
	table.remove(focusHistory.stack)
	focusHistory.pendingBack = { pane = target, deadline = tern.now() + 1000 }
	requireOwner(cx)
	cx.layout:focus(target)
	placement.changed()
	counters.focusWrites += 1
	schedule(32)
end

local function reconcileFocusHistory(cx, data)
	local history = focusHistory
	if history.pendingBack then
		local target = history.pendingBack.pane
		if data.focused == target and focusTarget(data, target) then
			history.current, history.pendingBack = target, nil
		elseif tern.now() > history.pendingBack.deadline then
			if focusTarget(data, target) then table.insert(history.stack, target) end
			history.pendingBack = nil
			report(cx, "Previous pane could not be shown", true)
		end
	elseif history.current == nil and focusTarget(data, data.focused) then
		history.current = data.focused
	end
end

-- NAT-03: why Attention is or is not mounted in this window, described from state the caller already read.
-- Pure: no native write and no inventory. Every state without a mounted rail names its cause.
local function availability(cx, prefs, data, selected, rail)
	local window = cx:window_key()
	local record = { window = window, enabled = prefs.enabled, owner = prefs.owner,
		owns = prefs.enabled and prefs.owner == window }
	local function describe(state, reason)
		record.state, record.reason = state, reason
		return record
	end
	if not prefs.enabled then return describe("disabled", "Attention is disabled · use Attention: Enable here") end
	if not record.owns then return describe("other-window", "Controlled in another window · use Attention: Enable here") end
	if not data then
		return describe("unavailable", humanize(inventoryError or storageProblem or "Native inventory unavailable")
			.. " · use native navigation")
	end
	if not selected then
		return describe("no-content", "No mounted rail — use native navigation · no content tab is selected in this window")
	end
	record.host, record.tab, record.target = selected.host, selected.tab, selected.target
	local host = data.hosts[selected.host]
	if not host or not host.connected then
		return describe("host-offline", "No mounted rail — use native navigation · this host is offline")
	end
	if host.key ~= "local" then
		return describe("remote-host", "Attention stays on your local host · remote sessions are shared")
	end
	record.pane, record.phase = rail and rail.pane, rail and rail.phase
	if not selected.eligible then
		return describe("deferred", if selected.arrangement.zoomed then "Placement deferred · unzoom this tab to place Attention"
			else "Placement deferred · select unzoomed nonfloating content in this tab")
	end
	if rail and rail.saved.userHidden then return describe("hidden", "Hidden in this tab · use Attention: Open") end
	if rail and rail.phase == "failed" then return describe("failed", rail.error or rail.status) end
	if not rail or not rail.pane then return describe("unmounted", "Attention is opening in this tab") end
	local native = data.allPanes[rail.pane]
	if rail.phase == "ready" and native and data.canvases[rail.pane] and native.tab == rail.tab and not native.parked then
		return describe("mounted", nil)
	end
	return describe(if rail.phase == "placing" or rail.phase == "recovering" then "placing" else "elsewhere", rail.status)
end

-- The recovery commands' shared resolver. It never requires a current tab: an empty session, an offline host or
-- another owning window yields an availability record and no rail instead of an error.
local function resolveHere(cx)
	local active, prefs = syncOwnership(cx)
	local here = { prefs = prefs }
	if active then
		here.data = refresh(cx)
		if here.data then
			discover(cx, here.data, prefs)
			here.selected = selectedContent(cx, here.data)
			local host = here.selected and here.data.hosts[here.selected.host]
			local tab = here.selected and here.data.tabs[here.selected.tab]
			if host and host.key == "local" and host.connected and tab then
				here.rail = ensureRail(here.data, prefs, host, tab)
			end
		end
	end
	here.availability = availability(cx, prefs, here.data, here.selected, here.rail)
	return here
end

-- Focuses this tab's Attention canvas. A parked canvas is never focused: that would deal it into the current tab.
local function focusNavigator(cx)
	local here = resolveHere(cx)
	local rail = here.rail
	local native = if rail and rail.pane and here.data then here.data.allPanes[rail.pane] else nil
	if not native or not here.data.canvases[rail.pane] then
		intents.refuse(cx, here.availability.reason or "Attention is not mounted in this tab · use Attention: Open")
		return
	end
	if native.parked then intents.refuse(cx, "Attention is parked · use Attention: Open"); return end
	requireOwner(cx)
	cx.layout:focus(rail.pane)
	placement.changed()
	counters.focusWrites += 1
	schedule(32)
end

-- Starts the bounded placement of this tab's rail at `position` (its recorded one when nil), replacing any placement
-- already running. Only two callers may start one: a click in this tab (resetPlacement) and the first eligible
-- visit of a tab an all-tabs action marked (placement.consume), so no rail moves without one of them.
function placement.start(cx, rail, position)
	local saved = rail.saved
	if rail.pane then
		if saved.placement == nil and rail.layout.job == nil and rail.phase ~= "placing" and rail.phase ~= "recovering" then
			prepareLayout(cx, rail)
		else
			generation += 1
			rail.generation = generation
		end
	end
	saved.moveTo = nil
	-- The next observation of this rail is a baseline, not a drag.
	rail.divider = nil
	if position then saved.position = position
	elseif saved.position == nil then saved.position = preferences().defaults.position end
	rail.error = nil
	if rail.pane then rail.phase = "recovering"
	elseif not saved.creating then rail.phase, rail.firstMissing, rail.discoveries = "unmounted", tern.now() - 2000, 1 end
	if rail.pane then savePlacement(cx, rail, "placing") else saveInstance(cx, rail) end
	schedule(placement.PASS_MS)
end

-- A tab marked by an all-tabs action moves on its first eligible visit: this tab selected and unzoomed, its host
-- connected, its rail settled. Hiding, parking, floating or hand-moving the rail drops the marker instead, and a
-- rail already at the marked edge just clears it. The marker is cleared as the move starts, so a degraded or
-- failed placement is never retried by it.
function placement.consume(cx, rail, data, selected)
	local saved = rail.saved
	local target = saved.moveTo
	if target == nil then return end
	local native = if rail.pane then data.allPanes[rail.pane] else nil
	if saved.userHidden or (native and (native.parked or native.floating or native.tab ~= rail.tab)) then
		saved.moveTo = nil
		saveInstance(cx, rail)
		return
	end
	if native == nil or not data.canvases[rail.pane] then return end
	if saved.creating or (rail.phase ~= "ready" and rail.phase ~= "failed") then return end
	if not (selected and selected.eligible and selected.host == rail.host and selected.tab == rail.tab) then return end
	local edge = layout.edgeOf(selected.arrangement.root, rail.pane)
	if rail.phase == "ready" and edge ~= nil and placement.positionOf[edge] == target then
		saved.moveTo = nil
		saveInstance(cx, rail)
		return
	end
	placement.start(cx, rail, target)
end

-- "Use this position for all tabs": the position becomes the default, and every rail that is not already there is
-- marked to move on its first eligible visit (the selected tab, when eligible, starts now). A rail on a disconnected
-- host is marked like any other and moves on its first visit after the host connects. Rails that are hidden, parked,
-- floating or not open in this tab stay where they are; the toast counts them by reason, and a tab with no rail mounted
-- simply opens its rail at the new position. One write records the default and every marker.
function placement.markAll(cx, data, selected, position)
	requireOwner(cx)
	assert(placement.positions[position], "Invalid placement action")
	local fresh = preferences()
	fresh.defaults.position = position
	local marked, kept, changes = 0, { hidden = 0, parked = 0, elsewhere = 0 }, {}
	for _, rail in pairs(rails) do
		local host, saved = data.hosts[rail.host], rail.saved
		if not saved.retiring and rail.phase ~= "closing" and rail.phase ~= "retired" then
			-- Native state of a disconnected host's pane is unknown; its marker is re-checked on the first visit.
			local connected = host ~= nil and host.connected
			local native = if rail.pane and connected then data.allPanes[rail.pane] else nil
			local candidate = table.clone(saved)
			candidate.moveTo = nil
			if saved.userHidden then
				kept.hidden += 1
			elseif rail.pane == nil and not saved.creating then
				candidate.position = position
			elseif connected and rail.pane and native and (native.parked or native.floating) then
				kept.parked += 1
			elseif connected and rail.pane and (native == nil or not data.canvases[rail.pane] or native.tab ~= rail.tab) then
				kept.elsewhere += 1
			else
				local there, heading = false, false
				if connected then
					local edge = nil
					if rail.pane then
						local read, arrangement = pcall(cx.session.layout, cx.session, rail.tab)
						if read and arrangement then edge = layout.edgeOf(arrangement.root, rail.pane) end
					end
					there = rail.phase == "ready" and saved.placement == nil and edge ~= nil
						and placement.positionOf[edge] == position
					heading = (rail.phase == "placing" or rail.phase == "recovering") and saved.position == position
				else
					there = saved.position == position and saved.placement == nil
				end
				if not there and not heading then candidate.moveTo, marked = position, marked + 1 end
			end
			if not deepEqual(candidate, saved) then table.insert(changes, { rail = rail, saved = candidate }) end
		end
	end
	for _, change in ipairs(changes) do
		local rail = change.rail
		fresh.instances[rail.key] = fresh.instances[rail.key] or {}
		fresh.instances[rail.key][tostring(rail.tab)] = change.saved
	end
	savePreferences(cx, fresh)
	for _, change in ipairs(changes) do
		local saved = change.rail.saved
		saved.moveTo, saved.position = change.saved.moveTo, change.saved.position
	end
	local failure = nil
	local host = selected and data.hosts[selected.host]
	local current = if host then rails[instanceKey(host.key, selected.tab)] else nil
	local selectedMarked = current ~= nil and current.saved.moveTo ~= nil
	if selectedMarked then
		local started, problem = pcall(placement.consume, cx, current, data, selected)
		if not started then failure = problem end
	end
	-- The selected tab moves now only when consume began its placement; a zoomed, floating or unready tab keeps its marker.
	local movesNow = selectedMarked and current.saved.moveTo == nil and current.phase == "recovering"
	cx:toast("info", "Attention · " .. string.upper(string.sub(position, 1, 1)) .. string.sub(position, 2) .. " for all tabs",
		markSummary(movesNow, marked - (if movesNow then 1 else 0), kept))
	if failure then report(cx, failure, true) end
	schedule(placement.PASS_MS)
end


local function resetPlacement(cx, rail, position)
	requireOwner(cx)
	observeShare(cx, rail)
	rail.saved.userHidden = false
	-- Per-tab relayout only: the global default changes through op = "default" or
	-- "Use ... for all tabs", never as a side effect of moving this tab's rail.
	placement.start(cx, rail, position or rail.saved.moveTo)
end

-- The palette form of a per-tab relayout: it needs a rail in this tab, moves only that tab
-- through the bounded placement machinery, and never touches the global default (that is
-- op = "default" or Use … for all tabs).
function placement.useInTab(cx, position)
	local here = resolveHere(cx)
	if not here.rail then
		notice = here.availability.reason
		cx:toast("info", "Attention", notice)
		return
	end
	resetPlacement(cx, here.rail, position)
end

local function openAttention(cx)
	-- Explicit Open re-confirms metadata-less canvases with a fresh bounded set of captures.
	remnantEvidence = {}
	local here = resolveHere(cx)
	local rail, data, selected = here.rail, here.data, here.selected
	if not rail then
		notice = here.availability.reason
		cx:toast("info", "Attention", notice)
		if here.availability.owns then schedule(32); armHeartbeat() end
		return
	end
	rail.saved.userHidden = false
	notice, lastError = nil, nil
	local native = rail.pane and data.allPanes[rail.pane]
	if native and native.parked then
		resetPlacement(cx, rail)
	elseif rail.pane == nil and not rail.saved.creating then
		rail.phase, rail.firstMissing, rail.discoveries, rail.error = "unmounted", tern.now() - 2000, 1, nil
		saveInstance(cx, rail)
	elseif not native then
		notice = "Creation or pane visibility is unconfirmed · waiting for native metadata; no duplicate opened"
		cx:toast("info", "Attention", notice)
	end
	if not selected.eligible then
		notice = "Placement deferred · select unzoomed nonfloating content in this tab"
		cx:toast("info", "Attention", notice)
	end
	schedule(32)
	armHeartbeat()
end

local function resetCurrentPlacement(cx)
	local here = resolveHere(cx)
	if not here.rail then
		notice = here.availability.reason
		cx:toast("info", "Attention", notice)
		return
	end
	resetPlacement(cx, here.rail)
end

-- The palette form of "All tabs": it needs an owning window with a readable inventory, not a rail in this tab.
function placement.useForAll(cx, position)
	local here = resolveHere(cx)
	if not here.data then
		notice = here.availability.reason
		cx:toast("info", "Attention", notice)
		return
	end
	placement.markAll(cx, here.data, here.selected, position)
end

local function enableAttention(cx)
	local prefs = preferences()
	local key = cx:window_key()
	assert(type(key) == "string", "Native window selector unavailable")
	-- Only this explicit command transfers ownership; selection/focus never does.
	if not prefs.enabled or prefs.owner ~= key then
		prefs.enabled, prefs.owner = true, key
		commitPreferences(prefs)
	end
	if not ownerActive or ownerKey ~= key then
		invalidate()
		ownerActive, ownerKey = true, key
	end
	openAttention(cx)
end

-- Disable stops Attention and leaves every rail pane where it is. With `closeRails` it first retires every rail
-- through the ordinary retire path, so a rail whose closure is not yet confirmed stays marked `retiring` in the store
-- and finishes on the next Enable; the disable itself still happens and the failure is reported.
local function disableAttention(cx, closeRails)
	requireOwner(cx)
	local retireFailure = nil
	if closeRails then
		local data = refresh(cx, true)
		assert(data, "Native inventory is unavailable; nothing was closed or disabled")
		for key, rail in pairs(rails) do
			local host = data.hosts[rail.host]
			if host and host.connected then
				local ran, retired = pcall(retire, cx, rail, data)
				if not ran then
					retireFailure = retireFailure or tostring(retired)
				elseif retired then
					removeInstance(cx, rail)
					rails[key] = nil
				end
			elseif not rail.saved.retiring then
				rail.saved.retiring = true
				saveInstance(cx, rail)
			end
		end
	end
	requireOwner(cx)
	local repaintFailure = nil
	local listed, canvases = pcall(function() return array(cx.canvas:list(), "Canvases") end)
	if listed then
		for _, canvas in ipairs(canvases) do
			if canvasOwned(canvas) then
				local painted, failure = pcall(setCanvas, cx, canvas.pane, {
					title = "Attention",
					view = { k = "col", p = { role = "attention.root" }, c = {
						{ k = "text", p = { text = "Attention is disabled" } },
						{ k = "text", p = { text = "Use Attention: Enable here to resume." } },
					} },
				})
				if not painted then repaintFailure = tostring(failure) end
			end
		end
	else
		repaintFailure = tostring(canvases)
	end
	requireOwner(cx)
	local prefs = preferences()
	prefs.enabled = false
	commitPreferences(prefs)
	if coalesced then coalesced:cancel(); coalesced = nil end
	if heartbeat then heartbeat:cancel(); heartbeat = nil end
	invalidate()
	ownerActive = false
	notice = "Attention is disabled"
	intents.publishDisabled(cx)
	if repaintFailure then report(cx, "Disabled; an unavailable canvas could not be repainted: " .. repaintFailure, true) end
	if retireFailure then report(cx, "Disabled; a rail could not be closed: " .. retireFailure, true) end
end


local function safeCommand(fn)
	return function(cx)
		local ok, failure = pcall(fn, cx)
		if not ok then report(cx, failure, true) else lastError = nil end
	end
end

local function normalizeChord(chord)
	local sequence = {}
	for segment in string.gmatch(string.lower(chord), "[^>]+") do
		local parts = {}
		for part in string.gmatch(segment, "[^+]+") do
			part = string.gsub(part, "%s", "")
			if part == "super" or part == "meta" or part == "command" then part = "cmd" end
			if part == "option" then part = "alt" end
			if part == "control" then part = "ctrl" end
			table.insert(parts, part)
		end
		table.sort(parts)
		table.insert(sequence, table.concat(parts, "+"))
	end
	return table.concat(sequence, ">")
end

local function chooseShortcut(cx)
	if shortcutChecked then return end
	shortcutChecked = true
	local ok, keys = pcall(function() return cx.actions:keys() end)
	if not ok or type(keys) ~= "table" then return end
	local occupied = {}
	for chord, actions in pairs(keys) do
		if type(chord) ~= "string" then return end
		occupied[normalizeChord(chord)] = actions
	end
	local chord = "cmd+j"
	local normalized = normalizeChord(chord)
	local configured = false
	for existing, actions in pairs(occupied) do
		if existing == normalized then
			if type(actions) ~= "table" or actions[1] ~= "plugin.attention.next" then return end
			configured = true
		elseif string.sub(existing, 1, #normalized + 1) == normalized .. ">" then
			return
		end
	end
	if configured then nextChord = chord; return end
	tern.bind(chord, "plugin.attention.next")
	-- Runtime registrations take effect after this callback returns.
	tern.timer(0, function(fresh)
		local readable, effective = pcall(function() return fresh.actions:keys() end)
		if not readable or type(effective) ~= "table" then return end
		for key, actions in pairs(effective) do
			if type(key) == "string" and normalizeChord(key) == normalized
				and type(actions) == "table" and actions[1] == "plugin.attention.next" then
				nextChord = chord
				if ownerActive then schedule(32) end
				return
			end
		end
	end)
end

runPass = function(cx, shared, sharedMigrate)
	if busy then schedule(32); return end
	busy = true
	local started = tern.now()
	catchup.passStartedAt = started
	local paused = nil
	local stage = nil
	local ok, failure = pcall(function()
		local carried = lastError
		local active, prefs = syncOwnership(cx, shared, sharedMigrate)
		if not active then
			if prefs.enabled then paused = "Controlled in another window · use Enable here" end
			return
		end
		placement.observations, placement.projections = {}, nil
		intents.ensureUi(cx, prefs)
		counters.passes += 1
		local data = refresh(cx, nil, nil, prefs)
		local arrived = false
		stage = "post"
		if data then
			instanceBatch = {}
			discover(cx, data, prefs)
			finishVisit(cx, data)
			reconcileFocusHistory(cx, data)
			local _, saved = project(cx, data, prefs, true)
			workspace = intents.projectWorkspace(cx, data, projection.rows, prefs.sessionOrder)
			view.normalize(logical, projection)
			intents.publish(cx, saved)
			local started = false
			if saved then arrived, started = observeArrivals() end
			-- An arrival opens its folded section: why make the user click to see what just came in.
			local revealed = arrived and view.revealQueue(logical, "attention")
			revealed = (started and view.revealQueue(logical, "working")) or revealed
			if revealed then saveUi(cx, view.ui(logical)) end
			reserveArrival(cx, data, arrived)
			stage = "maintain"
			maintainInstances(cx, data, prefs)
			placement.projections = nil
			stage = "render"
			local rendered = render(cx, data, prefs)
			if saved and rendered and carried ~= nil and notice == carried then notice, lastError = nil, nil end
			-- One validated commit carries every instance observation this pass collected.
			commitInstanceBatch(cx)
		else
			project(cx, snapshot, prefs, false)
			paused = pausedLine(storageProblem or inventoryError or "native inventory unavailable")
			intents.publishUnavailable(cx, storageProblem or inventoryError or "native inventory unavailable")
		end
	end)
	placement.observations, placement.projections, instanceBatch = nil, nil, nil
	busy = false
	catchup.passStartedAt = nil
	durationIndex = durationIndex % 128 + 1
	durations[durationIndex] = tern.now() - started
	if paused then
		paintState(cx, paused)
	elseif ok then
		statePainted = nil
	end
	if not ok then
		report(cx, failure, false)
		if stage ~= "maintain" and not canvasWriteFailed then paintState(cx, pausedLine(failure)) end
		canvasWriteFailed = nil
	end
end

schedule = function(ms)
	if coalesced then return end
	coalesced = tern.timer(ms, function(cx)
		coalesced = nil
		runPass(cx)
	end)
end

armHeartbeat = function()
	if heartbeat then return end
	heartbeat = tern.timer(1000, function(cx)
		heartbeat = nil
		-- Parse once with the migration flag; the pass below reuses this validated snapshot.
		local ok, prefs, migrate = pcall(preferences, true)
		if not ok then report(cx, prefs, false); armHeartbeat(); return end
		if prefs.enabled then
			runPass(cx, prefs, migrate)
			armHeartbeat()
		else
			local synchronized, failure = pcall(syncOwnership, cx)
			if not synchronized then report(cx, failure, false) end
		end
	end)
end

tern.command({ id = "enable", title = "Attention: Enable here", run = safeCommand(enableAttention) })
tern.command({ id = "open", title = "Attention: Open", run = safeCommand(openAttention) })
tern.command({ id = "reset-placement", title = "Attention: Reset placement (this tab)", run = safeCommand(resetCurrentPlacement) })
for _, position in ipairs({ "bottom", "right", "left" }) do
	tern.command({ id = "all-tabs-" .. position,
		title = "Attention: Use " .. string.upper(string.sub(position, 1, 1)) .. string.sub(position, 2) .. " for all tabs",
		run = safeCommand(function(cx) placement.useForAll(cx, position) end) })
end

for _, position in ipairs({ "bottom", "right", "left" }) do
	tern.command({ id = "this-tab-" .. position,
		title = "Attention: Use " .. string.upper(string.sub(position, 1, 1)) .. string.sub(position, 2) .. " in this tab",
		run = safeCommand(function(cx) placement.useInTab(cx, position) end) })
end
tern.command({ id = "next", title = "Attention: Next attention", run = safeCommand(nextAttention) })
tern.command({ id = "previous", title = "Attention: Previous pane", run = safeCommand(previousPane) })
tern.command({ id = "search", title = "Attention: Search workspace", run = safeCommand(intents.searchWorkspace) })
tern.command({ id = "focus-navigator", title = "Attention: Focus navigator", run = safeCommand(focusNavigator) })
tern.command({ id = "reveal", title = "Attention: Reveal current", run = safeCommand(intents.revealCurrent) })
tern.command({ id = "new", title = "Attention: New…", run = safeCommand(intents.newMenu) })
tern.command({ id = "disable", title = "Attention: Disable", run = safeCommand(function(cx) disableAttention(cx, false) end) })
tern.command({ id = "disable-and-close-rails", title = "Attention: Disable and close rails",
	run = safeCommand(function(cx) disableAttention(cx, true) end) })

local function queueEvent(kind, ev, cx)
	local ok, failure = pcall(function()
		local active = syncOwnership(cx)
		if not active then return end
		counters.events += 1
		-- Pane and tab topology reaches identity through per-pane membership in the next refresh; a closed or
		-- created ID is also dirty for an in-flight inspection so a reused ID cannot inherit its key.
		local paneId = type(ev) == "table" and id(ev.pane) and ev.pane or nil
		if (kind == "pane_created" or kind == "pane_closed") and paneId and identityRequest then
			identityRequest.dirty[paneId] = true
		elseif kind == "agent_state" or kind == "agent_finished" then
			if paneId then invalidateIdentity(paneId) else identityNeeded = true end
		end
		if kind == "agent_state" or kind == "agent_finished" or kind == "pane_created" or kind == "pane_closed" then
			agentCensus.dirty = true
		end
		if paneId and (kind == "title" or kind == "agent_finished" or kind == "agent_state") then
			sourceDirty[paneId] = true
			if sourceRequest then sourceRequest.dirty[paneId] = true end
			if intents.interactive.request then intents.interactive.request.dirty[paneId] = true end
		end
		-- Focus payloads are reduced in arrival order; sampling the focused pane on the next pass would collapse
		-- A→B→C to C. Attention's own canvases never join the history.
		if kind == "focus" and paneId then intents.noteFocus(paneId) end
		if type(ev) == "table" and id(ev.pane) then
			local event = nil
			if kind == "agent_state" and type(ev.new) == "string" and states[ev.new] then
				event = { kind = "state", pane = ev.pane, new = ev.new,
					old = if type(ev.old) == "string" and states[ev.old] then ev.old else nil, at = tern.now() }
			elseif kind == "agent_finished" and type(ev.result) == "string" and results[ev.result] then
				event = { kind = "finished", pane = ev.pane, result = ev.result, at = tern.now() }
			elseif kind == "pane_closed" then
				closedPanes[ev.pane] = true
				event = { kind = "closed", pane = ev.pane, at = tern.now() }
				for index = #focusHistory.stack, 1, -1 do
					if focusHistory.stack[index] == ev.pane then table.remove(focusHistory.stack, index) end
				end
				if focusHistory.current == ev.pane then focusHistory.current = nil end
				if focusHistory.pendingBack and focusHistory.pendingBack.pane == ev.pane then
					focusHistory.pendingBack = nil
				end
			end
			if event then
				if #events < 4096 then table.insert(events, event) else eventOverflow = true end
			end
		end
		if kind == "tab_closed" and type(ev) == "table" and id(ev.tab) then
			closedTabs[ev.tab] = true
			local prefs, changed = preferences(), false
			for _, entries in pairs(prefs.instances) do
				local saved = entries[tostring(ev.tab)]
				if saved and not saved.retiring then saved.retiring, changed = true, true end
			end
			for _, rail in pairs(rails) do
				if rail.tab == ev.tab then rail.saved.retiring, rail.phase = true, "closing" end
			end
			if changed then savePreferences(cx, prefs) end
			placement.createdTabs[ev.tab] = nil
		end
		if kind == "tab_created" and type(ev) == "table" and id(ev.tab) then
			local recorded = 0
			for _ in pairs(placement.createdTabs) do recorded += 1 end
			if recorded < placement.MAX_CREATED_TABS then placement.createdTabs[ev.tab] = true end
		end
		-- Native timers advance only while the window gets input, so a tab's rail mounting (new tab) or leaving (its
		-- last content pane closed) happens inside the event itself, not on a pass the next keystroke wakes. A new tab
		-- is focused after its tab_created, so focus runs at once while one awaits its rail; otherwise focus keeps its
		-- deferred pass (a visit lands on the pass after focus, so Next then Previous stays a non-visit).
		if kind == "tab_created" or kind == "pane_created" or kind == "pane_closed" or kind == "tab_closed"
			or (kind == "focus" and next(placement.createdTabs) ~= nil) then
			local inside = busy
			runPass(cx)
			if kind == "tab_closed" and not inside then intents.leaveEmptySession(cx) end
		else
			schedule(32)
		end
	end)
	if not ok then report(cx, failure, false) end
end

-- Unrolled: this frame sits at mlua's 200-register ceiling, and even a loop variable tips it over.
tern.on("focus", function(ev, cx) queueEvent("focus", ev, cx) end)
tern.on("pane_created", function(ev, cx) queueEvent("pane_created", ev, cx) end)
tern.on("pane_closed", function(ev, cx) queueEvent("pane_closed", ev, cx) end)
tern.on("tab_created", function(ev, cx) queueEvent("tab_created", ev, cx) end)
tern.on("tab_closed", function(ev, cx) queueEvent("tab_closed", ev, cx) end)
tern.on("title", function(ev, cx) queueEvent("title", ev, cx) end)
tern.on("cwd", function(ev, cx) queueEvent("cwd", ev, cx) end)
tern.on("agent_state", function(ev, cx) queueEvent("agent_state", ev, cx) end)
tern.on("agent_finished", function(ev, cx) queueEvent("agent_finished", ev, cx) end)

tern.on("budget", function(ev, cx)
	if type(ev) ~= "table" or (ev.state ~= "paused" and ev.state ~= "resumed") then return end
	local interrupted = pendingVisit ~= nil or pendingNavigation ~= nil
	catchup.budgetEventAt = tern.now()
	-- A hard interruption can bypass pcall cleanup and leave a diff or timer
	-- handle ahead of what the native host actually accepted.
	busy = false
	placement.observations, placement.projections, instanceBatch = nil, nil, nil
	intents.endNavigation(if pendingVisit then pendingVisit.navigation else pendingNavigation,
		cx, "Opening interrupted · try again")
	if coalesced then coalesced:cancel(); coalesced = nil end
	if heartbeat then heartbeat:cancel(); heartbeat = nil end
	if arrivalRetirement then arrivalRetirement:cancel(); arrivalRetirement = nil end
	for _, rail in pairs(rails) do
		view.invalidate(rail.view)
	end
	if ev.state == "paused" then
		counters.budgetPauses += 1
		report(cx, if interrupted then "Opening interrupted · try again"
			else "Native callback budget paused " .. text(ev.hook, "an Attention callback"), false)
		budgetNotice = notice
	elseif budgetNotice then
		if notice == budgetNotice then notice, lastError = nil, nil end
		budgetNotice = nil
	end
	local ok, prefs = pcall(preferences)
	if ok and prefs.enabled then
		if prefs.owner == cx:window_key() then
			schedule(if ev.state == "paused" then ev.paused_ms or 5000 else 32)
		end
		armHeartbeat()
	end
end)

tern.on("canvas_action", function(ev, cx)
	if type(ev) ~= "table" or ev.owner ~= "attention" then return false end
	local acceptedAt = tern.now()
	-- Always consume our clicks, including stale/disabled/foreign-window actions: never Carly fallback.
	local ok, failure = pcall(function()
		assert(id(ev.pane) and type(ev.act) == "string", "Invalid Attention action")
		local active, prefs = syncOwnership(cx)
		assert(active, "Use Attention: Enable here in this window")
		intents.ensureUi(cx, prefs)
		ownedCanvas(cx, ev.pane)
		local data = refresh(cx, true, nil, prefs)
		assert(data, "Native attention inventory is unavailable")
		local rail = nil
		for _, candidate in pairs(rails) do if candidate.pane == ev.pane then rail = candidate; break end end
		assert(rail, "Attention is reloading; try again after its current rows appear")
		local origin = captureOrigin(cx, rail)
		origin.action, origin.acceptedAt = ev.act, acceptedAt
		if repeatedNavigation(origin, nil) then return end
		local binding = rail.publishedBindings and rail.publishedBindings[ev.act]
		-- A view change paints on the next timer pass, so a click can land on a canvas that still shows the state before
		-- it. Paint what is current, then act only if the same action is still shown; a control that is gone does nothing.
		if rail.publishedLogicalRevision ~= logical.revision then
			render(cx, data, prefs)
			binding = rail.publishedBindings and rail.publishedBindings[ev.act]
		end
		if binding == nil or rail.publishedLogicalRevision ~= logical.revision then
			schedule(32)
			return
		end
		if binding.op == "cancel-navigation" then
			local navigation = if pendingVisit then pendingVisit.navigation else pendingNavigation
			if navigation and binding.token == navigation.token and binding.workId == navigation.workId
				and binding.serial == navigation.binding.serial and binding.pane == navigation.binding.pane
				and binding.identityKey == navigation.identityKey then
				intents.endNavigation(navigation)
				pruneNavigationJobs()
			end
			return
		end
		if binding.op == "next" then nextAttention(cx, origin, data); return end
		if binding.op == "previous" then previousPane(cx, data); return end
		if binding.op == "search" then intents.searchWorkspace(cx, data); return end
		if binding.op == "reveal" then intents.revealCurrent(cx, data); return end
		if binding.op == "workspace-open" then
			if view.restoreGroup(logical, binding.key) then saveUi(cx, view.ui(logical)) end
			intents.openWorkspaceKey(cx, binding.key, binding.signature, data)
			return
		end
		if binding.op == "route-open" then intents.routeOpen(cx, binding, data); return end
		if binding.op == "native-menu" then intents.nativeMenu(cx, rail, binding); return end
		if binding.op == "queue-menu" then intents.queueMenu(cx, binding); return end
		if binding.op == "section" then
			view.section(logical, binding.section)
			saveUi(cx, view.ui(logical))
		elseif binding.op == "workspace-toggle" then
			view.toggleGroup(logical, binding.key, binding.expanded)
			saveUi(cx, view.ui(logical))
		elseif binding.op == "workspace-minimize" then view.minimizeWorkspace(logical)
		elseif binding.op == "settings" then view.section(logical, "settings")
		elseif binding.op == "default" then
			-- The Settings placement row is the all-tabs move: it sets the default AND marks every eligible rail
			-- (this tab's moves now, the rest on their next eligible visit) — the same path the palette action runs.
			assert(placement.positions[binding.position], "Invalid default placement")
			placement.useForAll(cx, binding.position)
		elseif binding.op == "menu" then workMenu(cx, rail, binding)
		elseif binding.op == "details" or binding.op == "open" then
			local row = workRow(binding.workId)
			assert(row and row.serial == binding.serial and row.identityKey == binding.identityKey
				and row.pane == binding.pane
				and (binding.sourceSessionId == nil or row.sourceSessionId == binding.sourceSessionId),
				"This conversation is no longer current")
			if binding.op == "details" then view.expand(logical, binding.workId)
			else
				local target = table.clone(binding)
				target.origin, target.acceptedAt = origin, acceptedAt
				navigate(cx, target, data)
			end
		else error("Unknown Attention action") end
		-- The action may have changed the canvas, and a pass request can wait behind a pending timer (a native budget
		-- pause, for one). Paint what the action left now, so the click shows its result without waiting for that timer.
		if rail.publishedLogicalRevision ~= logical.revision then render(cx, data, prefs) end
		schedule(32)
	end)
	if not ok then
		report(cx, failure, true)
		schedule(32)
	else
		lastError = nil
	end
	return true
end)

-- Diagnostics reports the source lane's bookkeeping sizes via module-scope countKeys.

local function writeDiagnostics(cx)
	local written, pathOrError = pcall(function()
		local function bounded(value, limit)
			if value == nil then return nil end
			local valueText = tostring(value)
			if #valueText <= limit then return valueText end
			return string.sub(valueText, 1, (utf8.offset(valueText, 0, limit + 1) or limit + 1) - 1)
		end
		local ok, prefs = pcall(preferences)
		local canvasIds, layoutStatus = tern.json.array(), tern.json.array()
		local total = 0
		for _, rail in pairs(rails) do
			total += 1
			if #layoutStatus < 64 then
				if rail.pane then table.insert(canvasIds, rail.pane) end
				table.insert(layoutStatus, { host = rail.host, hostKey = rail.key, pane = rail.pane, tab = rail.tab,
					session = rail.session, phase = rail.phase, position = rail.saved.position,
					share = if ok and rail.saved.position then (prefs.defaults.shares[rail.saved.position][rail.key] or INITIAL_SHARE) else nil,
					userHidden = rail.saved.userHidden, status = bounded(rail.status, 128), pending = rail.pending,
					remnants = if rail.saved.remnants then tern.json.array(table.clone(rail.saved.remnants)) else nil })
			end
		end
		local where = { state = "preferences-unavailable", reason = bounded(prefs, 512) }
		if ok then
			local read, selected = pcall(function() return if snapshot then selectedContent(cx, snapshot) else nil end)
			local tab = read and selected and snapshot.tabs[selected.tab]
			local host = tab and snapshot.hosts[selected.host]
			local record = availability(cx, prefs, snapshot, if read then selected else nil,
				if host then rails[instanceKey(host.key, tab.id)] else nil)
			where = { state = record.state, reason = bounded(record.reason, 256), owns = record.owns,
				host = record.host, tab = record.tab, pane = record.pane, phase = record.phase }
		end
		local timings = table.clone(durations)
		table.sort(timings)
		local presentation = projection or model.current(store)
		local window = cx:window_key()
		local stages = {}
		for _, pane in ipairs(counters.stages.order) do
			local entry = counters.stages.panes[pane]
			if entry ~= nil then
				stages[tostring(pane)] = { membershipAt = entry.membershipAt, modelAt = entry.modelAt,
					sourceAt = entry.sourceAt, identityAt = entry.identityAt, claimedAt = entry.claimedAt }
			end
		end
		-- The stage recorder and its tables are machinery, not metrics: the payload's counters stay the plain numbers.
		local countersPayload = table.clone(counters)
		countersPayload.stages, countersPayload.stage = nil, nil
		local diagnostics = { owner = if ok then prefs.owner else nil, enabled = if ok then prefs.enabled else nil,
			preferenceError = if ok then nil else bounded(prefs, 512), window = window, availability = where,
			capturedAtMonotonicMs = tern.now(), active = ok and prefs.enabled and prefs.owner == window,
			status = presentation.status, rows = #presentation.rows, count = presentation.count, knownCount = presentation.knownCount,
			attentionCount = presentation.attentionCount, allCount = presentation.allCount,
			workingCount = #view.queue(presentation, "working"),
			reachableCount = presentation.reachableCount, awaitingHeaderCount = presentation.awaitingHeaderCount,
			logical = { section = logical.section, settings = logical.settings, revision = logical.revision,
				expandedWorkId = logical.expandedWorkId },
			sourcePending = sourceRequest ~= nil, sourceProofPending = sourceProofAfter ~= nil,
			sourceFailure = bounded(sourceFailure, 512),
			helperOperation = if sourceRequest then (if sourceRequest.action then sourceRequest.payload.op else "source") else nil,
			helperQueueDepth = #helperActions + #intents.interactive.queue,
			interactiveHeaderPending = intents.interactive.request ~= nil,
			sourceKeys = { dirty = countKeys(sourceDirty), pollPending = countKeys(sourcePollPending),
				locatorEpochs = countKeys(sourceLocatorEpochs), facts = countKeys(sourceFacts),
				observations = countKeys(sourceObservations), headers = countKeys(sourceHeaders) },
			agentStages = stages,
			canvasIds = canvasIds, instances = layoutStatus, instanceCount = total, counters = countersPayload,
			timings = { samples = #timings, maxMs = timings[#timings], p95Ms = timings[math.max(1, math.ceil(#timings * 0.95))] },
			notice = bounded(notice, 512), shortcut = nextChord, navigationPending = pendingVisit ~= nil or pendingNavigation ~= nil,
			previousDepth = #focusHistory.stack,
			identityRetryDelayMs = identityRetryDelay,
			limitations = "Native events missed while unloaded cannot be reconstructed; window ownership is explicit." }
		local encoded = tern.json.encode(diagnostics)
		assert(#encoded <= 65536, "Attention diagnostics exceeds the 64 KiB snapshot limit")
		local path = tern.plugin.data .. "/diagnostics.json"
		if not tern.fs.exists(tern.plugin.data) then tern.fs.mkdir(tern.plugin.data) end
		tern.fs.write(path, encoded)
		return path
	end)
	if written then
		cx:toast("success", "Attention diagnostics written", pathOrError)
	else
		-- Diagnostics failures must not change the rail's notice or schedule a render.
		cx:toast("error", "Attention diagnostics not written", tostring(pathOrError))
	end
end

tern.command({ id = "diagnostics", title = "Attention: Write diagnostics", run = writeDiagnostics })

-- Reloads do not receive window_start. A timer gives initialization its own fresh context.
tern.timer(0, function(cx)
	local ok, failure = pcall(function()
		chooseShortcut(cx)
		local _, prefs = syncOwnership(cx)
		runPass(cx)
		if prefs.enabled then armHeartbeat() end
	end)
	if not ok then report(cx, failure, true); armHeartbeat() end
end)
end

if tern ~= nil then
	-- Compilation counts against the native wall-time deadline. Requiring every module in
	-- the entry hook can abort startup before any click handler exists, leaving restored rails inert.
	local nextLoader = 1
	local function loadNext()
		loaders[nextLoader]()
		nextLoader += 1
		if nextLoader <= #loaders then tern.timer(0, loadNext)
		else bootstrap(tern) end
	end
	tern.timer(0, loadNext)
else
	-- Standalone Luau fixtures have no native event loop.
	for _, load in ipairs(loaders) do load() end
end
return bootstrap
