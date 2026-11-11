#!/usr/bin/env python3
"""Read-only, finite OMP source projection. JSON protocol 1 on stdin/stdout.

Only schema 3 and explicitly observed record shapes are read.
Selection is persisted disk replay, never a claim about an in-memory branch.
An observation revision is a stat fingerprint, not a producer generation or
protection against an arbitrary mutation that preserves all observed metadata.

Producer replay reference: @oh-my-pi/pi-coding-agent@18.14.0
src/session/session-entries.ts, resolveSessionLeafId. Version-matched published
source plus observed records is not an attestation of the installed binary.

Per-field trust (coverage.fields). Every consumed fact belongs to one field:
  clock      lastHuman, lastAssistant, lastTerminal, lastFinal, lastInteraction*,
             lastActivityAtUtc, lastError, inFlight
  questions  questions, questionOutcomes, questionCoverage
A field is "supported" when every record it reads parsed under a known shape and
the selected ancestry was replayed whole; otherwise "unknown". A record whose
shape is unrecognised demotes the fields it may carry: an ask call or ask result
that does not parse demotes `questions` only (its assistant clock still counts);
any other unparseable record, a missing parent or an output excerpt that had to be
dropped demotes both. Any such problem also makes the result partial
(complete=false), so question authority is withheld; the clock may still be shown.

Writer versions are an advisory, not a gate. writerSupport is "qualified" when
every runtime.version is in SUPPORTED_WRITERS and "unknown" otherwise (missing or
unlisted). It never demotes a field or completeness: a new omp release that writes
the same record shapes is read like the last one, and a release that changes a
shape demotes the field that shape feeds. (Gating the clock on this list dashed
every row after the 18.16.0 and 18.18.x updates; docs/PAPERCUTS.md.) A version is
listed after `python3 tools/qualify_writer.py <version>` passes: real sessions it
alone wrote parse with no issue and every consumed fact equals an independent
minimal reader of the raw JSONL. 18.12.3 and older are excluded: their loader
honors activeLeafId on model_usage entries only. 18.16.0 qualified 2026-11-02
(isolated-HOME sessions: print-mode tool call, rpc-ui ask select/multi/custom/
cancelled, tool-not-found failure, one 18.13.2 session resumed under 18.16.0).
18.18.0/.1/.2/.3/.5/.6/.7 qualified 2026-11-10 on read-only copies of the real
sessions they wrote (56/305/22/78/4/36/29 written by each alone), including five
answered HTML-form asks whose parsed wording equals the producer's own: every
comparable file passed; the only failures were not shapes (one >8 MiB record,
two files with more than 32 questions, one malformed 18.14.0-written ask). The
producer source diff was not run: the installed 18.18.8 is a compiled binary,
read only for the html-form and ask strings this docstring cites.

Ask shapes. `arguments.questions` (18.12-18.16) carries question/options per
question; results carry selectedOptions/customInput (single or `results` batch).
`arguments.html` (18.18) is a <form>; each named control is one question, worded
as the producer words it (packages/tui/src/html-form at 18.18.8: the control's
label, else the text block just before it, else its fieldset legend, else its
lone option, else its name) and the result is `details.answers` [{name, question,
answer}] in control order. A host-cancelled ask ("Ask tool was cancelled by the
user", isError) and "Ask interrupted by message" are reported as status failed,
never answered.

Approval prompts: omp 18.18.8 emits tool_approval_requested/resolved only to
extensions and the terminal notifier (OSC 777 permission_request); no session
record carries a pending approval, so none is reported here.

Provider errors. An assistant turn with stopReason "error" sets lastError
{kind, atUtc}; any later assistant turn on the selected branch clears it. kind is
"usage_limit" (producer flag UsageLimit 0x80000 in errorId, packages/ai/src/error/
flags.ts, or "usage limit" in errorMessage), "rate_limit" (errorStatus 429 or "rate
limit"/"at capacity" in errorMessage), "api_error" (another HTTP errorStatus) or
"provider" (network, stall, overload).
"""
from __future__ import annotations

from collections import deque
from datetime import datetime
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import json
import math
import os
import re
import sqlite3
import stat
import sys
import time

