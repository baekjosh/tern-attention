local model = require("../model")

-- LIFE-01: one conversation is driven through every signal while sitting in each disposition. The
-- assertions are the observable row fields and presentation counts, never model internals.

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local DISPOSITIONS = { "active", "reference", "finished" }

local function context(now, fields)
	local value = { window = "", hostKeys = { [1] = "local", [2] = "ssh:forge" }, connected = { ["local"] = true },
		coherent = true, nowUtc = now }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

-- fields: pane (default 11), host (1 local or 2 remote), key (identity), now (native snapshot clock), connected.
local function data(mode, fields)
	fields = fields or {}
	local paneId, hostId = fields.pane or 11, fields.host or 1
	local value = {
		ok = true, now = fields.now or 1, identityReady = true, identities = {},
		hosts = { [1] = { id = 1, key = "local", name = "Local", connected = true } },
		agents = {}, panes = {},
	}
	if hostId == 2 then
		value.hosts[2] = { id = 2, key = "ssh:forge", name = "Forge", connected = fields.connected ~= false }
	end
	if mode then
		value.agents[1] = { pane = paneId, state = mode }
		value.panes[paneId] = { host = hostId, tab = 10, session = 100, title = "Agent", alert = false }
		value.identities[paneId] = fields.key or "conversation:11"
	end
	return value
end

local function finished(pane, at)
	return { kind = "finished", pane = pane, result = "done", at = at }
end

local function closed(pane)
	return { kind = "closed", pane = pane, at = 2 }
end

-- A conversation holding one unreviewed completion, then placed in the requested disposition.
local function conversation(disposition, fields)
	local pane = (fields or {}).pane or 11
	local state = model.new()
	local first = model.reconcile(state, data("idle", fields), { finished(pane, 1) }, context(100)).rows[1]
	assert(first.attention and first.reviewRevision ~= nil, "fixture starts with an unreviewed completion")
	if disposition ~= "active" then assert(model.setDisposition(state, first.workId, disposition, 101)) end
	return state, model.current(state).rows[1]
end

