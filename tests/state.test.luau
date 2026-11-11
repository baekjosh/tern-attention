local identity = require("../identity")
local model = require("../model")

-- STATE-01: the schema-3 triage store is preserved exactly. STATE-07: remote and offline records without
-- proof are retained as last-known facts and are rebound only by a proven identity key.

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, field in pairs(value) do result[key] = copy(field) end
	return result
end

local function differs(a, b, path)
	if type(a) ~= type(b) then return path end
	if type(a) ~= "table" then return if a == b then nil else path end
	for key, value in pairs(a) do
		local found = differs(value, b[key], path .. "." .. tostring(key))
		if found then return found end
	end
	for key in pairs(b) do
		if a[key] == nil then return path .. "." .. tostring(key) end
	end
	return nil
end

local function expectSame(actual, expected, label)
	local path = differs(actual, expected, "store")
	assert(path == nil, label .. ": differs at " .. tostring(path))
end

local function context(now)
	return { window = "", hostKeys = { [1] = "local", [2] = "ssh:forge" }, connected = { ["local"] = true },
		coherent = true, nowUtc = now }
end

-- ---------------------------------------------------------------------------------------------
-- STATE-01
-- ---------------------------------------------------------------------------------------------

local function minimalRecord(serial)
	return { serial = serial, pane = 11, window = "", hostKey = "local", title = "Agent", sessionName = "Session",
		hostName = "Local", firstSeenUtc = 10, disposition = "active", queueOrder = 0, attentionRevision = 0, turn = 0 }
end

-- Every field the runtime models, populated with a valid value, plus fields it does not model.
local function fullRecord(serial)
	return {
		serial = serial, pane = 4002909519943, window = "window-a", hostKey = "ssh:forge", host = 2, tab = 20, session = 200,
		title = "Exact title", sessionName = "Session", hostName = "Forge", localHost = false, parked = true, floating = true,
		identityKey = "exact-identity", firstSeenUtc = 1234.5, disposition = "reference", queueOrder = 5,
		attentionRevision = 9, reviewRevision = 8, reviewKind = "done", reviewSuperseded = false,
		waiting = false, delivery = true, startup = true, nativeState = "idle", alert = true, turn = 3,
		finishedTurn = 3, finishedResult = "failed", legacy = true,
		deferredPane = 4, deferredWork = true, deferredResult = "done", deferredUtc = 1200,
		deferredWorkAfter = false, deferredWorkBefore = true, deferredWaitingUtc = 1201,
		retained = true, priority = 2, manualRevisit = true,
		sourceSessionId = "session-uuid", noOpenPane = true, replacedSource = true, waitingTurn = 2,
		sourceGap = true, sourceQuestionSuperseded = false, sourceQuestionRevision = 6, sourceWorkUtc = 1050,
		sourceQuestionBaseline = { revision = "rev-1", capturedAtUtc = 1000, ids = { "q1", "q2" } },
		source = {
			key = "exact-identity", sessionId = "session-uuid", capturedAtUtc = 1000, revision = "rev-1",
			status = "ready", complete = true, selection = "disk-replayed",
			coverage = { recordsComplete = true, historyScope = "full" },
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "q1", status = "open", askedAtUtc = 990, text = "Which option?" } },
			lastFinal = { id = "final", atUtc = 995, text = "Recorded final reply", timeKind = "completed" },
			lastKnown = { questions = { { id = "q0", status = "answered", retainedOrder = 1 } }, omittedQuestions = {},
				questionsKnown = 1, questionsIncluded = 1, questionsOmitted = 0, openQuestionsOmitted = 0,
				provenance = { questions = { q0 = { capturedAtUtc = 900, revision = "rev-0" } } } },
		},
		futureFlag = true, futureNested = { list = { 1, 2, { deep = "ünïcode" } }, text = "kept" },
	}
end

local function maximalStore()
	return { schema = 3, items = { minimalRecord(3), fullRecord(7) }, serial = 7, queueOrder = 5, attentionRevision = 9 }
end

local function pair()
	return { ok = true, now = 1, identityReady = true, identities = { [11] = "conversation:11", [22] = "conversation:22" },
		hosts = { [1] = { key = "local", name = "Local", connected = true } },
		agents = { { pane = 11, state = "waiting_input" }, { pane = 22, state = "idle" } },
		panes = {
			[11] = { host = 1, tab = 10, session = 100, title = "Alpha", sessionName = "Work", alert = false },
			[22] = { host = 1, tab = 11, session = 100, title = "Beta", sessionName = "Work", alert = false },
		} }
