local layout = require("../layout")

-- The reason a placement reports when the native minimum pane size limits it (a contract string).
local MINIMUM = "Pane sizes limited by the native minimum"

local function leaf(pane)
	return { pane = pane }
end

local function split(dir, ratio, a, b)
	return { split = dir, ratio = ratio, [1] = a, [2] = b }
end

local function copy(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = copy(item) end
	return result
end

local function same(actual, expected, label)
	assert(type(actual) == type(expected), label .. ": different types")
	if type(expected) ~= "table" then
		assert(actual == expected, label .. ": different values")
		return
	end
	for key, value in expected do same(actual[key], value, label .. "." .. tostring(key)) end
	for key in actual do assert(expected[key] ~= nil, label .. ": unexpected field " .. tostring(key)) end
end

local function near(actual, expected, tolerance, label)
	assert(type(actual) == "number" and math.abs(actual - expected) <= tolerance, label)
end

local function has(tree, pane)
	return tree ~= nil and (tree.pane == pane or (tree.pane == nil and (has(tree[1], pane) or has(tree[2], pane))))
end

-- This fake implements leaf-level native edits, not the desired root wrapper.
-- Reads return copies: mutating a readback cannot change native arrangement.
local function native(tabs, focused, options)
	local world = { tabs = copy(tabs), focused = focused, parked = {}, closed = {}, writes = 0, focusChanges = 0,
		width = 240, height = 120, minCells = 4 }
	for key, value in options or {} do world[key] = value end
	local scratch = if world.float32Ratios then buffer.create(4) else nil
	local function ratioNumber(value)
		if not scratch then return value end
		buffer.writef32(scratch, 0, value)
		return buffer.readf32(scratch, 0)
	end
	local session, arrangement = {}, {}
	local cx = { session = session, layout = arrangement }
	local function locate(pane)
		for id, tab in world.tabs do
			if has(tab.root, pane) then return id, false end
			for _, float in tab.floats do if float.pane == pane then return id, true end end
		end
		return nil, false
	end
	local function remove(tree, pane)
		if not tree then return nil end
		if tree.pane then return if tree.pane == pane then nil else tree end
		tree[1], tree[2] = remove(tree[1], pane), remove(tree[2], pane)
		if not tree[1] then return tree[2] end
		if not tree[2] then return tree[1] end
		return tree
	end
	local function detach(pane)
		local id, floating = locate(pane)
		if id then
			local tab = world.tabs[id]
			if floating then
				for index, float in tab.floats do
					if float.pane == pane then table.remove(tab.floats, index); break end
				end
			else
				tab.root = remove(tab.root, pane)
			end
			if not tab.root and #tab.floats == 0 then world.tabs[id] = nil end
		end
		world.parked[pane] = nil
	end
	local function insert(tree, pane, target, dir)
		if tree.pane then
			if tree.pane ~= target then return tree end
			local before = dir == "left" or dir == "up"
			return split(if dir == "left" or dir == "right" then "right" else "down", 0.5,
				if before then leaf(pane) else tree, if before then tree else leaf(pane))
		end
		tree[1], tree[2] = insert(tree[1], pane, target, dir), insert(tree[2], pane, target, dir)
		return tree
	end
	local function reveal(pane, opts)
		if opts == nil or opts.focus ~= false then
			if world.focused ~= pane then world.focusChanges += 1 end
			world.focused = pane
			local id = locate(pane)
			if id then world.tabs[id].focus = pane end
		end
	end
	-- With `minimum = { right = columns, down = rows }` the fake keeps every pane at or above that size, as native
	-- does: after each write it clamps every divider, parent first, so both sides keep their minimum demand.
	local function demand(tree, axis)
		if tree.pane then return 1 end
		local first, second = demand(tree[1], axis), demand(tree[2], axis)
		if tree.split == axis then return first + second end
		return math.max(first, second)
	end
	local function reflow(tab)
		if not world.minimum or not tab.root then return end
		local function walk(tree, width, height)
			if tree.pane then return end
			local extent = if tree.split == "right" then width else height
			local least = world.minimum[tree.split]
			local first, second = demand(tree[1], tree.split) * least, demand(tree[2], tree.split) * least
			if first + second <= extent then
				tree.ratio = ratioNumber(math.min(math.max(tree.ratio, first / extent), 1 - second / extent))
			end
			walk(tree[1], if tree.split == "right" then width * tree.ratio else width,
				if tree.split == "down" then height * tree.ratio else height)
			walk(tree[2], if tree.split == "right" then width * (1 - tree.ratio) else width,
				if tree.split == "down" then height * (1 - tree.ratio) else height)
		end
		walk(tab.root, world.width, world.height)
	end
	for _, tab in world.tabs do reflow(tab) end
	function session:layout(tab) return copy(world.tabs[tab]) end
	function session:focused() return world.focused end
	function session:tab_of(pane) return (locate(pane)) end
	function session:pane(pane)
		local id, floating = locate(pane)
		if not id and not world.parked[pane] then return nil end
		return { pane = pane, tab = id, floating = floating, parked = world.parked[pane] == true,
			focused = pane == world.focused, kind = if pane == 90 then "canvas" else "terminal", title = tostring(pane) }
	end
	function session:panes()
		local found, result = {}, {}
		local function walk(tree)
			if not tree then return end
			if tree.pane then found[tree.pane] = true else walk(tree[1]); walk(tree[2]) end
		end
		for _, tab in world.tabs do
			walk(tab.root)
			for _, float in tab.floats do found[float.pane] = true end
		end
		for pane in world.parked do found[pane] = true end
		for pane in found do table.insert(result, self:pane(pane)) end
		return result
	end
	function session:tabs()
		local result = {}
		for id, tab in world.tabs do table.insert(result, { id = id, pane = tab.focus, session = tab.session or 1 }) end
		return result
	end
	function arrangement:move(pane, target, dir, opts)
		local destination = locate(target)
		if pane == target or not session:pane(pane) or not destination or not has(world.tabs[destination].root, target) then return false end
		assert(dir == "left" or dir == "right" or dir == "up" or dir == "down", "fake supports native directional moves only")
		world.writes += 1
		detach(pane)
		world.tabs[destination].root = insert(world.tabs[destination].root, pane, target, dir)
		reflow(world.tabs[destination])
		reveal(pane, opts)
		return true
	end
	function arrangement:resize(pane, dir, cells)
		assert(cells == math.round(cells), "Native resize takes whole cells")
		world.writes += 1
		local id = locate(pane)
		if not id then return false end
		local axis = if dir == "left" or dir == "right" then "right" else "down"
		local sign = if dir == "right" or dir == "down" then 1 else -1
		local candidate, extent
		local function walk(tree, width, height)
			if tree.pane then return end
			local branch = if has(tree[1], pane) then 1 else 2
			local span = if tree.split == "right" then width else height
			if tree.split == axis then candidate, extent = tree, span end
			local fraction = if branch == 1 then tree.ratio else 1 - tree.ratio
			walk(tree[branch], if tree.split == "right" then width * fraction else width,
				if tree.split == "down" then height * fraction else height)
		end
		walk(world.tabs[id].root, world.width, world.height)
		if not candidate then return false end
		local minimum = if world.minimum then 0.0001 else math.min(0.49, world.minCells / extent)
		local delta = ratioNumber(sign * cells / extent)
		local ratio = ratioNumber(math.clamp(ratioNumber(candidate.ratio + delta), minimum, 1 - minimum))
		local changed = math.abs(ratio - candidate.ratio) > 0.0000001
		candidate.ratio = ratio
		if world.minimum then
			reflow(world.tabs[id])
			return true
		end
		return changed
	end
	function arrangement:focus(pane) world.writes += 1; reveal(pane, nil) end
	function arrangement:close(pane)
		world.writes += 1
		world.closed[pane] = true
		detach(pane)
	end
	function arrangement:park(pane)
		if not session:pane(pane) then return false, "Unknown pane" end
		world.writes += 1
		detach(pane)
		world.parked[pane] = true
		return true
	end
	function arrangement:even(_tab) error("Equalizing user content is forbidden") end
	function arrangement:restore(_snapshot) error("Broad restoration over live user arrangement is forbidden") end
	return cx, world
end

local function tab(id, root, focus, floats)
	return { tab = id, root = root, focus = focus, floats = floats or {}, zoomed = false }
end

local EDGES = { "left", "down", "right" }
-- Every scenario below runs once per edge; helpers read the edge under test from here.
local edge = "left"

local function axis(forEdge)
	return if forEdge == "down" then "down" else "right"
end

local function request(target, destination, share, generation)
	return { pane = 90, target = target, tab = destination, edge = edge, share = share or 0.25, now = 0, generation = generation or 1 }
end

local function content()
	return split("right", 0.63, leaf(11),
		split("down", 0.38, split("right", 0.42, leaf(12), leaf(13)), leaf(14)))
end

-- The canonical outer rail (default: pane 90) holding `share` of the tab, wrapping unchanged content.
local function attach(inner, share, forEdge, rail)
	forEdge = forEdge or edge
	if forEdge == "left" then return split("right", share, leaf(rail or 90), inner) end
	return split(axis(forEdge), 1 - share, inner, leaf(rail or 90))
end

local function innerOf(root)
	return root[if edge == "left" then 2 else 1]
end

local function setInner(root, value)
	root[if edge == "left" then 2 else 1] = value
end

local function observedShare(root)
	return if edge == "left" then root.ratio else 1 - root.ratio
end

-- What a native open with {target, dir = edge} produces: the rail splits off that leaf only.
local function opened(tree, target, share)
	if tree.pane then
		if tree.pane ~= target then return tree end
		return attach(tree, share or 0.25)
	end
	return split(tree.split, tree.ratio, opened(tree[1], target, share), opened(tree[2], target, share))
end

local function assertTree(actual, expected, width, height, label)
	assert(actual ~= nil, label .. ": missing tree")
	if expected.pane then
		assert(actual.pane == expected.pane and actual.split == nil, label .. ": wrong leaf")
		return
	end
	assert(actual.pane == nil and actual.split == expected.split, label .. ": changed split direction")
	local extent = if expected.split == "right" then width else height
	near(actual.ratio, expected.ratio, 1.01 / extent, label .. ": changed relative ratio by more than one cell")
	for index = 1, 2 do
		local fraction = if index == 1 then actual.ratio else 1 - actual.ratio
		assertTree(actual[index], expected[index], if actual.split == "right" then width * fraction else width,
			if actual.split == "down" then height * fraction else height, label .. "." .. tostring(index))
	end
end

local function safety(world, focused)
	assert(world.focused == focused and world.focusChanges == 0, "Background layout must never steal typing focus, even temporarily")
	assert(next(world.closed) == nil, "Reconstruction must not close any pane")
end

local function settle(state, cx, world, intent)
	local focused = world.focused
	local result
	for step = 1, 160 do
		intent.now += 32
		local writes = world.writes
		result = layout.reconcile(state, cx, intent)
		assert(world.writes - writes <= 4, "Each resumed callback must retain the native operation bound")
		assert(type(result) == "table" and type(result.again) == "boolean", "Reconcile must expose bounded continuation")
		safety(world, focused)
		if not result.again then
			assert(not result.settled or result.edge == intent.edge, "A settled placement reports the edge it settled on")
			return result
		end
	end
	error("Layout did not terminate within bounded reconciliation callbacks")
end

local function assertRail(world, destination, expected, share, forEdge)
	assertTree(world.tabs[destination].root, attach(expected, share, forEdge), world.width, world.height, "outer rail")
end

-- A placement pass issues up to four native operations, so a multi-step reconstruction needs fewer passes; the bound
-- is on operations per pass, never more.
for _, wanted in EDGES do
	edge = wanted
	local original = content()
	local cx, world = native({ [1] = tab(1, opened(original, 14), 14) }, 14)
	local state, intent = layout.new({ tab = 1, root = original }), request(14, 1)
	local most, passes, result = 0, 0, nil
	for _ = 1, 160 do
		intent.now += 32
		local writes = world.writes
		result = layout.reconcile(state, cx, intent)
		most, passes = math.max(most, world.writes - writes), passes + 1
		assert(world.writes - writes <= 4, wanted .. ": a pass never exceeds four native operations")
		if not result.again then break end
	end
	assert(result ~= nil and not result.again and result.settled, wanted .. ": the multi-step placement settles within 160 passes")
	assert(most > 2 and most <= 4, wanted .. ": a pass uses more than the old two-operation batch")
	assertRail(world, 1, original, 0.25)
end

-- Pure helpers preserve their inputs and collapse only the removed leaf's parent.
do
	local original = split("down", 0.27, leaf(20), split("right", 0.71, content(), leaf(90)))
	local before = copy(original)
	same(layout.strip(original, 90), split("down", 0.27, leaf(20), content()), "strip nested rail")
	same(original, before, "strip is immutable")
	same(layout.strip(original, 999), before, "strip absent pane")
	assert(layout.strip(leaf(90), 90) == nil, "Only rail means no content")
	assert(layout.strip(nil, 90) == nil, "Empty tree has no content")
	assert(not layout.isRail(attach(content(), 0.25, "left"), 90, "up"), "An unknown edge is never a rail")
	assert(not layout.isRail(attach(content(), 0.25, "left"), 90, nil), "A missing edge is never a rail")
	for _, wanted in EDGES do
		local wrapped = attach(content(), 0.25, wanted)
		assert(layout.isRail(wrapped, 90, wanted), wanted .. " wrapper is a " .. wanted .. " rail")
		assert(layout.edgeOf(wrapped, 90) == wanted, wanted .. " wrapper reports its edge")
		assert(layout.edgeOf(wrapped, 11) == nil and layout.edgeOf(wrapped, 999) == nil,
			"Only the rail pane itself occupies an edge")
		for _, other in EDGES do
			if other ~= wanted then assert(not layout.isRail(wrapped, 90, other), wanted .. " wrapper is not a " .. other .. " rail") end
		end
		assert(not layout.isRail(original, 90, wanted), "Nested right leaf is not an outer " .. wanted .. " rail")
		assert(not layout.isRail(leaf(90), 90, wanted), "Lone rail is not a content wrapper")
		assert(not layout.isRail(nil, 90, wanted), "Missing tree is not a rail")
	end
	for name, tree in {
		["top rail"] = split("down", 0.25, leaf(90), content()),
		["nested right rail"] = original,
		["lone rail"] = leaf(90),
		["no rail pane"] = split("right", 0.25, leaf(11), content()),
		["rail among floats only"] = leaf(11),
		["rail inside a nested split"] = split("down", 0.4, attach(content(), 0.25, "left"), leaf(15)),
	} do
		assert(layout.edgeOf(tree, 90) == nil, name .. " is not a canonical edge")
	end
	assert(layout.edgeOf(nil, 90) == nil, "Missing tree has no edge")
end

-- A pre-open seed survives persistence before pane identity exists, on every edge.
for _, wanted in EDGES do
	edge = wanted
	local original = split("right", 0.31, leaf(11), leaf(12))
	local saved = copy(layout.checkpoint(layout.new({ tab = 7, root = original })))
	assert(saved.version == 4, "Checkpoints use version 4")
	local restored = assert(layout.restore(saved))
	local cx, world = native({ [7] = tab(7, attach(original, 0.5), 11) }, 11)
	assert(settle(restored, cx, world, request(11, 7)).settled, wanted .. ": pre-open seed survives persistence")
	assertRail(world, 7, original, 0.25)
	for _, corrupt in { "version", "owner", "tree", "cycle" } do
		local invalid = copy(saved)
		if corrupt == "version" then invalid.version = 99
		elseif corrupt == "owner" then invalid.tab = "another-tab"
		elseif corrupt == "tree" then invalid.seed.root.second.pane = 11
		else invalid.loop = invalid end
		local state, reason = layout.restore(invalid)
		assert(state == nil and type(reason) == "string", "Invalid " .. corrupt .. " checkpoint must be rejected explicitly")
	end
end

do
	local deep = leaf(1)
	for pane = 2, 67 do deep = split("right", 0.5, deep, leaf(pane)) end
	local exported = pcall(layout.checkpoint, layout.new({ tab = 7, root = deep }))
	assert(not exported, "Before-write checkpoint export cannot accept a tree restore would reject")
end

-- Checkpoint version 3 carries the edge: in-flight and settled records round-trip on every edge.
for _, wanted in EDGES do
	edge = wanted
	local original = content()
	local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
	local cx, world = native({ [1] = tab(1, opened(original, 11), 31, floats) }, 31)
	local state = layout.new({ tab = 1, root = original, floats = floats })
	local intent = request(31, 1)
	assert(layout.reconcile(state, cx, intent).again, wanted .. ": reconstruction is in flight")
	local saved = copy(layout.checkpoint(state))
	assert(saved.version == 4 and saved.job ~= nil and saved.job.edge == wanted, wanted .. ": in-flight checkpoint carries its edge")
	local restored = assert(layout.restore(saved))
	assert(settle(restored, cx, world, intent).settled, wanted .. ": restored job completes")
	assert(layout.edgeOf(world.tabs[1].root, 90) == wanted, wanted .. ": restored job finished on its edge")
	assertRail(world, 1, original, 0.25)
	local done = copy(layout.checkpoint(restored))
	assert(done.version == 4 and done.job == nil and done.completed.settled and done.completed.edge == wanted,
		wanted .. ": settled checkpoint carries its edge")
	local replayed = assert(layout.restore(done))
	local writes = world.writes
	local again = layout.reconcile(replayed, cx, intent)
	assert(again.settled and again.edge == wanted and not again.changed and not again.again and world.writes == writes,
		wanted .. ": a restored completion replays its edge without writing")

	-- Malformed, older, and foreign-edge checkpoints are rejected by name, never replayed.
	for _, version in { 1, 2, 3 } do
		local old = copy(saved)
		old.version = version
		local rejected, reason = layout.restore(old)
		assert(rejected == nil and type(reason) == "string" and string.find(reason, "version " .. version, 1, true),
			"Version " .. version .. " is rejected with its version named")
	end
	local unversioned = copy(saved)
	unversioned.version = nil
	local rejected, reason = layout.restore(unversioned)
	assert(rejected == nil and type(reason) == "string" and string.find(reason, "version", 1, true), "A missing version is rejected by name")
	rejected, reason = layout.restore(7)
	assert(rejected == nil and type(reason) == "string", "A non-record checkpoint is rejected")
	for _, bad in { "up", "top", 3, false } do
		local foreign = copy(saved)
		foreign.job.edge = bad
		rejected, reason = layout.restore(foreign)
		assert(rejected == nil and type(reason) == "string", "In-flight edge " .. tostring(bad) .. " is rejected")
		local completed = copy(done)
		completed.completed.edge = bad
		rejected, reason = layout.restore(completed)
		assert(rejected == nil and type(reason) == "string", "Settled edge " .. tostring(bad) .. " is rejected")
	end
	local missing = copy(saved)
	missing.job.edge = nil
	assert(layout.restore(missing) == nil, "An in-flight checkpoint without an edge is rejected")
	local noEdge = copy(done)
	noEdge.completed.edge = nil
	assert(layout.restore(noEdge) == nil, "A settled checkpoint without an edge is rejected")
	local badShare = copy(saved)
	badShare.job.share = 1.5
	assert(layout.restore(badShare) == nil, "An out-of-range share is rejected")
end

for _, scenario in { "temporary", "reload", "protected-divider" } do
	for _, wanted in EDGES do
		edge = wanted
		local outer = if edge == "left" then 0.2000000476837158 else 0.7999999523162842
		local share = if edge == "left" then outer else 1 - outer
		local function rooted(inner)
			if edge == "left" then return split("right", outer, leaf(90), inner) end
			return split(axis(edge), outer, inner, leaf(90))
		end
		local original = split("right", 0.6299999952316284,
			split("right", 0.3100000023841858, leaf(11), leaf(12)),
			split("right", 0.7200000286102295, leaf(13), leaf(14)))
		local current = split("right", 0.5, split("right", 0.5, leaf(11), leaf(12)),
			split("right", 0.5, leaf(13), leaf(14)))
		local cx, world = native({ [1] = tab(1, rooted(current), 14) }, 14, { float32Ratios = true })
		local state, saved = layout.new({ tab = 1, root = original }), nil
		local resize, injected = cx.layout.resize, false
		cx.layout.resize = function(self, pane, direction, cells)
			if not injected and pane == 11 and direction == "right" then
				same(world.tabs[1].root, rooted(
					split("right", 0.5, leaf(11), split("right", 0.5, split("right", 0.5, leaf(13), leaf(12)), leaf(14)))),
					wanted .. ": observed native pre-fit exposure")
				assert(cells == 1, "The first write on a divider is one measuring cell")
				if scenario == "reload" then saved = copy(layout.checkpoint(state)) end
				local accepted = resize(self, pane, direction, cells)
				-- Native normalizes the squeezed side's partition after the write (observed native value).
				innerOf(world.tabs[1].root)[2].ratio = 0.6666666865348816
				injected = true
				if scenario == "protected-divider" then world.tabs[1].root.ratio = 0.70 end
				if scenario == "reload" then coroutine.yield("native-fit-reload") end
				return accepted
			end
			return resize(self, pane, direction, cells)
		end
		local intent = request(14, 1, share)
		if scenario == "reload" then
			local thread = coroutine.create(function() settle(state, cx, world, intent) end)
			local ok, marker = coroutine.resume(thread)
			assert(ok and marker == "native-fit-reload" and saved)
			assert(coroutine.close(thread))
			state = assert(layout.restore(saved))
		end
		local result = settle(state, cx, world, intent)
		assert(injected, "Exercise the observed native target and temporary-partition normalization")
		if scenario == "protected-divider" then
			assert(not result.settled and not result.again, wanted .. ": a different final divider remains protected")
			local before, writes = copy(world.tabs), world.writes
			settle(state, cx, world, intent)
			same(world.tabs, before, "Cancelled fit cannot overwrite the protected divider")
			assert(world.writes == writes, "Protected-divider cancellation is terminal")
		else
			assert(result.settled, wanted .. ": target fit plus operation-owned temporary normalization must complete: " .. tostring(result.reason))
			assertRail(world, 1, original, share)
		end
	end
end

for _, wanted in EDGES do
	edge = wanted

	for _, edited in { false, true } do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local cx, world = native({ [1] = tab(1, split("right", 0.5, attach(leaf(11), 0.4), leaf(12)), 11) }, 11)
		local state = layout.new({ tab = 1, root = original })
		local move, calls = cx.layout.move, 0
		cx.layout.move = function(self, ...)
			calls += 1
			if calls == 2 then world.writes += 1; return false end
			return move(self, ...)
		end
		local failed = settle(state, cx, world, request(11, 1))
		assert(calls == 2 and not failed.settled and not failed.again, "Unchanged native refusal terminates after the accepted first move")
		state = assert(layout.restore(copy(layout.checkpoint(state))))
		cx.layout.move = move
		if edited then
			world.tabs[1].root.ratio = 0.64
			local before, writes = copy(world.tabs), world.writes
			local result = settle(state, cx, world, request(11, 1, 0.25, 2))
			assert(not result.settled and not result.again and world.writes == writes, "User edits invalidate original-content repair authority")
			same(world.tabs, before, "Failed reload recovery cannot overwrite subsequent user edits")
		else
			assert(settle(state, cx, world, request(11, 1, 0.25, 2)).settled, "Reload and explicit Reset retain original intent after unchanged move refusal")
			assertRail(world, 1, original, 0.25)
		end
	end

	-- When the native minimum refuses a content ratio the rail is still placed: the content keeps its panes,
	-- axes and order, and the placement settles degraded with the native-minimum reason.
	do
		local original = split("right", 0.63, split("right", 0.37, leaf(11), leaf(12)),
			split("right", 0.71, leaf(13), leaf(14)))
		local current = split("right", 0.5, original[1], original[2])
		local cx, world = native({ [1] = tab(1, attach(current, 0.25), 11) }, 11)
		local resize = cx.layout.resize
		cx.layout.resize = function(self, pane, direction, cells)
			if pane == 11 then world.writes += 1; return false end
			return resize(self, pane, direction, cells)
		end
		local result = settle(layout.new({ tab = 1, root = original }), cx, world, request(11, 1))
		assert(result.settled and result.degraded and result.reason == MINIMUM, "A refused content ratio settles degraded: " .. tostring(result.reason))
		assertRail(world, 1, split("right", 0.5, split("right", 0.5, leaf(11), leaf(12)), original[2]), 0.25)
	end

	for _, kind in { "move", "resize" } do
		local original = split("right", 0.63, split("right", 0.37, leaf(11), leaf(12)),
			split("right", 0.71, leaf(13), leaf(14)))
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 31, floats) }, 31)
		local state = layout.new({ tab = 1, root = original, floats = floats })
		local intent, saved = request(31, 1), nil
		local operation = cx.layout[kind]
		cx.layout[kind] = function(self, ...)
			saved = copy(layout.checkpoint(state))
			operation(self, ...)
			coroutine.yield("reload")
		end
		local thread = coroutine.create(function()
			for _ = 1, 30 do layout.reconcile(state, cx, intent) end
		end)
		local ok, marker = coroutine.resume(thread)
		assert(ok and marker == "reload" and saved, "Persist intent before the accepted native " .. kind)
		assert(coroutine.close(thread))
		cx.layout[kind] = operation
		local invalid = copy(saved)
		invalid.job.pending.index += 1
		assert(layout.restore(invalid) == nil, "Pending checkpoint cannot redirect the regenerated operation")
		local restored, reason = layout.restore(saved)
		assert(restored, tostring(reason))
		state = restored
		assert(settle(state, cx, world, intent).settled, "Reload recovers pending " .. kind .. " and original topology")
		assertRail(world, 1, original, 0.25)
		same(world.tabs[1].floats, floats, "Reload preserves float placement")
	end

	-- Canvas creation is leaf-local; first mount must reconstruct unequal content.
	do
		local original = content()
		local floats = { { pane = 31, over = 12, corner = "bottom-right" } }
		local cx, world = native({ [1] = tab(1, split("down", 0.61, attach(leaf(11), 0.5), original[2]), 31, floats) }, 31)
		world.parked[40] = true
		local state = layout.new({ tab = 1, root = original, floats = floats })
		local intent = request(31, 1)
		assert(settle(state, cx, world, intent).settled, "Unequal nested first mount must settle")
		assertRail(world, 1, original, 0.25)
		same(world.tabs[1].floats, floats, "First mount preserves focused float ownership")
		assert(world.parked[40], "Unrelated parked panes remain parked")
		local writes = world.writes
		world.tabs[1].root = split("down", 0.43, world.tabs[1].root, leaf(15))
		local manuallyEdited = copy(world.tabs)
		for _ = 1, 5 do
			local idle = settle(state, cx, world, intent)
			assert(idle.settled and not idle.changed, "Completed placement never enforces ready geometry")
		end
		assert(world.writes == writes, "Ready placement must not write after manual movement or splits")
		same(world.tabs, manuallyEdited, "Ready state preserves manual layout")
		assert(settle(state, cx, world, request(31, 1, 0.32, 2)).settled, "Explicit reset uses current content")
		assertRail(world, 1, split("down", 0.43, layout.strip(manuallyEdited[1].root[1], 90), leaf(15)), 0.32)
	end

	-- Native resize addresses the nearest same-axis ancestor, regardless of
	-- which child contains the pane. Balanced same-axis parents need exposure.
	for _, original in {
		split("right", 0.773367, split("right", 0.5118267, leaf(11), leaf(12)), leaf(13)),
		split("right", 0.63, split("right", 0.37, leaf(11), leaf(12)), split("right", 0.71, leaf(13), leaf(14))),
		split("down", 0.57, split("down", 0.41, leaf(11), leaf(12)), split("down", 0.68, leaf(13), leaf(14))),
	} do
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local nativeContent = copy(original)
		local function unfitted(node)
			if node.pane then return end
			node.ratio = 0.5
			unfitted(node[1])
			unfitted(node[2])
		end
		unfitted(nativeContent)
		local cx, world = native({ [1] = tab(1, attach(nativeContent, 0.5), 31, floats) }, 31)
		local state = layout.new({ tab = 1, root = original, floats = floats })
		assert(settle(state, cx, world, request(31, 1)).settled, "Same-axis nested parent remains sizeable")
		assertRail(world, 1, original, 0.25)
		same(world.tabs[1].floats, floats, "Temporary divider exposure preserves floats")
	end

	-- f32 half-cell readback must select the nearer endpoint, never oscillate.
	do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 13) }, 13,
			{ width = 256, height = 128, float32Ratios = true })
		local extent = if edge == "down" then world.height else world.width
		local share = (math.floor(0.21 * extent) + 0.5) / extent
		local state, intent = layout.new(), request(13, 1, share)
		local result = settle(state, cx, world, intent)
		assert(result.settled, "Half-cell target must settle: " .. tostring(result.reason))
		near(result.share, share, 0.500001 / extent, "Nearest attainable native size")
		assertRail(world, 1, original, share)
		local writes = world.writes
		settle(state, cx, world, intent)
		assert(world.writes == writes, "Settled f32 fit must remain idle")
	end

	do
		local original = split("right", 0.5008, leaf(11), leaf(12))
		local cx, world = native({ [1] = tab(1, attach(split("right", 0.5, leaf(11), leaf(12)), 0.25), 11) }, 11,
			{ width = 4000, height = 2000 })
		local result = settle(layout.new({ tab = 1, root = original }), cx, world, request(11, 1))
		assert(result.settled and not result.degraded, "Small ratio error on a large native extent still needs measurement")
		assertRail(world, 1, original, 0.25)
	end

	-- Native normalization on a temporary operation-owned divider is recoverable.
	do
		local original = split("right", 0.30, leaf(11), split("right", 0.50, leaf(12), leaf(13)))
		local cx, world = native({ [1] = tab(1, split("right", 0.30, attach(leaf(11), 0.5), original[2]), 13) }, 13)
		local state = layout.new({ tab = 1, root = original })
		local intent = request(13, 1)
		local batch = layout.BATCH
		layout.BATCH = 2
		local ran, interrupted = pcall(layout.reconcile, state, cx, intent)
		layout.BATCH = batch
		assert(ran, interrupted)
		assert(interrupted.again)
		local temporary = world.tabs[1].root[1]
		assert(temporary.split == axis(edge) and has(temporary, 90), "Exercise an operation-owned temporary divider")
		temporary.ratio = 0.5272987484931946
		assert(settle(state, cx, world, intent).settled, "Temporary native normalization must retain original intent")
		assertRail(world, 1, original, 0.25)
	end

	-- Growing the rail resizes it toward the content; shrinking uses the same direction with negative cells.
	for _, grow in { true, false } do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, if grow then 0.1 else 0.5), 13) }, 13)
		local resize, calls = cx.layout.resize, {}
		cx.layout.resize = function(self, pane, direction, cells)
			if pane == 90 then table.insert(calls, { direction = direction, cells = cells }) end
			return resize(self, pane, direction, cells)
		end
		assert(settle(layout.new(), cx, world, request(13, 1, 0.3)).settled, "Resizing a placed rail settles")
		assert(#calls > 0, "The rail divider is resized natively")
		assert(calls[1].direction == ({ left = "right", down = "up", right = "left" })[edge],
			"The rail is resized toward its content")
		assert(if grow then calls[1].cells > 0 else calls[1].cells < 0, "Growth is positive cells, shrinking is negative")
		assertRail(world, 1, original, 0.3)
	end

	-- Interrupted writes are reconciled from fresh same-tab readback.
	for _, interruption in { "between-batches", "before-move", "move", "resize" } do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local cx, world = native({ [1] = tab(1, split("right", 0.5, attach(leaf(11), 0.5), leaf(12)), 11, floats) }, 11)
		local state = layout.new({ tab = 1, root = original, floats = floats })
		local intent = request(11, 1)
		if interruption == "between-batches" then
			assert(layout.reconcile(state, cx, intent).again)
		else
			local kind = if interruption == "resize" then "resize" else "move"
			local operation = cx.layout[kind]
			cx.layout[kind] = function(self, ...)
				if interruption == "before-move" then coroutine.yield("hard budget") end
				local accepted = operation(self, ...)
				coroutine.yield("hard budget")
				return accepted
			end
			local thread = coroutine.create(function()
				for _ = 1, 20 do layout.reconcile(state, cx, intent) end
			end)
			local ok, marker = coroutine.resume(thread)
			assert(ok and marker == "hard budget", "Interrupt at the native mutation boundary")
			assert(coroutine.close(thread))
			cx.layout[kind] = operation
		end
		assert(settle(state, cx, world, intent).settled, interruption .. " resumes bounded same-tab placement")
		assertRail(world, 1, original, 0.25)
		same(world.tabs[1].floats, floats, "Interrupted placement preserves floats")
	end

	-- An uncertain accepted move cannot claim a subsequent user content edit.
	do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 11) }, 11)
		local state, intent = layout.new(), request(11, 1)
		local move, accepted = cx.layout.move, 0
		cx.layout.move = function(self, ...)
			local result = move(self, ...)
			accepted += 1
			if accepted == 2 then coroutine.yield("hard budget") end
			return result
		end
		-- Force reconstruction rather than adopting an outer rail.
		world.tabs[1].root = split("down", 0.30, attach(leaf(11), 0.5), leaf(12))
		local thread = coroutine.create(function() layout.reconcile(state, cx, intent) end)
		local ok, marker = coroutine.resume(thread)
		assert(ok and marker == "hard budget")
		assert(coroutine.close(thread))
		cx.layout.move = move
		innerOf(world.tabs[1].root).ratio = 0.62
		local before, writes = copy(world.tabs), world.writes
		local result = settle(state, cx, world, intent)
		assert(not result.settled and not result.again and result.reason, "User divider edit cancels uncertain recovery")
		same(world.tabs, before, "Recovery cannot overwrite a user divider")
		assert(world.writes == writes, "Cancelled recovery performs no writes")
	end

	-- External edits win, including races between a native write and its readback.
	for _, edit in { "divider", "float", "structure" } do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 31, floats) }, 31)
		local state, intent = layout.new(), request(31, 1)
		local resize, injected = cx.layout.resize, false
		cx.layout.resize = function(self, ...)
			local accepted = resize(self, ...)
			if not injected then
				assert(accepted)
				injected = true
				if edit == "divider" then innerOf(world.tabs[1].root).ratio = 0.64
				elseif edit == "float" then world.tabs[1].floats[1].over = 12
				else setInner(world.tabs[1].root, split("right", 0.61, innerOf(world.tabs[1].root), leaf(15))) end
			end
			return accepted
		end
		local result = settle(state, cx, world, intent)
		assert(injected and not result.settled and not result.again and result.reason,
			"External " .. edit .. " must cancel placement explicitly")
		local before, writes = copy(world.tabs), world.writes
		for _ = 1, 5 do
			local stopped = layout.reconcile(state, cx, intent)
			assert(not stopped.settled and not stopped.again, "Cancelled generation cannot replan")
		end
		same(world.tabs, before, "Cancellation leaves user edits untouched")
		assert(world.writes == writes, "Cancelled placement cannot keep writing")
		assert(settle(state, cx, world, request(31, 1, 0.25, 2)).settled, "Explicit later reset can recover")
		assertRail(world, 1, innerOf(before[1].root), 0.25)
		same(world.tabs[1].floats, before[1].floats, "Reset preserves latest floats")
	end

	-- Refusing a requested outer size must not skip the remaining content fits.
	for _, limit in { "minimum", "exhaustion" } do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local cx, world = native({ [1] = tab(1, attach(split("down", 0.5, leaf(11), leaf(12)), 0.5), 11) }, 11)
		local resize = cx.layout.resize
		cx.layout.resize = function(self, pane, direction, cells)
			if pane == 90 then
				world.writes += 1
				if limit == "exhaustion" then
					world.tabs[1].root.ratio += 0.0001
					return true
				end
				return false
			end
			return resize(self, pane, direction, cells)
		end
		local state = layout.new({ tab = 1, root = original })
		local intent = request(11, 1)
		local result = settle(state, cx, world, intent)
		assert(result.settled and result.degraded and result.reason, "Only outer-size limit may settle degraded")
		assertRail(world, 1, original, observedShare(world.tabs[1].root))
		assert(world.writes < 20, "Outer sizing exhaustion is finite and leaves budget for content repair")
		local writes = world.writes
		settle(state, cx, world, intent)
		assert(world.writes == writes, "Degraded settlement must not restart the failed outer fit")
	end

	do
		local cx, world = native({ [1] = tab(1, attach(leaf(11), 0.5), 11) }, 11,
			{ minCells = if edge == "down" then 36 else 72 })
		local result = settle(layout.new(), cx, world, request(11, 1))
		assert(result.settled and result.degraded, "Actual native minimum settles explicitly degraded")
		assertRail(world, 1, leaf(11), 0.30)
		near(result.share, 0.30, 0.000001, "Native minimum returns its attainable size")
	end

	-- A failed tab A operation cannot poison an independently pinned tab B state.
	do
		local original = split("down", 0.30, leaf(11), leaf(12))
		local cx, world = native({
			[1] = tab(1, split("right", 0.5, attach(leaf(11), 0.4), leaf(12)), 11),
			[2] = tab(2, split("right", 0.5, leaf(91), leaf(21)), 21),
		}, 11)
		local move, calls = cx.layout.move, 0
		cx.layout.move = function(self, ...)
			calls += 1
			if calls == 2 then world.writes += 1; return false end
			return move(self, ...)
		end
		local a = layout.new({ tab = 1, root = original })
		local failed = settle(a, cx, world, request(11, 1))
		assert(not failed.settled and not failed.again and not failed.degraded, "A refused reconstruction move is a terminal failure")
		local beforeA, writes = copy(world.tabs[1]), world.writes
		local bIntent = request(21, 2)
		bIntent.pane = 91
		local rejected = layout.reconcile(a, cx, bIntent)
		assert(not rejected.settled and not rejected.again and rejected.reason, "Pinned state rejects another tab")
		assert(world.writes == writes, "Pinned guard performs no old-tab repair")
		world.focused = 21
		local b = layout.new()
		assert(settle(b, cx, world, bIntent).settled, "Independent tab B succeeds despite retained tab A failure")
		assertTree(world.tabs[2].root, attach(leaf(21), 0.25, nil, 91), world.width, world.height, "Tab B rail")
		same(world.tabs[1], beforeA, "Tab B never mutates failed tab A")
	end

	-- Membership guards apply even to a brand-new unpinned state.
	do
		local cx, world = native({ [1] = tab(1, attach(leaf(11), 0.25), 11),
			[2] = tab(2, leaf(21), 21) }, 21)
		local before = copy(world.tabs)
		local result = layout.reconcile(layout.new(), cx, request(21, 2))
		assert(not result.settled and not result.again and result.reason, "Another tab's pane cannot be adopted")
		assert(world.writes == 0, "Membership guard never migrates a rail")
		same(world.tabs, before, "Membership guard preserves both tabs")
	end

	-- A newer explicit share waits for same-tab content reconstruction.
	do
		local original = content()
		local cx, world = native({ [1] = tab(1, opened(original, 11), 13) }, 13)
		local state = layout.new({ tab = 1, root = original })
		assert(layout.reconcile(state, cx, request(13, 1)).again)
		assert(settle(state, cx, world, request(13, 1, 0.33, 2)).settled, "New same-tab share completes boundedly")
		assertRail(world, 1, original, 0.33)
	end

	-- The rail becomes the outermost child on its edge of any content tree, preserving identities, order and ratios.
	for _, shape in {
		{ name = "single leaf", tree = leaf(11), target = 11 },
		{ name = "two leaves", tree = split("right", 0.31, leaf(11), leaf(12)), target = 12 },
		{ name = "nested right and down", tree = content(), target = 14 },
		{ name = "same-axis chain", tree = split("right", 0.2, leaf(11), split("right", 0.4, leaf(12), split("right", 0.7, leaf(13), leaf(14)))), target = 13 },
	} do
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local cx, world = native({ [1] = tab(1, opened(shape.tree, shape.target), 31, floats) }, 31)
		local state = layout.new({ tab = 1, root = shape.tree, floats = floats })
		assert(settle(state, cx, world, request(31, 1)).settled, shape.name .. " settles on the outer rail")
		assert(layout.isRail(world.tabs[1].root, 90, edge) and layout.edgeOf(world.tabs[1].root, 90) == edge,
			shape.name .. " has exactly the canonical root")
		assertRail(world, 1, shape.tree, 0.25)
		same(world.tabs[1].floats, floats, shape.name .. " preserves floats")
	end

	-- A rail that is already canonical on its edge is adopted in place: no moves, and resizing never relocates it.
	do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, 0.25), 13) }, 13)
		local result = settle(layout.new(), cx, world, request(13, 1))
		assert(result.settled and world.writes == 0, "A canonical rail is adopted without any native write")
		assert(layout.edgeOf(world.tabs[1].root, 90) == edge, "Adoption leaves the rail on its edge")
		world.tabs[1].root.ratio = if edge == "left" then 0.4 else 0.6
		local move, moves = cx.layout.move, 0
		cx.layout.move = function(self, ...) moves += 1; return move(self, ...) end
		assert(settle(layout.new(), cx, world, request(13, 1, 0.3)).settled, "A new share on a placed rail settles")
		assert(moves == 0, "Resizing a placed rail never moves it")
		assertRail(world, 1, original, 0.3)
	end

	-- Content beyond the bounded reconstruction budget keeps the native rail beside its first pane, unmodified.
	do
		local wide = leaf(11)
		for pane = 12, 28 do wide = split("right", 0.5, wide, leaf(pane)) end
		local cx, world = native({ [1] = tab(1, opened(wide, 11), 11) }, 11)
		local before, writes = copy(world.tabs), world.writes
		local state, intent = layout.new(), request(11, 1)
		local result = settle(state, cx, world, intent)
		assert(result.settled and result.degraded and type(result.reason) == "string", "Oversized content settles explicitly degraded")
		assert(settle(state, cx, world, intent).settled, "The degraded completion replays for the same request")
		assert(world.writes == writes, "Oversized content is never reconstructed")
		same(world.tabs, before, "Oversized content keeps its native arrangement")
	end

	-- The pre-insertion seed is immutable, but never overrides changed identities.
	for _, scenario in { "rearranged", "addition", "removal", "float-edit", "different-tab" } do
		local original = split("right", 0.31, leaf(11), leaf(12))
		local live = split("down", 0.42, leaf(12), leaf(11))
		local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
		local seed = { tab = if scenario == "different-tab" then 2 else 1, root = original, floats = copy(floats) }
		local state = layout.new(seed)
		seed.root = leaf(999)
		if scenario == "addition" then live = split("right", 0.61, live, leaf(15)) end
		if scenario == "removal" then live = leaf(11) end
		if scenario == "float-edit" then floats[1].over = 12 end
		local cx, world = native({ [1] = tab(1, attach(live, 0.3), 11, floats) }, 11)
		local result = settle(state, cx, world, request(11, 1))
		if scenario == "different-tab" then
			assert(not result.settled and not result.again and world.writes == 0, "Seed pins its tab before first request")
		else
			assert(result.settled, scenario .. " must preserve valid content")
			assertRail(world, 1, if scenario == "rearranged" then original else live, 0.25)
			same(world.tabs[1].floats, floats, scenario .. " preserves floats")
		end
	end

	for _, scenario in { "zoom", "missing-target", "missing-tab", "missing-rail", "no-content", "floating-rail", "parked-rail", "invalid-edge", "missing-edge", "invalid-share" } do
		local cx, world = native({ [1] = tab(1, attach(leaf(11), 0.25), 11) }, 11)
		local intent = request(11, 1)
		if scenario == "invalid-edge" then intent.edge = "up" end
		if scenario == "missing-edge" then intent.edge = nil end
		if scenario == "invalid-share" then intent.share = 1 end
		if scenario == "zoom" then world.tabs[1].zoomed = true end
		if scenario == "missing-target" then intent.target = 999 end
		if scenario == "missing-tab" then intent.tab = 999 end
		if scenario == "missing-rail" then world.tabs[1].root = leaf(11) end
		if scenario == "no-content" then world.tabs[1].root, intent.target = leaf(90), 90 end
		if scenario == "floating-rail" then
			world.tabs[1].root = leaf(11)
			world.tabs[1].floats = { { pane = 90, over = 11, corner = "top-right" } }
		end
		if scenario == "parked-rail" then world.tabs[1].root = leaf(11); world.parked[90] = true end
		local before, parked = copy(world.tabs), copy(world.parked)
		local result = settle(layout.new(), cx, world, intent)
		assert(type(result.reason) == "string" and not result.settled and not result.again, scenario .. " is explicit and finite")
		assert(world.writes == 0, scenario .. " must not mutate native layout")
		same(world.tabs, before, scenario .. " preserves native layout")
		same(world.parked, parked, scenario .. " preserves parked state")
	end
