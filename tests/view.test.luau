local realView = require("../view")
local navigation = require("../navigation")
local census = require("./census")
local nativeCanvas = require("./native_canvas")
local copy, childAt = nativeCanvas.copy, nativeCanvas.childAt

-- The controller hands the Workspace snapshot to both normalization and rendering; fixtures carry it on the
-- presentation so every existing call site keeps its shape.
local view = setmetatable({
	normalize = function(logical, input, options)
		return realView.normalize(logical, input, options or { workspace = input.workspace })
	end,
	render = function(renderer, logical, input, options)
		local merged = table.clone(options or {})
		if merged.workspace == nil then merged.workspace = input.workspace end
		return realView.render(renderer, logical, input, merged)
	end,
}, { __index = realView })

local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
	for key in pairs(b) do if a[key] == nil then return false end end
	return true
end

local function walk(node, visit, visible)
	if visible and node.p and node.p.hidden then return end
	visit(node)
	for _, child in ipairs(node.c or {}) do walk(child, visit, visible) end
end

local function textOf(node)
	local parts = {}
	walk(node, function(child)
		if child.p and child.p.text then table.insert(parts, child.p.text) end
	end, true)
	return table.concat(parts, "\n")
end

-- The freshness chip is one logical role with two node roles: solid when live, dashed when only recorded.
local chipRoles = { ["attention.age"] = true, ["attention.age-recorded"] = true }

local function hasRole(item, role)
	if not item.p then return false end
	if role == "attention.age" then return chipRoles[item.p.role] == true end
	return item.p.role == role
end

local function roleText(root, role): string?
	local result: string? = nil
	walk(root, function(item)
		if hasRole(item, role) then result = item.p.text end
	end, true)
	return result
end

local function roleTitle(root, role): string?
	local result: string? = nil
	walk(root, function(item)
		if hasRole(item, role) then result = item.p.title end
	end, true)
	return result
end

-- The exact node role of the chip (live `attention.age` vs recorded `attention.age-recorded`), nil without a chip.
local function chipRole(root): string?
	local result: string? = nil
	walk(root, function(item)
		if item.p and chipRoles[item.p.role] then result = item.p.role end
	end, true)
	return result
end

local function bytes(value)
	if type(value) == "string" then
		assert(utf8.len(value), "native wire strings require valid UTF-8")
		local size = 2
		for index = 1, #value do
			local byte = string.byte(value, index)
			size += if byte < 32 then 6 elseif byte == 34 or byte == 92 then 2 else 1
		end
		return size
	elseif type(value) == "number" then
		assert(value == value and math.abs(value) < math.huge)
		return #tostring(value)
	elseif type(value) == "boolean" then return if value then 4 else 5 end
	assert(type(value) == "table" and getmetatable(value) == nil)
	local size = 2
	for key, item in pairs(value) do size += bytes(tostring(key)) + bytes(item) + 2 end
	return size
end

local allowedOps = {
	open = true, ["route-open"] = true, details = true, menu = true, section = true, page = true,
	next = true, previous = true, settings = true, position = true, default = true, age = true,
	search = true, new = true, reveal = true, ["workspace-toggle"] = true, ["workspace-aside"] = true,
	["workspace-open"] = true, ["native-menu"] = true, ["cancel-navigation"] = true,
}
local kinds = {
	col = true, row = true, section = true, rule = true, spacer = true, text = true,
	badge = true, kbd = true, icon = true, spinner = true, el = true, status = true, seg = true,
}
local function assertShape(screen, renderer, bindings, change)
	local count = 0
	local function check(node, depth)
		count += 1
		assert(depth < 32 and kinds[node.k], "native tree must use supported kinds and depth")
		local props = node.p or {}
		assert(props.href == nil, "source metadata is not an external link")
		if props.tag then
			assert(props.tag == "button" or props.tag == "div" or props.tag == "span" or props.tag == "label")
		end
		if props.actions then
			assert(props.actions.click and next(props.actions, "click") == nil, "actions must be single-click")
			local target = view.resolve(renderer, props.actions.click)
			assert(target and bindings[props.actions.click] and allowedOps[target.op], "every painted action has a current binding")
		end
		if props.tag == "button" then
			for _, child in ipairs(node.c or {}) do
				walk(child, function(descendant) assert(not (descendant.p and descendant.p.tag == "button"), "no nested buttons") end)
			end
		end
		local keys = {}
		for _, child in ipairs(node.c or {}) do
			local key = child.p and child.p.key
			assert(key and not keys[key], "native siblings need distinct stable keys")
			keys[key] = true
			check(child, depth + 1)
		end
	end
	check(screen.view, 1)
	assert(count < 2000 and bytes(screen) < 256 * 1024, "native full tree budget")
	assert(not screen.dock and (not change or not change.dock), "no native dock for paging")
	if change then assert(bytes(change) < 256 * 1024, "native patch wire budget") end
	for _, key in ipairs({ "header", "coverage", "rows", "empty", "settings" }) do
		assert(childAt(screen.view, key), "stable native root child missing")
	end
	assert(childAt(childAt(screen.view, "header"), "pagination"), "the pager is a stable child of the bounded header group")
	assert(not childAt(screen.view, "pagination"), "no pager row may sit in the scrolled region (it lives in the non-scrolling header)")
	for _, rowNode in ipairs(childAt(screen.view, "rows").c) do
		local actions = 0
		walk(rowNode, function(item) if item.p and item.p.actions then actions += 1 end end)
		assert(actions <= 3, "a row exposes at most three actions")
	end
end

local function row(serial)
	return {
		workId = "work:" .. serial, pane = serial + 100, serial = serial, host = 7,
		hostKey = "local", tab = 11, session = 13, identityKey = "exact:" .. serial,
		title = "Agent " .. serial, sessionName = "Workspace", hostName = "localhost", localHost = true,
		context = "Workspace · localhost", nativeState = "idle", disposition = "active",
		retained = false, attention = true, queueOrder = serial, attentionRevision = serial,
		reviewRevision = 1, reason = "New update", stale = false, navigable = true,
		orphaned = false, parked = false, floating = false, firstSeenUtc = 50,
	}
end

local function presentation(rows, status)
	local attention, later, reachable = 0, 0, 0
	for _, item in ipairs(rows) do
		if item.disposition == "later" then later += 1
		elseif item.attention then
			attention += 1
			if item.navigable then reachable += 1 end
		end
	end
	return {
		rows = rows, status = status or "ready", revision = 1,
		count = if not status or status == "ready" or status == "unsaved" then #rows else nil,
		knownCount = #rows, allCount = #rows, attentionCount = attention, laterCount = later,
		reachableCount = reachable, attentionTargets = {},
	}
end

-- One session, one unnamed tab per row with a pane: every conversation is its own flattened leaf; rows without
-- a pane stay saved conversations. Real navigation builds the snapshot.
local function workspaceOf(items)
	local raw = {
		hosts = { { id = 1, kind = "local", name = "localhost", state = "connected", current = true, panes = {} } },
		sessions = { { id = 13, host = 1, name = "Workspace", current = true, locked = false, tabs = #items } },
		tabs = {}, panes = {}, agents = {}, canvases = {}, focused = nil,
	}
	local identities = {}
	for index, item in ipairs(items) do
		if item.pane then
			table.insert(raw.hosts[1].panes, item.pane)
			table.insert(raw.tabs, { id = 200 + index, session = 13, position = index, pane = item.pane, title = item.title, panes = 1 })
			table.insert(raw.panes, { pane = item.pane, tab = 200 + index, title = item.title, kind = "agent", program = "omp",
				cwd = "/work", floating = false, parked = false })
			table.insert(raw.agents, { pane = item.pane, state = "idle" })
			identities[item.pane] = item.identityKey
		end
	end
	local data = navigation.inventory(raw, census.options())
	return navigation.project(data, { rows = items, identities = identities, identityPending = {}, window = "window", nowUtc = 1 })
end

local function paint(renderer, logical, input, screen, options)
	local before = copy(logical)
	local localBefore = copy(renderer)
	local change, bindings, info = view.render(renderer, logical, input, options)
	assert(equal(before, logical), "render must never mutate shared logical state")
	if screen and change then assert(change.view == nil, "live updates require keyed native patches") end
	screen = nativeCanvas.apply(screen, change)
	assert(screen and screen.view)
	localBefore.previous = nil
	local full = view.render(localBefore, logical, input, options)
	assert(equal(screen, full), "incremental native patch application must equal full rendering")
	assertShape(screen, renderer, bindings, change)
	return screen, info, change, bindings
end

local function findAction(screen, renderer, op, workId)
	local result
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == op and (not workId or binding.workId == workId) then result = action end
	end, true)
	return result
end

-- Workspace ids of one action kind, in tree order.
local function actionOrder(screen, renderer, op)
	local order = {}
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == op then table.insert(order, binding.workId) end
	end, true)
	return order
end

local function rowsByWork(screen, renderer)
	local map = {}
	for _, rowNode in ipairs(childAt(screen.view, "rows").c) do
		local action = findAction({ view = rowNode }, renderer, "menu")
		if action then map[view.resolve(renderer, action).workId] = rowNode end
	end
	return map
end

-- Inventory normalization preserves user intent while maintaining anchors and retiring disclosures.
do
	local logical, renderer = view.newState(), view.newRenderer("inventory-not-intent")
	local items = {}
	for serial = 1, 85 do items[serial] = row(serial) end
	local input = presentation(items)
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	view.expand(logical, "work:45")
	local intent, publication = logical.intentRevision, logical.revision
	local screen = paint(renderer, logical, input)
	local added = row(999)
	added.priority = 0
	table.insert(items, added)
	items[2].attention = false
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.revision > publication, "membership and ordering still publish their changed view")
	assert(logical.intentRevision == intent, "unrelated work entering or leaving Attention cannot cancel user intent")
	assert(findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:41"),
		"the selected slice stays anchored despite unrelated membership and priority reorder")
	assert(logical.expandedWorkId == "work:45" and string.find(textOf(childAt(screen.view, "rows")), "Source", 1, true))
	table.remove(items, 45)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.expandedWorkId == nil and logical.intentRevision == intent,
		"retiring the expanded target is derived state, not an explicit disclosure selection")
	assert(not findAction(screen, renderer, "details", "work:45"))
	input = presentation({ row(1) })
	view.normalize(logical, input)
	local info
	screen, info = paint(renderer, logical, input, screen)
	assert(info.page == 1 and info.shown == 1 and logical.intentRevision == intent,
		"clamping a vanished page does not manufacture a user selection")
	view.section(logical, "later")
	view.section(logical, "attention")
	assert(logical.intentRevision == intent + 2, "explicit away-and-back remains distinguishable after normalization")
end

-- Pending navigation belongs to one exact row, never to its runtime, review evidence or neighbors.
do
	local logical, renderer = view.newState(), view.newRenderer("row-navigation-pending")
	local item, other = row(1), row(2)
	item.sourceSessionId = "canonical-pending-header"
	item.sourceObservation = { status = "ready", capturedAtUtc = 1500, path = "/recorded/pending-session.jsonl" }
	item.source = {
		status = "ready", complete = true, sessionId = item.sourceSessionId,
		lastFinal = { id = "reply", atUtc = 1200, timeKind = "completed", text = "Preserved review body" },
	}
	local input = presentation({ item, other })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local original = childAt(childAt(screen.view, "rows"), "r1")
	local facts = {}
	for _, role in ipairs({ "attention.title", "attention.reason", "attention.age", "attention.runtime" }) do
		facts[role] = roleText(original, role)
		assert(facts[role] ~= nil, "fixture must expose the factual row content navigation must preserve")
	end
	local before = copy(input)
	for _, stage in ipairs({
		{ phase = "queued", text = "Waiting…", title = "Waiting for interactive verification before checking this target" },
		{ phase = "checking", text = "Checking…", title = "Checking target identity and source header before opening" },
		{ phase = "opening", text = "Opening…", title = "Opening the verified target" },
		{ phase = "confirming", text = "Confirming…", title = "Confirming the focused target with a fresh source header" },
	}) do
		local pending = {
			workId = item.workId, serial = item.serial, pane = item.pane, identityKey = item.identityKey, phase = stage.phase,
		}
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600, navigation = pending })
		assert(not findAction(screen, renderer, "cancel-navigation"), "tokenless progress cannot cancel an unidentified request")
		assert(roleText(childAt(screen.view, "rows"), "attention.navigation-pending") == stage.text,
			"tokenless fixtures still show the actual navigation phase")
		pending.token = "request:" .. stage.phase
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600, navigation = pending })
		local pendingRow = childAt(childAt(screen.view, "rows"), "r1")
		local otherRow = childAt(childAt(screen.view, "rows"), "r2")
		assert(roleText(childAt(pendingRow, "main"), "attention.navigation-pending") == stage.text,
			"each navigation phase has its own visible text")
		assert(roleTitle(pendingRow, "attention.navigation-pending") == stage.title, "progress title describes the actual stage")
		assert(roleText(pendingRow, "attention.cancel-navigation") == "Cancel", "the pending row has an explicit compact Cancel")
		local cancel = findAction(screen, renderer, "cancel-navigation", item.workId)
		assert(cancel and equal(view.resolve(renderer, cancel), {
			op = "cancel-navigation", token = pending.token, workId = item.workId, serial = item.serial,
			pane = item.pane, identityKey = item.identityKey,
		}), "Cancel carries only the current request token and exact row identity")
		assert(not findAction(screen, renderer, "cancel-navigation", other.workId), "another row has no Cancel")
		assert(findAction(screen, renderer, "menu", other.workId) and findAction(screen, renderer, "details", other.workId),
			"another row keeps its menu and inspection controls")
		assert(roleText(otherRow, "attention.navigation-pending") == nil, "pending feedback cannot leak to another row")
		assert(not findAction(screen, renderer, "open", item.workId), "the pending row cannot dispatch another Open")
		local otherOpen = findAction(screen, renderer, "open", other.workId)
		assert(otherOpen and view.resolve(renderer, otherOpen).identityKey == other.identityKey,
			"another row retains its exact Open target")
		assert(findAction(screen, renderer, "menu", item.workId) and findAction(screen, renderer, "details", item.workId),
			"pending navigation must not block explicit tracking or inspection")
		for role, expected in pairs(facts) do
			assert(roleText(pendingRow, role) == expected, "navigation progress cannot replace factual row content")
		end
		local inspect = view.resolve(renderer, findAction(screen, renderer, "details", item.workId))
		assert(inspect.reviewRevision == item.reviewRevision and inspect.sourceSessionId == item.sourceSessionId,
			"pending navigation preserves captured review and canonical header identity")
		assert(childAt(screen.view, "coverage").p.hidden, "row pending state cannot introduce a global coverage banner")
		view.expand(logical, item.workId)
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600, navigation = pending })
		local disclosure = childAt(childAt(childAt(screen.view, "rows"), "r1"), "disclosure")
		for _, fact in ipairs({ "Preserved review body", item.sourceSessionId, "/recorded/pending-session.jsonl" }) do
			assert(string.find(textOf(disclosure), fact, 1, true), "pending inspection retains source and header facts")
		end
		view.expand(logical, item.workId)
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
		local restored = findAction(screen, renderer, "open", item.workId)
		assert(restored and view.resolve(renderer, restored).reviewRevision == item.reviewRevision,
			"removing transient navigation restores Open without acknowledging the review")
		assert(roleText(childAt(screen.view, "rows"), "attention.navigation-pending") == nil)
		assert(not findAction(screen, renderer, "cancel-navigation") and view.resolve(renderer, cancel) == nil,
			"clearing pending removes Cancel and invalidates its old action")
	end
	for _, mismatch in ipairs({
		{ key = "workId", value = other.workId },
		{ key = "serial", value = other.serial },
		{ key = "pane", value = other.pane },
		{ key = "identityKey", value = "retired-identity" },
	}) do
		local pending = {
			workId = item.workId, serial = item.serial, pane = item.pane, identityKey = item.identityKey, phase = "checking", token = "stale-request",
		}
		pending[mismatch.key] = mismatch.value
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600, navigation = pending })
		assert(findAction(screen, renderer, "open", item.workId) and findAction(screen, renderer, "open", other.workId),
			"a stale or mismatched " .. mismatch.key .. " cannot disable either work")
		assert(roleText(childAt(screen.view, "rows"), "attention.navigation-pending") == nil,
			"nonmatching navigation cannot paint false progress")
		assert(not findAction(screen, renderer, "cancel-navigation"), "a stale row mismatch cannot show Cancel")
	end
	assert(equal(before, input), "pending presentation must not mutate review or source data")
