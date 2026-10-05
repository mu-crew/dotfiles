#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "tmux" / "scripts" / "mu-crew-host-color"
loader = importlib.machinery.SourceFileLoader("mu_crew_host_color", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
host_color = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = host_color
loader.exec_module(host_color)


class HostColorTest(unittest.TestCase):
    def test_matches_murmur(self):
        # murmur's test/dash-paint.test.ts pins the same value: crc32("linuxpc")
        # is 621039107. A drift on either side splits one host into two colors.
        self.assertEqual(
            host_color.host_color("linuxpc"), host_color.COLORS[621039107 % 8]
        )
        self.assertEqual(
            host_color.COLORS,
            (
                "#fab387",
                "#89dceb",
                "#cba6f7",
                "#a6e3a1",
                "#f9e2af",
                "#94e2d5",
                "#f5c2e7",
                "#eba0ac",
            ),
        )

    def test_short_name(self):
        self.assertEqual(
            host_color.host_color("linuxpc.lan"), host_color.host_color("linuxpc")
        )


if __name__ == "__main__":
    unittest.main()
