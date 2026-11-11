local model = require("../model")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function pane(id, fields)
	local value = { pane = id, host = 1, tab = 10, session = 100, title = "Agent " .. tostring(id),
		sessionName = "Workspace", hostName = "Local", alert = false, parked = false, floating = false }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

local function agent(id, state, deliveryError)
	return { pane = id, state = state, deliveryError = deliveryError }
end

local function snapshot(now, agents, panes, hosts)
	if panes == nil then
		panes = {}
		for _, entry in ipairs(agents) do panes[entry.pane] = pane(entry.pane) end
	end
	local identities = {}
	for id in pairs(panes) do identities[id] = "conversation:" .. tostring(id) end
	return { now = now, ok = true, agents = agents, panes = panes, identityReady = true, identities = identities,
		hosts = hosts or { [1] = { id = 1, key = "local", name = "Local", connected = true } } }
end

local function row(presentation, id)
	for _, entry in ipairs(presentation.rows) do if entry.pane == id then return entry end end
	return nil
end

local function healthy(presentation, expected)
	assert(presentation.status == "ready" and presentation.count == #presentation.rows)
	assert(presentation.knownCount == #presentation.rows and presentation.attentionCount == expected)
end

local function visit(state, id)
	local selected = row(model.current(state), id)
	return model.visit(state, id, selected.reviewRevision, selected.serial)
end

local function take(state, expected, focused)
	local target, _, serial = model.next(state, focused)
	assert(target == expected, "expected pane " .. tostring(expected) .. ", got " .. tostring(target))
	local selected = row(model.current(state), target)
	assert(serial == selected.serial)
	model.visit(state, target, selected.reviewRevision, serial)
end

test("failed initial coverage and unknown states never claim a quiet complete inbox", function()
	local state = model.new()
	assert(model.current(state).count == nil and model.current(state).status == "loading")
	local failed = model.reconcile(state, { ok = false, error = "offline" }, {})
	assert(failed.count == nil and failed.knownCount == 0 and model.next(state) == nil)
	local unknown = model.reconcile(state, snapshot(1, { agent(11, "future_state") }), {})
	assert(unknown.count == nil and #unknown.rows == 0 and model.next(state) == nil)
end)

test("idle working and exited inventories do not fabricate literal completions", function()
	local state = model.new()
	healthy(model.reconcile(state, snapshot(1, { agent(11, "idle"), agent(12, "exited") }), {}), 0)
	model.reconcile(state, snapshot(2, { agent(11, "working") }), {})
	healthy(model.reconcile(state, snapshot(3, { agent(11, "idle") }), {
		{ kind = "state", pane = 11, old = "working", new = "idle", at = 3 },
	}), 0)
	local nonAgent = snapshot(4, {}, { [99] = pane(99, { alert = true, startupError = "shell error" }) })
	healthy(model.reconcile(state, nonAgent, {}), 0)
end)

test("proven duplicate routes merge conditions without replacing canonical pane metadata", function()
	for _, canonical in ipairs({ "idle", "exited" }) do
		local state = model.new()
		local first = model.reconcile(state, snapshot(1, { agent(22, canonical) }), {}).rows[1]
		local live = snapshot(2, { agent(11, "working"), agent(22, canonical), agent(33, "waiting_input", "delivery") }, {
			[11] = pane(11, { title = "Duplicate worker" }),
			[22] = pane(22, { title = "Preferred route", tab = 20, session = 200, parked = true }),
			[33] = pane(33, { title = "Duplicate blocker", alert = true, startupError = "startup" }),
		})
		live.identities[11], live.identities[33] = first.identityKey, first.identityKey
		local merged = model.reconcile(state, live, {})
		healthy(merged, 1)
		assert(#merged.rows == 1 and merged.reachableCount == 1 and merged.attentionTargets[22])
		assert(merged.attentionTargets[11] == nil and merged.attentionTargets[33] == nil)
		local selected = merged.rows[1]
		assert(selected.workId == first.workId and selected.pane == 22 and selected.title == "Preferred route")
		assert(selected.tab == 20 and selected.session == 200 and selected.parked)
		assert(selected.nativeState == "waiting_input" and selected.condition == "waiting")
		assert(selected.reviewKind == "update" and selected.reviewRevision ~= nil and not selected.reviewSuperseded)
		local stored = model.snapshot(state).items[1]
		assert(stored.waiting and stored.delivery and stored.startup and stored.alert)

		live.now, live.agents[3].state = 3, "idle"
		local working = model.reconcile(state, live, {})
		healthy(working, 1)
		assert(working.rows[1].nativeState == "working" and working.rows[1].condition == "delivery")
		assert(working.rows[1].reviewRevision == selected.reviewRevision and working.rows[1].reviewSuperseded)
		live.now, live.agents[3].deliveryError = 4, nil
		local startup = model.reconcile(state, live, {})
		healthy(startup, 1)
		assert(startup.rows[1].condition == "startup")
		live.now, live.panes[33].startupError, live.panes[33].alert = 5, nil, false
		local quiet = model.reconcile(state, live, {})
		healthy(quiet, 0)
		assert(quiet.rows[1].nativeState == "working" and quiet.rows[1].condition == nil)
		live.now, live.agents[1].state = 6, "idle"
		local settled = model.reconcile(state, live, {})
		healthy(settled, 0)
		assert(settled.rows[1].nativeState == canonical and settled.rows[1].pane == 22)
		local revision = state.persistenceRevision
		model.reconcile(state, live, {})
		assert(state.persistenceRevision == revision, "unchanged merged observations do not write again")
	end
end)

test("unhealthy and unproven duplicate routes cannot contribute native conditions", function()
	for _, excluded in ipairs({ "unhealthy", "pending", "missing-agent" }) do
		local state = model.new()
		local first = model.reconcile(state, snapshot(1, { agent(22, "idle") }), {}).rows[1]
		local live = snapshot(2, { agent(11, "waiting_input", "delivery"), agent(22, "idle") }, {
			[11] = pane(11, { host = 2, alert = true, startupError = "startup" }), [22] = pane(22),
		}, {
			[1] = { key = "local", connected = true }, [2] = { key = "remote", connected = excluded ~= "unhealthy" },
		})
		live.identities[11] = first.identityKey
		if excluded == "pending" then live.identityPending = { [11] = true }
		elseif excluded == "missing-agent" then table.remove(live.agents, 1) end
		local current = model.reconcile(state, live, {})
		assert(#current.rows == 1 and current.knownCount == 1 and current.attentionCount == 0)
		assert(current.reachableCount == 0 and next(current.attentionTargets) == nil)
		assert(current.rows[1].pane == 22 and current.rows[1].nativeState == "idle")
		assert(current.rows[1].condition == nil and current.rows[1].reviewRevision == nil)
		local stored = model.snapshot(state).items[1]
		assert(not stored.waiting and not stored.delivery and not stored.startup and not stored.alert)
	end
end)

test("reserved canonical routes and incoherent snapshots retain the last merged conditions", function()
	for _, gate in ipairs({ "reserved", "incoherent" }) do
		local state = model.new()
		local live = snapshot(1, { agent(11, "idle"), agent(22, "idle") })
		live.identities[22] = live.identities[11]
		local first = model.reconcile(state, live, {}).rows[1]
		live.now, live.agents[2].state, live.agents[2].deliveryError = 2, "waiting_input", "delivery"
		live.panes[22].alert, live.panes[22].startupError = true, "startup"
		if gate == "reserved" then live.identityPending = { [11] = true, [22] = true } end
		local held = model.reconcile(state, live, {}, { coherent = gate ~= "incoherent" })
		assert(#held.rows == 1 and held.rows[1].serial == first.serial)
		assert(held.rows[1].nativeState == "idle" and held.rows[1].condition == nil and held.rows[1].stale)
		assert(held.attentionCount == 0 and held.rows[1].reviewRevision == nil)
		live.identityPending = nil
		local proven = model.reconcile(state, live, {}, { coherent = true })
		healthy(proven, 1)
		assert(proven.rows[1].serial == first.serial and proven.rows[1].pane == 11)
		assert(proven.rows[1].nativeState == "waiting_input" and proven.rows[1].condition == "waiting")
	end
end)

test("resuming work supersedes unread review without acknowledging it or resurrecting on idle", function()
	for _, callback in ipairs({ false, true }) do
		local state = model.new()
		local first = row(model.reconcile(state, snapshot(1, { agent(11, "idle") }), {
			{ kind = "finished", pane = 11, result = "done", at = 1 },
		}), 11)
		local resumed = model.reconcile(state, snapshot(2, { agent(11, "working") }), if callback then {
			{ kind = "state", pane = 11, old = "idle", new = "working", at = 2 },
		} else {})
		local working = row(resumed, 11)
		healthy(resumed, 0)
		assert(working.nativeState == "working" and working.reviewSuperseded == true)
		assert(working.reviewRevision == first.reviewRevision and working.reviewKind == "done")
		assert(resumed.reachableCount == 0 and resumed.attentionTargets[11] == nil and model.next(state) == nil)
		local idle = model.reconcile(state, snapshot(3, { agent(11, "idle") }), {})
		healthy(idle, 0)
		assert(row(idle, 11).reviewRevision == first.reviewRevision and row(idle, 11).reviewSuperseded)
		local fresh = row(model.reconcile(state, snapshot(4, { agent(11, "idle") }), {
			{ kind = "finished", pane = 11, result = "done", at = 4 },
		}), 11)
		assert(fresh.attention and not fresh.reviewSuperseded and fresh.reviewRevision > first.reviewRevision)
		assert(not model.visit(state, 11, first.reviewRevision, first.serial))
		assert(row(model.current(state), 11).attention)
		assert(visit(state, 11) and not row(model.current(state), 11).attention)
	end
end)

test("current completion waits for settled runtime while older and duplicate completions stay superseded", function()
	for _, order in ipairs({ "result-work", "work-result" }) do
		local state = model.new()
		model.reconcile(state, snapshot(1, { agent(11, "idle") }), {})
		local work = { kind = "state", pane = 11, old = "idle", new = "working", at = 2 }
		local finish = { kind = "finished", pane = 11, result = "done", at = if order == "result-work" then 1 else 2 }
		local events = if order == "result-work" then { finish, work } else { work, finish }
		local busy = row(model.reconcile(state, snapshot(2, { agent(11, "working") }), events), 11)
		assert(not busy.attention and busy.reviewRevision ~= nil)
		assert(busy.reviewSuperseded == (order == "result-work"))
		local settled = row(model.reconcile(state, snapshot(3, { agent(11, "idle") }), {}), 11)
		assert(settled.attention == (order == "work-result"))
		assert(settled.reviewRevision == busy.reviewRevision)
		local duplicate = row(model.reconcile(state, snapshot(4, { agent(11, "idle") }), { finish }), 11)
		assert(duplicate.reviewRevision == busy.reviewRevision and duplicate.attention == settled.attention)
	end
	local state = model.new()
	model.reconcile(state, snapshot(1, { agent(11, "idle") }), {})
	model.reconcile(state, snapshot(3, { agent(11, "working") }), {})
	local late = row(model.reconcile(state, snapshot(4, { agent(11, "working") }), {
		{ kind = "finished", pane = 11, result = "failed", at = 2 },
	}), 11)
	assert(late.reviewRevision ~= nil and late.reviewSuperseded and not late.attention)
	assert(not row(model.reconcile(state, snapshot(5, { agent(11, "idle") }), {}), 11).attention)
end)

test("fresh qualified source questions independently enter Attention after resumed work settles", function()
	local state = model.new()
	local live = snapshot(1, { agent(11, "idle") })
	live.sessions, live.tabs, live.sessionOrder = { [100] = { host = 1, name = "Workspace" } }, { [10] = { session = 100 } }, { 100 }
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "question-turns",
		status = "ready", capturedAtUtc = 100, revision = "old-question", schemaVersion = 3,
		writerVersions = { "18.14.0" }, selection = "disk-replayed", complete = true, coverage = {},
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "old-question", status = "open", askedAtUtc = 90, text = "Old request" } },
		lastFinal = { id = "old-reply", atUtc = 95, timeKind = "completed", text = "Original completed reply" } }
	live.sourceFacts = { [fact.key] = fact }
	local function replay(now, events)
		return model.reconcile(state, live, events or {}, { window = "", nowUtc = now, coherent = true,
			hostKeys = { [1] = "local" }, connected = { ["local"] = true } })
	end
	local original = row(replay(100, { { kind = "finished", pane = 11, result = "done", at = 1 } }), 11)
	live.now, live.agents[1].state = 2, "working"
	assert(not row(replay(101), 11).sourceQuestionCurrent)
	live.now, live.agents[1].state = 3, "idle"
	local quiet = replay(102)
	healthy(quiet, 0)
	assert(not row(quiet, 11).sourceQuestionCurrent and row(quiet, 11).reviewSuperseded)
	assert(model.next(state) == nil and model.sessionGroups(quiet, live, true)[1].attentionConversations == 0)
	fact = table.clone(fact)
	fact.capturedAtUtc, fact.revision = 104, "fresh-question"
	fact.questions = { fact.questions[1], { id = "fresh-question", status = "open", askedAtUtc = 104, text = "Choose current target" } }
	fact.questionCoverage = { status = "complete", knownTotal = 2, included = 2, omitted = 0 }
	live.sourceFacts[fact.key] = fact
	local current = replay(104)
	local fresh = row(current, 11)
	healthy(current, 1)
	assert(fresh.disposition == "active" and fresh.sourceQuestionCurrent and fresh.nativeState == "idle" and fresh.condition == nil)
	assert(fresh.reviewSuperseded and fresh.reviewRevision == original.reviewRevision and fresh.reviewKind == "done")
	assert(fresh.reason == "Recorded question unresolved" and fresh.source.lastFinal.id == "old-reply")
	assert(fresh.source.questions[1].status == "open" and fresh.source.questions[2].text == "Choose current target")
	assert(current.attentionTargets[11] and current.reachableCount == 1 and model.next(state) == 11)
	local session = model.sessionGroups(current, live, true)[1]
	assert(session.attentionConversations == 1 and session.attentionTabs == 1)
	local repeated = row(replay(105), 11)
	assert(repeated.attentionRevision == fresh.attentionRevision and repeated.sourceQuestionCurrent)
	assert(model.visit(state, 11, original.reviewRevision, original.serial))
	assert(row(model.current(state), 11).attention and row(model.current(state), 11).sourceQuestionCurrent,
		"acknowledging an old completed review does not answer the fresh recorded question")
end)

test("working alerts stay out of Attention while live blockers remain reachable after Open", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "working"), agent(12, "working", "not delivered"), agent(13, "working") },
		{ [11] = pane(11, { alert = true }), [12] = pane(12), [13] = pane(13, { startupError = "not started" }) })
	local first = model.reconcile(state, data, {})
	healthy(first, 2)
	assert(not row(first, 11).attention and row(first, 11).reviewRevision ~= nil and row(first, 11).reviewSuperseded)
	assert(row(first, 12).condition == "delivery" and row(first, 13).condition == "startup")
	assert(first.attentionTargets[11] == nil and first.attentionTargets[12] and first.attentionTargets[13])
	take(state, 12); take(state, 13)
	healthy(model.current(state), 2)
	local settled = model.reconcile(state, snapshot(2, { agent(11, "idle"), agent(12, "idle"), agent(13, "idle") }), {})
	healthy(settled, 0)
	assert(row(settled, 11).reviewRevision == row(first, 11).reviewRevision)
end)