ADAPTER = "omp-facts-v5"
SUPPORTED_WRITERS = frozenset(("18.12.5", "18.12.6", "18.13.0", "18.13.1", "18.13.2", "18.13.3",
                               "18.14.0", "18.14.1", "18.14.2", "18.15.0", "18.16.0",
                               "18.18.0", "18.18.1", "18.18.2", "18.18.3", "18.18.5", "18.18.6", "18.18.7"))
FIELDS = ("clock", "questions")
MAX_TARGETS = 64
MAX_RECORD_BYTES = 8 * 1024 * 1024
MAX_SOURCE_BYTES = 1024 * 1024 * 1024
MAX_RECORDS = 200000
SOURCE_SECONDS = 6
HEADER_BYTES = 64 * 1024
HEADER_RECORDS = 8
HEADER_SECONDS = 1
MAX_TEXT = 2000
# Replies keep only the excerpt the rail shows (view.luau source details, model.luau REPLY_TEXT_CHARS); the whole reply
# stays in the session file. Human input is shown only by its time, so its text is not carried.
REPLY_TEXT = 300
MAX_QUESTIONS = 32
MAX_TRACKED_QUESTIONS = 512
MAX_RUNNING_TOOLS = 64  # parallel tool calls tracked at once; more are not waited on by name
MAX_TOOL_NAME = 64
MAX_LIMIT_ACCOUNTS = 256  # accounts of one provider read from omp's store
LIMIT_DB_SECONDS = 0.25  # wait on omp's store lock at most this long
LIMIT_KINDS = frozenset(("usage_limit", "rate_limit"))
MAX_RESULT_BYTES = 128 * 1024
MAX_REQUEST_BYTES = 256 * 1024
# An HTML-form ask larger or deeper than this is not parsed; its questions field reads unknown.
MAX_FORM_CHARS = 256 * 1024
MAX_FORM_DEPTH = 64
METADATA_TYPES = frozenset(("model_change", "thinking_level_change", "service_tier_change",
    "model_usage", "custom", "custom_message", "label", "title_change", "credential_pin",
    "ttsr_injection", "compaction", "branch_summary", "reset_boundary", "mode_change", "session_init"))
TERMINALS = frozenset(("stop", "length", "error", "aborted"))
USAGE_LIMIT_FLAG = 0x80000
USAGE_LIMIT_TEXT = re.compile(r"usage[ _]limit", re.IGNORECASE)
RATE_LIMIT_TEXT = re.compile(r"\b429\b|rate[ _-]?limit|at capacity", re.IGNORECASE)


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


