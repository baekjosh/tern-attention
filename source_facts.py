#!/usr/bin/env python3
"""Read-only, finite OMP source projection. JSON protocol 1 on stdin/stdout.

Only schema 3 and explicitly observed writer record shapes are qualified.
Selection is persisted disk replay, never a claim about an in-memory branch.
An observation revision is a stat fingerprint, not a producer generation or
protection against an arbitrary mutation that preserves all observed metadata.

Producer replay reference: @oh-my-pi/pi-coding-agent@18.14.0
src/session/session-entries.ts, resolveSessionLeafId. Version-matched published
source plus observed records is not an attestation of the installed binary.

Qualified writers (SUPPORTED_WRITERS). A version is listed only when (1) real
sessions it alone wrote parse with no issue and every consumed fact (ask
questions, answers, clocks, lastFinal) equals an independent minimal reader of the
raw JSONL, and (2) the producer's session-entries.ts and ask.ts at that tag differ
from a qualified version only by fields this helper does not read. 18.12.3 and
older are excluded: their loader honors activeLeafId on model_usage entries only.
18.16.0 qualified 2026-11-02: six sessions written by 18.16.0 alone under an isolated
HOME (print-mode read tool call; rpc-ui ask select, multi-question select+multi,
custom input, cancelled, and a tool-not-found failure) and one real 18.13.2 session
resumed under 18.16.0 (mixed 18.13.2+18.16.0) parse with no issue and equal the raw
reader in tools/qualify_writer.py; producer 18.16.0 vs 18.15.0 differs in
session-entries.ts only by session_init.mountedTools and ask.ts is identical. A new
version stays unqualified (selectionSupport "unknown", writerSupport "unknown") until
both hold; `python3 tools/qualify_writer.py <version>` runs the cross-check.
Not exercised against real sessions: ask results under 18.14.1, 18.12.5 and
18.13.1 (producer ask.ts identical or additive only), and the 18.14.2+
"Ask interrupted by message" result, which this helper reports as status failed.
A host-cancelled ask (producer "Ask tool was cancelled by the user", isError, empty
details; observed under 18.16.0) is likewise reported as status failed, never answered.

Date mode request: {protocol:1,requestId,op:"date",civilDate:"YYYY-MM-DD",
civilTime?:"HH:MM",zone?:IANA,nowUtc?:number}. Date-only resolves local start
of day in zone (default: the system zone, reported as zoneSource "system").
Result status ready|invalid|ambiguous. A local time inside a DST gap
(problem "nonexistent") or repeated by a fold (status ambiguous, problem
"repeated") is refused with a specific error and never shifted. ready carries
resolvedUTC, display (local date time zone), utcDisplay (ISO instant), and
confirmation (the one user-facing statement); with nowUtc it also carries
past, and a past confirmation says the conversation returns on the next refresh.
"""
from __future__ import annotations

from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ADAPTER = "omp-facts-v2"
SUPPORTED_WRITERS = frozenset(("18.12.5", "18.12.6", "18.13.0", "18.13.1", "18.13.2", "18.13.3",
                               "18.14.0", "18.14.1", "18.14.2", "18.15.0", "18.16.0"))
MAX_TARGETS = 64
MAX_RECORD_BYTES = 8 * 1024 * 1024
MAX_SOURCE_BYTES = 1024 * 1024 * 1024
MAX_RECORDS = 200000
SOURCE_SECONDS = 6
HEADER_BYTES = 64 * 1024
HEADER_RECORDS = 8
HEADER_SECONDS = 1
MAX_TEXT = 2000
MAX_QUESTIONS = 32
MAX_TRACKED_QUESTIONS = 512
MAX_RESULT_BYTES = 128 * 1024
MAX_REQUEST_BYTES = 256 * 1024
METADATA_TYPES = frozenset(("model_change", "thinking_level_change", "service_tier_change",
    "model_usage", "custom", "custom_message", "label", "title_change", "credential_pin",
    "ttsr_injection", "compaction", "branch_summary", "reset_boundary", "mode_change", "session_init"))
TERMINALS = frozenset(("stop", "length", "error", "aborted"))