end

-- The request token, not a phase change, determines which cancellation action remains valid.
do
	local logical, renderer = view.newState(), view.newRenderer("navigation-cancel-token")
	local item = row(1)
	local input = presentation({ item })
	view.normalize(logical, input)
	local pending = {
		workId = item.workId, serial = item.serial, pane = item.pane, identityKey = item.identityKey,
		phase = "queued", token = "epoch:1",
	}
	local screen = paint(renderer, logical, input, nil, { navigation = pending })
	local first = findAction(screen, renderer, "cancel-navigation", item.workId)
	assert(first, "positive control: a live request can be cancelled")
	for _, phase in ipairs({ "checking", "opening", "confirming" }) do
		pending.phase = phase
		screen = paint(renderer, logical, input, screen, { navigation = pending })
		assert(findAction(screen, renderer, "cancel-navigation", item.workId) == first,
			"phase progress preserves cancellation of the same accepted request")
	end
	pending.token = "epoch:2"
	screen = paint(renderer, logical, input, screen, { navigation = pending })
	local replacement = findAction(screen, renderer, "cancel-navigation", item.workId)
	assert(replacement and replacement ~= first and view.resolve(renderer, first) == nil,
		"a replacement request retires the stale Cancel action even on the same row")
	assert(view.resolve(renderer, replacement).token == "epoch:2")
	pending.token = nil
	screen = paint(renderer, logical, input, screen, { navigation = pending })
	assert(not findAction(screen, renderer, "cancel-navigation") and view.resolve(renderer, replacement) == nil,
		"removing the token retires Cancel without hiding progress")
	assert(roleText(screen.view, "attention.navigation-pending") == "Confirming…")
end

-- Cancel uses one action slot in place of Open; a full page keeps the native tree and wire limits.
do
	local items = {}
	for index = 1, 40 do table.insert(items, row(index)) end
	local input = presentation(items)
	local item = items[40]
	for _, position in ipairs({ "left", "right", "bottom" }) do
		local logical, renderer = view.newState(), view.newRenderer("cancel-page-" .. position)
		view.normalize(logical, input)
		local screen, info
		for _, phase in ipairs({ "queued", "checking", "opening", "confirming" }) do
			screen, info = paint(renderer, logical, input, screen, { position = position, navigation = {
				workId = item.workId, serial = item.serial, pane = item.pane, identityKey = item.identityKey,
				phase = phase, token = "page-request",
			} })
			assert(info.shown == 40 and #childAt(screen.view, "rows").c == 40,
				"pending feedback and Cancel must not shrink the full forty-row page")
			assert(findAction(screen, renderer, "cancel-navigation", item.workId), "the fortieth row exposes Cancel")
			assert(not findAction(screen, renderer, "open", item.workId) and findAction(screen, renderer, "open", items[1].workId))
		end
	end
end

-- Two physical canvases share selection, fixed logical page and disclosure, never tokens/caches.
do
	local logical, a, b = view.newState(), view.newRenderer("A"), view.newRenderer("B")
	local items = {}
	for serial = 1, 90 do
		items[serial] = row(serial)
		items[serial].disposition = "later"
	end
	local input = presentation(items)
	view.section(logical, "later")
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	view.expand(logical, "work:45")
	local screenA, infoA = paint(a, logical, input, nil, { pageSize = 1 })
	local screenB, infoB = paint(b, logical, input, nil, { pageSize = 99 })
	assert(infoA.section == "later" and infoB.section == "later" and infoA.page == 2 and infoB.page == 2)
	assert(infoA.shown == 40 and infoB.shown == 40, "physical dimensions/options cannot select a different slice")
	assert(textOf(childAt(screenA.view, "rows")) == textOf(childAt(screenB.view, "rows")))
	assert(findAction(screenA, a, "menu", "work:45") ~= findAction(screenB, b, "menu", "work:45"))
	assert(view.resolve(b, findAction(screenA, a, "menu", "work:45")) == nil)
	local selected = copy(logical)
	view.invalidate(a)
	screenA = paint(a, logical, input)
	assert(equal(selected, logical), "renderer recovery cannot reset global state")
	assert(string.find(textOf(screenA.view), "Source", 1, true), "shared expanded work remains disclosed")
	view.section(logical, "settings")
	screenA = paint(a, logical, input, screenA)
	screenB = paint(b, logical, input, screenB)
	assert(not childAt(screenA.view, "settings").p.hidden and not childAt(screenB.view, "settings").p.hidden)
	view.section(logical, "settings")
	assert(logical.section == "later" and not logical.settings and logical.pages.later == 2)
end

-- Workspace lists quiet, working and saved conversations; Attention and Later use factual fields.
do
	local logical, renderer = view.newState(), view.newRenderer("inventory")
	local a, b, c, d = row(1), row(2), row(3), row(4)
	b.attention, b.nativeState = false, "working"
	c.disposition = "later"
	d.disposition, d.retained, d.pane, d.navigable, d.orphaned = "reference", true, nil, false, true
	d.attention, d.unavailableReason = false, "No open pane"
	local input = presentation({ a, b, c, d })
	input.workspace = workspaceOf({ a, b, c, d })
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.sectionCount == 1 and info.attentionCount == 1 and info.laterCount == 1)
	view.section(logical, "later")
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.sectionCount == 1 and findAction(screen, renderer, "route-open", c.workId))
	assert(not findAction(screen, renderer, "open", c.workId), "Later rows navigate without acknowledging review")
	view.section(logical, "workspace")
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.reachableCount == 1)
	assert(findAction(screen, renderer, "route-open", a.workId) and findAction(screen, renderer, "route-open", b.workId))
	assert(not findAction(screen, renderer, "route-open", c.workId), "a set-aside conversation waits behind its disclosure")
	assert(not findAction(screen, renderer, "open"), "Workspace never emits the review activation")
	assert(not findAction(screen, renderer, "route-open", d.workId) and findAction(screen, renderer, "menu", d.workId))
	assert(string.find(textOf(screen.view), "No open pane", 1, true))
	assert(string.find(textOf(screen.view), "Set aside 1", 1, true))
	assert(string.find(textOf(screen.view), "Working", 1, true), "runtime is distinct from review reason")
end

-- Explicit priority ranks Attention only; Later dates and Workspace native order remain independent.
do
	local logical, renderer = view.newState(), view.newRenderer("ordering")
	local a, b, c, d = row(1), row(2), row(3), row(4)
	b.priority, c.priority, d.priority = 0, 3, 0
	local input = presentation({ a, b, c, d })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local rows = childAt(screen.view, "rows").c
	assert(view.resolve(renderer, findAction({ view = rows[1] }, renderer, "open")).workId == b.workId)
	assert(view.resolve(renderer, findAction({ view = rows[2] }, renderer, "open")).workId == d.workId)
	assert(not string.find(textOf(rows[4]), "P1", 1, true), "unset priority is not inferred")
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ a, b, c, d })
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(equal(actionOrder(screen, renderer, "route-open"), { a.workId, b.workId, c.workId, d.workId }),
		"Workspace keeps native order whatever the Attention priority")
end

-- Current blockers lead passive review within priority; explicit priority and native inventory order win.
do
	local logical, renderer = view.newState(), view.newRenderer("blocker-order")
	local review, waiting, delivery, startup, priority = row(1), row(2), row(3), row(4), row(5)
	waiting.nativeState, delivery.condition, startup.condition = "waiting_input", "delivery", "startup"
	priority.priority = 0
	local input = presentation({ review, waiting, delivery, startup, priority })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local rows = childAt(screen.view, "rows").c
	for index, expected in ipairs({ priority, waiting, delivery, startup, review }) do
		assert(findAction({ view = rows[index] }, renderer, "open", expected.workId), "current blockers precede passive review at equal priority")
	end
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ review, waiting, delivery, startup, priority })
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(equal(actionOrder(screen, renderer, "route-open"),
		{ review.workId, waiting.workId, delivery.workId, startup.workId, priority.workId }), "Workspace retains native order")
end

-- Current runtime never borrows a previous reply's clock; inspection retains the original evidence.
do
	local logical, renderer = view.newState(), view.newRenderer("current-event")
	local item = row(1)
	item.reviewKind = "done"
	item.sourceObservation = { status = "ready", capturedAtUtc = 1200 }
	item.source = { status = "ready", complete = true, capturedAtUtc = 1200,
		lastFinal = { id = "reply", atUtc = 1000, timeKind = "completed", text = "Earlier reply body" },
		questions = { { id = "request", text = "An earlier unresolved question", status = "open", askedAtUtc = 900 } } }
	local input = presentation({ item })
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local rows = childAt(screen.view, "rows")
	local clock = roleText(rows, "attention.age")
	assert(clock ~= nil, "settled completion must display its recorded reply clock")
	assert(clock == "Replied 10m ago", "settled completion uses the recorded reply event")
	assert(roleTitle(rows, "attention.age") == "The agent last replied 10 minutes ago.", "the chip's tooltip states the same fact in full")
	item.nativeState, item.reviewSuperseded, item.attention = "working", true, false
	local info
	screen, info = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(info.attentionCount == 0 and not findAction(screen, renderer, "next"), "model-projected non-attention work does not contribute to counts or Next")
	rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.age") == nil and roleText(rows, "attention.reason") == nil,
		"Working has neither a historical reply clock nor stale review description")
	assert(roleText(rows, "attention.runtime") == "Working")
	local inspect = view.resolve(renderer, findAction(screen, renderer, "details", item.workId))
	assert(inspect.op == "details" and inspect.reviewRevision == 1)
	view.expand(logical, inspect.workId)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(item.reviewRevision == 1 and string.find(textOf(childAt(screen.view, "rows")), "Earlier reply body", 1, true),
		"inspection preserves unread revision and original reply facts")
	assert(view.resolve(renderer, findAction(screen, renderer, "route-open", item.workId)).op == "route-open")
	view.expand(logical, item.workId)
	item.nativeState = "idle"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(roleText(childAt(screen.view, "rows"), "attention.age") == nil, "settling runtime does not resurrect superseded review")
	item.condition, item.attention = "waiting", true
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.runtime") == "Waiting for input")
	clock = roleText(rows, "attention.age")
	assert(clock ~= nil, "input blocker must display request time evidence")
	assert(clock == "Asked 11m ago", "input blocker uses the request time rather than the reply time")
	assert(chipRole(rows) == "attention.age", "a live, readable row keeps the plain solid chip")
	item.sourceObservation.status = "missing"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	clock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(clock ~= nil, "unavailable source must retain qualified request time evidence")
	assert(clock == "≈ Asked 11m ago", "an unreadable source marks the chip as recorded, in short words")
	assert(chipRole(childAt(screen.view, "rows")) == "attention.age-recorded", "an unreadable source takes the recorded chip style")
	assert(not string.find(clock, "Last known", 1, true), "the marker replaces the long phrase")
	assert(string.find(roleTitle(childAt(screen.view, "rows"), "attention.age"), "cannot be read right now", 1, true),
		"the tooltip says the recorded time comes from a source that cannot be read")
	assert(roleText(childAt(screen.view, "rows"), "attention.uncertainty") == nil, "no extra qualification chip on the row")
	item.sourceObservation.status = "ready"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(roleText(childAt(screen.view, "rows"), "attention.age") == "Asked 11m ago"
		and chipRole(childAt(screen.view, "rows")) == "attention.age", "a readable source returns the chip to the live style")
	item.source.questions[1].askedAtUtc = nil
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	clock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(clock ~= nil, "request without a timestamp must display unknown time")
	assert(clock == "Asked · time unknown", "missing request clock cannot borrow reply time")
	item.condition, item.nativeState = "delivery", "working"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.runtime") == "Delivery failed" and not string.find(textOf(rows), "Working", 1, true))
	assert(not string.find(textOf(rows), "10m ago", 1, true), "delivery blocker does not inherit historical reply clock")
end