test("literal done failed and exited create review evidence without native alert", function()
	for _, result in ipairs({ "done", "failed", "exited" }) do
		local state = model.new()
		local first = model.reconcile(state, snapshot(1, { agent(11, "idle") }), {
			{ kind = "finished", pane = 11, result = result, at = 1 },
		})
		healthy(first, 1)
		assert(row(first, 11).reviewRevision ~= nil)
		local genericFocus = model.reconcile(state, snapshot(2, { agent(11, "idle") }), {
			{ kind = "focus", pane = 11, at = 2 },
		})
		assert(row(genericFocus, 11).reviewRevision == row(first, 11).reviewRevision)
		assert(model.next(state, 11) == 11, "focused review target must still be selectable")
		assert(visit(state, 11))
		healthy(model.current(state), 0)
	end
end)

test("review and live conditions clear independently", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {})
	assert(row(first, 11).reviewRevision == nil)
	assert(not visit(state, 11))
	local target, reason = model.next(state, 11)
	assert(target == nil and reason == "Already here · still needs input")
	local failed = model.reconcile(state, snapshot(2, { agent(11, "waiting_input") }), {
		{ kind = "finished", pane = 11, result = "failed", at = 2 },
	})
	local serial = row(failed, 11).serial
	assert(visit(state, 11))
	assert(row(model.current(state), 11).reviewRevision == nil and row(model.current(state), 11).serial == serial)
	healthy(model.reconcile(state, snapshot(3, { agent(11, "working") }), {}), 0)
	local again = model.reconcile(state, snapshot(4, { agent(11, "waiting_input") }), {
		{ kind = "finished", pane = 11, result = "done", at = 4 },
	})
	local captured = row(again, 11)
	local resolved = model.reconcile(state, snapshot(5, { agent(11, "idle") }), {})
	assert(row(resolved, 11).reviewRevision == captured.reviewRevision)
	assert(visit(state, 11))
	healthy(model.current(state), 0)
end)

