-- Pure workspace navigation: native inventory validation, the destination hierarchy, the conversation
-- overlay, the flattened visible rows, and the complete search inventory. No `tern`, no `cx`, no clock:
-- everything arrives as an argument, and nothing here mutates tracking state.
local navigation = {}

local TITLE_LIMIT = 160
local DETAIL_LIMIT = 160
local LABEL_LIMIT = 150
local MAX_DEPTH = 3

local KIND_LABELS = {
	terminal = "Terminal", agent = "Agent", plugin = "Plugin", browser = "Browser", file = "File", git = "Git",
	database = "Database", notebook = "Notebook", board = "Board", canvas = "Canvas", procs = "Processes",
	screen = "Screen", profile = "Profile", carly = "Carly",
}

local DISPOSITION_MARKERS = { later = "Later", reference = "Reference", finished = "Finished" }

local REASON_MARKERS = {
	["no-open-pane"] = "No open pane", offline = "Offline", unverified = "Unverified", missing = "Missing",
}

local UNVERIFIED_REASONS = {
	unverified = true, ["identity proof pending"] = true, ["source header proof pending"] = true, ambiguous = true,
}

local function isId(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge and value % 1 == 0
end

-- Text helpers ------------------------------------------------------------------------------------

local function bounded(value, limit)
	if #value <= limit then return value end
	local cut = limit
	-- Never cut inside a UTF-8 sequence: back up while the next byte is a continuation byte.
	while cut > 0 do
		local byte = string.byte(value, cut + 1)
		if byte == nil or byte < 128 or byte >= 192 then break end
		cut -= 1
	end
	return string.sub(value, 1, cut)
end

-- Sanitized single-line text, or nil when nothing printable remains.
local function clean(value, limit)
	if type(value) ~= "string" then return nil end
	local spaced = string.gsub(value, "%c", " ")
	spaced = string.gsub(spaced, "%s+", " ")
	spaced = string.gsub(string.gsub(spaced, "^ ", ""), " $", "")
	if spaced == "" then return nil end
	return bounded(spaced, limit or TITLE_LIMIT)
end

-- Non-blank native string, or nil; unlike the validated fields this never asserts.
local function soft(value)
	if type(value) == "string" and value ~= "" then return value end
	return nil
end

local function softNumber(value)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then return value end
	return nil
end

local function basename(path)
	return string.match(path, "([^/]+)/*$")
end

local function browserTitle(url)
	local authority, path = string.match(url, "^%a[%w+.-]*://([^/?#]*)([^?#]*)")
	if authority == nil then return nil end
	authority = string.gsub(authority, "^.*@", "")
	if authority == "" then return nil end
	if path == "/" then path = "" end
	return clean(authority .. path)
end

local function derivedTitle(paneKind, pane)
	if paneKind == "browser" then
		return (if pane.url then browserTitle(pane.url) else nil) or "Browser"
	elseif paneKind == "file" then
		local path = pane.path
		if path == nil then return "File" end
		if string.sub(path, 1, 5) == "note:" then return "Note" end
		return clean(basename(path)) or "File"
	elseif paneKind == "plugin" then
		return clean(pane.block) or "Plugin"
	elseif paneKind == "terminal" or paneKind == "agent" then
		local program = if pane.program then basename(pane.program) else nil
		local title = clean(program) or KIND_LABELS[paneKind]
		local folder = if pane.cwd then basename(pane.cwd) else nil
		folder = clean(folder)
		if folder then title = bounded(title .. " · " .. folder, TITLE_LIMIT) end
		return title
	end
	return KIND_LABELS[paneKind] or "Pane"
end

-- Canonical component encoding: every component is length-prefixed, so no value can forge a separator.
local function enc(...)
	local parts = {}
	for index = 1, select("#", ...) do
		local value = select(index, ...)
		if value == nil then
			parts[index] = "-"
		else
			local textual = tostring(value)
			parts[index] = #textual .. ":" .. textual
		end
	end
	return table.concat(parts, "|")
end

local function digest(value)
	local a, b = 2166136261, 5381
	for index = 1, #value do
		local byte = string.byte(value, index)
		a = bit32.bxor(a, byte)
		a = (bit32.lshift(a, 24) + a * 403) % 4294967296
		b = (b * 33 + byte) % 4294967296
	end
	return string.format("%08x%08x.%d", a, b, #value)
end

local function sortedKeys(map)
	local list = {}
	for key in pairs(map) do table.insert(list, key) end
	table.sort(list)
	return list
end

-- Keys ----------------------------------------------------------------------------------------------

local function hostNodeKey(hostKey) return "host:" .. #hostKey .. ":" .. hostKey end
-- Ids are digits only, so the final `#` always separates a host key that itself contains `#`.
local function sessionNodeKey(hostKey, id) return "session:" .. hostKey .. "#" .. tostring(id) end
local function tabNodeKey(hostKey, id) return "tab:" .. hostKey .. "#" .. tostring(id) end
local function paneNodeKey(hostKey, id) return "pane:" .. hostKey .. "#" .. tostring(id) end
local function retainedNodeKey(workId) return "retained:" .. workId end
local function asideKey(tabKey) return "aside:" .. tabKey end
local function sectionKey(kind, hostKey) return "section:" .. kind .. ":" .. (hostKey or "") end

-- Inventory -----------------------------------------------------------------------------------------

function navigation.inventory(raw, options)
	local null, states, closedTabs, canvasOwned = options.null, options.states, options.closedTabs, options.canvasOwned

	local function text(value, fallback)
		return if type(value) == "string" then value else fallback
	end
	local function optionalText(value)
		if value == nil or value == null then return nil end
		assert(type(value) == "string", "Unsupported native text field")
		return if value == "" then nil else value
	end
	local function flag(value)
		if value == nil or value == null then return false end
		assert(type(value) == "boolean", "Unsupported native boolean field")
		return value
	end
	local function optionalId(value)
		if value == nil or value == null then return nil end
		assert(isId(value), "Unsupported native identity")
		return value
	end
	local function array(value, label)
		assert(type(value) == "table" and value ~= null, label .. " unavailable")
		local count = 0
		for key in pairs(value) do
			assert(type(key) == "number" and key >= 1 and key % 1 == 0, label .. " has unsupported shape")
			count += 1
		end
		assert(count == #value, label .. " is not a contiguous list")
		return value
	end

	local nativeHosts = array(raw.hosts, "Hosts")
	local nativeSessions = array(raw.sessions, "Sessions")
	local nativeTabs = array(raw.tabs, "Tabs")
	local nativePanes = array(raw.panes, "Panes")
	local nativeAgents = array(raw.agents, "Agents")
	local nativeCanvases = array(raw.canvases, "Canvases")
	local hosts, membership, sessions, tabs, panes, agents, canvases, allPanes = {}, {}, {}, {}, {}, {}, {}, {}
	local hostOrder, sessionOrder, tabOrder = {}, {}, {}
	local canvasMetadata = {}
	local currentHost, currentSession = nil, nil
	for _, source in ipairs(nativeHosts) do
		assert(type(source) == "table" and isId(source.id) and type(source.state) == "string", "Unsupported host inventory")
		local key = if source.kind == "local" then "local" else optionalText(source.address)
		assert(key ~= nil, "Native host address unavailable")
		hosts[source.id] = { id = source.id, key = key, name = text(source.name, "Host"), state = source.state,
			connected = source.state == "connected", error = if source.state ~= "connected" then "Host " .. source.state else nil }
		table.insert(hostOrder, source.id)
		if flag(source.current) then currentHost = source.id end
		for _, pane in ipairs(array(source.panes, "Host panes")) do
			assert(isId(pane) and (membership[pane] == nil or membership[pane] == source.id), "Ambiguous host membership")
			membership[pane] = source.id
		end
	end
	for _, source in ipairs(nativeSessions) do
		assert(type(source) == "table" and isId(source.id) and isId(source.host) and hosts[source.host], "Unsupported session inventory")
		sessions[source.id] = { id = source.id, host = source.host, name = text(source.name, "Session"),
			locked = source.locked == true, tabCount = softNumber(source.tabs) }
		table.insert(sessionOrder, source.id)
		if flag(source.current) then currentSession = source.id end
	end
	for _, source in ipairs(nativeTabs) do
		assert(type(source) == "table" and isId(source.id) and isId(source.session) and sessions[source.session], "Unsupported tab inventory")
		local focusedPane = optionalId(source.pane)
		tabs[source.id] = { id = source.id, session = source.session, pane = focusedPane,
			name = soft(source.name), title = soft(source.title), position = softNumber(source.position),
			color = soft(source.color), paneCount = softNumber(source.panes), focusedPane = focusedPane }
		table.insert(tabOrder, source.id)
	end
	for _, source in ipairs(nativeCanvases) do
		assert(type(source) == "table" and isId(source.pane) and type(source.owner) == "string" and type(source.about) == "string",
			"Unsupported canvas inventory")
		canvasMetadata[source.pane] = source
		if canvasOwned(source) then canvases[source.pane] = source end
	end
	for _, source in ipairs(nativePanes) do
		assert(type(source) == "table" and isId(source.pane), "Unsupported pane inventory")
		local host = membership[source.pane]
		assert(hosts[host], "Pane host membership is pending")
		local tab = optionalId(source.tab)
		local session = if tab and tabs[tab] then sessions[tabs[tab].session] else nil
		assert(tab == nil or (session and session.host == host) or closedTabs[tab], "Pane session membership is pending")
		local pane = { pane = source.pane, host = host, tab = tab, session = if session then session.id else nil,
			title = text(source.title, "Agent"), sessionName = if session then session.name else "Parked",
			hostName = hosts[host].name, alert = flag(source.alert), parked = flag(source.parked),
			floating = flag(source.floating), startupError = optionalText(source.error), kind = optionalText(source.kind),
			block = optionalText(source.block),
			nativeTitle = soft(source.title), cwd = soft(source.cwd), program = soft(source.program),
			path = soft(source.path), url = soft(source.url), focused = source.focused == true, busy = source.busy == true }
		allPanes[pane.pane] = pane
		if not canvases[pane.pane] then panes[pane.pane] = pane end
	end
	for _, source in ipairs(nativeAgents) do
		assert(type(source) == "table" and isId(source.pane), "Unsupported agent inventory")
		if not canvases[source.pane] then
			assert(panes[source.pane], "Agent pane membership is pending")
			assert(type(source.state) == "string" and states[source.state], "Native agent state unavailable")
			table.insert(agents, { pane = source.pane, state = source.state, deliveryError = optionalText(source.delivery_error) })
		end
	end
	for pane in pairs(canvases) do
		assert(allPanes[pane], "Attention canvas host membership is pending")
	end
	table.sort(agents, function(a, b) return a.pane < b.pane end)
	local focused = optionalId(raw.focused)
	return { now = options.now, ok = true, hosts = hosts, hostOrder = hostOrder, panes = panes, agents = agents,
		allPanes = allPanes, canvases = canvases, canvasMetadata = canvasMetadata,
		tabs = tabs, sessions = sessions, sessionOrder = sessionOrder, tabOrder = tabOrder,
		currentHost = currentHost, currentSession = currentSession, focused = focused }
end

-- Projection ----------------------------------------------------------------------------------------

local function retainedReason(row)
	local reason = row.unavailableReason
	if row.noOpenPane == true or reason == "No open pane" then return "no-open-pane" end
	if type(reason) == "string" and (string.find(reason, "offline", 1, true) or reason == "disconnected") then return "offline" end
	if (type(reason) == "string" and UNVERIFIED_REASONS[reason]) or row.identityKey == nil then return "unverified" end
	if row.orphaned == true and row.retained == true then return "no-open-pane" end
	return "missing"
end

local function conversationLink(row, preferred, proof, routeCount)
	return { workId = row.workId, serial = row.serial, identityKey = row.identityKey,
		disposition = row.disposition or "active", attention = row.attention == true,
		nativeState = row.nativeState or "unknown", reviewRevision = row.reviewRevision,
		setAside = row.disposition == "later", routeCount = routeCount, preferred = preferred, proof = proof }
end

local function newDestination(pane, hostKey, tab, placement)
	local paneKind = pane.kind or "unknown"
	local title, titleSource = clean(pane.nativeTitle), "native"
	if title == nil then title, titleSource = derivedTitle(paneKind, pane), "derived" end
	return { key = paneNodeKey(hostKey, pane.pane), kind = "pane", paneKind = paneKind, hostKey = hostKey, pane = pane.pane,
		tabId = if tab then tab.id else nil, sessionId = if tab then tab.sessionId else nil,
		title = title, titleSource = titleSource, placement = placement, focused = pane.focused == true, current = false,
		path = pane.path, url = pane.url, cwd = pane.cwd, program = pane.program }
end

local function destinationSignature(destination)
	local link = destination.conversation
	return enc("pane", destination.hostKey, destination.pane, destination.tabId, destination.sessionId,
		destination.placement, destination.paneKind, link and link.workId, link and link.serial,
		link and link.identityKey, link and link.disposition, link and link.reviewRevision,
		link and link.preferred, link and link.proof)
end

function navigation.project(data, overlay)
	overlay = overlay or {}
	local identities, pending = overlay.identities or {}, overlay.identityPending or {}
	local hostNodes, hostByKey, hostById = {}, {}, {}
	local sessionById, tabById = {}, {}
	local destinations = {}
	local byKey = {}

	for _, hostId in ipairs(data.hostOrder) do
		local host = data.hosts[hostId]
		local node = { key = hostNodeKey(host.key), kind = "host", hostKey = host.key, id = hostId, name = clean(host.name) or "Host",
			connected = host.connected, state = host.state or (if host.connected then "connected" else "unavailable"),
			sessions = {}, parked = {}, unattached = {} }
		table.insert(hostNodes, node)
		hostByKey[host.key], hostById[hostId] = node, node
	end

	for _, sessionId in ipairs(data.sessionOrder) do
		local source = data.sessions[sessionId]
		local host = hostById[source.host]
		local node = { key = sessionNodeKey(host.hostKey, sessionId), kind = "session", hostKey = host.hostKey, id = sessionId,
			name = clean(source.name) or "Session", current = data.currentSession == sessionId, locked = source.locked == true,
			tabs = {}, empty = true }
		table.insert(host.sessions, node)
		sessionById[sessionId] = node
	end

	-- Tabs follow native position inside their session; without a complete set of positions the native tab order stands.
	local pendingTabs = {}
	for ordinal, tabId in ipairs(data.tabOrder) do
		local source = data.tabs[tabId]
		local session = sessionById[source.session]
		local list = pendingTabs[session.id]
		if list == nil then list = {}; pendingTabs[session.id] = list end
		table.insert(list, { source = source, ordinal = ordinal })
	end
	for sessionId, list in pairs(pendingTabs) do
		local positioned = true
		for _, entry in ipairs(list) do
			if entry.source.position == nil then positioned = false; break end
		end
		if positioned then
			table.sort(list, function(a, b)
				if a.source.position ~= b.source.position then return a.source.position < b.source.position end
				return a.ordinal < b.ordinal
			end)
		end
		local session = sessionById[sessionId]
		local host = hostByKey[session.hostKey]
		for index, entry in ipairs(list) do
			local source = entry.source
			local node = { key = tabNodeKey(host.hostKey, source.id), kind = "tab", hostKey = host.hostKey, id = source.id,
				sessionId = sessionId, name = clean(source.name), position = source.position or index, color = source.color,
				destinations = {}, flattened = false, focusedPane = source.focusedPane, nativeTitle = source.title }
			table.insert(session.tabs, node)
			tabById[source.id] = node
		end
		session.empty = false
	end

	-- Destinations: every non-owned native pane exactly once, in tab order else ascending pane id.
	local paneIds = sortedKeys(data.panes)
	for _, paneId in ipairs(paneIds) do
		local pane = data.panes[paneId]
		local host = hostById[pane.host]
		local tab = if pane.tab ~= nil then tabById[pane.tab] else nil
		local destination
		if pane.parked then
			destination = newDestination(pane, host.hostKey, nil, "parked")
			table.insert(host.parked, destination)
		elseif tab ~= nil then
			destination = newDestination(pane, host.hostKey, tab, if pane.floating then "floating" else "tiled")
		else
			destination = newDestination(pane, host.hostKey, nil, "unattached")
			table.insert(host.unattached, destination)
		end
		destination.current = data.focused == paneId
		destinations[paneId] = destination
	end
	for _, paneId in ipairs(paneIds) do
		local destination = destinations[paneId]
		if destination.placement == "tiled" then
			table.insert(tabById[destination.tabId].destinations, destination)
		end
	end
	for _, paneId in ipairs(paneIds) do
		local destination = destinations[paneId]
		if destination.placement == "floating" then
			table.insert(tabById[destination.tabId].destinations, destination)
		end
	end

	-- Conversation overlay. Preferred routes claim first (lowest serial wins a contested pane), then
	-- additional proven routes join; a record never merges with another by title.
	local ordered = {}
	for _, row in ipairs(overlay.rows or {}) do table.insert(ordered, row) end
	table.sort(ordered, function(a, b) return a.serial < b.serial end)
	local claimed, linked, unrouted = {}, {}, {}
	for _, row in ipairs(ordered) do
		local leaf = if row.pane ~= nil then destinations[row.pane] else nil
		if leaf == nil then
			table.insert(unrouted, { row = row, reason = retainedReason(row) })
		elseif claimed[row.pane] ~= nil then
			table.insert(unrouted, { row = row, reason = "unverified" })
		else
			claimed[row.pane] = row
			table.insert(linked, { row = row, leaves = { leaf } })
		end
	end
	local provenPanes = {}
	for _, paneId in ipairs(paneIds) do
		local key = identities[paneId]
		if key ~= nil and not pending[paneId] then
			local list = provenPanes[key]
			if list == nil then list = {}; provenPanes[key] = list end
			table.insert(list, paneId)
		end
	end
	for _, entry in ipairs(linked) do
		local key = entry.row.identityKey
		for _, paneId in ipairs(if key ~= nil then provenPanes[key] or {} else {}) do
			if claimed[paneId] == nil then
				claimed[paneId] = entry.row
				table.insert(entry.leaves, destinations[paneId])
			end
		end
	end
	local counts = { hosts = #hostNodes, sessions = #data.sessionOrder, tabs = #data.tabOrder, destinations = #paneIds,
		conversations = #linked, retained = #unrouted, setAside = 0 }
	for _, entry in ipairs(linked) do
		local row, routes = entry.row, #entry.leaves
		for index, leaf in ipairs(entry.leaves) do
			local proof = "proven"
			if index == 1 then
				local key = row.identityKey
				if key == nil or identities[leaf.pane] ~= key or pending[leaf.pane] then proof = "unproven" end
			end
			leaf.conversation = conversationLink(row, index == 1, proof, routes)
		end
		if row.disposition == "later" then counts.setAside += 1 end
	end

	local retained = {}
	for _, entry in ipairs(unrouted) do
		local row = entry.row
		table.insert(retained, { key = retainedNodeKey(row.workId), kind = "retained", workId = row.workId, serial = row.serial,
			title = clean(row.title) or "Saved conversation", sessionName = clean(row.sessionName), hostName = clean(row.hostName),
			hostKey = row.hostKey, disposition = row.disposition or "active", retainedRecord = row.retained == true,
			reason = entry.reason, identityKey = row.identityKey, reviewRevision = row.reviewRevision })
	end

	-- Finalize: tab titles, flattening, signatures, key index.
	local parts = {}
	local function register(node)
		byKey[node.key] = node
		table.insert(parts, node.signature)
	end
	local coverage = {}
	for _, host in ipairs(hostNodes) do
		for _, session in ipairs(host.sessions) do
			for _, tab in ipairs(session.tabs) do
				local first = tab.destinations[1]
				local title = tab.name
				if title == nil and tab.focusedPane ~= nil and not data.canvases[tab.focusedPane] then
					title = clean(tab.nativeTitle)
				end
				tab.title = title or ("Tab " .. tostring(tab.position))
				tab.nativeTitle = nil
				tab.flattened = tab.name == nil and #tab.destinations == 1
					and not (first.conversation ~= nil and first.conversation.setAside)
				local paneList = {}
				for _, destination in ipairs(tab.destinations) do
					destination.signature = destinationSignature(destination)
					table.insert(paneList, destination.pane)
				end
				tab.signature = enc("tab", tab.hostKey, tab.id, tab.sessionId, table.concat(paneList, ","))
			end
			session.signature = enc("session", session.hostKey, session.id)
		end
		for _, list in ipairs({ host.parked, host.unattached }) do
			for _, destination in ipairs(list) do destination.signature = destinationSignature(destination) end
		end
		host.signature = enc("host", host.hostKey, host.id, host.connected)
		table.insert(coverage, { hostKey = host.hostKey, hostId = host.id, name = host.name,
			connected = host.connected, state = host.state })
	end
	for _, node in ipairs(retained) do
		node.signature = enc("retained", node.workId, node.serial, node.identityKey, node.disposition,
			node.reviewRevision, node.reason, node.hostKey)
	end
	for _, host in ipairs(hostNodes) do
		register(host)
		for _, session in ipairs(host.sessions) do
			register(session)
			for _, tab in ipairs(session.tabs) do
				register(tab)
				for _, destination in ipairs(tab.destinations) do register(destination) end
			end
		end
		for _, destination in ipairs(host.parked) do register(destination) end
		for _, destination in ipairs(host.unattached) do register(destination) end
	end
	for _, node in ipairs(retained) do register(node) end

	return { signature = digest(table.concat(parts, "\n")), hosts = hostNodes, retained = retained, counts = counts,
		byKey = byKey, byPane = destinations, currentPane = if destinations[data.focused] then data.focused else nil,
		coverage = coverage }
end

-- Rows ----------------------------------------------------------------------------------------------

local function kindLabel(destination)
	if destination.paneKind == "file" and destination.path ~= nil and string.sub(destination.path, 1, 5) == "note:" then
		return "Note"
	end
	return KIND_LABELS[destination.paneKind] or "Pane"
end

local function markers(destination, host)
	local list = {}
	local link = destination.conversation
	if link ~= nil and DISPOSITION_MARKERS[link.disposition] then table.insert(list, DISPOSITION_MARKERS[link.disposition]) end
	if destination.placement == "parked" then table.insert(list, "Parked") end
	if destination.placement == "floating" then table.insert(list, "Floating") end
	if host ~= nil and not host.connected then table.insert(list, "Offline") end
	return list
end

local function leafKey(destination)
	local link = destination.conversation
	if link == nil then return destination.key end
	if link.preferred then return "r" .. tostring(link.serial) end
	return "r" .. tostring(link.serial) .. "@" .. tostring(destination.pane)
end

local function paneRef(destination)
	local link = destination.conversation
	return { kind = "pane", hostKey = destination.hostKey, id = destination.pane, pane = destination.pane,
		tab = destination.tabId, session = destination.sessionId, workId = if link then link.workId else nil,
		key = destination.key }
end

local function destinationCount(host)
	local count = #host.parked + #host.unattached
	for _, session in ipairs(host.sessions) do
		for _, tab in ipairs(session.tabs) do count += #tab.destinations end
	end
	return count
end

local function hasContent(host)
	return #host.sessions > 0 or #host.parked > 0 or #host.unattached > 0
end

function navigation.rows(snapshot, ui)
	ui = ui or {}
	local collapsed, asideOpen = ui.collapsed or {}, ui.setAsideOpen or {}
	local rows = {}
	local contentful = 0
	for _, host in ipairs(snapshot.hosts) do
		if hasContent(host) then contentful += 1 end
	end
	local showHosts = contentful > 1

	local function push(row)
		row.depth = math.min(row.depth, MAX_DEPTH)
		table.insert(rows, row)
	end

	local function leafRow(destination, host, depth)
		local label = { kindLabel(destination) }
		for _, marker in ipairs(markers(destination, host)) do table.insert(label, marker) end
		local availability = nil
		if not host.connected then availability = "offline"
		elseif destination.conversation ~= nil and destination.conversation.proof ~= "proven" then availability = "unverified" end
		push({ key = leafKey(destination), kind = "leaf", depth = depth, title = destination.title,
			context = table.concat(label, " · "), ref = paneRef(destination), signature = destination.signature,
			expandable = false, expanded = false,
			leaf = { paneKind = destination.paneKind, placement = destination.placement, current = destination.current,
				focused = destination.focused, conversation = destination.conversation, availability = availability } })
	end

	local function sectionRow(kind, title, host, count, depth)
		local key = sectionKey(kind, if host then host.hostKey else nil)
		local open = not collapsed[key]
		push({ key = key, kind = "section", depth = depth, title = title, ref = { kind = "section", hostKey = if host then host.hostKey else nil },
			signature = enc("section", key, count), expandable = true, expanded = open, count = count })
		return open
	end

	for _, host in ipairs(snapshot.hosts) do
		if not hasContent(host) then continue end
		local depth = 0
		local open = true
		if showHosts then
			open = not collapsed[host.key]
			push({ key = host.key, kind = "host", depth = 0, title = host.name,
				context = if host.connected then nil else "Host " .. host.state,
				ref = { kind = "host", hostKey = host.hostKey, id = host.id, key = host.key }, signature = host.signature,
				expandable = true, expanded = open, count = if host.connected then destinationCount(host) else nil })
			depth = 1
		end
		if not open then continue end
		for _, session in ipairs(host.sessions) do
			local sessionOpen = not collapsed[session.key]
			local sessionCount = nil
			if host.connected then
				sessionCount = 0
				for _, tab in ipairs(session.tabs) do sessionCount += #tab.destinations end
			end
			push({ key = session.key, kind = "session", depth = depth, title = session.name,
				context = if session.current then "Current" else nil,
				ref = { kind = "session", hostKey = session.hostKey, id = session.id, session = session.id, key = session.key },
				signature = session.signature, expandable = not session.empty, expanded = sessionOpen and not session.empty,
				count = sessionCount, empty = session.empty })
			if not sessionOpen then continue end
			for _, tab in ipairs(session.tabs) do
				if tab.flattened then
					leafRow(tab.destinations[1], host, depth + 1)
					continue
				end
				local tabOpen = not collapsed[tab.key]
				local visible, deferred, deferredWork, deferredCount = {}, {}, {}, 0
				for _, destination in ipairs(tab.destinations) do
					local link = destination.conversation
					if link ~= nil and link.setAside then
						table.insert(deferred, destination)
						if not deferredWork[link.workId] then deferredWork[link.workId] = true; deferredCount += 1 end
					else
						table.insert(visible, destination)
					end
				end
				push({ key = tab.key, kind = "tab", depth = depth + 1, title = tab.title,
					ref = { kind = "tab", hostKey = tab.hostKey, id = tab.id, tab = tab.id, session = tab.sessionId, key = tab.key },
					signature = tab.signature, expandable = #tab.destinations > 0, expanded = tabOpen and #tab.destinations > 0,
					count = if host.connected then #tab.destinations else nil,
					setAsideCount = if deferredCount > 0 then deferredCount else nil, empty = #tab.destinations == 0 })
				if not tabOpen then continue end
				for _, destination in ipairs(visible) do leafRow(destination, host, depth + 2) end
				if deferredCount > 0 then
					local expanded = asideOpen[tab.key] == true
					push({ key = asideKey(tab.key), kind = "aside", depth = depth + 2, title = "Set aside " .. deferredCount,
						ref = { kind = "aside", hostKey = tab.hostKey, tab = tab.id, session = tab.sessionId, key = tab.key },
						signature = enc("aside", tab.signature, deferredCount, expanded), expandable = true, expanded = expanded,
						count = deferredCount, setAsideCount = deferredCount })
					if expanded then
						for _, destination in ipairs(deferred) do leafRow(destination, host, depth + 3) end
					end
				end
			end
		end
		for _, section in ipairs({ { "parked", "Parked", host.parked }, { "unattached", "Unattached", host.unattached } }) do
			local list = section[3]
			if #list > 0 and sectionRow(section[1], section[2], host, #list, depth) then
				for _, destination in ipairs(list) do leafRow(destination, host, depth + 1) end
			end
		end
	end

	if #snapshot.retained > 0 then
		if sectionRow("retained", "Saved conversations", nil, #snapshot.retained, 0) then
			for _, node in ipairs(snapshot.retained) do
				local context = {}
				if node.hostName then table.insert(context, node.hostName) end
				if node.sessionName then table.insert(context, node.sessionName) end
				table.insert(context, REASON_MARKERS[node.reason])
				if DISPOSITION_MARKERS[node.disposition] then table.insert(context, DISPOSITION_MARKERS[node.disposition]) end
				push({ key = node.key, kind = "retained", depth = 1, title = node.title, context = table.concat(context, " · "),
					ref = { kind = "retained", hostKey = node.hostKey, workId = node.workId, key = node.key },
					signature = node.signature, expandable = false, expanded = false })
			end
		end
	end
	return { rows = rows, total = #rows }
end

-- Search --------------------------------------------------------------------------------------------

function navigation.searchItems(snapshot)
	local items = {}
	local multiHost = #snapshot.hosts > 1

	local function qualify(parts, host)
		if multiHost or (host ~= nil and host.hostKey ~= "local") then table.insert(parts, host.name) end
		return table.concat(parts, " · ")
	end

	local function add(node, kind, suffix, parts, host, detail, ref)
		table.insert(items, { id = node.key, label = bounded(qualify(parts, host), LABEL_LIMIT), detail = bounded(detail, DETAIL_LIMIT),
			kind = kind, ref = ref, signature = node.signature, suffix = suffix })
	end

	local function addDestination(destination, host, tab, session)
		local parts = { destination.title }
		if destination.placement == "parked" then table.insert(parts, "Parked")
		elseif tab == nil then table.insert(parts, "Unattached")
		else
			table.insert(parts, tab.title)
			table.insert(parts, session.name)
		end
		local detail = { kindLabel(destination) }
		for _, marker in ipairs(markers(destination, host)) do table.insert(detail, marker) end
		if destination.placement == "unattached" then table.insert(detail, "Unattached") end
		add(destination, "pane", destination.pane, parts, host, table.concat(detail, " · "), paneRef(destination))
	end

	for _, host in ipairs(snapshot.hosts) do
		for _, session in ipairs(host.sessions) do
			add(session, "session", session.id, { session.name }, host, if session.empty then "Session · Empty" else "Session",
				{ kind = "session", hostKey = session.hostKey, id = session.id, session = session.id, key = session.key })
			for _, tab in ipairs(session.tabs) do
				if tab.name ~= nil then
					add(tab, "tab", tab.id, { tab.title, session.name }, host, "Tab",
						{ kind = "tab", hostKey = tab.hostKey, id = tab.id, tab = tab.id, session = tab.sessionId, key = tab.key })
				end
				for _, destination in ipairs(tab.destinations) do addDestination(destination, host, tab, session) end
			end
		end
		for _, destination in ipairs(host.parked) do addDestination(destination, host, nil, nil) end
		for _, destination in ipairs(host.unattached) do addDestination(destination, host, nil, nil) end
	end
	for _, node in ipairs(snapshot.retained) do
		local parts, detail = { node.title }, { "Saved conversation", REASON_MARKERS[node.reason] }
		if node.sessionName then table.insert(parts, node.sessionName) end
		if node.hostName and (multiHost or node.hostKey ~= "local") then table.insert(parts, node.hostName) end
		if DISPOSITION_MARKERS[node.disposition] then table.insert(detail, DISPOSITION_MARKERS[node.disposition]) end
		table.insert(items, { id = node.key, label = bounded(table.concat(parts, " · "), LABEL_LIMIT),
			detail = bounded(table.concat(detail, " · "), DETAIL_LIMIT), kind = "retained",
			ref = { kind = "retained", hostKey = node.hostKey, workId = node.workId, key = node.key },
			signature = node.signature, suffix = node.serial })
	end

	-- The native picker filters on the label alone, so equal labels get a final disambiguator.
	local counts = {}
	for _, item in ipairs(items) do counts[item.label] = (counts[item.label] or 0) + 1 end
	local used = {}
	for _, item in ipairs(items) do
		if counts[item.label] > 1 then item.label = item.label .. " #" .. tostring(item.suffix) end
		local label, attempt = item.label, 1
		while used[label] do
			attempt += 1
			label = item.label .. " (" .. attempt .. ")"
		end
		item.label, used[label] = label, true
		item.suffix = nil
	end
	return items
end

-- Lookup --------------------------------------------------------------------------------------------

function navigation.resolve(snapshot, key)
	return snapshot.byKey[key]
end

function navigation.locate(snapshot, pane)
	local destination = snapshot.byPane[pane]
	return if destination then destination.key else nil
end

function navigation.signatureMatches(snapshot, key, signature)
	local node = snapshot.byKey[key]
	return node ~= nil and signature ~= nil and node.signature == signature
end

-- Row keys to open, outermost first, so `Reveal current` can expand everything above a destination.
function navigation.ancestors(snapshot, key)
	local node = snapshot.byKey[key]
	if node == nil or node.kind == "host" then return {} end
	if node.kind == "retained" then return { sectionKey("retained", nil) } end
	if node.kind == "session" then return { hostNodeKey(node.hostKey) } end
	if node.kind == "tab" then return { hostNodeKey(node.hostKey), sessionNodeKey(node.hostKey, node.sessionId) } end
	local chain = { hostNodeKey(node.hostKey) }
	if node.placement == "parked" or node.placement == "unattached" then
		table.insert(chain, sectionKey(node.placement, node.hostKey))
		return chain
	end
	local tabKey = tabNodeKey(node.hostKey, node.tabId)
	table.insert(chain, sessionNodeKey(node.hostKey, node.sessionId))
	table.insert(chain, tabKey)
	if node.conversation ~= nil and node.conversation.setAside then table.insert(chain, asideKey(tabKey)) end
	return chain
end

return navigation
