#!/usr/bin/env python3
"""Small provenance helper for MergeHawk verification runs."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import uuid


SCHEMA_VERSION = 1
EXCLUDED_PREFIXES = (".verification/", "docs/plans/")


class VerificationError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.decode("utf-8", errors="replace").strip()
        raise VerificationError(message or f"git {' '.join(args)} failed")
    return result.stdout


def worktree_root(root: str | Path) -> Path:
    candidate = Path(root).expanduser().resolve()
    top_level = Path(git(candidate, "rev-parse", "--show-toplevel").decode().strip()).resolve()
    if top_level != candidate:
        raise VerificationError(f"root must be the git worktree root: {top_level}")
    return top_level


def slot_slug(logical_name: str) -> str:
    if not logical_name or logical_name.strip() != logical_name:
        raise VerificationError("slot name must be nonempty and have no surrounding whitespace")
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", logical_name).strip("-")
    if not slug:
        raise VerificationError("slot name must contain a letter or number")
    return slug[:48]


def slot_identity(root: Path, logical_name: str) -> dict[str, str]:
    path_hash = hashlib.sha256(os.fsencode(str(root))).hexdigest()[:10]
    logical_hash = hashlib.sha256(logical_name.encode("utf-8")).hexdigest()[:8]
    slug = slot_slug(logical_name)
    key = f"{slug}-{logical_hash}-{path_hash}"
    bundle_slug = re.sub(r"[^a-z0-9-]+", "-", slug.lower().replace("_", "-")).strip("-")
    return {
        "logical_name": logical_name,
        "key": key,
        "app_name": f"MergeHawk {key}.app",
        "bundle_id": f"com.mergehawk.app.verification.{path_hash}.{logical_hash}.{bundle_slug}",
        "executable_name": f"mergehawk-v-{logical_hash}-{path_hash}",
    }


def slot_dir(root: Path, identity: dict[str, str]) -> Path:
    return root / ".verification" / identity["key"]


def excluded(path: str) -> bool:
    normalized = path.replace(os.sep, "/")
    return any(normalized == prefix[:-1] or normalized.startswith(prefix) for prefix in EXCLUDED_PREFIXES)


def git_paths(root: Path) -> list[str]:
    tracked = git(root, "ls-files", "-z").split(b"\0")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    paths = {
        os.fsdecode(path)
        for path in tracked + untracked
        if path and not excluded(os.fsdecode(path))
    }
    return sorted(paths)


def hash_file_state(root: Path, relative_path: str) -> dict[str, str]:
    path = root / relative_path
    if path.is_symlink():
        return {"path": relative_path, "kind": "symlink", "sha256": hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()}
    if not path.exists():
        return {"path": relative_path, "kind": "missing", "sha256": ""}
    if not path.is_file():
        return {"path": relative_path, "kind": "other", "sha256": ""}
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": relative_path, "kind": "file", "sha256": digest.hexdigest()}


def source_state(root: Path) -> dict[str, object]:
    entries = [hash_file_state(root, path) for path in git_paths(root)]
    encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {
        "fingerprint": hashlib.sha256(encoded).hexdigest(),
        "entry_count": len(entries),
    }


def artifact_hash(path: Path) -> str:
    path = path.resolve()
    if not path.exists():
        raise VerificationError(f"artifact does not exist: {path}")
    digest = hashlib.sha256()
    if path.is_file():
        paths = [path]
        base = path.parent
    else:
        paths = sorted(item for item in path.rglob("*") if item.is_file() or item.is_symlink())
        base = path
    for item in paths:
        relative = item.relative_to(base).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        if item.is_symlink():
            content = os.fsencode(os.readlink(item))
        else:
            content = item.read_bytes()
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def atomic_write(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"expected an object in {path}")
    return value


def create_or_validate_slot(root: Path, logical_name: str) -> tuple[dict[str, object], Path]:
    identity = slot_identity(root, logical_name)
    directory = slot_dir(root, identity)
    record_path = directory / "slot.json"
    runtime_dir = directory / "runtime"
    expected: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "logical_name": logical_name,
        "key": identity["key"],
        "worktree": str(root),
        "app": {
            "name": identity["app_name"],
            "bundle_id": identity["bundle_id"],
            "executable_name": identity["executable_name"],
            "runtime_path": str(runtime_dir / identity["app_name"]),
        },
    }
    if record_path.exists():
        existing = load_json(record_path)
        for key in ("schema_version", "logical_name", "key", "worktree", "app"):
            if existing.get(key) != expected[key]:
                raise VerificationError(f"slot record does not match this worktree/slot: {record_path}")
        return existing, directory
    directory.mkdir(parents=True, exist_ok=True)
    expected["created_at"] = utc_now()
    atomic_write(record_path, expected)
    return expected, directory


def load_slot(root: Path, logical_name: str) -> tuple[dict[str, object], Path]:
    identity = slot_identity(root, logical_name)
    directory = slot_dir(root, identity)
    if not (directory / "slot.json").is_file():
        raise VerificationError(f"unknown verification slot: {logical_name}")
    return create_or_validate_slot(root, logical_name)


def begin(root: Path, logical_name: str) -> Path:
    slot, directory = create_or_validate_slot(root, logical_name)
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + f"-{uuid.uuid4().hex[:8]}"
    run_dir = directory / "runs" / run_id
    run_dir.mkdir(parents=True)
    (run_dir / "logs").mkdir()
    (run_dir / "screenshots").mkdir()
    (run_dir / "notifications.jsonl").touch()
    head = git(root, "rev-parse", "HEAD").decode().strip()
    created = utc_now()
    manifest: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "slot": {"logical_name": logical_name, "key": slot["key"]},
        "worktree": str(root),
        "git_head": head,
        "source": source_state(root),
        "created_at": created,
        "updated_at": created,
        "commands": {},
        "app": {},
    }
    atomic_write(run_dir / "manifest.json", manifest)
    return run_dir


def run_context(root: Path, logical_name: str, run_dir_value: str, check_source: bool = True) -> tuple[dict[str, object], dict[str, object], Path, Path]:
    slot, directory = load_slot(root, logical_name)
    run_dir = Path(run_dir_value).expanduser().resolve()
    expected_parent = (directory / "runs").resolve()
    if run_dir.parent != expected_parent:
        raise VerificationError(f"run directory is not owned by slot {logical_name}: {run_dir}")
    manifest_path = run_dir / "manifest.json"
    manifest = load_json(manifest_path)
    expected_slot = {"logical_name": logical_name, "key": slot["key"]}
    if manifest.get("slot") != expected_slot or manifest.get("worktree") != str(root):
        raise VerificationError("run manifest belongs to another slot or worktree")
    if check_source:
        current = source_state(root)
        recorded = manifest.get("source", {})
        if not isinstance(recorded, dict) or current["fingerprint"] != recorded.get("fingerprint"):
            raise VerificationError("source changed since this verification run began")
    return slot, manifest, run_dir, manifest_path


def record_start(root: Path, slot_name: str, run_dir: str, command: str, output_path: str | None) -> None:
    _, manifest, resolved_run, manifest_path = run_context(root, slot_name, run_dir)
    commands = manifest.setdefault("commands", {})
    if not isinstance(commands, dict):
        raise VerificationError("invalid commands in run manifest")
    if command in commands:
        raise VerificationError(f"command record already exists: {command}")
    reserved: str | None = None
    if output_path:
        candidate = (resolved_run / output_path).resolve()
        if resolved_run not in candidate.parents:
            raise VerificationError("output path must be inside the run directory")
        if candidate.exists():
            raise VerificationError(f"stage output path already exists: {candidate}")
        candidate.parent.mkdir(parents=True, exist_ok=True)
        reserved = str(candidate)
    commands[command] = {"status": "running", "started_at": utc_now(), "output_path": reserved}
    manifest["updated_at"] = utc_now()
    atomic_write(manifest_path, manifest)


def record_finish(root: Path, slot_name: str, run_dir: str, command: str, exit_code: int, files: list[str], details: list[str]) -> None:
    _, manifest, resolved_run, manifest_path = run_context(root, slot_name, run_dir)
    commands = manifest.get("commands", {})
    if not isinstance(commands, dict) or command not in commands:
        raise VerificationError(f"command was not started: {command}")
    record = commands[command]
    if not isinstance(record, dict) or record.get("status") != "running":
        raise VerificationError(f"command is already finished: {command}")
    normalized_files: list[str] = []
    for value in files:
        path = Path(value).expanduser().resolve()
        if resolved_run not in path.parents:
            raise VerificationError(f"recorded file must be inside the run directory: {path}")
        if not path.exists():
            raise VerificationError(f"recorded file does not exist: {path}")
        normalized_files.append(str(path.relative_to(resolved_run)))
    parsed_details: dict[str, str] = {}
    for detail in details:
        key, separator, value = detail.partition("=")
        if not separator or not key:
            raise VerificationError(f"detail must be key=value: {detail}")
        parsed_details[key] = value
    record.update(
        {
            "status": "success" if exit_code == 0 else "failed",
            "finished_at": utc_now(),
            "exit_code": exit_code,
            "files": sorted(set(normalized_files)),
            "details": parsed_details,
        }
    )
    manifest["updated_at"] = utc_now()
    atomic_write(manifest_path, manifest)


def record_app(root: Path, slot_name: str, run_dir: str, kind: str, values: dict[str, object]) -> None:
    _, manifest, _, manifest_path = run_context(root, slot_name, run_dir, check_source=False)
    app = manifest.setdefault("app", {})
    if not isinstance(app, dict):
        raise VerificationError("invalid app record")
    app[kind] = values
    manifest["updated_at"] = utc_now()
    atomic_write(manifest_path, manifest)


def identify_run(root: Path, run_dir_value: str) -> tuple[dict[str, object], dict[str, object], Path]:
    run_dir = Path(run_dir_value).expanduser().resolve()
    verification_root = (root / ".verification").resolve()
    if run_dir.parent.name != "runs" or run_dir.parent.parent.parent != verification_root:
        raise VerificationError(f"run directory is not under this worktree's verification root: {run_dir}")
    manifest = load_json(run_dir / "manifest.json")
    slot = load_json(run_dir.parent.parent / "slot.json")
    manifest_slot = manifest.get("slot")
    expected_slot = {"logical_name": slot.get("logical_name"), "key": slot.get("key")}
    if manifest.get("worktree") != str(root) or manifest_slot != expected_slot:
        raise VerificationError("run manifest and slot record do not agree")
    return slot, manifest, run_dir


def validate_app_bundle(
    root: Path,
    slot_name: str,
    run_dir_value: str,
    path_value: str,
    kind: str,
    fixtures: bool,
    require_recorded: bool,
) -> str:
    slot, manifest, run_dir, _ = run_context(root, slot_name, run_dir_value)
    app = slot.get("app")
    if not isinstance(app, dict):
        raise VerificationError("invalid app slot record")
    path = Path(path_value).expanduser().resolve()
    expected_path = (
        run_dir / "app" / str(app["name"])
        if kind == "packaged"
        else Path(str(app["runtime_path"])).resolve()
    )
    if path != expected_path:
        raise VerificationError(f"unexpected {kind} app path: {path}")
    plist_path = path / "Contents" / "Info.plist"
    executable_path = path / "Contents" / "MacOS" / str(app["executable_name"])
    if not plist_path.is_file() or not executable_path.is_file():
        raise VerificationError(f"incomplete app bundle: {path}")
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    if plist.get("CFBundleIdentifier") != app["bundle_id"]:
        raise VerificationError("app bundle identifier does not match the slot")
    if plist.get("CFBundleExecutable") != app["executable_name"]:
        raise VerificationError("app executable name does not match the slot")
    expected_environment = mock_launch_environment(run_dir, fixtures)
    if plist.get("LSEnvironment") != expected_environment:
        raise VerificationError("app LSEnvironment does not match this run's mock configuration")
    file_result = subprocess.run(
        ["file", "-b", str(executable_path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if file_result.returncode != 0 or "Mach-O" not in file_result.stdout:
        raise VerificationError(f"slot executable is not Mach-O: {executable_path}")
    digest = artifact_hash(path)
    if require_recorded:
        app_records = manifest.get("app")
        record = app_records.get(kind) if isinstance(app_records, dict) else None
        if not isinstance(record, dict):
            raise VerificationError(f"no recorded {kind} app for this run")
        expected_record = {
            "path": str(path),
            "bundle_id": app["bundle_id"],
            "executable_name": app["executable_name"],
            "mock": True,
            "notification_type_fixtures": fixtures,
            "artifact_sha256": digest,
        }
        for key, value in expected_record.items():
            if record.get(key) != value:
                raise VerificationError(f"recorded {kind} app does not match current {key}")
    return digest


def mock_launch_environment(run_dir: Path, fixtures: bool) -> dict[str, str]:
    environment = {
        "MERGEHAWK_MOCK_MODE": "1",
        "MERGEHAWK_MOCK_REFRESH_DELAY_SECONDS": "3",
        "MERGEHAWK_NOTIFICATION_LOG": str(run_dir / "notifications.jsonl"),
        "MERGEHAWK_SUPPRESS_MACOS_NOTIFICATIONS": "1",
    }
    if fixtures:
        environment["MERGEHAWK_NOTIFICATION_TYPE_FIXTURES"] = "1"
    return environment


def shell_launch_environment(run_dir: Path, fixtures: bool) -> str:
    environment = mock_launch_environment(run_dir, fixtures)
    return shlex.join(f"{key}={value}" for key, value in environment.items())


def validate_required_commands(manifest: dict[str, object], run_dir: Path, required: list[str]) -> None:
    commands = manifest.get("commands", {})
    if not isinstance(commands, dict):
        raise VerificationError("invalid commands in run manifest")
    for command in required:
        record = commands.get(command)
        if not isinstance(record, dict) or record.get("status") != "success":
            raise VerificationError(f"required command is not successful: {command}")
        if command == "app":
            details = record.get("details")
            if not isinstance(details, dict) or details.get("opened") != "1":
                raise VerificationError("required app command did not record an actual launch")
            app = manifest.get("app")
            if not isinstance(app, dict) or not isinstance(app.get("runtime"), dict):
                raise VerificationError("required app command has no recorded runtime identity")
        files = record.get("files")
        if not isinstance(files, list):
            raise VerificationError(f"required command has invalid evidence files: {command}")
        for relative_value in files:
            if not isinstance(relative_value, str):
                raise VerificationError(f"required command has invalid evidence files: {command}")
            path = (run_dir / relative_value).resolve()
            if run_dir not in path.parents or not path.exists():
                raise VerificationError(f"required command evidence is missing: {command}: {relative_value}")


def field_value(slot: dict[str, object], run_dir: Path | None, field: str) -> str:
    app = slot.get("app")
    if not isinstance(app, dict):
        raise VerificationError("invalid app slot record")
    values: dict[str, object] = {
        "slot-key": slot["key"],
        "logical-slot": slot["logical_name"],
        "app-name": app["name"],
        "bundle-id": app["bundle_id"],
        "executable-name": app["executable_name"],
        "runtime-app": app["runtime_path"],
    }
    if run_dir is not None:
        values.update(
            {
                "run-dir": str(run_dir),
                "notifications": str(run_dir / "notifications.jsonl"),
                "packaged-app": str(run_dir / "app" / str(app["name"])),
            }
        )
    if field not in values:
        raise VerificationError(f"unsupported field: {field}")
    return str(values[field])


def parse_app_values(args: argparse.Namespace) -> dict[str, object]:
    path = Path(args.path).expanduser().resolve()
    if not path.exists():
        raise VerificationError(f"app path does not exist: {path}")
    return {
        "path": str(path),
        "bundle_id": args.bundle_id,
        "executable_name": args.executable_name,
        "mock": args.mock,
        "notification_type_fixtures": args.notification_type_fixtures,
        "artifact_sha256": artifact_hash(path),
        "recorded_at": utc_now(),
    }


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    subparsers = parser.add_subparsers(dest="action", required=True)

    begin_parser = subparsers.add_parser("begin")
    begin_parser.add_argument("--slot", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--slot", required=True)
    validate_parser.add_argument("--run-dir", required=True)

    info_parser = subparsers.add_parser("info")
    info_parser.add_argument("--slot", required=True)
    info_parser.add_argument("--run-dir")
    info_parser.add_argument("--allow-stale", action="store_true")
    info_parser.add_argument("--field", required=True)

    identify_parser = subparsers.add_parser("identify")
    identify_parser.add_argument("--run-dir", required=True)
    identify_parser.add_argument("--field", required=True, choices=("logical-slot", "slot-key"))

    start_parser = subparsers.add_parser("start")
    start_parser.add_argument("--slot", required=True)
    start_parser.add_argument("--run-dir", required=True)
    start_parser.add_argument("--command", required=True)
    start_parser.add_argument("--output-path")

    finish_parser = subparsers.add_parser("finish")
    finish_parser.add_argument("--slot", required=True)
    finish_parser.add_argument("--run-dir", required=True)
    finish_parser.add_argument("--command", required=True)
    finish_parser.add_argument("--exit-code", required=True, type=int)
    finish_parser.add_argument("--file", action="append", default=[])
    finish_parser.add_argument("--detail", action="append", default=[])

    app_parser = subparsers.add_parser("record-app")
    app_parser.add_argument("--slot", required=True)
    app_parser.add_argument("--run-dir", required=True)
    app_parser.add_argument("--kind", required=True, choices=("packaged", "runtime"))
    app_parser.add_argument("--path", required=True)
    app_parser.add_argument("--bundle-id", required=True)
    app_parser.add_argument("--executable-name", required=True)
    app_parser.add_argument("--mock", action="store_true")
    app_parser.add_argument("--notification-type-fixtures", action="store_true")

    validate_app_parser = subparsers.add_parser("validate-app")
    validate_app_parser.add_argument("--slot", required=True)
    validate_app_parser.add_argument("--run-dir", required=True)
    validate_app_parser.add_argument("--kind", required=True, choices=("packaged", "runtime"))
    validate_app_parser.add_argument("--path", required=True)
    validate_app_parser.add_argument("--notification-type-fixtures", action="store_true")
    validate_app_parser.add_argument("--require-recorded", action="store_true")

    environment_parser = subparsers.add_parser("launch-environment")
    environment_parser.add_argument("--slot", required=True)
    environment_parser.add_argument("--run-dir", required=True)
    environment_parser.add_argument("--notification-type-fixtures", action="store_true")

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--slot", required=True)
    status_parser.add_argument("--run-dir", required=True)
    status_parser.add_argument("--require", action="append", default=[])

    hash_parser = subparsers.add_parser("artifact-hash")
    hash_parser.add_argument("--path", required=True)
    return parser


def main() -> int:
    args = make_parser().parse_args()
    try:
        root = worktree_root(args.root)
        if args.action == "begin":
            print(begin(root, args.slot))
        elif args.action == "validate":
            run_context(root, args.slot, args.run_dir)
            print(Path(args.run_dir).expanduser().resolve())
        elif args.action == "info":
            slot, _ = load_slot(root, args.slot)
            resolved_run = None
            if args.run_dir:
                slot, _, resolved_run, _ = run_context(root, args.slot, args.run_dir, check_source=False)
            print(field_value(slot, resolved_run, args.field))
        elif args.action == "identify":
            slot, _, _ = identify_run(root, args.run_dir)
            print(field_value(slot, None, args.field))
        elif args.action == "start":
            record_start(root, args.slot, args.run_dir, args.command, args.output_path)
        elif args.action == "finish":
            record_finish(root, args.slot, args.run_dir, args.command, args.exit_code, args.file, args.detail)
        elif args.action == "record-app":
            record_app(root, args.slot, args.run_dir, args.kind, parse_app_values(args))
        elif args.action == "validate-app":
            print(
                validate_app_bundle(
                    root,
                    args.slot,
                    args.run_dir,
                    args.path,
                    args.kind,
                    args.notification_type_fixtures,
                    args.require_recorded,
                )
            )
        elif args.action == "launch-environment":
            _, _, resolved_run, _ = run_context(root, args.slot, args.run_dir, check_source=False)
            print(shell_launch_environment(resolved_run, args.notification_type_fixtures))
        elif args.action == "status":
            _, manifest, resolved_run, _ = run_context(root, args.slot, args.run_dir)
            validate_required_commands(manifest, resolved_run, args.require)
            print(f"fresh: {resolved_run}")
        elif args.action == "artifact-hash":
            print(artifact_hash(Path(args.path).expanduser()))
        return 0
    except VerificationError as error:
        print(f"verification-run: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
