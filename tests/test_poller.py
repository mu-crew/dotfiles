#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "tmux" / "scripts" / "mu-crew-poller"
loader = importlib.machinery.SourceFileLoader("mu_crew_poller", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
poller = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = poller
loader.exec_module(poller)

VM_STAT = """Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               10000.
Pages active:                             40000.
Pages inactive:                           20000.
Pages speculative:                         2000.
Pages wired down:                         18000.
Pages purgeable:                           4000.
File-backed pages:                        20000.
Pages occupied by compressor:              6000.
Compressions:                             10000.
Pageouts:                                   500.
Swapouts:                                   100.
"""
PRESSURE = """The system has 100000 pages with a page size of 4096.
System-wide memory free percentage: 40%
"""


class ParserTests(unittest.TestCase):
    def test_vm_stat_and_memory_pressure_are_parsed_from_recorded_output(self):
        page_size, counts = poller.parse_vm_stat(VM_STAT)
        pressure = poller.parse_memory_pressure(PRESSURE)
        self.assertEqual(page_size, 4096)
        self.assertEqual(counts["Pages occupied by compressor"], 6000)
        self.assertEqual(pressure, {"total_pages": 100000, "page_size": 4096, "free_percentage": 40})

    def test_darwin_score_uses_in_memory_rate_state(self):
        previous = {"ts": 9.0, "compressions": 0, "pageouts": 0, "swapouts": 0}
        score, state = poller.darwin_memory_score(VM_STAT, PRESSURE, previous, now=10.0)
        self.assertEqual(score, 30)
        self.assertEqual(state["swapouts"], 100)

    def test_linux_memory_is_used_over_total(self):
        text = "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 250 kB\n"
        self.assertEqual(poller.parse_meminfo(text), 75)

    def test_linux_cpu_uses_deltas(self):
        self.assertEqual(poller.parse_proc_stat_cpu("cpu  10 0 5 85 0 0 0 0\n", "cpu  30 0 5 165 0 0 0 0\n"), 20)

    def test_darwin_cpu_ticks_use_deltas_and_survive_wraparound(self):
        # [user, system, idle, nice]
        self.assertEqual(poller.parse_ticks_cpu([10, 5, 85, 0], [30, 5, 165, 0]), 20)
        self.assertEqual(poller.parse_ticks_cpu([1, 1, 1, 1], [1, 1, 1, 1]), 0)
        self.assertEqual(poller.parse_ticks_cpu([0xFFFFFFF0, 0, 0, 0], [0x10, 0, 0x20, 0]), 50)

    @unittest.skipUnless(sys.platform == "darwin", "host_statistics is macOS only")
    def test_darwin_cpu_probe_reads_host_statistics(self):
        worker = poller.Poller()
        update, code = worker.cpu()
        self.assertEqual(code, 0)
        self.assertTrue(0 <= int(update["@mu_crew_cpu"]) <= 100)
        self.assertIsInstance(worker.cpu_state, list)

    @unittest.skipUnless(sys.platform == "darwin", "Mach ports are macOS only")
    def test_darwin_cpu_probe_does_not_leak_host_port_send_rights(self):
        import ctypes

        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        lib.mach_host_self.restype = ctypes.c_uint32
        lib.mach_port_get_refs.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
        task = ctypes.c_uint32.in_dll(lib, "mach_task_self_").value
        host = lib.mach_host_self()

        def refs() -> int:
            out = ctypes.c_uint32()
            self.assertEqual(lib.mach_port_get_refs(task, host, 0, ctypes.byref(out)), 0)  # MACH_PORT_RIGHT_SEND
            return out.value

        poller.darwin_cpu_ticks()  # warm up
        before = refs()
        for _ in range(200):
            poller.darwin_cpu_ticks()
        self.assertEqual(refs(), before)

    def test_remote_counts_keep_crew_separate_except_attention(self):
        view = {
            "peers": [{"name": "dev"}],
            "panes": [
                {"local": True, "driver": "human", "activity": "running", "attention": []},
                {"local": False, "driver": "human", "activity": "running", "attention": []},
                {"local": False, "driver": "orchestrated", "activity": "running", "attention": [{"kind": "blocked"}]},
                {"local": False, "driver": "orchestrated", "activity": "stopped", "attention": [{"kind": "done"}]},
                {"local": False, "driver": "human", "activity": "stopped", "pending": 2, "attention": []},
                {"local": False, "driver": "orchestrated", "activity": "stopped", "attention": [{"kind": "error"}, {"kind": "done"}]},
            ],
        }
        self.assertEqual(
            poller.remote_counts(view),
            ({"crashed": 0, "error": 1, "blocked": 1, "done": 0, "working": 1, "waiting": 1, "idle": 0, "crew": 3}, 1),
        )


class PollOnceTests(unittest.TestCase):
    def test_a_failing_probe_command_is_a_failed_round_not_a_dead_loop(self):
        # vm_stat, memory_pressure and sysctl can exit non-zero, and
        # CalledProcessError is not an OSError. Uncaught, it ended the loop and
        # every pill went blank until the config was sourced again.
        class Failing:
            def memory(self):
                raise subprocess.CalledProcessError(1, ["vm_stat"])

        published = []
        original = poller.publish
        poller.publish = lambda values, current=None: published.append(values)
        try:
            self.assertEqual(poller.poll_once(Failing(), ["memory"]), 1)
        finally:
            poller.publish = original
        self.assertEqual(published, [{}])


class LoopTests(unittest.TestCase):
    def test_an_idle_wake_costs_one_tmux_call(self):
        # A wake that polls nothing used to run show-options twice (server
        # check, probe list); a wake that polls also read one interval per
        # ready probe and once more per publish. A wake now reads the server
        # once and shares the snapshot.
        import tempfile

        calls = []

        class Stop(Exception):
            pass

        def fake_tmux(*args):
            calls.append(args)
            out = "@mu_crew_probes uptime\n@mu_crew_uptime_interval 50\n"
            return subprocess.CompletedProcess(args, 0, out, "")

        class Worker:
            def uptime(self):
                return {"@mu_crew_uptime_value": "1"}, 0

        sleeps = []

        def fake_sleep(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 3:
                raise Stop

        saved = poller.tmux, poller.Poller, poller.time.sleep
        poller.tmux, poller.Poller, poller.time.sleep = fake_tmux, Worker, fake_sleep
        try:
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(Stop):
                    poller.loop(Path(directory) / "pid")
        finally:
            poller.tmux, poller.Poller, poller.time.sleep = saved
        reads = [call for call in calls if call[0] == "show-options"]
        # Wake 1 polls and publishes (one set-option); wakes 2 and 3 only read.
        self.assertEqual(reads, [("show-options", "-g")] * 3)
        self.assertEqual([call[0] for call in calls if call[0] != "show-options"],
                         ["set-option", "refresh-client"])
        self.assertTrue(all(0.1 <= value <= 1.0 for value in sleeps))

    def test_a_probe_list_change_is_seen_on_the_next_wake(self):
        snapshot = {"@mu_crew_probes": "cpu uptime", "@mu_crew_cpu_interval": "2"}
        self.assertEqual(poller.probes(snapshot), ["cpu", "uptime"])
        self.assertEqual(poller.interval("cpu", snapshot), 2.0)
        self.assertEqual(poller.interval("uptime", snapshot), poller.INTERVALS["uptime"])
        self.assertEqual(poller.probes({}), ["murmur_remote"])
        self.assertEqual(poller.interval("cpu", {"@mu_crew_cpu_interval": "5s"}), poller.INTERVALS["cpu"])

    def test_escaped_values_decode_as_show_option_gqv_printed_them(self):
        # Recorded `tmux 3.7c show-options -g` lines for values set with tabs,
        # newlines, quotes, backslashes and padding.
        shown = "\n".join([
            "@mu_crew_probes cpu\\tuptime",
            "@mu_crew_a cpu\\nuptime",
            "@mu_crew_cpu_interval \\t0.1\\t",
            "@mu_crew_b \"a b\"",
            "@mu_crew_c \"it's \\\"q\\\" \\\\ back \\$x #h\"",
            "@mu_crew_d 'x\\001\"y'",
            "@mu_crew_e \"  0.1 \"",
            "@mu_crew_f a\\\\b",
            "@mu_crew_g ''",
            "status-left foo",
        ])
        saved = poller.tmux
        poller.tmux = lambda *args: subprocess.CompletedProcess(args, 0, shown + "\n", "")
        try:
            snapshot = poller.current_options()
        finally:
            poller.tmux = saved
        self.assertEqual(snapshot, {
            "@mu_crew_probes": "cpu\tuptime",
            "@mu_crew_a": "cpu\nuptime",
            "@mu_crew_cpu_interval": "\t0.1\t",
            "@mu_crew_b": "a b",
            "@mu_crew_c": "it's \"q\" \\ back $x #h",
            "@mu_crew_d": "x\x01\"y",
            "@mu_crew_e": "  0.1 ",
            "@mu_crew_f": "a\\b",
            "@mu_crew_g": "",
        })
        self.assertEqual(poller.probes(snapshot), ["cpu", "uptime"])
        self.assertEqual(poller.probes({"@mu_crew_probes": snapshot["@mu_crew_a"]}), ["cpu", "uptime"])
        self.assertEqual(poller.interval("cpu", snapshot), 0.1)

    @unittest.skipUnless(shutil.which("tmux"), "needs tmux")
    def test_snapshot_matches_show_option_gqv_on_a_private_server(self):
        socket = f"mu-exp-poller-test-{os.getpid()}"

        def private(*args):
            return subprocess.run(["tmux", "-L", socket, "-f", "/dev/null", *args],
                                  text=True, capture_output=True, env={**os.environ, "TMUX": ""})

        values = {
            "@mu_crew_probes": "cpu\tuptime",
            "@mu_crew_cpu_interval": "\t0.1\t",
            "@mu_crew_a": "cpu\nuptime",
            "@mu_crew_b": "it's \"q\" \\ back $x #h",
            "@mu_crew_c": "  0.1 ",
        }
        saved = poller.tmux
        poller.tmux = private
        try:
            self.assertEqual(private("new-session", "-d", "-s", "x").returncode, 0)
            for name, value in values.items():
                self.assertEqual(private("set-option", "-g", name, value).returncode, 0)
            snapshot = poller.current_options()
            for name in values:
                self.assertEqual(snapshot[name].strip(), poller.option(name), name)
            self.assertEqual(poller.probes(snapshot), ["cpu", "uptime"])
            self.assertEqual(poller.interval("cpu", snapshot), 0.1)
        finally:
            poller.tmux = saved
            private("kill-server")

    def test_a_tab_separated_probe_list_keeps_the_loop_polling(self):
        # The loop exits (and relaunches itself) when it reads no probes.
        class Stop(Exception):
            pass

        polled = []

        def fake_tmux(*args):
            out = "@mu_crew_probes cpu\\tuptime\n@mu_crew_cpu_interval \\t50\\t\n"
            return subprocess.CompletedProcess(args, 0, out, "")

        class Worker:
            def cpu(self):
                polled.append("cpu")
                return {"@mu_crew_cpu": "1"}, 0

            def uptime(self):
                polled.append("uptime")
                return {"@mu_crew_uptime_value": "1"}, 0

        def fake_sleep(seconds):
            raise Stop

        saved = poller.tmux, poller.Poller, poller.time.sleep
        poller.tmux, poller.Poller, poller.time.sleep = fake_tmux, Worker, fake_sleep
        try:
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(Stop):
                    poller.loop(Path(directory) / "pid")
        finally:
            poller.tmux, poller.Poller, poller.time.sleep = saved
        self.assertEqual(polled, ["cpu", "uptime"])


if __name__ == "__main__":
    unittest.main()
