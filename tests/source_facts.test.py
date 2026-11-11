"""Exercise the shipped adapter, with bounded producer-shaped records (no history copies).

Observed shapes: design packet agents[0] dc71542d/fe81d89e/2e68ae9b
(18.13.3); agents[1] 320ffa10 (18.14.0); agents[15]
8ad968ba/d5109313 (18.14.0). Payloads below are independent tiny examples.
"""
import contextlib
import io
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

HELPER = Path(__file__).resolve().parents[1] / "source_facts.py"
spec = importlib.util.spec_from_file_location("source_facts", HELPER)
assert spec is not None and spec.loader is not None
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


def header(session="session-one"):
    return {"type": "session", "version": 3, "id": session,
            "timestamp": "2026-10-29T00:00:00Z", "cwd": "/project"}


def entry(ident, parent=None, message=None, **fields):
    result = {"type": "message" if message is not None else "custom", "id": ident,
              "parentId": parent, "timestamp": "2026-10-29T01:00:00Z",
              "runtime": {"version": "18.14.0"}}
    if message is not None:
        result["message"] = message
    result.update(fields)
    return result


def assistant(text="Result", stop="stop", **fields):
    return {"role": "assistant", "content": [{"type": "thinking", "thinking": "PRIVATE_REASONING"},
            {"type": "text", "text": text}], "stopReason": stop,
            "timestamp": 1793235600000, "completedAt": 1793235600123,
            "providerPayload": {"private": "PRIVATE_PROVIDER"}, **fields}


def ask(questions, call="ask-one"):
    return assistant("", "toolUse", content=[{"type": "toolCall", "name": "ask",
           "id": call, "arguments": {"questions": questions}}])


def question(ident="q1", multi=False):
    return {"id": ident, "question": "Choose " + ident, "multi": multi,
            "options": [{"label": "Yes"}, {"label": "No"}]}


def answer(details, call="ask-one", error=False, text="PRIVATE_RAW_TOOL"):
    return {"role": "toolResult", "toolName": "ask", "toolCallId": call,
            "content": [{"type": "text", "text": text}], "details": details,
            "isError": error, "timestamp": 1793235601000}


# An omp 18.18 HTML-form ask, shaped like the producer's own example (packages/coding-agent ask tool): context text,
# a fieldset radio group, label-wrapped and label-for controls, an unlabeled textarea, hidden and submit inputs.
FORM = """<form>
  <p>Sessions live in memory &amp; are lost on restart.</p>
  <fieldset>
    <legend>Session store</legend>
    <label><input type="radio" name="store" value="sqlite" checked> SQLite: one file</label>
    <label><input type="radio" name="store" value="redis"> Redis: shared</label>
  </fieldset>
  <label>Session lifetime (days) <input type="number" name="ttl_days" value="30" min="1"></label>
  <p>Which extras?</p>
  <label><input type="checkbox" name="extras" value="a"> Metrics</label>
  <label><input type="checkbox" name="extras" value="b"> Tracing</label>
  <svg viewBox="0 0 10 10"><text>diagram label</text></svg>
  <label for="region">Deploy region</label>
  <select id="region" name="region"><option>us</option><option>eu</option></select>
  <textarea name="extra_notes"></textarea>
  <input type="hidden" name="token" value="x">
  <input type="submit" value="Go">
</form>"""
FORM_QUESTIONS = ["Session store", "Session lifetime (days)", "Which extras?", "Deploy region", "extra notes"]


def form_ask(html=FORM, call="form-one"):
    return assistant("", "toolUse", content=[{"type": "toolCall", "name": "ask", "id": call,
                                              "arguments": {"i": "Choosing storage", "html": html}}])


def form_answers(answers, call="form-one", **details):
    return answer({"answers": [{"name": name, "question": "PRODUCER_WORDING", "answer": value}
                               for name, value in answers], **details}, call)


class SourceFactsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "session.jsonl"

    def write(self, records, suffix=b""):
        self.path.write_bytes(b"".join(json.dumps(r).encode() + b"\n" for r in records) + suffix)

    def request(self, **target):
        return adapter.respond({"protocol": 1, "requestId": "request-one", "nowUtc": 1793235700,
                                "targets": [{"key": "exact-native-key", "path": str(self.path), **target}]})["results"][0]

    def test_completed_clock_terminal_and_allowlisted_content(self):
        self.write([{"type": "title", "v": 1, "title": "title"}, header(),
                    entry("a", message=assistant()),
                    entry("b", "a", assistant("Artifact available; continuing", "toolUse")),
                    entry("c", "b", assistant("", "error"))])
        result = self.request()
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["lastFinal"]["id"], "a")
        self.assertEqual(result["lastFinal"]["atUtc"], 1793235600.123)
        self.assertEqual(result["lastFinal"]["timeKind"], "completed")
        self.assertEqual(result["lastAssistant"]["stopReason"], "error")
        self.assertEqual(result["lastTerminal"]["stopReason"], "error")
        output = json.dumps(result)
        self.assertNotIn("PRIVATE_REASONING", output)
        self.assertNotIn("PRIVATE_PROVIDER", output)
        self.assertNotIn("taskComplete", result)

    def test_recorded_fallback_and_terminal_kinds(self):
        for stop in ("stop", "toolUse", "length", "error", "aborted"):
            msg = assistant(stop=stop)
            msg.pop("completedAt")
            self.write([header(), entry("a", message=msg)])
            result = self.request()
            if stop == "stop":
                self.assertEqual(result["lastFinal"]["timeKind"], "recorded")
            else:
                self.assertNotIn("lastFinal", result)
            if stop == "toolUse":
                self.assertNotIn("lastTerminal", result)
            else:
                self.assertEqual(result["lastTerminal"]["stopReason"], stop)

    def test_active_leaf_off_branch_null_and_missing_fallback(self):
        base = [header(), entry("a", message=assistant("Active")),
                entry("b", "a", assistant("Off branch"), activeLeafId="a")]
        self.write(base)
        self.assertEqual(self.request()["lastFinal"]["text"], "Active")
        self.write(base + [entry("c", "b", assistant("Hidden"), activeLeafId=None)])
        result = self.request()
        self.assertIsNone(result["selectedLeafId"])
        self.assertNotIn("lastFinal", result)
        self.write(base + [entry("c", "b", assistant("Hidden"), activeLeafId="gone")])
        self.assertEqual(self.request()["selectedLeafId"], "a")

    def test_two_answers_do_not_close_third_question_or_reissued_attempt(self):
        qs = [question("one"), question("two"), question("three")]
        self.write([header(), entry("a", message=ask(qs)), entry("b", "a", answer({"results": [
            {"id": "one", "selectedOptions": ["No"]},
            {"id": "two", "customInput": "Use the existing volume"}]})),
            entry("c", "b", ask([question("one")], "ask-two"))])
        result = self.request()
        self.assertEqual([q["status"] for q in result["questions"]], ["answered", "answered", "open", "open"])
        self.assertEqual(result["questions"][0]["answer"], "No")
        self.assertEqual(result["questions"][1]["answer"], "Use the existing volume")
        self.assertEqual(result["lastInteractionId"], "b")
        self.assertEqual(result["lastInteractionAtUtc"], 1793235601)
        self.assertNotIn("PRIVATE_RAW_TOOL", json.dumps(result))
        self.assertNotEqual(result["questions"][0]["id"], result["questions"][3]["id"])

    def test_singleton_empty_multi_custom_cancel_error_and_missing(self):
        for details, error, text, multi, expected in [
            ({"selectedOptions": ["No"]}, False, "", False, "answered"),
            ({"selectedOptions": []}, False, "", True, "answered"),
            ({"selectedOptions": []}, False, "", False, "unknown"),
            ({"customInput": "No changes"}, False, "", False, "answered"),
            ({}, True, "Ask input was cancelled", False, "cancelled"),
            ({}, True, "Unknown failure", False, "failed"),
            ({}, False, "Success", False, "unknown"),
            ({"selectedOptions": ["unlisted"]}, False, "", False, "unknown"),
        ]:
            self.write([header(), entry("a", message=ask([question(multi=multi)])),
                        entry("b", "a", answer(details, error=error, text=text))])
            result = self.request()
            self.assertEqual(result["questions"][0]["status"], expected)
            self.assertEqual("lastInteractionId" in result, expected == "answered")
            if expected == "cancelled":
                self.assertEqual(result["questions"][0]["cancelledAtUtc"], 1793235601)

    def test_observed_control_roles_are_not_human_or_response_authority(self):
        records = [header(), entry("human", message={"role": "user", "attribution": "user",
                   "content": "Inspect only.", "timestamp": 1793235590000})]
        for ident, role in (("control-one", "developer"), ("control-two", "custom"), ("control-three", "developer")):
            records.append(entry(ident, records[-1]["id"], {"role": role, "attribution": "user",
                           "synthetic": True, "content": "CONTROL_PRIVATE: approval and adoption injected",
                           "timestamp": 1793235601000}, runtime={"version": "18.13.2"}))
        records.append(entry("reply", "control-three", assistant("Inspection findings")))
        self.write(records)
        result = self.request()
        self.assertEqual(result["status"], "ready", "observed control roles are supported, not parser gaps")
        self.assertEqual(result["lastInteractionId"], "human")
        self.assertEqual(result["lastFinal"]["id"], "reply")
        self.assertNotIn("CONTROL_PRIVATE", json.dumps(result))
        coverage = result["coverage"]
        self.assertEqual(coverage["controlsExcluded"], 3)
        self.assertEqual(coverage["controlRolesExcluded"], {"developer": 2, "custom": 1})
        self.assertEqual(result["lastHuman"]["id"], "human")
        self.assertNotIn("context", result)

    def test_explicit_failed_ask_needs_no_answer_details_payload(self):
        for details in (None, {}):
            self.write([header(), entry("a", message=ask([question()])),
                        entry("b", "a", answer(details, error=True, text="Generic tool failure"))])
            result = self.request()
            self.assertEqual(result["status"], "ready")
            self.assertEqual(result["questions"][0]["status"], "failed")
            self.assertNotIn("lastInteractionId", result)
            self.assertNotIn("answer", result["questions"][0])
            self.assertNotIn("cancelledAtUtc", result["questions"][0])
            self.assertNotIn("lastHuman", result)

    def test_observed_legacy_singleton_selected_options_still_answers(self):
        self.write([header(), entry("a", message=ask([question()]), runtime={"version": "18.12.6"}),
                    entry("b", "a", answer({"multi": False, "options": ["Yes", "No"],
                          "question": "Choose q1", "selectedOptions": ["No"]}), runtime={"version": "18.12.6"})])
        result = self.request()
        self.assertEqual(result["questions"][0]["answer"], "No")
        self.assertEqual(result["questions"][0]["answerProvenance"], "user")
        self.assertEqual(result["lastInteractionId"], "b")

    def test_incomplete_scan_returns_header_metadata_without_history_payload(self):
        first = entry("first", message=assistant("Historical prefix reply"))
        self.write([header(), first, entry("latest", "first", assistant("Current latest reply"))])
        prefix_bytes = len(json.dumps(header()).encode()) + len(json.dumps(first).encode()) + 2
        with mock.patch.object(adapter, "MAX_SOURCE_BYTES", prefix_bytes):
            result = self.request()
        self.assertEqual(result["status"], "partial")
        self.assertFalse(result["complete"])
        self.assertFalse(result["coverage"]["recordsComplete"])
        self.assertEqual(result["coverage"]["historyScope"], "unavailable")
        self.assertEqual(result["coverage"]["fields"], {"clock": "unknown", "questions": "unknown"})
        self.assertEqual(result["sessionId"], "session-one")
        self.assertIsNone(result["selectedLeafId"])
        self.assertEqual(result["selection"], "unknown")
        self.assertEqual(result["metrics"]["bytesRead"], prefix_bytes, "no prefix history replay")
        self.assertFalse(result["reusable"])
        for field in ("lastFinal", "lastAssistant", "lastTerminal", "lastHuman", "questions",
                      "context", "lastInteractionId", "lastInteractionAtUtc", "semanticRevision"):
            self.assertNotIn(field, result)
        self.assertNotIn("Historical prefix reply", json.dumps(result))
        self.assertEqual(result["questionCoverage"], {"status": "unknown", "knownTotal": 0, "included": 0, "omitted": 0})

    def test_timeout_selection_is_automatic_not_a_human_answer(self):
        self.write([header(), entry("human", message={"role": "user", "attribution": "user",
                    "content": "Inspect only.", "timestamp": 1793235590000}),
                    entry("a", "human", ask([question()])),
                    entry("b", "a", answer({"selectedOptions": ["Yes"], "timedOut": True}))])
        result = self.request()
        fact = result["questions"][0]
        self.assertEqual(fact["status"], "answered", "the interactive attempt has a valid recorded resolution")
        self.assertEqual(fact["answer"], "Yes")
        self.assertEqual(fact["answerProvenance"], "automatic")
        self.assertTrue(fact["timedOut"])
        self.assertEqual(fact["resolvedAtUtc"], 1793235601)
        self.assertNotIn("answeredAtUtc", fact, "automatic choice is not a human answer clock")
        self.assertEqual(result["lastInteractionId"], "human")
        self.assertEqual(result["lastInteractionAtUtc"], 1793235590)
        self.assertEqual(result["lastHuman"]["id"], "human")

    def test_mixed_batch_preserves_manual_and_automatic_question_provenance(self):
        self.write([header(), entry("a", message=ask([question("manual"), question("auto")])),
                    entry("b", "a", answer({"results": [
                        {"id": "manual", "customInput": "Use the existing folder", "timedOut": False},
                        {"id": "auto", "selectedOptions": ["No"], "timedOut": True}]}))])
        result = self.request()
        manual, automatic = result["questions"]
        self.assertEqual([manual["status"], automatic["status"]], ["answered", "answered"])
        self.assertEqual(manual["answerProvenance"], "user")
        self.assertEqual(manual["answeredAtUtc"], 1793235601)
        self.assertFalse(manual["timedOut"])
        self.assertEqual(automatic["answerProvenance"], "automatic")
        self.assertNotIn("answeredAtUtc", automatic)
        self.assertEqual(result["lastInteractionId"], "b")
        self.assertEqual(result["lastHuman"]["id"], "b:0")

    def test_reissued_raw_call_id_resolves_only_its_own_attempt(self):
        self.write([header(),
                    entry("first", message=ask([question()], call="reused")),
                    entry("first-answer", "first", answer({"selectedOptions": ["Yes"]}, call="reused")),
                    entry("second", "first-answer", ask([question()], call="reused")),
                    entry("second-answer", "second", answer({"selectedOptions": ["No"]}, call="reused"))])
        result = self.request()
        old, new = result["questions"]
        self.assertNotEqual(old["id"], new["id"])
        self.assertEqual((old["status"], old["answer"]), ("answered", "Yes"))
        self.assertEqual((new["status"], new.get("answer")), ("answered", "No"))
        self.assertEqual(result["lastHuman"]["id"], "second-answer:0")
        with mock.patch.object(adapter, "MAX_TRACKED_QUESTIONS", 1):
            bounded = self.request()
        self.assertEqual(len(bounded["questions"]), 1)
        self.assertEqual(bounded["questions"][0]["answer"], "No")
        self.assertEqual(bounded["questionCoverage"]["omitted"], 1)

    def test_manual_structured_answer_becomes_latest_human_anchor(self):
        self.write([header(), entry("human", message={"role": "user", "attribution": "user",
                    "content": "Initial scope", "timestamp": 1793235590000}),
                    entry("a", "human", ask([question()])),
                    entry("b", "a", answer({"customInput": "Also implement the export step"}))])
        result = self.request()
        human = result["lastHuman"]
        self.assertEqual(human["id"], "b:0")
        self.assertEqual(human["provenance"], "user")
        self.assertEqual(human["atUtc"], 1793235601)
        self.assertEqual(human["questionId"], result["questions"][0]["id"])
        self.assertEqual(human["callId"], "ask-one")
        self.assertEqual(human["sourceEntryId"], "b")
        self.assertEqual(human["answerKind"], "custom")
        self.assertTrue(human["structuredAnswer"])
        self.assertEqual(result["lastInteractionId"], "b")

    def test_later_automatic_selection_never_overwrites_manual_human_anchor(self):
        automatic = answer({"selectedOptions": ["Yes"], "timedOut": True}, call="ask-two")
        automatic["timestamp"] = 1793235602000
        self.write([header(), entry("human", message={"role": "user", "attribution": "user",
                    "content": "Initial scope", "timestamp": 1793235590000}),
                    entry("a", "human", ask([question()])),
                    entry("b", "a", answer({"selectedOptions": ["No"]})),
                    entry("c", "b", ask([question()], call="ask-two")),
                    entry("d", "c", automatic)])
        result = self.request()
        self.assertEqual(result["lastHuman"]["id"], "b:0")
        self.assertEqual(result["lastHuman"]["atUtc"], 1793235601)
        self.assertEqual(result["lastHuman"]["answerKind"], "selection")
        self.assertEqual(result["lastInteractionId"], "b")
        self.assertEqual(result["questions"][1]["answerProvenance"], "automatic")

    def test_valid_empty_selection_keeps_raw_empty_and_typed_human_excerpt(self):
        for automatic in (False, True):
            self.write([header(), entry("a", message=ask([question(multi=True)])),
                        entry("b", "a", answer({"selectedOptions": [], "timedOut": automatic}))])
            result = self.request()
            question_fact = result["questions"][0]
            self.assertEqual(question_fact["status"], "answered")
            self.assertEqual(question_fact["answer"], "", "raw UI answer remains valid empty, not missing")
            self.assertEqual(question_fact["answerProvenance"], "automatic" if automatic else "user")
            if automatic:
                self.assertNotIn("lastHuman", result)
                self.assertNotIn("lastInteractionId", result)
            else:
                self.assertEqual(result["lastHuman"]["id"], "b:0")
                self.assertEqual(result["lastHuman"]["questionId"], question_fact["id"])
                self.assertEqual(result["lastHuman"]["answerKind"], "selection")

    def test_replay_timeout_cannot_poison_unchanged_file_recovery(self):
        self.write([header(), entry("a", message=assistant())])
        with mock.patch.object(adapter, "replay_offsets",
                               side_effect=adapter.SourceProblem("partial", "source-replay-limit")):
            failed = self.request()
        self.assertEqual(failed["status"], "partial")
        self.assertFalse(failed["reusable"])
        reuse = {"previousRevision": failed["revision"]} if failed["reusable"] else {}
        recovered = self.request(**reuse)
        self.assertEqual(recovered["status"], "ready")
        self.assertEqual(recovered["lastFinal"]["text"], "Result")
        self.assertTrue(recovered["reusable"])
        unchanged = self.request(previousRevision=recovered["revision"])
        self.assertEqual(unchanged["status"], "unchanged")
        self.assertTrue(unchanged["reusable"])
        self.assertEqual(unchanged["metrics"]["bytesRead"], 0)

    def test_one_total_target_budget_includes_scan_ancestry_and_replay(self):
        self.write([header(), entry("a", message={"role": "user", "attribution": "user", "content": "Scope"}),
                    entry("b", "a", assistant())])
        clock = [0.0]
        normalize = adapter.normalize
        def costly_normalize(record):
            clock[0] += 3.0
            return normalize(record)
        with mock.patch.object(adapter.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(adapter, "normalize", side_effect=costly_normalize):
            result = self.request()
        self.assertEqual(result["status"], "partial", "replay must not receive a fresh six-second budget")
        self.assertEqual(result["reason"], "source-replay-limit")
        self.assertFalse(result["reusable"])

    def test_explicit_human_not_synthetic_role_or_quoted_question(self):
        self.write([header(), entry("a", message={"role": "user", "attribution": "user",
                    "content": "Implement scope", "timestamp": 1793235600000}),
                    entry("b", "a", {"role": "user", "attribution": "agent", "content": "Synthetic control"}),
                    entry("c", "b", assistant("Would you like another explanation?"))])
        result = self.request()
        self.assertEqual(result["lastHuman"]["id"], "a")
        self.assertEqual(result["lastInteractionId"], "a")
        self.assertEqual(result["questions"], [])
        self.assertNotIn("Synthetic control", json.dumps(result))

    def test_metadata_only_unchanged_rewrite_and_header_identity(self):
        self.write([header(), entry("a", message=assistant("Before"))])
        before = self.request()
        unchanged = self.request(previousRevision=before["revision"], expectedSessionId="session-one")
        self.assertEqual(unchanged["status"], "unchanged")
        self.assertEqual(unchanged["metrics"]["bytesRead"], 0)
        self.write([header(), entry("z", message=assistant("After"))])
        after = self.request(previousRevision=before["revision"])
        self.assertEqual(after["lastFinal"]["text"], "After")
        self.assertNotEqual(before["revision"], after["revision"])
        self.write([header("replacement"), entry("a", message=assistant())])
        self.assertEqual(self.request(expectedSessionId="session-one")["status"], "unsupported")

    def test_factual_excerpts_ignore_metadata_and_provider_noise(self):
        records = [header(), entry("a", message=assistant())]
        self.write(records)
        before = self.request()
        records[1]["message"]["providerPayload"] = {"other": "noise"}
        records += [entry("telemetry", "a", type="model_usage", purpose="tiny")]
        self.write(records)
        after = self.request()
        self.assertEqual(before["lastFinal"], after["lastFinal"])
        self.assertEqual(before["questionCoverage"], after["questionCoverage"])
        records[1]["message"]["content"][1]["text"] = "Changed result"
        self.write(records)
        self.assertEqual(self.request()["lastFinal"]["text"], "Changed result")

    def test_listed_writers_are_qualified_and_a_missing_version_is_only_an_advisory(self):
        for writer in ("18.12.5", "18.12.6", "18.13.0", "18.13.1", "18.13.2", "18.13.3",
                       "18.14.0", "18.14.1", "18.14.2", "18.15.0", "18.16.0",
                       "18.18.0", "18.18.1", "18.18.2", "18.18.3", "18.18.5", "18.18.6", "18.18.7"):
            runtime = {"version": writer}
            self.write([header(), entry("ask", message=ask([question()]), runtime=runtime),
                        entry("answer", "ask", answer({"selectedOptions": ["Yes"]}), runtime=runtime),
                        entry("a", "answer", message=assistant(), runtime=runtime)])
            result = self.request()
            self.assertEqual(result["status"], "ready", writer)
            self.assertEqual(result["writerVersions"], [writer])
            self.assertEqual(result["schemaVersion"], 3)
            self.assertEqual(result["selection"], "disk-replayed")
            self.assertEqual(result["coverage"]["writerSupport"], "qualified", writer)
            self.assertEqual(result["coverage"]["fields"], {"clock": "supported", "questions": "supported"}, writer)
            self.assertEqual(result["coverage"]["liveLeaf"], "not-observed")
            self.assertEqual(result["questions"][0]["status"], "answered", writer)
            self.assertEqual(result["questions"][0]["answer"], "Yes", writer)
        self.write([header(), entry("a", message=assistant(), runtime={})])
        missing = self.request()
        self.assertEqual(missing["status"], "ready")
        self.assertEqual(missing["coverage"]["writerSupport"], "unknown")
        self.assertEqual(missing["coverage"]["fields"], {"clock": "supported", "questions": "supported"})
        unsupported_header = header()
        unsupported_header["version"] = 4
        self.write([unsupported_header])
        self.assertEqual(self.request()["status"], "unsupported")

    def test_host_cancelled_ask_under_18_16_0_is_failed_never_answered(self):
        runtime = {"version": "18.16.0"}
        cancelled = answer({}, error=True, text="Ask tool was cancelled by the user")
        self.write([header(), entry("ask", message=ask([question()]), runtime=runtime),
                    entry("cancel", "ask", cancelled, runtime=runtime),
                    entry("stopped", "cancel", assistant("", "aborted"), runtime=runtime)])
        result = self.request()
        self.assertEqual(result["coverage"]["writerSupport"], "qualified")
        self.assertEqual(result["questions"][0]["status"], "failed")
        self.assertNotIn("answer", result["questions"][0])
        self.assertEqual(result["lastTerminal"]["stopReason"], "aborted")

    def test_qualified_writer_with_a_changed_record_shape_degrades_visibly(self):
        runtime = {"version": "18.15.0"}
        changed = [
            entry("a", message={"role": "newRole", "content": "x"}, runtime=runtime),
            entry("a", message=assistant(stop="newStop"), runtime=runtime),
            entry("a", message=ask([{"question": "Choose", "options": "Yes,No"}]), runtime=runtime),
        ]
        for record in changed:
            self.write([header(), record])
            result = self.request()
            self.assertEqual(result["status"], "partial", record["message"])
            self.assertFalse(result["complete"])
            self.assertEqual(result["coverage"]["writerSupport"], "qualified")
            self.assertTrue(result["coverage"]["issues"])

    def test_html_form_ask_questions_take_the_producers_wording_and_its_answers(self):
        runtime = {"version": "18.18.7"}
        self.write([header(), entry("ask", message=form_ask(), runtime=runtime)])
        asked = self.request()
        self.assertEqual(asked["status"], "ready")
        self.assertEqual(asked["coverage"]["fields"], {"clock": "supported", "questions": "supported"})
        self.assertEqual([q["text"] for q in asked["questions"]], FORM_QUESTIONS)
        self.assertEqual({q["status"] for q in asked["questions"]}, {"open"})
        self.assertNotIn("diagram label", json.dumps(asked))
        submitted = [("store", "SQLite: one file"), ("ttl_days", "30"), ("extras", "Metrics, Tracing"),
                     ("region", "eu"), ("extra_notes", "")]
        self.write([header(), entry("ask", message=form_ask(), runtime=runtime),
                    entry("answer", "ask", form_answers(submitted), runtime=runtime)])
        answered = self.request()
        self.assertEqual(answered["status"], "ready")
        self.assertEqual([(q["text"], q["status"], q["answer"]) for q in answered["questions"]],
                         [(text, "answered", value) for text, (_, value) in zip(FORM_QUESTIONS, submitted)])
        self.assertEqual(answered["questions"][0]["answerProvenance"], "user")
        self.assertEqual(answered["lastHuman"]["sourceEntryId"], "answer")
        self.write([header(), entry("ask", message=form_ask(), runtime=runtime),
                    entry("answer", "ask", form_answers(submitted, timedOut=True), runtime=runtime)])
        timed = self.request()["questions"][0]
        self.assertEqual((timed["status"], timed["answerProvenance"]), ("answered", "automatic"))
        self.write([header(), entry("ask", message=form_ask(), runtime=runtime),
                    entry("cancel", "ask", answer({}, "form-one", error=True, text="Ask input was cancelled"), runtime=runtime)])
        self.assertEqual({q["status"] for q in self.request()["questions"]}, {"cancelled"})

    def test_unknown_writer_with_parseable_records_keeps_every_field_supported(self):
        runtime = {"version": "99.0.0"}
        self.write([header(), entry("ask", message=ask([question()]), runtime=runtime),
                    entry("answer", "ask", answer({"selectedOptions": ["Yes"]}), runtime=runtime),
                    entry("a", "answer", message=assistant(), runtime=runtime)])
        result = self.request()
        self.assertEqual(result["status"], "ready")
        self.assertTrue(result["complete"])
        self.assertEqual(result["coverage"]["writerSupport"], "unknown")
        self.assertEqual(result["coverage"]["fields"], {"clock": "supported", "questions": "supported"})
        self.assertEqual(result["coverage"]["issues"], [])
        self.assertEqual(result["lastFinal"]["atUtc"], 1793235600.123)
        self.assertEqual(result["questionCoverage"]["status"], "complete")

    def test_an_unparseable_ask_demotes_only_questions_and_its_record_keeps_the_clock(self):
        broken = ask([{"question": "Choose", "options": "Yes,No"}])
        broken["completedAt"] = 1793235700000
        self.write([header(), entry("a", message=assistant()), entry("broken", "a", broken)])
        result = self.request()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["coverage"]["fields"], {"clock": "supported", "questions": "unknown"})
        self.assertIn("unsupported-question-options", result["coverage"]["issues"])
        self.assertEqual(result["lastAssistant"]["id"], "broken")
        self.assertEqual(result["lastActivityAtUtc"], 1793235700)
        self.assertEqual(result["questionCoverage"]["status"], "unknown")
        malformed_result = answer({"results": "not-a-list"})
        self.write([header(), entry("ask", message=ask([question()])), entry("bad", "ask", malformed_result)])
        self.assertEqual(self.request()["coverage"]["fields"], {"clock": "supported", "questions": "unknown"})

    def test_provider_error_on_the_last_turn_is_a_fact_and_a_later_turn_clears_it(self):
        errors = [
            ({"errorStatus": 429, "errorId": 659456, "errorMessage": '429 {"error":{"message":"[1308][Usage limit reached for 5 hour]"}}'}, "usage_limit"),
            ({"errorMessage": "Codex error event: The usage limit has been reached (code=usage_limit_reached)"}, "usage_limit"),
            ({"errorStatus": 429, "errorId": 135168, "errorMessage": '429 {"error":{"message":"[1302][Rate limit reached for requests]"}}'}, "rate_limit"),
            ({"errorStatus": 500, "errorMessage": "500 Internal Server Error"}, "api_error"),
            ({"errorMessage": "ECONNRESET: The socket connection was closed unexpectedly"}, "provider"),
        ]
        for fields, kind in errors:
            failed = assistant("", "error", **fields)
            failed["completedAt"] = 1793235800000
            records = [header(), entry("a", message=assistant()), entry("failed", "a", failed)]
            self.write(records)
            self.assertEqual(self.request()["lastError"], {"id": "failed", "kind": kind, "atUtc": 1793235800}, kind)
            self.write(records + [entry("retried", "failed", assistant("Recovered"))])
            recovered = self.request()
            self.assertNotIn("lastError", recovered, kind)
            self.assertEqual(recovered["lastFinal"]["id"], "retried")

    def test_last_activity_is_the_newest_assistant_or_tool_record_not_human_input(self):
        tool = {"role": "toolResult", "toolName": "bash", "toolCallId": "call", "content": [{"type": "text", "text": "PRIVATE"}],
                "isError": False, "timestamp": 1793235900000}
        human = {"role": "user", "attribution": "user", "content": "next", "timestamp": 1793236000000}
        self.write([header(), entry("a", message=assistant("", "toolUse")), entry("tool", "a", tool), entry("human", "tool", human)])
        result = self.request()
        self.assertEqual(result["lastActivityAtUtc"], 1793235900)
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_factual_projection_has_no_generative_input_or_interpretation(self):
        self.write([header(), entry("user", message={"role": "user", "attribution": "user",
                    "content": "Inspect only; do not change anything.", "timestamp": 1793235600000}),
                    entry("ask", "user", ask([question()])),
                    entry("answer", "ask", answer({"customInput": "Use the existing folder"})),
                    entry("result", "answer", assistant("Findings available; no change made."))])
        result = self.request()
        self.assertEqual(result["questions"][0]["status"], "answered")
        self.assertEqual(result["questions"][0]["answer"], "Use the existing folder")
        self.assertEqual(result["lastHuman"]["sourceEntryId"], "answer")
        for field in ("semanticRevision", "context", "state", "messages", "nextOwner", "nextMove", "workRemaining"):
            self.assertNotIn(field, result)
        coverage = result["questionCoverage"]
        self.assertEqual(coverage["status"], "complete")
        self.assertEqual(coverage["knownTotal"], 1)
        self.assertEqual(coverage["included"], 1)
        self.assertEqual(coverage["included"], len(result["questions"]))
        self.assertEqual(coverage["omitted"], 0)
        self.assertIs(coverage["textTruncated"], False)
        self.assertEqual(result["questions"][0]["text"], "Choose q1")

    def test_positional_batch_without_ids_and_single_choice_rejects_multiple(self):
        qs = [question(), question()]
        for q in qs:
            q.pop("id")
        self.write([header(), entry("a", message=ask(qs)), entry("b", "a", answer({"results": [
            {"selectedOptions": ["Yes"]}, {"selectedOptions": ["No"]}]}))])
        self.assertEqual([q["answer"] for q in self.request()["questions"]], ["Yes", "No"])
        self.write([header(), entry("a", message=ask([question()])),
                    entry("b", "a", answer({"selectedOptions": ["Yes", "No"]}))])
        self.assertEqual(self.request()["questions"][0]["status"], "unknown")

    def test_reset_boundary_discards_prior_facts_without_inventing_summary_authority(self):
        self.write([header(), entry("a", message=assistant("Old reply")),
                    entry("clear", "a", type="reset_boundary"),
                    entry("b", "clear", assistant("New reply")),
                    entry("summary", "b", type="compaction", summary="PRIVATE_UNVERIFIED_SUMMARY")])
        result = self.request()
        self.assertEqual(result["lastFinal"]["text"], "New reply")
        self.assertNotIn("Old reply", json.dumps(result))
        self.assertNotIn("PRIVATE_UNVERIFIED_SUMMARY", json.dumps(result))
        self.assertEqual(result["coverage"]["summariesExcluded"], 1)
        self.assertEqual(result["questionCoverage"]["status"], "complete")

    def test_partial_malformed_unsupported_and_ancestry_are_explicit(self):
        self.write([header(), entry("a", message=assistant())], b'{"type":')
        self.assertEqual(self.request()["status"], "partial")
        self.write([header(), entry("a", "missing", assistant())])
        self.assertFalse(self.request()["complete"])
        self.write([header(), entry("a", "a", assistant())])
        self.assertEqual(self.request()["status"], "malformed")
        self.write([header(), entry("a", message=assistant()), entry("a", message=assistant("conflict"))])
        self.assertEqual(self.request()["status"], "malformed")
        self.write([header(), entry("a", message={"role": "newRole", "content": "x"})])
        unknown = self.request()
        self.assertEqual(unknown["status"], "partial")
        self.assertEqual(unknown["coverage"]["fields"], {"clock": "unknown", "questions": "unknown"})
        self.path.write_text("{not json}\n")
        self.assertEqual(self.request()["status"], "malformed")
        self.path.unlink()
        self.assertEqual(self.request()["status"], "missing")
        self.path.mkdir()
        self.assertEqual(self.request()["status"], "unsupported")

    def test_factual_excerpt_clipping_and_oversize_record_are_explicit(self):
        self.write([header(), entry("human", message={"role": "user", "attribution": "user",
                    "content": "x" * (adapter.MAX_TEXT + 10)}),
                    entry("reply", "human", assistant("y" * (adapter.REPLY_TEXT + 1)))])
        result = self.request()
        self.assertNotIn("text", result["lastHuman"], "human input is carried by its time, not its text")
        for field in ("lastFinal", "lastAssistant"):
            self.assertEqual(result[field]["text"], "y" * adapter.REPLY_TEXT)
            self.assertTrue(result[field]["textTruncated"])
        self.assertEqual(result["questionCoverage"]["status"], "complete")
        self.write([header()], b"x" * (adapter.MAX_RECORD_BYTES + 1) + b"\n")
        result = self.request()
        self.assertEqual(result["status"], "partial")
        self.assertFalse(result["complete"])

    def test_question_count_coverage_is_bounded_and_matches_actual_output(self):
        records = [header()]
        for index in range(45):
            ident = "ask-" + str(index)
            parent = "ask-" + str(index - 1) if index else None
            records.append(entry(ident, parent, ask([question("same-wording")], "call-" + str(index))))
        self.write(records)
        result = self.request()
        self.assertEqual(len(result["questions"]), adapter.MAX_QUESTIONS)
        self.assertEqual(result["questionCoverage"]["knownTotal"], 45)
        self.assertEqual(result["questionCoverage"]["included"], len(result["questions"]))
        self.assertEqual(result["questionCoverage"]["omitted"], 45 - len(result["questions"]))
        self.assertEqual(result["questionCoverage"]["status"], "bounded")
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()),
                             adapter.MAX_RESULT_BYTES)

    def test_question_text_clipping_does_not_hide_complete_identity_coverage(self):
        q = question()
        q["question"] = "q" * (adapter.MAX_TEXT + 10)
        self.write([header(), entry("a", message=ask([q]))])
        result = self.request()
        coverage = result["questionCoverage"]
        self.assertEqual(coverage["status"], "complete")
        self.assertEqual(coverage["knownTotal"], 1)
        self.assertEqual(coverage["included"], 1)
        self.assertEqual(coverage["included"], len(result["questions"]))
        self.assertEqual(coverage["omitted"], 0)
        self.assertIs(coverage["textTruncated"], True)
        self.assertEqual(result["questions"][0]["text"], q["question"][:adapter.MAX_TEXT])
        self.assertEqual(result["questions"][0]["status"], "open")

    def test_output_fitting_updates_final_question_coverage(self):
        questions = [question("q" + str(i)) for i in range(8)]
        for q in questions:
            q["question"] += "x" * 700
        self.write([header(), entry("a", message=ask(questions))])
        with mock.patch.object(adapter, "MAX_RESULT_BYTES", 4000):
            result = self.request()
        coverage = result["questionCoverage"]
        self.assertEqual(coverage["status"], "bounded")
        self.assertEqual(coverage["knownTotal"], 8)
        self.assertEqual(coverage["included"], len(result["questions"]))
        self.assertEqual(coverage["omitted"], 8 - len(result["questions"]))
        self.assertLess(coverage["included"], 8)
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()), 4000)

    def test_omitted_positive_outcomes_keep_exact_attempt_and_answer_provenance(self):
        records = [header()]
        parent = None
        for index, (status, automatic) in enumerate([
                ("answered", False), ("answered", True), ("cancelled", False),
                ("failed", False), ("unknown", False)] + [("answered", True)] * 32):
            call = "reused-call"
            ident = "ask-" + str(index)
            records.append(entry(ident, parent, ask([question()], call)))
            details = {"selectedOptions": ["No"], "timedOut": automatic} if status == "answered" else {}
            parent = "result-" + str(index)
            records.append(entry(parent, ident, answer(
                details, call, error=status in ("cancelled", "failed"),
                text="Ask input was cancelled" if status == "cancelled" else "PRIVATE_RAW_TOOL")))
        self.write(records)
        result = self.request()
        outcomes = {json.loads(q["id"])[0]: q for q in result["questionOutcomes"]}
        self.assertEqual(outcomes["ask-0"]["status"], "answered")
        self.assertEqual(outcomes["ask-0"]["answerProvenance"], "user")
        self.assertFalse(outcomes["ask-0"]["timedOut"])
        self.assertEqual(outcomes["ask-0"]["answeredAtUtc"], 1793235601)
        self.assertEqual(outcomes["ask-1"]["answerProvenance"], "automatic")
        self.assertTrue(outcomes["ask-1"]["timedOut"])
        self.assertEqual(outcomes["ask-1"]["resolvedAtUtc"], 1793235601)
        self.assertNotIn("answeredAtUtc", outcomes["ask-1"])
        self.assertEqual(outcomes["ask-2"]["status"], "cancelled")
        self.assertEqual(outcomes["ask-2"]["cancelledAtUtc"], 1793235601)
        self.assertEqual(outcomes["ask-3"]["status"], "failed")
        self.assertNotIn("ask-4", outcomes, "unknown evidence is not a positive outcome")
        self.assertTrue(all(set(q) <= {"id", "status", "askedAtUtc", "answeredAtUtc", "cancelledAtUtc",
                                      "resolvedAtUtc", "answerProvenance", "timedOut"}
                            for q in outcomes.values()))
        self.assertTrue(set(q["id"] for q in result["questions"]).isdisjoint(q["id"] for q in outcomes.values()))
        self.assertEqual(result["lastHuman"]["sourceEntryId"], "result-0")
        self.assertEqual(result["lastInteractionId"], "result-0", "automatic/cancelled/failed are not fresh human input")
        records.append(entry("selected-original", parent, type="label", activeLeafId="ask-0"))
        self.write(records)
        selected = self.request()
        self.assertEqual(selected["questions"][0]["status"], "open")
        self.assertEqual(selected["questionOutcomes"], [], "off-branch answers cannot settle the selected attempt")
        self.assertNotIn("lastInteractionId", selected)

    def test_positive_outcomes_survive_text_output_fitting(self):
        questions = [question("q" + str(i)) for i in range(8)]
        for q in questions:
            q["question"] = "Long question " * 150
        self.write([header(), entry("ask", message=ask(questions)),
                    entry("answer", "ask", answer({"results": [
                        {"id": q["id"], "selectedOptions": ["Yes"], "timedOut": True} for q in questions]}))])
        with mock.patch.object(adapter, "MAX_RESULT_BYTES", 4000):
            result = self.request()
        excerpts, outcomes, coverage = result["questions"], result["questionOutcomes"], result["questionCoverage"]
        self.assertLess(len(excerpts), 8)
        self.assertEqual(len(excerpts) + len(outcomes), 8)
        self.assertEqual(coverage["included"], len(excerpts))
        self.assertEqual(coverage["omitted"], len(outcomes))
        self.assertEqual(coverage["outcomeIncluded"], len(outcomes))
        self.assertEqual(coverage["outcomeOmitted"], 0)
        self.assertTrue(all(q["status"] == "answered" and q["answerProvenance"] == "automatic" for q in outcomes))
        self.assertNotIn("lastInteractionId", result)
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()), 4000)

    def test_outcome_tracking_bound_and_oversized_identity_are_explicit(self):
        records = [header()]
        parent = None
        for index in range(513):
            ident, call = "ask-" + str(index), "call-" + str(index)
            records.append(entry(ident, parent, ask([question()], call)))
            parent = "answer-" + str(index)
            records.append(entry(parent, ident, answer({"selectedOptions": ["Yes"], "timedOut": True}, call)))
        self.write(records)
        result = self.request()
        self.assertEqual(len(result["questions"]), 32)
        self.assertEqual(len(result["questionOutcomes"]), 480)
        self.assertEqual(result["questionCoverage"]["trackingOmitted"], 1)
        self.assertEqual(result["questionCoverage"]["knownTotal"], 513)
        self.assertEqual(result["questionCoverage"]["status"], "bounded")
        self.assertNotIn("ask-0", {json.loads(q["id"])[0] for q in result["questionOutcomes"]})
        self.write([header(), entry("ask", message=ask([question("x" * adapter.MAX_RESULT_BYTES)])),
                    entry("answer", "ask", answer({"selectedOptions": ["Yes"], "timedOut": True}))])
        bounded = self.request()
        self.assertEqual(bounded["questions"], [])
        self.assertEqual(bounded["questionOutcomes"], [])
        self.assertEqual(bounded["questionCoverage"]["status"], "bounded")
        self.assertEqual(bounded["questionCoverage"]["outcomeOmitted"], 1)
        self.assertLessEqual(len(json.dumps(bounded, ensure_ascii=False, separators=(",", ":")).encode()),
                             adapter.MAX_RESULT_BYTES)

    def test_oversized_output_identity_never_truncates_into_a_false_match(self):
        huge = "x" * adapter.MAX_RESULT_BYTES
        self.write([header(), entry("ask", message=ask([question(huge)])),
                    entry("answer", "ask", answer({"selectedOptions": ["Yes"]}))])
        result = self.request()
        self.assertEqual(result["status"], "partial")
        self.assertFalse(result["complete"])
        self.assertNotIn("lastHuman", result)
        self.assertEqual(result["questionOutcomes"], [])
        self.assertEqual(result["questionCoverage"]["outcomeOmitted"], 1)
        self.assertIn("output-excerpt-limit", result["coverage"]["issues"])
        self.assertLessEqual(len(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()),
                             adapter.MAX_RESULT_BYTES)
        self.write([header(huge), entry("a", message=assistant())])
        envelope = self.request()
        self.assertEqual(envelope["status"], "partial")
        self.assertEqual(envelope["reason"], "source-output-limit")
        self.assertFalse(envelope["reusable"])
        self.assertEqual(envelope["questionCoverage"]["status"], "unknown")
        self.assertLessEqual(len(json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode()),
                             adapter.MAX_RESULT_BYTES)

    def test_real_model_settles_previously_seen_attempt_from_compact_parser_outcome(self):
        luau = shutil.which("luau")
        self.assertIsNotNone(luau, "the real Luau CLI is required for the parser/model contract regression")
        assert luau is not None
        cases = []
        for status in ("answered", "automatic", "cancelled", "failed"):
            records = [header(), entry("first", message=ask([question()]))]
            self.write(records)
            before = self.request()
            records.append(entry("resolved", "first", answer(
                {"selectedOptions": ["No"], "timedOut": status == "automatic"},
                error=status in ("cancelled", "failed"),
                text="Ask input was cancelled" if status == "cancelled" else "PRIVATE_RAW_TOOL")))
            parent = "resolved"
            for index in range(32):
                ident, call = "later-" + str(index), "call-" + str(index)
                records.append(entry(ident, parent, ask([question()], call)))
                parent = "answer-" + str(index)
                records.append(entry(parent, ident, answer({"selectedOptions": ["Yes"], "timedOut": True}, call)))
            self.write(records)
            after = self.request()
            self.assertEqual(after["questionCoverage"]["knownTotal"], 33)
            self.assertEqual(after["questionCoverage"]["included"], 32)
            self.assertEqual(after["questionOutcomes"][0]["id"], before["questions"][0]["id"])
            self.assertNotIn(before["questions"][0]["id"], {q["id"] for q in after["questions"]})
            self.assertEqual(after.get("lastInteractionId"), "resolved" if status == "answered" else None)
            cases.append({"before": before, "after": after, "status": "answered" if status == "automatic" else status})

        def literal(value):
            if value is None:
                return "nil"
            if isinstance(value, bool):
                return "true" if value else "false"
            if isinstance(value, (str, int, float)):
                return json.dumps(value, ensure_ascii=False)
            if isinstance(value, list):
                return "{" + ",".join(literal(v) for v in value) + "}"
            return "{" + ",".join("[" + literal(k) + "]=" + literal(v) for k, v in value.items()) + "}"

        script = r'''
local model = require("../model")
local cases = CASES
for _, case in ipairs(cases) do
    local before, after = case.before, case.after
    local live = {
        ok = true, now = 1, identityReady = true, identities = { [11] = before.key },
        hosts = { [1] = { key = "local", connected = true, name = "Local" } },
        agents = { { pane = 11, state = "idle" } },
        panes = { [11] = { host = 1, tab = 10, session = 100, title = "Agent", alert = false } },
        sources = { [11] = { key = before.key, path = before.path, localSource = true } },
        sourceFacts = { [before.key] = before },
    }
    local context = { window = "", hostKeys = { [1] = "local" }, connected = { ["local"] = true },
        coherent = true, nowUtc = before.capturedAtUtc }
    local state = model.new()
    assert(model.reconcile(state, live, {}, context).rows[1].attention, "the observed open attempt needs input")
    state = model.new(model.snapshot(state))
    live.sourceFacts[before.key] = after
    local resolved = model.reconcile(state, live, {}, context).rows[1]
    assert(not resolved.attention, "positive compact outcome must settle retained input: " .. case.status)
    local retained
    for _, question in ipairs(resolved.source.lastKnown.questions) do
        if question.id == before.questions[1].id then retained = question end
    end
    assert(retained and retained.status == case.status and retained.text == before.questions[1].text,
        "settlement preserves the original attempt and text")
    assert(not model.current(model.new(model.snapshot(state))).rows[1].attention, "settlement survives restore")

    local working = model.new()
    live.sourceFacts[before.key] = before
    assert(model.reconcile(working, live, {}, context).rows[1].attention)
    live.agents[1].state = "working"
    assert(not model.reconcile(working, live,
        { { kind = "state", pane = 11, old = "idle", new = "working", at = 2 } }, context).rows[1].attention,
        "observed Working suppresses source questions without pretending they were answered")
    live.sourceFacts[before.key] = after
    assert(not model.reconcile(working, live, {}, context).rows[1].attention)
end
print("parser-model outcomes passed")
'''.replace("CASES", literal(cases), 1)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".luau", prefix=".source-model-",
                                         dir=HELPER.parent / "tests") as fixture:
            fixture.write(script)
            fixture.flush()
            proc = subprocess.run([luau, fixture.name], text=True, capture_output=True, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("parser-model outcomes passed", proc.stdout)

    def test_old_contextual_adapter_revision_cannot_reuse_factual_projection(self):
        self.write([header(), entry("a", message=assistant())])
        current = self.request()
        old_revision = "omp-source-v1:" + current["revision"].split(":", 1)[1]
        reprojected = self.request(previousRevision=old_revision)
        self.assertEqual(reprojected["status"], "ready")
        self.assertGreater(reprojected["metrics"]["bytesRead"], 0)
        self.assertNotIn("context", reprojected)

    def test_outcome_less_revision_cannot_reuse_unchanged_source(self):
        self.write([header(), entry("a", message=ask([question()]))])
        current = self.request()
        old_revision = "omp-facts-v1:" + current["revision"].split(":", 1)[1]
        reprojected = self.request(previousRevision=old_revision)
        self.assertEqual(reprojected["status"], "ready")
        self.assertGreater(reprojected["metrics"]["bytesRead"], 0)

    def test_cli_is_finite_json_and_one_bad_target_does_not_starve_other(self):
        self.write([header(), entry("a", message=assistant())])
        request = {"protocol": 1, "requestId": "cli", "nowUtc": 1793235700, "targets": [
            {"key": "remote", "path": "ssh://forge/session"},
            {"key": "local", "path": str(self.path)}]}
        proc = subprocess.run([sys.executable, str(HELPER)], input=json.dumps(request),
                              text=True, capture_output=True, timeout=10, check=True)
        result = json.loads(proc.stdout)
        self.assertEqual(result["requestId"], "cli")
        self.assertEqual([r["status"] for r in result["results"]], ["unsupported", "ready"])
        self.assertEqual(proc.stderr, "")

    def header_request(self, **target):
        return adapter.respond({"protocol": 1, "requestId": "fresh-header", "op": "header", "nowUtc": 1793235700,
                                "targets": [{"key": "exact-native-key", "path": str(self.path), **target}]})["results"][0]

    def test_header_proof_skips_title_and_blanks_without_reading_history(self):
        self.write([{"type": "title", "v": 1, "title": "Mutable title"}, header()],
                   b"THIS MALFORMED TRANSCRIPT BODY MUST NOT BE PARSED\n")
        self.path.write_bytes(b"\n" + self.path.read_bytes())
        result = self.header_request(expectedSessionId="session-one")
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["sessionId"], "session-one")
        self.assertEqual(result["capturedAtUtc"], 1793235700)
        self.assertIsInstance(result["revision"], str)
        self.assertFalse(result["historyRead"])
        for field in ("context", "questions", "semanticRevision", "lastFinal", "lastHuman"):
            self.assertNotIn(field, result)

    def test_header_mismatch_returns_actual_identity_and_reused_path_is_caught(self):
        self.write([header()])
        before = self.header_request(expectedSessionId="session-one")
        self.assertEqual(before["status"], "ready")
        self.write([header("replacement-header")])
        after = self.header_request(expectedSessionId="session-one")
        self.assertEqual(after["status"], "changed")
        self.assertEqual(after["sessionId"], "replacement-header")
        self.assertNotEqual(after["revision"], before["revision"])
        self.assertFalse(after["historyRead"])

    def test_header_metadata_race_cannot_return_ready(self):
        self.write([header()])
        before = self.path.stat()
        attributes = {name: getattr(before, name) for name in
                      ("st_mode", "st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")}
        attributes["st_mtime_ns"] += 1
        after = SimpleNamespace(**attributes)
        with mock.patch.object(adapter.os, "fstat", side_effect=[before, after]):
            result = self.header_request(expectedSessionId="session-one")
        self.assertEqual(result["status"], "changed")
        self.assertEqual(result["reason"], "source-changed-during-header-read")
        self.assertFalse(result["historyRead"])

    def test_header_bounds_bytes_physical_records_and_total_time(self):
        self.path.write_bytes(b"x" * (64 * 1024) + b"\n" + json.dumps(header()).encode() + b"\n")
        self.assertEqual(self.header_request()["reason"], "header-byte-limit")
        self.path.write_bytes(b"\n" * 8 + json.dumps(header()).encode() + b"\n")
        self.assertEqual(self.header_request()["reason"], "header-record-limit")
        self.path.write_bytes(b"\n" * 7 + json.dumps(header()).encode() + b"\n")
        self.assertEqual(self.header_request()["status"], "ready")
        self.write([{"type": "title", "v": 1, "title": "Mutable"}, header()])
        clock = [0.0]
        def ticking_clock():
            current = clock[0]
            clock[0] += 0.6
            return current
        with mock.patch.object(adapter.time, "monotonic", side_effect=ticking_clock):
            result = self.header_request()
        self.assertEqual(result["status"], "changed")
        self.assertEqual(result["reason"], "header-deadline")
        self.assertFalse(result["historyRead"])

    def test_header_proof_does_not_require_any_writer_history_version(self):
        self.write([header(), entry("future", message={"role": "unknown", "content": "UNREAD_HISTORY"},
                                   runtime={"version": "999.0.0"})])
        result = self.header_request()
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["sessionId"], "session-one")
        self.assertNotIn("UNREAD_HISTORY", json.dumps(result))
        self.assertFalse(result["historyRead"])

    def test_header_missing_malformed_and_unsupported_are_distinct(self):
        self.assertEqual(self.header_request()["status"], "missing")
        self.path.write_bytes(b"{broken\\n")
        self.assertEqual(self.header_request()["status"], "malformed")
        self.write([{"type": "session", "version": 4, "id": "new-schema"}])
        self.assertEqual(self.header_request()["status"], "unsupported")
        self.write([{"type": "title", "v": 2}, header()])
        self.assertEqual(self.header_request()["status"], "unsupported")
        self.path.unlink()
        self.path.mkdir()
        self.assertEqual(self.header_request()["status"], "unsupported")
        result = adapter.respond({"protocol": 1, "requestId": "remote-header", "op": "header", "nowUtc": 1793235700,
                                  "targets": [{"key": "remote", "path": "ssh://forge/session"}]})["results"][0]
        self.assertEqual(result["status"], "unsupported")
        self.assertFalse(result["historyRead"])

    def test_missing_and_future_clocks_are_not_zero_or_clamped(self):
        msg = assistant()
        msg.pop("timestamp")
        msg.pop("completedAt")
        record = entry("a", message=msg)
        record.pop("timestamp")
        self.write([header(), record])
        self.assertNotIn("atUtc", self.request()["lastFinal"])
        record["message"]["completedAt"] = 9999999999000
        self.write([header(), record])
        self.assertEqual(self.request()["lastFinal"]["atUtc"], 9999999999)

    def test_invalid_protocol_is_explicit_and_never_runs_sources(self):
        for request in (None, {}, {"protocol": True, "requestId": "boolean"},
                        {"protocol": 1, "requestId": "not-finite", "nowUtc": float("nan"), "targets": []}):
            with self.assertRaises(ValueError):
                adapter.respond(request)


