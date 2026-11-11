local model = require("../model")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function context(nowUtc)
	return { window = "durable-window", hostKeys = { [1] = "local" },
		connected = { ["local"] = true }, coherent = true, nowUtc = nowUtc }
end

local function snapshot(now, doneAlert)
	return {
		ok = true, now = now, identityReady = true,
		identities = { [11] = "conversation:done", [22] = "conversation:failed", [33] = "conversation:chrome" },
		hosts = { [1] = { key = "local", name = "Local", connected = true } },
		agents = { { pane = 11, state = "idle" }, { pane = 22, state = "idle" }, { pane = 33, state = "waiting_input" } },
		panes = {
			[11] = { host = 1, tab = 10, session = 100, title = "Completed task", alert = doneAlert },
			[22] = { host = 1, tab = 20, session = 100, title = "Failed task", alert = false },
			[33] = { host = 1, tab = 30, session = 100, title = "Chrome", alert = false },
		},
	}
end

local function row(presentation, pane)
	for _, entry in ipairs(presentation.rows) do
		if entry.pane == pane then return entry end
	end
	return nil
end

local function visit(state, selected)
	return model.visit(state, selected.pane, selected.reviewRevision, selected.serial)
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, field in pairs(value) do result[key] = copy(field) end
	return result
end

local function same(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for key, value in pairs(a) do if not same(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

test("restored duplicate routes preserve canonical identity and merged review without persistence churn", function()
	local state = model.new()
	local live = {
		ok = true, now = 1, identityReady = true, identities = { [22] = "conversation:duplicate" },
		hosts = { [1] = { key = "local", name = "Local", connected = true } },
		agents = { { pane = 22, state = "idle" } },
		panes = { [22] = { host = 1, tab = 20, session = 100, title = "Preferred", alert = false } },
	}
	model.reconcile(state, live, {}, context(1000))
	live.now, live.identities[11] = 2, live.identities[22]
	live.panes[11] = { host = 1, tab = 10, session = 100, title = "Duplicate", alert = true }
	table.insert(live.agents, { pane = 11, state = "waiting_input", deliveryError = "delivery" })
	local first = model.reconcile(state, live, {}, context(1001)).rows[1]
	assert(first.pane == 22 and first.reviewKind == "update" and first.condition == "waiting")
	assert(model.setDisposition(state, first.workId, "finished", 1002))
	local saved = model.snapshot(state)
	assert(#saved.items == 1 and saved.items[1].waiting and saved.items[1].delivery and saved.items[1].alert)
	state = model.new(saved)
	live.now = 1
	local restored = model.reconcile(state, live, {}, context(1003))
	assert(#restored.rows == 1 and restored.knownCount == 1 and restored.attentionCount == 0 and restored.rows[1].disposition == "finished")
	local selected = restored.rows[1]
	assert(selected.pane == 22 and selected.title == "Preferred" and selected.navigable and not selected.stale)
	assert(selected.workId == first.workId and selected.identityKey == first.identityKey)
	assert(selected.reviewRevision == first.reviewRevision and selected.attentionRevision == first.attentionRevision)
	assert(selected.firstSeenUtc == first.firstSeenUtc and selected.queueOrder == first.queueOrder)
	local revision = state.persistenceRevision
	live.now = 2
	model.reconcile(state, live, {}, context(1004))
	assert(state.persistenceRevision == revision)
	assert(model.visit(state, selected.pane, selected.reviewRevision, selected.serial))
	local acknowledged = model.current(state)
	assert(#acknowledged.rows == 1 and acknowledged.rows[1].reviewRevision == nil)
	assert(acknowledged.rows[1].condition == "waiting" and acknowledged.rows[1].disposition == "finished")
	state = model.new(model.snapshot(state))
	local again = model.reconcile(state, live, {}, context(1005))
	assert(#again.rows == 1 and again.rows[1].pane == 22 and again.rows[1].reviewRevision == nil)
	assert(again.rows[1].condition == "waiting" and again.attentionCount == 0 and again.rows[1].disposition == "finished")
end)

test("superseded unread revisions survive offline restore and idle without reentering Attention", function()
	local state = model.new()
	local original = row(model.reconcile(state, snapshot(10, false), {
		{ kind = "finished", pane = 11, result = "done", at = 10 },
	}, context(1000)), 11)
	local busy = snapshot(20, false)
	busy.agents[1].state = "working"
	local resumed = row(model.reconcile(state, busy, {}, context(1001)), 11)
	assert(not resumed.attention and resumed.reviewSuperseded and resumed.reviewRevision == original.reviewRevision)
	local saved = model.snapshot(state)
	local stored
	for _, item in ipairs(saved.items) do if item.serial == original.serial then stored = item end end
	assert(stored.reviewSuperseded == true and stored.reviewRevision == original.reviewRevision and stored.finishedResult == "done")
	state = model.new(saved)
	assert(not row(model.current(state), 11).attention)
	local offline = row(model.reconcile(state, { ok = false }, {}, context(1002)), 11)
	assert(offline.stale and not offline.attention and offline.reviewRevision == original.reviewRevision)
	local settled = row(model.reconcile(state, snapshot(1, false), {}, context(1003)), 11)
	assert(settled.navigable and not settled.attention and settled.reviewSuperseded and settled.serial == original.serial)
	state = model.new(model.snapshot(state))
	local repeated = row(model.reconcile(state, snapshot(1, false), {}, context(1004)), 11)
	assert(not repeated.attention and repeated.reviewRevision == original.reviewRevision)
	stored.reviewSuperseded = nil
	local oldSchema = model.new(saved)
	assert(not row(model.current(oldSchema), 11).attention, "old schema-3 Working records also retire earlier cues")
	assert(row(model.current(oldSchema), 11).reviewRevision == original.reviewRevision)
end)

test("independent source question supersession migrates Working records and survives current-question restore", function()
	local state, live = model.new(), snapshot(1, false)
	live.sources = { [11] = { key = "conversation:done", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:done", path = "/exact/session", sessionId = "durable-questions",
		status = "ready", capturedAtUtc = 1000, revision = "old", schemaVersion = 3,
		writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "old", status = "open", askedAtUtc = 900 } } }
	live.sourceFacts = { [fact.key] = fact }
	local original = row(model.reconcile(state, live, {
		{ kind = "finished", pane = 11, result = "done", at = 1 },
	}, context(1000)), 11)
	live.now, live.agents[1].state = 2, "working"
	model.reconcile(state, live, {}, context(1001))
	local legacy = model.snapshot(state)
	for _, item in ipairs(legacy.items) do
		if item.serial == original.serial then
			item.reviewSuperseded, item.sourceQuestionSuperseded, item.sourceQuestionRevision = nil, nil, nil
		end
	end
	state = model.new(legacy)
	live.now, live.agents[1].state = 3, "idle"
	local quiet = row(model.reconcile(state, live, {}, context(1002)), 11)
	assert(not quiet.attention and not quiet.sourceQuestionCurrent and quiet.reviewSuperseded)
	for _, item in ipairs(model.snapshot(state).items) do
		if item.serial == original.serial then assert(item.sourceQuestionSuperseded == true) end
	end
	live.now, live.agents[1].state = 4, "working"
	model.reconcile(state, live, {}, context(1003))
	fact = table.clone(fact)
	fact.revision, fact.capturedAtUtc = "fresh", 1004
	fact.questions = { fact.questions[1], { id = "fresh", status = "open", askedAtUtc = 1004 } }
	fact.questionCoverage = { status = "complete", knownTotal = 2, included = 2, omitted = 0 }
	live.sourceFacts[fact.key] = fact
	local busy = row(model.reconcile(state, live, {}, context(1004)), 11)
	assert(not busy.sourceQuestionCurrent and not busy.attention and busy.reviewSuperseded)
	local saved = model.snapshot(state)
	local questionRevision
	for _, item in ipairs(saved.items) do
		if item.serial == original.serial then
			assert(item.sourceQuestionSuperseded == false and item.reviewSuperseded == true)
			assert(item.reviewRevision == original.reviewRevision)
			item.sourceQuestionRevision = saved.attentionRevision + 10
			questionRevision = item.sourceQuestionRevision
		end
	end
	assert(questionRevision ~= nil)
	state = model.new(saved)
	assert(model.snapshot(state).attentionRevision >= questionRevision, "restored source causality seeds the shared sequence")
	assert(not row(model.current(state), 11).sourceQuestionCurrent, "Working still masks a genuinely fresh question")
	live.now, live.agents[1].state = 5, "idle"
	local current = row(model.reconcile(state, live, {}, context(1005)), 11)
	assert(current.sourceQuestionCurrent and current.attention and current.reviewSuperseded)
	assert(current.reviewRevision == original.reviewRevision and current.reason == "Recorded question unresolved")
	live.now, live.agents[1].state = 6, "working"
	model.reconcile(state, live, {}, context(1006))
	for _, item in ipairs(model.snapshot(state).items) do
		if item.serial == original.serial then
			assert(item.sourceQuestionSuperseded == true and item.sourceQuestionRevision > questionRevision)
			assert(item.attentionRevision == busy.attentionRevision and item.firstSeenUtc == busy.firstSeenUtc,
				"suppression bookkeeping is not a new Attention arrival")
		end
	end
end)

test("a current result with lagging working inventory survives reload and enters only once settled", function()
	for _, result in ipairs({ "done", "failed", "exited" }) do
		local state = model.new()
		local busy = snapshot(10, false)
		busy.agents[1].state = "working"
		model.reconcile(state, busy, {}, context(1000))
		busy.now = 20
		local resultRow = row(model.reconcile(state, busy, {
			{ kind = "finished", pane = 11, result = result, at = 20 },
		}, context(1001)), 11)
		assert(not resultRow.attention and not resultRow.reviewSuperseded and resultRow.reviewKind == result)
		state = model.new(model.snapshot(state))
		assert(not row(model.current(state), 11).attention)
		local settled = row(model.reconcile(state, snapshot(1, false), {}, context(1002)), 11)
		assert(settled.attention and not settled.reviewSuperseded and settled.reviewRevision == resultRow.reviewRevision)
		local duplicate = row(model.reconcile(state, snapshot(2, false), {
			{ kind = "finished", pane = 11, result = result, at = 2 },
		}, context(1003)), 11)
		assert(duplicate.reviewRevision == resultRow.reviewRevision and duplicate.queueOrder == resultRow.queueOrder)
		assert(visit(state, duplicate))
		local readAgain = row(model.reconcile(state, snapshot(3, false), {
			{ kind = "finished", pane = 11, result = result, at = 3 },
		}, context(1004)), 11)
		assert(not readAgain.attention and readAgain.reviewRevision == nil)
	end
end)

test("pending-record loss: reload preserves two P0 records and the Finished Chrome row", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1000, true), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
		{ kind = "finished", pane = 22, result = "failed", at = 1000 },
	}, context(1000))
	assert(original.status == "ready" and original.count == 3)
	assert(row(original, 11).reviewRevision ~= nil and row(original, 22).reviewRevision ~= nil)
	assert(model.setDisposition(state, "work:" .. tostring(row(original, 33).serial), "finished", 1000))
	local saved = model.snapshot(state)
	assert(saved.schema == 3 and #saved.items == 3)
	local reloaded = model.new(saved)
	assert(#model.current(reloaded).rows == 3, "restored records must render before inventory arrives")
	local restored = model.reconcile(reloaded, snapshot(2000, false), {}, context(1001))
	assert(#model.snapshot(reloaded).items == 3)
	local done, failed, chrome = row(restored, 11), row(restored, 22), row(restored, 33)
	assert(done ~= nil and done.disposition == "active" and done.reviewRevision == row(original, 11).reviewRevision)
	assert(failed ~= nil and failed.disposition == "active" and failed.reviewRevision == row(original, 22).reviewRevision)
	assert(chrome ~= nil and chrome.disposition == "finished")
	assert(restored.status == "ready" and restored.count == 3 and restored.knownCount == 3)
	assert(restored.attentionCount == 2)
	assert(restored.attentionTargets[11] and restored.attentionTargets[22] and not restored.attentionTargets[33])
end)

test("a captured visit revision cannot acknowledge a newer completion", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 22, result = "failed", at = 1000 },
	}, context(1000))
	local selected = row(first, 22)
	local after = model.reconcile(state, snapshot(2000, false), {
		{ kind = "state", pane = 22, new = "working", old = "idle", at = 1500 },
		{ kind = "finished", pane = 22, result = "failed", at = 2000 },
	}, context(1001))
	local newer = row(after, 22)
	assert(newer.reviewRevision ~= selected.reviewRevision and newer.serial == selected.serial)
	assert(not visit(state, selected))
	assert(row(model.current(state), 22).reviewRevision == newer.reviewRevision)
	assert(visit(state, newer))
	assert(not row(model.current(state), 22).attention)
	assert(row(model.current(state), 33) ~= nil)
end)

test("acknowledged turn cursors survive reload and suppress duplicate completion", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
	}, context(1000))
	assert(visit(state, row(first, 11)))
	state = model.new(model.snapshot(state))
	local repeated = model.reconcile(state, snapshot(2000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 2000 },
	}, context(1001))
	assert(not row(repeated, 11).attention, "a duplicate done is not a new turn")
	local fresh = model.reconcile(state, snapshot(3000, false), {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 2500 },
		{ kind = "finished", pane = 11, result = "done", at = 3000 },
	}, context(1002))
	assert(row(fresh, 11) ~= nil and row(fresh, 11).reviewRevision ~= nil)