-- A fresh source question stays distinct from a superseded reply and from native waiting.
do
	local logical, renderer = view.newState(), view.newRenderer("fresh-source-question")
	local item = row(1)
	item.reviewKind, item.reviewSuperseded, item.sourceQuestionCurrent = "done", true, true
	item.reason = "Source question recorded"
	item.sourceObservation = { status = "ready", capturedAtUtc = 1550 }
	item.source = { status = "ready", complete = true, questionCoverage = { status = "complete" },
		lastFinal = { id = "reply", atUtc = 1000, timeKind = "completed", text = "Earlier result" },
		questions = {
			{ id = "old-request", status = "open", askedAtUtc = 900, text = "Earlier request" },
			{ id = "fresh-request", status = "open", askedAtUtc = 1500, text = "New decision" },
		} }
	local input = presentation({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.reason") == "(Source question recorded)")
	assert(roleText(rows, "attention.runtime") == "Idle", "recorded source questions cannot invent native waiting")
	assert(roleText(rows, "attention.age") == "Asked 1m ago", "fresh question clock wins over the older reply and request")
	assert(not string.find(textOf(rows), "Reply to review", 1, true))
	item.sourceQuestionCurrent = false
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.reason") == nil and roleText(rows, "attention.age") == nil,
		"without a current source question, superseded review stays historical")
	item.sourceQuestionCurrent, item.nativeState, item.attention = true, "working", false
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	rows = childAt(screen.view, "rows")
	assert(roleText(rows, "attention.runtime") == "Working"
		and roleText(rows, "attention.reason") == nil and roleText(rows, "attention.age") == nil,
		"Working cannot acquire a historical source clock or reason")
end

-- Native conditions and source facts independently disclose their last-known status.
do
	for _, sample in ipairs({
		{ condition = "waiting", state = "waiting_input", runtime = "Offline · waiting for input", current = "Waiting for input",
			clock = "≈ Asked 1m ago", role = "attention.age-recorded" },
		{ condition = "delivery", state = "idle", runtime = "Offline · delivery failed", current = "Delivery failed",
			clock = "Delivery time unknown", role = "attention.age" },
		{ condition = "startup", state = "working", runtime = "Offline · startup failed", current = "Startup failed",
			clock = "Startup time unknown", role = "attention.age" },
	}) do
		local logical, renderer = view.newState(), view.newRenderer("stale-" .. sample.condition)
		local item = row(1)
		item.stale, item.condition, item.nativeState = true, sample.condition, sample.state
		item.reason = sample.runtime
		item.sourceObservation = { status = "missing", capturedAtUtc = 1600 }
		item.source = { status = "ready", complete = true,
			questions = { { id = "request", status = "open", askedAtUtc = 1500, text = "Recorded decision" } } }
		local input = presentation({ item })
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
		local rows = childAt(screen.view, "rows")
		assert(roleText(rows, "attention.runtime") == sample.runtime, "an offline condition is visibly marked Offline")
		assert(string.find(roleTitle(rows, "attention.runtime"), "Offline", 1, true), "the runtime tooltip explains the offline marker")
		assert(roleText(rows, "attention.age") == sample.clock, "source clock keeps its independent event meaning")
		assert(chipRole(rows) == sample.role, "only a time that is recorded rather than readable takes the recorded style")
		assert(roleText(rows, "attention.reason") == nil, "qualified condition is never duplicated as a reason")
		assert(not string.find(textOf(rows), "Last known", 1, true), "live rows never say Last known")
		item.stale = false
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
		rows = childAt(screen.view, "rows")
		assert(roleText(rows, "attention.runtime") == sample.current, "source unavailability alone does not make native runtime historical")
		assert(roleText(rows, "attention.age") == sample.clock, "refreshing native state does not freshen unavailable source evidence")
		assert(chipRole(rows) == sample.role, "an unreadable source keeps the chip marked after the pane returns")
	end
end

-- Recorded replies and assistant updates are not promoted to completed replies; stale clocks stay qualified.
do
	local logical, renderer = view.newState(), view.newRenderer("event-meaning")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 1500 }
	item.source = { status = "ready", complete = true,
		lastFinal = { id = "reply", atUtc = 1200, timeKind = "recorded", text = "Recorded response" } }
	local input = presentation({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local clock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(clock ~= nil, "recorded reply must display its event clock")
	assert(clock == "Replied 6m ago", "a recorded reply reads as a reply")
	assert(chipRole(childAt(screen.view, "rows")) == "attention.age", "a readable source's chip is solid")
	assert(string.find(roleTitle(childAt(screen.view, "rows"), "attention.age"), "was recorded 6 minutes ago", 1, true),
		"the tooltip keeps the recorded-not-completed qualification")
	item.source.lastFinal = nil
	item.source.lastAssistant = { id = "update", atUtc = 1400, text = "Intermediate report" }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	clock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(clock ~= nil, "assistant update must display its event clock")
	assert(clock == "Updated 3m ago", "assistant update does not claim a completed reply")
	item.stale = true
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	clock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(clock ~= nil, "stale inventory must retain its qualified event clock")
	assert(clock == "≈ Updated 3m ago" and string.find(roleTitle(childAt(screen.view, "rows"), "attention.age"), "Offline", 1, true),
		"stale inventory keeps the time, marks it recorded, and says Offline in its tooltip")
	assert(chipRole(childAt(screen.view, "rows")) == "attention.age-recorded", "an offline row takes the recorded chip style")
	assert(roleText(childAt(screen.view, "rows"), "attention.runtime") == "Offline · idle", "stale runtime is marked Offline")
	item.stale, item.nativeState, item.reason = false, "waiting_input", "Waiting for input"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(roleText(childAt(screen.view, "rows"), "attention.reason") == nil, "state is not repeated as a description")
end

-- A row whose source has not been observed in this run, or whose history is unqualified, is marked recorded, never silent.
do
	local replied = { id = "reply", atUtc = 1200, timeKind = "completed", text = "Reply" }
	local samples = {
		{ name = "unobserved", observation = false, coverage = {}, role = "attention.age-recorded" },
		{ name = "unqualified", observation = { status = "ready", capturedAtUtc = 1500 },
			coverage = { selectionSupport = "unknown" }, role = "attention.age-recorded" },
		{ name = "observed", observation = { status = "ready", capturedAtUtc = 1500 }, coverage = {}, role = "attention.age" },
	}
	for _, sample in ipairs(samples) do
		local logical, renderer = view.newState(), view.newRenderer("recorded-" .. sample.name)
		local item = row(1)
		item.sourceObservation = sample.observation or nil
		item.source = { status = "ready", complete = true, coverage = sample.coverage, lastFinal = replied }
		local input = presentation({ item })
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
		local rows = childAt(screen.view, "rows")
		assert(chipRole(rows) == sample.role, sample.name .. ": the chip style says whether the time is readable")
		local marked = string.sub(roleText(rows, "attention.age"), 1, #"≈ ") == "≈ "
		assert(marked == (sample.role == "attention.age-recorded"), sample.name .. ": the marker agrees with the style")
	end
end

-- Single-page removal and reinsertion before the anchor never hides a row or expires its arrival cue.
do
	local logical, renderer = view.newState(), view.newRenderer("single-page-anchor")
	local items = { row(1), row(2), row(3) }
	local input = presentation(items)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { now = 100 })
	items[1].nativeState, items[1].attention = "working", false
	input.revision = 2
	view.normalize(logical, input)
	local info
	screen, info = paint(renderer, logical, input, screen, { now = 200 })
	assert(info.shown == 2 and logical.starts.attention == 1)
	items[1].nativeState, items[1].attention = "idle", true
	input.revision = 3
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen, { now = 300, arrival = true })
	assert(info.shown == 3 and logical.starts.attention == 1 and info.pages == 1)
	for _, item in ipairs(items) do assert(findAction(screen, renderer, "open", item.workId), "every single-page item remains visible") end
	assert(not findAction(screen, renderer, "page"), "one-page inventory needs no recovery pager")
	screen = paint(renderer, logical, input, screen, { now = 1068 })
	assert(string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true), "768ms-old arrival remains visible for the original 900ms")
end

-- Stable anchors survive insertion and removal, with one global nearest-survivor fallback.
do
	local logical, renderer = view.newState(), view.newRenderer("anchor")
	local items = {}
	for serial = 1, 85 do items[serial] = row(serial) end
	local input = presentation(items)
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local anchor = findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open")
	assert(view.resolve(renderer, anchor).workId == "work:41")
	local added = row(999)
	added.priority = 0
	table.insert(items, 1, added)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:41"))
	for index, item in ipairs(items) do if item.workId == "work:41" then table.remove(items, index) break end end
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:42"))
	view.expand(logical, "work:84")
	input.rows = { row(1) }
	view.normalize(logical, input)
	assert(logical.pages.attention == 1 and logical.expandedWorkId == nil)
end

-- Page movement follows the displayed anchored slice, not the nominal page containing its first item.
do
	local logical, renderer = view.newState(), view.newRenderer("shifted-anchor")
	local items = {}
	for serial = 1, 160 do items[serial] = row(serial) end
	local input = presentation(items)
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	for serial = 1, 39 do
		local added = row(1000 + serial)
		added.priority = 0
		table.insert(items, 1, added)
	end
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local seen = {}
	for _, rowNode in ipairs(childAt(screen.view, "rows").c) do
		local action = findAction({ view = rowNode }, renderer, "open")
		seen[view.resolve(renderer, action).workId] = true
	end
	view.page(logical, 1)
	view.normalize(logical, input)
	local info
	screen, info = paint(renderer, logical, input, screen)
	local visible = childAt(screen.view, "rows").c
	assert(findAction({ view = visible[1] }, renderer, "open", "work:81"))
	for _, rowNode in ipairs(visible) do
		local action = findAction({ view = rowNode }, renderer, "open")
		assert(not seen[view.resolve(renderer, action).workId], "Next must not replay the shifted prior slice")
	end
	assert(string.find(textOf(childAt(childAt(screen.view, "header"), "pagination")), "120–159 of 199", 1, true))
	view.page(logical, 1)
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.shown == 40 and findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:121"))
	local atEnd = logical.starts.attention
	view.page(logical, 1)
	view.normalize(logical, input)
	assert(logical.starts.attention == atEnd, "moving beyond the last actual slice must stay put")
	view.page(logical, -1)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:81"))
end

-- Shrinking a multi-page inventory to one page exposes every surviving conversation immediately.
do
	local logical, renderer = view.newState(), view.newRenderer("short-anchor")
	local items = {}
	for serial = 1, 85 do items[serial] = row(serial) end
	local input = presentation(items)
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	local smaller = {}
	for serial = 31, 60 do table.insert(smaller, items[serial]) end
	input = presentation(smaller)
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.pages == 1 and info.shown == 30 and logical.starts.attention == 1)
	assert(not findAction(screen, renderer, "page"), "a one-page section has no hidden prefix requiring Previous")
	for serial = 31, 60 do assert(findAction(screen, renderer, "open", "work:" .. serial)) end
end

-- Review, identity and contextual action revisions are fenced, without changing stable pointer targets on ticks.
do
	local logical, renderer = view.newState(), view.newRenderer("tokens")
	local item = row(1)
	local input = presentation({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local open = findAction(screen, renderer, "open")
	local section = findAction(screen, renderer, "section")
	local _, _, unchanged = paint(renderer, logical, input, screen)
	assert(unchanged == nil, "unchanged logical/data render must not write")
	item.title = "Renamed"
	screen = paint(renderer, logical, input, screen)
	assert(findAction(screen, renderer, "open") == open, "metadata changes do not churn pointer targets")
	item.reviewRevision = 2
	screen = paint(renderer, logical, input, screen)
	assert(findAction(screen, renderer, "open") ~= open and view.resolve(renderer, open) == nil)
	assert(view.resolve(renderer, findAction(screen, renderer, "open")).reviewRevision == 2)
	view.toggleAside(logical, "tab:elsewhere")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(view.resolve(renderer, section) == nil, "old contextual selection token is no longer accepted")
	local replacement = row(2)
	replacement.pane = item.pane
	input.rows = { replacement }
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(view.resolve(renderer, open) == nil, "pane reuse never revives the prior work incarnation")
	local target = view.resolve(renderer, findAction(screen, renderer, "open"))
	target.pane = 0
	assert(view.resolve(renderer, findAction(screen, renderer, "open")).pane == replacement.pane, "resolve returns an isolated binding")
end

-- Source clocks are qualified, secondary evidence lives in detail, no idle/done or missing-time fiction.
do
	local logical, renderer = view.newState(), view.newRenderer("clocks")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 1200 }
	item.nativeState, item.reason, item.reviewSuperseded, item.attention = "working", "New update", true, false
	item.source = {
		status = "ready", selection = "disk-replayed", complete = true, revision = "r1",
		lastFinal = { id = "final", atUtc = 1000, timeKind = "completed", text = "Output" },
		lastHuman = { id = "human", atUtc = 800, text = "Build it", provenance = "user" },
		lastAssistant = { id = "working-output", atUtc = 1100, stopReason = "toolUse", text = "Artifact reported at /work/result" },
		sessionId = "source-session", selectedLeafId = "working-output", schemaVersion = 3, capturedAtUtc = 1200,
		lastInteractionAtUtc = 800,
		questions = { { id = "q1", text = "Choose a target", status = "open", askedAtUtc = 900 } },
	}
	local input = presentation({ item })
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Working", 1, true) and roleText(childAt(screen.view, "rows"), "attention.age") == nil)
	assert(not string.find(visible, "Human input", 1, true))
	local disclosure = findAction(screen, renderer, "details")
	assert(view.resolve(renderer, disclosure).workId == item.workId)
	view.expand(logical, item.workId)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "disk-replayed", 1, true) and string.find(visible, "1000", 1, true))
	assert(string.find(visible, "Choose a target", 1, true) and string.find(visible, "Human input", 1, true))
	assert(string.find(visible, "Artifact reported", 1, true) and string.find(visible, "source-session", 1, true))
	item.source.lastHuman.provenance = "unknown"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "attribution unknown", 1, true) and not string.find(visible, "Human input", 1, true))
	item.source.lastFinal.atUtc = 1700
	item.source.questions = {}
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(string.find(textOf(screen.view), "clock uncertain", 1, true))
	item.source = nil
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(string.find(textOf(screen.view), "unknown", 1, true), "legacy first observation is not a source clock")
end