end

-- A placed rail moves between any two edges through the same engine; content identity, axes, order, ratios,
-- floats and focus are preserved.
for _, shape in {
	{ name = "single leaf", tree = leaf(11) },
	{ name = "two leaves", tree = split("right", 0.31, leaf(11), leaf(12)) },
	{ name = "nested right and down", tree = content() },
	{ name = "same-axis chain", tree = split("right", 0.2, leaf(11), split("right", 0.4, leaf(12), split("right", 0.7, leaf(13), leaf(14)))) },
} do
	for _, from in EDGES do
		for _, to in EDGES do
			if from ~= to then
				local label = shape.name .. " " .. from .. " -> " .. to
				local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
				local cx, world = native({ [1] = tab(1, attach(shape.tree, 0.3, from), 31, floats) }, 31)
				world.parked[40] = true
				edge = to
				local result = settle(layout.new(), cx, world, request(31, 1, 0.3))
				assert(result.settled and result.edge == to, label .. " settles on the new edge: " .. tostring(result.reason))
				near(result.share, 0.3, 1.01 / world.width, label .. " reports the observed share")
				assert(layout.edgeOf(world.tabs[1].root, 90) == to, label .. " ends on the new edge")
				assertRail(world, 1, shape.tree, 0.3, to)
				same(world.tabs[1].floats, floats, label .. " preserves floats")
				assert(world.tabs[1].focus == 31 and world.parked[40], label .. " preserves focus and parked panes")
			end
		end
	end
