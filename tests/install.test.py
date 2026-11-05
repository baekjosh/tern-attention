import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "attention_install", Path(__file__).resolve().parents[1] / "tools" / "install.py"
)
assert spec is not None and spec.loader is not None
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)


class PackageLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir()
        for name in install.RUNTIME_FILES:
            (self.source / name).write_text("runtime " + name)
        (self.source / "private.txt").write_text("not runtime")
        for name in ("decisions.luau", "decision_rubric.json"):
            (self.source / name).write_text("retired trial " + name)
        self.root = self.base / "runtime"
        self.root.mkdir()
        self.links = self.base / "plugins"
        self.links.mkdir()

    def package(self, attempted=False):
        package = install.prepare(self.source, self.root)
        if attempted:
            marker = install.package_marker(package, self.root)
            marker["activation_attempted"] = True
            install.write_marker(package, marker)
        return package

    def legacy_package(self, attempted=False, size=8):
        package = Path(tempfile.mkdtemp(prefix="package-legacy-", dir=self.root))
        files = (
            "plugin.toml", "window.luau", "model.luau", "layout.luau",
            "view.luau", "identity.luau", "titles.luau", "styles.css",
        )
        if size >= 9:
            files += ("source_facts.py",)
        if size == 10:
            files += ("navigation.luau",)
        if size == 11:
            files += ("decisions.luau", "decision_rubric.json")
        for name in files:
            (package / name).write_text("legacy runtime " + name)
        marker = {
            "producer": "tern-attention/tools/install.py:1",
            "files": {name: install.signature(package / name) for name in files},
            "activation_attempted": attempted,
        }
        if size == 10:
            marker["capability"] = "workspace-navigator-1"
        install.write_marker(package, marker)
        return package

    def without_capability(self, package):
        marker = install.package_marker(package, self.root)
        del marker["capability"]
        install.write_marker(package, marker)

    def link(self, package, name="attention"):
        (self.links / (name + ".path")).write_text(str(package) + "\n")

    def test_prepare_copies_only_runtime_and_decouples_source_edits(self):
        package = self.package()
        self.assertEqual(
            {entry.name for entry in package.iterdir()},
            {
                "plugin.toml", "window.luau", "model.luau", "layout.luau",
                "view.luau", "identity.luau", "titles.luau", "styles.css",
                "source_facts.py", "navigation.luau", "host.luau", "phone.luau",
                install.MARKER,
            },
        )
        self.assertEqual(len(install.RUNTIME_FILES), 12)
        self.assertEqual(install.RUNTIME_CAPABILITY, "workspace-navigator-2")
        self.assertEqual(install.package_marker(package, self.root)["capability"], "workspace-navigator-2")
        (self.source / "model.luau").write_text("new source")
        self.assertEqual((package / "model.luau").read_text(), "runtime model.luau")
        self.assertEqual((self.source / "private.txt").read_text(), "not runtime")
        (self.source / "source_facts.py").unlink()
        self.assertEqual((package / "source_facts.py").read_text(), "runtime source_facts.py")
        self.assertFalse((package / "source_facts.py").is_symlink())

    def test_every_previous_complete_shape_is_recognized(self):
        for size in (8, 9, 10, 11):
            with self.subTest(size=size):
                package = self.legacy_package(attempted=True, size=size)
                marker = install.package_marker(package, self.root)
                self.assertEqual(len(marker["files"]), size)
                self.assertTrue(marker["activation_attempted"])

    def test_sweep_removes_unreachable_legacy_generations_only(self):
        stale_eight = self.legacy_package(attempted=True)
        stale_eleven = self.legacy_package(attempted=True, size=11)
        previous = self.legacy_package(attempted=True)
        linked = self.legacy_package(attempted=True, size=11)
        prepared = self.legacy_package(size=11)
        modified = self.legacy_package(attempted=True, size=11)
        (modified / "decisions.luau").write_text("user modification")
        unexpected = self.legacy_package(attempted=True)
        (unexpected / "notes.txt").write_text("user notes")
        foreign = self.legacy_package(attempted=True, size=11)
        marker = install.package_marker(foreign, self.root)
        marker["producer"] = "another producer"
        install.write_marker(foreign, marker)
        current = self.package(attempted=True)
        self.link(current)
        self.link(linked, "another-plugin")
        report = install.sweep(self.root, self.links, current, previous)
        self.assertCountEqual(report["removed"], [str(stale_eight), str(stale_eleven)])
        self.assertFalse(stale_eight.exists())
        self.assertFalse(stale_eleven.exists())
        for kept in (previous, linked, prepared, modified, unexpected, foreign, current):
            self.assertTrue(kept.is_dir())
        self.assertEqual((modified / "decisions.luau").read_text(), "user modification")
        self.assertEqual((unexpected / "notes.txt").read_text(), "user notes")
        self.assertEqual(install.read_link(self.links / "another-plugin.path"), linked)

    def assert_current_legacy_kept(self, size):
        current = self.legacy_package(attempted=True, size=size)
        stale = self.legacy_package(attempted=True, size=size)
        self.link(current)
        report = install.sweep(self.root, self.links, current, None)
        self.assertEqual(report["removed"], [str(stale)])
        self.assertTrue(current.is_dir())
        self.assertEqual(install.read_link(self.links / "attention.path"), current)

    def test_sweep_keeps_current_eight_file_legacy_link(self):
        self.assert_current_legacy_kept(8)

    def test_sweep_keeps_current_eleven_file_legacy_link(self):
        self.assert_current_legacy_kept(11)

    def test_sweep_keeps_current_ten_file_previous_link(self):
        self.assert_current_legacy_kept(10)

    def test_sweep_preserves_ten_file_previous_generation(self):
        previous = self.legacy_package(attempted=True, size=10)
        older = self.legacy_package(attempted=True, size=10)
        current = self.package(attempted=True)
        self.link(current)
        report = install.sweep(self.root, self.links, current, previous)
        self.assertEqual(report["removed"], [str(older)])
        self.assertTrue(previous.is_dir())
        self.assertEqual((previous / "navigation.luau").read_text(), "legacy runtime navigation.luau")
        self.assertFalse((previous / "host.luau").exists())

    def test_sweep_preserves_eleven_file_previous_generation(self):
        previous = self.legacy_package(attempted=True, size=11)
        current = self.package(attempted=True)
        self.link(current)
        report = install.sweep(self.root, self.links, current, previous)
        self.assertEqual(report["removed"], [])
        self.assertTrue(previous.is_dir())
        self.assertEqual((previous / "decisions.luau").read_text(), "legacy runtime decisions.luau")

    def test_legacy_cleanup_preserves_links_but_removes_unlinked_owned_packages(self):
        for size in (8, 10, 11):
            with self.subTest(size=size):
                package = self.legacy_package(size=size)
                self.link(package)
                report = install.cleanup_failed(package, self.root, self.links)
                self.assertEqual(report["removed"], [])
                self.assertTrue(package.exists())
                (self.links / "attention.path").unlink()
                report = install.cleanup_failed(package, self.root, self.links)
                self.assertEqual(report["removed"], [str(package)])
                self.assertFalse(package.exists())

    def test_legacy_activation_rejected_before_native_link_or_marker_change(self):
        for size in (8, 9, 10, 11):
            with self.subTest(size=size):
                package = self.legacy_package(attempted=True, size=size)
                marker_before = (package / install.MARKER).read_bytes()
                with patch.object(install, "native") as native:
                    with self.assertRaisesRegex(ValueError, "fix forward"):
                        install.activate(package, self.root, self.links, {})
                native.assert_not_called()
                self.assertEqual((package / install.MARKER).read_bytes(), marker_before)
                self.assertIsNone(install.read_link(self.links / "attention.path"))

    def test_current_twelve_file_activation_links_exact_prepared_package(self):
        package = self.package()
        report = {}

        def native(args):
            self.assertEqual(args, ["link", str(package)])
            self.link(package)
            return {"exitCode": 0, "json": {"status": "ready"}, "stdout": "{}", "stderr": ""}

        with patch.object(install, "native", side_effect=native):
            result = install.activate(package, self.root, self.links, report)
        self.assertEqual(result, 0)
        self.assertEqual(report["status"], "linked")
        self.assertTrue(report["linked"])
        self.assertEqual(install.read_link(self.links / "attention.path"), package)

    def test_activation_rejects_current_file_set_without_runtime_capability(self):
        package = self.package()
        self.without_capability(package)
        # File set and hashes still match: only the capability is missing.
        self.assertEqual(set(install.package_marker(package, self.root)["files"]), set(install.RUNTIME_FILES))
        marker_before = (package / install.MARKER).read_bytes()
        with patch.object(install, "native") as native:
            with self.assertRaisesRegex(ValueError, "runtime capability"):
                install.activate(package, self.root, self.links, {})
        native.assert_not_called()
        self.assertEqual((package / install.MARKER).read_bytes(), marker_before)
        self.assertIsNone(install.read_link(self.links / "attention.path"))

    def test_activation_rejects_previous_and_unknown_runtime_capabilities(self):
        for capability in ("workspace-navigator-0", "workspace-navigator-1"):
            with self.subTest(capability=capability):
                package = self.package()
                marker = install.package_marker(package, self.root)
                marker["capability"] = capability
                install.write_marker(package, marker)
                marker_before = (package / install.MARKER).read_bytes()
                with patch.object(install, "native") as native:
                    with self.assertRaisesRegex(ValueError, "runtime capability"):
                        install.activate(package, self.root, self.links, {})
                native.assert_not_called()
                self.assertEqual((package / install.MARKER).read_bytes(), marker_before)

    def test_activate_existing_cli_rejects_package_without_capability_and_keeps_it(self):
        package = self.package()
        self.without_capability(package)

        def native(args):
            self.assertEqual(args, ["dir"])
            return {"exitCode": 0, "json": {"dir": str(self.links)}, "stdout": "{}", "stderr": ""}

        stdout = io.StringIO()
        with patch.object(install, "RUNTIME_ROOT", self.root), \
                patch.object(install, "native", side_effect=native) as stub, \
                patch.object(sys, "argv", ["install.py", "--activate-existing", str(package)]), \
                contextlib.redirect_stdout(stdout):
            code = install.main()
        self.assertEqual(code, 1)
        self.assertIn("runtime capability", json.loads(stdout.getvalue())["error"])
        stub.assert_called_once()
        self.assertTrue(package.is_dir())
        self.assertIsNone(install.read_link(self.links / "attention.path"))

    def test_activate_existing_cli_links_package_prepared_with_current_capability(self):
        package = self.package()

        def native(args):
            if args == ["dir"]:
                return {"exitCode": 0, "json": {"dir": str(self.links)}, "stdout": "{}", "stderr": ""}
            self.assertEqual(args, ["link", str(package)])
            self.link(package)
            return {"exitCode": 0, "json": {"status": "ready"}, "stdout": "{}", "stderr": ""}

        stdout = io.StringIO()
        with patch.object(install, "RUNTIME_ROOT", self.root), \
                patch.object(install, "native", side_effect=native), \
                patch.object(sys, "argv", ["install.py", "--activate-existing", str(package)]), \
                contextlib.redirect_stdout(stdout):
            code = install.main()
        report = json.loads(stdout.getvalue())
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "linked")
        self.assertEqual(install.read_link(self.links / "attention.path"), package)
        self.assertTrue(package.is_dir())

    def test_sweep_keeps_current_previous_baseline_and_unactivated_packages(self):
        stale = self.package(attempted=True)
        previous = self.package(attempted=True)
        current = self.package(attempted=True)
        prepared = self.package()
        baseline = self.root / "stable"
        baseline.mkdir()
        (baseline / "window.luau").write_text("baseline")
        self.link(current)
        report = install.sweep(self.root, self.links, current, previous)
        self.assertFalse(stale.exists())
        for kept in (previous, current, prepared, baseline):
            self.assertTrue(kept.is_dir())
        self.assertEqual(report["removed"], [str(stale)])
        self.assertGreater(report["removedBytes"], 0)
        self.assertTrue(any(item["path"] == str(baseline) for item in report["retained"]))

    def test_sweep_preserves_unknown_files_edits_and_other_links(self):
        unknown = self.package(attempted=True)
        (unknown / "notes.txt").write_text("user-authored")
        edited = self.package(attempted=True)
        (edited / "model.luau").write_text("user-authored replacement")
        other = self.package(attempted=True)
        self.link(other, "another-plugin")
        current = self.package(attempted=True)
        self.link(current)
        report = install.sweep(self.root, self.links, current, None)
        self.assertEqual(report["removed"], [])
        self.assertEqual((unknown / "notes.txt").read_text(), "user-authored")
        self.assertEqual((edited / "model.luau").read_text(), "user-authored replacement")
        self.assertTrue(other.exists())
        self.assertEqual(install.read_link(self.links / "another-plugin.path"), other)

    def test_sweep_rejects_symlinks_and_does_not_follow_them(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "important").write_text("keep")
        (self.root / "package-symlink").symlink_to(outside, target_is_directory=True)
        candidate = self.package(attempted=True)
        (candidate / "model.luau").unlink()
        (candidate / "model.luau").symlink_to(outside / "important")
        current = self.package(attempted=True)
        self.link(current)
        report = install.sweep(self.root, self.links, current, None)
        self.assertEqual(report["removed"], [])
        self.assertEqual((outside / "important").read_text(), "keep")
        with self.assertRaises(ValueError):
            install.package_marker(self.root / "package-symlink", self.root)

    def test_sweep_does_not_delete_after_attention_link_changes(self):
        stale = self.package(attempted=True)
        current = self.package(attempted=True)
        self.link(stale)
        with self.assertRaises(ValueError):
            install.sweep(self.root, self.links, current, None)
        self.assertTrue(stale.exists())
        self.assertTrue(current.exists())

    def test_failed_staging_cleanup_requires_known_unlinked_target(self):
        candidate = self.package()
        self.link(candidate)
        report = install.cleanup_failed(candidate, self.root, self.links)
        self.assertEqual(report["removed"], [])
        self.assertTrue(candidate.exists())
        (self.links / "attention.path").write_text("")
        report = install.cleanup_failed(candidate, self.root, self.links)
        self.assertEqual(report["removed"], [])
        self.assertTrue(candidate.exists())
        (self.links / "attention.path").unlink()
        report = install.cleanup_failed(candidate, self.root, self.links)
        self.assertEqual(report["removed"], [str(candidate)])
        self.assertFalse(candidate.exists())

    def test_partial_owned_staging_is_cleaned_but_incomplete_activation_is_rejected(self):
        candidate = self.root / "package-partial"
        candidate.mkdir()
        (candidate / "window.luau").write_text("partially copied")
        install.write_marker(candidate, {
            "producer": install.PRODUCER,
            "files": {"window.luau": install.signature(candidate / "window.luau")},
            "activation_attempted": False,
        })
        with self.assertRaises(ValueError):
            install.package_marker(candidate, self.root)
        report = install.cleanup_failed(candidate, self.root, self.links)
        self.assertEqual(report["removed"], [str(candidate)])
        self.assertFalse(candidate.exists())

    def test_receipt_errors_are_not_hidden_by_process_success(self):
        receipt = {"reload": {"plugins": [{"id": "attention", "status": "error", "error": "compile failed"}], "problems": []}}
        errors = install.receipt_errors(receipt)
        self.assertTrue(any("compile failed" in error for error in errors))
        self.assertEqual(install.receipt_errors({"problems": [], "status": "ready"}), [])


if __name__ == "__main__":
    unittest.main()