-- Every bounded projected request remains inspectable; current attempts lead without changing causal facts.
do
	local logical, renderer = view.newState(), view.newRenderer("questions-coverage")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 1000 }
	item.nativeState, item.reason = "waiting_input", "Decision requested"
	item.source = {
		status = "ready", complete = true, selection = "disk-replayed",
		coverage = { recordsComplete = true, ancestryComplete = true, controlsExcluded = 9 },
		questionCoverage = { status = "bounded", knownTotal = 39, included = 32, omitted = 7, textTruncated = true },
		questions = {},
	}
	for index = 1, 32 do
		item.source.questions[index] = {
			id = "q:" .. index, text = "Projected question " .. index,
			status = if index > 30 then "open" else "answered",
			askedAtUtc = if index == 32 then 900 else 100,
		}
	end
	item.source.questions[32].text = string.rep("current request ", 100) .. "TAIL_OF_CURRENT_REQUEST"
	item.source.questions[1].answer = "Recorded earlier answer"
	local before = copy(item.source)
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1000 })
	local visible = textOf(childAt(screen.view, "rows"))
	for index = 1, 31 do assert(string.find(visible, "Projected question " .. index .. "\n", 1, true)) end
	assert(string.find(visible, "TAIL_OF_CURRENT_REQUEST", 1, true), "view must not hide the bounded current request's tail")
	assert(string.find(visible, "Recorded earlier answer", 1, true))
	local currentAt = string.find(visible, "TAIL_OF_CURRENT_REQUEST", 1, true)
	local olderAt = string.find(visible, "Projected question 1", 1, true)
	assert(currentAt and olderAt and currentAt < olderAt, "current and recent requests precede resolved history")
	local primaryClock
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(primaryClock and string.find(primaryClock, "1m ago", 1, true), "primary request clock follows latest causal open attempt")
	assert(not string.find(primaryClock, "waiting", 1, true), "recorded request age is not continuous response debt")
	assert(string.find(visible, "complete supported history", 1, true))
	assert(string.find(visible, "Question coverage: bounded", 1, true) and string.find(visible, "7 omitted", 1, true))
	assert(string.find(visible, "question text clipped", 1, true), "bounded factual text coverage remains visible")
	assert(equal(before, item.source), "presentation ordering must not mutate canonical question facts")
	item.source.questions[32].askedAtUtc = nil
	screen = paint(renderer, logical, input, screen, { nowUtc = 1000 })
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(string.find(primaryClock, "unknown", 1, true), "unknown newest timestamp must not borrow an older request's clock")
end

-- Next and Previous preserve their global purposes even from Later and Settings.
do
	local logical, renderer = view.newState(), view.newRenderer("navigation")
	local input = presentation({ row(1) })
	view.section(logical, "later")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { previous = { available = true, title = "Editor" } })
	assert(findAction(screen, renderer, "next") and findAction(screen, renderer, "previous"))
	assert(string.find(textOf(screen.view), "Prev", 1, true) and string.find(textOf(screen.view), "Next", 1, true))
	view.section(logical, "settings")
	screen = paint(renderer, logical, input, screen, { previous = { available = true, title = "Editor" } })
	assert(findAction(screen, renderer, "next") and findAction(screen, renderer, "previous"))
	input.rows = {}
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { previous = { available = false } })
	assert(not findAction(screen, renderer, "next") and not findAction(screen, renderer, "previous"))
end

-- The toolbar, its bounded non-sticky header group, and the Workspace-only current-location line.
do
	local logical, renderer = view.newState(), view.newRenderer("toolbar")
	local input = presentation({ row(1), row(2) }, "partial")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.shown == 2 and info.total == nil)
	local header = childAt(screen.view, "header")
	assert(screen.view.c[1] == header and header.p.role == "attention.header", "toolbar and location share one bounded header group")
	assert(childAt(header, "queues") and childAt(header, "tools") and childAt(header, "location") and childAt(header, "utility"))
	assert(not findAction(screen, renderer, "search"), "Search stays inert until the controller reports a route")
	assert(not findAction(screen, renderer, "reveal"), "Attention shows no current-location line")
	local sections = {}
	walk(header, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == "section" then table.insert(sections, binding.section) end
	end, true)
	assert(equal(sections, { "attention", "later", "working", "workspace" }), "four modes, in order")
	assert(not findAction(screen, renderer, "sessions"), "there is no session chooser")
	assert(not findAction(screen, renderer, "new"), "the header has no New button")
	local current = { key = "pane:local#9", title = "Quarry notes", context = "Note · Quarry · Workbench" }
	screen = paint(renderer, logical, input, screen, { search = { available = true }, current = current })
	local utility = childAt(childAt(screen.view, "header"), "utility")
	assert(utility.c[1].p.key == "search" and utility.c[2].p.key == "settings", "search then the gear, gear rightmost")
	assert(utility.c[1].p.title == "Search workspace" and utility.c[1].c[1].k == "icon" and utility.c[1].c[1].p.name == "search",
		"Search is a magnifying-glass icon button")
	assert(view.resolve(renderer, findAction(screen, renderer, "search")).logicalRevision == logical.revision)
	assert(not findAction(screen, renderer, "reveal"), "the current location stays out of Attention even when known")
	view.section(logical, "later")
	screen = paint(renderer, logical, input, screen, { current = current })
	assert(not findAction(screen, renderer, "reveal") and not string.find(textOf(screen.view), "Quarry notes", 1, true),
		"and out of Later")
	view.section(logical, "workspace")
	screen = paint(renderer, logical, input, screen, { current = current })
	assert(view.resolve(renderer, findAction(screen, renderer, "reveal")).op == "reveal", "Workspace names and reveals the current place")
	local location = textOf(childAt(childAt(screen.view, "header"), "location"))
	assert(string.find(location, "Quarry notes", 1, true) and string.find(location, "Note · Quarry · Workbench", 1, true))
	screen = paint(renderer, logical, input, screen)
	assert(not findAction(screen, renderer, "reveal") and string.find(textOf(screen.view), "No current location", 1, true),
		"Workspace with no known place says so")
	view.section(logical, "settings")
	screen = paint(renderer, logical, input, screen, { current = current })
	assert(not findAction(screen, renderer, "reveal") and not string.find(textOf(screen.view), "Quarry notes", 1, true),
		"Settings shows no current-location line")
	input.status, input.message = "unsaved", "Disk write failed"
	screen = paint(renderer, logical, input, screen)
	assert(string.find(textOf(screen.view), "not saved", 1, true))
	-- The pager sits in the bounded header after the location line: hidden on a single page, present and compact otherwise.
	assert(childAt(header, "pagination").p.hidden and not findAction(screen, renderer, "page"), "one page needs no pager")
	local many = {}
	for serial = 1, 50 do many[serial] = row(serial) end
	input = presentation(many)
	view.section(logical, "attention")
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	header = childAt(screen.view, "header")
	local pager = childAt(header, "pagination")
	assert(header.c[4] == pager and not pager.p.hidden and info.pages == 2, "the pager is the header's last row on a multi-page list")
	assert(string.find(textOf(pager), "1–40 of 50", 1, true) and childAt(pager, "page-next") and not childAt(pager, "page-prev"))
	assert(childAt(pager, "page-next").p.title == "Next page · 40 per page")
	view.page(logical, 1)
	view.normalize(logical, input)
	local change
	screen, info, change = paint(renderer, logical, input, screen)
	pager = childAt(childAt(screen.view, "header"), "pagination")
	assert(string.find(textOf(pager), "41–50 of 50", 1, true) and childAt(pager, "page-prev") and not childAt(pager, "page-next"))
	assert(change and change.set and change.set.header and change.set.header.c[4].p.key == "pagination", "paging patches the header-hosted pager")
end

-- Empty conversation queues are silent: no sentence that could be mistaken for an item. Workspace keeps its
-- explanation of a missing inventory, and a truthful status line is never suppressed.
do
	local logical, renderer = view.newState(), view.newRenderer("empty")
	local input = presentation({})
	view.normalize(logical, input)
	local screen
	for _, name in ipairs({ "attention", "later", "working" }) do
		view.section(logical, name)
		screen = paint(renderer, logical, input, screen)
		for _, key in ipairs({ "coverage", "rows", "empty", "settings" }) do
			assert(textOf(childAt(screen.view, key)) == "", "an empty " .. name .. " shows nothing in " .. key)
		end
	end
	view.section(logical, "workspace")
	screen = paint(renderer, logical, input, screen)
	assert(textOf(childAt(screen.view, "empty")) ~= "", "an empty Workspace explains the missing inventory")
	view.section(logical, "attention")
	input.status, input.message = "unsaved", "Disk write failed"
	screen = paint(renderer, logical, input, screen)
	assert(string.find(textOf(childAt(screen.view, "coverage")), "not saved", 1, true),
		"a truthful notice still shows on an empty Attention")
end

-- Arrival feedback is local and explicit, never a first paint/recovery/background catch-up replay.
do
	local logical, renderer = view.newState(), view.newRenderer("arrival")
	local input = presentation({ row(1) })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { now = 100, arrival = true })
	assert(not string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true))
	table.insert(input.rows, row(2))
	input.revision = 2
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { now = 200, arrival = true })
	assert(string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true))
	screen = paint(renderer, logical, input, screen, { now = 1200 })
	assert(not string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true))
	view.invalidate(renderer)
	screen = paint(renderer, logical, input, nil, { now = 1300, arrival = true })

	assert(not string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true))
end
-- Settings offers placement as one global default only: three default bindings with the
-- current default selected, no per-tab or bulk bindings (those live in the palette).
for _, default in { "bottom", "right", "left" } do
	local logical, renderer = view.newState(), view.newRenderer("settings")
	local input = presentation({ row(1) })
	view.section(logical, "settings")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil,
		{ settings = { position = "right", defaultPosition = default, backlogAfterSeconds = 21600 } })
	local age, roles, otherPlacement, defaults = nil, {}, 0, 0
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == "age" and binding.seconds == 21600 then age = binding end
		if binding and binding.op == "default" then
			defaults += 1
			roles[binding.position] = node.p.role
		elseif binding and binding.op == "position" then otherPlacement += 1 end
	end, true)
	assert(age, "aging stays independently actionable")
	assert(defaults == 3 and otherPlacement == 0,
		"placement offers exactly three default choices and no per-tab or bulk bindings in Settings")
	for _, position in { "bottom", "right", "left" } do
		assert(roles[position] == (if position == default then "attention.selected" else "attention.control"),
			default .. ": only the current default is selected")
	end
	local label = default:sub(1, 1):upper() .. default:sub(2)
	local visible = textOf(screen.view)
	for _, caption in { "Rail placement", "Default for new tabs: " .. label .. ".",
		"Use … in this tab relayouts just that tab" } do
		assert(string.find(visible, caption, 1, true), "the placement control is labelled " .. caption)
	end
end

-- Worst-case bounded hostile metadata preserves real wire/node/action invariants.
do
	local logical, renderer = view.newState(), view.newRenderer("bounds")
	local items = {}
	for serial = 1, 45 do
		local item = row(serial)
		item.title, item.sessionName = string.rep("世界\n", 1000), string.rep("Long session ", 1000)
		item.reason, item.context, item.hostName = string.rep("reason ", 1000), string.rep("context ", 1000), "\255invalid"
		items[serial] = item
	end
	view.normalize(logical, presentation(items))
	local screen, info = paint(renderer, logical, presentation(items))
	assert(info.shown == 40 and info.pages == 2)
	assert(string.find(textOf(screen.view), "unknown host", 1, true))
	walk(childAt(screen.view, "rows"), function(node)
		if node.k == "text" then assert(not string.find(node.p.text, "[\r\n]"), "bounded row labels are single-line") end
	end)
end

-- A failed fresh acquisition keeps useful old facts but cannot present them as current live source.
do
	local logical, renderer = view.newState(), view.newRenderer("source-observation")
	local item = row(1)
	item.source = {
		status = "ready", complete = true, selection = "disk-replayed", capturedAtUtc = 1000,
		lastFinal = { id = "final", atUtc = 800, timeKind = "completed", text = "Useful recorded result" },
	}
	item.sourceObservation = { status = "missing", capturedAtUtc = 1500, path = "/source/session.jsonl" }
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Latest source availability: missing", 1, true))
	assert(string.find(visible, "1500 UTC seconds", 1, true) and string.find(visible, "1m ago", 1, true))
	assert(string.find(visible, "Last known source snapshot", 1, true) and string.find(visible, "1000 UTC seconds", 1, true))
	assert(string.find(visible, "Useful recorded result", 1, true), "availability failure must not erase accepted source facts")
	item.sourceObservation = { status = "unchanged", capturedAtUtc = 1580 }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Latest source availability: unchanged", 1, true))
	assert(not string.find(visible, "Last known source snapshot", 1, true))
	assert(string.find(visible, "Source snapshot captured", 1, true) and string.find(visible, "1000 UTC seconds", 1, true))
	item.sourceObservation = { status = "partial", capturedAtUtc = 1590, selection = "unknown",
		recordsComplete = false, historyScope = "unavailable", selectionSupport = "unknown" }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Source history unavailable", 1, true))
	assert(string.find(visible, "Last known final completed", 1, true) and string.find(visible, "1000 UTC seconds", 1, true))
	local primaryClock
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(primaryClock == "≈ Replied 13m ago" and string.find(roleTitle(childAt(screen.view, "rows"), "attention.age"), "cannot be read right now", 1, true),
		"partial metadata observation cannot make preserved complete source facts current")
	assert(chipRole(childAt(screen.view, "rows")) == "attention.age-recorded", "preserved facts from an unreadable source take the recorded style")
	item.source = nil
	item.sourceObservation = { status = "unsupported", capturedAtUtc = 1590 }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Latest source availability: unsupported", 1, true) and string.find(visible, "Source unavailable", 1, true))
end

-- Automatic timeout selections resolve attempts without impersonating a human answer.
do
	local logical, renderer = view.newState(), view.newRenderer("answer-provenance")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 350 }
	item.source = {
		status = "ready", complete = true, selection = "disk-replayed",
		questions = {
			{ id = "manual", text = "Manual choice", status = "answered", answer = "User chose A",
				answerProvenance = "user", timedOut = false, answeredAtUtc = 200 },
			{ id = "automatic", text = "Timeout choice", status = "answered", answer = "Default B",
				answerProvenance = "automatic", timedOut = true, resolvedAtUtc = 300 },
		},
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 400 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "automatically resolved", 1, true) and string.find(visible, "timeout", 1, true))
	assert(string.find(visible, "Automatic selection", 1, true) and string.find(visible, "Default B", 1, true))
	assert(string.find(visible, "not a human reply", 1, true))
	assert(string.find(visible, "Automatic resolution recorded: 300 UTC seconds", 1, true))
	assert(string.find(visible, "User answer recorded: 200 UTC seconds", 1, true) and string.find(visible, "User chose A", 1, true))
	assert(not string.find(visible, "Human interaction recorded", 1, true), "view cannot infer human interaction from automatic or mixed results")