end)

for _, completionAt in ipairs({ 190, 200 }) do
	test("completion before new work survives snapshot catch-up at " .. tostring(completionAt), function()
		local state = model.new()
		model.reconcile(state, snapshot(100, false), {}, context(1000))
		local working = snapshot(200, false)
		working.agents[1].state = "working"
		local selected = row(model.reconcile(state, working, {
			{ kind = "finished", pane = 11, result = "done", at = completionAt },
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		}, context(1001)), 11)
		assert(selected and selected.reviewRevision ~= nil, "new work must preserve an unreviewed completion")
		assert(not selected.attention and selected.reviewSuperseded, "later work retires the earlier cue without acknowledging it")
		local newer = row(model.reconcile(state, snapshot(300, false), {
			{ kind = "finished", pane = 11, result = "done", at = 300 },
		}, context(1002)), 11)
		assert(newer.reviewRevision > selected.reviewRevision and newer.serial == selected.serial)
		assert(newer.queueOrder == selected.queueOrder)
		assert(not visit(state, selected))
		assert(visit(state, newer))
		model.reconcile(state, working, {
			{ kind = "finished", pane = 11, result = "done", at = completionAt },
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		}, context(1003))
		assert(not row(model.current(state), 11).attention, "replayed acknowledged callbacks must not resurrect review")
		state = model.new(model.snapshot(state))
		local repeated = model.reconcile(state, snapshot(1, false), {
			{ kind = "finished", pane = 11, result = "done", at = 1 },
		}, context(1004))
		assert(not row(repeated, 11).attention)
	end)
end

test("snapshot-only new work follows an earlier literal completion", function()
	local state = model.new()
	model.reconcile(state, snapshot(100, false), {}, context(1000))
	local working = snapshot(200, false)
	working.agents[1].state = "working"
	local selected = row(model.reconcile(state, working, {
		{ kind = "finished", pane = 11, result = "done", at = 190 },
	}, context(1001)), 11)
	assert(selected and selected.reviewRevision ~= nil)
	assert(not selected.attention and selected.reviewSuperseded)
	local newer = row(model.reconcile(state, snapshot(300, false), {
		{ kind = "finished", pane = 11, result = "done", at = 300 },
	}, context(1002)), 11)
	assert(newer.reviewRevision > selected.reviewRevision)
	assert(not visit(state, selected))
end)

