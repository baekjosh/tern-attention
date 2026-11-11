-- Synthetic workspace census with invented names. Shape: 11 sessions (2 empty), 22 tabs (9 named; 5 with 2-3
-- agents; 6 with no agent), 22 conversation panes, 5 notes, 2 browsers (one sharing a tab with an agent),
-- 1 shell, one Finished conversation sharing a tab with an active one, and 8 offline remote last-known records
-- (two titled `omp`, no identity). Two Attention rails (owned canvases) sit in tabs and are never destinations.
local census = {}
-- Stand-in for tern.json.null.
census.null = {}

local LOCAL_HOST, REMOTE_HOST = 1, 2
local REMOTE_ADDRESS = "host-two.invalid"

local function agent(title, model) return { kind = "agent", title = title, program = "omp", cwd = "/work/atlas", model = model } end
local function note(title) return { kind = "file", title = title or "", path = "note:ledger" } end
local function browser(title, url) return { kind = "browser", title = title, url = url } end

-- id ranges: sessions 31-41, tabs 51-72, panes 101+, rails 801+.
local SESSIONS = {
	{ id = 31, name = "Harbor", tabs = {
		{ id = 51, name = "tide charts", panes = { agent("Tide ledger", "GPT-6 Astra"), agent("Sketch pad", "GPT-6 Astra") } },
		{ id = 52, panes = { agent("Buoy audit") } },
		{ id = 53, name = "harbor notes", panes = { note("") } },
		{ id = 54, panes = { agent("Pier schedule") } },
	} },
	{ id = 32, name = "Orchard", tabs = {
		{ id = 55, name = "grafting", panes = { agent("Rootstock plan"), agent("Pruning round") } },
		{ id = 56, panes = { agent("Blossom watch") } },
		{ id = 57, panes = { note("") } },
	} },
	{ id = 33, name = "Quarry", tabs = {
		{ id = 58, panes = { agent("Slab survey"), browser("Stone catalogue", "https://stone.example.invalid/catalogue") } },
		{ id = 59, name = "blast log", panes = { agent("Charge sizing", "GPT-6 Astra"), agent("Vibration limits", "Claude Opus 4.6"), agent("Dust study") } },
		{ id = 60, panes = { note("") } },
	} },
	{ id = 34, name = "Lantern", tabs = {
		{ id = 61, name = "wick study", panes = { agent("Wick braid"), agent("Oil grades") } },
		{ id = 62, panes = { agent("Glass cutting") } },
		{ id = 63, name = "reading list", panes = { browser("", "https://docs.example.invalid/reading") } },
	} },
	{ id = 35, name = "Meadow", tabs = {
		{ id = 64, name = "hay", panes = { agent("Bale counting") } },
		{ id = 65, panes = { note("") } },
	} },
	{ id = 36, name = "Granite", tabs = {
		{ id = 66, panes = { agent("Core samples"), agent("Sketch pad") } },
		{ id = 67, panes = { agent("Polish grades") } },
	} },
	{ id = 37, name = "Willow", tabs = {
		{ id = 68, panes = { agent("Basket weave") } },
		{ id = 69, name = "scratch", panes = { { kind = "terminal", title = "", program = "/bin/zsh", cwd = "/work/atlas/scratch" }, note("Loose ends") } },
	} },
	{ id = 38, name = "Copper", tabs = {
		{ id = 70, name = "kettle", panes = { agent("Kettle seam") } },
		{ id = 71, panes = { agent("Patina test") } },
	} },
	{ id = 39, name = "Saffron", tabs = {
		{ id = 72, panes = { agent("Thread harvest") } },
	} },
	{ id = 40, name = "Dune", tabs = {} },
	{ id = 41, name = "Fjord", tabs = {} },
}

local RAILS = { [51] = 801, [58] = 802 }

local OFFLINE_TITLES = { "omp", "omp", "Index rebuild", "Pager duty", "Spec review", "Release train", "Backfill", "Cutover plan" }

-- Role -> id lookups for tests (invented, stable).
census.session = { harbor = 31, dune = 40, fjord = 41 }
census.tab = {
	multiNamed = 51, single = 52, namedNote = 53, mixed = 58, finishedShared = 59, namedBrowser = 63, reference = 64,
	pair = 66, shell = 69, finished = 70,
}
census.rail = { multiNamed = 801, mixed = 802 }

