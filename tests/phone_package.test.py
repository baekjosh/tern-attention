#!/usr/bin/env python3
"""Tests for tools/phone_package.py. Never touches the network or runs tailscale."""

import hashlib
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("phone_package", REPO / "tools" / "phone_package.py")
assert SPEC is not None and SPEC.loader is not None
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)

MANIFEST = (
    'schema = 1\nid = "attention"\nname = "Attention (phone)"\nversion = "9.9.9"\n'
    'window = "window.luau"\n'
)


class Recorder:
    """Stands in for subprocess.run; records every command and never executes anything."""

    def __init__(self, status=0, missing=False):
        self.calls, self.status, self.missing = [], status, missing

    def __call__(self, command, check=False):
        self.calls.append(command)
        if self.missing:
            raise FileNotFoundError("tailscale")
        return type("Result", (), {"returncode": self.status})()


class PhonePackageTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="phone-package-test-"))
        self.addCleanup(shutil.rmtree, self.temp, ignore_errors=True)
        self.source = self.temp / "attention-phone"
        self.source.mkdir()
        (self.source / "plugin.toml").write_text(MANIFEST)
        (self.source / "window.luau").write_text("return nil\n")
        (self.source / "README.md").write_text("# Attention phone\n")
        self.dist = self.temp / "dist"

    def build(self):
        return tool.build(self.source, self.dist)

    def test_build_is_deterministic(self):
        path, first = self.build()
        again, second = self.build()
        self.assertEqual(path, again)
        self.assertEqual(first, second)
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), second)

    def test_build_sha_changes_with_content(self):
        _, first = self.build()
        (self.source / "window.luau").write_text("return 1\n")
        _, second = self.build()
        self.assertNotEqual(first, second)

    def test_zip_layout(self):
        path, _ = self.build()
        self.assertEqual(path.name, "attention-phone-9.9.9.zip")
        with zipfile.ZipFile(path) as archive:
            names = [info.filename for info in archive.infolist()]
            self.assertEqual(names, ["attention-phone/", "attention-phone/README.md",
                                     "attention-phone/plugin.toml", "attention-phone/window.luau"])
            self.assertEqual(archive.read("attention-phone/plugin.toml").decode(), MANIFEST)
            for info in archive.infolist():
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
            self.assertIsNone(archive.testzip())
        self.assertEqual(sorted(entry.name for entry in (self.dist / "attention-phone").iterdir()),
                         list(tool.FILES))

    def test_stage_is_replaced_not_merged(self):
        self.build()
        (self.dist / "attention-phone" / "stray.txt").write_text("x")
        self.build()
        self.assertFalse((self.dist / "attention-phone" / "stray.txt").exists())

    def test_stray_source_file_is_refused(self):
        (self.source / "notes.txt").write_text("x")
        with self.assertRaises(tool.PackageError):
            self.build()
        self.assertFalse((self.dist / "attention-phone-9.9.9.zip").exists())

    def test_manifest_rules(self):
        cases = {
            "missing schema": MANIFEST.replace("schema = 1\n", ""),
            "unsupported schema": MANIFEST.replace("schema = 1", "schema = 2"),
            "string schema": MANIFEST.replace("schema = 1", 'schema = "1"'),
            "bad id": MANIFEST.replace('id = "attention"', 'id = "Attention_Phone"'),
            "long id": MANIFEST.replace('id = "attention"', 'id = "' + "a" * 33 + '"'),
            "unknown key": MANIFEST + 'color = "red"\n',
            "no window": MANIFEST.replace('window = "window.luau"\n', ""),
            "host half": MANIFEST + 'host = "window.luau"\n',
            "missing entry": MANIFEST.replace("window.luau", "gone.luau"),
            "escaping entry": MANIFEST.replace("window.luau", "../window.luau"),
            "wrong extension": MANIFEST.replace("window.luau", "window.js"),
            "no version": MANIFEST.replace('version = "9.9.9"\n', ""),
            "empty name": MANIFEST.replace("Attention (phone)", ""),
            "not toml": "not toml =\n",
        }
        for label, text in cases.items():
            with self.subTest(label):
                (self.source / "plugin.toml").write_text(text)
                with self.assertRaises(tool.PackageError):
                    tool.validate_manifest(self.source)

    def test_send_refuses_without_a_built_zip(self):
        run, lines = Recorder(), []
        with self.assertRaisesRegex(tool.PackageError, "build"):
            tool.send("iphone", True, self.source, self.dist, run, lines.append)
        self.assertEqual(run.calls, [])

    def test_send_without_yes_prints_the_command_and_runs_nothing(self):
        path, _ = self.build()
        run, lines = Recorder(), []
        self.assertEqual(tool.send("my-iphone", False, self.source, self.dist, run, lines.append), 0)
        self.assertEqual(run.calls, [])
        self.assertEqual(lines[0], f"tailscale file cp {path} my-iphone:")

    def test_send_with_yes_runs_exactly_the_printed_command(self):
        path, _ = self.build()
        run, lines = Recorder(status=3), []
        self.assertEqual(tool.send("my-iphone", True, self.source, self.dist, run, lines.append), 3)
        self.assertEqual(run.calls, [["tailscale", "file", "cp", str(path), "my-iphone:"]])
        self.assertEqual(lines[0], f"tailscale file cp {path} my-iphone:")

    def test_send_refuses_hostile_device_names(self):
        self.build()
        for name in ("--help", "-x", "", "a b", "a;b", "a$(b)", "../x", "x" * 300):
            with self.subTest(name):
                run = Recorder()
                with self.assertRaises(tool.PackageError):
                    tool.send(name, True, self.source, self.dist, run, lambda _: None)
                self.assertEqual(run.calls, [])

    def test_send_refuses_a_stale_zip(self):
        self.build()
        (self.source / "window.luau").write_text("return 2\n")
        run = Recorder()
        with self.assertRaisesRegex(tool.PackageError, "older"):
            tool.send("my-iphone", True, self.source, self.dist, run, lambda _: None)
        self.assertEqual(run.calls, [])

    def test_send_refuses_a_foreign_zip(self):
        self.build()
        zip_file = self.dist / "attention-phone-9.9.9.zip"
        with zipfile.ZipFile(zip_file, "w") as archive:
            archive.writestr("plugin.toml", MANIFEST)
        run = Recorder()
        with self.assertRaisesRegex(tool.PackageError, "layout"):
            tool.send("my-iphone", True, self.source, self.dist, run, lambda _: None)
        self.assertEqual(run.calls, [])

    def test_send_reports_missing_tailscale(self):
        self.build()
        with self.assertRaisesRegex(tool.PackageError, "tailscale"):
            tool.send("my-iphone", True, self.source, self.dist, Recorder(missing=True), lambda _: None)

    def test_cli_build_then_send(self):
        run, lines = Recorder(), []
        self.assertEqual(tool.main(["send", "--to", "my-iphone", "--yes"], run, lines.append, self.source, self.dist), 1)
        self.assertEqual(run.calls, [])
        self.assertEqual(tool.main(["build"], run, lines.append, self.source, self.dist), 0)
        digest = hashlib.sha256((self.dist / "attention-phone-9.9.9.zip").read_bytes()).hexdigest()
        self.assertTrue(any(digest in line for line in lines))
        self.assertEqual(run.calls, [])
        self.assertEqual(tool.main(["send", "--to", "my-iphone"], run, lines.append, self.source, self.dist), 0)
        self.assertEqual(run.calls, [])
        self.assertEqual(tool.main(["send", "--to", "my-iphone", "--yes"], run, lines.append, self.source, self.dist), 0)
        self.assertEqual(len(run.calls), 1)

    def test_both_commands_warn_that_the_package_is_phone_only(self):
        for argv in (["build"], ["send", "--to", "my-iphone"]):
            with self.subTest(argv):
                run, lines = Recorder(), []
                tool.main(["build"], run, lines.append, self.source, self.dist)
                lines.clear()
                self.assertEqual(tool.main(argv, run, lines.append, self.source, self.dist), 0)
                self.assertIn("PHONE ONLY", lines[0])
                self.assertIn("Never copy it into the Mac", lines[0])


if __name__ == "__main__":
    unittest.main()
