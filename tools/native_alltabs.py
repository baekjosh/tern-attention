#!/usr/bin/env python3
"""Native journeys for the explicit "use this position for all tabs" action (isolated headless Tern, real package).

    persist   rail at LEFT, press Bottom on the tab, reload the plugin, switch tabs and back, create a new tab, reload
              again: it must stay bottom and new tabs must open at the default bottom (no path may rewrite a chosen
              position back to the physical edge)
    alltabs   4 tabs, two rails at LEFT, Settings > All tabs > Bottom: the visited tab starts at once, the other marked
              tab waits for its visit, tabs with no rail open at bottom, content trees are unchanged, no marker remains
    shots     the two-row Placement setting at 1839x1135 (screenshot)
    all       every journey

    python3 tools/native_alltabs.py all [--package READYDIR] [--log FILE]

The package comes from `python3 tools/install.py --prepare-only` unless --package is given. Everything runs through
tools/native_harness.py (isolated config/home); the live Tern is never touched.
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_harness as nh  # noqa: E402
import native_journeys as nj  # noqa: E402

PLUGIN, ENABLE, OPEN = nj.PLUGIN, nj.ENABLE, nj.OPEN


def lua(T, code):
    return nj.lua_retry(T, code) or {}


def nudged_wait(T, predicate, what, timeout=60.0, nudge_every=6.0):
    """Pump until predicate() holds; headless plugin timers stall mid-placement, so `Attention: Open` is the nudge."""
    started, nudged = time.monotonic(), time.monotonic()
    while time.monotonic() - started < timeout:
        T.pump()
        if predicate():
            return round(time.monotonic() - started, 2)
        if time.monotonic() - nudged >= nudge_every:
            T.run_action(OPEN, check=False)
            nudged = time.monotonic()
        time.sleep(0.3)
    raise nh.WaitTimeout(f"{what} not reached in {timeout}s")


def edge_of(T, tab):
    return nj.physical_edge(T, tab)


def content_tree(T, tab, edge):
    """Canonical shape of the tab's content subtree (everything but the rail), or None when the rail is not canonical at `edge`."""
    rail = nj.tab_rail(T, tab)
    root = nj.layout_of(T, tab)["root"]
    content = nj.rail_content(root, rail, edge) if rail is not None else None
    return nj.canon(content) if content is not None else None


def stored(T, tab):
    return nj.placement_record(T, tab) or {}


def defaults(T):
    return ((T.kv(PLUGIN) or {}).get("preferences") or {}).get("defaults") or {}


def focus_content(T, tab):
    rail = nj.tab_rail(T, tab)
    pane = [p["pane"] for p in nj.pane_rows(T) if p["tab"] == tab and p["pane"] != rail and not p["floating"]][0]
    nj.focus_pane(T, pane)
    return pane


def click_position(T, label, scope):
    """Click Settings > Placement `label` in the `scope` row ("this" = first match, "all" = last match in document order)."""
    if nj.page_button_text(T, label) is None:
        nj.click_until(T, lambda: nj.button_by_title(T, "More \u00b7"), lambda: nj.page_button_text(T, label) is not None, "settings open")
    for _ in range(4):
        for _ in range(6):
            T.pump()
            time.sleep(0.3)
        found = [n for n in nj.nodes(T, "button") if n.get("text") == label]
        if found:
            nj.click_node(T, found[0] if scope == "this" else found[-1])
            return len(found)
    raise nh.HarnessError(f"no {label} button")


