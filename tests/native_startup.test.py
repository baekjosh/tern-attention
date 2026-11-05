#!/usr/bin/env python3
"""Cold-load Attention once and exercise its real native canvas action handler."""

import argparse
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("native_harness", ROOT / "tools" / "native_harness.py")
assert SPEC is not None and SPEC.loader is not None
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)
PACKAGE = ROOT


class NativeStartup(unittest.TestCase):
    def test_first_load_accepts_canvas_navigation_without_reload(self):
        # The ordinary journey harness can reload after a load-budget failure. That would hide
        # this defect: the desktop keeps yesterday's clickable canvas but has no handler.
        with harness.IsolatedTern(PACKAGE, load_attempts=1, start_attempts=1) as app:
            app.enable_and_mount("attention")
            app.wait_for(lambda: harness.rail_rendered(app.tree("button").get("nodes")),
                         timeout=10, pump=True, what="rendered Attention controls")
            previous = None

            def stationary_later():
                nonlocal previous
                current = next(node for node in app.tree("button")["nodes"]
                               if str(node.get("title", "")).startswith("Later"))
                stable = previous is not None and current["rect"] == previous["rect"]
                previous = current
                return current if stable else None

            later = app.wait_for(stationary_later, timeout=5, interval=0.25, pump=True,
                                 what="settled Later button")
            x, y, width, height = later["rect"]
            app.ctl("click", f"{x + width / 2:.1f}", f"{y + height / 2:.1f}")

            def showing_later():
                prefs = (app.kv("attention") or {}).get("preferences") or {}
                return any(state.get("section") == "later"
                           for state in prefs.get("uiByWindow", {}).values())

            app.wait_for(showing_later, timeout=5, pump=True,
                         what="Later selection persisted after the native click")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, default=ROOT)
    args, remaining = parser.parse_known_args()
    PACKAGE = args.package
    unittest.main(argv=[__file__, *remaining])
