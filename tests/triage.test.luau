local model = require("../model")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function context(now, fields)
	local value = { window = "", hostKeys = { [1] = "local" }, connected = { ["local"] = true }, coherent = true, nowUtc = now }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

local function data(mode, alert, problems)
	return {
		ok = true, now = 1, identityReady = true, identities = { [11] = "conversation:11" },
		hosts = { [1] = { key = "local", connected = true, name = "Local" } },
		agents = if mode then { { pane = 11, state = mode, deliveryError = problems and problems.delivery } } else {},
		panes = if mode then { [11] = { host = 1, tab = 10, session = 100, title = "Agent", alert = alert,
			startupError = problems and problems.startup } } else {},
	}
end

local function waiting(now)
	local state = model.new()
	return state, model.reconcile(state, data("waiting_input", false), {}, context(now))
end

local function bucket(state, expected)
	local presentation = model.current(state)
	assert(#presentation.rows == 1 and presentation.rows[1].disposition == expected)
	assert(presentation.attentionCount == (if expected == "active" then 1 else 0))
	assert((presentation.attentionTargets[11] == true) == (expected == "active" and presentation.rows[1].navigable))
	return presentation.rows[1]
end

test("The default retains P0 across downtime, ignores age, and never changes manual triage", function()
	for _, fields in ipairs({ {}, { afterSeconds = 0 }, { afterSeconds = 10800 } }) do
		local state, first = waiting(1000)
		local revision = state.persistenceRevision
		model.reconcile(state, data("waiting_input", false), {}, context(1000000, fields))
		assert(bucket(state, "active").firstSeenUtc == 1000)
		assert(state.persistenceRevision == revision)
		state = model.new(model.snapshot(state))
		model.reconcile(state, data("waiting_input", false), {}, context(2000000, fields))
		bucket(state, "active")
		assert(model.setDisposition(state, "work:" .. tostring(first.rows[1].serial), "finished", 2000000))
		model.reconcile(state, data("waiting_input", false), {}, context(3000000, fields))
		bucket(state, "finished")
		assert(model.setDisposition(state, "work:" .. tostring(first.rows[1].serial), "active", 3000000))
		model.reconcile(state, data("waiting_input", false), {}, context(4000000, fields))
		bucket(state, "active")
		revision = state.persistenceRevision
		model.reconcile(state, data("waiting_input", false), {}, context(9999999, fields))
		assert(state.persistenceRevision == revision)
	end
end)

test("explicit tracking retains closed work without resetting age", function()
	for _, disposition in ipairs({ "reference", "finished" }) do
		local state, first = waiting(1000)
		assert(model.setDisposition(state, first.rows[1].workId, disposition, 11800))
		local saved = model.snapshot(state)
		assert(saved.items[1].retained and saved.items[1].firstSeenUtc == 1000)
		local restored = model.new(saved)
		model.reconcile(restored, data("waiting_input", false), {}, context(11801))
		local closed = model.reconcile(restored, data(nil, false), { { kind = "closed", pane = 11 } }, context(11802))
		assert(#closed.rows == 1 and closed.rows[1].disposition == disposition and closed.rows[1].pane == nil)
		assert(closed.rows[1].retained and closed.rows[1].orphaned and not closed.rows[1].navigable
			and closed.rows[1].firstSeenUtc == 1000)
		local closedSaved = model.snapshot(restored)
		assert(closedSaved.items[1].retained and closedSaved.items[1].noOpenPane
			and closedSaved.items[1].firstSeenUtc == 1000)
		local reloaded = model.current(model.new(closedSaved))
		assert(#reloaded.rows == 1 and reloaded.rows[1].disposition == disposition and reloaded.rows[1].retained
			and reloaded.rows[1].pane == nil and reloaded.rows[1].orphaned and not reloaded.rows[1].navigable
			and reloaded.rows[1].firstSeenUtc == 1000)
	end
	local state, first = waiting(1000)
	model.setDisposition(state, first.rows[1].workId, "finished", 1100)
	state.entries[first.rows[1].serial].retained = false
	assert(model.setDisposition(state, first.rows[1].workId, "finished", 1200))
	assert(model.snapshot(state).items[1].retained)
end)

test("Finished is indefinite and Resume keeps the original age and place", function()
	local state, first = waiting(100)
	local selected = first.rows[1]
	assert(model.setDisposition(state, "work:" .. tostring(selected.serial), "finished", 200))
	assert(not model.setDisposition(state, "work:" .. tostring(selected.serial), "finished", 300))
	model.reconcile(state, data("waiting_input", false), {}, context(1000000))
	assert(bucket(state, "finished").firstSeenUtc == 100)
	assert(model.setDisposition(state, "work:" .. tostring(selected.serial), "active", 1000000))
	local restored = bucket(state, "active")
	assert(restored.queueOrder == selected.queueOrder and restored.firstSeenUtc == 100)
end)

test("ordinary completion never interrupts Finished or changes its stable place", function()
	local state, first = waiting(100)
	local selected = first.rows[1]
	model.reconcile(state, data("waiting_input", true), {}, context(200))
	local updated = bucket(state, "active")
	assert(updated.queueOrder == selected.queueOrder and updated.firstSeenUtc == 200)
	assert(model.setDisposition(state, "work:" .. tostring(selected.serial), "finished", 201))
	model.reconcile(state, data("waiting_input", true), {
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, context(300))
	local promoted = bucket(state, "finished")
	assert(promoted.queueOrder == selected.queueOrder and promoted.firstSeenUtc == 300)
	assert(not model.setDisposition(state, selected.workId, "finished", 301))
	model.reconcile(state, data("waiting_input", true), {
		{ kind = "finished", pane = 11, result = "done", at = 3 },
	}, context(400))
	assert(bucket(state, "finished").firstSeenUtc == 300)
end)

test("Finished retains superseded unread evidence and fresh native blockers never interrupt it", function()
	for _, condition in ipairs({ "delivery", "startup", "waiting" }) do
		local state = model.new()
		local initial = data("idle", false)
		initial.now = 10
		local first = model.reconcile(state, initial, {
			{ kind = "finished", pane = 11, result = "done", at = 10 },
		}, context(100)).rows[1]
		assert(model.setDisposition(state, first.workId, "finished", 101))
		local busy = data("working", false)
		busy.now = 20
		local resumed = model.reconcile(state, busy, {}, context(102)).rows[1]
		assert(resumed.disposition == "finished" and resumed.reviewSuperseded and resumed.reviewRevision == first.reviewRevision)
		assert(not resumed.attention and resumed.queueOrder == first.queueOrder)
		state = model.new(model.snapshot(state))
		local idle = data("idle", false)
		idle.now = 1
		local settled = model.reconcile(state, idle, {}, context(103)).rows[1]
		assert(settled.disposition == "finished" and settled.reviewRevision == first.reviewRevision and settled.reviewSuperseded)
		local completed = model.reconcile(state, idle, {
			{ kind = "finished", pane = 11, result = "done", at = 2 },
		}, context(104)).rows[1]
		assert(completed.disposition == "finished" and not completed.attention and not completed.reviewSuperseded)
		assert(completed.reviewRevision > first.reviewRevision and completed.queueOrder == first.queueOrder)
		busy.now = 3
		model.reconcile(state, busy, {}, context(105))
		local blocked = data(if condition == "waiting" then "waiting_input" else "working", false,
			if condition == "waiting" then nil else { [condition] = "current problem" })
		blocked.now = 4
		local current = model.reconcile(state, blocked, {}, context(106)).rows[1]
		assert(current.disposition == "finished" and not current.attention)
		assert(current.reviewRevision == completed.reviewRevision and current.serial == first.serial)
		assert(current.queueOrder == first.queueOrder and model.next(state) == nil)
		assert(model.setDisposition(state, first.workId, "active", 107, { bringBack = true }))
		local broughtBack = model.current(state).rows[1]
		assert(broughtBack.attention and broughtBack.condition == condition and model.next(state) == 11)
	end
end)

test("manual revisit is superseded by work and explicit Bring back restores it without changing runtime", function()
	local state = model.new()
	local first = model.reconcile(state, data("idle", false), {}, context(100)).rows[1]
	assert(model.setDisposition(state, first.workId, "active", 101, { bringBack = true }))
	local manual = model.current(state).rows[1]
	assert(manual.attention and manual.reviewKind == "manual")
	local busy = data("working", false)
	busy.now = 2
	local resumed = model.reconcile(state, busy, {}, context(102)).rows[1]
	assert(not resumed.attention and resumed.reviewSuperseded and resumed.reviewRevision == manual.reviewRevision)
	local idle = data("idle", false)
	idle.now = 3
	local settled = model.reconcile(state, idle, {}, context(103)).rows[1]
	assert(not settled.attention and settled.reviewRevision == manual.reviewRevision)
	assert(model.setDisposition(state, first.workId, "active", 104, { bringBack = true }))
	local restored = model.current(state).rows[1]
	assert(restored.attention and not restored.reviewSuperseded and restored.nativeState == "idle")
	assert(restored.reviewRevision > manual.reviewRevision and restored.serial == first.serial)
end)

test("reload and rediscovery never wake an unchanged Finished condition", function()
	local state, first = waiting(100)
	assert(model.setDisposition(state, "work:" .. tostring(first.rows[1].serial), "finished", 200))
	state = model.new(model.snapshot(state))
	model.reconcile(state, { ok = false }, {}, context(300, { coherent = false }))
	assert(bucket(state, "finished").stale)
	model.reconcile(state, data("waiting_input", false), {}, context(400))
	assert(bucket(state, "finished").firstSeenUtc == 100)
	model.reconcile(state, data("working", false), {}, context(500))
	assert(model.current(state).attentionCount == 0)
	model.reconcile(state, data("waiting_input", false), {}, context(600))
	bucket(state, "finished")
end)

test("duplicate-route blocker transitions never reactivate Finished", function()
	local state = model.new()
	local live = data("idle", false)
	live.identities[22] = live.identities[11]
	live.panes[22] = { host = 1, tab = 20, session = 100, title = "Duplicate" }
	table.insert(live.agents, { pane = 22, state = "waiting_input" })
	local first = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(first.pane == 11 and first.condition == "waiting" and first.firstSeenUtc == 100)
	assert(model.setDisposition(state, first.workId, "finished", 101))
	local revision = state.persistenceRevision
	live.now = 2
	model.reconcile(state, live, {}, context(200))
	assert(bucket(state, "finished").firstSeenUtc == 100 and state.persistenceRevision == revision)
	live.now, live.agents[2].state = 3, "working"
	local busy = model.reconcile(state, live, {}, context(300))
	assert(#busy.rows == 1 and busy.attentionCount == 0)
	assert(busy.rows[1].nativeState == "working" and busy.rows[1].pane == 11)
	live.now, live.agents[2].state = 4, "waiting_input"
	model.reconcile(state, live, {}, context(400))
	local still = bucket(state, "finished")
	assert(still.serial == first.serial and still.pane == 11)
	assert(model.next(state) == nil)
	revision = state.persistenceRevision
	live.now = 5
	local repeated = model.reconcile(state, live, {}, context(500))
	assert(repeated.count == 1 and repeated.knownCount == 1 and repeated.reachableCount == 0)
	assert(repeated.rows[1].firstSeenUtc == still.firstSeenUtc and repeated.rows[1].queueOrder == still.queueOrder)
	assert(repeated.rows[1].attentionRevision == still.attentionRevision and state.persistenceRevision == revision)
end)

for _, problem in ipairs({ "delivery", "startup" }) do
	test("new " .. problem .. " condition never reactivates Finished work", function()
		local state, first = waiting(100)
		model.setDisposition(state, "work:" .. tostring(first.rows[1].serial), "finished", 100)
		bucket(state, "finished")
		model.reconcile(state, data("waiting_input", false, { [problem] = "problem" }), {}, context(200))
		bucket(state, "finished")
		model.reconcile(state, data("waiting_input", false), {}, context(400))
		model.reconcile(state, data("waiting_input", false, { [problem] = "new detail" }), {}, context(500))
		bucket(state, "finished")
	end)
end

test("schema1 migration retains bucket and age and joins only positive same-scope evidence", function()
	local saved = { schema = 1, records = {
		{ window = "", host = "local", pane = 11, firstSeenUtc = 100, bucket = "backlog" },
		{ window = "another-window", host = "local", pane = 22, firstSeenUtc = 150, bucket = "p0" },
	} }
	local state = model.new(saved)
	assert(model.snapshot(state).schema == 3 and #model.current(state).rows == 2)
	local before = model.current(state).rows[1]
	assert(before.reviewRevision ~= nil and not before.navigable and before.firstSeenUtc == 100)
	local restored = model.reconcile(state, data("waiting_input", false), {}, context(200))
	local joined
	for _, entry in ipairs(restored.rows) do if entry.pane == 11 then joined = entry end end
	assert(joined and joined.navigable and joined.disposition == "finished" and joined.firstSeenUtc == 100)
	assert(joined.identityKey == "conversation:11" and joined.reviewRevision == before.reviewRevision)
	assert(saved.schema == 1 and saved.records[1].host == "local")
	local unknown = model.new({ schema = 1, records = { saved.records[1] } })
	local idle = model.reconcile(unknown, data("idle", false), {}, context(200))
	assert(#idle.rows == 2 and not idle.rows[1].navigable and idle.rows[1].disposition == "finished")
end)

test("legacy opaque locators cannot collide or join another window or host", function()
	local saved = { schema = 1, records = {
		{ window = "a:b", host = "c", pane = "opaque:/pane", firstSeenUtc = 10, bucket = "backlog" },
		{ window = "a", host = "b:c", pane = "opaque:/pane", firstSeenUtc = 20, bucket = "p0" },
	} }
	local state = model.new(saved)
	local retained = model.reconcile(state, data("waiting_input", false), {}, context(30))
	assert(#retained.rows == 3)
	local orphanCount = 0
	for _, entry in ipairs(retained.rows) do if entry.orphaned then orphanCount += 1 end end
	assert(orphanCount == 2)
end)

test("schema3 roundtrip uses one independent array and preserves read and unread state", function()
	local state, first = waiting(100)
	model.reconcile(state, data("waiting_input", true), {}, context(101))
	local saved = model.snapshot(state)
	assert(getmetatable(saved.items) == nil and saved.records == nil and saved.cursors == nil)
	setmetatable(saved.items, { __metatable = false })
	assert(saved.schema == 3)
	local loaded = model.new(saved)
	saved.items[1].disposition = "finished"
	local restored = model.reconcile(loaded, data("waiting_input", false), {}, context(102))
	assert(restored.rows[1].disposition == "active" and restored.rows[1].reviewRevision ~= nil)
	assert(model.visit(loaded, 11, restored.rows[1].reviewRevision, first.rows[1].serial))
	model.reconcile(loaded, data("idle", false), {}, context(103))
	loaded = model.new(model.snapshot(loaded))
	model.reconcile(loaded, data("idle", false), {}, context(104))
	assert(model.current(loaded).attentionCount == 0 and #model.snapshot(loaded).items == 1)
end)

test("invalid schemas records counters and duplicate identities fail without mutating input", function()
	for _, saved in ipairs({ false, {}, { schema = 9, records = {} }, { schema = 1, records = { {} } },
		{ schema = 1, records = { { window = "", host = "local", pane = 11, bucket = "backlog", firstSeenUtc = 0 / 0 } } },
		{ schema = 1, records = { [2] = { window = "", host = "local", pane = 11, bucket = "p0", firstSeenUtc = 10 } } },
		{ schema = 2, records = {}, cursors = {} },
	}) do
		local ok, failure = pcall(model.new, saved)
		assert(not ok and string.find(tostring(failure), "triage"))
	end
	local state = waiting(100)
	local saved = model.snapshot(state)
	local duplicate = table.clone(saved.items[1])
	duplicate.serial = duplicate.serial + 1
	saved.serial = duplicate.serial
	table.insert(saved.items, duplicate)
	assert(not pcall(model.new, saved))
	assert(#saved.items == 2, "failed hydration must not modify the supplied store")
end)

test("last close retains explicit Finished while ordinary quiet work remains live only", function()
	local state, first = waiting(100)
	model.setDisposition(state, "work:" .. tostring(first.rows[1].serial), "finished", 100)
	model.reconcile(state, data(nil, false), {}, context(200))
	assert(#model.current(state).rows == 1 and #model.snapshot(state).items == 1)
	model.reconcile(state, data(nil, false), { { kind = "closed", pane = 11, at = 2 } }, context(300))
	assert(#model.current(state).rows == 1 and model.current(state).rows[1].pane == nil
		and model.current(state).rows[1].disposition == "finished")
	model.reconcile(state, data("waiting_input", false), {}, context(400))
	model.reconcile(state, data("working", false), {}, context(500))
	assert(model.current(state).attentionCount == 0 and #model.current(state).rows == 1)
end)

test("Chrome schema1 Backlog stays one original row before and after delayed inspect", function()
	local paneId, firstSeenUtc = 4002909519943, 1793224308
	local state = model.new({ schema = 1, records = {
		{ window = "", host = "local", pane = paneId, bucket = "backlog", firstSeenUtc = firstSeenUtc },
	} })
	local live = data("waiting_input", false)
	live.agents[1].pane = paneId
	live.panes[paneId], live.panes[11] = live.panes[11], nil
	live.identityReady, live.identities = false, {}
	local pending = model.reconcile(state, live, {}, context(firstSeenUtc + 100))
	assert(#pending.rows == 1 and pending.attentionCount == 0 and pending.rows[1].disposition == "finished")
	assert(pending.rows[1].firstSeenUtc == firstSeenUtc)
	local serial, order = pending.rows[1].serial, pending.rows[1].queueOrder
	live.identityReady, live.identities = true, { [paneId] = "chrome-conversation" }
	local verified = model.reconcile(state, live, {}, context(firstSeenUtc + 101))
	assert(#verified.rows == 1 and verified.rows[1].serial == serial and verified.rows[1].queueOrder == order)
	assert(verified.rows[1].disposition == "finished" and verified.rows[1].firstSeenUtc == firstSeenUtc)
	assert(verified.rows[1].navigable and verified.rows[1].identityKey == "chrome-conversation")
end)

test("schema2 pending rows and read cursors reserve their pane until identity becomes available", function()
	for _, reviewed in ipairs({ false, true }) do
		local state = model.new()
		local first = model.reconcile(state, data("idle", true), {}, context(100)).rows[1]
		if reviewed then assert(model.visit(state, 11, first.reviewRevision, first.serial))
		else model.setDisposition(state, "work:" .. tostring(first.serial), "finished", 100) end
		state = model.new(model.snapshot(state))
		local live = data("idle", true)
		live.identityReady, live.identities = false, {}
		for now = 101, 103 do
			local pending = model.reconcile(state, live, {}, context(now))
			assert(#pending.rows == 1)
			assert(pending.attentionCount == 0)
			if not reviewed then
				assert(pending.rows[1].serial == first.serial and pending.rows[1].disposition == "finished")
				assert(not pending.rows[1].navigable and pending.rows[1].firstSeenUtc == 100)
			end
		end
		live.identityReady, live.identities = true, { [11] = "conversation:11" }
		local verified = model.reconcile(state, live, {}, context(104))
		assert(#verified.rows == 1 and verified.attentionCount == 0)
		if not reviewed then assert(verified.rows[1].serial == first.serial and verified.rows[1].disposition == "finished") end
	end
end)

test("literal evidence deferred for identity proof survives another reload and transfers only to the proven identity", function()
	for _, replacement in ipairs({ false, true }) do
		local state = model.new()
		local first = model.reconcile(state, data("idle", true), {}, context(100)).rows[1]
		assert(model.visit(state, 11, first.reviewRevision, first.serial))
		state = model.new(model.snapshot(state))
		local live = data("idle", false)
		live.identityReady, live.identities = false, {}
		local deferred = model.reconcile(state, live, {
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 1 },
			{ kind = "finished", pane = 11, result = "done", at = 2 },
		}, context(101))
		assert(#deferred.rows == 1 and not deferred.rows[1].navigable)
		state = model.new(model.snapshot(state))
		live.identityReady = true
		live.identities = { [11] = if replacement then "replacement" else "conversation:11" }
		local resolved = model.reconcile(state, live, {}, context(102))
		assert(#resolved.rows == 1 and resolved.rows[1].reviewRevision ~= nil and resolved.rows[1].navigable)
		assert(resolved.rows[1].identityKey == live.identities[11])
		assert((resolved.rows[1].serial == first.serial) == not replacement)
		assert(resolved.rows[1].firstSeenUtc == 101)
	end
end)

test("schema3 inventories quiet work and keeps Finished work finished through new direct episodes", function()
	local state = model.new()
	local quiet = model.reconcile(state, data("idle", false), {}, context(100))
	assert(quiet.allCount == 1 and quiet.attentionCount == 0 and quiet.rows[1].nativeState == "idle")
	local id = quiet.rows[1].workId
	assert(model.setDisposition(state, id, "finished", 101))
	model.reconcile(state, data("idle", true), { { kind = "finished", pane = 11, result = "done", at = 2 } }, context(150))
	assert(model.current(state).rows[1].disposition == "finished" and model.current(state).attentionCount == 0)
	model.reconcile(state, data("idle", true), {}, context(200))
	assert(model.current(state).rows[1].disposition == "finished" and model.current(state).attentionCount == 0)
	state = model.new(model.snapshot(state))
	model.reconcile(state, data("waiting_input", false), {}, context(203))
	assert(model.current(state).attentionCount == 0, "startup discovery cannot prove a fresh blocker")
	model.reconcile(state, data("working", false), {}, context(204))
	model.reconcile(state, data("waiting_input", false), {}, context(205))
	assert(model.current(state).rows[1].disposition == "finished" and model.current(state).attentionCount == 0)
	assert(model.setDisposition(state, id, "active", 206, { bringBack = true }))
	assert(model.current(state).rows[1].disposition == "active" and model.current(state).attentionCount == 1)
end)

test("explicit retention and ranks survive closure without creating a navigation target", function()
	local state, first = waiting(100)
	local id = first.rows[1].workId
	assert(model.setPriority(state, id, 0))
	assert(model.setDisposition(state, id, "reference", 101))
	model.reconcile(state, data(nil, false), { { kind = "closed", pane = 11 } }, context(102))
	local retained = model.current(state).rows[1]
	assert(retained.workId == id and retained.pane == nil and retained.retained and retained.priority == 0)
	assert(not retained.attention and not retained.navigable and retained.unavailableReason == "No open pane")
	state = model.new(model.snapshot(state))
	assert(model.setDisposition(state, id, "active", 103))
	assert(model.current(state).attentionCount == 0, "resume is not execution or an invented update")
	assert(model.removeRetained(state, id) and #model.current(state).rows == 0)
end)

test("rank changes wait for the next Next round and never reorder All work", function()
	local state = model.new()
	local live = data("waiting_input", false)
	live.agents[2] = { pane = 22, state = "waiting_input" }
	live.panes[22] = { host = 1, tab = 20, session = 100, title = "Second" }
	live.identities[22], live.tabOrder, live.sessionOrder = "conversation:22", { 10, 20 }, { 100 }
	local initial = model.reconcile(state, live, {}, context(100))
	assert(model.next(state) == 11)
	model.skip(state, 11)
	assert(model.setPriority(state, initial.rows[1].workId, 0))
	assert(model.next(state) == 22, "current round survivors retain their place")
	model.skip(state, 22)
	assert(model.next(state) == 11)
	assert(model.current(state).rows[1].pane == 11 and model.current(state).rows[2].pane == 22)
end)

test("source backfill and new human text preserve explicit tracking until Resume", function()
	for _, disposition in ipairs({ "reference", "finished" }) do
		local state, live = model.new(), data("idle", true)
		local first = model.reconcile(state, live, {}, context(100)).rows[1]
		assert(model.visit(state, 11, first.reviewRevision, first.serial))
		live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
		local fact = { key = "conversation:11", path = "/exact/session", status = "ready", capturedAtUtc = 101,
			sessionId = "header-one", revision = "r1", selection = "disk-replayed", complete = true,
			schemaVersion = 3, writerVersions = { "18.14.0" }, coverage = {}, questions = {},
			questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 },
			lastFinal = { id = "final-one", atUtc = 90, timeKind = "completed", text = "Done" },
			lastHuman = { id = "human-one", provenance = "user", text = "Build it" } }
		live.sourceFacts = { [fact.key] = fact }
		local baseline = model.reconcile(state, live, {}, context(101)).rows[1]
		assert(baseline.source.sessionId == "header-one" and not baseline.attention and baseline.reviewRevision == nil)
		assert(model.setDisposition(state, baseline.workId, disposition, 102))
		assert(model.setPriority(state, baseline.workId, 2))
		state = model.new(model.snapshot(state))
		fact = table.clone(fact)
		fact.revision, fact.capturedAtUtc = "r2", 103
		fact.lastHuman = { id = "human-two", provenance = "user", text = "Implement a separate export feature", atUtc = 103 }
		live.sourceFacts[fact.key], live.agents[1].state = fact, "working"
		local kept = model.reconcile(state, live, {}, context(103)).rows[1]
		assert(kept.disposition == disposition and kept.priority == 2 and not kept.attention)
		assert(kept.source.lastHuman.id == "human-two" and kept.nativeState == "working")
		assert(model.setDisposition(state, kept.workId, "active", 104))
		assert(model.current(state).rows[1].disposition == "active" and model.current(state).rows[1].priority == 2)
	end
end)

test("multiple bindings count one conversation and close independently", function()
	local state = model.new()
	local live = data("waiting_input", false)
	live.agents[2] = { pane = 22, state = "working" }
	live.panes[22] = { host = 1, tab = 20, session = 100, title = "Duplicate" }
	live.identities[22] = live.identities[11]
	local first = model.reconcile(state, live, {}, context(100))
	assert(first.allCount == 1 and first.attentionCount == 1 and state.byPane[11] == state.byPane[22])
	local id = first.rows[1].workId
	state = model.new(model.snapshot(state))
	model.reconcile(state, live, {}, context(100))
	assert(state.byPane[11] == state.byPane[22], "all proven bindings restore together")
	local interrupted = model.reconcile(state, { ok = false }, { { kind = "closed", pane = 11 } }, context(100))
	assert(interrupted.allCount == 1 and interrupted.rows[1].workId == id and not interrupted.rows[1].navigable,
		"closing one binding during a failed inventory cannot erase the other")
	live.panes[11], live.agents[1] = nil, live.agents[2]
	live.agents[2], live.identities[11] = nil, nil
	local surviving = model.reconcile(state, live, { { kind = "closed", pane = 11 } }, context(101))
	assert(surviving.allCount == 1 and surviving.rows[1].workId == id and surviving.rows[1].pane == 22)
	assert(model.setDisposition(state, id, "finished", 102))
	live.panes, live.agents, live.identities = {}, {}, {}
	local closed = model.reconcile(state, live, { { kind = "closed", pane = 22 } }, context(103))
	assert(closed.allCount == 1 and closed.rows[1].pane == nil and closed.reachableCount == 0)
end)

test("changed header cannot inherit old explicit intent or navigate without matching header proof", function()
	local state = model.new()
	local live = data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "old-header", status = "ready",
		capturedAtUtc = 100, revision = "old", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	live.sourceFacts = { ["conversation:11"] = fact }
	local first = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(model.setDisposition(state, first.workId, "reference", 101))
	assert(model.setPriority(state, first.workId, 0))
	state = model.new(model.snapshot(state))
	live.sourceFacts = {}
	local unproven = model.reconcile(state, live, {}, context(102)).rows[1]
	assert(not unproven.navigable and unproven.workId == first.workId)
	fact = table.clone(fact)
	fact.sessionId, fact.revision, fact.capturedAtUtc = "new-header", "new", 103
	live.sourceFacts = { ["conversation:11"] = fact }
	local replacement = model.reconcile(state, live, {}, context(103))
	assert(replacement.allCount == 2 and replacement.attentionCount == 0)
	local old, new
	for _, item in ipairs(replacement.rows) do
		if item.workId == first.workId then old = item else new = item end
	end
	assert(old.pane == nil and old.disposition == "reference" and not old.navigable)
	assert(old.sourceObservation.status == "header-mismatch" and new.sourceObservation.status == "ready")
	assert(new.pane == 11 and new.disposition == "active" and new.priority == nil and new.reviewRevision == nil)
	local roundtrip = model.new(model.snapshot(state))
	assert(model.current(roundtrip).allCount == 2, "composite header identities survive schema3 reload")
end)

test("recorded question outcomes remain independent of runtime and review acknowledgment", function()
	local state, live = model.new(), data("working", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "questions", status = "ready",
		capturedAtUtc = 100, revision = "q1", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 3, included = 3, omitted = 0 },
		questions = { { id = "a", status = "answered", answeredAtUtc = 90 }, { id = "b", status = "cancelled", cancelledAtUtc = 91 },
			{ id = "c", status = "open", askedAtUtc = 80 } } }
	live.sourceFacts = { [fact.key] = fact }
	local first = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(first.nativeState == "working" and not first.attention and first.reviewRevision == nil and first.reviewSuperseded)
	assert(not model.visit(state, 11, nil, first.serial), "Open never answers the remaining question")
	assert(model.setDisposition(state, first.workId, "finished", 102))
	assert(model.current(state).attentionCount == 0)
	assert(model.setDisposition(state, first.workId, "active", 103, { bringBack = true }))
	local broughtBack = model.current(state).rows[1]
	assert(model.visit(state, 11, broughtBack.reviewRevision, broughtBack.serial))
	assert(not model.current(state).rows[1].attention and model.current(state).rows[1].source.questions[3].status == "open")
	fact = table.clone(fact)
	fact.revision, fact.capturedAtUtc = "q2", 104
	fact.questions = { { id = "a", status = "answered" }, { id = "b", status = "cancelled" },
		{ id = "c", status = "answered", resolvedAtUtc = 104, answerProvenance = "automatic", timedOut = true } }
	live.sourceFacts[fact.key] = fact
	local executing = model.reconcile(state, live, {}, context(104)).rows[1]
	assert(executing.nativeState == "working" and not executing.attention and executing.reviewRevision == nil)
	assert(executing.source.questions[3].answeredAtUtc == nil and executing.source.lastHuman == nil,
		"automatic timeout resolution is not human activity")
end)

test("source replay cannot reset question supersession through baseline repeats bounded gaps or old history", function()
	for _, mode in ipairs({ "baseline", "repeat", "bounded", "gap", "history" }) do
		local state, live = model.new(), data("idle", false)
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "question-authority",
			status = "ready", capturedAtUtc = 100, revision = "old", schemaVersion = 3,
			writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "old", status = "open", askedAtUtc = 90 } } }
		if mode ~= "baseline" then
			live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
			live.sourceFacts = { [fact.key] = fact }
		end
		local original = model.reconcile(state, live, {
			{ kind = "finished", pane = 11, result = "done", at = 1 },
		}, context(100)).rows[1]
		live.now, live.agents[1].state = 2, "working"
		model.reconcile(state, live, {}, context(101))
		live.now, live.agents[1].state = 3, "idle"
		assert(not model.reconcile(state, live, {}, context(102)).rows[1].attention)
		live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		if mode == "gap" then
			live.sourceFacts[fact.key] = { key = fact.key, path = fact.path, status = "missing", capturedAtUtc = 104 }
			model.reconcile(state, live, {}, context(104))
		end
		local replay = table.clone(fact)
		if mode ~= "repeat" then replay.revision, replay.capturedAtUtc = mode, 105 end
		if mode == "baseline" or mode == "gap" or mode == "bounded" then
			replay.questions = { fact.questions[1], { id = "unqualified", status = "open", askedAtUtc = 95 } }
			replay.questionCoverage = { status = if mode == "bounded" then "bounded" else "complete",
				knownTotal = if mode == "bounded" then 3 else 2, included = 2, omitted = if mode == "bounded" then 1 else 0 }
		elseif mode == "history" then
			replay.questions = { { id = "old", status = "open", askedAtUtc = 105 } }
		end
		live.sourceFacts = { [fact.key] = replay }
		local quiet = model.reconcile(state, live, {}, context(105)).rows[1]
		assert(quiet.disposition == "active" and not quiet.attention and not quiet.sourceQuestionCurrent)
		assert(quiet.reviewSuperseded and quiet.reviewRevision == original.reviewRevision and quiet.nativeState == "idle")
		local saved = model.snapshot(state)
		assert(saved.items[1].sourceQuestionSuperseded == true)
		state = model.new(saved)
		local repeated = model.reconcile(state, live, {}, context(106)).rows[1]
		assert(not repeated.sourceQuestionCurrent and repeated.disposition == "active" and repeated.attentionRevision == quiet.attentionRevision)
		-- Establish complete coverage without treating already-seen questions as a fresh arrival.
		replay = table.clone(replay)
		replay.revision, replay.capturedAtUtc = "complete-established", 107
		replay.questionCoverage = { status = "complete", knownTotal = #replay.questions, included = #replay.questions, omitted = 0 }
		live.sourceFacts[fact.key] = replay
		assert(not model.reconcile(state, live, {}, context(107)).rows[1].sourceQuestionCurrent, mode)
		local fresh = table.clone(replay)
		fresh.revision, fresh.capturedAtUtc, fresh.questions = "new-qualified", 108, table.clone(replay.questions)
		table.insert(fresh.questions, { id = "new-qualified", status = "open", askedAtUtc = 108 })
		fresh.questionCoverage = { status = "complete", knownTotal = #fresh.questions, included = #fresh.questions, omitted = 0 }
		live.sourceFacts[fact.key] = fresh
		local current = model.reconcile(state, live, {}, context(108)).rows[1]
		assert(current.sourceQuestionCurrent and current.attention and current.disposition == "active")
		assert(current.reviewSuperseded and current.reviewRevision == original.reviewRevision and current.nativeState == "idle")
	end
end)

test("schema2 pending records and quiet cursors migrate once without inventing priority", function()
	local function legacy(serial, paneId, bucketName)
		return { serial = serial, pane = paneId, window = "", hostKey = "local", host = 1,
			tab = paneId, session = 100, title = "Legacy", sessionName = "Workspace", hostName = "Local",
			localHost = true, identityKey = "legacy:" .. tostring(paneId), firstSeenUtc = 50,
			bucket = bucketName, queueOrder = serial, attentionRevision = 5, turn = 2,
			nativeState = "idle", waiting = false, delivery = false, startup = false, alert = false }
	end
	local pending = legacy(5, 11, "backlog")
	pending.reviewRevision, pending.reviewKind, pending.finishedTurn, pending.finishedResult = 5, "done", 2, "done"
	local quiet = legacy(7, 22, "p0")
	quiet.finishedTurn, quiet.finishedResult = 2, "done"
	local input = { schema = 2, records = { pending }, cursors = { quiet }, serial = 7, queueOrder = 7, attentionRevision = 5 }
	local state = model.new(input)
	local saved = model.snapshot(state)
	assert(saved.schema == 3 and #saved.items == 2 and saved.records == nil and saved.cursors == nil)
	assert(saved.items[1].serial == 5 and saved.items[1].disposition == "finished" and saved.items[1].retained)
	assert(saved.items[2].serial == 7 and saved.items[2].disposition == "active" and saved.items[2].reviewRevision == nil)
	assert(saved.items[1].priority == nil and saved.items[2].priority == nil)
	assert(model.current(state).allCount == 2 and model.current(state).attentionCount == 0)
	local loaded = model.new(saved)
	assert(loaded.persistenceRevision == 0 and model.snapshot(loaded).attentionRevision == 5)
	assert(input.schema == 2 and input.records[1].bucket == "backlog" and input.cursors[1].finishedResult == "done")
end)

test("source availability observations retain last good evidence and do not persist observation ticks", function()
	local state = model.new()
	local live = data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local good = { key = "conversation:11", path = "/exact/session", sessionId = "known", status = "ready",
		capturedAtUtc = 100, revision = "one", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	live.sourceFacts = { ["conversation:11"] = good }
	local first = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(first.sourceObservation.status == "ready" and first.sourceObservation.capturedAtUtc == 100)
	live.sourceFacts["conversation:11"] = { key = good.key, path = good.path, status = "missing", capturedAtUtc = 101 }
	local missing = model.reconcile(state, live, {}, context(101)).rows[1]
	assert(missing.source.status == "ready" and missing.source.capturedAtUtc == 100)
	assert(missing.sourceObservation.status == "missing" and missing.sourceObservation.capturedAtUtc == 101)
	local revision = state.persistenceRevision
	live.sourceFacts["conversation:11"] = { key = good.key, path = good.path, status = "missing", capturedAtUtc = 102 }
	local recheck = model.reconcile(state, live, {}, context(102)).rows[1]
	assert(state.persistenceRevision == revision, "observation-only ticks do not rewrite the canonical store")
	assert(recheck == missing and recheck.sourceObservation.capturedAtUtc == 101,
		"a re-check that finds the same availability keeps the row (no repaint) and the time it was first seen")
	assert(model.snapshot(state).items[1].sourceObservation == nil and model.snapshot(state).items[1].source.revision == "one")
	live.sourceFacts["conversation:11"] = { key = good.key, path = "/wrong/source", status = "missing", capturedAtUtc = 103 }
	local foreign = model.reconcile(state, live, {}, context(103)).rows[1].sourceObservation
	assert(foreign.capturedAtUtc == 101 and foreign.path == good.path, "a different locator cannot replace qualified availability")
end)

test("source read failures fence navigation without suppressing fresh native blockers", function()
	for _, status in ipairs({ "missing", "malformed", "unsupported" }) do
		for _, condition in ipairs({ "waiting", "delivery", "startup" }) do
			local state = model.new()
			local live = data("idle", false)
			live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
			local good = { key = "conversation:11", path = "/exact/session", sessionId = "native-independent", status = "ready",
				capturedAtUtc = 100, revision = "one", schemaVersion = 3, writerVersions = { "18.14.0" },
				selection = "disk-replayed", complete = true, coverage = {}, questions = {},
				questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
			live.sourceFacts = { ["conversation:11"] = good }
			local initial = model.reconcile(state, live, {}, context(100)).rows[1]
			assert(initial.disposition == "active")
			live.sourceFacts[good.key] = { key = good.key, path = good.path, status = status, capturedAtUtc = 101 }
			model.reconcile(state, live, {}, context(101))
			if condition == "waiting" then live.agents[1].state = "waiting_input"
			elseif condition == "delivery" then live.agents[1].deliveryError = "not delivered"
			else live.panes[11].startupError = "not started" end
			local events = if condition == "waiting" then { { kind = "state", pane = 11, old = "idle", new = "waiting_input", at = 2 } } else {}
			local current = model.reconcile(state, live, events, context(102)).rows[1]
			assert(current.source.sessionId == good.sessionId and current.source.capturedAtUtc == 100)
			assert(current.sourceObservation.status == status and not current.navigable and not current.stale)
			assert(current.attention and current.disposition == "active", "a fresh native blocker raises attention despite source failure")
			if condition == "waiting" then assert(current.nativeState == "waiting_input" and current.reason == "Needs input")
			elseif condition == "delivery" then assert(current.reason == "Prompt not delivered")
			else assert(current.reason == "Agent startup problem") end
			assert(model.snapshot(state).items[1].deferredWaitingUtc == nil, "source failure must not defer native callbacks")
		end
	end
end)

test("repeated partial source replay preserves a flat last-known question through schema3 reload", function()
	local state = model.new()
	local live = data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local complete = { key = "conversation:11", path = "/exact/session", sessionId = "partial-ledger", status = "ready",
		capturedAtUtc = 100, revision = "complete", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		lastFinal = { id = "final", atUtc = 80, timeKind = "completed", text = "Choose deployment target" },
		questions = { { id = "original-open", status = "open", askedAtUtc = 90 } } }
	live.sourceFacts = { ["conversation:11"] = complete }
	assert(model.reconcile(state, live, {}, context(100)).rows[1].attention)
	for index = 1, 2 do
		local partial = table.clone(complete)
		partial.status, partial.complete, partial.revision, partial.capturedAtUtc =
			"partial", false, "partial-" .. tostring(index), 100 + index
		partial.questionCoverage = { status = "unknown", knownTotal = 0, included = 0, omitted = 0 }
		partial.lastFinal, partial.questions = nil, {}
		live.sourceFacts[complete.key] = partial
		assert(model.reconcile(state, live, {}, context(100 + index)).rows[1].reason == "Last recorded question unresolved")
	end
	local saved = model.snapshot(state)
	assert(saved.items[1].source.lastKnown.lastFinal.id == "final")
	assert(saved.items[1].source.lastKnown.questions[1].id == "original-open" and saved.items[1].source.lastKnown.lastKnown == nil)
	assert(saved.items[1].source.capturedAtUtc == 102 and saved.items[1].source.lastKnown.provenance.lastFinal.capturedAtUtc == 100)
	assert(saved.items[1].source.lastKnown.provenance.questions["original-open"].capturedAtUtc == 100
		and saved.items[1].source.lastKnown.provenance.questions["original-open"].complete == true)
	state = model.new(saved)
	assert(model.current(state).rows[1].attention and model.current(state).rows[1].reason == "Last recorded question unresolved")
	local uncertain = table.clone(live.sourceFacts[complete.key])
	uncertain.revision, uncertain.capturedAtUtc = "uncertain-question", 103
	uncertain.questionCoverage = { status = "unknown", knownTotal = 1, included = 1, omitted = 0 }
	uncertain.questions = { { id = "original-open", status = "unknown" } }
	live.sourceFacts[complete.key] = uncertain
	assert(model.reconcile(state, live, {}, context(103)).rows[1].attention, "unknown partial status is not positive resolution")
	local answered = table.clone(live.sourceFacts[complete.key])
	answered.revision, answered.capturedAtUtc = "positive-answer", 104
	answered.questions = { { id = "original-open", status = "answered", answeredAtUtc = 104 } }
	live.sourceFacts[complete.key] = answered
	local resolved = model.reconcile(state, live, {}, context(104)).rows[1]
	assert(not resolved.attention, "positive per-question evidence can settle the retained attempt even during partial replay")
	assert(resolved.source.lastKnown.provenance.questions["original-open"].capturedAtUtc == 104
		and resolved.source.lastKnown.provenance.questions["original-open"].complete == false)
	local staleOpen = table.clone(answered)
	staleOpen.revision, staleOpen.capturedAtUtc = "partial-open", 105
	staleOpen.questions = { { id = "original-open", status = "open", askedAtUtc = 90 } }
	live.sourceFacts[complete.key] = staleOpen
	assert(not model.reconcile(state, live, {}, context(105)).rows[1].attention, "partial replay cannot reopen an answered attempt")
	assert(not model.current(model.new(model.snapshot(state))).rows[1].attention, "hydration uses the same qualified ledger")
end)

test("complete replay with bounded questions preserves omitted known attempts until positive resolution", function()
	for _, omission in ipairs({ "bounded", "unknown", "absent" }) do
		local state = model.new()
		local live = data("idle", false)
		live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "bounded", status = "ready",
			capturedAtUtc = 100, revision = "all-questions", schemaVersion = 3,
			writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "still-open", status = "open", askedAtUtc = 90, text = "Which target?" } } }
		live.sourceFacts = { [fact.key] = fact }
		assert(model.reconcile(state, live, {}, context(100)).rows[1].attention)
		local bounded = table.clone(fact)
		bounded.revision, bounded.capturedAtUtc, bounded.questions = "bounded-questions", 101, {}
		bounded.questionCoverage = if omission == "absent" then nil
			else { status = omission, knownTotal = 1, included = 0, omitted = 1 }
		live.sourceFacts[fact.key] = bounded
		local omitted = model.reconcile(state, live, {}, context(101)).rows[1]
		assert(omitted.source.complete and omitted.attention and omitted.reason == "Last recorded question unresolved")
		state = model.new(model.snapshot(state))
		assert(model.current(state).rows[1].attention)
		local answered = table.clone(bounded)
		answered.revision, answered.capturedAtUtc = "bounded-answer", 102
		answered.questionCoverage = if omission == "absent" then nil
			else { status = omission, knownTotal = 1, included = 1, omitted = 0 }
		answered.questions = { { id = "still-open", status = "answered", answeredAtUtc = 102 } }
		live.sourceFacts[fact.key] = answered
		assert(not model.reconcile(state, live, {}, context(102)).rows[1].attention)
		local allCovered = table.clone(answered)
		allCovered.revision, allCovered.capturedAtUtc, allCovered.questions = "complete-ledger", 103, {}
		allCovered.questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 }
		live.sourceFacts[fact.key] = allCovered
		assert(model.reconcile(state, live, {}, context(103)).rows[1].source.lastKnown == nil,
			"only complete question coverage can retire absent retained question state")
	end
end)

test("retained question text is capped at32 while compact identities still resolve omitted attempts", function()
	local state = model.new()
	local live = data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "bounded-payload", status = "ready",
		capturedAtUtc = 100, revision = "first", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 32, included = 32, omitted = 0 } }
	for index = 1, 32 do
		fact.questions[index] = { id = "question-" .. tostring(index), status = "open", askedAtUtc = 90, text = "Original question " .. tostring(index) }
	end
	live.sourceFacts = { [fact.key] = fact }
	model.reconcile(state, live, {}, context(100))
	local partial = table.clone(fact)
	partial.status, partial.complete, partial.revision, partial.capturedAtUtc, partial.questions =
		"partial", false, "second", 101, {}
	partial.questionCoverage = { status = "unknown", knownTotal = 32, included = 32, omitted = 0 }
	for index = 33, 64 do
		table.insert(partial.questions, { id = "question-" .. tostring(index), status = "open", askedAtUtc = 101, text = "New question " .. tostring(index) })
	end
	live.sourceFacts[fact.key] = partial
	local current = model.reconcile(state, live, {}, context(101)).rows[1]
	local known = current.source.lastKnown
	assert(#known.questions == 32 and #known.omittedQuestions == 32 and known.questionsKnown == 64)
	assert(known.questionsIncluded == 32 and known.questionsOmitted == 32 and known.openQuestionsOmitted == 32)
	assert(known.questions[1].id == "question-33" and known.omittedQuestions[1].id == "question-1")
	assert(known.omittedQuestions[1].text == nil and known.provenance.questions["question-1"].capturedAtUtc == 100)
	state = model.new(model.snapshot(state))
	assert(model.current(state).rows[1].attention)
	local answered = table.clone(partial)
	answered.status, answered.complete, answered.revision, answered.capturedAtUtc =
		"ready", true, "omitted-answer", 102
	answered.questions = {}
	answered.questionOutcomes = { { id = "question-1", status = "answered", answeredAtUtc = 102 },
		{ id = "question-2", status = "answered", resolvedAtUtc = 102, answerProvenance = "automatic", timedOut = true } }
	answered.questionCoverage = { status = "bounded", knownTotal = 64, included = 0, omitted = 64 }
	live.sourceFacts[fact.key] = answered
	known = model.reconcile(state, live, {}, context(102)).rows[1].source.lastKnown
	assert(#known.questions == 32 and known.questionsKnown == 64 and known.openQuestionsOmitted == 30)
	assert(known.questions[1].id == "question-33", "retained order survives payload/metadata partitioning")
	assert(known.omittedQuestions[1].id == "question-1" and known.omittedQuestions[1].status == "answered")
	assert(known.omittedQuestions[1].askedAtUtc == 90 and known.omittedQuestions[1].answeredAtUtc == 102,
		"positive status updates retain independently evidenced question and answer clocks")
	assert(known.provenance.questions["question-1"].capturedAtUtc == 102)
	assert(known.omittedQuestions[2].resolvedAtUtc == 102 and known.omittedQuestions[2].answerProvenance == "automatic"
		and known.omittedQuestions[2].timedOut and known.omittedQuestions[2].answeredAtUtc == nil)
end)

test("only fully qualified complete selected history retires an absent attempt", function()
	for _, coverage in ipairs({ "complete", "bounded", "unknown", "unqualified" }) do
		local state, live = model.new(), data("idle", false)
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "absence", status = "ready",
			capturedAtUtc = 100, revision = "open", schemaVersion = 3, writerVersions = { "18.14.0" },
			selection = "disk-replayed", selectedLeafId = "question-branch", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "original", status = "open", askedAtUtc = 90, text = "Still needs an answer" } } }
		live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		live.sourceFacts = { [fact.key] = fact }
		assert(model.reconcile(state, live, {}, context(100)).rows[1].attention)
		fact = table.clone(fact)
		fact.revision, fact.capturedAtUtc, fact.questions, fact.selectedLeafId = "empty", 101, {}, "other-branch"
		local fullyCovered = coverage == "complete" or coverage == "unqualified"
		fact.questionCoverage = { status = if fullyCovered then "complete" else coverage, knownTotal = if fullyCovered then 0 else 1,
			included = 0, omitted = if fullyCovered then 0 else 1 }
		if coverage == "unqualified" then
			fact.status, fact.complete, fact.coverage = "partial", false, { fields = { clock = "supported", questions = "unknown" } }
		end
		live.sourceFacts[fact.key] = fact
		local current = model.reconcile(state, live, {}, context(101)).rows[1]
		assert(current.attention == (coverage ~= "complete"), coverage)
		if coverage == "complete" then
			assert(current.source.lastKnown == nil and #current.source.questions == 0,
				"branch replacement removes the absent attempt rather than inventing an answer")
		else
			assert(current.source.lastKnown.questions[1].status == "open"
				and current.source.lastKnown.questions[1].text == "Still needs an answer")
		end
		assert(model.current(model.new(model.snapshot(state))).rows[1].attention == (coverage ~= "complete"), coverage)
	end
end)

test("compact positive outcomes settle retained attempts without replacing original facts", function()
	for _, status in ipairs({ "answered", "cancelled", "failed" }) do
		local state, live = model.new(), data("idle", false)
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "compact", status = "ready",
			capturedAtUtc = 100, revision = "open", schemaVersion = 3, writerVersions = { "18.14.0" },
			selection = "disk-replayed", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "original", status = "open", askedAtUtc = 90, text = "Keep this original question" } } }
		live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		live.sourceFacts = { [fact.key] = fact }
		assert(model.reconcile(state, live, {}, context(100)).rows[1].attention)
		local resolved = table.clone(fact)
		resolved.revision, resolved.capturedAtUtc, resolved.questions = "resolved", 102, {}
		for index = 1, 32 do table.insert(resolved.questions, { id = "settled-" .. tostring(index), status = "answered" }) end
		resolved.questionCoverage = { status = "bounded", knownTotal = 34, included = 32, omitted = 2 }
		resolved.questionOutcomes = { { id = "original", status = status, resolvedAtUtc = 101, answerProvenance = "automatic", timedOut = true },
			{ id = "never-observed", status = "answered", answeredAtUtc = 101 } }
		live.sourceFacts[fact.key] = resolved
		local row = model.reconcile(state, live, {}, context(102)).rows[1]
		assert(not row.attention)
		local ledger = row.source.lastKnown
		local found
		for _, records in ipairs({ ledger.questions, ledger.omittedQuestions }) do
			for _, question in ipairs(records) do
				assert(question.id ~= "never-observed", "outcomes do not create retained obligations")
				if question.id == "original" then found = question end
			end
		end
		assert(found and found.status == status and found.askedAtUtc == 90 and found.resolvedAtUtc == 101
			and found.text == "Keep this original question")
		assert(ledger.provenance.questions.original.capturedAtUtc == 102)
		assert(not model.current(model.new(model.snapshot(state))).rows[1].attention)
	end
	-- With room in the excerpt budget, an outcome must preserve the original text.
	for _, coverage in ipairs({ "complete", "bounded", "unknown", "unqualified" }) do
		local state, live = model.new(), data("idle", false)
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "text", status = "ready",
			capturedAtUtc = 100, revision = "open", schemaVersion = 3, writerVersions = { "18.14.0" },
			selection = "disk-replayed", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "original", status = "open", askedAtUtc = 90, text = "Original text" } } }
		live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		live.sourceFacts = { [fact.key] = fact }
		model.reconcile(state, live, {}, context(100))
		fact = table.clone(fact)
		fact.revision, fact.capturedAtUtc, fact.questions = "answered", 101, {}
		fact.selectedLeafId = "answer-branch"
		fact.questionCoverage = { status = "bounded", knownTotal = 1, included = 0, omitted = 1 }
		fact.questionOutcomes = { { id = "original", status = "answered", answeredAtUtc = 101 } }
		live.sourceFacts[fact.key] = fact
		local resolved = model.reconcile(state, live, {}, context(101)).rows[1]
		assert(resolved.source.lastKnown.questions[1].text == "Original text" and not resolved.attention)
		fact = table.clone(fact)
		fact.revision, fact.capturedAtUtc, fact.questionOutcomes = "replayed-open", 102, nil
		fact.selectedLeafId = "question-branch"
		fact.questions = { { id = "original", status = "open", askedAtUtc = 90 } }
		fact.questionCoverage = { status = if coverage == "unqualified" then "complete" else coverage,
			knownTotal = 1, included = 1, omitted = 0 }
		if coverage == "unqualified" then
			fact.status, fact.complete, fact.coverage = "partial", false, { fields = { clock = "supported", questions = "unknown" } }
		end
		live.sourceFacts[fact.key] = fact
		local repeated = model.reconcile(state, live, {}, context(102)).rows[1]
		assert(repeated.attention == (coverage == "complete"), coverage)
		if coverage == "complete" then
			assert(repeated.source.lastKnown == nil and repeated.source.questions[1].status == "open",
				"a fully qualified selected-branch rewind replaces the resolved attempt")
		else
			assert(repeated.source.lastKnown.questions[1].status == "answered"
				and repeated.source.lastKnown.questions[1].text == "Original text")
		end
		assert(model.current(model.new(model.snapshot(state))).rows[1].attention == (coverage == "complete"), coverage)
	end
end)

test("invalid or question-unknown compact outcomes never settle retained questions", function()
	for _, mode in ipairs({ "duplicate", "sparse", "oversized", "open", "timestamp", "provenance", "timeout",
		"wrong-session", "wrong-key", "stale", "unavailable", "questions-unknown" }) do
		local state, live = model.new(), data("idle", false)
		local fact = { key = "conversation:11", path = "/exact/session", sessionId = "guarded", status = "ready",
			capturedAtUtc = 100, revision = "open", schemaVersion = 3, writerVersions = { "18.14.0" },
			selection = "disk-replayed", complete = true, coverage = {},
			questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
			questions = { { id = "original", status = "open", askedAtUtc = 90, text = "Keep me" } } }
		live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		live.sourceFacts = { [fact.key] = fact }
		local initial = model.reconcile(state, live, {}, context(100)).rows[1]
		model.setDisposition(state, initial.workId, "reference", 100)
		local invalid = table.clone(fact)
		invalid.revision, invalid.capturedAtUtc, invalid.questions = "invalid", 101, {}
		invalid.questionCoverage = { status = "bounded", knownTotal = 1, included = 0, omitted = 1 }
		invalid.questionOutcomes = { { id = "original", status = "answered", answeredAtUtc = 101 } }
		if mode == "duplicate" then invalid.questionOutcomes[2] = invalid.questionOutcomes[1]
		elseif mode == "sparse" then invalid.questionOutcomes[3] = { id = "other", status = "failed" }
		elseif mode == "oversized" then
			for index = 2, 513 do invalid.questionOutcomes[index] = { id = tostring(index), status = "answered" } end
		elseif mode == "open" then invalid.questionOutcomes[1].status = "open"
		elseif mode == "timestamp" then invalid.questionOutcomes[1].answeredAtUtc = "101"
		elseif mode == "provenance" then invalid.questionOutcomes[1].answerProvenance = {}
		elseif mode == "timeout" then invalid.questionOutcomes[1].timedOut = "true"
		elseif mode == "wrong-session" then invalid.sessionId = "another"
		elseif mode == "wrong-key" then invalid.key = "another"
		elseif mode == "stale" then invalid.capturedAtUtc = 99
		elseif mode == "unavailable" then invalid.coverage = { recordsComplete = false, historyScope = "unavailable" }
		elseif mode == "questions-unknown" then
			invalid.status, invalid.complete = "partial", false
			invalid.coverage = { fields = { clock = "supported", questions = "unknown" } }
		end
		live.sourceFacts[fact.key] = invalid
		local row = model.reconcile(state, live, {}, context(101)).rows[1]
		local ledger = row.source.lastKnown or row.source
		assert(ledger.questions[1].status == "open" and ledger.questions[1].text == "Keep me", mode)
		if mode == "questions-unknown" then
			assert(row.source.revision == "invalid" and row.source.questionOutcomes[1].status == "answered",
				"usable body observations remain inspectable without settling retained debt")
		else
			assert(row.source.revision == "open", mode)
		end
		local restored = model.current(model.new(model.snapshot(state))).rows[1].source
		local restoredLedger = restored.lastKnown or restored
		assert(restoredLedger.questions[1].status == "open" and restoredLedger.questions[1].text == "Keep me", mode)
	end
end)

test("active source recovery admits only qualified post-work questions once across restore", function()
	for _, gap in ipairs({ "missing", "partial" }) do
		for _, timing in ipairs({ "fresh", "pre-work", "unknown" }) do
			local state, live = model.new(), data("idle", false)
			local fact = { key = "conversation:11", path = "/exact/session", sessionId = "recover", status = "ready",
				capturedAtUtc = 100, revision = "baseline", schemaVersion = 3, writerVersions = { "18.14.0" },
				selection = "disk-replayed", complete = true, coverage = {},
				questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
				questions = { { id = "old", status = "open", askedAtUtc = 90 } } }
			live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
			live.sourceFacts = { [fact.key] = fact }
			local original = model.reconcile(state, live, { { kind = "finished", pane = 11, result = "done", at = 1 } }, context(100)).rows[1]
			live.now, live.agents[1].state = 2, "working"
			model.reconcile(state, live, {}, context(101))
			local recovered = table.clone(fact)
			recovered.revision, recovered.capturedAtUtc = "recovered", 105
			recovered.questions = { fact.questions[1], { id = "new", status = "open",
				askedAtUtc = if timing == "fresh" then 104 elseif timing == "pre-work" then 100 else nil } }
			recovered.questionCoverage = { status = "complete", knownTotal = 2, included = 2, omitted = 0 }
			local interrupted = if gap == "missing" then { key = fact.key, path = fact.path, status = "missing", capturedAtUtc = 103 }
				else table.clone(recovered)
			if gap == "partial" then
				interrupted.status, interrupted.complete, interrupted.revision, interrupted.capturedAtUtc = "partial", false, "partial", 104
				interrupted.questionCoverage = { status = "unknown", knownTotal = 2, included = 2, omitted = 0 }
			end
			live.sourceFacts[fact.key], live.now, live.agents[1].state = interrupted, 3, "idle"
			model.reconcile(state, live, {}, context(104))
			state = model.new(model.snapshot(state))
			live.sourceFacts[fact.key] = recovered
			local row = model.reconcile(state, live, {}, context(105)).rows[1]
			assert(row.sourceQuestionCurrent == (timing == "fresh") and row.attention == (timing == "fresh"), gap .. timing)
			assert(row.reviewSuperseded and row.reviewRevision == original.reviewRevision)
			local attentionRevision = row.attentionRevision
			state = model.new(model.snapshot(state))
			row = model.reconcile(state, live, {}, context(106)).rows[1]
			assert(row.attentionRevision == attentionRevision and row.attention == (timing == "fresh"))
		end
	end
end)

test("metadata-only partial preserves qualified history but independently proves stable header navigation", function()
	local state = model.new()
	local live = data("idle", false)
	live.sessions, live.tabs, live.sessionOrder = { [100] = { host = 1, name = "Workspace" } }, { [10] = { session = 100 } }, { 100 }
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local function metadata(at, sessionId, issues)
		return { key = "conversation:11", path = "/exact/session", sessionId = sessionId, status = "partial",
			capturedAtUtc = at, revision = "metadata-" .. tostring(at), schemaVersion = 3, writerVersions = { "unknown-version" },
			selection = "unknown", complete = false,
			coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" },
				issues = issues or {} } }
	end
	live.sourceFacts = { ["conversation:11"] = metadata(100, "header-one") }
	local initial = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(initial.source == nil and initial.sourceSessionId == "header-one" and not initial.attention and initial.navigable)
	assert(initial.sourceObservation.historyScope == "unavailable" and initial.sourceObservation.recordsComplete == false)
	assert(model.snapshot(state).items[1].sourceSessionId == "header-one", "validated header identity does not require history")
	state = model.new(model.snapshot(state))
	model.reconcile(state, live, {}, context(100))
	live.agents[1].state = "waiting_input"
	live.sourceFacts["conversation:11"] = metadata(101, "header-one")
	local waitingRow = model.reconcile(state, live, {}, context(101)).rows[1]
	assert(waitingRow.attention and waitingRow.navigable and waitingRow.reason == "Needs input" and waitingRow.source == nil)
	assert(model.sessionGroups(model.current(state), live, true)[1].target.sourceSessionId == "header-one")
	local qualified = { key = "conversation:11", path = "/exact/session", sessionId = "header-one", status = "ready",
		capturedAtUtc = 102, revision = "qualified", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true,
		coverage = { recordsComplete = true, historyScope = "selected-ancestry", fields = { clock = "supported", questions = "supported" } },
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		lastFinal = { id = "qualified-final", atUtc = 80, timeKind = "completed", text = "Qualified output" },
		questions = { { id = "qualified-open", status = "open", askedAtUtc = 95, text = "Selected question" } } }
	live.agents[1].state, live.sourceFacts["conversation:11"] = "idle", qualified
	local current = model.reconcile(state, live, {}, context(102)).rows[1]
	assert(current.attention and current.reviewRevision == nil, "a recorded question is independent of native update cues")
	assert(model.setDisposition(state, current.workId, "finished", 102))
	live.sourceFacts["conversation:11"] = metadata(103, "header-one")
	local deferred = model.reconcile(state, live, {}, context(103)).rows[1]
	assert(deferred.disposition == "finished" and not deferred.attention and deferred.navigable)
	assert(deferred.source.capturedAtUtc == 102 and deferred.source.questions[1].status == "open"
		and deferred.source.lastFinal.id == "qualified-final", "unavailable history does not resolve or replace qualified facts")
	assert(model.setDisposition(state, current.workId, "active", 104, { bringBack = true }))
	local broughtBack = model.current(state).rows[1]
	assert(model.visit(state, 11, broughtBack.reviewRevision, broughtBack.serial))
	assert(model.current(state).rows[1].attention and model.current(state).rows[1].reason == "Last recorded question unresolved")
	local applicablePartial = table.clone(qualified)
	applicablePartial.status, applicablePartial.complete, applicablePartial.revision, applicablePartial.capturedAtUtc =
		"partial", false, "applicable-answer", 105
	applicablePartial.questionCoverage = { status = "unknown", knownTotal = 1, included = 1, omitted = 0 }
	applicablePartial.questions = { { id = "qualified-open", status = "answered", answeredAtUtc = 105 } }
	live.sourceFacts["conversation:11"] = applicablePartial
	assert(not model.reconcile(state, live, {}, context(105)).rows[1].attention,
		"positive selected-ancestry evidence remains applicable despite separate partial omissions")
	assert(model.setPriority(state, current.workId, 2))
	live.sourceFacts["conversation:11"] = metadata(106, "header-two")
	local replaced = model.reconcile(state, live, {}, context(106))
	local replacement
	for _, candidate in ipairs(replaced.rows) do if candidate.workId ~= current.workId then replacement = candidate end end
	assert(replaced.allCount == 2 and replacement and replacement.navigable and replacement.source == nil
		and replacement.disposition == "active" and replacement.priority == nil, "stable metadata-only new header gets a separate work identity")
	assert(replacement.sourceSessionId == "header-two")
	live.sourceFacts["conversation:11"] = metadata(105, "header-one")
	assert(model.reconcile(state, live, {}, context(107)).allCount == 2, "an older header callback cannot reactivate or replace current work")
	live.sourceFacts["conversation:11"] = metadata(107, "racing-header", { "source-changed-during-read" })
	live.agents[1].state = "working"
	local raced = model.reconcile(state, live, {}, context(107))
	local same
	for _, candidate in ipairs(raced.rows) do if candidate.workId == replacement.workId then same = candidate end end
	assert(raced.allCount == 2 and same and not same.navigable and same.nativeState == "working")
	for _, item in ipairs(model.snapshot(state).items) do
		if item.serial == replacement.serial then assert(item.sourceSessionId == "header-two", "a racing old header is not replacement proof") end
	end
	live.sourceFacts["conversation:11"] = metadata(108, "header-one")
	local restored = model.reconcile(state, live, {}, context(108))
	assert(restored.allCount == 1 and restored.rows[1].workId == current.workId and restored.rows[1].sourceSessionId == "header-one"
		and restored.rows[1].priority == 2 and restored.rows[1].navigable, "fresh exact original header rebinds its retained work, not a duplicate")
end)

test("retired derived fields are discarded without rejecting or mutating factual user state", function()
	local state, live = model.new(), data("idle", true)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "cache", status = "ready",
		capturedAtUtc = 100, revision = "cache", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	live.sourceFacts = { [fact.key] = fact }
	local original = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(model.setDisposition(state, original.workId, "finished", 101))
	assert(model.setPriority(state, original.workId, 2))
	local saved = model.snapshot(state)
	saved.semanticConfiguration = "retired"
	local input = saved.items[1]
	input.semantic, input.correction, input.scopePendingBaseline = "broken retired cache", false, true
	input.source.context, input.source.semanticRevision = { messages = { "obsolete inference input" } }, "retired"
	input.source.state, input.source.messages = "retired state", { "retired messages" }
	local output = model.snapshot(model.new(saved)).items[1]
	assert(output.source.revision == "cache" and output.disposition == "finished" and output.retained and output.priority == 2)
	assert(output.serial == original.serial and output.reviewRevision == original.reviewRevision)
	assert(output.semantic == nil and output.correction == nil and output.scopePendingBaseline == nil)
	assert(output.source.context == nil and output.source.semanticRevision == nil and output.source.state == nil and output.source.messages == nil)
	assert(saved.items[1].source.context.messages[1] == "obsolete inference input" and saved.semanticConfiguration == "retired")
end)

test("current-owner observations revalidate cached history without changing its capture clocks", function()
	local state, live = model.new(), data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local body = { key = "conversation:11", path = "/exact/session", sessionId = "owner", status = "ready",
		capturedAtUtc = 100, revision = "body-one", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, reusable = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 },
		lastFinal = { id = "final", atUtc = 90, text = "Recorded final", timeKind = "completed" } }
	live.sourceFacts = { [body.key] = body }
	local first = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(not first.attention and first.navigable)
	state = model.new(model.snapshot(state))
	live.sourceObservations, live.sourceHeaders = {}, {}
	local unverified = model.reconcile(state, live, {}, context(101)).rows[1]
	assert(unverified.source.capturedAtUtc == 100 and unverified.sourceObservation == nil and not unverified.navigable)
	live.sourceHeaders[body.key] = { key = body.key, path = body.path, status = "ready", sessionId = body.sessionId,
		revision = body.revision, capturedAtUtc = 102, historyRead = false }
	local headerOnly = model.reconcile(state, live, {}, context(102)).rows[1]
	assert(headerOnly.navigable and headerOnly.sourceSessionId == body.sessionId and headerOnly.sourceObservation == nil)
	live.sourceObservations[body.key] = { key = body.key, path = body.path, status = "unchanged", revision = body.revision, capturedAtUtc = 103 }
	local verified = model.reconcile(state, live, {}, context(103)).rows[1]
	assert(verified.navigable and verified.source.capturedAtUtc == 100 and verified.source.lastFinal.atUtc == 90)
	assert(verified.sourceObservation.status == "unchanged" and verified.sourceObservation.capturedAtUtc == 103)
	live.sourceHeaders[body.key] = { key = body.key, path = body.path, status = "ready", sessionId = body.sessionId,
		revision = "changed-same-header", capturedAtUtc = 104, historyRead = false }
	local staleBody = model.reconcile(state, live, {}, context(104)).rows[1]
	assert(staleBody.navigable and not staleBody.attention and staleBody.source.capturedAtUtc == 100)
	assert(staleBody.sourceObservation.status == "history-changed" and staleBody.sourceObservation.historyRead == false)
	live.sourceHeaders[body.key] = { key = body.key, path = body.path, status = "changed", sessionId = "different",
		revision = "body-two", capturedAtUtc = 105, historyRead = false }
	local changed = model.reconcile(state, live, {}, context(105))
	assert(changed.allCount == 1 and changed.rows[1].sourceSessionId == "owner" and not changed.rows[1].navigable
		and not changed.rows[1].retryableHeaderRoute and changed.rows[1].source.capturedAtUtc == 100)
	live.sourceObservations[body.key] = { key = body.key, path = body.path, sessionId = "different", status = "partial",
		revision = "body-two", capturedAtUtc = 106, schemaVersion = 3, writerVersions = {}, selection = "unknown", complete = false,
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } } }
	local refreshed = model.reconcile(state, live, {}, context(106)).rows[1]
	assert(refreshed.workId ~= first.workId and refreshed.sourceSessionId == "different" and refreshed.source == nil and refreshed.navigable,
		"source acquisition, not a changed action response, establishes replacement work")
end)

