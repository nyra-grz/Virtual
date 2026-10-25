"""Tester regressions without downloads, installers, Wine or screen access.

Run: uv run --with pyyaml python -m unittest discover -s scripts/tests -v
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Event, Lock
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("compat_test", Path(__file__).resolve().parents[1] / "compat-test.py")
compat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compat)


class CompatibilityRunTests(unittest.TestCase):
    def simulate(self, *, clone_failure=False, installer_timeout=False,
                 launch_failure=False, installed=True, capture=True, guest_windows=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name).resolve()
        out = root / "result"
        base = out / "base-room/prefix"
        (base / "drive_c/windows/system32").mkdir(parents=True)
        engine = root / "engine"
        winlist = root / "winlist"
        winlist.touch()
        clock = [0]
        server_calls = []
        proc = Mock()
        proc.poll.return_value = None

        def fake_run(cmd, **kwargs):
            if cmd[0] == "cp":
                if clone_failure:
                    return subprocess.CompletedProcess(cmd, 1, "", "no space")
                shutil.copytree(cmd[2], cmd[3])
            elif cmd[0] == "screencapture" and capture:
                Path(cmd[-1]).touch()
            elif cmd[0] == "x86_64-w64-mingw32-gcc":
                Path(cmd[cmd.index("-o") + 1]).touch()
            elif cmd[0].endswith("virtualserver"):
                server_calls.append((cmd[1], kwargs["env"]["WINEPREFIX"], kwargs.get("timeout")))
            return subprocess.CompletedProcess(cmd, 1 if cmd[0] == "screencapture" and not capture else 0, "", "")

        def fake_links(prefix):
            return set() if prefix == base or not installed else {prefix / "app.lnk"}

        window_calls = [0]
        def fake_windows(*args):
            window_calls[0] += 1
            if launch_failure and window_calls[0] > 1:
                raise RuntimeError("window query failed")
            return {} if window_calls[0] == 1 else {"123": ("Example", 900, 600)}

        argv = ["compat-test.py", "Example.App", "--out", str(out),
                "--engine", str(engine), "--winlist", str(winlist), "--launch-wait", "60"]
        if guest_windows:
            argv.append("--guest-windows")
        installer = Mock(return_value=subprocess.CompletedProcess([], 0))
        if installer_timeout:
            installer.side_effect = subprocess.TimeoutExpired("installer", 420)
        with ExitStack() as stack:
            for name, value in {
                "ROOT": root,
                "manifest": Mock(return_value=("1.0", {"Installers": [{"Architecture": "x64", "InstallerType": "nullsoft", "InstallerUrl": "https://example.test/app.exe", "InstallerSha256": "00"}]})),
                "download": Mock(return_value=True), "run": fake_run,
                "shortcuts": fake_links, "registered_apps": Mock(return_value={}),
                "windows": fake_windows, "missing_dlls": Mock(return_value=[]), "uniform": Mock(return_value=False),
            }.items():
                stack.enter_context(patch.object(compat, name, value))
            stack.enter_context(patch.object(compat.sys, "argv", argv))
            stack.enter_context(patch.object(compat.time, "time", lambda: clock[0]))
            stack.enter_context(patch.object(compat.time, "sleep", lambda seconds: clock.__setitem__(0, clock[0] + seconds)))
            stack.enter_context(patch.object(compat.subprocess, "run", installer))
            stack.enter_context(patch.object(compat.subprocess, "Popen", return_value=proc))
            stack.enter_context(redirect_stdout(io.StringIO()))
            compat.main()
        return json.loads((out / "results.json").read_text())[0], server_calls, installer, proc, clock[0]

    def test_observes_until_deadline_and_cleans_up(self):
        result, calls, _, proc, elapsed = self.simulate()
        self.assertEqual(result["status"], "läuft")
        self.assertEqual(result["seconds"], 60)
        self.assertGreaterEqual(elapsed, 60)
        self.assertEqual([c[0] for c in calls], ["-k", "-w", "-k", "-w", "-k", "-w"])
        self.assertTrue(all(c[1].endswith("base-room/prefix") and c[2] == 15 for c in calls[:2]))
        self.assertTrue(all(c[1].endswith("rooms/Example.App/prefix") and c[2] == 15 for c in calls[2:]))
        proc.kill.assert_called_once()
        proc.wait.assert_called_once_with(timeout=5)

    def test_failed_capture_is_not_counted_as_running(self):
        result, _, _, _, _ = self.simulate(capture=False)
        self.assertEqual(result["status"], "Fenster offen (Darstellung ungeprüft)")
        self.assertNotIn("uniform", result["windows"][0])

    def test_guest_windows_cannot_verify_rendering(self):
        result, _, _, _, _ = self.simulate(guest_windows=True)
        self.assertEqual(result["status"], "Fenster offen (Darstellung ungeprüft)")

    def test_clone_failure_does_not_run_installer(self):
        result, calls, installer, _, _ = self.simulate(clone_failure=True)
        self.assertIn("Raum konnte nicht geklont", result["status"])
        installer.assert_not_called()
        self.assertEqual([c[0] for c in calls], ["-k", "-w", "-k", "-w"])

    def test_installer_timeout_cleans_detached_children(self):
        result, calls, _, _, _ = self.simulate(installer_timeout=True, installed=False)
        self.assertEqual(result["install_exit"], "Zeitlimit")
        self.assertEqual(result["status"], "nicht installiert")
        self.assertEqual([c[0] for c in calls], ["-k", "-w", "-k", "-w", "-k", "-w"])

    def test_window_query_exception_still_reaps_launch_process(self):
        result, calls, _, proc, _ = self.simulate(launch_failure=True)
        self.assertIn("window query failed", result["status"])
        self.assertEqual([c[0] for c in calls][-2:], ["-k", "-w"])
        proc.kill.assert_called_once()
        proc.wait.assert_called_once_with(timeout=5)


class CauseTests(unittest.TestCase):
    def diagnose(self, text, **result):
        log = Mock()
        log.exists.return_value = True
        log.read_text.return_value = text
        return compat.cause(result, log), result

    def test_unimplemented_api_abort_is_the_cause(self):
        name = "KERNEL32.dll.SetThreadpoolTimerEx"
        reason, result = self.diagnose(
            "wine: Call from 00006FFFFABCDE to unimplemented function " + name + ", aborting\n",
            status="kein Fenster", missing_dlls=["unrelated.dll"])
        self.assertEqual(reason, "nicht implementiert: " + name)
        self.assertEqual(result["unimplemented_function"], name)

    def test_crash_does_not_borrow_a_module_from_another_process(self):
        reason, result = self.diagnose(
            '0020:0024:trace:loaddll:build_module Loaded L"C:\\actual.dll" at 0000000140000000: native\n'
            '0030:0034:trace:loaddll:build_module Loaded L"C:\\unrelated.dll" at 0000000140001000: native\n'
            '0020:0024:err:seh:dispatch_exception Unhandled page fault on read access to 0000000000000000 at address 0000000140001500\n',
            status="Absturz")
        self.assertEqual(reason, "Absturz (Modul unbekannt)")
        self.assertEqual(result["crash_in"], "0000000140001500")
        self.assertNotIn("unrelated", reason)

    def test_thread_only_module_bases_do_not_prove_image_bounds(self):
        reason, _ = self.diagnose(
            '0024:trace:loaddll:build_module Loaded L"C:\\example.dll" at 0000000140000000: native\n'
            'wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140015000 (thread 0024), starting debugger...\n',
            status="Absturz")
        self.assertEqual(reason, "Absturz (Modul unbekannt)")


class HelperTests(unittest.TestCase):
    def test_stop_room_waits_even_when_kill_times_out(self):
        with patch.object(compat, "run", side_effect=[subprocess.TimeoutExpired("server", 15), subprocess.CompletedProcess([], 0)]) as run:
            self.assertTrue(compat.stop_room("server", {"WINEPREFIX": "/test/prefix"}))
        self.assertEqual([call.args[0][-1] for call in run.call_args_list], ["-k", "-w"])
        self.assertTrue(all(call.kwargs["timeout"] == 15 for call in run.call_args_list))

    def test_room_shutdown_is_not_proven_when_wait_times_out(self):
        with patch.object(compat, "run", side_effect=[subprocess.CompletedProcess([], 0), subprocess.TimeoutExpired("server", 15)]):
            self.assertFalse(compat.stop_room("server", {"WINEPREFIX": "/test/prefix"}))

    def test_positive_cli_limits(self):
        for value in ("0", "-3"):
            with self.assertRaises(argparse.ArgumentTypeError):
                compat.positive_int(value)
        self.assertEqual(compat.positive_int("3"), 3)

    def test_published_results_do_not_share_mutating_worker_dicts(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "results.json"
            lock = Lock()
            published = [{"app": "Example.App"}]
            local = {"app": "Example.App", **{str(index): index for index in range(2000)}}
            compat.write_results(path, published, lock, (0, local))
            self.assertIsNot(published[0], local)
            started, stop = Event(), Event()
            def mutate_worker():
                started.set()
                while not stop.is_set():
                    for index in range(100):
                        local["changing" + str(index)] = index
                    for index in range(100):
                        local.pop("changing" + str(index), None)
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(mutate_worker)
                started.wait(timeout=1)
                try:
                    for _ in range(20):
                        compat.write_results(path, published, lock)
                        snapshot = json.loads(path.read_text())[0]
                        self.assertEqual(len(snapshot), 2001)
                        self.assertFalse(any(key.startswith("changing") for key in snapshot))
                finally:
                    stop.set()
                    future.result(timeout=1)

    def test_parallel_snapshots_are_complete_json(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "results.json"
            lock = Lock()
            compat.write_results(path, [], lock)
            def writer(number):
                for _ in range(20):
                    compat.write_results(path, [{"app": str(number), "payload": "x" * 2000}], lock)
            with ThreadPoolExecutor(max_workers=3) as pool:
                futures = [pool.submit(writer, number) for number in range(3)]
                while not all(future.done() for future in futures):
                    snapshot = json.loads(path.read_text())
                    self.assertIsInstance(snapshot, list)
                for future in futures:
                    future.result()
            self.assertFalse(path.with_name("results.json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
