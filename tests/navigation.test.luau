local navigation = require("../navigation")
local census = require("./census")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function inventory(mutateRaw, mutateOptions)
	local raw, options = census.raw(), census.options()
	if mutateRaw then mutateRaw(raw) end
	if mutateOptions then mutateOptions(options) end
	return navigation.inventory(raw, options)
end

-- Builds a snapshot from the census; every callback edits its fixture copy in place.
local function build(edit)
	edit = edit or {}
	local data = inventory(edit.raw, edit.options)
	local rows, identities = census.rows(), census.identities()
	if edit.rows then rows = edit.rows(rows) or rows end
	if edit.identities then edit.identities(identities) end
	local snapshot = navigation.project(data, { rows = rows, identities = identities,
		identityPending = edit.pending or {}, window = "window", nowUtc = 1 })
	return snapshot, data, rows
end

local function destinations(snapshot)
	local list = {}
	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do
				for _, destination in ipairs(tab.destinations) do table.insert(list, destination) end
			end
		end
		for _, destination in ipairs(host.parked) do table.insert(list, destination) end
		for _, destination in ipairs(host.unattached) do table.insert(list, destination) end
	end
	return list
end

local function tabNode(snapshot, id)
	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do
				if tab.id == id then return tab end
			end
		end
	end
	error("no tab " .. tostring(id))
end

local function sessionNode(snapshot, id)
	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			if session.id == id then return session end
		end
	end
	error("no session " .. tostring(id))
end

local function destination(snapshot, pane)
	local key = navigation.locate(snapshot, pane)
	assert(key ~= nil, "pane " .. tostring(pane) .. " is not a destination")
	return snapshot.byKey[key]
end

local function leafRow(result, pane)
	for _, row in ipairs(result.rows) do
		if row.kind == "leaf" and row.ref.pane == pane then return row end
	end
	return nil
end

local function rowOfKind(result, kind, predicate)
	for _, row in ipairs(result.rows) do
		if row.kind == kind and (predicate == nil or predicate(row)) then return row end
	end
	return nil
end

local function count(map)
	local total = 0
	for _ in pairs(map) do total += 1 end
	return total
end

local function rowFor(rows, title)
	for _, row in ipairs(rows) do
		if row.title == title then return row end
	end
	error("no census row titled " .. title)
end

local function paneOf(title, index)
	return census.agentPanes(title)[index or 1]
end

local function allAsideOpen(snapshot)
	local open = {}
	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do open[tab.key] = true end
		end
	end
	return open
end

local function rejects(raw, message)
	local ok, failure = pcall(navigation.inventory, raw, census.options())
	assert(not ok and string.find(tostring(failure), message, 1, true), "expected failure containing '" .. message .. "', got " .. tostring(failure))
end

