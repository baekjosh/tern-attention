local identity = {}
local HOP_FIELDS = { "principal", "method", "from", "host", "user" }

local function id(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge and value % 1 == 0
end

local function arraySize(value)
	if type(value) ~= "table" then return nil end
	local count = 0
	for index in pairs(value) do
		if not id(index) or index < 1 then return nil end
		count += 1
	end
	for index = 1, count do
		if value[index] == nil then return nil end
	end
	return count
end

local function packed(value)
	return tostring(#value) .. ":" .. value
end

local function conversation(pane)
	local file, provenance = pane.omp_session_file, pane.identity
	if type(file) ~= "string" or file == "" or type(provenance) ~= "table" then return nil end
	local count = arraySize(provenance.hops)
	if count == nil or count == 0 then return nil end
	local parts = { "tern-conversation:1:", packed(file), packed(tostring(count)) }
	for index = 1, count do
		local hop = provenance.hops[index]
		if type(hop) ~= "table" then return nil end
		for _, field in ipairs(HOP_FIELDS) do
			local value = hop[field]
			if type(value) ~= "string" or (field ~= "from" and value == "") then return nil end
			table.insert(parts, packed(value))
		end
	end
	return table.concat(parts)
end

function identity.index(document)
	assert(type(document) == "table", "Invalid native inspect document")
	local count = arraySize(document.panes)
	assert(count ~= nil, "Invalid native inspect panes array")
	local result, seen = {}, {}
	for index = 1, count do
		local pane = document.panes[index]
		assert(type(pane) == "table" and id(pane.pane), "Invalid native inspect pane ID")
		assert(not seen[pane.pane], "Duplicate native inspect pane ID")
		seen[pane.pane] = true
		result[pane.pane] = conversation(pane)
	end
	return result
end

function identity.sources(document)
	local indexed = identity.index(document)
	local result = {}
	for _, pane in ipairs(document.panes) do
		local key = indexed[pane.pane]
		if key ~= nil then
			local localSource = true
			for _, hop in ipairs(pane.identity.hops) do
				if hop.method ~= "local" then localSource = false end
			end
			result[pane.pane] = { key = key, path = pane.omp_session_file, localSource = localSource }
		end
	end
	return result
end

function identity.resolve(key, index, currentPanes, preferredPane)
	if type(key) ~= "string" or key == "" then return nil, "missing" end
	if preferredPane ~= nil and currentPanes[preferredPane] ~= nil and index[preferredPane] == key then
		return preferredPane
	end
	local match = nil
	for pane, candidate in pairs(index) do
		if candidate == key and currentPanes[pane] ~= nil then
			if match ~= nil then return nil, "ambiguous" end
			match = pane
		end
	end
	if match == nil then return nil, "missing" end
	return match
end

return identity
