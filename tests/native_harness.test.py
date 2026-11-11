#!/usr/bin/env python3
"""Pure-helper tests for tools/native_harness.py. Never launches Tern."""

import importlib.util
import os
from pathlib import Path
import signal
import socket
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "native_harness", Path(__file__).resolve().parents[1] / "tools" / "native_harness.py")
assert SPEC is not None and SPEC.loader is not None
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


def unquote(token):
    """Reference decoder for the documented script escapes: \\\\ \\" \\n \\t inside double quotes."""
    assert token[0] == token[-1] == '"'
    out, index, body = [], 0, token[1:-1]
    while index < len(body):
        char = body[index]
        if char == "\\":
            index += 1
            out.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}[body[index]])
        else:
            out.append(char)
        index += 1
    return "".join(out)


class FakeChild:
    """Stands in for subprocess.Popen: survives SIGTERM unless told otherwise."""

    def __init__(self, pid=4242, dies_on=(signal.SIGTERM,)):
        self.pid, self.dies_on, self.signals, self.code = pid, dies_on, [], None

    def poll(self):
        return self.code

    def deliver(self, group, sent):
        assert group == self.pid
        self.signals.append(sent)
        if sent in self.dies_on:
            self.code = -int(sent)


class PortAndArguments(unittest.TestCase):
    def test_free_port_is_bindable_and_varies_by_call_site(self):
        port = harness.free_port()
        self.assertTrue(1024 <= port <= 65535)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))

    def test_commands_are_plain_argv(self):
        self.assertEqual(harness.serve_command("/bin/tern", 61000, Path("/r/shots")),
                         ["/bin/tern", "serve", "--control", "61000", "--out", "/r/shots"])
        self.assertEqual(harness.ctl_command("/bin/tern", 61000, "wheel", 0, -3),
                         ["/bin/tern", "ctl", "--control", "61000", "wheel", "0", "-3"])

    def test_quote_round_trips_awkward_lua(self):
        code = 'local s = "a\\"b\\n\tc" -- note\nreturn [[x  y]] .. \'  z\''
        self.assertEqual(unquote(harness.quote(code)), code)

    def test_env_scrubs_inherited_tern_and_isolates_paths(self):
        base = {"PATH": "/usr/bin", "HOME": "/Users/real", "TERN_PANE_SOCKET": "/live/daemon.sock",
                "TERN_WINDOW_KEY": "w", "TERN_IDENTITY": "{}", "TERN_CONFIG_DIR": "/live/config",
                "STENCIL_LOG": "trace", "LANG": "en_US.UTF-8"}
        env = harness.build_env("/tmp/root", base=base)
        self.assertEqual(env["HOME"], "/tmp/root/home")
        self.assertEqual(env["TERN_CONFIG_DIR"], "/tmp/root/config")
        self.assertEqual(env["TERN_DAEMON_SOCKET"], "/tmp/root/d.sock")
        self.assertEqual(env["STENCIL_FIXTURE_ROOT"], "/tmp/root/crates/tern")
        self.assertEqual(env["PATH"], "/usr/bin")
        for leaked in ("TERN_PANE_SOCKET", "TERN_WINDOW_KEY", "TERN_IDENTITY", "STENCIL_LOG"):
            self.assertNotIn(leaked, env)
        self.assertEqual(harness.build_env("/tmp/root", base=base, extra={"STENCIL_LOG": "warn"})["STENCIL_LOG"], "warn")


