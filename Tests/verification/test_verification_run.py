from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import shlex
import subprocess
import tempfile
import time
import unittest


HELPER_PATH = Path(__file__).resolve().parents[2] / "scripts" / "verification-run.py"
SPEC = importlib.util.spec_from_file_location("verification_run", HELPER_PATH)
assert SPEC and SPEC.loader
verification_run = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verification_run)



def copy_signed_sleep(path: Path) -> None:
    """Copies /bin/sleep and ad-hoc signs it, since macOS kills an unsigned copy as soon as it runs."""
    shutil.copyfile("/bin/sleep", path)
    path.chmod(0o755)
    subprocess.run(
        ["codesign", "--force", "-s", "-", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

class VerificationRunTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="mergehawk verification tests ")
        self.addCleanup(self.temporary_directory.cleanup)
        self.base = Path(self.temporary_directory.name)

    def make_repo(self, name: str) -> Path:
        root = self.base / name
        root.mkdir()
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "tests@example.com"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Verification Tests"], check=True)
        (root / "source.txt").write_text("initial\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "initial"], check=True)
        return root.resolve()

    def prepare_launcher(self, name: str) -> tuple[Path, Path, dict[str, str], Path]:
        root = self.make_repo(name)
        scripts = root / "scripts"
        scripts.mkdir()
        for filename in ("verification-run.py", "run-agent-app.sh"):
            shutil.copy2(HELPER_PATH.with_name(filename), scripts / filename)
        run_dir = verification_run.begin(root, "review")
        slot, _, _, _ = verification_run.run_context(root, "review", str(run_dir))
        app = slot["app"]
        packaged = Path(verification_run.field_value(slot, run_dir, "packaged-app"))
        executable = packaged / "Contents" / "MacOS" / app["executable_name"]
        executable.parent.mkdir(parents=True)
        copy_signed_sleep(executable)
        with (packaged / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": app["bundle_id"],
                "CFBundleExecutable": app["executable_name"],
                "LSEnvironment": verification_run.mock_launch_environment(run_dir, False),
            }, handle)
        subprocess.run([
            str(scripts / "verification-run.py"), "--root", str(root), "record-app",
            "--slot", "review", "--run-dir", str(run_dir), "--kind", "packaged",
            "--path", str(packaged), "--bundle-id", app["bundle_id"],
            "--executable-name", app["executable_name"], "--mock",
        ], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stubs = self.base / f"{name} stubs"
        stubs.mkdir()
        calls = stubs / "open-calls.jsonl"
        pids = stubs / "pids.txt"
        open_stub = stubs / "open"
        open_stub.write_text("""#!/usr/bin/python3
import json, os, subprocess, sys
with open(os.environ["TEST_OPEN_CALLS"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
process = subprocess.Popen([os.environ["TEST_RUNTIME_EXECUTABLE"], "60"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with open(os.environ["TEST_PIDS"], "a") as log:
    log.write(str(process.pid) + "\\n")
""", encoding="utf-8")
        open_stub.chmod(0o755)
        for command, body in (("osascript", "exit 0"), ("sleep", "/bin/sleep 0.01")):
            stub = stubs / command
            stub.write_text(f"#!/usr/bin/env bash\n{body}\n", encoding="utf-8")
            stub.chmod(0o755)
        environment = dict(os.environ)
        environment.update({
            "PATH": f"{stubs}:{environment['PATH']}",
            "TEST_OPEN_CALLS": str(calls), "TEST_PIDS": str(pids),
            "TEST_RUNTIME_EXECUTABLE": str(Path(app["runtime_path"]) / "Contents" / "MacOS" / app["executable_name"]),
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        def cleanup_processes() -> None:
            if pids.exists():
                for value in pids.read_text().splitlines():
                    try:
                        os.kill(int(value), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        self.addCleanup(cleanup_processes)
        return root, run_dir, environment, calls

    def launch(self, root: Path, run_dir: Path, environment: dict[str, str], *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([
            str(root / "scripts" / "run-agent-app.sh"), "--slot", "review",
            "--run-dir", str(run_dir), *arguments,
        ], cwd=root, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)

    def test_launcher_default_menu_and_native_arguments_and_preserved_review_evidence(self) -> None:
        root, run_dir, environment, calls = self.prepare_launcher("launch surfaces")
        results = []
        manifests = []
        prior_evidence = {}
        for arguments in ((), ("--stage", "app-menu", "--ui", "menu"),
                          ("--stage", "app-review", "--ui", "native", "--mock-scenario", "long-lists")):
            result = self.launch(root, run_dir, environment, *arguments)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            results.append(json.loads(calls.read_text().splitlines()[-1]))
            manifests.append(json.loads((run_dir / "manifest.json").read_text()))
            for relative, content in prior_evidence.items():
                self.assertEqual((run_dir / relative).read_bytes(), content)
            prior_evidence = {
                relative: (run_dir / relative).read_bytes()
                for record in manifests[-1]["commands"].values() for relative in record["files"]
            }
        self.assertEqual(results[0][results[0].index("--verification-ui") + 1], "settings")
        self.assertEqual(results[1][results[1].index("--verification-ui") + 1], "menu")
        self.assertNotIn("--verification-ui", results[2])
        self.assertEqual(results[2][results[2].index("--mock-scenario") + 1], "long-lists")
        self.assertEqual(results[2][results[2].index("--notification-log") + 1], str(run_dir / "notifications-app-review.jsonl"))
        initial_log = (run_dir / "logs" / "app.log").read_bytes()
        initial_notification_log = (run_dir / "notifications.jsonl").read_bytes()
        self.assertEqual(manifests[0]["commands"]["app"], manifests[2]["commands"]["app"])
        self.assertEqual(manifests[1]["commands"]["app-menu"], manifests[2]["commands"]["app-menu"])
        for key in ("source", "slot"):
            self.assertEqual(manifests[0][key], manifests[2][key])
        self.assertEqual(manifests[0]["app"]["packaged"], manifests[2]["app"]["packaged"])
        for key in ("path", "bundle_id", "executable_name", "mock", "artifact_sha256"):
            self.assertEqual(manifests[0]["app"]["runtime"][key], manifests[2]["app"]["runtime"][key])
        runtime = Path(manifests[2]["app"]["runtime"]["path"])
        with (runtime / "Contents" / "Info.plist").open("rb") as handle:
            self.assertEqual(plistlib.load(handle)["LSEnvironment"], verification_run.mock_launch_environment(run_dir, False))
        review = manifests[2]["commands"]["app-review"]
        self.assertEqual(review["details"]["opened"], "1")
        self.assertEqual(review["details"]["ui"], "native")
        verification_run.validate_required_commands(manifests[2], run_dir, ["app-review"])
        rejected = self.launch(root, run_dir, environment, "--stage", "app-review", "--ui", "native")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("already exists", rejected.stderr)
        second = self.launch(root, run_dir, environment, "--stage", "app-review-2", "--ui", "native")
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        final = json.loads((run_dir / "manifest.json").read_text())
        self.assertEqual(final["commands"]["app-review"], review)
        self.assertEqual((run_dir / "logs" / "app.log").read_bytes(), initial_log)
        self.assertEqual((run_dir / "notifications.jsonl").read_bytes(), initial_notification_log)
        verification_run.validate_required_commands(final, run_dir, ["app-review-2"])
        with self.assertRaisesRegex(verification_run.VerificationError, "not successful"):
            verification_run.validate_required_commands(final, run_dir, ["app-review-3"])
        pids = [int(value) for value in Path(environment["TEST_PIDS"]).read_text().splitlines()]
        for pid in pids[:-1]:
            process = subprocess.run(["ps", "-p", str(pid), "-o", "command="], text=True, stdout=subprocess.PIPE)
            self.assertNotIn(environment["TEST_RUNTIME_EXECUTABLE"], process.stdout)
        self.assertIn(environment["TEST_RUNTIME_EXECUTABLE"], subprocess.run(
            ["ps", "-p", str(pids[-1]), "-o", "command="], text=True, stdout=subprocess.PIPE
        ).stdout)

    def test_launcher_unknown_ui_fails_before_creating_run(self) -> None:
        root = self.make_repo("unknown presentation")
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy2(HELPER_PATH.with_name("run-agent-app.sh"), scripts / "run-agent-app.sh")
        result = subprocess.run([str(scripts / "run-agent-app.sh"), "--ui", "unknown"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 2)
        self.assertIn("settings, menu or native", result.stderr)
        self.assertFalse((root / ".verification").exists())

    def test_launcher_native_preparation_is_not_review_launch(self) -> None:
        root, run_dir, environment, calls = self.prepare_launcher("prepare native")
        result = self.launch(root, run_dir, environment, "--stage", "app-review", "--ui", "native", "--no-open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(calls.exists())
        manifest = json.loads((run_dir / "manifest.json").read_text())
        self.assertEqual(manifest["commands"]["app-review"]["details"]["opened"], "0")
        self.assertIn("runtime", manifest["app"])
        with self.assertRaisesRegex(verification_run.VerificationError, "actual launch"):
            verification_run.validate_required_commands(manifest, run_dir, ["app-review"])

    def test_review_status_requires_native_presentation_and_runtime_identity(self) -> None:
        root = self.make_repo("review evidence")
        run_dir = verification_run.begin(root, "review")
        log = run_dir / "logs" / "app-review.log"
        log.write_text("review\n")
        for name in ("app-review", "app-review-2"):
            verification_run.record_start(root, "review", str(run_dir), name, None, app_launch=True)
            verification_run.record_finish(root, "review", str(run_dir), name, 0, [str(log)], ["opened=1", "ui=settings"])
        manifest = json.loads((run_dir / "manifest.json").read_text())
        for name in ("app-review", "app-review-2"):
            with self.assertRaisesRegex(verification_run.VerificationError, "native presentation"):
                verification_run.validate_required_commands(manifest, run_dir, [name])
            manifest["commands"][name]["details"]["ui"] = "native"
            with self.assertRaisesRegex(verification_run.VerificationError, "runtime identity"):
                verification_run.validate_required_commands(manifest, run_dir, [name])
        manifest["app"] = {"runtime": {"bundle_id": "review"}}
        with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
            verification_run.validate_required_commands(manifest, run_dir, ["app-review"])
        verification_run.validate_required_commands(manifest, run_dir, ["app-review-2"])

    def test_review_status_ignores_later_verification_and_screenshot_stages(self) -> None:
        root = self.make_repo("nonlaunch stages")
        run_dir = verification_run.begin(root, "review")
        log = run_dir / "logs" / "result.log"
        log.write_text("passed\n")
        verification_run.record_start(root, "review", str(run_dir), "app-review", None, app_launch=True)
        verification_run.record_finish(root, "review", str(run_dir), "app-review", 0,
                                       [str(log)], ["opened=1", "ui=native"])
        for name in ("verify", "screenshots"):
            verification_run.record_start(root, "review", str(run_dir), name, None)
            verification_run.record_finish(root, "review", str(run_dir), name, 0, [str(log)], [])
        manifest = json.loads((run_dir / "manifest.json").read_text())
        manifest["app"] = {"runtime": {"bundle_id": "review"}}
        verification_run.validate_required_commands(manifest, run_dir, ["app-review", "verify", "screenshots"])

    def test_launcher_later_menu_settings_and_preparation_supersede_native_review(self) -> None:
        root, run_dir, environment, _ = self.prepare_launcher("superseded review")
        review_name = "app-review"
        result = self.launch(root, run_dir, environment, "--stage", review_name, "--ui", "native")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for index, (stage, arguments) in enumerate((
            ("app-menu", ("--ui", "menu")),
            ("app-settings", ("--ui", "settings")),
            ("app-prepared", ("--ui", "native", "--no-open")),
        ), start=2):
            with self.subTest(stage=stage):
                result = self.launch(root, run_dir, environment, "--stage", stage, *arguments)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                manifest = json.loads((run_dir / "manifest.json").read_text())
                with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
                    verification_run.validate_required_commands(manifest, run_dir, [review_name])
                if stage == "app-prepared":
                    self.assertEqual(manifest["commands"][stage]["details"]["opened"], "0")
                previous_review = review_name
                review_name = f"app-review-{index}"
                result = self.launch(root, run_dir, environment, "--stage", review_name, "--ui", "native")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                manifest = json.loads((run_dir / "manifest.json").read_text())
                verification_run.validate_required_commands(manifest, run_dir, [review_name])
                with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
                    verification_run.validate_required_commands(manifest, run_dir, [previous_review])

    def record_native_review(self, root: Path, run_dir: Path, stage: str) -> dict[str, object]:
        log = run_dir / "logs" / f"{stage}.log"
        log.write_text("native review\n")
        verification_run.record_start(root, "review", str(run_dir), stage, None, app_launch=True)
        verification_run.record_finish(root, "review", str(run_dir), stage, 0, [str(log)], ["opened=1", "ui=native"])
        verification_run.record_app(root, "review", str(run_dir), "runtime", {"bundle_id": "review"})
        return json.loads((run_dir / "manifest.json").read_text())

    def test_interrupted_launcher_start_invalidates_review_without_finished_details(self) -> None:
        root = self.make_repo("interrupted launch")
        run_dir = verification_run.begin(root, "review")
        review_manifest = self.record_native_review(root, run_dir, "app-review")
        verification_run.validate_required_commands(review_manifest, run_dir, ["app-review"])
        verification_run.record_start(root, "review", str(run_dir), "app-interrupted", None, app_launch=True)
        manifest = json.loads((run_dir / "manifest.json").read_text())
        self.assertEqual(manifest["commands"]["app-interrupted"]["status"], "running")
        self.assertNotIn("details", manifest["commands"]["app-interrupted"])
        self.assertEqual(manifest["commands"]["app-review"], review_manifest["commands"]["app-review"])
        with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
            verification_run.validate_required_commands(manifest, run_dir, ["app-review"])
        next_manifest = self.record_native_review(root, run_dir, "app-review-2")
        verification_run.validate_required_commands(next_manifest, run_dir, ["app-review-2"])

    def test_actual_launcher_declares_ownership_before_interrupted_runtime_shutdown(self) -> None:
        root, run_dir, environment, _ = self.prepare_launcher("interrupted actual launcher")
        result = self.launch(root, run_dir, environment, "--stage", "app-review", "--ui", "native")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = json.loads((run_dir / "manifest.json").read_text())
        review_record = manifest["commands"]["app-review"]
        osascript = Path(environment["TEST_OPEN_CALLS"]).parent / "osascript"
        original_stub = osascript.read_text()
        shutdown_marker = osascript.with_name("shutdown-started")
        osascript.write_text(f"#!/usr/bin/env bash\ntouch {shlex.quote(str(shutdown_marker))}\n/bin/sleep 60\n")
        process = subprocess.Popen([
            str(root / "scripts" / "run-agent-app.sh"), "--slot", "review",
            "--run-dir", str(run_dir), "--stage", "app-interrupted", "--ui", "menu",
        ], cwd=root, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 20
            while not shutdown_marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(shutdown_marker.exists(), "launcher did not enter owned-runtime shutdown")
            interrupted = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual(interrupted["commands"]["app-interrupted"]["status"], "running")
            self.assertNotIn("details", interrupted["commands"]["app-interrupted"])
            self.assertEqual(interrupted["commands"]["app-review"], review_record)
            with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
                verification_run.validate_required_commands(interrupted, run_dir, ["app-review"])
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
            osascript.write_text(original_stub)
        result = self.launch(root, run_dir, environment, "--stage", "app-review-2", "--ui", "native")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        final = json.loads((run_dir / "manifest.json").read_text())
        self.assertEqual(final["commands"]["app-review"], review_record)
        verification_run.validate_required_commands(final, run_dir, ["app-review-2"])

    def test_new_run_launch_owns_slot_and_preserves_historical_review(self) -> None:
        root = self.make_repo("cross run launch")
        first_run = verification_run.begin(root, "review")
        first_manifest = self.record_native_review(root, first_run, "app-review")
        prior_files = {path: path.read_bytes() for path in first_run.rglob("*") if path.is_file()}
        second_run = verification_run.begin(root, "review")
        self.assertEqual(first_manifest["source"], json.loads((second_run / "manifest.json").read_text())["source"])
        verification_run.validate_required_commands(first_manifest, first_run, ["app-review"])
        verification_run.record_start(root, "review", str(second_run), "app-review", None, app_launch=True)
        with self.assertRaisesRegex(verification_run.VerificationError, "latest slot launch"):
            verification_run.validate_required_commands(first_manifest, first_run, ["app-review"])
        latest_path = first_run.parent.parent / "latest-launch.json"
        latest = latest_path.read_bytes()
        with self.assertRaisesRegex(verification_run.VerificationError, "already exists"):
            verification_run.record_start(root, "review", str(first_run), "app-review", None, app_launch=True)
        self.assertEqual(latest_path.read_bytes(), latest)
        verification_run.record_start(root, "review", str(second_run), "ui", None)
        self.assertEqual(latest_path.read_bytes(), latest)
        next_manifest = self.record_native_review(root, second_run, "app-review-2")
        verification_run.validate_required_commands(next_manifest, second_run, ["app-review-2"])
        for path, content in prior_files.items():
            self.assertEqual(path.read_bytes(), content)

    def test_same_logical_slot_has_distinct_worktree_keys(self) -> None:
        first = self.make_repo("first repo")
        second = self.make_repo("second repo")

        first_key = verification_run.slot_identity(first, "review")["key"]
        second_key = verification_run.slot_identity(second, "review")["key"]

        self.assertNotEqual(first_key, second_key)
        self.assertTrue(first_key.startswith("review-"))

        first_run = verification_run.begin(first, "review")
        verification_run.begin(second, "review")
        with self.assertRaisesRegex(verification_run.VerificationError, "not owned"):
            verification_run.run_context(second, "review", str(first_run))

    def test_normalization_and_case_collisions_remain_distinct(self) -> None:
        root = self.make_repo("collision repo")

        identities = [
            verification_run.slot_identity(root, name)
            for name in ("MER-12", "mer-12", "MER 12", "MER@12")
        ]

        self.assertEqual(len({identity["key"].lower() for identity in identities}), 4)
        self.assertEqual(len({identity["bundle_id"] for identity in identities}), 4)
        self.assertEqual(len({identity["executable_name"] for identity in identities}), 4)

    def test_distinct_runs_preserve_earlier_files(self) -> None:
        root = self.make_repo("repo with spaces")
        first = verification_run.begin(root, "review")
        evidence = first / "logs" / "result.txt"
        evidence.write_text("first run\n", encoding="utf-8")

        second = verification_run.begin(root, "review")

        self.assertNotEqual(first, second)
        self.assertEqual(evidence.read_text(encoding="utf-8"), "first run\n")

    def test_same_status_dirty_edit_invalidates_source(self) -> None:
        root = self.make_repo("dirty repo")
        source = root / "source.txt"
        source.write_text("first dirty value\n", encoding="utf-8")
        run_dir = verification_run.begin(root, "review")
        first_status = subprocess.run(
            ["git", "-C", str(root), "status", "--short"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout

        source.write_text("second dirty value\n", encoding="utf-8")
        second_status = subprocess.run(
            ["git", "-C", str(root), "status", "--short"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout

        self.assertEqual(first_status, second_status)
        with self.assertRaisesRegex(verification_run.VerificationError, "source changed"):
            verification_run.run_context(root, "review", str(run_dir))

    def test_chmod_invalidates_source_and_artifact_fingerprints(self) -> None:
        root = self.make_repo("mode repo")
        source = root / "source.txt"
        source.chmod(0o644)
        run_dir = verification_run.begin(root, "review")
        artifact_before = verification_run.artifact_hash(source)

        source.chmod(0o755)

        with self.assertRaisesRegex(verification_run.VerificationError, "source changed"):
            verification_run.run_context(root, "review", str(run_dir))
        self.assertNotEqual(artifact_before, verification_run.artifact_hash(source))

    def test_app_validation_rejects_other_execute_without_owner_execute(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("effective root bypasses current-user execute permission checks")
        root = self.make_repo("nonexecutable app repo")
        run_dir = verification_run.begin(root, "review")
        slot, _, resolved_run, _ = verification_run.run_context(root, "review", str(run_dir))
        app = slot["app"]
        bundle = resolved_run / "app" / app["name"]
        executable = bundle / "Contents" / "MacOS" / app["executable_name"]
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"not executable")
        executable.chmod(0o601)
        self.assertFalse(os.access(executable, os.X_OK))
        with (bundle / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": app["bundle_id"],
                    "CFBundleExecutable": app["executable_name"],
                    "LSEnvironment": verification_run.mock_launch_environment(resolved_run, False),
                },
                handle,
            )

        with self.assertRaisesRegex(verification_run.VerificationError, "not executable"):
            verification_run.validate_app_bundle(
                root,
                "review",
                str(run_dir),
                str(bundle),
                "packaged",
                False,
                False,
            )

    def test_failed_stage_cannot_be_reused_or_changed_to_success(self) -> None:
        root = self.make_repo("failed capture")
        run_dir = verification_run.begin(root, "review")
        verification_run.record_start(root, "review", str(run_dir), "ui", "screenshots/ui")
        stage_dir = run_dir / "screenshots" / "ui"
        stage_dir.mkdir()
        partial = stage_dir / "partial.png"
        partial.write_bytes(b"partial")
        verification_run.record_finish(root, "review", str(run_dir), "ui", 1, [str(partial)], [])

        with self.assertRaisesRegex(verification_run.VerificationError, "already exists"):
            verification_run.record_start(root, "review", str(run_dir), "ui", "screenshots/ui")
        with self.assertRaisesRegex(verification_run.VerificationError, "already finished"):
            verification_run.record_finish(root, "review", str(run_dir), "ui", 0, [str(partial)], [])

        manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["commands"]["ui"]["status"], "failed")

    def test_paths_with_spaces_round_trip_in_run_metadata(self) -> None:
        root = self.make_repo("worktree with spaces")
        run_dir = verification_run.begin(root, "Visual Review")
        slot, _, resolved_run, _ = verification_run.run_context(root, "Visual Review", str(run_dir))

        notification_path = verification_run.field_value(slot, resolved_run, "notifications")
        packaged_path = verification_run.field_value(slot, resolved_run, "packaged-app")

        self.assertEqual(notification_path, str(run_dir / "notifications.jsonl"))
        self.assertIn("worktree with spaces", notification_path)
        self.assertIn("MergeHawk Visual-Review-", packaged_path)

        expected_environment = verification_run.mock_launch_environment(resolved_run, fixtures=True)
        emitted_environment = verification_run.shell_launch_environment(resolved_run, fixtures=True)
        parsed_environment = dict(assignment.split("=", 1) for assignment in shlex.split(emitted_environment))
        self.assertEqual(parsed_environment, expected_environment)
        self.assertEqual(parsed_environment["MERGEHAWK_NOTIFICATION_LOG"], notification_path)

    def test_identity_lookup_does_not_rehash_source(self) -> None:
        root = self.make_repo("identity repo")
        run_dir = verification_run.begin(root, "review")
        original_source_state = verification_run.source_state
        verification_run.source_state = lambda _: (_ for _ in ()).throw(AssertionError("source was rehashed"))
        try:
            slot, _, resolved_run, _ = verification_run.run_context(
                root,
                "review",
                str(run_dir),
                check_source=False,
            )
            self.assertEqual(verification_run.field_value(slot, resolved_run, "run-dir"), str(run_dir))
        finally:
            verification_run.source_state = original_source_state

    def test_status_requires_actual_app_launch(self) -> None:
        root = self.make_repo("prepare only repo")
        run_dir = verification_run.begin(root, "review")
        log = run_dir / "logs" / "app.log"
        log.write_text("prepared\n", encoding="utf-8")
        verification_run.record_start(root, "review", str(run_dir), "app", None)
        verification_run.record_finish(
            root,
            "review",
            str(run_dir),
            "app",
            0,
            [str(log)],
            ["opened=0"],
        )
        manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))

        with self.assertRaisesRegex(verification_run.VerificationError, "actual launch"):
            verification_run.validate_required_commands(manifest, run_dir, ["app"])

    def test_status_rejects_missing_recorded_evidence(self) -> None:
        root = self.make_repo("missing evidence repo")
        run_dir = verification_run.begin(root, "review")
        log = run_dir / "logs" / "verify.log"
        log.write_text("passed\n", encoding="utf-8")
        verification_run.record_start(root, "review", str(run_dir), "verify", None)
        verification_run.record_finish(
            root,
            "review",
            str(run_dir),
            "verify",
            0,
            [str(log)],
            [],
        )
        log.unlink()
        manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))

        with self.assertRaisesRegex(verification_run.VerificationError, "evidence is missing"):
            verification_run.validate_required_commands(manifest, run_dir, ["verify"])

    def test_ui_rejects_reserved_command_stage_names(self) -> None:
        verify_ui = HELPER_PATH.with_name("verify-ui.sh")
        for reserved_name in ("verify", "app"):
            result = subprocess.run(
                [str(verify_ui), "--stage", reserved_name],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(f"Reserved UI stage name: {reserved_name}", result.stderr)

    def test_teardown_targets_only_exact_slot_and_preserves_runs(self) -> None:
        root = self.make_repo("teardown repo")
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy2(HELPER_PATH, scripts / "verification-run.py")
        teardown_source = HELPER_PATH.with_name("teardown-agent-app.sh")
        if not teardown_source.exists():
            self.skipTest("teardown script is not available yet")
        shutil.copy2(teardown_source, scripts / "teardown-agent-app.sh")
        (scripts / "teardown-agent-app.sh").chmod(0o755)
        run_dir = verification_run.begin(root, "Agent-3")
        identity = verification_run.slot_identity(root, "Agent-3")
        exact_slot = root / ".verification" / identity["key"]
        runtime = exact_slot / "runtime"
        runtime.mkdir()
        (runtime / "owned.txt").write_text("owned", encoding="utf-8")
        alias_runtime = root / ".verification" / identity["key"].lower().replace("-", "") / "runtime"
        alias_runtime.mkdir(parents=True)
        (alias_runtime / "unrelated.txt").write_text("keep", encoding="utf-8")

        stubs = self.base / "command stubs"
        stubs.mkdir()
        osascript_stub = stubs / "osascript"
        osascript_stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        osascript_stub.chmod(0o755)
        sleep_stub = stubs / "sleep"
        sleep_stub.write_text("#!/usr/bin/env bash\n/bin/sleep 0.01\n", encoding="utf-8")
        sleep_stub.chmod(0o755)
        environment = dict(**__import__("os").environ)
        environment["PATH"] = f"{stubs}:{environment['PATH']}"
        subprocess.run(
            [str(scripts / "teardown-agent-app.sh"), "--run-dir", str(run_dir)],
            cwd=root,
            env=environment,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        self.assertFalse(runtime.exists())
        self.assertTrue(alias_runtime.exists())
        self.assertTrue((run_dir / "manifest.json").exists())

        slot_record = json.loads((exact_slot / "slot.json").read_text(encoding="utf-8"))
        runtime_app = Path(slot_record["app"]["runtime_path"])
        executable = runtime_app / "Contents" / "MacOS" / slot_record["app"]["executable_name"]
        executable.parent.mkdir(parents=True)
        copy_signed_sleep(executable)
        control_executable = alias_runtime / "control-sleep"
        copy_signed_sleep(control_executable)
        processes = [
            subprocess.Popen([str(executable), "60"]),
            subprocess.Popen([str(executable), "60"]),
        ]
        control_process = subprocess.Popen([str(control_executable), "60"])
        (runtime / "pid").write_text(f"{processes[0].pid}\n", encoding="utf-8")
        try:
            subprocess.run(
                [str(scripts / "teardown-agent-app.sh"), "--slot", "Agent-3"],
                cwd=root,
                env=environment,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for process in processes:
                process.wait(timeout=2)
            self.assertIsNone(control_process.poll())
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=2)
            if control_process.poll() is None:
                control_process.terminate()
                control_process.wait(timeout=2)
        self.assertFalse(runtime.exists())
        self.assertTrue(alias_runtime.exists())
        self.assertTrue((run_dir / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