end

-- Two real conversations: one kept as reference with no priority, one with an unread completion and a priority.
local function builtStore()
	local state = model.new()
	local presentation = model.reconcile(state, pair(), { { kind = "finished", pane = 22, result = "done", at = 1 } }, context(100))
	local alpha, beta
	for _, row in ipairs(presentation.rows) do
		if row.pane == 11 then alpha = row else beta = row end
	end
	assert(model.setDisposition(state, alpha.workId, "reference", 101))
	assert(model.setPriority(state, beta.workId, 1))
	model.reconcile(state, pair(), {}, context(150))
	local saved = model.snapshot(state)
	assert(#saved.items == 2 and saved.items[1].disposition == "reference" and saved.items[2].priority == 1
		and saved.items[2].reviewRevision ~= nil)
	return saved, alpha.workId, beta.workId
end

test("a maximal schema-3 store round-trips every field exactly, including fields this runtime does not model", function()
	local saved = maximalStore()
	local pristine = copy(saved)
	local state = model.new(saved)
	expectSame(saved, pristine, "loading never mutates the supplied store")
	assert(state.persistenceRevision == 0, "an already-normal store needs no rewrite")
	local first = model.snapshot(state)
	expectSame(first, pristine, "load then save")
	expectSame(model.snapshot(model.new(copy(first))), pristine, "second generation")
	first.items[2].futureNested.list[3].deep = "changed"
	first.items[2].source.questions[1].text = "changed"
	first.items[2].sourceQuestionBaseline.ids[1] = "changed"
	expectSame(model.snapshot(state), pristine, "a saved snapshot shares no table with the live store")
end)

test("reload, reconcile and save are a fixed point for a store built by real operations", function()
	local saved, alpha, beta = builtStore()
	for generation = 1, 3 do
		local state = model.new(copy(saved))
		assert(state.persistenceRevision == 0, "generation " .. tostring(generation) .. " loads clean")
		for pass = 1, 2 do
			model.reconcile(state, pair(), {}, context(200 + pass))
			assert(not model.setDisposition(state, alpha, "reference", 300), "an unchanged disposition is a no-op")
			assert(not model.setPriority(state, beta, 1), "an unchanged priority is a no-op")
		end
		assert(state.persistenceRevision == 0, "generation " .. tostring(generation) .. " writes nothing")
		expectSame(model.snapshot(state), saved, "generation " .. tostring(generation))
	end
end)

test("fields this runtime does not model survive reconcile and edits while retired fields are still dropped", function()
	local saved, alpha = builtStore()
	local extended = copy(saved)
	for _, item in ipairs(extended.items) do item.carried = { owner = "newer writer", serial = item.serial } end
	extended.items[1].semantic = "retired cache"
	local state = model.new(copy(extended))
	assert(state.persistenceRevision > 0, "discarding a retired field schedules a rewrite")
	local live = pair()
	live.panes[11].title = "Alpha renamed"
	model.reconcile(state, live, {}, context(300))
	assert(model.setPriority(state, alpha, 2))
	local out = model.snapshot(state)
	for _, item in ipairs(out.items) do
		assert(item.carried ~= nil and item.carried.owner == "newer writer" and item.carried.serial == item.serial,
			"record " .. tostring(item.serial) .. " keeps its unmodelled field")
	end
	assert(out.items[1].title == "Alpha renamed" and out.items[1].priority == 2, "known fields still update")
	assert(out.items[1].semantic == nil, "retired fields are not resurrected")
	assert(model.snapshot(model.new({ schema = 1, records = {
		{ window = "", host = "local", pane = 11, firstSeenUtc = 1, bucket = "p0" } } })).items[1].bucket == nil,
		"legacy bucket data never leaks into schema 3")
end)

test("a higher schema is refused untouched and never rewritten as schema 3", function()
	local saved = builtStore()
	for _, schema in ipairs({ 4, 99 }) do
		local future = copy(saved)
		future.schema = schema
		future.futureTopLevel = { keep = true }
		local pristine = copy(future)
		local ok, failure = pcall(model.new, future)
		assert(not ok and string.find(tostring(failure), "Invalid triage store schema", 1, true), "schema " .. tostring(schema))
		expectSame(future, pristine, "refused schema " .. tostring(schema))
	end
	local parallel = copy(saved)
	parallel.records = {}
	local pristine = copy(parallel)
	local ok, failure = pcall(model.new, parallel)
	assert(not ok and string.find(tostring(failure), "Invalid triage parallel store", 1, true))
	expectSame(parallel, pristine, "refused parallel store")
	local corrupt = copy(saved)
	corrupt.items[2].disposition = "archived"
	pristine = copy(corrupt)
	assert(not pcall(model.new, corrupt))
	expectSame(corrupt, pristine, "refused invalid record")
	assert(model.snapshot(model.new(copy(saved))).schema == 3)
end)

