#!/usr/bin/env python3
"""Build and send the phone Tern package (folder `attention-phone/`, plugin id `attention`, the window half the iPhone runs).

    python3 tools/phone_package.py build
    python3 tools/phone_package.py send --to <tailscale-name> [--yes]

`build` stages `dist/attention-phone/` (plugin.toml, window.luau, README.md) and writes a deterministic
`dist/attention-phone-<version>.zip`: sorted entries, fixed timestamps and modes, `attention-phone/` as the
zip root with plugin.toml directly inside it. `send` prints the exact `tailscale file cp` command and runs it
only with `--yes`. The package carries the Mac plugin's id (`attention`) on purpose, so it is PHONE ONLY: both
commands print a warning, and it must never be installed on the Mac. Stdlib only.
"""

import argparse
import hashlib
import io
import re
import shlex
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "phone-package" / "attention-phone"
DIST = ROOT / "dist"
FOLDER = "attention-phone"
FILES = ("README.md", "plugin.toml", "window.luau")
MANIFEST_KEYS = {"schema", "id", "name", "version", "description", "icon", "host", "window", "styles"}
ID_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
TAILSCALE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$")
ZIP_TIME = (1980, 1, 1, 0, 0, 0)
PHONE_ONLY = ("PHONE ONLY: this package has the same plugin id (`attention`) as the Mac plugin. "
              "Never copy it into the Mac's Tern plugins folder.")


class PackageError(Exception):
    pass


def relative_entry(package, value, label):
    path = Path(value) if isinstance(value, str) else None
    if (path is None or not value or path.is_absolute() or ".." in path.parts
            or path.suffix not in (".luau", ".lua")):
        raise PackageError(f"{label} {value!r} must be a relative .luau or .lua path inside the plugin")
    if not (package / path).is_file():
        raise PackageError(f"missing entry {value}")
    return path


def validate_manifest(package):
    """Minimal schema-1 check: keys, id, name, entries exist. Returns the parsed manifest."""
    manifest_path = package / "plugin.toml"
    if not manifest_path.is_file():
        raise PackageError("no plugin.toml")
    try:
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as failure:
        raise PackageError(f"cannot read plugin.toml: {failure}") from failure
    if "schema" not in manifest:
        raise PackageError("missing schema")
    if manifest["schema"] != 1 or isinstance(manifest["schema"], bool):
        raise PackageError(f"unsupported schema {manifest['schema']!r}")
    unknown = sorted(set(manifest) - MANIFEST_KEYS)
    if unknown:
        raise PackageError(f"unknown field `{unknown[0]}`")
    if "blocks" in manifest or "lenses" in manifest:
        raise PackageError("a phone package has no host half, so it declares no blocks or lenses")
    identifier = manifest.get("id")
    if not isinstance(identifier, str) or not ID_PATTERN.fullmatch(identifier):
        raise PackageError(f"invalid id {identifier!r} (lowercase letters, digits and -, 1-32 long)")
    name = manifest.get("name")
    if not isinstance(name, str) or not 1 <= len(name) <= 64:
        raise PackageError("name must be 1-64 characters")
    if not isinstance(manifest.get("version"), str) or not manifest["version"]:
        raise PackageError("missing field `version`")
    if "host" in manifest:
        raise PackageError("a phone package must not have a host entry (iOS skips host halves)")
    if "window" not in manifest:
        raise PackageError("needs a window entry")
    relative_entry(package, manifest["window"], "window")
    styles = manifest.get("styles", [])
    if not isinstance(styles, list):
        raise PackageError("styles must be a list")
    for style in styles:
        if not isinstance(style, str) or Path(style).is_absolute() or ".." in Path(style).parts \
                or not (package / style).is_file():
            raise PackageError(f"style {style!r} must be a relative path to an existing file")
    return manifest


def source_files(source):
    present = sorted(entry.name for entry in source.iterdir())
    if present != list(FILES):
        raise PackageError(f"package source must contain exactly {', '.join(FILES)}; found {', '.join(present)}")
    for name in FILES:
        if not (source / name).is_file() or (source / name).is_symlink():
            raise PackageError(f"{name} is not a regular file")
    return {name: (source / name).read_bytes() for name in FILES}


