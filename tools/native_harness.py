#!/usr/bin/env python3
"""Drive a REAL plugin package inside an isolated, headless `tern serve`.

Nothing here touches the user's Tern: the child gets a private config dir, daemon socket, HOME and a
scrubbed environment (every inherited TERN_* variable is dropped), runs in its own process group, and is
always killed and deleted on exit. Stdlib only.

Why fixtures: `tern serve` loads NO plugins on its own, and `<config>/plugins/<id>.path` links are
ignored by it. The only headless loader is the `plugins fixtures` control command, which reads
`$STENCIL_FIXTURE_ROOT/../plugins/fixtures/<dir>` for every plugin. The harness therefore builds
`<root>/crates/tern` (the fixture root) and `<root>/crates/plugins/fixtures/<id>` symlinks to the real
package directories, then sends `plugins fixtures` once the control port answers.

    with IsolatedTern(package_dir) as tern:
        tern.run_action("plugin.attention.enable")
        tern.wait_for(lambda: tern.canvases(), timeout=15)

CLI: python3 tools/native_harness.py smoke --package READYDIR
"""

import argparse
import atexit
import contextlib
import json
import os
import re
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import tomllib


class HarnessError(RuntimeError):
    pass


class LuaError(HarnessError):
    pass


class WaitTimeout(HarnessError):
    pass


# ---------------------------------------------------------------------------------------------
# Pure helpers (unit-tested without launching Tern)
# ---------------------------------------------------------------------------------------------

def free_port(host="127.0.0.1"):
    """Ask the kernel for an unused TCP port. Racy by nature; callers retry on a failed start."""
    with contextlib.closing(socket.socket(socket.AF_INET, socket.SOCK_STREAM)) as probe:
        probe.bind((host, 0))
        return probe.getsockname()[1]


def build_env(root, base=None, extra=None):
    """Child environment: PATH/locale only from `base`, no TERN_*/STENCIL_* leakage, private HOME.

    TERN_PANE_SOCKET / TERN_WINDOW_SOCKET / TERN_IDENTITY inherited from a Tern pane point at the LIVE
    daemon, so they must never reach the child (Attention shells out to `tern inspect` and `tern capture`).
    """
    base = os.environ if base is None else base
    root = Path(root)
    env = {key: value for key, value in base.items()
           if key in ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "USER", "LOGNAME", "SHELL")}
    env.update({
        "HOME": str(root / "home"),
        "TERN_CONFIG_DIR": str(root / "config"),
        "TERN_DAEMON_SOCKET": str(root / "d.sock"),
        "STENCIL_FIXTURE_ROOT": str(root / "crates" / "tern"),
    })
    env.update(extra or {})
    return env


def serve_command(tern, port, shots):
    return [str(tern), "serve", "--control", str(port), "--out", str(shots)]


def ctl_command(tern, port, *args):
    return [str(tern), "ctl", "--control", str(port), *[str(arg) for arg in args]]


def quote(text):
    """Quote one argument for Tern's script grammar (`type`, `rename`, ...): \\ \" newline tab escaped."""
    escaped = (str(text).replace("\\", "\\\\").replace('"', '\\"')
               .replace("\n", "\\n").replace("\t", "\\t"))
    return f'"{escaped}"'


def parse_reply(stdout):
    """One JSON line per `tern ctl` reply; `{"ok":false,"error":..}` raises."""
    lines = [line for line in stdout.splitlines() if line.strip()]
    if not lines:
        raise HarnessError("Empty control reply")
    try:
        reply = json.loads(lines[-1])
    except ValueError as error:
        raise HarnessError(f"Control reply was not JSON: {lines[-1][:300]!r}") from error
    if not isinstance(reply, dict):
        raise HarnessError(f"Control reply was not an object: {reply!r}")
    if reply.get("ok") is False:
        raise HarnessError(f"Control command failed: {reply.get('error')}")
    return reply


PUMP_KEY = "ctrl+shift+f12"
FRESH_STATE_NOTE = "(fresh Lua state"
TRUNCATION = re.compile(r"\n\u2026 (\d+) bytes cut \u2026\n")