test("delivery and startup conditions survive visits and clear on observed resolution", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(1, {
		agent(11, "idle", "delivery refused"), agent(12, "exited"),
	}, { [11] = pane(11), [12] = pane(12, { startupError = "launch refused" }) }), {})
	healthy(first, 2)
	assert(row(first, 11).reason ~= row(first, 12).reason)
	visit(state, 11); visit(state, 12)
	healthy(model.current(state), 2)
	local resolved = model.reconcile(state, snapshot(2, { agent(11, "idle"), agent(12, "exited") },
		{ [11] = pane(11), [12] = pane(12, { startupError = "launch refused" }) }), {})
	assert(not row(resolved, 11).attention and row(resolved, 12).attention)
	healthy(model.reconcile(state, snapshot(3, { agent(11, "idle"), agent(12, "exited") }), {}), 0)
end)

test("native alert false never acknowledges and unchanged true never resurrects a reviewed update", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "idle") }, { [11] = pane(11, { alert = true, parked = true, floating = true }) })
	local first = model.reconcile(state, data, {})
	assert(first.rows[1].parked and first.rows[1].floating)
	local captured = first.rows[1]
	local cleared = model.reconcile(state, snapshot(2, { agent(11, "idle") }), {})
	assert(cleared.rows[1].reviewRevision == captured.reviewRevision)
	assert(visit(state, 11))
	data.now = 3
	local newer = model.reconcile(state, data, {})
	assert(newer.rows[1].reviewRevision ~= captured.reviewRevision)
	assert(visit(state, 11))
	healthy(model.reconcile(state, data, {}), 0)
end)

test("captured nil or older revision advances navigation without erasing a racing update", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input"), agent(22, "waiting_input") })
	local first = model.reconcile(state, data, {})
	local captured = row(first, 11)
	assert(model.next(state) == 11)
	local newer = model.reconcile(state, data, { { kind = "finished", pane = 11, result = "failed", at = 2 } })
	assert(not model.visit(state, 11, captured.reviewRevision, captured.serial))
	assert(row(model.current(state), 11).reviewRevision == row(newer, 11).reviewRevision)
	assert(model.next(state) == 22)
	take(state, 22)
	take(state, 11)
	assert(row(model.current(state), 11).reviewRevision == nil)
end)

test("early literal completion survives join lag, inventory failure and arbitrary elapsed time", function()
	local state = model.new()
	local incomplete = snapshot(1, { agent(11, "working") }, {})
	local early = model.reconcile(state, incomplete, { { kind = "finished", pane = 11, result = "done", at = 1 } })
	assert(#early.rows == 1 and early.rows[1].reviewRevision ~= nil and not early.rows[1].navigable)
	local serial, revision = early.rows[1].serial, early.rows[1].reviewRevision
	local offline = model.reconcile(state, { ok = false }, {})
	assert(offline.rows[1].serial == serial and offline.rows[1].reviewRevision == revision)
	local joined = model.reconcile(state, snapshot(100000, { agent(11, "idle") }), {})
	assert(#joined.rows == 1 and joined.rows[1].serial == serial and joined.rows[1].navigable)
	assert(joined.rows[1].reviewRevision == revision)
end)

test("duplicate done is quiet until observed new work and older events cannot replace newer evidence", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "idle") })
	local first = model.reconcile(state, data, { { kind = "finished", pane = 11, result = "done", at = 1 } })
	for _, at in ipairs({ 1, 3, 10000 }) do
		local repeated = model.reconcile(state, data, { { kind = "finished", pane = 11, result = "done", at = at } })
		assert(repeated.rows[1].reviewRevision == first.rows[1].reviewRevision)
	end
	local newer = model.reconcile(state, data, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10001 },
		{ kind = "finished", pane = 11, result = "done", at = 10002 },
	})
	assert(newer.rows[1].reviewRevision > first.rows[1].reviewRevision)
	assert(newer.rows[1].serial == first.rows[1].serial and newer.rows[1].queueOrder == first.rows[1].queueOrder)
	local older = model.reconcile(state, data, { { kind = "finished", pane = 11, result = "failed", at = 1 } })
	assert(older.rows[1].reviewRevision == newer.rows[1].reviewRevision)
end)