def zip_bytes(files):
    """Deterministic archive: sorted entries, fixed timestamps, modes and creator."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        folder = zipfile.ZipInfo(FOLDER + "/", ZIP_TIME)
        folder.create_system = 3
        folder.external_attr = (0o40755 << 16) | 0x10
        archive.writestr(folder, b"")
        for name in sorted(files):
            info = zipfile.ZipInfo(f"{FOLDER}/{name}", ZIP_TIME)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, files[name], zipfile.ZIP_DEFLATED, 9)
    return buffer.getvalue()


def zip_path(dist, version):
    return dist / f"{FOLDER}-{version}.zip"


def build(source=SOURCE, dist=DIST):
    """Stages dist/attention-phone/ and writes the zip; returns (zip path, sha256 hex)."""
    manifest = validate_manifest(source)
    files = source_files(source)
    stage = dist / FOLDER
    if stage.is_symlink():
        raise PackageError(f"{stage} is a symlink")
    dist.mkdir(parents=True, exist_ok=True)
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    for name, content in files.items():
        (stage / name).write_bytes(content)
    validate_manifest(stage)
    data = zip_bytes(files)
    target = zip_path(dist, manifest["version"])
    target.write_bytes(data)
    return target, hashlib.sha256(data).hexdigest()


def read_archive(path):
    """Member name -> bytes for a built zip; refuses anything but the attention-phone/ layout."""
    try:
        with zipfile.ZipFile(path) as archive:
            members = {info.filename: archive.read(info) for info in archive.infolist() if not info.is_dir()}
    except (zipfile.BadZipFile, OSError) as failure:
        raise PackageError(f"{path} is not a readable zip: {failure}") from failure
    expected = {f"{FOLDER}/{name}" for name in FILES}
    if set(members) != expected:
        raise PackageError(f"{path.name} has the wrong layout; run build again")
    return members


def send_command(path, target):
    if not TAILSCALE_NAME.fullmatch(target):
        raise PackageError(f"{target!r} is not a tailscale device name")
    return ["tailscale", "file", "cp", str(path), f"{target}:"]


def send(target, yes, source=SOURCE, dist=DIST, run=subprocess.run, out=print):
    """Prints the exact Taildrop command; runs it only when `yes`. Returns the exit status."""
    manifest = validate_manifest(source)
    path = zip_path(dist, manifest["version"])
    if not path.is_file():
        raise PackageError(f"{path} does not exist; run `phone_package.py build` first")
    members = read_archive(path)
    current = source_files(source)
    if members != {f"{FOLDER}/{name}": content for name, content in current.items()}:
        raise PackageError(f"{path.name} is older than phone-package/attention-phone; run build again")
    command = send_command(path, target)
    out(shlex.join(command))
    if not yes:
        out("Not sent. Add --yes to run it.")
        return 0
    try:
        return run(command, check=False).returncode
    except FileNotFoundError as failure:
        raise PackageError("tailscale is not installed or not on PATH") from failure


def bold(text):
    """Bold on a terminal; plain text when output is piped."""
    return f"\033[1m{text}\033[0m" if sys.stdout.isatty() else text


def main(argv=None, run=subprocess.run, out=print, source=SOURCE, dist=DIST):
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build", help="stage dist/attention-phone and write the zip")
    sender = commands.add_parser("send", help="send the built zip with Taildrop")
    sender.add_argument("--to", required=True, metavar="TAILSCALE_NAME")
    sender.add_argument("--yes", action="store_true", help="actually run tailscale file cp")
    args = parser.parse_args(argv)
    try:
        out(bold(PHONE_ONLY))
        if args.command == "build":
            path, digest = build(source, dist)
            out(f"zip     {path}")
            out(f"sha256  {digest}")
            out("Next:   python3 tools/phone_package.py send --to <tailscale-name> --yes")
            out("Then on the phone: save the zip from Taildrop into Files › On My iPhone › Tern › Plugins,")
            out("replacing any older attention-phone folder there, unzip it (attention-phone/plugin.toml must sit")
            out("directly inside), then Reload plugins.")
            return 0
        return send(args.to, args.yes, source, dist, run, out)
    except PackageError as failure:
        print(f"phone_package: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