def parse_lua_answer(last_tool):
    """`state.carly.last_tool` -> answer text. Drops the one-time fresh-state note and the leading arrow."""
    if not isinstance(last_tool, dict) or not isinstance(last_tool.get("text"), str):
        raise HarnessError(f"No Carly tool answer: {last_tool!r}")
    text = last_tool["text"]
    if last_tool.get("error"):
        raise LuaError(text)
    lines = text.split("\n")
    if lines and lines[0].startswith(FRESH_STATE_NOTE):
        lines = lines[1:]
    text = "\n".join(lines)
    cut = TRUNCATION.search(text)
    if cut:
        raise HarnessError(f"Carly truncated the answer ({cut.group(1)} bytes cut); return less data from Lua")
    if text.startswith("\u2192 "):
        text = text[2:]
    elif text.startswith("\u2192"):
        text = text[1:]
    return text.strip()


def lua_json_source(code):
    """Wrap a Lua chunk (use `return`) so its result comes back as one JSON document."""
    return f"local __r = (function()\n{code}\nend)()\nreturn tern.json.encode(__r)"


def as_list(value):
    """tern.json.encode renders an empty Lua table as `{}`; normalise to a Python list."""
    if value in ({}, None):
        return []
    return value


def flatten_texts(nodes):
    """All non-empty `text` strings in a `tree` node list, document order."""
    found = []
    for node in nodes or []:
        if isinstance(node, dict):
            if isinstance(node.get("text"), str) and node["text"]:
                found.append(node["text"])
            found.extend(flatten_texts(node.get("children")))
    return found


def rail_rendered(buttons):
    """True when `button` tree nodes show a rendered rail: the Attention mode button and Search are present, plus the
    gear (`More ·`) or the owner-recovery `Return to` button. Matches by `title`, as native_journeys.rail_ready does."""
    titles = [str(node.get("title", "")) for node in buttons or [] if isinstance(node, dict)]
    def has(prefix):
        return any(title.startswith(prefix) for title in titles)
    return has("Attention \u00b7") and has("Search") and (has("More \u00b7") or has("Return to"))


def plugin_id(package):
    manifest = Path(package) / "plugin.toml"
    try:
        value = tomllib.loads(manifest.read_text())["id"]
    except (OSError, ValueError, KeyError) as error:
        raise HarnessError(f"Unreadable plugin manifest {manifest}: {error}") from error
    if not isinstance(value, str) or not value:
        raise HarnessError(f"Invalid plugin id in {manifest}")
    return value


def terminate(proc, grace=5.0, killpg=os.killpg, getpgid=os.getpgid, sleep=time.sleep, clock=time.monotonic):
    """TERM then KILL the child's OWN process group. Refuses to signal our group or an unknown pid."""
    if proc is None or proc.poll() is not None:
        return "already-exited"
    try:
        group = getpgid(proc.pid)
    except ProcessLookupError:
        return "already-exited"
    if group != proc.pid or group == getpgid(0):
        raise HarnessError(f"Child {proc.pid} is not the leader of its own process group; not signalling")
    outcome = "terminated"
    for sent in (signal.SIGTERM, signal.SIGKILL):
        try:
            killpg(group, sent)
        except ProcessLookupError:
            return "terminated"
        deadline = clock() + grace
        while clock() < deadline:
            if proc.poll() is not None:
                return outcome
            sleep(0.05)
        outcome = "killed"
    return outcome


def read_tail(path, limit=4000):
    try:
        data = Path(path).read_bytes()
    except OSError:
        return ""
    return data[-limit:].decode("utf-8", "replace")


# ---------------------------------------------------------------------------------------------
# The isolated instance
# ---------------------------------------------------------------------------------------------