end

-- A newer explicit edge waits for same-tab reconstruction in flight, then moves the rail.
for _, from in EDGES do
	for _, to in EDGES do
		if from ~= to then
			local original = content()
			edge = from
			local cx, world = native({ [1] = tab(1, opened(original, 11), 13) }, 13)
			local state = layout.new({ tab = 1, root = original })
			assert(layout.reconcile(state, cx, request(13, 1)).again, "Reconstruction toward " .. from .. " is in flight")
			edge = to
			assert(settle(state, cx, world, request(13, 1, 0.25, 2)).settled, from .. " -> " .. to .. " completes boundedly")
			assert(layout.edgeOf(world.tabs[1].root, 90) == to, "The newest edge wins")
			assertRail(world, 1, original, 0.25)
		end
	end
end

-- Native minimum-size reflow follows the engine's own writes: the first readback after a move is clean, the next
-- shows the divider above the new pair rebalanced, and a resize can rebalance dividers inside the side it
-- squeezed. The remaining fits restore both; edits the engine did not cause still cancel the placement.
local function comb(first, second, third)
	return split("right", first, leaf(11), split("right", second, leaf(12), split("right", third, leaf(13), leaf(14))))
end

local function branches()
	return split("right", 0.65, split("down", 0.4, leaf(11), leaf(12)), split("down", 0.6, leaf(13), leaf(14)))
