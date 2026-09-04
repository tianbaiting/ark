#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "claim_sr_event_rewards.py"
SPEC = importlib.util.spec_from_file_location("claim_sr_event_rewards", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.path.insert(0, str(MODULE_PATH.parent))
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def base_screen(color: tuple[int, int, int]) -> Image.Image:
    return Image.new("RGB", (1920, 1080), color)


class ClaimSrEventRewardsTest(unittest.TestCase):
    def test_recognizes_event_hub_color_layout(self) -> None:
        image = base_screen((0, 50, 216))
        draw = ImageDraw.Draw(image)
        draw.rectangle((1450, 220, 1800, 330), fill=(100, 110, 120))
        draw.rectangle((1400, 920, 1820, 1040), fill=(35, 65, 115))
        self.assertTrue(MODULE.is_event_hub(image))
        self.assertFalse(MODULE.is_event_hub(base_screen((0, 50, 216))))

    def test_detects_red_travel_claim_button(self) -> None:
        image = base_screen((20, 30, 90))
        image.putpixel((1660, 270), (230, 0, 0))
        self.assertTrue(MODULE.has_travel_claim(image))
        image.putpixel((1660, 270), (5, 5, 40))
        self.assertFalse(MODULE.has_travel_claim(image))

    def test_detects_only_active_blue_tarot_button(self) -> None:
        active = base_screen((255, 255, 255))
        ImageDraw.Draw(active).rectangle((0, 800, 280, 1080), fill=(60, 80, 220))
        inactive = base_screen((255, 255, 255))
        ImageDraw.Draw(inactive).rectangle((0, 800, 280, 1080), fill=(130, 130, 130))
        self.assertTrue(MODULE.has_active_tarot_spread(active))
        self.assertFalse(MODULE.has_active_tarot_spread(inactive))

    def test_event_window_honors_explicit_offset(self) -> None:
        self.assertTrue(
            MODULE.in_event_window(
                datetime(2026, 9, 10, tzinfo=timezone.utc),
                MODULE.DEFAULT_START,
                MODULE.DEFAULT_END,
            )
        )
        self.assertFalse(
            MODULE.in_event_window(
                datetime(2026, 9, 20, tzinfo=timezone.utc),
                MODULE.DEFAULT_START,
                MODULE.DEFAULT_END,
            )
        )


if __name__ == "__main__":
    unittest.main()
