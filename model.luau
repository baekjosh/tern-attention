local identity = require("./identity")
local model = {}
local recognized = { idle = true, working = true, waiting_input = true, exited = true }
local fields = {
	"serial", "pane", "window", "hostKey", "host", "tab", "session", "title", "sessionName", "hostName",
	"localHost", "parked", "floating", "identityKey", "firstSeenUtc", "disposition", "queueOrder",
	"attentionRevision", "reviewRevision", "reviewKind", "reviewSuperseded", "waiting", "delivery", "startup", "nativeState",
	"alert", "turn", "finishedTurn", "finishedResult", "legacy",
	"deferredPane", "deferredWork", "deferredResult", "deferredUtc", "deferredWorkAfter", "deferredWorkBefore", "deferredWaitingUtc",
	"retained", "priority", "manualRevisit",
	"sourceSessionId", "source", "noOpenPane", "replacedSource",
	"waitingTurn", "sourceGap", "sourceQuestionSuperseded", "sourceQuestionRevision",
	"sourceQuestionBaseline", "sourceWorkUtc",
}
local deferredFields = { "deferredPane", "deferredWork", "deferredResult", "deferredUtc", "deferredWorkAfter", "deferredWorkBefore", "deferredWaitingUtc" }
local known = {}
for _, key in ipairs(fields) do known[key] = true end
-- Retired record fields are discarded on load; any other field this runtime does not model is carried
-- through every save unchanged so a newer writer's durable facts survive.
local retiredRecordFields = { semantic = true, correction = true, scopeHumanId = true, scopePendingBaseline = true, scopeBaselineRevision = true,
	untilUtc = true, availableOn = true, availableTime = true, zone = true, blockerEpisode = true, laterEpisode = true, laterUtc = true }

local function label(value, fallback)
	return if type(value) == "string" and value ~= "" then value else fallback
end

local function finite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer(value)
	return finite(value) and value >= 0 and value % 1 == 0
end

local function identifier(value)
	return integer(value) or (type(value) == "string" and value ~= "")
end

local function plain(value)
	return type(value) == "table" and not getmetatable(value)
end
local function arraySize(value)
	assert(plain(value), "Invalid triage store: expected array")
	local count = 0
	for index in pairs(value) do
		assert(integer(index) and index >= 1, "Invalid triage record index")
		count += 1
	end
	for index = 1, count do assert(value[index] ~= nil, "Invalid triage array gap") end
	return count
end

local function changed(state, entry, key, value)
	if entry[key] == value then return false end
	entry[key] = value
	-- Every durable mutation retires the entry's cached snapshot copy; the next save re-copies it.
	entry.durableCopy = nil
	state.persistenceRevision += 1
	return true
end

local function pending(entry)
	return entry.reviewRevision ~= nil or entry.waiting or entry.delivery or entry.startup or entry.deferredResult ~= nil
end

-- The source reader's per-field trust (source_facts.py coverage.fields): "unknown" means that field's records did not
-- parse; an absent table (older captures, fixtures) asserts nothing.
local function fieldUnknown(coverage, field)
	return type(coverage) == "table" and type(coverage.fields) == "table" and coverage.fields[field] == "unknown"
end

local function historyApplicable(source)
	local coverage = if type(source.coverage) == "table" then source.coverage else {}
	return source.selection == "disk-replayed" and coverage.recordsComplete ~= false
		and coverage.historyScope ~= "unavailable" and coverage.historyScope ~= "observed-prefix"
		and not fieldUnknown(coverage, "questions")
end

local function historyCurrent(entry)
	local observation = entry.sourceObservation
	return entry.stale ~= true and entry.source ~= nil and entry.source.complete == true and historyApplicable(entry.source)
		and observation ~= nil and (observation.status == "ready" or observation.status == "unchanged")
		and observation.revision == entry.source.revision and observation.selection == "disk-replayed" and observation.recordsComplete ~= false
		and observation.historyScope ~= "unavailable" and observation.historyScope ~= "observed-prefix"
		and observation.questionSupport ~= "unknown"
end

local function questionCoverageComplete(source)
	local coverage = source.questionCoverage
	return historyApplicable(source) and source.complete == true and type(coverage) == "table" and coverage.status == "complete"
		and integer(coverage.knownTotal) and integer(coverage.included) and coverage.omitted == 0
		and coverage.knownTotal == coverage.included and coverage.included == #(source.questions or {})
end

local function questionState(source)
	if source == nil then return false, false end
	local current, open, fallback = {}, false, false
	for _, question in ipairs(source.questions or {}) do
		if question.status == "open" and question.scope ~= "observed-prefix" then current[question.id] = true end
	end
	local ledger = source.lastKnown or source
	for _, questions in ipairs({ ledger.questions or {}, ledger.omittedQuestions or {} }) do
		for _, question in ipairs(questions) do
			if question.status == "open" and question.scope ~= "observed-prefix" and (source.lastKnown ~= nil or historyApplicable(source)) then
				open = true
				if not source.complete or not current[question.id] then fallback = true end
			end
		end
	end
	return open, fallback
end

local function conditionFor(entry)
	return entry.condition or (if entry.waiting then "waiting" elseif entry.delivery then "delivery"
		elseif entry.startup then "startup" else nil)
end

local function passiveCurrent(entry)
	return entry.nativeState ~= "working" and entry.reviewSuperseded ~= true
end

local function sourceQuestionCurrent(entry)
	return entry.sourceOpen == true and entry.nativeState ~= "working" and entry.sourceQuestionSuperseded ~= true
end

-- Line-two wording of a row's need (view.luau renders need.text verbatim).
local PROVIDER_NEEDS = { rate_limit = "Rate limited", usage_limit = "Usage limit reached", api_error = "API error",
	provider = "Provider error" }
local REVIEW_NEEDS = { done = "Reply to review", update = "New update", failed = "Agent reported failure",
	exited = "Agent exited", waiting = "Previous input request", delivery = "Previous delivery problem",
	startup = "Previous startup problem", manual = "Manual revisit", legacy = "Saved review" }
-- "Asks: " plus this many characters stays within the ~40 the line has room for.
local QUESTION_NEED_CHARS = 34

-- The kind of provider error that ended the agent's last recorded turn, while it still stands: not while the agent works
-- again, and not when that work started after the error was recorded (`sourceWorkUtc`).
local function providerError(entry)
	local source = entry.source
	local failure = if source then source.lastError else nil
	if type(failure) ~= "table" or PROVIDER_NEEDS[failure.kind] == nil or not finite(failure.atUtc)
		or entry.nativeState == "working" or fieldUnknown(source.coverage, "clock")
		or (entry.sourceWorkUtc ~= nil and failure.atUtc <= entry.sourceWorkUtc) then return nil end
	return failure.kind
end

-- A usage or rate limit's three wordings: while omp blocks every account (the row rests, out of Attention), once
-- that block's deadline passed (due, never claimed as reset: the provider may still refuse), and with no deadline.
local LIMIT_NEEDS = {
	usage_limit = { "Usage limit", "Usage limit · reset due", "Usage limit · reset time unknown" },
	rate_limit = { "Rate limited", "Rate limit · reset due", "Rate limited · reset time unknown" },
}

-- Until when a limited row rests: the reader's `limit` says every enabled account of the provider is blocked until
-- `untilUtc`. Nil once that passes, for any other error, or when the store could not say (the row stays in Attention).
local function restingUntil(entry, nowUtc)
	local kind = providerError(entry)
	if LIMIT_NEEDS[kind] == nil then return nil end
	local limit = entry.source.lastError.limit
	if type(limit) ~= "table" or limit.status ~= "blocked" or not finite(limit.untilUtc) or not finite(nowUtc)
		or nowUtc >= limit.untilUtc then return nil end
	return limit.untilUtc
end

local function attentionEligible(entry)
	return entry.disposition == "active" and (conditionFor(entry) ~= nil or sourceQuestionCurrent(entry)
		or (providerError(entry) ~= nil and entry.resting == nil) or (passiveCurrent(entry)
		and (entry.reviewRevision ~= nil or entry.deferredResult ~= nil or entry.manualRevisit == true)))
end

local function reasonFor(entry)
	local condition
	if entry.waiting then condition = "Needs input"
	elseif entry.delivery then condition = "Prompt not delivered"
	elseif entry.startup then condition = "Agent startup problem" end
	if condition ~= nil and entry.stale then condition = "Last known: " .. condition end
	local review
	if passiveCurrent(entry) and entry.reviewRevision ~= nil then
		if entry.reviewKind == "done" then review = "Turn finished · review pending"
		elseif entry.reviewKind == "manual" then review = "Manual revisit"
		elseif entry.reviewKind == "failed" then review = "Agent reported failure · review pending"
		elseif entry.reviewKind == "exited" then review = "Agent exited · review pending"
		elseif entry.reviewKind == "legacy" then review = "Saved attention · review pending"
		elseif entry.reviewKind == "waiting" then review = "Previous input request · review pending"
		elseif entry.reviewKind == "delivery" then review = "Previous delivery problem · review pending"
		elseif entry.reviewKind == "startup" then review = "Previous startup problem · review pending"
		else review = "Unreviewed update" end
	elseif passiveCurrent(entry) and entry.deferredResult ~= nil then
		review = "Observed completion · identity unverified"
	end
	if condition == nil and sourceQuestionCurrent(entry) then
		return if entry.sourceOpenLastKnown or entry.stale or not historyCurrent(entry) then "Last recorded question unresolved" else "Recorded question unresolved"
	end
	local provider = if condition == nil then providerError(entry) else nil
	if provider then
		local phrase = (if entry.stale then "Last known: " else "Recorded: ") .. PROVIDER_NEEDS[provider]
		return if review then phrase .. " · review pending" else phrase
	end
	if condition or review then return if condition and review then condition .. " · " .. review else condition or review end
	if passiveCurrent(entry) and entry.manualRevisit then return "Manual revisit" end
	if entry.disposition == "reference" then return "Kept as reference" end
	if entry.disposition == "finished" then return "Finished for now" end
	return if entry.nativeState == "working" then "Working" elseif entry.nativeState == "exited" then "Agent exited"
		elseif entry.source and entry.source.lastFinal then "Recorded final reply" else "No established next move"
end

-- One open question's words for line two: whitespace collapsed, no closing punctuation, cut at a word with "…".
local function questionNeed(source)
	local ledgers = { source.questions or {} }
	if type(source.lastKnown) == "table" then table.insert(ledgers, source.lastKnown.questions or {}) end
	for _, ledger in ipairs(ledgers) do
		for index = #ledger, 1, -1 do
			local question = ledger[index]
			if question.status == "open" and type(question.text) == "string" then
				local words = string.match((string.gsub(question.text, "%s+", " ")), "^%s*(.-)%s*$")
				words = string.gsub(words, "[%?%.:;,!%s]+$", "")
				if words ~= "" then
					local length = utf8.len(words)
					if length == nil then break end
					if length > QUESTION_NEED_CHARS then
						local cut = string.sub(words, 1, utf8.offset(words, QUESTION_NEED_CHARS + 1) - 1)
						local atWord = string.match(cut, "^(.*%S)%s+%S*$")
						if atWord and utf8.len(atWord) > QUESTION_NEED_CHARS // 2 then cut = atWord end
						words = string.gsub(cut, "[%?%.:;,!%s]+$", "") .. "…"
					end
					return "Asks: " .. words
				end
			end
		end
	end
	return "Asks a question"
end

-- What a working agent is waiting on and since when. The source names it: a tool call started without a result
-- ("tool", with its name) or the model call since the prompt or tool result that started it ("model"), never earlier
-- than the observed start of work, so a call left open by an older turn cannot backdate this one. Without that,
-- when it last did something on record (its newest assistant/tool record, the prompt, or the observed start of
-- work, whichever is latest), waiting on nothing known. Nil without a source whose clock parsed.
local function workingSince(entry)
	local source = entry.source
	if source == nil or fieldUnknown(source.coverage, "clock") then return nil end
	local flight = source.inFlight
	if type(flight) == "table" and finite(flight.sinceUtc) and (flight.kind == "tool" or flight.kind == "model") then
		local since = flight.sinceUtc
		if finite(entry.sourceWorkUtc) and entry.sourceWorkUtc > since then since = entry.sourceWorkUtc end
		return since, flight.kind, if flight.kind == "tool" and type(flight.tool) == "string" then flight.tool else nil
	end
	local since = nil
	-- Not ipairs: any of the three may be nil.
	for _, at in { source.lastActivityAtUtc or false, source.lastInteractionAtUtc or false, entry.sourceWorkUtc or false } do
		if finite(at) and (since == nil or at > since) then since = at end
	end
	return since
