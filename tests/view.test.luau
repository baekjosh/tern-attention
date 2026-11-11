local realView = require("../view")
local navigation = require("../navigation")
local census = require("./census")
local nativeCanvas = require("./native_canvas")
local copy, childAt = nativeCanvas.copy, nativeCanvas.childAt

-- The controller hands the Workspace snapshot to both normalization and rendering; fixtures carry it on the
-- presentation so every existing call site keeps its shape.
local view = setmetatable({
	normalize = function(logical, input)
		return realView.normalize(logical, input)
	end,
	render = function(renderer, logical, input, options)
		local merged = table.clone(options or {})
		if merged.workspace == nil then merged.workspace = input.workspace end
		-- The long-standing row assertions below exercise the bottom strip's two-line rows; the left/right rail
		-- anatomy has its own section further down, which passes an explicit position.
		if merged.position == nil then merged.position = "bottom" end
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
	open = true, ["route-open"] = true, details = true, menu = true, section = true,
	next = true, previous = true, settings = true, position = true, default = true, age = true,
	search = true, new = true, reveal = true, ["workspace-toggle"] = true,
	["workspace-open"] = true, ["native-menu"] = true, ["cancel-navigation"] = true,
	["workspace-minimize"] = true, ["queue-menu"] = true,
}
local kinds = {
	col = true, row = true, section = true, rule = true, spacer = true, text = true,
	badge = true, kbd = true, icon = true, spinner = true, el = true, status = true, seg = true, split = true, list = true,
}
-- A workspace list's render units (one per listed row): ledger blocks flatten to their label (the session's row; its
-- edge strip belongs to it) and their rows, a Minimized group to its toggle and its boxes; other rows stand alone.
local function ledgerUnits(rowsContainer)
	local units = {}
	local function add(rowNode)
		if rowNode.p and (rowNode.p.role == "workspace.ledger" or rowNode.p.role == "workspace.ledger-current") then
			table.insert(units, (childAt(rowNode, "label")))
			for _, ledgerRow in ipairs(childAt(rowNode, "rows").c or {}) do table.insert(units, ledgerRow) end
		elseif rowNode.p and rowNode.p.role == "workspace.minimized-line" then
			table.insert(units, (childAt(rowNode, "toggle")))
			local boxes = childAt(rowNode, "boxes")
			for _, box in ipairs(if boxes then boxes.c or {} else {}) do add(box) end
		else
			table.insert(units, rowNode)
		end
	end
	for _, rowNode in ipairs(rowsContainer.c or {}) do add(rowNode) end
	return units
end

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
	walk(screen.view, function(node)
		local role = node.p and node.p.role
		assert(not (role and (string.find(role, "pagination", 1, true) or string.find(role, "page-control", 1, true))),
			"nothing paginates: every row shows")
	end)
	if change then assert(bytes(change) < 256 * 1024, "native patch wire budget") end
	if screen.view.k == "split" then
		assert(screen.view.p.key == "regions" and screen.view.p.dir == "col" and screen.view.p.grow == 1
			and #screen.view.c == 2, "a left/right rail is one split root of two regions")
		local top, bottom = childAt(screen.view, "top"), childAt(screen.view, "bottom")
		assert(top and bottom, "stable region keys")
		for _, key in ipairs({ "tools", "coverage", "settings", "stack" }) do
			assert(childAt(top, key), "stable top region child missing: " .. key)
		end
		for _, key in ipairs({ "head", "rows", "empty" }) do
			assert(childAt(bottom, key), "stable workspace region child missing: " .. key)
		end
		assert(bottom.c[#bottom.c].p.key == "head", "the Workspace head is the region's last child: a pinned footer with the tree above it")
		local head = childAt(bottom, "head")
	assert(#head.c == 1 and (childAt(childAt(head, "line"), "title") or childAt(childAt(head, "line"), "location")),
		"the Workspace head is the place line itself: one line, the region's name or the reveal control")
		for _, name in ipairs({ "attention", "working" }) do
			local section = childAt(childAt(top, "stack"), name)
			assert(section and childAt(section, "head") and childAt(section, "rows"), "each queue section keeps its header and rows")
		end
	else
		for _, key in ipairs({ "header", "coverage", "rows", "empty", "settings" }) do
			assert(childAt(screen.view, key), "stable native root child missing")
		end
		assert(childAt(screen.view, "header") and not childAt(screen.view, "pagination"), "no pager row exists anywhere")
	end
	local function checkRows(list)
		for _, unit in ipairs(ledgerUnits(list)) do
			local actions = 0
			walk(unit, function(item) if item.p and item.p.actions then actions += 1 end end)
			assert(actions <= 3, "a row exposes at most three actions")
		end
	end
	if screen.view.k == "split" then
		for _, name in ipairs({ "attention", "working" }) do
			checkRows(childAt(childAt(childAt(childAt(screen.view, "top"), "stack"), name), "rows"))
		end
		checkRows(childAt(childAt(screen.view, "bottom"), "rows"))
	else
		checkRows(childAt(screen.view, "rows"))
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
		live = true,
	}
end

local function presentation(rows, status)
	local attention, reachable = 0, 0
	for _, item in ipairs(rows) do
		if item.attention then
			attention += 1
			if item.navigable then reachable += 1 end
		end
	end
	return {
		rows = rows, status = status or "ready", revision = 1,
		count = if not status or status == "ready" or status == "unsaved" then #rows else nil,
		knownCount = #rows, allCount = #rows, attentionCount = attention,
		reachableCount = reachable, attentionTargets = {},
	}
end

-- One session, one unnamed tab per row with a pane (or, with `parked`, every pane parked: one leaf row each, no tab
-- row); rows without a pane stay saved conversations. Real navigation builds the snapshot.
local function workspaceOf(items, parked)
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
				cwd = "/work", floating = false, parked = parked == true })
			table.insert(raw.agents, { pane = item.pane, state = "idle" })
			identities[item.pane] = item.identityKey
		end
	end
	local data = navigation.inventory(raw, census.options())
	return navigation.project(data, { rows = items, identities = identities, identityPending = {}, window = "window", nowUtc = 1 })
end

local function listedRow(snapshot, ui, kind, title)
	for _, navRow in ipairs(navigation.rows(snapshot, ui).rows) do
		if navRow.kind == kind and navRow.title == title then return navRow end
	end
	error("no " .. kind .. " row titled " .. title)
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

-- One section's rows container: the bottom strip's single list, or a left/right rail's per-section list.
local function sectionRows(screen, section)
	if screen.view.k ~= "split" then return childAt(screen.view, "rows") end
	if section == "workspace" then return childAt(childAt(screen.view, "bottom"), "rows") end
	return childAt(childAt(childAt(childAt(screen.view, "top"), "stack"), section), "rows")
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

-- The binding of the first painted action carrying exactly this op and key.
local function findKeyed(screen, renderer, op, key)
	local result
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == op and binding.key == key then result = binding end
	end, true)
	return result
end

-- Keys of the Workspace tab rows for these items, in the order given (the pane title names its unnamed tab).
local function tabKeys(snapshot, logical, items)
	local keys = {}
	for _, item in ipairs(items) do table.insert(keys, listedRow(snapshot, logical.workspace, "tab", item.title).key) end
	return keys
end

-- Keys of the painted Workspace tab activations, in tree order. Host and session rows also open by key, so only keys
-- of the snapshot's tab rows count; every tab row the snapshot lists must still appear exactly where the tree paints it.
local function openOrder(screen, renderer, snapshot, logical)
	local tabs = {}
	for _, navRow in ipairs(navigation.rows(snapshot, logical.workspace).rows) do
		if navRow.kind == "tab" then tabs[navRow.key] = true end
	end
	local order = {}
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == "workspace-open" and tabs[binding.key] and order[#order] ~= binding.key then
			table.insert(order, binding.key)
		end
	end, true)
	return order
end

-- A conversation inside a tab lives in Workspace as its tab row: titled by the pane, opening that tab by key and
-- signature, never as a tracked route or a review activation. Returns the painted screen and its info.
local function assertTabRow(item, options)
	local logical, renderer = view.newState(), view.newRenderer("tab-row")
	local input = presentation({ item })
	input.workspace = workspaceOf({ item })
	view.section(logical, "workspace")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input, nil, options)
	local tab = listedRow(input.workspace, logical.workspace, "tab", item.title)
	local binding = findKeyed(screen, renderer, "workspace-open", tab.key)
	assert(binding and binding.signature == tab.signature, "the tab row opens its tab by key and signature")
	assert(not findAction(screen, renderer, "route-open") and not findAction(screen, renderer, "open"), "a tab row is not a tracked route")
	assert(string.find(textOf(childAt(screen.view, "rows")), item.title, 1, true), "the tab row shows the pane title")
	return screen, info
end

local function rowsByWork(screen, renderer)
	local map = {}
	for _, rowNode in ipairs(ledgerUnits(childAt(screen.view, "rows"))) do
		local action = findAction({ view = rowNode }, renderer, "menu")
		if action then map[view.resolve(renderer, action).workId] = rowNode end
	end
	return map
end

-- Inventory normalization preserves user intent and retires disclosures; every row shows, so a membership change
-- never hides one.
do
	local logical, renderer = view.newState(), view.newRenderer("inventory-not-intent")
	local items = {}
	for serial = 1, 50 do items[serial] = row(serial) end
	local input = presentation(items)
	view.normalize(logical, input)
	view.expand(logical, "work:45")
	local intent = logical.intentRevision
	local screen, info = paint(renderer, logical, input)
	assert(info.shown == 50 and #childAt(screen.view, "rows").c == 50, "every Attention row shows")
	local added = row(999)
	added.priority = 0
	table.insert(items, added)
	items[2].attention = false
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(logical.intentRevision == intent, "unrelated work entering or leaving Attention cannot cancel user intent")
	assert(info.shown == 50 and findAction({ view = childAt(screen.view, "rows").c[1] }, renderer, "open", "work:999"),
		"a new top-priority row leads the list")
	assert(logical.expandedWorkId == "work:45" and string.find(textOf(childAt(screen.view, "rows")), "Source", 1, true))
	table.remove(items, 45)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(logical.expandedWorkId == nil and logical.intentRevision == intent,
		"retiring the expanded target is derived state, not an explicit disclosure selection")
	assert(not findAction(screen, renderer, "details", "work:45"))
	input = presentation({ row(1) })
	view.normalize(logical, input)
	local shrunk
	screen, shrunk = paint(renderer, logical, input, screen)
	assert(shrunk.shown == 1 and logical.intentRevision == intent, "shrinking the inventory does not manufacture a user selection")
	view.section(logical, "working")
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

-- Cancel uses one action slot in place of Open; a full list keeps the native tree and wire limits.
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
			assert(info.shown == 40 and #sectionRows(screen, "attention").c == 40,
				"pending feedback and Cancel must not shrink the forty-row list")
			assert(findAction(screen, renderer, "cancel-navigation", item.workId), "the fortieth row exposes Cancel")
			assert(not findAction(screen, renderer, "open", item.workId) and findAction(screen, renderer, "open", items[1].workId))
		end
	end
end

-- Two physical canvases share selection and disclosure, never tokens/caches.
do
	local logical, a, b = view.newState(), view.newRenderer("A"), view.newRenderer("B")
	local items = {}
	for serial = 1, 45 do
		items[serial] = row(serial)
		items[serial].nativeState, items[serial].attention = "working", false
	end
	local input = presentation(items)
	view.section(logical, "working")
	view.normalize(logical, input)
	view.expand(logical, "work:45")
	local screenA, infoA = paint(a, logical, input, nil)
	local screenB, infoB = paint(b, logical, input, nil)
	assert(infoA.section == "working" and infoB.section == "working")
	assert(infoA.shown == 45 and infoB.shown == 45, "both canvases list every row")
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
	assert(logical.section == "working" and not logical.settings)
end

-- Workspace is a tree of tabs: each tab is one row that opens its pane. Attention and Working use factual fields; a
-- finished conversation and a set-aside conversation with no open pane are in neither queue.
do
	local logical, renderer = view.newState(), view.newRenderer("inventory")
	local a, b, c, d = row(1), row(2), row(3), row(4)
	b.attention, b.nativeState = false, "working"
	c.disposition, c.attention = "finished", false
	d.disposition, d.retained, d.pane, d.navigable, d.orphaned = "reference", true, nil, false, true
	d.attention, d.unavailableReason = false, "No open pane"
	local input = presentation({ a, b, c, d })
	input.workspace = workspaceOf({ a, b, c, d })
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.sectionCount == 1 and info.attentionCount == 1 and info.workingCount == 1)
	assert(findAction(screen, renderer, "open", a.workId))
	for _, item in ipairs({ c, d }) do
		assert(not findAction(screen, renderer, "open", item.workId) and not findAction(screen, renderer, "menu", item.workId),
			"a finished row and a row with no open pane are not in Attention")
	end
	local saved = input.workspace.retained[1]
	assert(findKeyed(screen, renderer, "workspace-open", saved.key) == nil, "a retained record with no queue row has no entry in Attention")
	view.section(logical, "working")
	view.normalize(logical, input)
	local workingScreen = paint(renderer, logical, input, screen)
	assert(findAction(workingScreen, renderer, "route-open", b.workId))
	assert(not findAction(workingScreen, renderer, "open", b.workId), "Working rows navigate without acknowledging review")
	for _, item in ipairs({ c, d }) do
		assert(not findAction(workingScreen, renderer, "route-open", item.workId) and not findAction(workingScreen, renderer, "menu", item.workId),
			"a finished row and a row with no open pane are not in Working")
	end
	assert(findKeyed(workingScreen, renderer, "workspace-open", saved.key) == nil, "a retained record with no queue row has no entry in Working")
	view.section(logical, "workspace")
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, workingScreen)
	assert(info.reachableCount == 1)
	for _, item in ipairs({ a, b, c }) do
		local tab = listedRow(input.workspace, logical.workspace, "tab", item.title)
		local binding = findKeyed(screen, renderer, "workspace-open", tab.key)
		assert(binding and binding.signature == tab.signature, "every conversation's tab opens by key and signature, whatever its tracking state")
	end
	assert(not findAction(screen, renderer, "route-open") and not findAction(screen, renderer, "open"),
		"Workspace rows open panes by key; they never emit a tracked route or the review activation")
	assert(findKeyed(screen, renderer, "workspace-open", saved.key) == nil,
		"a retained record is not a Workspace row; the tree holds hosts, sessions, tabs, and Parked/Unattached panes")
