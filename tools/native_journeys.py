#!/usr/bin/env python3
"""Native journeys: drive the REAL Attention package in an isolated, headless `tern serve`.

Subcommands (each prints one JSON report on stdout; `--log FILE` also appends a Markdown log):

    j1   geometry   content-tree classes -> canonical outer rail on --edge (bottom default; right/left on request)
    j2   workspace  ~6 sessions / ~35 tabs / notes / browser / parked / floating; Workspace list in the rail
    j3   search     palette "Search workspace" picker: completeness, narrowing, Enter focuses, Escape inert
    j4   recovery   settings.json untouched by Attention; disable leaves native actions working
    j5   window     what window-ownership facts are observable headless
    j6   pager      Workspace pager lives in the non-sticky header: visible at scroll top and after scrolling
    all  every journey above
    migration  read-only copy of the real kv.json -> schema 4, `relocate` stripped, triage deep diff 0, no tmp files, idempotent reload (not in `all`)
    adoption   synthetic pre-position store over rails at bottom/right/left, plugin reload: positions adopted, nothing moves, second load writes nothing (not in `all`)
    shots      screenshots of the bottom strip (Attention, Workspace, Later, Settings) at 1280x800 and 1839x1135 with a read-only copy of the real store (not in `all`)
    phone      `--package <pkg> [--phone-package dist/attention-phone]`: real window half publishes phone.json (contract, counts = rail badges, heartbeat-only rewrites), the
               host block `attention.queue` at 390x844 (rows, Later, disable/enable, ping), tap-to-jump in the phone package (pane found by title even when its cwd/program differ, a
               conversation in another session found after switching to it, parked never moved) (not in `all`)

Journeys j2-j6 and `all` run once per rail edge (`--edge`, default bottom; `all` runs bottom then left). The bottom pass uses 1839x1135 because a bottom strip is
only ~20 % of the tab height; the left pass keeps the compact viewport its geometry was calibrated on.

The package comes from `python3 tools/install.py --prepare-only` (run automatically unless --package is given;
it only writes the installer-owned runtime directory and runs the read-only `tern plugin dir --json`).
Everything else goes through tools/native_harness.py (isolated config/home, no inherited TERN_* env).
"""

import argparse
import contextlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_harness as nh  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
PLUGIN = "attention"
ENABLE = f"plugin.{PLUGIN}.enable"
OPEN = f"plugin.{PLUGIN}.open"
DISABLE = f"plugin.{PLUGIN}.disable"
SEARCH = f"plugin.{PLUGIN}.search"
DIAGNOSTICS = f"plugin.{PLUGIN}.diagnostics"
SHOT_DIR = Path("/tmp/qual-a-shots")


class Log:
    def __init__(self, path=None):
        self.path = Path(path) if path else None
        self.lines = []

    def __call__(self, text=""):
        self.lines.append(text)
        print(text, file=sys.stderr, flush=True)
        if self.path:
            with self.path.open("a") as handle:
                handle.write(text + "\n")


def prepare_package():
    done = subprocess.run([sys.executable, str(REPO / "tools/install.py"), "--prepare-only"],
                          capture_output=True, text=True, check=True, cwd=REPO)
    return json.loads(done.stdout)["readyDirectory"]


# ---------------------------------------------------------------------------------------------
# Window helpers (all Carly Luau; answers are filtered in Lua because >8 KB is truncated)
# ---------------------------------------------------------------------------------------------

def canon(tree):
    """Layout tree -> nested tuples of (split, first, second) / ('p', pane): ids, order and axes, no ratios."""
    if tree is None:
        return None
    if "pane" in tree:
        return ("p", tree["pane"])
    return (tree["split"], canon(tree["1"]), canon(tree["2"]))


def ratios(tree):
    if tree is None or "pane" in tree:
        return []
    return [round(tree["ratio"], 3)] + ratios(tree["1"]) + ratios(tree["2"])


def float_key(floats):
    return sorted((item["pane"], item.get("over")) for item in nh.as_list(floats))


def lua_ok(T, code):
    return T.lua_json(code)


def layout_of(T, tab):
    return T.lua_json(f"return cx.session:layout({tab})")


def focused(T):
    return T.lua_json("return { f = cx.session:focused() }")["f"]


def rail_canvases(T):
    return T.canvases(PLUGIN)


def placement_record(T, tab):
    kv = T.kv(PLUGIN) or {}
    instances = ((kv.get("preferences") or {}).get("instances") or {})
    for host in instances.values():
        entry = host.get(str(tab))
        if entry is not None:
            return entry
    return None


def diagnostics(T):
    """Run the diagnostics command and return the written diagnostics.json (waits for a fresh write)."""
    path = T.config / "plugin-data" / PLUGIN / "diagnostics.json"
    before = path.stat().st_mtime_ns if path.exists() else 0
    T.run_action(DIAGNOSTICS)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_mtime_ns != before:
            with contextlib.suppress(ValueError):
                return json.loads(path.read_text())
        time.sleep(0.1)
    raise nh.WaitTimeout("diagnostics.json was not rewritten")


# The edge the current journey pass exercises (set by main). A bottom strip is only ~20 % of the tab height, so the
# bottom pass runs at the viewport the user actually has; the left pass keeps the compact viewport its geometry was calibrated on.
RUN = {"edge": "bottom"}
BOTTOM_VIEWPORT = (1839, 1135)


def new_instance(package, **kwargs):
    return nh.IsolatedTern(package, **kwargs)


def world_instance(package, width, height, **kwargs):
    """An isolated instance for a workspace journey: default rail position = RUN edge (seeded), bottom pass at BOTTOM_VIEWPORT."""
    edge = RUN["edge"]
    if edge == "bottom":
        width, height = BOTTOM_VIEWPORT
    if "seed_files" not in kwargs:
        seed = seeded_position(edge)
        if seed:
            kwargs["seed_files"] = seed
    return new_instance(package, width=width, height=height, **kwargs)


def surface_text(T):
    nodes = T.tree("[data-surface]").get("nodes") or []
    return nodes[0].get("text", "") if nodes else None


def button_rect(T, text, selector="button", exact=True):
    for node in T.tree(selector).get("nodes") or []:
        label = node.get("text", "")
        if (label == text) if exact else (text in label):
            return node
    return None


def click_center(T, node):
    x, y, w, h = node["rect"]
    return T.ctl("click", f"{x + w / 2:.1f}", f"{y + h / 2:.1f}")


def click_button(T, text, exact=True):
    node = button_rect(T, text, exact=exact)
    if node is None:
        raise nh.HarnessError(f"no button {text!r} in the tree")
    click_center(T, node)
    return node


# ---------------------------------------------------------------------------------------------
# J1 geometry
# ---------------------------------------------------------------------------------------------

# op = ("split", fromIndex, dir) | ("float", index); pane list starts as [the first shell]; each split appends.
CLASSES = {
    "single": [],
    "two-side-by-side": [("split", 0, "right")],
    "two-stacked": [("split", 0, "down")],
    "three-in-a-row": [("split", 0, "right"), ("split", 1, "right")],
    "grid-2x2": [("split", 0, "right"), ("split", 0, "down"), ("split", 1, "down")],
    "mixed-3": [("split", 0, "right"), ("split", 1, "down")],
    "single-plus-float": [("split", 0, "right"), ("float", 1)],
    "two-side-plus-float": [("split", 0, "right"), ("split", 1, "down"), ("float", 2)],
    "four-in-a-row": [("split", 0, "right"), ("split", 1, "right"), ("split", 2, "right")],
    "five-in-a-row": [("split", 0, "right"), ("split", 1, "right"), ("split", 2, "right"), ("split", 3, "right")],
    "seventeen-leaves": [("split", index, "right" if index % 2 else "down") for index in range(16)],
}


# Tabs with more than layout.MAX_CONTENT_LEAVES (16) leaves keep the rail beside the first pane by design.
DEGRADED_BY_DESIGN = {"seventeen-leaves": "Too many panes to place Attention full-height"}

# When the native minimum pane size (~93 px wide, ~55 px high) prevents the content ratios or the requested rail size,
# the engine still places the rail, reports this status, and keeps the rail at or above MIN_RAIL_SHARE when native allows.
MINIMUM_REASON = "Pane sizes limited by the native minimum"
MIN_RAIL_SHARE = 0.2

DEFAULT_EDGE = "bottom"
EDGES = ("bottom", "right", "left")
# (root split axis, child holding the rail, child holding the content) for each canonical outer rail.
RAIL_SIDE = {"left": ("right", "1", "2"), "right": ("right", "2", "1"), "bottom": ("down", "2", "1")}


def rail_content(root, rail, edge):
    """The content subtree when `root` is the canonical outer rail of `edge` around `rail`, else None."""
    split, rail_key, content_key = RAIL_SIDE[edge]
    if root.get("split") == split and root.get(rail_key, {}).get("pane") == rail:
        return root[content_key]
    return None


def seeded_position(edge):
    """kv.json seed that makes `edge` the default position for new rails (bottom is the built-in default)."""
    if edge == DEFAULT_EDGE:
        return None
    preferences = {"schema": 4, "enabled": False, "backlogAfterSeconds": 0,
                   "defaults": {"position": edge, "shares": {"left": {}, "bottom": {}, "right": {}}, "hidden": {}},
                   "instances": {}, "uiByWindow": {}}
    return {f"plugin-data/{PLUGIN}/kv.json": json.dumps({"preferences": preferences}).encode()}


def build(T, ops):
    panes = [T.lua_json("return { p = cx.session:focused() }")["p"]]
    for op in ops:
        if op[0] == "split":
            known = {p["pane"] for p in pane_rows(T)}
            for attempt in range(6):
                try:
                    new = T.lua_json(f"return {{ p = cx.layout:split({panes[op[1]]}, '{op[2]}', {{}}, {{ focus = false }}) }}")["p"]
                    break
                except nh.LuaError as error:
                    # Tern aborts a Carly call that runs past 50 ms (CPU load); the split may or may not have landed, so look
                    # for exactly one new pane before trying again (never create a second one).
                    if "slice budget" not in str(error):
                        raise
                    time.sleep(0.3)
                    fresh = {p["pane"] for p in pane_rows(T)} - known
                    if len(fresh) == 1:
                        new = fresh.pop()
                        break
                    if fresh:
                        raise nh.HarnessError(f"split left {len(fresh)} new panes after a slice-budget abort")
            else:
                raise nh.HarnessError("split kept exceeding the 50 ms slice budget")
            panes.append(new)
        else:
            ok = T.lua_json(f"local a, b = cx.layout:float({panes[op[1]]}) return {{ ok = a, why = b }}")
            if not ok["ok"]:
                raise nh.HarnessError(f"float failed: {ok}")
    return panes


def placed_state(T, tab, before, edge=DEFAULT_EDGE):
    """(placed, facts). Placed = one rail, canonical outer rail on `edge`, content untouched, no unfinished placement record."""
    rails = [item for item in rail_canvases(T) if str(item["about"]).endswith(f":{tab}")]
    lay = layout_of(T, tab)
    root = lay["root"]
    facts = {"rails": [item["pane"] for item in rails], "rootSplit": root.get("split"), "rootRatio": root.get("ratio")}
    record = placement_record(T, tab) or {}
    facts["placement"] = (record.get("placement") or {}).get("status")
    facts["placementReason"] = (record.get("placement") or {}).get("reason")
    canonical = False
    if len(rails) == 1:
        content = rail_content(root, rails[0]["pane"], edge)
        if content is not None:
            canonical = canon(content) == canon(before["root"]) and float_key(lay["floats"]) == float_key(before["floats"])
    facts["canonical"] = canonical
    facts["focus"] = lay.get("focus")
    return canonical and facts["placement"] is None, facts, lay


def keep_shot(T, name):
    """Screenshot into the instance, then copy it out so it outlives the temporary root."""
    source = Path(T.shot(name))
    SHOT_DIR.mkdir(parents=True, exist_ok=True)
    target = SHOT_DIR / f"{name}.png"
    target.write_bytes(source.read_bytes())
    return str(target)


def place_with_nudges(T, tab, before, natural_wait=8.0, nudge_every=5.0, max_nudges=3, budget=40.0, edge=DEFAULT_EDGE):
    """Wait for the canonical rail. Placement normally completes in ~1 s; when the plugin's own timer chain stalls
    (observed headless: passes frozen, placement record stuck at "placing") `Attention: Open` is issued after
    `natural_wait` and every `nudge_every` s. Returns (placedAt|None, firstNudgeAt|None, nudges, facts, layout)."""
    started = time.monotonic()
    nudges, first_nudge, last_nudge = 0, None, None
    facts, lay, settled = {}, None, None
    while time.monotonic() - started < budget:
        T.pump()
        ok, facts, lay = placed_state(T, tab, before, edge)
        elapsed = time.monotonic() - started
        if ok:
            return round(elapsed, 2), first_nudge, nudges, facts, lay
        if facts.get("placement") == "failed":
            return None, first_nudge, nudges, facts, lay
        if facts.get("placement") is None and len(facts.get("rails", [])) == 1 and not facts.get("canonical"):
            settled = settled if settled is not None else elapsed
            if elapsed - settled >= 4.0:  # one rail, no placement record, not canonical: a settled (degraded) outcome
                return None, first_nudge, nudges, facts, lay
        else:
            settled = None
        due = elapsed >= natural_wait and (last_nudge is None or elapsed - last_nudge >= nudge_every)
        if due and nudges < max_nudges:
            T.run_action(OPEN, check=False)
            nudges, last_nudge = nudges + 1, elapsed
            first_nudge = first_nudge if first_nudge is not None else round(elapsed, 2)
        time.sleep(0.2)
    return None, first_nudge, nudges, facts, lay