# HTML-form asks (omp 18.18). A port of the producer's question wording (packages/tui/src/html-form at 18.18.8:
# _G.build and Ou): blocks are text, fields and opaque media; a field's question is its label, else the text block
# just before it, else its section (fieldset legend) title, else its lone option's label, else its name.
FORM_VOID = frozenset(("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                       "source", "track", "wbr"))
FORM_SKIPPED = frozenset(("button", "head", "iframe", "link", "meta", "noscript", "script", "style", "template", "title"))
FORM_BLOCKS = frozenset(("address", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt", "figure",
                         "figcaption", "footer", "header", "li", "main", "nav", "p", "section"))
FORM_HEADINGS = frozenset(("h1", "h2", "h3", "h4", "h5", "h6", "summary"))
FORM_CONTROLS = frozenset(("input", "select", "textarea"))
FORM_UNANSWERED_INPUTS = frozenset(("button", "file", "image", "reset", "submit"))
# An open <p> ends where one of these starts; an open <li>/<option> ends at the next sibling of its kind.
FORM_CLOSES_P = FORM_BLOCKS | FORM_HEADINGS | frozenset(("fieldset", "form", "hr", "ol", "ul", "pre", "table", "legend"))


class FormNode:
    __slots__ = ("tag", "attrs", "children", "parent")

    def __init__(self, tag, attrs, parent):
        self.tag, self.attrs, self.children, self.parent = tag, attrs, [], parent

    def elements(self):
        return [child for child in self.children if isinstance(child, FormNode)]

    def descendants(self, tags):
        found, stack = [], list(reversed(self.elements()))
        while stack:
            node = stack.pop()
            if node.tag in tags:
                found.append(node)
            stack.extend(reversed(node.elements()))
        return found

    def closest(self, tag):
        node = self
        while node is not None and node.tag != tag:
            node = node.parent
        return node

    def contains(self, other):
        while other is not None and other is not self:
            other = other.parent
        return other is self

    def text_content(self):
        return "".join(child if isinstance(child, str) else child.text_content() for child in self.children)


class FormTree(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = FormNode("#document", {}, None)
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        self.open(tag, attrs, tag in FORM_VOID)

    def handle_startendtag(self, tag, attrs):
        self.open(tag, attrs, True)

    def open(self, tag, attrs, void):
        if tag in FORM_CLOSES_P:
            self.close_open("p", ("button", "fieldset", "form", "table", "td", "th", "li"))
        if tag in ("li", "option"):
            self.close_open(tag, ("ul", "ol") if tag == "li" else ("select", "datalist", "optgroup"))
        values = {}
        for name, value in attrs:
            values.setdefault(name, "" if value is None else value)
        node = FormNode(tag, values, self.stack[-1])
        self.stack[-1].children.append(node)
        if not void:
            if len(self.stack) > MAX_FORM_DEPTH:
                raise SourceProblem("partial", "unsupported-ask-form")
            self.stack.append(node)

    def close_open(self, tag, scope):
        for index in range(len(self.stack) - 1, 0, -1):
            name = self.stack[index].tag
            if name == tag:
                del self.stack[index:]
                return
            if name in scope:
                return

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def form_words(text):
    return " ".join(text.split())


def form_text(node):
    """Visible text of a node, without controls, media or skipped elements (producer #g)."""
    parts = []

    def walk(current):
        for child in current.children:
            if isinstance(child, str):
                parts.append(child)
                continue
            tag = child.tag
            if tag in FORM_SKIPPED or tag in FORM_CONTROLS or tag == "svg":
                continue
            if tag == "br":
                parts.append("\n")
                continue
            if tag == "img":
                parts.append(child.attrs.get("alt", ""))
                continue
            if tag in FORM_BLOCKS or tag in FORM_HEADINGS:
                parts.append(" ")
            walk(child)

    walk(node)
    return "".join(parts).strip()


class FormQuestions:
    """Named form controls in producer order, each with the question text the producer shows for it."""

    def __init__(self, root):
        self.root = root
        self.section = {"title": "", "blocks": []}
        self.sections = [self.section]
        self.pending, self.depth, self.groups, self.fields = [], 0, {}, []
        ids = {control.attrs["id"] for control in root.descendants(FORM_CONTROLS) if control.attrs.get("id")}
        self.labels = {}
        for label in root.descendants(("label",)):
            target = label.attrs.get("for")
            if target and target in ids and target not in self.labels:
                self.labels[target] = label

    def build(self):
        self.children(self.root)
        self.flush()
        questions = []
        for section in self.sections:
            before = ""
            for block in section["blocks"]:
                if block["kind"] == "field":
                    field = block["field"]
                    lone = field["options"][0] if field["kind"] == "choice" and len(field["options"]) == 1 else ""
                    field["question"] = form_words(field["label"] or before or section["title"] or lone or field["name"])
                    before = ""
                else:
                    before = block.get("text", "")
        for field in self.fields:
            if field["name"]:
                questions.append({"name": field["name"], "question": field["question"] or field["name"]})
        return questions

    def flush(self):
        text = "".join(self.pending).strip()
        self.pending = []
        if text:
            self.section["blocks"].append({"kind": "text", "text": text})

    def opaque(self):
        self.section["blocks"].append({"kind": "opaque"})

    def start_section(self, title):
        if not self.section["blocks"] and not self.section["title"]:
            self.section["title"] = title
            return
        self.section = {"title": title, "blocks": []}
        self.sections.append(self.section)

    def children(self, node):
        for child in node.children:
            self.node(child)

    def node(self, node):
        if isinstance(node, str):
            self.pending.append(node)
            return
        tag = node.tag
        if tag in FORM_SKIPPED:
            return
        if tag == "br":
            self.pending.append("\n")
        elif tag == "hr":
            self.flush()
        elif tag in FORM_CONTROLS:
            self.control(node, "")
        elif tag == "label":
            target = node.attrs.get("for")
            if target and self.labels.get(target) is node:
                return
            controls = node.descendants(FORM_CONTROLS)
            if not controls:
                self.children(node)
                return
            self.flush()
            text = form_text(node)
            for control in controls:
                self.control(control, text)
        elif tag == "fieldset":
            self.flush()
            legend = next((child for child in node.elements() if child.tag == "legend"), None)
            if self.depth > 0:
                if legend is not None:
                    self.node(legend)
            else:
                self.start_section(form_text(legend) if legend is not None else "")
            self.depth += 1
            for child in node.children:
                if child is not legend:
                    self.node(child)
            self.flush()
            self.depth -= 1
            if self.depth == 0:
                self.start_section("")
        elif tag in ("ul", "ol"):
            self.flush()
            if node.descendants(FORM_CONTROLS):
                self.children(node)
                self.flush()
            elif any(form_text(item) for item in node.elements() if item.tag == "li"):
                self.opaque()
        elif tag in ("pre", "svg"):
            self.flush()
            self.opaque()
        elif tag == "img":
            self.flush()
            if node.attrs.get("src", "").strip():
                self.opaque()
        elif tag == "table":
            self.table(node)
        elif tag == "legend" or tag in FORM_HEADINGS or tag in FORM_BLOCKS:
            self.flush()
            self.children(node)
            self.flush()
        else:
            self.children(node)

    def table(self, table):
        self.flush()
        rows = [row for row in table.descendants(("tr",)) if row.closest("table") is table]
        if not table.descendants(FORM_CONTROLS):
            if any(form_text(cell) for row in rows for cell in row.elements() if cell.tag in ("td", "th")):
                self.opaque()
            return
        headers = []
        for row in rows:
            cells = [cell for cell in row.elements() if cell.tag in ("td", "th")]
            if all(cell.tag == "th" for cell in cells) and not row.descendants(FORM_CONTROLS):
                headers = [form_text(cell) for cell in cells]
                continue
            words = [form_text(cell) for cell in cells if not cell.descendants(FORM_CONTROLS)]
            line = " · ".join(word for word in words if word)
            if line:
                self.section["blocks"].append({"kind": "text", "text": line})
            for position, cell in enumerate(cells):
                for control in cell.descendants(FORM_CONTROLS):
                    label = control.closest("label")
                    text = form_text(label) if label is not None and cell.contains(label) else form_text(cell)
                    self.control(control, text or (headers[position] if position < len(headers) else ""))

    def control(self, node, label):
        self.flush()
        if not label:
            target = self.labels.get(node.attrs.get("id")) if node.attrs.get("id") else None
            label = form_text(target) if target is not None else (node.attrs.get("aria-label") or node.attrs.get("title") or "").strip()
        name = node.attrs.get("name", "")
        derived = re.sub(r"[_-]+", " ", name)
        if node.tag == "select":
            options = [form_words(option.text_content()) for option in node.descendants(("option",))]
            self.add({"kind": "choice", "name": name, "label": label, "options": options})
            return
        if node.tag == "textarea":
            self.add({"kind": "text", "name": name, "label": label or derived, "options": []})
            return
        kind = node.attrs.get("type", "text").lower()
        if kind in FORM_UNANSWERED_INPUTS or kind == "hidden":
            return
        if kind in ("radio", "checkbox"):
            option = label or node.attrs.get("value", name)
            group = self.groups.get((kind, name))
            if group is not None:
                group["options"].append(option)
                return
            group = {"kind": "choice", "name": name, "label": "", "options": [option]}
            self.groups[(kind, name)] = group
            self.add(group)
            return
        self.add({"kind": "text", "name": name, "label": label or derived, "options": []})

    def add(self, field):
        self.fields.append(field)
        self.section["blocks"].append({"kind": "field", "field": field})


def form_questions(html):
    """[{name, question}] for each named control of an ask form, in the order the producer answers them."""
    if len(html) > MAX_FORM_CHARS:
        raise SourceProblem("partial", "unsupported-ask-form")
    tree = FormTree()
    try:
        tree.feed(html)
        tree.close()
    except (AssertionError, ValueError) as error:
        raise SourceProblem("partial", "unsupported-ask-form") from error
    forms = tree.root.descendants(("form",))
    return FormQuestions(forms[0] if forms else tree.root).build()


def form_question(raw, entry_id, call_id, index, at):
    text = raw["question"]
    question = {"id": json.dumps([entry_id, call_id, raw["name"], index], separators=(",", ":")),
                "callId": call_id, "index": index, "text": text[:MAX_TEXT], "status": "open", "questionId": raw["name"]}
    with_time(question, "askedAtUtc", at)
    return {"fact": question, "options": [], "multi": False, "form": True, "textChars": len(text)}


def ask_questions(arguments, entry_id, call_id, at):
    if isinstance(arguments.get("html"), str):
        raws = form_questions(arguments["html"])
        if len(raws) > MAX_QUESTIONS:
            raise SourceProblem("partial", "unsupported-ask-questions")
        make = form_question
    else:
        raws = arguments.get("questions")
        if not isinstance(raws, list) or not raws or len(raws) > MAX_QUESTIONS:
            raise SourceProblem("partial", "unsupported-ask-questions")
        make = allowed_question
    asks, seen = [], set()
    for index, raw in enumerate(raws):
        q = make(raw, entry_id, call_id, index, at)
        qid = q["fact"].get("questionId")
        if qid is not None and qid in seen:
            raise SourceProblem("partial", "duplicate-question-id")
        seen.add(qid)
        asks.append(q)
    return asks


def provider_error_kind(message):
    flags, status, text = message.get("errorId"), message.get("errorStatus"), message.get("errorMessage")
    text = text if isinstance(text, str) else ""
    if (type(flags) is int and flags & USAGE_LIMIT_FLAG) or USAGE_LIMIT_TEXT.search(text):
        return "usage_limit"
    if status == 429 or RATE_LIMIT_TEXT.search(text):
        return "rate_limit"
    if type(status) is int:
        return "api_error"
    return "provider"


def ask_answer(message, ident, at):
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
    if "timedOut" in details and not isinstance(details["timedOut"], bool):
        raise SourceProblem("partial", "unsupported-answer-timeout-provenance")
    answers = details.get("answers")
    if answers is not None:
        # HTML-form result: one {name, question, answer} per named control; timedOut covers the whole form.
        if not isinstance(answers, list) or len(answers) > MAX_QUESTIONS:
            raise SourceProblem("partial", "unsupported-form-result")
        cleaned = []
        for raw in answers:
            if not isinstance(raw, dict) or not isinstance(raw.get("name"), str) or not isinstance(raw.get("answer"), str):
                raise SourceProblem("partial", "unsupported-form-result")
            cleaned.append({"id": raw["name"], "formAnswer": bounded_text(raw["answer"]),
                            "timedOut": details.get("timedOut") is True})
        result = {"kind": "answer", "id": ident, "callId": call_id, "batch": True, "results": cleaned,
                  "cancelled": cancellation, "error": message.get("isError") is True}
        return with_time(result, "atUtc", at)
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


def normalize(entry):
    """One record's facts, or None. Raises SourceProblem("partial") when the record's shape is unknown, which demotes
    every field; a shape problem confined to ask questions/answers is returned in `problems` as (field, reason)."""
    kind, ident = entry.get("type"), entry["id"]
    # omp marks each tool call as it starts running; a start with no result yet is the tool the agent is waiting on.
    if kind == "custom" and entry.get("customType") == "tool_execution_start":
        data = entry.get("data")
        call_id = data.get("toolCallId") if isinstance(data, dict) else None
        if not isinstance(call_id, str) or not call_id:
            return None
        name = data.get("toolName")
        start = {"kind": "tool_start", "id": ident, "callId": call_id,
                 "toolName": name[:MAX_TOOL_NAME] if isinstance(name, str) and name else "tool"}
        return with_time(start, "atUtc", recorded_time(data.get("startedAt")) or recorded_time(entry.get("timestamp")))
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
        if stop == "error":
            result["errorKind"] = provider_error_kind(message)
            provider = message.get("provider")
            result["provider"] = provider[:MAX_TOOL_NAME] if isinstance(provider, str) and provider else None
        with_time(result, "atUtc", assistant_at)
        content = message.get("content")
        try:
            for part in content if isinstance(content, list) else []:
                if not isinstance(part, dict) or part.get("type") != "toolCall" or part.get("name") != "ask":
                    continue
                arguments, call_id = part.get("arguments"), part.get("id")
                if not isinstance(arguments, dict) or not isinstance(call_id, str) or not call_id:
                    raise SourceProblem("partial", "unsupported-ask-call")
                result["asks"].extend(ask_questions(arguments, ident, call_id, assistant_at))
        except SourceProblem as problem:
            result["asks"], result["problems"] = [], [("questions", problem.reason)]
        return result
    if role == "toolResult":
        call_id = message.get("toolCallId")
        tool = with_time({"kind": "tool", "id": ident, "callId": call_id if isinstance(call_id, str) else None}, "atUtc", at)
        if message.get("toolName") != "ask":
            return tool
        try:
            return ask_answer(message, ident, at)
        except SourceProblem as problem:
            tool["problems"] = [("questions", problem.reason)]
            return tool
    # Known producer synthetic roles are deliberately not human input.
    if role in ("bashExecution", "branchSummary", "compactionSummary", "hookMessage"):
        return None
    raise SourceProblem("partial", "unsupported-message-role")


def provider_limit(database, provider, now):
    """omp's own deadline for a limited provider: it blocks an account until a deadline when it hits a limit, and
    deletes the block once that passes. {"status": "blocked", "untilUtc"} while every enabled account of the provider
    is blocked (until the first frees); otherwise None. No block is not a reset: an expired or never-written block
    says nothing about the plan, so nothing is claimed."""
    try:
        connection = sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True, timeout=LIMIT_DB_SECONDS)
    except (sqlite3.Error, ValueError):
        return None
    try:
        rows = connection.execute(
            "SELECT c.id, MAX(b.blocked_until_ms) FROM auth_credentials AS c "
            "LEFT JOIN auth_credential_blocks AS b ON b.credential_id = c.id AND b.blocked_until_ms > ? "
            "WHERE c.provider = ? AND c.disabled_cause IS NULL GROUP BY c.id LIMIT ?",
            (int(now * 1000), provider, MAX_LIMIT_ACCOUNTS)).fetchall()
    except sqlite3.Error:
        return None
    finally:
        connection.close()
    if not rows or any(until is None for _, until in rows):
        return None
    return {"status": "blocked", "untilUtc": min(until for _, until in rows) / 1000}


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
    form = raw.get("formAnswer")
    if form is not None and question.get("form"):
        # A submitted form answers every named control; a blank text field is answered with "".
        answer_text = form["text"]
        answer_chars = form["textChars"]
        answer_kind = "form"
    elif custom is not None and custom["text"].strip():
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
    # What a working agent is waiting on at the branch's end: tool calls started without a result, else the model
    # since the prompt or tool result that started its call. A terminal assistant turn waits on nothing.
    running, model_since = {}, None
    question_count, summary_count = 0, 0
    control_roles = {}
    for record in chain:
        if record is None:
            continue
        kind = record["kind"]
        if kind == "reset_boundary":
            facts, questions, calls = {}, deque(), {}
            running, model_since = {}, None
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
        if kind == "tool_start":
            if at is not None and len(running) < MAX_RUNNING_TOOLS:
                running[record["callId"]] = (at, record["toolName"])
            continue
        if kind in ("assistant", "tool", "answer") and at is not None:
            facts["lastActivityAtUtc"] = max(at, facts.get("lastActivityAtUtc", at))
        if kind in ("tool", "answer"):
            running.pop(record.get("callId"), None)
        if kind in ("user", "tool", "answer"):
            model_since = at
        elif kind == "assistant":
            model_since = None
            if record["stopReason"] in TERMINALS:
                running = {}
        if kind == "user":
            human = with_time({"id": ident, "provenance": record["provenance"]}, "atUtc", at)
            if record["provenance"] == "user" or "lastHuman" not in facts:
                facts["lastHuman"] = human
            if record["provenance"] == "user" and at is not None:
                facts.update(lastInteractionAtUtc=at, lastInteractionId=ident)
        elif kind == "assistant":
            text, stop = record["text"], record["stopReason"]
            excerpt, clipped = text[:REPLY_TEXT], record["textChars"] > REPLY_TEXT
            facts["lastAssistant"] = with_time({"id": ident, "text": excerpt, "stopReason": stop,
                                               "textTruncated": clipped}, "atUtc", at)
            if stop in TERMINALS:
                facts["lastTerminal"] = with_time({"id": ident, "stopReason": stop}, "atUtc", at)
            if stop == "stop" and text:
                facts["lastFinal"] = with_time({"id": ident, "text": excerpt, "timeKind": record["timeKind"],
                                               "textTruncated": clipped}, "atUtc", at)
            # Only the newest assistant turn's ending counts: a later turn of any kind clears a provider error.
            if stop == "error":
                failure = {"id": ident, "kind": record["errorKind"]}
                if record["provider"]:
                    failure["provider"] = record["provider"]
                facts["lastError"] = with_time(failure, "atUtc", at)
            else:
                facts.pop("lastError", None)
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
                    facts["lastHuman"] = with_time({
                        "id": ident + ":" + str(q["fact"]["index"]), "provenance": "user",
                        "questionId": q["fact"]["id"], "callId": q["fact"]["callId"], "sourceEntryId": ident,
                        "answerKind": q["answerKind"], "structuredAnswer": True, "answerProvenance": "user",
                        "timedOut": False,
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
    if running:
        since, name = min(running.values())
        facts["inFlight"] = {"kind": "tool", "tool": name, "count": len(running), "sinceUtc": since}
    elif model_since is not None:
        facts["inFlight"] = {"kind": "model", "sinceUtc": model_since}
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
            result["coverage"]["fields"]["clock"] = "unknown"
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
        # scoped: reason -> the one field it demotes; whole: a record failed in a way that may hide any field.
        writer_unknown, scoped, whole = False, {}, False
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
                    writer_unknown = True
                else:
                    versions.add(writer)
                    writer_unknown = writer_unknown or writer not in SUPPORTED_WRITERS
                line_hash = hashlib.sha256(line).hexdigest()
                if ident in entries and entries[ident][2] != line_hash:
                    raise SourceProblem("malformed", "conflicting-entry-id")
                try:
                    normalized = normalize(record)
                except UnicodeError:
                    raise SourceProblem("malformed", "invalid-unicode-text")
                except SourceProblem as problem:
                    if problem.status != "partial":
                        raise
                    issues.add(problem.reason)
                    whole = True
                else:
                    for field, reason in (normalized or {}).get("problems", ()):
                        issues.add(reason)
                        scoped.setdefault(reason, field)
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
        writer_support = "unknown" if writer_unknown else "qualified"
        if not records_complete:
            result.update(status="partial", sessionId=header["id"], schemaVersion=header["version"],
                          writerVersions=sorted(versions), selectedLeafId=None, selection="unknown", complete=False,
                          coverage={"records": metrics["recordsRead"], "entries": len(entries), "recordsComplete": False,
                                    "historyScope": "unavailable", "fields": {field: "unknown" for field in FIELDS},
                                    "writerSupport": writer_support,
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
        damaged = set(FIELDS) if whole or issues.difference(scoped) else set(scoped.values())
        coverage = {"records": metrics["recordsRead"], "entries": len(entries), "ancestryEntries": len(chain),
                    "offBranchEntries": len(entries) - len(chain), "ancestryComplete": ancestry_complete,
                    "writerSupport": writer_support,
                    "fields": {field: "unknown" if field in damaged else "supported" for field in FIELDS},
                    "schemaSupport": "schema3-observed-writers", "issues": sorted(issues),
                    "selectionFallback": selection_fallback, "liveLeaf": "not-observed"}
        coverage.update(recordsComplete=True, historyScope=history_scope)
        result.update(status="ready" if complete else "partial", sessionId=header["id"], schemaVersion=header["version"],
                      writerVersions=sorted(versions), selectedLeafId=selected, selection="disk-replayed", complete=complete, coverage=coverage)
        result["questionCoverage"] = {"status": "unknown", "knownTotal": 0, "included": 0, "omitted": 0}
        result.update(project(replay_offsets(path, target, revision, reversed(chain), metrics, deadline),
                              complete, coverage))
        failure = result.get("lastError")
        if failure and failure["kind"] in LIMIT_KINDS and failure.get("provider"):
            limit = provider_limit(Path(path).parents[2] / "agent.db", failure["provider"], now)
            if limit is not None:
                failure["limit"] = limit
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
                result["coverage"]["fields"] = {field: "unknown" for field in FIELDS}
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


def respond(request):
    if (not isinstance(request, dict) or type(request.get("protocol")) is not int or request["protocol"] != 1
            or not isinstance(request.get("requestId"), str)):
        raise ValueError("protocol 1 and string requestId required")
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
