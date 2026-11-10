"""Meaningful integration tests. Every write is confined to a temporary fake home."""

import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import importlib.util


HELPER = Path(__file__).resolve().parents[1] / "Resources/lidglow-hook.py"


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name).resolve() / "home"
        self.home.mkdir()
        self.data = self.home / "Library/Application Support/LidGlow"
        self.env = dict(os.environ, LIDGLOW_HOME=str(self.home), LIDGLOW_DATA_DIR=str(self.data))

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, *args, payload="", code=0):
        result = subprocess.run([sys.executable, str(HELPER), *args], env=self.env,
                                input=payload, text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def manage(self, command, agent="codex", code=0):
        return json.loads(self.run_helper(command, "--agent", agent, code=code))

    def settings(self, agent="codex"):
        return self.home / (".codex/hooks.json" if agent == "codex" else ".claude/settings.json")

    def write_settings(self, obj, agent="codex"):
        path = self.settings(agent)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(obj))

    def events(self):
        directory = self.data / "events"
        return list(directory.glob("*.json")) if directory.exists() else []

    def test_snapshot_has_only_status_and_hashed_identity(self):
        secret = "private prompt and code should never appear"
        original = {"session_id": "sensitive-session", "prompt": secret,
                    "tool_input": {"command": "cat secret-key"}, "cwd": "/private/project"}
        output = self.run_helper("event", "--source", "codex", "--state", "working",
                                 "--lidglow-hook", payload=json.dumps(original))
        self.assertEqual(output, "")
        paths = self.events()
        self.assertEqual(len(paths), 1)
        snapshot = json.loads(paths[0].read_text())
        self.assertEqual(set(snapshot), {"source", "session_id", "state", "timestamp"})
        self.assertEqual(snapshot["session_id"], hashlib.sha256(b"sensitive-session").hexdigest()[:24])
        self.assertEqual(snapshot["state"], "working")
        self.assertNotIn(secret, paths[0].read_text())
        self.assertNotIn("sensitive-session", paths[0].read_text())
        self.assertEqual(paths[0].stat().st_mode & 0o777, 0o600)

    def test_malformed_inputs_are_silent_and_do_not_emit(self):
        for payload in ("bad json", "[]", "null", "{}", '{"session_id": null}',
                        '{"session_id": ""}', '{"session_id": 123}', "x" * (1024 * 1024 + 1)):
            output = self.run_helper("event", "--source", "claude", "--state", "working", payload=payload)
            self.assertEqual(output, "")
        self.assertEqual(self.events(), [])

    def test_write_failure_does_not_fail_hook(self):
        self.data.parent.mkdir(parents=True)
        self.data.write_text("not a directory")
        self.assertEqual(self.run_helper("event", "--source", "codex", "--state", "complete",
                                        payload='{"session_id":"x"}'), "")

    def test_preserves_unrelated_settings_and_idempotent_install(self):
        user_handler = {"type": "command", "command": "echo existing"}
        user_group = {"matcher": "Bash", "hooks": [user_handler]}
        original = {"theme": "dark", "env": {"ONE": "two"},
                    "hooks": {"PreToolUse": [user_group], "OtherEvent": [{"hooks": [user_handler]}]}}
        for agent in ("codex", "claude"):
            self.write_settings(original, agent)
            self.assertTrue(self.manage("install", agent)["installed"])
            first = self.settings(agent).read_bytes()
            self.assertTrue(self.manage("install", agent)["installed"])
            self.assertEqual(self.settings(agent).read_bytes(), first)
            config = json.loads(first)
            self.assertEqual(config["theme"], "dark")
            self.assertEqual(config["env"], {"ONE": "two"})
            self.assertEqual(config["hooks"]["PreToolUse"][0], user_group)
            self.assertTrue(self.manage("status", agent)["installed"])
            self.assertFalse(self.manage("uninstall", agent)["installed"])
            self.assertEqual(json.loads(self.settings(agent).read_text()), original)
            self.assertFalse(self.manage("status", agent)["installed"])
            backups = list(self.settings(agent).parent.glob("*.lidglow-backup-*"))
            self.assertEqual(len(backups), 2)
            self.assertEqual(json.loads(backups[0].read_text())["theme"], "dark")

    def test_uninstall_only_our_handler_in_mixed_group(self):
        self.manage("install")
        config = json.loads(self.settings().read_text())
        other = {"type": "command", "command": "echo --lidglow-hook"}
        config["hooks"]["Stop"][0]["hooks"].append(other)
        self.write_settings(config)
        self.manage("uninstall")
        remaining = json.loads(self.settings().read_text())
        self.assertEqual(remaining, {"hooks": {"Stop": [{"hooks": [other]}]}})

    def test_status_is_readonly_and_requires_helper_and_complete_configuration(self):
        before = list(self.home.rglob("*"))
        self.assertFalse(self.manage("status")["installed"])
        self.assertEqual(list(self.home.rglob("*")), before)
        self.manage("install")
        helper = self.data / "lidglow-hook.py"
        helper.unlink()
        config_bytes = self.settings().read_bytes()
        before = set(self.home.rglob("*"))
        result = self.manage("status")
        self.assertFalse(result["installed"])
        self.assertIn("Install hooks", result["message"])
        self.assertEqual(self.settings().read_bytes(), config_bytes)
        self.assertEqual(set(self.home.rglob("*")), before)
        self.manage("install")
        self.assertTrue(self.manage("status")["installed"])
        config = json.loads(self.settings().read_text())
        del config["hooks"]["Stop"]
        self.write_settings(config)
        result = self.manage("status")
        self.assertFalse(result["installed"])
        self.assertIn("incomplete", result["message"])
        self.manage("install")
        config = json.loads(self.settings().read_text())
        config["hooks"]["Stop"][0]["hooks"][0]["command"] = config["hooks"]["Stop"][0]["hooks"][0]["command"].replace("--state complete", "--state working")
        self.write_settings(config)
        self.assertFalse(self.manage("status")["installed"])
        self.manage("install")
        config = json.loads(self.settings().read_text())
        config["hooks"]["PreToolUse"][0]["matcher"] = "Bash"
        self.write_settings(config)
        self.assertFalse(self.manage("status")["installed"])
        self.manage("install")
        result = self.manage("status")
        self.assertTrue(result["installed"])
        self.assertIn("Trust is not checked", result["message"])

    def test_invalid_existing_json_is_untouched(self):
        path = self.settings()
        path.parent.mkdir()
        for invalid in (b"{broken", b"[]", b'{"hooks":[]}', b'{"hooks":{"Stop":"bad"}}',
                        b'{"hooks":{"Stop":[null]}}', b'{"hooks":{"Stop":[{}]}}',
                        b'{"hooks":{"Stop":[{"hooks":[4]}]}}',
                        b'{"hooks":{"Stop":[{"hooks":[],"matcher":[]}]}}',
                        b'{"hooks":{},"hooks":{}}', b'{"number":NaN}'):
            path.write_bytes(invalid)
            result = self.manage("install", code=1)
            self.assertFalse(result["ok"])
            self.assertEqual(path.read_bytes(), invalid)
            self.assertFalse(list(path.parent.glob("*.lidglow-backup-*")))

    def test_preserves_preexisting_empty_hooks_and_arrays(self):
        original = {"hooks": {"UnrelatedEvent": [], "EmptyGroup": [{"hooks": []}]}, "other": {"keep": []}}
        self.write_settings(original)
        self.manage("install")
        self.manage("uninstall")
        self.assertEqual(json.loads(self.settings().read_text()), original)
        self.write_settings({"hooks": {}})
        self.manage("install")
        self.manage("uninstall")
        self.assertEqual(json.loads(self.settings().read_text()), {"hooks": {}})

    def test_exponent_overflow_config_is_rejected_without_rewriting_settings(self):
        for agent in ("codex", "claude"):
            path = self.settings(agent)
            path.parent.mkdir(parents=True)
            for number in (b"1e999", b"-1e999", b"1.8E308"):
                original = b'{"unrelated":{"number":' + number + b'},"hooks":{}}'
                path.write_bytes(original)
                for action in ("install", "uninstall", "status"):
                    result = self.manage(action, agent, code=1)
                    self.assertFalse(result["ok"])
                    self.assertEqual(path.read_bytes(), original)
                self.assertFalse(list(path.parent.glob("*.lidglow-backup-*")))
        self.assertFalse(self.data.exists(), "Rejected settings must not install helper files")

        # Serialization is a second boundary if future management code introduces
        # a nonfinite value after parsing a valid configuration.
        spec = importlib.util.spec_from_file_location("lidglow_overflow_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        path = self.settings()
        original = b'{"keep":true}'
        path.write_bytes(original)
        for number in (float("inf"), float("-inf"), float("nan")):
            with self.assertRaises(ValueError):
                module.save_config(path, {"keep": True, "number": number}, original)
            self.assertEqual(path.read_bytes(), original)

    def test_nonregular_config_and_bounded_management_lock(self):
        path = self.settings()
        path.parent.mkdir()
        os.mkfifo(path)
        start = time.monotonic()
        self.assertFalse(self.manage("install", code=1)["ok"])
        self.assertLess(time.monotonic() - start, 2)
        self.assertTrue(path.is_fifo())
        path.unlink()
        lock = path.parent / ".lidglow.lock"
        with lock.open("a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            start = time.monotonic()
            result = self.manage("install", code=1)
            self.assertIn("still running", result["message"])
            self.assertLess(time.monotonic() - start, 2)
        self.assertFalse(path.exists())

    def test_oversized_config_rejected_without_backup(self):
        path = self.settings()
        path.parent.mkdir()
        with path.open("wb") as handle:
            handle.truncate(8 * 1024 * 1024 + 1)
        self.assertFalse(self.manage("install", code=1)["ok"])
        self.assertEqual(path.stat().st_size, 8 * 1024 * 1024 + 1)
        self.assertFalse(list(path.parent.glob("*.lidglow-backup-*")))

    def test_hardlinked_config_is_not_replaced(self):
        original = self.home / "outside-settings.json"
        original.write_text('{"keep":true}')
        path = self.settings()
        path.parent.mkdir()
        os.link(original, path)
        self.assertFalse(self.manage("install", code=1)["ok"])
        self.assertEqual(path.read_bytes(), original.read_bytes())
        self.assertEqual(path.stat().st_ino, original.stat().st_ino)

    def test_detects_external_settings_edit_during_backup(self):
        spec = importlib.util.spec_from_file_location("lidglow_hook_test", HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = b'{"keep":"original"}'
        external = b'{"keep":"external edit"}'
        path = self.settings()
        path.parent.mkdir()
        path.write_bytes(original)
        original_atomic = module.atomic_bytes
        def competing_write(destination, content, *args, **kwargs):
            result = original_atomic(destination, content, *args, **kwargs)
            if ".lidglow-backup-" in destination.name:
                path.write_bytes(external)
            return result
        with mock.patch.object(module, "atomic_bytes", side_effect=competing_write):
            with self.assertRaisesRegex(ValueError, "changed during"):
                module.save_config(path, {"keep": "original", "new": True}, original)
        self.assertEqual(path.read_bytes(), external)

    @unittest.skipUnless(os.environ.get("LIDGLOW_SIGNAL_BINARY"), "native helper binary not supplied")
    def test_native_install_status_repair_and_selective_uninstall(self):
        binary = str(Path(os.environ["LIDGLOW_SIGNAL_BINARY"]).resolve())
        original = {"theme": "dark", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo keep"}]}]}}
        self.write_settings(original)
        args = ("install", "--agent", "codex", "--native-helper", binary)
        self.assertTrue(json.loads(self.run_helper(*args))["installed"])
        installed = self.data / "lidglow-signal"
        self.assertEqual(installed.stat().st_mode & 0o777, 0o700)
        config = json.loads(self.settings().read_text())
        command = config["hooks"]["Stop"][-1]["hooks"][0]["command"]
        self.assertNotIn("python", command)
        result = subprocess.run(command, shell=True, env=self.env,
                                input='{"session_id":"native install"}', capture_output=True, text=True, timeout=2)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(json.loads(self.events()[0].read_text())["state"], "complete")
        before_end = self.events()[0].read_bytes()
        end_command = config["hooks"]["SessionEnd"][0]["hooks"][0]["command"]
        end = subprocess.run(end_command, shell=True, env=self.env,
                             input='{"session_id":"native install"}', capture_output=True, text=True, timeout=2)
        self.assertEqual((end.returncode, end.stdout, end.stderr), (0, "", ""))
        self.assertEqual(self.events()[0].read_bytes(), before_end)
        self.assertTrue(self.manage("status")["installed"])
        before = self.settings().read_bytes()
        self.run_helper(*args)
        self.assertEqual(self.settings().read_bytes(), before)
        installed.unlink()
        self.assertFalse(self.manage("status")["installed"])
        self.run_helper(*args)
        self.assertTrue(self.manage("status")["installed"])
        self.manage("uninstall")
        self.assertEqual(json.loads(self.settings().read_text()), original)
        self.assertFalse(self.manage("status")["installed"])

    def test_rejects_non_native_install_argument(self):
        self.write_settings({"keep": True})
        original = self.settings().read_bytes()
        result = json.loads(self.run_helper("install", "--agent", "codex", "--native-helper", str(HELPER), code=1))
        self.assertIn("not a native", result["message"])
        self.assertEqual(self.settings().read_bytes(), original)

    def test_only_session_end_preserves_finish_and_old_install_repairs(self):
        for agent in ("codex", "claude"):
            self.manage("install", agent)
            config = json.loads(self.settings(agent).read_text())
            for event, groups in config["hooks"].items():
                for group in groups:
                    for handler in group["hooks"]:
                        self.assertEqual("--preserve-finish" in handler["command"], event == "SessionEnd")
            end = config["hooks"]["SessionEnd"][0]["hooks"][0]
            end["command"] = end["command"].replace(" --preserve-finish", "")
            self.write_settings(config, agent)
            self.assertFalse(self.manage("status", agent)["installed"])
            self.manage("install", agent)
            self.assertTrue(self.manage("status", agent)["installed"])
            installed = self.settings(agent).read_bytes()
            self.manage("install", agent)
            self.assertEqual(self.settings(agent).read_bytes(), installed)

    def test_installed_helper_command_handles_spaces_and_real_stdin(self):
        self.manage("install", "claude")
        config = json.loads(self.settings("claude").read_text())
        command = config["hooks"]["Stop"][0]["hooks"][0]["command"]
        result = subprocess.run(command, shell=True, env=self.env,
                                input='{"session_id":"session with spaces"}',
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(json.loads(self.events()[0].read_text())["state"], "complete")
        self.assertEqual(config["hooks"]["Notification"][0]["matcher"], "permission_prompt|idle_prompt")

    def test_concurrent_install_and_events_stay_valid(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            tasks = [pool.submit(self.manage, "install") for _ in range(6)]
            for task in tasks:
                self.assertTrue(task.result()["ok"])
        config = json.loads(self.settings().read_text())
        self.assertTrue(all(len(groups) == 1 for groups in config["hooks"].values()))
        def send(index):
            return self.run_helper("emit", "--source", "custom", "--state", "working",
                                   "--session", str(index % 4))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(list(pool.map(send, range(24))), [""] * 24)
        self.assertEqual(len(self.events()), 4)
        for path in self.events():
            self.assertEqual(json.loads(path.read_text())["state"], "working")

    def test_rejects_config_and_data_symlinks(self):
        outside = self.home / "outside.json"
        outside.write_text('{"keep":true}')
        path = self.settings()
        path.parent.mkdir()
        path.symlink_to(outside)
        self.assertFalse(self.manage("install", code=1)["ok"])
        self.assertEqual(outside.read_text(), '{"keep":true}')
        self.data.parent.mkdir(parents=True, exist_ok=True)
        target = self.home / "other-data"
        target.mkdir()
        self.data.symlink_to(target)
        self.assertEqual(self.run_helper("emit", "--source", "custom", "--state", "working"), "")
        self.assertEqual(list(target.iterdir()), [])

    def test_snapshot_count_bounded_and_old_files_pruned(self):
        directory = self.data / "events"
        directory.mkdir(parents=True)
        for index in range(260):
            (directory / (str(index) + ".json")).write_text("{}")
        old = directory / "old.json"
        old.write_text("{}")
        os.utime(old, (1, 1))
        self.run_helper("emit", "--source", "custom", "--state", "complete")
        self.assertFalse(old.exists())
        self.assertLessEqual(len(self.events()), 256)


class SignalTests(unittest.TestCase):
    setUp = HookTests.setUp
    tearDown = HookTests.tearDown
    events = HookTests.events

    def signal(self, *args, payload=b"", timeout=2):
        prefix = getattr(self, "prefix", [sys.executable, str(HELPER)])
        if isinstance(payload, str):
            payload = payload.encode()
        result = subprocess.run(prefix + list(args), env=self.env, input=payload,
                                capture_output=True, timeout=timeout)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
        return result

    def test_input_types_sizes_and_unicode_hash(self):
        for value in (None, [], 12, True, {}, {"session_id": None}, {"session_id": []},
                      {"session_id": 3}, {"session_id": True}, {"session_id": ""},
                      {"session_id": "x" * 4097}):
            self.signal("event", "--source", "codex", "--state", "working", payload=json.dumps(value))
        for payload in (b"bad json", b"\xff", b"[" * 10000,
                        json.dumps({"session_id": "large", "prompt": "x" * (1024 * 1024)})):
            self.signal("event", "--source", "codex", "--state", "working", payload=payload)
        self.assertEqual(self.events(), [])
        session = "a\u0301 / 日本語 🔆"
        for source in ("codex", "claude"):
            self.signal("event", "--source", source, "--state", "working",
                        payload=json.dumps({"session_id": session, "prompt": "DO NOT KEEP"}))
        self.assertEqual(len(self.events()), 2)
        for path in self.events():
            obj = json.loads(path.read_text())
            self.assertEqual(obj["session_id"], hashlib.sha256(session.encode()).hexdigest()[:24])
            self.assertEqual(set(obj), {"source", "session_id", "state", "timestamp"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_repeat_coalescing_periodic_refresh_and_failure_pipeline(self):
        for state in ("working", "attention", "error", "complete", "idle"):
            self.signal("emit", "--source", "custom", "--state", state, "--session", "pipeline")
            self.assertEqual(json.loads(self.events()[0].read_text())["state"], state)
        self.signal("emit", "--source", "custom", "--state", "working", "--session", "pipeline")
        path = self.events()[0]
        before = path.read_bytes()
        self.signal("emit", "--source", "custom", "--state", "working", "--session", "pipeline")
        self.assertEqual(path.read_bytes(), before)
        older = json.loads(before)
        older["timestamp"] = time.time() - 31
        path.write_text(json.dumps(older))
        self.signal("emit", "--source", "custom", "--state", "working", "--session", "pipeline")
        self.assertGreater(json.loads(path.read_text())["timestamp"], older["timestamp"])

    def test_session_end_preserves_finish_but_explicit_idle_clears(self):
        for source in ("codex", "claude"):
            payload = json.dumps({"session_id": source + " finish"})
            path = self.data / "events" / (source + "-" + hashlib.sha256((source + " finish").encode()).hexdigest()[:24] + ".json")
            for finish in ("complete", "error"):
                self.signal("event", "--source", source, "--state", finish, payload=payload)
                before = path.read_bytes()
                self.signal("event", "--source", source, "--state", "idle", "--preserve-finish", payload=payload)
                self.assertEqual(path.read_bytes(), before, "SessionEnd must preserve the original finish and timestamp")
                self.signal("event", "--source", source, "--state", "idle", payload=payload)
                self.assertEqual(json.loads(path.read_text())["state"], "idle", "Explicit idle and Interrupt still clear a finish")
            self.signal("event", "--source", source, "--state", "working", payload=payload)
            self.signal("event", "--source", source, "--state", "idle", "--preserve-finish", payload=payload)
            self.assertEqual(json.loads(path.read_text())["state"], "idle", "An unfinished working session ends normally")
            self.signal("event", "--source", source, "--state", "complete", payload=payload)
            stale = json.loads(path.read_text())
            stale["timestamp"] = time.time() - 86401
            path.write_text(json.dumps(stale))
            self.signal("event", "--source", source, "--state", "idle", "--preserve-finish", payload=payload)
            self.assertEqual(json.loads(path.read_text())["state"], "idle", "Finishes outside the 24-hour snapshot lifetime are not preserved")

    def test_nonregular_destination_and_symlink_paths_are_not_replaced(self):
        directory = self.data / "events"
        directory.mkdir(parents=True)
        destination = directory / ("custom-" + hashlib.sha256(b"default").hexdigest()[:24] + ".json")
        os.mkfifo(destination)
        self.signal("emit", "--source", "custom", "--state", "working")
        self.assertTrue(destination.is_fifo())
        destination.unlink()
        destination.mkdir()
        self.signal("emit", "--source", "custom", "--state", "working")
        self.assertTrue(destination.is_dir())
        destination.rmdir()
        outside = self.home / "private.json"
        outside.write_text("keep this file")
        destination.symlink_to(outside)
        self.signal("emit", "--source", "custom", "--state", "working")
        self.assertEqual(outside.read_text(), "keep this file")
        self.assertTrue(destination.is_symlink())

    def test_pruning_keeps_current_signal_despite_future_file_times(self):
        directory = self.data / "events"
        directory.mkdir(parents=True)
        for index in range(260):
            path = directory / (str(index) + ".json")
            path.write_text("{}")
            os.utime(path, (time.time() + 3600, time.time() + 3600))
        self.signal("emit", "--source", "custom", "--state", "complete")
        destination = directory / ("custom-" + hashlib.sha256(b"default").hexdigest()[:24] + ".json")
        self.assertEqual(json.loads(destination.read_text())["state"], "complete")
        self.assertLessEqual(len(self.events()), 256)

    def test_hardlinked_snapshot_is_not_read_or_replaced(self):
        directory = self.data / "events"
        directory.mkdir(parents=True)
        original = self.home / "outside-snapshot.json"
        original.write_text('{"private":"keep"}')
        destination = directory / ("custom-" + hashlib.sha256(b"default").hexdigest()[:24] + ".json")
        os.link(original, destination)
        self.signal("emit", "--source", "custom", "--state", "complete")
        self.assertEqual(original.read_text(), '{"private":"keep"}')
        self.assertEqual(destination.stat().st_ino, original.stat().st_ino)

    def test_locked_spool_and_unclosed_stdin_are_bounded(self):
        directory = self.data / "events"
        directory.mkdir(parents=True)
        with (directory / ".lidglow.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            start = time.monotonic()
            self.signal("emit", "--source", "custom", "--state", "working")
            self.assertLess(time.monotonic() - start, 1.5)
        self.assertEqual(self.events(), [])
        prefix = getattr(self, "prefix", [sys.executable, str(HELPER)])
        process = subprocess.Popen(prefix + ["event", "--source", "codex", "--state", "working"],
                                   env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b'{"session_id":"unfinished"}')
            process.stdin.flush()
            process.wait(timeout=1.5)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stdout.read(), b"")
            self.assertEqual(process.stderr.read(), b"")
        finally:
            process.stdin.close(); process.stdout.close(); process.stderr.close()
            if process.poll() is None:
                process.kill(); process.wait()
        self.assertEqual(self.events(), [])

    def test_concurrent_writers_readers_and_snapshot_bound(self):
        invalid = []
        def write(index):
            self.signal("emit", "--source", "custom", "--state", "working", "--session", "s" + str(index))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            jobs = [pool.submit(write, index) for index in range(280)]
            while not all(job.done() for job in jobs):
                for path in self.events():
                    try:
                        value = json.loads(path.read_bytes())
                        if set(value) != {"source", "session_id", "state", "timestamp"}:
                            invalid.append("wrong fields")
                    except FileNotFoundError:
                        pass
                    except Exception as error:
                        invalid.append(str(error))
                time.sleep(0.002)
            for job in jobs:
                job.result()
        self.assertEqual(invalid, [])
        self.assertLessEqual(len(self.events()), 256)
        self.assertGreater(len(self.events()), 200)


@unittest.skipUnless(os.environ.get("LIDGLOW_SIGNAL_BINARY"), "native helper binary not supplied")
class NativeSignalTests(SignalTests):
    def setUp(self):
        super().setUp()
        self.prefix = [str(Path(os.environ["LIDGLOW_SIGNAL_BINARY"]).resolve())]


if __name__ == "__main__":
    unittest.main()