end

-- Partial replay keeps per-fact last-known evidence without borrowing the latest capture or reopening a resolved attempt.
do
	local logical, renderer = view.newState(), view.newRenderer("partial-last-known")
	local item = row(1)
	item.sourceObservation = { status = "partial", capturedAtUtc = 1000 }
	item.nativeState = "waiting_input"
	local priorObservation = {
		capturedAtUtc = 800, complete = true, selection = "disk-replayed", selectedLeafId = "older-leaf",
		coverage = { recordsComplete = true, ancestryComplete = true, controlsExcluded = 3 },
		questionCoverage = { status = "bounded", knownTotal = 39, included = 32, omitted = 7 },
	}
	item.source = {
		status = "partial", complete = false, capturedAtUtc = 1000, selection = "disk-replayed",
		selectedLeafId = "partial-leaf",
		lastAssistant = { id = "new-assistant", text = "Current positive assistant evidence", atUtc = 950 },
		lastHuman = { id = "new-human", provenance = "user", atUtc = 900 },
		questions = {
			{ id = "resolved", text = "Stale open replay must not return", status = "open", askedAtUtc = 990 },
			{ id = "current", text = "Current positive request", status = "open", askedAtUtc = 970 },
		},
		lastKnown = {
			lastFinal = { id = "old-final", text = "Preserved final evidence", timeKind = "completed", atUtc = 700 },
			lastAssistant = { id = "old-assistant", text = "Superseded fallback assistant", atUtc = 650 },
			lastTerminal = { id = "old-error", stopReason = "error", atUtc = 600 },
			lastHuman = { id = "old-human", provenance = "user", atUtc = 500 },
			lastInteractionAtUtc = 450, lastInteractionId = "old-interaction",
			questions = {
				{ id = "resolved", text = "Previously answered exact attempt", status = "answered",
					answer = "Recorded settled choice", answerProvenance = "user", answeredAtUtc = 750, askedAtUtc = 400 },
				{ id = "historical-open", text = "Historical unresolved request", status = "open", askedAtUtc = 300 },
			},
			provenance = {
				lastFinal = priorObservation, lastAssistant = priorObservation, lastTerminal = priorObservation,
				lastHuman = priorObservation, lastInteraction = priorObservation,
				questions = { resolved = priorObservation, ["historical-open"] = priorObservation },
			},
		},
	}
	local input = presentation({ item })
	local before = copy(item.source)
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1100 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Preserved final evidence", 1, true))
	assert(string.find(visible, "Last known final", 1, true) and string.find(visible, "800 UTC seconds", 1, true))
	assert(string.find(visible, "older-leaf", 1, true) and string.find(visible, "controls excluded: 3", 1, true))
	assert(string.find(visible, "Last known request question coverage: bounded", 1, true),
		"parser completeness at the original observation must not imply complete question projection")
	assert(string.find(visible, "Current positive assistant evidence", 1, true) and not string.find(visible, "Superseded fallback assistant", 1, true))
	assert(string.find(visible, "Last known terminal", 1, true) and string.find(visible, "Last known human interaction", 1, true))
	assert(string.find(visible, "Recorded settled choice", 1, true) and not string.find(visible, "Stale open replay", 1, true))
	assert(string.find(visible, "Last known request", 1, true), "fallback requests remain visibly historical")
	local primaryClock
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(primaryClock and not string.find(primaryClock, "Last known", 1, true) and string.find(primaryClock, "2m ago", 1, true))
	assert(equal(before, item.source), "fallback presentation must not mutate accepted evidence")
	item.source.questions = { item.source.questions[1] }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(string.find(primaryClock, "Asked", 1, true) and string.find(roleTitle(childAt(screen.view, "rows"), "attention.age"), "last recorded time", 1, true),
		"historical request time is not a current continuous wait")
	assert(string.sub(primaryClock, 1, #"≈ ") == "≈ " and chipRole(childAt(screen.view, "rows")) == "attention.age-recorded",
		"a historical request time is marked as recorded")
	-- A newly recorded positive resolution overrides the retained open question without a duplicate.
	item.source.questions = {
		{ id = "historical-open", text = "Current cancellation", status = "cancelled", cancelledAtUtc = 1050 },
	}
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Current cancellation", 1, true) and not string.find(visible, "Historical unresolved request", 1, true))
end

-- Complete disk replay is not complete question coverage; bounded retained payload and known omissions stay distinct.
do
	local logical, renderer = view.newState(), view.newRenderer("bounded-question-ledger")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 1000 }
	item.nativeState = "waiting_input"
	local priorObservation = { capturedAtUtc = 800, complete = true, selection = "disk-replayed" }
	local retained = {
		questions = {}, omittedQuestions = {
			{ id = "omitted-resolved", status = "answered", answeredAtUtc = 700 },
			{ id = "omitted-open", status = "open", askedAtUtc = 600 },
		},
		questionsKnown = 34, questionsIncluded = 32, questionsOmitted = 2, openQuestionsOmitted = 1,
		provenance = { questions = { ["omitted-resolved"] = priorObservation, ["omitted-open"] = priorObservation } },
	}
	for index = 1, 32 do
		retained.questions[index] = {
			id = "selected:" .. index, text = "Selected payload " .. index,
			status = if index == 32 then "open" else "answered", askedAtUtc = 500,
		}
		retained.provenance.questions["selected:" .. index] = priorObservation
	end
	retained.questions[1].answer = "Prior exact answer remains settled"
	retained.questions[1].answerProvenance = "user"
	item.source = {
		status = "ready", complete = true, capturedAtUtc = 1000, selection = "disk-replayed",
		questionCoverage = { status = "bounded", knownTotal = 5, included = 3, omitted = 2 },
		lastKnown = retained,
		questions = {
			{ id = "selected:1", text = "FALSE_REOPEN_FROM_BOUNDED_REPLAY", status = "open", askedAtUtc = 990 },
			{ id = "omitted-resolved", text = "OMITTED_BODY_MUST_NOT_EXPAND", status = "open", askedAtUtc = 995 },
			{ id = "selected:32", text = "Current included request", status = "open", askedAtUtc = 900 },
		},
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local before = copy(item.source)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1100 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "complete supported history", 1, true))
	assert(string.find(visible, "Known retained questions: 34 known", 1, true))
	assert(string.find(visible, "32 included", 1, true) and string.find(visible, "2 omitted", 1, true) and string.find(visible, "1 open omitted", 1, true))
	assert(string.find(visible, "Prior exact answer remains settled", 1, true) and string.find(visible, "Current included request", 1, true))
	assert(not string.find(visible, "FALSE_REOPEN", 1, true) and not string.find(visible, "OMITTED_BODY", 1, true))
	assert(equal(before, item.source), "bounded ledger rendering is read-only")
	item.source.questionCoverage = nil
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	assert(not string.find(textOf(childAt(screen.view, "rows")), "FALSE_REOPEN", 1, true), "unknown projected question coverage cannot reopen a known resolved attempt")
	item.source.questionCoverage = { status = "complete", knownTotal = 3, included = 3, omitted = 0 }
	item.source.questions[1].text = "Complete selected-branch request"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	assert(string.find(textOf(childAt(screen.view, "rows")), "Complete selected-branch request", 1, true),
		"complete factual question coverage permits current selected-history evidence")
end

-- Incomplete record scans are metadata-only: current clocks stay unknown and qualified prior facts survive.
do
	local logical, renderer = view.newState(), view.newRenderer("history-unavailable")
	local item = row(1)
	item.nativeState = "waiting_input"
	item.source = {
		status = "partial", complete = false, capturedAtUtc = 1000, selection = "unknown",
		coverage = { recordsComplete = false, historyScope = "unavailable", selectionSupport = "unknown" },
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1100 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Source history unavailable", 1, true))
	assert(not string.find(visible, "Question recorded", 1, true) and not string.find(visible, "Final completed", 1, true))
	local primaryClock
	walk(childAt(screen.view, "rows"), function(node)
		if hasRole(node, "attention.age") then primaryClock = node.p.text end
	end, true)
	assert(primaryClock and string.find(primaryClock, "unknown", 1, true))
	local qualified = { capturedAtUtc = 800, complete = true, selection = "disk-replayed", selectedLeafId = "qualified-leaf" }
	item.source.lastKnown = {
		lastFinal = { id = "qualified-final", atUtc = 700, timeKind = "completed", text = "Qualified prior result" },
		questions = { { id = "attempt", text = "Qualified prior unresolved request", status = "open", askedAtUtc = 650 } },
		provenance = { lastFinal = qualified, questions = { attempt = qualified } },
	}
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Qualified prior result", 1, true) and string.find(visible, "Last known request", 1, true))
	assert(string.find(visible, "Qualified prior unresolved request", 1, true))
	item.nativeState, item.attention = "working", false
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1100 })
	primaryClock = roleText(childAt(screen.view, "rows"), "attention.age")
	assert(primaryClock == nil, "Working cannot display a historical completion clock even when source is unavailable")
	assert(string.find(textOf(childAt(screen.view, "rows")), "Working", 1, true), "source failure does not replace current native runtime")
end