test("a delayed literal result is not acknowledged by an already observed newer working snapshot", function()
	local state = model.new()
	model.reconcile(state, snapshot(100, false), {}, context(1000))
	local working = snapshot(200, false)
	working.agents[1].state = "working"
	model.reconcile(state, working, {}, context(1001))
	local selected = row(model.reconcile(state, working, {
		{ kind = "finished", pane = 11, result = "done", at = 190 },
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
	}, context(1002)), 11)
	assert(selected and selected.reviewRevision ~= nil)
	assert(not selected.attention and selected.reviewSuperseded)
	local newer = row(model.reconcile(state, snapshot(300, false), {
		{ kind = "finished", pane = 11, result = "done", at = 300 },
	}, context(1003)), 11)
	assert(newer.reviewRevision > selected.reviewRevision)
	assert(not visit(state, selected))
	assert(visit(state, newer))
	local repeated = model.reconcile(state, snapshot(301, false), {
		{ kind = "finished", pane = 11, result = "done", at = 190 },
	}, context(1004))
	assert(not row(repeated, 11).attention)
end)

for _, restart in ipairs({ false, true }) do
	test("deferred completion then work survives snapshot catch-up with restart " .. tostring(restart), function()
		local state = model.new()
		model.reconcile(state, snapshot(100, false), {}, context(1000))
		state = model.new(model.snapshot(state))
		local deferred = snapshot(200, false)
		deferred.identityReady, deferred.agents[1].state = false, "working"
		model.reconcile(state, deferred, {
			{ kind = "finished", pane = 11, result = "done", at = 190 },
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		}, context(1001))
		if restart then state = model.new(model.snapshot(state)) end
		local working = snapshot(if restart then 1 else 201, false)
		working.agents[1].state = "working"
		local selected = row(model.reconcile(state, working, {}, context(1002)), 11)
		assert(selected and selected.reviewRevision ~= nil)
		assert(not selected.attention and selected.reviewSuperseded)
		local at = if restart then 2 else 300
		local newer = row(model.reconcile(state, snapshot(at, false), {
			{ kind = "finished", pane = 11, result = "done", at = at },
		}, context(1003)), 11)
		assert(newer.reviewRevision > selected.reviewRevision)
		assert(not visit(state, selected))
		assert(visit(state, newer))
		local repeated = model.reconcile(state, snapshot(at + 1, false), {
			{ kind = "finished", pane = 11, result = "done", at = at },
		}, context(1004))
		assert(not row(repeated, 11).attention)
	end)
end

for _, restart in ipairs({ false, true }) do
	test("deferred same-clock work-result-work preserves both sides with restart " .. tostring(restart), function()
		local state = model.new()
		local original = row(model.reconcile(state, snapshot(100, false), {
			{ kind = "finished", pane = 11, result = "done", at = 100 },
		}, context(1000)), 11)
		assert(visit(state, original))
		state = model.new(model.snapshot(state))
		local deferred = snapshot(200, false)
		deferred.identityReady, deferred.agents[1].state = false, "working"
		model.reconcile(state, deferred, {
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
			{ kind = "finished", pane = 11, result = "done", at = 200 },
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		}, context(1001))
		if restart then state = model.new(model.snapshot(state)) end
		local working = snapshot(if restart then 1 else 201, false)
		working.agents[1].state = "working"
		local selected = row(model.reconcile(state, working, {}, context(1002)), 11)
		assert(selected and selected.reviewRevision > original.reviewRevision)
		assert(not selected.attention and selected.reviewSuperseded)
		local at = if restart then 2 else 300
		local newer = row(model.reconcile(state, snapshot(at, false), {
			{ kind = "finished", pane = 11, result = "done", at = at },
		}, context(1003)), 11)
		assert(newer.reviewRevision > selected.reviewRevision)
		assert(not visit(state, selected))
		assert(visit(state, newer))
		local duplicate = model.reconcile(state, snapshot(at + 1, false), {
			{ kind = "finished", pane = 11, result = "done", at = at },
		}, context(1004))
		assert(not row(duplicate, 11).attention)
	end)
end

test("a deferred late result remains before already observed newer work", function()
	local state = model.new()
	model.reconcile(state, snapshot(100, false), {}, context(1000))
	state = model.new(model.snapshot(state))
	local deferred = snapshot(200, false)
	deferred.identityReady, deferred.agents[1].state = false, "working"
	model.reconcile(state, deferred, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		{ kind = "finished", pane = 11, result = "done", at = 190 },
	}, context(1001))
	state = model.new(model.snapshot(state))
	local working = snapshot(1, false)
	working.agents[1].state = "working"
	local selected = row(model.reconcile(state, working, {}, context(1002)), 11)
	assert(selected and selected.reviewRevision ~= nil)
	assert(not selected.attention and selected.reviewSuperseded)
	local newer = row(model.reconcile(state, snapshot(2, false), {
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, context(1003)), 11)
	assert(newer.reviewRevision > selected.reviewRevision)
	assert(not visit(state, selected))
end)

test("same-clock working callbacks separate completions without duplicating snapshot work", function()
	local state = model.new()
	model.reconcile(state, snapshot(100, false), {}, context(1000))
	local working = snapshot(200, false)
	working.agents[1].state = "working"
	local selected = row(model.reconcile(state, working, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
		{ kind = "finished", pane = 11, result = "done", at = 200 },
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 200 },
	}, context(1001)), 11)
	local newer = row(model.reconcile(state, snapshot(200, false), {
		{ kind = "finished", pane = 11, result = "done", at = 200 },
	}, context(1002)), 11)
	assert(selected and newer and newer.reviewRevision > selected.reviewRevision)
	assert(not selected.attention and selected.reviewSuperseded)
	assert(not visit(state, selected))
	assert(visit(state, newer))
	local duplicate = model.reconcile(state, snapshot(201, false), {
		{ kind = "finished", pane = 11, result = "done", at = 200 },
	}, context(1003))
	assert(not row(duplicate, 11).attention)
end)

test("inventory failure retains unseen evidence without routing or acknowledgement", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
	}, context(1000))
	local selected = row(first, 11)
	local failed = model.reconcile(state, { ok = false, error = "native read failed" }, {}, context(1001))
	assert(failed.count == nil and failed.attentionCount == 2)
	assert(row(failed, 11).stale and not row(failed, 11).navigable)
	assert(not visit(state, selected))
	state = model.new(model.snapshot(state))
	local restored = model.reconcile(state, snapshot(2000, false), {}, context(1002))
	assert(row(restored, 11).reviewRevision == selected.reviewRevision)
end)