QUALIFY = Path(__file__).resolve().parents[1] / "tools" / "qualify_writer.py"
qualify_spec = importlib.util.spec_from_file_location("qualify_writer", QUALIFY)
assert qualify_spec is not None and qualify_spec.loader is not None
qualify = importlib.util.module_from_spec(qualify_spec)
qualify_spec.loader.exec_module(qualify)
NEXT = "18.99.0"


class QualifyWriterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def session(self, name, records):
        path = self.dir / name
        path.write_bytes(b"".join(json.dumps(r).encode() + b"\n" for r in records))
        return path

    def run_tool(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = qualify.main([NEXT, "--dir", str(self.dir)])
        return code, output.getvalue()

    def asked_session(self, version, name="sole.jsonl", prefix=()):
        runtime = {"version": version}
        return self.session(name, [header(), *prefix,
                            entry("ask", prefix[-1]["id"] if prefix else None, ask([question()]), runtime=runtime),
                            entry("answer", "ask", answer({"selectedOptions": ["Yes"]}), runtime=runtime),
                            entry("done", "answer", assistant("Finished"), runtime=runtime)])

    def test_sole_and_mixed_version_sessions_pass_without_touching_sources_or_the_shipped_allowlist(self):
        sole = self.asked_session(NEXT)
        older = entry("old", None, assistant("Earlier"), runtime={"version": "18.14.0"})
        mixed = self.asked_session(NEXT, "mixed.jsonl", prefix=[older])
        before = [(p.read_bytes(), p.stat().st_mtime_ns) for p in (sole, mixed)]
        code, output = self.run_tool()
        self.assertEqual(code, 0, output)
        self.assertIn("PASS %s [sole]" % sole, output)
        self.assertIn("PASS %s [mixed 18.14.0,%s]" % (mixed, NEXT), output)
        self.assertIn("QUALIFIED", output)
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns) for p in (sole, mixed)])
        self.assertNotIn(NEXT, adapter.SUPPORTED_WRITERS)
        self.write_and_check_unqualified(sole)

    def write_and_check_unqualified(self, path):
        result = adapter.respond({"protocol": 1, "requestId": "r", "nowUtc": 1793235700,
                                  "targets": [{"key": "k", "path": str(path)}]})["results"][0]
        self.assertEqual(result["coverage"]["writerSupport"], "unknown")

    def test_changed_record_shape_fails_the_file_and_the_verdict(self):
        runtime = {"version": NEXT}
        self.session("sole.jsonl", [header(), entry("a", message=assistant(stop="newStop"), runtime=runtime)])
        code, output = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("FAIL", output)
        self.assertIn("NOT QUALIFIED", output)

    def test_form_asks_pass_only_when_parsed_wording_equals_the_producers(self):
        runtime = {"version": NEXT}
        submitted = list(zip(["store", "ttl_days", "extras", "region", "extra_notes"], ["Redis: shared", "7", "", "us", ""]))

        def form_session(wording):
            result = answer({"answers": [{"name": name, "question": question, "answer": value}
                                         for (name, value), question in zip(submitted, wording)]}, "form-one")
            return [header(), entry("ask", message=form_ask(), runtime=runtime),
                    entry("answer", "ask", result, runtime=runtime), entry("done", "answer", assistant("Done"), runtime=runtime)]

        self.session("sole.jsonl", form_session(FORM_QUESTIONS))
        code, output = self.run_tool()
        self.assertEqual(code, 0, output)
        self.session("sole.jsonl", form_session(["Storage backend"] + FORM_QUESTIONS[1:]))
        code, output = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("questions differ", output)

    def test_a_version_never_written_alone_or_absent_is_not_qualified(self):
        code, output = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("NOT QUALIFIED: 0 files", output)
        older = entry("old", None, assistant("Earlier"), runtime={"version": "18.14.0"})
        self.asked_session(NEXT, "mixed.jsonl", prefix=[older])
        code, output = self.run_tool()
        self.assertEqual(code, 1)
        self.assertIn("PASS", output)
        self.assertIn("NOT QUALIFIED", output)


if __name__ == "__main__":
    unittest.main()