local layout = nil
local function build()
	if layout ~= nil then return layout end
	layout = { panes = {}, tabs = {}, sessions = {}, titles = {}, byTitle = {} }
	local nextPane = 101
	for _, session in ipairs(SESSIONS) do
		table.insert(layout.sessions, { id = session.id, name = session.name, tabCount = #session.tabs })
		for position, tab in ipairs(session.tabs) do
			local entry = { id = tab.id, session = session.id, name = tab.name, position = position, panes = {} }
			for _, spec in ipairs(tab.panes) do
				local pane = { id = nextPane, spec = spec, tab = tab.id, session = session.id }
				nextPane += 1
				table.insert(entry.panes, pane)
				table.insert(layout.panes, pane)
				layout.byTitle[spec.title] = layout.byTitle[spec.title] or {}
				table.insert(layout.byTitle[spec.title], pane.id)
			end
			table.insert(layout.tabs, entry)
		end
	end
	return layout
end

-- Pane ids of the census by tab id, in native order.
function census.tabPanes(tab)
	for _, entry in ipairs(build().tabs) do
		if entry.id == tab then
			local ids = {}
			for _, pane in ipairs(entry.panes) do table.insert(ids, pane.id) end
			return ids
		end
	end
	error("unknown census tab " .. tostring(tab))
end

-- Every content pane id of the census, ascending.
function census.contentPanes()
	local ids = {}
	for _, pane in ipairs(build().panes) do table.insert(ids, pane.id) end
	return ids
end

-- Conversation (agent) pane ids by exact title; titles may repeat.
function census.agentPanes(title)
	return build().byTitle[title] or {}
end

function census.raw()
	local built = build()
	local content, panes, agents, tabs, sessions, canvases = {}, {}, {}, {}, {}, {}
	for _, session in ipairs(built.sessions) do
		table.insert(sessions, { id = session.id, host = LOCAL_HOST, name = session.name, current = session.id == 31,
			locked = false, tabs = session.tabCount })
	end
	for _, tab in ipairs(built.tabs) do
		local first = tab.panes[1]
		local rail = RAILS[tab.id]
		table.insert(tabs, { id = tab.id, session = tab.session, name = tab.name, position = tab.position,
			pane = first.id, title = first.spec.title, panes = #tab.panes + (if rail then 1 else 0) })
		for _, pane in ipairs(tab.panes) do
			table.insert(content, pane.id)
			table.insert(panes, { pane = pane.id, tab = tab.id, title = pane.spec.title, kind = pane.spec.kind,
				program = pane.spec.program, cwd = pane.spec.cwd or "", url = pane.spec.url, path = pane.spec.path,
				focused = pane.id == first.id and tab.id == 52, floating = false, parked = false })
			if pane.spec.kind == "agent" then table.insert(agents, { pane = pane.id, state = "idle", model = pane.spec.model }) end
		end
		if rail then
			table.insert(content, rail)
			table.insert(panes, { pane = rail, tab = tab.id, title = "Sketch pad", kind = "plugin", block = "tern.canvas",
				cwd = "", floating = false, parked = false })
			table.insert(canvases, { pane = rail, owner = "attention", about = "attention:rail:v1", title = "Sketch pad" })
		end
	end
	return {
		hosts = {
			{ id = LOCAL_HOST, kind = "local", name = "Workbench", state = "connected", current = true, panes = content },
			{ id = REMOTE_HOST, kind = "remote", address = REMOTE_ADDRESS, name = "Remote Lab", state = "reconnecting",
				current = false, panes = {} },
		},
		sessions = sessions, tabs = tabs, panes = panes, agents = agents, canvases = canvases, focused = census.tabPanes(52)[1],
	}
end

function census.options()
	return {
		canvasOwned = function(canvas) return canvas.owner == "attention" and canvas.about == "attention:rail:v1" end,
		closedTabs = {}, now = 1000, null = census.null,
		states = { idle = true, working = true, waiting_input = true, exited = true },
	}
end

-- Pane that the raw census reports as focused (the lone pane of tab 52).
function census.focusedPane()
	return census.tabPanes(52)[1]
end

-- Conversation tracking rows as the model publishes them, plus the 8 offline remote records.
function census.rows()
	local built = build()
	local rows, serial = {}, 0
	local overrides = {
		["Vibration limits"] = { disposition = "finished", retained = true },
		["Bale counting"] = { disposition = "reference", retained = true },
		["Kettle seam"] = { disposition = "finished", retained = true },
		["Slab survey"] = { attention = true, reviewRevision = 4 },
	}
	for _, pane in ipairs(built.panes) do
		if pane.spec.kind == "agent" then
			serial += 1
			local row = { workId = "work:" .. serial, serial = serial, pane = pane.id, host = LOCAL_HOST, hostKey = "local",
				tab = pane.tab, session = pane.session, title = pane.spec.title, sessionName = "", hostName = "Workbench",
				disposition = "active", retained = false, identityKey = "conversation:" .. pane.id, attention = false,
				nativeState = "idle", orphaned = false, noOpenPane = false, navigable = true, live = true }
			for field, value in pairs(overrides[pane.spec.title] or {}) do row[field] = value end
			table.insert(rows, row)
		end
	end
	for index, title in ipairs(OFFLINE_TITLES) do
		serial += 1
		table.insert(rows, { workId = "work:" .. serial, serial = serial, pane = 700 + index, host = REMOTE_HOST,
			hostKey = REMOTE_ADDRESS, title = title, sessionName = "Rolling", hostName = "Remote Lab", disposition = "active",
			retained = false, identityKey = nil, attention = false, nativeState = "unknown", orphaned = false,
			noOpenPane = false, navigable = false, unavailableReason = "Remote Lab offline",
			stale = true, live = false })
	end
	return rows
end

-- Proven locator keys for every local conversation pane.
function census.identities()
	local identities = {}
	for _, pane in ipairs(build().panes) do
		if pane.spec.kind == "agent" then identities[pane.id] = "conversation:" .. pane.id end
	end
	return identities
end

return census