test("header-only initial identity strengthening preserves captured review race protection", function()
	local state = model.new()
	local live = data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	live.sourceFacts, live.sourceObservations, live.sourceHeaders = {}, {}, {}
	local original = model.reconcile(state, live, { { kind = "finished", pane = 11, result = "done", at = 1 } }, context(100)).rows[1]
	assert(original.sourceSessionId == nil and original.reviewRevision ~= nil)
	live.sourceHeaders["conversation:11"] = { key = "conversation:11", path = "/exact/session", status = "ready", sessionId = "strengthened",
		revision = "header-stat", capturedAtUtc = 101, historyRead = false }
	local strengthened = model.reconcile(state, live, {}, context(101)).rows[1]
	assert(strengthened.workId == original.workId and strengthened.serial == original.serial and strengthened.pane == original.pane
		and strengthened.reviewRevision == original.reviewRevision and strengthened.sourceSessionId == "strengthened" and strengthened.source == nil)
	local newer = model.reconcile(state, live, { { kind = "state", pane = 11, old = "idle", new = "working", at = 2 },
		{ kind = "finished", pane = 11, result = "done", at = 3 } }, context(102)).rows[1]
	assert(newer.reviewRevision ~= original.reviewRevision)
	assert(not model.visit(state, original.pane, original.reviewRevision, original.serial))
	assert(model.current(state).rows[1].reviewRevision == newer.reviewRevision)
end)


