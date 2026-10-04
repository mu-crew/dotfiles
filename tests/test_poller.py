#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import subprocess
import sys
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

    def test_remote_counts_keep_crew_separate_except_attention(self):
        view = {
            "peers": [{"name": "dev"}],
            "panes": [
                {"local": True, "driver": "human", "activity": "running", "attention": []},
                {"local": False, "driver": "human", "activity": "running", "attention": []},
                {"local": False, "driver": "orchestrated", "activity": "running", "attention": [{"kind": "blocked"}]},
                {"local": False, "driver": "orchestrated", "activity": "stopped", "attention": [{"kind": "done"}]},
                {"local": False, "driver": "human", "activity": "stopped", "pending": 2, "attention": []},
            ],
        }
        self.assertEqual(
            poller.remote_counts(view),
            ({"crashed": 0, "blocked": 1, "done": 0, "working": 1, "waiting": 1, "idle": 0, "crew": 2}, 1),
        )


class PollOnceTests(unittest.TestCase):
    def test_a_failing_probe_command_is_a_failed_round_not_a_dead_loop(self):
        # vm_stat, memory_pressure, top and sysctl can exit non-zero, and
        # CalledProcessError is not an OSError. Uncaught, it ended the loop and
        # every pill went blank until the config was sourced again.
        class Failing:
            def memory(self):
                raise subprocess.CalledProcessError(1, ["vm_stat"])

        published = []
        original = poller.publish
        poller.publish = published.append
        try:
            self.assertEqual(poller.poll_once(Failing(), ["memory"]), 1)
        finally:
            poller.publish = original
        self.assertEqual(published, [{}])


if __name__ == "__main__":
    unittest.main()