test("absent disconnected and partial partitions retain metadata but never route unverified panes", function()
	local state = model.new()
	local hosts = { [1] = { key = "local", connected = true }, [2] = { key = "remote", name = "Remote", connected = true } }
	local data = snapshot(1, { agent(11, "waiting_input"), agent(22, "waiting_input") },
		{ [11] = pane(11), [22] = pane(22, { host = 2, sessionName = "Remote work" }) }, hosts)
	local first = model.reconcile(state, data, {}, { nowUtc = 100 })
	hosts[2].connected = false
	local partial = model.reconcile(state, data, {}, { nowUtc = 110 })
	assert(partial.status == "partial" and partial.count == nil and partial.knownCount == 2)
	assert(#partial.offlineHosts == 1 and partial.offlineHosts[1].name == "Remote"
		and partial.offlineHosts[1].key == "remote", "partial coverage names exactly its offline hosts")
	assert(row(partial, 22).stale and not row(partial, 22).navigable)
	assert(row(partial, 22).sessionName == "Remote work" and row(partial, 22).serial == row(first, 22).serial)
	assert(model.next(state) == 11)
	data.panes[11], data.agents = nil, {}
	local absent = model.reconcile(state, data, {}, { nowUtc = 111 })
	assert(#absent.rows == 1 and row(absent, 11) == nil and not row(absent, 22).navigable)
	assert(model.next(state) == nil)
end)

test("closure wins even on failed snapshots and cannot leave a stale round target", function()
	for _, kind in ipairs({ "closed", "finished" }) do
		local state = model.new()
		model.reconcile(state, snapshot(1, { agent(11, "waiting_input"), agent(22, "waiting_input") }), {})
		assert(model.next(state) == 11)
		local closed = model.reconcile(state, { ok = false }, {
			{ kind = kind, pane = 11, result = "closed", at = 2 },
			{ kind = "finished", pane = 11, result = "done", at = 2 },
		})
		assert(row(closed, 11) == nil and row(closed, 22) ~= nil and closed.count == nil)
		local recovered = model.reconcile(state, snapshot(3, { agent(22, "waiting_input") }), {})
		assert(#recovered.rows == 1 and model.next(state) == 22)
	end
end)

test("unavailable removal is exact and cannot delete a navigable replacement sharing its pane ID", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	local original = model.reconcile(state, data, {}).rows[1]
	data.identities[11] = "replacement"
	local replaced = model.reconcile(state, data, {})
	assert(#replaced.rows == 2)
	local live
	for _, entry in ipairs(replaced.rows) do if entry.navigable then live = entry end end
	assert(live ~= nil and live.serial ~= original.serial)
	assert(not model.visit(state, 11, original.reviewRevision, original.serial))
	assert(not model.removeUnavailable(state, 11, live.serial))
	assert(model.removeUnavailable(state, 11, original.serial))
	assert(#model.current(state).rows == 1 and model.current(state).rows[1].serial == live.serial)
end)

test("exact identity rebinding keeps one work across multiple proven live bindings", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {}).rows[1]
	state = model.new(model.snapshot(state))
	local data = snapshot(2, { agent(22, "waiting_input"), agent(33, "idle") })
	data.identities[22], data.identities[33] = original.identityKey, original.identityKey
	local duplicate = model.reconcile(state, data, {})
	assert(#duplicate.rows == 1 and duplicate.rows[1].pane == 22)
	assert(duplicate.rows[1].navigable and duplicate.rows[1].workId == original.workId)
	data.identities[33] = "other"
	local rebound = model.reconcile(state, data, {}).rows[1]
	assert(rebound.pane == 22 and rebound.serial == original.serial and rebound.queueOrder == original.queueOrder)
	assert(rebound.firstSeenUtc == original.firstSeenUtc and rebound.navigable)
	data.identityReady, data.identities = false, {}
	local failedIdentity = model.reconcile(state, data, {}).rows[1]
	assert(failedIdentity.identityKey == original.identityKey and failedIdentity.navigable)
end)

test("restored keyless identity stays unverified until the same pane's identity is proven", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	data.identityReady, data.identities = false, {}
	local original = model.reconcile(state, data, {}).rows[1]
	assert(original.navigable and original.identityKey == nil)
	state = model.new(model.snapshot(state))
	local restored = model.reconcile(state, data, {})
	local saved
	for _, entry in ipairs(restored.rows) do if entry.serial == original.serial then saved = entry end end
	assert(#restored.rows == 1 and saved and saved.orphaned and not saved.navigable)
	assert(not model.visit(state, saved.pane, saved.reviewRevision, saved.serial))
	data.identityReady, data.identities = true, { [11] = "conversation:11" }
	local proven = model.reconcile(state, data, {})
	assert(#proven.rows == 1 and proven.rows[1].serial == original.serial and proven.rows[1].navigable)
	assert(proven.rows[1].identityKey == "conversation:11" and proven.rows[1].queueOrder == original.queueOrder)
end)

test("a settled snapshot after a restart deletes unretained rows whose pane is gone", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {}).rows[1]
	state = model.new(model.snapshot(state))
	local after = model.reconcile(state, snapshot(2, { agent(99, "idle") }), {})
	for _, entry in ipairs(after.rows) do
		assert(entry.serial ~= original.serial, "the row is deleted by observed state, not by a close event")
	end
end)

test("a retained row whose pane vanished across a restart becomes the no-open-pane terminal", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {}).rows[1]
	assert(model.setDisposition(state, original.workId, "reference", 2))
	state = model.new(model.snapshot(state))
	local after = model.reconcile(state, snapshot(3, { agent(99, "idle") }), {})
	local kept
	for _, entry in ipairs(after.rows) do if entry.serial == original.serial then kept = entry end end
	assert(kept and kept.retained and kept.pane == nil and kept.orphaned and not kept.navigable
		and kept.unavailableReason == "No open pane",
		"the retained keep survives as the explicit terminal with no pane to navigate")
	assert(model.removeRetained(state, kept.workId), "the terminal row stays removable")
end)

test("an unsettled or identity-pending snapshot never deletes a restored row", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {}).rows[1]
	state = model.new(model.snapshot(state))
	local data = snapshot(2, {})
	data.identityReady, data.identities = false, {}
	local held = model.reconcile(state, data, {})
	local saved
	for _, entry in ipairs(held.rows) do if entry.serial == original.serial then saved = entry end end
	assert(saved, "only a settled, identity-ready snapshot reconciles a vanished pane away")
	local failed = model.reconcile(state, { ok = false, error = "coverage" }, {})
	assert(#failed.rows == 1, "a failed snapshot holds rows untouched")
end)


test("restored blockers become reviewable history rather than disappearing on idle readback", function()
	local state = model.new()
	local first = model.reconcile(state, snapshot(10000, { agent(11, "waiting_input") }), {}).rows[1]
	state = model.new(model.snapshot(state))
	local restored = model.current(state).rows[1]
	assert(restored.stale and not restored.navigable and restored.reason ~= "Needs input")
	local historical = model.reconcile(state, snapshot(1, { agent(11, "idle") }), {}).rows[1]
	assert(historical and historical.serial == first.serial and historical.reviewRevision ~= nil)
	assert(historical.navigable and historical.reason ~= "Needs input")
	assert(visit(state, 11))
	healthy(model.current(state), 0)
end)

test("unchanged snapshots and generic focus do not dirty storage or churn presentation", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	local first = model.reconcile(state, data, {})
	local revision = state.persistenceRevision
	for now = 2, 5 do
		data.now = now
		local same = model.reconcile(state, data, { { kind = "focus", pane = 11, at = now } })
		assert(same == first and state.persistenceRevision == revision)
	end
	data.panes[11].title, data.panes[11].sessionName = "Renamed", "Another workspace"
	local renamed = model.reconcile(state, data, {})
	assert(renamed.rows[1].serial == first.rows[1].serial and renamed.rows[1].title == "Renamed")
	assert(renamed.rows[1].attentionRevision == first.rows[1].attentionRevision and state.persistenceRevision > revision)
end)

test("rounds use queue order, defer arrivals, skip unavailable rows and never acknowledge skips", function()
	local state = model.new()
	local data = snapshot(1, { agent(20, "waiting_input"), agent(30, "waiting_input") })
	model.reconcile(state, data, {})
	take(state, 20)
	table.insert(data.agents, agent(10, "waiting_input")); data.panes[10] = pane(10); data.identities[10] = "conversation:10"
	model.reconcile(state, data, {})
	for _, expected in ipairs({ 30, 20, 30, 10 }) do take(state, expected) end
	local failed = model.reconcile(state, data, { { kind = "finished", pane = 20, result = "failed", at = 2 } })
	local review = row(failed, 20).reviewRevision
	model.skip(state, 20)
	assert(row(model.current(state), 20).reviewRevision == review)
	assert(model.next(state, nil, { [10] = true }) == 10)
	assert(row(model.current(state), 20).reviewRevision == review)
	assert(model.next(state, nil, {}) == nil)
end)

test("observed work between unchanged waiting snapshots is a new request without duplicate churn", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	local first = model.reconcile(state, data, {}).rows[1]
	local fresh = model.reconcile(state, data, {
		{ kind = "state", pane = 11, old = "waiting_input", new = "working", at = 2 },
		{ kind = "state", pane = 11, old = "working", new = "waiting_input", at = 3 },
	}).rows[1]
	assert(fresh.disposition == "active" and fresh.attentionRevision > first.attentionRevision and fresh.serial == first.serial)
	local unchanged = model.reconcile(state, data, {
		{ kind = "state", pane = 11, old = "waiting_input", new = "waiting_input", at = 4 },
	}).rows[1]
	assert(unchanged.attentionRevision == fresh.attentionRevision)
end)

test("structured names remain independent from delimiters and duplicate labels get stable serials", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input"), agent(22, "waiting_input") }, {
		[11] = pane(11, { title = "Same", sessionName = "a · b", hostName = "c" }),
		[22] = pane(22, { title = "Same", sessionName = "a · b", hostName = "c" }),
	})
	local original = model.reconcile(state, data, {})
	for _, entry in ipairs(original.rows) do
		assert(entry.context == "a · b · c · #" .. tostring(entry.serial))
		assert(entry.sessionName == "a · b" and entry.hostName == "c" and entry.localHost)
	end
	data.panes[11].sessionName, data.panes[11].hostName = "a", "b · c"
	local changed = model.reconcile(state, data, {})
	assert(row(changed, 11).context == row(original, 11).context)
	assert(row(changed, 11).sessionName == "a" and row(changed, 11).hostName == "b · c")
	assert(row(changed, 11).attentionRevision == row(original, 11).attentionRevision)
	for _, invalid in ipairs({ "", false, 42 }) do
		data.panes[11].sessionName, data.panes[11].hostName, data.hosts[1].name = invalid, invalid, invalid
		local fallback = model.reconcile(state, data, {})
		assert(row(fallback, 11).sessionName == "Unknown session" and row(fallback, 11).hostName == "Unknown host")
	end
end)

test("old terminal events cannot replace a newer observed result cursor", function()
	local state = model.new()
	local original = model.reconcile(state, snapshot(1, { agent(11, "idle") }), {
		{ kind = "finished", pane = 11, result = "failed", at = 1 },
	}).rows[1]
	model.reconcile(state, snapshot(3, { agent(11, "working") }), {})
	local delayed = model.reconcile(state, snapshot(4, { agent(11, "working") }), {
		{ kind = "finished", pane = 11, result = "done", at = 0 },
	}).rows[1]
	assert(delayed.reviewRevision == original.reviewRevision)
end)

test("closure of a replacement does not erase an unmatched previous conversation", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	local original = model.reconcile(state, data, {}).rows[1]
	data.identities[11] = "replacement"
	assert(#model.reconcile(state, data, {}).rows == 2)
	local remaining = model.reconcile(state, data, { { kind = "closed", pane = 11, at = 2 } })
	assert(#remaining.rows == 1 and remaining.rows[1].serial == original.serial)
	assert(remaining.rows[1].orphaned and not remaining.rows[1].navigable)
end)

test("current VM observations wait for fresh identity and cannot contaminate a reused pane", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "waiting_input") })
	local original = model.reconcile(state, data, {}).rows[1]
	data.identityReady = false
	data.agents[1].state, data.panes[11].alert = "idle", true
	local pendingProof = model.reconcile(state, data, {
		{ kind = "finished", pane = 11, result = "done", at = 2 },
	})
	assert(#pendingProof.rows == 1 and pendingProof.rows[1].serial == original.serial)
	assert(pendingProof.rows[1].reviewRevision == nil and pendingProof.rows[1].stale)
	data.identityReady, data.identities[11] = true, "replacement"
	local proven = model.reconcile(state, data, {})
	assert(#proven.rows == 2)
	for _, entry in ipairs(proven.rows) do
		if entry.serial == original.serial then
			assert(entry.reviewRevision == nil and not entry.navigable and entry.identityKey == original.identityKey)
		else
			assert(entry.reviewRevision ~= nil and entry.navigable and entry.identityKey == "replacement")
		end
	end
	data.identityReady, data.identities = false, {}
	local retry = model.reconcile(state, data, {})
	local navigable = 0
	for _, entry in ipairs(retry.rows) do
		if entry.navigable then navigable += 1; assert(entry.identityKey == "replacement") end
	end
	assert(navigable == 1, "failed inspection must not rebind the rejected old identity")
end)

test("native inventory reorder cannot reorder P0 or the in-progress navigation round", function()
	local state = model.new()
	local data = snapshot(1, { agent(30, "waiting_input"), agent(10, "waiting_input"), agent(20, "waiting_input") })
	local first = model.reconcile(state, data, {})
	assert(first.rows[1].pane == 10 and first.rows[2].pane == 20 and first.rows[3].pane == 30)
	take(state, 10)
	data.agents = { agent(20, "waiting_input"), agent(30, "waiting_input"), agent(10, "waiting_input") }
	local repeated = model.reconcile(state, data, {})
	assert(repeated == first)
	assert(model.next(state) == 20)
	model.setDisposition(state, "work:" .. tostring(row(repeated, 10).serial), "reference", 0)
	model.setDisposition(state, "work:" .. tostring(row(model.current(state), 10).serial), "active", 1, { bringBack = true })
	local restored = model.current(state)
	assert(restored.rows[1].pane == 10 and restored.rows[2].pane == 20 and restored.rows[3].pane == 30, "All work is not queue order")
	take(state, 20)
	take(state, 30)
	take(state, 20)
end)

test("Next traverses every retained model entry beyond UI pagination", function()
	local state, agents = model.new(), {}
	for id = 1, 241 do table.insert(agents, agent(id, "waiting_input")) end
	healthy(model.reconcile(state, snapshot(1, agents), {}), 241)
	for expected = 1, 241 do take(state, expected) end
	assert(model.next(state) == 1)
end)

local function sessionInventory(agents, panes)
	local data = snapshot(10, agents, panes)
	data.sessions = {
		[100] = { id = 100, host = 1, name = "Workspace" },
		[200] = { id = 200, host = 1, name = "Quiet" },
		[300] = { id = 300, host = 1, name = "Empty" },
	}
	data.tabs = {
		[10] = { id = 10, session = 100 },
		[11] = { id = 11, session = 100 },
		[20] = { id = 20, session = 200 },
		[30] = { id = 30, session = 300 },
	}
	data.sessionOrder = { 200, 300, 100 }
	data.currentHost, data.currentSession = 1, 100
	return data
end

test("Attention counts session targets and Next exclude resumed work and rank blockers within priority", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "idle"), agent(12, "idle"), agent(13, "idle"), agent(14, "idle") })
	model.reconcile(state, data, {
		{ kind = "finished", pane = 11, result = "done", at = 1 },
		{ kind = "finished", pane = 12, result = "done", at = 2 },
		{ kind = "finished", pane = 13, result = "done", at = 3 },
	})
	data.now = 11
	data.agents[1].state = "working"
	data.agents[4].state = "waiting_input"
	local presentation = model.reconcile(state, data, {})
	assert(presentation.attentionCount == 3 and presentation.allCount == 4 and presentation.reachableCount == 3)
	assert(not row(presentation, 11).attention and presentation.attentionTargets[11] == nil)
	local group = model.sessionGroups(presentation, data, true)[1]
	assert(group.attentionConversations == 3 and group.attentionTabs == 1 and group.allConversations == 4)
	assert(group.target.pane == 14 and group.target.condition == "waiting" and model.next(state) == 14)
	model.skip(state, 14)
	take(state, 12); take(state, 13)
	assert(model.next(state) == 14, "remaining blockers return in the next round")
	model.setPriority(state, row(presentation, 13).workId, 1)
	model.setDisposition(state, row(presentation, 13).workId, "active", 12, { bringBack = true })
	model.skip(state, 14)
	assert(model.next(state) == 13, "explicit priority precedes blocker rank")
	local prioritized = model.sessionGroups(model.current(state), data, true)[1]
	assert(prioritized.target.pane == 13)
end)