-- Row actions capture only canonical positively known headers, never transient observation UUIDs.
do
	local logical, renderer = view.newState(), view.newRenderer("header-bindings")
	local item = row(1)
	item.sourceObservation = { status = "ready", capturedAtUtc = 100, sessionId = "untrusted-observation-header" }
	local input = presentation({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	for _, op in ipairs({ "open", "details", "menu" }) do
		assert(view.resolve(renderer, findAction(screen, renderer, op)).sourceSessionId == nil)
	end
	item.sourceSessionId = "canonical-header-A"
	screen = paint(renderer, logical, input, screen)
	local oldActions = {}
	for _, op in ipairs({ "open", "details", "menu" }) do
		local action = findAction(screen, renderer, op)
		oldActions[op] = action
		assert(view.resolve(renderer, action).sourceSessionId == "canonical-header-A")
	end
	item.sourceSessionId = "canonical-header-B"
	screen = paint(renderer, logical, input, screen)
	for _, op in ipairs({ "open", "details", "menu" }) do
		assert(view.resolve(renderer, oldActions[op]) == nil, "changed known header must invalidate captured action")
		assert(view.resolve(renderer, findAction(screen, renderer, op)).sourceSessionId == "canonical-header-B")
	end
end

-- Saved source facts without a current-owner observation are last known, not freshly qualified history.
do
	local logical, renderer = view.newState(), view.newRenderer("saved-source")
	local item = row(1)
	item.nativeState, item.attention = "working", false
	item.source = { status = "ready", complete = true, selection = "disk-replayed", capturedAtUtc = 1000,
		lastFinal = { id = "saved-final", atUtc = 800, timeKind = "completed", text = "Saved useful result" } }
	local input = presentation({ item })
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Latest source availability: unknown", 1, true))
	assert(string.find(visible, "Last known final completed", 1, true))
	assert(string.find(visible, "Saved useful result", 1, true) and string.find(visible, "Working", 1, true))
	item.sourceObservation = { status = "ready", capturedAtUtc = 1590 }
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	visible = textOf(childAt(screen.view, "rows"))
	assert(not string.find(visible, "Last known final completed", 1, true) and string.find(visible, "Final completed", 1, true))
	assert(string.find(visible, "Source snapshot captured", 1, true), "fresh acquisition observation restores current-source qualification")
end


-- Model-qualified proof-pending routes expose existing Open/Next attempts without inflating verified reachability.
do
	local logical, renderer = view.newState(), view.newRenderer("header-attempt")
	local candidate, offline, retained = row(1), row(2), row(3)
	candidate.navigable, candidate.retryableHeaderRoute, candidate.sourceSessionId = false, true, "known-header"
	candidate.unavailableReason = "identity proof pending"
	offline.navigable, offline.unavailableReason = false, "disconnected"
	retained.pane, retained.navigable, retained.retained, retained.orphaned = nil, false, true, true
	retained.unavailableReason = "No open pane"
	local input = presentation({ candidate, offline, retained })
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	local open = findAction(screen, renderer, "open", candidate.workId)
	assert(open and view.resolve(renderer, open).sourceSessionId == "known-header")
	assert(not findAction(screen, renderer, "open", offline.workId) and not findAction(screen, renderer, "open", retained.workId))
	assert(info.reachableCount == 0 and info.awaitingHeaderCount == 1)
	assert(findAction(screen, renderer, "next"), "Next can attempt the one eligible model-qualified route")
	local tooltip
	walk(screen.view, function(node)
		if node.p and node.p.actions and node.p.actions.click == open then tooltip = node.p.title end
	end, true)
	assert(tooltip and string.find(tooltip, "Verify header, then open", 1, true))
	candidate.retryableHeaderRoute = false
	screen, info = paint(renderer, logical, input, screen)
	assert(info.reachableCount == 0 and info.awaitingHeaderCount == 0 and not findAction(screen, renderer, "next"))
	assert(view.resolve(renderer, open) == nil, "a withdrawn attempt route cannot retain its old Open action")
end

-- Quiet live work stays in Workspace and communicates absence of a current cue, not completion.
do
	local logical, renderer = view.newState(), view.newRenderer("quiet-facts")
	local item = row(1)
	item.attention, item.reason = false, ""
	item.sourceObservation = { status = "ready", capturedAtUtc = 1000 }
	item.source = { status = "ready", complete = true, selection = "disk-replayed", capturedAtUtc = 1000,
		lastFinal = { id = "reply", atUtc = 800, timeKind = "completed", text = "Recorded final reply" },
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	local input = presentation({ item })
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item })
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	assert(findAction(screen, renderer, "route-open", item.workId) and info.attentionCount == 0)
	view.expand(logical, item.workId)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(string.find(textOf(childAt(screen.view, "rows")), "Final completed", 1, true), "recorded response event remains independently inspectable")
end

do
	local logical, renderer = view.newState(), view.newRenderer("unqualified-selection")
	local item = row(1)
	item.sourceObservation = { status = "partial", capturedAtUtc = 1000, selectionSupport = "unknown" }
	item.source = {
		status = "partial", complete = false, capturedAtUtc = 1000, selection = "disk-replayed",
		coverage = { recordsComplete = true, historyScope = "selected-ancestry", writerSupport = "unknown", selectionSupport = "unknown" },
		questionCoverage = { status = "unknown", knownTotal = 2, included = 2, omitted = 0 },
		lastFinal = { id = "observed-final", atUtc = 900, timeKind = "completed", text = "Useful observed excerpt" },
		questions = { { id = "known", status = "answered", text = "Unqualified replacement must not settle prior question" },
			{ id = "unqualified-only", status = "open", text = "Observed attempt with unqualified selection", askedAtUtc = 950 } },
		lastKnown = {
			questions = { { id = "known", status = "open", text = "Previously qualified open attempt", askedAtUtc = 800 } },
			provenance = { questions = { known = { capturedAtUtc = 850, complete = true, selection = "disk-replayed",
				coverage = { recordsComplete = true, selectionSupport = "schema3-replayed" } } } },
		},
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1100 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Useful observed excerpt", 1, true) and string.find(visible, "selection support: unknown", 1, true))
	assert(string.find(visible, "Previously qualified open attempt", 1, true)
		and not string.find(visible, "Unqualified replacement must not settle prior question", 1, true))
	assert(string.find(visible, "Observed attempt with unqualified selection", 1, true)
		and string.find(visible, "Last known request", 1, true))
end

-- Decision evidence leads tracking and diagnostics without dropping recorded history.
do
	local logical, renderer = view.newState(), view.newRenderer("decision-first")
	local item = row(1)
	item.nativeState, item.sourceQuestionCurrent = "waiting_input", true
	item.sourceObservation = { status = "ready", capturedAtUtc = 1550, path = "/recorded/session.jsonl" }
	item.source = {
		status = "ready", complete = true, capturedAtUtc = 1550, sessionId = "exact-source-session",
		questionCoverage = { status = "complete", knownTotal = 3, included = 3, omitted = 0 },
		lastFinal = { id = "reply", text = "Review this deliverable", atUtc = 1400, timeKind = "completed" },
		lastAssistant = { id = "update", text = "A newer recorded update", atUtc = 1450 },
		questions = {
			{ id = "old", text = "An answered earlier request", status = "answered", answer = "Earlier answer", askedAtUtc = 900 },
			{ id = "current", text = "Choose the release target", status = "open", askedAtUtc = 1500 },
			{ id = "uncertain", text = "An attempt with unknown outcome", status = "unknown", askedAtUtc = 1550 },
		},
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local function disclosure()
		return childAt(childAt(screen.view, "rows").c[1], "disclosure")
	end
	local function position(key)
		for index, entry in ipairs(disclosure().c) do if entry.p.key == key then return index end end
		error("Missing disclosed fact: " .. key)
	end
	assert(disclosure().c[1].p.text == "Request open: Choose the release target")
	assert(position("question-time-1") < position("tracking") and position("tracking") < position("source-path"))
	assert(position("tracking") < position("source-identity") and position("tracking") < position("source-question-coverage"))
	local visible = textOf(disclosure())
	for _, fact in ipairs({ "Review this deliverable", "A newer recorded update", "An answered earlier request", "Earlier answer", "An attempt with unknown outcome", "exact-source-session" }) do
		assert(string.find(visible, fact, 1, true), "ordering cannot drop retained evidence")
	end
	for _, runtime in ipairs({ "exited", "unknown" }) do
		item.nativeState, item.reviewSuperseded, item.reason = runtime, true, "Source question recorded"
		item.reviewKind = "exited"
		screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
		assert(roleText(childAt(screen.view, "rows"), "attention.age") == "Asked 1m ago")
		assert(roleText(childAt(screen.view, "rows"), "attention.reason") == "(Source question recorded)")
		assert(disclosure().c[1].p.text == "Request open: Choose the release target",
			"qualified source questions do not require idle native runtime")
	end
	item.nativeState, item.sourceQuestionCurrent, item.reviewSuperseded, item.reviewKind = "idle", false, false, "done"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(disclosure().c[1].p.text == "Review this deliverable")
	assert(position("final") < position("tracking") and position("assistant") < position("source-observed"))
	item.reviewKind = "update"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(disclosure().c[1].p.text == "A newer recorded update", "update review leads with its update, not the older final")
	item.stale = true
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(string.find(disclosure().c[1].p.text, "Last known", 1, true), "decision-first evidence retains stale qualification")
	item.nativeState, item.reviewSuperseded, item.sourceQuestionCurrent = "working", true, true
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(roleText(childAt(screen.view, "rows"), "attention.age") == nil, "Working still suppresses the review clock")
end

-- Parking intent and exact availability survive collapsed rows, including legacy saved schedules.
do
	local logical, renderer = view.newState(), view.newRenderer("visible-parking")
	local morning, evening, legacy, indefinite, reference, finished = row(1), row(2), row(3), row(4), row(5), row(6)
	for _, item in ipairs({ morning, evening, legacy, indefinite, reference, finished }) do
		item.disposition, item.reviewKind, item.retained = "later", "done", true
		item.source = { lastFinal = { id = "old", text = "Old review", timeKind = "completed", atUtc = 100 } }
	end
	morning.untilUtc, morning.availableOn, morning.availableTime, morning.zone = 1767344400, "2026-01-02", "09:00", "Etc/UTC"
	evening.untilUtc, evening.availableOn, evening.availableTime, evening.zone = 1767373200, "2026-01-02", "17:00", "Etc/UTC"
	legacy.untilUtc, legacy.availableOn, legacy.zone = morning.untilUtc, "2026-01-02", "America/Los_Angeles"
	reference.disposition, finished.disposition, finished.nativeState = "reference", "finished", "working"
	local input = presentation({ morning, evening, legacy, indefinite, reference, finished })
	input.workspace = workspaceOf({ morning, evening, legacy, indefinite, reference, finished })
	view.section(logical, "later")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1767300000 })
	local nodes = rowsByWork(screen, renderer)
	local am, pm, old = roleText(nodes[morning.workId], "attention.age"), roleText(nodes[evening.workId], "attention.age"),
		roleText(nodes[legacy.workId], "attention.age")
	assert(am ~= pm and string.find(am, "09:00", 1, true) and string.find(pm, "17:00", 1, true))
	assert(string.find(am, "2026-01-02", 1, true) and string.find(am, "UTC", 1, true))
	assert(string.find(old, "2026-01-02 09:00", 1, true) and string.find(old, "UTC", 1, true),
		"legacy UTC timestamp must not be represented as a guessed local date-only schedule")
	assert(roleText(nodes[indefinite.workId], "attention.age") == "No return date")
	for _, item in ipairs({ morning, evening, legacy, indefinite }) do
		assert(not string.find(textOf(nodes[item.workId]), "Reply to review", 1, true), "review cannot override explicit parking intent")
		assert(view.resolve(renderer, findAction(screen, renderer, "route-open", item.workId)).reviewRevision == nil)
	end
	assert(not nodes[reference.workId] and not nodes[finished.workId], "only deferred conversations are in Later")
	view.expand(logical, legacy.workId)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1767300000 })
	assert(string.find(textOf(childAt(rowsByWork(screen, renderer)[legacy.workId], "disclosure")), old, 1, true),
		"legacy exact time is also available in disclosure")
	legacy.untilUtc, legacy.availableTime = math.huge, "99:99"
	screen = paint(renderer, logical, input, screen, { nowUtc = 1767300000 })
	assert(roleText(rowsByWork(screen, renderer)[legacy.workId], "attention.age") == "Return time unknown")
	view.expand(logical, legacy.workId)

	-- Workspace keeps Reference and Finished visible and quiet; deferred leaves wait behind Set aside.
	view.section(logical, "workspace")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1767300000 })
	nodes = rowsByWork(screen, renderer)
	assert(string.find(textOf(nodes[reference.workId]), "Reference", 1, true))
	assert(string.find(textOf(nodes[finished.workId]), "Finished", 1, true))
	assert(roleText(nodes[reference.workId], "workspace.title-dim") == reference.title, "Reference is low emphasis")
	assert(roleText(nodes[finished.workId], "attention.runtime") == "Working", "finished tracking does not claim the agent is finished")
	assert(not nodes[morning.workId] and not nodes[indefinite.workId])
	for _, navRow in ipairs(navigation.rows(input.workspace, logical.workspace).rows) do
		if navRow.kind == "aside" then view.toggleAside(logical, navRow.ref.key) end
	end
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1767300000 })
	nodes = rowsByWork(screen, renderer)
	for _, item in ipairs({ morning, evening, legacy, indefinite }) do
		assert(string.find(textOf(nodes[item.workId]), "Later", 1, true), "opened deferred leaves carry their marker")
		assert(view.resolve(renderer, findAction(screen, renderer, "route-open", item.workId)).reviewRevision == nil)
	end
	assert(string.find(roleText(nodes[morning.workId], "attention.age"), "09:00", 1, true), "the exact return time survives")
end

-- The tree itself, rendered from the real navigation over the synthetic census.
local function censusSnapshot(edit)
	edit = edit or {}
	local raw, options, identities, rows = census.raw(), census.options(), census.identities(), census.rows()
	if edit.raw then edit.raw(raw) end
	if edit.options then edit.options(options) end
	if edit.identities then edit.identities(identities) end
	local snapshot = navigation.project(navigation.inventory(raw, options),
		{ rows = rows, identities = identities, identityPending = {}, window = "window", nowUtc = 1 })
	local input = presentation(rows)
	input.workspace = snapshot
	return input, snapshot, rows
end

-- Every Workspace page rendered on its own: { node, bindings } in tree order.
local function collectWorkspace(input, ui)
	local state = view.newState()
	view.restore(state, { section = "workspace", collapsed = ui.collapsed, setAsideOpen = ui.setAsideOpen })
	local entries, pages = {}, 0
	while true do
		view.normalize(state, input)
		local screen, bindings, info = view.render(view.newRenderer("collect" .. pages), state, input, {})
		for _, rowNode in ipairs(childAt(screen.view, "rows").c) do table.insert(entries, { node = rowNode, bindings = bindings }) end
		pages += 1
		assert(pages < 50, "paging must terminate")
		if info.page >= info.pages then return entries end
		view.page(state, 1)
	end
end

local function bindingsOf(entry)
	local list = {}
	walk(entry.node, function(item)
		local action = item.p and item.p.actions and item.p.actions.click
		if action then table.insert(list, entry.bindings[action]) end
	end)
	return list
end

local function findEntry(entries, predicate)
	for _, entry in ipairs(entries) do
		for _, binding in ipairs(bindingsOf(entry)) do
			if predicate(binding) then return entry, binding end
		end
	end
	return nil, nil
end

local function entryFor(entries, op, key)
	return findEntry(entries, function(binding) return binding.op == op and binding.key == key end)
end

local function entryForWork(entries, op, workId)
	return findEntry(entries, function(binding) return binding.op == op and binding.workId == workId end)
end

local function workIdOf(rows, title)
	for _, item in ipairs(rows) do
		if item.title == title then return item.workId end
	end
	error("no census row titled " .. title)
end

local function listedRow(snapshot, ui, kind, title)
	for _, navRow in ipairs(navigation.rows(snapshot, ui).rows) do
		if navRow.kind == kind and navRow.title == title then return navRow end
	end
	error("no " .. kind .. " row titled " .. title)
end