for _, condition in ipairs({ "waiting", "delivery", "startup" }) do
	test(condition .. " survives restart and coverage gaps as acknowledgeable history", function()
		for _, gap in ipairs({ "restart", "unknown", "missing", "disconnected", "incoherent", "coverage" }) do
			local state = model.new()
			local data = snapshot(10000, false)
			data.agents[1].state = if condition == "waiting" then "waiting_input" else "idle"
			data.agents[1].deliveryError = if condition == "delivery" then "not delivered" else nil
			data.panes[11].startupError = if condition == "startup" then "not started" else nil
			local first = row(model.reconcile(state, data, {}, context(1000)), 11)
			assert(first and first.reviewRevision == nil)
			assert(model.setDisposition(state, "work:" .. tostring(first.serial), "finished", 1000))
			if gap == "restart" then
				state = model.new(model.snapshot(state))
			else
				local absent, gapContext = snapshot(10001, false), context(if gap == "disconnected" then 1009 else 1001)
				if gap == "unknown" then absent.agents[1].state = "future_state"
				elseif gap == "missing" then absent.agents[1] = absent.agents[3]; absent.agents[3] = nil; absent.panes[11] = nil
				elseif gap == "disconnected" then absent.hosts[1].connected = false
				elseif gap == "incoherent" then gapContext.coherent = false
				else absent.ok = false end
				local unavailable = row(model.reconcile(state, absent, {}, gapContext), 11) or model.current(state).rows[1]
				assert(unavailable and unavailable.stale)
			end
			local awaitingProof = snapshot(10002, false)
			awaitingProof.identityReady = false
			assert(row(model.reconcile(state, awaitingProof, {}, context(1001)), 11) ~= nil)
			local historical = row(model.reconcile(state, snapshot(1, false), {}, context(1002)), 11)
			assert(historical and (historical.reviewRevision ~= nil) == (gap ~= "missing") and historical.navigable)
			assert(historical.serial == first.serial and historical.disposition == "finished")
			assert(historical.firstSeenUtc == first.firstSeenUtc and historical.queueOrder == first.queueOrder)
			assert(historical.reason ~= first.reason, "historical obligation must not claim a current live condition")
			local again = row(model.reconcile(state, snapshot(2, false), {}, context(1003)), 11)
			assert(again.reviewRevision == historical.reviewRevision)
			state = model.new(model.snapshot(state))
			local savedHistory = row(model.reconcile(state, snapshot(1, false), {}, context(1004)), 11)
			assert(savedHistory.reviewRevision == historical.reviewRevision)
			assert(visit(state, savedHistory) == (gap ~= "missing") and row(model.current(state), 11).reviewRevision == nil)
		end
	end)

	test(condition .. " resolution held for healthy identity revalidation does not invent review", function()
		local state = model.new()
		local data = snapshot(10000, false)
		data.agents[1].state = if condition == "waiting" then "waiting_input" else "idle"
		data.agents[1].deliveryError = if condition == "delivery" then "not delivered" else nil
		data.panes[11].startupError = if condition == "startup" then "not started" else nil
		local first = row(model.reconcile(state, data, {}, context(1000)), 11)
		assert(first and first.reviewRevision == nil and not visit(state, first))
		local working = snapshot(10010, false)
		working.agents[1].state, working.identityReady = "working", false
		local held = row(model.reconcile(state, working, {
			{ kind = "state", pane = 11, old = data.agents[1].state, new = "working", at = 10010 },
		}, context(1001)), 11)
		assert(held and held.stale and held.reviewRevision == nil)
		model.reconcile(state, working, {}, context(1002))
		working.identityReady = true
		local resolved = model.reconcile(state, working, {}, context(1003))
		assert(not row(resolved, 11).attention, "same-identity observed resolution creates no historical review")
		state = model.new(model.snapshot(state))
		assert(not row(model.reconcile(state, working, {}, context(1004)), 11).attention)
	end)

	test(condition .. " remains active when reconfirmed and clears only on continuous resolution", function()
		local state = model.new()
		local data = snapshot(10000, false)
		data.agents[1].state = if condition == "waiting" then "waiting_input" else "idle"
		data.agents[1].deliveryError = if condition == "delivery" then "not delivered" else nil
		data.panes[11].startupError = if condition == "startup" then "not started" else nil
		local first = row(model.reconcile(state, data, {}, context(1000)), 11)
		state = model.new(model.snapshot(state))
		data.now = 1
		local live = row(model.reconcile(state, data, {}, context(1001)), 11)
		assert(live and live.reason == first.reason and live.reviewRevision == nil)
		assert(not visit(state, live) and row(model.current(state), 11) ~= nil)
		assert(not row(model.reconcile(state, snapshot(2, false), {}, context(1002)), 11).attention)
	end)
end

test("unknown restored identity retains the condition until exact routing proof arrives", function()
	local state = model.new()
	local data = snapshot(10000, false)
	data.agents[1].state = "waiting_input"
	local first = row(model.reconcile(state, data, {}, context(1000)), 11)
	state = model.new(model.snapshot(state))
	data = snapshot(1, false)
	data.identityReady, data.identities = false, {}
	local unknown = row(model.reconcile(state, data, {}, context(1001)), 11)
	assert(unknown and unknown.stale and not unknown.navigable and unknown.serial == first.serial)
	assert(not visit(state, unknown))
	local proven = row(model.reconcile(state, snapshot(2, false), {}, context(1002)), 11)
	assert(proven and proven.navigable and proven.reviewRevision ~= nil)
	assert(visit(state, proven) and not row(model.current(state), 11).attention)
end)

for _, result in ipairs({ "done", "failed" }) do
	test("deferred " .. result .. " replay never imports the previous runtime clock", function()
		local state = model.new()
		model.reconcile(state, snapshot(10000, false), {
			{ kind = "finished", pane = 11, result = result, at = 10000 },
		}, context(2000))
		state = model.new(model.snapshot(state))
		local deferred = snapshot(10010, false)
		deferred.identityReady, deferred.agents[1].state = false, "working"
		model.reconcile(state, deferred, {
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 10010 },
		}, context(2001))
		deferred.now, deferred.agents[1].state = 10020, "idle"
		model.reconcile(state, deferred, {
			{ kind = "finished", pane = 11, result = result, at = 10020 },
			{ kind = "finished", pane = 11, result = result, at = 10020 },
		}, context(2002))
		state = model.new(model.snapshot(state))
		local replayed = row(model.reconcile(state, snapshot(1, false), {}, context(2003)), 11)
		local duplicate = row(model.reconcile(state, snapshot(1, false), {
			{ kind = "finished", pane = 11, result = result, at = 1 },
		}, context(2003)), 11)
		assert(duplicate.reviewRevision == replayed.reviewRevision)
		local working = snapshot(2, false)
		working.agents[1].state = "working"
		model.reconcile(state, working, {
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 2 },
		}, context(2004))
		local newest = row(model.reconcile(state, snapshot(3, false), {
			{ kind = "finished", pane = 11, result = result, at = 3 },
		}, context(2005)), 11)
		assert(newest.reviewRevision > replayed.reviewRevision and newest.serial == replayed.serial)
		local stale = row(model.reconcile(state, snapshot(4, false), {
			{ kind = "finished", pane = 11, result = if result == "done" then "failed" else "done", at = 1 },
			{ kind = "finished", pane = 11, result = result, at = 3 },
		}, context(2006)), 11)
		assert(stale.reviewRevision == newest.reviewRevision)
		assert(visit(state, stale))
		state = model.new(model.snapshot(state))
		local quiet = model.reconcile(state, snapshot(1, false), {
			{ kind = "finished", pane = 11, result = result, at = 1 },
		}, context(2007))
		assert(not row(quiet, 11).attention, "acknowledged result remains deduplicated after restart")
	end)
end

test("historical review has its own captured revision and cannot dismiss a reconfirmed input request", function()
	local state = model.new()
	local data = snapshot(10000, false)
	data.agents[1].state = "waiting_input"
	local completed = row(model.reconcile(state, data, {
		{ kind = "finished", pane = 11, result = "done", at = 10000 },
	}, context(1000)), 11)
	assert(visit(state, completed))
	state = model.new(model.snapshot(state))
	local historical = row(model.reconcile(state, snapshot(1, false), {}, context(1001)), 11)
	assert(historical.reviewRevision ~= completed.reviewRevision)
	assert(not visit(state, completed))
	data.now = 2
	local live = row(model.reconcile(state, data, {}, context(1002)), 11)
	assert(live.reviewRevision == historical.reviewRevision)
	assert(visit(state, live))
	local remaining = row(model.current(state), 11)
	assert(remaining and remaining.reviewRevision == nil)
	assert(not visit(state, remaining), "review acknowledgement must not resolve current input")
end)

