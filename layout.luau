local layout = {}

-- Native operations one placement pass may issue: a tab the user is waiting on converges in few passes. A field,
-- so a test can shorten a pass to stop a job mid-flight.
layout.BATCH = 4
local FIT_LIMIT = 12
-- Measured cell sizes kept per divider; see cellRange.
local CELL_MEMORY = 6
-- Writes before a cell size may decide a stop or a bracket. Native measures from the geometry it last drew, and its first
-- two measurements have come from geometry not yet drawn: 16 and 18 cells against 75 to 100 on a 700 px left edge, and
-- 34 and 36 against about 145 on a 1280 px one.
local SETTLED_WRITES = 3
local GUESS_CELLS = 180
local REVEAL = { focus = false }
-- Each content leaf costs a native move plus sized dividers; beyond this the rail stays beside its first pane.
local MAX_CONTENT_LEAVES = 16
-- The smallest rail share Attention settles at whenever the native minimum pane size allows it.
local FLOOR = 0.2
local RATIO_EPSILON = 0.000001
local MINIMUM = "Pane sizes limited by the native minimum"
local UNCONVERGED = "Native sizing did not converge within bounded attempts"

local function firstLeaf(tree)
	while tree and not tree.pane do tree = tree[1] end
	return tree and tree.pane
end

local function leafCount(tree)
	if tree.pane then return 1 end
	return leafCount(tree[1]) + leafCount(tree[2])
end

function layout.strip(tree, rail)
	if not tree then return nil end
	if tree.pane then return if tree.pane == rail then nil else { pane = tree.pane } end
	local a, b = layout.strip(tree[1], rail), layout.strip(tree[2], rail)
	if not a then return b end
	if not b then return a end
	return { split = tree.split, ratio = tree.ratio, [1] = a, [2] = b }
end

-- Where each outer rail sits: the root divider axis, which child holds the rail (the other holds the content),
-- and the native resize direction and ratio sign that grow it.
local EDGES = {
	left = { split = "right", rail = 1, grow = "right", sign = 1 },
	down = { split = "down", rail = 2, grow = "up", sign = -1 },
	right = { split = "right", rail = 2, grow = "left", sign = -1 },
}
local EDGE_ORDER = { "left", "down", "right" }

function layout.isRail(tree, rail, edge)
	local spec = EDGES[edge]
	return spec ~= nil and tree ~= nil and tree.split == spec.split and tree[1] ~= nil and tree[2] ~= nil
		and tree[spec.rail].pane == rail
end

-- The canonical edge the rail currently occupies, or nil when the tree is not a canonical outer rail.
function layout.edgeOf(tree, rail)
	for _, edge in EDGE_ORDER do
		if layout.isRail(tree, rail, edge) then return edge end
	end
	return nil
end

local function equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for key, value in a do if not equal(value, b[key]) then return false end end
	for key in b do if a[key] == nil then return false end end
	return true
end

local function has(tree, pane)
	if not tree then return false end
	if tree.pane then return tree.pane == pane end
	return has(tree[1], pane) or has(tree[2], pane)
end

local function snapshot(value)
	if type(value) ~= "table" then return value end
	local result = {}
	for key, item in value do result[key] = snapshot(item) end
	return table.freeze(result)
end

local function seededContent(seed, tab, destination, rail, content)
	if not seed or seed.tab ~= tab or not seed.root or has(seed.root, rail)
		or not equal(seed.floats, destination.floats) then return content end
	local identities = {}
	local function collect(tree, expected)
		if not tree then return false end
		if tree.pane then
			if identities[tree.pane] ~= expected then return false end
			identities[tree.pane] = not expected
			return true
		end
		return (tree.split == "right" or tree.split == "down")
			and collect(tree[1], expected) and collect(tree[2], expected)
	end
	if not collect(seed.root, nil) or not collect(content, true) then return content end
	for _, remaining in identities do if remaining then return content end end
	return seed.root
end

local function shape(a, b)
	if not a or not b then return a == b end
	if a.pane or b.pane then return a.pane == b.pane end
	return a.split == b.split and shape(a[1], b[1]) and shape(a[2], b[2])
end

local function nodeAt(tree, path)
	for _, index in path do
		if not tree or tree.pane then return nil end
		tree = tree[index]
	end
	return tree
end

local function exposedLeaf(tree, axis)
	if tree.pane then return tree.pane end
	if tree.split == axis then return nil end
	return exposedLeaf(tree[1], axis) or exposedLeaf(tree[2], axis)
end