-- Groups, typed counts, disclosure, flattening, empty sessions and the native More menu.
do
	local input, snapshot = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	local harborEntry, open = entryFor(entries, "workspace-open", harbor.key)
	assert(harborEntry and open.signature == harbor.signature, "a session row opens by key and signature")
	assert(string.find(textOf(harborEntry.node), "5 places", 1, true), "groups carry typed counts")
	assert(entryFor(entries, "workspace-toggle", harbor.key), "a populated session discloses")
	local _, menu = entryFor(entries, "native-menu", harbor.key)
	assert(menu and menu.signature == harbor.signature, "More carries the exact session")
	for _, name in ipairs({ "Dune", "Fjord" }) do
		local empty = listedRow(snapshot, {}, "session", name)
		local emptyEntry = entryFor(entries, "workspace-open", empty.key)
		assert(emptyEntry and string.find(textOf(emptyEntry.node), "Empty", 1, true), "an empty session stays visible")
		assert(not entryFor(entries, "workspace-toggle", empty.key), "an empty session has nothing to expand")
	end
	assert(not entryFor(entries, "workspace-open", "tab:local#" .. census.tab.single),
		"an unnamed one-agent tab shows only its conversation")
	local named = "tab:local#" .. census.tab.multiNamed
	local namedEntry, namedOpen = entryFor(entries, "workspace-open", named)
	assert(namedEntry and string.find(textOf(namedEntry.node), "tide charts", 1, true))
	assert(namedOpen.signature == snapshot.byKey[named].signature)
	assert(entryFor(entries, "native-menu", named) and entryFor(entries, "workspace-toggle", named))
	local collapsed = collectWorkspace(input, { collapsed = { [harbor.key] = true } })
	assert(#collapsed < #entries and entryFor(collapsed, "workspace-toggle", harbor.key), "collapse hides the children, not the group")
	assert(not entryFor(collapsed, "workspace-open", named), "a collapsed session hides its tabs")
	assert(entryFor(collapsed, "workspace-open", "tab:local#" .. census.tab.reference), "other sessions are untouched")
end

-- Leaf bindings: conversations navigate by route, everything else by exact key and signature.
do
	local input, snapshot, rows = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local buoy = workIdOf(rows, "Buoy audit")
	local _, route = entryForWork(entries, "route-open", buoy)
	local buoyPane = census.agentPanes("Buoy audit")[1]
	assert(route and route.pane == buoyPane and route.identityKey == "conversation:" .. buoyPane and route.serial ~= nil)
	assert(route.reviewRevision == nil, "navigating to a conversation never names a review revision")
	local slab = workIdOf(rows, "Slab survey")
	local _, slabRoute = entryForWork(entries, "route-open", slab)
	local _, slabDetails = entryForWork(entries, "details", slab)
	local _, slabMenu = entryForWork(entries, "menu", slab)
	assert(slabRoute.reviewRevision == nil and slabDetails.reviewRevision == 4 and slabMenu.reviewRevision == 4,
		"inspection and tracking keep the review identity, navigation drops it")
	assert(not findEntry(entries, function(binding) return binding.op == "open" end), "Workspace never emits the review activation")
	local notePane = census.tabPanes(census.tab.namedNote)[1]
	local noteKey = "pane:local#" .. notePane
	local noteEntry, noteOpen = entryFor(entries, "workspace-open", noteKey)
	assert(noteEntry and noteOpen.signature == snapshot.byKey[noteKey].signature and noteOpen.placement == "tiled")
	assert(string.find(textOf(noteEntry.node), "Note", 1, true))
	local browserKey = "pane:local#" .. census.tabPanes(census.tab.namedBrowser)[1]
	local browserEntry = entryFor(entries, "workspace-open", browserKey)
	assert(browserEntry and string.find(textOf(browserEntry.node), "docs.example.invalid/reading", 1, true)
		and string.find(textOf(browserEntry.node), "Browser", 1, true))
	local shellKey = "pane:local#" .. census.tabPanes(census.tab.shell)[1]
	local shellEntry = entryFor(entries, "workspace-open", shellKey)
	assert(shellEntry and string.find(textOf(shellEntry.node), "Terminal", 1, true))
	assert(findEntry({ shellEntry }, function(binding) return binding.op == "details" end) == nil, "only conversations have details")
end

-- Set aside, Reference and Finished markers, and the current destination.
do
	local input, snapshot, rows = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local blast = "tab:local#" .. census.tab.laterShared
	local asideEntry, aside = entryFor(entries, "workspace-aside", blast)
	assert(asideEntry and string.find(textOf(asideEntry.node), "Set aside 1", 1, true) and aside.logicalRevision ~= nil)
	local vibration = workIdOf(rows, "Vibration limits")
	assert(not entryForWork(entries, "route-open", vibration), "the deferred conversation waits behind the disclosure")
	assert(entryForWork(entries, "route-open", workIdOf(rows, "Charge sizing"))
		and entryForWork(entries, "route-open", workIdOf(rows, "Dust study")), "siblings in the tab stay visible")
	local opened = collectWorkspace(input, { setAsideOpen = { [blast] = true } })
	local deferred = entryForWork(opened, "route-open", vibration)
	assert(deferred and string.find(textOf(deferred.node), "Later", 1, true))
	assert(roleText(deferred.node, "workspace.title-dim") == "Vibration limits", "set-aside work is low emphasis")
	assert(entryFor(opened, "workspace-aside", blast), "the disclosure stays to close it again")
	local reference = entryForWork(entries, "route-open", workIdOf(rows, "Bale counting"))
	local finished = entryForWork(entries, "route-open", workIdOf(rows, "Kettle seam"))
	assert(string.find(textOf(reference.node), "Reference", 1, true) and string.find(textOf(finished.node), "Finished", 1, true))
	assert(roleText(reference.node, "workspace.title-dim") == "Bale counting")
	local current = entryForWork(entries, "route-open", workIdOf(rows, "Buoy audit"))
	local other = entryForWork(entries, "route-open", workIdOf(rows, "Tide ledger"))
	assert(childAt(current.node, "main").p.role == "workspace.main-current", "the current destination is highlighted")
	assert(childAt(other.node, "main").p.role == "workspace.main")
	assert(snapshot.currentPane == census.focusedPane())
end

-- Offline last-known records: a labeled section, no activation, both `omp` records distinct.
do
	local input, snapshot, rows = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local section = listedRow(snapshot, {}, "section", "Saved conversations")
	local sectionEntry = entryFor(entries, "workspace-toggle", section.key)
	assert(sectionEntry and string.find(textOf(sectionEntry.node), "8 saved", 1, true))
	local saved, works = {}, {}
	for _, item in ipairs(rows) do
		if item.pane > 700 then
			local entry = entryForWork(entries, "details", item.workId)
			assert(entry, "every saved conversation is listed")
			assert(not entryForWork(entries, "route-open", item.workId) and not entryForWork(entries, "open", item.workId),
				"a saved conversation is never presented as an open pane")
			assert(entryForWork(entries, "menu", item.workId) and string.find(textOf(entry.node), "Offline", 1, true))
			table.insert(saved, entry)
			works[item.workId] = true
		end
	end
	local omp = 0
	for _, entry in ipairs(saved) do
		if roleText(entry.node, "attention.title") == "omp" then omp += 1 end
	end
	assert(#saved == 8 and omp == 2, "both omp-titled records stay separate rows")
	local collapsed = collectWorkspace(input, { collapsed = { [section.key] = true } })
	assert(entryFor(collapsed, "workspace-toggle", section.key) and not findEntry(collapsed, function(binding)
		return works[binding.workId] == true
	end), "collapsing the section hides the records and keeps the section")
end

-- A second proven route is its own leaf; navigation targets that pane, tracking targets the record.
do
	local notePane = census.tabPanes(census.tab.namedNote)[1]
	local buoyPane = census.agentPanes("Buoy audit")[1]
	local input, _, rows = censusSnapshot({ identities = function(identities)
		identities[notePane] = "conversation:" .. buoyPane
	end })
	local entries = collectWorkspace(input, {})
	local buoy = workIdOf(rows, "Buoy audit")
	local count, extra = 0, nil
	for _, entry in ipairs(entries) do
		for _, binding in ipairs(bindingsOf(entry)) do
			if binding.op == "route-open" and binding.workId == buoy then
				count += 1
				if binding.pane == notePane then extra = entry end
			end
		end
	end
	assert(count == 2 and extra, "both routes are reachable")
	local routes = {}
	for _, binding in ipairs(bindingsOf(extra)) do routes[binding.op] = binding end
	assert(routes["route-open"].pane == notePane and routes["route-open"].identityKey == "conversation:" .. buoyPane)
	assert(routes.details.pane == buoyPane and routes.menu.pane == buoyPane, "tracking stays with the record's preferred route")
end

-- Attention keeps the review activation; Later navigates.
do
	local input, _, rows = censusSnapshot()
	local logical, renderer = view.newState(), view.newRenderer("census-queues")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local slab = workIdOf(rows, "Slab survey")
	local open = view.resolve(renderer, findAction(screen, renderer, "open", slab))
	assert(open.reviewRevision == 4 and open.identityKey == "conversation:" .. census.agentPanes("Slab survey")[1])
	assert(not findAction(screen, renderer, "route-open"), "Attention rows acknowledge through open only")
	view.section(logical, "later")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	local route = view.resolve(renderer, findAction(screen, renderer, "route-open", workIdOf(rows, "Vibration limits")))
	assert(route.op == "route-open" and route.reviewRevision == nil and not findAction(screen, renderer, "open"))
end

-- Markers for floating and parked panes; parked leaves are rendered but flagged for the controller to withhold.
do
	local floating, parked = census.tabPanes(census.tab.namedNote)[1], 880
	local input, snapshot = censusSnapshot({ raw = function(raw)
		for _, source in ipairs(raw.panes) do
			if source.pane == floating then source.floating = true end
		end
		table.insert(raw.panes, { pane = parked, title = "Set down", kind = "browser", url = "https://parked.example.invalid/", parked = true })
		table.insert(raw.hosts[1].panes, parked)
		table.insert(raw.panes, { pane = 881, title = "Mystery", kind = nil, cwd = "" })
		table.insert(raw.hosts[1].panes, 881)
	end })
	local entries = collectWorkspace(input, {})
	local floatEntry, floatOpen = entryFor(entries, "workspace-open", "pane:local#" .. floating)
	assert(floatEntry and string.find(textOf(floatEntry.node), "Floating", 1, true) and floatOpen.placement == "floating")
	local parkedEntry, parkedOpen = entryFor(entries, "workspace-open", "pane:local#" .. parked)
	assert(parkedEntry and string.find(textOf(parkedEntry.node), "Parked", 1, true), "parked panes are rendered")
	assert(parkedOpen.placement == "parked" and parkedOpen.signature == snapshot.byKey["pane:local#" .. parked].signature)
	local unknown = entryFor(entries, "workspace-open", "pane:local#881")
	assert(unknown and string.find(textOf(unknown.node), "Pane", 1, true), "an unknown kind is still a destination")
end

-- Offline hosts keep their rows without activating panes or reporting counts.
do
	local FAR = 900
	local input, snapshot = censusSnapshot({ raw = function(raw)
		raw.hosts[2].panes = { FAR }
		table.insert(raw.sessions, { id = 77, host = 2, name = "Remote work", current = false })
		table.insert(raw.tabs, { id = 90, session = 77, pane = FAR, position = 1 })
		table.insert(raw.panes, { pane = FAR, tab = 90, title = "Far shell", kind = "terminal", program = "zsh", cwd = "" })
	end })
	local entries = collectWorkspace(input, {})
	local remote = listedRow(snapshot, {}, "host", "Remote Lab")
	local remoteEntry = entryFor(entries, "workspace-open", remote.key)
	assert(remoteEntry and string.find(textOf(remoteEntry.node), "Host reconnecting", 1, true))
	assert(not string.find(textOf(remoteEntry.node), "places", 1, true), "an unreachable host never reports a count")
	local farKey = "pane:host-two.invalid#" .. FAR
	assert(snapshot.byKey[farKey] and not entryFor(entries, "workspace-open", farKey), "an offline pane is listed without an activation")
	local farNode
	for _, entry in ipairs(entries) do
		if string.find(textOf(entry.node), "Far shell", 1, true) then farNode = entry end
	end
	assert(farNode and string.find(textOf(farNode.node), "Offline", 1, true))
end

-- Persisted UI is exactly the section and the disclosure sets; hostile input is sanitized.
do
	local input, snapshot = censusSnapshot()
	local logical = view.newState()
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	local blast = "tab:local#" .. census.tab.laterShared
	local intent = logical.intentRevision
	view.section(logical, "workspace")
	view.toggleGroup(logical, harbor.key)
	view.toggleAside(logical, blast)
	assert(logical.intentRevision == intent + 3 and logical.workspace.collapsed[harbor.key] and logical.workspace.setAsideOpen[blast],
		"disclosure changes are explicit intent")
	view.normalize(logical, input)
	view.page(logical, 1)
	view.expand(logical, "work:3")
	view.section(logical, "settings")
	local saved = view.ui(logical)
	assert(equal(saved, { section = "workspace", collapsed = { [harbor.key] = true }, setAsideOpen = { [blast] = true } }),
		"only the section and the disclosure sets persist")
	saved.collapsed[harbor.key] = nil
	assert(logical.workspace.collapsed[harbor.key], "the persisted value is a copy")
	local restored = view.newState()
	view.restore(restored, view.ui(logical))
	assert(equal(view.ui(restored), view.ui(logical)) and not restored.settings and restored.expandedWorkId == nil)
	assert(restored.pages.workspace == 1 and restored.anchors.workspace == nil, "pages and anchors are memory-only")
	view.toggleGroup(logical, harbor.key)
	view.toggleGroup(logical, harbor.key)
	assert(logical.workspace.collapsed[harbor.key], "a second toggle collapses again")
	view.toggleGroup(restored, harbor.key)
	assert(restored.workspace.collapsed[harbor.key] == nil, "a toggle reopens a collapsed group")
	assert(not pcall(view.toggleGroup, restored, 7) and not pcall(view.toggleAside, restored, ""), "keys must be non-empty strings")

	local hostile = {
		section = "settings",
		collapsed = { [1] = true, ok = true, no = "yes", off = false, nested = {}, [string.rep("k", 300)] = true },
		setAsideOpen = "everything", pages = { workspace = 9 }, expandedWorkId = "work:1", settings = true,
	}
	local clean = view.newState()
	view.restore(clean, hostile)
	assert(equal(view.ui(clean), { section = "attention", collapsed = { ok = true }, setAsideOpen = {} }),
		"unknown sections fall back to Attention and only exact true string keys survive")
	assert(clean.pages.workspace == 1 and clean.expandedWorkId == nil and not clean.settings)
	for _, junk in ipairs({ "text", 7, true }) do
		local fresh = view.newState()
		view.restore(fresh, junk)
		assert(equal(view.ui(fresh), { section = "attention", collapsed = {}, setAsideOpen = {} }))
	end
	local many = {}
	for index = 1, 700 do many["key" .. index] = true end
	local bounded = view.newState()
	view.restore(bounded, { section = "later", collapsed = many })
	local kept = 0
	for _ in pairs(view.ui(bounded).collapsed) do kept += 1 end
	assert(view.ui(bounded).section == "later" and kept <= 512, "restored state is bounded")
end

-- Row-key anchors survive collapse and expansion; the next surviving neighbor takes over, then the previous.
do
	local input, snapshot = censusSnapshot()
	local logical, renderer = view.newState(), view.newRenderer("anchors")
	view.section(logical, "workspace")
	view.normalize(logical, input)
	view.page(logical, 1)
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.page == 2 and info.pages == 2, "the census needs a second Workspace page")
	local before = copy(logical.anchors.workspace)
	local firstNode = childAt(screen.view, "rows").c[1].p.key
	local function listedKeys()
		local keys = {}
		for index, navRow in ipairs(navigation.rows(snapshot, logical.workspace).rows) do keys[navRow.key] = index end
		return keys
	end
	-- Collapsing a session above the anchor moves the slice's index, not its first row.
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	assert(listedKeys()[harbor.key] < before.index)
	view.toggleGroup(logical, harbor.key)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.anchors.workspace.key == before.key and logical.starts.workspace < before.index)
	assert(childAt(screen.view, "rows").c[1].p.key == firstNode, "the same row still leads the page")
	-- Collapsing the group that holds the anchor moves it to the next surviving neighbor.
	local order = copy(logical.anchors.workspace)
	local listed = navigation.rows(snapshot, logical.workspace).rows
	local holder
	for index, navRow in ipairs(listed) do
		if navRow.key == order.key then
			for back = index, 1, -1 do
				if listed[back].kind == "session" then holder = listed[back].key break end
			end
		end
	end
	assert(holder, "the anchor sits inside a session")
	view.toggleGroup(logical, holder)
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	local survivors = listedKeys()
	local expected
	if survivors[order.key] then expected = order.key
	else
		for index = order.index + 1, #order.order do
			if survivors[order.order[index]] then expected = order.order[index] break end
		end
	end
	assert(expected and logical.anchors.workspace.key == expected, "the anchor moves to the next surviving row")
	assert(info.shown > 0 and childAt(screen.view, "rows").c[1].p.key ~= firstNode)
end

