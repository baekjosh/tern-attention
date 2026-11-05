local canvas = {}

export type Span = { t: string, href: string? }
export type Props = {
	key: string?, role: string?, tag: string?, title: string?, href: string?,
	text: string?, label: string?, spans: (string | Span | { Span })?,
	actions: { [string]: string }?,
	hidden: boolean?, wrap: (string | boolean)?, truncate: string?,
	gap: string?, shrink: number?, lines: number?, justify: string?,
	tone: string?, priority: number?, transparent: boolean?, name: string?, size: number?,
}
export type Node = { k: string, p: Props, c: { Node }? }
export type Screen = {
	view: Node?, dock: Node?,
	pane: number?, owner: string?, about: string?, title: string?,
}
export type Change = { title: string?, view: Node?, dock: Node?, set: { [string]: Node | false }? }

-- Snapshot plain fixture trees without exposing their recursive structure to callers.
-- Erasure is confined to this traversal; the public contract preserves the input type.
function canvas.copy<T>(value: T): T
	if type(value) ~= "table" then return value end
	local source: any = value
	local result: any = {}
	for key, item in pairs(source) do result[key] = canvas.copy(item) end
	if getmetatable(source) == false then setmetatable(result, { __metatable = false }) end
	return result
end

function canvas.childAt(node: Node, key: string): (Node?, number?)
	for index, child in ipairs(node.c or {}) do
		if (child.p and child.p.key == key) or (not (child.p and child.p.key) and tostring(index - 1) == key) then
			return child, index
		end
	end
	return nil, nil
end

function canvas.apply(screen: Screen?, change: Change?): Screen?
	if change == nil then return screen end
	assert(type(change) == "table", "expected native CanvasChange")
	screen = if screen then canvas.copy(screen) else {}
	if change.title ~= nil then screen.title = change.title end
	if change.view ~= nil then screen.view = canvas.copy(change.view) end
	if change.dock ~= nil then screen.dock = canvas.copy(change.dock) end
	assert(screen.view, "native canvas requires a drawn view")
	for path, replacement in pairs(change.set or {}) do
		assert(type(path) == "string" and not string.find(path, "/", 1, true), "invalid native keyed path")
		local segments = string.split(path, ".")
		local parent = screen.view
		for index = 1, #segments - 1 do
			parent = canvas.childAt(parent, segments[index])
			assert(parent, "patch parent must already exist: " .. path)
		end
		local key = segments[#segments]
		local _, index = canvas.childAt(parent, key)
		parent.c = parent.c or {}
		if replacement == false then
			assert(index, "cannot remove an absent keyed child: " .. path)
			table.remove(parent.c, index)
		else
			assert(type(replacement) == "table" and replacement.p and replacement.p.key == key,
				"replacement must retain its addressed key: " .. path)
			if index then parent.c[index] = canvas.copy(replacement)
			else table.insert(parent.c, canvas.copy(replacement)) end
		end
	end
	return screen
end

function canvas.sourceFact(revision)
	return { status = "ready", reusable = true, sessionId = "header-uuid", schemaVersion = 3,
		writerVersions = { "18.14.0" }, revision = revision,
		selectedLeafId = "reply", selection = "disk-replayed", complete = true,
		coverage = { recordsComplete = true },
		questions = {}, questionCoverage = { status = "complete", knownTotal = 0, included = 0, omitted = 0 },
		lastHuman = { id = "request", text = "Build the report and index", atUtc = 1700000000, provenance = "user" },
		lastAssistant = { id = "reply", text = "Report available; index still pending.", stopReason = "stop" } }
end

return canvas