-- The fewest native minimum-size units `tree` needs along `axis`.
local function demand(tree, axis)
	if tree.pane then return 1 end
	local first, second = demand(tree[1], axis), demand(tree[2], axis)
	if tree.split == axis then return first + second end
	return math.max(first, second)
end

-- Native minimum-size reflow moves a divider toward the ratio at which both sides hold their minimum demand
-- equally and never past it; any other change of `before` into `after` is not a reflow.
local function reflowed(node, before, after)
	local first, second = demand(node[1], node.split), demand(node[2], node.split)
	local balanced = first / (first + second)
	return after >= math.min(before, balanced) - RATIO_EPSILON and after <= math.max(before, balanced) + RATIO_EPSILON
end

-- The ratio a fit aims for. Once a native cell is measured, the rail aims half a cell inside its floor share,
-- so the nearest attainable size never lands below it.
local function aim(fit)
	if fit.bound == nil or fit.extent == nil then return fit.ratio end
	if fit.above then return math.max(fit.ratio, fit.bound + 0.5 / fit.extent) end
	return math.min(fit.ratio, fit.bound - 0.5 / fit.extent)
end

local function insert(tree, pane, target, direction)
	if tree.pane then
		if tree.pane ~= target then return tree end
		local added = { pane = pane }
		if direction == "left" then return { split = "right", ratio = 0.5, [1] = added, [2] = tree } end
		return { split = direction, ratio = 0.5, [1] = tree, [2] = added }
	end
	return { split = tree.split, ratio = tree.ratio,
		[1] = insert(tree[1], pane, target, direction), [2] = insert(tree[2], pane, target, direction) }
end

local function plan(tree, rail, tab, edge, share, expected, content)
	local spec = EDGES[edge]
	local ratio = if spec.rail == 1 then share else 1 - share
	local root = if spec.rail == 1
		then { split = spec.split, ratio = ratio, [1] = { pane = rail }, [2] = content }
		else { split = spec.split, ratio = ratio, [1] = content, [2] = { pane = rail } }
	local job = { tab = tab, rail = rail, edge = edge, share = share, content = content, desired = root,
		initial = expected, expected = expected, steps = {}, index = 1 }
	local function move(pane, target, direction)
		table.insert(job.steps, { kind = "move", pane = pane, target = target, dir = direction })
	end
	local function rebuild(node)
		if node.pane then return end
		move(firstLeaf(node[2]), firstLeaf(node[1]), node.split)
		rebuild(node[1])
		rebuild(node[2])
	end
	if not shape(tree, root) then
		move(rail, firstLeaf(content), edge)
		rebuild(content)
	end
	table.insert(job.steps, { kind = "fit", path = {}, ratio = ratio, pane = rail,
		dir = spec.grow, sign = spec.sign, attempts = 0, moves = {}, above = spec.rail == 1,
		bound = if share > FLOOR then (if spec.rail == 1 then FLOOR else 1 - FLOOR) else nil })
	local function size(node, path)
		if node.pane then return end
		local pane = exposedLeaf(node[1], node.split) or exposedLeaf(node[2], node.split)
		local hidden = pane == nil
		if hidden then
			-- Native resize selects the nearest same-axis ancestor, on either
			-- side. Expose this divider, fit it, then rebuild and fit its children.
			pane = firstLeaf(node[1])
			local target = firstLeaf(node[2])
			local function evacuate(child)
				if child.pane then
					if child.pane ~= pane then move(child.pane, target, node.split) end
				else
					evacuate(child[1])
					evacuate(child[2])
				end
			end
			evacuate(node[1])
		end
		table.insert(job.steps, { kind = "fit", path = table.clone(path), ratio = node.ratio or 0.5,
			pane = pane, dir = node.split, sign = 1, attempts = 0, moves = {} })
		if hidden then rebuild(node[1]) end
		for index = 1, 2 do
			table.insert(path, index)
			size(node[index], path)
			table.remove(path)
		end
	end
	size(content, { 3 - spec.rail })
	return job
end

local function stopped(reason, parked)
	return { settled = false, changed = false, again = false, reason = reason, parked = parked }
end

function layout.new(seed)
	return { tab = if seed then seed.tab else nil, pane = nil, generation = nil, job = nil, completed = nil,
		seed = if seed then snapshot({ tab = seed.tab, root = seed.root, floats = seed.floats or {} }) else nil }
end