end

-- Explicit priority ranks Attention only; Workspace native order remains independent.
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
	assert(equal(openOrder(screen, renderer, input.workspace, logical), tabKeys(input.workspace, logical, { a, b, c, d })),
		"Workspace keeps native tab order whatever the Attention priority")
	assert(not findAction(screen, renderer, "route-open"), "tab rows open by tab key, not by tracked route")
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
	assert(equal(openOrder(screen, renderer, input.workspace, logical),
		tabKeys(input.workspace, logical, { review, waiting, delivery, startup, priority })),
		"Workspace retains native tab order")
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
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	local rows = childAt(screen.view, "rows")
	local clock = roleText(rows, "attention.age")
	assert(clock ~= nil, "settled completion must display its recorded reply clock")
	assert(clock == "Replied 10m ago", "settled completion uses the recorded reply event")
	assert(roleTitle(rows, "attention.age") == "The agent last replied 10 minutes ago.", "the chip's tooltip states the same fact in full")
	item.nativeState, item.reviewSuperseded, item.attention = "working", true, false
	view.section(logical, "working")
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
	screen, info = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(info.attentionCount == 0 and info.workingCount == 0 and info.sectionCount == 0,
		"settling runtime does not resurrect superseded review: the quiet conversation has no queue row")
	item.condition, item.attention = "waiting", true
	view.section(logical, "attention")
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
	assertTabRow(item, { nowUtc = 1600 })
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
	view.section(logical, "working")
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
		item.stale, item.live, item.condition, item.nativeState = true, false, sample.condition, sample.state
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
	item.stale, item.live = true, false
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

-- A row whose source has not been observed in this run, or whose reader cannot support its clock, is marked recorded,
-- never silent. An unrecognised omp writer whose clock fields are supported keeps the live clock.
do
	local replied = { id = "reply", atUtc = 1200, timeKind = "completed", text = "Reply" }
	local ready = { status = "ready", capturedAtUtc = 1500, clockSupport = "supported", questionSupport = "supported" }
	local samples = {
		{ name = "unobserved", observation = false, coverage = {}, role = "attention.age-recorded" },
		{ name = "unsupported clock", observation = ready,
			coverage = { fields = { clock = "unknown", questions = "supported" } }, role = "attention.age-recorded" },
		{ name = "header-only observation", observation = { status = "ready", capturedAtUtc = 1500,
			clockSupport = "unknown", questionSupport = "unknown" }, coverage = {}, role = "attention.age-recorded" },
		{ name = "newer writer", observation = ready, coverage = { writerSupport = "unknown",
			fields = { clock = "supported", questions = "supported" } }, role = "attention.age" },
		{ name = "observed", observation = ready, coverage = {}, role = "attention.age" },
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

-- Removal and reinsertion never hides a row or expires its arrival cue.
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
	assert(info.shown == 2)
	items[1].nativeState, items[1].attention = "idle", true
	input.revision = 3
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen, { now = 300, arrival = true })
	assert(info.shown == 3)
	for _, item in ipairs(items) do assert(findAction(screen, renderer, "open", item.workId), "every item remains visible") end
	screen = paint(renderer, logical, input, screen, { now = 1068 })
	assert(string.find(childAt(screen.view, "rows").p.role, "arrival", 1, true), "768ms-old arrival remains visible for the original 900ms")
end

-- Every conversation shows, whatever the list size: nothing pages, hides a prefix, or loses its open action.
do
	for _, position in ipairs({ "bottom", "left", "right" }) do
		local logical, renderer = view.newState(), view.newRenderer("every-row-" .. position)
		local items = {}
		for serial = 1, 60 do items[serial] = row(serial) end
		local input = presentation(items)
		view.normalize(logical, input)
		local screen, info = paint(renderer, logical, input, nil, { position = position })
		assert(info.shown == 60 and info.omitted == 0 and #sectionRows(screen, "attention").c == 60, position .. ": all sixty rows show")
		for _, item in ipairs(items) do
			assert(findAction(screen, renderer, "open", item.workId), position .. ": every row keeps its open action")
		end
		table.remove(items, 1)
		view.normalize(logical, input)
		screen, info = paint(renderer, logical, input, screen, { position = position })
		assert(info.shown == 59 and findAction(screen, renderer, "open", "work:2"), position .. ": a departed row never hides a neighbor")
	end
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
	view.toggleGroup(logical, "tab:elsewhere")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(view.resolve(renderer, section).op == "section", "an unchanged control keeps its action across unrelated view changes")
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
	view.section(logical, "working")
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

-- Next and Previous preserve their global purposes even from Working and Settings.
do
	local logical, renderer = view.newState(), view.newRenderer("navigation")
	local input = presentation({ row(1) })
	view.section(logical, "working")
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
	assert(equal(sections, { "attention", "working", "workspace" }), "three modes, in order")
	assert(not findAction(screen, renderer, "sessions"), "there is no session chooser")
	assert(not findAction(screen, renderer, "new"), "the header has no New button")
	local current = { key = "pane:local#9", title = "Quarry notes", context = "Note · Quarry · Workbench" }
	screen = paint(renderer, logical, input, screen, { search = { available = true }, current = current })
	local utility = childAt(childAt(screen.view, "header"), "utility")
	assert(utility.c[1].p.key == "search" and utility.c[2].p.key == "settings", "search then the gear, gear rightmost")
	assert(utility.c[1].p.title == "Search workspace" and utility.c[1].c[1].k == "icon" and utility.c[1].c[1].p.name == "search",
		"Search is a magnifying-glass icon button")
	assert(view.resolve(renderer, findAction(screen, renderer, "search")).op == "search", "Search clicks dispatch the search operation")
	assert(not findAction(screen, renderer, "reveal"), "the current location stays out of Attention even when known")
	view.section(logical, "working")
	screen = paint(renderer, logical, input, screen, { current = current })
	assert(not findAction(screen, renderer, "reveal") and not string.find(textOf(screen.view), "Quarry notes", 1, true),
		"and out of Working")
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
	-- Nothing pages: a long list shows every row and the header carries no pager.
	local many = {}
	for serial = 1, 50 do many[serial] = row(serial) end
	input = presentation(many)
	view.section(logical, "attention")
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	header = childAt(screen.view, "header")
	assert(info.shown == 50 and #childAt(screen.view, "rows").c == 50, "all fifty rows render")
	assert(not childAt(header, "pagination") and #header.c == 4, "the header has no pager")
end

-- Empty conversation queues are silent: no sentence that could be mistaken for an item. Workspace keeps its
-- explanation of a missing inventory, and a truthful status line is never suppressed.
do
	local logical, renderer = view.newState(), view.newRenderer("empty")
	local input = presentation({})
	view.normalize(logical, input)
	local screen
	for _, name in ipairs({ "attention", "working" }) do
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
		{ settings = { position = "right", defaultPosition = default } })
	local age, roles, defaults = nil, {}, 0
	walk(screen.view, function(node)
		local action = node.p and node.p.actions and node.p.actions.click
		local binding = action and view.resolve(renderer, action)
		if binding and binding.op == "age" then age = binding end
		if binding and binding.op == "default" then
			defaults += 1
			roles[binding.position] = node.p.role
		end
	end, true)
	assert(not age, "there is no age control any more")
	assert(not string.find(textOf(screen.view), "age-to-", 1, true), "Settings no longer mentions automatic aging")
	assert(defaults == 3, "placement offers exactly three default choices in Settings")
	for _, position in { "bottom", "right", "left" } do
		assert(roles[position] == (if position == default then "attention.selected" else "attention.control"),
			default .. ": only the current default is selected")
	end
	local label = default:sub(1, 1):upper() .. default:sub(2)
	local visible = textOf(screen.view)
	for _, caption in { "Rail placement", "Default for new tabs: " .. label .. ".",
		"moves every rail there", "Use … in this tab relayouts just that tab" } do
		assert(string.find(visible, caption, 1, true), "the placement control is labelled " .. caption)
	end
end

-- Worst-case bounded hostile metadata preserves real wire/node/action invariants.
do
	local logical, renderer = view.newState(), view.newRenderer("bounds")
	local items = {}
	for serial = 1, 40 do
		local item = row(serial)
		item.title, item.sessionName = string.rep("世界\n", 1000), string.rep("Long session ", 1000)
		item.reason, item.context, item.hostName = string.rep("reason ", 1000), string.rep("context ", 1000), "\255invalid"
		items[serial] = item
	end
	view.normalize(logical, presentation(items))
	local screen, info = paint(renderer, logical, presentation(items))
	assert(info.shown == 40)
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
		recordsComplete = false, historyScope = "unavailable", clockSupport = "unknown", questionSupport = "unknown" }
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
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } },
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
	view.section(logical, "working")
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
	view.section(logical, "working")
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

-- Quiet live work stays in Workspace (its tab row; a parked pane keeps an inspectable leaf) and communicates absence of
-- a current cue, not completion.
do
	local logical, renderer = view.newState(), view.newRenderer("quiet-facts")
	local item = row(1)
	item.attention, item.reason = false, ""
	item.sourceObservation = { status = "ready", capturedAtUtc = 1000 }
	item.source = { status = "ready", complete = true, selection = "disk-replayed", capturedAtUtc = 1000,
		lastFinal = { id = "reply", atUtc = 800, timeKind = "completed", text = "Recorded final reply" },
		questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 } }
	local input = presentation({ item })
	local _, quiet = assertTabRow(item, { nowUtc = 1600 })
	assert(quiet.attentionCount == 0 and quiet.workingCount == 0,
		"quiet work has no queue row; Workspace is where it lives")
	view.section(logical, "workspace")
	input.workspace = workspaceOf({ item }, true)
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input, nil, { nowUtc = 1600 })
	assert(findAction(screen, renderer, "route-open", item.workId) and info.attentionCount == 0)
	view.expand(logical, item.workId)
	screen = paint(renderer, logical, input, screen, { nowUtc = 1600 })
	assert(string.find(textOf(childAt(screen.view, "rows")), "Final completed", 1, true), "recorded response event remains independently inspectable")
end

do
	local logical, renderer = view.newState(), view.newRenderer("unsupported-questions")
	local item = row(1)
	item.sourceObservation = { status = "partial", capturedAtUtc = 1000, clockSupport = "unknown", questionSupport = "unknown" }
	item.source = {
		status = "partial", complete = false, capturedAtUtc = 1000, selection = "disk-replayed",
		coverage = { recordsComplete = true, historyScope = "selected-ancestry", writerSupport = "unknown",
			fields = { clock = "unknown", questions = "unknown" } },
		questionCoverage = { status = "unknown", knownTotal = 2, included = 2, omitted = 0 },
		lastFinal = { id = "observed-final", atUtc = 900, timeKind = "completed", text = "Useful observed excerpt" },
		questions = { { id = "known", status = "answered", text = "Unqualified replacement must not settle prior question" },
			{ id = "unqualified-only", status = "open", text = "Observed attempt with unqualified selection", askedAtUtc = 950 } },
		lastKnown = {
			questions = { { id = "known", status = "open", text = "Previously qualified open attempt", askedAtUtc = 800 } },
			provenance = { questions = { known = { capturedAtUtc = 850, complete = true, selection = "disk-replayed",
				coverage = { recordsComplete = true, fields = { clock = "supported", questions = "supported" } } } } },
		},
	}
	local input = presentation({ item })
	view.expand(logical, item.workId)
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1100 })
	local visible = textOf(childAt(screen.view, "rows"))
	assert(string.find(visible, "Useful observed excerpt", 1, true) and string.find(visible, "question support: unknown", 1, true)
		and string.find(visible, "clock support: unknown", 1, true))
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