test("recorded questions and outcomes survive supersession without overriding current work or returning on idle", function()
	local state = model.new()
	local fact = {
		key = "conversation:11", path = "/fixture/history", sessionId = "source-11", revision = "r1",
		capturedAtUtc = 1, status = "ready", complete = true, selection = "disk-replayed", schemaVersion = 3,
		writerVersions = {}, coverage = { recordsComplete = true },
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "request-1", status = "open", text = "Choose a destination", askedAtUtc = 1 } },
		lastFinal = { id = "reply-1", text = "Earlier reply", atUtc = 1, timeKind = "completed" },
	}
	local function sourced(now, mode)
		local data = snapshot(now, { agent(11, mode) })
		data.sources = { [11] = { key = fact.key, path = fact.path, localSource = true } }
		data.sourceFacts = { [fact.key] = fact }
		return data
	end
	local first = row(model.reconcile(state, sourced(1, "idle"), {}, { nowUtc = 1 }), 11)
	assert(first.attention and first.source.questions[1].status == "open")
	local busy = row(model.reconcile(state, sourced(2, "working"), {}, { nowUtc = 2 }), 11)
	assert(not busy.attention and busy.reviewSuperseded and busy.source.lastFinal.id == "reply-1")
	state = model.new(model.snapshot(state))
	local idle = row(model.reconcile(state, sourced(3, "idle"), {}, { nowUtc = 3 }), 11)
	assert(not idle.attention and idle.source.questions[1].status == "open" and idle.source.lastFinal.id == "reply-1")
	assert(model.setDisposition(state, idle.workId, "active", 4, { bringBack = true }))
	assert(row(model.current(state), 11).attention and not row(model.current(state), 11).reviewSuperseded)
end)

test("session groups count distinct P0 tabs in native order and retain quiet content", function()
	local state = model.new()
	local data = sessionInventory({
		agent(11, "waiting_input"), agent(12, "waiting_input"),
		agent(13, "waiting_input"), agent(14, "waiting_input"),
	}, {
		[11] = pane(11), [12] = pane(12),
		[13] = pane(13, { tab = 11 }), [14] = pane(14, { tab = 11 }),
		[21] = pane(21, { session = 200, tab = 20 }),
	})
	local presentation = model.reconcile(state, data, {})
	local groups = model.sessionGroups(presentation, data, true)
	assert(#groups == 2 and groups[1].session == 200 and groups[2].session == 100)
	local quiet, active = groups[1], groups[2]
	assert(quiet.attentionTabs == 0 and quiet.attentionConversations == 0 and quiet.target == nil)
	assert(quiet.laterTabs == nil and quiet.laterConversations == nil)
	assert(quiet.known and quiet.available and not quiet.current)
	assert(active.attentionTabs == 2 and active.attentionConversations == 4 and active.current)
	assert(active.laterTabs == nil and active.laterConversations == nil)
	assert(active.host == 1 and active.hostKey == "local" and active.localHost)
	assert(active.name == "Workspace" and active.label == "Workspace" and active.hostName == "Local")
	assert(active.target.pane == 11 and active.target.serial == row(presentation, 11).serial)
	assert(active.target.host == 1 and active.target.session == 100 and active.target.tab == 10)
	active.target.pane = 999
	assert(row(presentation, 11).pane == 11 and data.panes[11].pane == 11)
	assert(model.sessionGroups(presentation, data, true)[2].target.pane == 11)
end)

test("session grouping counts only active rows as Attention; Reference and Finished leave the group counts", function()
	local state = model.new()
	local data = sessionInventory({
		agent(11, "waiting_input"), agent(12, "waiting_input"),
		agent(13, "waiting_input"), agent(14, "waiting_input"),
	}, {
		[11] = pane(11), [12] = pane(12), [13] = pane(13), [14] = pane(14, { tab = 11 }),
	})
	local native = model.reconcile(state, data, {})
	local projection = table.clone(native)
	projection.rows = {}
	for _, source in ipairs(native.rows) do
		local projected = table.clone(source)
		projected.disposition = if source.pane == 12 then "reference" elseif source.pane == 13 then "active" else "finished"
		projected.attention = source.pane == 13
		table.insert(projection.rows, projected)
	end
	local group = model.sessionGroups(projection, data, true)[1]
	assert(group.attentionConversations == 1 and group.attentionTabs == 1 and group.target.pane == 13)
	assert(group.laterConversations == nil and group.laterTabs == nil)
	row(projection, 13).disposition = "finished"
	row(projection, 13).attention = false
	group = model.sessionGroups(projection, data, true)[1]
	assert(group.attentionConversations == 0 and group.attentionTabs == 0 and group.target == nil and group.known)
end)

test("Finished moves P0 out of Attention without creating a target or changing the global round", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(12, "waiting_input") })
	local projection = model.reconcile(state, data, {})
	local group = model.sessionGroups(projection, data, true)[1]
	assert(group.attentionTabs == 1 and group.attentionConversations == 2 and group.target.pane == 11)
	assert(model.next(state) == 11)
	visit(state, 11)
	assert(model.setDisposition(state, "work:" .. tostring(row(projection, 11).serial), "finished", 100))
	projection = model.current(state)
	group = model.sessionGroups(projection, data, true)[1]
	assert(group.attentionTabs == 1 and group.attentionConversations == 1 and group.target.pane == 12)
	assert(model.next(state) == 12, "finishing one row must preserve the remaining round")
	assert(model.setDisposition(state, "work:" .. tostring(row(projection, 12).serial), "reference", 100))
	projection = model.current(state)
	for _ = 1, 3 do
		group = model.sessionGroups(projection, data, true)[1]
		assert(group.attentionTabs == 0 and group.attentionConversations == 0 and group.target == nil and group.known)
	end
	assert(model.next(state) == nil, "Reference and Finished rows never remain Next targets")