test("deferred current-runtime ordering rejects older work and duplicate terminal delivery", function()
	local state = model.new()
	model.reconcile(state, snapshot(10000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 10000 },
	}, context(2000))
	local deferred = snapshot(10010, false)
	deferred.identityReady = false
	model.reconcile(state, deferred, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10010 },
		{ kind = "finished", pane = 11, result = "failed", at = 10020 },
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10005 },
		{ kind = "finished", pane = 11, result = "done", at = 10006 },
		{ kind = "finished", pane = 11, result = "failed", at = 10020 },
	}, context(2001))
	local replayed = row(model.reconcile(state, snapshot(10021, false), {}, context(2002)), 11)
	assert(visit(state, replayed))
	local duplicate = model.reconcile(state, snapshot(10022, false), {
		{ kind = "finished", pane = 11, result = "failed", at = 10020 },
	}, context(2003))
	assert(not row(duplicate, 11).attention)
	local newerFailure = row(model.reconcile(state, snapshot(10023, false), {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10022 },
		{ kind = "finished", pane = 11, result = "failed", at = 10023 },
	}, context(2004)), 11)
	assert(newerFailure and newerFailure.reviewRevision > replayed.reviewRevision)
end)

test("work deferred after a completion retains causal order across another reload", function()
	local state = model.new()
	local first = row(model.reconcile(state, snapshot(10000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 10000 },
	}, context(2000)), 11)
	assert(visit(state, first))
	state = model.new(model.snapshot(state))
	local deferred = snapshot(10020, false)
	deferred.identityReady = false
	model.reconcile(state, deferred, {
		{ kind = "finished", pane = 11, result = "done", at = 10010 },
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10020 },
	}, context(2001))
	state = model.new(model.snapshot(state))
	local replayed = model.reconcile(state, snapshot(1, false), {}, context(2002))
	assert(not row(replayed, 11).attention, "duplicate result precedes the deferred new turn")
	local completed = row(model.reconcile(state, snapshot(2, false), {
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, context(2003)), 11)
	assert(completed and completed.reviewRevision > first.reviewRevision)
end)

for _, restart in ipairs({ "none", "reload", "reload-pending" }) do
	test("a new input request deferred between unchanged waiting snapshots is applied once after proof without reactivating Finished with restart " .. restart, function()
		local state = model.new()
		local waiting = snapshot(100, false)
		waiting.agents[1].state = "waiting_input"
		local first = row(model.reconcile(state, waiting, {}, context(1000)), 11)
		assert(first and first.reviewRevision == nil and first.disposition == "active")
		assert(model.setDisposition(state, "work:" .. tostring(first.serial), "finished", 1001))
		local pending = snapshot(200, false)
		pending.agents[1].state, pending.identityReady = "waiting_input", false
		local held = row(model.reconcile(state, pending, {
			{ kind = "state", pane = 11, old = "waiting_input", new = "working", at = 150 },
			{ kind = "state", pane = 11, old = "working", new = "waiting_input", at = 160 },
		}, context(1002)), 11)
		assert(held and held.disposition == "finished" and held.attentionRevision == first.attentionRevision,
			"identity proof must gate the new request")
		if restart ~= "none" then
			local saved = model.snapshot(state)
			local record
			for _, candidate in ipairs(saved.items) do
				if candidate.serial == first.serial then record = candidate end
			end
			assert(record and record.deferredWaitingUtc == 1002 and record.deferredWork == true and record.deferredPane == 11)
			assert(record.deferredWaitingAt == nil, "runtime clocks are never persisted")
			state = model.new(saved)
			if restart == "reload-pending" then
				local again = snapshot(1, false)
				again.agents[1].state, again.identityReady = "waiting_input", false
				assert(row(model.reconcile(state, again, {}, context(1003)), 11).disposition == "finished")
			end
		end
		local proven = snapshot(if restart == "none" then 300 else 2, false)
		proven.agents[1].state = "waiting_input"
		local promoted = row(model.reconcile(state, proven, {}, context(1004)), 11)
		assert(promoted and promoted.serial == first.serial and promoted.disposition == "finished" and not promoted.attention,
			"the confirmed new request is recorded but never reactivates the Finished row")
		assert(promoted.attentionRevision > first.attentionRevision)
		assert(promoted.firstSeenUtc == 1002 and promoted.reviewRevision == nil)
		local settled = snapshot(if restart == "none" then 301 else 3, false)
		settled.agents[1].state = "waiting_input"
		local replayedOnce = row(model.reconcile(state, settled, if restart == "none" then {
			{ kind = "state", pane = 11, old = "working", new = "waiting_input", at = 160 },
		} else {}, context(1005)), 11)
		assert(replayedOnce.attentionRevision == promoted.attentionRevision and replayedOnce.queueOrder == promoted.queueOrder,
			"the deferred request replays exactly once")
	end)
end

test("predeployment schema2 runtime-clock records are rejected rather than silently losing deferred work", function()
	local state = model.new()
	model.reconcile(state, snapshot(10000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 10000 },
	}, context(2000))
	local saved = model.snapshot(state)
	saved.items[1].deferredPane, saved.items[1].deferredWorkAt = 11, 10010
	assert(not pcall(model.new, saved))
end)

test("pending proof holds only its own pane while every other restored identity resolves", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
		{ kind = "finished", pane = 22, result = "failed", at = 1000 },
	}, context(1000))
	local failedRevision = row(original, 22).reviewRevision
	state = model.new(model.snapshot(state))
	local churn = snapshot(1, false)
	churn.identityPending = { [22] = true }
	local held = model.reconcile(state, churn, {
		{ kind = "state", pane = 22, old = "idle", new = "working", at = 1 },
	}, context(1001))
	local done, failed, chrome = row(held, 11), row(held, 22), row(held, 33)
	assert(done and done.navigable and not done.stale, "a proven restored identity resolves despite another pending pane")
	assert(chrome and chrome.navigable and not chrome.stale, "every unaffected restored identity resolves")
	assert(failed and not failed.navigable and failed.stale and failed.unavailableReason == "identity proof pending",
		"the pending pane alone keeps its restored identity unproven rather than missing")
	assert(failed.serial == row(original, 22).serial and failed.reviewRevision == failedRevision)
	churn.identityPending = nil
	local proven = row(model.reconcile(state, churn, {}, context(1002)), 22)
	assert(proven and proven.navigable and not proven.stale and proven.serial == failed.serial
		and proven.reviewRevision == failedRevision, "the follow-up proof resolves the held pane to the same review")
end)

test("a reused pane with a new conversation stays isolated while another pane's proof is pending", function()
	local state = model.new()
	local original = row(model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
	}, context(1000)), 11)
	state = model.new(model.snapshot(state))
	local reused = snapshot(1, false)
	reused.identities[11], reused.identityPending = "conversation:replacement", { [22] = true }
	local presentation = model.reconcile(state, reused, {
		{ kind = "finished", pane = 11, result = "failed", at = 1 },
	}, context(1001))
	local old, new
	for _, entry in ipairs(presentation.rows) do
		if entry.serial == original.serial then old = entry elseif entry.pane == 11 then new = entry end
	end
	assert(old and not old.navigable and old.identityKey == "conversation:done"
		and old.reviewRevision == original.reviewRevision, "the original conversation never rebinds to the reused pane")
	assert(new and new.navigable and new.identityKey == "conversation:replacement" and new.reviewRevision ~= nil,
		"the new conversation's completion is a separate proven review")
end)

test("a key absent from proven panes is held rather than missing until the pending pane is proven", function()
	local state = model.new()
	local original = row(model.reconcile(state, snapshot(1000, false), {
		{ kind = "finished", pane = 11, result = "done", at = 1000 },
	}, context(1000)), 11)
	state = model.new(model.snapshot(state))
	-- After relaunch the conversation runs in pane 44, whose proof is still pending.
	local relaunched = snapshot(1, false)
	relaunched.panes[44], relaunched.panes[11] = relaunched.panes[11], nil
	relaunched.agents[1].pane = 44
	relaunched.identities = { [22] = "conversation:failed", [33] = "conversation:chrome" }
	relaunched.identityPending = { [44] = true }
	local held = row(model.reconcile(state, relaunched, {}, context(1001)), 11)
	assert(held and held.serial == original.serial and not held.navigable
		and held.unavailableReason == "identity proof pending", "a possibly pending key is not reported missing")
	relaunched.identities[44], relaunched.identityPending = "conversation:done", nil
	local moved = row(model.reconcile(state, relaunched, {}, context(1002)), 44)
	assert(moved and moved.serial == original.serial and moved.navigable
		and moved.reviewRevision == original.reviewRevision, "the proven key rebinds the held review to its new pane")
end)