def j1_class(package, name, ops, width, height, log, edge=DEFAULT_EDGE):
    with new_instance(package, seed_files=seeded_position(edge), width=width, height=height) as T:
        tab = T.tabs()[0]["id"]
        panes = build(T, ops)
        before = layout_of(T, tab)
        focus_before = focused(T)
        T.run_action(ENABLE)
        placed_at, first_nudge, nudges, facts, lay = place_with_nudges(T, tab, before, edge=edge)
        time.sleep(3.0)  # drift check: placement must stay put
        ok_after, facts_after, lay_after = placed_state(T, tab, before, edge)
        diag = diagnostics(T)
        instance = (diag.get("instances") or [{}])[0]
        shot = keep_shot(T, f"j1-{edge}-{name}-{width}x{height}")
        rail_count_all = len(rail_canvases(T))
        content_after = rail_content(lay_after["root"], facts_after["rails"][0], edge) if len(facts_after["rails"]) == 1 else None
        result = {
            "edge": edge, "class": name, "viewport": f"{width}x{height}", "panes": len(panes),
            "placedAtSeconds": placed_at, "firstNudgeAtSeconds": first_nudge, "nudges": nudges,
            "stableAfter3s": ok_after, "railsInTab": facts_after["rails"], "railsInWindow": rail_count_all,
            "rootSplit": facts_after["rootSplit"], "rootRatio": facts_after["rootRatio"],
            "contentRatiosBefore": ratios(before["root"]), "contentRatiosAfter": ratios(content_after) if content_after else None,
            "focusBefore": focus_before, "focusAfter": focused(T), "layoutFocusAfter": lay_after.get("focus"),
            "focusUnchanged": focus_before == focused(T) == lay_after.get("focus"),
            "floatsBefore": float_key(before["floats"]), "floatsAfter": float_key(lay_after["floats"]),
            "contentBefore": canon(before["root"]), "contentAfter": canon(content_after) if content_after else None,
            "placementRecord": facts_after["placement"], "placementReason": facts_after["placementReason"],
            "phase": instance.get("phase"), "status": instance.get("status"), "diagStatus": diag.get("status"),
            "availability": diag.get("availability", {}).get("state"),
            "layoutWrites": (diag.get("counters") or {}).get("layoutWrites"), "errors": (diag.get("counters") or {}).get("errors"),
            "railText": (surface_text(T) or "")[:240], "shot": shot,
            "warnings": T.plugin_warnings()[-3:],
        }
        degraded = name in DEGRADED_BY_DESIGN
        ratio = facts_after["rootRatio"]
        result["railShare"] = None if ratio is None else round(ratio if edge == "left" else 1 - ratio, 4)
        result["limitedByMinimum"] = MINIMUM_REASON in str(result["status"])
        if degraded:
            result["pass"] = bool(placed_at is None and "Too many panes" in str(result["status"]) and len(facts_after["rails"]) == 1
                                  and result["focusUnchanged"] and rail_count_all == 1)
            result["expected"] = "degraded: " + DEGRADED_BY_DESIGN[name]
        else:
            # Placed (canonical outer rail, content identity/axes/order and floats intact, stable for 3 s), either
            # clean or degraded by the native minimum with that exact status; never a sliver.
            result["pass"] = bool(placed_at is not None and ok_after and len(facts_after["rails"]) == 1
                                  and result["focusUnchanged"] and rail_count_all == 1
                                  and (result["status"] == "Ready in this tab" or result["limitedByMinimum"])
                                  and result["railShare"] is not None and result["railShare"] >= MIN_RAIL_SHARE)
        result["outcome"] = "pass" if result["pass"] else "fail"
        log(f"- **{name}** [{edge}] {width}x{height}: {result['outcome'].upper()} placed@{placed_at}s "
            f"(nudges {nudges}, first at {first_nudge}s) phase={result['phase']} status={result['status']!r} "
            f"ratio={result['rootRatio']} focusUnchanged={result['focusUnchanged']} shot={shot}")
        return result


def j1(package, log, viewports=((1280, 800), (700, 400)), classes=None, edges=(DEFAULT_EDGE,)):
    log("## J1 geometry")
    results = []
    for edge in edges:
        for width, height in viewports:
            names = classes or list(CLASSES)
            if (width, height) == (700, 400) and classes is None:
                names = ["single", "two-side-by-side", "grid-2x2", "single-plus-float", "four-in-a-row", "five-in-a-row"]
            for name in names:
                for attempt in range(3):
                    try:
                        results.append(j1_class(package, name, CLASSES[name], width, height, log, edge))
                        break
                    except nh.LuaError as error:
                        # Building the tab (not the plugin) hit Tern's 50 ms Carly slice budget under CPU load: a fresh instance redoes it.
                        if "slice budget" not in str(error) or attempt == 2:
                            raise
                        log(f"- NOTE J1 {name} [{edge}] {width}x{height}: harness build hit the 50 ms slice budget; retrying on a fresh instance")
    outcomes = [item["outcome"] for item in results]
    return {"journey": "J1", "pass": "fail" not in outcomes, "outcomes": {key: outcomes.count(key) for key in sorted(set(outcomes))},
            "results": results}



# ---------------------------------------------------------------------------------------------
# Shared world + UI helpers (J2-J5)
# ---------------------------------------------------------------------------------------------

SESSIONS = ("alpha", "bravo", "charlie", "delta", "echo", "foxtrot")
PAGER = re.compile(r"(\d+)\u2013(\d+) of (\d+)")
GROUP = re.compile(r"^Go to \u00b7 (.+) \u00b7 (\d+) places?$")


class Checks:
    """Named assertions with their decisive evidence; the journey passes when every check passes."""

    def __init__(self, log, prefix):
        self.items, self.log, self.prefix = [], log, prefix

    def __call__(self, name, ok, evidence=None):
        ok = bool(ok)
        self.items.append({"check": f"{self.prefix}.{name}", "pass": ok, "evidence": evidence})
        self.log(f"- {'PASS' if ok else 'FAIL'} {self.prefix}.{name}: {json.dumps(evidence, default=str)[:700]}")
        return ok

    @property
    def passed(self):
        return all(item["pass"] for item in self.items)


def lua_retry(T, code, tries=4):
    """`lua_json` that retries Tern's 50 ms Carly slice budget (only raised before the call's effects are read)."""
    for attempt in range(tries):
        try:
            return T.lua_json(code)
        except nh.LuaError as error:
            if "slice budget" not in str(error) or attempt == tries - 1:
                raise
            time.sleep(0.2)


def sessions_of(T):
    return nh.as_list(lua_retry(T, "local o = {} for _, s in ipairs(cx.sessions:list()) do "
                                   "o[#o + 1] = { id = s.id, name = s.name, current = s.current == true } end return o"))


def pane_rows(T):
    rows = nh.as_list(lua_retry(T, "local o = {} for _, p in ipairs(cx.session:panes()) do o[#o + 1] = "
                                   "{ p.pane, p.tab or 0, p.kind or '?', p.floating and 1 or 0, p.parked and 1 or 0, p.title or '' } end return o"))
    return [{"pane": r[0], "tab": r[1] or None, "kind": r[2], "floating": bool(r[3]), "parked": bool(r[4]), "title": r[5]} for r in rows]


def current_session(T):
    current = [s for s in sessions_of(T) if s["current"]]
    return current[0]["name"] if current else None


def focus_pane(T, pane):
    lua_retry(T, f"cx.layout:focus({pane}) return {{ ok = true }}")


def build_world(T, sessions=SESSIONS, tabs_per_session=5):
    """~6 sessions / 30 shell tabs (unique cwd => unique titles) / 3 notes / 1 browser / 1 parked / 1 floating pane.
    The first tab of the first session stays a single shell: that is where the rail goes."""
    ws = T.root / "ws"
    ws.mkdir(exist_ok=True)

    def folder(label):
        path = ws / label
        path.mkdir(exist_ok=True)
        return json.dumps(str(path))

    world: dict = {"named": {}}
    first = lua_retry(T, "return { p = cx.session:focused() }")["p"]
    lua_retry(T, f"return {{ ok = cx.layout:rename_session(1, {json.dumps(sessions[0])}) }}")
    world["railPane"] = first
    world["railTab"] = lua_retry(T, f"return {{ t = cx.session:tab_of({first}) }}")["t"]
    for index, name in enumerate(sessions):
        if index > 0:
            for _ in range(4):
                with contextlib.suppress(nh.LuaError):
                    T.lua_json(f"return {{ s = cx.sessions:create({{ name = {json.dumps(name)}, cwd = {folder(name + '-t1')} }}) }}")
                if name in [s["name"] for s in sessions_of(T)]:
                    break
                time.sleep(0.3)
            else:
                raise nh.HarnessError(f"session {name} was not created")
        for have in range(2, tabs_per_session + 1):
            lua_retry(T, f"return {{ p = cx.layout:new_tab({{ cwd = {folder(f'{name}-t{have}')} }}) }}")
    for entry in sessions_of(T):
        victim = [tab for tab in T.tabs() if tab["session"] == entry["id"]][-1]["id"]
        label = f"Build {entry['name']}"
        lua_retry(T, f"cx.layout:name_tab({victim}, {json.dumps(label)}) return {{ ok = true }}")
        world["named"][victim] = label
    world["notes"] = [lua_retry(T, f"return {{ p = cx.docs:new_note('Note {n}', '# note {n}') }}")["p"] for n in (1, 2, 3)]
    owner = lua_retry(T, "return { p = cx.session:focused() }")["p"]
    T.lua_json(f"cx.browser:call({{ op = 'open', owner = {owner}, url = 'https://example.com/docs/page?q=1' }}):next(function() end) return {{ ok = true }}")
    T.wait_for(lambda: [p for p in pane_rows(T) if p["kind"] == "browser"], timeout=10, what="browser pane")
    first_alpha = [tab for tab in T.tabs() if tab["session"] == 1][1]["pane"]
    world["parked"] = lua_retry(T, f"return {{ p = cx.layout:split({first_alpha}, 'right', {{ cwd = {folder('parked-one')} }}, {{ focus = false }}) }}")["p"]
    lua_retry(T, f"local ok, why = cx.layout:park({world['parked']}) return {{ ok = ok, why = why }}")
    bravo = [s for s in sessions_of(T) if s["name"] == sessions[1]][0]["id"]
    second_bravo = [tab for tab in T.tabs() if tab["session"] == bravo][1]["pane"]
    world["floating"] = lua_retry(T, f"return {{ p = cx.layout:split({second_bravo}, 'down', {{ cwd = {folder('float-one')} }}, {{ focus = false }}) }}")["p"]
    lua_retry(T, f"local ok, why = cx.layout:float({world['floating']}) return {{ ok = ok, why = why }}")
    focus_pane(T, world["railPane"])
    world["browser"] = [p["pane"] for p in pane_rows(T) if p["kind"] == "browser"][0]
    return world


def nodes(T, selector):
    return T.tree(selector).get("nodes") or []


def ws_buttons(T):
    """Workspace row buttons in document order (the DOM holds the whole page, visible or scrolled out)."""
    return [n for n in nodes(T, "button") if str(n.get("title", "")).startswith(("Go to \u00b7 ", "Collapse \u00b7 ", "Expand \u00b7 "))]


def row_titles(T):
    return [n["title"] for n in ws_buttons(T)]


def page_button(T, label):
    found = [n for n in nodes(T, "button") if str(n.get("title", "")).startswith(label)]
    return found[0] if found else None


def find_page_button(T, label):
    """The Next/Previous page button. The pager is the last row of the bounded header group, so it is on screen at every
    scroll offset; None when the list really has no such button."""
    return page_button(T, label)


def pager_text(T):
    for node in nodes(T, "[data-role]"):
        match = PAGER.search(node.get("text", "") or "")
        if match:
            return match.group(0)
    return None


def pump_until(T, predicate, timeout=8.0, what="UI"):
    return T.wait_for(predicate, timeout=timeout, interval=0.25, what=what, pump=True)


def click_node(T, node, settle=2.0):
    """Click the node's center after its rectangle holds still for two reads. A rail shifts its rows by one status line when a
    transient notice appears or clears (observed at the bottom strip: a row moved 30 px between the tree read and the click),
    and a click that lands on the neighbouring row is a harness race, not a navigation result."""
    title, rect = node.get("title"), node["rect"]
    deadline = time.monotonic() + settle
    while title and time.monotonic() < deadline:
        T.pump()
        again = [n for n in nodes(T, "button") if n.get("title") == title]
        if not again:
            break
        if again[0]["rect"] == rect:
            break
        rect = again[0]["rect"]
        time.sleep(0.25)
    x, y, w, h = rect
    # Click near the left end of wide rows: native toasts (every Carly query raises one) are centred on the window bottom and
    # swallow clicks on the lowest rows of a bottom strip, and a floating pane can cover its right end.
    return T.ctl("click", f"{x + min(w / 2, 120):.1f}", f"{y + h / 2:.1f}")


def button_by_title(T, prefix):
    found = [n for n in nodes(T, "button") if str(n.get("title", "")).startswith(prefix)]
    return found[0] if found else None


def click_until(T, finder, effect, what, tries=3, timeout=4.0):
    """Click `finder()`'s node until `effect()` holds. A canvas ignores clicks until its first render bound its actions,
    so an early click can be lost; the effect is always checked before a retry, so a toggle is never double-fired."""
    last = None
    for _ in range(tries):
        node = finder()
        if node is None:
            time.sleep(0.3)
            T.pump()
            continue
        click_node(T, node)
        try:
            return pump_until(T, effect, timeout, what)
        except nh.WaitTimeout as error:
            last = error
    raise last or nh.WaitTimeout(f"{what}: target never appeared")


def region(T):
    """(top, bottom) of the scrolling list area: below the bounded header, above the pager."""
    surface = nodes(T, "[data-surface]")[0]["rect"]
    sticky = [n for n in nodes(T, "[data-role]") if re.match(r"Attention\d+Later\d+Currently working\d+Workspace", str(n.get("text", "")))
              and abs(n["rect"][1] - surface[1]) < 3 and n["rect"][3] < 400]
    top = min(n["rect"][1] + n["rect"][3] for n in sticky) if sticky else surface[1]
    bottom = surface[1] + surface[3]
    return top, bottom


def is_visible(T, node):
    top, bottom = region(T)
    return node["rect"][1] >= top and node["rect"][1] + node["rect"][3] <= bottom

def at_top(T):
    """Scroll the rail's list back to its first row (rows scrolled above the list area are not in the tree)."""
    T.ctl("hover", "[data-surface]")
    T.wheel(0, -6000)
    T.pump()
    time.sleep(0.2)