end)

test("stale and incomplete coverage never become known quiet session counts", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input") }, {
		[11] = pane(11), [21] = pane(21, { session = 200, tab = 20 }),
	})
	model.reconcile(state, data, {})
	local stale = model.reconcile(state, { ok = false, error = "offline" }, {})
	local groups = model.sessionGroups(stale, data, false)
	assert(#groups == 2)
	assert(not groups[1].known and not groups[1].available and groups[1].attentionConversations == 0)
	assert(not groups[2].known and not groups[2].available and groups[2].attentionConversations == 1)
	assert(groups[2].attentionTabs == 1 and groups[2].target == nil)
	groups = model.sessionGroups(stale, data, true)
	assert(groups[2].available and not groups[2].known and groups[2].target == nil)
	data.hosts[1].connected = false
	assert(not model.sessionGroups(stale, data, true)[2].available)
	assert(#model.sessionGroups(stale, nil, false) == 0)
	groups = model.sessionGroups(nil, data, false)
	assert(#groups == 2 and not groups[1].known and not groups[2].known)
	assert(groups[2].attentionConversations == 0 and groups[2].target == nil)
	assert(groups[1].laterTabs == nil and groups[2].laterConversations == nil)
	data.sessionOrder = nil
	assert(#model.sessionGroups(stale, data, false) == 0, "unknown native order must not become hash order")
end)

test("remote and duplicate session labels remain unambiguous without changing native order", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(21, "waiting_input"),
		agent(31, "waiting_input"), agent(41, "waiting_input") }, {
		[11] = pane(11),
		[21] = pane(21, { host = 2, tab = 20, session = 200 }),
		[31] = pane(31, { host = 3, tab = 30, session = 300 }),
		[41] = pane(41, { host = 2, tab = 40, session = 400 }),
	})
	data.hosts[2] = { id = 2, key = "ssh:alpha", name = "Remote", connected = true }
	data.hosts[3] = { id = 3, key = "ssh:beta", name = "Remote", connected = true }
	data.sessions[200].host, data.sessions[200].name = 2, "Workspace"
	data.sessions[300].host, data.sessions[300].name = 3, "Workspace"
	data.sessions[400] = { id = 400, host = 2, name = "Unique" }
	data.tabs[40] = { id = 40, session = 400 }
	data.sessionOrder = { 300, 100, 400, 200 }
	local groups = model.sessionGroups(model.reconcile(state, data, {}), data, true)
	assert(#groups == 4 and groups[1].session == 300 and groups[2].session == 100)
	assert(groups[3].session == 400 and groups[4].session == 200)
	assert(groups[1].label ~= groups[4].label and groups[2].label ~= groups[2].name)
	assert(groups[1].hostKey == "ssh:beta" and not groups[1].localHost)
	assert(groups[3].label ~= groups[3].name, "unique remote sessions still qualify their host")
	assert(groups[1].label ~= groups[2].label and groups[4].label ~= groups[2].label)
end)

test("literal session names cannot mimic final identity-qualified labels", function()
	local state = model.new()
	local data = sessionInventory({
		agent(71, "waiting_input"), agent(81, "waiting_input"), agent(11, "waiting_input"),
	}, {
		[71] = pane(71, { host = 2, tab = 70, session = 7 }),
		[81] = pane(81, { host = 3, tab = 80, session = 8 }),
		[11] = pane(11),
	})
	data.hosts[2] = { id = 2, key = "ssh:alpha", name = "Remote", connected = true }
	data.hosts[3] = { id = 3, key = "ssh:beta", name = "Remote", connected = true }
	data.sessions[7] = { id = 7, host = 2, name = "Work" }
	data.sessions[8] = { id = 8, host = 3, name = "Work" }
	data.sessions[100].name = "Work · Remote · #7"
	data.tabs[70], data.tabs[80] = { id = 70, session = 7 }, { id = 80, session = 8 }
	data.sessionOrder = { 8, 100, 7 }
	local presentation = model.reconcile(state, data, {})
	local groups = model.sessionGroups(presentation, data, true)
	assert(#groups == 3)
	assert(groups[1].label ~= groups[2].label and groups[1].label ~= groups[3].label)
	assert(groups[2].label ~= groups[3].label, "literal suffix mimic must not duplicate a remote label")

	data.sessions[200].name = groups[3].label
	data.panes[21] = pane(21, { session = 200, tab = 20 })
	table.insert(data.agents, agent(21, "waiting_input"))
	data.sessionOrder = { 8, 200, 100, 7 }
	presentation = model.reconcile(state, data, {})
	groups = model.sessionGroups(presentation, data, true)
	local repeated = model.sessionGroups(presentation, data, true)
	local expectedPanes = { 81, 21, 11, 71 }
	local labels = {}
	assert(#groups == 4 and #repeated == 4)
	for index, group in ipairs(groups) do
		assert(not labels[group.label], "prefix-mimicking names must also remain distinct")
		labels[group.label] = true
		assert(group.label == repeated[index].label, "label qualification must be deterministic")
		assert(group.session == data.sessionOrder[index], "qualification must preserve native order")
		local expected = data.panes[expectedPanes[index]]
		assert(group.host == expected.host and group.hostKey == data.hosts[expected.host].key)
		assert(group.target.pane == expected.pane and group.target.host == expected.host)
		assert(group.target.session == expected.session and group.target.tab == expected.tab)
	end
end)

test("moved or closed targets are never counted or selected under obsolete session membership", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(12, "waiting_input") }, {
		[11] = pane(11), [12] = pane(12), [21] = pane(21, { tab = 20, session = 200 }),
	})
	local presentation = model.reconcile(state, data, {})
	data.panes[11].session, data.panes[11].tab = 200, 20
	local groups = model.sessionGroups(presentation, data, true)
	assert(groups[1].attentionConversations == 0 and groups[1].target == nil and not groups[1].known)
	assert(groups[2].attentionConversations == 1 and groups[2].target.pane == 12 and not groups[2].known)
	data.panes[12] = nil
	groups = model.sessionGroups(presentation, data, true)
	assert(#groups == 1 and groups[1].session == 200 and groups[1].target == nil)
	data.panes[11].session = 100
	groups = model.sessionGroups(presentation, data, true)
	assert(#groups == 1 and not groups[1].known and groups[1].target == nil,
		"a pane/tab session disagreement cannot establish membership")
end)

test("parked tabless and Attention-only sessions do not enter session grouping", function()
	local state = model.new()
	local parked = pane(11, { parked = true })
	local tabless = pane(12)
	tabless.tab, tabless.session = nil, nil
	local data = sessionInventory({ agent(11, "waiting_input"), agent(12, "waiting_input") }, {
		[11] = parked, [12] = tabless,
	})
	data.allPanes = table.clone(data.panes)
	data.allPanes[21] = pane(21, { session = 200, tab = 20 })
	data.canvases = { [21] = { pane = 21 } }
	assert(#model.sessionGroups(model.reconcile(state, data, {}), data, true) == 0)
end)

test("session selection is oldest-first and does not cycle or alter the global Next round", function()
	local state = model.new()
	local data = sessionInventory({ agent(30, "waiting_input") })
	model.reconcile(state, data, {})
	data.agents = { agent(10, "waiting_input"), agent(20, "waiting_input"), agent(30, "waiting_input") }
	data.panes[10], data.panes[20] = pane(10), pane(20)
	local presentation = model.reconcile(state, data, {})
	assert(model.next(state) == 30)
	visit(state, 30)
	for _ = 1, 3 do
		assert(model.sessionGroups(presentation, data, true)[1].target.pane == 30)
	end
	assert(model.next(state) == 10, "pure session selection must not reset or finish the live round")
	visit(state, 10)
	data.agents[4], data.panes[5] = agent(5, "waiting_input"), pane(5)
	presentation = model.reconcile(state, data, {})
	assert(model.sessionGroups(presentation, data, true)[1].target.pane == 30)
	assert(model.next(state) == 20, "new arrivals must remain outside the in-progress round")
	visit(state, 20)
	assert(model.next(state) == 30, "global oldest-first behavior is unchanged")
end)

test("a stale oldest row cannot hide a fresh reachable target or claim complete coverage", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(12, "waiting_input") })
	local native = model.reconcile(state, data, {})
	local presentation = table.clone(native)
	presentation.rows = { table.clone(native.rows[1]), native.rows[2] }
	presentation.rows[1].stale = true
	local group = model.sessionGroups(presentation, data, true)[1]
	assert(group.attentionTabs == 1 and group.attentionConversations == 2)
	assert(group.available and not group.known and group.target.pane == 12)
	presentation.status, presentation.count = "partial", nil
	group = model.sessionGroups(presentation, data, true)[1]
	assert(group.available and not group.known and group.target.pane == 12)
	data.hosts[1].error = "partial host inventory"
	group = model.sessionGroups(presentation, data, true)[1]
	assert(not group.available and not group.known and group.target == nil)
end)

test("same-session tab moves and host moves invalidate the old target identity", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(12, "waiting_input") })
	local presentation = model.reconcile(state, data, {})
	data.panes[11].tab = 11
	local groups = model.sessionGroups(presentation, data, true)
	assert(groups[1].attentionConversations == 1 and groups[1].target.pane == 12 and not groups[1].known)
	data.hosts[2] = { id = 2, key = "ssh:remote", name = "Remote", connected = true }
	data.sessions[200].host = 2
	data.panes[11].host, data.panes[11].session, data.panes[11].tab = 2, 200, 20
	groups = model.sessionGroups(presentation, data, true)
	assert(#groups == 2 and groups[1].session == 200 and groups[1].host == 2)
	assert(groups[1].attentionConversations == 0 and not groups[1].known and groups[1].target == nil)
	assert(groups[2].attentionConversations == 1 and groups[2].target.pane == 12)
end)

test("reply acknowledgments clear only their captured review without touching live conditions or turns", function()
	local state = model.new()
	local done = model.reconcile(state, snapshot(1, { agent(11, "idle") }), {
		{ kind = "finished", pane = 11, result = "done", at = 1 },
	})
	healthy(done, 1)
	local reviewed = row(done, 11).reviewRevision
	local acknowledged = model.reconcile(state, snapshot(2, { agent(11, "working") }), {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 2 },
		{ kind = "reply", pane = 11, reviewRevision = reviewed, at = 3 },
	})
	assert(acknowledged.attentionCount == 0)
	healthy(acknowledged, 0)

	state = model.new()
	local data = snapshot(1, { agent(11, "idle") })
	local first = model.reconcile(state, data, { { kind = "finished", pane = 11, result = "done", at = 1 } })
	local second = model.reconcile(state, data, {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 10001 },
		{ kind = "finished", pane = 11, result = "done", at = 10002 },
	})
	assert(second.rows[1].reviewRevision > first.rows[1].reviewRevision)
	local stale = model.reconcile(state, data, {
		{ kind = "reply", pane = 11, reviewRevision = first.rows[1].reviewRevision, at = 10003 },
	})
	assert(stale.attentionCount == 1 and row(stale, 11).reviewRevision == second.rows[1].reviewRevision)
	healthy(model.reconcile(state, data, {
		{ kind = "reply", pane = 11, reviewRevision = second.rows[1].reviewRevision, at = 10004 },
	}), 0)

	state = model.new()
	healthy(model.reconcile(state, snapshot(1, { agent(11, "waiting_input") }), {}), 1)
	local combined = model.reconcile(state, snapshot(2, { agent(11, "waiting_input") }), {
		{ kind = "finished", pane = 11, result = "failed", at = 2 },
	})
	local condition = row(combined, 11)
	assert(condition.reviewRevision ~= nil and string.find(condition.reason, "Needs input", 1, true))
	local replied = model.reconcile(state, snapshot(3, { agent(11, "waiting_input") }), {
		{ kind = "reply", pane = 11, reviewRevision = condition.reviewRevision, at = 3 },
	})
	assert(replied.attentionCount == 1)
	local remained = row(replied, 11)
	assert(remained.reviewRevision == nil and string.find(remained.reason, "Needs input", 1, true))

	state = model.new()
	model.reconcile(state, snapshot(1, { agent(11, "idle") }), {})
	model.reconcile(state, snapshot(2, { agent(11, "working") }), {
		{ kind = "state", pane = 11, old = "idle", new = "working", at = 2 },
	})
	local finished = model.reconcile(state, snapshot(3, { agent(11, "idle") }), {
		{ kind = "finished", pane = 11, result = "done", at = 3 },
	})
	healthy(finished, 1)
	local before = model.snapshot(state)
	assert(before.items[1].turn == 1, "fixture must count exactly one observed turn before the reply")
	model.reconcile(state, snapshot(4, { agent(11, "idle") }), {
		{ kind = "reply", pane = 11, reviewRevision = row(finished, 11).reviewRevision, at = 4 },
	})
	local after = model.snapshot(state)
	assert(#after.items == 1 and after.items[1].turn == before.items[1].turn and not model.current(state).rows[1].attention)
end)