local function readGuard(cx, request)
	local destination = cx.session:layout(request.tab)
	if not destination then return nil, "Destination tab is unavailable" end
	if destination.zoomed then return nil, "Zoom pauses Attention placement" end
	local rail = cx.session:pane(request.pane)
	if not rail then return nil, "Attention pane is unavailable" end
	if rail.parked then return nil, "Attention was parked", true end
	if rail.floating then return nil, "Attention was floated" end
	if cx.session:tab_of(request.pane) ~= request.tab then return nil, "Attention belongs to another tab" end
	if not layout.strip(destination.root, request.pane) then return nil, "No content remains in this tab" end
	local target = cx.session:pane(request.target)
	if not target or target.parked or cx.session:tab_of(request.target) ~= request.tab then
		return nil, "Destination pane is unavailable"
	end
	return destination
end

-- The (pane, target) pairs of the run of consecutive move steps that ends at `last`.
local function movedPairs(job, last)
	local moves = {}
	for index = last, 1, -1 do
		local step = job.steps[index]
		if not step or step.kind ~= "move" then break end
		table.insert(moves, step)
	end
	return moves
end

-- Where the engine's latest native write could have reflowed ratios, derived from its progress alone:
-- `moved` pairs (the dividers above each new split) after moves, or `fit` (the squeezed side of the
-- sized divider) after a resize.
local function recentScope(job)
	local step = job.steps[job.index]
	if step and step.kind == "fit" and step.attempts > 0 then return { fit = step.path, squeezed = step.squeezed } end
	local previous = job.steps[job.index - 1]
	if previous and previous.kind == "move" then return { moved = movedPairs(job, job.index - 1) } end
	if previous then return { fit = previous.path, squeezed = previous.squeezed } end
	return {}
end