end

local function swapLeaves(tree, a, b)
	if tree.pane then
		if tree.pane == a then tree.pane = b elseif tree.pane == b then tree.pane = a end
		return
	end
	swapLeaves(tree[1], a, b)
	swapLeaves(tree[2], a, b)
end

local function reflowing(original, reflowRatio)
	local floats = { { pane = 31, over = 11, corner = "bottom-right" } }
	local cx, world = native({ [1] = tab(1, opened(original, 11), 31, floats) }, 31)
	world.reflowed = 0
	local move, read = cx.layout.move, cx.session.layout
	local armed
	local function parentOfPair(tree, parent, pane, target)
		for index = 1, 2 do
			local child = tree[index]
			if child.pane == nil and has(child, pane) and has(child, target) then
				return parentOfPair(child, tree, pane, target)
			end
		end
		return parent
	end
	cx.layout.move = function(self, pane, target, dir, opts)
		local accepted = move(self, pane, target, dir, opts)
		armed = { pane = pane, target = target, seen = false }
		return accepted
	end
	cx.session.layout = function(self, tabId)
		local view = read(self, tabId)
		if armed and armed.seen then
			local parent = parentOfPair(world.tabs[tabId].root, nil, armed.pane, armed.target)
			if parent and math.abs(parent.ratio - reflowRatio) > 0.0000001 then
				parent.ratio = reflowRatio
				world.reflowed += 1
				view = read(self, tabId)
			end
			armed = nil
		elseif armed then
			armed.seen = true
		end
		return view
	end
	return cx, world, layout.new({ tab = 1, root = original, floats = floats }), request(31, 1), floats