class IsolatedTern:
    """Context manager owning one headless `tern serve` with real plugin packages loaded.

    package_dir    prepared READYDIR (from `tools/install.py --prepare-only`); symlinked, never copied
    extra_plugins  more package directories to load alongside it
    settings       dict written to <config>/settings.json before start (e.g. {"plugins_disabled": [...]})
    seed_files     {relpath: bytes} written under <config> (e.g. plugin-data/attention/kv.json)
    env            extra environment for the child (may override HOME etc.; TERN_* extras are allowed)
    keep           leave the temp root on disk (path in .root) for inspection
    """

    def __init__(self, package_dir, extra_plugins=(), settings=None, seed_files=None, env=None,
                 width=1280, height=800, scale=None, keep=False, tern="tern", ready_timeout=60.0,
                 command_timeout=30.0, start_attempts=3, await_actions=True, load_attempts=3, load_wait=8.0):
        self.packages = [Path(package_dir).expanduser().resolve(),
                         *[Path(path).expanduser().resolve() for path in extra_plugins]]
        self.settings = settings
        self.seed_files = dict(seed_files or {})
        self.extra_env = dict(env or {})
        self.width, self.height, self.scale = width, height, scale
        self.keep = keep
        self.ready_timeout = ready_timeout
        self.command_timeout = command_timeout
        self.start_attempts = start_attempts
        self.await_actions = await_actions
        self.load_attempts, self.load_wait, self.load_attempts_used = load_attempts, load_wait, 0
        resolved = shutil.which(str(tern))
        if resolved is None:
            raise HarnessError(f"tern executable not found: {tern}")
        self.tern = resolved
        self.root = None
        self.port = None
        self.proc = None
        self.plugin_ids = []
        self._log = None
        self._closed = False

    # -- lifecycle ---------------------------------------------------------------------------

    def __enter__(self):
        try:
            self._start()
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    @property
    def config(self):
        return self.root / "config"

    @property
    def log_path(self):
        return self.root / "serve.log"

    def _prepare_root(self):
        self.root = Path(tempfile.mkdtemp(prefix="native-harness."))
        for sub in ("config/plugins", "home", "shots", "crates/tern/goldens", "crates/plugins/fixtures"):
            (self.root / sub).mkdir(parents=True)
        self.plugin_ids = []
        for package in self.packages:
            if not package.is_dir():
                raise HarnessError(f"Plugin package directory missing: {package}")
            identity = plugin_id(package)
            if identity in self.plugin_ids:
                raise HarnessError(f"Duplicate plugin id {identity}")
            self.plugin_ids.append(identity)
            (self.root / "crates/plugins/fixtures" / identity).symlink_to(package, target_is_directory=True)
        if self.settings is not None:
            (self.config / "settings.json").write_text(json.dumps(self.settings))
        for relative, content in self.seed_files.items():
            target = (self.config / relative).resolve()
            if self.config.resolve() not in target.parents:
                raise HarnessError(f"Seed file escapes the config directory: {relative}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)

    def _start(self):
        atexit.register(self.close)
        self._prepare_root()
        env = build_env(self.root, extra=self.extra_env)
        last = None
        for attempt in range(self.start_attempts):
            self.port = free_port()
            self._log = open(self.log_path, "ab")
            self.proc = subprocess.Popen(serve_command(self.tern, self.port, self.root / "shots"),
                                         cwd=self.root, env=env, stdin=subprocess.DEVNULL,
                                         stdout=self._log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                self._wait_ready()
                break
            except HarnessError as error:
                last = error
                terminate(self.proc)
                self.proc = None
        else:
            raise HarnessError(f"tern serve never became ready after {self.start_attempts} attempts: {last}")
        if self.scale is None:
            self.ctl("size", self.width, self.height)
        else:
            self.ctl("size", self.width, self.height, self.scale)
        self._load_plugins()

    def _load_plugins(self):
        """`plugins fixtures` replies before plugin VMs register commands, and a window entry that takes
        longer than Tern's 500 ms load budget is paused for 5 s (then silently never loads). Retry past
        the pause; `loadAttempts` records how many it took."""
        self.load_attempts_used = 0
        for _ in range(self.load_attempts):
            self.load_attempts_used += 1
            self.ctl("plugins", "fixtures")
            if not self.await_actions:
                return
            try:
                self.wait_for(self._plugins_loaded, timeout=self.load_wait, interval=0.2,
                              what=f"plugin actions for {self.plugin_ids}")
                return
            except WaitTimeout:
                continue
        warnings = [line for line in read_tail(self.log_path, 20000).splitlines() if "plugin" in line and "WARN" in line]
        raise HarnessError(f"Plugins {self.plugin_ids} never loaded in {self.load_attempts} attempts.\n"
                           + "\n".join(warnings[-6:]))

    def _plugins_loaded(self):
        loaded = set(self.lua_json("local ids = {}\n"
                                   "for _, item in ipairs(cx.actions:list()) do\n"
                                   "  if item.plugin then ids[item.plugin] = true end\n"
                                   "end\nreturn ids").keys())
        return set(self.plugin_ids) <= loaded

    def _wait_ready(self):
        deadline = time.monotonic() + self.ready_timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise HarnessError(f"tern serve exited with {self.proc.returncode} before ready.\n"
                                   f"--- serve.log tail ---\n{read_tail(self.log_path)}")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.5):
                    pass
                self.ctl("state")
                return
            except (OSError, HarnessError):
                time.sleep(0.1)
        raise HarnessError(f"Control port {self.port} not ready in {self.ready_timeout}s.\n"
                           f"--- serve.log tail ---\n{read_tail(self.log_path)}")

    def close(self):
        """Idempotent: ask politely, kill our own process group, delete the root unless keep."""
        if self._closed:
            return
        self._closed = True
        atexit.unregister(self.close)
        if self.proc is not None and self.proc.poll() is None and self.port is not None:
            with contextlib.suppress(HarnessError, subprocess.SubprocessError, OSError):
                self._run(ctl_command(self.tern, self.port, "quit"), timeout=5)
            with contextlib.suppress(subprocess.TimeoutExpired):
                self.proc.wait(timeout=5)
        terminate(self.proc)
        if self._log is not None:
            self._log.close()
        if self.root is not None and not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)

    # -- control -----------------------------------------------------------------------------

    def _run(self, command, timeout):
        try:
            done = subprocess.run(command, cwd=self.root, env=build_env(self.root, extra=self.extra_env),
                                  capture_output=True, text=True, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise HarnessError(f"`{' '.join(command[4:])}` timed out after {timeout}s") from error
        if done.returncode != 0 and not done.stdout.strip():
            raise HarnessError(f"`tern ctl` exited {done.returncode}: {done.stderr.strip()[:500]}")
        return done.stdout

    def ctl(self, *args, timeout=None):
        """Send one control command; returns the decoded JSON reply, raises on {"ok":false}."""
        if self.proc is not None and self.proc.poll() is not None:
            raise HarnessError(f"tern serve exited with {self.proc.returncode}.\n"
                               f"--- serve.log tail ---\n{read_tail(self.log_path)}")
        return parse_reply(self._run(ctl_command(self.tern, self.port, *args), timeout or self.command_timeout))

    def state(self):
        return self.ctl("state")

    def lua(self, code):
        """Run Luau in the Carly window VM (fresh Lua state per call, `cx` = window). Returns answer text.

        Transport: the whole chunk is sent as ONE quoted ctl token, so quotes, newlines and `--` comments
        survive. Raises LuaError with the Luau message on failure. Never `await` a picker here.
        """
        self.ctl("carly", "lua", quote(code))
        carly = self.state()["carly"]
        turns = carly.get("turns") or []
        if not turns or turns[-1].get("asked") != code:
            raise HarnessError("Carly answer does not belong to this call (stale last_tool)")
        return parse_lua_answer(carly.get("last_tool"))

    def lua_json(self, code):
        """Run a chunk that `return`s plain data; decode it. Empty tables decode to {} (see as_list)."""
        return json.loads(self.lua(lua_json_source(code)))

    def run_action(self, name, check=True):
        """`plugins run <action>`; the control reply is ok:true even for unknown actions, so verify first."""
        if check:
            self.lua_json(f"return cx.actions:describe({json.dumps(name)})")
        self.ctl("plugins", "run", name)

    def enable_and_mount(self, plugin, timeout=30.0, retry_after=3.0):
        """Run `plugin.<id>.enable`, then wait for the plugin's canvas (owner == id); see mount_count."""
        self.run_action(f"plugin.{plugin}.enable")
        return self.mount_count(plugin, 1, timeout=timeout, retry_after=retry_after, enabled_at=time.monotonic())

    def mount_count(self, plugin, count, timeout=30.0, retry_after=3.0, enabled_at=None):
        """Wait until `count` canvases owned by `plugin` exist, re-running `plugin.<id>.open` (in the
        focused tab) every `retry_after` seconds without progress.

        Headless serve only runs plugin timers when the window receives input events, so every poll pumps (see
        `pump`); `open` is still re-issued every `retry_after` seconds as a backstop.
        Returns {"attempts": opens issued (+1 when enabled_at), "seconds", "canvases"}.
        """
        started = enabled_at if enabled_at is not None else time.monotonic()
        attempts, last_try = (1 if enabled_at is not None else 0), time.monotonic()
        while True:
            found = self.canvases(plugin)
            if len(found) >= count:
                return {"attempts": attempts, "seconds": round(time.monotonic() - started, 2), "canvases": found}
            if time.monotonic() - started > timeout:
                raise WaitTimeout(f"{len(found)}/{count} {plugin} canvases after {timeout}s and {attempts} attempts;"
                                  f" warnings={self.plugin_warnings()[-3:]}")
            if time.monotonic() - last_try >= retry_after:
                self.run_action(f"plugin.{plugin}.open", check=False)
                attempts, last_try = attempts + 1, time.monotonic()
            self.pump()
            time.sleep(0.1)

    def plugin_actions(self):
        """Ids of every non-builtin action (filtered in Lua: the full list exceeds the 8 KB answer cap)."""
        return as_list(self.lua_json("local ids = {}\n"
                                     "for _, item in ipairs(cx.actions:list()) do\n"
                                     "  if item.kind ~= 'builtin' then ids[#ids + 1] = item.id end\n"
                                     "end\nreturn ids"))

    def wait_for(self, predicate, timeout=15.0, interval=0.25, what="condition", pump=False):
        """Poll until predicate() is truthy; return its value (pump=True wakes plugin timers before each try).
        WaitTimeout carries the last value/error."""
        deadline = time.monotonic() + timeout
        last = None
        while True:
            try:
                if pump:
                    self.pump()
                last = predicate()
                if last:
                    return last
            except HarnessError as error:
                last = error
            if time.monotonic() >= deadline:
                raise WaitTimeout(f"Timed out after {timeout}s waiting for {what}; last={last!r}")
            time.sleep(interval)

    def pump(self):
        """Wake the plugin timer queue. Measured: in headless `tern serve` plugin `tern.timer` callbacks (including a
        plugin's own schedule(32) passes and 1 s heartbeat) do not run while the window is idle; they advance a few
        steps per input event. `key ctrl+shift+f12` (unbound) is the cheapest event that wakes them. Do not pump while
        a native picker/menu is open (the key would reach it)."""
        self.ctl("key", PUMP_KEY)

    # -- window facts ------------------------------------------------------------------------

    def canvases(self, owner=None):
        items = as_list(self.lua_json("return cx.canvas:list()"))
        return [item for item in items if owner is None or item.get("owner") == owner]

    def tabs(self):
        return as_list(self.lua_json("return cx.session:tabs()"))

    def layouts(self):
        return self.lua_json("local out = {}\n"
                             "for _, tab in ipairs(cx.session:tabs()) do out[#out + 1] = cx.session:layout(tab.id) end\n"
                             "return out")

    def new_tab(self):
        """Open a content tab with a shell; returns its first pane id."""
        pane = self.lua_json("return { pane = cx.layout:new_tab({}) }")["pane"]
        if not isinstance(pane, int):
            raise HarnessError(f"new_tab returned {pane!r}")
        return pane

    def plugin_warnings(self):
        """WARN/ERROR lines about plugins from the child's log (load-budget pauses, entry failures)."""
        return [line for line in read_tail(self.log_path, 40000).splitlines()
                if "plugin" in line and ("WARN" in line or "ERROR" in line)]

    def kv(self, plugin):
        """The plugin's persisted tern.kv store, read straight from <config>/plugin-data/<id>/kv.json."""
        path = self.config / "plugin-data" / plugin / "kv.json"
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            return None

    # -- scenario commands -------------------------------------------------------------------

    def shot(self, name):
        """Write <name>.png under <root>/shots/serve; returns its path."""
        return self.ctl("shot", name)["png"]

    def dump(self, selector=None):
        return self.ctl("dump", *([selector] if selector else []))

    def tree(self, selector=None):
        return self.ctl("tree", *([selector] if selector else []))

    def tree_texts(self, selector=None):
        reply = self.tree(selector)
        return flatten_texts(reply.get("nodes") or reply.get("tree"))

    def wheel(self, dx, dy):
        return self.ctl("wheel", dx, dy)

    def key(self, combo):
        return self.ctl("key", combo)

    def type(self, text):
        return self.ctl("type", quote(text))

    def click(self, target):
        return self.ctl("click", target)

    def quit(self):
        self.close()


# ---------------------------------------------------------------------------------------------
# CLI smoke
# ---------------------------------------------------------------------------------------------

def smoke(package, keep=False, shot=None, mount_timeout=30.0):
    report = {"package": str(Path(package).resolve()), "steps": {}}
    started = time.monotonic()
    with IsolatedTern(package, keep=keep) as tern:
        plugin = tern.plugin_ids[0]
        report["root"] = str(tern.root) if keep else None
        report["pluginId"] = plugin
        report["startSeconds"] = round(time.monotonic() - started, 2)
        report["loadAttempts"] = tern.load_attempts_used
        report["pluginActions"] = tern.plugin_actions()
        report["windowKey"] = tern.lua_json("return { key = cx:window_key() }")["key"]
        report["canvasesBeforeEnable"] = tern.canvases(plugin)

        t0 = time.monotonic()
        mounted = tern.enable_and_mount(plugin, timeout=mount_timeout)
        report["steps"]["firstCanvasSeconds"] = round(time.monotonic() - t0, 2)
        report["steps"]["enableAttempts"] = mounted["attempts"]
        report["kvAfterEnable"] = tern.kv(plugin)
        report["firstCanvas"] = mounted["canvases"]

        pane = tern.new_tab()
        t1 = time.monotonic()
        second = tern.mount_count(plugin, 2, timeout=mount_timeout)
        report["steps"]["secondCanvasSeconds"] = round(time.monotonic() - t1, 2)
        report["steps"]["secondTabOpenAttempts"] = second["attempts"]
        report["secondTabPane"] = pane
        report["canvases"] = second["canvases"]
        report["tabs"] = tern.tabs()
        report["layouts"] = tern.layouts()
        marker = tern.tree_texts("[data-surface]")
        report["surfaceTexts"] = marker
        try:
            tern.wait_for(lambda: rail_rendered(tern.tree("button").get("nodes")), timeout=10.0,
                          what="rendered rail (mode, Search, and gear buttons)", pump=True)
            report["renderVisible"] = True
        except WaitTimeout as error:
            report["renderVisible"] = False
            report["renderWait"] = str(error)
        if shot:
            png = tern.shot("smoke")
            shutil.copyfile(png, shot)
            report["shot"] = str(shot)
    report["totalSeconds"] = round(time.monotonic() - started, 2)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    one = commands.add_parser("smoke", help="start an isolated Tern, enable the plugin, report canvas mounts")
    one.add_argument("--package", required=True, type=Path, help="READYDIR from install.py --prepare-only")
    one.add_argument("--keep", action="store_true", help="leave the temp root on disk")
    one.add_argument("--shot", type=Path, help="copy a screenshot PNG here")
    args = parser.parse_args(argv)
    try:
        report = smoke(args.package, keep=args.keep, shot=args.shot)
    except HarnessError as error:
        print(json.dumps({"status": "failed", "error": str(error)}, indent=2))
        return 1
    report["status"] = "ok" if report["renderVisible"] and len(report["canvases"]) >= 2 else "failed"
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
