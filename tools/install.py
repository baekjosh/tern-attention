#!/usr/bin/env python3
"""Prepare and link a small Attention runtime, retaining one previous generation."""

import argparse
import fcntl
import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


LEGACY_RUNTIME_FILES = (
    "plugin.toml", "window.luau", "model.luau", "layout.luau",
    "view.luau", "identity.luau", "titles.luau", "styles.css",
)
SOURCE_FACTS_RUNTIME_FILES = LEGACY_RUNTIME_FILES + ("source_facts.py",)
PREVIOUS_RUNTIME_FILES = SOURCE_FACTS_RUNTIME_FILES + ("navigation.luau",)
RUNTIME_FILES = PREVIOUS_RUNTIME_FILES + ("host.luau", "phone.luau")
RETIRED_RUNTIME_FILES = SOURCE_FACTS_RUNTIME_FILES + ("decisions.luau", "decision_rubric.json")
# Bump when the runtime or the preference schema it writes changes incompatibly. A
# prepared package whose marker lacks the current value must be prepared again.
RUNTIME_CAPABILITY = "workspace-navigator-2"
MARKER = ".attention-package.json"
PRODUCER = "tern-attention/tools/install.py:1"
RUNTIME_ROOT = Path.home() / "Library/Application Support/Tern/attention-runtime"
SOURCE = Path(__file__).resolve().parents[1]