-- A prior package without inspect saved current-VM rows without identity keys.
local function keyless(events)
	local state = model.new()
	local blind = snapshot(1000, false)
	blind.identityReady, blind.identities = false, {}
	local first = model.reconcile(state, blind, events, context(1000))
	assert(row(first, 11) and row(first, 11).identityKey == nil, "fixture must save a keyless row")
	return model.new(model.snapshot(state)), row(first, 11)
end

test("a keyless restored row binds after proof and new attention joins it instead of duplicating", function()
	local state, original = keyless({ { kind = "finished", pane = 11, result = "failed", at = 1000 } })
	local pendingProof = snapshot(1, false)
	pendingProof.identityReady = false
	local held = model.reconcile(state, pendingProof, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 1 },
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, context(1001))
	assert(#held.rows == 3 and row(held, 11).serial == original.serial and not row(held, 11).navigable,
		"attention during pending proof is held by the keyless record, never a new row")
	local proven = model.reconcile(state, snapshot(3, false), {}, context(1002))
	local bound = row(proven, 11)
	assert(#proven.rows == 3 and bound.serial == original.serial and bound.queueOrder == original.queueOrder)
	assert(bound.navigable and not bound.stale and not bound.orphaned and bound.identityKey == "conversation:done")
	assert(bound.reviewRevision > original.reviewRevision, "the held completion replays onto the bound record")
	assert(model.next(state, 33) == 11, "the bound record is a navigation target")
	local after = model.reconcile(state, snapshot(5, false), {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 4 },
		{ kind = "finished", pane = 11, result = "failed", at = 5 },
	}, context(1003))
	assert(#after.rows == 3 and row(after, 11).serial == original.serial and row(after, 11).reviewRevision > bound.reviewRevision)
	state = model.new(model.snapshot(state))
	local reloaded = model.reconcile(state, snapshot(1, false), {}, context(1004))
	assert(#reloaded.rows == 3 and row(reloaded, 11).serial == original.serial and row(reloaded, 11).navigable
		and row(reloaded, 11).identityKey == "conversation:done")
end)

test("a keyless restored row on a pane without a conversation locator binds by pane continuity", function()
	local state, original = keyless({ { kind = "finished", pane = 11, result = "failed", at = 1000 } })
	local pendingProof = snapshot(1, false)
	pendingProof.identityReady, pendingProof.identities = false, {}
	model.reconcile(state, pendingProof, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 1 },
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, context(1001))
	local nonOmp = snapshot(3, false)
	nonOmp.identities = {}
	local bound = row(model.reconcile(state, nonOmp, {}, context(1002)), 11)
	assert(bound and bound.serial == original.serial and bound.navigable and bound.identityKey == nil)
	assert(bound.reviewRevision > original.reviewRevision and bound.reason == "Turn finished · review pending",
		"held evidence replays on the continuity-bound record rather than staying unverified")
	assert(visit(state, bound) and not row(model.current(state), 11).attention)
	local again = row(model.reconcile(state, nonOmp, {
		{ kind = "finished", pane = 11, result = "failed", at = 4 },
	}, context(1003)), 11)
	assert(again and again.serial == original.serial and again.navigable)
end)

test("a keyless restored row stays orphaned when its pane is absent or in another scope", function()
	local state, original = keyless({ { kind = "finished", pane = 11, result = "failed", at = 1000 } })
	assert(model.setDisposition(state, original.workId, "reference", 1000))
	local absent = snapshot(1, false)
	absent.panes[11], absent.agents[1] = nil, { pane = 44, state = "idle" }
	absent.panes[44], absent.identities[44] = { host = 1, tab = 10, session = 100, title = "Completed task" }, "conversation:other"
	local missing = model.reconcile(state, absent, {}, context(1001))
	local kept
	for _, candidate in ipairs(missing.rows) do if candidate.workId == original.workId then kept = candidate end end
	assert(kept and kept.serial == original.serial and kept.orphaned and not kept.navigable
		and kept.unavailableReason == "No open pane" and kept.identityKey == nil, "a same-title pane never adopts the retained record")
	local elsewhere = context(1002)
	elsewhere.window = "another-window"
	local foreign = model.reconcile(state, snapshot(2, false), {
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	}, elsewhere)
	local old, new = nil, nil
	for _, entry in ipairs(foreign.rows) do
		if entry.serial == original.serial then old = entry elseif entry.pane == 11 then new = entry end
	end
	assert(old and old.orphaned and not old.navigable and old.identityKey == nil, "another window never binds the record")
	assert(new and new.navigable and new.serial ~= original.serial)
end)

local function record(fields)
	local value = { window = "durable-window", hostKey = "local", host = 1, session = 100, sessionName = "Unknown session",
		hostName = "Local", localHost = true, parked = false, floating = false, nativeState = "idle",
		waiting = false, delivery = false, startup = false, alert = false, bucket = "p0", turn = 0 }
	for key, field in pairs(fields) do value[key] = field end
	return value
end

local function nativeDuplicates()
	return { schema = 2, serial = 41, queueOrder = 41, attentionRevision = 41, cursors = {}, records = {
		record({ serial = 5, pane = 11, tab = 10, title = "Completed task", firstSeenUtc = 100, queueOrder = 5,
			attentionRevision = 5, reviewRevision = 5, reviewKind = "failed", turn = 1, finishedTurn = 1, finishedResult = "failed" }),
		record({ serial = 7, pane = 33, tab = 30, title = "Chrome", identityKey = "conversation:chrome", firstSeenUtc = 200,
			queueOrder = 7, attentionRevision = 7, reviewRevision = 7, reviewKind = "update" }),
		record({ serial = 14, pane = 22, tab = 20, title = "Failed task", bucket = "backlog", firstSeenUtc = 300,
			queueOrder = 14, attentionRevision = 14, reviewRevision = 14, reviewKind = "update" }),
		record({ serial = 32, pane = 11, tab = 10, title = "Completed task", identityKey = "conversation:done", firstSeenUtc = 500,
			queueOrder = 32, attentionRevision = 32, reviewRevision = 32, reviewKind = "update",
			turn = 4, finishedTurn = 3, finishedResult = "done" }),
		record({ serial = 41, pane = 22, tab = 20, title = "Failed task", identityKey = "conversation:failed", firstSeenUtc = 600,
			queueOrder = 41, attentionRevision = 41, reviewRevision = 41, reviewKind = "update" }),
	} }
end