-- Five hundred destinations stay within the native caps and every one stays reachable through the pager.
do
	local raw = { hosts = { { id = 1, kind = "local", name = "Workbench", state = "connected", current = true, panes = {} } },
		sessions = {}, tabs = {}, panes = {}, agents = {}, canvases = {}, focused = nil }
	local pane, tab = 1000, 5000
	for session = 1, 5 do
		table.insert(raw.sessions, { id = session, host = 1, name = "Session " .. session, current = session == 1, locked = false, tabs = 10 })
		for position = 1, 10 do
			tab += 1
			local first
			for _ = 1, 10 do
				pane += 1
				first = first or pane
				table.insert(raw.hosts[1].panes, pane)
				table.insert(raw.panes, { pane = pane, tab = tab, title = "Shell " .. pane, kind = "terminal", program = "zsh",
					cwd = "", floating = false, parked = false })
			end
			table.insert(raw.tabs, { id = tab, session = session, name = "Tab " .. tab, position = position, pane = first,
				title = "Shell", panes = 10 })
		end
	end
	local snapshot = navigation.project(navigation.inventory(raw, census.options()),
		{ rows = {}, identities = {}, identityPending = {}, window = "window", nowUtc = 1 })
	assert(snapshot.counts.destinations == 500)
	local input = presentation({})
	input.workspace = snapshot
	local logical, renderer = view.newState(), view.newRenderer("wide")
	view.section(logical, "workspace")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	local reached, pages = {}, 1
	while true do
		assert(info.shown <= 40 and bytes(screen) < 256 * 1024, "every page stays inside the native caps")
		walk(screen.view, function(node)
			local action = node.p and node.p.actions and node.p.actions.click
			local binding = action and view.resolve(renderer, action)
			if binding and binding.op == "workspace-open" and string.sub(binding.key, 1, 5) == "pane:" then reached[binding.key] = true end
		end, true)
		if info.page >= info.pages then break end
		assert(findAction(screen, renderer, "page"), "the pager is present whenever there is another page")
		view.page(logical, 1)
		view.normalize(logical, input)
		screen, info = paint(renderer, logical, input, screen)
		pages += 1
		assert(pages < 50)
	end
	local count = 0
	for _ in pairs(reached) do count += 1 end
	assert(count == 500 and pages == info.pages and pages > 12, "all 500 destinations are reachable by paging")
	local pager = childAt(childAt(screen.view, "header"), "pagination")
	assert(not pager.p.hidden, "the last page keeps its way back")
	local previous
	walk(pager, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == "page" and binding.delta == -1 then previous = binding end
	end, true)
	assert(previous and previous.section == "workspace")
end

-- Sections retain their own keyed pagination state; the removed All section stays gone.
do
	local logical = view.newState()
	assert(logical.section == "attention" and next(logical.workspace.collapsed) == nil and next(logical.workspace.setAsideOpen) == nil)
	assert(logical.pages.all == nil and logical.starts.all == nil)
	assert(not pcall(view.section, logical, "all"), "the All work section no longer exists")
	for _, name in ipairs({ "workspace", "working", "later", "attention" }) do
		view.section(logical, name)
		assert(logical.section == name and not logical.settings)
	end
end

-- A pending route-open shows progress on exactly the leaf being opened.
do
	local first, second = row(1), row(2)
	local logical, renderer = view.newState(), view.newRenderer("leaf-pending")
	local input = presentation({ first, second })
	input.workspace = workspaceOf({ first, second })
	view.section(logical, "workspace")
	view.normalize(logical, input)
	local pending = { workId = first.workId, serial = first.serial, pane = first.pane, identityKey = first.identityKey, phase = "checking" }
	local screen = paint(renderer, logical, input, nil, { navigation = pending })
	local nodes = rowsByWork(screen, renderer)
	assert(roleText(nodes[first.workId], "attention.navigation-pending") ~= nil)
	assert(roleText(nodes[second.workId], "attention.navigation-pending") == nil)
	assert(not findAction(screen, renderer, "route-open", first.workId) and findAction(screen, renderer, "route-open", second.workId))
end

-- Bottom strip: the session is its own column spanning both row lines in every conversation row (Attention, Later,
-- Working, Workspace leaf, saved conversation); a left or right rail keeps it inside the metadata line instead.
do
	local function build(sessionName)
		local active, later, saved = row(1), row(2), row(3)
		for _, item in ipairs({ active, later, saved }) do item.sessionName = sessionName end
		later.disposition, later.attention, later.reason = "later", false, "Deferred"
		saved.pane, saved.navigable, saved.retained, saved.attention, saved.disposition = nil, false, true, false, "reference"
		saved.unavailableReason = "No open pane"
		return active, later, saved
	end
	local function shape(section, position, sessionName)
		local active, later, saved = build(sessionName)
		if section == "working" then active.nativeState = "working" end
		local logical, renderer = view.newState(), view.newRenderer("session-column-" .. section .. "-" .. position)
		local input = presentation({ active, later, saved })
		input.workspace = workspaceOf({ active, later, saved })
		view.section(logical, section)
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { nowUtc = 1600, position = position })
		return childAt(screen.view, "rows"), renderer, screen, { active, later, saved }
	end
	local function count(root, role)
		local found = 0
		walk(root, function(item) if item.p and item.p.role == role then found += 1 end end, true)
		return found
	end
	-- Workspace shows the active leaf and the saved conversation; the Later leaf is collapsed under Set aside.
	for _, case in ipairs({ { "attention", 1 }, { "later", 1 }, { "working", 1 }, { "workspace", 2 } }) do
		local rows, renderer, screen, items = shape(case[1], "bottom", "harbor")
		assert(count(rows, "attention.session-cell") == case[2],
			case[1] .. ": every conversation row has a session column in the bottom strip")
		assert(count(rows, "attention.session") == 0, case[1] .. ": the metadata line no longer repeats the session")
		assert(roleText(rows, "attention.session-name") == "harbor", case[1] .. ": the column carries the session name")
		assert(roleTitle(rows, "attention.session-name") == "harbor", "an ellipsized session name keeps its full text in a tooltip")
		assert(roleText(rows, "attention.title") ~= nil and roleText(rows, "attention.runtime") ~= nil,
			"title and state stay beside the session column")
		if case[1] == "attention" then
			local open = findAction(screen, renderer, "open", items[1].workId)
			assert(open and view.resolve(renderer, open).identityKey == items[1].identityKey, "the session column leaves the open action intact")
		end
	end
	for _, position in ipairs({ "left", "right" }) do
		for _, section in ipairs({ "attention", "later", "working", "workspace" }) do
			local rows = shape(section, position, "harbor")
			assert(count(rows, "attention.session-cell") == 0 and count(rows, "attention.session-name") == 0,
				position .. ": a narrow rail has no session column")
		end
		local rows = shape("attention", position, "harbor")
		assert(roleText(rows, "attention.session") == "harbor", position .. ": the session stays in the metadata line")
	end
end

-- Currently working is a live-state view, not a tracking disposition or an identity-enrichment gate.
do
	local items = {}
	for serial = 1, 12 do
		items[serial] = row(serial)
		items[serial].nativeState, items[serial].attention = "working", false
	end
	items[2].disposition, items[2].untilUtc = "later", 1
	items[3].disposition, items[4].disposition = "reference", "finished"
	items[5].nativeState, items[6].nativeState = "idle", "waiting_input"
	items[6].attention = true
	items[7].stale, items[8].pane, items[9].orphaned = true, nil, true
	items[10].noOpenPane, items[11].offline = true, true
	items[12].identityKey, items[12].navigable, items[12].unavailableReason = nil, false, "identity pending"
	items[12].retryableHeaderRoute = true
	items[1].priority, items[1].queueOrder = 0, 12
	local input = presentation(items)
	local ordered = view.queue(input, "working")
	assert(#ordered == 5 and ordered[1] == items[2] and ordered[2] == items[3]
		and ordered[3] == items[4] and ordered[4] == items[1] and ordered[5] == items[12],
		"working uses stable queue order then serial, regardless of priority, date, disposition or source identity")
	assert(#view.queue(input, "attention") == 1 and view.queue(input, "attention")[1] == items[6])
	assert(#view.queue(input, "later") == 1 and view.queue(input, "later")[1] == items[2])
	local logical, renderer = view.newState(), view.newRenderer("currently-working")
	view.section(logical, "working")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input, nil, { position = "bottom" })
	assert(info.workingCount == #ordered and info.sectionCount == #ordered)
	local queues = childAt(childAt(screen.view, "header"), "queues")
	assert(queues.c[1].p.key == "attention" and queues.c[2].p.key == "later"
		and queues.c[3].p.key == "working" and queues.c[4].p.key == "workspace")
	assert(textOf(queues.c[3]) == "Currently working\n5" and queues.c[3].p.role == "attention.queue-selected")
	assert(childAt(childAt(screen.view, "header"), "location").p.hidden, "current location stays Workspace-only")
	for _, item in ipairs(ordered) do
		local open = findAction(screen, renderer, "route-open", item.workId)
		assert(open and view.resolve(renderer, open).reviewRevision == nil and not findAction(screen, renderer, "open", item.workId),
			"working opens route without acknowledging a review")
		assert(findAction(screen, renderer, "details", item.workId) and findAction(screen, renderer, "menu", item.workId))
	end
	view.expand(logical, items[3].workId)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(childAt(rowsByWork(screen, renderer)[items[3].workId], "disclosure"), "working has recorded-fact disclosure")
	local saved, restored = view.ui(logical), view.newState()
	view.restore(restored, saved)
	assert(restored.section == "working" and restored.pages.working == 1 and restored.starts.working == 1
		and restored.expandedWorkId == nil and not restored.settings, "only the selected mode survives restoration")
	items[1].nativeState, items[1].attention = "waiting_input", true
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == 4 and #view.queue(input, "attention") == 2
		and rowsByWork(screen, renderer)[items[1].workId] == nil, "waiting leaves Working for existing Attention semantics")
	assert(items[1].disposition == "active" and items[2].disposition == "later", "view changes no tracking dispositions")
	for _, item in ipairs(items) do item.nativeState = "idle" end
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == 0 and #childAt(screen.view, "rows").c == 0 and childAt(screen.view, "empty").p.hidden,
		"empty Working is clean without a placeholder or fabricated row")
end

-- Working anchors survive membership changes and the full badge count is independent of its page.
do
	local items = {}
	for serial = 1, 85 do
		local item = row(serial)
		item.nativeState, item.attention = "working", false
		table.insert(items, item)
	end
	local input, logical, renderer = presentation(items), view.newState(), view.newRenderer("working-pages")
	view.section(logical, "working")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.workingCount == 85 and info.pages == 3 and #childAt(screen.view, "rows").c == 40)
	view.page(logical, 1)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.anchors.working.key == "r41" and childAt(screen.view, "rows").c[1].p.key == "r41")
	items[41].nativeState, items[41].attention = "waiting_input", true
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(logical.anchors.working.key == "r42" and childAt(screen.view, "rows").c[1].p.key == "r42"
		and info.workingCount == 84, "a departed anchor advances to its surviving neighbor")
	view.section(logical, "attention")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.starts.attention == 1 and #childAt(screen.view, "rows").c == 1)
	view.section(logical, "working")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(childAt(screen.view, "rows").c[1].p.key == "r42", "switching modes preserves the Working anchor")
	view.page(logical, 1)
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == 84 and #childAt(screen.view, "rows").c == 4
		and childAt(screen.view, "rows").c[1].p.key == "r82", "the final page keeps honest full totals")
end

-- Queue derivation is memoized per presentation: repeats on unchanged content reuse the identical list,
-- while in-place edits or a rebuilt presentation re-derive.
do
	local items = {}
	for serial = 1, 12 do
		local item = row(serial)
		item.nativeState, item.attention = "working", false
		items[serial] = item
	end
	items[2].disposition, items[2].untilUtc = "later", 1
	items[1].priority, items[1].queueOrder = 0, 12
	local input = presentation(items)
	local working = view.queue(input, "working")
	assert(#working == 12 and working[1] == items[2] and working[11] == items[1] and working[12] == items[12],
		"queue derives the working order with queue order then serial tie-breaks")
	assert(view.queue(input, "working") == working and view.queue(input, "later")[1] == items[2],
		"unchanged content reuses the memoized list per section")
	items[5].nativeState = "idle"
	local trimmed = view.queue(input, "working")
	assert(#working == 12 and #trimmed == 11 and trimmed[10] == items[1] and trimmed[11] == items[12],
		"an in-place row edit re-derives without disturbing the earlier list")
	assert(view.queue(presentation(items), "working") ~= trimmed and #view.queue(presentation(items), "working") == 11,
		"a rebuilt presentation derives its own list")
	items[7].attention, items[8].attention = true, true
	assert(view.queue(input, "attention")[1] == items[7], "equal priority falls back to queue order")
	items[8].priority = 0
	local ranked = view.queue(input, "attention")
	assert(ranked[1] == items[8] and ranked[2] == items[7], "an ordering-only edit also invalidates the memo")
end

-- Normalization bounds the live disclosure maps with the same cap restore applies, so a long-lived VM cannot
-- grow them without limit and the persisted ui copy mirrors the bounded live maps exactly.
do
	local logical = view.newState()
	for index = 1, 600 do view.toggleGroup(logical, "group:" .. index) end
	for index = 1, 520 do view.toggleAside(logical, "aside:" .. index) end
	view.normalize(logical, presentation({ row(1) }))
	local collapsed, setAside = logical.workspace.collapsed, logical.workspace.setAsideOpen
	local function size(map)
		local count = 0
		for _ in pairs(map) do count += 1 end
		return count
	end
	local ui = view.ui(logical)
	assert(size(collapsed) == 512 and size(setAside) == 512, "over-cap maps trim to exactly the 512-key cap")
	assert(size(ui.collapsed) == 512 and size(ui.setAsideOpen) == 512, "the persisted copy stays bounded with the live maps")
	for key in pairs(collapsed) do assert(ui.collapsed[key] == true, "the ui copy carries every surviving live key") end
	for key in pairs(setAside) do assert(ui.setAsideOpen[key] == true, "the ui copy carries every surviving aside key") end
	for key in pairs(ui.collapsed) do assert(collapsed[key] == true, "the ui copy invents no live key") end
	assert(collapsed["group:1"] == true and collapsed["group:99"] == nil,
		"eviction keeps the lexicographically smallest keys, exactly like restore and the persisted sanitizer")
	local restored = view.newState()
	view.restore(restored, ui)
	local function sameSet(a, b)
		for key in pairs(a) do if b[key] ~= true then return false end end
		for key in pairs(b) do if a[key] ~= true then return false end end
		return true
	end
	assert(sameSet(restored.workspace.collapsed, collapsed) and sameSet(restored.workspace.setAsideOpen, setAside),
		"the bounded live maps are exactly what restore keeps, so eviction matches the persisted rule")
end

return true