end

-- The row's need (kind, text, sinceUtc), in reasonFor's precedence; a stale row's need is its last known one.
local function needFor(entry)
	local condition, kind, text, since, wait, tool, untilUtc = conditionFor(entry), nil, nil, nil, nil, nil, nil
	local provider = if condition == nil then providerError(entry) else nil
	if condition == "waiting" then kind, text = "waiting", "Waiting for input"
	elseif condition == "delivery" then kind, text = "undelivered", "Prompt not delivered"
	elseif condition == "startup" then kind, text = "startup", "Agent didn't start"
	elseif sourceQuestionCurrent(entry) then kind, text = "question", questionNeed(entry.source)
	elseif provider and LIMIT_NEEDS[provider] then
		local words, limit = LIMIT_NEEDS[provider], entry.source.lastError.limit
		if entry.resting then kind, text, untilUtc = "resting", words[1], entry.resting
		else kind, text = "provider", if type(limit) == "table" and limit.status == "blocked" then words[2] else words[3] end
	elseif provider then kind, text = "provider", PROVIDER_NEEDS[provider]
	elseif passiveCurrent(entry) and entry.reviewRevision ~= nil then kind, text = "review", REVIEW_NEEDS[entry.reviewKind] or "New update"
	elseif passiveCurrent(entry) and entry.deferredResult ~= nil then kind, text = "review", "Completion unverified"
	elseif passiveCurrent(entry) and entry.manualRevisit then kind, text = "review", "Manual revisit"
	elseif entry.disposition == "active" and entry.nativeState == "working" then
		kind, text = "working", "Working"
		since, wait, tool = workingSince(entry)
	else return nil end
	if entry.stale then return "offline", "Last known: " .. text, nil end
	return kind, text, since, wait, tool, untilUtc
end

-- Rows compare shallowly (publish), so an unchanged need keeps the previous row's table.
local function needOf(entry)
	local kind, text, since, wait, tool, untilUtc = needFor(entry)
	if kind == nil then return nil end
	local previous = if entry.row then entry.row.need else nil
	if previous and previous.kind == kind and previous.text == text and previous.sinceUtc == since
		and previous.wait == wait and previous.tool == tool and previous.untilUtc == untilUtc then return previous end
	return { kind = kind, text = text, sinceUtc = since, wait = wait, tool = tool, untilUtc = untilUtc }
end

local function ranked(a, b)
	local ap, bp = a.priority or 4, b.priority or 4
	if ap ~= bp then return ap < bp end
	local ac, bc = conditionFor(a) ~= nil, conditionFor(b) ~= nil
	if ac ~= bc then return ac end
	if a.queueOrder ~= b.queueOrder then return a.queueOrder < b.queueOrder end
	return a.serial < b.serial
end

local function publish(state)
	local eligible, collisions = {}, {}
	for _, entry in pairs(state.entries) do
		table.insert(eligible, entry)
		local context = entry.sessionName .. " · " .. entry.hostName
		local titles = collisions[context] or {}
		collisions[context] = titles
		titles[entry.title] = (titles[entry.title] or 0) + 1
	end
	table.sort(eligible, function(a, b)
		local sessions, tabs = state.sessionOrder or {}, state.tabOrder or {}
		local as, bs = sessions[a.session] or math.huge, sessions[b.session] or math.huge
		if as ~= bs then return as < bs end
		local at, bt = tabs[a.tab] or math.huge, tabs[b.tab] or math.huge
		if at ~= bt then return at < bt end
		return a.serial < b.serial
	end)
	local old, rows, targets = state.presentation, {}, {}
	local attentionCount, reachableCount, awaitingHeaderCount = 0, 0, 0
	local counted = state.complete or state.status == "unsaved"
	local offline = if state.status == "partial" then state.offlineHosts else nil
	local different = old.status ~= state.status or old.message ~= state.message
		or (old.count ~= nil) ~= counted or #old.rows ~= #eligible
	local previousOffline = old.offlineHosts or {}
	if #previousOffline ~= #(offline or {}) then different = true end
	for index, offlineHost in ipairs(previousOffline) do
		local current = if offline ~= nil then offline[index] else nil
		if current == nil or current.name ~= offlineHost.name or current.key ~= offlineHost.key then different = true end
	end
	for index, entry in ipairs(eligible) do
		local context = entry.sessionName .. " · " .. entry.hostName
		if collisions[context][entry.title] > 1 then context ..= " · #" .. tostring(entry.serial) end
		local candidate = {
			workId = "work:" .. tostring(entry.serial), serial = entry.serial,
			pane = if entry.noOpenPane then nil else entry.pane, host = entry.host, hostKey = entry.hostKey,
			live = state.byPane[entry.pane] == entry,
			tab = entry.tab, session = entry.session, title = entry.title, sessionName = entry.sessionName,
			hostName = entry.hostName, localHost = entry.localHost, context = context, reason = reasonFor(entry),
			firstSeenUtc = entry.firstSeenUtc, disposition = entry.disposition, retained = entry.retained == true,
			priority = entry.priority, queueOrder = entry.queueOrder, identityKey = entry.identityKey,
			attention = attentionEligible(entry), attentionRevision = entry.attentionRevision, reviewRevision = entry.reviewRevision,
			condition = conditionFor(entry), reviewKind = entry.reviewKind, reviewSuperseded = entry.reviewSuperseded == true,
			sourceQuestionCurrent = sourceQuestionCurrent(entry), need = needOf(entry), resting = entry.resting,
			stale = entry.stale == true, navigable = entry.navigable == true, orphaned = entry.orphaned == true,
			retryableHeaderRoute = entry.retryableHeaderRoute == true,
			unavailableReason = entry.unavailableReason, parked = entry.parked, floating = entry.floating,
			nativeState = entry.nativeState or "unknown", runtimeObservedAtUtc = entry.runtimeObservedAtUtc,
			source = entry.source, sourceObservation = entry.sourceObservation, sourceSessionId = entry.sourceSessionId,
		}
		local row, same = entry.row, entry.row ~= nil
		if row then
			for key, value in pairs(candidate) do if row[key] ~= value then same = false; break end end
			if same then for key, value in pairs(row) do if candidate[key] ~= value then same = false; break end end end
		end
		if not same then row = candidate; entry.row = row end
		rows[index] = row
		if old.rows[index] ~= row then different = true end
		if row.attention then
			attentionCount += 1
			if row.pane ~= nil and (row.navigable or row.retryableHeaderRoute) then
				targets[row.pane] = true
				if row.navigable then reachableCount += 1 else awaitingHeaderCount += 1 end
			end
		end
	end
	if different then
		state.presentation = {
			rows = rows, status = state.status, message = state.message, revision = old.revision + 1,
			count = if counted then #rows else nil, knownCount = #rows, allCount = #rows,
			attentionCount = attentionCount, reachableCount = reachableCount,
			awaitingHeaderCount = awaitingHeaderCount,
			attentionTargets = targets, offlineHosts = offline,
		}
	end
	return state.presentation
end

local retiredSourceFields = { context = true, semanticRevision = true, state = true, messages = true, contextCoverage = true }

