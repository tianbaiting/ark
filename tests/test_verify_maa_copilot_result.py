#!/usr/bin/env python3

import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "verify_maa_copilot_result.py"
SPEC = importlib.util.spec_from_file_location("verify_maa_copilot_result", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def synthetic_screen(stars: int, background: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGB", (1920, 1080), background)
    draw = ImageDraw.Draw(image)
    for center_x in MODULE.STAR_CENTERS_X[:stars]:
        draw.rectangle((center_x - 35, 440, center_x + 35, 520), fill=(10, 220, 245))
    return image


def png_bytes(image: Image.Image) -> bytes:
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


class VerifyMaaCopilotResultTest(unittest.TestCase):
    def test_accepts_only_three_star_result(self) -> None:
        result = MODULE.classify_result(
            synthetic_screen(3, (30, 30, 30)), "MISSION RESULTS"
        )
        self.assertEqual(result, MODULE.Classification("success", 3))

    def test_rejects_two_star_result(self) -> None:
        result = MODULE.classify_result(
            synthetic_screen(2, (30, 30, 30)), "MISSION RESULTS"
        )
        self.assertEqual(result, MODULE.Classification("failure", 2))

    def test_rejects_explicit_failure(self) -> None:
        result = MODULE.classify_result(
            synthetic_screen(0, (30, 30, 30)), "MISSION FAILED"
        )
        self.assertEqual(result, MODULE.Classification("failure", 0))

    def test_does_not_confuse_blue_event_map_with_result(self) -> None:
        result = MODULE.classify_result(synthetic_screen(3, (10, 150, 230)))
        self.assertEqual(result, MODULE.Classification("unknown"))

    def test_visual_fallback_works_without_tesseract(self) -> None:
        result = MODULE.classify_result(synthetic_screen(3, (30, 30, 30)))
        self.assertEqual(result, MODULE.Classification("success", 3))

    def test_live_verifier_skips_post_battle_story_before_checking_result(self) -> None:
        captures = [
            png_bytes(synthetic_screen(0, (30, 30, 30))),
            png_bytes(synthetic_screen(0, (30, 30, 30))),
            png_bytes(synthetic_screen(3, (30, 30, 30))),
        ]
        with (
            mock.patch.object(MODULE, "capture_screen", side_effect=captures),
            mock.patch.object(MODULE, "tap") as tapped,
            mock.patch.object(MODULE.time, "sleep"),
        ):
            result = MODULE.verify_live("adb", "serial", "", 0)
        self.assertEqual(result, MODULE.Classification("success", 3))
        self.assertEqual(tapped.call_count, 2)


if __name__ == "__main__":
    unittest.main()