-- ---------------------------------------------------------------------------------------------
-- STATE-07
-- ---------------------------------------------------------------------------------------------

-- options: panes = { { id, title, key, state } }, connected, hostName, pending = { [paneId] = true }
local function remote(options)
	local value = {
		ok = true, now = 1, identityReady = true, identities = {}, identityPending = options.pending,
		hosts = {
			[1] = { id = 1, key = "local", name = "Local", connected = true },
			[2] = { id = 2, key = "ssh:forge", name = options.hostName or "Forge", connected = options.connected ~= false },
		},
		agents = {}, panes = {},
	}
	for _, spec in ipairs(options.panes or {}) do
		table.insert(value.agents, { pane = spec.id, state = spec.state or "waiting_input" })
		value.panes[spec.id] = { host = 2, tab = 20, session = 200, title = spec.title or "omp", alert = false }
		value.identities[spec.id] = spec.key
	end
	return value
end

-- A proven remote locator exactly as the native inspect document publishes it.
local function proofOf(paneId, file, host, principal)
	local document = { panes = { { pane = paneId, omp_session_file = file,
		identity = { hops = { { principal = principal or "josh", method = "ssh", from = "", host = host, user = "josh" } } } } } }
	return identity.index(document)[paneId]
end

local function outage(state, reload)
	model.reconcile(state, remote({ connected = false }), {}, context(110))
	if not reload then return state end
	state = model.new(model.snapshot(state))
	model.reconcile(state, remote({ connected = false }), {}, context(111))
	return state
end