class SourceProblem(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason
        super().__init__(reason)


def digest(value):
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def finite(value):
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except OverflowError:
        return False


def milliseconds(value):
    return value / 1000 if finite(value) else None


def recorded_time(value):
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return date.timestamp() if date.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


def with_time(value, name, at):
    if at is not None:
        value[name] = at
    return value


def text_content(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        raise SourceProblem("partial", "unsupported-message-content")
    return "\n".join(part["text"] for part in content
                     if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str))


def bounded_text(text):
    return {"text": text[:MAX_TEXT], "textChars": len(text)}


def allowed_question(raw, entry_id, call_id, index, at):
    if not isinstance(raw, dict) or not isinstance(raw.get("question"), str):
        raise SourceProblem("partial", "unsupported-question-shape")
    options = raw.get("options")
    if not isinstance(options, list):
        raise SourceProblem("partial", "unsupported-question-options")
    labels = []
    for option in options:
        label = option.get("label") if isinstance(option, dict) else option
        if not isinstance(label, str):
            raise SourceProblem("partial", "unsupported-question-option")
        labels.append(label)
    question_id = raw.get("id")
    if question_id is not None and not isinstance(question_id, str):
        raise SourceProblem("partial", "unsupported-question-id")
    question = {"id": json.dumps([entry_id, call_id, question_id, index], separators=(",", ":")),
                "callId": call_id, "index": index, "text": raw["question"][:MAX_TEXT], "status": "open"}
    if question_id is not None:
        question["questionId"] = question_id
    with_time(question, "askedAtUtc", at)
    return {"fact": question, "options": labels, "multi": raw.get("multi") is True,
            "textChars": len(raw["question"])}


def normalize(entry):
    kind, ident = entry.get("type"), entry["id"]
    if kind != "message":
        if kind not in METADATA_TYPES:
            raise SourceProblem("partial", "unsupported-entry-type")
        return {"kind": kind} if kind in ("reset_boundary", "compaction", "branch_summary") else None
    message = entry.get("message")
    if not isinstance(message, dict):
        raise SourceProblem("partial", "unsupported-message")
    role = message.get("role")
    if role in ("developer", "custom"):
        return {"kind": "control", "role": role}
    at = milliseconds(message.get("timestamp"))
    if at is None:
        at = recorded_time(entry.get("timestamp"))
    if role == "user":
        attribution = message.get("attribution")
        if attribution not in (None, "user"):
            return None
        text = text_content(message.get("content", []))
        if not text:
            return None
        result = {"kind": "user", "id": ident, "provenance": "user" if attribution == "user" else "unknown",
                  **bounded_text(text)}
        return with_time(result, "atUtc", at)
    if role == "assistant":
        stop = message.get("stopReason")
        if stop not in TERMINALS and stop != "toolUse":
            raise SourceProblem("partial", "unsupported-assistant-stop")
        completed = milliseconds(message.get("completedAt"))
        # Fallback is envelope creation time, not the provider request-start timestamp.
        assistant_at = completed if completed is not None else recorded_time(entry.get("timestamp"))
        text = text_content(message.get("content", []))
        result = {"kind": "assistant", "id": ident, "stopReason": stop,
                  "timeKind": "completed" if completed is not None else "recorded", **bounded_text(text), "asks": []}
        with_time(result, "atUtc", assistant_at)
        content = message.get("content")
        for part in content if isinstance(content, list) else []:
            if not isinstance(part, dict) or part.get("type") != "toolCall" or part.get("name") != "ask":
                continue
            arguments, call_id = part.get("arguments"), part.get("id")
            if not isinstance(arguments, dict) or not isinstance(call_id, str) or not call_id:
                raise SourceProblem("partial", "unsupported-ask-call")
            questions = arguments.get("questions")
            if not isinstance(questions, list) or not questions or len(questions) > MAX_QUESTIONS:
                raise SourceProblem("partial", "unsupported-ask-questions")
            seen = set()
            for index, raw in enumerate(questions):
                q = allowed_question(raw, ident, call_id, index, assistant_at)
                qid = q["fact"].get("questionId")
                if qid is not None and qid in seen:
                    raise SourceProblem("partial", "duplicate-question-id")
                seen.add(qid)
                result["asks"].append(q)
        return result
    if role == "toolResult":
        if message.get("toolName") != "ask":
            return None
        call_id, details = message.get("toolCallId"), message.get("details")
        if not isinstance(call_id, str):
            raise SourceProblem("partial", "unsupported-ask-result")
        if details is None and message.get("isError") is True:
            details = {}
        if not isinstance(details, dict):
            raise SourceProblem("partial", "unsupported-ask-result")
        # Only this exact producer cancellation sentinel is decoded. Never expose raw tool text.
        content = message.get("content", [])
        cancellation = (message.get("isError") is True and isinstance(content, (str, list))
                        and text_content(content) == "Ask input was cancelled")
        def outcome(raw):
            if not isinstance(raw, dict):
                return None
            return {name: raw[name] for name in ("id", "selectedOptions", "customInput", "multi", "timedOut") if name in raw}
        raw_results = details.get("results")
        if raw_results is not None and (not isinstance(raw_results, list) or len(raw_results) > MAX_QUESTIONS):
            raise SourceProblem("partial", "unsupported-batch-result")
        results = [outcome(raw) for raw in raw_results] if isinstance(raw_results, list) else [outcome(details)]
        # Project only supported factual fields, never raw tool output.
        cleaned = []
        for raw in results:
            if raw is None:
                cleaned.append({})
                continue
            clean = {}
            if "timedOut" in raw and not isinstance(raw["timedOut"], bool):
                raise SourceProblem("partial", "unsupported-answer-timeout-provenance")
            clean["timedOut"] = raw.get("timedOut") is True
            if isinstance(raw.get("id"), str):
                clean["id"] = raw["id"]
            if isinstance(raw.get("customInput"), str):
                clean["customInput"] = bounded_text(raw["customInput"])
            selected = raw.get("selectedOptions")
            if isinstance(selected, list) and len(selected) <= MAX_QUESTIONS and all(isinstance(x, str) for x in selected):
                clean["selectedOptions"] = selected
            cleaned.append(clean)
        result = {"kind": "answer", "id": ident, "callId": call_id, "batch": isinstance(raw_results, list),
                  "results": cleaned, "cancelled": cancellation, "error": message.get("isError") is True}
        return with_time(result, "atUtc", at)
    # Known producer synthetic roles are deliberately not human input.
    if role in ("bashExecution", "branchSummary", "compactionSummary", "hookMessage"):
        return None
    raise SourceProblem("partial", "unsupported-message-role")


def observation(info, target):
    return ADAPTER + ":" + digest([target["key"], target["path"], info.st_dev, info.st_ino,
                                   info.st_size, info.st_mtime_ns, info.st_ctime_ns])


def question_public(question):
    return dict(question["fact"])


def question_outcome(fact):
    if fact["status"] not in ("answered", "cancelled", "failed"):
        return None
    return {name: fact[name] for name in (
        "id", "status", "askedAtUtc", "answeredAtUtc", "cancelledAtUtc",
        "resolvedAtUtc", "answerProvenance", "timedOut") if name in fact}


def resolve_answer(question, result, at):
    fact = question["fact"]
    if result.get("cancelled"):
        fact["status"] = "cancelled"
        with_time(fact, "cancelledAtUtc", at)
        return False
    if result.get("error"):
        fact["status"] = "failed"
        return False
    raw = result["value"]
    automatic = raw.get("timedOut") is True
    fact.update(answerProvenance="automatic" if automatic else "user", timedOut=automatic)
    custom = raw.get("customInput")
    selected = raw.get("selectedOptions")
    if custom is not None and custom["text"].strip():
        answer_text = custom["text"]
        answer_chars = custom["textChars"]
        answer_kind = "custom"
    elif selected is not None and all(value in question["options"] for value in selected) and (
            (question["multi"] and len(set(selected)) == len(selected)) or (not question["multi"] and len(selected) == 1)):
        answer_text = ", ".join(selected)
        answer_chars = len(answer_text)
        answer_kind = "selection"
    else:
        fact["status"] = "unknown"
        return False
    fact.update(status="answered", answer=answer_text[:MAX_TEXT])
    question["answerChars"] = answer_chars
    question["answerKind"] = answer_kind
    fact.pop("answeredAtUtc", None)
    fact.pop("resolvedAtUtc", None)
    with_time(fact, "resolvedAtUtc" if automatic else "answeredAtUtc", at)
    return True


def project(chain, complete, coverage):
    facts, questions, calls = {}, deque(), {}
    question_count, summary_count = 0, 0
    control_roles = {}
    for record in chain:
        if record is None:
            continue
        kind = record["kind"]
        if kind == "reset_boundary":
            facts, questions, calls = {}, deque(), {}
            question_count, summary_count, control_roles = 0, 0, {}
            continue
        if kind == "control":
            role = record["role"]
            control_roles[role] = control_roles.get(role, 0) + 1
            continue
        if kind in ("compaction", "branch_summary"):
            summary_count += 1
            continue
        at, ident = record.get("atUtc"), record["id"]
        if kind == "user":
            text = record["text"]
            human = with_time({"id": ident, "text": text, "provenance": record["provenance"],
                               "textTruncated": record["textChars"] > len(text)}, "atUtc", at)
            if record["provenance"] == "user" or "lastHuman" not in facts:
                facts["lastHuman"] = human
            if record["provenance"] == "user" and at is not None:
                facts.update(lastInteractionAtUtc=at, lastInteractionId=ident)
        elif kind == "assistant":
            text, stop = record["text"], record["stopReason"]
            clipped = record["textChars"] > len(text)
            facts["lastAssistant"] = with_time({"id": ident, "text": text, "stopReason": stop,
                                               "textTruncated": clipped}, "atUtc", at)
            if stop in TERMINALS:
                facts["lastTerminal"] = with_time({"id": ident, "stopReason": stop}, "atUtc", at)
            if stop == "stop" and text:
                facts["lastFinal"] = with_time({"id": ident, "text": text, "timeKind": record["timeKind"],
                                               "textTruncated": clipped}, "atUtc", at)
            for question in record["asks"]:
                q = {**question, "fact": dict(question["fact"])}
                questions.append(q)
                # Provider call IDs may repeat in later assistant entries.
                if q["fact"]["index"] == 0:
                    calls[q["fact"]["callId"]] = []
                calls[q["fact"]["callId"]].append(q)
                question_count += 1
                if len(questions) > MAX_TRACKED_QUESTIONS:
                    retired = questions.popleft()
                    retired_call = calls.get(retired["fact"]["callId"])
                    if retired_call is not None and retired in retired_call:
                        retired_call.remove(retired)
                        if not retired_call:
                            del calls[retired["fact"]["callId"]]
        elif kind == "answer":
            call_questions = calls.get(record["callId"], [])
            if not call_questions:
                coverage["unmatchedAskResults"] = coverage.get("unmatchedAskResults", 0) + 1
                continue
            result_by_id, duplicates = {}, set()
            for raw in record["results"]:
                qid = raw.get("id")
                if qid in result_by_id:
                    duplicates.add(qid)
                result_by_id[qid] = raw
            for q in call_questions:
                if record["cancelled"] or record["error"]:
                    raw = {}
                elif not record["batch"] and len(call_questions) == 1:
                    raw = record["results"][0]
                elif (record["batch"] and q["fact"].get("questionId") is None
                      and len(record["results"]) == len(call_questions)
                      and all("id" not in value for value in record["results"])):
                    raw = record["results"][q["fact"]["index"]]
                else:
                    qid = q["fact"].get("questionId")
                    raw = result_by_id.get(qid) if qid is not None and qid not in duplicates else None
                    if raw is None:
                        continue
                if not resolve_answer(q, {"value": raw, "cancelled": record["cancelled"], "error": record["error"]}, at):
                    continue
                if q["fact"]["answerProvenance"] == "user":
                    if at is not None:
                        facts.update(lastInteractionAtUtc=at, lastInteractionId=ident)
                    text = ("[]" if q["answerKind"] == "selection" and raw.get("selectedOptions") == []
                            else q["fact"]["answer"])
                    facts["lastHuman"] = with_time({
                        "id": ident + ":" + str(q["fact"]["index"]), "text": text, "provenance": "user",
                        "questionId": q["fact"]["id"], "callId": q["fact"]["callId"], "sourceEntryId": ident,
                        "answerKind": q["answerKind"], "structuredAnswer": True, "answerProvenance": "user",
                        "timedOut": False, "textTruncated": q["answerChars"] > len(q["fact"]["answer"]),
                    }, "atUtc", at)
    selected = [q for q in questions if q["fact"]["status"] in ("open", "unknown")][-MAX_QUESTIONS:]
    if len(selected) < MAX_QUESTIONS:
        kept = {q["fact"]["id"] for q in selected}
        selected = [q for q in questions if q["fact"]["id"] not in kept][-(MAX_QUESTIONS - len(selected)):] + selected
    kept = {q["fact"]["id"] for q in selected}
    selected = [q for q in questions if q["fact"]["id"] in kept]
    public = []
    for q in selected:
        fact = question_public(q)
        fact["textTruncated"] = q["textChars"] > len(fact["text"]) or q.get("answerChars", 0) > len(fact.get("answer", ""))
        public.append(fact)
    facts["questions"] = public
    facts["questionOutcomes"] = [question_outcome(q["fact"]) for q in questions
                                if q["fact"]["id"] not in kept and q["fact"]["status"] in ("answered", "cancelled", "failed")]
    facts["questionCoverage"] = {
        "status": "unknown" if not complete else "bounded" if question_count > len(public) else "complete",
        "knownTotal": question_count, "included": len(public), "omitted": question_count - len(public),
        "textTruncated": any(q["textTruncated"] for q in public),
        "outcomeIncluded": len(facts["questionOutcomes"]), "outcomeOmitted": 0,
        "trackingOmitted": question_count - len(questions),
    }
    coverage.update(controlsExcluded=sum(control_roles.values()), controlRolesExcluded=control_roles,
                    summariesExcluded=summary_count)
    return facts


def replay_offsets(path, target, revision, chain, metrics, deadline):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or observation(os.fstat(stream.fileno()), target) != revision:
            raise SourceProblem("partial", "source-changed-before-replay")
        for offset, expected_hash in chain:
            if time.monotonic() > deadline:
                raise SourceProblem("partial", "source-replay-limit")
            stream.seek(offset)
            line = stream.readline(MAX_RECORD_BYTES + 1)
            metrics["bytesRead"] += len(line)
            metrics["recordsRead"] += 1
            if hashlib.sha256(line).hexdigest() != expected_hash:
                raise SourceProblem("partial", "source-changed-during-replay")
            try:
                yield normalize(json.loads(line))
            except SourceProblem as problem:
                if problem.status != "partial":
                    raise
                yield None
        if time.monotonic() > deadline:
            raise SourceProblem("partial", "source-replay-limit")
        if observation(os.fstat(stream.fileno()), target) != revision:
            raise SourceProblem("partial", "source-changed-during-replay")


def fit_output(result):
    def size(value):
        return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode())

    questions = deque((q, size(q)) for q in result["questions"])
    outcomes = deque((q, size(q)) for q in result["questionOutcomes"])
    question_bytes = sum(length for _, length in questions)
    outcome_bytes = sum(length for _, length in outcomes)
    coverage = result["questionCoverage"]
    envelope = {**result, "questions": [], "questionOutcomes": []}
    while True:
        coverage["included"] = len(questions)
        coverage["omitted"] = coverage["knownTotal"] - len(questions)
        coverage["outcomeIncluded"] = len(outcomes)
        coverage["textTruncated"] = any(q.get("textTruncated", False) for q, _ in questions)
        if coverage["status"] != "unknown":
            coverage["status"] = "bounded" if coverage["omitted"] else "complete"
        total = (size(envelope) + question_bytes + max(0, len(questions) - 1)
                 + outcome_bytes + max(0, len(outcomes) - 1))
        if total <= MAX_RESULT_BYTES:
            result["questions"] = [q for q, _ in questions]
            result["questionOutcomes"] = [q for q, _ in outcomes]
            return result
        if questions:
            question, length = questions.popleft()
            question_bytes -= length
            outcome = question_outcome(question)
            if outcome is not None:
                length = size(outcome)
                outcomes.append((outcome, length))
                outcome_bytes += length
            continue
        # Oversized native identities can also occur in non-question excerpts.
        # Omit that excerpt explicitly, never truncate an identity into another.
        excerpts = [(size(envelope[name]), name) for name in
                    ("lastHuman", "lastAssistant", "lastFinal", "lastTerminal") if name in envelope]
        if excerpts and (size(envelope) > MAX_RESULT_BYTES or max(excerpts)[0] > MAX_RESULT_BYTES // 2):
            _, name = max(excerpts)
            result.pop(name)
            envelope.pop(name)
            result.update(status="partial", complete=False)
            envelope.update(status="partial", complete=False)
            issues = result["coverage"]["issues"]
            if "output-excerpt-limit" not in issues:
                issues.append("output-excerpt-limit")
            continue
        if outcomes:
            _, length = outcomes.popleft()
            outcome_bytes -= length
            coverage["outcomeOmitted"] += 1
            continue
        # An unbounded session/entry/target identity cannot fit even without facts.
        failure = {name: result[name] for name in ("key", "path", "capturedAtUtc")}
        failure.update(status="partial", reason="source-output-limit", complete=False, reusable=False,
                       questionCoverage={**coverage, "status": "unknown"})
        if size(failure) > MAX_RESULT_BYTES:
            failure.pop("key")
            failure.pop("path")
        return failure


def read_header_target(target, now):
    result = {"key": target.get("key"), "path": target.get("path"), "status": "unsupported",
              "capturedAtUtc": now, "historyRead": False}
    deadline = time.monotonic() + HEADER_SECONDS
    path, key = target.get("path"), target.get("key")
    if not isinstance(key, str) or not key or not isinstance(path, str) or not os.path.isabs(path) or "\0" in path:
        result["reason"] = "exact-local-absolute-locator-required"
        return result
    expected = target.get("expectedSessionId")
    if expected is not None and (not isinstance(expected, str) or not expected):
        result.update(status="malformed", reason="invalid-expected-session-id")
        return result
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise SourceProblem("unsupported", "source-is-not-regular-file")
        revision = observation(before, target)
        result["revision"] = revision
        # Raw FileIO avoids buffered read-ahead into transcript records after the header.
        with os.fdopen(fd, "rb", buffering=0) as stream:
            fd = None
            consumed = 0
            for _ in range(HEADER_RECORDS):
                if time.monotonic() > deadline:
                    raise SourceProblem("changed", "header-deadline")
                remaining = HEADER_BYTES - consumed
                if remaining <= 0:
                    raise SourceProblem("unsupported", "header-byte-limit")
                line = stream.readline(remaining)
                consumed += len(line)
                if time.monotonic() > deadline:
                    raise SourceProblem("changed", "header-deadline")
                if not line:
                    raise SourceProblem("unsupported", "missing-session-header")
                if not line.endswith(b"\n"):
                    raise SourceProblem("unsupported" if consumed == HEADER_BYTES else "malformed",
                                        "header-byte-limit" if consumed == HEADER_BYTES else "incomplete-header-record")
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError, RecursionError):
                    raise SourceProblem("malformed", "malformed-header-json")
                if not isinstance(record, dict):
                    raise SourceProblem("malformed", "header-record-is-not-object")
                if record.get("type") == "title":
                    if type(record.get("v")) is not int or record["v"] != 1:
                        raise SourceProblem("unsupported", "unsupported-title-version")
                    continue
                if record.get("type") != "session" or record.get("version") != 3:
                    raise SourceProblem("unsupported", "unsupported-session-header")
                session_id = record.get("id")
                if not isinstance(session_id, str) or not session_id:
                    raise SourceProblem("malformed", "invalid-session-header-id")
                result["sessionId"] = session_id
                after = os.fstat(stream.fileno())
                if observation(after, target) != revision:
                    raise SourceProblem("changed", "source-changed-during-header-read")
                if time.monotonic() > deadline:
                    raise SourceProblem("changed", "header-deadline")
                if expected is not None and expected != session_id:
                    result.update(status="changed", reason="session-header-changed")
                else:
                    result["status"] = "ready"
                return result
            raise SourceProblem("unsupported", "header-record-limit")
    except SourceProblem as problem:
        result.update(status=problem.status, reason=problem.reason)
    except FileNotFoundError:
        result.update(status="missing", reason="source-missing")
    except (OSError, ValueError, OverflowError, RecursionError):
        result.update(status="unsupported", reason="source-header-unreadable")
    finally:
        if fd is not None:
            os.close(fd)
    return result