end

for _, wanted in EDGES do
	edge = wanted

	for _, original in { comb(0.5, 0.5, 0.5), comb(0.35, 0.6, 0.45), content() } do
		local cx, world, state, intent, floats = reflowing(original, 0.4153)
		local result = settle(state, cx, world, intent)
		assert(result.settled and not result.degraded, wanted .. ": native reflow after our own moves must not cancel placement")
		assert(world.reflowed >= 2, "The fake native really rebalanced dividers after moves")
		assertRail(world, 1, original, 0.25)
		same(world.tabs[1].floats, floats, "Reflow preserves floats")
	end

	-- A structural edit between steps is never mistaken for reflow.
	do
		local original = comb(0.5, 0.5, 0.5)
		local cx, world, state, intent = reflowing(original, 0.4153)
		assert(layout.reconcile(state, cx, intent).again)
		swapLeaves(world.tabs[1].root, 12, 13)
		local result = settle(state, cx, world, intent)
		assert(not result.settled and not result.again and result.reason, "Rearranged content cancels despite native reflow")
		local before, writes = copy(world.tabs), world.writes
		assert(not layout.reconcile(state, cx, intent).settled and world.writes == writes, "Cancelled placement stays cancelled")
		same(world.tabs, before, "Cancellation leaves the user's arrangement untouched")
	end

	-- A ratio edit on a divider the engine already fitted cancels; a squeezed-side reflow does not.
	for _, scenario in {
		{ name = "fitted divider", original = comb(0.65, 0.6, 0.4), edit = function(root) root.ratio = 0.6 end, cancels = true },
		{ name = "side not squeezed", original = branches(), edit = function(root) innerOf(root)[1].ratio = 0.9 end, cancels = true },
		{ name = "squeezed side", original = branches(), edit = function(root) innerOf(root)[2].ratio = 0.9 end, cancels = false },
		{ name = "squeezed chain", original = comb(0.65, 0.6, 0.4), edit = function(root)
			local inner = innerOf(root)
			inner[2].ratio, inner[2][2].ratio = 0.5272987484931946, 0.31
		end, cancels = false },
	} do
		local cx, world, state, intent = reflowing(scenario.original, 0.4153)
		local resize, injected = cx.layout.resize, false
		cx.layout.resize = function(self, pane, direction, cells)
			local accepted = resize(self, pane, direction, cells)
			if not injected and pane == 11 and direction == "right" then
				assert(accepted, "The first content fit is accepted")
				injected = true
				scenario.edit(world.tabs[1].root)
			end
			return accepted
		end
		local result = settle(state, cx, world, intent)
		assert(injected, scenario.name .. ": the edit was injected")
		if scenario.cancels then
			assert(not result.settled and not result.again and result.reason, wanted .. ": " .. scenario.name .. " edit cancels placement")
			local before, writes = copy(world.tabs), world.writes
			layout.reconcile(state, cx, intent)
			assert(world.writes == writes, scenario.name .. ": cancelled placement performs no writes")
			same(world.tabs, before, scenario.name .. ": cancellation leaves the edit")
		else
			assert(result.settled and not result.degraded, wanted .. ": " .. scenario.name .. " reflow is restored by its own fit")
			assertRail(world, 1, scenario.original, 0.25)
		end
	end