test("a stalled host holds its last healthy coverage for up to eight seconds", function()
	local state = model.new()
	local hosts = { [1] = { id = 1, key = "local", name = "Local", connected = true },
		[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = true } }
	local data = snapshot(1, { agent(11, "waiting_input") },
		{ [11] = pane(11, { host = 2, hostName = "Forge" }) }, hosts)
	healthy(model.reconcile(state, data, {}, { nowUtc = 100 }), 1)
	hosts[2].connected = false
	local held = model.reconcile(state, data, {}, { nowUtc = 107 })
	assert(held.status == "ready" and held.count == 1 and held.offlineHosts == nil,
		"a seven second stall keeps the host's coverage healthy")
	local dropped = model.reconcile(state, data, {}, { nowUtc = 108 })
	assert(dropped.status == "partial" and dropped.count == nil and not row(dropped, 11).navigable)
	assert(#dropped.offlineHosts == 1 and dropped.offlineHosts[1].name == "Forge"
		and dropped.offlineHosts[1].key == "ssh:forge")
	hosts[2].connected = true
	local recovered = model.reconcile(state, data, {}, { nowUtc = 109 })
	assert(recovered.status == "ready" and recovered.count == 1 and recovered.offlineHosts == nil,
		"becoming healthy is immediate even within the debounce window")
end)

