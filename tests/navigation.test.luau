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

local function tabRow(result, id)
	return rowOfKind(result, "tab", function(row) return row.ref.tab == id end)
end

-- Parks every content pane so each one is a leaf row in the Parked section.
local function parkedAll(edit)
	edit = edit or {}
	local inner = edit.raw
	edit.raw = function(raw)
		for _, pane in ipairs(raw.panes) do pane.parked = true end
		if inner then inner(raw) end
	end
	return build(edit)
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
	assert(session.tabs[1].title == "Agent" and session.tabs[1].name == nil, "an untitled tab takes its target's title")
	assert(destination(snapshot, paneOf("Tide ledger")).title == "Agent", "an untitled agent with no program falls back to its kind")
end)

test("a placeholder or bare-path native title yields the derived title; a real title stays native", function()
	local dash, hyphen, tilde, path, real = paneOf("Tide ledger"), paneOf("Basket weave"), paneOf("Kettle seam"),
		paneOf("Buoy audit"), paneOf("Slab survey")
	local titles = { [dash] = "\u{2013}", [hyphen] = "-", [tilde] = "~", [path] = "~/src/atlas", [real] = "~ vim notes" }
	local snapshot = build({ raw = function(raw)
		for _, pane in ipairs(raw.panes) do
			if titles[pane.pane] then pane.title = titles[pane.pane] end
		end
	end })
	for _, pane in ipairs({ dash, hyphen }) do
		local node = destination(snapshot, pane)
		assert(node.title == "omp · atlas" and node.titleSource == "derived", "placeholder title must derive: " .. tostring(node.title))
	end
	for _, pane in ipairs({ tilde, path }) do
		local node = destination(snapshot, pane)
		assert(node.titleSource == "derived" and node.title ~= titles[pane], "a bare path must derive: " .. tostring(node.title))
	end
	local kept = destination(snapshot, real)
	assert(kept.title == "~ vim notes" and kept.titleSource == "native")
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

test("every census pane appears once in the hierarchy and search, and is reached through its tab row", function()
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
	local result = navigation.rows(snapshot, {})
	local rowKeys, tabRows = {}, 0
	for _, row in ipairs(result.rows) do
		rowKeys[row.key] = true
		assert(row.kind ~= "leaf", "the census has no parked or unattached panes")
		if row.kind == "tab" then tabRows += 1 end
	end
	assert(tabRows == 22 and snapshot.counts.tabs == 22)
	for _, pane in ipairs(expected) do
		assert(searched[pane] == 1, "search must list pane " .. pane .. " once")
		assert(rowKeys[navigation.rowKey(snapshot, destination(snapshot, pane).key)], "pane " .. pane .. " has a tab row")
	end
end)

test("a tab is titled by its focused pane, a named tab by its name", function()
	local snapshot = build()
	local named = tabNode(snapshot, census.tab.multiNamed)
	assert(named.title == "tide charts" and named.target.pane == census.tabPanes(51)[1])
	local unnamed = tabNode(snapshot, census.tab.pair)
	assert(unnamed.name == nil and unnamed.title == "Core samples" and unnamed.target.pane == census.tabPanes(66)[1])
	local refocused = build({ raw = function(raw)
		for _, tab in ipairs(raw.tabs) do
			if tab.id == census.tab.pair then tab.pane = census.tabPanes(66)[2] end
			if tab.id == census.tab.multiNamed then tab.pane = census.tabPanes(51)[2] end
		end
	end })
	assert(tabNode(refocused, census.tab.pair).title == "Sketch pad"
		and tabNode(refocused, census.tab.pair).target.pane == census.tabPanes(66)[2])
	assert(tabNode(refocused, census.tab.multiNamed).title == "tide charts"
		and tabNode(refocused, census.tab.multiNamed).target.pane == census.tabPanes(51)[2],
		"a name outranks the pane title while the target still follows focus")
	local row = tabRow(navigation.rows(refocused, {}), census.tab.pair)
	assert(row.title == "Sketch pad" and row.expandable == false and row.count == nil)
end)

test("a tab row names the native tile of its focused pane", function()
	local result = navigation.rows(build(), {})
	for id, icon in pairs({ [census.tab.single] = "app-omp", [census.tab.namedNote] = "tile-note",
		[census.tab.namedBrowser] = "globe", [census.tab.shell] = "tile-shell" }) do
		assert(tabRow(result, id).icon == icon, "tab " .. id .. " shows " .. icon .. ", got " .. tostring(tabRow(result, id).icon))
	end
	local edited = navigation.rows(build({ raw = function(raw)
		for _, pane in ipairs(raw.panes) do
			if pane.tab == census.tab.shell and pane.kind == "terminal" then pane.program = "/opt/homebrew/bin/nvim" end
			if pane.tab == 57 then pane.path = "/work/atlas/README.md" end
			if pane.tab == census.tab.namedBrowser then pane.kind, pane.program = "canvas", nil end
		end
	end }), {})
	assert(tabRow(edited, census.tab.shell).icon == "app-vim", "a terminal running nvim shows the vim tile")
	assert(tabRow(edited, 57).icon == "tile-document", "a file that is not a note shows the document tile")
	assert(tabRow(edited, census.tab.namedBrowser).icon == "tile-shell", "a canvas shows the shell tile, as native does")
end)

test("a leading title glyph moves to the tile; the signature stays the snapshot's", function()
	local function rowTitled(name)
		local snapshot = build({ raw = function(raw)
			for _, tab in ipairs(raw.tabs) do
				if tab.id == census.tab.multiNamed then tab.name = name end
			end
		end })
		local row = tabRow(navigation.rows(snapshot, {}), census.tab.multiNamed)
		local tab = tabNode(snapshot, census.tab.multiNamed)
		assert(row.signature == tab.signature)
		return row, tab.title
	end
	local nerd = rowTitled("\u{F0403} EXP: x")
	assert(nerd.title == "EXP: x" and nerd.glyph == "\u{F0403}", "a private-use glyph and its space leave the title")
	local emoji = rowTitled("\u{1F7E2} build")
	assert(emoji.title == "build" and emoji.glyph == "\u{1F7E2}", "an emoji moves too")
	for _, name in ipairs({ "x \u{F0403}", "plain title", "\u{F0403}x", "\u{F0403} ", "é tide" }) do
		local row, title = rowTitled(name)
		assert(row.title == title and row.glyph == nil, "unchanged: " .. name)
	end
end)

test("a focus outside the tab falls back to the tab's first content pane", function()
	local snapshot = build({ raw = function(raw)
		for _, tab in ipairs(raw.tabs) do
			if tab.id == census.tab.pair then tab.pane = census.tabPanes(52)[1] end
			if tab.id == census.tab.mixed then tab.pane = census.rail.mixed end
			if tab.id == 54 then tab.pane = nil end
		end
	end })
	local pair = tabNode(snapshot, census.tab.pair)
	assert(pair.target.pane == census.tabPanes(66)[1] and pair.title == "Core samples", "another tab's pane never targets")
	local mixed = tabNode(snapshot, census.tab.mixed)
	assert(mixed.target.pane == census.tabPanes(58)[1] and mixed.title == "Slab survey", "an owned rail never targets")
	assert(tabNode(snapshot, 54).target.pane == census.tabPanes(54)[1], "no focused pane at all")
end)

test("empty tabs are hidden, sessions with no visible tab are listed empty, and counts.tabs counts visible tabs", function()
	local snapshot = build({ raw = function(raw)
		table.insert(raw.tabs, { id = 90, session = census.session.harbor, position = 5 })
		table.insert(raw.sessions, { id = 77, host = 1, name = "Hollow", current = false })
		table.insert(raw.tabs, { id = 91, session = 77, position = 1 })
	end })
	assert(tabNode(snapshot, 90).target == nil and tabNode(snapshot, 91).target == nil)
	assert(snapshot.counts.tabs == 22, "tabs without a content pane are not visible")
	local result = navigation.rows(snapshot, {})
	assert(tabRow(result, 90) == nil and tabRow(result, 91) == nil)
	local sessions = 0
	for _, row in ipairs(result.rows) do
		if row.kind == "session" then sessions += 1 end
	end
	assert(sessions == 12, "every session is listed, the empty census sessions and the hollow one included")
	for _, id in ipairs({ census.session.dune, census.session.fjord, 77 }) do
		assert(sessionNode(snapshot, id).empty)
		local row = rowOfKind(result, "session", function(candidate) return candidate.ref.session == id end)
		assert(row and row.empty and not row.expandable and row.count == nil, "an empty session is a row with nothing to expand")
	end
	local harbor = rowOfKind(result, "session", function(row) return row.ref.session == census.session.harbor end)
	assert(harbor.count == 4 and harbor.context == nil and harbor.expandable == true, "a bare count of visible tabs, no Current text")
	assert(navigation.signatureMatches(snapshot, harbor.ref.key, harbor.signature))
	local found = 0
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		if item.kind == "session" and (item.ref.session == census.session.dune or item.ref.session == 77) then found += 1 end
	end
	assert(found == 2, "hidden sessions stay searchable")
	assert(snapshot.counts.sessions == 12)
end)

test("only the tab holding the current pane is marked current", function()
	local function currentTabs(snapshot)
		local marked = {}
		for _, row in ipairs(navigation.rows(snapshot, {}).rows) do
			if row.kind == "tab" then
				assert(type(row.current) == "boolean")
				if row.current then table.insert(marked, row.ref.tab) end
			end
		end
		return marked
	end
	local marked = currentTabs(build())
	assert(#marked == 1 and marked[1] == census.tab.single)
	local background = build({ raw = function(raw) raw.focused = census.tabPanes(66)[2] end })
	marked = currentTabs(background)
	assert(#marked == 1 and marked[1] == census.tab.pair, "the current pane marks its tab even when it is not the tab's target")
	assert(tabNode(background, census.tab.pair).target.pane == census.tabPanes(66)[1])
end)

test("one conversation on two routes keeps both links and counts once", function()
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
	assert(active.counts.conversations == 21, "distinct conversations, not routes")

	local finished = build(edit("finished"))
	local rows = navigation.rows(finished, {})
	assert(tabRow(rows, census.tab.pair) ~= nil, "a Finished conversation never removes its tab")
end)

test("Finished conversations are not rows; their tab stays", function()
	local snapshot = build()
	local tab = tabNode(snapshot, census.tab.finishedShared)
	local rows = navigation.rows(snapshot, {})
	assert(tabRow(rows, tab.id) ~= nil and #tab.destinations == 3)
	for _, row in ipairs(rows.rows) do
		assert(row.kind == "session" or row.kind == "tab" or row.kind == "section",
			"the census tree holds only sessions, tabs, and Parked/Unattached sections")
	end
	local finished = build({ rows = function(rows) rowFor(rows, "Buoy audit").disposition = "finished" end })
	assert(tabRow(navigation.rows(finished, {}), census.tab.single) ~= nil, "a Finished lone pane keeps its tab row")
end)

test("Reference and Finished conversations keep their disposition and their tab row", function()
	local snapshot = build()
	local result = navigation.rows(snapshot, {})
	for title, disposition in pairs({ ["Bale counting"] = "reference", ["Kettle seam"] = "finished" }) do
		local node = destination(snapshot, paneOf(title))
		assert(node.conversation.disposition == disposition)
		assert(tabRow(result, node.tabId) ~= nil, title .. " stays reachable through its tab")
	end
end)

test("offline and retained records stay separate from open panes with typed counts", function()
	local snapshot = build({ rows = function(rows)
		table.insert(rows, { workId = "work:101", serial = 101, pane = nil, host = 1, hostKey = "local", title = "Closed thread",
			sessionName = "Harbor", hostName = "Workbench", disposition = "finished", retained = true,
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
	assert(rowOfKind(result, "section", function(row) return row.title == "Saved conversations" end) == nil,
		"the Saved conversations section is gone from the tree")
	for _, row in ipairs(result.rows) do
		assert(row.kind ~= "retained", "a retained record is not a Workspace row; Search and the queues reach it")
	end
	assert(rowOfKind(result, "host") == nil, "an offline host with no live content forces no host row")
	local closed
	for _, item in ipairs(navigation.searchItems(snapshot)) do
		if item.kind == "retained" and item.ref.key == byWork["work:101"].key then closed = item end
	end
	assert(closed and string.find(closed.label, "Closed thread", 1, true) == 1,
		"Search lists a saved conversation that has no open pane")
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

test("search is independent of collapse state", function()
	local snapshot = build()
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
	local deferred = build({ rows = function(rows) rowFor(rows, "Tide ledger").disposition = "finished" end })
	assert(not navigation.signatureMatches(deferred, key, signature), "disposition changes the target")
	local revised = build({ rows = function(rows) rowFor(rows, "Tide ledger").reviewRevision = 9 end })
	assert(not navigation.signatureMatches(revised, key, signature), "a new review revision changes the target")
	local retargeted = build({ rows = function(rows) rowFor(rows, "Tide ledger").workId = "work:900" end })
	assert(not navigation.signatureMatches(retargeted, key, signature), "a different record is a different target")
	assert(not navigation.signatureMatches(base, "pane:local#99999", signature))
	assert(not navigation.signatureMatches(base, key, nil))
end)

test("an agent's model rides onto its conversation row, display only", function()
	local result = navigation.rows(parkedAll(), {})
	local function model(title)
		local row = leafRow(result, paneOf(title))
		assert(row ~= nil and row.leaf.conversation ~= nil, title .. " is a conversation leaf")
		return row.leaf.model
	end
	assert(model("Tide ledger") == "GPT-6 Astra" and model("Sketch pad") == "GPT-6 Astra", "present")
	assert(model("Buoy audit") == nil and model("Pier schedule") == nil, "absent stays nil")
	assert(model("Charge sizing") == "GPT-6 Astra" and model("Vibration limits") == "Claude Opus 4.6"
		and model("Dust study") == nil, "each agent keeps its own model, nil included")
	assert(leafRow(result, census.tabPanes(census.tab.namedNote)[1]).leaf.model == nil, "a note has no model")
	assert(leafRow(result, census.tabPanes(census.tab.namedBrowser)[1]).leaf.model == nil, "a browser has no model")

	local untracked = parkedAll({ rows = function(rows)
		local kept = {}
		for _, row in ipairs(rows) do
			if row.title ~= "Tide ledger" then table.insert(kept, row) end
		end
		return kept
	end })
	local bare = leafRow(navigation.rows(untracked, {}), paneOf("Tide ledger"))
	assert(bare ~= nil and bare.leaf.conversation == nil and bare.leaf.model == nil,
		"the model belongs to conversation rows; an untracked agent pane keeps the kind sub-line")
end)

test("an unusable native model reads as absent and never fails the inventory", function()
	for _, junk in ipairs({ "", "   ", "\n\t", 42, true, census.null, {} }) do
		local snapshot = parkedAll({ raw = function(raw)
			for _, agent in ipairs(raw.agents) do agent.model = junk end
		end })
		local leaves = 0
		for _, row in ipairs(navigation.rows(snapshot, {}).rows) do
			if row.kind == "leaf" then
				leaves += 1
				assert(row.leaf.model == nil, "junk model " .. tostring(junk) .. " reads as nil")
			end
		end
		assert(leaves == 30)
	end
	local padded = parkedAll({ raw = function(raw)
		for _, agent in ipairs(raw.agents) do
			if agent.pane == paneOf("Buoy audit") then agent.model = "  GPT-6\n Astra  " end
		end
	end })
	assert(leafRow(navigation.rows(padded, {}), paneOf("Buoy audit")).leaf.model == "GPT-6 Astra", "sanitized like any other native text")
end)

test("targets ignore the model; the workspace repaint digest tracks it", function()
	local with = build()
	local without = build({ raw = function(raw)
		for _, agent in ipairs(raw.agents) do agent.model = nil end
	end })
	local flipped = build({ raw = function(raw)
		for _, agent in ipairs(raw.agents) do agent.model = "Claude Opus 4.6" end
	end })
	for _, other in ipairs({ without, flipped }) do
		assert(other.signature ~= with.signature, "the workspace digest follows the model so catchup repaints")
		for index, left in ipairs(destinations(with)) do
			local right = destinations(other)[index]
			assert(left.key == right.key and left.signature == right.signature, "destination key and signature ignore the model")
			assert(navigation.signatureMatches(other, left.key, left.signature), "a model change never refuses a captured target")
		end
		local leftRows, rightRows = navigation.rows(with, {}).rows, navigation.rows(other, {}).rows
		assert(#leftRows == #rightRows)
		for index, left in ipairs(leftRows) do
			assert(left.key == rightRows[index].key and left.signature == rightRows[index].signature, "row key and signature ignore the model")
		end
		local leftItems, rightItems = navigation.searchItems(with), navigation.searchItems(other)
		assert(#leftItems == #rightItems)
		for index, left in ipairs(leftItems) do
			local right = rightItems[index]
			assert(left.id == right.id and left.label == right.label and left.detail == right.detail and left.signature == right.signature,
				"search items ignore the model")
		end
	end
	assert(without.signature ~= flipped.signature, "absent and replaced models digest differently")
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
	assert(tabNode(snapshot, 52).target.pane == census.tabPanes(52)[1] and tabNode(snapshot, 52).title == "Buoy audit",
		"an extra canvas never changes the tab's target")
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
	assert(leafRow(result, census.tabPanes(52)[1]) == nil, "a pane inside a tab has no row of its own")
	assert(navigation.rowKey(snapshot, destination(snapshot, 851).key) == destination(snapshot, 851).key,
		"a parked pane is its own row")
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
	assert(tabNode(snapshot, 58).title == "Slab survey", "an owned rail never names a tab; the first content pane does")
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
	local parked = parkedAll({ pending = { [first] = true } })
	assert(leafRow(navigation.rows(parked, {}), first).leaf.availability == "unverified")
	assert(destination(snapshot, census.tabPanes(53)[1]).conversation == nil, "notes carry no conversation")
	assert(snapshot.counts.conversations == 22)
	local attention = destination(snapshot, paneOf("Slab survey")).conversation
	assert(attention.attention and attention.reviewRevision == 4 and attention.nativeState == "idle")
end)

test("rows keep unique keys, bounded depth, and targets that re-resolve exactly", function()
	local snapshot = build()
	local result = navigation.rows(snapshot, {})
	assert(result.total == #result.rows)
	local keys = {}
	for _, row in ipairs(result.rows) do
		assert(keys[row.key] == nil, "duplicate row key " .. row.key)
		keys[row.key] = true
		assert(row.depth >= 0 and row.depth <= 3)
		if row.kind ~= "section" then
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
	assert(#hostRows == 2 and hostRows[1].depth == 0 and hostRows[1].count == 22 and hostRows[2].count == 1,
		"host counts are visible tabs")
	local sessionRow = rowOfKind(result, "session", function(row) return row.ref.session == 31 end)
	assert(sessionRow.depth == 1)
	assert(count(live.byKey) == live.counts.hosts + live.counts.sessions + live.counts.tabs + live.counts.destinations + live.counts.retained)
	local collapsed = navigation.rows(live, { collapsed = { [hostRows[1].key] = true } })
	assert(tabRow(collapsed, 52) == nil and tabRow(collapsed, 90) ~= nil)
	-- A minimized session's tabs sit behind the Minimized line, so the host counts only what it shows.
	local harborKey = sessionNode(live, census.session.harbor).key
	local minimizedRows = navigation.rows(live, { collapsed = { [harborKey] = true } })
	local hostOf = function(rows) return rowOfKind(rows, "host", function(row) return row.ref.hostKey == "local" end) end
	assert(hostOf(minimizedRows).count == 18, "minimizing a 4-tab session drops it from its host's count: "
		.. tostring(hostOf(minimizedRows).count))
	assert(navigation.signatureMatches(live, hostOf(minimizedRows).ref.key, hostOf(minimizedRows).signature),
		"the host row still binds to its snapshot node")
	assert(hostOf(navigation.rows(live, { collapsed = {} })).count == 22, "restoring it brings the tabs back")

	local offline = remote("reconnecting")
	local offlineRows = navigation.rows(offline, {})
	local far
	for _, row in ipairs(offlineRows.rows) do
		if row.kind == "host" and row.ref.hostKey == "host-two.invalid" then far = row end
	end
	assert(far and far.count == nil and far.context == "Host reconnecting", "an unreachable host never reports zero")
	assert(tabRow(offlineRows, 90) ~= nil, "an offline host's tabs stay listed")
	assert(offline.counts.tabs == 22 and live.counts.tabs == 23, "counts.tabs covers connected hosts only")
	assert(offline.coverage[2].connected == false and offline.coverage[1].connected == true)
end)

test("ancestors end at the tab row and rowKey maps a pane to the row that represents it", function()
	local snapshot = build()
	local target = destination(snapshot, paneOf("Vibration limits"))
	local tab = tabNode(snapshot, census.tab.finishedShared)
	local chain = navigation.ancestors(snapshot, target.key)
	assert(#chain == 3 and chain[1] == snapshot.hosts[1].key and chain[2] == sessionNode(snapshot, tab.sessionId).key
		and chain[3] == tab.key, "host, session, tab")
	local collapsed = {}
	for key, node in pairs(snapshot.byKey) do
		if node.kind == "host" or node.kind == "session" then collapsed[key] = true end
	end
	assert(tabRow(navigation.rows(snapshot, { collapsed = collapsed }), tab.id) == nil)
	for _, key in ipairs(chain) do collapsed[key] = nil end
	assert(tabRow(navigation.rows(snapshot, { collapsed = collapsed }), tab.id) ~= nil,
		"opening the ancestors makes the tab row reachable")
	assert(#navigation.ancestors(snapshot, tab.key) == 2 and #navigation.ancestors(snapshot, "missing") == 0)
	assert(navigation.locate(snapshot, target.pane) == target.key and navigation.locate(snapshot, 99999) == nil)
	assert(snapshot.currentPane == census.focusedPane() and destination(snapshot, census.focusedPane()).current)

	assert(navigation.rowKey(snapshot, target.key) == tab.key, "a pane inside a tab maps to its tab row")
	assert(navigation.rowKey(snapshot, tab.key) == tab.key)
	assert(navigation.rowKey(snapshot, snapshot.retained[1].key) == snapshot.retained[1].key)
	assert(navigation.rowKey(snapshot, "missing") == "missing")
	assert(navigation.rowKey(snapshot, sessionNode(snapshot, tab.sessionId).key) == sessionNode(snapshot, tab.sessionId).key)
end)

-- Manual session order (overlay.sessionOrder): stored ids first in their stored order, unknown sessions of the
-- host after them in native order, stored ids with no live session ignored, other hosts untouched.
test("sessionOrder reorders one host, appends new sessions, ignores stale ids, and leaves other hosts native", function()
	local plain = build()
	local host = plain.hosts[1]
	local other = plain.hosts[2]
	assert(#host.sessions > 2, "fixture: the local host carries several sessions")
	local nativeIds, stored = {}, { 999 }
	for index = #host.sessions, 1, -1 do table.insert(stored, host.sessions[index].id) end
	for _, session in ipairs(host.sessions) do table.insert(nativeIds, session.id) end
	local raw, options = census.raw(), census.options()
	local data = navigation.inventory(raw, options)
	local rows, identities = census.rows(), census.identities()
	local reordered = navigation.project(data, { rows = rows, identities = identities, identityPending = {},
		window = "window", nowUtc = 1, sessionOrder = { [host.hostKey] = stored } })
	local got = {}
	for _, session in ipairs(reordered.hosts[1].sessions) do table.insert(got, session.id) end
	local expected = {}
	for index = #nativeIds, 1, -1 do table.insert(expected, nativeIds[index]) end
	assert(#got == #expected, "a stale stored id adds no session")
	for index, id in ipairs(expected) do
		assert(got[index] == id, "the host shows its sessions in the stored order, reversed here")
	end
	local otherIds = {}
	for _, session in ipairs(other.sessions) do table.insert(otherIds, session.id) end
	local otherGot = {}
	for _, session in ipairs(reordered.hosts[2].sessions) do table.insert(otherGot, session.id) end
	assert(#otherIds == #otherGot, "a host without a stored order keeps every session")
	for index, id in ipairs(otherIds) do
		assert(otherGot[index] == id, "a host without a stored order keeps its native order")
	end
	-- A stored order listing only some sessions still shows them all: the unlisted ones append natively.
	local partial = navigation.project(data, { rows = rows, identities = identities, identityPending = {},
		window = "window", nowUtc = 1, sessionOrder = { [host.hostKey] = { nativeIds[2] } } })
	local partialIds = {}
	for _, session in ipairs(partial.hosts[1].sessions) do table.insert(partialIds, session.id) end
	assert(partialIds[1] == nativeIds[2] and #partialIds == #nativeIds,
		"the one stored session leads and the rest append in native order")
end)

return true