local function transientDrift(job, before, after, scope)
	local fitPath = scope.fit
	local fitDepth = if fitPath then #fitPath else -1
	local squeezed = scope.squeezed
	if fitPath and scope.self then
		local was, now = nodeAt(before, fitPath), nodeAt(after, fitPath)
		if was and now and not was.pane and not now.pane then
			local x, y = was.ratio or 0.5, now.ratio or 0.5
			squeezed = if y > x then 2 elseif y < x then 1 else nil
		end
	end
	if not job.positions then
		job.positions, job.dividers, job.fits = {}, {}, {}
		for _, step in job.steps do
			if step.kind == "fit" then job.fits[table.concat(step.path, ".")] = step end
		end
		local position = 0
		local function index(tree, path)
			if tree.pane then
				position += 1
				job.positions[tree.pane] = position
				return position, position
			end
			local branch = table.concat(path, ".")
			table.insert(path, 1)
			local first, middle = index(tree[1], path)
			path[#path] = 2
			local _, last = index(tree[2], path)
			table.remove(path)
			job.dividers[tree.split .. ":" .. first .. ":" .. middle .. ":" .. last] = job.fits[branch]
			return first, last
		end
		index(job.desired, {})
	end
	-- Native reflow rebalances dividers above a freshly split pair, never the new split itself:
	-- `node` is such a divider when a child of it already holds both panes of a move.
	local function aboveMoved(node)
		for _, move in scope.moved do
			for index = 1, 2 do
				if has(node[index], move.pane) and has(node[index], move.target) then return true end
			end
		end
		return false
	end
	local function compare(a, b, depth: number, onFitPath: boolean, underFit: boolean): (boolean, number, number, number)
		if not a or not b then return false, 0, 0, 0 end
		if a.pane or b.pane then
			local position = job.positions[b.pane]
			if a.pane ~= b.pane or position == nil then return false, 0, 0, 0 end
			return true, position, position, 1
		end
		if a.split ~= b.split then return false, 0, 0, 0 end
		local child = if onFitPath and depth < fitDepth then fitPath[depth + 1] else nil
		local left, first, middle, leftCount = compare(a[1], b[1], depth + 1, child == 1,
			underFit or (onFitPath and depth == fitDepth and squeezed == 1))
		if not left then return false, 0, 0, 0 end
		local right, second, last, rightCount = compare(a[2], b[2], depth + 1, child == 2,
			underFit or (onFitPath and depth == fitDepth and squeezed == 2))
		if not right then return false, 0, 0, 0 end
		if (a.ratio or 0.5) ~= (b.ratio or 0.5) and not (scope.self and onFitPath and depth == fitDepth) then
			local contiguous = leftCount == middle - first + 1 and rightCount == last - second + 1
				and second == middle + 1
			local owner = if contiguous then job.dividers[b.split .. ":" .. first .. ":" .. middle .. ":" .. last] else nil
			-- A final divider stays protected once fitted. Until then the native minimum-size reflow
			-- that follows our own write may rebalance it, and its own pending fit restores the
			-- recorded ratio: only inside the squeezed side of the sized divider, or above the pair of a moved pane.
			-- A content divider may also be pushed by the minimum at any time, but only toward the ratio where
			-- both sides hold their minimum equally; the final audit reports whatever could not be restored.
			local protected = not (owner and owner.applied == nil and (underFit or (scope.moved ~= nil and aboveMoved(b))))
				and not (owner and #owner.path > 0 and reflowed(b, a.ratio or 0.5, b.ratio or 0.5))
			if owner and protected then
				return false, 0, 0, 0
			end
		end
		return true, math.min(first, second), math.max(middle, last), leftCount + rightCount
	end
	-- Pane identity, axes and order are always exact.
	return compare(before, after, 0, fitPath ~= nil, false)
end

-- Cell sizes measured on one divider. The smallest is the largest native move, which caps steps; the largest is the
-- least move, which the stop test uses. A stale measurement reads a smaller cell than native's steady state, because
-- native moved more cells than were asked; it can cap steps for at most CELL_MEMORY writes. Nil until a write measures.
local function cellRange(fit)
	local latest: number? = fit.extent
	if latest == nil then return nil, nil end
	local smallest: number, largest: number = latest, latest
	for _, extent: number in fit.moves do
		smallest, largest = math.min(smallest, extent), math.max(largest, extent)
	end
	return smallest, largest
end

local function finishPending(job, after)
	local pending = job.pending
	if not after or not equal(after.floats, pending.before.floats) then return false end
	local fitted = if pending.kind == "fit" then nodeAt(after.root, pending.fit.path) else nil
	local targetUnchanged = pending.kind ~= "fit" or (fitted ~= nil and (fitted.ratio or 0.5) == pending.ratio)
	local scope = if pending.kind == "move" then { moved = movedPairs(job, pending.index) } else { fit = pending.fit.path }
	if pending.accepted == nil and targetUnchanged and (equal(after.root, pending.before.root)
		or transientDrift(job, pending.before.root, after.root, scope)) then
		-- No observable move: keep the original intent and any native normalization.
		job.expected, job.pending = after, nil
		return true
	end
	if pending.kind == "move" then
		if pending.accepted == false and equal(after.root, pending.before.root) then
			job.failure = "Native move refused the content reconstruction"
			job.expected, job.pending = after, nil
			return true
		end
		if not equal(after.root, pending.expected) and not transientDrift(job, pending.expected, after.root, scope) then return false end
		if pending.accepted == false then job.failure = "Native move did not preserve the expected layout" end
		job.index = pending.index + 1
	else
		scope.self = true
		if not transientDrift(job, pending.before.root, after.root, scope) then return false end
		local nextRatio = nodeAt(after.root, pending.fit.path).ratio or 0.5
		local delta = nextRatio - pending.ratio
		local fit = pending.fit
		fit.attempts = pending.attempts
		if math.abs(delta) >= 0.0000001 then fit.squeezed = if delta > 0 then 2 else 1 end
		if pending.accepted == false or math.abs(delta) < 0.0000001 then
			if math.abs(fit.ratio - nextRatio) > 1 / pending.extent then job.degraded = job.degraded or MINIMUM end
			job.index = pending.index + 1
			fit.applied = nextRatio
		else
			fit.extent = math.abs(pending.cells / delta)
			table.insert(fit.moves, fit.extent)
			if #fit.moves > CELL_MEMORY then table.remove(fit.moves, 1) end
			local previousError, nextError = aim(fit) - pending.ratio, aim(fit) - nextRatio
			-- One native cell brackets adjacent attainable sizes, once SETTLED_WRITES writes have measured it. Choose the
			-- nearer endpoint (either on a tie), rather than rounding half a cell forever.
			if pending.attempts >= SETTLED_WRITES and math.abs(pending.cells) == 1 and previousError * nextError <= 0
				and math.abs(nextError) <= math.abs(previousError) then
				job.index = pending.index + 1
				fit.applied = nextRatio
			end
		end
	end
	job.expected = after
	job.pending = nil
	return true
end

local function terminate(state, request, reason, changed, recoverable)
	local job = state.job
	state.recovery = if recoverable and job then {
		root = job.content, floats = job.expected.floats, expected = job.expected,
	} else nil
	state.job, state.seed = nil, nil
	state.completed = { generation = request.generation, settled = false, reason = reason }
	local result = stopped(reason)
	result.changed = changed
	return result
end

local function fitOne(cx, job, fit, before)
	local node = nodeAt(before.root, fit.path)
	if not node or node.pane then return false, "Split changed during sizing" end
	local ratio = node.ratio or 0.5
	local error = aim(fit) - ratio
	local extent = fit.extent or GUESS_CELLS
	local direction = if error / fit.sign > 0 then 1 else -1
	local smallest, largest = cellRange(fit)
	-- Stop once the largest recent cell size says the rail is within half a cell, and only after SETTLED_WRITES writes.
	-- The first writes can measure geometry native has not drawn yet, and a stale size is too small: it would stop early.
	if math.abs(error) < 0.000001 or (fit.attempts >= SETTLED_WRITES and largest ~= nil and math.round(error * largest / fit.sign) == 0) then
		job.index += 1
		fit.applied = ratio
		return false
	end
	if fit.attempts >= FIT_LIMIT then
		job.degraded = job.degraded or UNCONVERGED
		job.index += 1
		fit.applied = ratio
		return false
	end
	-- The first write moves one native cell toward its target and so measures the cell size. Later steps are capped by
	-- the smallest recent size, and a step is never empty while a cell is still due.
	local cells = if smallest == nil then direction else math.round(error * smallest / fit.sign)
	if cells == 0 then cells = direction end
	cells = math.clamp(cells, -512, 512)
	local pending = { kind = "fit", before = before, fit = fit, index = job.index,
		ratio = ratio, extent = extent, cells = cells, attempts = fit.attempts + 1 }
	job.pending = pending
	pending.accepted = cx.layout:resize(fit.pane, fit.dir, cells)
	local after = cx.session:layout(job.tab)
	if not finishPending(job, after) then
		if pending.accepted == false then return true, "Native resize did not preserve the expected layout" end
		return true, nil, true
	end
	return true, job.failure
end

function layout.reconcile(state, cx, request)
	if state.tab ~= nil and state.tab ~= request.tab then return stopped("Layout state belongs to another tab") end
	if state.pane ~= nil and state.pane ~= request.pane then return stopped("Layout state belongs to another Attention pane") end
	if state.generation and request.generation < state.generation then return stopped("Superseded layout request") end
	local edge, share = request.edge, request.share
	if EDGES[edge] == nil then return stopped("Attention edge must be left, down, or right") end
	if type(share) ~= "number" or share ~= share or share <= 0 or share >= 1 then
		return stopped("Attention size must be a share between zero and one")
	end
	state.tab, state.pane, state.generation = request.tab, request.pane, request.generation
	local completed = state.completed
	if completed and completed.generation == request.generation then
		return { settled = completed.settled, changed = false, again = false, reason = completed.reason,
			edge = completed.edge, share = completed.share, degraded = completed.degraded }
	end
	local destination, reason, parked = readGuard(cx, request)
	if not destination then return stopped(reason, parked) end
	local job = state.job
	if job then
		-- A callback can abort after an accepted native write. Recover only its
		-- recorded same-tab effect; an unrelated user edit cancels this request.
		local recovered = not job.pending or finishPending(job, destination)
		if recovered and equal(destination.floats, job.expected.floats)
			and not equal(destination.root, job.expected.root) and transientDrift(job, job.expected.root, destination.root, recentScope(job)) then
			job.expected = destination
		end
		if not recovered or not equal(destination.root, job.expected.root) or not equal(destination.floats, job.expected.floats) then
			return terminate(state, request, "Native layout changed; Attention placement cancelled", false)
		end
		if job.failure then return terminate(state, request, job.failure, false, true) end
	else
		if state.recovery then
			local recovery = state.recovery
			if not equal(destination.root, recovery.expected.root) or not equal(destination.floats, recovery.expected.floats) then
				return terminate(state, request, "Native layout changed after failed placement; original repair cancelled", false)
			end
			state.seed = { tab = state.tab, root = recovery.root, floats = recovery.floats }
			state.recovery = nil
		end
		local content = seededContent(state.seed, request.tab, destination, request.pane, layout.strip(destination.root, request.pane))
		state.seed, state.completed = nil, nil
		if leafCount(content) > MAX_CONTENT_LEAVES then
			-- Native docking targets a leaf, never the tab edge: reconstructing this much content is unbounded work.
			local reason = "Too many panes to place Attention full-height · it stays beside its first pane"
			state.completed = { generation = request.generation, settled = true, edge = edge, share = share,
				degraded = true, reason = reason }
			return { settled = true, changed = false, again = false, edge = edge, share = share, degraded = true, reason = reason }
		end
		job = plan(destination.root, request.pane, request.tab, edge, share, destination, content)
		state.job = job
	end

	local changed = false
	for _ = 1, layout.BATCH do
		local live, guardReason, guardParked = readGuard(cx, request)
		if not live then
			local result = stopped(guardReason, guardParked)
			result.changed = changed
			return result
		end
		if equal(live.floats, job.expected.floats) and not equal(live.root, job.expected.root)
			and transientDrift(job, job.expected.root, live.root, recentScope(job)) then
			job.expected = live
		end
		if not equal(live.root, job.expected.root) or not equal(live.floats, job.expected.floats) then
			return terminate(state, request, "Native layout changed; Attention placement cancelled", changed)
		end
		local operation = job.steps[job.index]
		if operation and operation.kind == "move" then
			if cx.session:tab_of(operation.pane) ~= job.tab or not has(live.root, operation.target) then
				return terminate(state, request, "A reconstruction pane is unavailable", changed)
			end
			local expected = insert(layout.strip(live.root, operation.pane), operation.pane, operation.target, operation.dir)
			local pending = { kind = "move", before = live, expected = expected, index = job.index }
			job.pending = pending
			pending.accepted = cx.layout:move(operation.pane, operation.target, operation.dir, REVEAL)
			changed = true
			local after = cx.session:layout(job.tab)
			if not finishPending(job, after) then
				return terminate(state, request, "Native move did not preserve the expected layout", changed)
			end
			if job.failure then return terminate(state, request, job.failure, changed, true) end
		else
			if operation then
				local wrote, fitReason, interrupted = fitOne(cx, job, operation, live)
				changed = changed or wrote
				if fitReason then return terminate(state, request, fitReason, changed, job.pending == nil) end
				if interrupted then
					return terminate(state, request, "Native layout changed during sizing; Attention placement cancelled", changed)
				end
			else
				if not shape(live.root, job.desired) then
					return terminate(state, request, "Native layout did not form the requested outer rail", changed)
				end
				-- Whatever native could not hold at its recorded ratio, a refused fit or a minimum-size reflow that
				-- pushed a fitted divider, is a limit of the native minimum: the rail stays placed and says so.
				for _, step in job.steps do
					if step.kind == "fit" then
						local node = nodeAt(live.root, step.path)
						if node == nil or node.pane
							or math.abs((node.ratio or 0.5) - step.ratio) > 1 / (step.extent or GUESS_CELLS) + RATIO_EPSILON then
							job.degraded = job.degraded or MINIMUM
						end
					end
				end
				state.job = nil
				-- Finish an interrupted same-tab reconstruction before accepting a
				-- newer explicit placement. Never repair or migrate another tab.
				if job.edge ~= edge or job.share ~= share then
					return { settled = false, changed = changed, again = true }
				end
				local ratio = live.root.ratio or 0.5
				local observed = if EDGES[job.edge].rail == 1 then ratio else 1 - ratio
				state.completed = { generation = request.generation, settled = true, edge = job.edge,
					share = observed, degraded = if job.degraded then true else nil, reason = job.degraded }
				return { settled = true, changed = changed, again = false, edge = job.edge,
					share = observed, degraded = state.completed.degraded, reason = job.degraded }
			end
		end
	end
	return { settled = false, changed = changed, again = true }
end

local function packTree(tree)
	local nodes = 0
	local function walk(node, depth)
		nodes += 1
		assert(nodes <= 511 and depth <= 64 and node ~= nil, "Placement tree exceeds checkpoint bound")
		if node.pane then return { pane = node.pane } end
		return { split = node.split, ratio = node.ratio, first = walk(node[1], depth + 1), second = walk(node[2], depth + 1) }
	end
	return walk(tree, 0)
end

local function packView(view)
	assert(#view.floats <= 256, "Placement floats exceed checkpoint bound")
	return { root = packTree(view.root), floats = view.floats, focus = view.focus, zoomed = view.zoomed, tab = view.tab }
end

local function validatePlain(record)
	local budget, ancestors = 16384, {}
	local function plain(value: unknown, depth: number)
		budget -= 1
		assert(budget >= 0 and depth <= 128, "Placement checkpoint exceeds its bound")
		if value == nil or type(value) == "boolean" then return end
		if type(value) == "number" then assert(value == value and math.abs(value) < math.huge, "Invalid checkpoint number"); return end
		if type(value) == "string" then assert(#value <= 4096, "Invalid checkpoint string"); return end
		assert(type(value) == "table" and not ancestors[value], "Invalid checkpoint value")
		ancestors[value] = true
		local array, count = nil, 0
		for key, item in value do
			local numeric = type(key) == "number"
			assert((numeric and key >= 1 and key == math.floor(key)) or (type(key) == "string" and #key <= 64), "Invalid checkpoint key")
			assert(array == nil or array == numeric, "Checkpoint must use JSON arrays or objects")
			array, count = numeric, count + 1
			plain(item, depth + 1)
		end
		if array then assert(#value == count, "Invalid checkpoint array") end
		ancestors[value] = nil
	end
	plain(record, 0)
end

function layout.checkpoint(state)
	local seed, recovery, job = state.seed, state.recovery, state.job
	if seed then assert(#seed.floats <= 256, "Placement seed floats exceed checkpoint bound") end
	if recovery then assert(#recovery.floats <= 256, "Placement recovery floats exceed checkpoint bound") end
	local record = { version = 4, tab = state.tab, pane = state.pane, generation = state.generation,
		completed = state.completed,
		seed = if seed then { root = packTree(seed.root), floats = seed.floats } else nil,
		recovery = if recovery then { root = packTree(recovery.root), floats = recovery.floats,
			expected = packView(recovery.expected) } else nil }
	if job then
		assert(#job.steps <= 4096, "Placement steps exceed checkpoint bound")
		local fits = {}
		for index, step in job.steps do
			if step.kind == "fit" and (step.attempts > 0 or step.extent ~= nil or step.applied ~= nil) then
				table.insert(fits, { index = index, attempts = step.attempts, extent = step.extent, applied = step.applied })
			end
		end
		local pending = job.pending
		record.job = { edge = job.edge, share = job.share, content = packTree(job.content),
			initial = packView(job.initial), expected = packView(job.expected), index = job.index, fits = fits,
			failure = job.failure, degraded = job.degraded,
			pending = if pending then { index = pending.index, accepted = pending.accepted, ratio = pending.ratio,
				extent = pending.extent, cells = pending.cells, attempts = pending.attempts } else nil }
	end
	validatePlain(record)
	return snapshot(record)
end

function layout.restore(record)
	-- Only the current checkpoint shape is replayable; every other version is rejected by name and dropped.
	if type(record) ~= "table" then return nil, "Placement checkpoint is not a record" end
	if record.version ~= 4 then
		return nil, "Unsupported placement checkpoint version " .. (if type(record.version) == "number" then tostring(record.version) else "unknown")
	end
	local ok, restored = pcall(function()
		validatePlain(record)
		local function integer(value)
			return type(value) == "number" and value >= 0 and value == math.floor(value)
		end
		local function identity(value)
			return integer(value) and value <= 9007199254740991
		end
		local function fraction(value)
			return type(value) == "number" and value > 0 and value < 1
		end
		local function tree(value)
			local nodes, ids = 0, {}
			local function walk(node, depth)
				nodes += 1
				assert(nodes <= 511 and depth <= 64 and type(node) == "table", "Invalid checkpoint tree")
				if node.pane ~= nil then
					assert(identity(node.pane) and not ids[node.pane], "Invalid checkpoint pane identity")
					ids[node.pane] = true
					return { pane = node.pane }
				end
				assert((node.split == "right" or node.split == "down") and fraction(node.ratio), "Invalid checkpoint divider")
				return { split = node.split, ratio = node.ratio, [1] = walk(node.first, depth + 1), [2] = walk(node.second, depth + 1) }
			end
			return walk(value, 0)
		end
		local function floats(value)
			assert(type(value) == "table" and #value <= 256, "Invalid checkpoint floats")
			for _, float in value do
				assert(type(float) == "table" and identity(float.pane), "Invalid checkpoint float identity")
			end
			return snapshot(value)
		end
		local function view(value)
			assert(type(value) == "table", "Invalid checkpoint layout")
			return { root = tree(value.root), floats = floats(value.floats), focus = value.focus,
				zoomed = value.zoomed, tab = value.tab }
		end
		local function identities(a, b)
			local ids = {}
			local function collect(node, remove)
				if node.pane then
					if remove then assert(ids[node.pane], "Placement identities changed"); ids[node.pane] = nil
					else ids[node.pane] = true end
				else collect(node[1], remove); collect(node[2], remove) end
			end
			collect(a, false)
			collect(b, true)
			assert(next(ids) == nil, "Placement identities changed")
		end
		assert(identity(record.tab) and (record.pane == nil or identity(record.pane)), "Invalid placement owner")
		assert(record.generation == nil or integer(record.generation), "Invalid placement generation")
		local state = { tab = record.tab, pane = record.pane, generation = record.generation }
		if record.seed then
			state.seed = { tab = state.tab, root = tree(record.seed.root), floats = floats(record.seed.floats) }
			assert(not state.pane or not has(state.seed.root, state.pane), "Seed contains Attention")
		end
		if record.completed then
			local done = record.completed
			assert(type(done) == "table" and integer(done.generation) and done.generation == state.generation
				and type(done.settled) == "boolean" and (done.reason == nil or type(done.reason) == "string"), "Invalid placement completion")
			if done.settled then
				assert(EDGES[done.edge] ~= nil and fraction(done.share), "Invalid completed placement")
			end
			state.completed = snapshot(done)
		end
		if record.recovery then
			assert(state.pane and state.completed and not state.completed.settled, "Invalid placement recovery")
			local recovery = record.recovery
			state.recovery = { root = tree(recovery.root), floats = floats(recovery.floats), expected = view(recovery.expected) }
			assert(not has(state.recovery.root, state.pane), "Recovery contains Attention")
			identities(state.recovery.root, assert(layout.strip(state.recovery.expected.root, state.pane)))
		end
		if record.job then
			assert(state.pane and state.generation and not state.completed and not state.recovery and not state.seed, "Invalid active placement")
			local saved = record.job
			assert(EDGES[saved.edge] ~= nil and fraction(saved.share), "Invalid placement request")
			local initial, expected, content = view(saved.initial), view(saved.expected), tree(saved.content)
			assert(has(initial.root, state.pane) and has(expected.root, state.pane) and not has(content, state.pane), "Invalid active pane membership")
			identities(initial.root, expected.root)
			identities(content, assert(layout.strip(initial.root, state.pane)))
			local job = plan(initial.root, state.pane, state.tab, saved.edge, saved.share, initial, content)
			assert(#job.steps <= 4096 and integer(saved.index) and saved.index >= 1 and saved.index <= #job.steps + 1, "Invalid placement cursor")
			job.index, job.expected = saved.index, expected
			assert(saved.failure == nil or type(saved.failure) == "string", "Invalid placement failure")
			assert(saved.degraded == nil or type(saved.degraded) == "string", "Invalid degraded placement")
			job.failure, job.degraded = saved.failure, saved.degraded
			assert(type(saved.fits) == "table" and #saved.fits <= #job.steps, "Invalid placement fits")
			local seen = {}
			for _, fit in saved.fits do
				assert(type(fit) == "table" and integer(fit.index) and not seen[fit.index], "Invalid fit identity")
				seen[fit.index] = true
				local step = job.steps[fit.index]
				assert(step and step.kind == "fit" and integer(fit.attempts) and fit.attempts <= FIT_LIMIT
					and (fit.extent == nil or (type(fit.extent) == "number" and fit.extent > 0))
					and (fit.applied == nil or fraction(fit.applied)), "Invalid native fit")
				step.attempts, step.extent, step.applied = fit.attempts, fit.extent, fit.applied
			end
			if saved.pending then
				local savedPending, step = saved.pending, job.steps[job.index]
				assert(type(savedPending) == "table" and step and savedPending.index == job.index
					and (savedPending.accepted == nil or type(savedPending.accepted) == "boolean"), "Invalid pending placement")
				local pending = { kind = step.kind, index = job.index, before = expected, accepted = savedPending.accepted }
				if step.kind == "move" then
					assert(has(expected.root, step.pane) and has(expected.root, step.target), "Invalid pending move identities")
					pending.expected = insert(layout.strip(expected.root, step.pane), step.pane, step.target, step.dir)
				else
					local node = nodeAt(expected.root, step.path)
					assert(node and not node.pane and savedPending.ratio == (node.ratio or 0.5)
						and type(savedPending.extent) == "number" and savedPending.extent > 0
						and type(savedPending.cells) == "number" and savedPending.cells ~= 0
						and savedPending.cells == math.floor(savedPending.cells) and math.abs(savedPending.cells) <= 512
						and integer(savedPending.attempts) and savedPending.attempts >= 1 and savedPending.attempts <= FIT_LIMIT, "Invalid pending fit")
					pending.fit, pending.ratio, pending.extent = step, savedPending.ratio, savedPending.extent
					pending.cells, pending.attempts = savedPending.cells, savedPending.attempts
				end
				job.pending = pending
			end
			state.job = job
		end
		return state
	end)
	if not ok then return nil, tostring(restored) end
	return restored
end

return layout