test("pending local header can be attempted globally without granting navigation or acknowledgment", function()
	local state, live = model.new(), data("waiting_input", false)
	live.sessions, live.tabs, live.sessionOrder = { [100] = { host = 1, name = "Workspace" } }, { [10] = { session = 100 } }, { 100 }
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "known", status = "ready",
		capturedAtUtc = 100, revision = "one", schemaVersion = 3, writerVersions = { "18.14.0" },
		selection = "disk-replayed", complete = true, coverage = {}, questions = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	live.sourceFacts = { [fact.key] = fact }
	local original = model.reconcile(state, live, {}, context(100)).rows[1]
	state = model.new(model.snapshot(state))
	live.sourceObservations, live.sourceHeaders = {}, {}
	local pending = model.reconcile(state, live, {}, context(101))
	local row = pending.rows[1]
	assert(not row.navigable and row.retryableHeaderRoute and not row.stale and pending.reachableCount == 0
		and pending.awaitingHeaderCount == 1 and pending.attentionTargets[11])
	assert(model.next(state, nil, pending.attentionTargets) == 11)
	assert(model.sessionGroups(pending, live, true)[1].target.serial == original.serial)
	assert(not model.visit(state, 11, row.reviewRevision, row.serial))
	live.sourceHeaders[fact.key] = { key = fact.key, path = fact.path, sessionId = fact.sessionId, status = "ready",
		revision = fact.revision, capturedAtUtc = 102, historyRead = false }
	local proven = model.reconcile(state, live, {}, context(102))
	assert(proven.rows[1].navigable and not proven.rows[1].retryableHeaderRoute and proven.reachableCount == 1
		and proven.awaitingHeaderCount == 0)
end)