test("identity consolidation follows causal source-question state rather than unrelated review freshness", function()
	local state, live = model.new(), snapshot(1, false)
	live.agents = { live.agents[1] }
	live.panes, live.identities = { [11] = live.panes[11] }, { [11] = "conversation:done" }
	live.sources = { [11] = { key = "conversation:done", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:done", path = "/exact/session", sessionId = "merge-questions",
		status = "ready", capturedAtUtc = 1000, revision = "old", schemaVersion = 3,
		writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "old", status = "open", askedAtUtc = 900 } } }
	live.sourceFacts = { [fact.key] = fact }
	local original = model.reconcile(state, live, {
		{ kind = "finished", pane = 11, result = "done", at = 1 },
	}, context(1000)).rows[1]
	live.now, live.agents[1].state = 2, "working"
	model.reconcile(state, live, {}, context(1001))
	live.now, live.agents[1].state = 3, "idle"
	model.reconcile(state, live, {}, context(1002))
	local oldSuppression = model.snapshot(state).items[1]
	fact = table.clone(fact)
	fact.revision, fact.capturedAtUtc = "fresh", 1003
	fact.questions = { fact.questions[1], { id = "fresh", status = "open", askedAtUtc = 1003 } }
	fact.questionCoverage = { status = "complete", knownTotal = 2, included = 2, omitted = 0 }
	live.sourceFacts[fact.key] = fact
	assert(model.reconcile(state, live, {}, context(1003)).rows[1].sourceQuestionCurrent)
	local freshSaved = model.snapshot(state)
	live.now, live.agents[1].state = 4, "working"
	model.reconcile(state, live, {}, context(1004))
	live.now, live.agents[1].state = 5, "idle"
	model.reconcile(state, live, {}, context(1005))
	local newSuppression = model.snapshot(state).items[1]
	for _, mode in ipairs({ "older-suppression", "newer-suppression", "no-question-default" }) do
		local saved = table.clone(freshSaved)
		local duplicate = table.clone(if mode == "newer-suppression" then newSuppression else oldSuppression)
		duplicate.serial, duplicate.queueOrder, duplicate.identityKey = 2, 2, nil
		duplicate.source, duplicate.sourceSessionId = nil, nil
		duplicate.attentionRevision = freshSaved.attentionRevision + 100
		if mode == "no-question-default" then
			duplicate.sourceQuestionSuperseded, duplicate.sourceQuestionRevision = false, nil
		end
		saved.items, saved.serial, saved.queueOrder = { freshSaved.items[1], duplicate }, 2, 2
		saved.attentionRevision = duplicate.attentionRevision
		local mergedState = model.new(saved)
		local merged = model.reconcile(mergedState, live, {}, context(1006))
		local current = merged.rows[1]
		assert(#merged.rows == 1 and current.serial == original.serial and current.reviewSuperseded)
		assert(current.reviewRevision == original.reviewRevision and current.nativeState == "idle")
		assert(current.sourceQuestionCurrent == (mode ~= "newer-suppression") and current.attention == current.sourceQuestionCurrent)
		assert(current.source.questions[2].id == "fresh", "an unrelated no-question record cannot erase established source evidence")
		local reloaded = model.new(model.snapshot(mergedState))
		local restored = model.reconcile(reloaded, live, {}, context(1007)).rows[1]
		assert(restored.sourceQuestionCurrent == current.sourceQuestionCurrent and restored.reviewRevision == original.reviewRevision)
	end
end)

test("active gap qualification survives identity consolidation and repeated restore", function()
	local state, live = model.new(), snapshot(1, false)
	live.agents = { live.agents[1] }
	live.panes, live.identities = { [11] = live.panes[11] }, { [11] = "conversation:done" }
	local fact = { key = "conversation:done", path = "/exact/session", sessionId = "merge-recovery",
		status = "ready", capturedAtUtc = 1000, revision = "old", schemaVersion = 3,
		writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "old", status = "open", askedAtUtc = 900 } } }
	live.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
	live.sourceFacts = { [fact.key] = fact }
	local first = model.reconcile(state, live, { { kind = "finished", pane = 11, result = "done", at = 1 } }, context(1000)).rows[1]
	live.now, live.agents[1].state = 2, "working"
	model.reconcile(state, live, {}, context(1001))
	live.sourceFacts[fact.key] = { key = fact.key, path = fact.path, status = "missing", capturedAtUtc = 1002 }
	live.now, live.agents[1].state = 3, "idle"
	model.reconcile(state, live, {}, context(1002))
	local saved = model.snapshot(state)
	local duplicate = table.clone(saved.items[1])
	duplicate.serial, duplicate.queueOrder, duplicate.identityKey = 2, 2, nil
	duplicate.source, duplicate.sourceSessionId, duplicate.sourceQuestionBaseline = nil, nil, nil
	duplicate.attentionRevision = saved.attentionRevision + 100
	saved.items[2], saved.serial, saved.queueOrder, saved.attentionRevision = duplicate, 2, 2, duplicate.attentionRevision
	state = model.new(saved)
	fact = table.clone(fact)
	fact.revision, fact.capturedAtUtc = "recovered", 1004
	fact.questions = { fact.questions[1], { id = "fresh", status = "open", askedAtUtc = 1003 } }
	fact.questionCoverage = { status = "complete", knownTotal = 2, included = 2, omitted = 0 }
	live.sourceFacts[fact.key] = fact
	local recovered = model.reconcile(state, live, {}, context(1004))
	assert(#recovered.rows == 1 and recovered.rows[1].attention and recovered.rows[1].sourceQuestionCurrent)
	assert(recovered.rows[1].reviewSuperseded and recovered.rows[1].reviewRevision == first.reviewRevision)
	local revision = recovered.rows[1].attentionRevision
	state = model.new(model.snapshot(state))
	local repeated = model.reconcile(state, live, {}, context(1005)).rows[1]
	assert(repeated.attention and repeated.attentionRevision == revision and repeated.reviewSuperseded)
end)

test("identity consolidation keeps supersession but does not retire a genuinely newer review", function()
	for _, superseded in ipairs({ true, false }) do
		local saved = nativeDuplicates()
		saved.records[1].reviewSuperseded, saved.records[1].turn = true, 4
		saved.records[4].reviewSuperseded = superseded
		local state = model.new(saved)
		local quiet = snapshot(1, false)
		quiet.agents[3].state = "idle"
		local merged = row(model.reconcile(state, quiet, {}, context(1001)), 11)
		assert(merged.serial == 5 and merged.reviewRevision == 32 and merged.identityKey == "conversation:done")
		assert(merged.reviewSuperseded == superseded and merged.attention == not superseded)
		state = model.new(model.snapshot(state))
		local reloaded = row(model.reconcile(state, quiet, {}, context(1002)), 11)
		assert(reloaded.serial == 5 and reloaded.reviewRevision == 32 and reloaded.attention == not superseded)
	end
end)