-- Attention counts only active attention rows; the total counts everything.
local function expectCounts(state, disposition, attention, label)
	local presentation = model.current(state)
	assert(presentation.attentionCount == (if attention then 1 else 0),
		label .. ": attention count " .. tostring(presentation.attentionCount))
	assert(presentation.laterCount == nil, label .. ": there is no Later count")
	assert(presentation.allCount == #presentation.rows, label .. ": total counts every row")
end

local function reachable(state)
	return (model.next(state)) ~= nil
end

local function byWork(presentation, workId)
	for _, row in ipairs(presentation.rows) do
		if row.workId == workId then return row end
	end
	return nil
end

test("every disposition transition applies the same row, count and ordering rules", function()
	for _, from in ipairs(DISPOSITIONS) do
		for _, to in ipairs(DISPOSITIONS) do
			local label = from .. " -> " .. to
			local state, before = conversation(from)
			assert(model.setDisposition(state, before.workId, to, 200) == (from ~= to), label .. ": repeating a disposition is a no-op")
			local row = model.current(state).rows[1]
			assert(row.workId == before.workId and row.disposition == to, label)
			assert(row.retained == (to ~= "active" or before.retained), label .. ": every non-active disposition is retained")
			assert(row.attention == (to == "active"), label .. ": only active work needs Attention")
			expectCounts(state, to, to == "active", label)
			assert(row.reviewRevision == before.reviewRevision and row.queueOrder == before.queueOrder,
				label .. ": transitions invent no review and keep their place")
			assert(reachable(state) == (to == "active"), label .. ": only active work is a Next target")
		end
	end
end)

test("Reference and Finished clear a brought-back manual revisit", function()
	for _, settled in ipairs({ "reference", "finished" }) do
		local state, parked = conversation(settled)
		assert(model.setDisposition(state, parked.workId, "active", 200, { bringBack = true }))
		local resumed = model.current(state).rows[1]
		assert(resumed.reviewKind == "manual" and resumed.attention, settled)
		assert(resumed.reviewRevision > parked.reviewRevision and resumed.queueOrder > parked.queueOrder,
			settled .. ": bringing back is a fresh manual revisit")
		assert(model.setDisposition(state, parked.workId, settled, 201))
		local row = model.current(state).rows[1]
		assert(row.disposition == settled and row.reviewRevision == nil and row.reviewKind == nil and not row.attention, settled)
		expectCounts(state, settled, false, settled)
		local saved = model.snapshot(state).items[1]
		assert(saved.manualRevisit == nil and saved.reviewKind == nil and saved.reviewRevision == nil, settled)
	end
end)

test("ordinary completion advances review evidence but never changes the disposition", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		local resumed = model.reconcile(state, data("working", { now = 20 }), {}, context(102)).rows[1]
		assert(resumed.disposition == disposition and resumed.reviewSuperseded and not resumed.attention
			and resumed.reviewRevision == first.reviewRevision, disposition .. ": new work supersedes the unread review")
		state = model.new(model.snapshot(state))
		local settled = model.reconcile(state, data("idle", { now = 1 }), {}, context(103)).rows[1]
		assert(settled.disposition == disposition and settled.reviewSuperseded and not settled.attention
			and settled.reviewRevision == first.reviewRevision, disposition .. ": idle does not resurrect the review")
		local done = model.reconcile(state, data("idle", { now = 1 }), { finished(11, 2) }, context(104)).rows[1]
		assert(done.disposition == disposition and done.workId == first.workId, disposition .. ": completion keeps the disposition")
		assert(done.attention == (disposition == "active"), disposition .. ": only active work re-enters Attention")
		assert(done.reviewRevision > first.reviewRevision and not done.reviewSuperseded, disposition .. ": fresh review evidence")
		assert(done.queueOrder == first.queueOrder and done.firstSeenUtc == 104, disposition .. ": stable place, fresh age")
		expectCounts(state, disposition, disposition == "active", disposition)
		assert(reachable(state) == (disposition == "active"), disposition)
	end
end)

test("a new direct blocker keeps every disposition; only active work needs Attention", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		model.reconcile(state, data("working", { now = 20 }), {}, context(102))
		local row = model.reconcile(state, data("waiting_input", { now = 30 }), {}, context(103)).rows[1]
		assert(row.workId == first.workId and row.disposition == disposition, disposition .. " -> " .. row.disposition)
		assert(row.condition == "waiting", disposition .. ": the live condition is always recorded")
		assert(row.attention == (disposition == "active"), disposition .. ": condition counts only on active work")
		assert(row.reviewRevision == first.reviewRevision, disposition .. ": a blocker is not a review revision")
		assert(row.queueOrder == first.queueOrder, disposition .. ": no reordering")
		expectCounts(state, disposition, disposition == "active", disposition)
		assert(reachable(state) == (disposition == "active"), disposition)
	end
end)

test("native state changes never move a record between dispositions", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		local exited = model.reconcile(state, data("exited"), {}, context(102)).rows[1]
		assert(exited.nativeState == "exited" and exited.disposition == disposition
			and exited.reviewRevision == first.reviewRevision, disposition)
		assert(exited.attention == (disposition == "active"), disposition .. ": exit alone adds no Attention")
		expectCounts(state, disposition, disposition == "active", disposition)
		for _, native in ipairs({ "working", "idle" }) do
			local row = model.reconcile(state, data(native, { now = 20 }), {}, context(103)).rows[1]
			assert(row.nativeState == native and row.disposition == disposition and row.workId == first.workId, disposition .. " " .. native)
			assert(row.reviewRevision == first.reviewRevision and row.reviewSuperseded and not row.attention,
				disposition .. " " .. native .. ": resumed work hides the unread review and idle does not return it")
			expectCounts(state, disposition, false, disposition .. " " .. native)
		end
	end
end)

test("closing and reopening a pane keeps retained dispositions and forgets unretained work", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		local shut = model.reconcile(state, data(nil), { closed(11) }, context(102))
		local reopened = data("idle", { pane = 22 })
		if disposition == "active" then
			assert(#shut.rows == 0 and #model.snapshot(state).items == 0, "unretained active work disappears with its last pane")
			expectCounts(state, disposition, false, disposition)
			local back = model.reconcile(state, reopened, {}, context(103))
			assert(#back.rows == 1 and back.rows[1].workId ~= first.workId, "a closed unretained record is never resurrected")
			assert(back.rows[1].pane == 22 and back.rows[1].navigable and not back.rows[1].attention)
		else
			assert(#shut.rows == 1, disposition)
			local row = shut.rows[1]
			assert(row.workId == first.workId and row.pane == nil and row.retained and row.orphaned and not row.navigable, disposition)
			assert(row.disposition == disposition and row.reviewRevision == first.reviewRevision and not row.attention, disposition)
			expectCounts(state, disposition, false, disposition)
			assert(shut.reachableCount == 0 and not reachable(state), disposition .. ": no pane is no target")
			local saved = model.snapshot(state).items[1]
			assert(saved.noOpenPane == true and saved.disposition == disposition, disposition)
			local back = model.reconcile(state, reopened, {}, context(103))
			assert(#back.rows == 1, disposition .. ": reopening never duplicates the record")
			local rebound = back.rows[1]
			assert(rebound.workId == first.workId and rebound.pane == 22 and rebound.navigable and not rebound.orphaned, disposition)
			assert(rebound.disposition == disposition and rebound.reviewRevision == first.reviewRevision and not rebound.attention, disposition)
			expectCounts(state, disposition, false, disposition)
			assert(model.snapshot(state).items[1].noOpenPane == nil, disposition .. ": the no-pane marker clears")
		end
	end
end)

test("an offline host retains each disposition's last-known facts and never closes or alerts", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local remote = { host = 2, pane = 22 }
		local state, first = conversation(disposition, remote)
	local function retained(presentation, reason, label)
		assert(#presentation.rows == 1, label .. ": the record is never closed by an outage")
		local row = presentation.rows[1]
		assert(row.workId == first.workId and row.disposition == disposition and row.stale and not row.navigable, label)
		assert(row.unavailableReason == reason, label .. ": " .. tostring(row.unavailableReason))
		assert(row.attentionRevision == first.attentionRevision and row.reviewRevision == first.reviewRevision,
			label .. ": an outage mints no revision")
		assert(row.attention == (disposition == "active"), label .. ": last-known Attention is unchanged")
		assert(presentation.status == "partial" and #presentation.offlineHosts == 1, label)
		assert(presentation.reachableCount == 0 and not reachable(state), label .. ": offline work is never a target")
		assert(presentation.attentionCount == (if disposition == "active" then 1 else 0),
			label .. ": attention count " .. tostring(presentation.attentionCount))
		assert(presentation.allCount == #presentation.rows, label .. ": total counts every row")
	end
	retained(model.reconcile(state, data("idle", { host = 2, pane = 22, connected = false }), {}, context(110)),
		"disconnected", disposition .. " listed")
	retained(model.reconcile(state, data(nil, { host = 2, pane = 22, connected = false }), {}, context(111)),
		"Forge offline", disposition .. " absent")
		local back = model.reconcile(state, data("idle", remote), {}, context(120))
		assert(back.status == "ready" and #back.rows == 1, disposition)
		local row = back.rows[1]
		assert(row.workId == first.workId and row.navigable and not row.stale and not row.orphaned, disposition .. ": reconnect")
		assert(row.disposition == disposition and row.attentionRevision == first.attentionRevision
			and row.reviewRevision == first.reviewRevision, disposition .. ": reconnect keeps every fact")
		expectCounts(state, disposition, disposition == "active", disposition .. " reconnect")
	end
end)

test("a replaced conversation never inherits the old record's disposition or review", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		local swapped = data("idle")
		swapped.identities[11] = "conversation:other"
		local presentation = model.reconcile(state, swapped, {}, context(102))
		assert(#presentation.rows == 2, disposition .. ": the old record is kept, not merged or deleted")
		local old = byWork(presentation, first.workId)
		assert(old ~= nil and not old.navigable and old.orphaned and old.disposition == disposition, disposition)
		assert(old.reviewRevision == first.reviewRevision and old.attention == (disposition == "active"), disposition)
		local fresh
		for _, row in ipairs(presentation.rows) do if row.workId ~= first.workId then fresh = row end end
		assert(fresh ~= nil and fresh.identityKey == "conversation:other", disposition)
		assert(fresh.disposition == "active" and fresh.navigable and not fresh.attention and fresh.reviewRevision == nil,
			disposition .. ": the new conversation starts neutral")
		assert(presentation.attentionCount == (if disposition == "active" then 1 else 0), disposition)
		assert(presentation.reachableCount == 0 and not reachable(state), disposition .. ": the unreachable old record is no target")
	end
end)

test("closing one of several proven routes keeps the same record on the survivor in every disposition", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state = model.new()
		local live = data("idle")
		live.agents[2] = { pane = 33, state = "idle" }
		live.panes[33] = { host = 1, tab = 11, session = 100, title = "Duplicate", alert = false }
		live.identities[33] = live.identities[11]
		local first = model.reconcile(state, live, { finished(11, 1) }, context(100)).rows[1]
		assert(first.attention and model.current(state).allCount == 1, "two routes are one conversation")
		if disposition ~= "active" then assert(model.setDisposition(state, first.workId, disposition, 101)) end
		local after = model.reconcile(state, data("idle", { pane = 33 }), { closed(11) }, context(102))
		assert(after.allCount == 1 and after.rows[1].workId == first.workId and after.rows[1].pane == 33, disposition)
		assert(after.rows[1].navigable and after.rows[1].disposition == disposition, disposition)
		assert(after.rows[1].attention == (disposition == "active"), disposition)
		expectCounts(state, disposition, disposition == "active", disposition)
		local last = model.reconcile(state, data(nil), { closed(33) }, context(103))
		assert(#last.rows == (if disposition == "active" then 0 else 1), disposition .. ": only the last close ends unretained work")
	end
end)

test("reload and event replay never resurrect an acknowledged completion in any disposition", function()
	for _, disposition in ipairs(DISPOSITIONS) do
		local state, first = conversation(disposition)
		assert(model.visit(state, 11, first.reviewRevision, first.serial), disposition)
		local reviewed = model.current(state).rows[1]
		assert(reviewed.reviewRevision == nil and not reviewed.attention and reviewed.disposition == disposition, disposition)
		state = model.new(model.snapshot(state))
		local revision = state.persistenceRevision
		for pass = 1, 2 do
			local replayed = model.reconcile(state, data("idle"), { finished(11, 1) }, context(200 + pass)).rows[1]
			assert(replayed.workId == first.workId and replayed.disposition == disposition, disposition)
			assert(replayed.reviewRevision == nil and not replayed.attention, disposition .. ": replay " .. tostring(pass))
		end
		assert(state.persistenceRevision == revision, disposition .. ": replay writes nothing")
		expectCounts(state, disposition, false, disposition)
	end
end)

return true