end

-- Native minimum pane size (about 93 px by 55 px: 10.6 columns by 2.7 rows of an 80 x 20 cell tab). Content ratios
-- or the requested rail size may be out of reach; the rail is still placed, whatever native cannot hold is reported
-- as `degraded`, and nothing ends failed with a sliver.
local MINIMUM_PANE = { right = 10.6, down = 2.7 }

local function structure(tree)
	if tree.pane then return tostring(tree.pane) end
	return tree.split .. "(" .. structure(tree[1]) .. "," .. structure(tree[2]) .. ")"
end

-- Five panes in a row, every pane just above the minimum on an 80-column tab (a native-clamped row).
local function five()
	return split("right", 0.461, leaf(11), split("right", 0.25, leaf(12),
		split("right", 0.333, leaf(13), split("right", 0.5, leaf(14), leaf(15)))))
end

local function grid()
	return split("right", 0.5, split("down", 0.5, leaf(11), leaf(12)), split("down", 0.5, leaf(13), leaf(14)))
end

local FLOATS = { { pane = 31, over = 11, corner = "bottom-right" } }

-- A tab as a native open leaves it (the rail split off the first pane), with the minimum enforced.
local function narrow(content, options)
	local settings = { width = 80, height = 20, minimum = MINIMUM_PANE }
	for key, value in options or {} do settings[key] = value end
	local cx, world = native({ [1] = tab(1, opened(content, 11, 0.25), 31, copy(FLOATS)) }, 31, settings)
	return cx, world, layout.new({ tab = 1, root = content, floats = copy(FLOATS) })