-- A stored reply keeps only the excerpt the rail shows (view.luau's source details label 300 characters); the whole reply
-- stays in the agent's own session file. Human input is shown only by its time, so its text is not stored. The source
-- reader applies the same bound (source_facts.py REPLY_TEXT); this one migrates records saved before it.
local REPLY_TEXT_CHARS = 300

-- A copy of `source` with replies bounded, or nil when it already is.
local function boundedReplies(source)
	local changed = false
	local function bound(ledger)
		if type(ledger) ~= "table" then return ledger end
		local copy = nil
		for _, field in ipairs({ "lastFinal", "lastAssistant" }) do
			local reply = ledger[field]
			if type(reply) == "table" and type(reply.text) == "string" then
				local cut = utf8.offset(reply.text, REPLY_TEXT_CHARS + 1)
				if cut and cut <= #reply.text then
					copy = copy or table.clone(ledger)
					copy[field] = table.clone(reply)
					copy[field].text, copy[field].textTruncated = string.sub(reply.text, 1, cut - 1), true
				end
			end
		end
		if type(ledger.lastHuman) == "table" and ledger.lastHuman.text ~= nil then
			copy = copy or table.clone(ledger)
			copy.lastHuman = table.clone(ledger.lastHuman)
			copy.lastHuman.text = nil
		end
		if copy then changed = true end
		return copy or ledger
	end
	local result = bound(source)
	if type(result.lastKnown) == "table" then
		local lastKnown = bound(result.lastKnown)
		if lastKnown ~= result.lastKnown then
			if result == source then result = table.clone(source) end
			result.lastKnown = lastKnown
		end
	end
	return if changed then result else nil
end

local function copyValue(value, depth, factual)
	if type(value) ~= "table" then return value end
	assert((depth or 0) < 32 and plain(value), "Invalid triage nested evidence")
	local result = {}
	for key, field in pairs(value) do
		if not factual or not retiredSourceFields[key] then result[key] = copyValue(field, (depth or 0) + 1, factual) end
	end
	return result
end

local function copyRecord(entry)
	local record = {}
	for _, key in ipairs(fields) do record[key] = copyValue(entry[key], 0, key == "source") end
	return record
end

local function validateRecord(record)
	assert(plain(record) and integer(record.serial) and record.serial > 0 and identifier(record.pane)
		and type(record.window) == "string" and type(record.hostKey) == "string"
		and finite(record.firstSeenUtc) and record.firstSeenUtc >= 0
		and integer(record.queueOrder) and integer(record.attentionRevision) and integer(record.turn)
		and (record.disposition == "active" or record.disposition == "reference" or record.disposition == "finished"),
		"Invalid triage durable record")
	assert(record.lastResultAt == nil and record.eventObservedAt == nil and record.workObservedAt == nil
		and record.deferredWorkAt == nil and record.deferredAt == nil and record.deferredWaitingAt == nil, "Unsupported triage runtime-clock record")
	for _, key in ipairs({ "title", "sessionName", "hostName" }) do
		assert(type(record[key]) == "string", "Invalid triage metadata")
	end
	for _, key in ipairs({ "host", "tab", "session", "deferredPane" }) do
		assert(record[key] == nil or identifier(record[key]), "Invalid triage native locator")
	end
	for _, key in ipairs({ "localHost", "parked", "floating", "waiting", "delivery", "startup", "alert", "legacy", "reviewSuperseded", "sourceQuestionSuperseded", "deferredWork", "deferredWorkAfter", "deferredWorkBefore" }) do
		assert(record[key] == nil or type(record[key]) == "boolean", "Invalid triage condition")
	end
	assert(record.identityKey == nil or (type(record.identityKey) == "string" and record.identityKey ~= ""), "Invalid triage identity")
	assert(record.nativeState == nil or recognized[record.nativeState], "Invalid triage native state")
	assert(record.reviewKind == nil or record.reviewKind == "done" or record.reviewKind == "failed"
		or record.reviewKind == "exited" or record.reviewKind == "update" or record.reviewKind == "legacy"
		or record.reviewKind == "waiting" or record.reviewKind == "delivery" or record.reviewKind == "startup"
		or record.reviewKind == "manual", "Invalid triage review")
	for _, key in ipairs({ "reviewRevision", "finishedTurn", "sourceQuestionRevision" }) do
		assert(record[key] == nil or integer(record[key]), "Invalid triage revision")
	end
	assert(record.deferredUtc == nil or finite(record.deferredUtc), "Invalid triage observation time")
	assert(record.finishedResult == nil or record.finishedResult == "done" or record.finishedResult == "failed"
		or record.finishedResult == "exited", "Invalid triage terminal cursor")
	assert((record.reviewRevision == nil) == (record.reviewKind == nil), "Invalid triage review evidence")
	assert(record.deferredResult == nil or record.deferredResult == "done" or record.deferredResult == "failed"
		or record.deferredResult == "exited", "Invalid triage deferred result")
	assert(record.deferredResult == nil or (record.deferredUtc ~= nil
		and record.deferredPane ~= nil), "Invalid triage deferred evidence")
	assert(record.deferredWaitingUtc == nil or (finite(record.deferredWaitingUtc)
		and record.deferredPane ~= nil), "Invalid triage deferred input request")
	assert(record.priority == nil or (integer(record.priority) and record.priority <= 3), "Invalid triage priority")
	assert(record.retained == nil or type(record.retained) == "boolean", "Invalid triage retention")
	assert(record.sourceWorkUtc == nil or finite(record.sourceWorkUtc), "Invalid triage source work cutoff")
	if record.sourceQuestionBaseline ~= nil then
		local baseline = record.sourceQuestionBaseline
		assert(plain(baseline) and finite(baseline.capturedAtUtc) and type(baseline.revision) == "string"
			and arraySize(baseline.ids) <= 32, "Invalid triage question baseline")
		local ids = {}
		for _, id in ipairs(baseline.ids) do
			assert(type(id) == "string" and id ~= "" and not ids[id], "Invalid triage question baseline identity")
			ids[id] = true
		end
	end
	for _, key in ipairs({ "sourceSessionId" }) do
		assert(record[key] == nil or type(record[key]) == "string", "Invalid triage source metadata")
	end
	for _, key in ipairs({ "waitingTurn" }) do
		assert(record[key] == nil or integer(record[key]), "Invalid triage episode")
	end
	for _, key in ipairs({ "source" }) do
		assert(record[key] == nil or plain(record[key]), "Invalid triage evidence")
	end
	for _, key in ipairs({ "noOpenPane", "replacedSource", "sourceGap", "manualRevisit" }) do
		assert(record[key] == nil or type(record[key]) == "boolean", "Invalid triage evidence state")
	end
	if record.source then
		assert(record.source.key == record.identityKey and record.source.sessionId == record.sourceSessionId
			and finite(record.source.capturedAtUtc)
			and type(record.source.questions or {}) == "table", "Invalid triage source identity")
	end
end

function model.new(saved)
	local state = {
		entries = {}, byPane = {}, hosts = {}, hostHealth = {}, serial = 0, queueOrder = 0, attentionRevision = 0,
		persistenceRevision = 0, snapshotRevision = -1, status = "loading", complete = false, message = "Loading native agents",
		presentation = { rows = {}, status = "loading", knownCount = 0, revision = 0,
			attentionCount = 0, allCount = 0, reachableCount = 0, awaitingHeaderCount = 0,
			attentionTargets = {}, message = "Loading native agents" },
	}
	if saved == nil then return state end
	assert(plain(saved) and (saved.schema == 1 or saved.schema == 2 or saved.schema == 3), "Invalid triage store schema")
	assert(saved.schema ~= 3 or (saved.records == nil and saved.cursors == nil), "Invalid triage parallel store")
	if saved.semanticConfiguration ~= nil then state.persistenceRevision += 1 end
	local identities, locators = {}, {}
	local function insert(record)
		assert(plain(record), "Invalid triage durable record")
		-- The retired Later queue (disposition `later`, legacy bucket `backlog`): a set-aside record loads as Finished for
		-- now, retained; its Later dates and episodes are retired fields, discarded below.
		if saved.schema ~= 3 then
			record = table.clone(record)
			assert(record.bucket == "p0" or record.bucket == "backlog", "Invalid triage legacy bucket")
			record.disposition = if record.bucket == "backlog" then "finished" else "active"
			record.retained = if record.bucket == "backlog" then true else nil
			record.priority = nil
		elseif record.disposition == "later" then
			record = table.clone(record)
			record.disposition, record.retained = "finished", true
			state.persistenceRevision += 1
		end
		for obsolete in pairs(retiredRecordFields) do
			if record[obsolete] ~= nil then state.persistenceRevision += 1; break end
		end
		if type(record.source) == "table" then
			for obsolete in pairs(retiredSourceFields) do
				if record.source[obsolete] ~= nil then state.persistenceRevision += 1; break end
			end
			local bounded = boundedReplies(record.source)
			if bounded then
				record = table.clone(record)
				record.source = bounded
				state.persistenceRevision += 1
			end
		end
		validateRecord(record)
		assert(state.entries[record.serial] == nil, "Invalid triage duplicate serial")
		if record.identityKey ~= nil then
			local composite = record.identityKey .. ":" .. tostring(#(record.sourceSessionId or ""))
				.. ":" .. (record.sourceSessionId or "")
			assert(not identities[composite], "Invalid triage duplicate identity")
			identities[composite] = true
		end
		local entry = copyRecord(record)
		if saved.schema == 3 then
			for key, value in pairs(record) do
				if not known[key] and not retiredRecordFields[key] then
					entry.unknown = entry.unknown or {}
					entry.unknown[key] = copyValue(value, 0, false)
				end
			end
		end
		if entry.reviewSuperseded == nil and entry.nativeState == "working" then
			changed(state, entry, "reviewSuperseded", true)
		end
		if entry.sourceQuestionSuperseded == nil and (entry.nativeState == "working" or entry.reviewSuperseded == true) then
			changed(state, entry, "sourceQuestionSuperseded", true)
			changed(state, entry, "sourceQuestionRevision", entry.attentionRevision)
		end
		entry.restored, entry.stale, entry.orphaned, entry.navigable = true, true, true, false
		entry.unavailableReason = if entry.noOpenPane then "No open pane" else "unverified"
		entry.sourceOpen, entry.sourceOpenLastKnown = questionState(entry.source)
		state.entries[entry.serial] = entry
		state.serial = math.max(state.serial, entry.serial)
		state.queueOrder = math.max(state.queueOrder, entry.queueOrder)
		state.attentionRevision = math.max(state.attentionRevision, entry.attentionRevision, entry.reviewRevision or 0)
	end
	local records = if saved.schema == 3 then saved.items else saved.records
	for index = 1, arraySize(records) do
		local record = records[index]
		if saved.schema == 1 then
			assert(plain(record) and type(record.window) == "string" and type(record.host) == "string"
				and record.host ~= "" and identifier(record.pane) and finite(record.firstSeenUtc) and record.firstSeenUtc >= 0
				and (record.bucket == "p0" or record.bucket == "backlog"), "Invalid triage legacy record")
			local locator = tostring(#record.window) .. ":" .. record.window .. tostring(#record.host) .. ":" .. record.host
				.. ":" .. type(record.pane) .. ":" .. tostring(record.pane)
			assert(not locators[locator], "Invalid triage duplicate locator")
			locators[locator] = true
			insert({ serial = index, pane = record.pane, window = record.window, hostKey = record.host,
				firstSeenUtc = record.firstSeenUtc, bucket = record.bucket, queueOrder = index,
				attentionRevision = index, reviewRevision = index, reviewKind = "legacy", legacy = true,
				title = "Saved agent", sessionName = "Unknown session", hostName = record.host,
				localHost = record.host == "local", turn = 0 })
		else
			insert(record)
			if saved.schema == 2 then assert(pending(record), "Invalid triage pending record") end
		end
	end
	if saved.schema == 2 then
		for index = 1, arraySize(saved.cursors) do
			local cursor = saved.cursors[index]
			insert(cursor)
			assert(not pending(cursor), "Invalid triage quiet cursor")
		end
	end
	if saved.schema ~= 1 then
		for _, key in ipairs({ "serial", "queueOrder", "attentionRevision" }) do
			assert(integer(saved[key]) and saved[key] >= state[key], "Invalid triage counter")
			state[key] = saved[key]
		end
	end
	for _, entry in pairs(state.entries) do
		state.attentionRevision = math.max(state.attentionRevision, entry.sourceQuestionRevision or 0)
	end
	if saved.schema ~= 3 then state.persistenceRevision = 1 end
	publish(state)
	return state
end

function model.snapshot(state)
	-- Durable copies are cached per entry and retired by changed(), so a save after a revision
	-- change re-copies only what changed. A same-revision save distrusts that cache: its caller
	-- may still hold and mutate the previous output, so it never shares item tables with it.
	local reuse = state.persistenceRevision ~= state.snapshotRevision
	local items, entries = {}, {}
	for _, entry in pairs(state.entries) do table.insert(entries, entry) end
	table.sort(entries, function(a, b) return a.serial < b.serial end)
	for _, entry in ipairs(entries) do
		local item = if reuse then entry.durableCopy else nil
		if item == nil then
			item = copyRecord(entry)
			for key, value in pairs(entry.unknown or {}) do item[key] = copyValue(value, 0, false) end
			entry.durableCopy = item
		end
		table.insert(items, item)
	end
	state.snapshotRevision = state.persistenceRevision
	return { schema = 3, items = items, serial = state.serial,
		queueOrder = state.queueOrder, attentionRevision = state.attentionRevision }
end

function model.current(state)
	return state.presentation
end

local function newEntry(state, pane, context)
	state.serial += 1
	local entry = {
		serial = state.serial, pane = pane, window = context.window or "", hostKey = "",
		title = "Agent", sessionName = "Unknown session", hostName = "Unknown host", localHost = false,
		firstSeenUtc = context.nowUtc or 0, disposition = "active", queueOrder = 0, attentionRevision = 0, turn = 0,
		stale = true, navigable = false, orphaned = true, unavailableReason = "unverified",
	}
	state.entries[entry.serial] = entry
	state.persistenceRevision += 1
	return entry
end

local function attention(state, entry, now, reviewKind)
	if not pending(entry) then
		state.queueOrder += 1
		changed(state, entry, "queueOrder", state.queueOrder)
	end
	changed(state, entry, "firstSeenUtc", now)
	state.attentionRevision += 1
	changed(state, entry, "attentionRevision", state.attentionRevision)
	if reviewKind ~= nil then
		changed(state, entry, "reviewRevision", state.attentionRevision)
		changed(state, entry, "reviewKind", reviewKind)
		changed(state, entry, "reviewSuperseded", false)
	end
end

local function observe(state, entry, event, now, historical)
	-- A reply acknowledges only the exact review revision the user addressed, captured before
	-- newer completions in the same batch can replace it. It never touches live conditions or
	-- navigation state.
	if event.kind == "reply" then
		if entry.reviewRevision ~= nil and entry.reviewRevision == event.reviewRevision then
			changed(state, entry, "reviewRevision", nil)
			changed(state, entry, "reviewKind", nil)
		end
		return
	end
	local working = event.kind == "state" and event.new == "working" and event.old ~= "working"
	local waiting = event.kind == "state" and event.new == "waiting_input" and event.old ~= "waiting_input"
	local finished = event.kind == "finished" and (event.result == "done" or event.result == "failed" or event.result == "exited")
	if not working and not waiting and not finished then return end
	-- Runtime clocks order only events observed in this VM; persisted replay carries causal order instead.
	-- Turns and deferred work flags are plugin observation facts, not native turn identities.
	local at = if historical then nil else event.at or 0
	if at ~= nil and not finished and ((entry.eventObservedAt ~= nil and at < entry.eventObservedAt)
		or (entry.workObservedAt ~= nil and at < entry.workObservedAt)) then return end
	if working then
		if at ~= nil and entry.workObservedAt == at and entry.finishedTurn ~= entry.turn then return end
		changed(state, entry, "turn", entry.turn + 1)
		changed(state, entry, "reviewSuperseded", true)
		state.attentionRevision += 1
		changed(state, entry, "sourceQuestionSuperseded", true)
		changed(state, entry, "sourceQuestionRevision", state.attentionRevision)
		changed(state, entry, "sourceWorkUtc", math.max(entry.sourceWorkUtc or now, now))
		if at ~= nil then entry.workObservedAt, entry.eventObservedAt = at, at end
		return
	end
	if waiting then
		if entry.waiting and not entry.conditionRaised and entry.turn > (entry.waitingTurn or 0)
			and (entry.eventObservedAt == nil or (at ~= nil and at > entry.eventObservedAt)) then
			attention(state, entry, now, nil)
			changed(state, entry, "waitingTurn", entry.turn)
		end
		if at ~= nil then entry.eventObservedAt = at end
		return
	end
	local resultTurn = entry.turn
	if at ~= nil then
		if entry.lastResultAt ~= nil and at < entry.lastResultAt then return end
		if entry.workObservedAt ~= nil and at < entry.workObservedAt then resultTurn = math.max(0, resultTurn - 1) end
	end
	if entry.finishedTurn ~= nil and resultTurn < entry.finishedTurn then return end
	if entry.finishedTurn == resultTurn and entry.finishedResult == event.result then
		if at ~= nil then
			entry.lastResultAt = at
			entry.eventObservedAt = math.max(entry.eventObservedAt or at, at)
		end
		return
	end
	changed(state, entry, "finishedTurn", resultTurn)
	changed(state, entry, "finishedResult", event.result)
	if at ~= nil then
		entry.lastResultAt = at
		entry.eventObservedAt = math.max(entry.eventObservedAt or at, at)
	else entry.lastResultAt = nil end
	attention(state, entry, now, event.result)
	if resultTurn < entry.turn then changed(state, entry, "reviewSuperseded", true) end
end

local function clearDeferred(state, entry)
	for _, key in ipairs(deferredFields) do changed(state, entry, key, nil) end
	entry.deferredWorkAt, entry.deferredAt, entry.deferredObservedAt, entry.deferredWaitingAt = nil, nil, nil, nil
end

-- One durable record survives for a pane whose keyless restored record duplicates another record:
-- the earlier serial keeps its place, the newer review, age and observation cursors win.
local function absorb(state, keep, other)
	local newer = if other.attentionRevision > keep.attentionRevision then other else keep
	local review = if (other.reviewRevision or -1) > (keep.reviewRevision or -1) then other else keep
	local deferred = if newer.deferredPane ~= nil or (keep.deferredPane == nil and other.deferredPane == nil) then newer
		elseif keep.deferredPane ~= nil then keep else other
	local merged = {}
	for _, key in ipairs(fields) do merged[key] = newer[key] end
	merged.serial, merged.queueOrder = keep.serial, keep.queueOrder
	merged.identityKey = keep.identityKey or other.identityKey
	merged.disposition = if keep.disposition == "active" or other.disposition == "active" then "active" else newer.disposition
	merged.retained = keep.retained or other.retained
	merged.priority = keep.priority or other.priority
	merged.firstSeenUtc = math.max(keep.firstSeenUtc, other.firstSeenUtc)
	merged.attentionRevision = math.max(keep.attentionRevision, other.attentionRevision)
	merged.reviewRevision, merged.reviewKind = review.reviewRevision, review.reviewKind
	merged.reviewSuperseded = review.reviewSuperseded == true
		or (keep.reviewRevision == other.reviewRevision
			and (keep.reviewSuperseded == true or other.reviewSuperseded == true))
	local question = if (other.sourceQuestionRevision or -1) > (keep.sourceQuestionRevision or -1) then other else keep
	merged.sourceQuestionRevision = question.sourceQuestionRevision
	merged.sourceQuestionSuperseded = question.sourceQuestionSuperseded
	if keep.sourceQuestionRevision == other.sourceQuestionRevision then
		merged.sourceQuestionSuperseded = if keep.sourceQuestionSuperseded == true or other.sourceQuestionSuperseded == true then true
			elseif keep.sourceQuestionSuperseded == false or other.sourceQuestionSuperseded == false then false else nil
	end
	local sourceOwner = if keep.sourceQuestionRevision ~= other.sourceQuestionRevision and question.source ~= nil then question
		elseif newer.source ~= nil then newer elseif keep.source ~= nil then keep else other
	merged.source, merged.sourceSessionId, merged.sourceGap = sourceOwner.source, sourceOwner.sourceSessionId, sourceOwner.sourceGap
	merged.sourceQuestionBaseline = sourceOwner.sourceQuestionBaseline
	merged.sourceWorkUtc = if keep.sourceWorkUtc and other.sourceWorkUtc then math.max(keep.sourceWorkUtc, other.sourceWorkUtc)
		else keep.sourceWorkUtc or other.sourceWorkUtc
	for _, key in ipairs({ "waiting", "delivery", "startup", "alert" }) do
		if keep[key] or other[key] then merged[key] = true end
	end
	merged.legacy = nil
	for _, key in ipairs(deferredFields) do merged[key] = deferred[key] end
	-- Merged durable fields bypass changed(), so the survivor's cached snapshot copy retires here too.
	keep.durableCopy = nil
	for _, key in ipairs(fields) do keep[key] = merged[key] end
	keep.sourceOpen, keep.sourceOpenLastKnown = questionState(keep.source)
	keep.sourceObservation, keep.sourceObservedAtUtc = sourceOwner.sourceObservation, sourceOwner.sourceObservedAtUtc
	keep.eventObservedAt, keep.workObservedAt, keep.lastResultAt = newer.eventObservedAt, newer.workObservedAt, newer.lastResultAt
	keep.deferredWorkAt, keep.deferredAt = deferred.deferredWorkAt, deferred.deferredAt
	keep.deferredObservedAt, keep.deferredWaitingAt = deferred.deferredObservedAt, deferred.deferredWaitingAt
	keep.restored = keep.restored == true and other.restored == true
	keep.conditionGap = keep.conditionGap == true or other.conditionGap == true
	keep.identityRejected, keep.row = false, nil
	state.entries[other.serial] = nil
	state.persistenceRevision += 1
end

local function deferObservation(state, entry, event, now)
	local at = event.at or 0
	local finished = event.kind == "finished" and (event.result == "done" or event.result == "failed" or event.result == "exited")
	if not finished and ((entry.deferredObservedAt ~= nil and at < entry.deferredObservedAt)
		or (entry.eventObservedAt ~= nil and at < entry.eventObservedAt)
		or (entry.workObservedAt ~= nil and at < entry.workObservedAt)) then return end
	if event.kind == "state" and event.new == "working" and event.old ~= "working" then
		if entry.deferredWorkAt == at and (entry.deferredResult == nil or entry.deferredWorkAfter) then return end
		entry.deferredWorkAt, entry.deferredObservedAt = at, at
		changed(state, entry, "deferredPane", event.pane)
		changed(state, entry, "deferredWork", true)
		changed(state, entry, "deferredWorkAfter", entry.deferredResult ~= nil)
		-- Work after a deferred input request answered it; only a request newer than all deferred work replays.
		entry.deferredWaitingAt = nil
		changed(state, entry, "deferredWaitingUtc", nil)
	elseif event.kind == "state" and event.new == "waiting_input" and event.old ~= "waiting_input" then
		if entry.deferredWaitingUtc ~= nil and entry.deferredWaitingAt == at then return end
		entry.deferredWaitingAt = at
		entry.deferredObservedAt = math.max(entry.deferredObservedAt or at, at)
		changed(state, entry, "deferredPane", event.pane)
		changed(state, entry, "deferredWaitingUtc", now)
	elseif finished then
		if (entry.deferredAt ~= nil and at < entry.deferredAt)
			or (entry.lastResultAt ~= nil and at < entry.lastResultAt) then return end
		if event.result == entry.deferredResult and not entry.deferredWorkAfter then return end
		local beforeWork = entry.deferredWorkAt ~= nil and at < entry.deferredWorkAt
		changed(state, entry, "deferredWorkBefore", entry.deferredWorkBefore == true or (entry.deferredWork == true and not beforeWork))
		entry.deferredAt = at
		entry.deferredObservedAt = math.max(entry.deferredObservedAt or at, at)
		changed(state, entry, "deferredPane", event.pane)
		changed(state, entry, "deferredResult", event.result)
		changed(state, entry, "deferredUtc", now)
		changed(state, entry, "deferredWorkAfter", beforeWork)
		if entry.deferredWaitingAt == nil or at >= entry.deferredWaitingAt then
			entry.deferredWaitingAt = nil
			changed(state, entry, "deferredWaitingUtc", nil)
		end
		if entry.queueOrder == 0 then
			state.queueOrder += 1
			changed(state, entry, "queueOrder", state.queueOrder)
		end
	end
end

local function stableHeader(fact)
	local issues = fact.coverage.issues
	if issues ~= nil and type(issues) ~= "table" then return false end
	for _, issue in ipairs(issues or {}) do if issue == "source-changed-during-read" then return false end end
	return true
end

local function sourcePair(snapshot, pane, key, now)
	local locator = (snapshot.sources or {})[pane]
	if snapshot.identityReady ~= true or (snapshot.identityPending or {})[pane]
		or (snapshot.identities or {})[pane] ~= key or type(locator) ~= "table"
		or locator.localSource ~= true or locator.key ~= key or type(locator.path) ~= "string" or locator.path == "" then return nil end
	local function matched(value)
		return type(value) == "table" and value.key == key and value.path == locator.path
			and finite(value.capturedAtUtc) and value.capturedAtUtc >= 0 and value.capturedAtUtc <= now
	end
	local cached = (snapshot.sourceFacts or {})[key]
	if not matched(cached) then cached = nil end
	local observed = if snapshot.sourceObservations == nil then cached else snapshot.sourceObservations[key]
	if not matched(observed) then return nil, nil, locator end
	if observed.status == "ready" or observed.status == "partial" then return observed, observed, locator end
	if observed.status == "unchanged" and cached and type(cached.revision) == "string"
		and cached.revision == observed.revision and cached.capturedAtUtc <= observed.capturedAtUtc then return observed, cached, locator end
	return observed, nil, locator
end

local function actionHeader(snapshot, locator, key, now)
	local header = (snapshot.sourceHeaders or {})[key]
	if locator == nil or type(header) ~= "table" or header.historyRead ~= false or header.key ~= key or header.path ~= locator.path
		or not finite(header.capturedAtUtc) or header.capturedAtUtc < 0 or header.capturedAtUtc > now then return nil end
	if header.status ~= "ready" and header.status ~= "changed" and header.status ~= "missing"
		and header.status ~= "unsupported" and header.status ~= "malformed" then return nil end
	return header
end

local function sourceHeaderShape(fact)
	return fact ~= nil and (fact.status == "ready" or fact.status == "partial")
		and type(fact.sessionId) == "string" and fact.sessionId ~= ""
		and type(fact.revision) == "string" and fact.revision ~= "" and type(fact.complete) == "boolean"
		and (fact.status == "ready") == fact.complete and type(fact.coverage) == "table"
		and fact.schemaVersion == 3 and type(fact.writerVersions) == "table" and stableHeader(fact)
end

local function headerSupersedes(header, observed, body)
	return header ~= nil and (observed == nil or header.capturedAtUtc >= observed.capturedAtUtc)
		and not (observed and body and header.revision ~= nil and header.revision == observed.revision and header.sessionId == body.sessionId)
end

local function observeSource(entry, snapshot, pane, key, now)
	local observed, body, locator = sourcePair(snapshot, pane, key, now)
	local header = actionHeader(snapshot, locator, key, now)
	local candidate
	if observed then
		local status = observed.status
		if status == "ready" or status == "partial" or status == "missing" or status == "unsupported"
			or status == "malformed" or status == "unchanged" then
			local coverage = if body and type(body.coverage) == "table" then body.coverage
				elseif type(observed.coverage) == "table" then observed.coverage else {}
			local sessionId = if body then body.sessionId else observed.sessionId
			if entry.sourceSessionId and sessionId and entry.sourceSessionId ~= sessionId and sourceHeaderShape(body) then status = "header-mismatch" end
			local fields = if type(coverage.fields) == "table" then coverage.fields else {}
			candidate = { status = status, capturedAtUtc = observed.capturedAtUtc, path = observed.path, sessionId = sessionId,
				revision = observed.revision, selection = if body then body.selection else observed.selection,
				recordsComplete = coverage.recordsComplete, historyScope = coverage.historyScope,
				clockSupport = fields.clock, questionSupport = fields.questions }
		end
	end
	if headerSupersedes(header, observed, body) then
		local status
		if header.status ~= "ready" then status = if header.status == "changed" then "header-mismatch" else header.status
		elseif entry.sourceSessionId and header.sessionId ~= entry.sourceSessionId then status = "header-mismatch"
		elseif observed and body and header.revision ~= observed.revision then status = "history-changed" end
		if status then
			candidate = { status = status, capturedAtUtc = header.capturedAtUtc, path = header.path, sessionId = header.sessionId,
				revision = header.revision, selection = "unknown", recordsComplete = false, historyScope = "unavailable",
				clockSupport = "unknown", questionSupport = "unknown", historyRead = false }
		end
	end
	if candidate then
		local previous = entry.sourceObservation
		if (entry.sourceObservedAtUtc and candidate.capturedAtUtc < entry.sourceObservedAtUtc)
			or (entry.source and candidate.capturedAtUtc < entry.source.capturedAtUtc) then return nil end
		-- `sourceObservedAtUtc` is the latest capture, for ordering; the observation itself keeps the time this availability
		-- was first seen, so a periodic re-check that finds nothing new leaves the presentation (and every rail) untouched.
		entry.sourceObservedAtUtc = candidate.capturedAtUtc
		local same = previous ~= nil
		if previous then
			for field, value in pairs(candidate) do
				if field ~= "capturedAtUtc" and previous[field] ~= value then same = false; break end
			end
			if same then
				for field, value in pairs(previous) do
					if field ~= "capturedAtUtc" and candidate[field] ~= value then same = false; break end
				end
			end
		end
		if not same then entry.sourceObservation = candidate end
	end
	return observed or (if header and header.status ~= "ready" then header else nil)
end

local function sourceHeader(snapshot, pane, key, now, entry)
	local observed, body, locator = sourcePair(snapshot, pane, key, now)
	local header = actionHeader(snapshot, locator, key, now)
	local proof
	if headerSupersedes(header, observed, body) then
		if header.status ~= "ready" or type(header.sessionId) ~= "string" or header.sessionId == ""
			or type(header.revision) ~= "string" or header.revision == ""
			or (entry and entry.sourceSessionId and entry.sourceSessionId ~= header.sessionId) then return nil end
		proof = header
	elseif observed and sourceHeaderShape(body) then
		proof = { key = key, path = locator.path, sessionId = body.sessionId, revision = observed.revision,
			capturedAtUtc = if header then math.max(observed.capturedAtUtc, header.capturedAtUtc) else observed.capturedAtUtc }
	else return nil end
	if entry and ((entry.sourceObservedAtUtc and proof.capturedAtUtc < entry.sourceObservedAtUtc)
		or (entry.source and proof.capturedAtUtc < entry.source.capturedAtUtc)) then return nil end
	return proof
end

local function acceptedSource(snapshot, pane, key, now, entry)
	local observed, fact, locator = sourcePair(snapshot, pane, key, now)
	local header = actionHeader(snapshot, locator, key, now)
	if observed == nil or not sourceHeaderShape(fact) or fact.selection ~= "disk-replayed"
		or fact.coverage.recordsComplete == false or fact.coverage.historyScope == "unavailable"
		or fact.coverage.historyScope == "observed-prefix" or headerSupersedes(header, observed, fact) then return nil end
	if entry and entry.sourceObservedAtUtc and observed.capturedAtUtc < entry.sourceObservedAtUtc then return nil end
	if fact.questions ~= nil and type(fact.questions) ~= "table" then return nil end
	local ids = {}
	for index, question in ipairs(fact.questions or {}) do
		if index > 32 then return nil end
		if type(question) ~= "table" or type(question.id) ~= "string" or question.id == "" or ids[question.id]
			or question.scope == "observed-prefix" or (question.status ~= "open" and question.status ~= "answered" and question.status ~= "cancelled"
				and question.status ~= "failed" and question.status ~= "unknown") then return nil end
		ids[question.id] = true
	end
	if fact.questionOutcomes ~= nil then
		if not plain(fact.questionOutcomes) then return nil end
		local count = 0
		for index in pairs(fact.questionOutcomes) do
			if not integer(index) or index < 1 or index > 512 then return nil end
			count += 1
		end
		for index = 1, count do
			local outcome = fact.questionOutcomes[index]
			if not plain(outcome) or type(outcome.id) ~= "string" or outcome.id == "" or ids[outcome.id]
				or (outcome.status ~= "answered" and outcome.status ~= "cancelled" and outcome.status ~= "failed") then return nil end
			ids[outcome.id] = true
			for _, field in ipairs({ "askedAtUtc", "answeredAtUtc", "cancelledAtUtc", "resolvedAtUtc" }) do
				if outcome[field] ~= nil and not finite(outcome[field]) then return nil end
			end
			if outcome.answerProvenance ~= nil and outcome.answerProvenance ~= "automatic"
				and outcome.answerProvenance ~= "user" then return nil end
			if outcome.timedOut ~= nil and type(outcome.timedOut) ~= "boolean" then return nil end
			for field in pairs(outcome) do
				if field ~= "id" and field ~= "status" and field ~= "askedAtUtc" and field ~= "answeredAtUtc"
					and field ~= "cancelledAtUtc" and field ~= "resolvedAtUtc" and field ~= "answerProvenance" and field ~= "timedOut" then return nil end
			end
		end
	end
	for _, keyName in ipairs({ "lastFinal", "lastHuman", "lastAssistant", "lastTerminal" }) do
		local value = fact[keyName]
		if value ~= nil and (type(value) ~= "table" or type(value.id) ~= "string" or value.scope == "observed-prefix") then return nil end
	end
	return fact, observed.capturedAtUtc
end

local function sourceCapture(fact)
	return { capturedAtUtc = fact.capturedAtUtc, complete = fact.complete, selection = fact.selection,
		selectedLeafId = fact.selectedLeafId, sessionId = fact.sessionId, revision = fact.revision, coverage = fact.coverage,
		questionCoverage = fact.questionCoverage }
end

local function boundQuestions(questions, retainedText)
	local selected, count = {}, 0
	for rank = 1, 4 do
		for index = #questions, 1, -1 do
			local status = questions[index].status
			local questionRank = if status == "open" then 1 elseif status == "unknown" then 2
				elseif retainedText[questions[index].id] then 3 else 4
			if questionRank == rank and count < 32 then selected[index] = true; count += 1 end
		end
	end
	local included, omitted, openOmitted = {}, {}, 0
	for index, question in ipairs(questions) do
		if selected[index] then table.insert(included, question)
		else
			table.insert(omitted, { id = question.id, callId = question.callId, questionId = question.questionId, index = question.index,
				status = question.status, askedAtUtc = question.askedAtUtc, answeredAtUtc = question.answeredAtUtc,
				cancelledAtUtc = question.cancelledAtUtc, resolvedAtUtc = question.resolvedAtUtc,
				answerProvenance = question.answerProvenance, timedOut = question.timedOut, retainedOrder = question.retainedOrder })
			if question.status == "open" then openOmitted += 1 end
		end
	end
	return included, omitted, openOmitted
end

local function applySource(state, entry, fact, snapshot, now, verifiedAtUtc)
	if entry.source and fact.capturedAtUtc < entry.source.capturedAtUtc and verifiedAtUtc < entry.source.capturedAtUtc then return end
	local old, baseline = entry.source, entry.source == nil
	local qualifiedBaseline = entry.sourceQuestionBaseline
	local recovering = old ~= nil and (entry.sourceGap == true or not questionCoverageComplete(old))
	if old == nil or old.revision ~= fact.revision or old.status ~= fact.status then
		local accepted = copyValue(fact, 0, true)
		accepted.lastKnown = nil
		accepted = boundedReplies(accepted) or accepted
		if old and not questionCoverageComplete(fact) then
			local prior, lastKnown = old.lastKnown or {}, {}
			local previousProvenance = prior.provenance or {}
			local oldCapture, currentCapture = sourceCapture(old), sourceCapture(accepted)
			local provenance = { questions = {} }
			if not fact.complete then
				for _, field in ipairs({ "lastFinal", "lastAssistant", "lastTerminal", "lastHuman" }) do
					lastKnown[field] = accepted[field] or old[field] or prior[field]
					provenance[field] = if accepted[field] ~= nil then currentCapture
						elseif old[field] ~= nil then oldCapture else previousProvenance[field]
				end
				local interaction = if accepted.lastInteractionAtUtc ~= nil then accepted
					elseif old.lastInteractionAtUtc ~= nil then old else prior
				lastKnown.lastInteractionAtUtc, lastKnown.lastInteractionId = interaction.lastInteractionAtUtc, interaction.lastInteractionId
				provenance.lastInteraction = if interaction == accepted then currentCapture
					elseif interaction == old then oldCapture else previousProvenance.lastInteraction
			end
			local questions, positions, nextOrder = {}, {}, 0
			local retainedText = {}
			for _, ledger in ipairs({ prior.questions or {}, old.questions or {} }) do
				for _, question in ipairs(ledger) do
					if type(question.text) == "string" then retainedText[question.id] = true end
				end
			end
			for _, ledger in ipairs({ prior.questions or {}, prior.omittedQuestions or {} }) do
				for _, question in ipairs(ledger) do nextOrder = math.max(nextOrder, question.retainedOrder or 0) end
			end
			for ledgerIndex, ledger in ipairs({ prior.questions or {}, prior.omittedQuestions or {}, old.questions or {}, accepted.questions or {} }) do
				if ledgerIndex == 3 and not historyApplicable(old)
					or ledgerIndex == 4 and not historyApplicable(accepted) then continue end
				for _, question in ipairs(ledger) do
					local origin = if ledgerIndex <= 2 then (previousProvenance.questions or {})[question.id]
						elseif ledgerIndex == 3 then oldCapture else currentCapture
					local index = positions[question.id]
					if index == nil then
						local retained = table.clone(question)
						if ledgerIndex <= 2 and question.retainedOrder ~= nil then retained.retainedOrder = question.retainedOrder
						else nextOrder += 1; retained.retainedOrder = nextOrder end
						table.insert(questions, retained)
						positions[question.id] = #questions
						provenance.questions[question.id] = origin
					else
						local previous = questions[index]
						local resolved = previous.status == "answered" or previous.status == "cancelled" or previous.status == "failed"
						if question.status ~= "unknown" and (not resolved or question.status ~= "open") then
							local retained = table.clone(previous)
							for field, value in pairs(question) do retained[field] = value end
							retained.retainedOrder = previous.retainedOrder
							questions[index] = retained
							provenance.questions[question.id] = origin
						end
					end
				end
			end
			if historyApplicable(accepted) then
				for _, outcome in ipairs(accepted.questionOutcomes or {}) do
					local index = positions[outcome.id]
					if index then
						local retained = table.clone(questions[index])
						for field, value in pairs(outcome) do
							if field ~= "askedAtUtc" or retained.askedAtUtc == nil then retained[field] = value end
						end
						questions[index] = retained
						provenance.questions[outcome.id] = currentCapture
					end
				end
			end
			table.sort(questions, function(a, b) return a.retainedOrder < b.retainedOrder end)
			lastKnown.questions, lastKnown.omittedQuestions, lastKnown.openQuestionsOmitted = boundQuestions(questions, retainedText)
			lastKnown.questionsKnown, lastKnown.questionsIncluded, lastKnown.questionsOmitted = #questions, #lastKnown.questions, #lastKnown.omittedQuestions
			lastKnown.provenance = provenance
			accepted.lastKnown = lastKnown
		end
		changed(state, entry, "source", accepted)
		changed(state, entry, "sourceSessionId", fact.sessionId)
		local oldQuestions, newQuestion = {}, false
		local priorLedger = if old then old.lastKnown or old else {}
		if recovering and entry.disposition == "active" and qualifiedBaseline then
			for _, id in ipairs(qualifiedBaseline.ids) do oldQuestions[id] = true end
		else
			for _, ledger in ipairs({ priorLedger.questions or {}, priorLedger.omittedQuestions or {} }) do
				for _, question in ipairs(ledger) do oldQuestions[question.id] = true end
			end
		end
		for _, question in ipairs(fact.questions or {}) do
			if question.status == "open" and old and not oldQuestions[question.id] then
				if recovering then
					if entry.disposition == "active" and qualifiedBaseline and finite(question.askedAtUtc)
						and question.askedAtUtc > math.max(qualifiedBaseline.capturedAtUtc, entry.sourceWorkUtc or 0)
						and question.askedAtUtc <= now then newQuestion = true end
				else
					newQuestion = true
				end
			end
		end
		entry.sourceOpen, entry.sourceOpenLastKnown = questionState(accepted)
		-- Historical enrichment never borrows a native timestamp or acknowledges native evidence.
		if not baseline and questionCoverageComplete(fact)
			and (not recovering and questionCoverageComplete(old)
				or recovering and entry.disposition == "active" and qualifiedBaseline ~= nil) then
			if newQuestion then
				attention(state, entry, now, nil)
				changed(state, entry, "sourceQuestionSuperseded", false)
				changed(state, entry, "sourceQuestionRevision", state.attentionRevision)
			end
		end
	end
	if questionCoverageComplete(fact) and entry.disposition == "active"
		and (qualifiedBaseline == nil or qualifiedBaseline.revision ~= fact.revision) then
		local ids = {}
		for _, question in ipairs(fact.questions or {}) do table.insert(ids, question.id) end
		changed(state, entry, "sourceQuestionBaseline", { revision = fact.revision, capturedAtUtc = fact.capturedAtUtc, ids = ids })
	end
	changed(state, entry, "sourceGap", not fact.complete or nil)
end
-- One transition into the retained terminal state: the record keeps its identity and history, but its pane is
-- gone and it can only reopen, never navigate. Every path that decides a pane is gone funnels through here.
local function markNoOpenPane(state, entry)
	changed(state, entry, "noOpenPane", true)
	entry.navigable, entry.orphaned, entry.stale = false, true, true
	entry.unavailableReason = "No open pane"
end

function model.reconcile(state, snapshot, events, context)
	context = context or { window = "", nowUtc = 0, coherent = true, hostKeys = {}, connected = {} }
	local now = context.nowUtc or 0
	state.sessionOrder, state.tabOrder = {}, {}
	for index, id in ipairs(snapshot.sessionOrder or {}) do state.sessionOrder[id] = index end
	for index, id in ipairs(snapshot.tabOrder or {}) do state.tabOrder[id] = index end
	local panes, hosts, members = snapshot.panes or {}, snapshot.hosts or {}, {}
	-- Identities carry fresh proof for proven panes and only the last observed hint for panes whose proof is
	-- pending. A pending pane is handled exactly as if no proof were ready, for that pane alone.
	local keys = snapshot.identities or {}
	local ready, unproven = snapshot.identityReady == true, snapshot.identityPending or {}
	local function proven(pane) return ready and not unproven[pane] end
	local provenKeys, undecided = {}, not ready
	for pane, key in pairs(keys) do if proven(pane) then provenKeys[pane] = key end end
	for pane in pairs(unproven) do if panes[pane] ~= nil then undecided = true end end
	local closed = {}
	for _, event in ipairs(events) do
		if event.kind == "closed" or (event.kind == "finished" and event.result == "closed") then closed[event.pane] = true end
	end
	-- A record's host id is a native runtime id and goes stale across restarts while its stable key persists.
	-- Re-resolve by key before any pass judges liveness, so a vanished pane is judged against its own host.
	local hostsByKey = {}
	for hostId, host in pairs(hosts) do if host.key ~= nil then hostsByKey[host.key] = hostId end end
	for _, entry in pairs(state.entries) do
		if entry.hostKey ~= nil then
			local current = hosts[entry.host]
			if current == nil or current.key ~= entry.hostKey then
				local resolved = hostsByKey[entry.hostKey]
				if resolved ~= nil then changed(state, entry, "host", resolved) end
			end
		end
	end
	for serial, entry in pairs(state.entries) do
		local fact = if entry.identityKey then sourceHeader(snapshot, entry.pane, entry.identityKey, now, entry) else nil
		local observed = if entry.identityKey then observeSource(entry, snapshot, entry.pane, entry.identityKey, now) else nil
		if type(observed) == "table" and observed.status ~= "ready" and observed.status ~= "unchanged" then
			changed(state, entry, "sourceGap", true)
		end
		if fact and entry.replacedSource and fact.sessionId == entry.sourceSessionId then
			changed(state, entry, "replacedSource", nil)
			entry.conditionGap = true
		end
		if fact and entry.sourceSessionId and fact.sessionId ~= entry.sourceSessionId and not entry.replacedSource
			and (entry.source == nil or fact.capturedAtUtc >= entry.source.capturedAtUtc) then
			if entry.retained then
				changed(state, entry, "replacedSource", true)
				markNoOpenPane(state, entry)
			else
				state.entries[serial] = nil
				state.persistenceRevision += 1
				continue
			end
		end
		if entry.deferredPane ~= nil and closed[entry.deferredPane] then clearDeferred(state, entry) end
		local bound = state.byPane[entry.pane]
		local key = keys[entry.pane]
		if closed[entry.pane] and (bound == entry or (key ~= nil and key == entry.identityKey)
			or (bound == nil and not entry.restored and not entry.identityRejected
				and (key == nil or entry.identityKey == nil))) then
			local survivor
			for paneId, candidate in pairs(keys) do
				if candidate == entry.identityKey and panes[paneId] and not closed[paneId]
					and (proven(paneId) or state.byPane[paneId] == entry) then
					if survivor == nil or tostring(paneId) < tostring(survivor) then survivor = paneId end
				end
			end
			if snapshot.ok ~= true or context.coherent == false then
				for paneId, owner in pairs(state.byPane) do
					if owner == entry and not closed[paneId]
						and (survivor == nil or tostring(paneId) < tostring(survivor)) then survivor = paneId end
				end
			end
			if survivor then changed(state, entry, "pane", survivor)
			elseif entry.retained then
				markNoOpenPane(state, entry)
			else
				state.entries[serial] = nil
				state.persistenceRevision += 1
			end
		end
	end
	local healthy, unknown = {}, snapshot.ok ~= true or context.coherent == false
	for hostId in pairs(state.hosts) do
		if hosts[hostId] == nil then
			state.hosts[hostId] = nil
			state.hostHealth[hostId] = nil
		end
	end
	for hostId, host in pairs(hosts) do
		state.hosts[hostId] = true
		local observed = snapshot.ok == true and host.connected == true and host.error == nil
		local held = state.hostHealth[hostId]
		-- Coverage is per host: a disconnected host keeps its last healthy state for 8s before it
		-- turns unhealthy, while a failed snapshot is never debounced.
		if observed then
			healthy[hostId] = true
			state.hostHealth[hostId] = { healthy = true, since = now }
		elseif held ~= nil and held.healthy and snapshot.ok == true and now - held.since < 8 then
			healthy[hostId] = true
		else
			healthy[hostId] = false
			state.hostHealth[hostId] = { healthy = false, since = now }
		end
	end
	local brokenJoin = false
	for _, agent in ipairs(snapshot.agents or {}) do
		members[agent.pane] = agent
		local pane = panes[agent.pane]
		if pane == nil then brokenJoin, unknown = true, true
		elseif hosts[pane.host] == nil then unknown = true
		elseif not recognized[agent.state] then healthy[pane.host] = false end
	end
	local available, offline = 0, 0
	for hostId in pairs(state.hosts) do
		if healthy[hostId] then available += 1 else offline += 1 end
	end
	state.complete = not unknown and offline == 0 and available > 0
	if state.complete then state.status, state.message = "ready", nil
	elseif not unknown and available > 0 then state.status, state.message = "partial", nil
	else state.status, state.message = "unavailable", label(snapshot.error, "Native agent coverage unavailable") end

	local function hostKeyOf(hostId)
		return (context.hostKeys or {})[hostId] or (hosts[hostId] or {}).key or ""
	end
	local offlineHosts = {}
	for hostId in pairs(hosts) do
		if not healthy[hostId] then
			table.insert(offlineHosts, { name = label(hosts[hostId].name, "Unknown host"), key = hostKeyOf(hostId) })
		end
	end
	table.sort(offlineHosts, function(a, b)
		if a.name == b.name then return a.key < b.key end
		return a.name < b.name
	end)
	state.offlineHosts = offlineHosts
	-- A keyless restored schema2 record was saved while identity proof was unavailable. It continues the same
	-- pane in the same window and host once that pane's identity is proven: by adopting the proven key, or by
	-- pane continuity when the pane has no conversation locator. Absent, unhealthy or pending panes stay unbound.
	local function continuous(entry)
		local pane = panes[entry.pane]
		return entry.restored == true and entry.identityKey == nil and not entry.legacy and not entry.identityRejected
			and pane ~= nil and not closed[entry.pane] and healthy[pane.host] == true and proven(entry.pane)
			and entry.window == (context.window or "") and entry.hostKey == hostKeyOf(pane.host)
	end
	do
		local ordered, byKey, claimed = {}, {}, {}
		for _, entry in pairs(state.entries) do
			table.insert(ordered, entry)
			if entry.identityKey and not entry.replacedSource then byKey[entry.identityKey] = entry end
		end
		table.sort(ordered, function(a, b) return a.serial < b.serial end)
		for _, entry in ipairs(ordered) do
			if state.entries[entry.serial] ~= entry or not continuous(entry) then continue end
			local key = keys[entry.pane]
			local keyed = if key ~= nil then byKey[key] else nil
			-- A record of the same proven key outside this pane and scope is ambiguity, never a merge.
			if keyed ~= nil and (keyed.window ~= entry.window or keyed.hostKey ~= entry.hostKey
				or identity.resolve(key, provenKeys, panes, keyed.pane) ~= entry.pane) then continue end
			local owner = claimed[entry.pane] or keyed
			if owner == nil then
				claimed[entry.pane] = entry
			else
				local keep, other = entry, owner
				if owner.serial < entry.serial then keep, other = owner, entry end
				absorb(state, keep, other)
				if keep.identityKey then byKey[keep.identityKey] = keep end
				claimed[entry.pane] = keep
			end
		end
	end

	local byPane, byIdentity, reserved = {}, {}, {}
	for _, entry in pairs(state.entries) do
		if entry.identityKey and not entry.replacedSource then byIdentity[entry.identityKey] = entry end
	end
	for _, entry in pairs(state.entries) do
		entry.retryableHeaderRoute = false
		if entry.replacedSource then
			entry.navigable, entry.stale, entry.orphaned = false, true, true
			entry.unavailableReason = "No open pane"
			continue
		end
		entry.conditionRaised = false
		entry.conditionGap = entry.conditionGap == true or entry.restored == true
		entry.stale, entry.navigable = true, false
		local target, reason
		local previous = panes[entry.pane]
		local sameScope = entry.window == (context.window or "") and previous ~= nil
			and (entry.hostKey == ((context.hostKeys or {})[previous.host] or (hosts[previous.host] or {}).key or "")
				or (not entry.restored and entry.host == nil and entry.hostKey == ""))
		local ownProven = proven(entry.pane)
		local resolved, held = entry.identityKey ~= nil and ready, false
		if resolved then
			target, reason = identity.resolve(entry.identityKey, provenKeys, panes, entry.pane)
			if target == nil and reason == "ambiguous" then
				-- A proven duplicate locator is one conversation with several routes. Keep a
				-- preferred route, otherwise choose deterministically; count it only once.
				for candidate, key in pairs(provenKeys) do
					if key == entry.identityKey and panes[candidate] and members[candidate] and not closed[candidate] then
						if target == nil or tostring(candidate) < tostring(target) then target = candidate end
					end
				end
			end
			if target == nil then
				if reason == "ambiguous" or (ownProven and keys[entry.pane] ~= nil and keys[entry.pane] ~= entry.identityKey) then
					entry.identityRejected = true
				end
				-- An unmatched key may belong to a pane whose proof is pending: hold it as unproven.
				if reason ~= "ambiguous" and undecided then held, reason = true, nil end
			end
		end
		if held or not resolved then
			if not entry.restored and not entry.identityRejected and sameScope
				and (not ownProven or held or keys[entry.pane] == nil or keys[entry.pane] == entry.identityKey or entry.identityKey == nil) then
				target = entry.pane
			elseif entry.legacy and sameScope and members[entry.pane] ~= nil and healthy[previous.host]
				and (previous.alert == true or members[entry.pane].state == "waiting_input"
					or members[entry.pane].deliveryError ~= nil or previous.startupError ~= nil or entry.deferredResult ~= nil) then
				target = entry.pane
			elseif continuous(entry) then
				target = entry.pane
			else reason = if held then "identity proof pending" elseif previous == nil then "missing" else "unverified" end
		end
		if target ~= nil and entry.identityKey == nil and keys[target] ~= nil
			and byIdentity[keys[target]] ~= nil and byIdentity[keys[target]] ~= entry then
			target, reason = nil, "ambiguous"
		end
		if target ~= nil and not closed[target] and byPane[target] == nil then
			local pane = panes[target]
			changed(state, entry, "pane", target)
			changed(state, entry, "noOpenPane", nil)
			byPane[target] = entry
			entry.identityRejected = false
			entry.orphaned = false
			entry.unavailableReason = if healthy[pane.host] then nil else "disconnected"
			entry.navigable = snapshot.ok == true and healthy[pane.host] == true
			if proven(target) and keys[target] ~= nil and (entry.identityKey == nil or keys[target] == entry.identityKey) then
				changed(state, entry, "identityKey", keys[target])
				byIdentity[keys[target]] = entry
			end
			if entry.sourceSessionId ~= nil then
				local source = sourceHeader(snapshot, target, entry.identityKey, now, entry)
				if source == nil or source.sessionId ~= entry.sourceSessionId then
					entry.navigable, entry.stale = false, true
					entry.unavailableReason = "source header proof pending"
				end
			end
			if entry.identityKey ~= nil and (held or not proven(target)) then
				reserved[target] = entry
				entry.unavailableReason = "identity proof pending"
			end
		else
			local offlineHost = snapshot.ok == true and entry.host ~= nil and hosts[entry.host] ~= nil and not healthy[entry.host]
			if offlineHost then
				entry.orphaned = false
				entry.unavailableReason = label(hosts[entry.host].name, entry.hostName) .. " offline"
			else
				entry.orphaned = snapshot.ok == true or entry.restored == true or entry.identityRejected == true
				entry.unavailableReason = if snapshot.ok ~= true then "coverage unavailable" else reason or "ambiguous"
			end
			if (entry.restored or (entry.identityKey ~= nil and not entry.identityRejected and (not ready or held)))
				and (sameScope or (previous == nil and entry.window == (context.window or "")))
				and (not ownProven or keys[entry.pane] == nil) then
				reserved[entry.pane] = entry
			end
		end
		-- A healthy observation held for identity proof is not a gap in the native source.
		local observedPane = if target ~= nil and byPane[target] == entry then panes[target] else nil
		if observedPane == nil or members[target] == nil or not healthy[observedPane.host] or context.coherent == false then
			entry.conditionGap = true
		end
	end

	local ids = {}
	for pane in pairs(members) do if not closed[pane] then table.insert(ids, pane) end end
	table.sort(ids, function(a, b) return if type(a) == type(b) then a < b else tostring(a) < tostring(b) end)
	for _, paneId in ipairs(ids) do
		local pane = panes[paneId]
		if byPane[paneId] == nil and reserved[paneId] == nil and pane ~= nil and healthy[pane.host] then
			local known = keys[paneId] and byIdentity[keys[paneId]]
			if known ~= nil and proven(paneId) and not known.replacedSource
				and (not known.restored or byPane[known.pane] == known) then
				byPane[paneId] = known
			elseif known == nil then
				local entry = newEntry(state, paneId, context)
				byPane[paneId] = entry
				if proven(paneId) then
					changed(state, entry, "identityKey", keys[paneId])
					if keys[paneId] then byIdentity[keys[paneId]] = entry end
				end
				entry.navigable, entry.orphaned, entry.unavailableReason = true, false, nil
			end
		end
	end

	local turnsBeforeReplay, waitingReplay = {}, {}
	for paneId, entry in pairs(byPane) do turnsBeforeReplay[paneId] = entry.turn end
	for _, source in pairs(state.entries) do
		local deferredPane = source.deferredPane
		local target = if deferredPane ~= nil then byPane[deferredPane] else nil
		if target ~= nil and proven(deferredPane) and target.navigable
			and (keys[deferredPane] ~= nil or (target == source and source.identityKey == nil)) then
			local work, result, observedUtc, workAfter, workBefore = source.deferredWork, source.deferredResult,
				source.deferredUtc, source.deferredWorkAfter, source.deferredWorkBefore
			local workAt, at = source.deferredWorkAt, source.deferredAt
			if source.deferredWaitingUtc ~= nil then
				table.insert(waitingReplay, { target = target, utc = source.deferredWaitingUtc, at = source.deferredWaitingAt })
			end
			clearDeferred(state, source)
			if work and (not workAfter or workBefore) then
				local beforeAt = if workAfter then nil else workAt
				observe(state, target, { kind = "state", new = "working", old = "idle", at = beforeAt }, observedUtc or now, beforeAt == nil)
			end
			if result ~= nil then
				observe(state, target, { kind = "finished", result = result, at = at }, observedUtc or now, at == nil)
			end
			if work and workAfter then
				observe(state, target, { kind = "state", new = "working", old = "idle", at = workAt }, observedUtc or now, workAt == nil)
			end
		end
	end
	local boundIds, nativeConditions = {}, {}
	for paneId, entry in pairs(byPane) do
		table.insert(boundIds, paneId)
		local agent, pane = members[paneId], panes[paneId]
		if agent and pane and healthy[pane.host] and reserved[paneId] == nil and context.coherent ~= false then
			local conditions = nativeConditions[entry]
			if conditions == nil then
				conditions = { waiting = false, working = false, delivery = false, startup = false, alert = false }
				nativeConditions[entry] = conditions
			end
			conditions.waiting = conditions.waiting or agent.state == "waiting_input"
			conditions.working = conditions.working or agent.state == "working"
			conditions.delivery = conditions.delivery or agent.deliveryError ~= nil
			conditions.startup = conditions.startup or pane.startupError ~= nil
			conditions.alert = conditions.alert or pane.alert == true
		end
	end
	table.sort(boundIds, function(a, b) return if type(a) == type(b) then a < b else tostring(a) < tostring(b) end)
	local snapshotWork, callbackWork = {}, {}
	for _, event in ipairs(events) do
		local entry = byPane[event.pane]
		if entry ~= nil and event.kind == "state" and event.new == "working" and event.old ~= "working"
			and (entry.eventObservedAt == nil or (event.at or 0) >= entry.eventObservedAt)
			and (entry.workObservedAt == nil or (event.at or 0) >= entry.workObservedAt) then
			callbackWork[event.pane] = true
		end
	end
	for _, paneId in ipairs(boundIds) do
		local entry = byPane[paneId]
		local pane, agent = panes[paneId], members[paneId]
		if pane and agent and paneId == entry.pane and healthy[pane.host] and reserved[paneId] == nil and context.coherent ~= false then
			local host = hosts[pane.host]
			changed(state, entry, "window", context.window or "")
			changed(state, entry, "hostKey", (context.hostKeys or {})[pane.host] or host.key or entry.hostKey)
			for _, key in ipairs({ "host", "tab", "session" }) do changed(state, entry, key, pane[key]) end
			changed(state, entry, "title", label(pane.title, "Agent"))
			changed(state, entry, "sessionName", label(pane.sessionName, "Unknown session"))
			changed(state, entry, "hostName", label(pane.hostName, label(host.name, "Unknown host")))
			changed(state, entry, "localHost", entry.hostKey == "local")
			changed(state, entry, "parked", pane.parked == true)
			changed(state, entry, "floating", pane.floating == true)
			entry.stale = false
			-- Duplicate proven routes contribute conditions, never the canonical route's metadata.
			local conditions = nativeConditions[entry]
			local waiting, delivery, startup, alert = conditions.waiting, conditions.delivery, conditions.startup, conditions.alert
			local nativeState = if waiting then "waiting_input" elseif conditions.working then "working" else agent.state
			local freshCondition = (waiting and not entry.waiting) or (delivery and not entry.delivery) or (startup and not entry.startup)
			local freshAlert = alert and not entry.alert
			if entry.conditionGap and entry.reviewRevision == nil then
				local historical = if entry.waiting and not waiting then "waiting"
					elseif entry.delivery and not delivery then "delivery"
					elseif entry.startup and not startup then "startup" else nil
				if historical ~= nil then
					state.attentionRevision += 1
					changed(state, entry, "reviewRevision", state.attentionRevision)
					changed(state, entry, "reviewKind", historical)
				end
			end
			if nativeState == "working" and entry.nativeState ~= "working"
				and entry.turn == turnsBeforeReplay[paneId] and not callbackWork[paneId] then
				snapshotWork[paneId] = { kind = "state", old = entry.nativeState, new = "working", at = snapshot.now }
			end
			if not entry.legacy and (freshCondition or freshAlert) then
				attention(state, entry, now, if freshAlert then "update" else nil)
				if freshAlert then changed(state, entry, "reviewSuperseded", nativeState == "working") end
			end
			if entry.nativeState ~= nativeState then entry.runtimeObservedAtUtc = now end
			entry.conditionRaised = waiting and freshCondition
			if freshCondition and waiting then changed(state, entry, "waitingTurn", entry.turn) end
			changed(state, entry, "nativeState", nativeState)
			changed(state, entry, "waiting", waiting)
			changed(state, entry, "delivery", delivery)
			changed(state, entry, "startup", startup)
			changed(state, entry, "alert", alert)
			changed(state, entry, "legacy", nil)
			entry.restored, entry.conditionGap = false, false
		end
	end
	-- A deferred input request follows every deferred work/result; its attention depends on the
	-- now-confirmed native condition, exactly as a live callback after this snapshot would.
	for _, replay in ipairs(waitingReplay) do
		observe(state, replay.target, { kind = "state", old = "working", new = "waiting_input", at = replay.at },
			replay.utc, replay.at == nil)
	end
	state.byPane = byPane
	for _, event in ipairs(events) do
		if closed[event.pane] then continue end
		if reserved[event.pane] ~= nil then
			deferObservation(state, reserved[event.pane], event, now)
			continue
		end
		local entry = byPane[event.pane]
		if entry == nil then
			for _, candidate in pairs(state.entries) do
				if candidate.pane == event.pane and not candidate.restored and not candidate.identityRejected
					and candidate.window == (context.window or "")
					and (keys[event.pane] == nil or candidate.identityKey == nil or keys[event.pane] == candidate.identityKey) then entry = candidate; break end
			end
		end
		if entry == nil and event.kind == "finished" and (event.result == "done" or event.result == "failed" or event.result == "exited") then
			entry = if proven(event.pane) and keys[event.pane] ~= nil then byIdentity[keys[event.pane]] else nil
			if entry == nil then
				entry = newEntry(state, event.pane, context)
				if proven(event.pane) then
					changed(state, entry, "identityKey", keys[event.pane])
					if entry.identityKey then byIdentity[entry.identityKey] = entry end
				end
			end
		end
		-- Callbacks carry causal transitions; an unmatched snapshot transition is only catch-up.
		-- Insert catch-up after older callbacks, never ahead of their unreviewed completion.
		local work = snapshotWork[event.pane]
		if entry ~= nil and work ~= nil and (event.at or 0) >= (work.at or 0) then
			observe(state, entry, work, now)
			snapshotWork[event.pane] = nil
		end
		if entry ~= nil then observe(state, entry, event, now) end
	end
	for _, paneId in ipairs(boundIds) do
		local work = snapshotWork[paneId]
		if work ~= nil then observe(state, byPane[paneId], work, now) end
	end
	-- A last-pane disappearance on a healthy, coherent inventory is an observed close.
	-- An offline/pending observation is not absence and must retain the last known route.
	for serial, entry in pairs(state.entries) do
		if entry.identityRejected and not entry.retained and not pending(entry) and not entry.sourceOpen
			and ready and not undecided then
			state.entries[serial] = nil
			state.persistenceRevision += 1
			continue
		end
		if not entry.identityRejected and not entry.replacedSource
			and panes[entry.pane] == nil and snapshot.ok == true and context.coherent ~= false
			and entry.host ~= nil and hosts[entry.host] ~= nil and healthy[entry.host]
			and (entry.identityKey == nil or (ready and not undecided)) then
			if entry.retained then
				markNoOpenPane(state, entry)
			else
				state.entries[serial] = nil
				state.persistenceRevision += 1
				continue
			end
		end
		if entry.noOpenPane then
			entry.navigable = false
			changed(state, entry, "waiting", false)
			changed(state, entry, "delivery", false)
			changed(state, entry, "startup", false)
			changed(state, entry, "nativeState", nil)
			if entry.orphaned then entry.unavailableReason = "No open pane" end
		end
		if entry.identityKey and proven(entry.pane) and not entry.replacedSource and not entry.noOpenPane
			and byPane[entry.pane] == entry and not entry.stale and snapshot.ok == true and context.coherent ~= false then
			observeSource(entry, snapshot, entry.pane, entry.identityKey, now)
			local header = sourceHeader(snapshot, entry.pane, entry.identityKey, now, entry)
			if header and entry.sourceSessionId == nil then changed(state, entry, "sourceSessionId", header.sessionId) end
			local fact, verifiedAtUtc = acceptedSource(snapshot, entry.pane, entry.identityKey, now, entry)
			if fact then applySource(state, entry, fact, snapshot, now, verifiedAtUtc)
			elseif (snapshot.sourceFacts or {})[entry.identityKey] ~= nil then changed(state, entry, "sourceGap", true) end
			local locator = (snapshot.sources or {})[entry.pane]
			local rawHeader = actionHeader(snapshot, locator, entry.identityKey, now)
			local mismatched = entry.sourceObservation and entry.sourceObservation.status == "header-mismatch"
				or rawHeader and (rawHeader.status == "changed" or rawHeader.sessionId ~= nil
					and rawHeader.sessionId ~= entry.sourceSessionId)
			entry.retryableHeaderRoute = not entry.navigable and entry.sourceSessionId ~= nil
				and entry.unavailableReason == "source header proof pending" and not entry.identityRejected
				and not entry.orphaned and entry.localHost == true and locator ~= nil
				and locator.localSource == true and locator.key == entry.identityKey and not mismatched
		end
	end
	-- Rests are timed: every pass re-reads the clock, so a row comes back to Attention when its limit's end passes.
	for _, entry in pairs(state.entries) do entry.resting = restingUntil(entry, now) end
	return publish(state)
end
local function selected(state, pane, serial)
	local entry = state.entries[serial]
	return if entry and not entry.noOpenPane and (entry.pane == pane or state.byPane[pane] == entry) then entry else nil
end

local function work(state, workId)
	if type(workId) ~= "string" then return nil end
	local serial = tonumber(string.match(workId, "^work:(%d+)$"))
	return if serial then state.entries[serial] else nil
end

function model.setDisposition(state, workId, disposition, nowUtc, options)
	assert(disposition == "active" or disposition == "reference" or disposition == "finished", "Invalid triage disposition")
	assert(finite(nowUtc), "Invalid triage action time")
	local entry = work(state, workId)
	if entry == nil then return false end
	options = options or {}
	if entry.disposition == disposition and options.bringBack ~= true then
		if disposition ~= "active" and changed(state, entry, "retained", true) then publish(state); return true end
		return false
	end
	changed(state, entry, "disposition", disposition)
	if disposition ~= "active" then
		changed(state, entry, "retained", true)
		changed(state, entry, "sourceQuestionBaseline", nil)
	end
	if disposition == "active" and options.bringBack == true then
		state.queueOrder += 1
		changed(state, entry, "queueOrder", state.queueOrder)
		changed(state, entry, "firstSeenUtc", nowUtc or entry.firstSeenUtc)
		changed(state, entry, "manualRevisit", true)
		state.attentionRevision += 1
		changed(state, entry, "attentionRevision", state.attentionRevision)
		changed(state, entry, "reviewRevision", state.attentionRevision)
		changed(state, entry, "reviewKind", "manual")
		changed(state, entry, "reviewSuperseded", false)
	elseif disposition == "reference" or disposition == "finished" then
		changed(state, entry, "manualRevisit", nil)
		if entry.reviewKind == "manual" then
			changed(state, entry, "reviewRevision", nil)
			changed(state, entry, "reviewKind", nil)
		end
	end
	publish(state)
	return true
end

function model.setPriority(state, workId, priority)
	assert(priority == nil or (integer(priority) and priority <= 3), "Invalid triage priority")
	local entry = work(state, workId)
	if entry == nil or not changed(state, entry, "priority", priority) then return false end
	publish(state)
	return true
end

function model.removeRetained(state, workId)
	local entry = work(state, workId)
	if entry == nil or not entry.retained or not entry.noOpenPane or not entry.orphaned then return false end
	state.entries[entry.serial] = nil
	state.persistenceRevision += 1
	publish(state)
	return true
end

function model.removeUnavailable(state, pane, serial)
	local entry = selected(state, pane, serial)
	if entry == nil or entry.navigable or not entry.orphaned then return false end
	state.entries[serial] = nil
	if state.byPane[pane] == entry then state.byPane[pane] = nil end
	state.persistenceRevision += 1
	publish(state)
	return true
end

local function startRound(state, allowed)
	local round = { entries = {}, finished = {} }
	for _, row in ipairs(state.presentation.rows) do
		if row.attention and (row.navigable or row.retryableHeaderRoute) and (allowed == nil or allowed[row.pane] == true) then
			table.insert(round.entries, { serial = row.serial, queueOrder = row.queueOrder })
		end
	end
	table.sort(round.entries, function(a, b) return ranked(state.entries[a.serial], state.entries[b.serial]) end)
	state.round = round
	return round
end

local function remaining(state, round, focused, allowed)
	local here, target
	for _, member in ipairs(round.entries) do
		if not round.finished[member.serial] then
			local entry = state.entries[member.serial]
			if entry == nil or not attentionEligible(entry) or not (entry.navigable or entry.retryableHeaderRoute)
				or entry.queueOrder ~= member.queueOrder or (allowed ~= nil and allowed[entry.pane] ~= true) then
				round.finished[member.serial] = true
			elseif entry.pane == focused or (focused ~= nil and state.byPane[focused] == entry) then here = entry
			elseif target == nil then target = entry end
		end
	end
	if target ~= nil and here ~= nil then round.finished[here.serial] = true end
	return target, here
end

function model.next(state, focused, allowed)
	local round = state.round or startRound(state, allowed)
	local target, here = remaining(state, round, focused, allowed)
	if target then return target.pane, nil, target.serial end
	if here and here.reviewRevision ~= nil then return here.pane, nil, here.serial end
	round = startRound(state, allowed)
	target, here = remaining(state, round, focused, allowed)
	if target then return target.pane, nil, target.serial end
	if here then
		if here.reviewRevision ~= nil then return here.pane, nil, here.serial end
		return nil, if here.waiting then "Already here · still needs input" else "Already here · still needs attention"
	end
	if state.presentation.attentionCount > 0 then return nil, "No reachable Attention target · targets unavailable" end
	return nil, if state.complete then "No conversations need attention" else "No reachable Attention target · coverage unavailable"
end

function model.visit(state, pane, reviewRevision, serial)
	local entry = selected(state, pane, serial)
	if entry == nil or not entry.navigable then return false end
	local round = state.round or startRound(state)
	round.finished[entry.serial] = true
	if reviewRevision == nil or entry.reviewRevision ~= reviewRevision then return false end
	changed(state, entry, "manualRevisit", nil)
	changed(state, entry, "reviewRevision", nil)
	changed(state, entry, "reviewKind", nil)
	publish(state)
	return true
end

function model.skip(state, pane)
	local entry = state.byPane[pane]
	if entry ~= nil then
		local round = state.round or startRound(state)
		round.finished[entry.serial] = true
	end
end

function model.sessionGroups(presentation, data, coherent)
	if data == nil or data.sessionOrder == nil then return {} end
	local records, ordered = {}, {}
	-- Group trust is per host: another host being offline never taints this host's sessions.
	for _, sessionId in ipairs(data.sessionOrder) do
		local session = data.sessions[sessionId]
		local host = if session then data.hosts[session.host] else nil
		if records[sessionId] == nil and host ~= nil and type(host.key) == "string" and host.key ~= "" then
			local available = coherent == true and data.ok ~= false and host.connected == true and host.error == nil
			local name = label(session.name, "Session")
			local group = {
				session = sessionId, host = session.host, hostKey = host.key,
				name = name, label = name, hostName = label(host.name, "Host"), localHost = host.key == "local",
				current = data.currentHost == session.host and data.currentSession == sessionId,
				available = available, known = available,
				attentionTabs = 0, attentionConversations = 0, allConversations = 0,
			}
			local record = { group = group, tabs = {}, content = false }
			records[sessionId] = record
			table.insert(ordered, record)
		end
	end
	-- An unassigned join only makes every host's counts uncertain when its own host cannot be determined;
	-- otherwise unhealthy hosts are already unknown and healthy hosts keep their counts.
	local unassignedUnknown = false
	for _, pane in pairs(data.panes) do
		if pane.tab == nil or pane.parked then continue end
		local tab = data.tabs[pane.tab]
		local record = if tab then records[tab.session] else nil
		if record ~= nil and pane.session == tab.session and pane.host == record.group.host then record.content = true
		else
			local previous = records[pane.session]
			if previous then previous.group.known = false end
			if record then record.group.known = false end
			if previous == nil and record == nil and data.hosts[pane.host] == nil then unassignedUnknown = true end
		end
	end
	for _, row in ipairs(if presentation then presentation.rows else {}) do
		if row.tab == nil or row.parked then continue end
		local record = records[row.session]
		local pane = data.panes[row.pane]
		local tab = if pane and pane.tab then data.tabs[pane.tab] else nil
		local current = if tab then records[tab.session] else nil
		local matches = record ~= nil and pane ~= nil and not pane.parked and tab ~= nil
			and pane.host == row.host and pane.tab == row.tab and pane.session == row.session
			and tab.session == row.session and record.group.host == row.host
		if not matches then
			if record then record.group.known = false end
			if current then current.group.known = false end
			if record == nil and current == nil and (pane == nil or data.hosts[pane.host] == nil) then unassignedUnknown = true end
			-- An unavailable retained row still contributes its honest last-known session count.
			if row.navigable or record == nil or record.group.host ~= row.host then continue end
		end
		local group = record.group
		record.content = true
		if row.stale or not row.navigable then group.known = false end
		group.allConversations += 1
		if row.attention then
			group.attentionConversations += 1
			if not record.tabs[row.tab] then record.tabs[row.tab] = true; group.attentionTabs += 1 end
			if matches and group.available and (row.navigable or row.retryableHeaderRoute) and not row.stale
				and (group.target == nil or ranked(row, group.target)) then
				group.target = { pane = row.pane, serial = row.serial, workId = row.workId, host = row.host, session = row.session,
					tab = row.tab, reviewRevision = row.reviewRevision, queueOrder = row.queueOrder, priority = row.priority, condition = row.condition,
					identityKey = row.identityKey, sourceSessionId = row.sourceSessionId }
			end
		end
	end
	local groups, names, labels = {}, {}, {}
	for _, record in ipairs(ordered) do
		if record.content then
			local group = record.group
			if unassignedUnknown then group.known = false end
			if group.allConversations > 0 then
				names[group.name] = (names[group.name] or 0) + 1
			end
			table.insert(groups, group)
		end
	end
	for _, group in ipairs(groups) do
		if not group.localHost or (names[group.name] or 0) > 1 then group.label = group.name .. " · " .. group.hostName end
		labels[group.label] = (labels[group.label] or 0) + 1
	end
	local finalLabels, collision = {}, false
	for _, group in ipairs(groups) do
		if labels[group.label] > 1 then group.label ..= " · #" .. tostring(group.session) end
		if finalLabels[group.label] then collision = true end
		finalLabels[group.label] = true
	end
	if collision then for _, group in ipairs(groups) do group.label = "#" .. tostring(group.session) .. " · " .. group.label end end
	return groups
end

return model