test("same-title remote records without proof never merge, gain attention or lose last-known facts", function()
	for _, kept in ipairs({ false, true }) do
		local label = if kept then "kept" else "unkept"
		local state = model.new()
		local first = model.reconcile(state, remote({ panes = { { id = 22 }, { id = 23 } } }), {}, context(100))
		assert(#first.rows == 2 and first.attentionCount == 2 and first.rows[1].workId ~= first.rows[2].workId, label)
		local old = {}
		for _, row in ipairs(first.rows) do
			assert(row.title == "omp" and row.identityKey == nil and row.navigable, label)
			old[row.workId] = row
		end
		if kept then
			for workId in pairs(old) do assert(model.setDisposition(state, workId, "reference", 101)) end
		end

		local offline = model.reconcile(state, remote({ connected = false }), {}, context(110))
		assert(offline.status == "partial" and #offline.rows == 2 and offline.reachableCount == 0, label)
		assert(offline.attentionCount == (if kept then 0 else 2), label .. ": the outage adds no Attention")
		for _, row in ipairs(offline.rows) do
			local before = old[row.workId]
			assert(before ~= nil and row.pane == before.pane and row.title == "omp" and row.hostName == "Forge", label)
			assert(row.stale and not row.navigable and not row.orphaned and row.unavailableReason == "Forge offline", label)
			assert(row.attentionRevision == before.attentionRevision and row.reviewRevision == before.reviewRevision,
				label .. ": an outage mints no revision")
			assert(row.attention == not kept, label)
		end

		local back = model.reconcile(state, remote({ panes = { { id = 32 } } }), {}, context(120))
		local fresh
		for _, row in ipairs(back.rows) do
			if old[row.workId] == nil then
				assert(fresh == nil, label .. ": exactly one new record")
				fresh = row
			else
				assert(kept, label .. ": unretained proofless records close with their host's pane, they are not merged")
				assert(row.pane == nil and row.retained and not row.navigable and not row.attention
					and row.disposition == "reference" and row.unavailableReason == "No open pane", label)
				assert(row.attentionRevision == old[row.workId].attentionRevision, label)
			end
		end
		assert(#back.rows == (if kept then 3 else 1), label)
		assert(fresh ~= nil and fresh.pane == 32 and fresh.title == "omp" and fresh.identityKey == nil, label)
		assert(fresh.disposition == "active" and fresh.navigable and fresh.attention, label .. ": a same-title pane is a new record")
		assert(back.attentionCount == 1, label)
	end
end)

test("a reappearing remote host rebinds a keyed record only through its proven identity key", function()
	for _, reload in ipairs({ false, true }) do
		local label = if reload then "after reload" else "same runtime"
		local keyOne = proofOf(22, "/home/dev/.omp/one.jsonl", "forge")
		local decoyKey = proofOf(66, "/home/dev/.omp/two.jsonl", "forge")
		assert(keyOne ~= nil and decoyKey ~= nil and keyOne ~= decoyKey)
		local state = model.new()
		local first = model.reconcile(state, remote({ panes = { { id = 22, title = "omp", key = keyOne } } }), {}, context(100)).rows[1]
		assert(first.identityKey == keyOne and first.navigable and first.attention, label)
		state = outage(state, reload)
		local offline = model.current(state)
		assert(#offline.rows == 1 and offline.rows[1].workId == first.workId, label)
		assert(offline.rows[1].stale and not offline.rows[1].navigable and offline.reachableCount == 0, label)

		local back = model.reconcile(state, remote({ hostName = "Forge (renamed)", panes = {
			{ id = 66, title = "omp", key = decoyKey }, { id = 55, title = "renamed", key = keyOne },
		} }), {}, context(130))
		assert(#back.rows == 2, label)
		for _, row in ipairs(back.rows) do
			if row.workId == first.workId then
				assert(row.pane == 55 and row.navigable and not row.stale and row.identityKey == keyOne, label)
				assert(row.title == "renamed" and row.hostName == "Forge (renamed)", label .. ": display names follow the host")
				assert(row.attentionRevision == first.attentionRevision, label .. ": rebinding mints no Attention")
			else
				assert(row.pane == 66 and row.identityKey == decoyKey and row.disposition == "active", label)
				assert(row.title == "omp", label .. ": the same-title pane is a separate record")
			end
		end
	end
end)

test("a changed address or provenance is a different conversation that never inherits the old record", function()
	local file = "/home/dev/.omp/one.jsonl"
	for _, change in ipairs({ { host = "forge-moved" }, { principal = "someone-else" } }) do
		for _, reload in ipairs({ false, true }) do
			local label = (change.host or change.principal) .. (if reload then " after reload" else "")
			local original = proofOf(22, file, "forge")
			local moved = proofOf(55, file, change.host or "forge", change.principal)
			assert(original ~= nil and moved ~= nil and moved ~= original, label)
			local state = model.new()
			local first = model.reconcile(state, remote({ panes = { { id = 22, title = "omp", key = original } } }), {}, context(100)).rows[1]
			assert(model.setDisposition(state, first.workId, "reference", 101))
			state = outage(state, reload)

			local back = model.reconcile(state, remote({ panes = { { id = 55, title = "omp", key = moved } } }), {}, context(130))
			assert(#back.rows == 2 and back.attentionCount == 1, label)
			for _, row in ipairs(back.rows) do
				if row.workId == first.workId then
					assert(row.identityKey == original and row.pane == nil and row.retained and row.disposition == "reference", label)
					assert(not row.navigable and not row.attention and row.unavailableReason == "No open pane", label)
				else
					assert(row.identityKey == moved and row.pane == 55 and row.disposition == "active", label)
					assert(row.navigable and row.attention and row.reviewRevision == nil, label)
				end
			end
		end
	end
end)

test("an unproven pending pane neither rebinds a keyed remote record nor spawns a duplicate until proof arrives", function()
	for _, reload in ipairs({ false, true }) do
		local label = if reload then "after reload" else "same runtime"
		local key = proofOf(22, "/home/dev/.omp/one.jsonl", "forge")
		local state = model.new()
		local first = model.reconcile(state, remote({ panes = { { id = 22, title = "omp", key = key } } }), {}, context(100)).rows[1]
		state = outage(state, reload)

		local pending = remote({ pending = { [55] = true }, panes = { { id = 55, title = "omp", key = key } } })
		local held = model.reconcile(state, pending, {}, context(130))
		assert(#held.rows == 1 and held.rows[1].workId == first.workId, label .. ": no duplicate record while proof is pending")
		assert(held.rows[1].pane == 22 and not held.rows[1].navigable, label .. ": the hint is not proof")
		assert(held.reachableCount == 0 and next(held.attentionTargets) == nil, label)

		local proven = model.reconcile(state, remote({ panes = { { id = 55, title = "omp", key = key } } }), {}, context(131))
		assert(#proven.rows == 1 and proven.rows[1].workId == first.workId, label)
		assert(proven.rows[1].pane == 55 and proven.rows[1].navigable and not proven.rows[1].stale, label)
		assert(proven.rows[1].attentionRevision == first.attentionRevision, label)
	end
end)

return true