def read_target(target, now):
    result = {"key": target.get("key"), "path": target.get("path"), "status": "unsupported",
              "capturedAtUtc": now, "reusable": False}
    metrics = {"bytesRead": 0, "recordsRead": 0}
    result["metrics"] = metrics
    deadline = time.monotonic() + SOURCE_SECONDS
    path, key = target.get("path"), target.get("key")
    if not isinstance(key, str) or not key or not isinstance(path, str) or not os.path.isabs(path) or "\0" in path:
        result["reason"] = "exact-local-absolute-locator-required"
        return result
    fd = None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise SourceProblem("unsupported", "source-is-not-regular-file")
        revision = observation(before, target)
        result["revision"] = revision
        if target.get("previousRevision") == revision:
            result.update(status="unchanged", reusable=True)
            return result
        entries, header, versions, issues = {}, None, set(), set()
        selected, last_self = None, None
        with os.fdopen(fd, "rb") as stream:
            fd = None
            while True:
                if time.monotonic() > deadline:
                    issues.add("source-deadline")
                    break
                if metrics["bytesRead"] >= MAX_SOURCE_BYTES or metrics["recordsRead"] >= MAX_RECORDS:
                    issues.add("source-limit")
                    break
                offset = stream.tell()
                line = stream.readline(MAX_RECORD_BYTES + 1)
                metrics["bytesRead"] += len(line)
                if not line:
                    break
                if len(line) > MAX_RECORD_BYTES:
                    issues.add("oversized-record")
                    while not line.endswith(b"\n") and line:
                        if time.monotonic() > deadline or metrics["bytesRead"] >= MAX_SOURCE_BYTES:
                            break
                        line = stream.readline(MAX_RECORD_BYTES + 1)
                        metrics["bytesRead"] += len(line)
                    continue
                if not line.endswith(b"\n"):
                    issues.add("partial-line")
                    break
                if not line.strip():
                    continue
                metrics["recordsRead"] += 1
                try:
                    record = json.loads(line)
                except (ValueError, UnicodeError, RecursionError):
                    raise SourceProblem("malformed", "malformed-json-record")
                if not isinstance(record, dict):
                    raise SourceProblem("malformed", "record-is-not-object")
                kind = record.get("type")
                if kind == "title":
                    if record.get("v") != 1:
                        issues.add("unsupported-title-version")
                    continue
                if kind == "session":
                    if header is not None:
                        raise SourceProblem("malformed", "multiple-session-headers")
                    if record.get("version") != 3 or not isinstance(record.get("id"), str) or not record["id"]:
                        raise SourceProblem("unsupported", "unsupported-session-header")
                    header = {"id": record["id"], "version": record["version"]}
                    if target.get("expectedSessionId") is not None and target["expectedSessionId"] != header["id"]:
                        raise SourceProblem("unsupported", "session-header-mismatch")
                    continue
                if header is None:
                    raise SourceProblem("unsupported", "missing-session-header")
                ident, parent = record.get("id"), record.get("parentId")
                if not isinstance(ident, str) or not ident or (parent is not None and not isinstance(parent, str)) or "parentId" not in record:
                    raise SourceProblem("malformed", "invalid-entry-identity")
                if "activeLeafId" in record and record["activeLeafId"] is not None and not isinstance(record["activeLeafId"], str):
                    raise SourceProblem("malformed", "invalid-active-leaf")
                runtime = record.get("runtime")
                writer = runtime.get("version") if isinstance(runtime, dict) else None
                if writer is not None and not isinstance(writer, str):
                    raise SourceProblem("unsupported", "unsupported-runtime-identity")
                if writer is None:
                    issues.add("missing-writer-version")
                else:
                    versions.add(writer)
                    if writer not in SUPPORTED_WRITERS:
                        issues.add("unqualified-writer-version")
                line_hash = hashlib.sha256(line).hexdigest()
                if ident in entries and entries[ident][2] != line_hash:
                    raise SourceProblem("malformed", "conflicting-entry-id")
                try:
                    normalize(record)
                except UnicodeError:
                    raise SourceProblem("malformed", "invalid-unicode-text")
                except SourceProblem as problem:
                    if problem.status != "partial":
                        raise
                    issues.add(problem.reason)
                entries[ident] = (parent, offset, line_hash)
                selected = record.get("activeLeafId", ident)
                if selected == ident:
                    last_self = ident
            after = os.fstat(stream.fileno())
        if header is None:
            raise SourceProblem("unsupported", "missing-session-header")
        if observation(after, target) != revision:
            issues.add("source-changed-during-read")
        records_complete = not issues.intersection(("source-deadline", "source-limit", "partial-line",
                                                    "oversized-record", "source-changed-during-read"))
        if not records_complete:
            result.update(status="partial", sessionId=header["id"], schemaVersion=header["version"],
                          writerVersions=sorted(versions), selectedLeafId=None, selection="unknown", complete=False,
                          coverage={"records": metrics["recordsRead"], "entries": len(entries), "recordsComplete": False,
                                    "historyScope": "unavailable", "selectionSupport": "unknown",
                                    "writerSupport": "unknown" if issues.intersection(("missing-writer-version", "unqualified-writer-version")) else "qualified",
                                    "schemaSupport": "schema3-observed-writers", "issues": sorted(issues),
                                    "liveLeaf": "not-observed"})
            result["questionCoverage"] = {"status": "unknown", "knownTotal": 0, "included": 0, "omitted": 0}
            return result
        if selected is not None and selected not in entries:
            selected = last_self
            selection_fallback = True
        else:
            selection_fallback = False
        chain, seen = [], set()
        cursor = selected
        ancestry_complete = True
        while cursor is not None:
            if time.monotonic() > deadline:
                issues.add("source-ancestry-deadline")
                ancestry_complete = False
                break
            if cursor in seen:
                raise SourceProblem("malformed", "ancestry-cycle")
            seen.add(cursor)
            record_tuple = entries.get(cursor)
            if record_tuple is None:
                issues.add("missing-parent")
                ancestry_complete = False
                break
            parent, offset, line_hash = record_tuple
            chain.append((offset, line_hash))
            cursor = parent
        complete = not issues
        history_scope = "selected-ancestry"
        coverage = {"records": metrics["recordsRead"], "entries": len(entries), "ancestryEntries": len(chain),
                    "offBranchEntries": len(entries) - len(chain), "ancestryComplete": ancestry_complete,
                    "writerSupport": "unknown" if issues.intersection(("missing-writer-version", "unqualified-writer-version")) else "qualified",
                    "selectionSupport": "unknown" if issues.intersection(("missing-writer-version", "unqualified-writer-version")) else "schema3-replayed",
                    "schemaSupport": "schema3-observed-writers", "issues": sorted(issues),
                    "selectionFallback": selection_fallback, "liveLeaf": "not-observed"}
        coverage.update(recordsComplete=True, historyScope=history_scope)
        result.update(status="ready" if complete else "partial", sessionId=header["id"], schemaVersion=header["version"],
                      writerVersions=sorted(versions), selectedLeafId=selected, selection="disk-replayed", complete=complete, coverage=coverage)
        result["questionCoverage"] = {"status": "unknown", "knownTotal": 0, "included": 0, "omitted": 0}
        result.update(project(replay_offsets(path, target, revision, reversed(chain), metrics, deadline),
                              complete, coverage))
        result = fit_output(result)
        result["reusable"] = result.get("reason") != "source-output-limit" and not issues.intersection((
            "source-deadline", "source-ancestry-deadline", "source-changed-during-read", "partial-line"))
        return result
    except SourceProblem as problem:
        result.update(status=problem.status, reason=problem.reason)
        if problem.status == "partial":
            result["complete"] = False
            if "coverage" in result:
                result["coverage"]["issues"] = sorted(set(result["coverage"]["issues"]) | {problem.reason})
            result["questionCoverage"] = {"status": "unknown", "knownTotal": 0, "included": 0, "omitted": 0}
        return result
    except FileNotFoundError:
        result.update(status="missing", reason="source-missing")
        return result
    except (OSError, ValueError, OverflowError, RecursionError):
        result.update(status="partial" if "sessionId" in result else "missing",
                      reason="source-unreadable-or-changed", complete=False)
        return result
    finally:
        if fd is not None:
            os.close(fd)


