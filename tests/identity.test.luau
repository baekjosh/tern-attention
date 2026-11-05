local identity = require("../identity")

local function test(name, body)
	local ok, failure = pcall(body)
	assert(ok, name .. ": " .. tostring(failure))
end

local function hop(fields)
	local value = { principal = "operator", method = "local", from = "origin", host = "workstation", user = "operator" }
	for key, field in pairs(fields or {}) do value[key] = field end
	return value
end

local function pane(id, file, hops)
	return { pane = id, title = "Same title", omp_session_file = file or "/sessions/conversation.jsonl",
		identity = { hops = hops or { hop() } } }
end

local function rejects(document)
	local ok, failure = pcall(identity.index, document)
	assert(not ok and type(failure) == "string", "malformed inspect data must fail explicitly")
end

test("exact native conversation restores after its pane ID changes", function()
	local saved = identity.index({ panes = { pane(11) } })[11]
	local current = identity.index({ panes = { pane(97) } })
	local target, reason = identity.resolve(saved, current, { [97] = {} }, 11)
	assert(target == 97 and reason == nil)
end)

test("reused preferred pane cannot substitute a different conversation", function()
	local saved = identity.index({ panes = { pane(11) } })[11]
	local current = identity.index({ panes = { pane(11, "/sessions/other.jsonl"), pane(97) } })
	assert(identity.resolve(saved, current, { [11] = {}, [97] = {} }, 11) == 97)
	local target, reason = identity.resolve(saved, current, { [11] = {} }, 11)
	assert(target == nil and reason == "missing")
end)

test("identical titles never provide conversation identity", function()
	local saved = identity.index({ panes = { pane(11) } })[11]
	local candidate = pane(97, "/sessions/other.jsonl")
	candidate.cwd, candidate.timestamp, candidate.message = "/same", 100, "same message"
	local current = identity.index({ panes = { candidate, { pane = 98, title = candidate.title } } })
	local target, reason = identity.resolve(saved, current, { [97] = {}, [98] = {} }, 11)
	assert(target == nil and reason == "missing" and current[98] == nil)
end)

test("duplicate conversation candidates require a matching present preferred pane", function()
	local current = identity.index({ panes = { pane(11), pane(97) } })
	local target, reason = identity.resolve(current[11], current, { [11] = {}, [97] = {} }, 42)
	assert(target == nil and reason == "ambiguous")
	local preferred, preferredReason = identity.resolve(current[11], current, { [11] = {}, [97] = {} }, 11)
	assert(preferred == 11 and preferredReason == nil)
	assert(identity.resolve(current[11], current, { [97] = {} }, 11) == 97)
end)

test("absent current panes are never routable even with exact indexed identity", function()
	local current = identity.index({ panes = { pane(11) } })
	local target, reason = identity.resolve(current[11], current, {}, 11)
	assert(target == nil and reason == "missing")
	local absent, absentReason = identity.resolve(nil, current, { [11] = {} }, 11)
	assert(absent == nil and absentReason == "missing")
end)

test("missing metadata never invents conversation or provenance", function()
	for _, field in ipairs({ "omp_session_file", "identity" }) do
		local candidate = pane(11)
		candidate[field] = nil
		assert(identity.index({ panes = { candidate } })[11] == nil)
	end
	local candidate = pane(11)
	candidate.identity.hops = nil
	assert(identity.index({ panes = { candidate } })[11] == nil)
	candidate = { pane = 11, session_file = "/sessions/conversation.jsonl", hops = { hop() } }
	assert(identity.index({ panes = { candidate } })[11] == nil, "legacy aliases are not native evidence")
end)

test("local provenance accepts empty from but requires every published field", function()
	local candidate = pane(11, nil, { hop({ from = "" }) })
	local current = identity.index({ panes = { candidate } })
	assert(type(current[11]) == "string")
	for _, field in ipairs({ "principal", "method", "from", "host", "user" }) do
		local missing = pane(11)
		missing.identity.hops[1][field] = nil
		assert(identity.index({ panes = { missing } })[11] == nil)
		if field ~= "from" then
			missing.identity.hops[1][field] = ""
			assert(identity.index({ panes = { missing } })[11] == nil)
		end
	end
	local missingLaterHop = pane(11, nil, { hop(), {} })
	assert(identity.index({ panes = { missingLaterHop } })[11] == nil,
		"partial provenance cannot truncate the native hop chain")
end)

test("unsupported optional metadata is unavailable without alias fallback", function()
	for _, value in ipairs({ false, 17, {}, "" }) do
		local candidate = pane(11)
		candidate.omp_session_file = value
		assert(identity.index({ panes = { candidate } })[11] == nil)
	end
	for _, value in ipairs({ false, 17, "identity", {} }) do
		local candidate = pane(11)
		candidate.identity = value
		assert(identity.index({ panes = { candidate } })[11] == nil)
	end
	for _, value in ipairs({ false, "hops", {}, { [2] = hop() }, { named = hop() }, { false } }) do
		local candidate = pane(11)
		candidate.identity.hops = value
		assert(identity.index({ panes = { candidate } })[11] == nil)
	end
	for _, field in ipairs({ "principal", "method", "from", "host", "user" }) do
		local candidate = pane(11)
		candidate.identity.hops[1][field] = {}
		assert(identity.index({ panes = { candidate } })[11] == nil)
	end
end)

test("malformed inspect containers and duplicate pane IDs fail explicitly", function()
	for _, document in ipairs({ false, "inspect", {}, { panes = false }, { panes = "panes" },
		{ panes = { named = pane(11) } }, { panes = { [2] = pane(11) } },
		{ panes = { false } }, { panes = { {} } }, { panes = { pane("11") } },
		{ panes = { pane(1.5) } }, { panes = { pane(math.huge) } },
		{ panes = { pane(0 / 0) } }, { panes = { pane(11), pane(11) } },
		{ panes = { { pane = 11 }, { pane = 11 } } } }) do
		rejects(document)
	end
	rejects(nil)
	assert(next(identity.index({ panes = {} })) == nil)
end)