-- Set-aside conversations (reference, finished, and a finished record with no open pane) sit in neither queue;
-- Workspace still lists a tab row per open pane whatever its tracking state.
do
	local logical, renderer = view.newState(), view.newRenderer("set-aside")
	local reference, finished, closed = row(1), row(2), row(3)
	for _, item in ipairs({ reference, finished, closed }) do
		item.reviewKind, item.retained, item.attention = "done", true, false
		item.source = { lastFinal = { id = "old", text = "Old review", timeKind = "completed", atUtc = 100 } }
	end
	reference.disposition, finished.disposition, closed.disposition = "reference", "finished", "finished"
	closed.pane, closed.navigable, closed.orphaned, closed.noOpenPane, closed.unavailableReason = nil, false, true, true, "No open pane"
	local input = presentation({ reference, finished, closed })
	input.workspace = workspaceOf({ reference, finished, closed })
	assert(#view.queue(input, "attention") == 0 and #view.queue(input, "working") == 0, "set-aside rows belong to no queue")
	for _, section in ipairs({ "attention", "working" }) do
		view.section(logical, section)
		view.normalize(logical, input)
		renderer = view.newRenderer("set-aside-" .. section)
		local screen, info = paint(renderer, logical, input, nil, { nowUtc = 1767300000 })
		assert(info.shown == 0 and #sectionRows(screen, section).c == 0, section .. " lists no set-aside row")
		assert(info.attentionCount == 0 and info.workingCount == 0)
		for _, item in ipairs({ reference, finished, closed }) do
			assert(not findAction(screen, renderer, "menu", item.workId) and not findAction(screen, renderer, "route-open", item.workId)
				and not findAction(screen, renderer, "open", item.workId), section .. " offers nothing for " .. item.workId)
		end
	end

	view.section(logical, "workspace")
	view.normalize(logical, input)
	renderer = view.newRenderer("set-aside-workspace")
	local screen = paint(renderer, logical, input, nil, { nowUtc = 1767300000 })
	assert(not findAction(screen, renderer, "route-open") and not findAction(screen, renderer, "open"))
	for _, item in ipairs({ reference, finished }) do
		local tab = listedRow(input.workspace, logical.workspace, "tab", item.title)
		local binding = findKeyed(screen, renderer, "workspace-open", tab.key)
		assert(binding and binding.signature == tab.signature, "every open conversation's tab is listed and opens by key")
	end
	local ledgerList = childAt(screen.view, "rows").c
	assert(#ledgerList == 1 and (ledgerList[1].p.role == "workspace.ledger" or ledgerList[1].p.role == "workspace.ledger-current")
		and #childAt(ledgerList[1], "rows").c == 2, "one session block and two tab rows; the closed conversation is no tree row")
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

-- Every row of one section rendered in order as { node, bindings }. There is one list; nothing pages.
local function collectWorkspace(input, ui, options, section)
	section = section or "workspace"
	local state = view.newState()
	view.restore(state, { section = section, collapsed = ui.collapsed })
	local position = options and options.position
	if (position == "left" or position == "right") and not ui.railDefaults then
		-- Rail sessions other than this Mac's start closed; the row-shape assertions want every tree open.
		for _, host in ipairs(input.workspace.hosts) do
			for _, session in ipairs(host.sessions) do
				if state.workspace.collapsed[session.key] == nil then state.workspace.collapsed[session.key] = false end
			end
		end
	end
	view.normalize(state, input)
	local screen, bindings = view.render(view.newRenderer("collect"), state, input, options or {})
	local entries = {}
	local function addUnit(unit) table.insert(entries, { node = unit, bindings = bindings }) end
	for _, rowNode in ipairs(sectionRows(screen, section).c) do
		if section == "workspace" and rowNode.p and (rowNode.p.role == "workspace.ledger" or rowNode.p.role == "workspace.ledger-current") then
			local edge = childAt(rowNode, "edge")
			if edge then addUnit(edge) end
			addUnit(childAt(rowNode, "label"))
			for _, ledgerRow in ipairs(childAt(rowNode, "rows").c or {}) do addUnit(ledgerRow) end
		else
			addUnit(rowNode)
		end
	end
	return entries
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

-- The No tabs line is a disclosure of its own: open by default with each empty session's name; folded, only the
-- centred "No tabs (N)" toggle remains, and its toggle flips exactly that host's fold.
do
	local input, snapshot = censusSnapshot()
	local function emptyLine(ui)
		for _, entry in ipairs(collectWorkspace(input, ui)) do
			if entry.node.p.role == "workspace.empty-line" then return entry end
		end
		return nil
	end
	local open = emptyLine({})
	assert(open and childAt(open.node, "names") and #childAt(open.node, "names").c == 2, "open, the line lists both empty sessions")
	local toggle = bindingsOf(open)[1]
	assert(toggle.op == "workspace-toggle" and toggle.expanded == true and string.find(toggle.key, "^empties:"),
		"the No tabs label is the line's own disclosure")
	assert(textOf(childAt(open.node, "toggle")) == "No tabs (2)", "the toggle counts the empty sessions")
	local folded = emptyLine({ collapsed = { [toggle.key] = true } })
	assert(folded and childAt(folded.node, "names") == nil and #bindingsOf(folded) == 1,
		"folded, only the toggle remains")
	assert(listedRow(snapshot, {}, "session", "Dune").empty, "folding hides names, not the sessions themselves")
end

-- A host's tail (its Minimized group, then No tabs) comes after its last open session box even when a Parked
-- section follows that session directly: the box closes before the tail is emitted.
do
	local input, snapshot = censusSnapshot({ raw = function(raw)
		local kept = {}
		for _, session in ipairs(raw.sessions) do
			if session.id ~= census.session.dune and session.id ~= census.session.fjord then table.insert(kept, session) end
		end
		raw.sessions = kept
		for _, pane in ipairs(raw.panes) do
			if pane.pane == census.tabPanes(census.tab.multiNamed)[2] then pane.parked = true end
		end
	end })
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	local entries = collectWorkspace(input, { collapsed = { [harbor.key] = true } })
	local groupAt, lastEdge, sectionAt
	for index, entry in ipairs(entries) do
		local role = entry.node.p.role
		if role == "workspace.minimized-line" then groupAt = index end
		if role == "workspace.ledger-edge" then lastEdge = index end
		if role == "workspace.ledger-label" and roleText(entry.node, "workspace.title") == "Parked" then sectionAt = index end
	end
	assert(groupAt and lastEdge and sectionAt, "the world has open sessions, a Minimized group, and a Parked section")
	assert(lastEdge < groupAt and groupAt < sectionAt,
		"the Minimized group follows the host's last open session and precedes its Parked section")
end

-- Groups, bare tab counts, disclosure, listed empty sessions, and the native More menu.
do
	local input, snapshot = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	local edgeEntry, harborToggle = entryFor(entries, "workspace-toggle", harbor.key)
	assert(edgeEntry and edgeEntry.node.p.role == "workspace.ledger-edge" and harborToggle.expanded == true
		and edgeEntry.node.p.text == "\u{2212}", "an open session's left edge is its − (minimize) strip")
	local harborEntry, harborOpen = entryFor(entries, "workspace-open", harbor.key)
	assert(harborEntry and harborEntry.node.p.role == "workspace.ledger-label" and harborOpen.signature == harbor.signature,
		"a session's name jumps to the session")
	assert(not string.find(textOf(harborEntry.node), "place", 1, true) and not string.find(textOf(harborEntry.node), "Current", 1, true),
		"a session label has no places wording and no Current text")
	assert(not entryFor(entries, "native-menu", harbor.key),
		"a session label carries no menu: the palette and tab rows own those actions")
	for _, name in ipairs({ "Dune", "Fjord" }) do
		local empty = listedRow(snapshot, {}, "session", name)
		assert(empty.empty and not empty.expandable and empty.count == nil, "an empty session is listed with nothing to expand")
		assert(not entryFor(entries, "workspace-toggle", empty.key), "an empty session's name is not a disclosure")
		local emptyEntry, emptyOpen = entryFor(entries, "workspace-open", empty.key)
		local named = false
		walk(emptyEntry and emptyEntry.node or {}, function(item)
			if item.p and item.p.role == "workspace.empty-name" and item.p.text == name then named = true end
		end)
		assert(emptyEntry and emptyEntry.node.p.role == "workspace.empty-line" and named and emptyOpen.signature == empty.signature,
			"an empty session is its name on the host's one No tabs line, opening a tab there")
	end
	local single = "tab:local#" .. census.tab.single
	local singleEntry, singleOpen = entryFor(entries, "workspace-open", single)
	assert(singleEntry and roleText(singleEntry.node, "workspace.title-tab") == "Buoy audit", "an unnamed tab is titled by its target pane")
	assert(singleOpen.signature == snapshot.byKey[single].signature)
	assert(not entryFor(entries, "workspace-toggle", single), "a tab row is a plain row with no disclosure")
	local named = "tab:local#" .. census.tab.multiNamed
	local namedEntry, namedOpen = entryFor(entries, "workspace-open", named)
	assert(namedEntry and roleText(namedEntry.node, "workspace.title-tab") == "tide charts", "a named tab is titled by its name")
	assert(namedOpen.signature == snapshot.byKey[named].signature)
	assert(entryFor(entries, "native-menu", named) and not entryFor(entries, "workspace-toggle", named))
	assert(roleText(namedEntry.node, "workspace.count") == nil, "a tab row has no count")
	for _, pane in ipairs(census.tabPanes(census.tab.multiNamed)) do
		assert(not entryFor(entries, "workspace-open", "pane:local#" .. pane), "panes inside a tab are not Workspace rows")
	end
	local collapsed = collectWorkspace(input, { collapsed = { [harbor.key] = true } })
	local groupEntry = entryFor(collapsed, "workspace-open", harbor.key)
	assert(groupEntry and groupEntry.node.p.role == "workspace.minimized-line"
		and not entryFor(collapsed, "workspace-toggle", harbor.key),
		"a minimized session leaves the host's list for its Minimized group, with no fold of its own there")
	assert(textOf(childAt(groupEntry.node, "toggle")) == "Minimized (1)", "the group counts its sessions")
	-- Its +, its name and its tab count all go to the session, which restores it: none is a dead click.
	local goes = 0
	for _, binding in ipairs(bindingsOf(groupEntry)) do
		if binding.op == "workspace-open" and binding.key == harbor.key then
			assert(binding.signature == harbor.signature, "each opens the session the user saw")
			goes += 1
		end
	end
	assert(goes == 3, "a minimized box's +, name and tab count each go to its session")
	assert(not entryFor(collapsed, "workspace-open", named), "a minimized session hides its tabs")
	assert(entryFor(collapsed, "workspace-open", "tab:local#" .. census.tab.reference), "other sessions are untouched")
	local groupAt, emptyAt
	for index, entry in ipairs(collapsed) do
		if entry.node.p.role == "workspace.minimized-line" then groupAt = index end
		if entry.node.p.role == "workspace.empty-line" then emptyAt = index end
	end
	assert(groupAt and emptyAt and groupAt < emptyAt, "the Minimized group sits above No tabs")
	for index, entry in ipairs(collapsed) do
		if entry.node.p.role == "workspace.ledger-edge" then
			assert(index < groupAt, "the Minimized group follows every open session box of its host")
		end
	end
	local restored = collectWorkspace(input, { collapsed = { [harbor.key] = false } })
	assert(#restored == #entries and entryFor(restored, "workspace-open", named), "restoring returns the session and its tabs")
end

-- A tab row leads with the native sidebar's tile: Tern's icon for its focused program, and a title glyph moved onto
-- the tile rather than left at the head of the label.
do
	local function tileOf(entry)
		local found = nil
		walk(entry.node, function(item) if item.p and item.p.role == "workspace.tile" then found = item end end, true)
		return found
	end
	local input = censusSnapshot({ raw = function(raw)
		for _, tab in ipairs(raw.tabs) do
			if tab.id == census.tab.multiNamed then tab.name = "\u{F0403} EXP: x" end
		end
	end })
	local entries = collectWorkspace(input, {}, { position = "right" })
	for _, case in ipairs({ { census.tab.single, "app-omp" }, { census.tab.namedNote, "tile-note" },
		{ census.tab.namedBrowser, "globe" }, { census.tab.shell, "tile-shell" } }) do
		local entry = entryFor(entries, "workspace-open", "tab:local#" .. case[1])
		local tile = tileOf(entry)
		local summary = childAt(childAt(childAt(entry.node, "main"), "open"), "summary")
		assert(summary.c[1] == tile and #tile.c == 1 and tile.c[1].k == "icon" and tile.c[1].p.name == case[2],
			"tab " .. case[1] .. " leads with the " .. case[2] .. " tile")
	end
	local glyphEntry = entryFor(entries, "workspace-open", "tab:local#" .. census.tab.multiNamed)
	local plate = nil
	walk(glyphEntry.node, function(item) if item.p and item.p.role == "workspace.tile-plate" then plate = item end end, true)
	assert(roleText(glyphEntry.node, "workspace.title-tab") == "EXP: x", "the label drops the glyph and its space")
	assert(tileOf(glyphEntry) == nil and plate and #plate.c == 1 and plate.c[1].p.role == "workspace.tile-glyph"
		and plate.c[1].p.text == "\u{F0403}", "the glyph takes the program icon's place on a plain plate")
end

-- Tab bindings: a tab opens by exact key and signature, titled by its name or its target pane; the current tab
-- carries the single current marker; conversations inside tabs emit no route of their own.
do
	local input, snapshot = censusSnapshot()
	local entries = collectWorkspace(input, {})
	for _, case in ipairs({
		{ census.tab.single, "Buoy audit" }, { census.tab.mixed, "Slab survey" }, { census.tab.finishedShared, "blast log" },
		{ census.tab.namedNote, "harbor notes" }, { census.tab.namedBrowser, "reading list" }, { census.tab.shell, "scratch" },
	}) do
		local key = "tab:local#" .. case[1]
		local entry, open = entryFor(entries, "workspace-open", key)
		assert(entry and roleText(entry.node, "workspace.title-tab") == case[2], key .. " is titled " .. case[2])
		assert(open.signature == snapshot.byKey[key].signature, "a tab opens by key and exact signature")
	end
	assert(not findEntry(entries, function(binding) return binding.op == "route-open" or binding.op == "open" end),
		"a tab never emits a conversation route or the review activation")
	local current = 0
	for _, entry in ipairs(entries) do
		local main = childAt(entry.node, "main")
		if main and main.p.role == "workspace.main-current" then current += 1 end
	end
	assert(current == 1, "exactly one row carries the current marker")
	local currentTab = entryFor(entries, "workspace-open", "tab:local#" .. census.tab.single)
	local otherTab = entryFor(entries, "workspace-open", "tab:local#" .. census.tab.shell)
	assert(childAt(currentTab.node, "main").p.role == "workspace.main-current", "the focused pane's tab is the current row")
	assert(childAt(otherTab.node, "main").p.role == "workspace.main")
	assert(snapshot.currentPane == census.focusedPane())
end

-- Tracking states never reshape the tree: Reference and Finished conversations are in no queue and still have tab rows.
do
	local input = censusSnapshot()
	local entries = collectWorkspace(input, {})
	for _, entry in ipairs(entries) do
		assert(not string.find(textOf(entry.node), "Set aside", 1, true), "no set-aside rows in the tree")
		assert(roleText(entry.node, "workspace.title-dim") == nil, "tab and session rows are never dimmed")
	end
	for _, tab in ipairs({ census.tab.finishedShared, census.tab.reference, census.tab.finished }) do
		assert(entryFor(entries, "workspace-open", "tab:local#" .. tab), "a tab with tracked work is still one plain tab row")
	end
end

-- Offline last-known records sit in no queue: not the Workspace tree, not Attention, not Working. Both `omp` records
-- stay distinct saved conversations.
do
	local input, snapshot, rows = censusSnapshot()
	local entries = collectWorkspace(input, {})
	local offlineWorks, saved, omp = {}, 0, 0
	for _, item in ipairs(rows) do
		if item.pane > 700 then
			offlineWorks[item.workId] = true
			saved += 1
			if item.title == "omp" then omp += 1 end
		end
	end
	local offlineKeys, distinct = {}, 0
	for _, node in ipairs(snapshot.retained) do
		if offlineWorks[node.workId] and not offlineKeys[node.key] then offlineKeys[node.key], distinct = true, distinct + 1 end
	end
	local function isOffline(binding) return offlineWorks[binding.workId] or offlineKeys[binding.key] end
	assert(not findEntry(entries, isOffline), "the Workspace tree holds no retained record: hosts, sessions, tabs, and panes only")
	for _, section in ipairs({ "attention", "working" }) do
		assert(not findEntry(collectWorkspace(input, {}, nil, section), isOffline), "no offline record is a " .. section .. " row")
	end
	assert(saved == 8 and omp == 2 and distinct == 8, "every offline record keeps its own saved-conversation entry, both omp-titled ones distinct")
end

-- Attention keeps the review activation; Working navigates.
do
	local input, _, rows = censusSnapshot()
	local logical, renderer = view.newState(), view.newRenderer("census-queues")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input)
	local slab = workIdOf(rows, "Slab survey")
	local open = view.resolve(renderer, findAction(screen, renderer, "open", slab))
	assert(open.reviewRevision == 4 and open.identityKey == "conversation:" .. census.agentPanes("Slab survey")[1])
	assert(not findAction(screen, renderer, "route-open"), "Attention rows acknowledge through open only")
	for _, item in ipairs(rows) do
		if item.title == "Vibration limits" then item.nativeState = "working" end
	end
	view.section(logical, "working")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	local route = view.resolve(renderer, findAction(screen, renderer, "route-open", workIdOf(rows, "Vibration limits")))
	assert(route.op == "route-open" and route.reviewRevision == nil and not findAction(screen, renderer, "open"))
end

-- Floating tab panes stay inside their tab; parked and unattached panes keep one leaf row each.
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
	assert(entryFor(entries, "workspace-open", "tab:local#" .. census.tab.namedNote)
		and not entryFor(entries, "workspace-open", "pane:local#" .. floating), "a floating pane belongs to its tab row")
	local parkedEntry, parkedOpen = entryFor(entries, "workspace-open", "pane:local#" .. parked)
	assert(parkedEntry and string.find(textOf(parkedEntry.node), "Parked", 1, true), "parked panes keep a leaf row")
	assert(parkedOpen.placement == "parked" and parkedOpen.signature == snapshot.byKey["pane:local#" .. parked].signature)
	local unknown = entryFor(entries, "workspace-open", "pane:local#881")
	assert(unknown and string.find(textOf(unknown.node), "Pane", 1, true), "an unattached pane of unknown kind keeps a leaf row")
end

-- Offline hosts keep their rows and report no count; their tabs are still listed.
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
	local remoteEntry = entryFor(entries, "workspace-toggle", remote.key)
	assert(remoteEntry and string.find(textOf(remoteEntry.node), "Host reconnecting", 1, true),
		"an offline host's band carries its state")
	assert(remoteEntry.node.p.role == "workspace.host-row", "a host row heads its own block")
	assert(not entryFor(entries, "workspace-open", remote.key), "a band discloses its rows; it is not a destination")
	assert(roleText(remoteEntry.node, "workspace.count") == nil, "an unreachable host never reports a count")
	local farNode
	for _, entry in ipairs(entries) do
		if string.find(textOf(entry.node), "Far shell", 1, true) then farNode = entry end
	end
	assert(farNode and roleText(farNode.node, "workspace.title-tab") == "Far shell", "an offline host's tab is still listed")
end

-- Persisted UI is exactly the section and the disclosure set; hostile input is sanitized.
do
	local input, snapshot = censusSnapshot()
	local logical = view.newState()
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	local intent = logical.intentRevision
	view.section(logical, "workspace")
	view.toggleGroup(logical, harbor.key)
	assert(logical.intentRevision == intent + 2 and logical.workspace.collapsed[harbor.key], "disclosure changes are explicit intent")
	view.normalize(logical, input)
	view.expand(logical, "work:3")
	view.section(logical, "settings")
	local saved = view.ui(logical)
	assert(equal(saved, { section = "workspace", collapsed = { [harbor.key] = true } }),
		"only the section and the disclosure set persist")
	saved.collapsed[harbor.key] = nil
	assert(logical.workspace.collapsed[harbor.key], "the persisted value is a copy")
	local restored = view.newState()
	view.restore(restored, view.ui(logical))
	assert(equal(view.ui(restored), view.ui(logical)) and not restored.settings and restored.expandedWorkId == nil)
	view.toggleGroup(logical, harbor.key)
	view.toggleGroup(logical, harbor.key)
	assert(logical.workspace.collapsed[harbor.key], "a second toggle collapses again")
	view.toggleGroup(restored, harbor.key)
	assert(restored.workspace.collapsed[harbor.key] == nil, "a toggle reopens a collapsed group")
	assert(not pcall(view.toggleGroup, restored, 7), "keys must be non-empty strings")

	local hostile = {
		section = "settings",
		collapsed = { [1] = true, ok = true, no = "yes", off = false, nested = {}, [string.rep("k", 300)] = true },
		expandedWorkId = "work:1", settings = true,
	}
	local clean = view.newState()
	view.restore(clean, hostile)
	assert(equal(view.ui(clean), { section = "attention", collapsed = { ok = true, off = false } }),
		"unknown sections fall back to Attention and only exact boolean string keys survive")
	assert(clean.expandedWorkId == nil and not clean.settings)
	for _, junk in ipairs({ "text", 7, true }) do
		local fresh = view.newState()
		view.restore(fresh, junk)
		assert(equal(view.ui(fresh), { section = "attention", collapsed = {} }))
	end
	local many = {}
	for index = 1, 700 do many["key" .. index] = true end
	local bounded = view.newState()
	view.restore(bounded, { section = "later", collapsed = many })
	local kept = 0
	for _ in pairs(view.ui(bounded).collapsed) do kept += 1 end
	assert(view.ui(bounded).section == "attention" and kept <= 512, "a retired Later section restores to Attention and the state stays bounded")
end

-- The removed All section stays gone.
do
	local logical = view.newState()
	assert(logical.section == "attention" and next(logical.workspace.collapsed) == nil)
	assert(not pcall(view.section, logical, "all"), "the All work section no longer exists")
	for _, name in ipairs({ "workspace", "working", "attention" }) do
		view.section(logical, name)
		assert(logical.section == name and not logical.settings)
	end
	assert(not pcall(view.section, logical, "later"), "the Later section no longer exists")
end

-- A pending route-open shows progress on exactly the leaf being opened.
do
	local first, second = row(1), row(2)
	local logical, renderer = view.newState(), view.newRenderer("leaf-pending")
	local input = presentation({ first, second })
	input.workspace = workspaceOf({ first, second }, true)
	view.section(logical, "workspace")
	view.normalize(logical, input)
	local pending = { workId = first.workId, serial = first.serial, pane = first.pane, identityKey = first.identityKey, phase = "checking" }
	local screen = paint(renderer, logical, input, nil, { navigation = pending })
	local nodes = rowsByWork(screen, renderer)
	assert(roleText(nodes[first.workId], "attention.navigation-pending") ~= nil)
	assert(roleText(nodes[second.workId], "attention.navigation-pending") == nil)
	assert(not findAction(screen, renderer, "route-open", first.workId) and findAction(screen, renderer, "route-open", second.workId))
end

-- Bottom strip: the session is its own column spanning both row lines in every conversation row (Attention,
-- Working, Workspace leaf, saved conversation); a left or right rail has no session text on its single line.
do
	local function build(sessionName)
		local active, finished, saved = row(1), row(2), row(3)
		for _, item in ipairs({ active, finished, saved }) do item.sessionName = sessionName end
		finished.disposition, finished.attention = "finished", false
		saved.pane, saved.navigable, saved.retained, saved.attention, saved.disposition = nil, false, true, false, "reference"
		saved.unavailableReason = "No open pane"
		return active, finished, saved
	end
	local function shape(section, position, sessionName)
		local active, finished, saved = build(sessionName)
		if section == "working" then active.nativeState = "working" end
		local logical, renderer = view.newState(), view.newRenderer("session-column-" .. section .. "-" .. position)
		local input = presentation({ active, finished, saved })
		input.workspace = workspaceOf({ active, finished, saved }, true)
		view.section(logical, section)
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { nowUtc = 1600, position = position })
		return sectionRows(screen, section), renderer, screen, { active, finished, saved }
	end
	local function count(root, role)
		local found = 0
		walk(root, function(item) if item.p and item.p.role == role then found += 1 end end, true)
		return found
	end
	-- Workspace shows the active and the finished leaf (parked panes); the set-aside saved row is in no queue.
	for _, case in ipairs({ { "attention", 1 }, { "working", 1 }, { "workspace", 2 } }) do
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
	-- A left or right rail leads each queue row with its owning session in a fixed-width ALL-CAPS column. The Workspace
	-- tree has no such column: its tree already groups by session.
	for _, position in ipairs({ "left", "right" }) do
		for _, section in ipairs({ "attention", "working" }) do
			local rows = shape(section, position, "harbor")
			assert(count(rows, "attention.rail-session-cell") == 1,
				position .. ": " .. section .. " queue rows lead with the session column")
			assert(roleText(rows, "attention.rail-session") == "HARBOR", position .. ": the rail session is ALL CAPS")
			assert(roleTitle(rows, "attention.rail-session") == "harbor", position .. ": the full session name stays in a tooltip")
			assert(count(rows, "attention.session-cell") == 0, position .. ": a rail has no bottom-strip session column")
			assert(string.find(roleTitle(rows, "attention.open"), "harbor", 1, true), position .. ": the session stays in the row's tooltip")
		end
		local rows = shape("workspace", position, "harbor")
		assert(count(rows, "attention.rail-session-cell") == 0, position .. ": a Workspace leaf has no queue session column")
	end
end

-- Currently working is a live-state view, not a tracking disposition or an identity-enrichment gate.
do
	local items = {}
	for serial = 1, 12 do
		items[serial] = row(serial)
		items[serial].nativeState, items[serial].attention = "working", false
	end
	items[2].disposition = "finished"
	items[3].disposition, items[4].disposition = "reference", "finished"
	items[5].nativeState, items[6].nativeState = "idle", "waiting_input"
	items[6].attention = true
	items[7].stale, items[7].navigable = true, false
	items[8].live, items[9].orphaned = false, true
	items[10].noOpenPane, items[11].offline = true, true
	items[12].identityKey, items[12].navigable, items[12].unavailableReason = nil, false, "identity pending"
	items[12].retryableHeaderRoute = true
	items[1].priority, items[1].queueOrder = 0, 12
	local input = presentation(items)
	local ordered = view.queue(input, "working")
	assert(#ordered == 6 and ordered[1] == items[2] and ordered[2] == items[3]
		and ordered[3] == items[4] and ordered[4] == items[7] and ordered[5] == items[1] and ordered[6] == items[12],
		"working is every live pane in stable queue order, regardless of priority, date, disposition or source proof")
	assert(#view.queue(input, "attention") == 1 and view.queue(input, "attention")[1] == items[6])
	local logical, renderer = view.newState(), view.newRenderer("currently-working")
	view.section(logical, "working")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input, nil, { position = "bottom" })
	assert(info.workingCount == #ordered and info.sectionCount == #ordered)
	local queues = childAt(childAt(screen.view, "header"), "queues")
	assert(childAt(queues, "attention") and childAt(queues, "working") and childAt(queues, "workspace")
		and not childAt(queues, "later"), "the strip names its three tabs")
	assert(textOf(childAt(queues, "working")) == "Currently working\n" .. #ordered
		and childAt(queues, "working").p.role == "attention.queue-selected")
	assert(childAt(childAt(screen.view, "header"), "location").p.hidden, "current location stays Workspace-only")
	for _, item in ipairs(ordered) do
		local open = findAction(screen, renderer, "route-open", item.workId)
		assert((open ~= nil) == (item.navigable or item.retryableHeaderRoute == true),
			"working offers Open exactly when its route is navigable; a stale row waits for the source proof")
		if open then
			assert(view.resolve(renderer, open).reviewRevision == nil and not findAction(screen, renderer, "open", item.workId),
				"working opens route without acknowledging a review")
		end
		assert(findAction(screen, renderer, "details", item.workId) and findAction(screen, renderer, "menu", item.workId))
	end
	view.expand(logical, items[3].workId)
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(childAt(rowsByWork(screen, renderer)[items[3].workId], "disclosure"), "working has recorded-fact disclosure")
	local saved, restored = view.ui(logical), view.newState()
	view.restore(restored, saved)
	assert(restored.section == "working" and restored.expandedWorkId == nil and not restored.settings,
		"only the selected mode survives restoration")
	items[1].nativeState, items[1].attention = "waiting_input", true
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == #ordered - 1 and #view.queue(input, "attention") == 2
		and rowsByWork(screen, renderer)[items[1].workId] == nil, "waiting leaves Working for existing Attention semantics")
	assert(items[1].disposition == "active" and items[2].disposition == "finished", "view changes no tracking dispositions")
	for _, item in ipairs(items) do item.nativeState = "idle" end
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == 0 and #childAt(screen.view, "rows").c == 0 and childAt(screen.view, "empty").p.hidden,
		"empty Working is clean without a placeholder or fabricated row")
end

-- Working lists every row; membership changes never hide or shift one, and the badge counts them all.
do
	local items = {}
	for serial = 1, 60 do
		local item = row(serial)
		item.nativeState, item.attention = "working", false
		table.insert(items, item)
	end
	local input, logical, renderer = presentation(items), view.newState(), view.newRenderer("working-all")
	view.section(logical, "working")
	view.normalize(logical, input)
	local screen, info = paint(renderer, logical, input)
	assert(info.workingCount == 60 and info.shown == 60 and #childAt(screen.view, "rows").c == 60)
	items[41].nativeState, items[41].attention = "waiting_input", true
	view.normalize(logical, input)
	screen, info = paint(renderer, logical, input, screen)
	assert(info.workingCount == 59 and #childAt(screen.view, "rows").c == 59 and not findAction(screen, renderer, "route-open", "work:41"),
		"a departed row leaves; its neighbors stay")
	view.section(logical, "attention")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(#childAt(screen.view, "rows").c == 1)
	view.section(logical, "working")
	view.normalize(logical, input)
	screen = paint(renderer, logical, input, screen)
	assert(#childAt(screen.view, "rows").c == 59 and childAt(screen.view, "rows").c[1].p.key == "r1",
		"switching modes keeps the complete list")
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
	items[2].disposition = "finished"
	items[1].priority, items[1].queueOrder = 0, 12
	local input = presentation(items)
	local working = view.queue(input, "working")
	assert(#working == 12 and working[1] == items[2] and working[11] == items[1] and working[12] == items[12],
		"queue derives the working order with queue order then serial tie-breaks")
	assert(view.queue(input, "working") == working and view.queue(input, "attention") == view.queue(input, "attention"),
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

-- Normalization bounds the live disclosure map with the same cap restore applies, so a long-lived VM cannot
-- grow it without limit and the persisted ui copy mirrors the bounded live map exactly.
do
	local logical = view.newState()
	for index = 1, 600 do view.toggleGroup(logical, "group:" .. index) end
	view.normalize(logical, presentation({ row(1) }))
	local collapsed = logical.workspace.collapsed
	local function size(map)
		local count = 0
		for _ in pairs(map) do count += 1 end
		return count
	end
	local ui = view.ui(logical)
	assert(size(collapsed) == 512, "an over-cap map trims to exactly the 512-key cap")
	assert(size(ui.collapsed) == 512, "the persisted copy stays bounded with the live map")
	for key in pairs(collapsed) do assert(ui.collapsed[key] == true, "the ui copy carries every surviving live key") end
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
	assert(sameSet(restored.workspace.collapsed, collapsed),
		"the bounded live map is exactly what restore keeps, so eviction matches the persisted rule")
end

-- Rail queue rows (left and right rails): [title | priority?] over [model · need · age], and the More button; no
-- state marker, no inline triage buttons, no disclosure chevron.
do
	local function count(root, role)
		local found = 0
		walk(root, function(item) if item.p and item.p.role == role then found += 1 end end, true)
		return found
	end
	local function iconNames(root)
		local names = {}
		walk(root, function(item) if item.k == "icon" then table.insert(names, item.p.name) end end, true)
		return names
	end
	local function openOf(rowNode) return childAt(childAt(rowNode, "main"), "open") end
	-- The title line sits beside the session column in a queue row, so search the Open button for it.
	local function lineOf(rowNode)
		local found = nil
		walk(openOf(rowNode), function(item)
			if found == nil and item.p and item.p.key == "line" then found = item end
		end, true)
		return found
	end
	local function railItem(serial)
		local item = row(serial)
		item.sourceObservation = { status = "ready", capturedAtUtc = 1500 }
		item.source = { status = "ready", complete = true,
			lastFinal = { id = "reply", atUtc = 1200, timeKind = "completed", text = "Reply" } }
		return item
	end
	local function railScreen(name, items, section, options, screen, logical, renderer)
		logical, renderer = logical or view.newState(), renderer or view.newRenderer(name)
		local input = presentation(items)
		if section then view.section(logical, section) end
		view.normalize(logical, input)
		options = options or {}
		options.position, options.nowUtc = options.position or "right", options.nowUtc or 1600
		return paint(renderer, logical, input, screen, options), logical, renderer, input
	end

	local function detailOf(rowNode) return childAt(childAt(childAt(openOf(rowNode), "cells"), "body"), "detail") end
	local function keys(container)
		local list = {}
		for _, child in ipairs(container.c or {}) do table.insert(list, child.p.key) end
		return table.concat(list, ",")
	end

	local item = railItem(1)
	item.priority, item.need = 1, { kind = "review", text = "New update" }
	local screen, logical, renderer, input = railScreen("rail-anatomy", { item })
	local rowNode = childAt(sectionRows(screen, "attention"), "r1")
	assert(rowNode.p.role == "attention.row" and #rowNode.c == 1, "a collapsed rail row is exactly its main line")
	local main = childAt(rowNode, "main")
	assert(main.p.role == "attention.row-main" and #main.c == 2 and main.c[1].p.key == "open" and main.c[2].p.key == "menu",
		"the line is the open button and the More button, nothing else")
	local open, line = openOf(rowNode), lineOf(rowNode)
	assert(open.p.role == "attention.open" and #open.c == 1 and line.p.role == "attention.line", "the open button holds one column and the title line")
	local cells = childAt(open, "cells")
	local session = childAt(cells, "session-cell")
	assert(session.p.role == "attention.rail-session-cell" and session.c[1].p.role == "attention.rail-session"
		and session.c[1].p.text == "WORKSPACE" and session.c[1].p.title == "Workspace",
		"the owning session leads the row in ALL CAPS and keeps its full name in a tooltip")
	assert(line.c[1].p.role == "attention.title" and line.c[1].p.text == "Agent 1" and line.c[1].p.title == "Agent 1")
	assert(#line.c == 2 and line.c[2].p.key == "priority" and line.c[2].p.role == "attention.priority"
		and line.c[2].p.text == "P1" and line.c[2].p.title == "P1 Next", "line one is the title and its priority chip, nothing else")
	local detail = detailOf(rowNode)
	assert(detail.p.role == "attention.detail-line" and keys(detail) == "need",
		"line two is the need alone when no model is known; it carries no age: " .. keys(detail))
	assert(detail.c[1].p.role == "attention.need" and detail.c[1].p.text == "New update" and detail.c[1].p.title == "New update",
		"the need is the model's phrase, verbatim, with its full text in a tooltip")
	assert(string.find(childAt(main, "open").p.title, "The agent last replied 6 minutes ago.", 1, true),
		"the clock's sentence stays in the row tooltip")
	assert(main.c[2].p.role == "attention.more" and main.c[2].c[1].p.name == "more" and main.c[2].c[1].p.role == "attention.more-icon")
	assert(view.resolve(renderer, main.c[2].p.actions.click).op == "menu", "More opens the tracking menu")
	local last = 0
	for _, piece in ipairs({ "Open · Agent 1", "Workspace", "New update", "P1 Next", "Idle", "The agent last replied 6 minutes ago." }) do
		local at = string.find(open.p.title, piece, last + 1, true)
		assert(at, "the tooltip carries " .. piece)
		last = at
	end
	assert(not findAction(screen, renderer, "details"), "no inline inspect button")
	for _, role in ipairs({ "attention.triage", "attention.triage-icon", "attention.summary", "attention.metadata",
		"attention.runtime", "attention.reason", "attention.session", "attention.qualifiers", "attention.session-cell",
		"attention.state", "attention.chips" }) do
		assert(count(rowNode, role) == 0, "a rail row has no " .. role)
	end
	for _, name in ipairs(iconNames(rowNode)) do assert(name ~= "chev" and name ~= "chev-r", "a rail row has no disclosure chevron") end
	local unpriced = railItem(2)
	local second = railScreen("rail-unset", { unpriced })
	local unpricedRow = childAt(sectionRows(second, "attention"), "r2")
	assert(#lineOf(unpricedRow).c == 1, "an unset priority renders no chip")
	assert(keys(detailOf(unpricedRow)) == "", "no need, no model: an empty line two, with no stray separator")

	-- With a known model, line two reads model · need.
	local modeled = railItem(3)
	modeled.need, modeled.sourceObservation.status = { kind = "question", text = "Asks: Ship it?" }, "missing"
	local modeledInput = presentation({ modeled })
	modeledInput.workspace = workspaceOf({ modeled })
	modeledInput.workspace.byPane[modeled.pane].model = "Opus 5.5"
	local modeledLogical = view.newState()
	view.normalize(modeledLogical, modeledInput)
	local modeledRow = childAt(sectionRows(paint(view.newRenderer("rail-model"), modeledLogical, modeledInput, nil,
		{ position = "left", nowUtc = 1320 }), "attention"), "r3")
	local modeledDetail = detailOf(modeledRow)
	assert(keys(modeledDetail) == "model,sep-need,need", "model · need: " .. keys(modeledDetail))
	assert(textOf(modeledDetail) == "Opus 5.5\n·\nAsks: Ship it?", textOf(modeledDetail))
	assert(modeledDetail.c[1].p.role == "attention.model-line", "the model keeps its line role")

	-- A Working row's line two follows what its agent waits on: a model call is quiet until 15m, then Stalled; a tool
	-- is named after a minute and Stalled only past an hour; with nothing known in flight, it never claims a stall.
	for _, case in ipairs({
		{ wait = "model", since = 1100, text = "" },
		{ wait = "model", since = 600, text = "Stalled 16m", tip = "No reply from the model · asked 16 minutes ago" },
		{ wait = "tool", tool = "eval", since = 1570, text = "" },
		{ wait = "tool", tool = "eval", since = 1360, text = "Running eval 4m", tip = "Running eval · started 4 minutes ago" },
		{ wait = "tool", tool = "wait", since = 400, text = "Waiting on jobs 20m" },
		{ wait = "tool", tool = "bash", since = -2000, text = "Stalled · Running bash 1h" },
		{ since = -5600, text = "" },
	}) do
		local busy = railItem(5)
		busy.nativeState, busy.attention, busy.reviewRevision = "working", false, nil
		busy.need = { kind = "working", text = "Working", sinceUtc = case.since, wait = case.wait, tool = case.tool }
		local busyRow = childAt(sectionRows(railScreen("rail-working", { busy }), "working"), "r5")
		local detail = textOf(detailOf(busyRow))
		local line = string.gsub(string.gsub(detail, "\n·\n", " · "), "\n", " ")
		local need = roleText(busyRow, "attention.need") or ""
		assert(need == case.text, (case.wait or "unknown") .. " since " .. case.since .. ": " .. line)
		if case.tip then assert(roleTitle(busyRow, "attention.need") == case.tip, roleTitle(busyRow, "attention.need")) end
	end

	-- The focused pane's conversation is marked current in its queue row too, like its Workspace box.
	local focusedItem, otherItem = railItem(8), railItem(9)
	local focusedScreen = railScreen("rail-current", { focusedItem, otherItem }, nil, { current = { workId = focusedItem.workId } })
	local focusedRows = sectionRows(focusedScreen, "attention")
	assert(childAt(childAt(focusedRows, "r8"), "main").p.role == "attention.row-main-current"
		and childAt(childAt(focusedRows, "r9"), "main").p.role == "attention.row-main", "only the focused conversation is current")

	-- A limit with a known reset rests out of Attention: folded under one line at its bottom (closed until opened),
	-- the row says how long until the provider serves again.
	local asking, limited = railItem(6), railItem(7)
	limited.attention, limited.resting = false, 1600 + 7500
	limited.need = { kind = "resting", text = "Usage limit", untilUtc = limited.resting }
	local restScreen, restLogical, restRenderer, restInput = railScreen("rail-resting", { asking, limited })
	local attentionRows = sectionRows(restScreen, "attention")
	assert(childAt(attentionRows, "r7") == nil and childAt(attentionRows, "r6") ~= nil, "a resting row is not an Attention row")
	local restToggle = childAt(attentionRows, "resting-toggle")
	assert(restToggle and roleText(restToggle, "workspace.sub-label") == "Waiting on reset (1)" and childAt(attentionRows, "resting") == nil,
		"the waiting group starts folded with its count")
	local restBinding = view.resolve(restRenderer, restToggle.p.actions.click)
	view.toggleGroup(restLogical, restBinding.key, restBinding.expanded)
	restScreen = paint(restRenderer, restLogical, restInput, restScreen, { position = "right", nowUtc = 1600 })
	local restingRow = childAt(childAt(sectionRows(restScreen, "attention"), "resting"), "r7")
	assert(restingRow and roleText(restingRow, "attention.need") == "Usage limit · back in 2h",
		tostring(restingRow and roleText(restingRow, "attention.need")))

	view.expand(logical, item.workId)
	screen = paint(renderer, logical, input, screen, { position = "right", nowUtc = 1600 })
	rowNode = childAt(sectionRows(screen, "attention"), "r1")
	assert(#rowNode.c == 3 and rowNode.c[2].p.key == "collapse" and rowNode.c[3].p.key == "disclosure")
	assert(view.resolve(renderer, findAction({ view = rowNode }, renderer, "details", item.workId)).op == "details",
		"an opened rail row can be closed")
	assert(count(rowNode, "attention.triage") == 0 and #main.c == 2, "closing needs no chevron")
	view.expand(logical, item.workId)
	screen = paint(renderer, logical, input, screen, { position = "right", nowUtc = 1600 })
	assert(not findAction(screen, renderer, "details") and #childAt(sectionRows(screen, "attention"), "r1").c == 1)

	-- The runtime state is no longer a line-one marker: line two says what is needed (the model's `need`), and the
	-- full runtime words stay in the row tooltip. A failure with no recorded time shows no age; its sentence moves
	-- to the tooltip.
	for _, sample in ipairs({
		{ name = "native waiting", edit = function(it) it.nativeState = "waiting_input" end, title = "Waiting for input" },
		{ name = "waiting condition", edit = function(it) it.condition = "waiting" end, title = "Waiting for input" },
		{ name = "delivery", edit = function(it) it.condition = "delivery" end, title = "Delivery failed",
			fixed = "When the prompt delivery failed is not recorded." },
		{ name = "startup", edit = function(it) it.condition = "startup" end, title = "Startup failed",
			fixed = "When the agent startup failed is not recorded." },
		{ name = "exited", edit = function(it) it.nativeState = "exited" end, title = "Exited" },
		{ name = "unknown", edit = function(it) it.nativeState = "unknown" end, title = "Runtime unknown" },
		{ name = "offline", edit = function(it) it.stale, it.live = true, false end, title = "Offline · idle" },
		{ name = "awaiting proof", edit = function(it) it.stale = true end, title = "Idle" },
		{ name = "working", edit = function(it) it.nativeState = "working" end, title = "Working" },
		{ name = "idle", edit = function(_) end, title = "Idle" },
	}) do
		local sampleItem = railItem(1)
		sample.edit(sampleItem)
		local sampleScreen = railScreen("rail-state-" .. sample.name, { sampleItem })
		local sampleRow = childAt(sectionRows(sampleScreen, "attention"), "r1")
		assert(count(sampleRow, "attention.state") == 0 and #lineOf(sampleRow).c == 1, sample.name .. ": line one has no state marker")
		assert(string.find(openOf(sampleRow).p.title, sample.title, 1, true), sample.name .. ": the row tooltip carries the state")
		assert(roleText(sampleRow, "attention.runtime") == nil, sample.name .. ": the full runtime phrase is not on the row")
		if sample.fixed then
			assert(roleText(detailOf(sampleRow), "attention.age") == nil, sample.name .. ": no recorded time, no age")
			assert(string.find(openOf(sampleRow).p.title, sample.fixed, 1, true), sample.name .. ": the tooltip says so")
		end
	end

	local pendingItem = railItem(4)
	local pendingScreen, _, pendingRenderer = railScreen("rail-pending", { pendingItem }, nil, { navigation = {
		workId = pendingItem.workId, serial = pendingItem.serial, pane = pendingItem.pane,
		identityKey = pendingItem.identityKey, phase = "checking", token = "t:1" } })
	local pendingRow = childAt(sectionRows(pendingScreen, "attention"), "r4")
	local pendingLine = lineOf(pendingRow)
	assert(#pendingLine.c == 2 and pendingLine.c[2].p.key == "navigation-pending")
	local pendingMain = childAt(pendingRow, "main")
	assert(pendingMain.c[1].p.role == "attention.open-pending" and pendingMain.c[2].p.key == "cancel-navigation"
		and pendingMain.c[3].p.key == "menu" and not findAction(pendingScreen, pendingRenderer, "open"))

	local variety = {}
	for serial = 1, 6 do variety[serial] = railItem(serial) end
	variety[2].title, variety[2].priority, variety[2].nativeState = string.rep("very long title ", 30), 0, "waiting_input"
	variety[3].stale, variety[3].condition = true, "delivery"
	variety[4].nativeState = "working"
	variety[5].nativeState, variety[5].priority = "exited", 3
	variety[6].nativeState, variety[6].source = "unknown", nil
	local varietyScreen = railScreen("rail-shape", variety)
	for _, rowNode in ipairs(sectionRows(varietyScreen, "attention").c) do
		local mainNode = childAt(rowNode, "main")
		local lineNode = lineOf(rowNode)
		assert(#rowNode.c == 1 and #mainNode.c == 2 and #openOf(rowNode).c == 1, "queue rows are one line, whatever they show")
		local lastKey = lineNode.c[#lineNode.c].p.key
		assert(lineNode.c[1].p.role == "attention.title" and (lastKey == "title" or lastKey == "priority"))
		assert(detailOf(rowNode).p.role == "attention.detail-line", "every queue row has its second line")
	end
end

-- Workspace leaves (parked and unattached panes) on a rail: line one is the title and an abnormal-state marker; the
-- second line exists only when a sub-line string does (the model of a conversation; the kind of any other pane).
do
	local function openOf(entry) return childAt(childAt(entry.node, "main"), "open") end
	local notePane = census.tabPanes(census.tab.namedNote)[1]
	local shellPane = census.tabPanes(census.tab.shell)[1]
	local browserPane = census.tabPanes(census.tab.namedBrowser)[1]
	local function leaves(edit)
		return censusSnapshot({ raw = function(raw)
			for _, source in ipairs(raw.panes) do
				local named = source.title == "Buoy audit" or source.title == "Tide ledger" or source.title == "Slab survey"
				if (source.kind == "agent" and named) or source.pane == notePane or source.pane == shellPane
					or source.pane == browserPane then
					source.parked = true
				end
			end
			if edit then edit(raw) end
		end })
	end
	local input, _, rows = leaves()
	local function rowOf(workId)
		for _, item in ipairs(rows) do
			if item.workId == workId then return item end
		end
		error("no row " .. workId)
	end
	local buoy, tide, slab = workIdOf(rows, "Buoy audit"), workIdOf(rows, "Tide ledger"), workIdOf(rows, "Slab survey")
	rowOf(tide).nativeState = "waiting_input"
	rowOf(slab).stale, rowOf(slab).live, rowOf(slab).priority = true, false, 2
	local options = { position = "right", nowUtc = 1700000000 }
	local entries = collectWorkspace(input, {}, options)

	local quiet = entryForWork(entries, "route-open", buoy)
	assert(quiet and #openOf(quiet).c == 1 and #childAt(openOf(quiet), "line").c == 1,
		"an Idle conversation leaf with no model is one title line")
	assert(childAt(childAt(quiet.node, "main"), "menu").p.role == "attention.more")
	assert(roleText(quiet.node, "workspace.model") == nil, "no known model, no model line")
	local waiting = entryForWork(entries, "route-open", tide)
	local waitingChips = childAt(childAt(openOf(waiting), "line"), "chips")
	assert(#waitingChips.c == 1 and waitingChips.c[1].p.role == "attention.state" and waitingChips.c[1].p.text == "Waiting"
		and waitingChips.c[1].p.title == "Waiting for input", "the marker sits at the right edge of the title line")
	local tideOpen = openOf(waiting)
	assert(#tideOpen.c == 2 and tideOpen.c[1].p.key == "line" and tideOpen.c[2].p.key == "model"
		and tideOpen.c[2].p.role == "workspace.model" and tideOpen.c[2].p.title == "GPT-6 Astra", "a known model follows the title line")
	local offline = entryForWork(entries, "route-open", slab)
	local offlineChips = childAt(childAt(openOf(offline), "line"), "chips")
	assert(#offlineChips.c == 1 and offlineChips.c[1].p.text == "Offline", "a leaf has no age or priority chip")
	for _, piece in ipairs({ "P2 Planned", "Offline · idle" }) do
		assert(string.find(openOf(offline).p.title, piece, 1, true), "priority and runtime moved to the tooltip: " .. piece)
	end
	assert(not findEntry(entries, function(binding) return binding.op == "details" end), "leaf rows have no inspect button")
	for _, entry in ipairs(entries) do
		local _, menu = findEntry({ entry }, function(binding) return binding.op == "menu" end)
		if menu then
			walk(entry.node, function(item)
				assert(not (item.p and (item.p.role == "attention.triage" or item.p.role == "attention.triage-icon")), "no triage node")
				assert(not (item.k == "icon" and (item.p.name == "chev" or item.p.name == "chev-r")), "no chevron on a conversation row")
			end)
		end
	end

	for _, case in ipairs({ { notePane, "Note" }, { shellPane, "Terminal" }, { browserPane, "Browser" } }) do
		local entry = entryFor(entries, "workspace-open", "pane:local#" .. case[1])
		local paneOpen = openOf(entry)
		assert(#paneOpen.c == 2 and paneOpen.c[1].p.key == "line" and #paneOpen.c[1].c == 1, case[2] .. ": title line, then sub-line")
		assert(paneOpen.c[2].p.role == "workspace.model" and paneOpen.c[2].p.text == case[2] .. " · Parked"
			and paneOpen.c[2].p.title == paneOpen.c[2].p.text,
			case[2] .. ": the sub-line is the kind then the Parked marker, with the same full text in its tooltip")
	end

	-- With no model anywhere, no leaf names one.
	local bare = leaves(function(raw)
		for _, agent in ipairs(raw.agents) do agent.model = nil end
	end)
	local bareEntries = collectWorkspace(bare, {}, options)
	assert(roleText(entryForWork(bareEntries, "route-open", workIdOf(bare.rows, "Tide ledger")).node, "workspace.model") == nil,
		"an unmodeled world renders no model line")

	-- The bottom strip lists the same leaves, so it takes the same line, in its metadata row.
	local bottom = collectWorkspace(input, {}, { position = "bottom", nowUtc = 1700000000 })
	local function bottomMetadata(workId)
		return childAt(childAt(childAt(openOf(entryForWork(bottom, "route-open", workId)), "cells"), "body"), "metadata")
	end
	local bottomModel = childAt(bottomMetadata(tide), "model")
	assert(bottomModel and bottomModel.p.role == "workspace.model" and bottomModel.p.text == "GPT-6 Astra"
		and bottomModel.p.title == "GPT-6 Astra", "bottom: the model sits in the metadata row with its tooltip")
	assert(childAt(bottomMetadata(buoy), "model") == nil, "bottom: no model, no line")
	assert(roleText(entryFor(bottom, "workspace-open", "pane:local#" .. notePane).node, "workspace.context") == "Note · Parked",
		"bottom: a parked note keeps its kind and marker in the context line")
end

-- Bottom header: three tabs on line one with the labelled one-line toolbar and Currently working.
do
	local logical, renderer = view.newState(), view.newRenderer("header-bottom")
	local input = presentation({ row(1) })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { position = "bottom", settings = { shortcut = "cmd+j" },
		search = { available = true }, previous = { available = true, title = "Editor" } })
	local header = childAt(screen.view, "header")
	assert(header.p.role == "attention.header", "bottom: header role")
	local keys = {}
	for _, child in ipairs(header.c) do table.insert(keys, child.p.key) end
	assert(equal(keys, { "queues", "tools", "location", "utility" }), "bottom: the header's children are stable")
	local queues, tools = childAt(header, "queues"), childAt(header, "tools")
	assert(#queues.c == 3 and queues.c[1].p.key == "attention" and queues.c[3].p.key == "workspace",
		"bottom: the queue tabs follow the stored order and Workspace stays last")
	assert(string.find(textOf(childAt(queues, "working")), "^Currently working"), "bottom: the working tab keeps the full mode name")
	local nextButton, previousButton = childAt(tools, "next"), childAt(tools, "previous")
	assert(#tools.c == 2 and nextButton and previousButton)
	assert(string.find(nextButton.p.title, "⌘J", 1, true), "the shortcut stays in Next's tooltip")
	assert(string.find(previousButton.p.title, "Editor", 1, true))
	assert(textOf(nextButton) == "Next" and textOf(previousButton) == "Prev", "the bottom strip keeps its labelled buttons")
	local utility = childAt(header, "utility")
	assert(utility.c[1].p.key == "search" and utility.c[2].p.key == "settings" and #utility.c == 2)
	assert(childAt(header, "location").p.role == "attention.location-none", "outside Workspace the location node stays keyed, empty and hidden")
	assert(screen.view.k == "col", "bottom stays one column, never a split")
end

-- The Workspace location line names its conversation's model when one is known, and names none when it is not.
do
	local logical, renderer = view.newState(), view.newRenderer("location-model")
	local input = presentation({ row(1) })
	view.normalize(logical, input)
	view.section(logical, "workspace")
	local place = { key = "pane:local#1", title = "TERN: Fix native sidebar journeys", context = "work · studio" }
	local named = paint(renderer, logical, input, nil, { position = "bottom", search = { available = true },
		current = { key = place.key, title = place.title, context = place.context, model = "Claude Opus 4.6" } })
	local location = childAt(childAt(named.view, "header"), "location")
	assert(location.p.role == "attention.location", "the Workspace location is the reveal button")
	assert(textOf(childAt(location, "model")) == "Claude Opus 4.6", "the location line names the conversation's model")
	local bare = paint(renderer, logical, input, named, { position = "bottom", search = { available = true }, current = place })
	local bareLocation = childAt(childAt(bare.view, "header"), "location")
	assert(bareLocation.p.role == "attention.location" and childAt(bareLocation, "model") == nil,
		"a place with no known model names none, and the location line still shows")
end

-- Left and right rails: one native split of two regions. The attention stack (tools line, then Attention /
-- Working sections) sits over Workspace; there is no tab row and no queue tabs.
do
	local items = {}
	for index = 1, 75 do
		items[index] = row(index)
		if index > 50 then items[index].nativeState, items[index].attention = "working", false
		elseif index > 25 then items[index].disposition, items[index].attention = "finished", false end
	end
	local input = presentation(items)
	local function count(root, role)
		local found = 0
		walk(root, function(item) if item.p and item.p.role == role then found += 1 end end, true)
		return found
	end
	for _, position in ipairs({ "left", "right" }) do
		local logical, renderer = view.newState(), view.newRenderer("regions-" .. position)
		view.normalize(logical, input, { position = position })
		local options = { position = position, nowUtc = 1600, settings = { shortcut = "cmd+j" },
			search = { available = true }, previous = { available = true, title = "Editor" } }
		local screen, info, _, bindings = paint(renderer, logical, input, nil, options)
		local root = screen.view
		assert(root.k == "split" and root.p.role == "attention.regions" and root.p.dir == "col" and root.p.grow == 1,
			position .. ": the canvas root is one native column split")
		assert(equal(root.p.sizes, { 1 / 3, 1 - 1 / 3 }), position .. ": regions start with the queues a third")
		local top, bottom = childAt(root, "top"), childAt(root, "bottom")
		assert(top.p.min == 140 and bottom.p.min == 140, position .. ": each region keeps a minimum height")
		assert(not childAt(root, "header") and count(root, "attention.queue") == 0 and count(root, "attention.queue-selected") == 0,
			position .. ": no tab row and no four queue tabs")
		assert(info.shown == 50, position .. ": two full sections show their rows at once; finished rows sit in neither")

		-- Tools line: Next / Previous, then Search and the gear.
		local line = childAt(top, "tools")
		assert(line.p.role == "attention.tools-line", position .. ": the tools line is pinned atop the attention region")
		local buttons, utility = childAt(line, "buttons"), childAt(line, "utility")
		local nextButton, previousButton = childAt(buttons, "next"), childAt(buttons, "previous")
		assert(#buttons.c == 2 and string.find(nextButton.p.title, "⌘J", 1, true) and string.find(previousButton.p.title, "Editor", 1, true))
		assert(#nextButton.c == 1 and nextButton.c[1].p.name == "fast-forward" and textOf(nextButton) == "", position .. ": Next is icon-only")
		assert(#previousButton.c == 1 and previousButton.c[1].p.name == "rewind" and textOf(previousButton) == "", position .. ": Prev is icon-only")
		assert(utility.c[1].p.key == "search" and utility.c[2].p.key == "settings" and #utility.c == 2)

		-- Sections: toggle (chevron, title, count) in one header; sections are open by default.
		local stack = childAt(top, "stack")
		for _, name in ipairs({ "attention", "working" }) do
			local section = childAt(stack, name)
			local head = childAt(section, "head")
			local toggle = childAt(head, "toggle")
			assert(toggle.p.role == "workspace.section" and not childAt(head, "pagination"), name .. ": the toggle heads the section")
			assert(textOf(toggle) == ({ attention = "Attention", working = "Working" })[name] .. "\n25",
				name .. ": the title reads plain, its count beside it")
			local binding = view.resolve(renderer, toggle.p.actions.click)
			assert(binding.op == "workspace-toggle" and binding.key == "queue:" .. name and binding.expanded == true)
			assert(#childAt(section, "rows").c == 25 and not childAt(section, "rows").p.hidden, name .. ": every row, open")
		end

		-- Workspace region: its title in a pinned header over the tree.
		local head = childAt(bottom, "head")
		assert(head.p.role == "attention.region-head")
		assert(roleText(head, "workspace.title") == "Workspace" and not childAt(childAt(head, "line"), "pagination"))
		assert(not childAt(head, "location") and childAt(childAt(head, "line"), "title"),
			position .. ": without a current place the header is the region's name and the reveal control is gone")

		-- Re-rendering without a share change re-sends the same sizes, so a native drag survives; a share change
		-- sends different sizes every time, even for the same share twice.
		view.expand(logical, items[1].workId)
		local change = view.render(renderer, logical, input, options)
		assert(change == nil or change.view == nil, position .. ": an ordinary update never resends the split")
		local sizes = {}
		for _, share in ipairs({ 0.25, 0.25, 0.5, 0.75 }) do
			view.divider(logical, share)
			local resent = view.render(renderer, logical, input, options)
			assert(resent and resent.view and resent.view.k == "split", position .. ": a share change resends the split whole")
			local sent = resent.view.p.sizes
			assert(math.abs(sent[1] - share) < 0.001 and math.abs(sent[1] + sent[2] - 1) < 1e-9,
				position .. ": the split sizes follow the new top share")
			assert(not equal(sent, sizes), position .. ": each share change sends a different sizes array")
			sizes = sent
			local again = view.render(renderer, logical, input, options)
			assert(again == nil or again.view == nil, position .. ": the next ordinary render keeps the set sizes")
		end
		assert(not pcall(view.divider, logical, 0) and not pcall(view.divider, logical, 1), "a share must lie strictly inside (0, 1)")
	end
end

-- A left/right rail's Workspace rows are a native list whose `selected` names the direct child holding the current
-- place by its full rendered id, so a freshly shown rail scrolls to where you are. It is the current session's box;
-- minimized, that box sits in its host's Minimized group and the group is selected; with no current session, nothing.
do
	local prefix = "main.regions.bottom.rows."
	local function rowsOf(input, collapsed)
		local state = view.newState()
		view.restore(state, { section = "workspace", collapsed = collapsed })
		view.normalize(state, input)
		local screen = view.render(view.newRenderer("anchor"), state, input, { position = "left" })
		return childAt(childAt(screen.view, "bottom"), "rows")
	end
	local function hasChild(rows, key)
		for _, child in ipairs(rows.c) do if child.p.key == key then return true end end
		return false
	end
	local input, snapshot = censusSnapshot()
	local harbor = listedRow(snapshot, {}, "session", "Harbor")
	assert(harbor.current, "the census opens in the Harbor session")

	local open = rowsOf(input, { [harbor.key] = false })
	assert(open.k == "list" and open.p.role == "attention.workspace-rows" and open.p.max.lines == 400,
		"the rail's Workspace rows are a capped native list")
	local box
	for _, child in ipairs(open.c) do
		if child.p.role == "workspace.ledger-current" then box = child end
	end
	assert(box and open.p.selected == prefix .. box.p.key and hasChild(open, box.p.key),
		"the list selects the current session's box, a direct child, by its full rendered id")

	local folded = rowsOf(input, { [harbor.key] = true })
	local group
	for _, child in ipairs(folded.c) do
		if child.p.role == "workspace.minimized-line" then
			for _, minimizedBox in ipairs(childAt(child, "boxes").c) do
				if minimizedBox.p.role == "workspace.ledger-current" then group = child end
			end
		end
	end
	assert(group and folded.p.selected == prefix .. group.p.key and hasChild(folded, group.p.key),
		"a minimized current session selects its host's Minimized group")

	local nowhere = rowsOf(select(1, censusSnapshot({ raw = function(raw)
		for _, session in ipairs(raw.sessions) do session.current = false end
	end })), { [harbor.key] = false })
	assert(nowhere.k == "list" and nowhere.p.selected == nil, "with no current session nothing is selected")
end

-- A rail lists every row of each queue section; a finished or reference row and a row with no open pane sit in no
-- queue, and an empty Attention section is just its header.
do
	local items = {}
	for index = 1, 60 do
		items[index] = row(index)
		if index > 50 then
			items[index].pane, items[index].navigable, items[index].orphaned, items[index].retained = nil, false, true, true
			items[index].attention, items[index].unavailableReason = false, "No open pane"
		elseif index > 40 then items[index].disposition, items[index].attention = "finished", false
		elseif index > 30 then items[index].disposition, items[index].attention = "reference", false end
	end
	local input = presentation(items)
	local logical, renderer = view.newState(), view.newRenderer("regions-all-rows")
	view.normalize(logical, input)
	local options = { position = "right", nowUtc = 1600 }
	local screen, info = paint(renderer, logical, input, nil, options)
	assert(#sectionRows(screen, "attention").c == 30 and #sectionRows(screen, "working").c == 0 and info.shown == 30,
		"each queue lists every row; reference, finished and no-pane rows sit in neither")
	assert(info.attentionCount == 30 and info.workingCount == 0 and info.laterCount == nil, "the counts are the two queues")
	for index = 31, 60 do
		assert(not findAction(screen, renderer, "open", items[index].workId) and not findAction(screen, renderer, "route-open", items[index].workId)
			and not findAction(screen, renderer, "menu", items[index].workId),
			"a reference, finished or no-pane row is in neither queue")
	end
	-- An empty queue section holds no lines at all: no floor, no blank placeholder.
	local emptyInput = presentation({})
	local emptyLogical, emptyRenderer = view.newState(), view.newRenderer("attention-floor-empty")
	view.normalize(emptyLogical, emptyInput)
	local empty = paint(emptyRenderer, emptyLogical, emptyInput, nil, { position = "right", nowUtc = 1600 })
	assert(#sectionRows(empty, "attention").c == 0 and #sectionRows(empty, "working").c == 0,
		"Attention and Working hold no lines while they are empty")
	local room = 0
	walk(empty.view, function(item) if item.p and item.p.role == "attention.room" then room += 1 end end, true)
	assert(room == 0, "an empty Attention section is just its header, with no blank line")
end

-- Rail sessions start closed, except this Mac's, which open in full. An explicit open or close sticks, survives
-- restore, and the stored map stays honest.
do
	local input, snapshot = censusSnapshot()
	local function listing(logical, source)
		local renderer = view.newRenderer("rail-sessions")
		source = source or input
		view.normalize(logical, source, { position = "right" })
		local screen, _, _, bindings = paint(renderer, logical, source, nil, { position = "right", nowUtc = 1700000000 })
		local entries = {}
		for _, unit in ipairs(ledgerUnits(sectionRows(screen, "workspace"))) do
			table.insert(entries, { node = unit, bindings = bindings })
		end
		return entries
	end
	-- Every session set to `collapsed`; nil leaves each session at its default.
	local function stateWith(collapsed)
		local logical = view.newState()
		view.restore(logical, { section = "workspace" })
		for _, host in ipairs(snapshot.hosts) do
			for _, session in ipairs(host.sessions) do
				if collapsed ~= nil then view.toggleGroup(logical, session.key, collapsed) end
			end
		end
		return logical
	end
	local allClosed = stateWith(true)
	local closed = listing(allClosed)
	local leaked = {}
	for _, entry in ipairs(closed) do
		local label = textOf(entry.node)
		for _, binding in ipairs(bindingsOf(entry)) do
			if (binding.op == "route-open" or (binding.op == "workspace-open" and string.sub(binding.key or "", 1, 5) == "pane:"))
				and not (string.find(label, "Parked", 1, true) or string.find(label, "Floating", 1, true)) then
				table.insert(leaked, { label = label, op = binding.op })
			end
		end
	end
	local leakNote = if next(leaked) then " (leaked: " .. leaked[1].label .. " via " .. leaked[1].op .. ")" else ""
	assert(not next(leaked), "closed sessions hide every conversation and pane under them; only ungrouped parked/floating rows remain" .. leakNote)

	-- Every census session is on this Mac, so its default is the fully expanded tree. The same tree relabelled as
	-- another host's starts closed, which is the other branch of the default.
	local function relabelled()
		local other = table.clone(snapshot)
		other.hosts = {}
		for index, host in ipairs(snapshot.hosts) do
			other.hosts[index] = table.clone(host)
			other.hosts[index].hostKey = "elsewhere"
		end
		local source = table.clone(input)
		source.workspace = other
		return source
	end
	local defaults = listing(stateWith(nil))
	local allOpen = listing(stateWith(false))
	assert(#defaults == #allOpen and #defaults > #closed, "this Mac's sessions open in full by default")
	assert(#listing(stateWith(nil), relabelled()) == #closed, "another host's sessions start closed")

	local logical = allClosed
	local sessionKey = snapshot.hosts[1].sessions[1].key
	view.toggleGroup(logical, sessionKey, false)
	assert(view.ui(logical).collapsed[sessionKey] == false, "an explicitly opened session is remembered as open")
	local persisted = view.newState()
	view.restore(persisted, view.ui(logical))
	assert(persisted.workspace.collapsed[sessionKey] == false, "the open state survives restore")
	assert(#listing(logical) > #closed, "the opened session lists its children")
	view.toggleGroup(logical, sessionKey, true)
	assert(view.ui(logical).collapsed[sessionKey] == true and #listing(logical) == #closed)
end

-- Bottom placement keeps today's rows: a session column, two lines, and both inline buttons.
do
	local item = row(1)
	item.priority = 1
	local logical, renderer = view.newState(), view.newRenderer("bottom-rows")
	local input = presentation({ item })
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { position = "bottom", nowUtc = 1600 })
	local rowNode = childAt(childAt(screen.view, "rows"), "r1")
	local function count(root, role)
		local found = 0
		walk(root, function(node) if node.p and node.p.role == role then found += 1 end end, true)
		return found
	end
	assert(count(rowNode, "attention.session-cell") == 1 and count(rowNode, "attention.summary") == 1
		and count(rowNode, "attention.metadata") == 1, "bottom rows keep the session column and both lines")
	assert(count(rowNode, "attention.triage") == 1 and count(rowNode, "attention.more") == 1 and count(rowNode, "attention.line") == 0 and count(rowNode, "attention.chips") == 0)
	assert(roleText(rowNode, "attention.runtime") == "Idle" and roleText(rowNode, "attention.priority") == "P1")
	assert(findAction(screen, renderer, "details", item.workId) and findAction(screen, renderer, "menu", item.workId))
end

-- One session of `count` one-pane tabs on this Mac.
local function tabsWorkspace(count)
	local raw = { hosts = { { id = 1, kind = "local", name = "Workbench", state = "connected", current = true, panes = {} } },
		sessions = { { id = 1, host = 1, name = "Session", current = true, locked = false, tabs = count } },
		tabs = {}, panes = {}, agents = {}, canvases = {}, focused = nil }
	for index = 1, count do
		local pane, tab = 1000 + index, 5000 + index
		table.insert(raw.hosts[1].panes, pane)
		table.insert(raw.tabs, { id = tab, session = 1, name = "Tab " .. index, position = index, pane = pane, title = "Shell", panes = 1 })
		table.insert(raw.panes, { pane = pane, tab = tab, title = "Shell " .. pane, kind = "terminal", program = "zsh",
			cwd = "", floating = false, parked = false })
	end
	local snapshot = navigation.project(navigation.inventory(raw, census.options()),
		{ rows = {}, identities = {}, identityPending = {}, window = "window", nowUtc = 1 })
	local input = presentation({})
	input.workspace = snapshot
	return input, snapshot
end

-- The Workspace header names the current tab and its session, never the tree's size, and never says "places".
do
	for _, case in ipairs({ { 1, "· 1 tab" }, { 3, "· 3 tabs" } }) do
		local input = tabsWorkspace(case[1])
		local logical, renderer = view.newState(), view.newRenderer("header-count")
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { position = "right" })
		local head = childAt(childAt(screen.view, "bottom"), "head")
		assert(roleText(head, "workspace.title") == "Workspace" and roleText(head, "workspace.count") == nil
			and roleText(head, "attention.rail-session") == nil,
			"with no current place the header reads Workspace, with no count retelling")
		-- The bottom strip's Workspace mode tab still carries the count, so the tree's size reads there.
		local strip = paint(view.newRenderer("header-count-strip"), logical, input, nil, { position = "bottom" })
		local mode
		walk(strip.view, function(node)
			if node.p and node.p.key == "workspace" and (node.p.role == "attention.queue" or node.p.role == "attention.queue-selected") then mode = node end
		end)
		assert(mode ~= nil and roleText(mode, "attention.queue-count") == case[2], "the strip's Workspace tab reads Workspace " .. case[2])
		assert(not string.find(textOf(screen.view), "%f[%a]places?%f[%A]"), "no places wording anywhere")
	end
	local input = censusSnapshot()
	local logical, renderer = view.newState(), view.newRenderer("header-census")
	view.normalize(logical, input)
	local screen = paint(renderer, logical, input, nil, { position = "left" })
	local head = childAt(childAt(screen.view, "bottom"), "head")
	assert(roleText(head, "workspace.count") == nil, "the header never retells the tab count")
	-- A known place: the head line IS the place line — the current tab · its session as the fold control, with the
	-- focused place in the tooltip — and the fold control is an icon whose tooltip carries its state.
	screen = paint(renderer, logical, input, screen, { position = "left", current = { key = "pane:local#9", title = "Quarry notes",
		context = "Note · Quarry · Workbench", tab = "Note", session = "Quarry" } })
	head = childAt(childAt(screen.view, "bottom"), "head")
	assert(roleText(head, "workspace.title") == "Note" and roleText(head, "attention.rail-session") == "QUARRY",
		"the header names its session in the rail caps column and the current tab")
	local fold = childAt(childAt(head, "line"), "minimize")
	assert(fold.p.role == "attention.region-toggle" and fold.c[1].k == "icon" and fold.c[1].p.name == "minus"
		and fold.p.title == "Minimize the Workspace tree",
		"the fold control is a minus icon carrying its state in the tooltip")
	local place = childAt(childAt(head, "line"), "location")
	assert(place.p.role == "attention.location" and place.p.tag == "button"
		and place.p.title == "Minimize the Workspace tree · Quarry notes · Note · Quarry · Workbench",
		"the place card itself folds the tree, carrying the focused place in its tooltip")
	assert(#head.c == 1 and not findAction(screen, renderer, "reveal"),
		"the place names once: no second line, and the header folds the tree instead of revealing")
	-- Minimized, the region docks to the rail's bottom and the fold offers expansion.
	view.minimizeWorkspace(logical)
	screen = paint(renderer, logical, input, nil, { position = "left", current = { key = "pane:local#9", title = "Quarry notes",
		context = "Note · Quarry · Workbench", tab = "Note", session = "Quarry" } })
	local bottom = childAt(screen.view, "bottom")
	assert(bottom.p.role == "attention.region-docked", "the minimized workspace docks at the rail's bottom")
	fold = childAt(childAt(childAt(bottom, "head"), "line"), "minimize")
	assert(fold.c[1].p.name == "plus" and fold.p.title == "Show the Workspace tree",
		"minimized, the fold is a plus icon offering to expand")
end

-- Sixty tabs show every row on every placement, with no pager anywhere.
do
	local input, snapshot = tabsWorkspace(60)
	for _, position in ipairs({ "bottom", "right" }) do
		local logical, renderer = view.newState(), view.newRenderer("sixty-" .. position)
		view.section(logical, "workspace")
		view.normalize(logical, input)
		local screen, info = paint(renderer, logical, input, nil, { position = position })
		local rows = sectionRows(screen, "workspace")
		assert(info.shown == 61 and info.omitted == 0 and #ledgerUnits(rows) == 61, position .. ": the session label and all sixty tabs show")
		assert(not childAt(rows, "more"), position .. ": under the cap there is no footer")
		for _, navRow in ipairs(navigation.rows(snapshot, logical.workspace).rows) do
			if navRow.kind == "tab" then
				assert(findKeyed(screen, renderer, "workspace-open", navRow.key), position .. ": every tab row opens")
			end
		end
	end
end

local function nodesOf(root)
	local total = 1
	for _, child in ipairs(root.c or {}) do total += nodesOf(child) end
	return total
end

-- Tab rows stop at the node ceiling before the row ceiling: they (about 8 nodes each) run out of nodes well short of
-- 200 rows. One footer says how many rows were left out; never silent. Fewer rows than the ceiling show in full.
do
	for _, position in ipairs({ "bottom", "right" }) do
		local input = tabsWorkspace(299)
		local logical, renderer = view.newState(), view.newRenderer("capped-" .. position)
		view.section(logical, "workspace")
		view.normalize(logical, input)
		local screen, info = paint(renderer, logical, input, nil, { position = position })
		local rows = sectionRows(screen, "workspace")
		assert(info.shown > 100 and info.shown < view.MAX_CANVAS_ROWS, position .. ": the node ceiling stops the list before the row ceiling")
		assert(info.shown + info.omitted == 300 and #ledgerUnits(rows) == info.shown + 1, position .. ": every row is either shown or counted")
		local footer = rows.c[#rows.c]
		assert(footer.p.key == "more" and footer.p.role == "workspace.more"
			and footer.p.text == info.omitted .. " more not shown · Search reaches them", position .. ": the footer counts the rows not shown")
		assert(not findAction({ view = footer }, renderer, "workspace-open"), position .. ": the footer is not a row")
		assert(nodesOf(screen.view) <= view.MAX_CANVAS_NODES, position .. ": the update stays under the node ceiling")

		local few = tabsWorkspace(100)
		local fewLogical, fewRenderer = view.newState(), view.newRenderer("under-" .. position)
		view.section(fewLogical, "workspace")
		view.normalize(fewLogical, few)
		local fewScreen, fewInfo = paint(fewRenderer, fewLogical, few, nil, { position = position })
		assert(fewInfo.shown == 101 and fewInfo.omitted == 0 and not childAt(sectionRows(fewScreen, "workspace"), "more"),
			position .. ": under the ceilings there is no footer")
	end
end

-- One budget covers the whole canvas in canvas order: Attention, then Workspace. The first row that does not
-- fit closes it for every later row, one footer reports the rest, and a conversation-heavy update never exceeds
-- MAX_CANVAS_NODES.
do
	local items = {}
	for index = 1, 240 do
		items[index] = row(index)
	end
	local input = presentation(items)
	local logical, renderer = view.newState(), view.newRenderer("budget")
	view.normalize(logical, input)
	local screen, _, info = view.render(renderer, logical, input, { position = "right", nowUtc = 1600 })
	local attention = #sectionRows(screen, "attention").c
	assert(nodesOf(screen.view) <= view.MAX_CANVAS_NODES, "a conversation-heavy rail update stays under the node ceiling")
	assert(info.omitted > 0 and info.shown == attention and info.shown + info.omitted == 240, "every row is either shown or counted")
	local workspaceRows = sectionRows(screen, "workspace")
	assert(#workspaceRows.c == 1 and workspaceRows.c[1].p.key == "more"
		and workspaceRows.c[1].p.text == info.omitted .. " more not shown · Search reaches them", "the single footer closes the canvas")

	local stripLogical, stripRenderer = view.newState(), view.newRenderer("budget-strip")
	view.section(stripLogical, "attention")
	view.normalize(stripLogical, input)
	local strip, _, stripInfo = view.render(stripRenderer, stripLogical, input, { position = "bottom", nowUtc = 1600 })
	local stripRows = childAt(strip.view, "rows")
	assert(nodesOf(strip.view) <= view.MAX_CANVAS_NODES, "a conversation-heavy strip update stays under the node ceiling")
	assert(stripInfo.omitted > 0 and stripInfo.shown + stripInfo.omitted == 240 and #stripRows.c == stripInfo.shown + 1
		and stripRows.c[#stripRows.c].p.text == stripInfo.omitted .. " more not shown · Search reaches them")

	local heavy = censusSnapshot()
	for _, position in ipairs({ "left", "bottom" }) do
		local censusLogical, censusRenderer = view.newState(), view.newRenderer("budget-census-" .. position)
		view.section(censusLogical, "workspace")
		view.normalize(censusLogical, heavy)
		local censusScreen = view.render(censusRenderer, censusLogical, heavy, { position = position, nowUtc = 1700000000 })
		assert(nodesOf(censusScreen.view) <= view.MAX_CANVAS_NODES, position .. ": the census update stays under the node ceiling")
	end
end

-- A conversation with no open pane never dead-ends: its queue row and its Saved conversations row reveal the saved entry.
do
	local live, orphan, parkedFinished = row(1), row(2), row(3)
	for _, item in ipairs({ orphan, parkedFinished }) do
		item.pane, item.navigable, item.orphaned, item.retained, item.noOpenPane = nil, false, true, true, true
		item.unavailableReason = "No open pane"
	end
	parkedFinished.disposition, parkedFinished.attention = "finished", false
	local input = presentation({ live, orphan, parkedFinished })
	input.workspace = workspaceOf({ live, orphan, parkedFinished })
	local saved = {}
	for _, node in ipairs(input.workspace.retained) do saved[node.workId] = node end
	assert(saved[orphan.workId] and saved[parkedFinished.workId] and not saved[live.workId])
	local function reveals(screen, renderer, key)
		local found = 0
		walk(screen.view, function(node)
			local action = node.p and node.p.actions and node.p.actions.click
			local binding = action and view.resolve(renderer, action)
			if binding and binding.op == "workspace-open" and binding.key == key then found += 1 end
		end, true)
		return found
	end
	for _, position in ipairs({ "bottom", "right" }) do
		local logical, renderer = view.newState(), view.newRenderer("reveal-" .. position)
		view.section(logical, "attention")
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil, { position = position, nowUtc = 1600 })
		local node = saved[orphan.workId]
		assert(reveals(screen, renderer, node.key) == 1, position .. ": the Attention row reveals its saved entry")
		assert(findKeyed(screen, renderer, "workspace-open", node.key).signature == node.signature)
		assert(not findAction(screen, renderer, "route-open", orphan.workId), "a saved entry is never routed as an open pane")
		assert(reveals(screen, renderer, saved[parkedFinished.workId].key) == 0
			and not findAction(screen, renderer, "menu", parkedFinished.workId),
			position .. ": a finished record with no open pane is in no queue, so it has no row to reveal from")
		local workspaceLogical, workspaceRenderer = view.newState(), view.newRenderer("saved-" .. position)
		view.section(workspaceLogical, "workspace")
		view.normalize(workspaceLogical, input)
		local workspaceScreen = paint(workspaceRenderer, workspaceLogical, input, nil, { position = position, nowUtc = 1600 })
		assert(reveals(workspaceScreen, workspaceRenderer, saved[orphan.workId].key) == (if position == "bottom" then 0 else 1)
			and reveals(workspaceScreen, workspaceRenderer, saved[parkedFinished.workId].key) == 0,
			position .. ": only the Attention queue carries a retained record; the Workspace tree carries none")
	end
	-- With no Workspace snapshot there is nothing to reveal, and the row stays quietly unavailable.
	local bare = presentation({ orphan })
	local logical, renderer = view.newState(), view.newRenderer("reveal-none")
	view.normalize(logical, bare)
	local screen = paint(renderer, logical, bare, nil, { position = "bottom", nowUtc = 1600 })
	assert(not findAction(screen, renderer, "workspace-open"))
end

-- Stored queue order drives both placements: the stack lists the two queue sections in the stored order and
-- the strip shows the same order with Workspace fixed last. Each stacked queue head carries its ⋯ menu.
do
	local input = presentation({ row(1) })
	for _, position in ipairs({ "left", "bottom" }) do
		local logical, renderer = view.newState(), view.newRenderer("queue-order-" .. position)
		view.normalize(logical, input)
		local screen = paint(renderer, logical, input, nil,
			{ position = position, queueOrder = { "working", "attention" } })
		local names = {}
		if position == "bottom" then
			local queues = childAt(childAt(screen.view, "header"), "queues")
			for _, child in ipairs(queues.c) do table.insert(names, child.p.key) end
		else
			local stack = childAt(childAt(screen.view, "top"), "stack")
			for _, section in ipairs(stack.c) do table.insert(names, section.p.key) end
		end
		assert(equal(names, { "working", "attention", "workspace" })
			or equal(names, { "working", "attention" }),
			position .. ": the stored queue order drives the placement, Workspace last in the strip")
		assert((findAction(screen, renderer, "queue-menu") ~= nil) == (position == "left"),
			position .. ": the stacked queue heads carry the ⋯ menu; the strip's tabs stay plain")
	end
end

return true
