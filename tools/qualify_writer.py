#!/usr/bin/env python3
"""Cross-check one OMP version against source_facts.py on real sessions.

    python3 tools/qualify_writer.py <version> [--dir DIR]... [--since-days N]

Chore for every omp update (see the SUPPORTED_WRITERS docstring in
source_facts.py): until a version is listed there, every session it writes or
resumes degrades to selectionSupport "unknown". Steps:

1. Produce real sessions of that version. Disk history only has them after the
   update has run for a while. Otherwise run the new omp under an isolated HOME
   (never ~/.omp) against a local OpenAI-compatible mock model server, once in
   print mode with a tool call, once in --mode rpc-ui with set_ask_dialog to
   answer an `ask` select/custom/multi/cancelled, and once resuming an older
   session so a mixed-version file exists; pass those session dirs via --dir.
2. Run this tool. A file is PASS when the helper (with the version allowlisted
   in memory only) reports ready/complete with no issues and its lastFinal and
   ask question/answer outcomes equal the minimal raw-JSONL reader below.
3. Diff the producer at the new tag against the last qualified tag
   (src/session/session-entries.ts, src/tools/ask.ts); only fields this helper
   does not read may differ.
4. Add the version to SUPPORTED_WRITERS, extend the allowlist test, and record
   the evidence in the source_facts.py docstring.

Sources are never modified: each match is copied read-only into a temp dir.
Exit 0 only when every checked file passes and at least one file was written
by the version alone.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import sys
import tempfile
import time
from datetime import datetime

HELPER = Path(__file__).resolve().parents[1] / "source_facts.py"
MAX_TEXT = 2000
MAX_QUESTIONS = 32


def load_helper(version):
    spec = importlib.util.spec_from_file_location("source_facts_under_qualification", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.SUPPORTED_WRITERS = module.SUPPORTED_WRITERS | {version}
    return module


def writers_of(path):
    versions = set()
    for line in path.read_bytes().splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        runtime = record.get("runtime") if isinstance(record, dict) else None
        if isinstance(runtime, dict) and isinstance(runtime.get("version"), str):
            versions.add(runtime["version"])
    return versions


def text_of(content):
    if isinstance(content, str):
        return content
    return "\n".join(p["text"] for p in content if isinstance(p, dict) and p.get("type") == "text")


def instant(message, record):
    done = message.get("completedAt")
    if isinstance(done, (int, float)):
        return done / 1000
    return datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00")).timestamp()


def minimal_reader(path):
    """Raw-JSONL facts: lastFinal and ask outcomes along the selected branch."""
    entries, order = {}, []
    for line in path.read_bytes().splitlines():
        record = json.loads(line)
        if record.get("type") in ("title", "session"):
            continue
        entries[record["id"]] = record
        order.append(record)
    if not order:
        return {"final": None, "questions": []}
    last = order[-1]
    leaf = last.get("activeLeafId", last["id"])
    if leaf is not None and leaf not in entries:
        leaf = next((r["id"] for r in reversed(order) if r.get("activeLeafId", r["id"]) == r["id"]), None)
    chain = []
    while leaf is not None:
        chain.append(entries[leaf])
        leaf = entries[leaf]["parentId"]
    chain.reverse()
    final, questions, calls = None, [], {}
    for record in chain:
        message = record.get("message")
        if not isinstance(message, dict):
            continue
        if message.get("role") == "assistant":
            text = text_of(message.get("content", []))
            if message.get("stopReason") == "stop" and text:
                final = {"id": record["id"], "text": text[:MAX_TEXT], "atUtc": instant(message, record)}
            for part in message.get("content", []) if isinstance(message.get("content"), list) else []:
                if part.get("type") == "toolCall" and part.get("name") == "ask":
                    calls[part["id"]] = []
                    for raw in part["arguments"]["questions"]:
                        question = {"text": raw["question"], "status": "open", "answer": None, "qid": raw.get("id")}
                        questions.append(question)
                        calls[part["id"]].append(question)
        elif message.get("role") == "toolResult" and message.get("toolName") == "ask":
            asked = calls.get(message.get("toolCallId"), [])
            details = message.get("details") or {}
            if message.get("isError"):
                state = "cancelled" if text_of(message.get("content", [])) == "Ask input was cancelled" else "failed"
                for question in asked:
                    question["status"] = state
                continue
            results = details.get("results") if isinstance(details.get("results"), list) else [details]
            for question, result in zip(asked, results):
                custom = (result.get("customInput") or "").strip()
                chosen = result.get("selectedOptions") or []
                question["status"] = "answered"
                question["answer"] = custom[:MAX_TEXT] if custom else ", ".join(chosen)[:MAX_TEXT]
    return {"final": final, "questions": [(q["text"][:MAX_TEXT], q["status"], q["answer"]) for q in questions]}


def check(helper, path):
    result = helper.respond({"protocol": 1, "requestId": "qualify", "nowUtc": time.time(),
                             "targets": [{"key": "qualify", "path": str(path)}]})["results"][0]
    if result["status"] != "ready" or result.get("complete") is not True:
        return "helper %s: %s" % (result["status"], result.get("reason") or result["coverage"]["issues"])
    if result["coverage"]["issues"] or result["coverage"]["selectionSupport"] != "schema3-replayed":
        return "helper issues %s" % result["coverage"]["issues"]
    expected = minimal_reader(path)
    if len(expected["questions"]) > MAX_QUESTIONS:
        return "more than %d questions: not comparable" % MAX_QUESTIONS
    final = result.get("lastFinal")
    got = None if final is None else {"id": final["id"], "text": final["text"], "atUtc": final["atUtc"]}
    if got != expected["final"]:
        return "lastFinal differs: helper %r reader %r" % (got, expected["final"])
    questions = [(q["text"], q["status"], q.get("answer")) for q in result["questions"]]
    if questions != expected["questions"]:
        return "questions differ: helper %r reader %r" % (questions, expected["questions"])
    return None


def candidates(version, directories, since_days):
    needle = re.compile(rb'"version"\s*:\s*"' + re.escape(version.encode()) + rb'"')
    cutoff = time.time() - since_days * 86400 if since_days else 0
    for directory in directories:
        for root, _dirs, names in os.walk(directory):
            for name in names:
                path = Path(root, name)
                if name.endswith(".jsonl") and path.stat().st_mtime >= cutoff and needle.search(path.read_bytes()):
                    yield path


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("version")
    parser.add_argument("--dir", action="append", default=[])
    parser.add_argument("--since-days", type=float, default=0)
    args = parser.parse_args(argv)
    directories = args.dir or [str(Path.home() / ".omp" / "agent" / "sessions")]
    helper = load_helper(args.version)
    failed = sole = total = 0
    with tempfile.TemporaryDirectory() as scratch:
        for source in candidates(args.version, directories, args.since_days):
            copy = Path(scratch, "%06d.jsonl" % total)
            shutil.copyfile(source, copy)
            copy.chmod(0o400)
            total += 1
            writers = writers_of(copy)
            sole += writers == {args.version}
            problem = check(helper, copy)
            failed += problem is not None
            kind = "sole" if writers == {args.version} else "mixed " + ",".join(sorted(writers))
            print("%s %s [%s]%s" % ("PASS" if problem is None else "FAIL", source, kind,
                                    "" if problem is None else ": " + problem))
    verdict = total > 0 and failed == 0 and sole > 0
    print("%s: %d files, %d failed, %d written by %s alone" % (
        "QUALIFIED (record evidence, then edit SUPPORTED_WRITERS)" if verdict else "NOT QUALIFIED",
        total, failed, sole, args.version))
    return 0 if verdict else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