test("hostile separator strings cannot alias distinct field boundaries", function()
	local a = pane(11, "a:b", { hop({ principal = "c" }) })
	local b = pane(12, "a", { hop({ principal = "b:c" }) })
	local c = pane(13, "a\000b", { hop({ host = "x:y", user = "z" }) })
	local d = pane(14, "a\000b", { hop({ host = "x", user = "y:z" }) })
	local e = pane(15, "1:a2:bc", { hop({ principal = "\000:1:" }) })
	local f = pane(16, "1:a2:b", { hop({ principal = "c\000:1:" }) })
	local current = identity.index({ panes = { a, b, c, d, e, f } })
	assert(current[11] ~= current[12] and current[13] ~= current[14] and current[15] ~= current[16])
end)

test("every hop field and hop ordering participates in identity", function()
	local original = identity.index({ panes = { pane(11, nil, { hop(), hop({ host = "remote" }) }) } })[11]
	for _, field in ipairs({ "principal", "method", "from", "host", "user" }) do
		local candidate = pane(11, nil, { hop(), hop({ host = "remote" }) })
		candidate.identity.hops[1][field] ..= ":changed"
		assert(identity.index({ panes = { candidate } })[11] ~= original, field .. " must participate")
	end
	local reversed = pane(11, nil, { hop({ host = "remote" }), hop() })
	assert(identity.index({ panes = { reversed } })[11] ~= original)
	assert(identity.index({ panes = { pane(11) } })[11] ~= original)
end)

test("native numeric pane IDs remain unchanged and cosmetic metadata is ignored", function()
	local numeric = -9223372036854775808
	local a, b = pane(numeric), pane(27)
	b.title, b.cwd, b.timestamp, b.message = "renamed", "/elsewhere", 9999, "changed"
	local current = identity.index({ panes = { a, b } })
	assert(current[numeric] ~= nil and current[numeric] == current[27])
	assert(identity.resolve(current[numeric], current, { [numeric] = {} }, numeric) == numeric)
end)

test("sources expose only exact locators and prove local ordered provenance", function()
	local localPane = pane(11)
	local remotePane = pane(12, "/sessions/same-local-spelling.jsonl", { hop(), hop({ method = "ssh", host = "remote" }) })
	local unknownPane = pane(13, "/sessions/unknown.jsonl", { hop({ method = "unknown" }) })
	local localChain = pane(14, nil, { hop(), hop({ from = "", method = "local" }) })
	local document = { panes = { localPane, remotePane, unknownPane, localChain, { pane = 15 } } }
	local index, sources = identity.index(document), identity.sources(document)
	assert(sources[11].key == index[11] and sources[11].path == localPane.omp_session_file and sources[11].localSource)
	assert(sources[12].key == index[12] and sources[12].path == remotePane.omp_session_file and not sources[12].localSource)
	assert(not sources[13].localSource and sources[14].localSource and sources[15] == nil)
	assert(identity.index(document)[11] == index[11], "sources must not mutate exact identity")
	local damaged = pane(16)
	damaged.identity.hops[1].host = nil
	assert(identity.sources({ panes = { damaged } })[16] == nil)
	local invalid = pcall(identity.sources, { panes = { localPane, localPane } })
	assert(not invalid)
end)

test("remote display renames keep a conversation's key while any address or provenance change replaces it", function()
	local function remote(id, fields)
		local hopFields = { method = "ssh", host = "forge" }
		for key, value in pairs(fields or {}) do hopFields[key] = value end
		return pane(id, "/sessions/remote.jsonl", { hop(), hop(hopFields) })
	end
	local key = identity.index({ panes = { remote(22) } })[22]
	local renamed = remote(77)
	renamed.title, renamed.cwd, renamed.hostName = "Forge (renamed)", "/elsewhere", "Forge (renamed)"
	assert(identity.index({ panes = { renamed } })[77] == key, "display names and pane IDs are not identity")
	for _, change in ipairs({ { host = "forge-moved" }, { user = "other" }, { principal = "other" }, { method = "mosh" },
		{ from = "elsewhere" } }) do
		local moved = identity.index({ panes = { remote(22, change) } })
		assert(moved[22] ~= key, "an address or provenance change is a different conversation")
		local target, reason = identity.resolve(key, moved, { [22] = {} }, 22)
		assert(target == nil and reason == "missing", "the old key never resolves to the moved conversation")
	end
	assert(identity.index({ panes = { pane(22, "/sessions/remote.jsonl") } })[22] ~= key,
		"the same locator spelled locally is not the remote conversation")
	local document = { panes = { remote(22) } }
	local source = identity.sources(document)[22]
	assert(source.key == key and source.path == "/sessions/remote.jsonl" and not source.localSource,
		"a remote locator is never a local source")
end)

test("two hosts spelling the same session path stay distinct conversations", function()
	local alpha = pane(1, "/sessions/shared.jsonl", { hop(), hop({ method = "ssh", host = "alpha" }) })
	local beta = pane(2, "/sessions/shared.jsonl", { hop(), hop({ method = "ssh", host = "beta" }) })
	local index = identity.index({ panes = { alpha, beta } })
	assert(index[1] ~= index[2])
	local current = { [1] = {}, [2] = {} }
	assert(identity.resolve(index[1], index, current, 2) == 1, "a preferred pane of another host cannot substitute")
	assert(identity.resolve(index[2], index, current, 1) == 2)
end)

return true