test("an unparsed ask preserves observed excerpts without creating or resolving qualified question debt", function()
	local state, live = model.new(), data("idle", false)
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local partial = { key = "conversation:11", path = "/exact/session", sessionId = "older-writer", status = "partial",
		capturedAtUtc = 100, revision = "observed-partial", schemaVersion = 3, writerVersions = { "99.0.0" },
		selection = "disk-replayed", complete = false,
		coverage = { recordsComplete = true, historyScope = "selected-ancestry", writerSupport = "unknown",
			fields = { clock = "supported", questions = "unknown" }, issues = { "unsupported-ask-questions" } },
		lastFinal = { id = "observed-final", atUtc = 90, timeKind = "completed", text = "Recorded output" },
		questions = { { id = "question", status = "open", askedAtUtc = 95 } },
		questionCoverage = { status = "unknown", knownTotal = 1, included = 1, omitted = 0 } }
	live.sourceFacts = { [partial.key] = partial }
	local observed = model.reconcile(state, live, {}, context(100)).rows[1]
	assert(observed.source and observed.source.lastFinal.id == "observed-final" and not observed.attention
		and observed.source.coverage.fields.questions == "unknown", "known excerpts remain inspectable, not current branch authority")
	local qualified = table.clone(partial)
	qualified.status, qualified.complete, qualified.revision, qualified.capturedAtUtc = "ready", true, "qualified", 110
	qualified.coverage = { recordsComplete = true, historyScope = "selected-ancestry", fields = { clock = "supported", questions = "supported" } }
	qualified.questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 }
	live.sourceFacts[partial.key] = qualified
	local known = model.reconcile(state, live, {}, context(110)).rows[1]
	assert(known.attention and model.setDisposition(state, known.workId, "finished", 111))
	local uncertainAnswer = table.clone(partial)
	uncertainAnswer.revision, uncertainAnswer.capturedAtUtc = "unqualified-answer", 112
	uncertainAnswer.questions = { { id = "question", status = "answered", answeredAtUtc = 112 } }
	live.sourceFacts[partial.key] = uncertainAnswer
	local deferred = model.reconcile(state, live, {}, context(112)).rows[1]
	assert(deferred.disposition == "finished" and deferred.source.lastKnown.questions[1].status == "open",
		"unqualified selection cannot discharge a previously qualified open attempt")
	assert(model.setDisposition(state, known.workId, "active", 113, { bringBack = true }))
	local broughtBack = model.current(state).rows[1]
	assert(model.visit(state, 11, broughtBack.reviewRevision, broughtBack.serial))
	assert(model.current(state).rows[1].attention and model.current(state).rows[1].reason == "Last recorded question unresolved")
	assert(model.current(model.new(model.snapshot(state))).rows[1].source.lastFinal.id == "observed-final")
end)

return true