def signature(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f"Not a private regular file: {path}")
    return [info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def write_marker(package, marker):
    (package / MARKER).write_text(json.dumps(marker, sort_keys=True) + "\n")


def package_marker(package, root, complete=True):
    if package.is_symlink() or not package.is_dir() or package.parent != root:
        raise ValueError(f"Not a direct package directory: {package}")
    if not (package / MARKER).exists():
        raise ValueError(f"Unmarked baseline or foreign directory retained: {package}")
    signature(package / MARKER)
    marker = json.loads((package / MARKER).read_text())
    if not isinstance(marker, dict) or marker.get("producer") != PRODUCER:
        raise ValueError(f"Unmarked or foreign package: {package}")
    files = marker.get("files")
    if not isinstance(files, dict) or not set(files).issubset(set(RUNTIME_FILES) | set(RETIRED_RUNTIME_FILES)):
        raise ValueError(f"Invalid ownership marker: {package}")
    if complete and set(files) not in (
            set(RUNTIME_FILES), set(PREVIOUS_RUNTIME_FILES),
            set(SOURCE_FACTS_RUNTIME_FILES), set(LEGACY_RUNTIME_FILES),
            set(RETIRED_RUNTIME_FILES)):
        raise ValueError(f"Incomplete package: {package}")
    if {entry.name for entry in package.iterdir()} != set(files) | {MARKER}:
        raise ValueError(f"Unexpected files in package: {package}")
    for name in files:
        signature(package / name)
    return marker


def prepare(source, root):
    # Validate the inputs before creating any staging directory.
    for name in RUNTIME_FILES:
        path = source / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or non-regular runtime source: {path}")
    package = Path(tempfile.mkdtemp(prefix="package-", dir=root))
    marker = {"producer": PRODUCER, "capability": RUNTIME_CAPABILITY, "files": {},
              "activation_attempted": False}
    try:
        write_marker(package, marker)
        for name in RUNTIME_FILES:
            target = package / name
            # No checkout, source metadata, caches, or auxiliary files are copied.
            try:
                with (source / name).open("rb") as incoming, target.open("xb") as outgoing:
                    while chunk := incoming.read(65536):
                        outgoing.write(chunk)
            finally:
                if target.exists():
                    marker["files"][name] = signature(target)
                    write_marker(package, marker)
        return package
    except Exception as error:
        # The caller owns readback and cleanup, even for a partial copy.
        raise PreparationError(package, error) from error


class PreparationError(Exception):
    def __init__(self, package, cause):
        self.package = package
        super().__init__(f"Preparing {package}: {cause}")


def read_link(path):
    try:
        value = path.read_text().strip()
    except FileNotFoundError:
        if path.is_symlink():
            raise ValueError(f"Dangling plugin link file: {path}")
        return None
    if not value or "\n" in value or not Path(value).is_absolute():
        raise ValueError(f"Unreadable plugin target in {path}")
    return Path(value)


def linked_targets(plugins):
    if not plugins.is_dir():
        raise ValueError(f"Plugin directory unavailable: {plugins}")
    return {target.resolve() for entry in plugins.glob("*.path")
            if (target := read_link(entry)) is not None}


def cleanup_report():
    return {"selected": [], "removed": [], "selectedBytes": 0,
            "removedBytes": 0, "freedAllocatedBytes": 0, "retained": [],
            "byteMeaning": "File bytes removed and allocated blocks unlinked; not a free-space measurement."}


def remove_owned(package, root, report):
    marker = package_marker(package, root, complete=False)
    for name, saved in marker["files"].items():
        if signature(package / name) != saved:
            raise ValueError(f"Modified package file retained: {package / name}")
    paths = [package / name for name in marker["files"]] + [package / MARKER]
    observed = {path: signature(path) for path in paths}
    report["selected"].append(str(package))
    report["selectedBytes"] += sum(value[1] for value in observed.values())
    # Never recurse: a concurrent unexpected addition must survive, not be rmtree'd.
    for path in paths:
        if signature(path) != observed[path]:
            raise ValueError(f"Package changed during cleanup: {path}")
        info = path.lstat()
        path.unlink()
        report["removedBytes"] += info.st_size
        report["freedAllocatedBytes"] += info.st_blocks * 512
    package.rmdir()
    report["removed"].append(str(package))


def cleanup_failed(package, root, plugins):
    report = cleanup_report()
    try:
        if package.resolve() in linked_targets(plugins):
            raise ValueError("Package is linked; retained without automatic rollback")
        remove_owned(package, root, report)
    except (OSError, ValueError) as error:
        report["retained"].append({"path": str(package), "reason": str(error)})
    return report


def sweep(root, plugins, current, previous):
    report = cleanup_report()
    keep = {current}
    if previous is not None:
        keep.add(previous)
    if read_link(plugins / "attention.path") != current:
        raise ValueError("Attention link changed; no sweep performed")
    for package in sorted(root.iterdir()):
        if not package.is_dir() and not package.is_symlink():
            continue
        try:
            if package in keep:
                raise ValueError("Current or previous target")
            if package.resolve() in linked_targets(plugins):
                raise ValueError("Referenced by a plugin link")
            marker = package_marker(package, root)
            if marker.get("activation_attempted") is not True:
                raise ValueError("Prepared package has not been activated")
            if read_link(plugins / "attention.path") != current:
                raise ValueError("Attention link changed during sweep")
            remove_owned(package, root, report)
        except (OSError, ValueError) as error:
            report["retained"].append({"path": str(package), "reason": str(error)})
    return report


def native(args):
    result = subprocess.run(["tern", "plugin", *args, "--json"],
                            capture_output=True, text=True, timeout=60, check=False)
    receipt = {"exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    try:
        receipt["json"] = json.loads(result.stdout)
    except ValueError:
        receipt["parseError"] = "Native stdout was not JSON"
    return receipt


def receipt_errors(value, location="receipt"):
    errors = []
    if isinstance(value, dict):
        for key, child in value.items():
            at = f"{location}.{key}"
            if (key in {"error", "errors", "problems", "reload_error", "reload_errors"} and child
                    or key in {"ok", "success", "reload"} and child is False
                    or key == "status" and child in ("error", "failed", "failure")):
                errors.append(f"{at}: {json.dumps(child)}")
            elif isinstance(child, (dict, list)):
                errors.extend(receipt_errors(child, at))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(receipt_errors(child, f"{location}[{index}]"))
    return errors


def activate(package, root, plugins, report):
    marker = package_marker(package, root)
    if set(marker["files"]) != set(RUNTIME_FILES):
        raise ValueError(
            "Non-current package cannot activate after the workspace navigator cutover; fix forward with a newly prepared runtime"
        )
    if marker.get("capability") != RUNTIME_CAPABILITY:
        raise ValueError(
            f"Package lacks runtime capability {RUNTIME_CAPABILITY}; prepare a new runtime instead of activating {package}"
        )
    previous = read_link(plugins / "attention.path")
    if previous == package:
        saved = marker.get("previous")
        previous = Path(saved) if isinstance(saved, str) and Path(saved).is_absolute() else None
    else:
        marker["previous"] = str(previous) if previous is not None else None
        marker["activation_attempted"] = True
        write_marker(package, marker)
    report["previous"] = str(previous) if previous is not None else None
    failures = []
    try:
        receipt = native(["link", str(package)])
        report["nativeReceipt"] = receipt
        if receipt["exitCode"] != 0:
            failures.append(f"Native link exited {receipt['exitCode']}")
        if "parseError" in receipt or not isinstance(receipt.get("json"), dict):
            failures.append(receipt.get("parseError", "Native receipt was not a JSON object"))
        else:
            failures.extend(receipt_errors(receipt["json"]))
    except (OSError, subprocess.TimeoutExpired) as error:
        failures.append(str(error))
        if isinstance(error, subprocess.TimeoutExpired):
            report["nativeReceipt"] = {
                "timeout": True,
                "stdout": error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else error.stdout,
                "stderr": error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr,
            }
    try:
        actual = read_link(plugins / "attention.path")
        report["readback"] = str(actual) if actual is not None else None
        report["linked"] = actual == package
        if actual != package:
            failures.append("Attention link readback does not exactly match prepared package")
    except (OSError, ValueError) as error:
        failures.append(f"Link readback unavailable: {error}")
        report["linked"] = None
    if failures:
        report["errors"] = failures
        report["cleanup"] = cleanup_failed(package, root, plugins)
        report["status"] = "linked-with-errors" if report["linked"] else "activation-failed"
        return 1
    report["cleanup"] = sweep(root, plugins, package, previous)
    report["status"] = "linked"
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--prepare-only", action="store_true", help="Copy runtime only; print readyDirectory for compilation")
    mode.add_argument("--activate-existing", type=Path, metavar="READYDIR", help="Link a complete producer-owned package prepared with the current runtime capability, without recopying; fix forward otherwise")
    args = parser.parse_args()
    report = {"status": "failed", "renderProof": False}
    package = None
    created = False
    plugins = None
    root = RUNTIME_ROOT.resolve()
    try:
        root.mkdir(parents=True, exist_ok=True)
        with (root / ".install.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            directory = native(["dir"])
            report["directoryReceipt"] = directory
            payload = directory.get("json")
            value = payload.get("dir") if isinstance(payload, dict) else None
            if directory["exitCode"] != 0 or not isinstance(value, str) or not Path(value).is_absolute():
                raise ValueError("Native plugin directory unavailable")
            plugins = Path(value)
            # Read the old link before staging or activation. Never rewrite other links.
            read_link(plugins / "attention.path")
            if args.activate_existing is not None:
                raw = args.activate_existing.expanduser().absolute()
                if raw.is_symlink():
                    raise ValueError("Activation target must not be a symlink")
                package = raw.resolve()
                package_marker(package, root)
            else:
                package = prepare(SOURCE, root)
                created = True
            report["readyDirectory"] = str(package)
            if args.prepare_only:
                report["status"] = "prepared"
                code = 0
            else:
                code = activate(package, root, plugins, report)
    except (OSError, ValueError, PreparationError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        if isinstance(error, PreparationError):
            package = error.package
            created = True
            report["readyDirectory"] = str(package)
        if created and package is not None and plugins is not None:
            report["cleanup"] = cleanup_failed(package, root, plugins)
        code = 1
    print(json.dumps(report, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