test("inventory carries native structure and keeps owned canvases out of destinations", function()
	local data = inventory()
	assert(#data.hostOrder == 2 and data.hostOrder[1] == 1 and data.hostOrder[2] == 2)
	assert(data.sessions[31].tabCount == 4 and data.sessions[31].locked == false)
	local tab = data.tabs[51]
	assert(tab.name == "tide charts" and tab.position == 1 and tab.paneCount == 3 and tab.focusedPane == 101)
	assert(data.tabs[52].name == nil, "an unnamed native tab has no name")
	assert(data.panes[801] == nil and data.canvases[801] ~= nil and data.allPanes[801] ~= nil,
		"an owned rail is a known canvas but never a content pane")
	local ledger = data.panes[paneOf("Tide ledger")]
	assert(ledger.nativeTitle == "Tide ledger" and ledger.program == "omp" and ledger.cwd == "/work/atlas")
	local noteId = census.tabPanes(53)[1]
	assert(data.panes[noteId].nativeTitle == nil and data.panes[noteId].path == "note:ledger")
	assert(data.hosts[2].connected == false and data.hosts[2].key == "host-two.invalid")
end)

test("absent optional native fields read as nil and never fail the inventory", function()
	local snapshot = build({ raw = function(raw)
		for _, session in ipairs(raw.sessions) do session.locked, session.tabs = nil, nil end
		for _, tab in ipairs(raw.tabs) do tab.name, tab.position, tab.color, tab.panes, tab.title = nil, nil, nil, nil, nil end
		for _, pane in ipairs(raw.panes) do
			pane.title, pane.cwd, pane.program, pane.path, pane.url, pane.focused = nil, nil, nil, nil, nil, nil
		end
	end })
	assert(snapshot.counts.destinations == 30 and snapshot.counts.tabs == 22)
	local session = sessionNode(snapshot, census.session.harbor)
	assert(session.tabs[1].id == 51 and session.tabs[2].id == 52 and session.tabs[4].id == 54,
		"without native positions the native tab order stands")
	assert(session.tabs[1].title == "Tab 1" and session.tabs[1].name == nil)
	assert(destination(snapshot, paneOf("Tide ledger")).title == "Agent", "an untitled agent with no program falls back to its kind")
end)

test("existing inventory failures keep their messages", function()
	rejects((function() local raw = census.raw(); raw.hosts = nil; return raw end)(), "Hosts unavailable")
	rejects((function() local raw = census.raw(); raw.tabs = { { id = 1 } }; return raw end)(), "Unsupported tab inventory")
	rejects((function() local raw = census.raw(); raw.hosts[2].panes = { 101 }; return raw end)(), "Ambiguous host membership")
	rejects((function()
		local raw = census.raw()
		table.insert(raw.panes, { pane = 999, tab = 52, title = "Stray" })
		return raw
	end)(), "Pane host membership is pending")
	rejects((function()
		local raw = census.raw()
		raw.agents[1].state = "mystery"
		return raw
	end)(), "Native agent state unavailable")
	rejects((function()
		local raw = census.raw()
		raw.canvases[1].about = nil
		return raw
	end)(), "Unsupported canvas inventory")
end)

test("every census pane appears exactly once in the hierarchy, search, and fully expanded rows", function()
	local snapshot = build()
	local expected = census.contentPanes()
	assert(#expected == 30)
	local seen = {}
	for _, node in ipairs(destinations(snapshot)) do seen[node.pane] = (seen[node.pane] or 0) + 1 end
	assert(count(seen) == 30 and snapshot.counts.destinations == 30)
	for _, pane in ipairs(expected) do assert(seen[pane] == 1, "pane " .. pane .. " must appear exactly once") end
	local searched = {}
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		if item.kind == "pane" then searched[item.ref.pane] = (searched[item.ref.pane] or 0) + 1 end
	end
	local rendered = {}
	local result = navigation.rows(snapshot, { setAsideOpen = allAsideOpen(snapshot) })
	for _, row in ipairs(result.rows) do
		if row.kind == "leaf" then rendered[row.ref.pane] = (rendered[row.ref.pane] or 0) + 1 end
	end
	for _, pane in ipairs(expected) do
		assert(searched[pane] == 1, "search must list pane " .. pane .. " once")
		assert(rendered[pane] == 1, "expanded rows must list pane " .. pane .. " once")
	end
end)

test("empty sessions stay selectable everywhere", function()
	local snapshot = build()
	for _, id in ipairs({ census.session.dune, census.session.fjord }) do
		local session = sessionNode(snapshot, id)
		assert(session.empty and #session.tabs == 0)
		assert(navigation.resolve(snapshot, session.key) == session)
		local row = rowOfKind(navigation.rows(snapshot, {}), "session", function(row) return row.ref.session == id end)
		assert(row and row.empty == true and row.expandable == false and row.count == 0)
		assert(navigation.signatureMatches(snapshot, session.key, row.signature))
	end
	local found = 0
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		if item.kind == "session" and (item.ref.session == census.session.dune or item.ref.session == census.session.fjord) then
			found += 1
		end
	end
	assert(found == 2, "empty sessions are search results")
	assert(snapshot.counts.sessions == 11)
end)

test("flattening applies only to unnamed single non-deferred destinations", function()
	local snapshot = build()
	assert(tabNode(snapshot, census.tab.single).flattened, "an unnamed single-child tab flattens")
	assert(not tabNode(snapshot, census.tab.namedNote).flattened, "a named one-child tab stays a parent")
	assert(not tabNode(snapshot, census.tab.namedBrowser).flattened)
	assert(not tabNode(snapshot, census.tab.multiNamed).flattened)
	assert(not tabNode(snapshot, census.tab.mixed).flattened, "an agent plus a browser never flattens")
	assert(not tabNode(snapshot, census.tab.pair).flattened, "an unnamed multi-child tab never flattens")
	local tab = tabNode(snapshot, census.tab.single)
	local result = navigation.rows(snapshot, {})
	assert(rowOfKind(result, "tab", function(row) return row.ref.key == tab.key end) == nil)
	local leaf = leafRow(result, tab.destinations[1].pane)
	local session = rowOfKind(result, "session", function(row) return row.ref.session == tab.sessionId end)
	assert(leaf and leaf.depth == session.depth + 1, "the flattened leaf takes the tab's place")

	local deferred = build({ rows = function(rows) rowFor(rows, "Buoy audit").disposition = "later" end })
	local parent = tabNode(deferred, census.tab.single)
	assert(not parent.flattened, "a set-aside lone leaf keeps its tab visible")
	local rows = navigation.rows(deferred, {})
	assert(rowOfKind(rows, "tab", function(row) return row.ref.key == parent.key end), "the tab row remains")
	assert(rowOfKind(rows, "aside", function(row) return row.ref.key == parent.key end).count == 1)
	assert(leafRow(rows, parent.destinations[1].pane) == nil, "the deferred leaf is collapsed under Set aside")
end)

test("one conversation on two routes never flattens a tab, and its deferral counts once", function()
	local shared = paneOf("Core samples")
	local second = paneOf("Sketch pad", 2)
	local function edit(disposition)
		return {
			rows = function(list)
				local kept = {}
				for _, row in ipairs(list) do
					if row.pane ~= second then table.insert(kept, row) end
					if row.pane == shared then row.disposition = disposition end
				end
				return kept
			end,
			identities = function(identities) identities[second] = identities[shared] end,
		}
	end
	local active = build(edit("active"))
	local first = destination(active, shared)
	assert(first.conversation.routeCount == 2 and first.conversation.preferred)
	local extra = destination(active, second)
	assert(extra.conversation.workId == first.conversation.workId and not extra.conversation.preferred
		and extra.conversation.proof == "proven")
	assert(not tabNode(active, census.tab.pair).flattened)
	assert(active.counts.conversations == 21, "distinct conversations, not routes")

	local later = build(edit("later"))
	assert(later.counts.setAside == 2, "the census Later plus this one; two routes count once")
	local tab = tabNode(later, census.tab.pair)
	local collapsed = navigation.rows(later, {})
	local aside = rowOfKind(collapsed, "aside", function(row) return row.ref.key == tab.key end)
	assert(aside and aside.count == 1 and aside.title == "Set aside 1", "both routes collapse under one count")
	assert(leafRow(collapsed, shared) == nil and leafRow(collapsed, second) == nil)
	local opened = navigation.rows(later, { setAsideOpen = { [tab.key] = true } })
	local primary, secondary = leafRow(opened, shared), leafRow(opened, second)
	assert(primary and secondary and primary.key == "r" .. first.conversation.serial
		and secondary.key == "r" .. first.conversation.serial .. "@" .. second)
	assert(primary.depth == rowOfKind(opened, "aside", function(row) return row.ref.key == tab.key end).depth + 1)
end)

test("set aside collapses only deferred conversations inside their group", function()
	local snapshot = build()
	assert(snapshot.counts.setAside == 1)
	local tab = tabNode(snapshot, census.tab.laterShared)
	local later, active = paneOf("Vibration limits"), paneOf("Charge sizing")
	local closed = navigation.rows(snapshot, {})
	local tabRow = rowOfKind(closed, "tab", function(row) return row.ref.key == tab.key end)
	assert(tabRow and tabRow.setAsideCount == 1 and tabRow.count == 3, "the tab keeps all three places in its count")
	assert(leafRow(closed, active) and leafRow(closed, paneOf("Dust study")), "siblings stay visible")
	assert(leafRow(closed, later) == nil)
	local aside = rowOfKind(closed, "aside", function(row) return row.ref.key == tab.key end)
	assert(aside and aside.title == "Set aside 1" and aside.expanded == false)
	assert(aside.depth == leafRow(closed, active).depth)
	local opened = navigation.rows(snapshot, { setAsideOpen = { [tab.key] = true } })
	local revealed = leafRow(opened, later)
	assert(revealed and revealed.depth == aside.depth + 1 and revealed.leaf.conversation.setAside)
	assert(rowOfKind(opened, "aside", function(row) return row.ref.key == tab.key end).expanded == true)

	local mixed = build({ rows = function(rows) rowFor(rows, "Slab survey").disposition = "later" end })
	local mixedTab = tabNode(mixed, census.tab.mixed)
	local browser = census.tabPanes(census.tab.mixed)[2]
	local rows = navigation.rows(mixed, {})
	assert(leafRow(rows, browser), "a non-conversation sibling never collapses with a deferred conversation")
	assert(leafRow(rows, census.tabPanes(census.tab.mixed)[1]) == nil)
	assert(rowOfKind(rows, "aside", function(row) return row.ref.key == mixedTab.key end).count == 1)
end)

test("Reference and Finished conversations stay visible with their marker", function()
	local snapshot = build()
	local result = navigation.rows(snapshot, {})
	for title, disposition in pairs({ ["Bale counting"] = "reference", ["Kettle seam"] = "finished" }) do
		local pane = paneOf(title)
		local row = leafRow(result, pane)
		assert(row and row.leaf.conversation.disposition == disposition, title .. " stays a visible leaf")
		assert(not row.leaf.conversation.setAside)
		assert(rowOfKind(result, "aside", function(candidate) return candidate.ref.tab == destination(snapshot, pane).tabId end) == nil,
			title .. " is never hidden under Set aside")
	end
end)

test("offline and retained records stay separate from open panes with typed counts", function()
	local snapshot = build({ rows = function(rows)
		table.insert(rows, { workId = "work:101", serial = 101, pane = nil, host = 1, hostKey = "local", title = "Closed thread",
			sessionName = "Harbor", hostName = "Workbench", disposition = "later", retained = true,
			identityKey = "conversation:gone", noOpenPane = true, orphaned = true, unavailableReason = "No open pane",
			nativeState = "unknown", attention = false })
		table.insert(rows, { workId = "work:102", serial = 102, pane = paneOf("Tide ledger"), host = 1, hostKey = "local",
			title = "Contested", sessionName = "Harbor", hostName = "Workbench", disposition = "active", retained = false,
			identityKey = "conversation:other", nativeState = "idle", attention = false })
	end })
	assert(snapshot.counts.conversations == 22 and snapshot.counts.retained == 10 and snapshot.counts.destinations == 30)
	local reasons = { offline = 0 }
	for _, node in ipairs(snapshot.retained) do
		reasons[node.reason] = (reasons[node.reason] or 0) + 1
	end
	assert(reasons.offline == 8 and reasons["no-open-pane"] == 1 and reasons.unverified == 1)
	local byWork = {}
	for _, node in ipairs(snapshot.retained) do byWork[node.workId] = node end
	assert(byWork["work:101"].retainedRecord and byWork["work:101"].reason == "no-open-pane")
	assert(byWork["work:102"].reason == "unverified", "a contested pane stays with the first claimant")
	assert(not byWork["work:23"].retainedRecord and byWork["work:23"].reason == "offline")
	assert(byWork["work:23"].key ~= byWork["work:24"].key and byWork["work:23"].title == "omp" and byWork["work:24"].title == "omp",
		"two records with the same title remain two records")
	for _, node in ipairs(destinations(snapshot)) do
		assert(node.conversation == nil or node.conversation.workId ~= "work:23", "an offline record is never an open pane")
	end
	local result = navigation.rows(snapshot, {})
	local section = rowOfKind(result, "section", function(row) return row.title == "Saved conversations" end)
	assert(section and section.count == 10 and section.depth == 0)
	local after = 0
	local last = result.rows[#result.rows]
	assert(last.kind == "retained" and last.depth == 1)
	for index, row in ipairs(result.rows) do
		if row.kind == "retained" then after += 1; assert(result.rows[index - 1].kind == "retained" or result.rows[index - 1] == section) end
	end
	assert(after == 10)
	assert(rowOfKind(result, "host") == nil, "an offline host with no live content forces no host row")
end)

test("search labels disambiguate equal text and keys never collide on separators", function()
	local snapshot = build({ raw = function(raw)
		for _, tab in ipairs(raw.tabs) do
			if tab.id == 66 then tab.name = "tide charts" end
		end
		for _, session in ipairs(raw.sessions) do
			if session.id == 36 then session.name = "Harbor" end
		end
		-- Separator forgery: "Ledger · notes" in tab "Desk" vs "Ledger" in tab "notes · Desk" yield the same joined text.
		for _, tab in ipairs(raw.tabs) do
			if tab.id == 52 then tab.name = "Desk" elseif tab.id == 54 then tab.name = "notes · Desk" end
		end
		for _, pane in ipairs(raw.panes) do
			if pane.title == "Buoy audit" then pane.title = "Ledger · notes" end
			if pane.title == "Pier schedule" then pane.title = "Ledger" end
		end
	end })
	local items = navigation.searchItems(snapshot)
	local labels, ids = {}, {}
	for _, item in ipairs(items) do
		assert(labels[item.label] == nil, "labels must be unique, repeated: " .. item.label)
		assert(ids[item.id] == nil, "ids must be unique")
		assert(#item.detail > 0 and #item.detail <= 160 and #item.label > 0)
		labels[item.label], ids[item.id] = true, true
	end
	local sketchA, sketchB = paneOf("Sketch pad", 1), paneOf("Sketch pad", 2)
	local function labelOf(pane)
		for _, item in ipairs(items) do
			if item.kind == "pane" and item.ref.pane == pane then return item.label end
		end
		error("no search item")
	end
	assert(string.sub(labelOf(sketchA), -#(" #" .. sketchA)) == " #" .. sketchA)
	assert(string.sub(labelOf(sketchB), -#(" #" .. sketchB)) == " #" .. sketchB)
	local idA, idB = census.tabPanes(52)[1], census.tabPanes(54)[1]
	local forgedA, forgedB = labelOf(idA), labelOf(idB)
	assert(string.sub(forgedA, 1, #forgedA - #(" #" .. idA)) == string.sub(forgedB, 1, #forgedB - #(" #" .. idB)),
		"the forged texts coincide before disambiguation")
	assert(forgedA ~= forgedB)
	local nodes = snapshot.counts.hosts + snapshot.counts.sessions + snapshot.counts.tabs + snapshot.counts.destinations
		+ snapshot.counts.retained
	assert(count(snapshot.byKey) == nodes, "no two nodes share a key")
end)

test("search items carry host qualifiers and exact refs for every inventory kind", function()
	local snapshot = build()
	local items = navigation.searchItems(snapshot)
	local kinds = { pane = 0, tab = 0, session = 0, retained = 0 }
	for _, item in ipairs(items) do
		kinds[item.kind] += 1
		assert(navigation.signatureMatches(snapshot, item.id, item.signature))
		assert(item.ref.key == item.id)
	end
	assert(kinds.pane == 30 and kinds.session == 11 and kinds.tab == 9 and kinds.retained == 8,
		"every destination, session, named tab, and retained record is searchable")
	local tide
	for _, item in ipairs(items) do
		if item.kind == "pane" and item.ref.pane == paneOf("Tide ledger") then tide = item end
	end
	assert(tide and string.find(tide.label, "Tide ledger · tide charts · Harbor · Workbench", 1, true) == 1,
		"labels carry tab, session, and host once several hosts exist")
	for _, item in ipairs(items) do
		if item.kind == "retained" then assert(string.find(item.label, "Remote Lab", 1, true)) end
	end
end)

test("search and flattening are independent of collapse state", function()
	local snapshot = build()
	local before = {}
	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do before[tab.key] = tab.flattened end
		end
	end
	local collapsed = {}
	for key, node in pairs(snapshot.byKey) do
		if node.kind == "host" or node.kind == "session" or node.kind == "tab" then collapsed[key] = true end
	end
	local hidden = navigation.rows(snapshot, { collapsed = collapsed })
	local stillShown = {}
	for _, row in ipairs(hidden.rows) do
		if row.kind == "tab" or row.kind == "leaf" then table.insert(stillShown, row.key) end
	end
	assert(#stillShown == 0, "collapsed sessions hide their tabs and leaves")
	assert(rowOfKind(hidden, "session", function(row) return row.ref.session == census.session.harbor end).expanded == false)
	assert(hidden.total < navigation.rows(snapshot, {}).total)
	local searched = 0
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		if item.kind == "pane" then searched += 1 end
	end
	assert(searched == 30, "collapsed groups never remove search results")
	for key, flattened in pairs(before) do assert(snapshot.byKey[key].flattened == flattened, "rows never change flattening") end
end)

test("signatures follow identity, placement, and disposition but not titles or focus", function()
	local base = build()
	local pane = paneOf("Tide ledger")
	local key = destination(base, pane).key
	local signature = destination(base, pane).signature
	assert(navigation.signatureMatches(base, key, signature))
	local renamed = build({ raw = function(raw)
		for _, source in ipairs(raw.panes) do
			if source.pane == pane then source.title = "Renamed entirely"; source.focused = true end
		end
	end })
	assert(navigation.signatureMatches(renamed, key, signature), "renaming and focus never invalidate a target")
	assert(destination(renamed, pane).title == "Renamed entirely")
	local floating = build({ raw = function(raw)
		for _, source in ipairs(raw.panes) do
			if source.pane == pane then source.floating = true end
		end
	end })
	assert(not navigation.signatureMatches(floating, key, signature), "placement changes the target")
	assert(destination(floating, pane).placement == "floating" and floating.signature ~= base.signature)
	local moved = build({ identities = function(identities) identities[pane] = "conversation:replaced" end })
	assert(not navigation.signatureMatches(moved, key, signature), "identity proof changes the target")
	local deferred = build({ rows = function(rows) rowFor(rows, "Tide ledger").disposition = "later" end })
	assert(not navigation.signatureMatches(deferred, key, signature), "disposition changes the target")
	local revised = build({ rows = function(rows) rowFor(rows, "Tide ledger").reviewRevision = 9 end })
	assert(not navigation.signatureMatches(revised, key, signature), "a new review revision changes the target")
	local retargeted = build({ rows = function(rows) rowFor(rows, "Tide ledger").workId = "work:900" end })
	assert(not navigation.signatureMatches(retargeted, key, signature), "a different record is a different target")
	assert(not navigation.signatureMatches(base, "pane:local#99999", signature))
	assert(not navigation.signatureMatches(base, key, nil))
end)

test("projection and rows are deterministic and independent of input order", function()
	local first, second = build(), build()
	assert(first.signature == second.signature)
	local a, b = navigation.rows(first, {}), navigation.rows(second, {})
	assert(a.total == b.total)
	for index, row in ipairs(a.rows) do
		assert(row.key == b.rows[index].key and row.signature == b.rows[index].signature)
	end
	local reversed = build({ rows = function(rows)
		local flipped = {}
		for index = #rows, 1, -1 do table.insert(flipped, rows[index]) end
		return flipped
	end })
	assert(reversed.signature == first.signature)
	for index, node in ipairs(reversed.retained) do assert(node.key == first.retained[index].key) end
end)

test("owned canvases are excluded while other canvases and unplaced panes stay visible", function()
	local snapshot = build({
		raw = function(raw)
			table.insert(raw.panes, { pane = 850, tab = 52, title = "Carly notes", kind = "plugin", block = "carly.board", cwd = "" })
			table.insert(raw.canvases, { pane = 850, owner = "carly", about = "board", title = "Carly notes" })
			table.insert(raw.panes, { pane = 851, title = "Set down", kind = "browser", url = "https://parked.example.invalid/", parked = true })
			table.insert(raw.panes, { pane = 852, title = "Loose", kind = "terminal", program = "zsh", cwd = "" })
			table.insert(raw.panes, { pane = 853, title = "Closed tab leftover", kind = "terminal", tab = 99, cwd = "" })
			for _, host in ipairs(raw.hosts) do
				if host.id == 1 then
					for _, pane in ipairs({ 850, 851, 852, 853 }) do table.insert(host.panes, pane) end
				end
			end
		end,
		options = function(options) options.closedTabs[99] = true end,
	})
	assert(navigation.locate(snapshot, census.rail.multiNamed) == nil and navigation.locate(snapshot, census.rail.mixed) == nil)
	assert(destination(snapshot, 850).title == "Carly notes" and destination(snapshot, 850).tabId == 52)
	assert(not tabNode(snapshot, 52).flattened, "an extra canvas makes the tab a parent")
	assert(destination(snapshot, 851).placement == "parked" and destination(snapshot, 851).tabId == nil)
	assert(destination(snapshot, 852).placement == "unattached" and destination(snapshot, 853).placement == "unattached")
	local local_ = snapshot.hosts[1]
	assert(#local_.parked == 1 and #local_.unattached == 2)
	assert(snapshot.counts.destinations == 34)
	local result = navigation.rows(snapshot, {})
	local parked = rowOfKind(result, "section", function(row) return row.title == "Parked" end)
	local unattached = rowOfKind(result, "section", function(row) return row.title == "Unattached" end)
	assert(parked and parked.count == 1 and unattached and unattached.count == 2)
	assert(leafRow(result, 851).leaf.placement == "parked" and leafRow(result, 853).leaf.placement == "unattached")
	assert(leafRow(result, 851).depth == parked.depth + 1)
	assert(navigation.ancestors(snapshot, destination(snapshot, 851).key)[2] == parked.key)
	local hidden = navigation.rows(snapshot, { collapsed = { [parked.key] = true } })
	assert(leafRow(hidden, 851) == nil and leafRow(hidden, 852) ~= nil)
end)

test("titles fall back by native kind and are sanitized and bounded", function()
	local long = string.rep("x", 300)
	local accented = string.rep("é", 100)
	local snapshot = build({ raw = function(raw)
		for _, tab in ipairs(raw.tabs) do
			if tab.id == 58 then tab.pane, tab.title = 802, "Sketch pad" end
		end
		for _, pane in ipairs(raw.panes) do
			if pane.pane == census.tabPanes(63)[1] then pane.url = "https://user:secret@docs.example.invalid/guide/start?token=abc#top" end
			if pane.title == "Tide ledger" then pane.title = "Line\none\tTwo" end
			if pane.title == "Oil grades" then pane.title = long end
			if pane.title == "Wick braid" then pane.title = accented end
		end
	end })
	assert(destination(snapshot, census.tabPanes(63)[1]).title == "docs.example.invalid/guide/start")
	assert(destination(snapshot, census.tabPanes(63)[1]).titleSource == "derived")
	assert(destination(snapshot, census.tabPanes(57)[1]).title == "Note")
	assert(destination(snapshot, census.tabPanes(69)[1]).title == "zsh · scratch")
	assert(destination(snapshot, census.tabPanes(69)[2]).title == "Loose ends" and destination(snapshot, census.tabPanes(69)[2]).titleSource == "native")
	assert(destination(snapshot, census.tabPanes(58)[2]).title == "Stone catalogue")
	local sanitized = destination(snapshot, census.tabPanes(51)[1])
	assert(sanitized.title == "Line one Two", "control characters never reach a title")
	assert(#destination(snapshot, census.tabPanes(61)[2]).title == 160 and #destination(snapshot, census.tabPanes(61)[1]).title <= 160)
	assert(utf8.len(destination(snapshot, census.tabPanes(61)[1]).title) ~= nil, "bounding never splits a character")
	assert(tabNode(snapshot, 51).title == "tide charts", "a named tab keeps its name")
	assert(tabNode(snapshot, 52).title == "Buoy audit", "an unnamed tab shows its focused pane title")
	assert(tabNode(snapshot, 58).title == "Tab 1", "an owned rail never names a tab")
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		assert(not string.find(item.label, "secret", 1, true) and not string.find(item.label, "token", 1, true))
	end
end)

test("conversation links follow proof, claim order, and never merge by title", function()
	local first, second = paneOf("Sketch pad", 1), paneOf("Sketch pad", 2)
	local snapshot = build()
	assert(destination(snapshot, first).conversation.workId ~= destination(snapshot, second).conversation.workId,
		"identically titled conversations remain two records")
	assert(destination(snapshot, first).conversation.proof == "proven" and destination(snapshot, first).conversation.preferred)
	local pending = build({ pending = { [first] = true } })
	assert(destination(pending, first).conversation.proof == "unproven", "stale proof is shown but never trusted")
	local changed = build({ identities = function(identities) identities[first] = "conversation:other-file" end })
	assert(destination(changed, first).conversation.proof == "unproven", "a different file at the same pane is not the record")
	assert(destination(changed, first).conversation.workId == destination(snapshot, first).conversation.workId)
	local row = leafRow(navigation.rows(pending, {}), first)
	assert(row.leaf.availability == "unverified")
	assert(destination(snapshot, census.tabPanes(53)[1]).conversation == nil, "notes carry no conversation")
	assert(snapshot.counts.conversations == 22)
	local attention = destination(snapshot, paneOf("Slab survey")).conversation
	assert(attention.attention and attention.reviewRevision == 4 and attention.nativeState == "idle")
end)

test("rows keep unique keys, bounded depth, and targets that re-resolve exactly", function()
	local snapshot = build()
	local result = navigation.rows(snapshot, { setAsideOpen = allAsideOpen(snapshot) })
	assert(result.total == #result.rows)
	local keys = {}
	for _, row in ipairs(result.rows) do
		assert(keys[row.key] == nil, "duplicate row key " .. row.key)
		keys[row.key] = true
		assert(row.depth >= 0 and row.depth <= 3)
		if row.kind ~= "aside" and row.kind ~= "section" then
			assert(navigation.resolve(snapshot, row.ref.key) ~= nil, "row targets resolve: " .. row.key)
			assert(navigation.signatureMatches(snapshot, row.ref.key, row.signature))
		end
		if row.kind == "leaf" and row.leaf.conversation == nil then assert(row.key == row.ref.key) end
		if row.kind == "leaf" and row.leaf.conversation and row.leaf.conversation.preferred then
			assert(row.key == "r" .. row.leaf.conversation.serial)
		end
	end
	assert(rowOfKind(result, "host") == nil, "a single host with live content shows no host row")
	assert(result.rows[1].kind == "session" and result.rows[1].depth == 0)
end)

test("host rows appear when several hosts hold live content and offline counts stay unknown", function()
	local FAR = 900
	local function remote(state)
		return build({ raw = function(raw)
			raw.hosts[2].state = state
			raw.hosts[2].panes = { FAR }
			table.insert(raw.sessions, { id = 77, host = 2, name = "Remote work", current = false })
			table.insert(raw.tabs, { id = 90, session = 77, pane = FAR, position = 1 })
			table.insert(raw.panes, { pane = FAR, tab = 90, title = "Far shell", kind = "terminal", program = "zsh", cwd = "" })
		end })
	end
	local live = remote("connected")
	local result = navigation.rows(live, {})
	local hostRows = {}
	for _, row in ipairs(result.rows) do
		if row.kind == "host" then table.insert(hostRows, row) end
	end
	assert(#hostRows == 2 and hostRows[1].depth == 0 and hostRows[1].count == 30 and hostRows[2].count == 1)
	local sessionRow = rowOfKind(result, "session", function(row) return row.ref.session == 31 end)
	assert(sessionRow.depth == 1)
	assert(count(live.byKey) == live.counts.hosts + live.counts.sessions + live.counts.tabs + live.counts.destinations + live.counts.retained)
	local collapsed = navigation.rows(live, { collapsed = { [hostRows[1].key] = true } })
	assert(leafRow(collapsed, 101) == nil and leafRow(collapsed, FAR) ~= nil)

	local offline = remote("reconnecting")
	local offlineRows = navigation.rows(offline, {})
	local far
	for _, row in ipairs(offlineRows.rows) do
		if row.kind == "host" and row.ref.hostKey == "host-two.invalid" then far = row end
	end
	assert(far and far.count == nil and far.context == "Host reconnecting", "an unreachable host never reports zero")
	assert(leafRow(offlineRows, FAR).leaf.availability == "offline")
	assert(offline.coverage[2].connected == false and offline.coverage[1].connected == true)
end)

test("ancestors expand exactly the groups above a destination", function()
	local snapshot = build()
	local target = destination(snapshot, paneOf("Vibration limits"))
	local chain = navigation.ancestors(snapshot, target.key)
	assert(#chain == 4, "host, session, tab, and the Set aside disclosure")
	local collapsed, asideOpen = {}, {}
	for key, node in pairs(snapshot.byKey) do
		if node.kind == "host" or node.kind == "session" or node.kind == "tab" then collapsed[key] = true end
	end
	assert(leafRow(navigation.rows(snapshot, { collapsed = collapsed }), target.pane) == nil)
	local tab = tabNode(snapshot, census.tab.laterShared)
	for _, key in ipairs(chain) do
		if string.sub(key, 1, 6) == "aside:" then asideOpen[string.sub(key, 7)] = true else collapsed[key] = nil end
	end
	assert(asideOpen[tab.key])
	local revealed = leafRow(navigation.rows(snapshot, { collapsed = collapsed, setAsideOpen = asideOpen }), target.pane)
	assert(revealed ~= nil, "opening the ancestors makes the destination reachable")
	assert(#navigation.ancestors(snapshot, tab.key) == 2 and #navigation.ancestors(snapshot, "missing") == 0)
	assert(navigation.locate(snapshot, target.pane) == target.key and navigation.locate(snapshot, 99999) == nil)
	assert(snapshot.currentPane == census.focusedPane() and destination(snapshot, census.focusedPane()).current)
end)

return true