def persist_case(package, log, name, split, mid_move):
    """One rail at LEFT, Bottom pressed on its tab (optionally with split content and a plugin reload before the
    placement settles), then every re-read of the store the plugin can make."""
    check = nj.Checks(log, f"PERSIST.{name}")
    with nj.new_instance(package, seed_files=nj.seeded_position("left"), width=1280, height=800) as T:
        tab = T.tabs()[0]["id"]
        if split:
            nj.build(T, [("split", 0, "right"), ("split", 1, "down")])
        before = nj.layout_of(T, tab)
        contents = nj.canon(before["root"])
        T.run_action(ENABLE)
        placed, _, nudges, facts, _ = nj.place_with_nudges(T, tab, before, edge="left")
        check("starts-at-left", placed is not None and edge_of(T, tab) == "left", {"placedAt": placed, "nudges": nudges, "facts": facts})
        nj.rail_ready(T, tab)
        kv_path = T.config / "plugin-data" / PLUGIN / "kv.json"
        if mid_move:
            click_position(T, "Bottom", "this")
            nudged_wait(T, lambda: stored(T, tab).get("position") == "bottom", "request recorded")
            nj.reload_plugin(T)
        else:
            nj.choose_position(T, tab, "Bottom", "bottom")
        nudged_wait(T, lambda: stored(T, tab).get("placement") is None and edge_of(T, tab) == "bottom", "bottom placement settled")
        check("bottom-applied", edge_of(T, tab) == "bottom" and stored(T, tab).get("position") == "bottom"
              and defaults(T).get("position") == "bottom" and content_tree(T, tab, "bottom") == contents,
              {"edge": edge_of(T, tab), "stored": stored(T, tab).get("position"), "defaults": defaults(T).get("position"),
               "contentUnchanged": content_tree(T, tab, "bottom") == contents})
        tree = nj.layout_of(T, tab)
        nj.reload_plugin(T)
        nj.settle_store(T, kv_path, quiet=6.0)
        check("stays-bottom-after-plugin-reload", edge_of(T, tab) == "bottom" and stored(T, tab).get("position") == "bottom"
              and nj.layout_of(T, tab) == tree, {"edge": edge_of(T, tab), "stored": stored(T, tab).get("position")})
        second = T.new_tab()
        new_tab = T.lua_json(f"return {{ t = cx.session:tab_of({second}) }}")["t"]
        T.mount_count(PLUGIN, 2, timeout=40)
        nudged_wait(T, lambda: stored(T, new_tab).get("placement") is None and edge_of(T, new_tab) == "bottom", "new tab at bottom")
        check("new-tab-opens-at-default-bottom", edge_of(T, new_tab) == "bottom" and stored(T, new_tab).get("position") == "bottom",
              {"edge": edge_of(T, new_tab), "stored": stored(T, new_tab).get("position")})
        for target in (tab, new_tab, tab):
            focus_content(T, target)
            for _ in range(8):
                T.pump()
                time.sleep(0.4)
        check("stays-bottom-after-switching-tabs", edge_of(T, tab) == "bottom" and edge_of(T, new_tab) == "bottom"
              and stored(T, tab).get("position") == "bottom", {"edges": [edge_of(T, tab), edge_of(T, new_tab)]})
        trees = {t: nj.layout_of(T, t) for t in (tab, new_tab)}
        nj.reload_plugin(T)
        nj.settle_store(T, kv_path, quiet=6.0)
        again = {t: nj.layout_of(T, t) for t in (tab, new_tab)}
        check("stays-bottom-after-restart-like-reload", again == trees and all(edge_of(T, t) == "bottom" for t in trees)
              and all(stored(T, t).get("position") == "bottom" for t in trees),
              {"edges": {t: edge_of(T, t) for t in trees}, "stored": {t: stored(T, t).get("position") for t in trees}})
        check("no-plugin-errors", not [w for w in T.plugin_warnings() if "ERROR" in w], T.plugin_warnings()[-2:])
    return check


def persist(package, log):
    log("## persist: a chosen position survives reload, tab switches, new tabs")
    checks = [persist_case(package, log, name, split, mid) for name, split, mid in
              (("single", False, False), ("split-midmove", True, True))]
    items = [item for check in checks for item in check.items]
    return {"journey": "persist", "pass": all(check.passed for check in checks), "checks": items}