def local_zone():
    configured = os.environ.get("TZ", "").lstrip(":")
    if configured and not configured.startswith("/"):
        try:
            ZoneInfo(configured)
            return configured
        except (ZoneInfoNotFoundError, ValueError):
            pass
    try:
        target = str(Path("/etc/localtime").resolve())
        marker = "/zoneinfo/"
        if marker in target:
            return target.split(marker, 1)[1]
    except OSError:
        pass
    try:
        return Path("/etc/timezone").read_text(encoding="utf-8").strip()
    except OSError:
        return None


def resolve_date(request):
    date, civil_time = request.get("civilDate"), request.get("civilTime", "00:00")
    zone_explicit = "zone" in request
    zone_name = request.get("zone") if zone_explicit else local_zone()
    now = request.get("nowUtc")
    result = {"protocol": 1, "requestId": request["requestId"], "status": "invalid",
              "civilDate": date, "civilTime": civil_time}
    if isinstance(zone_name, str):
        result["zone"] = zone_name
        result["zoneSource"] = "request" if zone_explicit else "system"
    try:
        if not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            raise ValueError("civilDate must be YYYY-MM-DD")
        if not isinstance(civil_time, str) or not re.fullmatch(r"\d{2}:\d{2}", civil_time):
            raise ValueError("civilTime must be HH:MM")
        if now is not None and not finite(now):
            raise ValueError("nowUtc must be finite")
        if not isinstance(zone_name, str) or not zone_name or zone_name.startswith("/"):
            raise ValueError("local IANA time zone unavailable; supply zone")
        try:
            zone = ZoneInfo(zone_name)
        except ZoneInfoNotFoundError:
            raise ValueError("unknown time zone " + zone_name + "; use an IANA name such as America/New_York")
        civil = datetime.fromisoformat(date + "T" + civil_time)
        local = date + " " + civil_time + " " + zone_name
        candidates = set()
        for fold in (0, 1):
            aware = civil.replace(tzinfo=zone, fold=fold)
            utc = aware.astimezone(timezone.utc)
            if utc.astimezone(zone).replace(tzinfo=None) == civil:
                candidates.add(utc.timestamp())
        if not candidates:
            result["problem"] = "nonexistent"
            raise ValueError(local + " does not exist: clocks skip forward at that time. Choose another time.")
        if len(candidates) != 1:
            result.update(status="ambiguous", problem="repeated",
                          error=local + " happens twice: clocks fall back at that time. Choose another time.")
            return result
        instant = candidates.pop()
        utc_text = datetime.fromtimestamp(instant, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        result.update(status="ready", resolvedUTC=instant, display=local, utcDisplay=utc_text)
        text = "Bring back " + local + (" (system time zone)" if not zone_explicit else "") + " = " + utc_text + " UTC"
        if now is not None:
            result["past"] = instant <= now
            if result["past"]:
                text += ". That time has already passed: the conversation returns to Attention on the next refresh."
        result["confirmation"] = text
    except (ValueError, OverflowError) as error:
        result["error"] = str(error)
    return result


def respond(request):
    if (not isinstance(request, dict) or type(request.get("protocol")) is not int or request["protocol"] != 1
            or not isinstance(request.get("requestId"), str)):
        raise ValueError("protocol 1 and string requestId required")
    if request.get("op") == "date":
        return resolve_date(request)
    if request.get("op") not in (None, "source", "header"):
        raise ValueError("unsupported operation")
    targets, now = request.get("targets"), request.get("nowUtc")
    if not isinstance(targets, list) or len(targets) > MAX_TARGETS or not finite(now):
        raise ValueError("finite nowUtc and at most 64 targets required")
    header_mode = request.get("op") == "header"
    reader = read_header_target if header_mode else read_target
    results = []
    for target in targets:
        if not isinstance(target, dict):
            result = {"key": None, "path": None, "status": "malformed", "capturedAtUtc": now, "reason": "invalid-target"}
            result["historyRead" if header_mode else "reusable"] = False
            results.append(result)
        else:
            results.append(reader(target, now))
    return {"protocol": 1, "requestId": request["requestId"], "results": results}


def main():
    request = None
    try:
        raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
        if len(raw) > MAX_REQUEST_BYTES:
            raise ValueError("request exceeds 256 KiB")
        request = json.loads(raw)
        result = respond(request)
    except (ValueError, UnicodeError, RecursionError) as error:
        result = {"protocol": 1, "requestId": request.get("requestId") if isinstance(request, dict) else None,
                  "status": "malformed", "error": str(error)}
    sys.stdout.write(json.dumps(result, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