class Parsing(unittest.TestCase):
    def test_reply_ok_and_failure(self):
        self.assertEqual(harness.parse_reply('{"ok":true,"png":"/x.png"}\n')["png"], "/x.png")
        with self.assertRaisesRegex(harness.HarnessError, "unknown command"):
            harness.parse_reply('{"ok":false,"error":"unknown command \\"bogus\\""}')
        with self.assertRaises(harness.HarnessError):
            harness.parse_reply("")
        with self.assertRaises(harness.HarnessError):
            harness.parse_reply("not json")

    def test_lua_answer_arrow_and_one_time_header(self):
        first = {"text": '(fresh Lua state: earlier globals are gone)\n\u2192 {"a":1}', "error": False}
        later = {"text": '\u2192 {"a":1}', "error": False}
        self.assertEqual(harness.parse_lua_answer(first), '{"a":1}')
        self.assertEqual(harness.parse_lua_answer(later), '{"a":1}')
        self.assertEqual(harness.parse_lua_answer({"text": "\u2192 nil", "error": False}), "nil")

    def test_lua_error_and_truncation_are_loud_not_data(self):
        with self.assertRaisesRegex(harness.LuaError, "boom"):
            harness.parse_lua_answer({"text": "error: lua#1:1: boom", "error": True})
        cut = {"text": '\u2192 [{"a"\n\u2026 18315 bytes cut \u2026\n"z"}]', "error": False}
        with self.assertRaisesRegex(harness.HarnessError, "18315 bytes cut"):
            harness.parse_lua_answer(cut)
        with self.assertRaises(harness.HarnessError):
            harness.parse_lua_answer(None)

    def test_empty_lua_table_encodes_as_object(self):
        self.assertEqual(harness.as_list({}), [])
        self.assertEqual(harness.as_list([{"pane": 4}]), [{"pane": 4}])

    def test_flatten_texts_walks_children_in_order(self):
        nodes = [{"text": "Attention", "children": [{"text": "0"}, {"children": [{"text": "Working"}]}]}, {"text": ""}]
        self.assertEqual(harness.flatten_texts(nodes), ["Attention", "0", "Working"])

    def test_rail_rendered_needs_mode_search_and_gear_or_return_buttons(self):
        mode, search = {"title": "Attention \u00b7 2 need you"}, {"title": "Search workspace"}
        gear, back = {"title": "More \u00b7 Settings"}, {"title": "Return to Workspace"}
        self.assertTrue(harness.rail_rendered([mode, search, gear]))
        self.assertTrue(harness.rail_rendered([mode, search, {"title": "Back to Attention"}]))
        self.assertTrue(harness.rail_rendered([{"title": "Go to \u00b7 x"}, mode, search, back]))
        self.assertFalse(harness.rail_rendered([mode, search]))
        self.assertFalse(harness.rail_rendered([search, gear]))
        self.assertFalse(harness.rail_rendered([mode, gear]))
        self.assertFalse(harness.rail_rendered([{"text": "All work"}, {"text": "No current attention cue"}]))
        self.assertFalse(harness.rail_rendered(None))

    def test_plugin_id_from_manifest(self):
        with tempfile.TemporaryDirectory() as raw:
            (Path(raw) / "plugin.toml").write_text('schema = 1\nid = "attention"\nwindow = "window.luau"\n')
            self.assertEqual(harness.plugin_id(raw), "attention")
            with self.assertRaises(harness.HarnessError):
                harness.plugin_id(Path(raw) / "missing")


class Teardown(unittest.TestCase):
    def test_terminate_signals_only_the_childs_own_group(self):
        child = FakeChild()
        seen = []
        outcome = harness.terminate(child, grace=0.2,
                                    killpg=lambda group, sent: (seen.append((group, sent)), child.deliver(group, sent)),
                                    getpgid=lambda pid: 4242 if pid == 4242 else 1, sleep=lambda _: None)
        self.assertEqual(outcome, "terminated")
        self.assertEqual(seen, [(4242, signal.SIGTERM)])

    def test_terminate_escalates_to_kill(self):
        child = FakeChild(dies_on=(signal.SIGKILL,))
        ticks = iter(range(1000))
        outcome = harness.terminate(child, grace=3,
                                    killpg=lambda group, sent: child.deliver(group, sent),
                                    getpgid=lambda pid: 4242 if pid == 4242 else 1,
                                    sleep=lambda _: None, clock=lambda: next(ticks))
        self.assertEqual(outcome, "killed")
        self.assertEqual(child.signals, [signal.SIGTERM, signal.SIGKILL])

    def test_terminate_refuses_a_shared_process_group(self):
        child = FakeChild()
        with self.assertRaisesRegex(harness.HarnessError, "own process group"):
            harness.terminate(child, killpg=lambda *_: self.fail("must not signal"),
                              getpgid=lambda pid: 99, sleep=lambda _: None)
        self.assertEqual(child.signals, [])

    def test_terminate_ignores_exited_or_missing_child(self):
        done = FakeChild()
        done.code = 0
        self.assertEqual(harness.terminate(done, killpg=lambda *_: self.fail("no signal")), "already-exited")
        self.assertEqual(harness.terminate(None), "already-exited")

    def test_close_removes_root_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as package:
            Path(package, "plugin.toml").write_text('schema = 1\nid = "demo"\nwindow = "window.luau"\n')
            instance = harness.IsolatedTern(package, tern="/bin/sh")
            instance._prepare_root()
            root = instance.root
            self.assertTrue((root / "crates/plugins/fixtures/demo").is_symlink())
            self.assertEqual(os.readlink(root / "crates/plugins/fixtures/demo"), str(Path(package).resolve()))
            instance.close()
            self.assertFalse(root.exists())
            instance.close()

    def test_keep_leaves_root_and_seed_files_stay_inside_config(self):
        with tempfile.TemporaryDirectory() as package:
            Path(package, "plugin.toml").write_text('schema = 1\nid = "demo"\nwindow = "window.luau"\n')
            seeded = harness.IsolatedTern(package, tern="/bin/sh", keep=True, settings={"plugins_disabled": []},
                                          seed_files={"plugin-data/demo/kv.json": b"{}"})
            seeded._prepare_root()
            try:
                self.assertEqual((seeded.config / "plugin-data/demo/kv.json").read_bytes(), b"{}")
                self.assertEqual((seeded.config / "settings.json").read_text(), '{"plugins_disabled": []}')
                seeded.close()
                self.assertTrue(seeded.root.exists())
            finally:
                import shutil
                shutil.rmtree(seeded.root, ignore_errors=True)
            escape = harness.IsolatedTern(package, tern="/bin/sh", seed_files={"../outside": b"x"})
            with self.assertRaisesRegex(harness.HarnessError, "escapes"):
                escape._prepare_root()
            escape.close()


if __name__ == "__main__":
    unittest.main()