end

local function extentOf(world)
	return if edge == "down" then world.height else world.width
end

for _, wanted in EDGES do
	edge = wanted

	-- A row of five on every edge: identity, axes, order and floats intact, the rail near its requested size.
	do
		local cx, world, state = narrow(five())
		local result = settle(state, cx, world, request(31, 1, 0.25))
		assert(result.settled and not result.again, wanted .. ": a row at the native minimum is placed: " .. tostring(result.reason))
		assert(layout.edgeOf(world.tabs[1].root, 90) == wanted, wanted .. ": the rail is on its edge")
		assert(structure(innerOf(world.tabs[1].root)) == structure(five()), wanted .. ": content identity, axes and order are intact")
		same(world.tabs[1].floats, FLOATS, wanted .. ": floats are preserved")
		assert(result.share >= 0.2, wanted .. ": the rail is never a sliver: " .. tostring(result.share))
		near(result.share, 0.25, 1.01 / extentOf(world), wanted .. ": the rail is within a cell of its requested size")
		if wanted == "down" then
			-- A bottom rail never narrows the row, so every ratio survives.
			assertRail(world, 1, five(), result.share)
			assert(not result.degraded, "A bottom rail keeps every content ratio")
		else
			assert(result.degraded and result.reason == MINIMUM,
				wanted .. ": a narrowed row cannot keep its ratios and says so: " .. tostring(result.reason))
		end
	end

	-- A 2x2 grid keeps its ratios and its rail.
	do
		local cx, world, state = narrow(grid())
		local result = settle(state, cx, world, request(31, 1, 0.25))
		assert(result.settled and not result.degraded, wanted .. ": a 2x2 grid is placed without degrading: " .. tostring(result.reason))
		assertRail(world, 1, grid(), result.share)
		near(result.share, 0.25, 1.01 / extentOf(world), wanted .. ": a 2x2 rail is within a cell of its requested size")
		assert(world.writes < 30, wanted .. ": a small tab converges in few native writes: " .. world.writes)
	end

	-- A size beyond what the minimum allows places the rail at the largest size native keeps.
	do
		local cx, world, state = narrow(five(), { width = 70 })
		local requested = 0.4
		local limit = 1 - 5 * MINIMUM_PANE.right / world.width
		if wanted == "down" then requested, limit = 0.95, 1 - MINIMUM_PANE.down / world.height end
		local result = settle(state, cx, world, request(31, 1, requested))
		assert(result.settled and result.degraded and result.reason == MINIMUM,
			wanted .. ": an unreachable size settles degraded: " .. tostring(result.reason))
		near(result.share, limit, 1.01 / extentOf(world), wanted .. ": the rail takes the largest size native allows")
		assert(structure(innerOf(world.tabs[1].root)) == structure(five()), wanted .. ": content identity, axes and order are intact")
	end

	-- Native reflow never excuses a real edit: dragging the fitted rail divider cancels the placement.
	do
		local cx, world, state = narrow(five())
		local resize, injected = cx.layout.resize, false
		cx.layout.resize = function(self, pane, direction, cells)
			local accepted = resize(self, pane, direction, cells)
			if not injected and pane ~= 90 then
				injected = true
				world.tabs[1].root.ratio += 0.1
			end
			return accepted
		end
		local result = settle(state, cx, world, request(31, 1, 0.25))
		assert(injected and not result.settled and not result.again and result.reason,
			wanted .. ": an edit of the fitted rail divider cancels despite native reflow")
	end

	-- A coarse native cell never lets the nearest attainable size fall below the floor share.
	do
		local cx, world = native({ [1] = tab(1, attach(leaf(11), 0.5), 11) }, 11, { width = 13, height = 13, minCells = 1 })
		local result = settle(layout.new(), cx, world, request(11, 1, 0.205))
		assert(result.settled, wanted .. ": a coarse tab settles")
		assert(result.share >= 0.2, wanted .. ": the nearest cell below the floor is not taken: " .. tostring(result.share))
		assertRail(world, 1, leaf(11), result.share)
	end

	-- Native converts cells with the geometry it last drew, so equal requests move a divider by different amounts.
	-- Sizing stays closed-loop: it never throws a divider across its target into a native limit.
	for _, scales in { { 1, 0.4, 3, 0.6, 2.4, 1.1 }, { 1, 2.6, 0.5, 1.8, 0.7, 2.2, 1.3 } } do
		for _, rows in { 45, 90 } do
			local cx, world, state = narrow(grid(), { width = rows * 4, height = rows })
			local resize, calls = cx.layout.resize, 0
			cx.layout.resize = function(self, pane, direction, cells)
				calls += 1
				local scaled = math.round(cells * scales[(calls - 1) % #scales + 1])
				return resize(self, pane, direction, if scaled == 0 then (if cells > 0 then 1 else -1) else scaled)
			end
			local result = settle(state, cx, world, request(31, 1, 0.25))
			assert(result.settled and not result.degraded, wanted .. ": uneven native step sizes still settle cleanly: " .. tostring(result.reason))
			near(result.share, 0.25, 1.5 / extentOf(world), wanted .. ": the rail lands within a cell and a half of its requested size")
			assertRail(world, 1, grid(), result.share)
		end
	end

	-- Native's first write after a placement can move the divider several times the cells it asked for, because it
	-- converts with the geometry it last drew. Sizing measures that move and still lands the rail within a cell and a half.
	for _, stale in { 5, 6 } do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 13) }, 13)
		local resize, calls = cx.layout.resize, 0
		cx.layout.resize = function(self, pane, direction, cells)
			calls += 1
			return resize(self, pane, direction, if calls == 1 then cells * stale else cells)
		end
		local result = settle(layout.new(), cx, world, request(13, 1, 0.25))
		assert(result.settled and not result.degraded, wanted .. ": a stale first write settles cleanly: " .. tostring(result.reason))
		near(result.share, 0.25, 1.5 / extentOf(world), wanted .. ": a stale first write lands the rail within a cell and a half")
		assertRail(world, 1, original, result.share)
	end

	-- A stale first write can carry the divider past its target. Sizing corrects that rather than accepting the nearest
	-- attainable size it measured while stale, which here is about two cells away.
	do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, 0.262), 13) }, 13)
		local resize, calls = cx.layout.resize, 0
		cx.layout.resize = function(self, pane, direction, cells)
			calls += 1
			return resize(self, pane, direction, if calls == 1 then cells * 5 else cells)
		end
		local result = settle(layout.new(), cx, world, request(13, 1, 0.25))
		assert(result.settled and not result.degraded, wanted .. ": a stale overshoot settles cleanly: " .. tostring(result.reason))
		near(result.share, 0.25, 1.5 / extentOf(world), wanted .. ": a stale overshoot lands the rail within a cell and a half")
		assertRail(world, 1, original, result.share)
	end

	-- The first two writes after a placement can both measure geometry native has not drawn yet. Here the first moves the
	-- divider five times the cells it asked for and the second about 4.4 times, the pattern traced on a 700 px left edge.
	-- Sizing must not stop on those sizes: the third write measures the drawn geometry.
	do
		local original = content()
		local cx, world = native({ [1] = tab(1, attach(original, 0.5), 13) }, 13, { width = 80, height = 80 })
		local resize, calls = cx.layout.resize, 0
		cx.layout.resize = function(self, pane, direction, cells)
			calls += 1
			local factor = if calls == 1 then 5 elseif calls == 2 then 4.375 else 1
			return resize(self, pane, direction, math.round(cells * factor))
		end
		local result = settle(layout.new(), cx, world, request(13, 1, 0.25))
		assert(result.settled and not result.degraded, wanted .. ": two stale writes settle cleanly: " .. tostring(result.reason))
		near(result.share, 0.25, 1.5 / extentOf(world), wanted .. ": two stale writes land the rail within a cell and a half")
		assertRail(world, 1, original, result.share)
	end
end

return true