test("an offline remote host never taints a healthy local group's known counts", function()
	local state = model.new()
	local data = sessionInventory({ agent(11, "waiting_input"), agent(22, "waiting_input") }, {
		[11] = pane(11), [22] = pane(22, { host = 2, session = 200, tab = 20 }),
	})
	data.hosts[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = true }
	data.sessions[200].host = 2
	local first = model.reconcile(state, data, {}, { nowUtc = 100 })
	assert(first.status == "ready" and first.count == 2)
	data.hosts[2].connected = false
	local partial = model.reconcile(state, data, {}, { nowUtc = 110 })
	assert(partial.status == "partial" and partial.count == nil and #partial.offlineHosts == 1)
	local groups = model.sessionGroups(partial, data, true)
	assert(#groups == 2 and groups[1].session == 200 and groups[2].session == 100)
	assert(not groups[1].known and not groups[1].available)
	assert(groups[2].known and groups[2].available, "a remote outage never taints the local host's counts")
	assert(groups[2].attentionTabs == 1 and groups[2].attentionConversations == 1 and groups[2].target.pane == 11)
	data.hosts[2].connected = true
	assert(model.sessionGroups(model.reconcile(state, data, {}, { nowUtc = 120 }), data, true)[1].known)
end)

test("a retained row on a known offline host reports the host instead of offering Remove", function()
	local state = model.new()
	local hosts = { [1] = { id = 1, key = "local", name = "Local", connected = true },
		[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = true } }
	local data = snapshot(1, { agent(22, "waiting_input") },
		{ [22] = pane(22, { host = 2, hostName = "Forge", sessionName = "Remote work" }) }, hosts)
	model.reconcile(state, data, {}, { nowUtc = 100 })
	hosts[2].connected = false
	data.panes[22], data.agents = nil, {}
	local offline = model.reconcile(state, data, {}, { nowUtc = 110 })
	local remote = row(offline, 22)
	assert(offline.status == "partial" and #offline.offlineHosts == 1 and offline.offlineHosts[1].name == "Forge")
	assert(remote and not remote.navigable and not remote.orphaned and remote.unavailableReason == "Forge offline",
		"an offline host keeps its row retained without Remove")
	assert(model.next(state) == nil)
	state = model.new(model.snapshot(state))
	local restored = row(model.reconcile(state, data, {}, { nowUtc = 111 }), 22)
	assert(restored and restored.unavailableReason == "Forge offline" and not restored.orphaned,
		"a restored record on its own offline host reports the host, not unverified")
end)

test("a forgotten host leaves coverage scope instead of pinning partial", function()
	local state = model.new()
	local hosts = { [1] = { id = 1, key = "local", name = "Local", connected = true },
		[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = true } }
	local data = snapshot(1, { agent(22, "waiting_input") },
		{ [22] = pane(22, { host = 2, hostName = "Forge" }) }, hosts)
	model.reconcile(state, data, {}, { nowUtc = 100 })
	local forgotten = model.reconcile(state, snapshot(2, { agent(11, "waiting_input") }, nil, { [1] = hosts[1] }),
		{}, { nowUtc = 101 })
	assert(forgotten.status == "ready" and forgotten.offlineHosts == nil,
		"a host absent from the inventory is out of scope, never unknown")
	assert(forgotten.count == 2 and state.hosts[2] == nil and state.hostHealth[2] == nil)
	local remote = row(forgotten, 22)
	assert(remote and remote.orphaned and remote.unavailableReason == "missing")
end)

test("a quiet cursor whose pane disappears on a healthy host is an observed close", function()
	local state = model.new()
	local data = snapshot(1, { agent(11, "idle") })
	model.reconcile(state, data, { { kind = "finished", pane = 11, result = "done", at = 1 } }, { nowUtc = 100 })
	assert(visit(state, 11))
	local revision = state.persistenceRevision
	data.panes[11], data.agents = nil, {}
	local closed = model.reconcile(state, data, {}, { nowUtc = 101 })
	assert(row(closed, 11) == nil and state.persistenceRevision == revision + 1,
		"an absent pane on a healthy host prunes the cursor exactly like a close event")
	assert(#model.snapshot(state).items == 0)

	local hosts = { [1] = { id = 1, key = "local", name = "Local", connected = true },
		[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = true } }
	local remote = model.new()
	local blind = snapshot(1, { agent(22, "waiting_input") }, { [22] = pane(22, { host = 2 }) }, hosts)
	blind.identityReady, blind.identities = false, {}
	model.reconcile(remote, blind, {}, { nowUtc = 100 })
	local working = snapshot(2, { agent(22, "working") }, { [22] = pane(22, { host = 2 }) }, hosts)
	working.identityReady, working.identities = false, {}
	model.reconcile(remote, working, {}, { nowUtc = 101 })
	remote = model.new(model.snapshot(remote))
	assert(#model.snapshot(remote).items == 1, "fixture saves one quiet keyless conversation")
	local savedRevision = remote.persistenceRevision
	local gone = model.reconcile(remote, snapshot(3, {}, {}, hosts), {}, { nowUtc = 102 })
	assert(#gone.rows == 0 and #model.snapshot(remote).items == 0 and remote.persistenceRevision > savedRevision,
		"a remote keyless cursor is pruned once its healthy host no longer lists its pane")
end)

local function needOf(presentation, id)
	local need = row(presentation, id).need
	if need == nil then return nil end
	return need.kind .. "|" .. need.text .. "|" .. tostring(need.sinceUtc)
end

test("each row's need names what it waits on, a blocker before Working, and nothing for a quiet row", function()
	local state = model.new()
	local hosts = { [1] = { key = "local", connected = true }, [2] = { key = "remote", name = "Remote", connected = true } }
	local data = snapshot(1, {
		agent(11, "waiting_input"), agent(12, "working", "delivery refused"), agent(13, "idle"), agent(14, "idle"),
		agent(15, "idle"), agent(16, "working"), agent(17, "idle"), agent(18, "working"), agent(22, "waiting_input"),
	}, { [11] = pane(11), [12] = pane(12), [13] = pane(13, { startupError = "launch refused" }), [14] = pane(14),
		[15] = pane(15), [16] = pane(16), [17] = pane(17), [18] = pane(18), [22] = pane(22, { host = 2 }) }, hosts)
	local first = model.reconcile(state, data, {
		{ kind = "finished", pane = 14, result = "done", at = 1 }, { kind = "finished", pane = 15, result = "failed", at = 1 },
	}, { nowUtc = 100 })
	assert(needOf(first, 11) == "waiting|Waiting for input|nil")
	assert(needOf(first, 12) == "undelivered|Prompt not delivered|nil", "a blocked working row names its blocker")
	assert(needOf(first, 13) == "startup|Agent didn't start|nil")
	assert(needOf(first, 14) == "review|Reply to review|nil")
	assert(needOf(first, 15) == "review|Agent reported failure|nil")
	assert(needOf(first, 16) == "working|Working|nil", "no readable source means no stall clock")
	assert(needOf(first, 17) == nil, "a quiet idle row has nothing to say")
	assert(model.setDisposition(state, row(first, 18).workId, "reference", 100))
	assert(row(model.current(state), 18).need == nil, "a Reference row is outside the queues")
	local kept = row(first, 11).need
	data.panes[11].title = "Renamed"
	local renamed = model.reconcile(state, data, {}, { nowUtc = 101 })
	assert(row(renamed, 11) ~= row(first, 11) and row(renamed, 11).need == kept,
		"an unchanged need keeps its table so the row compares equal on it")
	hosts[2].connected = false
	local offline = model.reconcile(state, data, {}, { nowUtc = 120 })
	assert(row(offline, 22).stale and needOf(offline, 22) == "offline|Last known: Waiting for input|nil")
end)

test("source questions, provider errors and recorded activity word a row's need", function()
	local state = model.new()
	local live = snapshot(1, { agent(11, "idle") })
	live.sources = { [11] = { key = "conversation:11", path = "/exact/session", localSource = true } }
	local fact = { key = "conversation:11", path = "/exact/session", sessionId = "needs", status = "ready",
		capturedAtUtc = 100, revision = "question", schemaVersion = 3, writerVersions = { "18.18.7" },
		selection = "disk-replayed", complete = true, coverage = { fields = { clock = "supported", questions = "supported" } },
		questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 },
		questions = { { id = "q", status = "open", askedAtUtc = 90, text = "  Which   database should\nwe use for sessions?  " } } }
	live.sourceFacts = { [fact.key] = fact }
	local function replay(now, changes)
		if changes then
			fact = table.clone(fact)
			for key, value in pairs(changes) do fact[key] = value end
			fact.capturedAtUtc, fact.revision = now, "revision-" .. tostring(now)
			live.sourceFacts[fact.key] = fact
		end
		return model.reconcile(state, live, {}, { window = "", nowUtc = now, coherent = true,
			hostKeys = { [1] = "local" }, connected = { ["local"] = true } })
	end
	local asked = replay(100)
	assert(needOf(asked, 11) == "question|Asks: Which database should we use for…|nil", needOf(asked, 11))
	assert(utf8.len(row(asked, 11).need.text) <= 40)
	local failed = replay(102, { questions = {}, questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 },
		lastError = { id = "e", kind = "usage_limit", atUtc = 101 }, lastActivityAtUtc = 101 })
	assert(row(failed, 11).attention and failed.attentionCount == 1, "a provider error that ended the turn needs attention")
	assert(needOf(failed, 11) == "provider|Usage limit · reset time unknown|nil" and row(failed, 11).reason == "Recorded: Usage limit reached")
	-- Every account blocked until 150: the row rests out of Attention, then returns on its own once the clock passes.
	local blocked = replay(102.5, { lastError = { id = "e", kind = "usage_limit", atUtc = 101,
		limit = { status = "blocked", untilUtc = 150 } } })
	assert(not row(blocked, 11).attention and blocked.attentionCount == 0 and row(blocked, 11).resting == 150
		and needOf(blocked, 11) == "resting|Usage limit|nil" and row(blocked, 11).need.untilUtc == 150, "a known reset rests")
	local reset = replay(150)
	assert(row(reset, 11).attention and reset.attentionCount == 1 and row(reset, 11).resting == nil
		and needOf(reset, 11) == "provider|Usage limit · reset due|nil", "the deadline passing returns the row, never claiming a reset")
	local unproven = replay(102.8, { lastError = { id = "e", kind = "usage_limit", atUtc = 101, limit = { status = "clear" } } })
	assert(needOf(unproven, 11) == "provider|Usage limit · reset time unknown|nil", "only an omp deadline makes a reset due")
	live.now, live.agents[1].state = 2, "working"
	local working = replay(103)
	assert(not row(working, 11).attention and needOf(working, 11) == "working|Working|103",
		"working again clears the error; the stall clock starts at the observed work")
	local held = row(working, 11).need
	local active = replay(110, { lastActivityAtUtc = 109 })
	assert(needOf(active, 11) == "working|Working|109" and row(active, 11).need ~= held, "new recorded activity moves the clock")
	live.now, live.agents[1].state = 3, "idle"
	local settled = replay(111)
	assert(not row(settled, 11).attention and needOf(settled, 11) == nil, "an error recorded before the new work is history")
	local again = replay(120, { lastError = { id = "e2", kind = "rate_limit", atUtc = 115 } })
	assert(row(again, 11).attention and needOf(again, 11) == "provider|Rate limited · reset time unknown|nil")
	local unknownClock = replay(121, { coverage = { fields = { clock = "unknown", questions = "supported" } } })
	assert(not row(unknownClock, 11).attention and needOf(unknownClock, 11) == nil, "an unparsed clock asserts no provider error")
end)

require("./lifecycle.test")
require("./state.test")
return true
