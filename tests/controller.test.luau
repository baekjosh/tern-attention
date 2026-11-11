local bootstrap = require("../window")

local nativeCanvas = require("./native_canvas")
local copy = nativeCanvas.copy

-- What native `tern.kv.get` returns is decoded JSON: every array (empty or not, never an object) carries a
-- protected metatable, so `table.clone` or `setmetatable` on a stored array raises exactly as it does natively.
-- A plain deep copy would let a parser that clones stored arrays pass here and fail on a real Tern.
local function decoded(value)
	if type(value) ~= "table" then return value end
	local result, count = {}, 0
	for key, item in pairs(value) do
		result[key] = decoded(item)
		count += 1
	end
	if getmetatable(value) == false or (#value > 0 and #value == count) then
		setmetatable(result, { __metatable = false })
	end
	return result
end

local function rowAction(node, op)
	op = op or "open"
	local click = node.p and node.p.actions and node.p.actions.click
	if type(click) == "string" and string.sub(click, 1, #op + 1) == op .. ":" then return click end
	for _, child in node.c or {} do
		local action = rowAction(child, op)
		if action then return action end
	end
	return nil
end


local function keyedAction(node, key)
	if node.p and node.p.hidden then return nil end
	if node.p and node.p.key == key and node.p.actions then return node.p.actions.click end
	for _, child in node.c or {} do
		local found = keyedAction(child, key)
		if found then return found end
	end
	return nil
end


-- A left or right rail draws the two-region stack (a split root: attention sections over Workspace); a bottom rail
-- keeps the strip with one selected section. These helpers address either shape, so a test names the section it is
-- looking at and never the shape. `world.viewing` is the section the test last asked to see: the stack shows all of
-- them at once, where the strip has to select one.
local function isStack(view) return view.k == "split" end

local function descend(node, ...)
	for _, key in { ... } do
		if node == nil then return nil end
		node = nativeCanvas.childAt(node, key)
	end
	return node
end

-- The keyed `rows` node of one section: the strip's single list, or that section's list inside the stack.
local function sectionRows(world, pane, section)
	local view = world.canvases[pane].view
	if not isStack(view) then return (nativeCanvas.childAt(view, "rows")) end
	section = section or world.viewing
	if section == "workspace" then return descend(view, "bottom", "rows") end
	return descend(view, "top", "stack", section, "rows")
end

-- What `rowAction` and `keyedAction` search for the section being looked at: the whole strip, or one stack list.
local function shown(world, pane)
	local view = world.canvases[pane].view
	if isStack(view) then return sectionRows(world, pane) end
	return view
end

local function coverageOf(view)
	if isStack(view) then return descend(view, "top", "coverage") end
	return (nativeCanvas.childAt(view, "coverage"))
end

-- The node carrying one queue's label and count, and the key of its label child: a strip tab, or a stack section header.
local function queueHead(world, pane, queue)
	local view = world.canvases[pane].view
	if isStack(view) then return descend(view, "top", "stack", queue, "head", "toggle"), "title" end
	return descend(view, "header", "queues", queue), "label"
end

local function queueCount(world, pane, queue)
	return nativeCanvas.childAt((queueHead(world, pane, queue)), "count").p.text
end

local function queueLabel(world, pane, queue)
	local head, labelKey = queueHead(world, pane, queue)
	return nativeCanvas.childAt(head, labelKey).p.text .. " · " .. nativeCanvas.childAt(head, "count").p.text
end

-- The strip's header parts: queue tabs, tools and the current-location line. The stack has no tabs; its tools and
-- location sit in the attention region and the Workspace head.
local function headerPart(world, pane, key)
	local view = world.canvases[pane].view
	if isStack(view) then
		if key == "location" then return descend(view, "bottom", "head", "line", "location") end
		if key == "tools" then return descend(view, "top", "tools", "buttons") end
		error("a stack has no header part named " .. key)
	end
	return (nativeCanvas.childAt(nativeCanvas.childAt(view, "header"), key))
end

local SECTION_NAMES = { attention = true, working = true, workspace = true }

-- Only the native boundary is fake; controller, model, view, and layout execute unchanged. The fixture opens rails
-- on the left unless a test names another default position, so the layout shapes read below stay stable; each edge
-- has its own placement tests further down.
local function native(enabled, os, position)
	local world = { now = 0, utcShift = 0, timers = {}, commands = {}, handlers = {}, warnings = {}, toasts = {},
		files = {}, directories = {}, fileWrites = 0, failWrite = false, nativeWrites = 0, inventoryReads = 0,
		prefs = { schema = 4, enabled = enabled, owner = if enabled then "desktop" else nil,
			defaults = { position = position or "left", shares = { left = {}, bottom = {}, right = {} }, hidden = {} },
			instances = {}, uiByWindow = {} },
		canvases = {}, opens = {}, attempts = 0, focusWrites = 0, canvasSets = 0, canvasSetsByPane = {}, nextPane = 90,
		transcripts = {},
		root = { pane = 10 }, focused = 10, failOpen = nil, agentState = "waiting_input", agentAlert = false,
		contentInspectionUnavailable = false, abortInventory = false, savedTriage = nil, failTriageWrite = false,
		triageWrites = 0, encoded = {}, encodingCount = 0, keys = {}, pluginKeys = {}, binds = {},
		failKeys = false, failBind = false, rejectBind = false, viewing = "attention" }
	world.processes, world.identityFiles, world.holdIdentity, world.inspections = {}, {}, false, 0
	-- The phone queue snapshot (`phone.json`) is kept apart from diagnostics files so neither counts as the other.
	world.phoneBytes, world.phoneWrites, world.failPhoneWrite, world.linkHandler = nil, 0, false, nil
	world.sourceProcesses, world.sourceRecords, world.prompts = {}, {}, {}
	-- The bundle and a PATH copy both exist, so the default world proves the version-matched bundle is preferred.
	world.cliFiles = { ["/Applications/Tern.app/Contents/MacOS/tern"] = true, ["/opt/tern/bin/tern"] = true }
	world.env, world.cliProbes, world.bundleProbes = { PATH = "/usr/bin::relative/bin:/opt/tern/bin" }, {}, 0
	local cx = { hosts = {}, sessions = {}, session = {}, agents = {}, canvas = {}, layout = {}, actions = {}, settings = {},
		docs = {}, browser = {} }
	world.settingsWrites, world.preferenceWrites, world.preferenceReads = 0, 0, 0
	-- Native visibility settings (tabs_autohide and kin) belong to the user: any write is a defect.
	function cx.settings:set() world.settingsWrites += 1; error("native settings must never be written") end
	function cx.settings:set_many() world.settingsWrites += 1; error("native settings must never be written") end
	world.tabs = { [3] = { session = 2, host = 1, content = 10 } }
	world.layouts, world.membership, world.parked, world.floating = {}, { [10] = 3 }, {}, {}
	world.replicaAt, world.replicaDelay, world.layoutWrites, world.closes = {}, 0, 0, {}
	world.parks = {}
	-- Window canvas metadata (list and get share one replica) may lag the session's pane inventory.
	world.metadataAt, world.metadataDelay = {}, 0
	-- Restart-restored canvas panes: in session inventory only, absent from cx.canvas list and get, and
	-- captured host-side as an empty-owner header with no body.
	world.restored = {}
	world.captures, world.captureLaunches, world.holdCaptures, world.captureOverride = {}, 0, false, nil
	world.paneHosts = { [10] = 1 }
	world.currentHost, world.currentSession = 1, 2
	world.sessions = { [2] = { host = 1, name = "Work" } }
	world.sessionOrder, world.sessionSwitches, world.pickers, world.vm = { 2 }, {}, {}, 1
	world.zoomed, world.floats, world.failMove = false, {}, false
	world.hostStates, world.layoutWritesByTab = {}, {}
	-- Native facts the workspace navigator reads, panes without a tab, the native creation and management calls,
	-- and a record of every call the plugin must never make.
	world.paneInfo, world.loose, world.hostSwitches, world.actionRuns = {}, {}, {}, {}
	-- The model each agent pane reports in the native agent list; a pane with no entry reports none.
	world.models = {}
	world.newTabs, world.noteCreates, world.fileOpens, world.browserCalls = {}, {}, {}, {}
	world.sessionCreates, world.renames, world.orders, world.ignoreOrders = {}, {}, {}, false
	world.nextTab, world.nextNativePane, world.nextSession = 40, 200, 40
	local function strip(tree, pane)
		if not tree then return nil end
		if tree.pane then return if tree.pane == pane then nil else copy(tree) end
		local left, right = strip(tree[1], pane), strip(tree[2], pane)
		if not left then return right end
		if not right then return left end
		return { split = tree.split, ratio = tree.ratio, [1] = left, [2] = right }
	end
	local function has(tree, pane)
		return tree ~= nil and (tree.pane == pane or (tree.pane == nil and (has(tree[1], pane) or has(tree[2], pane))))
	end
	local function insert(tree, pane, target, direction, share)
		if tree.pane then
			if tree.pane ~= target then return tree end
			local before = direction == "left" or direction == "up"
			local first = if share then (if before then share else 1 - share) else 0.5
			return { split = if direction == "left" or direction == "right" then "right" else "down", ratio = first,
				[1] = if before then { pane = pane } else tree, [2] = if before then tree else { pane = pane } }
		end
		tree[1], tree[2] = insert(tree[1], pane, target, direction, share), insert(tree[2], pane, target, direction, share)
		return tree
	end
	local function root(tab) return if tab == 3 then world.root else world.layouts[tab] end
	local function setRoot(tab, value)
		if tab == 3 then world.root = value else world.layouts[tab] = value end
	end
	local function visible(pane) return not world.replicaAt[pane] or world.now >= world.replicaAt[pane] end
	local function described(pane)
		return visible(pane) and (not world.metadataAt[pane] or world.now >= world.metadataAt[pane])
	end
	function world:addTab(tab, pane, host, session)
		self.tabs[tab] = { session = session or 2, host = host or 1, content = pane }
		local sessionId = session or 2
		if not self.sessions[sessionId] then
			self.sessions[sessionId] = { host = host or 1, name = "Work" }
			table.insert(self.sessionOrder, sessionId)
		end
		self.layouts[tab], self.membership[pane] = { pane = pane }, tab
		self.paneHosts[pane] = host or 1
	end
	function world:switch(tab)
		local info = self.tabs[tab]
		self.currentHost, self.currentSession, self.focused = info.host, info.session, info.content
		self.handlers.focus({ pane = self.focused }, cx)
	end
	-- A native event carries the context of the call that caused it: inside an await callback, that call's fresh one.
	function world:emit(kind, event) self.handlers[kind](event, self.awaitContext or cx) end
	function world:closePane(pane)
		local tab = self.membership[pane]
		if tab then setRoot(tab, strip(root(tab), pane)) end
		self.canvases[pane], self.membership[pane], self.parked[pane], self.floating[pane] = nil, nil, nil, nil
		self.restored[pane] = nil
		if tab and self.tabs[tab] and self.tabs[tab].content == pane then self.tabs[tab].content = nil end
		self:emit("pane_closed", { pane = pane })
	end
	local sdk = { json = { null = {} }, kv = {}, log = {}, fs = {}, process = {}, route = {},
		runtime = { os = os or "macos" },
		plugin = { dir = "/native/attention", data = "/native/attention-data" } }
	function sdk.json.array(value) return setmetatable(value or {}, { __metatable = false }) end
	-- The native encoder is trusted; capture its input rather than reimplementing JSON. Like the native encoder, equal
	-- content encodes to the same text: the token is a canonical (key-sorted) rendering of the value.
	local function canonical(value, depth)
		assert(depth < 64, "fake JSON nesting too deep")
		if type(value) ~= "table" then return type(value):sub(1, 1) .. tostring(value) end
		local keys = {}
		for key in value do table.insert(keys, key) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, key in keys do table.insert(parts, tostring(key) .. "=" .. canonical(value[key], depth + 1)) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	function sdk.json.encode(value)
		world.encodingCount += 1
		local token = "native-json:" .. canonical(value, 0)
		world.encoded[token] = copy(value)
		return token
	end
	function sdk.json.decode(value)
		assert(world.encoded[value], "malformed native JSON")
		return copy(world.encoded[value])
	end
	function world:identityDocument()
		local panes = {}
		for pane in self.membership do
			table.insert(panes, { pane = pane, omp_session_file = self.identityFiles[pane],
				identity = { hops = { { principal = "operator", method = "local", from = "",
					host = "desktop", user = "operator" } } } })
		end
		return { panes = panes }
	end
	function world:completeIdentity(index, result, options)
		local request = self.processes[index or #self.processes]
		assert(request and request.callback, "identity acquisition registers a native callback")
		if request.vm ~= self.vm then return end
		local fresh = { hosts = cx.hosts, sessions = cx.sessions, session = cx.session, agents = cx.agents,
			canvas = cx.canvas, layout = cx.layout, actions = cx.actions, window_key = cx.window_key,
			toast = cx.toast, pick = cx.pick, prompt = cx.prompt }
		self.awaitContext = fresh
		request.callback(result or { status = 0, stdout = sdk.json.encode(request.document), stderr = "", timed_out = false },
			if options and options.noContext then nil else fresh)
		self.awaitContext = nil
	end
	-- What `tern capture --surfaces` prints for the pane right now: a JSON header line, then the body.
	function world:captureResult(pane)
		local override = self.captureOverride
		if override == "error" then return { status = 1, stdout = "", stderr = "tern capture: no block", timed_out = false } end
		if override == "timeout" then return { status = -1, stdout = "", stderr = "", timed_out = true } end
		if override == "malformed" then return { status = 0, stdout = "{\"v\":1,\n", stderr = "", timed_out = false } end
		local canvas, header, body = self.canvases[pane], nil, ""
		if canvas then
			header, body = { v = 1, owner = canvas.owner, title = canvas.title, about = canvas.about }, "Attention\nP0\n"
		elseif self.restored[pane] then
			header = { v = 1, owner = "", title = "Canvas", about = "" }
		else
			return { status = 1, stdout = "", stderr = "tern capture: no block", timed_out = false }
		end
		if override == "foreign" then header.owner, header.about = "notes", "notes:board"
		elseif override == "body" then body = "stale surface text\n"
		elseif override == "oversized" then body = string.rep("x", 70000) end
		return { status = 0, stdout = sdk.json.encode(header) .. "\n" .. body, stderr = "", timed_out = false }
	end
	function world:completeCapture(index)
		local request = self.captures[index or #self.captures]
		assert(request and request.callback, "canvas capture registers a native callback")
		if request.vm ~= self.vm or request.completed then return end
		request.completed = true
		local fresh = { hosts = cx.hosts, sessions = cx.sessions, session = cx.session, agents = cx.agents,
			canvas = cx.canvas, layout = cx.layout, actions = cx.actions, window_key = cx.window_key,
			toast = cx.toast, pick = cx.pick, prompt = cx.prompt }
		self.awaitContext = fresh
		request.callback(self:captureResult(request.pane), fresh)
		self.awaitContext = nil
	end
	function sdk.process.run(argv, options, callback)
		if argv[2] == "/native/attention/source_facts.py" then
			assert(argv[1] == "/usr/bin/python3" and #argv == 2 and type(options.stdin) == "string"
				and options.timeout_ms > 0 and options.timeout_ms <= 8000,
				"source/header/date helper uses installed absolute assets, JSON stdin and finite native deadline")
			local input = sdk.json.decode(options.stdin)
			local interactive = string.sub(input.requestId, 1, 12) == "interactive:"
			for _, active in ipairs(world.sourceProcesses) do
				assert(active.vm ~= world.vm or active.completed or world.now >= active.at + active.timeout
					or active.interactive ~= interactive,
					"one finite interactive header and one ordinary helper may run concurrently")
			end
			assert(not interactive or input.op == "header", "only navigation header proofs use the interactive lane")
			local request = { input = copy(input), callback = callback, vm = world.vm, at = world.now,
				timeout = options.timeout_ms, interactive = interactive }
			table.insert(world.sourceProcesses, request)
			local index = #world.sourceProcesses
			if not world.holdSources and not (input.op == "header" and world.holdHeaders) then
				sdk.timer(0, function() world:completeSource(index) end)
			end
			return
		end
		if argv[2] == "capture" then
			assert(#argv == 6 and string.sub(argv[1], 1, 1) == "/" and world.cliFiles[argv[1]] and argv[3] == "--window"
				and argv[4] == "desktop" and string.match(argv[5], "^%d+$") and argv[6] == "--surfaces",
				"canvas capture spawns an existing absolute CLI with the exact window, pane and surfaces arguments")
			assert(options.timeout_ms > 0 and options.timeout_ms <= 3000, "canvas capture has a native process deadline")
			for _, active in world.captures do
				assert(active.vm ~= world.vm or active.completed, "at most one canvas capture runs at a time")
			end
			world.captureLaunches += 1
			if world.captureOverride == "spawn" then error("native spawn unavailable") end
			local request = { callback = callback, pane = tonumber(argv[5]), vm = world.vm, argv = copy(argv) }
			table.insert(world.captures, request)
			local index = #world.captures
			if not world.holdCaptures then sdk.timer(0, function() world:completeCapture(index) end) end
			return
		end
		assert(#argv == 5 and string.sub(argv[1], 1, 1) == "/" and world.cliFiles[argv[1]] and argv[2] == "inspect"
			and argv[3] == "--json" and argv[4] == "--window" and argv[5] == "desktop",
			"inspection spawns an existing absolute CLI with the exact window argument array")
		assert(options.timeout_ms > 0 and options.timeout_ms <= 3000, "inspection has a native process deadline")
		world.inspections += 1
		if world.failIdentitySpawn then error("native spawn unavailable") end
		local request = { callback = callback, document = world:identityDocument(), vm = world.vm,
			argv = copy(argv), at = world.now }
		table.insert(world.processes, request)
		local index = #world.processes
		if not world.holdIdentity then sdk.timer(0, function() world:completeIdentity(index) end) end
	end
	function cx:window_key()
		assert(not world.awaitContext or self == world.awaitContext, "await callbacks must use their fresh native context")
		return "desktop"
	end
	function cx:toast(kind, title, message) table.insert(world.toasts, { kind = kind, title = title, message = message }) end
	function cx:pick(options)
		local picker = { options = copy(options), vm = world.vm, context = self }
		table.insert(world.pickers, picker)
		return { kind = "pick", id = #world.pickers, next = function(_self, callback) picker.callback = callback end }
	end
	function world:choose(index, failure)
		local picker = self.pickers[#self.pickers]
		assert(picker and picker.callback, "native picker must register its asynchronous completion")
		if picker.vm ~= self.vm then return end
		local fresh = { hosts = cx.hosts, sessions = cx.sessions, session = cx.session, agents = cx.agents,
			canvas = cx.canvas, layout = cx.layout, actions = cx.actions, window_key = cx.window_key,
			toast = cx.toast, pick = cx.pick, prompt = cx.prompt, docs = cx.docs, browser = cx.browser }
		assert(fresh ~= picker.context, "native await completion supplies a fresh context")
		self.awaitContext = fresh
		picker.callback(if index then copy(picker.options.items[index]) else nil, failure, fresh)
		self.awaitContext = nil
	end
	function sdk.getenv(name) return world.env[name] end
	function cx:prompt(options)
		local prompt = { options = copy(options), vm = world.vm }
		table.insert(world.prompts, prompt)
		return { kind = "prompt", id = #world.prompts, next = function(_, callback) prompt.callback = callback end }
	end
	function world:answer(value, failure)
		local prompt = self.prompts[#self.prompts]
		assert(prompt and prompt.callback, "native prompt registers its completion")
		local fresh = setmetatable({ prompt = cx.prompt }, { __index = cx })
		prompt.callback(value, failure, fresh)
	end
	function world:completeSource(index, override)
		local request = self.sourceProcesses[index or #self.sourceProcesses]
		if request.vm ~= self.vm or request.completed then return end
		request.completed = true
		local input, response = request.input, nil
		if input.op == "date" then
			response = self.dateResponse or { status = "ready", resolvedUTC = 1800000000,
				civilTime = input.civilTime or "00:00",
				display = "2027-01-15 00:00:00 America/Los_Angeles", zone = "America/Los_Angeles" }
			response = copy(response)
			if response.status == "ready" and response.confirmation == nil then
				response.confirmation = "Bring back " .. response.display .. " = 2027-01-15T08:00:00Z UTC"
			end
		elseif input.op == "header" then
			response = { results = sdk.json.array() }
			for _, target in ipairs(input.targets) do
				local fact = self.sourceRecords[target.path]
				local proof = copy((self.headerResponses or {})[target.path])
				if proof == nil then
					proof = { status = "unsupported" }
					if fact and fact.schemaVersion == 3 and type(fact.sessionId) == "string" then
						proof = { status = if target.expectedSessionId and target.expectedSessionId ~= fact.sessionId then "changed" else "ready",
							sessionId = fact.sessionId, revision = fact.revision }
					end
				end
				proof.key, proof.path, proof.capturedAtUtc, proof.historyRead = target.key, target.path, input.nowUtc, false
				table.insert(response.results, proof)
			end
		else
			response = { results = sdk.json.array() }
			for _, target in ipairs(input.targets) do
				local fact = copy(self.sourceRecords[target.path] or { status = "unsupported" })
				if target.previousRevision ~= nil and target.previousRevision == fact.revision and fact.reusable == true then
					fact = { status = "unchanged", revision = fact.revision, reusable = true,
						metrics = { bytesRead = 0, recordsRead = 0 } }
				end
				fact.key, fact.path, fact.capturedAtUtc = target.key, target.path, input.nowUtc
				if fact.reusable == nil then fact.reusable = false end
				table.insert(response.results, fact)
			end
		end
		response.protocol, response.requestId = 1, input.requestId
		local fresh = setmetatable({ prompt = cx.prompt }, { __index = cx })
		request.callback(override or { status = 0, stdout = sdk.json.encode(response), stderr = "", timed_out = false }, fresh)
	end
	local phonePath = sdk.plugin.data .. "/phone.json"
	function sdk.fs.exists(path)
		if string.sub(path, -5) == "/tern" then
			table.insert(world.cliProbes, path)
			if path == "/Applications/Tern.app/Contents/MacOS/tern" then world.bundleProbes += 1 end
			return world.cliFiles[path] == true
		end
		if path == "/usr/bin/python3" or path == sdk.plugin.dir .. "/source_facts.py" then return true end
		return world.directories[path] == true or world.files[path] ~= nil or (path == phonePath and world.phoneBytes ~= nil)
	end
	function sdk.fs.mkdir(path) world.directories[path] = true end
	function sdk.fs.read(path, maxBytes)
		assert(type(maxBytes) == "number" or path ~= phonePath, "the phone queue is read with a size bound")
		local content = if path == phonePath then world.phoneBytes else world.files[path]
		assert(content ~= nil, "file unavailable")
		return content
	end
	function sdk.fs.write(path, content)
		assert(world.directories[sdk.plugin.data], "plugin data directory must exist before a write")
		assert(type(content) == "string", "native FS writes bytes, not a table")
		if path == phonePath then
			if world.failPhoneWrite then error("phone disk unavailable") end
			world.phoneBytes = content
			world.phoneWrites += 1
			return
		end
		if world.failWrite then error("diagnostics disk unavailable") end
		world.files[path] = content
		world.fileWrites += 1
	end
	function sdk.route.link(handler) world.linkHandler = handler end
	function cx.actions:keys()
		if world.failKeys then error("keymap unavailable") end
		local keys = copy(world.pluginKeys)
		for chord, actions in world.keys do keys[chord] = copy(actions) end
		return keys
	end
	function sdk.bind(chord, action)
		if world.failBind then error("binding unavailable") end
		table.insert(world.binds, { chord = chord, action = action })
		if not world.rejectBind then world.pluginKeys[chord] = { action } end
	end
	function sdk.now() return world.now end
	function sdk.kv.get(key)
		if key == "triage" and world.failTriageRead then error(world.triageReadMessage or "triage read unavailable") end
		if key == "preferences" then world.preferenceReads += 1 end
		return decoded(if key == "preferences" then world.prefs else world.savedTriage)
	end
	function sdk.kv.set(key, value)
		if key == "preferences" then
			if world.failPreferenceWrite then error("preference disk unavailable") end
			world.prefs = copy(value)
			if world.tamperPreferenceWrite then world.prefs.enabled = not world.prefs.enabled end
			world.preferenceWrites += 1
		else
			if world.failTriageWrite then error("triage disk unavailable") end
			world.savedTriage = copy(value)
			world.triageWrites += 1
		end
		world.nativeWrites += 1
	end
	function sdk.log.warn(_prefix, message) table.insert(world.warnings, message) end
	function sdk.command(command)
		world.commands[command.id] = command.run
	end
	function sdk.on(event, callback)
		local previous = world.handlers[event]
		world.handlers[event] = function(ev, context)
			local handled = if previous then previous(ev, context) else nil
			return callback(ev, context) or handled
		end
	end
	function sdk.timer(ms, callback)
		local timer = { due = world.now + ms, callback = callback, cancelled = false, fired = false }
		function timer:cancel() self.cancelled = true end
		table.insert(world.timers, timer)
		return timer
	end
	function world:advance(ms)
		-- Native emits `agent_state` when an agent's state changes (old = nil for an agent new since the last look); test
		-- code changes `agentState` directly, so the fake reports each change before time moves. The first look only records.
		if self.listAgents and self.handlers.agent_state then
			local seen, first = {}, self.agentStates == nil
			self.agentStates = self.agentStates or {}
			for _, agent in self.listAgents() do
				seen[agent.pane] = true
				local old = self.agentStates[agent.pane]
				if old ~= agent.state then
					self.agentStates[agent.pane] = agent.state
					if not first then self:emit("agent_state", { pane = agent.pane, old = old, new = agent.state }) end
				end
			end
			for pane in self.agentStates do if not seen[pane] then self.agentStates[pane] = nil end end
		end
		local untilTime = self.now + ms
		local steps = 0
		while true do
			local nextTimer = nil
			for _, timer in self.timers do
				if not timer.cancelled and not timer.fired and timer.due <= untilTime
					and (not nextTimer or timer.due < nextTimer.due) then nextTimer = timer end
			end
			if not nextTimer then break end
			steps += 1
			if steps >= 500 then
				error(debug.traceback("controller timer chain must remain bounded at " .. tostring(self.now)
					.. " through " .. tostring(untilTime), 2))
			end
			self.now = nextTimer.due
			nextTimer.fired = true
			nextTimer.callback(cx)
		end
		self.now = untilTime
	end
	function world:activeTimers()
		local count = 0
		for _, timer in self.timers do if not timer.cancelled and not timer.fired then count += 1 end end
		return count
	end
	function world:inspect()
		local before = self.fileWrites
		self:command("diagnostics")
		assert(self.fileWrites == before + 1, "diagnostics command must write exactly one snapshot")
		return copy(self.encoded[self.files[sdk.plugin.data .. "/diagnostics.json"]])
	end
	-- The phone queue snapshot as last written, decoded.
	function world:phoneSnapshot()
		assert(self.phoneBytes, "no phone queue snapshot has been written")
		return copy(self.encoded[self.phoneBytes])
	end
	function world:command(name) self.commands[name](cx) end
	function world:key(chord)
		local actions = cx.actions:keys()[chord]
		assert(actions and actions[1] == "plugin.attention.next", "key must resolve to the attention command")
		self:command("next")
	end
	function world:budget(state)
		self.handlers.budget({ hook = "timer", state = state, paused_ms = 5000 }, cx)
	end
	function world:interruptNextPass()
		local selected = nil
		for _, timer in self.timers do
			if not timer.cancelled and not timer.fired and (not selected or timer.due < selected.due) then
				selected = timer
			end
		end
		assert(selected, "an enabled rail must have a scheduled pass")
		self.now, selected.fired, self.abortInventory = selected.due, true, true
		local thread = coroutine.create(function() selected.callback(cx) end)
		local ok, marker = coroutine.resume(thread)
		assert(ok and marker == "native hard budget", "interrupt the actual pass at its native boundary")
		assert(coroutine.close(thread), "discard the interrupted native callback without resuming it")
		self:budget("paused")
	end
	function world:chooseLabel(label)
		local picker = self.pickers[#self.pickers]
		for index, item in ipairs(picker.options.items) do
			if item.label == label then self:choose(index); return end
		end
		error("Current native picker has no item: " .. label)
	end
	-- Expands recorded facts the way a user does on a left/right rail: the row's More button opens the native
	-- tracking menu and "Inspect recorded facts" is chosen from it. `scope` is a row (or a view whose first row is used).
	function world:expandRow(pane, scope)
		local action = rowAction(scope, "menu")
		assert(action, "the row offers its More menu")
		local before = #self.pickers
		self:click(pane, action)
		assert(#self.pickers == before + 1, "the More button opens exactly one native tracking menu")
		for index, item in ipairs(self.pickers[#self.pickers].options.items) do
			if item.op == "inspect" then self:choose(index); return end
		end
		error("the tracking menu offers Inspect recorded facts")
	end
	function world:helperCount(op)
		local count = 0
		for _, request in ipairs(self.sourceProcesses) do
			if (request.input.op or "source") == op then count += 1 end
		end
		return count
	end
	-- Presses a rendered control. A stack has no section tabs (every section is on screen), so choosing a section
	-- there only records which one the test reads next (and closes an open settings panel, as a tab would). Workspace
	-- also opens any session a stack still shows collapsed, as a user would (this Mac's sessions already start open).
	-- A stack pager belongs to its own section, not the first one found.
	function world:control(pane, key)
		local view = self.canvases[pane].view
		if isStack(view) and SECTION_NAMES[key] then
			self.viewing = key
			local settings = descend(view, "top", "settings")
			if settings and settings.p.hidden == false then
				-- The strip's section tabs also leave the settings panel; the stack's gear closes it.
				self:click(pane, keyedAction(view, "settings"))
				self:advance(32)
			end
			if key == "workspace" then self:openSessions(pane) end
			return
		end
		local scope = view
		local action = keyedAction(scope, key)
		assert(action, "current rendered control unavailable: " .. key)
		self:click(pane, action)
	end
	-- Presses the disclosure chevron of one stack section header (Attention or Working).
	function world:toggleQueue(pane, queue)
		local toggle = descend(self.canvases[pane].view, "top", "stack", queue, "head", "toggle")
		assert(toggle and toggle.p.actions, "the section header offers its toggle: " .. queue)
		self:click(pane, toggle.p.actions.click)
	end
	-- Restores every minimized session of a stack's Workspace list with its box's + strip: minimized boxes sit in a
	-- host's Minimized group.
	function world:openSessions(pane)
		for _ = 1, 16 do
			local rows = descend(self.canvases[pane].view, "bottom", "rows")
			local action = nil
			for _, row in ipairs(if rows then rows.c or {} else {}) do
				local boxes = if row.p.role == "workspace.minimized-line" then descend(row, "boxes") else nil
				local edge = if boxes and boxes.c and boxes.c[1] then nativeCanvas.childAt(boxes.c[1], "edge") else nil
				if edge and edge.p.actions then action = edge.p.actions.click; break end
			end
			if not action then return end
			self:click(pane, action)
			self:advance(32)
		end
		error("the stack kept collapsed sessions after sixteen openings")
	end
	-- Minimizes the first open session of a stack's Workspace list with its box's − strip: a real disclosure change.
	function world:closeSession(pane)
		local rows = descend(self.canvases[pane].view, "bottom", "rows")
		for _, row in ipairs(if rows then rows.c or {} else {}) do
			local ledger = string.sub(row.p.key, 1, 8) == "session_" and (row.p.role == "workspace.ledger" or row.p.role == "workspace.ledger-current")
			local edge = if ledger then nativeCanvas.childAt(row, "edge") else nil
			if edge and edge.p.actions then
				self:click(pane, edge.p.actions.click)
				self:advance(32)
				return
			end
		end
		error("no open session row to collapse")
	end
	function world:click(pane, action)
		assert(self.handlers.canvas_action({ owner = "attention", pane = pane, act = action }, cx) == true,
			"Attention must consume its own actions")
	end
	function world:reload()
		self.vm += 1
		for _, timer in self.timers do timer.cancelled = true end
		self.commands, self.handlers, self.pluginKeys = {}, {}, {}
		bootstrap(sdk, function() return 1700000000 + world.utcShift + math.floor(world.now / 1000) end)
	end
	function world:removeRail(pane)
		local tab = self.membership[pane] or 3
		self.canvases[pane], self.membership[pane] = nil, nil
		setRoot(tab, strip(root(tab), pane))
	end
	local function hostInventory()
		local hosts = { [1] = { id = 1, kind = "local", name = "Desktop", state = "connected", panes = {} } }
		local function hostFor(host)
			hosts[host] = hosts[host] or { id = host, kind = "remote", address = "host-" .. host,
				name = world.hostNames and world.hostNames[host] or "Remote", state = "connected", panes = {} }
			return hosts[host]
		end
		for tab, info in world.tabs do
			hostFor(info.host)
			for pane, membership in world.membership do
				if membership == tab and visible(pane) then table.insert(hosts[info.host].panes, pane) end
			end
		end
		for pane in world.canvases do
			local tab = world.membership[pane]
			if (not tab or not world.tabs[tab]) and visible(pane) then
				table.insert(hostFor(world.paneHosts[pane] or 1).panes, pane)
			end
		end
		for pane in world.loose do
			if visible(pane) then table.insert(hostFor(world.paneHosts[pane] or 1).panes, pane) end
		end
		local result = {}
		for _, host in hosts do
			host.current, host.state = host.id == world.currentHost, world.hostStates[host.id] or "connected"
			table.sort(host.panes)
			table.insert(result, host)
		end
		table.sort(result, function(a, b) return a.id < b.id end)
		return result
	end
	function cx.hosts:current()
		if world.failCurrentHost then error("native current host unavailable") end
		for _, host in hostInventory() do if host.current then return host end end
		return nil
	end
	function cx.hosts:list()
		world.inventoryReads += 1
		-- Models a pass whose native reads are slow: the clock moves while the pass runs.
		world.now += world.inventoryCost or 0
		if world.failInventory then error("native inventory unavailable") end
		if world.abortInventory then
			world.abortInventory = false
			coroutine.yield("native hard budget")
		end
		return hostInventory()
	end
	function cx.sessions:list()
		local result = {}
		for _, session in world.sessionOrder do
			local info = world.sessions[session]
			if info then table.insert(result, { id = session, host = info.host, name = info.name, locked = info.locked == true,
				current = session == world.currentSession }) end
		end
		return result
	end
	function cx.sessions:switch(session)
		local info = world.sessions[session]
		assert(info, "cannot switch to missing native session")
		table.insert(world.sessionSwitches, session)
		world.currentHost, world.currentSession = info.host, session
		for _, tab in world.tabs do
			if tab.session == session and tab.content then world.focused = tab.content; return end
		end
		world.focused = nil
	end
	function cx.session:focused() return world.focused end
	function cx.session:tabs()
		local tabs = {}
		for tab, info in world.tabs do
			local count = 0
			for pane, membership in world.membership do
				if membership == tab and not world.parked[pane] and not world.canvases[pane] then count += 1 end
			end
			local focusedPane = if world.membership[world.focused] == tab then world.focused else info.content
			local focusedInfo = focusedPane and cx.session:pane(focusedPane)
			table.insert(tabs, { id = tab, session = info.session, pane = focusedPane, name = info.name,
				title = focusedInfo and focusedInfo.title, position = info.position, color = info.color, panes = count })
		end
		return tabs
	end
	function cx.session:pane(pane)
		if world.beforePaneLookup then world.beforePaneLookup(pane) end
		if not visible(pane) then return nil end
		local tab = world.membership[pane]
		if not tab and not world.canvases[pane] and not world.loose[pane] then return nil end
		local canvas = world.canvases[pane] ~= nil or world.restored[pane] == true
		local info = world.paneInfo[pane] or {}
		return { pane = pane, tab = if world.parked[pane] then nil else tab,
			parked = world.parked[pane] == true, floating = world.floating[pane] == true,
			title = if world.canvases[pane] then world.canvases[pane].title elseif canvas then "Canvas"
				elseif info.title then info.title else world.agentTitle or "Agent",
			alert = pane == 10 and world.agentAlert, error = pane == 10 and world.startupError or nil,
			kind = if canvas then "plugin" else info.kind or "terminal", block = if canvas then "tern.canvas" else nil,
			path = info.path, url = info.url, cwd = info.cwd, program = info.program, focused = world.focused == pane }
	end
	function cx.session:panes()
		world.paneListReads = (world.paneListReads or 0) + 1
		local panes, seen = {}, {}
		for pane in world.membership do
			local value = self:pane(pane)
			if value then table.insert(panes, value); seen[pane] = true end
		end
		for _, source in { world.canvases, world.loose } do
			for pane in source do
				if not seen[pane] then
					local value = self:pane(pane)
					if value then table.insert(panes, value); seen[pane] = true end
				end
			end
		end
		return panes
	end
	function cx.session:tab_of(pane)
		local value = self:pane(pane)
		return value and value.tab
	end
	function cx.session:layout(tab)
		world.layoutReads = (world.layoutReads or 0) + 1
		if world.failLayoutAfter ~= nil then
			if world.failLayoutAfter == 0 then
				world.failLayoutAfter = nil
				error("native layout temporarily unavailable")
			end
			world.failLayoutAfter -= 1
		end
		if not world.tabs[tab] then return nil end
		return { root = copy(root(tab)), floats = copy(world.floats[tab] or {}),
			focus = if world.membership[world.focused] == tab then world.focused else world.tabs[tab].content,
			zoomed = tab == 3 and world.zoomed }
	end
	function cx.agents:list()
		world.agentListReads = (world.agentListReads or 0) + 1
		local agents = if world.membership[10] then { { pane = 10, state = world.agentState, delivery_error = world.deliveryError,
			model = world.models[10] } } else {}
		for pane, state in world.additionalAgents or {} do
			if world.membership[pane] then table.insert(agents, { pane = pane, state = state, model = world.models[pane] }) end
		end
		return agents
	end
	-- The fake's own change detection is not a plugin read.
	function world.listAgents()
		local reads = world.agentListReads
		local agents = cx.agents:list()
		world.agentListReads = reads
		return agents
	end
	function cx.agents:transcript(pane, opts) return world.transcripts[pane] or {} end
	function cx.canvas:list()
		if world.failCanvasList then error("native canvas list unavailable") end
		local canvases = {}
		for _, canvas in world.canvases do
			if described(canvas.pane) then
				table.insert(canvases, { pane = canvas.pane, owner = canvas.owner, about = canvas.about, title = canvas.title })
			end
		end
		return canvases
	end
	function cx.canvas:get(pane)
		if world.contentInspectionUnavailable then error("native canvas content inspection unavailable") end
		return if described(pane) then copy(world.canvases[pane]) else nil
	end
	function cx.canvas:open(options)
		world.attempts += 1
		world.nativeWrites += 1
		assert(type(options.view) == "table" and options.dock == nil, "creation requires complete content without a native dock")
		local target, direction
		if options.how == "beside" then
			assert(options.dir == nil and options.target == nil and options.ratio == nil and options.focus == false,
				"a bottom or right rail opens beside the focused pane and preserves focus")
			target, direction = world.focused, "right"
		else
			assert(options.how == nil and options.dir == "left" and options.focus == false and type(options.target) == "number"
				and type(options.ratio) == "number" and options.ratio > 0 and options.ratio < 1,
				"a left rail opens with its share to the left of an explicit target pane and preserves focus")
			target, direction = options.target, options.dir
		end
		if world.failOpen == "throw" then error("native open rejected") end
		if world.failOpen == "reject" then return nil, "native open rejected" end
		local pane = world.nextPane
		world.nextPane += 1
		world.canvases[pane] = { pane = pane, owner = "attention", about = options.about, title = options.title,
			view = copy(options.view), dock = copy(options.dock) }
		local tab = world.membership[target]
		assert(tab and has(root(tab), target) and not world.parked[target] and not world.floating[target],
			"the open target must be a tiled pane")
		world.membership[pane], world.replicaAt[pane] = tab, world.now + world.replicaDelay
		world.metadataAt[pane] = world.now + world.metadataDelay
		world.paneHosts[pane] = world.tabs[tab].host
		setRoot(tab, insert(root(tab), pane, target, direction, options.ratio))
		table.insert(world.opens, { pane = pane, options = copy(options) })
		assert(options.focus == false, "creation must preserve typing focus")
		if world.failOpen == "accepted-throw" then error("native reply interrupted after acceptance") end
		return pane
	end
	function cx.canvas:set(pane, change)
		if world.failCanvasPanes and world.failCanvasPanes[pane] then
			world.rejectedSets = (world.rejectedSets or 0) + 1
			error("native canvas update rejected for one pane")
		end
		if world.failNextCanvasSet or (world.failCanvasUntil and world.now < world.failCanvasUntil) then
			world.failNextCanvasSet = nil
			error("native canvas update rejected")
		end
		world.nativeWrites += 1
		world.canvasSets += 1
		world.canvasSetsByPane[pane] = (world.canvasSetsByPane[pane] or 0) + 1
		local canvas = world.canvases[pane]
		assert(canvas, "cannot update missing canvas")
		world.canvases[pane] = nativeCanvas.apply(canvas, change)
		if world.canvasPaints then
			local rows = sectionRows(world, pane, "attention")
			local coverage = coverageOf(world.canvases[pane].view)
			table.insert(world.canvasPaints, { pane = pane, at = world.now, role = rows and rows.p.role,
				notice = if coverage and not coverage.p.hidden then copy((nativeCanvas.childAt(coverage, "notice"))) else nil })
		end
	end
	function cx.layout:move(pane, target, direction, reveal)
		assert(reveal.focus == false, "placement must preserve focus")
		world.layoutWrites += 1
		if world.failMove then return false, "native move rejected" end
		if world.rejectContentMove and not world.canvases[pane] then
			-- Native accepts the first content move, then refuses the next without changing the layout.
			world.contentMoves = (world.contentMoves or 0) + 1
			if world.contentMoves == 2 then
				world.rejectContentMove = false
				world.contentMoveRejects = (world.contentMoveRejects or 0) + 1
				return false
			end
		end
		local tab = world.membership[pane]
		world.layoutWritesByTab[tab] = (world.layoutWritesByTab[tab] or 0) + 1
		assert(tab == world.membership[target], "stationary placement cannot cross tabs")
		local remaining = strip(root(tab), pane)
		assert(has(remaining, target), "native move requires a live leaf target")
		setRoot(tab, insert(remaining, pane, target, direction))
		world.nativeWrites += 1
		if world.abortAfterContentMove and not world.canvases[pane] then
			world.abortAfterContentMove = false
			coroutine.yield("native hard budget")
		end
		if world.throwAfterContentMove and not world.canvases[pane] then
			world.throwAfterContentMove = false
			world.reconstructionInterrupts = (world.reconstructionInterrupts or 0) + 1
			error("native reconstruction reply interrupted after acceptance")
		end
		return true
	end
	function cx.layout:resize(pane, direction, cells)
		world.nativeWrites += 1
		world.layoutWrites += 1
		assert(cells == math.round(cells), "native resize takes integer cells")
		local tab = world.membership[pane]
		world.layoutWritesByTab[tab] = (world.layoutWritesByTab[tab] or 0) + 1
		local tree = root(tab)
		assert(has(tree, pane), "native resize requires a tiled pane")
		local axis = if direction == "left" or direction == "right" then "right" else "down"
		local sign = if direction == "right" or direction == "down" then 1 else -1
		local candidate, extent
		local function walk(node, width, height)
			if node.pane then return end
			local branch = if has(node[1], pane) then 1 else 2
			local span = if node.split == "right" then width else height
			if node.split == axis then candidate, extent = node, span end
			local fraction = if branch == 1 then node.ratio else 1 - node.ratio
			walk(node[branch], if node.split == "right" then width * fraction else width,
				if node.split == "down" then height * fraction else height)
		end
		walk(tree, 180, 180)
		if not candidate then return false end
		local ratio = math.clamp(candidate.ratio + sign * cells / extent, 0.05, 0.95)
		local changed = math.abs(ratio - candidate.ratio) > 0.0000001
		candidate.ratio = ratio
		return changed
	end
	function cx.layout:close(pane)
		world.layoutWrites += 1
		table.insert(world.closes, pane)
		world:closePane(pane)
	end
	function cx.layout:park(pane)
		world.layoutWrites += 1
		table.insert(world.parks, pane)
		if world.refusePark and world.refusePark[pane] then return false, "native park refused" end
		local tab = world.membership[pane]
		setRoot(tab, strip(root(tab), pane))
		world.parked[pane] = true
		return true
	end
	function cx.layout:unpark(pane, reveal)
		assert(reveal.focus == false)
		world.layoutWrites += 1
		local tab = world.membership[world.focused]
		world.membership[pane], world.parked[pane] = tab, nil
		setRoot(tab, { split = "right", ratio = 0.5, [1] = root(tab), [2] = { pane = pane } })
		return true
	end
	function cx.layout:dock(pane, target, direction, reveal)
		world.floating[pane] = nil
		world.floats[world.membership[pane]] = {}
		return self:move(pane, target, direction, reveal)
	end
	function cx.layout:focus(pane)
		world.nativeWrites += 1
		assert(cx.session:pane(pane), "cannot focus missing target")
		world.focused = pane
		local tab = world.tabs[world.membership[pane]]
		if tab then world.currentHost, world.currentSession = tab.host, tab.session end
		if pane == 10 then world.agentAlert = false end
		world.focusWrites += 1
	end
	-- Native management and creation. Replies are deliberately not trusted by the plugin, so each fake can be told
	-- to accept a call without doing anything (`ignoreCreation`, `ignoreRename`).
	local function newPane(tab, info)
		local pane = world.nextNativePane
		world.nextNativePane += 1
		world.membership[pane], world.paneHosts[pane] = tab, world.tabs[tab].host
		world.paneInfo[pane] = info
		return pane
	end
	local function newTab(info)
		local tab = world.nextTab
		world.nextTab += 1
		world.tabs[tab] = { session = world.currentSession, host = world.currentHost }
		local pane = newPane(tab, info)
		world.tabs[tab].content, world.layouts[tab] = pane, { pane = pane }
		world.focused = pane
		return pane
	end
	function cx.layout:new_tab(launch)
		table.insert(world.newTabs, copy(launch or {}))
		if world.ignoreCreation then return nil end
		return newTab({ cwd = launch and launch.cwd })
	end
	function cx.layout:name_tab(tab, name)
		table.insert(world.renames, { tab = tab, name = name })
		if world.ignoreRename or not world.tabs[tab] then return end
		world.tabs[tab].name = if name == "" then nil else name
	end
	function cx.layout:rename_session(session, name)
		table.insert(world.renames, { session = session, name = name })
		if world.ignoreRename then return true end
		if not world.sessions[session] then return false, "unknown session" end
		world.sessions[session].name = name
		return true
	end
	function cx.layout:order_tab(tab, position)
		table.insert(world.orders, { tab = tab, position = position })
		if world.ignoreOrders or not world.tabs[tab] then return end
		-- Native re-denses the session's positions: splice among that session's tabs, then 1..n again.
		local session = world.tabs[tab].session
		local ids = {}
		for id, info in world.tabs do
			if info.session == session then table.insert(ids, { id = id, position = info.position or id }) end
		end
		table.sort(ids, function(a, b)
			if a.position ~= b.position then return a.position < b.position end
			return a.id < b.id
		end)
		local ordered = {}
		for _, entry in ipairs(ids) do
			if entry.id ~= tab then table.insert(ordered, entry.id) end
		end
		table.insert(ordered, math.min(math.max(position, 1), #ordered + 1), tab)
		for index, id in ipairs(ordered) do world.tabs[id].position = index end
	end
	function cx.docs:new_note(title, markdown)
		table.insert(world.noteCreates, { title = title, markdown = markdown })
		if world.ignoreCreation then return 0 end
		return newTab({ kind = "file", path = "note:" .. title, title = title })
	end
	function cx.docs:open(path)
		table.insert(world.fileOpens, path)
		if world.ignoreCreation then return 0 end
		return newTab({ kind = "file", path = path })
	end
	function cx.browser:call(operation)
		table.insert(world.browserCalls, copy(operation))
		local call = { vm = world.vm, operation = copy(operation) }
		world.browserCall = call
		return { kind = "browser", next = function(_self, callback) call.callback = callback end }
	end
	-- Completes the pending browser call; a reply that says "ok" but creates nothing is the untrusted case.
	function world:completeBrowser(result)
		local call = self.browserCall
		assert(call and call.callback, "browser open registers its asynchronous completion")
		if call.vm ~= self.vm then return end
		local fresh = { hosts = cx.hosts, sessions = cx.sessions, session = cx.session, agents = cx.agents,
			canvas = cx.canvas, layout = cx.layout, actions = cx.actions, window_key = cx.window_key,
			toast = cx.toast, pick = cx.pick, prompt = cx.prompt, docs = cx.docs, browser = cx.browser }
		if not self.ignoreCreation and (result == nil or result.error == nil) then
			newTab({ kind = "browser", url = call.operation.url })
		end
		self.awaitContext = fresh
		call.callback(result or { ok = {} }, nil, fresh)
		self.awaitContext = nil
	end
	function cx.sessions:create(options)
		table.insert(world.sessionCreates, copy(options))
		if world.ignoreCreation then return { id = 0, name = options.name } end
		local session = world.nextSession
		world.nextSession += 1
		world.sessions[session] = { host = world.currentHost, name = options.name }
		table.insert(world.sessionOrder, session)
		world.currentSession, world.focused = session, nil
		return { id = session, name = options.name }
	end
	function cx.hosts:switch(host)
		table.insert(world.hostSwitches, host)
		assert((world.hostStates[host] or "connected") == "connected", "cannot switch to a disconnected host")
		world.currentHost = host
		for _, session in world.sessionOrder do
			local info = world.sessions[session]
			if info and info.host == host then
				world.currentSession, world.focused = session, nil
				for _, tab in world.tabs do
					if tab.session == session and tab.content then world.focused = tab.content; break end
				end
				return
			end
		end
	end
	function cx.actions:run(id)
		table.insert(world.actionRuns, id)
		return ""
	end
	bootstrap(sdk, function() return 1700000000 + world.utcShift + math.floor(world.now / 1000) end)
	return world
end
local function savedItemFor(world, pane)
	for _, item in ipairs(world.savedTriage.items) do
		if item.pane == pane then return item end
	end
	error("No saved native work for pane " .. tostring(pane))
end

local function renderedRowFor(world, rail, pane)
	local serial = savedItemFor(world, pane).serial
	return (nativeCanvas.childAt(sectionRows(world, rail), "r" .. serial))
end
local function visibleText(node)
	if node.p and node.p.hidden then return "" end
	local parts = { if node.p then node.p.text or "" else "" }
	for _, child in ipairs(node.c or {}) do table.insert(parts, visibleText(child)) end
	return table.concat(parts, " ")
end

local function tooltipText(node)
	if node.p and node.p.hidden then return "" end
	local parts = { if node.p then node.p.title or "" else "" }
	for _, child in ipairs(node.c or {}) do table.insert(parts, tooltipText(child)) end
	return table.concat(parts, " ")
end
-- Workspace rows are keyed by their navigator key with every non-alphanumeric byte escaped; `part` names the
-- clickable child (open, toggle, menu, details).
local function wsRow(world, rail, key)
	local safe = string.gsub(key, "[^%w]", function(char) return string.format("_%02x", string.byte(char)) end)
	local rows = sectionRows(world, rail, "workspace")
	local direct = (nativeCanvas.childAt(rows, safe))
	if direct then return direct end
	for _, block in ipairs(rows.c or {}) do
		if block.p and (block.p.role == "workspace.ledger" or block.p.role == "workspace.ledger-current") then
			local nested = (nativeCanvas.childAt((nativeCanvas.childAt(block, "rows")), safe))
			if nested then return nested end
		elseif block.p and block.p.role == "workspace.empty-line" then
			local named = (nativeCanvas.childAt((nativeCanvas.childAt(block, "names")), safe))
			if named then return named end
		elseif block.p and block.p.role == "workspace.minimized-line" then
			local boxes = nativeCanvas.childAt(block, "boxes")
			local minimized = if boxes then (nativeCanvas.childAt(boxes, safe)) else nil
			if minimized then return minimized end
		end
	end
	return nil
end
local function wsPart(world, rail, key, part)
	local row = wsRow(world, rail, key)
	if not row then return nil end
	-- An empty session is its own button on the No tabs line.
	if row.p and row.p.role == "workspace.empty-name" then return if part == "open" then row.p.actions.click else nil end
	local ledger = row.p and (row.p.role == "workspace.ledger" or row.p.role == "workspace.ledger-current")
	-- A session box: its edge strip is the minimize/restore toggle, its name the jump.
	if ledger and part == "toggle" and nativeCanvas.childAt(row, "edge") then
		local edge = nativeCanvas.childAt(row, "edge")
		return if edge.p.actions then edge.p.actions.click else nil
	end
	local holder = if ledger then nativeCanvas.childAt(row, "label") else ((nativeCanvas.childAt(row, "main")) or row)
	local item = if holder then nativeCanvas.childAt(holder, if ledger and part == "open" then "name" else part) else nil
	return if item and item.p.actions then item.p.actions.click else nil
end



do
	local world = native(true)
	world.keys["cmd+d"] = { "split_right" }
	world:advance(3100)
	assert(#world.binds == 1 and world.binds[1].chord == "cmd+j"
		and world.binds[1].action == "plugin.attention.next", "install only the requested default")
	assert(world:inspect().shortcut == "cmd+j", "report the installed shortcut")
	assert(world.keys["cmd+d"][1] == "split_right", "unrelated keys must remain untouched")
	assert(world.focusWrites == 0, "background setup must not focus the P0 target")
	world.focused = world.opens[1].pane
	world:key("cmd+j")
	assert(world.focusWrites == 1 and world.focused == 10, "the shortcut must navigate to the next P0")
end

for _, chord in { "cmd+j", "J + Command", "super+j>k" } do
	local world = native(true)
	world.keys[chord] = { "new_tab" }
	world:advance(3100)
	assert(#world.binds == 0 and world:inspect().shortcut == nil,
		"an occupied chord or sequence prefix must not be overridden or trigger a fallback")
	assert(world.keys[chord][1] == "new_tab", "the existing action must be preserved")
end

for _, chord in { "cmd+j", "J + Command" } do
	local world = native(true)
	world.keys[chord] = { "plugin.attention.next" }
	world:advance(3100)
	assert(#world.binds == 0 and world:inspect().shortcut == "cmd+j",
		"an effective binding for the same action is already configured")
	assert(world.focusWrites == 0, "recognizing an existing binding must not navigate")
	world.focused = world.opens[1].pane
	world:key(chord)
	assert(world.focusWrites == 1 and world.focused == 10, "a configured shortcut must remain actionable")
end

do
	local world = native(true)
	world.keys["cmd+j"] = { "new_tab", "plugin.attention.next" }
	world:advance(3100)
	assert(#world.binds == 0 and world:inspect().shortcut == nil,
		"a lower-priority action must not be advertised as an unconditional shortcut")
end

do
	local world = native(true)
	world.keys["cmd+j"] = {}
	world:advance(3100)
	assert(#world.binds == 0 and world:inspect().shortcut == nil,
		"an explicitly empty effective binding must stay unbound")
end

do
	local world = native(true)
	world.keys["cmd+j"] = { "plugin.attention.next" }
	world.keys["cmd+j>k"] = { "new_tab" }
	world:advance(3100)
	assert(#world.binds == 0 and world:inspect().shortcut == nil,
		"a same-action binding must not hide an existing sequence conflict")
end

do
	local world = native(true)
	world.pluginKeys["alt+shift+cmd+n"] = { "plugin.attention.next" }
	world:reload()
	world:advance(3100)
	assert(world.pluginKeys["alt+shift+cmd+n"] == nil and world.pluginKeys["ctrl+alt+shift+n"] == nil,
		"reload must retire the old plugin defaults without compatibility bindings")
	assert(world.pluginKeys["cmd+j"][1] == "plugin.attention.next",
		"reload must install the new default")
end

for _, failure in { "failKeys", "failBind", "rejectBind" } do
	local world = native(true)
	world[failure] = true
	world:advance(3100)
	assert(world:inspect().shortcut == nil, "unavailable or rejected keys must not be advertised")
	assert(#world.opens == 1 and world.focusWrites == 0, "shortcut failures must preserve background attention")
end

do
	local world = native(true)
	local pane = 6609954668556
	world.prefs = { schema = 2, enabled = true, owner = "desktop", position = "bottom",
		shares = { bottom = { ["local"] = 0.32 }, right = {} }, suppressed = {} }
	world.canvases[pane] = { pane = pane, owner = "attention", about = "attention:rail:v1", title = "Attention",
		view = { k = "col", p = {}, c = {} } }
	world.membership[pane] = 3
	world.root = { split = "down", ratio = 0.68, [1] = { pane = 10 }, [2] = { pane = pane } }
	world:advance(2300)
	assert(#world.opens == 0 and world.canvases[pane].about == "attention:rail:v1",
		"existing owned canvases must be reused in place")
	assert(world.root.split == "down" and world.root[1].pane == 10 and world.root[2].pane == pane
		and math.abs(world.root.ratio - 0.68) < 0.000001 and world.layoutWrites == 0
		and world.focused == 10 and world.focusWrites == 0,
		"the adopted bottom rail stays at the bottom at its own height")
	assert(not world.prefs.instances["local"]["3"].userHidden, "adoption must not hide the existing rail")
	local saved = world.prefs.instances["local"]["3"]
	assert(world.prefs.schema == 4 and world.prefs.defaults.position == "bottom"
		and math.abs(world.prefs.defaults.shares.bottom["local"] - 0.32) < 0.000001
		and saved.position == "bottom" and saved.shares == nil,
		"a legacy store keeps its bottom position and height")
	world:reload()
	world:advance(2300)
	assert(#world.opens == 0 and world.canvases[pane], "reload must reuse the same adopted canvas")
	world:command("disable")
	assert(world.canvases[pane].dock == nil, "disabled presentation must not restore dock content")
end

do
	local world = native(true, "ios")
	world:advance(3100)
	assert(#world.opens == 0 and world.nativeWrites == 0 and world:activeTimers() == 0,
		"the desktop rail must remain completely inactive on iOS")
	assert(next(world.commands) == nil, "desktop-only commands must not appear on iOS")
end

-- Unknown absence must not silently hide a tab or create another accepted pane.
do
	local world = native(true)
	world:advance(2100)
	assert(#world.opens == 1 and world:inspect().count == 1, "startup must render the waiting agent")
	local first = world.opens[1]
	local staleAction = rowAction(first.options.view)
	assert(staleAction, "initial view must have an actionable row")
	world:removeRail(first.pane)
	world:advance(1000)
	assert(not world.prefs.instances["local"]["3"].userHidden and #world.opens == 1,
		"unknown absence must preserve identity without automatic replacement")
	world:emit("pane_closed", { pane = first.pane })
	world:advance(50)
	world:command("open")
	world:advance(2100)
	assert(#world.opens == 2, "explicit Open must recreate a disappeared rail on unchanged data")
	local replacement = world.opens[2]
	assert(replacement.options.view.k and replacement.options.dock == nil, "replacement needs complete dockless content")
	local action = rowAction(replacement.options.view)
	assert(action and action ~= staleAction, "replacement must issue fresh row tokens")
	assert(world:inspect().instances[1].pending == false, "replica discovery must clear pending")
	assert(world.root.split == "right" and world.root[1].pane == replacement.pane and math.abs(world.root.ratio - 0.25) < 0.01,
		"recreated rail must settle left of the content with its requested share")
	world:click(replacement.pane, staleAction)
	assert(world.focusWrites == 0, "old row token must not navigate through the replacement rail")
	world:click(replacement.pane, action)
	assert(world.focusWrites == 1 and world.focused == 10, "replacement row binding must remain actionable")
	world:advance(100)
	assert(not world:inspect().navigationPending, "replacement navigation must complete from native focus readback")
end

for _, failure in { "reject" } do
	local world = native(true)
	world.failOpen = failure
	world:advance(2100)
	assert(world.attempts == 1 and #world.opens == 0, "native creation failure must be exercised")
	assert(world:inspect().instances[1].pending == false, "native creation error must not wedge pending")
	world.failOpen = nil
	world:command("open")
	world:advance(2100)
	assert(#world.opens == 1, "creation must recover after native rejection or exception")
	local opened = world.opens[1]
	local action = rowAction(opened.options.view)
	assert(action and opened.options.dock == nil, "recovered creation must include complete dockless actionable content")
	world:click(opened.pane, action)
	assert(world.focusWrites == 1, "recovered binding must navigate")
end

-- A Tern daemon restart restores canvas panes blank: the session still reports a "Canvas"
-- tern.canvas plugin pane, but cx.canvas no longer lists it or returns it, so the owner-only
-- update path can never repaint it.
local function restoreBlank(world, panes)
	for _, pane in panes do world.canvases[pane], world.restored[pane] = nil, true end
end

local function instanceFor(world, tab)
	for _, instance in world:inspect().instances do if instance.tab == tab then return instance end end
	return nil
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	world:switch(5); world:advance(3100)
	local third = world.opens[3].pane
	assert(world.membership[first] == 3 and world.membership[second] == 4 and world.membership[third] == 5
		and world.root[1].pane == first and world.layouts[4][1].pane == second, "each tab mounts its own rail")
	local ratio, otherRatio, otherWrites = world.root.ratio, world.layouts[4].ratio, world.layoutWritesByTab[4] or 0
	world:switch(3)
	-- Another plugin's live canvas and an unrecorded restored blank canvas share the restarted tab.
	local foreignView = { k = "col", p = {}, c = {} }
	world.canvases[77] = { pane = 77, owner = "notes", about = "notes:board", title = "Notes", view = copy(foreignView) }
	world.restored[78] = true
	world.membership[77], world.membership[78], world.paneHosts[77], world.paneHosts[78] = 3, 3, 1, 1
	world.floating[77], world.floating[78] = true, true
	world.floats[3] = { { pane = 77, over = 10, corner = "top_right" }, { pane = 78, over = 10, corner = "bottom_right" } }
	world.prefs.instances["local"]["5"].userHidden = true
	restoreBlank(world, { first, second, third })
	world:reload()
	world:advance(6000)
	assert(#world.opens == 4 and world.membership[world.opens[4].pane] == 3
		and world.opens[4].options.about == "attention:tab:v1:2:3", "the focused tab mounts one owned replacement")
	local replacement = world.opens[4].pane
	assert(#world.closes == 1 and world.closes[1] == first and world.restored[first] == nil and world.membership[first] == nil,
		"only the recorded remnant closes, after its replacement is accepted")
	assert(world.root.split == "right" and world.root[1].pane == replacement and world.root[2].pane == 10
		and math.abs(world.root.ratio - ratio) < 0.01, "the replacement takes the saved share on the left")
	assert(world.prefs.instances["local"]["3"].pane == replacement and world.prefs.instances["local"]["3"].remnants == nil,
		"the registry records only the replacement once the remnant is gone")
	assert(world.canvases[77].owner == "notes" and world.canvases[77].view.k == foreignView.k
		and world.canvasSetsByPane[77] == nil and world.restored[78] and world.membership[78] == 3
		and world.floating[77] and world.floating[78],
		"other owners' canvases and unrecorded restored blank canvases stay untouched")
	assert(world.restored[second] and world.layouts[4][1].pane == second and world.layouts[4].ratio == otherRatio
		and (world.layoutWritesByTab[4] or 0) == otherWrites, "an unvisited tab's remnant waits untouched for that tab")
	assert(world.focusWrites == 0 and world.focused == 10, "recovery never moves focus")
	world:switch(4); world:advance(6000)
	local other = world.opens[5] and world.opens[5].pane
	assert(#world.opens == 5 and world.membership[other] == 4 and #world.closes == 2 and world.closes[2] == second
		and world.layouts[4][1].pane == other and math.abs(world.layouts[4].ratio - otherRatio) < 0.01,
		"visiting a restarted tab replaces exactly its own remnant in place")
	world:switch(5); world:advance(3100)
	assert(#world.opens == 5 and #world.closes == 2 and world.restored[third] and world.membership[third] == 5
		and world.prefs.instances["local"]["5"].userHidden and world.prefs.instances["local"]["5"].pane == third,
		"a hidden instance is not recreated and its remnant is left in place")
	assert(string.find(instanceFor(world, 5).status, "Restored blank canvas left in place", 1, true),
		"the retained hidden remnant is reported")
	local writes = world.layoutWrites
	world:reload(); world:advance(3100)
	assert(#world.opens == 5 and #world.closes == 2 and world.layoutWrites == writes,
		"recovery is idempotent across reload")
	assert(world.focusWrites == 0, "restart recovery never navigates")
end

do
	local world = native(true)
	world:advance(3100)
	local first = world.opens[1].pane
	local ratio = world.root.ratio
	restoreBlank(world, { first })
	world.failOpen = "reject"
	world:reload()
	world:advance(8000)
	local rejected = 0
	for _, toast in world.toasts do
		if toast.kind == "error" and string.find(toast.message, "native open rejected", 1, true) then rejected += 1 end
	end
	assert(world.attempts == 2 and #world.opens == 1 and rejected == 1, "a failed replacement is attempted and reported once")
	assert(#world.closes == 0 and world.restored[first] and world.root[1].pane == first and world.root.ratio == ratio,
		"a failed replacement leaves the remnant in place")
	local instance = instanceFor(world, 3)
	assert(instance.phase == "failed" and instance.remnants and instance.remnants[1] == first and #instance.remnants == 1
		and string.find(instance.status, "restored blank canvas left in place", 1, true), "failure status names the retained remnant")
	world:reload(); world:advance(5000)
	assert(world.attempts == 2 and #world.closes == 0, "reload does not loop a failed replacement")
	world.failOpen = nil
	world:command("open"); world:advance(5000)
	local replacement = world.opens[2] and world.opens[2].pane
	assert(#world.opens == 2 and #world.closes == 1 and world.closes[1] == first and world.restored[first] == nil
		and world.root[1].pane == replacement and math.abs(world.root.ratio - ratio) < 0.01,
		"explicit Open replaces the retained remnant")
	assert(world.focusWrites == 0, "failure recovery never navigates")
end

-- The window's canvas list and lookup share one replica: both can miss a live owned canvas at once.
-- Only a host-side capture separates that delay from a restart-blanked canvas.
do
	local world = native(true)
	world:advance(3100)
	local live = world.opens[1].pane
	local ratio = world.root.ratio
	world.metadataAt[live] = world.now + 8000
	world:reload(); world:advance(5000)
	assert(world.captureLaunches >= 1 and world.captures[1].pane == live
		and table.concat(world.captures[1].argv, " ") == "/Applications/Tern.app/Contents/MacOS/tern capture --window desktop "
			.. tostring(live) .. " --surfaces", "the delayed canvas is confirmed through one fixed-argument host capture")
	assert(#world.opens == 1 and #world.closes == 0 and world.canvases[live] and world.root[1].pane == live
		and world.root.ratio == ratio, "list and lookup absence during replica delay neither replaces nor closes the live canvas")
	assert(world.prefs.instances["local"]["3"].pane == live and world.prefs.instances["local"]["3"].remnants == nil,
		"the live canvas stays recorded and is never treated as a remnant")
	world:advance(5000)
	assert(#world.opens == 1 and #world.closes == 0 and world.prefs.instances["local"]["3"].pane == live,
		"late metadata adopts the same canvas")
end

-- An accepted creation whose metadata lags is awaited, never probed or replaced.
do
	local world = native(true)
	world.metadataDelay = 7000
	world:advance(2100)
	local pane = world.opens[1] and world.opens[1].pane
	assert(pane and world.prefs.instances["local"]["3"].creating, "creation is accepted while metadata lags")
	world:reload(); world:advance(3000)
	assert(#world.opens == 1 and #world.closes == 0 and world.captureLaunches == 0,
		"an accepted creation waiting for metadata is not a remnant candidate")
	world:advance(5000)
	assert(#world.opens == 1 and #world.closes == 0 and world.prefs.instances["local"]["3"].pane == pane
		and not world.prefs.instances["local"]["3"].creating, "late metadata settles the accepted creation")
end

-- Anything but a positively blank capture leaves the recorded canvas in place, with bounded retries.
for _, outcome in { "foreign", "body", "error", "timeout", "malformed", "oversized", "spawn" } do
	local world = native(true)
	world:advance(3100)
	local first = world.opens[1].pane
	local ratio = world.root.ratio
	restoreBlank(world, { first })
	world.captureOverride = outcome
	world:reload(); world:advance(30000)
	local content = outcome == "foreign" or outcome == "body"
	assert(#world.opens == 1 and #world.closes == 0 and world.restored[first] and world.root[1].pane == first
		and world.root.ratio == ratio, outcome .. " capture neither replaces nor closes the restored canvas")
	assert(world.prefs.instances["local"]["3"].pane == first and world.prefs.instances["local"]["3"].remnants == nil,
		outcome .. " capture keeps the canvas recorded rather than marking it a remnant")
	assert(world.captureLaunches == (if content then 1 else 3),
		outcome .. " capture is attempted a bounded number of times without heartbeat polling")
	world.captureOverride = nil
	world:command("open"); world:advance(6000)
	local replacement = world.opens[2] and world.opens[2].pane
	assert(#world.opens == 2 and #world.closes == 1 and world.closes[1] == first and world.restored[first] == nil
		and world.root[1].pane == replacement and math.abs(world.root.ratio - ratio) < 0.01,
		"after " .. outcome .. ", explicit Open re-captures and a positive blank capture permits recovery")
	assert(world.focusWrites == 0, "capture recovery never navigates")
end

-- A second restart after the replacement is accepted but before the old remnant closes keeps both
-- recorded remnants and retires each only after its own blank capture.
do
	local world = native(true)
	world:advance(3100)
	local first = world.opens[1].pane
	local ratio = world.root.ratio
	restoreBlank(world, { first })
	world.metadataDelay = 60000
	world:reload(); world:advance(4000)
	local second = world.opens[2] and world.opens[2].pane
	assert(second and #world.closes == 0 and world.restored[first], "the replacement is accepted while its metadata lags")
	world.metadataAt[second] = world.now
	world.holdCaptures = true
	world:reload(); world:advance(1100)
	local saved = world.prefs.instances["local"]["3"]
	assert(saved.pane == second and not saved.creating and saved.remnants and #saved.remnants == 1
		and saved.remnants[1] == first and #world.closes == 0,
		"the accepted replacement is recorded while the old remnant awaits a fresh capture")
	restoreBlank(world, { second })
	world.holdCaptures, world.metadataDelay = false, 0
	world:reload(); world:advance(6000)
	saved = world.prefs.instances["local"]["3"]
	local third = world.opens[3] and world.opens[3].pane
	assert(#world.opens == 3 and #world.closes == 2 and table.find(world.closes, first) and table.find(world.closes, second)
		and world.restored[first] == nil and world.restored[second] == nil,
		"both verified saved remnants are retired after the third canvas is accepted")
	assert(saved.pane == third and saved.remnants == nil and world.canvases[third] and world.root[1].pane == third
		and math.abs(world.root.ratio - ratio) < 0.01, "only the live replacement remains, in the saved share")
	assert(world.focusWrites == 0, "repeated restart recovery never navigates")
end

-- A blank leftover from a Tern restart never rendered Attention in this VM: the user closing it, whether
-- its capture is still pending or already blank, does not hide Attention; the tab gets a replacement in place.
for _, capture in { "pending", "blank" } do
	local world = native(true)
	world:advance(3100)
	local first = world.opens[1].pane
	local ratio = world.root.ratio
	restoreBlank(world, { first })
	world.holdCaptures = capture == "pending"
	world:reload(); world:advance(1100)
	assert(#world.opens == 1 and world.restored[first], capture .. ": the restored leftover is still open before recovery")
	world:closePane(first); world:advance(100)
	local saved = world.prefs.instances["local"]["3"]
	assert(not saved.userHidden and saved.pane == nil and saved.remnants == nil and saved.placement == nil,
		capture .. ": closing a restored leftover neither hides Attention nor keeps the pane recorded")
	world:advance(3100)
	local replacement = world.opens[2] and world.opens[2].pane
	assert(#world.opens == 2 and world.membership[replacement] == 3 and world.root.split == "right"
		and world.root[1].pane == replacement and math.abs(world.root.ratio - ratio) < 0.01 and #world.closes == 0,
		capture .. ": the selected tab remounts Attention in place with its saved orientation and share")
	world:reload(); world:advance(3100)
	saved = world.prefs.instances["local"]["3"]
	assert(#world.opens == 2 and saved.pane == replacement and not saved.userHidden,
		capture .. ": the replacement is stable across reload")
	assert(world.focusWrites == 0 and world.focused == 10, capture .. ": leftover closure recovery never moves focus")
end

-- A canvas this VM opened is functioning Attention even while its metadata lags: closing it hides the tab.
do
	local world = native(true)
	world.metadataDelay = 7000
	world:advance(2100)
	local pane = world.opens[1] and world.opens[1].pane
	assert(pane and world.prefs.instances["local"]["3"].creating, "creation is accepted while metadata lags")
	world:closePane(pane); world:advance(100)
	local saved = world.prefs.instances["local"]["3"]
	assert(saved.userHidden and saved.pane == nil and not saved.creating,
		"closing a freshly opened canvas hides Attention before its metadata arrives")
	world:advance(8000)
	assert(#world.opens == 1, "the hidden tab is not recreated")
	world:reload(); world:advance(3100)
	assert(#world.opens == 1 and world.prefs.instances["local"]["3"].userHidden, "the hide survives reload")
	assert(world.focusWrites == 0, "hiding never moves focus")
end

-- Startup is self-initializing without window_start, and disabling releases both
-- the queued reconcile callback and recurring heartbeat before re-enabling.
do
	local world = native(false)
	world:advance(0)
	assert(world:activeTimers() == 0 and #world.opens == 0, "disabled startup must not poll or create")
	world:advance(5000)
	assert(world.inventoryReads == 0 and world.nativeWrites == 0 and world:activeTimers() == 0,
		"shortcut confirmation while disabled must not schedule inventory or pane work")
	world:command("enable")
	world:advance(3100)
	assert(#world.opens == 1 and world:activeTimers() == 1, "enable must start one heartbeat chain")
	world:command("open")
	assert(world:activeTimers() == 2, "open must queue one coalesced pass without duplicating heartbeat")
	world:command("disable")
	assert(world:activeTimers() == 0 and not world.prefs.enabled, "disable must cancel all scheduled work")
	local passes = world:inspect().counters.passes
	world:advance(5000)
	assert(world:inspect().counters.passes == passes, "disabled callbacks must not reconcile")
	world:command("enable")
	world:advance(100)
	assert(#world.opens == 1 and world:activeTimers() == 1, "re-enable must reuse existing rail and one timer chain")
end

-- Native metadata is sufficient for ownership. A content-reader failure must
-- not prevent a valid row from focusing its agent.
do
	local world = native(true)
	world:advance(3100)
	local opened = world.opens[1]
	world.contentInspectionUnavailable = true
	world.focused = opened.pane
	world:click(opened.pane, rowAction(opened.options.view))
	assert(world.focused == 10, "metadata-backed navigation must not depend on full canvas content inspection")
end

-- The native hard budget can abort a callback without returning through its
-- pcall. Its resumption must restore both live rendering and the heartbeat.
do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world:interruptNextPass()
	world.focused = pane
	world:click(pane, rowAction(shown(world, pane)))
	assert(world.focused == 10, "a still-visible valid row must stay actionable during budget recovery")
	world.agentState = "idle"
	world.now += 5000
	world:budget("resumed")
	world:advance(100)
	assert(rowAction(shown(world, pane)) == nil,
		"budget recovery must replace the interrupted view with the current attention state")
	local reads = world.inventoryReads
	world:advance(1100)
	assert(world.inventoryReads > reads and world:activeTimers() == 1,
		"budget recovery must retain one live heartbeat")
	world:interruptNextPass()
	world:command("disable")
	local writes = world.nativeWrites
	world.now += 5000
	world:budget("resumed")
	world:advance(1100)
	assert(world:activeTimers() == 0 and world.nativeWrites == writes,
		"late budget resumption must not restart disabled work")
end

-- Budget recovery retains layout intent and the last observed divider, rather
-- than adopting a fresh layout state that overwrites an unobserved manual drag.
do
	local world = native(true)
	world:advance(4100)
	world.root.ratio = 0.39
	world:budget("paused")
	world.now += 5000
	world:budget("resumed")
	world:advance(3100)
	assert(math.abs(world.root.ratio - 0.39) < 0.000001,
		"budget recovery must preserve a native manual divider change")
	assert(math.abs(world.prefs.defaults.shares.left["local"] - 0.39) < 0.000001
		and world.prefs.instances["local"]["3"].shares == nil,
		"a manual share is retained as the host's width, never per tab")
	assert(world.focusWrites == 0 and world:activeTimers() == 1,
		"layout recovery must preserve typing focus and one heartbeat")
end

-- Diagnostics is an explicit command, not a poll/export, and cannot mutate rail
-- state, preferences, focus, timers, or the native inventory on success/failure.
do
	local world = native(true)
	world:advance(140000)
	assert(world.fileWrites == 0 and next(world.files) == nil,
		"startup and idle must never write diagnostics")
	local writes, reads, timers = world.nativeWrites, world.inventoryReads, #world.timers
	world:inspect()
	local path = "/native/attention-data/diagnostics.json"
	local bytes = world.files[path]
	local toast = world.toasts[#world.toasts]
	assert(toast.kind == "success" and toast.message == path, "successful diagnostics must notify its actual path")
	assert(world.nativeWrites == writes and world.inventoryReads == reads and #world.timers == timers,
		"diagnostics must not scan, render, persist preferences, alter layout, or add timers")
	world:advance(5000)
	assert(world.fileWrites == 1 and world.files[path] == bytes, "idle must not refresh the saved snapshot")
	world.failWrite = true
	writes, reads, timers = world.nativeWrites, world.inventoryReads, #world.timers
	for _ = 1, 2 do
		local notifications = #world.toasts
		world:command("diagnostics")
		toast = world.toasts[#world.toasts]
		assert(#world.toasts == notifications + 1 and toast.kind == "error"
			and string.find(toast.message, "diagnostics disk unavailable", 1, true),
			"every failed explicit write must surface the real error")
	end
	assert(world.fileWrites == 1 and world.files[path] == bytes, "failed write must not claim or replace a snapshot")
	assert(world.nativeWrites == writes and world.inventoryReads == reads and #world.timers == timers,
		"diagnostics errors must not affect the rail")
end

-- Attention on the phone: the owner window publishes its queue to `phone.json`; nothing else writes it, and a
-- failure or a quiet queue never turns into write spam.
local function phoneWarnings(world)
	local count = 0
	for _, warning in world.warnings do if string.find(warning, "Phone queue not published", 1, true) then count += 1 end end
	return count
end

do
	local phone = require("../phone")

	-- Published once the owner pass has a coherent queue; the queue is the desktop's own.
	local world = native(true)
	world:advance(3100)
	local first = world:phoneSnapshot()
	local accepted = phone.validate(first)
	assert(accepted ~= nil and first.schema == 2 and first.status == "ok" and first.host == "Desktop", "the owner publishes a valid schema-2 snapshot")
	assert(first.revision == 1 and world.phoneWrites == 1, "the first content is revision 1, written once")
	assert(first.counts.attention == 1 and #first.rows == 1 and first.rows[1].section == "attention"
		and first.rows[1].state == "Waiting for input" and first.rows[1].localHost == true,
		"the waiting conversation is the one Attention row")
	assert(first.rows[1].pane == 10 and first.rows[1].placement == "tiled", "the row names its native pane")
	assert(world.focusWrites == 0 and world.focused == 10, "publishing never moves native focus")
	world:advance(20000)
	assert(world.phoneWrites == 1, "a quiet queue is not rewritten before the heartbeat")
	world:advance(10000)
	local beat = world:phoneSnapshot()
	assert(world.phoneWrites == 2 and beat.revision == first.revision and beat.generatedUtc > first.generatedUtc,
		"the heartbeat refreshes the time and keeps the revision")
	local writes = world.phoneWrites
	world.agentState = "working"
	world:advance(1100)
	local changed = world:phoneSnapshot()
	assert(world.phoneWrites == writes + 1 and changed.revision == beat.revision + 1 and changed.counts.attention == 0
		and changed.counts.working == 1 and #changed.rows == 1 and changed.rows[1].section == "working",
		"a live working conversation is published at once with the next revision")
	-- Reload revalidates native bindings; once observed again, the live Working queue is restored.
	world:reload()
	world:advance(1100)
	local restored = world:phoneSnapshot()
	assert(restored.status == "ok" and restored.counts.working == 1 and restored.counts.attention == 0
		and #restored.rows == 1 and restored.rows[1].pane == 10 and restored.rows[1].section == "working",
		"a reload restores the observed working conversation without changing its route")
	world.agentState = "waiting_input"
	world:advance(1100)
	local waiting = world:phoneSnapshot()
	assert(waiting.counts.working == 0 and waiting.counts.attention == 1
		and #waiting.rows == 1 and waiting.rows[1].section == "attention" and waiting.rows[1].pane == 10,
		"a waiting-input observation moves the same conversation from Working to Attention")
end

do
	local world = native(false)
	world:advance(10000)
	assert(world.phoneBytes == nil and world.phoneWrites == 0, "a disabled window with no owner publishes nothing")
	world = native(true)
	world.prefs.owner = "another-window"
	world:advance(10000)
	assert(world.phoneBytes == nil and world.phoneWrites == 0, "a window that does not own Attention never publishes")
end

do
	-- Ownership moving to another window leaves the file to the new owner; Attention being disabled says so once.
	local world = native(true)
	world:advance(3100)
	local writes, bytes = world.phoneWrites, world.phoneBytes
	world.prefs.owner = "another-window"
	world:advance(5000)
	assert(world.phoneWrites == writes and world.phoneBytes == bytes, "the previous owner no longer touches the file")
	world = native(true)
	world:advance(3100)
	world.prefs.enabled = false
	world:advance(2100)
	assert(world:phoneSnapshot().status == "disabled", "an owner that finds Attention disabled says so")
	writes = world.phoneWrites
	world:advance(60000)
	assert(world.phoneWrites == writes, "and says it once")
end

do
	local phone = require("../phone")
	local world = native(true)
	world:advance(3100)
	local before = world:phoneSnapshot()
	world:command("disable")
	local disabled = world:phoneSnapshot()
	assert(phone.validate(disabled) ~= nil and disabled.status == "disabled" and #disabled.rows == 0
		and disabled.counts.attention == 0 and disabled.revision == before.revision + 1
		and disabled.host == before.host and disabled.reason ~= nil, "disabling tells the phone, once")
	local writes = world.phoneWrites
	world:advance(120000)
	assert(world.phoneWrites == writes, "a disabled window keeps no heartbeat")
	world:command("enable")
	world:advance(1100)
	local resumed = world:phoneSnapshot()
	assert(resumed.status == "ok" and resumed.revision == disabled.revision + 1 and #resumed.rows == 1,
		"enabling publishes the queue again")
end

do
	local phone = require("../phone")
	local world = native(true)
	world.failInventory = true
	world:advance(3100)
	local unavailable = world:phoneSnapshot()
	assert(phone.validate(unavailable) ~= nil and unavailable.status == "unavailable" and #unavailable.rows == 0
		and unavailable.reason == "native inventory unavailable", "an unreadable workspace is stated, not shown as empty")
	local writes = world.phoneWrites
	world:advance(10000)
	assert(world.phoneWrites == writes, "the same problem is not rewritten")
	world.failInventory = false
	world:advance(1100)
	assert(world:phoneSnapshot().status == "ok" and #world:phoneSnapshot().rows == 1, "recovery publishes the queue again")

	world = native(true)
	world.failTriageRead = true
	world.triageReadMessage = "triage store unreadable at /Users/someone/private/state.json"
	world:advance(3100)
	local storage = world:phoneSnapshot()
	assert(storage.status == "unavailable" and string.find(storage.reason, "Saved attention is unavailable", 1, true)
		and not string.find(storage.reason, "/Users", 1, true), "a storage problem is stated in plain words without paths")
end

do
	local world = native(true)
	world.failPhoneWrite = true
	world:advance(8000)
	assert(world.phoneWrites == 0 and world.canvases[world.opens[1].pane] ~= nil,
		"a failed phone write never breaks the pass or the rail")
	assert(phoneWarnings(world) == 1, "a failure is reported once, not on every pass")
	world.failPhoneWrite = false
	world:advance(1100)
	assert(world.phoneWrites == 1 and world:phoneSnapshot().revision == 1, "the next pass retries and publishes")
	world.failPhoneWrite = true
	world.agentState = "working"
	world:advance(1100)
	world.failPhoneWrite = false
	world:advance(1100)
	assert(world:phoneSnapshot().revision == 2 and world:phoneSnapshot().counts.attention == 0,
		"a change that could not be written is published, as one revision, once the disk works")
end

do
	local phone = require("../phone")

	-- Quiet passes reuse the written snapshot wholesale: no row construction, no comparison, no rewrite. Real
	-- input changes rebuild and publish, and the minute bucket keeps a reused build from aging past a minute.
	local world = native(true)
	world.phoneBuilds = 0
	local realSnapshot = phone.snapshot
	phone.snapshot = function(...) world.phoneBuilds += 1; return realSnapshot(...) end
	world:advance(3100)
	assert(world:phoneSnapshot().revision == 1 and world.phoneWrites == 1, "fixture: the queue is published once")
	local builds = world.phoneBuilds
	world:advance(2000)
	assert(world.phoneBuilds == builds and world.phoneWrites == 1,
		"two quiet passes construct no phone rows and rewrite nothing")
	world.agentTitle = "Renamed agent"
	world:emit("title", { pane = 10 }); world:advance(100)
	local retitled = world:phoneSnapshot()
	assert(world.phoneBuilds == builds + 1 and world.phoneWrites == 2 and retitled.revision == 2
		and retitled.rows[1].title == "Renamed agent",
		"a pane title change rebuilds the rows and publishes the next revision")
	world.tabs[3].name = "Renamed tab"
	world:advance(1100)
	local renamed = world:phoneSnapshot()
	assert(world.phoneBuilds == builds + 2 and world.phoneWrites == 3 and renamed.revision == 3
		and renamed.rows[1].tab == "Renamed tab",
		"a tab rename rebuilds through the workspace fingerprint and publishes the renamed row")
	local writes = world.phoneWrites
	world.utcShift += 60000 - ((1700000000 + world.utcShift + math.floor(world.now / 1000)) % 60000)
	world:advance(1000)
	assert(world.phoneBuilds == builds + 3 and world.phoneWrites == writes,
		"a minute rollover rebuilds once and rewrites nothing before the heartbeat")
	phone.snapshot = realSnapshot
end

do
	local world = native(true)
	world:advance(3100)
	local handler = world.linkHandler
	assert(handler ~= nil, "the desktop window claims links")
	local focus, writes = world.focused, world.focusWrites
	for _, url in ipairs({ "attention://jump?p=10&h=Desktop&t=&c=&g=", "attention://ping", "ATTENTION://jump?p=1&h=x" }) do
		local decision = handler({ url = url, pane = 10, mods = { cmd = false, alt = false, shift = false, ctrl = false } }, nil)
		assert(decision ~= nil and decision.handled == true and decision.url == nil and decision.path == nil
			and decision.block == nil, "Attention links are swallowed: " .. url)
	end
	for _, url in ipairs({ "https://example.com/attention://", "attention:jump", "mailto:a@b.c", "", "attention:/" }) do
		assert(handler({ url = url, pane = 10, mods = {} }, nil) == nil, "other links keep their built-in handling: " .. url)
	end
	assert(handler({ pane = 10, mods = {} }, nil) == nil and handler(nil, nil) == nil, "malformed requests are left alone")
	assert(world.focused == focus and world.focusWrites == writes, "a swallowed link changes nothing on the desktop")

	local other = native(true, "ios")
	assert(other.linkHandler == nil, "the iOS client runs no window half here")
end

do
	local world = native(true)
	world.prefs = { enabled = true, owner = "desktop", shares = { ["local"] = 0.39 }, suppressed = {} }
	world:advance(3100)
	local pane = world.opens[1].pane
	assert(world.prefs.schema == 4 and world.prefs.defaults.position == "left" and world.opens[1].options.dir == "left"
		and world.root.split == "right" and world.root[1].pane == pane and world.root[2].pane == 10
		and math.abs(world.root.ratio - 0.25) < 0.02,
		"legacy preferences migrate and the rail mounts on the left, the default position")
	assert(world.prefs.defaults.shares.right["local"] == 0.39 and world.prefs.defaults.shares.bottom["local"] == nil,
		"a legacy width stays a right-edge size and is never reused as a bottom height")
	assert(world.focusWrites == 0, "mounting migrated preferences must not focus an agent")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/controller-agent.jsonl"
	world.agentAlert = true
	world:advance(3100)
	local pane = world.opens[1].pane
	world:click(pane, rowAction(shown(world, pane), "menu")); world:chooseLabel("Finished for now · current scope")
	world:advance(100)
	assert(world:inspect().attentionCount == 0 and world.savedTriage.items[1].disposition == "finished")
	assert(world.agentAlert and world.focusWrites == 0, "Finishing must not acknowledge or focus native attention")
	world:command("next")
	assert(world.focusWrites == 0, "Next attention must exclude Finished work")
end

-- A stored record from the retired Later queue is rewritten as Finished on the first load, not only in memory.
do
	local first = native(true)
	first.identityFiles[10] = "/sessions/controller-agent.jsonl"
	first:advance(3100)
	local stored = copy(first.savedTriage)
	assert(stored and stored.schema == 3 and stored.items[1], "fixture: a saved schema-3 record")
	stored.items[1].disposition, stored.items[1].laterUtc, stored.items[1].laterEpisode = "later", 1, 0
	local world = native(true)
	world.identityFiles[10] = "/sessions/controller-agent.jsonl"
	world.savedTriage = stored
	world:advance(3100)
	local item = world.savedTriage.items[1]
	assert(world.triageWrites >= 1 and item.disposition == "finished" and item.retained == true
		and item.laterUtc == nil and item.laterEpisode == nil, "the Later → Finished migration reaches the store")
end

do
	local world = native(true)
	world.savedTriage = { schema = 777, preserved = "operator data" }
	world:advance(3100)
	assert(world:inspect().status == "unavailable" and world.savedTriage.schema == 777,
		"malformed saved triage must be explicit and must not be overwritten")
	world.savedTriage = nil
	-- Hydration first succeeds on the 4000ms heartbeat; only then can the
	-- two-second native-canvas discovery grace begin.
	world:advance(900)
	assert(world.savedTriage.schema == 3 and world.savedTriage.items[1].disposition == "active",
		"the ordinary heartbeat must recover and persist attention without a diagnostics command")
	assert(#world.opens == 0, "storage recovery must not bypass native-canvas discovery")
	world:advance(1999)
	assert(#world.opens == 0, "the discovery grace starts with a usable inventory, not failed hydration")
	world:advance(1)
	assert(#world.opens == 1, "recovered storage must automatically mount the panel after discovery")
	local pane = world.opens[1].pane
	local setAside = rowAction(shown(world, pane), "menu")
	assert(setAside and rowAction(shown(world, pane)),
		"automatic recovery must publish usable Open and More actions before diagnostics")
	world:advance(100)
	assert(world:inspect().attentionCount == 1 and world:inspect().status == "ready",
		"recovered storage must restore ready attention")
	world.failTriageWrite = true
	world:click(pane, rowAction(shown(world, pane), "menu")); world:chooseLabel("Finished for now · current scope")
	world:advance(100)
	local unsaved = world:inspect()
	assert(unsaved.status == "unsaved" and unsaved.count == 1 and unsaved.attentionCount == 0
		and world.savedTriage.items[1].disposition == "active",
		"a failed save keeps the exact count under an unsaved status, never durable success")
	world.failTriageWrite = false
	world:advance(1100)
	assert(world.savedTriage.items[1].disposition == "finished" and world:inspect().status == "ready",
		"a pending Finished must persist when storage returns")
	local writes = world.nativeWrites
	world:advance(5000)
	assert(world.nativeWrites == writes, "unchanged idle attention must not write canvas, layout, preferences, or triage")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12, 8, 9)
	world:advance(3100)
	local first = world.opens[1].pane
	local triageWrites = world.triageWrites
	world:switch(4)
	world:advance(3100)
	local second = world.opens[2].pane
	assert(first ~= second and world.membership[first] == 3 and world.membership[second] == 4,
		"each visited tab owns a stationary pane")
	local writes = world.layoutWrites
	for _ = 1, 4 do world:switch(3); world:advance(50); world:switch(4); world:advance(50) end
	assert(world.layoutWrites == writes and world.focusWrites == 0, "ready tab switches perform zero layout or focus writes")
	assert(world.triageWrites == triageWrites, "mounting and switching must preserve saved triage bytes")
	world:closePane(first)
	world:advance(100)
	assert(world.prefs.instances["local"]["3"].userHidden and not world.prefs.instances["local"]["4"].userHidden,
		"closing Attention hides only its own tab")
	world:switch(3); world:advance(3100)
	assert(#world.opens == 2, "hidden tabs must stay hidden on return")
	world:command("open"); world:advance(3100)
	assert(#world.opens == 3 and world.membership[world.opens[3].pane] == 3, "Open recreates only the current hidden tab")
	world:switch(5); world:advance(3100)
	assert(world.prefs.instances["host-8"]["5"].pane == world.opens[4].pane,
		"remote host instances must have independent stable identity")
	assert(world.membership[second] == 4, "host navigation cannot borrow another instance")
end

do
	local world = native(true)
	world:addTab(4, 11, 1, 7)
	world.sessions[2].name, world.sessions[7].name = "Session A", "Session B"
	world.identityFiles[10], world.identityFiles[11] = "/sessions/sticky-a.jsonl", "/sessions/sticky-b.jsonl"
	world.additionalAgents = { [11] = "working" }
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	world:switch(3); world:advance(100)
	local placementWrites = world.layoutWrites

	local function rows(pane, section) return sectionRows(world, pane, section).c end
	local function sectionOpen(pane, section) return not sectionRows(world, pane, section).p.hidden end

	assert(#rows(first, "attention") == 1 and #rows(first, "working") == 1,
		"shared-panel fixture has an Attention and a Working conversation from different native sessions")
	local workingRows = rows(first, "working")
	assert(rowAction(workingRows[1], "menu"), "the Working row offers its tracking menu")
	local workingKey, firstOpen = workingRows[1].p.key, rowAction(workingRows[1], "route-open")

	world:switch(4); world:advance(100)
	assert(#rows(second, "working") == 1 and rows(second, "working")[1].p.key == workingKey
		and rowAction(rows(second, "working")[1], "menu"),
		"shared logical body: session B must render the same working conversation, not its own session queue")
	local secondOpen = rowAction(rows(second, "working")[1], "route-open")
	assert(firstOpen and secondOpen and firstOpen ~= secondOpen,
		"shared logical content must retain independent per-canvas action tokens")

	-- Closing a section is the shared disclosure: it belongs to the window, not to the canvas that was clicked.
	assert(sectionOpen(second, "attention") and sectionOpen(second, "working"), "both queues start open")
	world:toggleQueue(second, "attention"); world:advance(100)
	assert(not sectionOpen(second, "attention") and sectionOpen(second, "working") and #rows(second, "working") == 1,
		"session B closes the Attention section and keeps Working open")
	world:switch(3); world:advance(100)
	assert(not sectionOpen(first, "attention") and sectionOpen(first, "working"),
		"shared logical disclosure: session A must follow the section session B closed")
	assert(#rows(first, "working") == 1 and rows(first, "working")[1].p.key == workingKey
		and rowAction(rows(first, "working")[1], "menu"),
		"shared logical body: session A keeps the working conversation while Attention is closed")
	assert(world.membership[first] == 3 and world.membership[second] == 4
		and world.layoutWrites == placementWrites and world.focusWrites == 0,
		"shared panel selection never moves either physical canvas or focuses an agent")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.root, world.floating[pane], world.floats[3] = { pane = 10 }, true, { { pane = pane } }
	local writes = world.layoutWrites
	world:advance(1100); world:reload(); world:advance(3100)
	assert(world.floating[pane] and world.layoutWrites == writes, "manual floating survives heartbeat and reload")
	world:control(pane, "settings"); world:advance(50)
	assert(world.canvases[pane].view, "floating Attention remains rendered and actionable")
	world:command("open"); world:advance(100)
	assert(world.floating[pane] and #world.opens == 1, "Open reuses a usable floating instance")
	world:command("reset-placement"); world:advance(500)
	assert(not world.floating[pane] and world.root.split == "right", "Reset explicitly restores this tab's outer rail")
	world.root, world.parked[pane] = { pane = 10 }, true
	writes = world.layoutWrites
	world:reload(); world:advance(3100)
	assert(world.parked[pane] and world.layoutWrites == writes, "manual parking survives reload")
	world:switch(4); world:advance(3100)
	assert(#world.opens == 2 and world.parked[pane], "a new tab cannot borrow an assigned parked instance")
	world:switch(3); world:command("open"); world:advance(500)
	assert(not world.parked[pane] and #world.opens == 2 and world.membership[pane] == 3,
		"Open recovers its own parked pane without duplicate creation")
end

do
	local world = native(true)
	world.replicaDelay = 6000
	world:advance(2100)
	assert(#world.opens == 1)
	world:reload(); world:advance(3100); world:command("open"); world:advance(100)
	assert(#world.opens == 1, "reload and Open cannot duplicate an accepted delayed canvas")
	world:advance(4000)
	assert(#world.opens == 1 and world:inspect().instances[1].pending == false,
		"late ownership metadata must settle the accepted instance")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	world:closePane(10); world:advance(100)
	assert(not world.canvases[first] and world.canvases[second], "last-content closure retires only the owned canvas")
	world:emit("tab_closed", { tab = 3 }); world.tabs[3] = nil; world:advance(100)
	assert(world.prefs.instances["local"]["3"] == nil, "confirmed closed tabs leave no registry entry")
	world:emit("tab_closed", { tab = 4 })
	world:advance(100)
	assert(not world.canvases[second], "tab closure before pane replica removal must retire its owned canvas")
end

do
	-- Retiring the last tab of a host also removes its now-empty host bucket, so preferences never persist a
	-- dead host key.
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	world:switch(4); world:advance(3100)
	assert(world.prefs.instances["local"]["3"] ~= nil and world.prefs.instances["local"]["4"] ~= nil,
		"fixture: both tabs of the local host are registered")
	world:closePane(10); world:advance(100)
	world:emit("tab_closed", { tab = 3 }); world.tabs[3] = nil; world:advance(100)
	assert(world.prefs.instances["local"]["3"] == nil and world.prefs.instances["local"]["4"] ~= nil,
		"one retired tab leaves the host bucket to its surviving tab")
	world:emit("tab_closed", { tab = 4 }); world:advance(100)
	assert(world.prefs.instances["local"] == nil,
		"retiring the host's last tab removes its empty bucket from persisted preferences")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world.membership[12], world.paneHosts[12] = 3, 1
	world.root = { split = "right", ratio = 0.63, [1] = { pane = 10 }, [2] = { pane = 12 } }
	world.failMove = true
	world:advance(3100)
	local first = world.opens[1].pane
	world.failMove = false
	world:switch(4); world:advance(3100)
	assert(#world.opens == 2 and world.membership[first] == 3 and world.layouts[4].split == "right"
		and world.layouts[4][1].pane == world.opens[2].pane,
		"failed initial placement is terminal and scoped to its tab")
	local writes = world.layoutWrites
	world:switch(3); world:advance(1100)
	assert(world.layoutWrites == writes, "failed placement cannot retry on ordinary focus")
	world:command("reset-placement"); world:advance(500)
	assert(world.root.split == "right" and world.root[1].pane == first, "explicit Reset retries failed same-tab placement")
end

do
	local world = native(true)
	world.zoomed = true
	world:advance(3100)
	assert(#world.opens == 0, "automatic mounting must defer while zoomed")
	world.zoomed = false
	world.floating[10] = true
	world:advance(3100)
	assert(#world.opens == 0, "automatic mounting must defer for floating focus")
	world.floating[10] = nil
	world:advance(3100)
	assert(#world.opens == 1 and world.focusWrites == 0, "eligibility mounts without a focus hop")
end

-- The only reset is the palette command, and it resets the tab the Mac is showing: another tab's rail is untouched.
do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	local untouched, otherWrites = copy(world.root), world.layoutWritesByTab[3] or 0
	world.layouts[4].ratio = 0.38
	world:command("reset-placement"); world:advance(500)
	assert(world.root.split == untouched.split and world.root.ratio == untouched.ratio
		and (world.layoutWritesByTab[3] or 0) == otherWrites,
		"Reset placement (this tab) changes only the focused tab even while another tab's rail was opened")
	assert(math.abs(world.layouts[4].ratio - 0.25) < 0.02 and world.prefs.instances["local"]["3"].shares == nil
		and world.prefs.instances["local"]["4"].shares == nil, "Reset applies the host's rail width; no tab keeps its own")
	assert(world.prefs.instances["local"]["3"].position == "left" and world.prefs.instances["local"]["4"].position == "left",
		"each tab records the edge its rail occupies")
	local sets = world.canvasSets
	world:command("disable")
	assert(world.canvasSets == sets + 2 and world:activeTimers() == 0, "global Disable repaints every rail once and stops work")
	world:advance(5000)
	assert(world.canvasSets == sets + 2, "disabled rails never repaint on a timer")
	world:command("enable"); world:advance(3100)
	assert(#world.opens == 2 and world.canvases[first] and world.canvases[second],
		"global re-enable adopts all existing per-tab canvases")
end

do
	local world = native(true)
	world.failOpen, world.replicaDelay = "accepted-throw", 6000
	world:advance(2100)
	assert(#world.opens == 1 and world.prefs.instances["local"]["3"].creating,
		"uncertain accepted creation retains a durable identity-discovery intent")
	world:reload(); world:advance(3100); world:command("open"); world:advance(100)
	assert(#world.opens == 1, "an interrupted native return cannot authorize a duplicate")
	world:advance(4000)
	assert(#world.opens == 1 and not world.prefs.instances["local"]["3"].creating
		and world.prefs.instances["local"]["3"].pane == world.opens[1].pane,
		"late creation metadata recovers the same accepted pane across reload")
end

do
	local world = native(true)
	world.failOpen = "throw"
	world:advance(3100)
	world:command("open"); world:advance(3100)
	local info = world:inspect().instances[1]
	assert(world.attempts == 1 and info.pending and string.find(info.status, "metadata", 1, true),
		"unconfirmed throws expose the recovery boundary rather than duplicate an uncertain native operation")
end

for _, collision in { false, true } do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	local second = nil
	if collision then world:switch(4); world:advance(3100); second = world.opens[2].pane end
	world.root = { pane = 10 }
	world.membership[first] = 4
	world.layouts[4] = { split = "right", ratio = 0.6, [1] = world.layouts[4], [2] = { pane = first } }
	local writes = world.layoutWrites
	world:advance(1100)
	assert(world.prefs.instances["local"]["4"].pane == first and world.prefs.instances["local"]["3"].userHidden,
		"manual cross-tab movement transfers registry association and hides its original tab")
	assert(world.layoutWrites == writes + (if collision then 1 else 0),
		"manual movement never enforces geometry; only a positively owned displaced duplicate is parked")
	if second then assert(world.parked[second] and world.prefs.instances["local"]["3"].pane == second) end
	world:emit("tab_closed", { tab = 3 }); world.tabs[3] = nil; world.membership[10] = nil; world:advance(100)
	assert(world.canvases[first] and world.membership[first] == 4,
		"closing the original tab must not close the manually moved canvas")
end

do
	local world = native(true)
	world:advance(3100)
	local pane, writes = world.opens[1].pane, world.layoutWrites
	world.failInventory = true
	world:advance(3100)
	assert(not world.prefs.instances["local"]["3"].userHidden and #world.opens == 1 and world.layoutWrites == writes,
		"unavailable inventory never means hidden or missing and never drives layout")
	world.failInventory = false
	world:advance(1100)
	assert(world.prefs.instances["local"]["3"].pane == pane and #world.opens == 1,
		"coherent inventory resumes the same instance")
end

do
	local world = native(true)
	world.prefs = { schema = 2, enabled = true, owner = "desktop", position = "right", backlogAfterSeconds = 43200,
		shares = { bottom = { ["local"] = 0.3 }, right = { ["local"] = 0.4 } }, suppressed = { ["local"] = true } }
	world:addTab(4, 11)
	world:advance(3100); world:switch(4); world:advance(3100)
	assert(world.prefs.schema == 4 and world.prefs.owner == "desktop" and world.prefs.backlogAfterSeconds == nil
		and #world.opens == 0, "migration preserves owner and conservative host suppression and drops the retired age cutoff")
	world:command("open"); world:advance(500)
	local pane = world.opens[1] and world.opens[1].pane
	assert(#world.opens == 1 and world.prefs.instances["local"]["4"].pane == pane
		and world.prefs.instances["local"]["4"].position == "right"
		and world.prefs.defaults.position == "right" and world.prefs.defaults.shares.right["local"] == 0.4
		and world.prefs.defaults.shares.bottom["local"] == 0.3,
		"explicit Open overrides suppression only for its tab, at the migrated position and size")
	assert(world.layouts[4].split == "right" and world.layouts[4][2].pane == pane and world.layouts[4][1].pane == 11
		and math.abs(world.layouts[4].ratio - 0.6) < 0.01, "the migrated right size places the rail on the right")
	world:switch(3); world:advance(3100)
	assert(#world.opens == 1, "opening another tab must not erase migrated suppression")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.membership[11], world.paneHosts[11] = 3, 1
	world.root = { split = "right", ratio = 0.41, [1] = { pane = 10 },
		[2] = { split = "down", ratio = 0.67, [1] = { pane = 11 }, [2] = { pane = pane } } }
	local writes = world.layoutWrites
	world:advance(3100); world:reload(); world:advance(3100)
	assert(world.layoutWrites == writes and world.root.ratio == 0.41
		and world.root[2].ratio == 0.67 and world.root[2][2].pane == pane,
		"manual content splits and leaf-local Attention placement survive heartbeat and reload without enforcement")
	assert(#world.opens == 1 and world.focusWrites == 0, "manual topology remains one usable Attention instance")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	local firstSets, totalSets = world.canvasSetsByPane[first] or 0, world.canvasSets
	world.agentState = "idle"
	world:advance(1100)
	assert(world.canvasSets == totalSets + 2 and (world.canvasSetsByPane[first] or 0) == firstSets + 1,
		"a queue change repaints the active tab at once and each other tab's rail exactly once")
	assert(not rowAction(shown(world, first)) and not rowAction(shown(world, second)),
		"the rail of the tab the Mac is not showing converges to the latest queue without a tab switch")
	world:switch(3); world:advance(50)
	-- The Workspace's current-place marker moves with focus, but only the rail that becomes active repaints for it: the
	-- rail of the tab left behind keeps its frame until its own content changes or it is shown again.
	local secondSets = world.canvasSetsByPane[second] or 0
	assert(world.canvasSets == totalSets + 3 and (world.canvasSetsByPane[first] or 0) == firstSets + 2
		and (world.canvasSetsByPane[second] or 0) == secondSets and not rowAction(shown(world, first)),
		"activating a tab repaints only that tab's rail for the moved current marker")
	local settled = world.canvasSets
	world:advance(1100)
	assert(world.canvasSets == settled, "converged rails stay quiet after the marker moves")
	assert(world:activeTimers() == 1, "converged rails leave only the heartbeat scheduled")
	world.layouts[4], world.floating[second], world.floats[4] = { pane = 11 }, true, { { pane = second } }
	world:switch(4)
	world.focused = second
	world:emit("focus", { pane = second })
	firstSets = world.canvasSetsByPane[first] or 0
	assert(not rowAction(shown(world, second)), "the floating rail begins without an attention target")
	world.agentState = "waiting_input"
	world:advance(1100)
	assert((world.canvasSetsByPane[first] or 0) == firstSets + 1
		and rowAction(shown(world, second)) and rowAction(shown(world, first)),
		"focused floating Attention is active and the other tab's rail catches up once")
end

-- A phone mirrors every rail canvas, not only the one in the tab the Mac is showing, so a rail in another tab must
-- follow the logical state instead of keeping its last frame.
local function mirroredWorld(tabs)
	local world = native(true)
	world.additionalAgents = {}
	for tab = 4, 3 + tabs do
		world:addTab(tab, 7 + tab)
		world.additionalAgents[7 + tab] = "working"
	end
	world:advance(3100)
	local rails = { world.opens[1].pane }
	for tab = 4, 3 + tabs do
		world:switch(tab); world:advance(3100)
		table.insert(rails, world.opens[#world.opens].pane)
	end
	world:switch(3); world:advance(3100)
	for _, rail in rails do
		assert(queueCount(world, rail, "attention") == "1", "fixture: every rail starts showing the one waiting request")
	end
	return world, rails
end

do
	local world, rails = mirroredWorld(4)
	local reads, writes = world.layoutReads, world.layoutWrites
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.layoutReads - reads <= #rails + 1 and world.layoutReads - reads >= #rails,
		"settled rails share per-pass read-only layout observations, not duplicate full layout censuses")
	assert(world.layoutWrites == writes, "observing settled rails never enforces geometry")
	local prefWrites = world.preferenceWrites
	world.root.ratio = 0.37
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.preferenceWrites == prefWrites, "a divider edit is not written on its first observation")
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(math.abs(world.prefs.defaults.shares.left["local"] - 0.37) < 0.000001
		and world.prefs.instances["local"]["3"].shares == nil and world.layoutWrites == writes,
		"the next passes observe a user divider edit, never a cross-pass cache, and record it once it has settled")
	local before, writesByTab = {}, copy(world.layoutWritesByTab)
	for _, rail in ipairs(rails) do
		local tab = world.membership[rail]
		before[tab] = copy(if tab == 3 then world.root else world.layouts[tab])
	end
	world:command("all-tabs-right"); world:advance(3100)
	for index = 2, #rails do
		local tab = world.membership[rails[index]]
		local saved = world.prefs.instances["local"][tostring(tab)]
		local tree, previous = world.layouts[tab], before[tab]
		assert(tree.split == previous.split and tree.ratio == previous.ratio
			and tree[1] and tree[1].pane == previous[1].pane
			and tree[2] and tree[2].pane == previous[2].pane
			and (world.layoutWritesByTab[tab] or 0) == (writesByTab[tab] or 0)
			and saved.position == "left" and saved.moveTo == "right",
			"marking background rails records the move without changing unseen tabs")
	end
	local rightShare = 0.25
	for _, rail in ipairs(rails) do
		local tab = world.membership[rail]
		world:switch(tab); world:advance(2100)
		local tree = if tab == 3 then world.root else world.layouts[tab]
		local saved = world.prefs.instances["local"][tostring(tab)]
		assert(tree.split == "right" and tree[2] and tree[2].pane == rail
			and saved.position == "right" and saved.moveTo == nil and saved.placement == nil and saved.shares == nil
			and (world.layoutWritesByTab[tab] or 0) > (writesByTab[tab] or 0)
			and math.abs(tree.ratio - (1 - rightShare)) < 0.02,
			"an eligible visit moves and resizes its rail to the host's width for that edge, with no per-tab size")
		tree.ratio = 0.63
		world:emit("cwd", { pane = world.tabs[tab].content }); world:advance(32)
		reads, writes = world.layoutReads, world.layoutWrites
		local inventories = world.inventoryReads
		world:emit("cwd", { pane = world.tabs[tab].content }); world:advance(32)
		local passes = world.inventoryReads - inventories
		assert(passes > 0 and world.layoutReads - reads >= #rails * passes
			and world.layoutReads - reads <= (#rails + 1) * passes,
			"each observed pass keeps bounded layout reads even when multiple scheduled passes share the interval")
		assert(math.abs(world.prefs.defaults.shares.right["local"] - 0.37) < 0.000001
			and world.layoutWrites == writes and tree.ratio == 0.63,
			"after native move/resize, a settled user divider edit is recorded as the host's width without enforcing geometry")
		rightShare = 0.37
	end
end

do
	local world = mirroredWorld(4)
	world:advance(5000)
	assert(world:activeTimers() == 1, "fixture: the settled world keeps only the heartbeat scheduled")
	local reads = world.preferenceReads
	world:advance(1000)
	assert(world.preferenceReads - reads == 1,
		"a settled owner heartbeat parses the preference document exactly once for its pass")
end

do
	local world, rails = mirroredWorld(4)
	local writes = world.preferenceWrites
	for _, rail in ipairs(rails) do
		local tab = world.membership[rail]
		-- A left rail's share is its tab's root ratio; editing every root observes every rail at once.
		local tree = if tab == 3 then world.root else world.layouts[tab]
		tree.ratio = 0.29
	end
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.preferenceWrites == writes, "a changed divider is written only once it has settled")
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.preferenceWrites - writes == 1,
		"one pass settling every rail's divider commits the host's width in a single write")
	assert(math.abs(world.prefs.defaults.shares.left["local"] - 0.29) < 0.000001, "the settled divider width is recorded")
	for _, rail in ipairs(rails) do
		assert(world.prefs.instances["local"][tostring(world.membership[rail])].shares == nil, "no rail keeps its own width")
	end
	world:reload(); world:advance(3100)
	assert(math.abs(world.prefs.defaults.shares.left["local"] - 0.29) < 0.000001, "the host's width persists across reload")
end

-- A focus change repaints only the rail in the active tab: a background rail keeps its frame until it becomes active or
-- its own content changes. The settle advance lets every rail's first paint land before the snapshot; the walk after it
-- stays well inside `catchup.REFRESH_MS` (10 s), after which any background rail is re-rendered on purpose
-- to pick up slow inputs such as the pinned location line.
do
	local world, rails = mirroredWorld(3)
	world:advance(3100)
	local untouched = rails[4]
	local sets = world.canvasSetsByPane[untouched] or 0
	for _, tab in ipairs({ 5, 4, 3 }) do
		world:switch(tab); world:advance(100)
	end
	assert((world.canvasSetsByPane[untouched] or 0) == sets, "a focus change never repaints a background rail")
end
local function setSecondRequest(world, waiting)
	local state = if waiting then "waiting_input" else "working"
	world.additionalAgents[11] = state
	world:emit("agent_state", { pane = 11, old = if waiting then "working" else "waiting_input", new = state })
end

do
	local world, rails = mirroredWorld(4)
	local sets = copy(world.canvasSetsByPane)
	world.canvasPaints = {}
	local reads = world.paneListReads
	setSecondRequest(world, true)
	world:advance(200)
	-- One visible change stales every hidden rail; they catch up from that pass's data, not one full pass each.
	local hidden = 0
	for _, paint in world.canvasPaints do if paint.pane ~= rails[1] then hidden += 1 end end
	assert(hidden == #rails - 1 and world.paneListReads - reads < hidden,
		"hidden rails catch up from the pass's data, not one inventory read per rail")
	world:advance(800)
	for index, rail in rails do
		assert(queueCount(world, rail, "attention") == "2", "every tab's rail reaches the new count without a tab switch")
		-- The visible rail also pulses for the arrival and retires the pulse; a background rail is painted exactly once.
		if index > 1 then
			assert((world.canvasSetsByPane[rail] or 0) == (sets[rail] or 0) + 1, "each background rail is painted once, never repeatedly")
		end
	end
	assert(world.canvasPaints[1].pane == rails[1], "the rail the Mac is showing is painted first")
	local perPass = {}
	for _, paint in world.canvasPaints do
		assert(paint.role ~= "attention.rows-arrival" and paint.role ~= "attention.rows-arrival-again"
			or paint.pane == rails[1], "a catch-up paint carries no arrival pulse")
		if paint.pane ~= rails[1] then perPass[paint.at] = (perPass[paint.at] or 0) + 1 end
	end
	for at, count in perPass do assert(count == 1, "pass at " .. tostring(at) .. " painted more than one background rail") end
	local settled = world.canvasSets
	world:advance(5000)
	assert(world.canvasSets == settled and world:activeTimers() == 1,
		"once every rail is current nothing is painted and no catch-up pass stays scheduled")
end

-- A quiet window rebuilds almost nothing: a rail whose render inputs are unchanged skips the render, so over a minute
-- the rail in view renders once per 10 s clock bucket (its ages) and each hidden rail about once (60 s bucket), instead
-- of a render every heartbeat and every hidden-rail refresh. Any input change still renders at once.
do
	local world, rails = mirroredWorld(4)
	world:advance(5000)
	local before = world:inspect().counters.renders
	world:advance(60000)
	local quiet = world:inspect().counters.renders - before
	assert(quiet <= 7 + 2 * (#rails - 1), "a quiet minute renders per clock bucket, not per pass: " .. tostring(quiet))
	before = world:inspect().counters.renders
	setSecondRequest(world, true)
	world:advance(100)
	assert(world:inspect().counters.renders > before and queueCount(world, rails[1], "attention") == "2",
		"a changed input renders and shows in the same pass")
end

-- Rails that keep lagging share the background paints: none is starved by the others. Each round renames every agent
-- (a change that never repeats), so every background pick writes and the per-rail write counts compare fairly.
do
	local world, rails = mirroredWorld(4)
	local sets = copy(world.canvasSetsByPane)
	for round = 1, 60 do
		world.agentTitle = "Agent " .. round
		world:emit("title", { pane = 10 })
		world:advance(32)
	end
	local least, most = math.huge, 0
	for index = 2, #rails do
		local painted = (world.canvasSetsByPane[rails[index]] or 0) - (sets[rails[index]] or 0)
		least, most = math.min(least, painted), math.max(most, painted)
	end
	assert(least > 0 and most - least <= 1, "background rails are served round-robin: " .. tostring(least) .. ".." .. tostring(most))
	world:advance(2000)
	for _, rail in rails do
		assert(queueCount(world, rail, "attention") == "1", "the burst settles every rail on the final state")
	end
end

-- A pass that already spent its share of the budget, or a native budget report, defers catch-up; the visible rail is
-- never deferred.
do
	local world, rails = mirroredWorld(3)
	local sets = copy(world.canvasSetsByPane)
	world.inventoryCost = 30
	setSecondRequest(world, true)
	world:advance(1500)
	assert(queueCount(world, rails[1], "attention") == "2", "the visible rail is painted however slow the pass")
	for index = 2, #rails do
		assert((world.canvasSetsByPane[rails[index]] or 0) == (sets[rails[index]] or 0)
			and queueCount(world, rails[index], "attention") == "1", "no background rail is painted by an over-budget pass")
	end
	world.inventoryCost = nil
	world:advance(1500)
	for _, rail in rails do
		assert(queueCount(world, rail, "attention") == "2", "cheap passes then catch every rail up")
	end
end

do
	local world, rails = mirroredWorld(3)
	world:budget("paused"); world:budget("resumed")
	setSecondRequest(world, true)
	world:advance(1500)
	assert(queueCount(world, rails[1], "attention") == "2", "the visible rail repaints straight after a budget report")
	for index = 2, #rails do
		assert(queueCount(world, rails[index], "attention") == "1", "background rails wait out a recent budget report")
	end
	world:advance(6000)
	for _, rail in rails do
		assert(queueCount(world, rail, "attention") == "2", "they catch up once the report is old")
	end
end

-- Parked, floating and rails of a disconnected host are not painted; an ordinary background rail beside them is.
do
	local world = native(true)
	world:addTab(4, 11); world:addTab(5, 12); world:addTab(6, 13, 8, 9); world:addTab(7, 14)
	world.additionalAgents = { [11] = "working", [12] = "working", [13] = "working", [14] = "working" }
	world:advance(3100)
	local rails = { world.opens[1].pane }
	for tab = 4, 7 do
		world:switch(tab); world:advance(3100)
		table.insert(rails, world.opens[#world.opens].pane)
	end
	world:switch(3); world:advance(3100)
	local ordinary, parked, remote, floating = rails[2], rails[3], rails[4], rails[5]
	world.layouts[5], world.parked[parked] = { pane = 12 }, true
	world.layouts[7], world.floating[floating], world.floats[7] = { pane = 14 }, true, { { pane = floating } }
	world.hostStates[8] = "disconnected"
	world:advance(1100)
	local sets = copy(world.canvasSetsByPane)
	setSecondRequest(world, true)
	world:advance(1500)
	assert(queueCount(world, ordinary, "attention") == "2", "fixture: an ordinary background rail catches up")
	for _, rail in { parked, remote, floating } do
		assert((world.canvasSetsByPane[rail] or 0) == (sets[rail] or 0), "a parked, floating or offline-host rail is not painted")
	end
	world.hostStates[8] = nil
	world:advance(1500)
	assert(queueCount(world, remote, "attention") == "2", "a reconnected host's rail catches up")
end

do
	local world = native(true)
	world:addTab(4, 11); world:addTab(5, 12)
	for tab, pane in { [3] = 91, [4] = 92, [5] = 93 } do
		world.canvases[pane] = { pane = pane, owner = "attention", about = "attention:tab:v1:2:" .. tostring(tab),
			title = "Attention", view = { k = "col", p = {}, c = {} } }
		world.membership[pane], world.paneHosts[pane] = tab, 1
	end
	world.root = { split = "down", ratio = 0.6, [1] = { pane = 10 }, [2] = { pane = 91 } }
	world.layouts[4] = { split = "down", ratio = 0.6, [1] = { pane = 11 }, [2] = { pane = 92 } }
	world.layouts[5] = { split = "down", ratio = 0.6, [1] = { pane = 12 }, [2] = { pane = 93 } }
	world.prefs = { schema = 4, enabled = true, owner = "desktop",
		defaults = { position = "bottom", shares = { left = {}, bottom = {}, right = {} }, hidden = {} }, uiByWindow = {},
		instances = { ["local"] = {
			["3"] = { tab = 3, session = 2, pane = 91, userHidden = false, position = "bottom" },
			["4"] = { tab = 4, session = 2, pane = 92, userHidden = false, position = "bottom" },
			["5"] = { tab = 5, session = 2, pane = 93, userHidden = true, position = "bottom" } } } }
	world.additionalAgents = { [11] = "working", [12] = "working" }
	world:advance(3100)
	assert(queueCount(world, 92, "attention") == "1" and world.canvasSetsByPane[93] == nil,
		"fixture: the ordinary background rail has caught up and the hidden one has not been written")
	setSecondRequest(world, true)
	world:advance(1500)
	assert(queueCount(world, 92, "attention") == "2" and world.canvasSetsByPane[93] == nil,
		"a user-hidden rail is never painted by catch-up")
end

-- One background rail failing to take a paint breaks neither the visible paint nor the other rails; it is reported
-- once, retried on a growing delay, and recovers when the native side does.
do
	local world, rails = mirroredWorld(3)
	local failing = rails[3]
	world.failCanvasPanes = { [failing] = true }
	local warnings, toasts = #world.warnings, #world.toasts
	world.canvasPaints = {}
	setSecondRequest(world, true)
	world:advance(1500)
	for _, rail in { rails[1], rails[2], rails[4] } do
		assert(queueCount(world, rail, "attention") == "2", "the other rails still converge")
	end
	assert(queueCount(world, failing, "attention") == "1", "the rejected rail keeps its last frame")
	assert(#world.warnings == warnings + 1 and #world.toasts == toasts, "the failure is logged once and never toasted")
	for _, paint in world.canvasPaints do
		assert(paint.notice == nil, "a background failure never puts a notice on a rail the user is looking at")
	end
	local attempts = world.rejectedSets
	world:advance(20000)
	assert(world.rejectedSets <= attempts + 4, "retries back off")
	assert(#world.warnings == warnings + 1 and world:activeTimers() == 1, "a failing streak is reported once and never spins")
	setSecondRequest(world, false)
	world:advance(500)
	assert(queueCount(world, rails[1], "attention") == "1", "the visible rail keeps painting while another rail fails")
	world.failCanvasPanes = nil
	world:advance(32000)
	for _, rail in rails do
		assert(queueCount(world, rail, "attention") == "1", "the rejected rail recovers when the native side accepts writes again")
	end
end

-- Catching a rail up is a paint and nothing else.
do
	local world, rails = mirroredWorld(3)
	world:toggleQueue(rails[1], "attention"); world:advance(40)
	local before = { prefs = world.preferenceWrites, phone = world.phoneWrites, triage = world.triageWrites,
		layout = world.layoutWrites, focus = world.focusWrites, native = world.nativeWrites - world.canvasSets,
		settings = world.settingsWrites }
	world:advance(1000)
	for index = 2, #rails do
		assert(sectionRows(world, rails[index], "attention").p.hidden == true
			and sectionRows(world, rails[index], "working").p.hidden == false,
			"a background rail follows the visible rail's closed section")
	end
	assert(world.preferenceWrites == before.prefs and world.phoneWrites == before.phone and world.triageWrites == before.triage
		and world.layoutWrites == before.layout and world.focusWrites == before.focus
		and world.nativeWrites - world.canvasSets == before.native and world.settingsWrites == before.settings,
		"catch-up writes only canvases: no preference, phone, triage, layout, focus or setting write")
end

do
	local world = native(true)
	world:addTab(5, 12, 8, 9)
	world:advance(3100); world:switch(5); world:advance(3100)
	local pane = world.opens[2].pane
	world.layouts[5], world.parked[pane] = { pane = 12 }, true
	world.hostStates[8] = "disconnected"
	world:advance(1100)
	assert(world.canvases[pane] and not world.prefs.instances["host-8"]["5"].retiring,
		"disconnection alone is unknown availability, not confirmed retirement")
	world:emit("tab_closed", { tab = 5 })
	world.tabs[5], world.membership[12] = nil, nil
	world:reload(); world:advance(1000)
	assert(world.canvases[pane] and world.prefs.instances["host-8"]["5"].retiring,
		"confirmed disconnected-tab retirement survives reload without closing an unavailable pane")
	world.hostStates[8] = "connected"
	world:switch(3); world:advance(1100)
	assert(not world.canvases[pane] and world.prefs.instances["host-8"] == nil,
		"reconnection consumes durable retirement, leaves no owned parked orphan, and drops the empty host bucket")
end

for _, phase in { "placing", "recovering", "failed" } do
	local world = native(true)
	world:addTab(4, 11)
	world.membership[12], world.paneHosts[12] = 3, 1
	world.root = { split = "right", ratio = 0.63, [1] = { pane = 10 }, [2] = { pane = 12 } }
	world.failMove = phase == "failed"
	world:advance(if phase == "placing" then 2000 else 3100)
	local pane = world.opens[1].pane
	if phase == "recovering" then world:command("reset-placement") end
	assert(world:inspect().instances[1].phase == phase, "exercise the requested non-ready lifecycle phase")
	world.root, world.membership[pane] = { pane = 10 }, 4
	world.layouts[4] = { split = "down", ratio = 0.65, [1] = { pane = 11 }, [2] = { pane = pane } }
	world:emit("tab_closed", { tab = 3 })
	world.tabs[3], world.membership[10], world.membership[12] = nil, nil, nil
	local writes = world.layoutWrites
	world:switch(4); world:advance(1100)
	assert(world.canvases[pane] and world.prefs.instances["local"]["4"].pane == pane
		and world.prefs.instances["local"]["3"] == nil and world.layoutWrites == writes,
		"moving a non-ready pane then closing its old tab preserves and adopts the actual destination without layout writes")
end

for _, recovery in { "same-vm", "reload", "rejected-reload", "external-edit", "reset-reload", "reset-zoom-reload" } do
	local world = native(true)
	world.membership[11], world.membership[12], world.paneHosts[11], world.paneHosts[12] = 3, 3, 1, 1
	world.root = { split = "right", ratio = 0.63, [1] = { pane = 10 },
		[2] = { split = "down", ratio = 0.38, [1] = { pane = 11 }, [2] = { pane = 12 } } }
	world:addTab(4, 20)
	world:switch(4); world:advance(3100)
	local otherPane = world.opens[1].pane
	local otherWrites = world.layoutWritesByTab[4] or 0
	local otherRatio = world.layouts[4].ratio
	local terminalRejection = recovery == "rejected-reload" or recovery == "reset-reload" or recovery == "reset-zoom-reload"
	world.throwAfterContentMove = not terminalRejection
	world.rejectContentMove = terminalRejection
	world:switch(3); world:advance(3100)
	local failed = nil
	for _, instance in world:inspect().instances do if instance.tab == 3 then failed = instance end end
	assert((if terminalRejection then world.contentMoveRejects == 1 else world.reconstructionInterrupts == 1)
		and failed and failed.phase == "failed", "exercise a real failed reconstruction after accepted native operations")
	if recovery ~= "same-vm" then
		local writes = world.layoutWrites
		world:reload(); world:advance(1100)
		local restored = nil
		for _, instance in world:inspect().instances do if instance.tab == 3 then restored = instance end end
		assert(restored and restored.phase == "failed" and world.layoutWrites == writes,
			"reload retains failed repair intent without silently adopting or rewriting the partial topology")
	end
	if recovery == "external-edit" then
		world.membership[13], world.paneHosts[13] = 3, 1
		world.root = { split = "right", ratio = 0.44, [1] = world.root, [2] = { pane = 13 } }
		local manualRoot, writes = world.root, world.layoutWrites
		world:command("reset-placement"); world:advance(1100)
		assert(world.root == manualRoot and world.root[2].pane == 13 and world.layoutWrites == writes,
			"restored pending-operation guard refuses to overwrite a manual content edit after interruption")
	else
		world.zoomed = recovery == "reset-zoom-reload"
		world:command("reset-placement")
		if recovery == "reset-reload" or recovery == "reset-zoom-reload" then
			local writes = world.layoutWrites
			if world.zoomed then world:advance(100) end
			world:reload()
			if world.zoomed then
				world:advance(100)
				assert(world.layoutWrites == writes, "zoom defers the persisted Reset without consuming it")
				world.zoomed = false
			end
		end
		world:advance(2000)
		local wrapper = world.root
		assert(wrapper.split == "right" and wrapper[1].pane == failed.pane and math.abs(wrapper.ratio - 0.25) < 0.01,
			"explicit recovery restores the requested outer rail")
		local content = wrapper[2]
		assert(content.split == "right" and content[1].pane == 10 and math.abs(content.ratio - 0.63) < 0.01
			and content[2].split == "down" and content[2][1].pane == 11 and content[2][2].pane == 12
			and math.abs(content[2].ratio - 0.38) < 0.01,
			"Reset resumes the interrupted original unequal topology instead of adopting its partial reconstruction")
		assert(world.prefs.instances["local"]["3"].placement == nil, "settlement releases temporary repair intent")
	end
	assert(world.focused == 10 and world.focusWrites == 0 and (world.layoutWritesByTab[4] or 0) == otherWrites
		and world.layouts[4].ratio == otherRatio and world.layouts[4][1].pane == otherPane,
		"interrupted recovery preserves typing focus and performs no writes in another tab")
end

do
	local world = native(true)
	world.membership[11], world.paneHosts[11] = 3, 1
	world.root = { split = "right", ratio = 0.63, [1] = { pane = 10 }, [2] = { pane = 11 } }
	world:advance(2000)
	assert(#world.opens == 1, "exercise placement after accepted creation but before its first layout write")
	local writes = world.layoutWrites
	world.failPreferenceWrite = true
	world:advance(100)
	assert(world.layoutWrites == writes, "failed durable checkpoint storage prevents forwarding the next native layout write")
	world.failPreferenceWrite = false
	world:command("reset-placement"); world:advance(1100)
	assert(world.root.split == "right" and world.root[1].pane == world.opens[1].pane,
		"checkpoint storage recovery permits explicit completion without another canvas")
end

do
	local world = native(true)
	for _, pane in { 11, 12, 13 } do world.membership[pane], world.paneHosts[pane] = 3, 1 end
	world.root = { split = "right", ratio = 0.61,
		[1] = { split = "right", ratio = 0.31, [1] = { pane = 10 }, [2] = { pane = 11 } },
		[2] = { split = "right", ratio = 0.68, [1] = { pane = 12 }, [2] = { pane = 13 } } }
	world:advance(5100)
	local wrapper = world.root
	assert(wrapper.split == "right" and wrapper[1].pane == world.opens[1].pane,
		"balanced same-axis content receives a full-height outer-left rail")
	local content = wrapper[2]
	local extent = 180 * (1 - wrapper.ratio)
	assert(content.split == "right" and math.abs(content.ratio - 0.61) <= 1.01 / extent
		and content[1].split == "right" and content[1][1].pane == 10 and content[1][2].pane == 11
		and math.abs(content[1].ratio - 0.31) <= 1.01 / (extent * content.ratio)
		and content[2].split == "right" and content[2][1].pane == 12 and content[2][2].pane == 13
		and math.abs(content[2].ratio - 0.68) <= 1.01 / (extent * (1 - content.ratio)),
		"nearest-axis native resizing preserves every original balanced-tree divider within one native cell")
	assert(world.focused == 10 and world.focusWrites == 0 and world:inspect().instances[1].phase == "ready",
		"balanced first placement settles without a focus hop")
end

do
	local world = native(true)
	world.membership[11], world.membership[12], world.paneHosts[11], world.paneHosts[12] = 3, 3, 1, 1
	world.root = { split = "right", ratio = 0.63, [1] = { pane = 10 },
		[2] = { split = "down", ratio = 0.38, [1] = { pane = 11 }, [2] = { pane = 12 } } }
	world.abortAfterContentMove = true
	local thread = coroutine.create(function() world:advance(3100) end)
	local ok, marker = coroutine.resume(thread)
	assert(ok and marker == "native hard budget", "interrupt after an accepted reconstruction move before its callback can save readback")
	assert(coroutine.close(thread))
	assert(world.prefs.instances["local"]["3"].placement.status == "placing", "write-ahead recovery must be durable before the native write")
	world:reload(); world:advance(3100)
	local wrapper = world.root
	local content = wrapper[2]
	assert(wrapper.split == "right" and wrapper[1].pane == world.opens[1].pane
		and content.split == "right" and content[1].pane == 10 and math.abs(content.ratio - 0.63) < 0.01
		and content[2].split == "down" and content[2][1].pane == 11 and content[2][2].pane == 12
		and math.abs(content[2].ratio - 0.38) < 0.01,
		"reload resumes the accepted pending operation and restores the original unequal content tree")
	assert(#world.opens == 1 and world.prefs.instances["local"]["3"].placement == nil
		and world.focused == 10 and world.focusWrites == 0, "active reload recovery neither duplicates nor steals focus")
end

local function equalValue(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in a do if not equalValue(value, b[key]) then return false end end
	for key in b do if a[key] == nil then return false end end
	return true
end

local function toastCount(world, kind, needle)
	local count = 0
	for _, toast in world.toasts do
		if (kind == nil or toast.kind == kind) and string.find(toast.message, needle, 1, true) then count += 1 end
	end
	return count
end

-- Schema 3 migrates in one validated write and keeps every rail's position and size. Whatever edge a rail occupies,
-- it is never relocated, and a hidden tab's rail is never touched.
do
	local world = native(true)
	world:addTab(4, 11); world:addTab(5, 12); world:addTab(6, 13)
	world.membership[14], world.paneHosts[14] = 6, 1
	local function install(tab, pane, tree)
		world.canvases[pane] = { pane = pane, owner = "attention", about = "attention:tab:v1:2:" .. tostring(tab),
			title = "Attention", view = { k = "col", p = {}, c = {} } }
		world.membership[pane], world.paneHosts[pane] = tab, 1
		if tab == 3 then world.root = tree else world.layouts[tab] = tree end
	end
	install(3, 91, { split = "down", ratio = 0.68, [1] = { pane = 10 }, [2] = { pane = 91 } })
	install(4, 92, { split = "right", ratio = 0.7, [1] = { pane = 11 }, [2] = { pane = 92 } })
	install(5, 93, { split = "down", ratio = 0.7, [1] = { pane = 12 }, [2] = { pane = 93 } })
	install(6, 94, { split = "right", ratio = 0.5, [1] = { pane = 13 },
		[2] = { split = "down", ratio = 0.6, [1] = { pane = 14 }, [2] = { pane = 94 } } })
	local function entry(tab, pane, position, share, hidden, placement)
		return { tab = tab, session = 2, pane = pane, userHidden = hidden, position = position,
			shares = { [position] = share }, placement = placement }
	end
	world.prefs = { schema = 3, enabled = true, owner = "desktop",
		defaults = { position = "bottom", shares = { bottom = { ["local"] = 0.3 }, right = {} }, hidden = {} },
		instances = { ["local"] = { ["3"] = entry(3, 91, "bottom", 0.32, false), ["4"] = entry(4, 92, "right", 0.3, false),
			["5"] = entry(5, 93, "bottom", 0.3, true),
			["6"] = entry(6, 94, "bottom", 0.4, false, { status = "placing", checkpoint = { version = 1, tab = 6 }, generation = 1 }) } } }
	local before = { [3] = copy(world.root), [4] = copy(world.layouts[4]), [5] = copy(world.layouts[5]), [6] = copy(world.layouts[6]) }
	world.zoomed = true
	world:advance(100)
	local migrated = world.prefs
	assert(migrated.schema == 4 and world.preferenceWrites == 1 and world.layoutWrites == 0,
		"a schema-3 store migrates in one validated write")
	assert(migrated.defaults.position == "bottom" and migrated.defaults.shares.bottom["local"] == 0.3
		and migrated.defaults.share == nil, "the default position and per-position sizes survive migration")
	for tab, position in { ["3"] = "bottom", ["4"] = "right", ["5"] = "bottom", ["6"] = "bottom" } do
		local saved = migrated.instances["local"][tab]
		assert(saved.position == position and saved.relocate == nil and saved.share == nil and saved.placement == nil,
			"tab " .. tab .. " keeps its position and drops the unreplayed legacy checkpoint")
	end
	assert(migrated.instances["local"]["4"].shares == nil and migrated.instances["local"]["6"].shares == nil,
		"per-tab sizes are dropped; widths live in the host defaults")
	world:reload(); world:advance(100)
	assert(world.preferenceWrites == 1 and equalValue(world.prefs, migrated), "migration is idempotent across reload")
	world.zoomed = false
	world:advance(2100)
	for _, tab in { 4, 5, 6, 3 } do
		world:switch(tab); world:advance(2100)
	end
	for tab, tree in before do
		assert(equalValue(if tab == 3 then world.root else world.layouts[tab], tree) and (world.layoutWritesByTab[tab] or 0) == 0,
			"tab " .. tostring(tab) .. " keeps its rail exactly where it was")
	end
	assert(world.layoutWrites == 0 and world.focusWrites == 0 and #world.opens == 0 and world.settingsWrites == 0,
		"no rail moves, no focus changes, no canvas is created and no native setting is written")
	assert(world.prefs.instances["local"]["5"].userHidden, "a hidden tab stays hidden")
	local settled = copy(world.prefs)
	world:reload(); world:advance(3100)
	assert(equalValue(world.prefs, settled), "a settled store is unchanged by reload")
end

-- The live schema-4 store lost every position in its first migration and marked all 22 rails `relocate`. Loading it
-- strips the flag in one write, adopts each rail at the edge it physically occupies (the default only where it has
-- none) in one more, keeps unknown fields, and never moves anything.
do
	local world = native(true)
	local kinds, entries, before = { "bottom", "right", "left", "nested" }, {}, {}
	for tab = 3, 24 do
		local content = if tab == 3 then 10 else 300 + tab
		local rail = 100 + tab
		if tab ~= 3 then world:addTab(tab, content) end
		world.canvases[rail] = { pane = rail, owner = "attention", about = "attention:tab:v1:2:" .. tostring(tab),
			title = "Attention", view = { k = "col", p = {}, c = {} } }
		world.membership[rail], world.paneHosts[rail] = tab, 1
		local kind, tree = kinds[(tab - 3) % 4 + 1], nil
		if kind == "bottom" then
			tree = { split = "down", ratio = 0.7, [1] = { pane = content }, [2] = { pane = rail } }
		elseif kind == "right" then
			tree = { split = "right", ratio = 0.7, [1] = { pane = content }, [2] = { pane = rail } }
		elseif kind == "left" then
			tree = { split = "right", ratio = 0.3, [1] = { pane = rail }, [2] = { pane = content } }
		else
			local extra = 500 + tab
			world.membership[extra], world.paneHosts[extra] = tab, 1
			tree = { split = "right", ratio = 0.5, [1] = { pane = content },
				[2] = { split = "down", ratio = 0.6, [1] = { pane = extra }, [2] = { pane = rail } } }
		end
		if tab == 3 then world.root = tree else world.layouts[tab] = tree end
		before[tab] = copy(tree)
		entries[tostring(tab)] = { tab = tab, session = 2, pane = rail, userHidden = tab % 7 == 0, share = 0.3,
			relocate = true, note = "kept" }
	end
	world.prefs = { schema = 4, enabled = true, owner = "desktop",
		defaults = { share = { ["local"] = 0.3 }, hidden = {} }, instances = { ["local"] = entries }, uiByWindow = {},
		futureField = { kept = true } }
	world:advance(100)
	local stored = world.prefs
	assert(world.preferenceWrites == 2, "one write strips the obsolete flag and one adopts every rail")
	assert(stored.schema == 4 and stored.futureField.kept == true and stored.defaults.position == "left"
		and stored.defaults.share == nil,
		"the default position is left; the retired single size map is dropped, not migrated; unknown fields survive")
	for _, edge in { "bottom", "right", "left" } do
		local width = stored.defaults.shares[edge]["local"]
		assert(width ~= nil and math.abs(width - 0.3) < 0.000001,
			edge .. ": adoption records the physical width its rails were found at, once per host and position")
	end
	local expected = { bottom = "bottom", right = "right", left = "left", nested = "left" }
	for tab = 3, 24 do
		local saved = stored.instances["local"][tostring(tab)]
		local kind = kinds[(tab - 3) % 4 + 1]
		assert(saved.relocate == nil and saved.share == nil and saved.note == "kept" and saved.position == expected[kind],
			"tab " .. tab .. " (" .. kind .. ") is adopted at its physical edge, the default when it has none")
		assert(saved.shares == nil, "tab " .. tab .. " records no per-tab size")
	end
	for tab = 3, 24 do
		assert(equalValue(if tab == 3 then world.root else world.layouts[tab], before[tab]),
			"tab " .. tab .. " is exactly as it was")
	end
	assert(world.layoutWrites == 0 and world.focusWrites == 0 and #world.opens == 0 and world.settingsWrites == 0,
		"nothing moves, focuses, opens or touches a native setting")
	local settled = copy(world.prefs)
	world:reload(); world:advance(3100)
	assert(world.preferenceWrites == 2 and equalValue(world.prefs, settled) and world.layoutWrites == 0,
		"the settled store is idempotent: a reload writes and moves nothing")
end

-- Preferences written while Later existed load without error. The retired age cutoff is dropped; `later` leaves the
-- stored queue order, and an order that is then not exactly Attention and Working falls back to the default. The
-- load rewrites the store, and the mounted rail paints the migrated order.
for _, case in ipairs({
	{ stored = { "working", "later", "attention" }, expected = { "working", "attention" } },
	{ stored = { "attention", "later" }, expected = { "attention", "working" } },
}) do
	local world = native(true)
	world.prefs.backlogAfterSeconds = 21600
	world.prefs.queueOrder = case.stored
	world:advance(3100)
	assert(toastCount(world, "error", "") == 0 and world:inspect().preferenceError == nil,
		"a store carrying the retired Later fields loads without error")
	assert(world.prefs.backlogAfterSeconds == nil and equalValue(world.prefs.queueOrder, case.expected),
		"the rewritten store has no age cutoff and the migrated queue order")
	local sections = {}
	for _, section in ipairs(descend(world.canvases[world.opens[1].pane].view, "top", "stack").c or {}) do
		table.insert(sections, section.p.key)
	end
	assert(equalValue(sections, case.expected), "the stack paints the migrated queue order")
end

-- A rail whose earlier creation or placement never finished is adopted where it physically is: the unreadable
-- earlier checkpoint is dropped, never replayed, and the stored default never drags the rail to another edge.
for _, interrupted in { "creating", "checkpoint" } do
	local world = native(true, nil, "left")
	world.canvases[91] = { pane = 91, owner = "attention", about = "attention:tab:v1:2:3", title = "Attention",
		view = { k = "col", p = {}, c = {} } }
	world.membership[91], world.paneHosts[91] = 3, 1
	world.root = { split = "down", ratio = 0.7, [1] = { pane = 10 }, [2] = { pane = 91 } }
	local entry = { tab = 3, session = 2, pane = 91, userHidden = false, relocate = true }
	if interrupted == "creating" then entry.creating = true
	else entry.placement = { status = "placing", checkpoint = { version = 2, tab = 3 }, generation = 1 } end
	world.prefs = { schema = 4, enabled = true, owner = "desktop",
		defaults = { position = "left", hidden = {} }, uiByWindow = {}, instances = { ["local"] = { ["3"] = entry } } }
	local before = copy(world.root)
	world:advance(3100)
	local saved = world.prefs.instances["local"]["3"]
	assert(equalValue(world.root, before) and world.layoutWrites == 0 and #world.opens == 0,
		interrupted .. ": the bottom rail is not moved to the default edge")
	assert(saved.position == "bottom" and saved.relocate == nil and saved.placement == nil and saved.creating == nil
		and world:inspect().instances[1].phase == "ready", interrupted .. ": it is adopted at the bottom and settles ready")
end

-- Parked, floating and hidden rails with no recorded position are adopted at the default and left exactly as found.
do
	local world = native(true)
	world:addTab(4, 11); world:addTab(5, 12)
	for tab, pane in { [3] = 91, [4] = 92, [5] = 93 } do
		world.canvases[pane] = { pane = pane, owner = "attention", about = "attention:tab:v1:2:" .. tostring(tab),
			title = "Attention", view = { k = "col", p = {}, c = {} } }
		world.membership[pane], world.paneHosts[pane] = tab, 1
	end
	world.parked[91] = true
	world.floating[92], world.floats[4] = true, { { pane = 92 } }
	world.layouts[5] = { split = "down", ratio = 0.5, [1] = { pane = 12 }, [2] = { pane = 93 } }
	world.prefs = { schema = 4, enabled = true, owner = "desktop",
		defaults = { position = "right", hidden = {} }, uiByWindow = {},
		instances = { ["local"] = {
			["3"] = { tab = 3, session = 2, pane = 91, userHidden = false, relocate = true },
			["4"] = { tab = 4, session = 2, pane = 92, userHidden = false, relocate = true },
			["5"] = { tab = 5, session = 2, pane = 93, userHidden = true, relocate = true } } } }
	local hiddenTree = copy(world.layouts[5])
	world:advance(3100); world:switch(4); world:advance(3100); world:switch(5); world:advance(3100)
	for _, tab in { "3", "4" } do
		assert(world.prefs.instances["local"][tab].position == "right" and world.prefs.instances["local"][tab].relocate == nil,
			"tab " .. tab .. " adopts the default position without a move")
	end
	local hidden = world.prefs.instances["local"]["5"]
	assert(hidden.userHidden and hidden.position == "bottom" and equalValue(world.layouts[5], hiddenTree),
		"a hidden tab's rail is adopted where it physically is and never moved")
	assert(world.parked[91] and world.floating[92] and world.layoutWrites == 0 and #world.opens == 0 and world.focusWrites == 0,
		"parked and floating rails stay parked and floating")
end

-- A new rail opens at the default position, which is the left edge unless the preferences say otherwise.
for _, case in { "default", "bottom", "right", "left" } do
	local world = native(true, nil, if case == "default" then "bottom" else case)
	if case == "default" then world.prefs.defaults.position = nil end
	world:advance(3100)
	local pane = world.opens[1].pane
	local position = if case == "default" then "left" else case
	local saved = world.prefs.instances["local"]["3"]
	if position == "left" then
		assert(world.opens[1].options.dir == "left" and world.root.split == "right" and world.root[1].pane == pane
			and world.root[2].pane == 10 and math.abs(world.root.ratio - 0.25) < 0.02, "a left rail opens full height on the left")
	elseif position == "right" then
		assert(world.opens[1].options.how == "beside" and world.root.split == "right" and world.root[1].pane == 10
			and world.root[2].pane == pane and math.abs(world.root.ratio - 0.75) < 0.02, "a right rail opens on the right edge")
	else
		assert(world.opens[1].options.how == "beside" and world.root.split == "down" and world.root[1].pane == 10
			and world.root[2].pane == pane and math.abs(world.root.ratio - 0.75) < 0.02,
			case .. ": a bottom rail opens as the full-width bottom strip")
	end
	assert(saved.position == position and saved.shares == nil and world.focusWrites == 0
		and world.focused == 10, case .. ": the position is recorded with no per-tab size and focus never moves")
end

-- A divider drag is written once, when it has settled, as the host's width for that edge; a rail opened later uses it.
do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	world.root.ratio = 0.33
	local writes = world.preferenceWrites
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.preferenceWrites == writes, "a divider still moving is not written")
	world:emit("cwd", { pane = 10 }); world:advance(32)
	assert(world.preferenceWrites == writes + 1 and math.abs(world.prefs.defaults.shares.left["local"] - 0.33) < 0.000001
		and world.prefs.instances["local"]["3"].shares == nil, "a settled divider is written once, as the host's width")
	world:advance(5000)
	assert(world.preferenceWrites == writes + 1, "later passes write nothing more")
	world:switch(4); world:advance(3100)
	assert(math.abs(world.layouts[4].ratio - 0.33) < 0.02, "a rail opened later uses the host's width")
end

-- Choosing a position moves only this tab's rail, each position remembers its own size, and the choice becomes the
-- default for rails opened later.
do
	local world = native(true, nil, "bottom")
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world.root.ratio = 0.6
	world:advance(3100)
	assert(math.abs(world.prefs.defaults.shares.bottom["local"] - 0.4) < 0.000001,
		"a settled divider drag is remembered as the host's bottom width")
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	local untouched, writes = copy(world.layouts[4]), world.layoutWritesByTab[4] or 0
	world:switch(3); world:advance(100)
	world:control(first, "settings"); world:advance(100)
	world:command("this-tab-right"); world:advance(1500)
	assert(world.root.split == "right" and world.root[1].pane == 10 and world.root[2].pane == first
		and math.abs(world.root.ratio - 0.75) < 0.02, "Right moves the rail to the right edge at its own default size")
	local saved = world.prefs.instances["local"]["3"]
	assert(saved.position == "right" and saved.shares == nil and world.prefs.defaults.position == "bottom"
		and math.abs(world.prefs.defaults.shares.bottom["local"] - 0.4) < 0.000001,
		"the choice is saved for the tab only; the default is untouched; the bottom width is remembered")
	assert(equalValue(world.layouts[4], untouched) and (world.layoutWritesByTab[4] or 0) == writes
		and world.prefs.instances["local"]["4"].position == "bottom", "only the chosen tab's rail moves")
	world:command("this-tab-bottom"); world:advance(1500)
	assert(world.root.split == "down" and world.root[2].pane == first and math.abs(world.root.ratio - 0.6) < 0.02,
		"Bottom applies the host's bottom width")
	world:command("this-tab-left"); world:advance(1500)
	assert(world.root.split == "right" and world.root[1].pane == first and world.root[2].pane == 10
		and math.abs(world.root.ratio - 0.25) < 0.02 and world.prefs.defaults.position == "bottom",
		"Left moves the rail to the full-height left edge without touching the default")
	world:command("reset-placement"); world:advance(1500)
	assert(world.prefs.instances["local"]["3"].position == "left" and world.root[1].pane == first,
		"Reset placement keeps the current position")
	world:addTab(5, 12); world:switch(5); world:advance(3100)
	local third = world.opens[3].pane
	assert(world.layouts[5].split == "down" and world.layouts[5][2].pane == third
		and world.prefs.instances["local"]["5"].position == "bottom", "a new rail opens at the default position")
	assert(world.focusWrites == 0 and world.canvases[second], "choosing a position never moves focus or touches another rail")
end

-- "All tabs" sets the default and marks each settled rail on a connected host; a marked tab moves only when it is
-- next visited, and the selected tab starts at once. Hidden, parked and floating rails are left as found and
-- counted, a rail already at the position is not marked, and nothing outside a visit or a click moves.
local function allTabsWorld()
	local world = native(true)
	for tab = 4, 7 do world:addTab(tab, 7 + tab) end
	world:advance(3100)
	local rails = { [3] = world.opens[1].pane }
	for index, tab in { 4, 5, 6, 7 } do
		world:switch(tab); world:advance(3100)
		rails[tab] = world.opens[index + 1].pane
	end
	world.prefs.defaults.position = "bottom"
	world:addTab(8, 15); world:switch(8); world:advance(3100)
	rails[8] = world.opens[6].pane
	world:switch(3); world:advance(100)
	return world, rails
end

do
	local world, rails = allTabsWorld()
	assert(world.prefs.instances["local"]["8"].position == "bottom" and world.layouts[8].split == "down",
		"fixture: one rail is already at the bottom, four sit on the left")
	world:closePane(rails[5]); world:advance(1100)
	world.layouts[6], world.parked[rails[6]] = { pane = 13 }, true
	world.layouts[7], world.floating[rails[7]], world.floats[7] = { pane = 14 }, true, { { pane = rails[7] } }
	world:advance(1100)
	local before, writesBefore = {}, copy(world.layoutWritesByTab)
	for tab = 4, 8 do before[tab] = copy(world.layouts[tab]) end
	local allWrites = world.layoutWrites
	world:control(rails[3], "settings"); world:advance(100)
	world:command("all-tabs-bottom"); world:advance(1500)
	assert(toastCount(world, "info", "This tab moves now · 1 tab moves on their next visit · left as they are: "
		.. "1 hidden, 2 parked or floating") == 1,
		"the selected tab starts now, the unvisited tab waits for its visit, and each kept rail is counted by reason")
	assert(world.root.split == "down" and world.root[2].pane == rails[3] and world.prefs.defaults.position == "bottom",
		"the selected tab starts at once and the position becomes the default")
	local stored = world.prefs.instances["local"]
	assert(stored["3"].moveTo == nil and stored["3"].position == "bottom", "a started tab carries no marker")
	assert(stored["4"].moveTo == "bottom" and stored["4"].position == "left",
		"a tab that has not been visited is marked and still records where its rail is")
	for _, tab in { "5", "6", "7", "8" } do
		assert(stored[tab].moveTo == nil, "tab " .. tab .. " is not marked")
	end
	for tab = 4, 8 do
		assert(equalValue(world.layouts[tab], before[tab]) and (world.layoutWritesByTab[tab] or 0) == (writesBefore[tab] or 0),
			"tab " .. tab .. " has not moved before its own visit")
	end
	assert(world.layoutWrites > allWrites, "the selected tab did move")
	world:advance(5000)
	assert(equalValue(world.layouts[4], before[4]), "waiting never moves a marked tab")
	world:switch(4); world:advance(2100)
	assert(world.layouts[4].split == "down" and world.layouts[4][2].pane == rails[4] and world.layouts[4][1].pane == 11,
		"the first visit moves the marked tab")
	assert(world.prefs.instances["local"]["4"].moveTo == nil and world.prefs.instances["local"]["4"].position == "bottom",
		"the cleared marker and the new position are saved")
	for _, tab in { 5, 6, 7, 8 } do
		world:switch(tab); world:advance(2100)
		assert(equalValue(world.layouts[tab], before[tab]) and (world.layoutWritesByTab[tab] or 0) == (writesBefore[tab] or 0),
			"visiting tab " .. tab .. " moves nothing")
	end
	assert(world.parked[rails[6]] and world.floating[rails[7]] and world.prefs.instances["local"]["5"].userHidden
		and #world.opens == 6, "parked, floating and hidden rails stay as they were found")
	assert(world.focusWrites == 0 and world.settingsWrites == 0, "no move changes focus or a native setting")
	local settled, moved = copy(world.prefs), world.layoutWrites
	world:reload(); world:advance(3100)
	for _, tab in { 3, 4, 5, 6, 7, 8 } do world:switch(tab); world:advance(2100) end
	assert(equalValue(world.prefs, settled) and world.layoutWrites == moved,
		"a settled store is unchanged by reload and further visits, and nothing moves again")
end

-- A tab marked while it is zoomed (or not selected) waits; the palette form needs no rail in the current tab.
do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	world:switch(3); world:advance(100)
	world.zoomed = true
	local writes = world.layoutWrites
	world:command("all-tabs-bottom"); world:advance(1500)
	assert(toastCount(world, "info", "2 tabs move on their next visit") == 1,
		"both rails are marked; the zoomed selected tab keeps its marker and is not reported as moving")
	assert(world.prefs.instances["local"]["3"].moveTo == "bottom" and world.layoutWrites == writes
		and world.root.split == "right", "a zoomed tab is marked but not moved")
	world:advance(3000)
	assert(world.layoutWrites == writes, "a zoomed tab keeps waiting")
	world.zoomed = false
	world:advance(2100)
	assert(world.root.split == "down" and world.root[2].pane == first and world.prefs.instances["local"]["3"].moveTo == nil,
		"unzooming is the first eligible visit")
	assert(world.layouts[4].split == "right" and world.layouts[4][1].pane == second, "the other tab still waits for its visit")
end

-- Left for all marks a rail on an offline host as well: its stored entry carries the marker, nothing is moved while
-- the host is away, and the rail moves on its first visit after the host connects.
do
	local world = native(true)
	world:addTab(4, 11, 5, 7)
	world:advance(3100)
	local here = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local remote = world.opens[2].pane
	world:switch(3); world:advance(100)
	assert(world.prefs.instances["host-5"]["4"] and world.layouts[4].split == "right" and world.root.split == "right",
		"fixture: a local rail and a remote rail both sit on the left")
	world.hostStates[5] = "disconnected"
	world:advance(1100)
	local tree, writes = copy(world.layouts[4]), world.layoutWritesByTab[4] or 0
	world:command("all-tabs-bottom"); world:advance(1500)
	assert(toastCount(world, "info", "This tab moves now · 1 tab moves on their next visit") == 1,
		"the connected rail moves now and the offline host's rail is queued for its next visit")
	assert(world.root.split == "down" and world.root[2].pane == here, "the connected rail moves")
	local offline = world.prefs.instances["host-5"]["4"]
	assert(offline.moveTo == "bottom" and offline.position == "left" and equalValue(world.layouts[4], tree)
		and (world.layoutWritesByTab[4] or 0) == writes and world.canvases[remote],
		"the offline host's rail is marked and not moved while the host is away")
	world.hostStates[5] = nil
	world:advance(1100)
	world:switch(4); world:advance(3100)
	assert(world.layouts[4].split == "down" and world.layouts[4][2].pane == remote
		and world.prefs.instances["host-5"]["4"].moveTo == nil and world.prefs.instances["host-5"]["4"].position == "bottom",
		"the rail moves on its first visit after the host connects")
end

-- The selected tab on an offline host is not an eligible visit: its mark stays while the host is away, and the rail
-- moves on the next pass after the host connects.
do
	local world = native(true)
	world:addTab(4, 11, 5, 7)
	world:advance(3100)
	world:switch(4); world:advance(3100)
	local remote = world.opens[2].pane
	assert(world.prefs.instances["host-5"]["4"] and world.layouts[4].split == "right",
		"fixture: the selected tab is on the remote host with its rail on the left")
	world.hostStates[5] = "disconnected"
	world:advance(1100)
	local tree, writes = copy(world.layouts[4]), world.layoutWritesByTab[4] or 0
	world:command("all-tabs-bottom"); world:advance(3000)
	local offline = world.prefs.instances["host-5"]["4"]
	assert(offline.moveTo == "bottom" and offline.position == "left" and equalValue(world.layouts[4], tree)
		and (world.layoutWritesByTab[4] or 0) == writes and toastCount(world, "info", "This tab moves now") == 0,
		"the selected tab on an offline host keeps its mark and does not move")
	world.hostStates[5] = nil
	world:advance(3100)
	assert(world.layouts[4].split == "down" and world.layouts[4][2].pane == remote
		and world.prefs.instances["host-5"]["4"].moveTo == nil and world.prefs.instances["host-5"]["4"].position == "bottom",
		"the rail moves once the host connects")
end

-- Hiding, parking or floating a marked rail, or moving it by hand, drops the marker without moving anything; a
-- position chosen on the tab itself replaces it.
for _, case in { "choice", "hide", "park", "float", "dragged" } do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	world:control(second, "settings"); world:advance(100)
	world:switch(3); world:advance(100)
	world:command("all-tabs-bottom"); world:advance(1500)
	assert(world.prefs.instances["local"]["4"].moveTo == "bottom", case .. ": the other tab is marked")
	local opens = #world.opens
	if case == "choice" then
		-- Per-tab choice is reachable on the current tab; the marker it supersedes is that tab's own.
		world:switch(4); world:advance(100)
		world:command("this-tab-right"); world:advance(1500)
		assert(world.layouts[4].split == "right" and world.layouts[4][2].pane == second, case .. ": the chosen position is applied")
	elseif case == "hide" then
		world:closePane(second); world:advance(1100)
	elseif case == "park" then
		world.layouts[4], world.parked[second] = { pane = 11 }, true
		world:advance(1100)
	elseif case == "float" then
		world.layouts[4], world.floating[second], world.floats[4] = { pane = 11 }, true, { { pane = second } }
		world:advance(1100)
	else
		world.layouts[4] = { split = "right", ratio = 0.7, [1] = { pane = 11 }, [2] = { pane = second } }
		world:advance(1100)
	end
	local stored = world.prefs.instances["local"]["4"]
	assert(stored.moveTo == nil, case .. ": the marker is dropped")
	local tree, writes = copy(world.layouts[4]), world.layoutWritesByTab[4] or 0
	world:switch(4); world:advance(3100)
	assert(equalValue(world.layouts[4], tree) and #world.opens == opens and (world.layoutWritesByTab[4] or 0) == writes,
		case .. ": visiting the tab moves nothing and opens nothing")
	if case == "dragged" then assert(stored.position == "right", case .. ": the hand-moved edge is remembered") end
	if case == "choice" then assert(stored.position == "right", case .. ": the chosen position is the tab's position") end
end

-- The marker is part of the stored tab: unknown fields beside it survive, a settled store is rewritten by nothing,
-- and a marker no version could have written is reported instead of trusted.
do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	world:switch(4); world:advance(3100)
	world:switch(3); world:advance(100)
	world:command("all-tabs-bottom"); world:advance(1500)
	world.prefs.instances["local"]["4"].note, world.prefs.futureField = "kept", { kept = true }
	local stored, writes = copy(world.prefs), world.preferenceWrites
	assert(stored.instances["local"]["4"].moveTo == "bottom")
	world:reload(); world:advance(3100)
	assert(equalValue(world.prefs, stored) and world.preferenceWrites == writes, "reloading a marked store changes nothing")
	world:reload(); world:advance(3100)
	assert(equalValue(world.prefs, stored) and world.preferenceWrites == writes, "and neither does reloading again")
	world:switch(4); world:advance(2100)
	local moved = world.prefs.instances["local"]["4"]
	assert(world.layouts[4].split == "down" and moved.moveTo == nil and moved.note == "kept" and world.prefs.futureField.kept == true,
		"the marker survived the reloads, moved the tab once, and unknown fields survived the rewrite")
end

do
	local world = native(true)
	world.prefs = { schema = 4, enabled = true, owner = "desktop", uiByWindow = {},
		defaults = { position = "bottom", shares = { left = {}, bottom = {}, right = {} }, hidden = {} },
		instances = { ["local"] = { ["3"] = { tab = 3, session = 2, userHidden = false, position = "left",
			moveTo = "banana" } } } }
	local original = copy(world.prefs)
	world:advance(3100)
	assert(equalValue(world.prefs, original) and world.preferenceWrites == 0 and #world.opens == 0 and world.layoutWrites == 0,
		"an unknown marker leaves the store untouched")
	assert(toastCount(world, "error", "") >= 1 and world:inspect().preferenceError ~= nil, "and is reported visibly")
end

-- Tabs that have no rail yet are not marked: they open at the new default. A stored instance with nothing mounted
-- follows it too.
do
	local world = native(true)
	world:addTab(4, 11); world:addTab(5, 12)
	world:advance(3100)
	local first = world.opens[1].pane
	world.prefs.instances["local"]["5"] = { tab = 5, session = 2, userHidden = false, position = "left" }
	world:advance(1100)
	world:command("all-tabs-right"); world:advance(1500)
	assert(toastCount(world, "info", "This tab moves now") == 1, "only the mounted rail moves now")
	assert(world.root.split == "right" and world.root[2].pane == first and world.prefs.defaults.position == "right")
	assert(world.prefs.instances["local"]["5"].position == "right" and world.prefs.instances["local"]["5"].moveTo == nil,
		"an instance with nothing mounted takes the new position without a marker")
	world:switch(4); world:advance(3100)
	world:switch(5); world:advance(3100)
	for _, tab in { 4, 5 } do
		local tree = world.layouts[tab]
		assert(tree.split == "right" and tree[1].pane == tab + 7 and tree[2].pane == world.opens[tab - 2].pane
			and world.prefs.instances["local"][tostring(tab)].position == "right", "tab " .. tab .. " opens its rail at the right")
	end
end

-- A placement that ends degraded (too many panes to reconstruct) clears the marker like any other: the rail stays
-- where it is, the stored position is the edge it really occupies, and the marker never retries.
do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	local content = { pane = 10 }
	for pane = 20, 36 do
		world.membership[pane], world.paneHosts[pane] = 3, 1
		content = { split = "right", ratio = 0.5, [1] = content, [2] = { pane = pane } }
	end
	world.root = { split = "right", ratio = 0.25, [1] = { pane = rail }, [2] = content }
	world:advance(1100)
	local tree, writes = copy(world.root), world.layoutWrites
	world:command("all-tabs-bottom"); world:advance(3000)
	assert(toastCount(world, "info", "This tab moves now") == 1, "the crowded tab moves now and then settles")
	local saved = world.prefs.instances["local"]["3"]
	assert(saved.moveTo == nil and saved.placement == nil and world:inspect().instances[1].phase == "ready",
		"a degraded placement settles and leaves no marker")
	assert(equalValue(world.root, tree) and world.layoutWrites == writes, "the rail stays beside its panes")
	assert(saved.position == "left", "the stored position is the edge the rail really occupies")
	world:advance(5000); world:switch(3); world:advance(3000)
	assert(world.layoutWrites == writes and world.prefs.instances["local"]["3"].moveTo == nil, "nothing retries")
end


-- A position chosen on a tab survives reload, restart-like reload mid-move, tab switches, new tabs, ownership
-- transfer and further passes: nothing re-reads the physical edge over a requested or completed choice.
for _, midMove in { false, true } do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:control(first, "settings"); world:advance(100)
	world:control(first, "default-bottom"); world:advance(100) -- the global default is its own choice now
	world:command("this-tab-bottom")
	if midMove then world:advance(40); world:reload() end
	world:advance(2500)
	first = world.root[2].pane -- the edge change remounts the canvas; track the current rail pane
	local function stays(step)
		assert(world.root.split == "down" and world.root[2].pane == first and world.root[1].pane == 10
			and world.prefs.instances["local"]["3"].position == "bottom" and world.prefs.defaults.position == "bottom",
			(if midMove then "mid-move: " else "settled: ") .. step)
	end
	stays("the choice is applied")
	world:reload(); world:advance(3100); stays("after a reload")
	world:switch(4); world:advance(3100); world:switch(3); world:advance(3100); stays("after switching tabs and back")
	assert(world.layouts[4].split == "down" and world.prefs.instances["local"]["4"].position == "bottom",
		"a new tab opens at the chosen default")
	world:command("disable"); world:command("enable"); world:advance(3100); stays("after an ownership transfer")
	world:addTab(5, 12); world:switch(5); world:advance(3100)
	assert(world.layouts[5].split == "down", "a tab created later opens at the default")
	world:reload(); world:advance(3100); world:switch(3); world:advance(3100); stays("after a restart-like reload")
end

-- Newer, unsupported and invalid stores are reported and never rewritten or downgraded.
for _, case in { "newer", "unsupported", "invalid" } do
	local world = native(true)
	if case == "newer" then
		world.prefs = { schema = 5, enabled = true, owner = "desktop", future = { kept = true } }
	elseif case == "unsupported" then
		world.prefs = { schema = "four", enabled = true, owner = "desktop" }
	else
		world.prefs = { schema = 3, enabled = true, owner = "desktop", instances = {},
			defaults = { position = "banana", shares = { bottom = {}, right = {} }, hidden = {} } }
	end
	local original = copy(world.prefs)
	world:advance(3100)
	world:command("enable"); world:command("open"); world:command("reset-placement"); world:command("disable")
	assert(equalValue(world.prefs, original) and world.preferenceWrites == 0,
		case .. " preferences are left exactly as found")
	assert(#world.opens == 0 and world.layoutWrites == 0 and world.settingsWrites == 0, case .. " preferences drive no native change")
	assert(toastCount(world, "error", "") >= 1 and world:inspect().preferenceError ~= nil,
		case .. " preferences are reported visibly")
end

-- A write whose readback differs from what was validated is a visible failure, not a silent success.
do
	local world = native(true)
	world.prefs = { enabled = true, owner = "desktop", shares = {}, suppressed = {} }
	world.tamperPreferenceWrite = true
	world:advance(100)
	assert(toastCount(world, "error", "did not persist") == 1 and world.preferenceWrites == 1 and #world.opens == 0,
		"a mismatched readback is reported and creates nothing")
end

-- Saved window state is sanitized on read, survives unrelated saves, and never carries another window's state away.
do
	local world = native(true)
	world.prefs.uiByWindow = {
		desktop = { section = "settings",
			collapsed = { ["host:1:local"] = true, ["session:local#2"] = false, [5] = true, bad = "yes" },
			setAsideOpen = { ["aside:tab:local#3"] = true } },
		other = { section = "working", collapsed = {} },
	}
	world:advance(3100)
	local pane = world.opens[1].pane
	world:toggleQueue(pane, "working"); world:advance(50)
	local saved = world.prefs.uiByWindow
	assert(world.prefs.schema == 4 and world.preferenceWrites >= 1, "the unrelated preference saved")
	assert(saved.desktop.section == "attention" and saved.desktop.collapsed["host:1:local"] == true
		and saved.desktop.collapsed[5] == nil and saved.desktop.collapsed.bad == nil
		and saved.desktop.setAsideOpen == nil and saved.other.section == "working",
		"transient sections, foreign keys and the retired Set aside state are dropped while valid state and other windows survive")
	assert(saved.desktop.collapsed["session:local#2"] == false,
		"an explicitly opened group survives as false where a collapsed entry is tri-state")
end

-- A left rail wraps nested content that also has a floating pane, preserving every divider and the float.
do
	local world = native(true)
	for _, pane in { 11, 12, 13 } do world.membership[pane], world.paneHosts[pane] = 3, 1 end
	world.root = { split = "right", ratio = 0.4, [1] = { pane = 10 },
		[2] = { split = "down", ratio = 0.6, [1] = { pane = 11 }, [2] = { pane = 12 } } }
	world.floating[13] = true
	world.floats[3] = { { pane = 13, over = 10, corner = "top_right" } }
	local floats = copy(world.floats[3])
	world:advance(5100)
	local wrapper = world.root
	assert(wrapper.split == "right" and wrapper[1].pane == world.opens[1].pane and math.abs(wrapper.ratio - 0.25) < 0.01,
		"the rail becomes the full-height first child of nested content")
	local content = wrapper[2]
	assert(content.split == "right" and content[1].pane == 10 and math.abs(content.ratio - 0.4) < 0.01
		and content[2].split == "down" and content[2][1].pane == 11 and content[2][2].pane == 12
		and math.abs(content[2].ratio - 0.6) < 0.01, "content identities, order and ratios are preserved")
	assert(equalValue(world.floats[3], floats) and world.floating[13] and world.focused == 10 and world.focusWrites == 0,
		"floats and focus are untouched")
end

-- Recovery commands work with no current instance: a disabled window, an empty session and returning content.
do
	local world = native(false)
	world.tabs, world.membership, world.paneHosts, world.focused = {}, {}, {}, nil
	world:advance(100)
	world:command("open"); world:command("reset-placement")
	assert(toastCount(world, "info", "Attention is disabled") == 2 and toastCount(world, "error", "") == 0,
		"a disabled window explains itself instead of failing")
	world:command("enable")
	assert(world.prefs.enabled and world.prefs.owner == "desktop" and world.prefs.schema == 4,
		"Enable here owns a window that has no content")
	assert(toastCount(world, "info", "No mounted rail — use native navigation") == 1 and toastCount(world, "error", "") == 0,
		"Enable here reports the native fallback in an empty session")
	world:command("reset-placement")
	assert(toastCount(world, "info", "No mounted rail — use native navigation") == 2,
		"Reset placement explains the missing rail without throwing")
	local state = world:inspect()
	assert(state.availability.state == "no-content" and state.availability.owns == true
		and string.find(state.availability.reason, "native navigation", 1, true),
		"diagnostics record why no rail is mounted")
	world:advance(10000)
	assert(#world.opens == 0 and world.layoutWrites == 0 and toastCount(world, "error", "") == 0,
		"an empty session never creates scaffolding content or a rail")
	world:addTab(4, 11); world:switch(4); world:advance(3100)
	assert(#world.opens == 1 and world.layouts[4][1].pane == world.opens[1].pane,
		"the owned window mounts the rail when content appears")
	world:command("disable")
	assert(not world.prefs.enabled and world.settingsWrites == 0, "Disable works without a rail and writes no native setting")
end

for _, interruptedReply in { false, true } do
	local world = native(true)
	world:addTab(4, 11)
	world.replicaDelay = 6000
	world.failOpen = if interruptedReply then "accepted-throw" else nil
	world:advance(2100)
	local pane = world.opens[1].pane
	world:emit("tab_closed", { tab = 3 })
	world.tabs[3], world.membership[10] = nil, nil
	world:switch(4); world:advance(100)
	local saved = world.prefs.instances["local"]["3"]
	assert(saved and saved.retiring and (saved.pane == pane or saved.creating),
		"connected host plus missing replica must retain confirmed retirement and accepted creation identity")
	world:reload(); world:advance(1100)
	assert(world.prefs.instances["local"]["3"] and world.canvases[pane],
		"retirement survives reload while accepted ownership metadata is still delayed")
	world.failOpen, world.replicaDelay = nil, 0
	world:advance(6000)
	assert(not world.canvases[pane] and world.prefs.instances["local"]["3"] == nil,
		"late metadata for a closed tab identifies and retires the same accepted pane, including interrupted replies")
end

local function beacon(world, pane)
	local group = sectionRows(world, pane, "attention")
	for _, row in ipairs(group.c) do
		assert(row.p.role ~= "attention.row-arrival" and row.p.role ~= "attention.row-arrival-again",
			"individual rows never own the collective cue")
	end
	if group.p.role == "attention.rows-arrival" or group.p.role == "attention.rows-arrival-again" then
		assert(#group.c > 0, "the collective cue requires occupied rows")
		for _, row in ipairs(group.c) do
			assert(row.p.role == "attention.row", "cued rows preserve their normal role and bindings")
		end
		return group.p.role
	end
	return nil
end

local function acceptedCues(world)
	local previous, cues = {}, {}
	for _, paint in ipairs(world.canvasPaints) do
		local role = paint.role
		if (role == "attention.rows-arrival" or role == "attention.rows-arrival-again")
			and previous[paint.pane] ~= role then
			table.insert(cues, paint)
		end
		previous[paint.pane] = role
	end
	return cues
end

for _, completion in ipairs({ "visible", "early", "finished" }) do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world:advance(3100)
	local pane = world.opens[1].pane
	local previousOpen = rowAction(shown(world, pane))
	assert(previousOpen and not beacon(world, pane), "pre-existing unseen attention seeds a quiet baseline")
	if completion == "finished" then
		world:click(pane, rowAction(shown(world, pane), "menu")); world:chooseLabel("Finished for now · current scope"); world:advance(100)
		assert(not rowAction(shown(world, pane)), "the existing unseen request leaves Attention as Finished")
	end
	local earlierRevision = world.savedTriage.items[1].reviewRevision
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(32)
	assert(not rowAction(shown(world, pane)) and world:inspect().attentionCount == 0
		and world.savedTriage.items[1].reviewRevision == earlierRevision and not beacon(world, pane),
		"continuous native alert cannot keep an earlier unread review in Attention during a fresh turn")
	if completion ~= "early" then world.agentState = "idle" end
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(32)
	local completionRevision = world.savedTriage.items[1].reviewRevision
	assert(completionRevision ~= nil and completionRevision ~= earlierRevision,
		"literal completion records a new unread revision even before runtime inventory settles")
	if completion == "early" then
		assert(not rowAction(shown(world, pane)) and world:inspect().attentionCount == 0 and not beacon(world, pane),
			"a completion with lagging working inventory is recorded but not presented or cued")
		world:advance(5100)
		assert(world.savedTriage.items[1].reviewRevision == completionRevision
			and not rowAction(shown(world, pane)) and not beacon(world, pane),
			"the recorded completion survives more than five seconds without leaking into the working queue")
		world.agentState = "idle"
		world:emit("agent_state", { pane = 10, old = "working", new = "idle" }); world:advance(32)
	end
	local completionOpen = rowAction(shown(world, pane))
	if completion == "finished" then
		assert(world.agentAlert and completionOpen == nil and world:inspect().attentionCount == 0 and not beacon(world, pane),
			"ordinary completion cannot interrupt explicit Finished or replay a cue")
	else
		assert(world.agentAlert and completionOpen and completionOpen ~= previousOpen
			and world:inspect().attentionCount == 1 and beacon(world, pane)
			and world.savedTriage.items[1].reviewRevision == completionRevision,
			"settled completion publishes its exact recorded revision with one cue without resetting native alert")
	end
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(32)
	assert(world.savedTriage.items[1].reviewRevision == completionRevision and not beacon(world, pane),
		"duplicate completion delivery neither creates a revision nor requeues a cue after cooldown")
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(32)
	assert(not rowAction(shown(world, pane)) and not beacon(world, pane),
		"starting another turn under continuous alert removes passive review without replaying completion")
	world.agentState = "idle"
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(32)
	assert(world.agentAlert and (if completion == "finished" then not beacon(world, pane) else beacon(world, pane)),
		"later output stays out of Attention for Finished work; an active turn can cue without resetting native alert")
	assert(world.focusWrites == 0, "completion-to-cue delivery never navigates or acknowledges the request")
end

for _, failure in ipairs({ "canvas", "maintenance" }) do
	local world = native(true)
	world.agentState = "working"
	world:advance(3100)
	local pane = world.opens[1].pane
	assert(not beacon(world, pane) and not rowAction(shown(world, pane)),
		"initial empty P0 is quiet")
	world.canvasPaints = {}
	if failure == "canvas" then world.failNextCanvasSet = true
	else world.failLayoutAfter = 1 end
	world.agentState = "waiting_input"
	world:emit("agent_state", { pane = 10, old = "working", new = "waiting_input" })
	world:advance(32)
	assert(#world.canvasPaints == 0 and not rowAction(shown(world, pane)) and not beacon(world, pane),
		"rejected arrival pass has not painted the request or started a cue")
	local rejectedAt = world.now
	while #world.canvasPaints == 0 and world.now < rejectedAt + 3000 do world:advance(1) end
	assert(#world.canvasPaints > 0, "the request must reach a healthy paint within the three-second retry bound")
	local deliveredAt, first = world.canvasPaints[1].at, beacon(world, pane)
	assert(deliveredAt < rejectedAt + 3000 and rowAction(shown(world, pane)),
		"the first healthy pass recovers the request before its cue reservation expires")
	assert(first and world.canvasPaints[1].role == first and #acceptedCues(world) == 1,
		"a transient " .. failure .. " failure must retain exactly one eligible cue until paint accepts it")
	world:emit("title", { pane = 10 }); world:advance(32)
	assert(beacon(world, pane) == first and #acceptedCues(world) == 1,
		"recovery delivers one cue, not a restart on unchanged state")
	world:advance(deliveredAt + 899 - world.now)
	assert(beacon(world, pane) == first, "the recovered cue lasts until its accepted-paint deadline")
	world:advance(1)
	assert(not beacon(world, pane)
		and sectionRows(world, pane, "attention").p.role == "attention.rows-occupied",
		"the recovered cue retires at 900ms while occupied P0 retains its permanent tint")
	world:advance(deliveredAt + 2999 - 32 - world.now)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(32)
	assert(not beacon(world, pane) and #acceptedCues(world) == 1,
		"the entire three-second cooldown begins at accepted paint, not the rejected attempt")
	world:advance(deliveredAt + 3100 - world.now)
	assert(not beacon(world, pane) and #acceptedCues(world) == 1,
		"the suppressed cooldown arrival never replays")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); world:advance(32)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(32)
	assert(beacon(world, pane) and #acceptedCues(world) == 2,
		"a genuinely fresh arrival can cue once after the accepted-paint cooldown")
	world:reload(); world:advance(1100)
	assert(not beacon(world, pane) and #acceptedCues(world) == 2,
		"reload never replays a recovered cue, including a pulse that would retire before readback")
	assert(world.focusWrites == 0, "retry, retirement, cooldown and reload never navigate")
end

for _, interruption in ipairs({ "section", "tab", "reload", "expiry" }) do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local pane = world.opens[1].pane
	if interruption == "tab" then
		world:switch(4); world:advance(3100)
		assert(#world.opens == 2, "both stationary rails must mount before the rejected arrival")
		world:switch(3); world:advance(1100)
	end
	world.canvasPaints = {}
	world.failNextCanvasSet = true
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(32)
	assert(not beacon(world, pane), "a rejected canvas update leaves no accepted cue")
	if interruption == "section" then
		world:toggleQueue(pane, "attention"); world:advance(32)
		world:toggleQueue(pane, "attention"); world:advance(1100)
	elseif interruption == "tab" then
		world:switch(4); world:advance(1100)
		assert(not beacon(world, world.opens[2].pane), "a pending cue cannot migrate to another tab")
		world:switch(3); world:advance(1100)
	elseif interruption == "reload" then
		world:reload(); world:advance(1100)
	else
		world.failCanvasUntil = world.now + 3000
		world:budget("paused")
		world:advance(5100)
	end
	assert(not beacon(world, pane) and #acceptedCues(world) == 0,
		"pending arrival is discarded after " .. interruption .. " without an intervening accepted pulse")
	if interruption == "expiry" then
		assert(#world.canvasPaints > 0
			and world.canvasPaints[1].at >= world.failCanvasUntil
			and sectionRows(world, pane, "attention").p.role == "attention.rows-occupied",
			"the first healthy paint after the three-second reservation bound is quiet but remains tinted")
	end
	world:advance(3100)
	assert(not beacon(world, pane) and #acceptedCues(world) == 0,
		"discarded pending arrivals never become catch-up pulses between readbacks")
	assert(world.focusWrites == 0, "discarding a pending cue never navigates")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world.additionalAgents = { [11] = "working", [12] = "working" }
	world:advance(3100)
	local pane = world.opens[1].pane
	local toastsBeforeArrivals = #world.toasts
	local function advanceQuietly(ms)
		local before = #world.toasts
		world:advance(ms)
		assert(#world.toasts == before, "arrival processing never emits native alerts")
	end
	assert(#sectionRows(world, pane, "attention").c == 1 and not beacon(world, pane),
		"the initial occupied list is quiet")
	local open = rowAction(shown(world, pane))
	world.agentAlert = true
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	local first = beacon(world, pane)
	assert(first and #sectionRows(world, pane, "attention").c == 1,
		"one occupied row receives the list band")
	assert(rowAction(shown(world, pane)) ~= open, "new review evidence receives a distinct Open token")
	open = rowAction(shown(world, pane))
	world.additionalAgents[11] = "waiting_input"
	world:emit("agent_state", { pane = 11, old = "working", new = "waiting_input" }); advanceQuietly(100)
	local rows = sectionRows(world, pane, "attention").c
	local secondMenu = rowAction(rows[2], "menu")
	assert(#rows == 2 and beacon(world, pane) == first and queueLabel(world, pane, "attention") == "Attention · 2",
		"a second arrival joins the existing band and immediately updates the count")
	assert(rowAction(rows[1]) == open, "group updates preserve existing row action targets")
	world.additionalAgents[12] = "waiting_input"
	world:emit("agent_state", { pane = 12, old = "working", new = "waiting_input" }); advanceQuietly(100)
	assert(#sectionRows(world, pane, "attention").c == 3
		and beacon(world, pane) == first and queueLabel(world, pane, "attention") == "Attention · 3",
		"three occupied rows share one unchanged band")
	world.agentState, world.agentAlert = "working", false
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "working" }); advanceQuietly(100)
	local remaining = sectionRows(world, pane, "attention").c
	assert(#remaining == 2 and rowAction(remaining[1], "menu") == secondMenu
		and queueLabel(world, pane, "attention") == "Attention · 2" and beacon(world, pane) == first,
		"resumed work leaves Attention while other requests retain their bindings and shared cue deadline")
	advanceQuietly(300)
	world.agentState = "waiting_input"
	world:emit("agent_state", { pane = 10, old = "working", new = "waiting_input" }); advanceQuietly(100)
	assert(beacon(world, pane) == first and queueLabel(world, pane, "attention") == "Attention · 3",
		"a late burst neither restarts nor intensifies the active cue; now=" .. tostring(world.now)
			.. " cue=" .. tostring(beacon(world, pane)) .. " first=" .. tostring(first)
			.. " queue=" .. queueLabel(world, pane, "attention") .. " native=" .. tostring(savedItemFor(world, 10).nativeState)
			.. " waiting=" .. tostring(savedItemFor(world, 10).waiting))
	advanceQuietly(200)
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	assert(not beacon(world, pane),
		"the original 900ms deadline wins even when the last arrival is much younger")
	world.additionalAgents[11] = "working"
	world:emit("agent_state", { pane = 11, old = "waiting_input", new = "working" }); advanceQuietly(100)
	assert(queueLabel(world, pane, "attention") == "Attention · 2" and queueCount(world, pane, "working") == "1")
	world.additionalAgents[11] = "waiting_input"
	world:emit("agent_state", { pane = 11, old = "working", new = "waiting_input" }); advanceQuietly(100)
	assert(not beacon(world, pane) and queueLabel(world, pane, "attention") == "Attention · 3" and queueCount(world, pane, "working") == "0"
		and #sectionRows(world, pane, "attention").c == 3,
		"a fresh native episode within the three-second rate cap updates rows and counts without a new cue")
	advanceQuietly(1300)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	assert(not beacon(world, pane) and queueLabel(world, pane, "attention") == "Attention · 3",
		"a new native revision near the end of the full three-second window is still consumed quietly")
	advanceQuietly(400)
	assert(not beacon(world, pane), "rate-limited arrivals never enqueue a trailing catch-up pulse")
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	assert(not beacon(world, pane), "unchanged attention stays quiet after the rate window ends")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); advanceQuietly(100)
	assert(beacon(world, pane) and beacon(world, pane) ~= first,
		"a genuinely new revision after three seconds starts a fresh cue")
	assert(world.focusWrites == 0, "collective arrivals never navigate")
	assert(#world.toasts == toastsBeforeArrivals, "arrival stimuli and processing never emit native alerts")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world.additionalAgents = { [11] = "working" }
	world:advance(3100)
	local pane = world.opens[1].pane
	world.holdIdentity = true
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(32)
	local started, first = world.now, beacon(world, pane)
	assert(first and world:activeTimers() == 2, "an active cue adds one retirement timer alongside the heartbeat")
	local retirement = nil
	for _, timer in ipairs(world.timers) do
		if not timer.cancelled and not timer.fired and timer.due == started + 900 then retirement = timer end
	end
	assert(retirement, "the cue has one exact 900ms retirement deadline")
	world:advance(200)
	world.additionalAgents[11] = "waiting_input"
	world:emit("agent_state", { pane = 11, old = "working", new = "waiting_input" }); world:advance(32)
	assert(#sectionRows(world, pane, "attention").c == 2
		and queueCount(world, pane, "attention") == "2" and beacon(world, pane) == first,
		"the pending retirement timer never delays ordinary arrival rows or counts")
	assert(world:activeTimers() == 2 and not retirement.cancelled and retirement.due == started + 900,
		"an active-cue update neither restarts its timer nor adds animation-frame timers")
	world:advance(started + 899 - world.now)
	assert(beacon(world, pane) == first, "an idle cue remains present just before its deadline")
	world:advance(1)
	assert(not beacon(world, pane) and retirement.fired and world:activeTimers() == 1,
		"the idle cue retires at 900ms without waiting for a heartbeat or another event")
	local sets = world.canvasSets
	world:advance(500)
	assert(world.canvasSets == sets, "the finished cue schedules no trailing animation work")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.holdIdentity = true
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(32)
	assert(beacon(world, pane) and world:activeTimers() == 2, "disable is exercised with an active retirement timer")
	world:command("disable")
	assert(world:activeTimers() == 0, "disable cancels the cue retirement timer as well as ordinary scheduled work")
	local sets = world.canvasSets
	world:advance(2000)
	assert(world.canvasSets == sets and world:activeTimers() == 0,
		"a disabled rail cannot be repainted or rearmed by its former retirement deadline")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	assert(not beacon(world, pane), "initial successful projection is a quiet baseline")
	local open = rowAction(shown(world, pane))
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "waiting_input" })
	world:advance(100)
	assert(not beacon(world, pane), "repeated pending requests are not arrivals")
	world.agentTitle = "Renamed agent"
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(not beacon(world, pane), "cosmetic row updates are not attention revisions")
	world.agentAlert = true
	world:emit("title", { pane = 10 })
	world:advance(100)
	local first = beacon(world, pane)
	assert(first, "a genuinely new attention revision cues the queue")
	assert(rowAction(shown(world, pane)) ~= open and rowAction(shown(world, pane), "menu") ~= nil,
		"new review evidence has a new Open token and a current revision-bound menu")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); world:advance(100)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(beacon(world, pane) == first, "event bursts preserve one finite pulse")
	world:advance(1800)
	assert(not beacon(world, pane), "heartbeat retires the finite cue without replay")
	world:advance(1000)
	world.agentState, world.agentAlert = "working", false
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "working" }); world:advance(100)
	world.agentState = "waiting_input"
	world:emit("agent_state", { pane = 10, old = "working", new = "waiting_input" }); world:advance(100)
	assert(beacon(world, pane), "a fresh waiting episode returns to P0 and cues")
	world:reload(); world:advance(1100)
	assert(not beacon(world, pane), "reload seeds a new baseline instead of replaying a cue")
	assert(world.focusWrites == 0, "queue arrivals never navigate")
end

-- A folded queue section opens itself when a conversation arrives in it: the arrival is seen (and Attention's cue
-- plays) without a click. Folding it again sticks until the next arrival.
do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	local function open(queue)
		local toggle = descend(world.canvases[pane].view, "top", "stack", queue, "head", "toggle")
		return string.find(toggle.p.title, "^Hide ") ~= nil
	end
	world:toggleQueue(pane, "attention"); world:advance(100)
	world:toggleQueue(pane, "working"); world:advance(100)
	assert(not open("attention") and not open("working"), "both sections start folded")
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(open("attention"), "an arrival opens folded Attention")
	assert(beacon(world, pane), "the arrival's cue plays in the section it opened")
	assert(not open("working"), "an Attention arrival leaves Working as the user left it")
	world:toggleQueue(pane, "attention"); world:advance(3100)
	assert(not open("attention"), "folding again sticks while nothing new arrives")
	world.agentAlert = false
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "working" }); world:advance(6100)
	assert(open("working") and queueCount(world, pane, "working") == "1", "a conversation that starts working opens folded Working")
end

-- Attention is out of sight while the settings panel replaces the stack; the same control hides it and brings it back.
for _, hiding in ipairs({ "settings" }) do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	local function toggle()
		if hiding == "settings" then world:control(pane, "settings") else world:toggleQueue(pane, "attention") end
		world:advance(100)
	end
	toggle()
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(not beacon(world, pane), "hidden P0 arrivals are consumed, not displayed")
	toggle()
	assert(not beacon(world, pane), "showing Attention again does not replay an arrival")
	world:advance(3100)
	assert(not beacon(world, pane), "a hidden arrival is not queued until the rate window expires")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); world:advance(100)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(beacon(world, pane), "fresh visible attention can cue after a consumed hidden arrival")
	toggle()
	toggle()
	assert(not beacon(world, pane), "leaving the queue retires an active cue instead of pausing it")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local firstPane = world.opens[1].pane
	world:switch(4); world:advance(3100)
	assert(#world.opens == 2, "both stationary rails must finish mounting before arrival")
	local secondPane = world.opens[2].pane
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(beacon(world, secondPane) and not beacon(world, firstPane),
		"only the currently visible stationary instance consumes a new arrival")
	world:switch(3); world:advance(100)
	assert(not beacon(world, firstPane), "switching to another stationary instance cannot replay")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); world:advance(100)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(not beacon(world, firstPane),
		"the three-second rate cap is window-wide, not reset by switching stationary instances")
	world:switch(4); world:advance(100)
	assert(not beacon(world, secondPane), "returning to the original instance cannot replay its retired cue")
	world:advance(3100)
	assert(not beacon(world, firstPane) and not beacon(world, secondPane),
		"arrivals consumed during the window-wide cooldown never replay on either tab")
	world.agentAlert = false
	world:emit("title", { pane = 10 }); world:advance(100)
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(beacon(world, secondPane) and not beacon(world, firstPane),
		"only a genuinely new post-cooldown arrival cues the currently visible tab")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.hostStates[1] = "disconnected"
	world:advance(1100)
	world.hostStates[1] = "connected"
	world:advance(1100)
	assert(not beacon(world, pane), "host availability and stale-only updates are not attention")
	world.failInventory = true
	world:advance(1100)
	world.failInventory = false
	world:advance(1100)
	assert(not beacon(world, pane), "inventory recovery cannot invent a fresh request")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12, 8, 9)
	world.additionalAgents = { [11] = "working" }
	world:advance(3100)
	local rail = world.opens[1].pane
	world:control(rail, "attention"); world:advance(100)
	world:control(rail, "attention"); world:advance(100)
	local function counts()
		return { queueCount(world, rail, "attention"), queueCount(world, rail, "working"), tostring(world:inspect().allCount) }
	end
	local before = counts()
	assert(before[1] == "1" and before[2] == "1" and before[3] == "2")
	world.hostStates[8] = "disconnected"
	world:advance(9000)
	local offline = counts()
	assert(offline[1] == before[1] and offline[2] == before[2] and offline[3] == before[3],
		"an offline laptop cannot change counts of tracked local Attention, Working or All work")
	assert(world:inspect().status == "partial" and world:inspect().count == nil,
		"tracked queue counts do not falsely establish complete remote coverage")
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().attentionCount == 1,
		"an offline laptop does not block navigation to a current local request")
	world.hostStates[8] = "connected"
	world:advance(1100)
	local reconnected = counts()
	assert(reconnected[1] == before[1] and reconnected[2] == before[2] and reconnected[3] == before[3])
end


do
	local world = native(true)
	world.currentHost = 404
	world:advance(1100)
	world.currentHost = 1
	world:advance(3100)
	assert(not beacon(world, world.opens[1].pane), "an absent active host cannot queue a later replay")
	world:reload()
	world.failInventory = true
	world:advance(1100)
	world.failInventory = false
	world:advance(1100)
	assert(not beacon(world, world.opens[1].pane), "failed initial inventory cannot seed a false empty baseline")
end

for _, origin in { "next", "open" } do
	local world = native(true)
	world:addTab(4, 11, 1, 7)
	world:addTab(5, 12, 1, 8)
	world.additionalAgents = { [11] = "waiting_input", [12] = "waiting_input" }
	world:advance(3100)
	local rail = world.opens[1].pane
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == 10, "global round visits A before attempting B")
	local targetRow = sectionRows(world, rail).c[2]
	local targetKey, targetAction = targetRow.p.key, rowAction(targetRow)
	if origin == "next" then world:command("next") else world:click(rail, targetAction) end
	assert(world.focused == 11 and world:inspect().navigationPending,
		"B must be awaiting native visit confirmation before it moves")
	world:addTab(6, 11, 1, 9)
	world.tabs[4], world.layouts[4] = nil, nil
	local notifications = #world.toasts
	world:switch(3); world:advance(1100)
	local failed = world:inspect()
	local movedRow = sectionRows(world, rail).c[2]
	local explained = false
	for index = notifications + 1, #world.toasts do
		if world.toasts[index].kind == "error" then explained = true end
	end
	assert(not failed.navigationPending and explained,
		"the moved target fails native visit confirmation after focus returns to A")
	assert(world.agentState == "waiting_input" and world.additionalAgents[11] == "waiting_input"
		and failed.attentionCount == 3 and movedRow.p.key == targetKey and rowAction(movedRow) == targetAction,
		"the failed visit preserves B's actual waiting request and original target serial")
	local focusWrites = world.focusWrites
	world:command("next"); world:advance(100)
	assert(world.focused == 11 and world.focusWrites == focusWrites + 1
		and not world:inspect().navigationPending and world:inspect().attentionCount == 3
		and world.additionalAgents[11] == "waiting_input",
		"failed " .. origin .. " preserves B's round position: a fresh Next confirms B without answering its input request")
	world:command("next"); world:advance(100)
	assert(world.focused == 12 and world.focusWrites == focusWrites + 2
		and not world:inspect().navigationPending and world:inspect().attentionCount == 3
		and world.additionalAgents[11] == "waiting_input" and world.additionalAgents[12] == "waiting_input",
		"only the successful B retry advances Next to C while both native input requests remain unresolved")
end

do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	local action = keyedAction(world.canvases[rail].view, "next")
	world.failInventory = true
	world:click(rail, action)
	assert(world.focusWrites == 0 and #world.sessionSwitches == 0 and #world.toasts > 0,
		"an opaque Next click cannot use stale inventory to navigate or claim a quiet session")
	world:advance(1100)
	assert(string.find(world.canvases[rail].view.c[1].p.text, "Attention paused ·", 1, true),
		"an unavailable inventory paints the paused line instead of stale evidence")
	world.failInventory = false
	world:advance(1100)
	assert(headerPart(world, rail, "tools") ~= nil, "recovered inventory repaints the toolbar in place of the paused line")
end

do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	local canvasWrites, layoutWrites = world.canvasSets, world.layoutWrites
	world.failInventory, world.failCurrentHost = true, true
	world:advance(1100)
	assert(world.canvasSets == canvasWrites + 1 and world.layoutWrites == layoutWrites and world.focusWrites == 0,
		"unavailable current-host identity must not render, place, or focus a rail from stale visibility")
	assert(string.find(world.canvases[rail].view.c[1].p.text, "Attention paused ·", 1, true),
		"the only canvas write is the paused line, never a stale rail")
	world.failInventory, world.failCurrentHost = false, false
	world:advance(1100)
	local count = queueCount(world, rail, "attention")
	assert(world.canvasSets > canvasWrites + 1 and tonumber(string.match(count, "%d+")) == 1,
		"recovered inventory repaints the observed attention")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/review-a.jsonl"
	world:addTab(4, 11, 1, 7)
	world:addTab(5, 12, 1, 8)
	world.identityFiles[11], world.identityFiles[12] = "/sessions/review-b.jsonl", "/sessions/chrome.jsonl"
	world.additionalAgents = { [11] = "idle", [12] = "waiting_input" }
	world:advance(3100)
	local arrivalLayoutWrites = world.layoutWrites
	world:emit("agent_finished", { pane = 11, result = "failed" }); world:advance(100)
	assert(world.layoutWrites == arrivalLayoutWrites and world.focusWrites == 0,
		"new completion updates Attention without any layout or focus write")
	local rail = world.opens[1].pane
	world:click(rail, rowAction(renderedRowFor(world, rail, 12), "menu")); world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(world:inspect().attentionCount == 2 and savedItemFor(world, 12).disposition == "finished")
	local writes = world.layoutWrites
	world.agentAlert = false
	world:reload(); world:advance(1100)
	local saved = world:inspect()
	assert(saved.attentionCount == 2 and savedItemFor(world, 12).disposition == "finished" and #world.savedTriage.items == 3,
		"reload and false native alert retain two P0 records and the independent Chrome Finished record")
	assert(world.layoutWrites == writes and world.focusWrites == 0,
		"durable queue restoration never writes layout or focus")
	assert(queueCount(world, rail, "attention") == "2" and queueCount(world, rail, "working") == "0",
		"toolbar uses the durable presentation after reload")
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == 10 and world:inspect().attentionCount == 1,
		"Next follows durable oldest-first order and acknowledges only its selected record")
	world:command("next"); world:advance(100)
	assert(world.focused == 11 and world:inspect().attentionCount == 0)
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/captured.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	assert(world.focusWrites == 0, "known identity navigation waits for fresh process evidence")
	local request = #world.processes
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" })
	world.agentState = "idle"
	world:emit("agent_finished", { pane = 10, result = "done" })
	world:advance(32)
	world:completeIdentity(request); world:advance(100)
	assert(world.focusWrites == 0 and #world.processes > request,
		"new observations supersede an in-flight proof before navigation")
	world:completeIdentity(#world.processes); world:advance(100)
	assert(world.focusWrites == 1 and world:inspect().attentionCount == 1,
		"revalidated navigation still uses its captured older review revision")
	world.holdIdentity = false
	world:click(rail, rowAction(shown(world, rail))); world:advance(100)
	assert(world:inspect().attentionCount == 0, "opening the freshly rendered revision acknowledges it")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/input.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowAction(shown(world, rail))); world:advance(100)
	assert(world:inspect().attentionCount == 1 and world.agentState == "waiting_input",
		"explicit Open cannot resolve a live input condition")
	local writes = world.focusWrites
	world:command("next"); world:advance(100)
	assert(world.focusWrites == writes and world:inspect().attentionCount == 1,
		"the sole currently focused waiting-only target reports still-needs-input without another focus")
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "working" }); world:advance(100)
	assert(world:inspect().attentionCount == 0, "observed input resolution retires an already reviewed condition")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/generic-focus.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.agentAlert, world.focused = false, 10
	world:emit("focus", { pane = 10 }); world:advance(100)
	assert(world:inspect().attentionCount == 1, "generic focus and native alert disappearance never acknowledge")
	world:click(rail, rowAction(shown(world, rail), "menu")); world:chooseLabel("Finished for now · current scope"); world:advance(100)
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu")); world:chooseLabel("New tab here"); world:advance(100)
	assert(#world.sessionSwitches == 1 and world:inspect().attentionCount == 0 and savedItemFor(world, 10).disposition == "finished",
		"a generic quiet-session switch never acknowledges or reactivates its Finished record")
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu")); world:chooseLabel("Bring back now"); world:advance(100)
	assert(world:inspect().attentionCount == 1, "unreviewed Finished work can be brought back after a generic switch")
end

do
	local world = native(true)
	world.agentAlert = true
	world.identityFiles[10] = "/sessions/migration.jsonl"
	world.savedTriage = { schema = 1, records = {
		{ window = "desktop", host = "local", pane = 10, firstSeenUtc = 1699999999, bucket = "backlog" },
	} }
	world:advance(3100)
	assert(world.savedTriage.schema == 3 and world:inspect().attentionCount == 0 and savedItemFor(world, 10).disposition == "finished"
		and savedItemFor(world, 10).retained, "positive same-scope native attention joins legacy Backlog as retained Finished")
	local writes, processes = world.triageWrites, #world.processes
	world:advance(5000)
	assert(world.triageWrites == writes and #world.processes == processes,
		"unchanged heartbeats neither rewrite durable facts nor spawn identity processes")
end

do
	local world = native(true)
	world.savedTriage = { schema = 1, records = {
		{ window = "desktop", host = "local", pane = 42, firstSeenUtc = 1699999999, bucket = "backlog" },
	} }
	world.failTriageRead = true
	world:advance(3100)
	assert(world.triageWrites == 0 and world.savedTriage.schema == 1 and world:inspect().status == "unavailable",
		"an unreadable KV store is not an empty new store and is never overwritten")
	world:emit("agent_finished", { pane = 10, result = "failed" })
	world.failTriageRead = false
	world:advance(1100)
	local finished = 0
	for _, item in ipairs(world.savedTriage.items) do
		if item.disposition == "finished" and item.retained then finished += 1 end
	end
	assert(world:inspect().attentionCount == 1 and finished == 1,
		"load recovery preserves saved unavailable records and queued observations")
end

for _, failure in { "json", "shape", "stdout", "stderr", "timeout", "exit", "context", "spawn" } do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/bad-result.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity, world.failIdentitySpawn = true, failure == "spawn"
	world:click(rail, rowAction(shown(world, rail)))
	local request = #world.processes
	if failure ~= "spawn" then
		local result = { status = 0, stdout = "invalid-json", stderr = "", timed_out = false }
		if failure == "shape" then
			world.processes[request].document = { panes = "not an array" }
			result = nil
		elseif failure == "stdout" then result.stdout = string.rep("x", 4 * 1024 * 1024 + 1)
		elseif failure == "stderr" then result.stderr = string.rep("x", 65537)
		elseif failure == "timeout" then result.timed_out, result.status = true, -1
		elseif failure == "exit" then result.status = 1 end
		world:completeIdentity(request, result, { noContext = failure == "context" })
	end
	world:advance(100)
	assert(world.focusWrites == 0 and world:inspect().attentionCount == 1,
		"invalid identity " .. failure .. " cannot focus or acknowledge retained review")
	local attempts = world.inspections
	world:advance(1900)
	assert(world.inspections == attempts, "a failed inspection waits out its 2s backoff before retrying")
	world:advance(1100)
	assert(world.inspections == attempts + 1, "exactly one backoff retry runs while the proof stays unresolved")
end

do
	-- Content signals (title/agent events) must not re-admit an inspection while the failure backoff is
	-- armed; a structural input (a new pane appearing) re-proves immediately even mid-backoff.
	local world = native(true)
	world:advance(3100)
	local attempts = world.inspections
	assert(attempts > 0, "fixture: the settled conversation proved identity at least once")
	world.holdIdentity = true
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(100)
	local failed = world.inspections
	assert(failed == attempts + 1, "fixture: a content signal admits one inspection while nothing is failing")
	world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "host unreachable", timed_out = false })
	world:advance(100)
	attempts = world.inspections
	for _ = 1, 4 do
		world:emit("agent_state", { pane = 10, old = "working", new = "idle" })
		world:emit("title", { pane = 10 })
		world:advance(100)
	end
	assert(world.inspections == attempts,
		"content signals during a failing inspection wait out the backoff instead of respawning")
	world:addTab(5, 12)
	world:emit("title", { pane = 12 }); world:advance(100)
	assert(world.inspections == attempts + 1,
		"a new pane is structural and re-proves immediately despite the armed backoff")
	world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "still unreachable", timed_out = false })
	world:advance(100)
	assert(world:inspect().identityRetryDelayMs == 4000,
		"the structural attempt's failure doubles the backoff for later content signals")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/inventory-recovery.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	assert(world:inspect().identityRetryDelayMs == nil, "a known waiting identity starts with no identity failure")
	local launches = world.inspections
	world.failInventory = true
	world:advance(1100)
	assert(world.inspections == launches, "unavailable inventory never launches identity inspection")
	world:advance(3000)
	world.failInventory = false
	world:advance(1100)
	assert(world.inspections == launches + 1,
		"inventory recovery with unchanged membership performs exactly one bounded identity inspection")
	assert(world:inspect().identityRetryDelayMs == nil and world:inspect().attentionCount == 1,
		"recovered known identity is verified again rather than reserved as stale forever")
	world:advance(10000)
	assert(world.inspections == launches + 1, "recovered unchanged heartbeats do not poll identity")
	for _, request in world.processes do
		assert(request.argv[1] == "/Applications/Tern.app/Contents/MacOS/tern",
			"identity inspection spawns the version-matched app bundle CLI before PATH copies")
	end
	assert(#world.processes >= 2 and world.bundleProbes == 1 and #world.cliProbes == 1,
		"the resolved CLI path is reused for the VM rather than probed per inspection")
end

for _, failure in { "exit", "spawn" } do
	for _, outcome in { "recover", "fail" } do
		local label = failure .. "/" .. outcome
		local world = native(true)
		world.identityFiles[10] = "/sessions/inspect-recovery.jsonl"
		world:advance(3100)
		local rail = world.opens[1].pane
		local launches = world.inspections
		world.holdIdentity, world.failIdentitySpawn = true, failure == "spawn"
		world:click(rail, rowAction(shown(world, rail)))
		assert(world.inspections == launches + 1, "Open requests one fresh identity proof: " .. label)
		if failure == "exit" then
			world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "inspect failed", timed_out = false })
		end
		world:advance(100)
		assert(world.focusWrites == 0 and world:inspect().attentionCount == 1 and #world.warnings > 0
			and world:inspect().identityRetryDelayMs ~= nil,
			"failed proof retains the P0 as unverified with a logged reason: " .. label)
		world:advance(1900)
		assert(world.inspections == launches + 1, "a failed inspection waits out its 2s backoff: " .. label)
		if outcome == "recover" then world.failIdentitySpawn = false end
		world:advance(1100)
		assert(world.inspections == launches + 2, "one backoff retry follows a failed inspection: " .. label)
		if outcome == "recover" then
			world:completeIdentity(#world.processes); world:advance(100)
			local recovered = world:inspect()
			assert(recovered.notice == nil and recovered.attentionCount == 1 and world.focusWrites == 0,
				"a successful retry restores verified identity and clears the failure without acknowledging: " .. label)
			world.holdIdentity = false
			local beforeMetadata = world.inspections
			world:advance(10000)
			assert(world.inspections == beforeMetadata, "verified rows do not spawn proof work on every heartbeat: " .. label)
			world:advance(20000)
			assert(world.inspections > beforeMetadata and world.inspections <= beforeMetadata + 2
				and world:inspect().attentionCount == 1 and world.focusWrites == 0,
				"coarse locator reconciliation preserves unchanged review instead of polling per heartbeat: " .. label)
		else
			if failure == "exit" then
				world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "inspect failed", timed_out = false })
			end
			world:advance(100)
			assert(world:inspect().identityRetryDelayMs == 4000, "a failed retry doubles the next backoff: " .. label)
			world:advance(5200)
			assert(world.inspections == launches + 3 and world:inspect().attentionCount == 1 and world.focusWrites == 0
				and world:inspect().identityRetryDelayMs ~= nil,
				"a failed retry stays truthfully unverified and retries on the doubled backoff: " .. label)
			if failure == "exit" then
				world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "inspect failed", timed_out = false })
				world:advance(100)
			end
			world.failIdentitySpawn = false
			world:click(rail, rowAction(shown(world, rail)))
			assert(world.inspections == launches + 4, "an explicit Open retries identity exactly once: " .. label)
		end
	end
end

do
	local world = native(true)
	world.cliFiles["/Applications/Tern.app/Contents/MacOS/tern"] = nil
	world.identityFiles[10] = "/sessions/path-cli.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	assert(#world.processes >= 1 and world.processes[1].argv[1] == "/opt/tern/bin/tern",
		"without the app bundle, inspection uses the first existing absolute PATH entry")
	assert(table.concat(world.cliProbes, "|") == "/Applications/Tern.app/Contents/MacOS/tern|/usr/bin/tern|/opt/tern/bin/tern",
		"resolution probes the bundle, then absolute PATH entries, skipping empty and relative entries")
	local before = #world.processes
	world:click(rail, rowAction(shown(world, rail)))
	world:advance(100)
	assert(#world.processes == before + 1 and world.processes[#world.processes].argv[1] == "/opt/tern/bin/tern"
		and #world.cliProbes == 3, "a later inspection reuses the resolved PATH CLI without probing again")
end

do
	-- A verified identity is persisted, then a new VM finds no CLI: the identity-gated review must stay unverified.
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/missing-cli.jsonl"
	world:advance(3100)
	local spawned = #world.processes
	assert(spawned >= 1 and world:inspect().attentionCount == 1, "the review starts with a verified native identity")
	world.cliFiles = {}
	world:reload()
	world:advance(3100)
	local logged = false
	for _, warning in world.warnings do
		if string.find(warning, "Tern CLI not found for identity inspection", 1, true) then logged = true end
	end
	assert(logged and #world.processes == spawned and world.focusWrites == 0 and world:inspect().attentionCount == 1,
		"a missing CLI never spawns a bare executable and reports a clear failure")
	world:advance(60000)
	assert(world:inspect().identityRetryDelayMs == 60000 and world.bundleProbes > 1,
		"resolution failures keep retrying on a capped 60s backoff rather than a tight loop")
	local settled = world.bundleProbes
	world:advance(61000)
	assert(world.bundleProbes == settled + 1, "the capped backoff probes again at the 60s cadence")
	world:command("next"); world:advance(100)
	assert(world.bundleProbes == settled + 2 and world.focusWrites == 0 and world:inspect().attentionCount == 1
		and #world.processes == spawned, "Next with no CLI resolves once and cannot focus or acknowledge")
	world:advance(59000)
	assert(world.bundleProbes == settled + 2, "the failed resolution waits out its capped backoff")
	world:advance(2000)
	assert(world.bundleProbes == settled + 3 and #world.processes == spawned and world.focusWrites == 0,
		"one capped backoff retry follows a failed resolution without ever spawning")
end

for _, change in { "owner", "epoch", "membership", "conversation" } do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/original.jsonl"
	world:addTab(4, 11)
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	local request = #world.processes
	if change == "owner" then world.prefs.owner = "other-window"
	elseif change == "epoch" then world:command("disable"); world:command("enable")
	elseif change == "membership" then world.membership[10] = 4
	else
		world.identityFiles[10] = "/sessions/replacement.jsonl"
		world.processes[request].document = world:identityDocument()
	end
	world:completeIdentity(request); world:advance(100)
	assert(world.focusWrites == 0, "late identity callback after " .. change .. " never routes the captured target")
	assert(#world.savedTriage.items >= 1, "late callback preserves pending evidence")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/ambiguous.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.membership[10], world.agentAlert = nil, false
	world.focused = rail
	world:addTab(4, 11)
	world:addTab(5, 12)
	world.identityFiles[11], world.identityFiles[12] = world.identityFiles[10], world.identityFiles[10]
	world:reload(); world:advance(1100)
	assert(world:inspect().attentionCount == 1 and world.focusWrites == 0,
		"ambiguous remapping retains one unavailable record without guessing a destination")
	world:command("next"); world:advance(100)
	assert(world.focusWrites == 0, "Next excludes ambiguous restored identity")
	local remove = rowAction(shown(world, rail), "menu")
	assert(remove, "unavailable identity exposes its revision-bound tracking menu")
	local writes = world.layoutWrites
	world:click(rail, remove); world:chooseLabel("Remove unavailable tracking · no verified route"); world:advance(100)
	assert(world:inspect().attentionCount == 0 and world.layoutWrites == writes and world.focusWrites == 0
		and world.membership[11] and world.membership[12],
		"removing an orphan changes only Attention, never either native session")
end

do
	local world = native(true)
	world.agentState = "idle"
	world:advance(3100)
	local rail = world.opens[1].pane
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local oldAction = rowAction(shown(world, rail))
	assert(oldAction, "first failure is published")
	world.failNextCanvasSet = true
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" })
	world:emit("agent_finished", { pane = 10, result = "failed" })
	world:advance(32)
	assert(rowAction(shown(world, rail)) == oldAction,
		"rejected canvas update leaves the original Open token visible")
	world:click(rail, oldAction); world:advance(100)
	assert(world.focusWrites == 1 and world:inspect().attentionCount == 1,
		"the last accepted canvas binding remains actionable but cannot acknowledge an unpainted newer failure")
	local newAction = rowAction(shown(world, rail))
	assert(newAction and newAction ~= oldAction, "successful retry publishes the newer revision's distinct token")
	world:click(rail, newAction); world:advance(100)
	assert(world:inspect().attentionCount == 0, "the newly published Open acknowledges the newer failure")
end

for _, identityChange in { false, true } do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/visit-before-state.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	local firstRequest = #world.processes
	world:completeIdentity(firstRequest)
	assert(world.focusWrites == 1 and world:inspect().navigationPending,
		"fresh identity proof focuses the target but still requires a destination readback")
	if identityChange then world.identityFiles[10] = "/sessions/visit-replacement.jsonl" end
	world.agentState = "exited"
	world:emit("agent_state", { pane = 10, old = "idle", new = "exited" })
	world:advance(32)
	assert(#world.processes > firstRequest and world:inspect().navigationPending and world:inspect().attentionCount == 1,
		"new state invalidates the returned snapshot's old proof before it can acknowledge")
	local replacementRequest = #world.processes
	world:advance(1100)
	assert(world:inspect().navigationPending and world:inspect().attentionCount == 1,
		"temporary proof unavailability waits for the bounded native inspection rather than cancelling the visit")
	world:completeIdentity(replacementRequest); world:advance(100)
	assert(not world:inspect().navigationPending and world.focusWrites == 1,
		"completed proof settles the existing visit without an extra focus write")
	assert(world:inspect().attentionCount == (if identityChange then 1 else 0),
		if identityChange then "same-pane replacement cannot acknowledge the original conversation"
			else "same-identity proof acknowledges the captured revision after the temporary wait")
end

do
	-- Native Tern runs many unrelated agents, so every inspection overlaps their state changes and pane creation.
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/restored-under-churn.jsonl"
	world:addTab(4, 11, 1, 7)
	world.identityFiles[11] = "/sessions/unrelated-churn.jsonl"
	world.additionalAgents = { [11] = "working" }
	world:advance(3100)
	local rail = world.opens[1].pane
	assert(world:inspect().attentionCount == 1, "the known identity starts as one P0 review")
	world.holdIdentity = true
	world:reload()
	local created = 0
	local function churn()
		for _ = 1, 3 do
			local old = world.additionalAgents[11]
			world.additionalAgents[11] = if old == "working" then "idle" else "working"
			world:emit("agent_state", { pane = 11, old = old, new = world.additionalAgents[11] })
		end
		created += 1
		local pane = 20 + created
		world:addTab(40 + created, pane, 1, 7)
		world.additionalAgents[pane] = "working"
		world:emit("pane_created", { pane = pane })
		world:emit("agent_state", { pane = pane, old = "idle", new = "working" })
		world:advance(32)
	end
	local function settle()
		local request = #world.processes
		churn()
		world:completeIdentity(request); world:advance(32)
		return request
	end
	world:advance(3100)
	local first = #world.processes
	assert(world.processes[first].vm == world.vm,
		"relaunch starts one inspection with the restored review unverified")
	assert(settle() == first and #world.processes == first + 1,
		"unrelated dirty panes coalesce into exactly one follow-up inspection")
	assert(world:inspect().attentionCount == 1,
		"unrelated activity during the first inspection cannot keep the restored known identity unverified")
	local request = settle()
	assert(#world.processes == request + 1,
		"continuous unrelated activity keeps one follow-up in flight without unverifying the restored review")
	world.focused = rail
	world:command("next")
	assert(world.focusWrites == 0, "known identity navigation waits for a fresh proof")
	for _ = 1, 2 do
		if world.focusWrites == 0 then settle() end
	end
	world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 1 and not world:inspect().navigationPending,
		"a restored known identity navigates within bounded inspections despite unrelated activity")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/target-signal.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	-- Complete within the 3s inspection deadline: a raced-but-valid response with a dirty target pane
	-- is a stale success, and its one content follow-up runs immediately under the input-class gate.
	world:reload(); world:advance(2000)
	local request = #world.processes
	world.agentState = "exited"
	world:emit("agent_state", { pane = 10, old = "idle", new = "exited" }); world:advance(32)
	world:completeIdentity(request); world:advance(32)
	assert(#world.processes == request + 1,
		"a signal on the target during inspection keeps it pending and schedules one follow-up inspection")
	world:completeIdentity(#world.processes); world:advance(32)
	assert(world:inspect().attentionCount == 1
		and #world.processes == request + 1, "the follow-up inspection verifies the target without further polling")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world.identityFiles[10] = "/sessions/moved-target.jsonl"
	world:addTab(4, 11)
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	local request = #world.processes
	-- The captured document still names the original conversation; the move invalidates it.
	world.membership[10], world.agentAlert = 4, false
	world:completeIdentity(request); world:advance(32)
	assert(world.focusWrites == 0 and #world.processes == request + 1 and not world:inspect().navigationPending,
		"a target that moved during inspection rejects the captured key and is re-inspected once")
	world.identityFiles[10] = "/sessions/moved-replacement.jsonl"
	world.processes[#world.processes].document = world:identityDocument()
	world:completeIdentity(#world.processes); world:advance(100)
	world:command("next"); world:advance(100)
	assert(world.focusWrites == 0 and world:inspect().attentionCount == 1,
		"the moved pane's new conversation never verifies the original review")
end

do
	local function reviewWorld()
		local world = native(true)
		world.agentState = "idle"
		world:advance(3100)
		world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
		assert(world:inspect().attentionCount == 1, "each scenario starts from one published review")
		return world
	end

	for _, transcript in ipairs({
		{ { role = "user", text = "my reply", tools = {} } },
		{ { role = "assistant", text = "result", tools = {} } },
		{},
	}) do
		local world = reviewWorld()
		local rail = world.opens[1].pane
		local revision = world.savedTriage.items[1].reviewRevision
		world.transcripts[10], world.agentState = transcript, "working"
		world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(32)
		assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail))
			and world.savedTriage.items[1].reviewRevision == revision and world.savedTriage.items[1].reviewSuperseded == true,
			"native resumption supersedes presentation without transcript-based acknowledgment or loss of the unread revision")
		world.agentState = "idle"
		world:emit("agent_state", { pane = 10, old = "working", new = "idle" }); world:advance(100)
		assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail))
			and world.savedTriage.items[1].reviewRevision == revision,
			"idle alone cannot resurrect a superseded review")
	end

	local racing = reviewWorld()
	local rail = racing.opens[1].pane
	local older = rowAction(shown(racing, rail))
	local olderRevision = racing.savedTriage.items[1].reviewRevision
	racing.transcripts[10] = { { role = "user", text = "my reply", tools = {} } }
	racing.agentState = "working"
	racing:emit("agent_state", { pane = 10, old = "idle", new = "working" }); racing:advance(32)
	racing:emit("agent_finished", { pane = 10, result = "done" }); racing:advance(32)
	local newerRevision = racing.savedTriage.items[1].reviewRevision
	assert(newerRevision ~= nil and newerRevision ~= olderRevision and racing:inspect().attentionCount == 0
		and not rowAction(shown(racing, rail)),
		"a newer completion is retained but not presented while native inventory still reports working")
	racing.agentState = "idle"
	racing:emit("agent_state", { pane = 10, old = "working", new = "idle" }); racing:advance(100)
	local newer = rowAction(shown(racing, rail))
	assert(racing:inspect().attentionCount == 1 and newer ~= nil and newer ~= older
		and racing.savedTriage.items[1].reviewRevision == newerRevision,
		"settled runtime publishes the retained newer completion despite a synthetic role=user transcript")
	racing:click(rail, newer); racing:advance(100)
	assert(racing:inspect().attentionCount == 0 and racing.savedTriage.items[1].reviewRevision == nil,
		"exact Open, not resumption or transcript roles, acknowledges the newly published completion")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.failTriageRead = true
	world:reload()
	world:advance(50)
	local line = world.canvases[pane].view.c[1].p.text
	assert(string.find(line, "Attention paused · Saved attention is unavailable", 1, true),
		"hydrate failure paints a one-line paused state on the owned canvas")
	assert(world:inspect().status == "unavailable", "hydrate failure never fabricates a count")
	local sets = world.canvasSetsByPane[pane]
	world.failTriageRead = false
	world:advance(2100)
	assert(world.canvasSetsByPane[pane] > sets
		and not string.find(world.canvases[pane].view.c[1].p.text or "", "Attention paused", 1, true),
		"recovered storage repaints the full rail instead of the paused line")
end

do
	-- A refused store surfaces plain words: no Lua traceback and no filesystem path in anything the user can see.
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.failTriageRead = true
	world.triageReadMessage = "EOF while parsing /Users/someone/Library/Application Support/Tern/plugin-data/attention/kv.json"
		.. "\nstack traceback:\n\t[C]: in function 'error'\n\t/Users/someone/tern/window.luau:12: in function <window.luau:9>"
	world:reload()
	world:advance(50)
	local texts = {}
	local function collect(item)
		if type(item) ~= "table" then return end
		if type(item.p) == "table" and type(item.p.text) == "string" then table.insert(texts, item.p.text) end
		for _, child in ipairs(item.c or {}) do collect(child) end
	end
	collect(world.canvases[pane].view)
	local diagnostics = world:inspect()
	table.insert(texts, diagnostics.notice or "")
	local joined = table.concat(texts, "\n")
	assert(string.find(joined, "Saved attention is unavailable", 1, true) and string.find(joined, "EOF while parsing", 1, true),
		"the refusal stays readable")
	for _, forbidden in { "stack traceback", "/Users", "/Library", ".luau", "kv.json" } do
		assert(not string.find(joined, forbidden, 1, true), "notice must not expose " .. forbidden .. ": " .. joined)
	end
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.failCurrentHost = true
	world:advance(1100)
	local line = world.canvases[pane].view.c[1].p.text
	assert(line == "Attention paused · native current host unavailable",
		"a failed pass paints one degraded line without source-file prefixes")
	world.failCurrentHost = false
	world:advance(1100)
	assert(world.canvases[pane].view.c[1].p.text ~= line, "a recovered pass renders the rail again")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.canvases[pane].title = "Deep research"
	world.prefs.owner = "laptop"
	world:advance(1100)
	assert(world.canvases[pane].view.c[1].p.text == "Controlled in another window · use Enable here",
		"a non-owner window paints the controlled line once")
	assert(world.canvases[pane].title == "Attention", "ownership loss resets the owned canvas title")
	local writes = world.canvasSetsByPane[pane]
	world:advance(3000)
	assert(world.canvasSetsByPane[pane] == writes, "the controlled line repaints only on change")
end

do
	local world = native(true)
	world:advance(3100)
	local pane = world.opens[1].pane
	world.canvases[pane].title = "Deep research"
	world:command("disable")
	assert(world.canvases[pane].title == "Attention"
		and world.canvases[pane].view.c[1].p.text == "Attention is disabled",
		"disabling resets the owned canvas title and paints the disabled state")
	assert(world.prefs.enabled == false, "disabling persists the disabled preference")
end

do
	local world = native(true)
	world.agentState = "idle"
	world:advance(3100)
	assert(world:inspect().attentionCount == 0 and world:inspect().count == 1,
		"All work includes the eligible idle conversation without inventing an Attention cue")
	world:command("next")
	local informed = 0
	for _, toast in world.toasts do
		if toast.kind == "info" and toast.message == "No conversations need attention" then informed += 1 end
	end
	assert(informed == 1, "an empty round explains itself once as a toast")
	assert(world:inspect().notice == nil, "an informational result never persists as the rail notice")
end

do
	local world = native(true)
	world:advance(3100)
	world.focused = nil
	world:command("open")
	assert(toastCount(world, "info", "No mounted rail — use native navigation") == 1 and toastCount(world, "error", "") == 0,
		"Open without selected content states why no rail is mounted instead of failing")
	local state = world:inspect()
	assert(state.availability.state == "no-content" and string.find(state.notice or "", "native navigation", 1, true),
		"the reason is recorded on the availability record and the rail notice")
	world.focused = 10
	world:command("open")
	assert(toastCount(world, "info", "No mounted rail") == 1 and world:inspect().availability.state == "mounted",
		"Open with selected content mounts without another report")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/backoff.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	local function failHeld()
		world:completeIdentity(#world.processes, { status = 1, stdout = "", stderr = "inspect failed", timed_out = false })
		return world.now
	end
	local function retryAfter(failAt, delay)
		local before = world.inspections
		world:advance(delay - 1)
		assert(world.inspections == before, "no retry fires before its backoff elapses")
		world:advance(1001)
		assert(world.inspections == before + 1, "exactly one retry follows the elapsed backoff")
		return world.processes[#world.processes].at - failAt
	end
	local failAt = failHeld()
	assert(world:inspect().identityRetryDelayMs == 2000, "the first failure schedules a 2s retry")
	local gap = retryAfter(failAt, 2000)
	assert(gap >= 2000 and gap <= 3000, "the first retry waits out the 2s backoff")
	failAt = failHeld()
	assert(world:inspect().identityRetryDelayMs == 4000, "the second failure doubles the backoff")
	gap = retryAfter(failAt, 4000)
	assert(gap >= 4000 and gap <= 5000, "the second retry waits out the 4s backoff")
	failAt = failHeld()
	assert(world:inspect().identityRetryDelayMs == 8000, "the third failure doubles the backoff again")
	gap = retryAfter(failAt, 8000)
	assert(gap >= 8000 and gap <= 9000, "the third retry waits out the 8s backoff")
	for _ = 1, 3 do
		failAt = failHeld()
		retryAfter(failAt, world:inspect().identityRetryDelayMs)
	end
	assert(world:inspect().identityRetryDelayMs == 60000, "the backoff caps at 60s")
	world.holdIdentity = false
	world:completeIdentity(#world.processes)
	assert(world:inspect().identityRetryDelayMs == nil, "a successful proof resets the backoff")
end

do
	local world = native(true)
	world:addTab(4, 11, 5, 7)
	world:addTab(6, 14, 5, 9)
	world.additionalAgents = { [11] = "waiting_input" }
	world:advance(3100)
	world:switch(4); world:advance(3100)
	local rail = world.opens[#world.opens].pane
	assert(world.prefs.instances["host-5"]["4"], "the remote tab records its instance")
	world.hostStates[5] = "disconnected"
	world.tabs[4], world.layouts[4] = nil, nil
	world.membership[11], world.membership[rail], world.canvases[rail] = nil, nil, nil
	world:switch(3)
	world:advance(4100)
	assert(world.prefs.instances["host-5"]["4"], "a disconnected host never retires its instances")
	world.hostStates[5] = nil
	world:advance(1500)
	assert(world.prefs.instances["host-5"]["4"], "absence shorter than three passes keeps the instance")
	world:advance(31000)
	assert(world.prefs.instances["host-5"] == nil,
		"an unobserved remote tab close retires after sustained absence, dropping the emptied host bucket")
	assert(instanceFor(world, 4) == nil, "the retired rail leaves the diagnostics inventory")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:advance(3100)
	world:switch(3); world:advance(100)
	world:switch(4); world:advance(100)
	world:switch(5); world:advance(100)
	assert(world.focusWrites == 0, "walking content panes performs no focus writes")
	world:command("previous")
	world:emit("focus", { pane = 11 }); world:advance(100)
	assert(world.focused == 11 and world.focusWrites == 1, "Previous walks back to the middle pane")
	world:command("previous")
	world:emit("focus", { pane = 10 }); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 2, "Previous walks back to the first pane")
	local toasts = #world.toasts
	world:command("previous"); world:advance(100)
	local empty = 0
	for _, toast in world.toasts do
		if toast.message == "No previous pane to return to" then empty += 1 end
	end
	assert(world.focusWrites == 2 and world.focused == 10 and empty == 1 and #world.toasts == toasts + 1,
		"an exhausted history explains itself once without focusing anything")
end

do
	local world = native(true)
	world.agentState = "idle"
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	assert(world:inspect().attentionCount == 1, "a failed completion leaves exactly one review pending")
	world:addTab(4, 11)
	world:switch(4); world:advance(100)
	local writes, triage = world.focusWrites, world.triageWrites
	world:command("previous")
	world:emit("focus", { pane = 10 }); world:advance(100)
	local review = world:inspect()
	assert(world.focused == 10 and world.focusWrites == writes + 1,
		"Previous returns to the pane holding the pending review")
	assert(review.attentionCount == 1 and review.navigationPending == false,
		"the restore is location-only: the review stays pending in its bucket with no round consumed")
	assert(world.triageWrites == triage, "Previous persists no triage change")
	world:command("next"); world:advance(100)
	assert(world.focused == 10 and world:inspect().attentionCount == 0,
		"Next still visits and acknowledges the review after Previous returned to it")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local rail = world.opens[1].pane
	world:switch(4); world:advance(100)
	world.focused = rail
	world:emit("focus", { pane = rail }); world:advance(100)
	local writes = world.focusWrites
	local reads = world.inventoryReads
	world:control(rail, "previous")
	assert(world.inventoryReads - reads == 1, "a Previous click takes exactly one native inventory")
	world:emit("focus", { pane = 10 }); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == writes + 1,
		"focusing the Attention rail never records it: Previous returns to the last departed content pane")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:addTab(6, 13)
	world:advance(3100)
	world:switch(4)
	world:switch(5)
	world:switch(6)
	world:advance(100)
	assert(world:inspect().previousDepth == 3,
		"focus events reduce in arrival order: a whole batch of transitions survives until the pass")
	world:command("previous")
	world:emit("focus", { pane = 12 }); world:advance(100)
	assert(world.focused == 12,
		"Previous returns to the middle emitted pane rather than the walk's collapsed endpoints")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:addTab(6, 13)
	world:advance(3100)
	world:switch(4); world:advance(100)
	world:switch(5); world:advance(100)
	world:switch(6); world:advance(100)
	world:closePane(12); world:advance(100)
	assert(world:inspect().previousDepth == 2, "closing a pane prunes it from the focus history")
	local writes = world.focusWrites
	world:command("previous")
	world:emit("focus", { pane = 11 }); world:advance(100)
	local empty = 0
	for _, toast in world.toasts do
		if toast.message == "No previous pane to return to" then empty += 1 end
	end
	assert(world.focused == 11 and world.focusWrites == writes + 1 and empty == 0,
		"Previous skips the closed pane and lands on the next valid entry")
end

do
	local world = native(true)
	world.agentState = "idle"
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	world:addTab(4, 11)
	world:switch(4); world:advance(100)
	local writes = world.focusWrites
	world:command("next")
	assert(world.focused == 10 and world.focusWrites == writes + 1, "Next jumps to the pending review")
	world:emit("focus", { pane = 10 })
	world:command("previous")
	world:emit("focus", { pane = 11 }); world:advance(100)
	local state = world:inspect()
	assert(world.focused == 11 and world.focusWrites == writes + 2,
		"Previous immediately restores the pane the jump departed")
	assert(state.attentionCount == 1 and state.navigationPending == false,
		"the outstanding visit is discarded without acknowledging or skipping the review")
	world:command("next"); world:advance(100)
	assert(world.focused == 10 and world:inspect().attentionCount == 0,
		"the superseded round stays intact for the next explicit Next")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:advance(3100)
	world:switch(4); world:advance(100)
	world:command("previous")
	world:emit("focus", { pane = 10 }); world:advance(100)
	world:switch(5); world:advance(100)
	assert(world:inspect().previousDepth == 1, "departing a restored pane pushes it back onto the history")
	local writes = world.focusWrites
	world:command("previous")
	world:emit("focus", { pane = 10 }); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == writes + 1,
		"a pane reached through Previous is returned to again after the next departure")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:addTab(5, 12)
	world:advance(3100)
	world:switch(4); world:advance(100)
	world:switch(5); world:advance(100)
	local writes = world.focusWrites
	world:command("previous")
	world:command("previous")
	assert(world.focused == 11 and world.focusWrites == writes + 1,
		"a back-to-back Previous coalesces into the single outstanding focus write")
	world:advance(100)
	world:command("previous")
	world:emit("focus", { pane = 10 }); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == writes + 2,
		"the coalesced press loses nothing: the next Previous still walks one entry")
end

do
	local world = native(true)
	local path = "/sessions/factual.jsonl"
	world.agentState, world.agentAlert, world.identityFiles[10] = "idle", true, path
	world.sourceRecords[path] = nativeCanvas.sourceFact("source-1")
	world:advance(3100)
	assert(world:helperCount("source") == 1, "one owner acquires the exact native-proven local source")
	local source = world.savedTriage.items[1].source
	assert(source.sessionId == "header-uuid" and source.lastHuman.atUtc == 1700000000,
		"source-qualified recorded clocks survive canonical persistence without role=user transcript guesses")
	local reads = world:helperCount("source")
	world:advance(5000)
	assert(world:helperCount("source") == reads, "unchanged source is not replayed on the heartbeat")
	world:addTab(4, 11)
	world:switch(4); world:advance(3100)
	assert(world:helperCount("source") == reads, "another physical canvas does not create another source acquisition")
	world:switch(3); world:advance(100)
	local rail = world.opens[1].pane
	world:control(rail, "attention"); world:advance(100)
	world:expandRow(rail, shown(world, rail)); world:advance(100)
	assert(world.focusWrites == 0 and world:inspect().logical.expandedWorkId ~= nil,
		"global disclosure inspects factual evidence without navigation or acknowledgment")
	world.sourceRecords[path].revision = "source-2"
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(world:helperCount("source") == reads + 1 and world.savedTriage.items[1].source.revision == "source-2"
		and world.savedTriage.items[1].source.lastHuman.atUtc == 1700000000,
		"coalesced source replay advances observation without resetting a recorded human clock")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/stale-source.jsonl"
	world.sourceRecords["/sessions/stale-source.jsonl"] = nativeCanvas.sourceFact("old-meaning")
	world.holdSources = true
	world:advance(3100)
	local request = #world.sourceProcesses
	world.identityFiles[10] = "/sessions/replacement.jsonl"
	world:emit("agent_state", { pane = 10, old = "waiting_input", new = "working" })
	world:advance(100)
	world:completeSource(request); world:advance(100)
	assert(world.savedTriage.items[1].source == nil,
		"old helper results cannot enrich a pane after its exact source identity changes")
end

do
	-- Closing every pane of a conversation leaves no source bookkeeping behind: the pane-keyed flags and
	-- locator epochs drop their keys, and with no locator, retained record or in-flight request holding the
	-- identity key, the fact, observation and header caches drop it too.
	local world = native(true)
	local path = "/sessions/dead-pane-bookkeeping.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = nativeCanvas.sourceFact("settled-body")
	world:advance(3100)
	local settled = world:inspect().sourceKeys
	assert(settled.dirty == 0 and settled.locatorEpochs == 1 and settled.facts == 1 and settled.observations == 1,
		"fixture: the settled conversation holds locator, fact and observation keys and nothing dirty")
	world:emit("title", { pane = 10 })
	world:closePane(10)
	world:advance(1100)
	local closed = world:inspect().sourceKeys
	assert(closed.dirty == 0 and closed.pollPending == 0 and closed.locatorEpochs == 0,
		"a closed pane leaves no dirty, poll-pending or epoch keys after the next pass")
	assert(closed.facts == 0 and closed.observations == 0 and closed.headers == 0,
		"with no locator, retained record or in-flight request, the identity-keyed caches drop the key")
end

do
	-- A retained no-pane record keeps its identity-keyed fact, so a reopened conversation resumes incremental
	-- capture, while its dead pane's flags and epochs are still dropped.
	local world = native(true)
	local path = "/sessions/retained-bookkeeping.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = nativeCanvas.sourceFact("retained-body")
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "menu")); world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(world.savedTriage.items[1].disposition == "finished", "fixture: the conversation is finished before its pane closes")
	world:closePane(10); world:advance(1100)
	local keys = world:inspect().sourceKeys
	assert(keys.locatorEpochs == 0 and keys.dirty == 0, "the retained record's dead pane still drops its flags")
	assert(keys.facts == 1 and keys.observations == 1,
		"the retained no-pane record pins its source fact and observation for a later reopen")
end

do
	-- An in-flight source read pins its identity key: eviction waits until the request settles.
	local world = native(true)
	local path = "/sessions/inflight-bookkeeping.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = nativeCanvas.sourceFact("inflight-body")
	world:advance(3100)
	world.holdSources = true
	world.sourceRecords[path].revision = "inflight-body-2"
	world:emit("title", { pane = 10 }); world:advance(100)
	local held = #world.sourceProcesses
	assert(held > 0 and not world.sourceProcesses[held].completed, "fixture: a source read is held in flight")
	world:closePane(10); world:advance(100)
	assert(world:inspect().sourceKeys.facts == 1, "the in-flight read keeps its key alive past the pane's closure")
	world:completeSource(held); world:advance(100)
	local settled = world:inspect().sourceKeys
	assert(settled.facts == 0 and settled.observations == 0,
		"once the request settles, the unreferenced key is evicted")
end

for _, change in ipairs({ "selection", "close", "owner" }) do
	local world = native(true)
	world.identityFiles[10] = "/sessions/stale-menu.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowAction(shown(world, rail), "menu"))
	if change == "selection" then world:closeSession(rail); world:advance(100)
	elseif change == "close" then world:closePane(10); world:advance(100)
	else world.prefs.owner = "other" end
	local writes = world.triageWrites
	world:chooseLabel("Keep as reference"); world:advance(100)
	assert(world.triageWrites == writes, "stale " .. change .. " picker must not mutate another logical selection or conversation")
end

do
	local world = native(true)
	for index = 1, 41 do
		local tab, pane = 20 + index, 200 + index
		world:addTab(tab, pane, 1, 7)
		world.additionalAgents = world.additionalAgents or {}
		world.additionalAgents[pane] = "waiting_input"
		world.identityFiles[pane] = "/sessions/page-" .. index .. ".jsonl"
	end
	world:advance(3100)
	local first = world.opens[1].pane
	world:control(first, "attention"); world:advance(100)
	world:expandRow(first, shown(world, first)); world:advance(100)
	local selected = world:inspect().logical.expandedWorkId
	local rowsA = sectionRows(world, first).c
	world:switch(21); world:advance(3100)
	local second = world.opens[2].pane
	local rowsB = sectionRows(world, second).c
	assert(world:inspect().logical.expandedWorkId == selected
		and #rowsA == #rowsB and rowsA[1].p.key == rowsB[1].p.key,
		"expanded stable work is one global value across native sessions")
	local opens = #world.opens
	world:closePane(second); world:advance(100); world:command("open"); world:advance(3100)
	assert(#world.opens == opens + 1 and world:inspect().logical.expandedWorkId == selected,
		"physical canvas replacement recreates only renderer/cache and preserves the shared detail")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/explicit-intent.jsonl"
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowAction(shown(world, rail), "menu")); world:choose(1); world:choose(4); world:advance(100)
	assert(world.savedTriage.items[1].priority == 2, "priority picker persists explicit P2 independently of native input")
	world:click(rail, rowAction(shown(world, rail), "menu")); world:chooseLabel("Keep as reference"); world:advance(100)
	assert(world.savedTriage.items[1].disposition == "reference" and world.savedTriage.items[1].retained
		and world:inspect().attentionCount == 0, "reference is explicit retention, not question resolution or execution")
end

do
	local world = native(true)
	world.identityFiles[10] = "/sessions/silent-old.jsonl"
	world.sourceRecords["/sessions/silent-old.jsonl"] = nativeCanvas.sourceFact("old-source")
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowAction(shown(world, rail), "menu")); world:choose(1); world:choose(4); world:advance(100)
	world:click(rail, rowAction(shown(world, rail), "menu")); world:chooseLabel("Keep as reference"); world:advance(100)
	local oldSerial = world.savedTriage.items[1].serial
	local fresh = nativeCanvas.sourceFact("replacement-source")
	fresh.sessionId = "replacement-header"
	world.identityFiles[10] = "/sessions/silent-new.jsonl"
	world.sourceRecords["/sessions/silent-new.jsonl"] = fresh
	local inspections = world.inspections
	world:advance(10000)
	assert(world.inspections == inspections, "source locators are not re-inspected on every native heartbeat")
	world:advance(18000)
	local old, replacement = nil, nil
	for _, item in ipairs(world.savedTriage.items) do
		if item.serial == oldSerial then old = item
		elseif item.source and item.source.sessionId == "replacement-header" then replacement = item end
	end
	assert(world.inspections > inspections and world.inspections <= inspections + 2
		and old and old.priority == 2 and old.disposition == "reference"
		and old.source.sessionId == "header-uuid" and replacement and replacement.priority == nil
		and replacement.serial ~= oldSerial and world.focusWrites == 0,
		"coarse native locator refresh detects silent pane replacement without inheriting explicit intent or source clocks")
	assert(world.sourceProcesses[#world.sourceProcesses].input.targets[1].path == "/sessions/silent-new.jsonl",
		"metadata replay reads the freshly returned locator rather than the stale same-pane path")
end


do
	local world = native(true)
	world.identityFiles[10] = "/sessions/interrupted-proof.jsonl"
	world.holdIdentity = true
	world:advance(3100)
	local first = #world.processes
	world:advance(5000)
	assert(#world.processes > first and world.focusWrites == 0,
		"a lost native proof callback releases its expired slot and retries with backoff instead of wedging enrichment")
	world.holdIdentity = false
	world:completeIdentity(#world.processes); world:advance(100)
	local rail = world.opens[1].pane
	assert(world:inspect().attentionCount == 1,
		"recovered locator proof restores useful native state without acknowledging pending input")
	local inspections = world.inspections
	world:completeIdentity(first); world:advance(100)
	assert(world.inspections == inspections and world.focusWrites == 0,
		"late callback from an expired proof generation cannot supersede the accepted replacement request")
end

do
	local world = native(true)
	local path = "/sessions/delayed-success.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = nativeCanvas.sourceFact("delayed-source")
	world.holdIdentity = true
	world:advance(3100)
	local request = #world.processes
	-- The child succeeded, but its callback arrives after expiry before any timer can refresh.
	world.now = world.processes[request].at + 4100
	world:completeIdentity(request)
	for _, timer in world.timers do
		if not timer.cancelled and not timer.fired and timer.due < world.now then timer.due = world.now end
	end
	world:advance(0)
	assert(world.savedTriage.items[1].identityKey == nil and world.savedTriage.items[1].source == nil
		and world.focusWrites == 0,
		"a successful callback that expires its own request cannot persist a conversation binding")
	world:advance(3000)
	assert(#world.processes > request, "expired callback delivery must retain the bounded proof retry")
	world.holdIdentity = false
	world:completeIdentity(#world.processes); world:advance(100)
	assert(world.savedTriage.items[1].source and world.savedTriage.items[1].source.sessionId == "header-uuid"
		and world:inspect().attentionCount == 1 and world.focusWrites == 0,
		"a fresh retry restores recorded facts without navigating or acknowledging the conversation")
end

do
	local world = native(true)
	local path = "/sessions/incomplete-replay.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = { status = "partial", sessionId = "header-uuid", schemaVersion = 3,
		writerVersions = {}, revision = "same-observation", selection = "unknown", complete = false, reusable = false,
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } },
		questionCoverage = { status = "unknown", knownTotal = 0, included = 0, omitted = 0 } }
	world:advance(3100)
	assert(world.savedTriage.items[1].source == nil, "an incomplete replay does not fabricate history")
	world.sourceRecords[path] = nativeCanvas.sourceFact("same-observation")
	world:emit("title", { pane = 10 }); world:advance(100)
	local replay = world.sourceProcesses[#world.sourceProcesses].input
	assert(replay.targets[1].previousRevision == nil and world.savedTriage.items[1].source.complete == true,
		"a timed-out or incomplete observation is replayed, never promoted to unchanged merely by matching metadata")
	world:emit("title", { pane = 10 }); world:advance(100)
	local unchanged = world.sourceProcesses[#world.sourceProcesses].input
	assert(unchanged.targets[1].previousRevision == "same-observation"
		and world.savedTriage.items[1].source.complete == true,
		"only a usable completed projection grants metadata-only reuse without discarding known facts")
end

do
	local world = native(true)
	local path = "/sessions/cutoff-metadata.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = { status = "partial", sessionId = "header-uuid", schemaVersion = 3,
		writerVersions = { "18.14.0" }, revision = "cutoff-observation", selection = "unknown",
		complete = false, reusable = false,
		questionCoverage = { status = "unknown", knownTotal = 0, included = 0, omitted = 0 },
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } } }
	world:advance(3100)
	assert(world:inspect().attentionCount == 0 and world.savedTriage.items[1].source == nil,
		"metadata-only cutoff cannot invent current history or attention")
	world.sourceRecords[path] = nativeCanvas.sourceFact("usable-replay")
	world:emit("title", { pane = 10 }); world:advance(100)
	local replay = world.sourceProcesses[#world.sourceProcesses].input
	assert(replay.targets[1].previousRevision == nil and world.savedTriage.items[1].source.complete == true,
		"metadata-only partial remains replayable and progresses to useful facts without unchanged-cache poisoning")
end

do
	local world = native(true)
	local path = "/sessions/header-only-navigation.jsonl"
	world.identityFiles[10] = path
	world.sourceRecords[path] = { status = "partial", sessionId = "header-A", schemaVersion = 3,
		writerVersions = {}, revision = "metadata-A", selection = "unknown", complete = false, reusable = false,
		questionCoverage = { status = "unknown", knownTotal = 0, included = 0, omitted = 0 },
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } } }
	world:advance(3100)
	local rail = world.opens[1].pane
	assert(world.savedTriage.items[1].sourceSessionId == "header-A" and world.savedTriage.items[1].source == nil,
		"positive header identity is available for navigation even when no source history is applicable")
	world.holdIdentity = true
	world:click(rail, rowAction(shown(world, rail)))
	local request = #world.processes
	world.sourceRecords[path].sessionId, world.sourceRecords[path].revision = "header-B", "metadata-B"
	world:emit("title", { pane = 10 }); world:advance(100)
	world:completeIdentity(request); world:advance(100)
	assert(world.focusWrites == 0 and not world:inspect().navigationPending and #world.processes > request,
		"fresh header mismatch cancels the captured navigation and requires a new identity proof before canonical replay")
	world.holdIdentity = false
	world:completeIdentity(#world.processes); world:advance(100)
	local replacement = nil
	for _, item in ipairs(world.savedTriage.items) do
		if item.sourceSessionId == "header-B" then replacement = item; break end
	end
	assert(replacement and world.focusWrites == 0 and not world:inspect().navigationPending,
		"fresh canonical header replacement rejects navigation captured from metadata-only old work without acknowledging it")
end

do
	local world = native(true)
	local path = "/sessions/fresh-open-header.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("stable-source")
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail = world.opens[1].pane
	local bodies, headers, captured = world:helperCount("source"), world:helperCount("header"), world.savedTriage.items[1].source.capturedAtUtc
	world:click(rail, rowAction(shown(world, rail))); world:advance(100)
	assert(world.focusWrites == 1 and world:inspect().attentionCount == 0
		and world:helperCount("source") == bodies and world:helperCount("header") >= headers + 2
		and world.savedTriage.items[1].source.capturedAtUtc == captured
		and world.savedTriage.items[1].source.lastHuman.atUtc == 1700000000,
		"verified Open separately proves the live header before navigation and acknowledgment without replaying history or resetting body/event clocks")
end

for _, action in ipairs({ "open", "priority" }) do
	local world = native(true)
	local path = "/sessions/silent-header-rewrite.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("same-stat-observation")
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail = world.opens[1].pane
	if action == "priority" then
		world:click(rail, rowAction(shown(world, rail), "menu")); world:choose(1)
	end
	local replacement = nativeCanvas.sourceFact("same-stat-observation")
	replacement.sessionId = "rewritten-header"
	world.sourceRecords[path] = replacement
	if action == "open" then world:click(rail, rowAction(shown(world, rail)))
	else world:choose(4) end
	world:advance(300)
	local found = false
	for _, record in ipairs(world.savedTriage.items) do
		assert(record.priority == nil, "a stale action cannot assign rank to a rewritten conversation")
		if record.sourceSessionId == "rewritten-header" then found = true end
	end
	assert(found and world.focusWrites == 0 and not world:inspect().navigationPending,
		"same-path header replacement cancels " .. action .. " and refreshes actual identity without retargeting")
end


do
	local world = native(true)
	local path = "/sessions/initial-header-strengthening.jsonl"
	world.identityFiles[10], world.sourceRecords[path], world.holdSources = path, nativeCanvas.sourceFact("first-body"), true
	world:advance(3100)
	local rail, serial = world.opens[1].pane, world.savedTriage.items[1].serial
	world:click(rail, rowAction(shown(world, rail), "menu"))
	world:completeSource(#world.sourceProcesses); world:advance(100)
	world.holdSources = false
	world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(world.savedTriage.items[1].serial == serial and world.savedTriage.items[1].sourceSessionId == "header-uuid"
		and world.savedTriage.items[1].disposition == "finished" and world.agentState == "waiting_input",
		"initial unknown header strengthens only the same captured work/binding/review, then fresh proof permits the explicit action")
end

do
	local world = native(true)
	local path = "/sessions/helper-owner-epoch.jsonl"
	world.identityFiles[10], world.sourceRecords[path], world.holdSources = path, nativeCanvas.sourceFact("owned-slot"), true
	world:advance(3100)
	local first, count = #world.sourceProcesses, #world.sourceProcesses
	world:command("disable"); world:command("enable"); world:advance(100)
	assert(#world.sourceProcesses == count,
		"owner epoch change cannot overlap an already-running finite helper merely by discarding its logical result")
	world.holdSources = false
	world:completeSource(first); world:advance(100)
	assert(#world.sourceProcesses > count and world.savedTriage.items[1].source.sessionId == "header-uuid",
		"old epoch result only releases its exact slot; the new owner then acquires fresh source proof")
end


do
	local world = native(true)
	local path = "/sessions/header-retry-without-history.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("original-body")
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail, captured = world.opens[1].pane, world.savedTriage.items[1].source.capturedAtUtc
	world.holdSources = true
	world:reload(); world:advance(100)
	local heldBody = #world.sourceProcesses
	local open = rowAction(shown(world, rail))
	assert(open, "an exact live local pane offers a header-verification attempt while current-owner history is unavailable")
	world:click(rail, open); world:advance(100)
	local heldHeader = #world.sourceProcesses
	assert(heldHeader > heldBody and world.sourceProcesses[heldHeader].input.op == "header"
		and not world.sourceProcesses[heldBody].completed,
		"fresh navigation proof starts independently of the held current-owner history projection")
	world.sourceRecords[path] = { status = "partial", sessionId = "header-uuid", schemaVersion = 3,
		writerVersions = {}, revision = "header-only-current", selection = "unknown", complete = false, reusable = false,
		questionCoverage = { status = "unknown", knownTotal = 0, included = 0, omitted = 0 },
		coverage = { recordsComplete = false, historyScope = "unavailable", fields = { clock = "unknown", questions = "unknown" } } }
	world.holdSources = false
	world:completeSource(heldBody); world:completeSource(heldHeader); world:advance(300)
	assert(world.focusWrites == 1 and not world:inspect().navigationPending
		and world.savedTriage.items[1].reviewRevision == nil
		and world.savedTriage.items[1].source.capturedAtUtc == captured
		and world:helperCount("header") > 0,
		"small fresh header proof enables exact navigation and captured acknowledgment without requiring a new history projection")
end

for _, choice in ipairs({ "Keep as reference", "Finished for now · current scope" }) do
	local world = native(true)
	local path = "/sessions/explicit-resume-only.jsonl"
	world.agentState, world.agentAlert, world.identityFiles[10] = "idle", true, path
	world.sourceRecords[path] = nativeCanvas.sourceFact("before-choice")
	world:advance(3100)
	local rail = world.opens[1].pane
	world:control(rail, "attention"); world:advance(100)
	world:click(rail, rowAction(shown(world, rail), "menu")); world:chooseLabel(choice); world:advance(100)
	local disposition = world.savedTriage.items[1].disposition
	world:advance(1100)
	local update = nativeCanvas.sourceFact("new-factual-input")
	update.lastHuman = { id = "new-human-input", text = "Implement the new feature now",
		atUtc = 1700000000 + math.floor(world.now / 1000), provenance = "user" }
	world.sourceRecords[path], world.agentState = update, "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(200)
	assert(world.savedTriage.items[1].disposition == disposition
		and world.savedTriage.items[1].source.lastHuman.id == "new-human-input"
		and world:inspect().attentionCount == 0,
		"new recorded text and native execution remain factual without automatically reactivating explicit tracking choices")
	world:control(rail, "working"); world:advance(100)
	world:click(rail, rowAction(shown(world, rail), "menu"))
	world:chooseLabel("Resume tracking · does not run agent"); world:advance(100)
	assert(world.savedTriage.items[1].disposition == "active" and world.agentState == "working" and world.focusWrites == 0,
		"only explicit Resume changes the tracking disposition, without executing or navigating the agent")
end

do
	local world = native(true)
	local path = "/sessions/header-with-unrelated-agent-event.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("captured-body")
	world:addTab(4, 11)
	world.additionalAgents = { [11] = "idle" }
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail, captured = world.opens[1].pane, world.savedTriage.items[1].source.capturedAtUtc
	world.holdHeaders = true
	world:click(rail, rowAction(shown(world, rail))); world:advance(100)
	local heldHeader, warnings = #world.sourceProcesses, #world.warnings
	assert(world.sourceProcesses[heldHeader].input.op == "header" and world:inspect().navigationPending and world.focusWrites == 0)
	world.additionalAgents[11] = "working"
	world:emit("agent_state", { pane = 11, old = "idle", new = "working" }); world:advance(100)
	assert(#world.warnings == warnings and world:inspect().navigationPending and world.focusWrites == 0,
		"an unrelated identity refresh cannot consume header-owned navigation or pause the panel")
	world.holdHeaders = false
	world:completeSource(heldHeader); world:advance(300)
	assert(world.focused == 10 and world.focusWrites == 1 and not world:inspect().navigationPending
		and world.savedTriage.items[1].reviewRevision == nil
		and world.savedTriage.items[1].source.capturedAtUtc == captured,
		"header proof survives unrelated native activity and acknowledges only its exact captured work")
end

do
	local world = native(true)
	world.agentState, world.agentAlert = "idle", true
	world:addTab(4, 11, 1, 7)
	world:addTab(5, 12, 1, 8)
	world.additionalAgents = { [11] = "working", [12] = "working" }
	world:advance(3100)
	local rail = world.opens[1].pane
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(100)
	local revision, serial = savedItemFor(world, 10).reviewRevision, savedItemFor(world, 10).serial
	world.additionalAgents[11] = "waiting_input"
	world:emit("agent_state", { pane = 11, old = "working", new = "waiting_input" }); world:advance(100)
	local rows = sectionRows(world, rail).c
	assert(#rows == 2 and rows[1].p.key == renderedRowFor(world, rail, 11).p.key
		and rows[2].p.key == "r" .. serial,
		"at equal priority a current native input blocker precedes an older passive completion")
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(100)
	rows = sectionRows(world, rail).c
	local state = world:inspect()
	assert(state.attentionCount == 1 and #rows == 1 and rows[1].p.key == renderedRowFor(world, rail, 11).p.key
		and savedItemFor(world, 10).reviewRevision == revision and savedItemFor(world, 10).reviewSuperseded == true,
		"resumed native-alert work disappears from Attention rows and counts without acknowledgment")
	assert(queueCount(world, rail, "attention") == "1", "toolbar count matches the eligible row list")
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == 11 and world.focusWrites == 1 and world:inspect().attentionCount == 1,
		"Next skips older resumed work and visits the current blocker without inventing an input acknowledgment")
	world:command("next"); world:advance(100)
	assert(world.focusWrites == 1, "Next never falls through to either ordinary working conversation")
	world:switch(3); world:advance(100)
	world:control(rail, "working"); world:advance(100)
	rows = sectionRows(world, rail).c
	assert(renderedRowFor(world, rail, 10) and renderedRowFor(world, rail, 12),
		"Working preserves both working conversations rather than dropping their recorded facts")
	local allOrder = {}
	for index, row in ipairs(rows) do allOrder[index] = row.p.key end
	local workingRow = renderedRowFor(world, rail, 10)
	local open, overflow = rowAction(workingRow, "route-open"), rowAction(workingRow, "menu")
	assert(open and overflow and not rowAction(workingRow, "details"),
		"working rows retain native Open and the menu; recorded facts open from the menu, not an inline chevron")
	world:expandRow(rail, workingRow); world:advance(100)
	local expanded = world:inspect().logical.expandedWorkId
	assert(expanded ~= nil and world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == revision,
		"disclosure inspects a superseded unread review without navigation or acknowledgment")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "menu"))
	assert(#world.pickers[#world.pickers].options.items > 0 and world.focusWrites == 1
		and savedItemFor(world, 10).reviewRevision == revision,
		"the same overflow operation opens native choices without acknowledging review")
	world:choose(nil)
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	local shared = sectionRows(world, second).c
	assert(world:inspect().logical.expandedWorkId == expanded and #shared == #allOrder,
		"physical canvases share one logical selection and disclosure")
	for index, row in ipairs(shared) do
		assert(row.p.key == allOrder[index], "All work retains native order across physical canvases")
	end
	world.agentState = "idle"
	world:emit("agent_state", { pane = 10, old = "working", new = "idle" }); world:advance(100)
	world:reload(); world:advance(1100)
	assert(world:inspect().attentionCount == 1 and savedItemFor(world, 10).reviewRevision == revision
		and savedItemFor(world, 10).reviewSuperseded == true,
		"restored supersession survives idle and reload without clearing or reviving the earlier unread revision")
	world:control(second, "attention"); world:advance(100)
	assert(#sectionRows(world, second).c == 1,
		"restored row membership agrees with persisted supersession")
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(100)
	assert(world:inspect().attentionCount == 2 and #sectionRows(world, second).c == 2
		and savedItemFor(world, 10).reviewRevision ~= revision,
		"a genuine new settled completion returns to the same Attention projection after restoration")
end

for _, blocker in ipairs({ "delivery", "startup" }) do
	local world = native(true)
	world.agentState = "idle"
	world:advance(3100)
	local rail = world.opens[1].pane
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local revision = savedItemFor(world, 10).reviewRevision
	world.agentState = "working"
	if blocker == "delivery" then world.deliveryError = "native prompt delivery failed"
	else world.startupError = "native agent startup failed" end
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(100)
	assert(world:inspect().attentionCount == 1 and #sectionRows(world, rail).c == 1
		and savedItemFor(world, 10).reviewRevision == revision and savedItemFor(world, 10).reviewSuperseded == true,
		"current native " .. blocker .. " blocker remains actionable while the older passive review is superseded")
	local summary = string.lower(visibleText(renderedRowFor(world, rail, 10)))
	assert(string.find(summary, if blocker == "delivery" then "prompt not delivered" else "agent didn't start", 1, true)
		and not string.find(summary, "working", 1, true),
		"the row's need names the " .. blocker .. " blocker rather than Working")
	world:expandRow(rail, shown(world, rail)); world:advance(100)
	assert(world.focusWrites == 0 and savedItemFor(world, 10).reviewRevision == revision,
		"inspecting a live " .. blocker .. " blocker does not navigate or acknowledge")
	world:click(rail, rowAction(shown(world, rail))); world:advance(100)
	assert(world.focused == 10 and world:inspect().attentionCount == 1
		and savedItemFor(world, 10).reviewRevision == nil,
		"exact Open acknowledges captured review but cannot resolve a native " .. blocker .. " condition")
	world.deliveryError, world.startupError = nil, nil
	-- A delivery error clearing has no native event; the next heartbeat after the 5 s agent census refresh picks it up.
	world:emit("title", { pane = 10 }); world:advance(6100)
	assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail)),
		"resolved " .. blocker .. " leaves ordinary working absent from Attention")
end

do
	local world = native(true)
	local path = "/sessions/historical-question-working.jsonl"
	local fact = nativeCanvas.sourceFact("unanswered-history")
	fact.questions = { { id = "past-request", status = "open", prompt = "Which target should I use?" } }
	fact.questionCoverage = { status = "complete", knownTotal = 1, included = 1, omitted = 0 }
	world.identityFiles[10], world.sourceRecords[path], world.agentState = path, fact, "idle"
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(100)
	local rail = world.opens[1].pane
	local revision = savedItemFor(world, 10).reviewRevision
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(100)
	assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail))
		and savedItemFor(world, 10).source.questions[1].status == "open"
		and savedItemFor(world, 10).reviewRevision == revision,
		"a historical unresolved question remains recorded but cannot override current native Working")
	world:control(rail, "working"); world:advance(100)
	local row = renderedRowFor(world, rail, 10)
	assert(string.find(visibleText(row) .. " " .. tooltipText(row), "Working", 1, true)
		and not string.find(visibleText(row), "Which target should I use?", 1, true),
		"the Working row presents the effective current state instead of the historical question")
	world:expandRow(rail, row); world:advance(100)
	assert(savedItemFor(world, 10).source.questions[1].status == "open"
		and savedItemFor(world, 10).reviewRevision == revision and world.focusWrites == 0,
		"disclosure preserves unresolved source facts and the unread revision without answering or navigating")
end

for _, initialAlert in ipairs({ false, true }) do
	local world = native(true)
	world.agentState, world.agentAlert = "working", initialAlert
	world:advance(3100)
	local rail = world.opens[1].pane
	assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail))
		and queueCount(world, rail, "attention") == "0" and not beacon(world, rail),
		"an initial ordinary working snapshot is not Attention, even with native alert already set")
	world.agentAlert = true
	world:emit("title", { pane = 10 }); world:advance(100)
	assert(world:inspect().attentionCount == 0 and not rowAction(shown(world, rail))
		and queueCount(world, rail, "attention") == "0" and not beacon(world, rail),
		"a native alert cannot independently promote ordinary working into rows, counts or arrival cues")
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focusWrites == 0, "Next excludes ordinary working regardless of initial or newly observed native alert")
	world:control(rail, "working"); world:advance(100)
	local workspaceRow = renderedRowFor(world, rail, 10)
	assert(string.find(visibleText(workspaceRow) .. " " .. tooltipText(workspaceRow), "Working", 1, true),
		"the excluded working conversation remains inspectable in Working")
end

local function holdCancelledNavigationHeader(world, rail)
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local held = #world.sourceProcesses
	local request = world.sourceProcesses[held]
	assert(request.interactive and request.input.op == "header" and not request.completed,
		"queued navigation fixture starts with a real held interactive header")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "cancel-navigation")); world:advance(100)
	assert(not world:inspect().navigationPending and not request.completed and world.focusWrites == 0,
		"logical cancellation leaves the finite interactive child owning its lane")
	return held
end

for _, action in ipairs({ "open", "next" }) do
	for _, stage in ipairs({ "identity", "header", "queued-header" }) do
		local world = native(true)
		local path = "/sessions/abandoned-" .. action .. "-" .. stage .. ".jsonl"
		world.agentState, world.identityFiles[10] = "idle", path
		world.sourceRecords[path] = nativeCanvas.sourceFact("abandoned-body")
		world:addTab(4, 11, 1, 7)
		world:addTab(5, 12, 1, 8)
		world.additionalAgents = { [11] = "idle", [12] = "idle" }
		world:advance(3100)
		world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
		world:emit("agent_finished", { pane = 12, result = "failed" }); world:advance(100)
		local rail, revision = world.opens[1].pane, savedItemFor(world, 10).reviewRevision
		world.holdIdentity, world.holdHeaders = stage == "identity", true
		local blocker = if stage == "queued-header" then holdCancelledNavigationHeader(world, rail) else nil
		world.focused = rail
		if action == "open" then world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
		else world:command("next") end
		world:advance(100)
		local heldIdentity, heldHeader = #world.processes, #world.sourceProcesses
		assert(not blocker or heldHeader == blocker,
			"the accepted request remains queued until the cancelled interactive child releases its lane")
		assert(world:inspect().navigationPending and world.focusWrites == 0,
			action .. " awaits " .. stage .. " before its first focus write")
		world:switch(4)
		world.holdIdentity, world.holdHeaders = false, false
		if stage == "identity" then world:completeIdentity(heldIdentity)
		else world:completeSource(heldHeader) end
		world:advance(300)
		assert(world.focused == 11 and world.focusWrites == 0 and not world:inspect().navigationPending
			and savedItemFor(world, 10).reviewRevision == revision,
			"a deliberate newer focus abandons " .. action .. " at " .. stage .. " without acknowledgment")
		world:command("next"); world:advance(300)
		assert(world.focused == 10 and world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == nil
			and savedItemFor(world, 12).reviewRevision ~= nil,
			"abandoned navigation consumes neither A's review nor its place before C in the round")
	end
end

do
	local world = native(true)
	local path = "/sessions/own-focus-event.jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("own-focus")
	world:addTab(4, 11)
	world.additionalAgents = { [11] = "idle" }
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	world:switch(4); world:advance(100)
	world.holdHeaders = true
	world:command("next"); world:advance(100)
	world:completeSource(#world.sourceProcesses)
	assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending)
	world:emit("focus", { pane = 10 }); world:advance(100)
	world.holdHeaders = false
	world:completeSource(#world.sourceProcesses); world:advance(100)
	assert(not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == nil,
		"the controller's own post-focus event preserves exact pending-visit confirmation")
end

for _, stage in ipairs({ "identity", "header" }) do
	local world = native(true)
	local path = "/sessions/sampled-focus-" .. stage .. ".jsonl"
	world.agentState, world.identityFiles[10] = "idle", path
	world.sourceRecords[path] = nativeCanvas.sourceFact("sampled-focus")
	world:addTab(4, 11)
	world.additionalAgents = { [11] = "idle" }
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail, revision = world.opens[1].pane, savedItemFor(world, 10).reviewRevision
	world.holdIdentity, world.holdHeaders = stage == "identity", true
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local held = if stage == "identity" then #world.processes else #world.sourceProcesses
	world.focused = 11
	world.holdIdentity, world.holdHeaders = false, false
	if stage == "identity" then world:completeIdentity(held) else world:completeSource(held) end
	world:advance(100)
	assert(world.focused == 11 and world.focusWrites == 0 and not world:inspect().navigationPending
		and savedItemFor(world, 10).reviewRevision == revision,
		"fresh native focus also abandons stale " .. stage .. " navigation if its event has not arrived")
end

do
	local world = native(true)
	world.agentState = "idle"
	for pane = 10, 15 do
		if pane ~= 10 then world:addTab(pane - 7, pane) end
		local path = "/sessions/priority-" .. pane .. ".jsonl"
		world.identityFiles[pane], world.sourceRecords[path] = path, nativeCanvas.sourceFact("body-" .. pane)
		world.sourceRecords[path].sessionId = "header-" .. pane
	end
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	local rail, before = world.opens[1].pane, #world.sourceProcesses
	world.holdSources = true
	for pane = 10, 15 do world:emit("title", { pane = pane }) end
	world:advance(100)
	local heldBody = #world.sourceProcesses
	local request = world.sourceProcesses[heldBody]
	assert(heldBody == before + 1 and #request.input.targets == 1 and request.timeout >= 6000 and request.timeout <= 8000,
		"background source replay occupies one target and one six-second budget plus bounded process overhead")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	assert(#world.sourceProcesses > heldBody and not request.completed and world.focusWrites == 0,
		"interactive header starts independently while the ordinary body retains its finite lane")
	local header = #world.sourceProcesses
	assert(world.sourceProcesses[header].input.op == "header")
	world:completeSource(header); world:advance(100)
	assert(world.focusWrites == 1 and not request.completed and world:inspect().navigationPending,
		"first fresh header focuses without waiting for body replay, but retains review until confirmation")
	world:completeSource(#world.sourceProcesses); world:advance(100)
	assert(not world:inspect().navigationPending and not request.completed)
	world.holdSources = false
	world:completeSource(heldBody); world:advance(1000)
	local covered, replays = {}, 0
	for index = before + 1, #world.sourceProcesses do
		local input = world.sourceProcesses[index].input
		if input.op == nil then
			assert(#input.targets == 1, "each background dispatch remains individually preemptible between targets")
			covered[input.targets[1].path] = true
			replays += 1
		end
	end
	local count = 0
	for _ in pairs(covered) do count += 1 end
	assert(count == 6 and replays == 6 and world.focusWrites == 1,
		"priority preserves every dirty target exactly once without replay loops or extra helper slots")
end

local function navigationWorld(targets)
	local world = native(true)
	world.agentState, world.additionalAgents = "idle", {}
	for pane = 10, 9 + targets do
		if pane ~= 10 then
			world:addTab(pane - 7, pane)
			world.additionalAgents[pane] = "idle"
		end
		local path = "/sessions/navigation-" .. pane .. ".jsonl"
		world.identityFiles[pane] = path
		world.sourceRecords[path] = nativeCanvas.sourceFact("navigation-body-" .. pane)
		world.sourceRecords[path].sessionId = "navigation-header-" .. pane
	end
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	return world, world.opens[1].pane
end

local function hasVisibleRole(node, role)
	if node.p and node.p.hidden then return false end
	if node.p and node.p.role == role then return true end
	for _, child in ipairs(node.c or {}) do
		if hasVisibleRole(child, role) then return true end
	end
	return false
end

do
	local world, rail = navigationWorld(3)
	world:emit("agent_finished", { pane = 12, result = "failed" }); world:advance(100)
	world.focused, world.holdHeaders = 11, true
	local first, last = savedItemFor(world, 10).reviewRevision, savedItemFor(world, 12).reviewRevision
	world:command("next"); world:advance(100)
	local held = #world.sourceProcesses
	assert(world.sourceProcesses[held].input.targets[1].path == world.identityFiles[10])
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "cancel-navigation")); world:advance(100)
	world:command("next"); world:advance(100)
	world:completeSource(held); world:advance(100)
	assert(world.focusWrites == 0 and world.sourceProcesses[#world.sourceProcesses].input.targets[1].path == world.identityFiles[10]
		and savedItemFor(world, 10).reviewRevision == first and savedItemFor(world, 12).reviewRevision == last,
		"cancelled Next consumes neither its cue nor its place before the next review")
	world.holdHeaders = false
	world:completeSource(#world.sourceProcesses); world:advance(300)
	assert(world.focused == 10 and savedItemFor(world, 10).reviewRevision == nil
		and savedItemFor(world, 12).reviewRevision == last)
end

for _, action in ipairs({ "open", "next" }) do
	for _, existingRound in ipairs({ false, true }) do
		local world = native(true)
		local path = "/sessions/new-review-during-confirmation.jsonl"
		world.agentState, world.identityFiles[10] = "idle", path
		world.sourceRecords[path] = nativeCanvas.sourceFact("captured-confirmation-body")
		world:addTab(4, 11); world:addTab(5, 12); world:addTab(6, 13)
		world.additionalAgents = { [11] = "idle", [12] = "idle", [13] = "idle" }
		world:advance(3100)
		world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
		world:emit("agent_finished", { pane = 12, result = "failed" }); world:advance(100)
		local rail = world.opens[1].pane
		if existingRound then
			world:emit("agent_finished", { pane = 13, result = "failed" }); world:advance(100)
			world:click(rail, rowAction(renderedRowFor(world, rail, 13))); world:advance(300)
			assert(savedItemFor(world, 13).reviewRevision == nil,
				"a separate completed Open establishes a round with A and C still unconsumed")
		end
		world:switch(4); world:advance(100)
		local captured, other = savedItemFor(world, 10).reviewRevision, savedItemFor(world, 12).reviewRevision
		local queueOrder, writes = savedItemFor(world, 10).queueOrder, world.focusWrites
		assert(captured ~= nil and other ~= nil and world:inspect().attentionCount == 2)
		world.holdHeaders = true
		if action == "open" then world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
		else world:command("next") end
		world:advance(100)
		local beforeFocus = #world.sourceProcesses
		assert(world.sourceProcesses[beforeFocus].input.op == "header" and world.focusWrites == writes)
		world:completeSource(beforeFocus); world:advance(100)
		local confirmation = #world.sourceProcesses
		assert(confirmation > beforeFocus and world.sourceProcesses[confirmation].input.op == "header"
			and not world.sourceProcesses[confirmation].completed and world.focused == 10
			and world.focusWrites == writes + 1 and world:inspect().navigationPending,
			"the review race starts only after proven focus and a distinct held confirmation header")
		local warnings = #world.warnings
		-- A newly discovered alert invalidates identity and dirties an in-flight header
		-- even without an explicit event; that stale proof must be rejected.
		world.agentAlert = true
		world:advance(1100)
		local newer = savedItemFor(world, 10).reviewRevision
		assert(newer ~= nil and newer ~= captured and savedItemFor(world, 10).queueOrder == queueOrder
			and world:inspect().navigationPending and not world.sourceProcesses[confirmation].completed,
			"a genuinely newer review arrives without replacing A's place or completing its held header")
		world:completeSource(confirmation); world:advance(100)
		assert(not world:inspect().navigationPending and world.focusWrites == writes + 1
			and #world.warnings > warnings
			and savedItemFor(world, 10).reviewRevision == newer and savedItemFor(world, 12).reviewRevision == other,
			"dirty " .. action .. " confirmation reports rejection and releases pending UI without acknowledging either cue")
		world:switch(4); world:advance(100)
		world.holdHeaders = false
		world:command("next"); world:advance(300)
		assert(world.focused == 10 and world.focusWrites == writes + 2
			and savedItemFor(world, 10).reviewRevision == nil and savedItemFor(world, 12).reviewRevision == other,
			"stale " .. action .. " consumes no turn in the " .. (if existingRound then "existing" else "new")
				.. " round: a fresh Next must still visit A before eligible C")
	end
end

for _, action in ipairs({ "open", "next" }) do
	local world, rail = navigationWorld(4)
	world:emit("agent_finished", { pane = 12, result = "failed" }); world:advance(100)
	world:emit("agent_finished", { pane = 11, result = "failed" }); world:advance(100)
	local captured = savedItemFor(world, 10).reviewRevision
	local second, third = savedItemFor(world, 12).reviewRevision, savedItemFor(world, 11).reviewRevision
	assert(captured and second and third and world:inspect().attentionCount == 3,
		"three cues distinguish preserving the round from skipping its previously focused or destination member")
	world.focused, world.holdHeaders = 12, true
	if action == "open" then world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
	else world:command("next") end
	world:advance(100)
	local preFocus = #world.sourceProcesses
	world:completeSource(preFocus)
	assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending,
		"the captured review has focused but cannot be acknowledged before confirmation")
	-- Deliver the new turn before the next pass dispatches confirmation. Its fresh
	-- identity/header must succeed, rather than ending on the dirty-header rejection path.
	local warnings = #world.warnings
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" })
	world.agentState = "idle"
	world:emit("agent_finished", { pane = 10, result = "failed" })
	world:advance(100)
	local current = savedItemFor(world, 10)
	local newer = current.reviewRevision
	assert(newer ~= nil and newer ~= captured and current.sourceSessionId == "navigation-header-10",
		"a new turn replaces the review of the same verified conversation before confirmation")
	local confirmation = #world.sourceProcesses
	assert(confirmation > preFocus and world.sourceProcesses[confirmation].input.op == "header"
		and not world.sourceProcesses[confirmation].completed,
		"confirmation obtains a distinct fresh held header after identity revalidation")
	world:completeSource(confirmation); world:advance(100)
	assert(not world:inspect().navigationPending and world.focusWrites == 1 and #world.warnings == warnings
		and savedItemFor(world, 10).reviewRevision == newer
		and savedItemFor(world, 12).reviewRevision == second and savedItemFor(world, 11).reviewRevision == third,
		"successful fresh confirmation retains a newer displayed revision without a proof-rejection escape")
	world.holdHeaders = false
	world:switch(6); world:advance(100)
	world:command("next"); world:advance(300)
	assert(world.focused == 10 and savedItemFor(world, 10).reviewRevision == nil
		and savedItemFor(world, 12).reviewRevision == second and savedItemFor(world, 11).reviewRevision == third,
		"the newer destination review remains first in the unchanged Next round")
	world:command("next"); world:advance(300)
	assert(world.focused == 12 and savedItemFor(world, 12).reviewRevision == nil
		and savedItemFor(world, 11).reviewRevision == third,
		"the unacknowledged visit also preserves the previously focused cue speculative Next would have skipped")
end

do
	local world, rail = navigationWorld(2)
	world.focused, world.holdIdentity, world.holdHeaders = 11, true, true
	world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
	local held = #world.processes
	world:emit("agent_finished", { pane = 11, result = "failed" })
	world:completeIdentity(held); world:advance(100)
	local deferred = savedItemFor(world, 11)
	assert(#world.processes > held and deferred.reviewRevision == nil
		and deferred.deferredPane == 11 and deferred.deferredResult == "failed" and world.focusWrites == 0,
		"the dirty first response retains the unrelated event without publishing it as identity-proven review")
	world:completeIdentity(#world.processes); world:advance(100)
	local unrelated = savedItemFor(world, 11).reviewRevision
	assert(unrelated ~= nil and savedItemFor(world, 11).deferredResult == nil and world.focusWrites == 0,
		"fresh follow-up identity proof applies the retained unrelated event exactly once")
	world:advance(100)
	assert(savedItemFor(world, 11).reviewRevision == unrelated,
		"subsequent reconciliation does not replay the consumed event batch")
	local captured = savedItemFor(world, 10).reviewRevision
	local preFocus = #world.sourceProcesses
	assert(world.sourceProcesses[preFocus].input.op == "header" and not world.sourceProcesses[preFocus].completed,
		"the independent destination still waits for its own fresh pre-focus header")
	world:completeSource(preFocus); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending
		and savedItemFor(world, 10).reviewRevision == captured and savedItemFor(world, 11).reviewRevision == unrelated,
		"pre-focus proof shows the destination but acknowledges neither review before confirmation")
	local confirmation = #world.sourceProcesses
	assert(confirmation > preFocus and world.sourceProcesses[confirmation].input.op == "header"
		and not world.sourceProcesses[confirmation].completed,
		"the destination confirmation owns a distinct fresh header")
	world.holdIdentity, world.holdHeaders = false, false
	world:completeSource(confirmation); world:advance(300)
	assert(world.focused == 10 and savedItemFor(world, 10).reviewRevision == nil
		and savedItemFor(world, 11).reviewRevision == unrelated,
		"coherent identity acceptance still acknowledges only the independently verified destination")
end

for _, afterFocus in ipairs({ false, true }) do
	local world, rail = navigationWorld(2)
	world.focused, world.holdHeaders, world.holdSources = 11, true, true
	local captured = copy(savedItemFor(world, 10))
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	if afterFocus then world:completeSource(#world.sourceProcesses); world:advance(100) end
	local path = world.identityFiles[10]
	world.sourceRecords[path].sessionId = "silent-replacement"
	world:completeSource(#world.sourceProcesses); world:advance(100)
	local retained = nil
	for _, item in ipairs(world.savedTriage.items) do
		if item.serial == captured.serial then retained = item end
	end
	assert(world.focusWrites == (if afterFocus then 1 else 0) and not world:inspect().navigationPending,
		"a silent same-path rewrite is rejected by the fresh " .. (if afterFocus then "confirmation" else "pre-focus") .. " header")
	assert(retained and retained.reviewRevision == captured.reviewRevision,
		"header replacement never acknowledges the captured old conversation review")
end

for _, changeOwner in ipairs({ false, true }) do
	local world, rail = navigationWorld(2)
	world.focused, world.holdHeaders = 11, true
	local captured = savedItemFor(world, 10).reviewRevision
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local held = #world.sourceProcesses
	if changeOwner then world.prefs.owner = "another-window"; world:advance(1100)
	else world:command("disable") end
	assert(not world.sourceProcesses[held].completed and world.focusWrites == 0,
		"owner invalidation fences intent without pretending its native header child terminated")
	world:completeSource(held); world:advance(100)
	assert(world.focusWrites == 0 and savedItemFor(world, 10).reviewRevision == captured
		and not world:inspect().navigationPending, "late old-owner verification cannot revive navigation or acknowledgment")
	world.holdHeaders = false
	world:command("enable"); world:advance(200)
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(300)
	assert(world.focused == 10 and savedItemFor(world, 10).reviewRevision == nil,
		"the new owner requires and completes a fresh navigation rather than inheriting old proof")
end

do
	local world, rail = navigationWorld(2)
	world.focused, world.holdHeaders, world.holdIdentity = 11, true, true
	local captured, accepted = savedItemFor(world, 10).reviewRevision, world.now
	world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
	local first = #world.processes
	world:emit("agent_state", { pane = 10, old = "idle", new = "idle" })
	world:advance(2900)
	world:completeIdentity(first); world:advance(100)
	assert(#world.processes > first and world.focusWrites == 0, "a signalled target requires its fresh follow-up identity")
	world:advance(2900)
	world:completeIdentity(#world.processes); world:advance(100)
	local preFocus = #world.sourceProcesses
	assert(world.sourceProcesses[preFocus].input.op == "header" and world.focusWrites == 0)
	world:advance(2900)
	world:completeSource(preFocus); world:advance(100)
	assert(world.focused == 10 and world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == captured)
	local acknowledgment = #world.sourceProcesses
	assert(acknowledgment > preFocus and world.sourceProcesses[acknowledgment].at + 3000 > accepted + 10000,
		"confirmation's individual helper budget extends past the original accepted-click deadline")
	world:advance(accepted + 10001 - world.now)
	assert(not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == captured,
		"the 10-second click deadline covers identity retries and confirmation without resetting at dispatch")
	world:completeSource(acknowledgment); world:advance(100)
	assert(world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == captured,
		"late confirmation cannot acknowledge the expired click")
end

do
	local world, rail = navigationWorld(2)
	world.focused, world.holdHeaders = 11, true
	local captured = savedItemFor(world, 10).reviewRevision
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local old = #world.sourceProcesses
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "cancel-navigation")); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	assert(#world.sourceProcesses == old and world:inspect().navigationPending,
		"replacement waits behind the cancelled but still-running interactive child")
	-- Host pause: timers have not been delivered; a completion must still reject expired queued work.
	world.now += 10001
	world:completeSource(old)
	assert(not world:inspect().navigationPending and world.focusWrites == 0
		and savedItemFor(world, 10).reviewRevision == captured,
		"late host delivery expires the click including its lane wait before launching or focusing")
end

-- Interactive navigation must not inherit the residual lifetime of unrelated ordinary work.
do
	local world, rail = navigationWorld(2)
	world.focused = 11
	world.holdSources, world.holdHeaders = true, true
	world:emit("title", { pane = 11 }); world:advance(100)
	local held = #world.sourceProcesses
	assert((world.sourceProcesses[held].input.op or "source") == "source")
	local captured = savedItemFor(world, 10).reviewRevision
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local header = #world.sourceProcesses
	assert(header > held and world.sourceProcesses[header].input.op == "header"
		and not world.sourceProcesses[held].completed and world.focusWrites == 0,
		"fresh pre-focus proof starts while unrelated source work still owns its lane")
	world:completeSource(header); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == captured)
	local confirmation = #world.sourceProcesses
	assert(confirmation > header and world.sourceProcesses[confirmation].input.op == "header")
	world:completeSource(confirmation); world:advance(100)
	assert(not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == nil
		and not world.sourceProcesses[held].completed,
		"two fresh headers finish the exact review without waiting for ordinary work")
end

for _, recovery in ipairs({ "deadline", "paused", "resumed" }) do
	local world, rail = navigationWorld(2)
	world:switch(4); world:advance(3100)
	rail = world.prefs.instances["local"]["4"].pane
	assert(world.focused == 11 and world.membership[rail] == 4
		and rowAction(renderedRowFor(world, rail, 10)),
		"recovery starts from the visible rail beside pane11 with pane10 as a distinct destination")
	world.holdHeaders = true
	local captured = savedItemFor(world, 10).reviewRevision
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local held = #world.sourceProcesses
	world.abortInventory = true
	local thread = coroutine.create(function() world:completeSource(held) end)
	local ok, marker = coroutine.resume(thread)
	assert(ok and marker == "native hard budget")
	assert(coroutine.close(thread), "dispose the header continuation at its native inventory seam")
	if recovery ~= "deadline" then
		world:budget(recovery)
		assert(not world:inspect().navigationPending and world.focusWrites == 0
			and savedItemFor(world, 10).reviewRevision == captured,
			"a budget notification immediately abandons the interrupted intent without acknowledgment")
	end
	world:advance(if recovery == "deadline" then 10100 else 100)
	assert(not world:inspect().navigationPending and world.focused == 11 and world.focusWrites == 0
		and savedItemFor(world, 10).reviewRevision == captured,
		"lost continuation is recoverable via " .. recovery .. " without consuming its review")
	if recovery == "paused" then
		local headers = world:helperCount("header")
		world:advance(5000)
		world:budget("resumed"); world:advance(100)
		assert(world:helperCount("header") == headers and world.focusWrites == 0
			and not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == captured,
			"the full host pause and resumed expiry service never revive or overlap the abandoned header")
	else
		world:advance(4200)
	end
	world.holdHeaders = false
	local retry = rowAction(renderedRowFor(world, rail, 10))
	assert(retry and world.focused == 11 and world.focusWrites == 0,
		"the visible rail restores a fresh same-target Open after recovery without needing background catch-up")
	world:click(rail, retry); world:advance(300)
	assert(world.focused == 10 and world.focusWrites == 1 and not world:inspect().navigationPending
		and savedItemFor(world, 10).reviewRevision == nil,
		"same-row fresh retry completes after " .. recovery .. " recovery")
end

for _, afterFocus in ipairs({ false, true }) do
	local world, rail = navigationWorld(2)
	world.focused, world.holdHeaders = 11, true
	local captured = savedItemFor(world, 10).reviewRevision
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	if afterFocus then world:completeSource(#world.sourceProcesses); world:advance(100) end
	local held, writes = #world.sourceProcesses, world.focusWrites
	local cancel = rowAction(renderedRowFor(world, rail, 10), "cancel-navigation")
	assert(cancel, "the pending exact row exposes Cancel")
	world:click(rail, cancel); world:advance(100)
	assert(not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == captured
		and not world.sourceProcesses[held].completed, "Cancel abandons intent, not a running native helper")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	world:click(rail, cancel); world:advance(100)
	assert(world:inspect().navigationPending, "stale cancel token cannot cancel a fresh accepted navigation")
	world:completeSource(held); world:advance(100)
	assert(world.focusWrites == writes and savedItemFor(world, 10).reviewRevision == captured,
		"cancelled completion never focuses or acknowledges")
	world.holdHeaders = false
	world:completeSource(#world.sourceProcesses); world:advance(300)
	assert(world.focused == 10 and world.focusWrites == writes + 1
		and savedItemFor(world, 10).reviewRevision == nil and not world:inspect().navigationPending)
end

for _, action in ipairs({ "open", "toolbar-next", "next" }) do
	for _, boundary in ipairs({ "identity", "header" }) do
		local world = native(true)
		local path = "/sessions/unrelated-arrival-a.jsonl"
		world.agentState, world.identityFiles[10] = "idle", path
		world.sourceRecords[path] = nativeCanvas.sourceFact("stable-navigation-a")
		world:addTab(4, 11)
		world.additionalAgents = { [11] = "working" }
		world:advance(3100)
		world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(100)
		local rail = world.opens[1].pane
		assert(savedItemFor(world, 11).source == nil and savedItemFor(world, 11).reviewRevision == nil
			and world:inspect().attentionCount == 1,
			"unrelated B begins as native-only working work, not an old qualified source completion")
		local captured = savedItemFor(world, 10).reviewRevision
		assert(captured ~= nil, "stable A has an independent source-backed review before navigation")
		world.holdIdentity, world.holdHeaders = boundary == "identity", true
		world.focused = rail
		if action == "open" then world:click(rail, rowAction(renderedRowFor(world, rail, 10)))
		elseif action == "toolbar-next" then world:control(rail, "next")
		else world:command("next") end
		world:advance(100)
		local held = if boundary == "identity" then #world.processes else #world.sourceProcesses
		assert(world:inspect().navigationPending and world.focusWrites == 0,
			action .. " must reach its held " .. boundary .. " proof before the unrelated completion")
		world.additionalAgents[11] = "idle"
		world:emit("agent_finished", { pane = 11, result = "done" }); world:advance(100)
		local unrelated = savedItemFor(world, 11).reviewRevision
		assert(unrelated ~= nil and world:inspect().attentionCount == 2,
			"the unrelated B completion must add real Attention while stable A is accepted")
		if boundary == "identity" then
			world.holdIdentity = false
			world:completeIdentity(held); world:advance(100)
			local current = world.processes[#world.processes]
			if current ~= world.processes[held] then world:completeIdentity(#world.processes); world:advance(100) end
		else
			world:completeSource(held); world:advance(100)
		end
		if boundary == "identity" then world:completeSource(#world.sourceProcesses); world:advance(100) end
		assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending
			and savedItemFor(world, 10).reviewRevision == captured,
			action .. " survives unrelated derived selection at " .. boundary .. " but cannot acknowledge before fresh destination proof")
		local ack = world.sourceProcesses[#world.sourceProcesses]
		assert(ack.input.op == "header" and not ack.completed,
			"the focused visit must own a fresh held acknowledgment header")
		world:completeSource(#world.sourceProcesses); world:advance(100)
		assert(world.focusWrites == 1 and not world:inspect().navigationPending
			and savedItemFor(world, 10).reviewRevision == nil
			and savedItemFor(world, 11).reviewRevision == unrelated and world:inspect().attentionCount == 1,
			action .. " acknowledges captured A only and leaves unrelated B new at " .. boundary)
	end
end

for _, selection in ipairs({ "queue", "settings", "disclosure" }) do
	for _, boundary in ipairs({ "identity", "header" }) do
		local world, rail = navigationWorld(2)
		local captured = savedItemFor(world, 10).reviewRevision
		world.holdIdentity, world.holdHeaders = boundary == "identity", true
		world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
		local held = if boundary == "identity" then #world.processes else #world.sourceProcesses
		if selection == "queue" then
			world:toggleQueue(rail, "attention"); world:advance(100)
			world:toggleQueue(rail, "attention"); world:advance(100)
		elseif selection == "settings" then
			world:control(rail, "settings"); world:advance(100)
			world:control(rail, "settings"); world:advance(100)
		else
			world:expandRow(rail, renderedRowFor(world, rail, 10)); world:advance(100)
			world:click(rail, rowAction(renderedRowFor(world, rail, 10), "details")); world:advance(100)
		end
		world.holdIdentity, world.holdHeaders = false, false
		if boundary == "identity" then world:completeIdentity(held) else world:completeSource(held) end
		world:advance(300)
		assert(world.focusWrites == 0 and not world:inspect().navigationPending
			and savedItemFor(world, 10).reviewRevision == captured,
			"explicit " .. selection .. " away-and-back invalidates the old " .. boundary .. " intent even when its visible selection returns")
		assert(rowAction(renderedRowFor(world, rail, 10)),
			"cancelling selection-bound navigation restores the target's current Open action")
	end
end

do
	local world, rail = navigationWorld(2)
	world.holdHeaders = true
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	local held = #world.sourceProcesses
	world:control(rail, "attention"); world:advance(100)
	world.holdHeaders = false
	world:completeSource(held); world:advance(300)
	assert(world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == nil,
		"clicking the already-selected section is a no-op, not an explicit away-and-back cancellation")
end

for _, stage in ipairs({ "identity", "header", "queued-header" }) do
	local world, rail = navigationWorld(2)
	world:emit("agent_finished", { pane = 11, result = "done" }); world:advance(100)
	local captured = savedItemFor(world, 10).reviewRevision
	assert(captured ~= nil and savedItemFor(world, 11).reviewRevision ~= nil
		and world:inspect().attentionCount == 2,
		"repeat-click fixtures retain two genuine settled reviews without an intervening working episode")
	world.holdIdentity, world.holdHeaders = stage == "identity", true
	local blocker = if stage == "queued-header" then holdCancelledNavigationHeader(world, rail) else nil
	local original = rowAction(renderedRowFor(world, rail, 10))
	local warnings, toasts = #world.warnings, #world.toasts
	world:click(rail, original); world:advance(100)
	local heldIdentity, heldHeader = #world.processes, #world.sourceProcesses
	for _ = 1, 4 do world:click(rail, original); world:advance(32) end
	assert(#world.processes == heldIdentity and #world.sourceProcesses == heldHeader
		and (not blocker or heldHeader == blocker),
		"repeats neither restart identity nor dispatch an extra header while the accepted request waits")
	assert(world.focusWrites == 0 and world:inspect().navigationPending,
		"repeated " .. stage .. " Open preserves one accepted destination before proof")
	local pendingRow = renderedRowFor(world, rail, 10)
	assert(hasVisibleRole(pendingRow, "attention.navigation-pending") and not rowAction(pendingRow),
		"accepted " .. stage .. " row visibly awaits proof without an enabled second Open")
	assert(rowAction(pendingRow, "menu") and not rowAction(pendingRow, "details"),
		"pending navigation leaves the accepted row's menu available and collapsed rows have no inline disclosure")
	assert(rowAction(renderedRowFor(world, rail, 11))
		and not hasVisibleRole(renderedRowFor(world, rail, 11), "attention.navigation-pending"),
		"pending paint never disables another row's Open or marks unrelated work as opening")
	world:closeSession(rail); world:advance(100)
	-- Collapsing a Workspace session deliberately cancelled that attempt; retry from a current token.
	world.holdIdentity, world.holdHeaders = false, false
	if stage == "identity" then world:completeIdentity(heldIdentity)
	else world:completeSource(heldHeader) end
	world:advance(300)
	assert(not world:inspect().navigationPending and not hasVisibleRole(renderedRowFor(world, rail, 10), "attention.navigation-pending")
		and savedItemFor(world, 10).reviewRevision == captured,
		"explicit cancellation clears pending presentation without acknowledging")
	world:control(rail, "attention"); world:advance(100)
	world.holdIdentity, world.holdHeaders = stage == "identity", true
	blocker = if stage == "queued-header" then holdCancelledNavigationHeader(world, rail) else nil
	original = rowAction(renderedRowFor(world, rail, 10))
	warnings, toasts = #world.warnings, #world.toasts
	world:click(rail, original); world:advance(100)
	heldIdentity, heldHeader = #world.processes, #world.sourceProcesses
	for _ = 1, 4 do world:click(rail, original); world:advance(32) end
	assert(#world.processes == heldIdentity and #world.sourceProcesses == heldHeader
		and (not blocker or heldHeader == blocker),
		"fresh retry repeats retain one identity attempt and one accepted queued or running header")
	assert(#world.warnings == warnings and #world.toasts == toasts,
		"old-token repeats coalesce silently during " .. stage .. ", rather than becoming stale-action errors")
	if stage == "identity" then
		world.holdIdentity = false
		world:completeIdentity(heldIdentity); world:advance(100)
	elseif stage == "queued-header" then
		world:completeSource(blocker); world:advance(100)
	end
	local proof = world.sourceProcesses[#world.sourceProcesses]
	assert(proof.input.op == "header" and not proof.completed,
		"one live pre-focus header owns the coalesced " .. stage .. " Open")
	world:completeSource(#world.sourceProcesses); world:advance(100)
	assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending
		and savedItemFor(world, 10).reviewRevision == captured,
		"first exact header opens the coalesced " .. stage .. " destination without draining obsolete copies or clearing review")
	assert(hasVisibleRole(renderedRowFor(world, rail, 10), "attention.navigation-pending")
		and not rowAction(renderedRowFor(world, rail, 10)),
		"post-focus confirmation stays visibly pending with Open unavailable")
	local ack = world.sourceProcesses[#world.sourceProcesses]
	assert(ack ~= proof and ack.input.op == "header" and not ack.completed,
		"post-focus acknowledgment requires its own fresh header, not the pre-focus result")
	world.holdHeaders, world.holdSources = false, false
	world:completeSource(#world.sourceProcesses); world:advance(300)
	world:control(rail, "attention"); world:advance(100)
	assert(world.focusWrites == 1 and not world:inspect().navigationPending
		and savedItemFor(world, 10).reviewRevision == nil
		and not hasVisibleRole(world.canvases[rail].view, "attention.navigation-pending"),
		"successful " .. stage .. " coalesced Open clears only its transient pending state")
	world:control(rail, "workspace"); world:advance(100)
	assert(wsPart(world, rail, "tab:local#3", "open"), "the tab is openable again after " .. stage .. " Open")
end

for _, failure in ipairs({ "identity", "header" }) do
	local world, rail = navigationWorld(2)
	local captured = savedItemFor(world, 10).reviewRevision
	world.holdIdentity, world.holdHeaders = failure == "identity", true
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	assert(hasVisibleRole(renderedRowFor(world, rail, 10), "attention.navigation-pending"),
		"the failure scenario begins with a visibly accepted " .. failure .. " action")
	local failed = { status = 1, stdout = "", stderr = "held proof unavailable", timed_out = false }
	local failedIdentity = world.processes[#world.processes]
	world.canvasPaints = {}
	if failure == "identity" then world:completeIdentity(#world.processes, failed)
	else world:completeSource(#world.sourceProcesses, failed) end
	world:advance(100)
	local errorPaint = nil
	for _, paint in ipairs(world.canvasPaints) do
		if paint.pane == rail and paint.notice and string.find(visibleText(paint.notice), "%S") then
			errorPaint = paint
			break
		end
	end
	assert(not world:inspect().navigationPending and errorPaint ~= nil
		and not hasVisibleRole(renderedRowFor(world, rail, 10), "attention.navigation-pending")
		and savedItemFor(world, 10).reviewRevision == captured and world.focusWrites == 0,
		"failed " .. failure .. " visibly reports the error, clears pending feedback, and never acknowledges")
	if failure == "identity" then
		assert(not rowAction(renderedRowFor(world, rail, 10)),
			"failed identity leaves the rejected route unavailable until fresh proof")
		world:advance(3000)
		assert(world.processes[#world.processes] ~= failedIdentity,
			"identity recovery waits for the existing backoff to admit a distinct fresh proof")
		assert(not rowAction(renderedRowFor(world, rail, 10))
			and not world:inspect().navigationPending
			and savedItemFor(world, 10).reviewRevision == captured and world.focusWrites == 0,
			"the held backoff retry cannot restore Open or replay navigation before fresh identity arrives")
		world:completeIdentity(#world.processes); world:advance(100)
		local recoveredCoverage = coverageOf(world.canvases[rail].view)
		assert(rowAction(renderedRowFor(world, rail, 10))
			and (recoveredCoverage.p.hidden or not nativeCanvas.childAt(recoveredCoverage, "notice"))
			and not world:inspect().navigationPending
			and not hasVisibleRole(renderedRowFor(world, rail, 10), "attention.navigation-pending")
			and savedItemFor(world, 10).reviewRevision == captured and world.focusWrites == 0,
			"fresh retry identity restores Open and clears its error without navigation or acknowledgment")
	else
		assert(rowAction(renderedRowFor(world, rail, 10)),
			"failed header proof retains the exact verified route for immediate explicit retry")
	end
end

for _, stage in ipairs({ "running-header", "queued-header" }) do
	local world, rail = navigationWorld(2)
	world:emit("agent_finished", { pane = 11, result = "done" }); world:advance(100)
	local first, second = savedItemFor(world, 10).reviewRevision, savedItemFor(world, 11).reviewRevision
	assert(first ~= nil and second ~= nil and world:inspect().attentionCount == 2,
		"supersession starts with distinct captured A and B reviews, not an empty acknowledgment oracle")
	world.holdHeaders = true
	local blocker = if stage == "queued-header" then holdCancelledNavigationHeader(world, rail) else nil
	local openA, openB = rowAction(renderedRowFor(world, rail, 10)), rowAction(renderedRowFor(world, rail, 11))
	world:click(rail, openA); world:advance(100)
	local held = #world.sourceProcesses
	world:click(rail, openB); world:advance(100)
	assert(#world.sourceProcesses == held and (not blocker or held == blocker),
		"supersession cannot overlap the running header or launch the obsolete queued A proof")
	local warnings, toasts = #world.warnings, #world.toasts
	assert(world.focusWrites == 0 and not world.sourceProcesses[held].completed,
		"supersession preserves ownership of the already-running finite " .. stage .. " helper")
	world:completeSource(held, { status = 1, stdout = "", stderr = "obsolete A proof failed", timed_out = false })
	world:advance(100)
	local live = world.sourceProcesses[#world.sourceProcesses]
	assert(live.input.op == "header" and live.input.targets[1].path == world.identityFiles[11],
		"superseded queued navigation proofs are skipped before the current B header dispatches")
	assert(#world.warnings == warnings and #world.toasts == toasts,
		"an obsolete A failure is not reported as the current B action's error")
	world:completeSource(#world.sourceProcesses); world:advance(100)
	assert(world.focused == 11 and world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == first
		and savedItemFor(world, 11).reviewRevision == second,
		"only the newest B destination focuses, while both captured reviews await acknowledgment")
	world.holdHeaders, world.holdSources = false, false
	world:completeSource(#world.sourceProcesses); world:advance(300)
	assert(world.focusWrites == 1 and savedItemFor(world, 10).reviewRevision == first
		and savedItemFor(world, 11).reviewRevision == nil and not world:inspect().navigationPending,
		"cross-target supersession acknowledges B only after its exact fresh destination header")
end

do
	local world, rail = navigationWorld(3)
	world:emit("agent_finished", { pane = 11, result = "failed" }); world:emit("agent_finished", { pane = 12, result = "failed" })
	world:advance(100)
	world.holdSources, world.holdHeaders = true, true
	world:emit("title", { pane = 12 }); world:advance(100)
	local heldBody = #world.sourceProcesses
	assert(world.sourceProcesses[heldBody].input.op == nil and not world.sourceProcesses[heldBody].completed,
		"independent menu work queues behind a real held source body")
	world:click(rail, rowAction(renderedRowFor(world, rail, 12), "menu"))
	world:chooseLabel("Finished for now · current scope")
	world:advance(100)
	assert(savedItemFor(world, 12).disposition == "active",
		"the independent menu mutation cannot finish before its queued helper proof")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 11))); world:advance(100)
	assert(not world.sourceProcesses[heldBody].completed,
		"navigation pruning cannot terminate the existing body which owns the helper slot")
	world:completeSource(heldBody); world:advance(100)
	local index = heldBody + 1
	for _ = 1, 12 do
		local request = world.sourceProcesses[index]
		if not request then break end
		world:completeSource(index); world:advance(100)
		index += 1
	end
	assert(world.focused == 11 and world.focusWrites == 1 and not world:inspect().navigationPending,
		"independent menu work and the newest B navigation both finish after pruning A")
	assert(savedItemFor(world, 12).disposition == "finished" and savedItemFor(world, 10).reviewRevision ~= nil,
		"pruning only navigation consumers preserves the independent menu mutation and A's unread review")
end

for _, targets in ipairs({ 2, 6 }) do
	for _, action in ipairs({ "open", "toolbar-next", "next" }) do
		for _, running in ipairs({ false, true }) do
			local world, rail = navigationWorld(targets)
			world.holdIdentity, world.holdHeaders, world.holdSources = true, true, true
			local original = rowAction(renderedRowFor(world, rail, 10))
			local before = #world.sourceProcesses
			for pane = 10, 9 + targets do world:emit("title", { pane = pane }) end
			if running then world:advance(100) end
			local heldBody = if running then #world.sourceProcesses else nil
			if heldBody then
				assert(world.sourceProcesses[heldBody].input.op == nil and not world.sourceProcesses[heldBody].completed,
					"the dirty-target scenario must start with a real body still owning its finite slot")
			end
			world.focused = rail
			if action == "open" then world:click(rail, original)
			elseif action == "toolbar-next" then world:control(rail, "next")
			else world:command("next") end
			world:advance(100)
			local heldIdentity = #world.processes
			for index = (heldBody or before) + 1, #world.sourceProcesses do
				assert(world.sourceProcesses[index].input.op ~= nil,
					action .. " acceptance fences dirty bodies before identity proof with " .. targets .. " targets")
			end
			if heldBody then world:completeSource(heldBody); world:advance(100) end
			for index = (heldBody or before) + 1, #world.sourceProcesses do
				assert(world.sourceProcesses[index].input.op ~= nil,
					"releasing the pre-existing body cannot dispatch another body while navigation awaits identity")
			end
			world.holdIdentity = false
			world:completeIdentity(heldIdentity); world:advance(100)
			local currentIdentity = world.processes[#world.processes]
			if currentIdentity ~= world.processes[heldIdentity] then
				world:completeIdentity(#world.processes); world:advance(100)
			end
			local preFocus = #world.sourceProcesses
			assert(world.sourceProcesses[preFocus].input.op == "header" and world.focusWrites == 0,
				action .. " identity-to-header handoff reserves the slot for navigation, not the next dirty body")
			for index = (heldBody or before) + 1, preFocus do
				assert(world.sourceProcesses[index].input.op ~= nil,
					"no body starts in the identity-to-pre-focus-header handoff gap")
			end
			world:completeSource(preFocus); world:advance(100)
			local ack = #world.sourceProcesses
			assert(world.focused == 10 and world.focusWrites == 1 and world:inspect().navigationPending
				and savedItemFor(world, 10).reviewRevision ~= nil and ack > preFocus
				and world.sourceProcesses[ack].input.op == "header",
				action .. " pre-focus-to-ack handoff keeps review unread and reserves a fresh exact header")
			for index = preFocus + 1, ack do
				assert(world.sourceProcesses[index].input.op ~= nil,
					"no body starts after pre-focus header completion before destination acknowledgment")
			end
			world.holdSources, world.holdHeaders = false, false
			world:completeSource(ack); world:advance(1000)
			assert(not world:inspect().navigationPending and savedItemFor(world, 10).reviewRevision == nil
				and world.focusWrites == 1,
				"exact acknowledgment completes before dirty background coverage resumes")
			local covered = {}
			for index = before + 1, #world.sourceProcesses do
				local request = world.sourceProcesses[index]
				if request.input.op == nil and request.completed then
					for _, target in ipairs(request.input.targets) do covered[target.path] = true end
				end
			end
			for pane = 10, 9 + targets do
				assert(covered[world.identityFiles[pane]],
					action .. " must resume dirty source coverage for pane " .. pane .. " after its fenced visit")
			end
		end
	end
end

-- ─── Workspace navigator ─────────────────────────────────────────────────────────────────────────────────
-- Fixture: two conversations with an unread review (tab 3 in session Work, tab 4 in session Research) and a
-- named note tab.
local function workspaceWorld(position)
	local world = native(true, nil, position)
	world.agentState = "idle"
	world.identityFiles[10], world.identityFiles[11] = "/sessions/ws-a.jsonl", "/sessions/ws-b.jsonl"
	world:addTab(4, 11, 1, 7)
	world.sessions[7].name = "Research"
	world.additionalAgents = { [11] = "idle" }
	world:addTab(5, 12, 1, 7)
	world.paneInfo[12] = { kind = "file", path = "note:Scratch", title = "Scratch" }
	world.tabs[5].name = "Notes"
	world:advance(3100)
	world:emit("agent_finished", { pane = 10, result = "failed" }); world:advance(100)
	world:emit("agent_finished", { pane = 11, result = "failed" }); world:advance(100)
	return world, world.opens[1].pane
end

local function pickerIndex(world, id)
	for index, item in ipairs(world.pickers[#world.pickers].options.items) do
		if item.id == id then return index end
	end
	error("the current picker has no item " .. id)
end

-- D4: navigation never changes review state or the Next attention round; review actions still do.
for _, via in ipairs({ "attention-open", "workspace-note", "workspace-conversation", "search", "previous", "reveal" }) do
	local world, rail = workspaceWorld()
	local revisionA, revisionB = savedItemFor(world, 10).reviewRevision, savedItemFor(world, 11).reviewRevision
	assert(revisionA ~= nil and revisionB ~= nil and world:inspect().attentionCount == 2,
		"both conversations carry an unread review before navigating")
	local start = if via == "workspace-conversation" or via == "search" then 12 else 10
	if start == 12 then
		-- The rail on screen is the one in the selected tab.
		world:switch(5); world:advance(3100)
		rail = world.opens[#world.opens].pane
	end
	local writes, focusBefore = world.triageWrites, world.focusWrites
	local target = 10
	if via == "attention-open" then
		world:click(rail, rowAction(renderedRowFor(world, rail, 10))); world:advance(100)
	elseif via == "workspace-note" then
		target = 12
		world:control(rail, "workspace"); world:advance(100)
		world:click(rail, wsPart(world, rail, "tab:local#5", "open")); world:advance(100)
	elseif via == "workspace-conversation" then
		world:control(rail, "workspace"); world:advance(100)
		world:click(rail, wsPart(world, rail, "tab:local#3", "open")); world:advance(100)
	elseif via == "search" then
		world:control(rail, "search")
		world:choose(pickerIndex(world, "pane:local#10")); world:advance(100)
	elseif via == "previous" then
		world:control(rail, "workspace"); world:advance(100)
		world:click(rail, wsPart(world, rail, "tab:local#5", "open")); world:advance(100)
		assert(world.focused == 12, "the detour reached the note")
		world:advance(3100)
		world:control(world.opens[#world.opens].pane, "previous"); world:advance(100)
	else
		world:control(rail, "workspace"); world:advance(100)
		world:click(rail, wsPart(world, rail, "session:local#2", "toggle")); world:advance(100)
		assert(not wsRow(world, rail, "tab:local#3"), "the collapsed session hides its tab")
		world:command("reveal"); world:advance(100)
		assert(wsRow(world, rail, "tab:local#3"), "Reveal current opens the collapsed session around the current pane's tab")
		target = 10
	end
	local acknowledged = via == "attention-open"
	assert(world.focused == target, via .. " lands on its exact target")
	assert((via == "reveal") == (world.focusWrites == focusBefore),
		via .. " moves native focus only when it navigates")
	assert(savedItemFor(world, 11).reviewRevision == revisionB and world.settingsWrites == 0, via .. " leaves the other review alone")
	if acknowledged then
		assert(savedItemFor(world, 10).reviewRevision == nil and world:inspect().attentionCount == 1,
			"Attention Open acknowledges exactly the displayed review")
	else
		assert(savedItemFor(world, 10).reviewRevision == revisionA and world.triageWrites == writes
			and world:inspect().attentionCount == 2,
			via .. " is navigation only: no acknowledgment and no tracking write")
	end
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == (if acknowledged then 11 else 10),
		via .. " leaves the Next attention round where it was")
	if not acknowledged then
		assert(savedItemFor(world, 10).reviewRevision == nil,
			"Next attention still acknowledges the review it opens")
	end
end

do
	local world = native(true)
	world:advance(3100)
	assert(world.commands["choose-session"] == nil and world.commands.search and world.commands.reveal
		and world.commands["focus-navigator"] and world.commands.new and world.commands.previous,
		"the session chooser is gone and the workspace commands are registered")
	assert(#world.binds == 1 and world.binds[1].chord == "cmd+j", "no new bare key is bound")
end

local function menuLabels(world)
	local labels = {}
	for _, item in ipairs(world.pickers[#world.pickers].options.items) do table.insert(labels, item.label) end
	return labels
end

local function hasLabel(labels, needle)
	for _, label in ipairs(labels) do
		if string.find(label, needle, 1, true) then return true end
	end
	return false
end

-- A reference conversation with no open pane is in no queue. Search still lists it, choosing it refuses plainly,
-- and nothing moves focus.
do
	local world, rail = workspaceWorld()
	local serial = savedItemFor(world, 10).serial
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "menu")); world:chooseLabel("Keep as reference"); world:advance(100)
	world:closePane(10); world:advance(100)
	world:switch(4); world:advance(3100)
	rail = world.opens[#world.opens].pane
	assert(not nativeCanvas.childAt(sectionRows(world, rail, "attention"), "r" .. serial)
		and not nativeCanvas.childAt(sectionRows(world, rail, "working"), "r" .. serial),
		"the reference conversation without an open pane is in no queue")
	local focusBefore, switches = world.focusWrites, #world.sessionSwitches
	world:control(rail, "search")
	world:choose(pickerIndex(world, "retained:work:" .. serial)); world:advance(100)
	assert(toastCount(world, "info", "No open pane") == 1
		and world.focusWrites == focusBefore and #world.sessionSwitches == switches,
		"choosing the saved conversation refuses plainly and navigates nowhere")
end


local function chooseContaining(world, needle)
	for index, label in ipairs(menuLabels(world)) do
		if string.find(label, needle, 1, true) then world:choose(index); return end
	end
	error("the current menu has no item containing " .. needle)
end

-- LIFE-06 / gate G9: a parked pane is never focused or unparked from here, a floating pane is focused without
-- docking, and an unattached pane is simply focused.
for _, placement in ipairs({ "parked", "floating", "unattached" }) do
	local world, rail = workspaceWorld()
	if placement == "parked" then world.parked[12] = true
	elseif placement == "floating" then world.floating[12], world.floats[5] = true, { { pane = 12, over = 11, corner = "top_right" } }
	else world.membership[12], world.tabs[5], world.loose[12] = nil, nil, true end
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	local action = wsPart(world, rail, if placement == "floating" then "tab:local#5" else "pane:local#12", "open")
	assert(action, "the " .. placement .. " pane is listed with its own open control")
	local focusBefore, layoutBefore = world.focusWrites, world.layoutWrites
	world:click(rail, action); world:advance(100)
	if placement == "parked" then
		assert(world.focusWrites == focusBefore and world.parked[12] == true and world.layoutWrites == layoutBefore
			and #world.actionRuns == 1 and world.actionRuns[1] == "parked_panes"
			and toastCount(world, "info", "Parked — restore it from Parked panes") == 1,
			"a parked pane is never focused or unparked: the native chooser restores it")
	else
		assert(world.focused == 12 and world.focusWrites == focusBefore + 1 and world.layoutWrites == layoutBefore
			and #world.actionRuns == 0 and (placement ~= "floating" or world.floating[12] == true),
			"a " .. placement .. " pane is focused exactly, without docking or any layout change")
	end
	assert(world.settingsWrites == 0, "no native setting is written")
end

-- Tab rows focus their content (never an owned canvas), a session label discloses its tabs, and a host band
-- discloses its sessions; a session with no visible tab is listed by name on the No tabs line, which opens a tab there.
do
	local world, rail = workspaceWorld()
	world.sessions[9] = { host = 1, name = "Empty" }
	table.insert(world.sessionOrder, 9)
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	assert(wsRow(world, rail, "pane:local#" .. rail) == nil, "the navigator never lists its own canvas")
	assert(wsRow(world, rail, "session:local#9") and not wsPart(world, rail, "session:local#9", "toggle"),
		"a session with no visible tab is listed, with nothing to disclose")
	local sessionToggle = wsPart(world, rail, "session:local#7", "toggle")
	assert(sessionToggle, "a session with tabs stays listed with its disclosure")
	local tabsBefore = #world.newTabs
	world:click(rail, wsPart(world, rail, "session:local#9", "open")); world:advance(100)
	assert(world.currentSession == 9 and #world.newTabs == tabsBefore + 1,
		"opening an empty session switches to it and opens its first tab")
	world:switch(5); world:advance(3100)
	local noteRail = world.opens[#world.opens].pane
	world.focused = noteRail
	world:click(noteRail, wsPart(world, noteRail, "tab:local#5", "open")); world:advance(100)
	assert(world.focused == 12 and world.canvases[world.focused] == nil,
		"a tab row focuses its content pane even when its focused pane is the owned canvas")
end

do
	local world, rail = workspaceWorld()
	world:addTab(6, 13, 8, 21)
	world.sessions[21].name, world.hostNames = "Laptop work", { [8] = "Laptop" }
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	local hostRow = wsRow(world, rail, "host:6:host-8")
	assert(hostRow and hostRow.p.tag == "button" and hostRow.p.actions and hostRow.p.actions.click,
		"a host row is listed once two hosts have content, and its whole row is the disclosure")
	world:click(rail, wsPart(world, rail, "tab:host-8#6", "open")); world:advance(100)
	assert(#world.hostSwitches == 1 and world.hostSwitches[1] == 8 and world.currentHost == 8,
		"a tab row on another host switches to that host")
end
-- A tab row on an offline host is refused like its host row: native focus does not change.
do
	local world, rail = workspaceWorld()
	world:addTab(6, 13, 8, 21)
	world.sessions[21].name, world.hostNames = "Laptop work", { [8] = "Laptop" }
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	world.hostStates[8] = "disconnected"; world:advance(1100)
	local action = wsPart(world, rail, "tab:host-8#6", "open")
	assert(action, "an offline host's tab row is listed with its open control")
	local focused = world.focused
	world:click(rail, action); world:advance(100)
	assert(world.focusWrites == 0 and world.focused == focused and #world.hostSwitches == 0
		and toastCount(world, "info", "Host is offline · nothing changed") == 1,
		"a tab row on an offline host is refused and focus does not change")
end

-- A control that no longer matches the native world is "Target changed", never a position or title fallback.
do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	local note = wsPart(world, rail, "tab:local#5", "open")
	local conversation = wsPart(world, rail, "tab:local#3", "open")
	world.membership[12] = 4
	world:click(rail, note)
	assert(toastCount(world, "info", "Target changed") == 1 and world.focusWrites == 0 and world.focused == 10,
		"a pane that moved tabs since the row was drawn is not activated")
	-- The rail's own tab loses its last content pane: the rail closes inside that close event, never left alone in the tab.
	world:closePane(10)
	assert(world.canvases[rail] == nil and world.focusWrites == 0, "a tab whose only content pane closed takes its rail with it")
end

-- A tab created while the window watches gets its rail inside its own events (native order: the shell's pane_created,
-- tab_created, then focus), with no restore grace and no timer.
do
	local world = native(true)
	world:advance(3100)
	local before = #world.opens
	world:addTab(4, 11)
	world:emit("pane_created", { pane = 11 })
	world:emit("tab_created", { tab = 4 })
	world:switch(4)
	local opened = world.opens[before + 1]
	assert(opened and world.membership[opened.pane] == 4, "the new tab's rail opens inside its creation events")
end

-- Closing the last tab of the current session goes back to where you were before (the empty session stays listed);
-- the window never sits in a session Attention cannot show itself in.
do
	local world = native(true)
	world:advance(3100)
	world:addTab(4, 11, 1, 21)
	world:switch(4); world:advance(3100)
	local tabRail = world.opens[#world.opens].pane
	assert(world.membership[tabRail] == 4 and world.currentSession == 21, "fixture: the other session's tab has its rail")
	world.tabs[4].content = nil
	world:closePane(11)
	assert(world.canvases[tabRail] == nil, "the emptied tab's rail closed with its last content pane")
	world.tabs[4], world.focused = nil, nil
	world:emit("tab_closed", { tab = 4 })
	assert(world.focused == 10 and world.currentSession == 2,
		"closing the session's last tab returns to the pane focused before it, in its own session")
end

-- The agent census is Tern's costliest read: a quiet heartbeat reuses it, an agent event re-reads it at once, and the
-- refresh age bounds how stale the fields without an event (model, delivery error) can be.
do
	local world = native(true)
	world:advance(8000)
	local reads = world.agentListReads
	world.agentState = "working"
	world:advance(100)
	assert(world.agentListReads > reads and world:inspect().attentionCount == 0,
		"an agent state change is read in the pass its event schedules")
	reads = world.agentListReads
	world:advance(4000)
	assert(world.agentListReads == reads, "quiet heartbeats reuse the agent census")
	world:advance(2000)
	assert(world.agentListReads == reads + 1, "the census refreshes once its age passes the refresh bound")
end

-- Closing a tab that leaves its session with other tabs moves nothing.
do
	local world = native(true)
	world:advance(3100)
	world:addTab(4, 11)
	world:switch(4); world:advance(3100)
	local writes = world.focusWrites
	world:closePane(11)
	world.tabs[4] = nil
	world:emit("tab_closed", { tab = 4 })
	assert(world.focusWrites == writes, "a session that still has tabs is left to native focus")
end

-- The rail's place line carries the focused conversation's model in its tooltip, and names none without a model.
do
	local world, rail = workspaceWorld()
	local function placeTooltip()
		local found = nil
		local function visit(node)
			if node.p and node.p.hidden then return end
			if node.p and node.p.role == "attention.location" and node.p.tag == "button" then found = node.p.title end
			for _, child in ipairs(node.c or {}) do visit(child) end
		end
		visit(world.canvases[rail].view)
		return found
	end
	world.models = { [10] = "GPT-6 Astra" }
	world:emit("agent_state", { pane = 10, old = "idle", new = "idle" }); world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	assert(placeTooltip() and string.find(placeTooltip(), "GPT-6 Astra", 1, true),
		"the place line's tooltip names the focused conversation's model")
	world.models = {}
	world:emit("agent_state", { pane = 10, old = "idle", new = "idle" }); world:advance(3100)
	assert(placeTooltip() and not string.find(placeTooltip(), "GPT-6 Astra", 1, true),
		"a place with no model names none in the place line's tooltip")
end

-- An agent's model is display only: flipping it re-renders the sub-line and moves no target signature, row key, or
-- control binding, so a control drawn before the flip still activates instead of refusing with "Target changed".
do
	local world, rail = workspaceWorld()
	local function modelLine(row)
		local found = nil
		local function visit(node)
			if node.p and node.p.hidden then return end
			if node.p and node.p.role == "attention.model-line" and node.p.text ~= "" then found = node.p.text end
			for _, child in ipairs(node.c or {}) do visit(child) end
		end
		visit(row)
		return found
	end
	local function conversationRow(pane)
		return (nativeCanvas.childAt(sectionRows(world, rail, "attention"), "r" .. savedItemFor(world, pane).serial))
	end
	local function rowKeys()
		local keys = {}
		for _, row in ipairs(sectionRows(world, rail, "workspace").c) do table.insert(keys, row.p.key) end
		return table.concat(keys, ",")
	end
	local function setModels(models)
		world.models = models
		world:emit("agent_state", { pane = 10, old = "idle", new = "idle" }); world:advance(3100)
	end
	setModels({ [10] = "GPT-6 Astra", [11] = "Claude Opus 4.6" })
	world:control(rail, "workspace"); world:advance(100)
	assert(modelLine(conversationRow(10)) == "GPT-6 Astra" and modelLine(conversationRow(11)) == "Claude Opus 4.6",
		"two different models: each Attention row names its own on the sub-line")
	local conversation = rowAction(conversationRow(10))
	local note = wsPart(world, rail, "tab:local#5", "open")
	local tab = wsPart(world, rail, "tab:local#3", "open")
	local session = wsPart(world, rail, "session:local#7", "toggle")
	local keys = rowKeys()
	assert(conversation and note and tab and session)
	local focusBefore = world.focusWrites
	for _, step in ipairs({
		{ models = { [10] = "GPT-6 Terra", [11] = "Claude Opus 4.6" }, first = "GPT-6 Terra", second = "Claude Opus 4.6" },
		{ models = { [10] = "Claude Opus 4.6", [11] = "Claude Opus 4.6" }, first = "Claude Opus 4.6", second = "Claude Opus 4.6" },
		{ models = {}, first = false, second = false },
		{ models = { [10] = "GPT-6 Astra", [11] = "Claude Opus 4.6" }, first = "GPT-6 Astra", second = "Claude Opus 4.6" },
	}) do
		setModels(step.models)
		local firstRow, secondRow = conversationRow(10), conversationRow(11)
		assert((modelLine(firstRow) or false) == step.first and (modelLine(secondRow) or false) == step.second,
			"the sub-line follows the model: a known model shows even when every row shares it, and an absent model draws none")
		assert(rowAction(firstRow) == conversation and wsPart(world, rail, "tab:local#5", "open") == note
			and wsPart(world, rail, "tab:local#3", "open") == tab
			and wsPart(world, rail, "session:local#7", "toggle") == session and rowKeys() == keys,
			"a model change redraws no control binding and no row key")
		assert(toastCount(world, "info", "Target changed") == 0, "a model change never refuses a target")
	end
	world:click(rail, note); world:advance(100)
	assert(world.focused == 12 and world.focusWrites == focusBefore + 1 and toastCount(world, "info", "Target changed") == 0,
		"a control drawn before the model flipped still activates its exact target")
end

-- A model that changes with no other event still reaches the rail: the paint gate must see the displayed model, not only
-- the identity signature, or the sub-line keeps a model the agent no longer reports.
do
	local world, rail = workspaceWorld()
	local function modelLine(row)
		local found = nil
		local function visit(node)
			if node.p and node.p.hidden then return end
			if node.p and node.p.role == "attention.model-line" and node.p.text ~= "" then found = node.p.text end
			for _, child in ipairs(node.c or {}) do visit(child) end
		end
		visit(row)
		return found
	end
	local function conversationRow()
		return (nativeCanvas.childAt(sectionRows(world, rail, "attention"), "r" .. savedItemFor(world, 10).serial))
	end
	world.models = { [10] = "GPT-6 Astra" }
	world:emit("agent_state", { pane = 10, old = "idle", new = "idle" }); world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	assert(modelLine(conversationRow()) == "GPT-6 Astra", "fixture: the first model paints")
	world.models = { [10] = "Claude Opus 4.6" }
	world:advance(3100)
	assert(modelLine(conversationRow()) == "Claude Opus 4.6",
		"a model change with no other event repaints the sub-line")
end

-- Search offers the complete inventory, cancel is inert, and an answer acts only in its own epoch and owner.
do
	local world, rail = workspaceWorld()
	world.sessions[9] = { host = 1, name = "Empty" }
	table.insert(world.sessionOrder, 9)
	world:advance(100)
	local reads = world.inventoryReads
	world:control(rail, "search")
	assert(world.inventoryReads - reads == 1, "a Search click takes exactly one native inventory")
	local items = world.pickers[1].options.items
	assert(#items == 7, "every session (empty too), named tab and destination is offered")
	local labels = {}
	for _, item in ipairs(items) do
		assert(item.label ~= "" and not labels[item.label] and item.detail ~= "" and #item.detail <= 160
			and item.id ~= "pane:local#" .. rail, "labels are unique and the navigator's own canvas is absent")
		labels[item.label] = true
	end
	assert(world.pickers[1].options.placeholder ~= nil, "the picker is labelled")
	local before = { world.focusWrites, world.preferenceWrites, world.triageWrites, #world.toasts }
	world:choose(nil); world:advance(100)
	assert(world.focusWrites == before[1] and world.preferenceWrites == before[2] and world.triageWrites == before[3]
		and #world.toasts == before[4], "cancelling search changes nothing")
	world:command("search")
	assert(#world.pickers == 2 and #world.pickers[2].options.items == 7, "the palette command opens the same picker")
end

for _, change in ipairs({ "owner", "epoch", "reload", "selection", "moved", "error" }) do
	local world, rail = workspaceWorld()
	world:control(rail, "search")
	local index = pickerIndex(world, "pane:local#12")
	if change == "owner" then world.prefs.owner = "other"
	elseif change == "epoch" then world:command("disable"); world:command("enable")
	elseif change == "reload" then world:reload()
	elseif change == "selection" then world:toggleQueue(rail, "attention")
	elseif change == "moved" then world.membership[12] = 4 end
	local focusBefore, toastsBefore = world.focusWrites, #world.toasts
	world:choose(index, if change == "error" then "picker unavailable" else nil)
	world:advance(100)
	assert(world.focusWrites == focusBefore and world.settingsWrites == 0,
		"a pending search cannot navigate after " .. change)
	assert(change == "reload" or #world.toasts > toastsBefore, "a refused search answer says so after " .. change)
end

-- Reveal current opens the collapsed session around a pane inside a tab and lands on that tab's row; the panes of a
-- tab have no rows of their own.
do
	local world, rail = workspaceWorld()
	world.membership[13], world.paneHosts[13] = 4, 1
	world.layouts[4] = { split = "right", ratio = 0.5, [1] = { pane = 11 }, [2] = { pane = 13 } }
	world.paneInfo[13] = { kind = "terminal", title = "Shell" }
	world:advance(100)
	world:control(rail, "workspace"); world:advance(100)
	assert(wsRow(world, rail, "tab:local#4") and not wsRow(world, rail, "pane:local#13")
		and not wsRow(world, rail, "r" .. savedItemFor(world, 11).serial), "a tab with two panes is one row")
	world:click(rail, wsPart(world, rail, "session:local#7", "toggle")); world:advance(100)
	assert(not wsRow(world, rail, "tab:local#4"), "the collapsed session hides its tabs")
	world:switch(4); world:advance(3100)
	local tabRail = world.opens[#world.opens].pane
	local focusBefore = world.focusWrites
	world:command("reveal"); world:advance(100)
	assert(wsRow(world, tabRail, "tab:local#4") and world.prefs.uiByWindow.desktop.collapsed["session:local#7"] == false
		and world.focusWrites == focusBefore,
		"Reveal current opens the session around the current pane's tab row and persists that disclosure")
end

-- A linked parked conversation's row is keyed by its conversation, not its pane: Reveal current still finds it and
-- opens the collapsed Parked section around it.
do
	local world, rail = workspaceWorld()
	world.parked[11] = true
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	local row = "r" .. savedItemFor(world, 11).serial
	assert(wsRow(world, rail, row), "fixture: the parked conversation is listed under Parked")
	world:click(rail, wsPart(world, rail, "section:parked:local", "toggle")); world:advance(100)
	assert(not wsRow(world, rail, row), "fixture: the collapsed Parked section hides it")
	world.focused = 11
	world:emit("focus", { pane = 11 }); world:advance(100)
	local focusBefore = world.focusWrites
	world:command("reveal"); world:advance(100)
	assert(wsRow(world, rail, row) and world.prefs.uiByWindow.desktop.collapsed["section:parked:local"] == false
		and world.focusWrites == focusBefore and toastCount(world, nil, "not listed") == 0,
		"Reveal current opens the Parked section around a linked parked pane without moving focus")
end

-- The location line is Workspace-only. The rail is not a destination: with the rail itself focused, the line and
-- Reveal current keep naming the last active content pane, until that pane disappears.
do
	local world, rail = workspaceWorld()
	local function holdsKey(node, key)
		if node.p and node.p.key == key then return true end
		for _, child in ipairs(node.c or {}) do
			if holdsKey(child, key) then return true end
		end
		return false
	end
	assert(not holdsKey(descend(world.canvases[rail].view, "top"), "location"),
		"the Attention and Working sections show no current-location line")
	assert(holdsKey(descend(world.canvases[rail].view, "bottom"), "location"), "the Workspace region owns the line")
	world:control(rail, "workspace"); world:advance(100)
	local content = visibleText(headerPart(world, rail, "location"))
	assert(not string.find(content, "No current location", 1, true) and string.find(content, "Agent", 1, true),
		"the content pane is the current location")
	assert(headerPart(world, rail, "location").p.tag == "button", "the content location is a Reveal button")
	world.focused = rail
	world:emit("focus", { pane = rail }); world:advance(3100)
	assert(world.focused == rail and visibleText(headerPart(world, rail, "location")) == content
		and headerPart(world, rail, "location").p.tag == "button", "rail focus keeps naming the last content location")
	world:click(rail, wsPart(world, rail, "session:local#2", "toggle")); world:advance(100)
	assert(not wsRow(world, rail, "tab:local#3"), "the collapsed session hides its tab")
	world:command("reveal"); world:advance(100)
	assert(wsRow(world, rail, "tab:local#3") and world.focused == rail,
		"Reveal current from the focused rail reveals the last content destination without moving focus")
	-- A second tab with two content panes keeps its rail when one of them closes.
	world:addTab(6, 14, 1, 2)
	world.paneInfo[14] = { kind = "terminal", title = "Shell A" }
	world.membership[15], world.paneHosts[15] = 6, 1
	world.paneInfo[15] = { kind = "terminal", title = "Shell B" }
	world.layouts[6] = { split = "right", ratio = 0.5, [1] = { pane = 14 }, [2] = { pane = 15 } }
	world:switch(6); world:advance(3100)
	local second = world.opens[#world.opens].pane
	world.focused = 15
	world:emit("focus", { pane = 15 }); world:advance(100)
	assert(string.find(tooltipText(headerPart(world, second, "location")), "Shell B", 1, true), "the focused content pane is the location")
	world.focused = second
	world:emit("focus", { pane = second }); world:advance(100)
	assert(string.find(tooltipText(headerPart(world, second, "location")), "Shell B", 1, true), "the rail focus keeps Shell B")
	world:closePane(15); world:advance(100)
	assert(world.canvases[second] and headerPart(world, second, "location") == nil,
		"the tracked content pane is forgotten when it disappears")
end

-- D3: the control window returns to where it left off; nothing transient is saved or replayed. The strip saves its
-- selected section; the stack has no section to select and saves only its disclosures (next test).
do
	local world, rail = workspaceWorld("bottom")
	assert(world:inspect().logical.section == "attention" and world.prefs.uiByWindow.desktop == nil,
		"first-ever activation starts in Attention")
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "session:local#7", "toggle")); world:advance(100)
	local saved = world.prefs.uiByWindow.desktop
	assert(saved.section == "workspace" and saved.collapsed["session:local#7"] == true, "section and collapse are saved")
	for key in saved do
		assert(key == "section" or key == "collapsed", "only navigator state is persisted: " .. key)
	end
	world:control(rail, "search")
	local pickers, focusBefore = #world.pickers, world.focusWrites
	world:reload(); world:advance(3100)
	assert(world:inspect().logical.section == "workspace" and #world.pickers == pickers and world.focusWrites == focusBefore,
		"the saved mode returns without replaying any action or reopening the picker")
	assert(wsRow(world, rail, "session:local#7") and not wsRow(world, rail, "tab:local#4"),
		"the collapsed session stays collapsed")
	world:control(rail, "attention"); world:advance(2100)
	assert(world:inspect().logical.section == "attention", "restoring happens once and never overrides a later choice")
end

-- This Mac's sessions start open on a stack rail. An explicit choice is stored and survives a reload: closing a session
-- stores `true`, and reopening it over the open default stores `false`, which must not collapse back after a reload.
do
	local world, rail = workspaceWorld()
	assert(world.prefs.uiByWindow.desktop == nil, "first-ever activation has saved nothing")
	assert(wsRow(world, rail, "tab:local#3") and wsRow(world, rail, "tab:local#4"),
		"this Mac's sessions start open on a stack rail")
	world:click(rail, wsPart(world, rail, "session:local#2", "toggle")); world:advance(100)
	assert(world.prefs.uiByWindow.desktop.collapsed["session:local#2"] == true
		and world.prefs.uiByWindow.desktop.collapsed["session:local#7"] == nil,
		"closing one session stores its explicit choice and leaves the other at its default")
	assert(not wsRow(world, rail, "tab:local#3"), "the closed session lists no tabs")
	world:click(rail, wsPart(world, rail, "session:local#2", "toggle")); world:advance(100)
	assert(world.prefs.uiByWindow.desktop.collapsed["session:local#2"] == false,
		"reopening a session over the open default is stored as explicit false")
	world:reload(); world:advance(3100)
	local restored = world.prefs.uiByWindow.desktop
	assert(restored.collapsed["session:local#2"] == false and wsRow(world, rail, "tab:local#3"),
		"the explicit open survives the reload cycle with no click after it")
end

-- A tab with no open pane has no Workspace row; Search can still name it, and choosing it is refused by name with
-- nothing changed.
do
	local world, rail = workspaceWorld()
	world.tabs[6] = { session = 7, host = 1, name = "Empty tab" }
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	assert(not wsRow(world, rail, "tab:local#6"), "an empty tab has no Workspace row")
	world:control(rail, "search")
	local index = pickerIndex(world, "tab:local#6")
	local focusBefore, switches = world.focusWrites, #world.sessionSwitches
	world:choose(index); world:advance(100)
	assert(toastCount(world, "info", "Tab has no open pane · nothing changed") == 1
		and world.focusWrites == focusBefore and #world.sessionSwitches == switches,
		"a tab with no open pane is refused and nothing changes")
end

-- The Workspace header's Minimize folds the tree into its header (the top region takes nearly all of the rail), and
-- Show restores the share the rail had. Layout only: nothing is focused or saved.
do
	local world, rail = workspaceWorld()
	world:advance(100)
	local function topShare() return world.canvases[rail].view.p.sizes[1] end
	local function minimizeControl() return keyedAction(descend(world.canvases[rail].view, "bottom", "head"), "minimize") end
	local before, focusBefore, prefsBefore = topShare(), world.focusWrites, world.preferenceWrites
	world:click(rail, minimizeControl()); world:advance(100)
	assert(math.abs(topShare() - 0.9) < 0.001, "minimize gives the attention region nine tenths of the rail")
	assert(descend(world.canvases[rail].view, "bottom", "rows").p.hidden == true, "minimized Workspace rows are hidden")
	world:click(rail, minimizeControl()); world:advance(100)
	assert(math.abs(topShare() - before) < 0.001, "Show restores the share the rail had before minimizing")
	assert(descend(world.canvases[rail].view, "bottom", "rows").p.hidden == false, "shown Workspace rows return")
	assert(world.focusWrites == focusBefore and world.preferenceWrites == prefsBefore,
		"minimizing is layout only: nothing is focused or saved")
end

-- The gear names the queue Settings returns to, and the Settings heading's Back closes Settings on that same queue.
do
	local world, rail = workspaceWorld()
	world:advance(100)
	local function titled(node, key)
		if node.p and node.p.key == key and node.p.title then return node.p.title end
		for _, child in node.c or {} do
			local found = titled(child, key)
			if found then return found end
		end
		return nil
	end
	world:control(rail, "settings"); world:advance(100)
	local view = world.canvases[rail].view
	assert(world:inspect().logical.settings == true and titled(view, "settings") == "Back to Attention",
		"the gear names the queue it returns to while Settings is open")
	world:click(rail, keyedAction(view, "back")); world:advance(100)
	assert(world:inspect().logical.settings == false and world:inspect().logical.section == "attention",
		"the Settings Back control closes Settings and keeps the queue it came from")
	assert(world.settingsWrites == 0, "closing Settings writes no native setting")
end

-- A click that reaches its canvas before the timer pass repaints acts on the control that canvas still shows, and
-- never reports a refusal. A control the newer paint no longer shows does nothing.
do
	local world, rail = workspaceWorld()
	world:advance(100)
	local errors, gear = toastCount(world, "error", ""), keyedAction(world.canvases[rail].view, "settings")
	world:toggleQueue(rail, "working")
	world:click(rail, gear)
	world:advance(100)
	assert(world:inspect().logical.settings == true and toastCount(world, "error", "") == errors,
		"a gear click that lands before the queue toggle paints still opens Settings without a refusal")
end

do
	local world, rail = workspaceWorld("bottom")
	world:advance(100)
	local view = world.canvases[rail].view
	local open, working = rowAction(shown(world, rail)), keyedAction(view, "working")
	assert(open and working, "fixture: an Attention row and the Working tab are on screen")
	local focuses, errors = world.focusWrites, toastCount(world, "error", "")
	world:click(rail, working)
	world:click(rail, open)
	world:advance(100)
	assert(world:inspect().logical.section == "working" and world.focusWrites == focuses and toastCount(world, "error", "") == errors,
		"a row the newer paint no longer shows does nothing, while the Working tab still takes effect")
end

-- New… works with no rail at all (an empty session), names its destination before committing, and confirms each
-- native effect by reading state back: a reply that "succeeds" without creating anything is an error.
local function emptyWorld()
	local world = native(true)
	world.tabs, world.membership, world.paneHosts, world.focused = {}, {}, {}, nil
	world:advance(3100)
	assert(#world.opens == 0, "an empty session mounts no rail")
	return world
end

for _, honest in ipairs({ true, false }) do
	local world = emptyWorld()
	world.ignoreCreation = not honest
	world:command("new")
	local items = world.pickers[1].options.items
	assert(#items == 5 and items[1].label == "New tab", "every creation kind is offered, and bare conversation creation is not")
	for _, item in ipairs(items) do
		assert(string.find(item.detail, "Desktop", 1, true) and (item.op == "session" or string.find(item.detail, "Work", 1, true)),
			"every kind names its host, and its session when it lands in one, before anything is committed")
	end
	world:choose(1); world:advance(100)
	assert(#world.newTabs == 1 and world.settingsWrites == 0, "New tab asks the native layout once")
	if honest then
		assert(world.focused ~= nil and toastCount(world, "error", "") == 0, "a created tab is verified from the pane list")
	else
		assert(toastCount(world, "error", "New tab was not created") == 1, "an accepted but empty reply is reported")
	end
end

for _, case in ipairs({
	{ label = "New note…", answer = "Plan", ran = function(world) return world.noteCreates[1] and world.noteCreates[1].title == "Plan" end,
		failure = "Note was not created" },
	{ label = "Open file…", answer = "docs/readme.md", ran = function(world) return world.fileOpens[1] == "docs/readme.md" end,
		failure = "File was not opened" },
	{ label = "Open URL…", answer = "https://example.test/a", browser = true,
		ran = function(world) return world.browserCalls[1] and world.browserCalls[1].op == "open"
			and world.browserCalls[1].url == "https://example.test/a" end, failure = "Browser was not created" },
	{ label = "New session…", answer = "Ops", ran = function(world)
		return world.sessionCreates[1] and world.sessionCreates[1].name == "Ops" end, failure = "Session was not created" },
}) do
	for _, honest in ipairs({ true, false }) do
		local world = emptyWorld()
		world.ignoreCreation = not honest
		world:command("new"); world:chooseLabel(case.label)
		world:answer(case.answer)
		if case.browser then world:completeBrowser() end
		world:advance(100)
		assert(case.ran(world), case.label .. " reaches its native call")
		if honest then
			assert(toastCount(world, "error", "") == 0 and world.settingsWrites == 0, case.label .. " is verified from native state")
			if case.label == "New session…" then assert(world.currentSession ~= 2, "the new session is current") end
		else
			assert(toastCount(world, "error", case.failure) == 1, case.label .. " reports an effect it could not read back")
		end
	end
end

-- A creation committed after the session changed is refused, and a cancelled prompt does nothing.
do
	local world = emptyWorld()
	world.sessions[9] = { host = 1, name = "Other" }
	table.insert(world.sessionOrder, 9)
	world:command("new"); world:chooseLabel("New note…")
	world.currentSession = 9
	world:answer("Late")
	assert(#world.noteCreates == 0 and toastCount(world, "error", "current session changed") == 1,
		"the destination named in the menu is re-checked at commit")
	world.currentSession = 2
	world:command("new"); world:chooseLabel("New note…")
	world:answer(nil)
	assert(#world.noteCreates == 0 and #world.newTabs == 0, "dismissing the prompt creates nothing")
end

-- Tab and session rows: rename with an explicit id and read back; add a tab in that session; never close.
for _, honest in ipairs({ true, false }) do
	local world, rail = workspaceWorld()
	world.ignoreRename = not honest
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#5", "menu"))
	local labels = {}
	for _, label in ipairs(menuLabels(world)) do
		if not string.find(label, "^Move ") then table.insert(labels, label) end
	end
	assert(#labels == 4 and labels[1] == "Rename tab…" and labels[2] == "New tab here"
		and labels[3] == "Park (keep program alive)" and labels[4] == "Close", "a tab with panes offers rename, a new tab, park and close")
	world:choose(1); world:answer("Docs"); world:advance(100)
	assert(world.renames[1].tab == 5 and world.renames[1].name == "Docs", "the tab is renamed by its explicit id")
	if honest then
		assert(world.tabs[5].name == "Docs" and string.find(visibleText(wsRow(world, rail, "tab:local#5")), "Docs", 1, true),
			"the new name is read back and drawn")
	else
		assert(toastCount(world, "error", "Tab was not renamed") == 1, "an ignored rename is reported")
	end
end

do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#5", "menu"))
	world:chooseLabel("New tab here"); world:advance(100)
	assert(world.sessionSwitches[#world.sessionSwitches] == 7 and #world.newTabs == 1
		and world.tabs[world.nextTab - 1].session == 7, "a new tab is created in the row's own session")
	assert(#world.closes == 0 and toastCount(world, "error", "") == 0, "creating a tab closes nothing")
	for _, run in ipairs(world.actionRuns) do assert(not string.find(run, "close", 1, true), "no close action is ever run") end
end

-- Tab rows that own panes offer Park and Close for every one of those panes, counted in the label when more than
-- one; a tab with no panes and a session row offer neither. Close is one deliberate menu choice with no second prompt.
local function tabPaneIds(world, tab)
	local ids = {}
	for pane, membership in world.membership do
		if membership == tab and not world.parked[pane] then table.insert(ids, pane) end
	end
	table.sort(ids)
	return ids
end
local function nonMoveLabels(world)
	local labels = {}
	for _, label in ipairs(menuLabels(world)) do
		if not string.find(label, "^Move ") then table.insert(labels, label) end
	end
	return labels
end

for _, op in ipairs({ "park", "close" }) do
	local world, rail = workspaceWorld()
	world.tabs[6] = { session = 7, host = 1 }
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)

	world:click(rail, wsPart(world, rail, "tab:local#5", "menu"))
	local single = nonMoveLabels(world)
	assert(#single == 4 and single[3] == "Park (keep program alive)" and single[4] == "Close",
		"a one-pane tab offers Park and Close without a count")
	world:choose(nil)

	assert(not wsRow(world, rail, "tab:local#6"), "an empty tab has no Workspace row")


	local expected = tabPaneIds(world, 3)
	assert(#expected >= 2, "fixture: the first tab holds its agent and its rail")
	world.models[10] = "zz-private-model"
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local multi = nonMoveLabels(world)
	local suffix = " · " .. #expected .. " panes"
	local park, close = #multi - 1, #multi
	assert(multi[close] == "Close" .. suffix and multi[park] == "Park (keep program alive)" .. suffix
		and multi[park - 1] == "New tab here" and multi[park - 2] == "Rename tab…",
		"a multi-pane tab counts its panes in both labels, after its target conversation's tracking items")
	assert(multi[1] == "Set priority · P0–P3 or unset",
		"the first item is the target conversation's first tracking label, ahead of the tab actions")
	for _, item in ipairs(world.pickers[#world.pickers].options.items) do
		for _, field in item do
			assert(not string.find(tostring(field), "zz-private-model", 1, true), "a menu item never carries the agent model")
		end
	end
	local writes = world.layoutWrites
	world:chooseLabel(if op == "park" then "Park (keep program alive)" .. suffix else "Close" .. suffix)
	local done, untouched = if op == "park" then world.parks else world.closes, if op == "park" then world.closes else world.parks
	table.sort(done)
	assert(equalValue(done, expected) and #untouched == 0
		and world.layoutWrites == writes + #expected and toastCount(world, "error", "") == 0,
		op .. " reaches every pane of that tab exactly once and nothing else")
	for _, pane in ipairs(tabPaneIds(world, 4)) do
		assert(world.membership[pane] == 4 and not world.parked[pane], "another tab's panes are untouched")
	end
	if op == "park" then
		for _, pane in ipairs(expected) do assert(world.parked[pane], "the pane is parked, not closed") end
	else
		for _, pane in ipairs(expected) do assert(world.membership[pane] == nil, "the pane is closed") end
	end
end

-- A refused park is reported, and the tab's other panes are still parked.
do
	local world, rail = workspaceWorld()
	world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	local expected = tabPaneIds(world, 3)
	world.refusePark = { [10] = true }
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	world:chooseLabel("Park (keep program alive) · " .. #expected .. " panes")
	assert(#world.parks == #expected and toastCount(world, "error", "native park refused") == 1,
		"every pane is attempted and the refusal is reported once")
	for _, pane in ipairs(expected) do assert((world.parked[pane] == true) == (pane ~= 10), "only the refused pane stays docked") end
end

-- A tab row's More menu lists its target conversation's tracking choices first, then the tab actions. An idle
-- conversation's Finished for now moves its tracking only: no focus change and the agent's state is unchanged.
do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local labels = menuLabels(world)
	assert(#labels >= 5 and labels[1] == "Set priority · P0–P3 or unset" and labels[2] == "Keep as reference"
		and labels[3] == "Finished for now · current scope" and labels[4] == "Inspect recorded facts · does not navigate or acknowledge"
		and labels[5] == "Rename tab…" and not hasLabel(labels, "Open existing pane"),
		"an idle conversation's tab offers its tracking choices, then the tab actions, and never Open existing pane")
	local focuses, agent = world.focusWrites, world.agentState
	world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(savedItemFor(world, 10).disposition == "finished" and world.focusWrites == focuses and world.agentState == agent
		and toastCount(world, "error", "") == 0, "Finished from a tab row sets tracking only: no focus change and the agent state is unchanged")
end

-- Inspect from a tab row's menu expands that conversation's recorded facts and does nothing else.
do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local item = savedItemFor(world, 10)
	local disposition, focuses = item.disposition, world.focusWrites
	world:chooseLabel("Inspect recorded facts · does not navigate or acknowledge"); world:advance(100)
	assert(world:inspect().logical.expandedWorkId == "work:" .. item.serial,
		"Inspect from a tab row expands that tab's target conversation")
	assert(world.focusWrites == focuses and savedItemFor(world, 10).disposition == disposition
		and toastCount(world, "error", "") == 0, "Inspect from a tab row neither navigates, changes tracking, nor reports an error")
end

-- The row's target is the first content pane when focus is on the Attention rail: its menu and its title both follow
-- that conversation, not the focused rail pane.
do
	local world, rail = workspaceWorld()
	world.paneInfo[10] = { title = "Ledger agent" }
	world.focused = rail
	world:emit("title", { pane = 10 }); world:emit("focus", { pane = rail }); world:advance(100)
	world:control(rail, "workspace"); world:advance(100)
	assert(world.membership[rail] == 3 and world.focused == rail, "fixture: focus is on the tab's Attention rail")
	assert(string.find(visibleText(wsRow(world, rail, "tab:local#3")), savedItemFor(world, 10).title, 1, true)
		and savedItemFor(world, 10).title == "Ledger agent", "the tab row is titled with its target conversation")
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local labels = menuLabels(world)
	assert(hasLabel(labels, "Finished for now") and hasLabel(labels, "Keep as reference"),
		"the tab menu lists the target conversation's tracking items although the rail has focus")
end

-- A reference conversation's tab row offers Resume tracking and Bring back. Resume restores tracking without
-- navigating and leaves the agent's state unchanged.
do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#4", "menu"))
	world:chooseLabel("Keep as reference"); world:advance(100)
	assert(savedItemFor(world, 11).disposition == "reference", "fixture: the tab's conversation is kept as reference from its tab row")
	world:click(rail, wsPart(world, rail, "tab:local#4", "menu"))
	local labels = menuLabels(world)
	assert(hasLabel(labels, "Resume tracking · does not run agent") and hasLabel(labels, "Bring back now")
		and hasLabel(labels, "Rename tab…"), "a reference conversation's tab offers resume and bring back beside the tab actions")
	local focuses, agent = world.focusWrites, world.additionalAgents[11]
	world:chooseLabel("Resume tracking · does not run agent"); world:advance(100)
	assert(savedItemFor(world, 11).disposition == "active" and world.focusWrites == focuses
		and world.additionalAgents[11] == agent and toastCount(world, "error", "") == 0,
		"Resume from a tab row restores tracking without navigating and leaves the agent state unchanged")
end

-- A tab menu opened before its conversation changed refuses its choice and writes nothing.
do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local opened = world.pickers[#world.pickers]
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	world:chooseLabel("Keep as reference"); world:advance(100)
	assert(savedItemFor(world, 10).disposition == "reference", "fixture: a second tab menu changes the conversation's tracking")
	local focuses = world.focusWrites
	world.pickers[#world.pickers + 1] = opened -- the first menu is still the one the user chooses from
	world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(savedItemFor(world, 10).disposition == "reference" and world.focusWrites == focuses
		and toastCount(world, "error", "This conversation menu is no longer current") == 1,
		"a stale tab menu refuses its choice with the current-menu message and writes nothing")
end

-- Disable leaves every rail where it is; Disable and close rails retires each rail pane and still disables.
do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	assert(world.canvases[first] and world.canvases[second], "fixture: two mounted rails")
	world:command("disable")
	assert(not world.prefs.enabled and #world.closes == 0 and world.canvases[first] and world.canvases[second],
		"plain Disable retires nothing")
end

do
	local world = native(true)
	world:addTab(4, 11)
	world:advance(3100)
	local first = world.opens[1].pane
	world:switch(4); world:advance(3100)
	local second = world.opens[2].pane
	assert(world.canvases[first] and world.canvases[second], "fixture: two mounted rails")
	world:command("disable-and-close-rails")
	local closed = copy(world.closes)
	table.sort(closed)
	assert(not world.prefs.enabled and equalValue(closed, { first, second }) and not world.canvases[first]
		and not world.canvases[second], "Disable and close rails disables and retires every rail pane")
	assert(world.membership[10] == 3 and world.membership[11] == 4 and world:activeTimers() == 0
		and world.settingsWrites == 0 and toastCount(world, "error", "") == 0,
		"content panes survive, no work stays scheduled, and no native setting is written")
	assert(world.prefs.instances["local"] == nil or next(world.prefs.instances["local"]) == nil,
		"each retired rail leaves the store")
end

-- LIFE-02 / LIFE-06: the conversation menu offers what the record supports, never Reopen, and says when a pane is
-- parked, floating or not in a tab; Open existing pane never unparks.
do
	local world, rail = workspaceWorld()
	world:click(rail, rowAction(renderedRowFor(world, rail, 11), "menu"))
	local active = menuLabels(world)
	assert(hasLabel(active, "Inspect recorded facts") and hasLabel(active, "Open existing pane")
		and not hasLabel(active, "Bring back") and not hasLabel(active, "Resume tracking") and not hasLabel(active, "Reopen"),
		"an active conversation offers inspect and open, but nothing to bring back or resume")
	chooseContaining(world, "Inspect recorded facts"); world:advance(100)
	assert(world:inspect().logical.expandedWorkId ~= nil and world.focusWrites == 0 and savedItemFor(world, 11).reviewRevision ~= nil,
		"Inspect expands the recorded facts without navigating or acknowledging")
	world:click(rail, rowAction(renderedRowFor(world, rail, 11), "menu")); world:chooseLabel("Keep as reference"); world:advance(100)
	-- A reference conversation is in no queue while idle; native execution adds it to Working, whose row carries
	-- the same menu.
	world.additionalAgents[11] = "working"
	world:emit("agent_state", { pane = 11, old = "idle", new = "working" }); world:advance(100)
	world:control(rail, "working"); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 11), "menu"))
	local reference = menuLabels(world)
	assert(hasLabel(reference, "Resume tracking · does not run agent") and hasLabel(reference, "Bring back now")
		and not hasLabel(reference, "Reopen"), "a reference conversation can be resumed or brought back")
	chooseContaining(world, "Open existing pane"); world:advance(100)
	assert(world.focused == 11 and savedItemFor(world, 11).disposition == "reference",
		"Open existing pane navigates without changing tracking")
	world:switch(3); world:advance(100)
	world:control(rail, "attention"); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "menu"))
	world:chooseLabel("Finished for now · current scope"); world:advance(100)
	world:control(rail, "workspace"); world:advance(100)
	world:click(rail, wsPart(world, rail, "tab:local#3", "menu"))
	local finished = menuLabels(world)
	assert(hasLabel(finished, "Bring back now") and hasLabel(finished, "Resume tracking") and not hasLabel(finished, "Reopen"),
		"a Finished conversation can be brought back")
	world:choose(nil)
end

for _, placement in ipairs({ "parked", "floating" }) do
	local world, rail = workspaceWorld()
	if placement == "parked" then world.parked[11] = true
	else world.floating[11], world.floats[4] = true, { { pane = 11, over = 13, corner = "top_right" } } end
	world:advance(3100)
	world:control(rail, "attention"); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 11), "menu"))
	local labels = menuLabels(world)
	assert(hasLabel(labels, if placement == "parked" then "parked, restore it from Parked panes" else "floating, shown without docking"),
		"the menu says the pane is " .. placement)
	local focusBefore, layoutBefore = world.focusWrites, world.layoutWrites
	chooseContaining(world, "Open existing pane"); world:advance(100)
	if placement == "parked" then
		assert(world.focusWrites == focusBefore and world.parked[11] == true and world.actionRuns[1] == "parked_panes",
			"a parked conversation is restored through the native chooser, never unparked here")
	else
		assert(world.focused == 11 and world.floating[11] == true and world.layoutWrites == layoutBefore,
			"a floating conversation is focused without docking")
	end
	assert(savedItemFor(world, 11).reviewRevision ~= nil, "opening a pane never acknowledges")
end

-- Focus navigator never focuses a parked canvas; Enable here (D6) retires the old owner's pending actions.
do
	local world, rail = workspaceWorld()
	world:command("focus-navigator")
	assert(world.focused == rail, "Focus navigator focuses this tab's rail")
	world.focused = 10
	world.parked[rail] = true
	world:advance(100)
	local writes = world.focusWrites
	world:command("focus-navigator")
	assert(world.focusWrites == writes and toastCount(world, "info", "parked") >= 1, "a parked rail is reported, never focused")
end

do
	local world, rail = workspaceWorld()
	world:control(rail, "workspace"); world:advance(100)
	local note = wsPart(world, rail, "tab:local#5", "open")
	world:control(rail, "search")
	local index = pickerIndex(world, "pane:local#12")
	local writes = { world.layoutWrites, world.focusWrites, world.preferenceWrites, world.triageWrites }
	world.prefs.owner = "other"
	world:click(rail, note); world:advance(5000)
	assert(world.layoutWrites == writes[1] and world.focusWrites == writes[2] and world.preferenceWrites == writes[3]
		and world.triageWrites == writes[4], "a window that lost ownership neither navigates, arranges nor saves anything")
	assert(toastCount(world, "error", "Enable here") >= 1, "its stale control explains where ownership went")
	world:command("enable"); world:advance(100)
	world:choose(index); world:advance(100)
	assert(world.focusWrites == writes[2] and world.settingsWrites == 0,
		"taking ownership back does not revive the old owner's pending picker")
	world:click(rail, note); world:advance(100)
	assert(world.focusWrites == writes[2], "nor its old control tokens")
end

-- NAT-05: disabling claims no unload fiction, and the disabled banner is painted only where the canvas is reachable.
do
	local world, rail = workspaceWorld()
	local before = copy(world.canvases[rail].view)
	world.failCanvasList = true
	world:command("disable")
	world.failCanvasList = false
	assert(world.prefs.enabled == false, "disabling does not depend on reaching the canvas")
	assert(toastCount(world, "error", "could not be repainted") == 1, "the unreachable canvas is reported")
	assert(equalValue(world.canvases[rail].view, before), "no disabled banner is claimed on a canvas that could not be reached")
	assert(world.settingsWrites == 0, "no native setting is written")
end
-- Currently working is shared, persisted navigation over live state, independent of triage and Next.
do
	local world = native(true, nil, "bottom")
	world.agentState, world.agentAlert = "idle", true
	world:addTab(4, 11, 1, 7)
	world.additionalAgents = { [11] = "waiting_input" }
	world:advance(3100)
	local rail = world.opens[1].pane
	world:emit("agent_finished", { pane = 10, result = "done" }); world:advance(100)
	local revision = savedItemFor(world, 10).reviewRevision
	assert(revision ~= nil, "the working fixture begins with an unread completion")
	world.agentState = "working"
	world:emit("agent_state", { pane = 10, old = "idle", new = "working" }); world:advance(100)
	world:control(rail, "working"); world:advance(100)
	local state = world:inspect()
	local rows = sectionRows(world, rail).c
	assert(state.logical.section == "working" and state.workingCount == 1 and state.attentionCount == 1
		and #rows == 1 and rows[1] == renderedRowFor(world, rail, 10), "only the live working conversation is shown")
	assert(queueCount(world, rail, "working") == "1" and visibleText(headerPart(world, rail, "location")) == "")
	local queues = headerPart(world, rail, "queues")
	assert(queues.c[1].p.key == "attention" and queues.c[2].p.key == "working" and queues.c[3].p.key == "workspace"
		and #queues.c == 3, "mode order is stable and Workspace stays last")
	local open = rowAction(rows[1], "route-open")
	assert(open and rowAction(rows[1], "details") and rowAction(rows[1], "menu"), "working retains all three row actions")
	world.focused = rail
	world:click(rail, open); world:advance(100)
	assert(world.focused == 10 and savedItemFor(world, 10).reviewRevision == revision,
		"opening Working never acknowledges the retained review")
	world.focused = rail
	world:command("next"); world:advance(100)
	assert(world.focused == 11 and savedItemFor(world, 10).reviewRevision == revision,
		"Working open does not consume or redirect the Next attention target")
	world:switch(3); world:advance(100)
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "menu"))
	world:chooseLabel("Finished for now · current scope"); world:advance(100)
	assert(world:inspect().workingCount == 1 and savedItemFor(world, 10).disposition == "finished",
		"live finished work remains in Working while it executes")
	local snapshot = world:phoneSnapshot()
	local working = nil
	for _, published in ipairs(snapshot.rows) do
		if published.serial == savedItemFor(world, 10).serial and published.section == "working" then working = published end
	end
	assert(snapshot.schema == 2 and snapshot.counts.working == 1 and working,
		"owner publishes the live finished work in Working")
	world:click(rail, rowAction(renderedRowFor(world, rail, 10), "details")); world:advance(100)
	assert(world:inspect().logical.expandedWorkId ~= nil, "working details expand")
	local focusBefore = world.focusWrites
	assert(world.prefs.uiByWindow.desktop.section == "working", "the selected Working mode is saved")
	world:reload(); world:advance(3100)
	assert(world:inspect().logical.section == "working" and world:inspect().logical.expandedWorkId == nil
		and world.focusWrites == focusBefore and world.prefs.defaults.position == "bottom", "reload restores Working without actions or placement changes")
	world.agentState = "waiting_input"
	world:emit("agent_state", { pane = 10, old = "working", new = "waiting_input" }); world:advance(100)
	state = world:inspect()
	assert(state.workingCount == 0 and state.attentionCount == 1
		and savedItemFor(world, 10).disposition == "finished", "a new native request does not reactivate Finished work")
	assert(#sectionRows(world, rail).c == 0
		and nativeCanvas.childAt(world.canvases[rail].view, "empty").p.hidden, "Working becomes cleanly empty")
	assert(world:phoneSnapshot().counts.working == 0 and world:phoneSnapshot().counts.attention == 1)
end

-- Manual reorder from the ⋯ menus: a tab row's menu moves the tab (natively, one order_tab call with a readback)
-- or its session (Attention's own order); a queue head's menu moves the queue. Only moves that change the order
-- are offered, the order persists across reloads, and a target that changed before the choice refuses.
local function nodeByKey(node, key)
	if node.p and node.p.key == key then return node end
	for _, child in node.c or {} do
		local found = nodeByKey(child, key)
		if found then return found end
	end
	return nil
end
local function rowMenu(world, rail, rowKey)
	local row = assert(nodeByKey(world.canvases[rail].view, rowKey), "row is painted: " .. rowKey)
	return assert(keyedAction(row, "menu"), "row carries its ⋯ menu: " .. rowKey)
end
local function pickerLabels(world)
	local labels = {}
	for _, item in ipairs(world.pickers[#world.pickers].options.items) do table.insert(labels, item.label) end
	return labels
end
local function hasLabel(labels, label) return table.find(labels, label) ~= nil end
local function errorToasts(world)
	local count = 0
	for _, toast in world.toasts do if toast.kind == "error" then count += 1 end end
	return count
end

do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	world:addTab(41, 201, 1, 2)
	world:addTab(42, 202, 1, 2)
	world.tabs[3].position, world.tabs[41].position, world.tabs[42].position = 1, 2, 3
	world:advance(2100)
	world:control(rail, "workspace"); world:advance(100)
	world:openSessions(rail)
	world:click(rail, rowMenu(world, rail, "tab_3alocal_2342")); world:advance(32)
	local labels = pickerLabels(world)
	assert(hasLabel(labels, "Move tab up") and hasLabel(labels, "Move tab to top")
		and not hasLabel(labels, "Move tab down") and not hasLabel(labels, "Move tab to bottom"),
		"the last tab offers only the moves that change the order")
	world:chooseLabel("Move tab to top"); world:advance(100)
	assert(#world.orders == 1 and world.orders[1].tab == 42 and world.orders[1].position == 1,
		"Move tab to top makes exactly one native order_tab call at position one")
	assert(errorToasts(world) == 0, "a menu move reports no error")
	assert(world.tabs[42].position == 1 and world.tabs[3].position == 2 and world.tabs[41].position == 3,
		"native re-denses the session's positions")
	-- The ledger shows the new native order, the same one the native sidebar holds.
	local order = {}
	for _, block in ipairs(sectionRows(world, rail, "workspace").c) do
		if block.p.role == "workspace.ledger-current" or block.p.role == "workspace.ledger" then
			for _, row in ipairs(nativeCanvas.childAt(block, "rows").c or {}) do
				table.insert(order, row.p.key)
			end
		end
	end
	assert(equalValue(order, { "tab_3alocal_2342", "tab_3alocal_233", "tab_3alocal_2341" }), "the ledger repaints in the native order")
	-- Move down from the middle lands one place later.
	world:click(rail, rowMenu(world, rail, "tab_3alocal_233")); world:advance(32)
	world:chooseLabel("Move tab down"); world:advance(100)
	assert(#world.orders == 2 and world.orders[2].tab == 3 and world.orders[2].position == 3,
		"Move tab down from the middle of three lands last")
	-- A tab that closes before the choice refuses rather than moving anything.
	world:click(rail, rowMenu(world, rail, "tab_3alocal_2341")); world:advance(32)
	world:closePane(201); world:advance(100)
	world:chooseLabel("Move tab up"); world:advance(100)
	assert(#world.orders == 2, "a vanished target never calls order_tab")
end

do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	world:addTab(41, 201, 1, 7)
	world:advance(2100)
	world:control(rail, "workspace"); world:advance(100)
	world:openSessions(rail)
	world:click(rail, rowMenu(world, rail, "tab_3alocal_2341")); world:advance(32)
	local labels = pickerLabels(world)
	assert(hasLabel(labels, "Move session up") and not hasLabel(labels, "Move session down")
		and not hasLabel(labels, "Move session to top"), "the last of two sessions offers only Move session up")
	world:chooseLabel("Move session up"); world:advance(100)
	assert(equalValue(world.prefs.sessionOrder, { ["local"] = { 7, 2 } }),
		"the session move persists the host's full session order")
	local function blocks()
		local keys = {}
		for _, block in ipairs(sectionRows(world, rail, "workspace").c) do
			if block.p.role == "workspace.ledger-current" or block.p.role == "workspace.ledger" then
				table.insert(keys, block.p.key)
			end
		end
		return keys
	end
	assert(equalValue(blocks(), { "session_3alocal_237", "session_3alocal_232" }), "the ledger follows the stored order")
	world:reload(); world:advance(3100)
	world:control(rail, "workspace"); world:advance(100)
	assert(equalValue(blocks(), { "session_3alocal_237", "session_3alocal_232" }), "reload restores the stored session order")
end

do
	local world = native(true)
	world:advance(3100)
	local rail = world.opens[1].pane
	world:click(rail, rowMenu(world, rail, "attention")); world:advance(32)
	local labels = pickerLabels(world)
	assert(equalValue(labels, { "Move down" }), "the first of two queues offers only Move down")
	world:chooseLabel("Move down"); world:advance(100)
	assert(errorToasts(world) == 0, "a queue move reports no error")
	assert(equalValue(world.prefs.queueOrder, { "working", "attention" }), "the queue move persists")
	local stack = descend(world.canvases[rail].view, "top", "stack")
	local sections = {}
	for _, section in ipairs(stack.c or {}) do table.insert(sections, section.p.key) end
	assert(equalValue(sections, { "working", "attention" }), "the stack repaints in the stored order")
end

return true
