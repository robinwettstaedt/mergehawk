from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import tempfile
import unittest


HELPER_PATH = Path(__file__).resolve().parents[2] / "scripts" / "verification-run.py"
SPEC = importlib.util.spec_from_file_location("verification_run", HELPER_PATH)
assert SPEC and SPEC.loader
verification_run = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verification_run)


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
        shutil.copyfile("/bin/sleep", executable)
        executable.chmod(0o755)
        control_executable = alias_runtime / "control-sleep"
        shutil.copyfile("/bin/sleep", control_executable)
        control_executable.chmod(0o755)
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