def alltabs(package, log):
    log("## alltabs: two rails at left, All tabs > Bottom, then visit every tab")
    check = nj.Checks(log, "ALLTABS")
    with nj.new_instance(package, seed_files=nj.seeded_position("left"), width=1280, height=800) as T:
        tab1 = T.tabs()[0]["id"]
        first = lua(T, "return { p = cx.session:focused() }")["p"]
        before1 = nj.layout_of(T, tab1)
        T.run_action(ENABLE)
        placed, _, nudges, facts, _ = nj.place_with_nudges(T, tab1, before1, edge="left")
        check("tab1-rail-at-left", placed is not None, {"placedAt": placed, "nudges": nudges, "facts": facts})
        pane2 = T.new_tab()
        tab2 = T.lua_json(f"return {{ t = cx.session:tab_of({pane2}) }}")["t"]
        nj.build(T, [("split", 0, "right")])
        T.mount_count(PLUGIN, 2, timeout=40)
        nudged_wait(T, lambda: stored(T, tab2).get("placement") is None and edge_of(T, tab2) == "left", "tab 2 rail at left")
        tabs = [tab1, tab2]
        for _ in range(2):
            pane = lua(T, "return { p = cx.layout:new_tab({}, { focus = false }) }")["p"]
            tabs.append(lua(T, f"return {{ t = cx.session:tab_of({pane}) }}")["t"])
        tab3, tab4 = tabs[2], tabs[3]
        nj.focus_pane(T, first)
        nj.rail_ready(T, tab1)
        lefts = {t: edge_of(T, t) for t in tabs}
        contents = {t: content_tree(T, t, "left") for t in (tab1, tab2)}
        check("fixture-two-rails-at-left-two-tabs-without-rail", lefts[tab1] == "left" and lefts[tab2] == "left"
              and nj.tab_rail(T, tab3) is None and nj.tab_rail(T, tab4) is None, {"edges": lefts, "tabs": tabs})
        tab2_before = nj.layout_of(T, tab2)
        shot_before = nj.keep_shot(T, "alltabs-before")
        clicked = click_position(T, "Bottom", "all")
        check("all-tabs-row-present", clicked >= 2, {"bottomButtons": clicked})
        nudged_wait(T, lambda: stored(T, tab1).get("placement") is None and edge_of(T, tab1) == "bottom", "visited tab moves at once")
        record = {t: stored(T, t) for t in tabs}
        check("selected-tab-moved-at-once", edge_of(T, tab1) == "bottom" and content_tree(T, tab1, "bottom") == contents[tab1]
              and record[tab1].get("moveTo") is None and record[tab1].get("position") == "bottom", {"edge": edge_of(T, tab1)})
        check("other-tab-marked-and-waiting", record[tab2].get("moveTo") == "bottom" and record[tab2].get("position") == "left"
              and nj.layout_of(T, tab2) == tab2_before, {"stored": record[tab2], "layoutUnchanged": nj.layout_of(T, tab2) == tab2_before})
        for _ in range(12):
            T.pump()
            time.sleep(0.5)
        check("waiting-moves-nothing", nj.layout_of(T, tab2) == tab2_before and nj.tab_rail(T, tab3) is None and nj.tab_rail(T, tab4) is None,
              {"tab2Edge": edge_of(T, tab2)})
        check("default-is-bottom", defaults(T).get("position") == "bottom", defaults(T))
        for target in (tab2, tab3, tab4):
            focus_content(T, target) if nj.tab_rail(T, target) is not None else nj.focus_pane(
                T, [p["pane"] for p in nj.pane_rows(T) if p["tab"] == target][0])
            nudged_wait(T, lambda t=target: nj.tab_rail(T, t) is not None and stored(T, t).get("placement") is None
                        and edge_of(T, t) == "bottom", f"tab {target} at bottom")
        final = {t: stored(T, t) for t in tabs}
        check("every-tab-at-bottom-with-content-unchanged", all(edge_of(T, t) == "bottom" for t in tabs)
              and content_tree(T, tab2, "bottom") == contents[tab2] and content_tree(T, tab1, "bottom") == contents[tab1],
              {"edges": {t: edge_of(T, t) for t in tabs}})
        check("no-marker-remains", all(entry.get("moveTo") is None and entry.get("position") == "bottom" for entry in final.values()),
              {t: {"position": e.get("position"), "moveTo": e.get("moveTo")} for t, e in final.items()})
        taken = {}
        for label, target in (("tab2", tab2), ("tab1", tab1)):
            focus_content(T, target)
            for _ in range(8):
                T.pump()
                time.sleep(0.4)
            taken[label] = nj.keep_shot(T, f"alltabs-after-{label}")
        check("shots", True, {"before": shot_before, **taken, "layouts": {t: nj.layout_of(T, t)["root"] for t in tabs}})
        check("no-plugin-errors", not [w for w in T.plugin_warnings() if "ERROR" in w], T.plugin_warnings()[-2:])
    return {"journey": "alltabs", "pass": check.passed, "checks": check.items}


def shots(package, log):
    """The Placement setting at the viewport the user has: two rows (This tab, All tabs) under Settings."""
    log("## shots: Settings > Placement at 1839x1135, rail at the default bottom")
    check = nj.Checks(log, "SHOTS")
    with nj.new_instance(package, width=1839, height=1135) as T:
        tab = T.tabs()[0]["id"]
        T.run_action(ENABLE)
        T.mount_count(PLUGIN, 1, timeout=40)
        nudged_wait(T, lambda: stored(T, tab).get("placement") is None and edge_of(T, tab) == "bottom", "rail at bottom")
        nj.rail_ready(T, tab)
        nj.click_until(T, lambda: nj.button_by_title(T, "More \u00b7"), lambda: nj.page_button_text(T, "Reset placement") is not None, "settings open")
        for _ in range(6):
            T.pump()
            time.sleep(0.4)
        T.ctl("hover", "[data-surface]")
        T.wheel(0, 400)
        for _ in range(4):
            T.pump()
            time.sleep(0.3)
        labels = [n.get("text") for n in nj.nodes(T, "button") if n.get("text") in ("Bottom", "Right", "Left", "Reset placement")]
        check("two-placement-rows", labels.count("Bottom") == 2 and labels.count("Right") == 2 and labels.count("Left") == 2
              and labels.count("Reset placement") == 1, {"labels": labels, "shot": nj.keep_shot(T, "alltabs-settings")})
    return {"journey": "shots", "pass": check.passed, "checks": check.items}

JOURNEYS = {"persist": persist, "alltabs": alltabs, "shots": shots}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("journey", choices=[*JOURNEYS, "all"])
    parser.add_argument("--package", help="prepared package dir (default: run install.py --prepare-only)")
    parser.add_argument("--log", help="append a Markdown log here")
    args = parser.parse_args(argv)
    package = args.package or nj.prepare_package()
    log = nj.Log(args.log)
    log(f"# native all-tabs journeys · package {package}")
    reports = []
    for name in (JOURNEYS if args.journey == "all" else [args.journey]):
        try:
            reports.append(JOURNEYS[name](package, log))
        except Exception as error:  # a crashed journey is a FAIL with its error, never a silent stop
            log(f"- FAIL {name} crashed: {type(error).__name__}: {error}")
            reports.append({"journey": name, "pass": False, "error": f"{type(error).__name__}: {error}"})
    print(json.dumps(reports, indent=1, default=str))
    return 0 if all(report.get("pass") for report in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