test("saved keyless and keyed duplicates of one pane merge into one stable row with the newer review", function()
	local state = model.new(nativeDuplicates())
	assert(#model.current(state).rows == 5, "duplicates restore before proof as saved")
	local quiet = snapshot(1, false)
	quiet.agents[3].state = "idle"
	local revision = state.persistenceRevision
	local merged = model.reconcile(state, quiet, {}, context(1001))
	assert(state.persistenceRevision > revision, "proven duplicate merges persist their migration")
	assert(#merged.rows == 3 and row(merged, 11).serial == 5 and row(merged, 33).serial == 7 and row(merged, 22).serial == 14,
		"the earlier serial and queue position survive")
	local feed, taste = row(merged, 11), row(merged, 22)
	assert(feed.pane == 11 and feed.queueOrder == 5 and feed.reviewRevision == 32 and feed.reason == "Unreviewed update")
	assert(feed.firstSeenUtc == 500 and feed.identityKey == "conversation:done" and feed.navigable and feed.disposition == "active")
	assert(taste.pane == 22 and taste.queueOrder == 14 and taste.reviewRevision == 41 and taste.disposition == "active"
		and taste.firstSeenUtc == 600 and taste.identityKey == "conversation:failed" and taste.navigable)
	local saved = model.snapshot(state)
	assert(#saved.items == 3 and saved.records == nil and saved.cursors == nil)
	for _, entry in ipairs(saved.items) do
		if entry.serial == 5 then
			assert(entry.turn == 4 and entry.finishedTurn == 3 and entry.finishedResult == "done" and entry.reviewKind == "update",
				"observation cursors come from the newer record as one consistent set")
		end
	end
	assert(model.next(state) == 11)
	state = model.new(saved)
	local reloaded = model.reconcile(state, quiet, {}, context(1002))
	assert(#reloaded.rows == 3 and row(reloaded, 11).serial == 5 and row(reloaded, 22).serial == 14)
	assert(#model.snapshot(state).items == 3, "reload after merge stays single")
	local repeated = model.reconcile(state, quiet, {
		{ kind = "finished", pane = 22, result = "failed", at = 2 },
	}, context(1003))
	assert(#repeated.rows == 3 and row(repeated, 22).serial == 14, "new attention joins the merged record")
end)

test("a keyless record never merges with a record whose key the pane no longer proves", function()
	local saved = nativeDuplicates()
	saved.records[4].identityKey = "conversation:previous"
	local state = model.new(saved)
	local quiet = snapshot(1, false)
	quiet.agents[3].state = "idle"
	local presentation = model.reconcile(state, quiet, {}, context(1001))
	local keylessRow, isolated
	for _, entry in ipairs(presentation.rows) do
		if entry.serial == 5 then keylessRow = entry elseif entry.serial == 32 then isolated = entry end
	end
	assert(#presentation.rows == 4 and keylessRow and isolated)
	assert(keylessRow.navigable and keylessRow.identityKey == "conversation:done" and keylessRow.reviewRevision == 5)
	assert(isolated.orphaned and not isolated.navigable and isolated.identityKey == "conversation:previous"
		and isolated.reviewRevision == 32, "a different proven key stays isolated")
end)

test("durable snapshot reuse keeps persisted output exact and re-copies only changed records", function()
	local state, live = model.new(), snapshot(1, false)
	live.sources = { [11] = { key = "conversation:done", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:done", path = "/exact/session", sessionId = "durable-copy-session",
		status = "ready", capturedAtUtc = 1000, revision = "cache", schemaVersion = 3,
		writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 },
		lastFinal = { id = "final", atUtc = 900, timeKind = "completed", text = string.rep("retained evidence ", 512) } }
	live.sourceFacts = { [fact.key] = fact }
	local opening = model.reconcile(state, live, {}, context(1000))
	assert(#opening.rows == 3, "the fixture opens three conversations")
	local stored = model.snapshot(state)
	assert(stored.items[1].pane == 11 and stored.items[1].source ~= nil
		and utf8.len(stored.items[1].source.lastFinal.text) == 300 and stored.items[1].source.lastFinal.textTruncated == true,
		"a stored reply keeps only the excerpt the rail shows, marked truncated")

	local unchanged = model.snapshot(state)
	assert(same(unchanged, stored), "an unchanged store persists the same document")
	assert(unchanged.items[1] ~= stored.items[1], "a same-revision snapshot hands out fresh tables")

	assert(model.setPriority(state, row(opening, 22).workId, 1))
	local edited = model.snapshot(state)
	assert(edited.items[2] ~= unchanged.items[2], "the changed record is re-copied")
	assert(edited.items[1] == unchanged.items[1] and edited.items[3] == unchanged.items[3],
		"unchanged records, including the large retained evidence, reuse their cached durable copies")
	local expected = copy(unchanged)
	expected.items[2].priority = 1
	assert(same(edited, expected), "a single-entry change persists exactly that change")

	model.reconcile(state, live, { { kind = "closed", pane = 33 } }, context(1001))
	local pruned = model.snapshot(state)
	expected = copy(edited)
	table.remove(expected.items, 3)
	assert(same(pruned, expected), "an entry delete persists exactly the removal")
	assert(pruned.items[1] == edited.items[1] and pruned.items[2] == edited.items[2],
		"surviving unchanged records still reuse their cached durable copies")

	live.agents = { live.agents[1], live.agents[2], { pane = 44, state = "idle" } }
	live.identities[33], live.identities[44] = nil, "conversation:new"
	live.panes[33], live.panes[44] = nil, { host = 1, tab = 40, session = 400, title = "Newly opened", alert = false }
	local grown = model.reconcile(state, live, {}, context(1002))
	assert(#grown.rows == 3 and row(grown, 44) ~= nil, "the fixture opens a replacement conversation")
	local created = model.snapshot(state)
	assert(#created.items == 3 and created.items[3].pane == 44 and created.items[3].title == "Newly opened"
		and created.items[3].identityKey == "conversation:new", "a created entry persists as a new sorted item")
	assert(created.items[1] == pruned.items[1] and created.items[2] == pruned.items[2],
		"existing unchanged records still reuse their cached durable copies")

	local rehydrated = model.snapshot(model.new(created))
	assert(same(rehydrated, created), "a hydrated store persists the same document")
	assert(rehydrated.items[1] ~= created.items[1] and rehydrated.items[3] ~= created.items[3],
		"hydration resets the durable-copy cache so restored stores never serve shared snapshots")

	-- A store saved before replies were bounded (full reply text, human text, in both the source and its last-known
	-- ledger) loads bounded and is marked for one rewrite.
	local legacy = copy(created)
	local legacySource = legacy.items[1].source
	legacySource.lastFinal.text, legacySource.lastFinal.textTruncated = string.rep("é", 400), nil
	legacySource.lastHuman = { id = "human", atUtc = 800, provenance = "user", text = "private prompt" }
	legacySource.lastKnown = { lastAssistant = { id = "older", atUtc = 700, stopReason = "stop", text = string.rep("a", 301) } }
	local migrated = model.new(legacy)
	local loaded = model.snapshot(migrated).items[1].source
	assert(migrated.persistenceRevision > 0, "a store holding unbounded replies is rewritten once")
	assert(loaded.lastFinal.text == string.rep("é", 300) and loaded.lastFinal.textTruncated == true
		and loaded.lastKnown.lastAssistant.text == string.rep("a", 300) and loaded.lastHuman.text == nil
		and loaded.lastHuman.atUtc == 800, "stored replies keep the shown excerpt (whole characters) and human input keeps its time")
	assert(model.new(model.snapshot(migrated)).persistenceRevision == 0, "a bounded store loads without another rewrite")
end)

test("retired Later records and legacy Backlog buckets load as retained Finished without their dates", function()
	local state = model.new()
	local first = row(model.reconcile(state, snapshot(1000, false), {}, context(1000)), 33)
	local saved = model.snapshot(state)
	local input
	for _, item in ipairs(saved.items) do if item.serial == first.serial then input = item end end
	input.disposition, input.retained = "later", nil
	input.untilUtc, input.availableOn, input.availableTime, input.zone = 5000, "2026-11-03", "09:00", "UTC"
	input.blockerEpisode, input.laterEpisode, input.laterUtc = 3, 2, 1500
	local loaded = model.new(saved)
	assert(loaded.persistenceRevision > 0, "a record carrying retired Later state is rewritten")
	local migrated = model.current(loaded).rows
	for _, entry in ipairs(migrated) do
		if entry.serial == first.serial then
			assert(entry.disposition == "finished" and entry.retained and not entry.attention)
			for _, retired in ipairs({ "untilUtc", "availableOn", "availableTime", "zone" }) do assert(entry[retired] == nil) end
		end
	end
	local resaved = model.snapshot(loaded)
	for _, item in ipairs(resaved.items) do
		if item.serial == first.serial then
			assert(item.disposition == "finished" and item.retained == true)
			for _, retired in ipairs({ "untilUtc", "availableOn", "availableTime", "zone", "blockerEpisode", "laterEpisode", "laterUtc" }) do
				assert(item[retired] == nil, retired)
			end
		end
	end
	assert(model.new(resaved).persistenceRevision == 0, "the migrated store loads without further rewrites")

	for _, bucketRecords in ipairs({
		{ schema = 1, records = { { window = "", host = "local", pane = 11, firstSeenUtc = 100, bucket = "backlog" } } },
		{ schema = 2, serial = 5, queueOrder = 5, attentionRevision = 5, cursors = {}, records = {
			record({ serial = 5, pane = 11, tab = 10, title = "Legacy", bucket = "backlog", firstSeenUtc = 100,
				queueOrder = 5, attentionRevision = 5, reviewRevision = 5, reviewKind = "update" }) } },
	}) do
		local items = model.snapshot(model.new(bucketRecords)).items
		assert(#items == 1 and items[1].disposition == "finished" and items[1].retained == true and items[1].firstSeenUtc == 100)
	end
end)

return true