def scroll_to(T, finder, limit=14):
    """Wheel over the rail until `finder()`'s row is fully inside the list area. Returns (wheels, node, hiddenBefore).
    A wheel step never exceeds 60 % of the list area, so a short bottom strip cannot be skipped over."""
    at_top(T)
    hidden_before = None
    top, bottom = region(T)
    delta = max(60, min(300, int((bottom - top) * 0.6)))
    for step in range(limit * max(1, 300 // delta)):
        node = finder()
        if node is not None:
            seen = is_visible(T, node)
            hidden_before = (not seen) if hidden_before is None else hidden_before
            if seen:
                return step, node, hidden_before
        T.wheel(0, delta)
        T.pump()
        time.sleep(0.15)
    raise nh.WaitTimeout("row never scrolled into view")


def overflowing_rows(T):
    """Leaf rows whose wrapped context line lies below the row box (it paints over the next row). Every context line is
    owned by the nearest row button at or above it; on a healthy row it sits on the title's line (~1 px below the row top)."""
    buttons = [n for n in ws_buttons(T) if n["title"].startswith("Go to \u00b7 ") and not GROUP.match(n["title"])]
    lines = [n for n in nodes(T, "[data-role]") if "gap-xs wrap" in str(n.get("class", "")) and n.get("text")]
    bad = []
    for line in lines:
        lx, ly = line["rect"][0], line["rect"][1]
        owners = [b for b in buttons if b["rect"][1] <= ly + 0.5 and b["rect"][0] <= lx <= b["rect"][0] + b["rect"][2]]
        if not owners:
            continue
        owner = max(owners, key=lambda b: b["rect"][1])
        line_bottom, row_bottom = ly + line["rect"][3], owner["rect"][1] + owner["rect"][3]
        if line_bottom > row_bottom + 1:
            bad.append({"row": owner["title"], "context": line["text"], "rowBottom": row_bottom, "contextBottom": line_bottom})
    return bad


def rail_ready(T, rail_tab):
    """Wait until the rail has rendered its mode buttons and utility row (actions are bound only after that)."""
    def ready():
        return (button_by_title(T, "Attention \u00b7") is not None and button_by_title(T, "Search") is not None
                and (button_by_title(T, "More \u00b7") is not None or button_by_title(T, "Return to") is not None))
    pump_until(T, ready, 10, "rail rendered")


def enable_and_place(T, world):
    tab = world["railTab"]
    before = layout_of(T, tab)
    T.run_action(ENABLE)
    placed_at, first_nudge, nudges, facts, _ = place_with_nudges(T, tab, before, edge=RUN["edge"])
    if placed_at is not None:
        rail_ready(T, tab)
    return {"placedAt": placed_at, "nudges": nudges, "facts": facts, "rail": (facts.get("rails") or [None])[0]}


def show_workspace(T):
    click_until(T, lambda: page_button_text(T, "Workspace"),
                lambda: any(t.startswith("Collapse \u00b7 ") for t in row_titles(T)), "Workspace section")


def page_button_text(T, text):
    found = [n for n in nodes(T, "button") if n.get("text") == text]
    return found[0] if found else None


def goto_page(T, label):
    """Click Next/Previous page and wait for the page indicator (`41–50 of 50 rows`) to change."""
    before = pager_text(T)
    click_until(T, lambda: find_page_button(T, label), lambda: pager_text(T) not in (None, before), f"{label} page indicator")


def collect_pages(T):
    """Every Workspace row across all pages, starting from page 1; returns (rows, pages)."""
    while find_page_button(T, "Previous page") is not None:
        goto_page(T, "Previous page")
    rows, pages = [], 0
    while True:
        pages += 1
        # the tree only lists rows near the visible window: read at the top, then while scrolling to the bottom, and
        # merge (titles are unique within one page; the pager is pinned in the header, so it needs no scrolling)
        seen = {}
        at_top(T)
        for node in ws_buttons(T):
            seen.setdefault(node["title"], {"title": node["title"], "text": node.get("text"), "page": pages})
        T.ctl("hover", "[data-surface]")
        for _ in range(8):
            T.wheel(0, 600)
            T.pump()
            time.sleep(0.15)
            for node in ws_buttons(T):
                seen.setdefault(node["title"], {"title": node["title"], "text": node.get("text"), "page": pages})
        nxt = find_page_button(T, "Next page")
        rows.extend(seen.values())
        if nxt is None:
            return rows, pages
        goto_page(T, "Next page")


def park_hand(T):
    return T.state()["park"]["hand"]


def title_to_pane(panes, title):
    found = [p for p in panes if p["title"] == title]
    return found[0]["pane"] if len(found) == 1 else None


def row_title(button_title):
    return button_title.split(" \u00b7 ")[1]


def sorted_tabs(T):
    return sorted((tab["id"], tab["session"]) for tab in T.tabs())


def world_state(T):
    """Everything an inert action must not change."""
    return {"focused": focused(T), "session": current_session(T), "tabs": sorted_tabs(T),
            "panes": sorted((p["pane"], p["tab"], p["parked"], p["floating"]) for p in pane_rows(T))}


# ---------------------------------------------------------------------------------------------
# J2 workspace list
# ---------------------------------------------------------------------------------------------

def last_leaf_row(T):
    rows = [n for n in ws_buttons(T) if n["title"].startswith("Go to \u00b7 ")]
    return rows[-1] if rows else None


def j2(package, log):
    log("## J2 workspace list (1280x600)")
    check = Checks(log, "J2")
    with world_instance(package, 1280, 600) as T:
        started = time.monotonic()
        world = build_world(T)
        panes, tabs, sessions = pane_rows(T), T.tabs(), sessions_of(T)
        kinds = {}
        for pane in panes:
            kinds[pane["kind"]] = kinds.get(pane["kind"], 0) + 1
        check("world", len(sessions) == 6 and len(tabs) >= 30 and kinds.get("file") == 3 and kinds.get("browser") == 1
              and sum(p["parked"] for p in panes) == 1 and sum(p["floating"] for p in panes) == 2,
              {"sessions": len(sessions), "tabs": len(tabs), "panes": len(panes), "kinds": kinds,
               "parked": sum(p["parked"] for p in panes), "floating": sum(p["floating"] for p in panes),
               "buildSeconds": round(time.monotonic() - started, 1)})
        placed = enable_and_place(T, world)
        check("rail-placed", placed["placedAt"] is not None, {"seconds": placed["placedAt"], "rail": placed["rail"]})
        rail = placed["rail"]
        destinations = [p for p in pane_rows(T) if p["pane"] != rail]
        rail_title = [p["title"] for p in panes if p["pane"] == world["railPane"]][0]
        # The location line belongs to Workspace alone: Attention (the first-ever mode) shows none, and an empty list shows no text.
        attention_text = surface_text(T) or ""
        check("no-location-line-outside-workspace",
              button_by_title(T, "Reveal in Workspace") is None and "No current" not in attention_text,
              {"revealButton": (button_by_title(T, "Reveal in Workspace") or {}).get("title"), "surfaceText": attention_text[:200]})
        keep_shot(T, "j2-attention")
        show_workspace(T)
        pump_until(T, lambda: button_by_title(T, "Reveal in Workspace") is not None or "No current location" in (surface_text(T) or ""), 8, "location line")
        keep_shot(T, "j2-workspace-p1")
        blank = "No current location" in (surface_text(T) or "")
        reveal = button_by_title(T, "Reveal in Workspace")
        check("location-workspace-mode", reveal is not None and reveal["title"] == f"Reveal in Workspace \u00b7 {rail_title} \u00b7 alpha",
              {"title": reveal and reveal["title"], "expected": f"{rail_title} \u00b7 alpha"})
        check("location-line-survives-rail-click", not blank,
              {"focusedPaneIsRail": focused(T) == rail, "lineReadsNoCurrentLocation": blank,
               "note": "clicking inside the rail focuses the rail pane; the location line then goes blank until a content pane is focused"})
        focus_pane(T, world["railPane"])
        pump_until(T, lambda: button_by_title(T, "Reveal in Workspace") is not None, 8, "location line")
        reveal = button_by_title(T, "Reveal in Workspace")
        check("location-after-refocus", reveal is not None and rail_title in reveal["title"] and reveal["title"].endswith("alpha"),
              {"title": reveal and reveal["title"]})

        rows, pages = collect_pages(T)
        titles = [r["title"] for r in rows]
        groups = {}
        for title in titles:
            match = GROUP.match(title)
            if match:
                groups[match.group(1)] = int(match.group(2))
        leaves = [t for t in titles if t.startswith("Go to \u00b7 ") and not GROUP.match(t)]
        tab_session = {tab["id"]: tab["session"] for tab in tabs}
        session_name = {s["id"]: s["name"] for s in sessions}
        expected, per_tab = {}, {}
        for pane in destinations:
            if pane["tab"] is None:
                continue
            name = session_name[tab_session[pane["tab"]]]
            expected[name] = expected.get(name, 0) + 1
            per_tab[pane["tab"]] = per_tab.get(pane["tab"], 0) + 1
        tab_title = {tab["id"]: tab["title"] for tab in tabs}
        for tab_id, count in per_tab.items():
            # a named tab is always a group; an unnamed tab is a group only when it holds more than one place
            label = world["named"].get(tab_id) or (tab_title[tab_id] if count > 1 else None)
            if label:
                expected[label] = expected.get(label, 0) + count
        check("group-rows-typed-counts", groups == expected,
              {"rendered": groups, "expectedFromNative": expected, "pages": pages, "rows": len(rows)})
        parked_row = [r for r in rows if r["title"] in ("Collapse \u00b7 Parked", "Expand \u00b7 Parked")]
        check("parked-section-count", len(parked_row) == 1 and "1 place" in str(parked_row[0]["text"]), parked_row)
        floating_rows = [t for t in leaves if t.endswith("\u00b7 Floating")]
        parked_rows = [t for t in leaves if t.endswith("\u00b7 Parked")]
        note_rows = [t for t in leaves if t.endswith("\u00b7 Note")]
        check("every-destination-listed-once", len(leaves) == len(destinations),
              {"leafRows": len(leaves), "nativeDestinations": len(destinations)})
        check("markers", len(floating_rows) == 2 and len(parked_rows) == 1 and len(note_rows) == 3,
              {"floating": floating_rows, "parked": parked_rows, "notes": len(note_rows)})

        while find_page_button(T, "Previous page") is not None:
            goto_page(T, "Previous page")
        bad = overflowing_rows(T)
        check("row-text-stays-inside-row", not bad, {"overflowingLeafRows": bad,
              "note": "context line wraps below the row box and paints over the next row" if bad else None})

        # wheel to the last row of page 1, click it
        at_top(T)
        wheels, node, hidden_before = scroll_to(T, lambda: last_leaf_row(T))
        target_title = row_title(node["title"])
        target = title_to_pane(destinations, target_title)
        click_node(T, node)
        try:
            pump_until(T, lambda: focused(T) == target, 6, "focus last page-1 row")
        except nh.WaitTimeout:
            pass
        check("wheel-reaches-last-row-page-1-and-click-focuses", hidden_before and wheels > 0 and target is not None and focused(T) == target,
              {"row": node["title"], "wheels": wheels, "hiddenBeforeWheel": hidden_before, "expectedPane": target, "focused": focused(T)})
        focus_pane(T, world["railPane"])
        rail_ready(T, world["railTab"])

        # page 2: the last row is the parked pane; clicking must open the native chooser and relocate nothing
        goto_page(T, "Next page")
        T.ctl("hover", "[data-surface]")
        wheels2, node2, hidden2 = scroll_to(T, lambda: last_leaf_row(T))
        keep_shot(T, "j2-workspace-p2")
        before = world_state(T)
        click_node(T, node2)
        opened = False
        for _ in range(20):
            if park_hand(T)["open"]:
                opened = True
                break
            time.sleep(0.25)
        keep_shot(T, "j2-parked-chooser")
        after = world_state(T)
        parked_now = [p for p in pane_rows(T) if p["pane"] == world["parked"]][0]
        check("last-row-is-parked-and-click-does-not-relocate",
              node2["title"].endswith("\u00b7 Parked") and opened and parked_now["parked"] and parked_now["tab"] is None and after == before,
              {"row": node2["title"], "wheels": wheels2, "hiddenBeforeWheel": hidden2, "chooserOpen": opened,
               "parkedPane": parked_now, "worldUnchanged": after == before})
        T.key("esc")
        time.sleep(0.5)
        check("parked-chooser-dismissed-pane-still-parked",
              not park_hand(T)["open"] and [p for p in pane_rows(T) if p["pane"] == world["parked"]][0]["parked"], park_hand(T))
        # last non-parked row: the floating browser; focus it without docking
        browser_row = button_by_title(T, "Go to \u00b7 example.com")
        click_node(T, browser_row)
        try:
            pump_until(T, lambda: focused(T) == world["browser"], 6, "focus browser row")
        except nh.WaitTimeout:
            pass
        browser_now = [p for p in pane_rows(T) if p["pane"] == world["browser"]][0]
        check("floating-row-focuses-without-docking", focused(T) == world["browser"] and browser_now["floating"],
              {"row": browser_row["title"], "focused": focused(T), "browser": browser_now, "session": current_session(T)})
        focus_pane(T, world["railPane"])
        rail_ready(T, world["railTab"])

        # collapse a group, persist across a plugin reload
        while find_page_button(T, "Previous page") is not None:
            goto_page(T, "Previous page")
        at_top(T)
        rows_before = len(ws_buttons(T))
        click_until(T, lambda: scroll_find(T, "Collapse \u00b7 bravo"), lambda: button_by_title(T, "Expand \u00b7 bravo") is not None, "collapse bravo")
        at_top(T)
        rows_after = len(ws_buttons(T))
        keep_shot(T, "j2-collapsed")
        time.sleep(0.5)
        ui = (((T.kv(PLUGIN) or {}).get("preferences") or {}).get("uiByWindow") or {})
        bravo_id = [s["id"] for s in sessions if s["name"] == "bravo"][0]
        check("collapse-toggles-and-is-persisted", rows_after < rows_before and any(f"#{bravo_id}" in key for entry in ui.values() for key in (entry.get("collapsed") or {})),
              {"buttonsBefore": rows_before, "buttonsAfter": rows_after, "uiByWindow": ui})
        T.ctl("plugins", "fixtures")
        T.wait_for(T._plugins_loaded, timeout=30, interval=0.3, what="plugin reload")
        nudged = False
        try:
            pump_until(T, lambda: button_by_title(T, "Expand \u00b7 bravo") is not None, 8, "collapsed group after reload")
        except nh.WaitTimeout:
            T.run_action(OPEN, check=False)
            nudged = True
            pump_until(T, lambda: button_by_title(T, "Expand \u00b7 bravo") is not None, 12, "collapsed group after reload + open")
        at_top(T)
        keep_shot(T, "j2-after-reload")
        check("collapse-survives-plugin-reload", button_by_title(T, "Expand \u00b7 bravo") is not None and button_by_title(T, "Collapse \u00b7 alpha") is not None,
              {"openNeeded": nudged, "titles": row_titles(T)[:12]})
    return {"journey": "J2", "pass": check.passed, "checks": check.items}


# ---------------------------------------------------------------------------------------------
# J3 search
# ---------------------------------------------------------------------------------------------

def open_search_via_palette(T):
    """Show all commands -> type the command -> Enter; returns the palette's option texts."""
    lua_retry(T, "cx.actions:run('show_commands') return { ok = true }")
    T.wait_for(lambda: T.state()["palette"] is not None, timeout=6, interval=0.2, what="command palette")
    T.type("Attention: Search workspace")
    time.sleep(0.4)
    options = [n.get("text") for n in nodes(T, "[role=option]")]
    T.key("enter")
    T.wait_for(lambda: T.state()["picker"], timeout=8, interval=0.25, what="search picker")
    return options


def open_search_via_action(T):
    lua_retry(T, f"cx.actions:run('{SEARCH}') return {{ ok = true }}")
    T.wait_for(lambda: T.state()["picker"], timeout=8, interval=0.25, what="search picker")


def picker_labels(T, limit=300):
    labels = []
    for _ in range(limit):
        selected = T.state()["picker"]["selected"]
        if selected in labels:
            break
        labels.append(selected)
        T.ctl("picker", "down")
    return labels


def j3(package, log):
    log("## J3 search")
    check = Checks(log, "J3")
    with world_instance(package, 1280, 600) as T:
        world = build_world(T)
        placed = enable_and_place(T, world)
        check("rail-placed", placed["placedAt"] is not None, {"seconds": placed["placedAt"]})
        rail = placed["rail"]
        listed = lua_retry(T, "local o = {} for _, a in ipairs(cx.actions:list()) do if a.plugin == 'attention' and string.find(a.label or '', 'Search') then "
                              "o[#o + 1] = { a.id, a.label } end end return o")
        check("action-id", nh.as_list(listed) == [[SEARCH, "Attention: Search workspace"]], listed)
        panes = [p for p in pane_rows(T) if p["pane"] != rail]
        sessions, tabs = sessions_of(T), T.tabs()
        expected_items = len(panes) + len(sessions) + len(world["named"])
        options = open_search_via_palette(T)
        picker = T.state()["picker"]
        check("opened-through-command-palette", "Attention: Search workspace" in options and picker["mode"] == "pick",
              {"paletteOptions": options, "picker": picker})
        labels = picker_labels(T)
        every_title = [p["title"] for p in panes if not any(p["title"] in label for label in labels)]
        check("lists-every-destination",
              picker["rows"] == expected_items == len(labels) and not every_title and not any(label.startswith("Attention") for label in labels),
              {"pickerRows": picker["rows"], "walked": len(labels), "expected": f"{len(panes)} panes + {len(sessions)} sessions + {len(world['named'])} named tabs = {expected_items}",
               "titlesMissingFromItems": every_title, "railListed": any(label.startswith("Attention") for label in labels)})
        T.ctl("picker", "esc")
        # typing narrows; Enter focuses exactly the selected pane
        open_search_via_action(T)
        T.type("foxtrot")
        time.sleep(0.4)
        narrowed = T.state()["picker"]["rows"]
        T.type("-t3")
        time.sleep(0.4)
        exact = T.state()["picker"]
        target = title_to_pane(panes, "foxtrot-t3")
        T.key("enter")
        try:
            pump_until(T, lambda: focused(T) == target, 8, "focus search result")
        except nh.WaitTimeout:
            pass
        check("typing-narrows-and-enter-focuses-exact-pane",
              0 < narrowed < expected_items and exact["rows"] == 1 and focused(T) == target and current_session(T) == "foxtrot",
              {"afterFoxtrot": narrowed, "afterFoxtrotT3": exact, "expectedPane": target, "focused": focused(T), "session": current_session(T)})
        focus_pane(T, world["railPane"])
        # Escape changes nothing
        before = world_state(T)
        open_search_via_action(T)
        T.type("bravo")
        time.sleep(0.3)
        T.ctl("picker", "esc")
        time.sleep(0.5)
        for _ in range(6):
            T.pump()
            time.sleep(0.25)
        after = world_state(T)
        check("escape-changes-nothing", T.state()["picker"] is None and after == before,
              {"focusedBefore": before["focused"], "focusedAfter": after["focused"], "sessionBefore": before["session"], "sessionAfter": after["session"],
               "worldUnchanged": after == before})
        # a parked destination found by search must not be relocated
        open_search_via_action(T)
        T.type("parked-one")
        time.sleep(0.4)
        hit = T.state()["picker"]
        before = world_state(T)
        T.key("enter")
        opened = False
        for _ in range(20):
            if park_hand(T)["open"]:
                opened = True
                break
            time.sleep(0.25)
        parked_now = [p for p in pane_rows(T) if p["pane"] == world["parked"]][0]
        check("search-result-parked-is-not-relocated", opened and parked_now["parked"] and parked_now["tab"] is None and world_state(T) == before,
              {"picker": hit, "chooserOpen": opened, "parkedPane": parked_now})
        T.key("esc")
    return {"journey": "J3", "pass": check.passed, "checks": check.items}


# ---------------------------------------------------------------------------------------------
# J4 recovery / no native writes
# ---------------------------------------------------------------------------------------------

SETTINGS_LUA = """
local all = cx.settings:list()
local keys = {}
for key in pairs(all) do keys[#keys + 1] = key end
table.sort(keys)
local out = {}
for index = %d, math.min(%d, #keys) do
  local key = keys[index]
  local ok, encoded = pcall(tern.json.encode, all[key])
  encoded = if ok then encoded else tostring(all[key])
  out[#out + 1] = { key, string.sub(encoded, 1, 100), #encoded }
end
return { n = #keys, rows = out }
"""


def settings_snapshot(T, step=40):
    """Every effective preference leaf (key -> [first 100 chars, encoded length])."""
    rows, total, start = {}, None, 1
    while total is None or start <= total:
        chunk = lua_retry(T, SETTINGS_LUA % (start, start + step - 1))
        total = chunk["n"]
        for key, head, size in nh.as_list(chunk["rows"]):
            rows[key] = [head, size]
        start += step
    return rows


def j4(package, log):
    log("## J4 recovery / no native writes")
    check = Checks(log, "J4")
    with world_instance(package, 1280, 600, settings={"tabs": "Vertical"}) as T:
        settings_path = T.config / "settings.json"
        bytes_before = settings_path.read_bytes()
        loaded = lua_retry(T, "return { tabs = cx.settings:get('tabs'), autohide = cx.settings:get('tabs_autohide') }")
        log(f"- FACT J4.seed-file: settings.json seeded with tabs=Vertical; effective tabs at start = {loaded['tabs']!r} "
            f"(headless serve ignores preference keys in settings.json, so Vertical is applied in memory with cx.settings:set)")
        lua_retry(T, "cx.settings:set('tabs', 'Vertical') return { ok = true }")
        effective = lua_retry(T, "return { tabs = cx.settings:get('tabs'), autohide = cx.settings:get('tabs_autohide') }")
        check("vertical-tabs-effective", effective["tabs"] == "Vertical" and effective["autohide"] is False and T.state().get("tab_orientation") == "vertical",
              {"effective": effective, "tab_orientation": T.state().get("tab_orientation"), "fileSeedIgnored": loaded["tabs"] != "Vertical"})
        snap_before = settings_snapshot(T)
        world = build_world(T, sessions=SESSIONS[:3], tabs_per_session=3)
        placed = enable_and_place(T, world)
        check("rail-placed-with-vertical-tabs", placed["placedAt"] is not None, {"seconds": placed["placedAt"]})
        rail = placed["rail"]
        # the whole journey: workspace, collapse/expand, row click, palette search + Enter, parked chooser, reveal, new
        show_workspace(T)
        click_until(T, lambda: scroll_find(T, "Collapse \u00b7 bravo"), lambda: button_by_title(T, "Expand \u00b7 bravo") is not None, "collapse")
        time.sleep(1.0)  # a click right after the toggle's own repaint can be dropped while the rail is still reconciling
        T.pump()
        click_until(T, lambda: scroll_find(T, "Expand \u00b7 bravo"), lambda: button_by_title(T, "Collapse \u00b7 bravo") is not None, "expand")
        panes = [p for p in pane_rows(T) if p["pane"] != rail]
        target = title_to_pane(panes, "charlie-t2")
        click_until(T, lambda: scroll_find(T, "Go to \u00b7 charlie-t2"), lambda: focused(T) == target, "row click")
        focus_pane(T, world["railPane"])
        rail_ready(T, world["railTab"])
        open_search_via_palette(T)
        T.type("bravo-t2")
        time.sleep(0.4)
        T.key("enter")
        pump_until(T, lambda: focused(T) == title_to_pane(panes, "bravo-t2"), 8, "search focus")
        focus_pane(T, world["railPane"])
        rail_ready(T, world["railTab"])
        lua_retry(T, f"cx.actions:run('plugin.{PLUGIN}.reveal') return {{ ok = true }}")
        for _ in range(6):
            T.pump()
            time.sleep(0.25)
        snap_after = settings_snapshot(T)
        diff = {key: [snap_before.get(key), snap_after.get(key)] for key in set(snap_before) | set(snap_after) if snap_before.get(key) != snap_after.get(key)}
        bytes_after = settings_path.read_bytes()
        check("settings-json-unchanged", bytes_after == bytes_before, {"before": bytes_before.decode(), "after": bytes_after.decode()})
        check("no-effective-preference-changed", not diff, {"changed": diff, "leaves": len(snap_after),
              "tabs": snap_after.get("tabs"), "tabs_autohide": snap_after.get("tabs_autohide")})
        # disable: rails and native recovery
        canvases_before = rail_canvases(T)
        T.run_action(DISABLE)
        try:
            pump_until(T, lambda: ((T.kv(PLUGIN) or {}).get("preferences") or {}).get("enabled") is False, 10, "disable persisted")
        except nh.WaitTimeout:
            pass
        for _ in range(8):
            T.pump()
            time.sleep(0.25)
        canvases_after = rail_canvases(T)
        layouts = {tab["id"]: layout_of(T, tab["id"]) for tab in T.tabs() if tab["session"] == 1}
        live_panes = {p["pane"]: p for p in pane_rows(T)}
        records = ((T.kv(PLUGIN) or {}).get("preferences") or {}).get("instances") or {}
        placing = [entry for host in records.values() for entry in host.values() if entry.get("placement")]
        keep_shot(T, "j4-after-disable")
        dangling = [c for c in canvases_after if c["pane"] not in live_panes or live_panes[c["pane"]]["tab"] is None]
        check("disable-leaves-no-broken-canvas",
              ((T.kv(PLUGIN) or {}).get("preferences") or {}).get("enabled") is False and not dangling and not placing,
              {"canvasesBefore": len(canvases_before), "canvasesAfter": len(canvases_after), "dangling": dangling, "unfinishedPlacements": placing,
               "railTabLayout": layouts.get(world["railTab"]), "railText": (surface_text(T) or "")[-120:]})
        native = {}
        for name in ("show_commands", "switch_session", "new_tab", "focus_tabs"):
            try:
                native[name] = {"describe": lua_retry(T, f"return cx.actions:describe('{name}')")}
            except nh.HarnessError as error:
                native[name] = {"error": str(error)[:120]}
        tabs_before = len(T.tabs())
        lua_retry(T, "cx.actions:run('show_commands') return { ok = true }")
        palette = T.wait_for(lambda: T.state()["palette"] is not None, timeout=5, interval=0.2, what="palette after disable")
        T.key("esc")
        lua_retry(T, "cx.actions:run('switch_session') return { ok = true }")
        switcher = T.wait_for(lambda: T.state()["palette"] is not None or T.state()["picker"] is not None, timeout=5, interval=0.2, what="switch_session surface")
        T.key("esc")
        lua_retry(T, "cx.actions:run('new_tab') return { ok = true }")
        grew = T.wait_for(lambda: len(T.tabs()) == tabs_before + 1, timeout=6, interval=0.3, what="new tab after disable", pump=True)
        element_before = T.state().get("focused_element")
        lua_retry(T, "cx.actions:run('focus_tabs') return { ok = true }")
        time.sleep(0.6)
        element_after = T.state().get("focused_element")
        check("native-actions-work-after-disable",
              all("error" not in entry and entry["describe"].get("available") for entry in native.values()) and palette and switcher and grew,
              {"describe": {k: v.get("describe", v) for k, v in native.items()}, "paletteOpened": bool(palette), "switchSessionOpened": bool(switcher),
               "newTabAddedOne": bool(grew), "focusTabsFocusedElement": [element_before, element_after]})
        final = settings_snapshot(T)
        check("no-visibility-setting-after-disable", final.get("tabs_autohide") == snap_before.get("tabs_autohide") and final.get("tabs") == snap_before.get("tabs"),
              {"tabs": final.get("tabs"), "tabs_autohide": final.get("tabs_autohide")})
    return {"journey": "J4", "pass": check.passed, "checks": check.items}


def scroll_find(T, prefix):
    """The row button whose title starts with `prefix`, after scrolling it fully into the list area (None if absent)."""
    if button_by_title(T, prefix) is None:
        return None
    try:
        return scroll_to(T, lambda: button_by_title(T, prefix))[1]
    except nh.WaitTimeout:
        return None


# ---------------------------------------------------------------------------------------------
# J5 ownership / window
# ---------------------------------------------------------------------------------------------

def j5(package, log):
    log("## J5 ownership / window")
    check = Checks(log, "J5")
    foreign = {"preferences": {"schema": 4, "enabled": True, "owner": "window-that-is-not-this-one", "backlogAfterSeconds": 0,
                               "defaults": {"hidden": {}, "share": {}}, "instances": {}, "uiByWindow": {}}}
    if RUN["edge"] != DEFAULT_EDGE:
        foreign["preferences"]["defaults"]["position"] = RUN["edge"]
    with world_instance(package, 1280, 600, seed_files={f"plugin-data/{PLUGIN}/kv.json": json.dumps(foreign).encode()}) as T:
        key = lua_retry(T, "return { key = cx:window_key() }")["key"]
        check("headless-window-key", key == "", {"window_key": key})
        tab = T.tabs()[0]["id"]
        before = layout_of(T, tab)
        T.run_action(OPEN, check=False)
        for _ in range(12):
            T.pump()
            time.sleep(0.25)
        after = layout_of(T, tab)
        status = diagnostics(T)
        check("foreign-owner-does-nothing", not rail_canvases(T) and after == before,
              {"canvases": len(rail_canvases(T)), "layoutUnchanged": after == before, "status": status.get("status"),
               "availability": status.get("availability"), "owns": (status.get("availability") or {}).get("owns")})
        T.run_action(ENABLE)
        placed = place_with_nudges(T, tab, before, edge=RUN["edge"])
        owner = (((T.kv(PLUGIN) or {}).get("preferences") or {}).get("owner"))
        check("enable-takes-ownership-and-places", placed[0] is not None and owner == key,
              {"placedAt": placed[0], "ownerNow": owner})
    log("- NOT EXERCISED J5.second-window: headless serve has exactly one window (window_key ''); a second window, "
        "per-window `tabs_autohide` propagation and live-GUI ownership hand-off cannot be driven. The foreign-owner case above "
        "is simulated by seeding kv owner, not by a real second window.")
    return {"journey": "J5", "pass": check.passed, "checks": check.items,
            "notExercised": ["second window", "live GUI ownership hand-off", "per-window tabs_autohide"]}


def pager_geometry(T):
    """Where the pager and the bounded header sit, in window pixels, plus how much of the rail is left for the list."""
    surface = nodes(T, "[data-surface]")[0]["rect"]
    top, bottom = region(T)
    inside = lambda n: surface[0] <= n["rect"][0] <= surface[0] + surface[2] and surface[1] <= n["rect"][1] <= top  # noqa: E731
    toolbar = [n for n in nodes(T, "button") if inside(n) and str(n.get("title", "")).startswith(("Next attention", "Previous \u00b7", "Search", "More \u00b7", "Return to"))]
    queues = [n for n in nodes(T, "button") if inside(n) and any(str(n.get("title", "")).startswith(q) for q in ("Attention \u00b7", "Later \u00b7", "Currently working \u00b7", "Workspace \u00b7"))]
    nxt, prev = page_button(T, "Next page"), page_button(T, "Previous page")
    pager = nxt or prev
    visible_rows = [n for n in ws_buttons(T) if n["rect"][1] >= top and n["rect"][1] + n["rect"][3] <= bottom]
    return {"surface": surface, "headerBottom": top, "toolbarLines": sorted({round(n["rect"][1]) for n in toolbar}),
            "queueLines": sorted({round(n["rect"][1]) for n in queues}), "toolbarButtons": len(toolbar),
            "pagerRect": pager["rect"] if pager else None, "pagerText": pager_text(T), "next": nxt is not None, "prev": prev is not None,
            "listFraction": round((surface[1] + surface[3] - top) / surface[3], 3), "visibleRows": len(visible_rows)}


def j6(package, log):
    log(f"## J6 header-hosted pager ({RUN['edge']} rail)")
    check = Checks(log, "J6")
    with world_instance(package, 1280, 800) as T:
        world = build_world(T)
        placed = enable_and_place(T, world)
        check("rail-placed", placed["placedAt"] is not None, {"seconds": placed["placedAt"], "rail": placed["rail"]})
        show_workspace(T)
        pump_until(T, lambda: pager_text(T) is not None, 10, "pager text")
        at_top(T)
        top = pager_geometry(T)
        keep_shot(T, "j6-top")
        log(f"geometry at scroll top: {top}")
        pager = top["pagerRect"]
        check("pager-visible-at-scroll-top", pager is not None and top["next"] and not top["prev"]
              and pager[1] >= top["surface"][1] and pager[1] + pager[3] <= top["headerBottom"] + 0.5, top)
        check("toolbar-one-line", max(top["toolbarLines"]) - min(top["toolbarLines"]) <= 2 and len(top["queueLines"]) == 1, top)
        # A left rail is a tall column; a bottom/right strip is a fraction of the tab, so it only has to keep a few rows usable.
        tall = RUN["edge"] == "left"
        check("list-usable", top["listFraction"] >= (0.7 if tall else 0.5) and top["visibleRows"] >= (8 if tall else 3), top)
        T.ctl("hover", "[data-surface]")
        T.wheel(0, 900)
        T.pump()
        time.sleep(0.3)
        scrolled = pager_geometry(T)
        keep_shot(T, "j6-scrolled")
        check("pager-pinned-after-scroll", scrolled["pagerRect"] == top["pagerRect"] and scrolled["pagerText"] == top["pagerText"], scrolled)
        T.wheel(0, 6000)
        T.pump()
        time.sleep(0.3)
        bottom = pager_geometry(T)
        keep_shot(T, "j6-bottom")
        check("header-and-pager-pinned-at-list-bottom", bottom["pagerRect"] == top["pagerRect"] and bottom["toolbarButtons"] == top["toolbarButtons"]
              and bottom["headerBottom"] == top["headerBottom"], bottom)
        before = pager_text(T)
        goto_page(T, "Next page")
        second = pager_geometry(T)
        keep_shot(T, "j6-page2")
        check("next-page-reaches-end", pager_text(T) != before and second["prev"], {"before": before, "after": pager_text(T), "geometry": second})
        goto_page(T, "Previous page")
        check("previous-page-returns", pager_text(T) == before, {"text": pager_text(T)})
    return {"journey": "j6", "pass": check.passed}


# ---------------------------------------------------------------------------------------------
# Migration rehearsal (not part of `all`: it needs the real store)
# ---------------------------------------------------------------------------------------------

LIVE_KV = Path.home() / "Library/Application Support/Tern/plugin-data" / PLUGIN / "kv.json"


def deep_diff(left, right, path="$", limit=25):
    """Paths where two decoded JSON values differ (an empty list means semantically identical)."""
    if type(left) is not type(right):
        return [f"{path}: {type(left).__name__} vs {type(right).__name__}"]
    if isinstance(left, dict):
        out = [f"{path}.{key}: only on one side" for key in sorted(set(left) ^ set(right))]
        for key in sorted(set(left) & set(right)):
            out += deep_diff(left[key], right[key], f"{path}.{key}", limit)
            if len(out) >= limit:
                break
        return out[:limit]
    if isinstance(left, list):
        if len(left) != len(right):
            return [f"{path}: length {len(left)} vs {len(right)}"]
        out = []
        for index, (a, b) in enumerate(zip(left, right)):
            out += deep_diff(a, b, f"{path}[{index}]", limit)
            if len(out) >= limit:
                break
        return out[:limit]
    return [] if left == right else [f"{path}: {left!r} vs {right!r}"]


def overlapping_buttons(T):
    """Pairs of buttons visible in the rail's list region (clipped to it: the DOM also holds rows scrolled out of view)
    whose rectangles intersect by more than 1 px in both axes."""
    surface = nodes(T, "[data-surface]")[0]["rect"]
    top, bottom = region(T)
    boxes = []
    for node in nodes(T, "button"):
        x, y, w, h = node.get("rect") or (0, 0, 0, 0)
        y0, y1 = max(y, top), min(y + h, bottom)
        if w > 0 and y1 - y0 > 1 and surface[0] <= x < surface[0] + surface[2]:
            boxes.append((x, y0, x + w, y1, str(node.get("title"))[:50]))
    pairs = []
    for index, a in enumerate(boxes):
        for b in boxes[index + 1:]:
            if min(a[2], b[2]) - max(a[0], b[0]) > 1 and min(a[3], b[3]) - max(a[1], b[1]) > 1:
                pairs.append([a[4], b[4]])
    return pairs, len(boxes)


def load_and_settle(T, settle=6.0, mount=True):
    """Enable (and optionally mount), then pump for `settle` seconds and return the kv.json bytes once they stop changing."""
    T.run_action(ENABLE)
    if mount:
        T.mount_count(PLUGIN, 1, timeout=40)
    kv_path = T.config / "plugin-data" / PLUGIN / "kv.json"
    end = time.monotonic() + settle
    while time.monotonic() < end:
        T.pump()
        time.sleep(0.25)
    stable, last, since = None, None, time.monotonic()
    while time.monotonic() - since < 3.0:
        T.pump()
        time.sleep(0.5)
        current = kv_path.read_bytes()
        if current != last:
            last, since = current, time.monotonic()
    stable = last
    return kv_path, stable


def migration(package, log, kv=None):
    """Load a READ-ONLY copy of the real store into an isolated Tern: schema 4, triage unchanged, no orphan tmp files,
    second load writes nothing, saved conversations listed without overlapping rows. The copy lives only in the
    instance's temporary root (deleted on close)."""
    log("## Migration rehearsal (real-store copy)")
    check = Checks(log, "MIG")
    source = Path(kv) if kv else LIVE_KV
    original_bytes = source.read_bytes()
    original = json.loads(original_bytes)
    check("source-schemas", True, {"bytes": len(original_bytes), "preferencesSchema": original["preferences"].get("schema"),
                                   "triageSchema": original["triage"].get("schema"), "triageItems": len(original["triage"]["items"])})
    with new_instance(package, seed_files={f"plugin-data/{PLUGIN}/kv.json": original_bytes}, width=1280, height=800) as T:
        root = T.root
        kv_path, first_bytes = load_and_settle(T)
        after = json.loads(first_bytes)
        directory = sorted(item.name for item in kv_path.parent.iterdir())
        check("preferences-schema-4", after["preferences"].get("schema") == 4,
              {"before": original["preferences"].get("schema"), "after": after["preferences"].get("schema")})
        flagged = lambda prefs: sum(1 for host in prefs["instances"].values() for entry in host.values() if "relocate" in entry)  # noqa: E731
        check("relocate-stripped", flagged(original["preferences"]) > 0 and flagged(after["preferences"]) == 0,
              {"before": flagged(original["preferences"]), "after": flagged(after["preferences"]),
               "instances": sum(len(host) for host in after["preferences"]["instances"].values())})
        diff = deep_diff(original["triage"], after["triage"])
        check("triage-deep-diff-0", not diff, {"differences": diff, "items": len(after["triage"]["items"])})
        check("no-orphan-tmp-files", not [name for name in directory if name != "kv.json"], {"directory": directory})
        show_workspace(T)
        rail = surface_text(T) or ""
        saved = [n for n in nodes(T, "button") if str(n.get("title", "")).startswith("Collapse \u00b7 Saved conversations")]
        count = re.search(r"(\d+) saved", saved[0].get("text", "")) if saved else None
        check("saved-conversations-section", bool(count) and int(count.group(1)) == len(original["triage"]["items"]),
              {"section": saved[0].get("text") if saved else None, "expected": len(original["triage"]["items"])})
        surface = nodes(T, "[data-surface]")[0]["rect"]
        worst, buttons_seen, shots = [], 0, []
        at_top(T)
        T.ctl("hover", "[data-surface]")
        for step in range(7):
            pairs, seen = overlapping_buttons(T)
            worst += pairs
            buttons_seen += seen
            if step in (0, 3):
                shots.append(keep_shot(T, f"mig-workspace-{step}"))
            T.wheel(0, 500)
            T.pump()
            time.sleep(0.3)
        rows = [n for n in nodes(T, "button") if str(n.get("title", "")).startswith("Checking identity")]
        check("rows-not-overlapping", not worst and buttons_seen > 20,
              {"railWidth": surface[2], "overlaps": worst[:6], "buttonsInspected": buttons_seen, "savedRowsInTree": len(rows), "shots": shots})
        later = button_by_title(T, "Later \u00b7")
        check("queue-counts", "Later" in rail and later is not None, {"rail": rail[:120], "later": later and later.get("text")})
        check("no-plugin-errors", not [w for w in T.plugin_warnings() if "ERROR" in w], T.plugin_warnings()[-2:])
    check("temporary-copy-removed", not Path(root).exists(), {"root": str(root)})
    # Second load of the migrated store. The isolated window does not contain the real store's tabs, so their registry
    # entries are marked `retiring` on the first load and pruned only after ~30 s of sustained absence; the no-write
    # claim is therefore measured inside that window, and the pruning is shown to converge on a third load.
    with new_instance(package, seed_files={f"plugin-data/{PLUGIN}/kv.json": first_bytes}, width=1280, height=800) as T:
        kv_path = T.config / "plugin-data" / PLUGIN / "kv.json"
        stat_before = kv_path.stat().st_mtime_ns
        started = time.monotonic()
        _, second_bytes = load_and_settle(T, settle=2.0, mount=False)
        window = round(time.monotonic() - started, 1)
        check("second-load-no-write", second_bytes == first_bytes and kv_path.stat().st_mtime_ns == stat_before,
              {"bytesEqual": second_bytes == first_bytes, "mtimeUnchanged": kv_path.stat().st_mtime_ns == stat_before,
               "observedSeconds": window, "directory": sorted(item.name for item in kv_path.parent.iterdir())})
        while time.monotonic() - started < 45:
            T.pump()
            time.sleep(0.5)
        pruned_bytes = kv_path.read_bytes()
        pruned = json.loads(pruned_bytes)
        diff = deep_diff(json.loads(first_bytes), pruned)
        check("absent-registry-entries-pruned-only", all(item.startswith("$.preferences.instances.") for item in diff)
              and pruned["triage"] == json.loads(first_bytes)["triage"] and pruned["preferences"].get("schema") == 4,
              {"differences": len(diff), "sample": diff[:3]})
    with new_instance(package, seed_files={f"plugin-data/{PLUGIN}/kv.json": pruned_bytes}, width=1280, height=800) as T:
        kv_path = T.config / "plugin-data" / PLUGIN / "kv.json"
        stat_before = kv_path.stat().st_mtime_ns
        _, third_bytes = load_and_settle(T, settle=9.0, mount=False)
        check("third-load-no-write", third_bytes == pruned_bytes and kv_path.stat().st_mtime_ns == stat_before,
              {"bytesEqual": third_bytes == pruned_bytes, "mtimeUnchanged": kv_path.stat().st_mtime_ns == stat_before})
    return {"journey": "migration", "pass": check.passed, "checks": check.items}


# ---------------------------------------------------------------------------------------------
# Adoption: a store written before placement was per-tab, over rails that physically sit at bottom / right / left
# ---------------------------------------------------------------------------------------------

def tab_rail(T, tab):
    rails = [item for item in T.canvases(PLUGIN) if str(item["about"]).endswith(f":{tab}")]
    return rails[0]["pane"] if rails else None


def physical_edge(T, tab):
    rail = tab_rail(T, tab)
    if rail is None:
        return None
    root = layout_of(T, tab)["root"]
    return next((edge for edge in EDGES if rail_content(root, rail, edge) is not None), None)


def choose_position(T, tab, label, edge):
    """Use the Settings Placement control in `tab` (its rail must be visible) and wait for the physical result."""
    rail = tab_rail(T, tab)
    content = [p["pane"] for p in pane_rows(T) if p["tab"] == tab and p["pane"] != rail][0]
    focus_pane(T, content)
    for _ in range(6):
        T.pump()
        time.sleep(0.4)
    rail_ready(T, tab)
    if page_button_text(T, label) is None:
        click_until(T, lambda: button_by_title(T, "More \u00b7"), lambda: page_button_text(T, label) is not None, "settings open")
    # A rail that was hidden catches up on its next pass; headless timers only advance on input, so pump before every click.
    for _ in range(4):
        for _ in range(6):
            T.pump()
            time.sleep(0.4)
        click_node(T, page_button_text(T, label))
        try:
            T.wait_for(lambda: (placement_record(T, tab) or {}).get("position") == edge or physical_edge(T, tab) == edge,
                       timeout=6, interval=0.3, what="placement accepted", pump=True)
            break
        except nh.WaitTimeout:
            continue
    T.wait_for(lambda: physical_edge(T, tab) == edge, timeout=40, interval=0.5, what=f"rail at {edge}", pump=True)


def reload_plugin(T, edit=None):
    """Unload the plugin (native canvases stay), optionally rewrite its on-disk store, then load it again and run Open: what an
    upgrade of the installed package does to live rails. Tern keeps a loaded plugin's store in memory, so only a reload re-reads it."""
    link = T.root / "crates/plugins/fixtures" / PLUGIN
    target = link.resolve()
    link.unlink()
    T.ctl("plugins", "fixtures")
    for _ in range(8):
        T.pump()
        time.sleep(0.4)
    kv_path = T.config / "plugin-data" / PLUGIN / "kv.json"
    written = None
    if edit:
        store = json.loads(kv_path.read_text())
        edit(store)
        kv_path.write_text(json.dumps(store))
        written = kv_path.read_bytes()
    link.symlink_to(target, target_is_directory=True)
    T.ctl("plugins", "fixtures")
    T.wait_for(lambda: OPEN in T.plugin_actions(), timeout=30, interval=0.5, what="plugin reloaded", pump=True)
    T.run_action(OPEN, check=False)
    return kv_path, written


def settle_store(T, kv_path, quiet=4.0, limit=60.0, change_from=None):
    """Pump until kv.json stops changing for `quiet` seconds (and, with `change_from`, has first differed from those bytes);
    a stalled plugin is nudged with Open every 6 s. Returns the bytes."""
    last, since, started, nudged = kv_path.read_bytes(), time.monotonic(), time.monotonic(), time.monotonic()
    while time.monotonic() - started < limit:
        T.pump()
        time.sleep(0.5)
        current = kv_path.read_bytes()
        if current != last:
            last, since = current, time.monotonic()
        elif time.monotonic() - since >= quiet and (change_from is None or current != change_from):
            break
        if time.monotonic() - nudged >= 6 and change_from is not None and current == change_from:
            T.run_action(OPEN, check=False)
            nudged = time.monotonic()
    return last


def adoption(package, log, kv=None):
    log("## Adoption rehearsal: a store without positions over rails at bottom / right / left")
    check = Checks(log, "ADOPT")
    with new_instance(package, width=1280, height=800) as T:
        tabs = [T.tabs()[0]["id"]]
        build(T, [("split", 0, "right")])
        T.run_action(ENABLE)
        T.mount_count(PLUGIN, 1, timeout=40)
        for ops in ([("split", 0, "right"), ("split", 0, "down")], [], [("split", 0, "down")]):
            pane = lua_retry(T, "return { p = cx.layout:new_tab({}) }")["p"]
            tabs.append(lua_retry(T, f"return {{ t = cx.session:tab_of({pane}) }}")["t"])
            build(T, ops)
            T.mount_count(PLUGIN, len(tabs), timeout=40)
        settled = lambda: (T.pump() or True) and all((placement_record(T, t) or {}).get("placement") is None for t in tabs)  # noqa: E731

        def settle(step):
            # Headless plugin timers can stall (passes frozen mid-placement in past headless runs); `Attention: Open` is the established nudge.
            started, nudged = time.monotonic(), time.monotonic()
            while time.monotonic() - started < 60:
                if settled():
                    return True
                if time.monotonic() - nudged >= 6:
                    T.run_action(OPEN, check=False)
                    nudged = time.monotonic()
                time.sleep(0.5)
            pending = {t: {"status": ((placement_record(T, t) or {}).get("placement") or {}).get("status"),
                           "reason": ((placement_record(T, t) or {}).get("placement") or {}).get("reason"),
                           "edge": physical_edge(T, t)} for t in tabs if (placement_record(T, t) or {}).get("placement")}
            check(f"placements-settle-after-{step}", False, {"pending": pending, "shot": keep_shot(T, f"adoption-unsettled-{step}")})
            return False

        if not settle("mount"):
            return {"journey": "adoption", "pass": False, "checks": check.items}
        edges = {t: physical_edge(T, t) for t in tabs}
        check("default-rails-at-bottom", all(edge == "bottom" for edge in edges.values()), edges)
        bottom_before = {t: layout_of(T, t) for t in tabs[:2]}
        choose_position(T, tabs[2], "Right", "right")
        if not settle("right"):
            return {"journey": "adoption", "pass": False, "checks": check.items}
        choose_position(T, tabs[3], "Left", "left")
        if not settle("left"):
            return {"journey": "adoption", "pass": False, "checks": check.items}
        edges = {t: physical_edge(T, t) for t in tabs}
        stored = {t: (placement_record(T, t) or {}).get("position") for t in tabs}
        check("placement-control-moves-only-its-tab", edges == dict(zip(tabs, ["bottom", "bottom", "right", "left"]))
              and all(layout_of(T, t) == bottom_before[t] for t in tabs[:2]), {"edges": edges, "stored": stored})
        check("stored-position-follows-physical-edge", stored == edges, {"stored": stored, "edges": edges})
        defaults = ((T.kv(PLUGIN) or {}).get("preferences") or {}).get("defaults") or {}
        check("last-choice-is-the-default-for-new-rails", defaults.get("position") == "left", defaults)
        before = {t: layout_of(T, t) for t in tabs}
        rails_before = {t: tab_rail(T, t) for t in tabs}
        # The size a rail physically has, read from the live layout (not from the store being rewritten).
        sizes = {t: (lambda ratio: ratio if edges[t] == "left" else 1 - ratio)(layout_of(T, t)["root"]["ratio"]) for t in tabs}

        def live_shape(store):
            # The live store at the time of the audit: bottom rails carried `relocate` with no size, rails the left-only build
            # had already moved carried a bare `share`, and `defaults` had neither a position nor per-position sizes.
            prefs = store["preferences"]
            for host in prefs["instances"].values():
                for entry in host.values():
                    shares, position = entry.pop("shares", {}), entry.pop("position", None)
                    if position == "left":
                        entry["share"] = shares.get("left", 0.25)
                    else:
                        entry["relocate"] = True
            prefs["defaults"] = {"hidden": {}, "share": {}}

        kv_path, written = reload_plugin(T, live_shape)
        raw = settle_store(T, kv_path, change_from=written)
        after = json.loads(raw)["preferences"]
        entries = {int(tab): entry for host in after["instances"].values() for tab, entry in host.items()}
        check("relocate-stripped", not any("relocate" in entry for entry in entries.values()),
              {tab: sorted(entry) for tab, entry in entries.items()})
        check("positions-adopted-from-physical-edge", {t: entries[t].get("position") for t in tabs} == edges,
              {"adopted": {t: entries[t].get("position") for t in tabs}, "physical": edges})
        adopted = {t: (entries[t].get("shares") or {}).get(edges[t]) for t in tabs}
        check("sizes-adopted-per-position", all(adopted[t] is not None and abs(adopted[t] - sizes[t]) < 0.02 for t in tabs)
              and not any("share" in entry for entry in entries.values()),
              {t: {"adopted": adopted[t], "physical": round(sizes[t], 4), "legacyShare": entries[t].get("share")} for t in tabs})
        check("schema-4-defaults-position", after.get("schema") == 4 and after["defaults"].get("position") == "bottom", after["defaults"])
        moved = {t: layout_of(T, t) != before[t] for t in tabs}
        check("no-rail-moved", not any(moved.values()) and {t: tab_rail(T, t) for t in tabs} == rails_before and
              {t: physical_edge(T, t) for t in tabs} == edges,
              {"layoutChanged": moved, "rails": {t: tab_rail(T, t) for t in tabs}, "edges": {t: physical_edge(T, t) for t in tabs}})
        stat = kv_path.stat().st_mtime_ns
        reload_plugin(T)
        second = settle_store(T, kv_path, quiet=8.0)
        check("second-load-writes-nothing", second == raw and kv_path.stat().st_mtime_ns == stat,
              {"bytesEqual": second == raw, "mtimeUnchanged": kv_path.stat().st_mtime_ns == stat})
        check("no-plugin-errors", not [w for w in T.plugin_warnings() if "ERROR" in w], T.plugin_warnings()[-2:])
    return {"journey": "adoption", "pass": check.passed, "checks": check.items}


# ---------------------------------------------------------------------------------------------
# Screenshots of the strip with the real store's records (read-only copy)
# ---------------------------------------------------------------------------------------------

def shots(package, log, kv=None):
    log("## Screenshots: bottom strip with a copy of the real store")
    check = Checks(log, "SHOTS")
    seed = (Path(kv) if kv else LIVE_KV).read_bytes()
    taken = {}
    for width, height in ((1280, 800), (1839, 1135)):
        with new_instance(package, seed_files={f"plugin-data/{PLUGIN}/kv.json": seed}, width=width, height=height) as T:
            load_and_settle(T, settle=4.0)
            tab = T.tabs()[0]["id"]
            edge = physical_edge(T, tab)
            root = layout_of(T, tab)["root"]
            surface = nodes(T, "[data-surface]")[0]["rect"]
            check(f"{width}x{height}.strip-at-bottom", edge == "bottom",
                  {"edge": edge, "rootSplit": root.get("split"), "rootRatio": root.get("ratio"), "rail": surface})
            shots_here = {}
            for mode in ("Attention", "Later", "Currently working", "Workspace"):
                for _ in range(3):
                    node = button_by_title(T, f"{mode} \u00b7")
                    if node is not None:
                        click_node(T, node)
                    for _ in range(5):
                        T.pump()
                        time.sleep(0.4)
                shots_here[mode] = keep_shot(T, f"final-{width}x{height}-{mode.lower()}")
            click_until(T, lambda: button_by_title(T, "More \u00b7"), lambda: page_button_text(T, "Reset placement") is not None, "settings")
            for _ in range(4):
                T.pump()
                time.sleep(0.4)
            shots_here["Settings"] = keep_shot(T, f"final-{width}x{height}-settings")
            check(f"{width}x{height}.placement-control-shown", all(page_button_text(T, label) for label in ("Bottom", "Right", "Left", "Reset placement")),
                  {"labels": [n.get("text") for n in nodes(T, "button") if n.get("text") in ("Bottom", "Right", "Left", "Reset placement")]})
            taken[f"{width}x{height}"] = shots_here
    log(f"- FACT SHOTS.files: {json.dumps(taken)}")
    return {"journey": "shots", "pass": check.passed, "checks": check.items, "shots": taken}

# ---------------------------------------------------------------------------------------------
# Phone: the REAL window half publishes phone.json, the host block `attention.queue` renders it, the phone package jumps
# ---------------------------------------------------------------------------------------------

PHONE_FILE = "phone.json"
PHONE_DIST = REPO / "dist/attention-phone"
PHONE_ID = "attention"
# The phone package carries the Mac plugin's id (`attention`) so Tern routes taps on the mirrored desktop rail to it on the iPhone.
# On a real Mac + iPhone it never shares a window with the Mac plugin (it is phone only). Here both window halves must load in ONE
# desktop Tern, where a duplicate id would collide, and the FIRST-registered `attention://` link handler wins (plugins register in
# plugin-id order). So the qualification loads a copy of the phone package whose manifest id differs and sorts before `attention`;
# only the manifest id differs (window.luau is byte-identical, checked).
PHONE_FIXTURE_ID = "aaa-attention-phone"
TOP_FIELDS = {"schema", "revision", "generatedUtc", "status", "reason", "host", "counts", "rows"}
ROW_FIELDS = {"serial", "workId", "section", "session", "tab", "title", "state", "clock", "host", "localHost", "pane",
              "paneTitle", "cwd", "program", "placement", "jumpable"}
CLOCK_FIELDS = {"kind", "atUtc", "recorded"}
ROW_TEXT_LIMITS = {"session": 64, "tab": 64, "title": 160, "state": 40, "host": 64, "workId": 200, "paneTitle": 160, "cwd": 200,
                   "program": 64}
LEAK = re.compile(r"traceback|\.luau|\w\.lua:\d|(?:^|[\s(])(?:~|/)[\w.\-]+/[\w.\-/]+", re.IGNORECASE)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def phone_problems(snapshot):
    """Contract violations in a decoded phone.json (an empty list means it conforms to the phone package contract)."""
    bad = []
    if not isinstance(snapshot, dict):
        return ["not an object"]
    if set(snapshot) - TOP_FIELDS:
        bad.append(f"unknown top-level fields {sorted(set(snapshot) - TOP_FIELDS)}")
    if snapshot.get("schema") != 2:
        bad.append("schema is not 2")
    if not isinstance(snapshot.get("revision"), int) or isinstance(snapshot.get("revision"), bool):
        bad.append("revision is not an integer")
    if not isinstance(snapshot.get("generatedUtc"), int):
        bad.append("generatedUtc is not an integer")
    if snapshot.get("status") not in ("ok", "disabled", "unavailable"):
        bad.append("status not in the enum")
    reason = snapshot.get("reason")
    if reason is not None and not (isinstance(reason, str) and len(reason) <= 200 and not LEAK.search(reason)):
        bad.append("reason is not plain words <= 200")
    if not (isinstance(snapshot.get("host"), str) and len(snapshot["host"]) <= 64):
        bad.append("host is not a string <= 64")
    counts = snapshot.get("counts")
    if not (isinstance(counts, dict) and set(counts) == {"attention", "later", "working"}
            and all(isinstance(counts[key], int) and counts[key] >= 0 for key in counts)):
        bad.append("counts are not {attention, later, working} integers")
    rows = nh.as_list(snapshot.get("rows"))
    if not isinstance(rows, list) or len(rows) > 60:
        return bad + ["rows is not a list of <= 60"]
    for index, row in enumerate(rows):
        where = f"rows[{index}]"
        if not isinstance(row, dict):
            bad.append(f"{where} not an object")
            continue
        if set(row) - ROW_FIELDS:
            bad.append(f"{where} unknown fields {sorted(set(row) - ROW_FIELDS)}")
        if not number(row.get("serial")):
            bad.append(f"{where}.serial")
        if row.get("section") not in ("attention", "later", "working"):
            bad.append(f"{where}.section")
        for key, limit in ROW_TEXT_LIMITS.items():
            value = row.get(key)
            required = key in ("session", "title", "host", "workId")
            if value is None and not required:
                continue
            if not (isinstance(value, str) and len(value) <= limit):
                bad.append(f"{where}.{key} not a string <= {limit}")
            elif key != "cwd" and LEAK.search(value):
                bad.append(f"{where}.{key} looks like a path or traceback: {value[:60]!r}")
        clock = row.get("clock")
        if not isinstance(clock, dict) or set(clock) - CLOCK_FIELDS:
            bad.append(f"{where}.clock")
        else:
            if clock.get("kind") not in (None, "asked", "replied", "updated"):
                bad.append(f"{where}.clock.kind")
            if clock.get("atUtc") is not None and not number(clock["atUtc"]):
                bad.append(f"{where}.clock.atUtc")
            if not isinstance(clock.get("recorded"), bool):
                bad.append(f"{where}.clock.recorded")
        for key in ("localHost", "jumpable"):
            if not isinstance(row.get(key), bool):
                bad.append(f"{where}.{key} not a boolean")
        if row.get("pane") is not None and not number(row["pane"]):
            bad.append(f"{where}.pane")
        if row.get("placement") not in (None, "tiled", "floating", "parked", "unattached"):
            bad.append(f"{where}.placement")
        offline = isinstance(row.get("state"), str) and "offline" in row["state"].lower()
        if row.get("jumpable") is True and (offline or row.get("pane") is None or row.get("placement") == "parked"):
            bad.append(f"{where} is jumpable but offline / without a pane / parked")
        if row.get("jumpable") is True and not (isinstance(row.get("paneTitle"), str) and row["paneTitle"].strip()):
            bad.append(f"{where} is jumpable without a paneTitle (the phone finds a pane by its title)")
    return bad


def phone_fixture(dist):
    """(holder, package dir): a copy of the built phone package whose manifest id sorts before `attention`."""
    dist = Path(dist)
    holder = Path(tempfile.mkdtemp(prefix="phone-qual."))
    target = holder / PHONE_FIXTURE_ID
    shutil.copytree(dist, target)
    manifest = target / "plugin.toml"
    text = manifest.read_text()
    patched = text.replace(f'id = "{PHONE_ID}"', f'id = "{PHONE_FIXTURE_ID}"')
    if patched == text:
        raise nh.HarnessError(f"{manifest} has no `id = \"{PHONE_ID}\"` line")
    manifest.write_text(patched)
    identical = (dist / "window.luau").read_bytes() == (target / "window.luau").read_bytes()
    return holder, target, identical


def queue_panes(T):
    """Every `attention.queue` block in the window: pane id, pane kind, the `block` field as Tern reports it, parked, focused."""
    rows = nh.as_list(lua_retry(T, "local o = {} for _, p in ipairs(cx.session:panes()) do if p.block == 'attention.queue' then "
                                   "o[#o + 1] = { p.pane, p.kind or '?', p.block, p.parked and 1 or 0, p.focused and 1 or 0 } end end return o"))
    return [{"pane": r[0], "kind": r[1], "block": r[2], "parked": bool(r[3]), "focused": bool(r[4])} for r in rows]


def tree_nodes(T):
    """Every node of the full `tree`, document order."""
    found, stack = [], list(reversed(T.ctl("tree").get("tree") or []))
    while stack:
        node = stack.pop()
        found.append(node)
        stack.extend(reversed(node.get("children") or []))
    return found


def toast_texts(T):
    """Visible toast messages (title | body); Carly's own acknowledgement toasts are dropped."""
    texts = []
    for node in tree_nodes(T):
        if "toast" in (node.get("class") or "").split():
            parts, stack = [], list(node.get("children") or [])
            while stack:
                child = stack.pop(0)
                if child.get("text"):
                    parts.append(child["text"])
                stack = list(child.get("children") or []) + stack
            text = " | ".join(parts) or node.get("text") or ""
            if not text.startswith("Carly"):
                texts.append(text)
    return texts


def pump_for(T, seconds, step=0.3):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        T.pump()
        time.sleep(step)


def toasts_clear(T, timeout=10.0):
    """Wait until no toast is on screen, so the next message is attributable to the next tap."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        T.pump()
        if not toast_texts(T):
            return True
        time.sleep(0.25)
    return False


def tap_and_watch(T, node, seconds=1.6):
    """Tap `node` once no earlier toast is showing; returns the distinct toasts seen afterwards."""
    toasts_clear(T)
    tap_node(T, node)
    return watch_toasts(T, seconds)


def inert_state(T):
    """World facts a tap on an unavailable row must not change. Plugin canvases are excluded: Attention mounts its rail in a new tab on its own."""
    state = world_state(T)
    state["panes"] = sorted((p["pane"], p["tab"], p["parked"], p["floating"]) for p in pane_rows(T) if p["kind"] != "plugin")
    return state


def watch_toasts(T, seconds=1.6, step=0.15):
    """Distinct toast messages seen while pumping for `seconds` (a toast outlives a single poll)."""
    seen, end = [], time.monotonic() + seconds
    while time.monotonic() < end:
        T.pump()
        for text in toast_texts(T):
            if text not in seen:
                seen.append(text)
        time.sleep(step)
    return seen


def block_surface(T):
    """The visible block's main region node (the rail's own surface is `sf-unfocused sf-folded`/mono)."""
    found = [n for n in nodes(T, "[data-surface]") if "sf-main" in n.get("class", "") and "sf-sans" in n.get("class", "")]
    return found[0] if found else None


def block_text(T):
    node = block_surface(T)
    return node.get("text", "") if node else ""


def block_rows(T):
    """Row nodes inside the block's main region (tap targets)."""
    surface = block_surface(T)
    if surface is None:
        return []
    x, y, w, h = surface["rect"]
    return [n for n in nodes(T, "[data-role]") if "sf-act" in n.get("class", "") and "sf-col" in n.get("class", "")
            and n["rect"][2] > w * 0.8 and y <= n["rect"][1] < y + h]


def tap_node(T, node):
    x, y, w, h = node["rect"]
    return T.ctl("click", f"{x + w / 2:.1f}", f"{y + h / 2:.1f}")


def block_tab(T, label):
    found = [n for n in tree_nodes(T) if "sf-tab" in (n.get("class") or "").split()
             and re.fullmatch(re.escape(label) + r"\s+\d+", n.get("text") or "")]
    return found[0] if found else None


def rail_badge(T, mode):
    node = button_by_title(T, f"{mode} \u00b7")
    found = re.search(r"(\d+)$", (node or {}).get("text", ""))
    return int(found.group(1)) if found else None


def read_phone(path):
    raw = path.read_bytes()
    return raw, json.loads(raw)


def await_phone(T, path, predicate, timeout=20.0, what="phone.json"):
    def read():
        try:
            return predicate(json.loads(path.read_bytes())) and json.loads(path.read_bytes())
        except (FileNotFoundError, ValueError):
            return None
    return T.wait_for(read, timeout=timeout, interval=0.5, what=what, pump=True)


def phone_row(serial, pane, panes, section="attention", jumpable=True, drop=(), **override):
    live = panes[pane]
    row = {"serial": serial, "workId": f"work:{serial}", "section": section, "session": "default", "tab": live["title"],
           "title": f"Jump test {live['title']}", "state": "Waiting for input",
           "clock": {"kind": "asked", "atUtc": int(time.time()) - 600, "recorded": True}, "host": "demo-mac", "localHost": True,
           "pane": pane, "paneTitle": live["title"], "cwd": live["cwd"], "program": live["program"],
           "placement": "parked" if live["parked"] else "tiled", "jumpable": jumpable}
    row.update(override)
    for key in drop:
        del row[key]
    return row


def phone(package, log, kv=None, phone_package=None, sample_seconds=75):
    """The REAL prepared package + the built phone package in one isolated Tern (see tools/phone_package.py)."""
    global SHOT_DIR
    SHOT_DIR = Path("/tmp/qual-phone-shots")
    log("## Phone: publish -> block -> jump")
    check = Checks(log, "PHONE")
    dist = Path(phone_package) if phone_package else PHONE_DIST
    if not (dist / "plugin.toml").exists():
        subprocess.run([sys.executable, str(REPO / "tools/phone_package.py"), "build"], check=True, cwd=REPO, capture_output=True)
    holder, fixture, identical = phone_fixture(dist)
    seed = (Path(kv) if kv else LIVE_KV).read_bytes()
    original = json.loads(seed)
    check("fixture", identical, {"phonePackage": str(dist), "fixtureId": PHONE_FIXTURE_ID, "windowLuauByteIdentical": identical,
                                 "storeBytes": len(seed), "triageItems": len(original["triage"]["items"])})
    try:
        with new_instance(package, extra_plugins=[fixture], seed_files={f"plugin-data/{PLUGIN}/kv.json": seed}, width=1280, height=800) as T:
            root = T.root
            data_dir = T.config / "plugin-data" / PLUGIN
            kv_path, file = data_dir / "kv.json", data_dir / PHONE_FILE
            # --- 5. host half loaded, window half unaffected --------------------------------------------------------------
            blocks = nh.as_list(lua_retry(T, "local o = {} for _, b in ipairs(cx.session:block_types()) do o[#o + 1] = { kind = b.kind, title = b.title, palette = b.palette } end return o"))
            queue = [b for b in blocks if b["kind"] == "attention.queue"]
            check("5-host-block-registered", len(queue) == 1 and queue[0]["title"] == "Attention queue" and queue[0]["palette"] is True,
                  {"blockTypes": blocks, "loadAttempts": T.load_attempts_used, "pluginIds": T.plugin_ids})
            actions = T.plugin_actions()
            check("5-window-actions", all(f"plugin.{PLUGIN}.{name}" in actions for name in ("enable", "open", "disable"))
                  and f"plugin.{PHONE_FIXTURE_ID}.queue" in actions, {"actions": len(actions), "phone": [a for a in actions if PHONE_FIXTURE_ID in a]})
            mounted = T.enable_and_mount(PLUGIN)
            check("5-rail-mounts-with-host-half", len(mounted["canvases"]) == 1, {"seconds": mounted["seconds"], "attempts": mounted["attempts"]})
            # --- 1. the owner window publishes ----------------------------------------------------------------------------
            published_at = time.monotonic()
            raw, first = None, None
            try:
                first = await_phone(T, file, lambda d: d.get("status") == "ok", timeout=30, what="first phone.json")
                raw = file.read_bytes()
            except nh.WaitTimeout as error:
                check("1-first-write", False, str(error))
            if first is None:
                return {"journey": "phone", "pass": False, "checks": check.items}
            check("1-first-write", True, {"seconds": round(time.monotonic() - published_at, 1), "bytes": len(raw), "revision": first["revision"],
                                          "status": first["status"], "host": first["host"]})
            pump_for(T, 3)
            first = json.loads(file.read_bytes())
            rows = nh.as_list(first["rows"])
            problems = phone_problems(first)
            check("1-contract", not problems, {"problems": problems[:6], "rows": len(rows), "keys": sorted(first)})
            rail = {"attention": rail_badge(T, "Attention"), "later": rail_badge(T, "Later"),
                    "working": rail_badge(T, "Currently working")}
            check("1-counts-equal-rail-badges", first["counts"] == rail and rail["attention"] is not None,
                  {"counts": first["counts"], "railBadges": rail,
                   "rowsBySection": {s: sum(1 for r in rows if r["section"] == s) for s in ("attention", "later", "working")}})
            by_section = {s: sum(1 for r in rows if r["section"] == s) for s in ("attention", "later", "working")}
            check("1-rows-match-counts", len(rows) <= 60 and (by_section == first["counts"] if sum(first["counts"].values()) <= 60 else len(rows) == 60),
                  {"rows": len(rows), "counts": first["counts"]})
            retained = [r for r in rows if "offline" in str(r.get("state", "")).lower() or r.get("pane") is None]
            check("1-retained-rows-not-jumpable", all(r["jumpable"] is False for r in retained) and len(retained) > 0,
                  {"retained": len(retained), "jumpable": [r["serial"] for r in retained if r["jumpable"]], "states": sorted({r.get("state") for r in retained})})
            section_rank = {"attention": 0, "later": 1, "working": 2}
            check("1-queue-order", [r["section"] for r in rows] == sorted((r["section"] for r in rows), key=lambda s: section_rank[s]),
                  [r["section"] for r in rows])
            check("1-no-secrets-in-bytes", not re.search(rb"identityKey|reviewRevision|sourceSessionId|\.luau|traceback", raw, re.IGNORECASE), {"bytes": len(raw)})
            # --- 2. no rewrite while nothing changes -----------------------------------------------------------------------
            # Attention's own registry pruning (an absent tab's entry retires after ~30 s) writes kv.json once; measure after it settled.
            settle_until = time.monotonic() + 45
            while time.monotonic() < settle_until:
                T.pump()
                time.sleep(0.5)
            last_kv, stable_since, kv_limit = None, time.monotonic(), time.monotonic() + 60
            while time.monotonic() - stable_since < 6 and time.monotonic() < kv_limit:
                T.pump()
                time.sleep(0.5)
                current = kv_path.read_bytes()
                if current != last_kv:
                    last_kv, stable_since = current, time.monotonic()
            kv_bytes, kv_mtime = kv_path.read_bytes(), kv_path.stat().st_mtime_ns
            baseline = json.loads(file.read_bytes())
            samples, last_key, started = [], None, time.monotonic()
            while time.monotonic() - started < sample_seconds:
                T.pump()
                stat = file.stat()
                key = (stat.st_ino, stat.st_mtime_ns)
                if key != last_key:
                    document = json.loads(file.read_bytes())
                    samples.append({"t": round(time.monotonic() - started, 1), "inode": stat.st_ino, "revision": document["revision"],
                                    "generatedUtc": document["generatedUtc"], "sameContent": {k: v for k, v in document.items() if k not in ("generatedUtc", "revision")}
                                    == {k: v for k, v in baseline.items() if k not in ("generatedUtc", "revision")}})
                    last_key = key
                time.sleep(2)
            writes = samples[1:] if samples and samples[0]["t"] < 2.5 else samples
            gaps = [round(b["generatedUtc"] - a["generatedUtc"]) for a, b in zip([{"generatedUtc": baseline["generatedUtc"]}] + writes, writes)]
            check("2-only-heartbeat-writes", len(writes) <= 3 and all(w["revision"] == baseline["revision"] and w["sameContent"] for w in writes)
                  and all(gap >= 25 for gap in gaps), {"seconds": sample_seconds, "distinctWrites": len(writes), "revision": baseline["revision"],
                                                       "gapsSeconds": gaps, "samples": samples})
            check("2-kv-bytes-unchanged-by-publishing", kv_path.read_bytes() == kv_bytes and kv_path.stat().st_mtime_ns == kv_mtime,
                  {"bytes": len(kv_bytes), "mtimeUnchanged": kv_path.stat().st_mtime_ns == kv_mtime})
            check("2-directory-clean", sorted(p.name for p in data_dir.iterdir()) == sorted([PHONE_FILE, "kv.json"]), sorted(p.name for p in data_dir.iterdir()))
            # --- the jump world: two shell tabs and one parked pane --------------------------------------------------------
            ws = T.root / "ws"
            ws.mkdir()
            for name in ("jump-a", "jump-b", "jump-parked"):
                (ws / name).mkdir()
            tab_a = lua_retry(T, f"return {{ p = cx.layout:new_tab({{ cwd = {json.dumps(str(ws / 'jump-a'))} }}) }}")["p"]
            tab_b = lua_retry(T, f"return {{ p = cx.layout:new_tab({{ cwd = {json.dumps(str(ws / 'jump-b'))} }}) }}")["p"]
            parked = lua_retry(T, f"return {{ p = cx.layout:split({tab_a}, 'right', {{ cwd = {json.dumps(str(ws / 'jump-parked'))} }}, {{ focus = false }}) }}")["p"]
            lua_retry(T, f"local ok, why = cx.layout:park({parked}) return {{ ok = ok, why = why }}")
            pump_for(T, 3)
            # --- 3. the host block at phone size ---------------------------------------------------------------------------
            T.ctl("size", 390, 844)
            # The phone package's palette command is how the queue opens on a phone: run it twice (and once more after focus moved
            # away) and exactly one `attention.queue` block may exist; it is reused and focused, never duplicated.
            queue_action = f"plugin.{PHONE_FIXTURE_ID}.queue"
            already = queue_panes(T)
            T.run_action(queue_action)
            T.wait_for(lambda: len(queue_panes(T)) >= 1, timeout=15, interval=0.5, what="queue block from the palette command", pump=True)
            pump_for(T, 1.5)
            run_one = queue_panes(T)
            T.run_action(queue_action)
            pump_for(T, 2)
            run_two = queue_panes(T)
            focus_pane(T, tab_a)
            pump_for(T, 1)
            away = focused(T)
            T.run_action(queue_action)
            pump_for(T, 2)
            run_three = queue_panes(T)
            block = run_one[0]["pane"] if run_one else None
            check("3-palette-opens-exactly-one-queue-block",
                  not already and len(run_one) == 1 and run_one[0]["kind"] == "plugin" and run_one[0]["block"] == "attention.queue"
                  and [p["pane"] for p in run_two] == [block] and [p["pane"] for p in run_three] == [block]
                  and away != block and focused(T) == block and not run_three[0]["parked"],
                  {"before": already, "afterFirstRun": run_one, "afterSecondRun": run_two, "afterRunFromAnotherPane": run_three,
                   "focusedAway": away, "focusedAfter": focused(T)})
            check("3-block-opens", isinstance(block, int), {"pane": block})
            T.wait_for(lambda: re.match(r"Attention \d+Later \d+Currently working \d+", block_text(T)), timeout=15, interval=0.5, what="block render", pump=True)
            text = block_text(T)
            live = json.loads(file.read_bytes())
            shown = re.match(r"Attention (\d+)Later (\d+)Currently working (\d+)", text)
            shown_counts = {"attention": int(shown.group(1)), "later": int(shown.group(2)),
                            "working": int(shown.group(3))} if shown else None
            check("3-block-counts-equal-file-and-rail", shown_counts == live["counts"] == rail, {"block": shown_counts, "file": live["counts"], "rail": rail})

            def show(label):
                tap_node(T, block_tab(T, label))
                pump_for(T, 1.5)
                return block_rows(T)

            def displayed(value):
                # The block drops private-use icon glyphs (and the space they leave) from display strings.
                return re.sub(r"\s+", " ", re.sub("[\ue000-\uf8ff\U000f0000-\U000ffffd\U00100000-\U0010fffd]", "", value)).strip()

            def matches(wanted, shown_rows):
                body = block_text(T)
                filler = not shown_rows and not re.fullmatch(r"Attention \d+Later \d+Currently working \d+Updated [^\u0000]*", body)
                return len(shown_rows) == len(wanted) and not filler and all(
                    displayed(r["session"]) in n.get("text", "") and displayed(r["title"]) in n.get("text", "")
                    for r, n in zip(wanted, shown_rows))

            expected = [r for r in nh.as_list(live["rows"]) if r["section"] == "attention"]
            later_rows = [r for r in nh.as_list(live["rows"]) if r["section"] == "later"]
            check("3-store-has-queued-rows", bool(expected or later_rows), {"attention": len(expected), "later": len(later_rows)})
            attention_view = block_rows(T)
            check("3-attention-rows-match", matches(expected, attention_view),
                  {"rows": [n.get("text", "")[:70] for n in attention_view], "expected": len(expected), "emptyRendersNothing": not attention_view and not expected})
            check("3-screenshot", True, {"attention": keep_shot(T, "phone-block-attention")})
            later_view = show("Later")
            check("3-later-section", matches(later_rows, later_view) and not any(displayed(r["title"]) in block_text(T) for r in expected),
                  {"laterTitles": [r["title"][:40] for r in later_rows], "rows": len(later_view), "text": block_text(T)[:120]})
            check("3-screenshot-later", True, {"later": keep_shot(T, "phone-block-later")})
            working_rows = [r for r in nh.as_list(live["rows"]) if r["section"] == "working"]
            working_view = show("Currently working")
            check("3-working-section", matches(working_rows, working_view),
                  {"workingTitles": [r["title"] for r in working_rows], "rows": len(working_view)})
            check("3-screenshot-working", True, {"working": keep_shot(T, "phone-block-working")})
            surface = block_surface(T)["rect"]
            pool = attention_view or later_view
            check("3-touch-layout", bool(pool) and all(n["rect"][3] >= 44 and n["rect"][0] >= 0 and n["rect"][0] + n["rect"][2] <= 390 for n in pool)
                  and surface[0] + surface[2] <= 390,
                  {"rowHeights": [n["rect"][3] for n in pool], "surface": surface, "tabHeight": (block_tab(T, "Attention") or {}).get("rect")})
            pump_for(T, 2)
            before = inert_state(T)
            tap_label = "Attention" if expected else "Later"
            tappable = show(tap_label)
            toasts = tap_and_watch(T, tappable[0])
            after = inert_state(T)
            moved = {key: [before[key], after[key]] for key in before if before[key] != after[key]}
            check("3-offline-row-toast-and-inert", any("offline" in t.lower() for t in toasts) and not moved
                  and not any("phone link" in t or "parked" in t or "find that" in t for t in toasts), {"section": tap_label, "toasts": toasts, "moved": moved})
            back = show("Attention")
            check("3-back-to-attention", len(back) == len(expected), {"rows": len(back)})
            button = [n for n in nodes(T, "button") if n.get("text") == "Test phone link"]
            toasts = tap_and_watch(T, button[0])
            check("4-ping-toast", "Attention phone link works" in toasts, {"toasts": toasts})
            before_disable = json.loads(file.read_bytes())
            T.run_action(DISABLE)
            started = time.monotonic()
            disabled = T.wait_for(lambda: "Attention is disabled on your Mac" in block_text(T), timeout=8, interval=0.4, what="disabled message", pump=True)
            seconds = round(time.monotonic() - started, 1)
            written = json.loads(file.read_bytes())
            check("3-disable-message", bool(disabled) and seconds <= 5 and written["status"] == "disabled",
                  {"seconds": seconds, "status": written["status"], "revision": [before_disable["revision"], written["revision"]], "text": block_text(T)[:80]})
            check("3-screenshot-disabled", True, {"disabled": keep_shot(T, "phone-block-disabled")})
            T.run_action(ENABLE)
            started = time.monotonic()

            def restored_now():
                return (len(block_rows(T)) == len(expected) and re.match(r"Attention \d+Later \d+Currently working \d+", block_text(T))
                        and json.loads(file.read_bytes())["status"] == "ok")

            nudged = False
            try:
                restored = T.wait_for(restored_now, timeout=5, interval=0.4, what="rows restored", pump=True)
            except nh.WaitTimeout:
                # Headless serve runs plugin timers only on input events, and a pass after `enable` sometimes never runs (the harness
                # records the same flake for the first mount); `Attention: Open` is the documented nudge.
                nudged = True
                T.run_action(OPEN)
                restored = T.wait_for(restored_now, timeout=10, interval=0.4, what="rows restored after Open", pump=True)
            seconds = round(time.monotonic() - started, 1)
            again = json.loads(file.read_bytes())
            check("3-enable-restores-rows", bool(restored) and again["status"] == "ok" and again["counts"] == live["counts"],
                  {"seconds": seconds, "nudgedWithOpen": nudged, "status": again["status"], "counts": again["counts"], "revision": again["revision"]})
            # --- 4. jump -------------------------------------------------------------------------------------------------
            T.run_action(DISABLE)
            await_phone(T, file, lambda d: d.get("status") == "disabled", timeout=10, what="disabled write")
            detail = {r["pane"]: r for r in nh.as_list(lua_retry(T, "local o = {} for _, p in ipairs(cx.session:panes()) do o[#o + 1] = "
                                                                    "{ pane = p.pane, title = p.title, cwd = p.cwd, program = p.program, parked = p.parked == true } end return o"))}
            crafted_rows = [phone_row(101, tab_a, detail), phone_row(102, tab_b, detail), phone_row(103, parked, detail),
                            phone_row(104, parked, detail, jumpable=False),
                            phone_row(105, tab_a, detail, title="Mismatch row", paneTitle="no-such-title"),
                            phone_row(106, parked, detail, placement="tiled")]
            crafted = {"schema": 2, "revision": written["revision"] + 10, "generatedUtc": int(time.time()), "status": "ok", "host": "demo-mac",
                       "counts": {"attention": len(crafted_rows), "later": 0, "working": 0}, "rows": crafted_rows}
            expected_flaws = ["rows[2] is jumpable but offline / without a pane / parked"]
            check("4-crafted-snapshot-only-flawed-where-intended", phone_problems(crafted) == expected_flaws, phone_problems(crafted))
            payload = json.dumps(crafted)
            file.write_text(payload)
            wrote_at = time.monotonic()
            T.wait_for(lambda: f"Attention {len(crafted_rows)}" in block_text(T) and bool(block_rows(T)),
                       timeout=10, interval=0.4, what="crafted rows", pump=True)
            check("4-screenshot-crafted", True, {"crafted": keep_shot(T, "phone-block-crafted")})

            def refocus():
                focus_pane(T, block)
                pump_for(T, 1.2)
                T.ctl("hover", ".sf-main[data-surface='plugin.attention.queue']")
                T.wheel(0, -4000)
                pump_for(T, 0.3)
                return block_rows(T)

            reach = {"scrolls": 0, "visible": None, "dockTop": None, "rect": None}

            def reveal(serial):
                """Find a stable row id, scrolling until its complete tap target is above the dock."""
                for _ in range(12):
                    found = nodes(T, f"[data-id='main.rows.r{serial}']")
                    node = next((n for n in found if "sf-act" in n.get("class", "")), None)
                    dock = [n for n in nodes(T, "[data-surface]") if "sf-dock" in n.get("class", "")]
                    limit = dock[0]["rect"][1] if dock else 1e9
                    top = block_surface(T)["rect"][1]
                    fits = node is not None and node["rect"][1] >= top and node["rect"][1] + node["rect"][3] <= limit
                    reach.update(visible=fits, dockTop=limit, rect=node["rect"] if node else None)
                    if fits:
                        return node
                    T.ctl("hover", ".sf-main[data-surface='plugin.attention.queue']")
                    T.wheel(0, 150)
                    reach["scrolls"] += 1
                    pump_for(T, 0.4)
                raise nh.WaitTimeout(f"queue row {serial} never became fully visible")

            def jump_tap(index):
                refocus()
                node = reveal(crafted_rows[index]["serial"])
                toasts = tap_and_watch(T, node, 1.2)
                return toasts, focused(T)

            parked_before = sorted(p["pane"] for p in pane_rows(T) if p["parked"])
            toasts, now = jump_tap(0)
            check("4-jump-focuses-exact-pane-a", now == tab_a, {"focused": now, "expected": tab_a, "toasts": toasts})
            toasts, now = jump_tap(1)
            check("4-jump-focuses-exact-pane-b", now == tab_b, {"focused": now, "expected": tab_b, "toasts": toasts})
            frozen = world_state(T)
            toasts, now = jump_tap(2)
            check("4-parked-row-blocked-by-block", any("parked" in t.lower() for t in toasts) and now == block, {"toasts": toasts, "focused": now})
            toasts, now = jump_tap(3)
            check("4-parked-nonjumpable-toast", any("parked" in t.lower() for t in toasts) and now == block, {"toasts": toasts, "focused": now})
            toasts, now = jump_tap(4)
            check("4-mismatched-evidence-finds-nothing", any("find that conversation" in t for t in toasts) and now == block, {"toasts": toasts, "focused": now})
            toasts, now = jump_tap(5)
            check("4-long-list-last-row-reachable", reach["scrolls"] > 0 and reach["visible"],
                  {"wheelsNeeded": reach["scrolls"], "visibleAfter": reach["visible"], "dockTop": reach["dockTop"], "row": reach["rect"]})
            check("4-stale-parked-link-never-unparks", any("parked" in t.lower() for t in toasts) and now == block
                  and sorted(p["pane"] for p in pane_rows(T) if p["parked"]) == parked_before, {"toasts": toasts, "focused": now, "parked": parked_before})
            check("4-nothing-else-moved", world_state(T)["panes"] == frozen["panes"] and world_state(T)["tabs"] == frozen["tabs"],
                  {"panes": len(frozen["panes"]), "tabs": len(frozen["tabs"])})
            while time.monotonic() - wrote_at < 33:
                T.pump()
                time.sleep(0.5)
            check("4-disabled-owner-never-rewrites", file.read_text() == payload, {"unchangedForSeconds": round(time.monotonic() - wrote_at)})
            # --- 4b. a conversation in ANOTHER session: found by its title, switching to the session the link names -------------
            def pane_details():
                return {r["pane"]: r for r in nh.as_list(lua_retry(
                    T, "local o = {} for _, p in ipairs(cx.session:panes()) do o[#o + 1] = { pane = p.pane, kind = p.kind, title = p.title, "
                       "cwd = p.cwd, program = p.program, parked = p.parked == true } end return o"))}

            origin = lua_retry(T, "local c = cx.sessions:current() return { id = c.id, name = c.name }")
            (ws / "jump-other").mkdir()
            known = set(pane_details())
            lua_retry(T, f"local s = cx.sessions:create({{ name = 'qual-other', cwd = {json.dumps(str(ws / 'jump-other'))} }}) return {{ id = s.id }}")
            pump_for(T, 2)
            there = {pane: info for pane, info in pane_details().items() if pane not in known and info["kind"] == "terminal"}
            check("4b-other-session-has-a-pane", len(there) == 1 and current_session(T) == "qual-other", {"new": there, "current": current_session(T)})
            other_pane = next(iter(there))
            lua_retry(T, f"cx.sessions:switch({origin['id']}) return {{ ok = true }}")
            pump_for(T, 2)
            listed_from_origin = other_pane in pane_details()
            tolerant = {"schema": 2, "revision": crafted["revision"] + 1, "generatedUtc": int(time.time()), "status": "ok", "host": "demo-mac",
                        "counts": {"attention": 3, "later": 0, "working": 0}, "rows": [
                            # The Mac's cwd and program are not the phone's, and one row has neither: the pane is still found by its title.
                            phone_row(107, tab_a, detail, cwd="/not/the/phones/cwd", program="not-a-program", session="elsewhere"),
                            phone_row(108, tab_b, detail, drop=("cwd", "program")),
                            phone_row(201, other_pane, there, session="qual-other")]}
            check("4b-tolerant-snapshot-conforms", phone_problems(tolerant) == [], phone_problems(tolerant))
            file.write_text(json.dumps(tolerant))
            T.wait_for(lambda: len(block_rows(T)) == 3, timeout=10, interval=0.4, what="tolerant rows", pump=True)
            failure_toast = ("find that", "Several", "parked")

            def tolerant_tap(index):
                rows_now = refocus()
                if len(rows_now) != 3:
                    raise nh.HarnessError(f"block shows {len(rows_now)} rows, expected 3")
                toasts = tap_and_watch(T, rows_now[index], 1.2)
                pump_for(T, 2.5)  # a jump that switches session looks again on 300 ms timers
                return toasts, focused(T)

            toasts, now = tolerant_tap(0)
            check("4b-differing-cwd-and-program-still-found-by-title", now == tab_a and not any(f in t for t in toasts for f in failure_toast),
                  {"focused": now, "expected": tab_a, "toasts": toasts})
            toasts, now = tolerant_tap(1)
            check("4b-no-cwd-or-program-found-by-title", now == tab_b and not any(f in t for t in toasts for f in failure_toast),
                  {"focused": now, "expected": tab_b, "toasts": toasts})
            toasts, now = tolerant_tap(2)
            check("4b-cross-session-jump-focuses-the-pane", now == other_pane and not any(f in t for t in toasts for f in failure_toast),
                  {"focused": now, "expected": other_pane, "toasts": toasts, "currentSession": current_session(T),
                   "paneListedFromOriginSession": listed_from_origin})
            # A live working row may share a serial with another queue; its visible action must use this section.
            refocus()
            working_sample = {"schema": 2, "revision": tolerant["revision"] + 1, "generatedUtc": int(time.time()),
                              "status": "ok", "host": "demo-mac", "counts": {"attention": 0, "later": 1, "working": 1},
                              "rows": [phone_row(301, tab_a, detail, section="later", state="Working"),
                                       phone_row(301, tab_b, detail, section="working", state="Working")]}
            file.write_text(json.dumps(working_sample))
            T.wait_for(lambda: "Currently working 1" in block_text(T), timeout=10, interval=.4,
                       pump=True, what="working count published")
            working_items = show("Currently working")
            check("4c-working-row-visible", len(working_items) == 1 and "Working" in working_items[0].get("text", ""),
                  {"rows": [r.get("text", "") for r in working_items]})
            toasts = tap_and_watch(T, working_items[0], 1.2)
            check("4c-working-jump-uses-visible-section", focused(T) == tab_b,
                  {"focused": focused(T), "expected": tab_b, "otherSectionPane": tab_a, "toasts": toasts})
            refocus()
            keep_shot(T, "phone-block-working-populated")
            # --- 5. the window half stayed healthy ------------------------------------------------------------------------
            errors = [w for w in T.plugin_warnings() if "ERROR" in w or "exceeded its budget" in w or "host" in w.lower() and "fail" in w.lower()]
            check("5-no-plugin-errors", not errors, {"errors": errors[-3:], "warnings": len(T.plugin_warnings())})
    finally:
        shutil.rmtree(holder, ignore_errors=True)
    check("temporary-copies-removed", not Path(root).exists() and not holder.exists(), {"root": str(root), "fixture": str(holder)})
    return {"journey": "phone", "pass": check.passed, "checks": check.items}



JOURNEYS = {"j1": j1, "j2": j2, "j3": j3, "j4": j4, "j5": j5, "j6": j6}
SEPARATE = {"migration": migration, "adoption": adoption, "shots": shots, "phone": phone}  # not in `all`: need the real store (read-only copy) / the built phone package


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("journey", choices=[*JOURNEYS, *SEPARATE, "all"])
    parser.add_argument("--package", help="prepared package dir (default: run install.py --prepare-only)")
    parser.add_argument("--log", help="append a Markdown log here")
    parser.add_argument("--only", nargs="*", help="J1: restrict to these class names")
    parser.add_argument("--edge", nargs="*", choices=[*EDGES, "all"],
                        help="J1: rail edges to exercise (default: bottom; with `all` journeys: bottom and left)")
    parser.add_argument("--kv", help="migration/phone: store to copy (default: the live plugin-data kv.json, read-only)")
    parser.add_argument("--phone-package", help="phone: built phone package dir (default: dist/attention-phone, built on demand)")
    parser.add_argument("--sample-seconds", type=int, default=75, help="phone: how long the heartbeat/no-rewrite window is sampled")
    args = parser.parse_args(argv)
    package = args.package or prepare_package()
    log = Log(args.log)
    head = subprocess.run(["git", "log", "-1", "--format=%h %s"], cwd=REPO, capture_output=True, text=True).stdout.strip()
    log(f"# native journeys · package {package} · checkout HEAD {head}")
    selected = list(JOURNEYS) if args.journey == "all" else [args.journey]
    runners = {**JOURNEYS, **SEPARATE}
    reports = []
    edges = EDGES if args.edge and "all" in args.edge else tuple(args.edge or (("bottom", "left") if args.journey == "all" else (DEFAULT_EDGE,)))
    for name in selected:
        runner = runners[name]
        if name == "j1":
            reports.append(runner(package, log, classes=args.only, edges=edges))
        elif name in SEPARATE:
            extra = {"phone_package": args.phone_package, "sample_seconds": args.sample_seconds} if name == "phone" else {}
            try:
                reports.append(runner(package, log, kv=args.kv, **extra))
            except Exception as error:  # a crashed journey is a FAIL with its error
                log(f"- FAIL {name} crashed: {type(error).__name__}: {error}")
                reports.append({"journey": name, "pass": False, "error": f"{type(error).__name__}: {error}"})
        else:
            for edge in edges:
                RUN["edge"] = edge
                try:
                    report = runner(package, log)
                except Exception as error:  # a crashed journey is a FAIL with its error, never a silent stop of the whole run
                    log(f"- FAIL {name}[{edge}] crashed: {type(error).__name__}: {error}")
                    report = {"journey": name, "pass": False, "error": f"{type(error).__name__}: {error}"}
                report["journey"] = f"{report['journey']}[{edge}]"
                reports.append(report)
    print(json.dumps(reports, indent=1, default=str))
    for report in reports:
        counts = report.get("outcomes") or {"pass" if report.get("pass") else "fail": 1}
        line = f"summary {report['journey']}: " + ", ".join(f"{count} {key}" for key, count in counts.items())
        log(line)
    # Exit 0 = every item passed; 1 = at least one FAIL.
    return 0 if all(report.get("pass") for report in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
