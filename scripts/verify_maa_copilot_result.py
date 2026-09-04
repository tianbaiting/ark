#!/usr/bin/env python3

from __future__ import annotations

import argparse
import io
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageStat


REFERENCE_WIDTH = 1920
REFERENCE_HEIGHT = 1080
STAR_CENTERS_X = (150, 260, 370)
STAR_TOP = 420
STAR_BOTTOM = 540
STAR_HALF_WIDTH = 48


@dataclass(frozen=True)
class Classification:
    state: str
    stars: int | None = None


def scale(value: int, actual: int, reference: int) -> int:
    return round(value * actual / reference)


def cyan_star_counts(image: Image.Image) -> list[int]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    top = scale(STAR_TOP, height, REFERENCE_HEIGHT)
    bottom = scale(STAR_BOTTOM, height, REFERENCE_HEIGHT)
    half_width = scale(STAR_HALF_WIDTH, width, REFERENCE_WIDTH)
    counts: list[int] = []

    for reference_x in STAR_CENTERS_X:
        center_x = scale(reference_x, width, REFERENCE_WIDTH)
        count = 0
        for y in range(top, bottom):
            for x in range(center_x - half_width, center_x + half_width):
                red, green, blue = pixels[x, y]
                if red < 90 and green > 150 and blue > 170 and blue >= green - 20:
                    count += 1
        counts.append(count)
    return counts


def has_dark_result_panel(image: Image.Image) -> bool:
    width, height = image.size
    panel = image.convert("RGB").crop(
        (
            scale(50, width, REFERENCE_WIDTH),
            scale(100, height, REFERENCE_HEIGHT),
            scale(500, width, REFERENCE_WIDTH),
            scale(700, height, REFERENCE_HEIGHT),
        )
    )
    red, green, blue = ImageStat.Stat(panel).mean
    return red < 100 and green < 110 and blue < 160


def classify_result(image: Image.Image, ocr_text: str = "") -> Classification:
    normalized = re.sub(r"\s+", " ", ocr_text.upper())
    if "MISSION FAILED" in normalized:
        return Classification("failure", 0)

    counts = cyan_star_counts(image)
    area_scale = image.width * image.height / (REFERENCE_WIDTH * REFERENCE_HEIGHT)
    threshold = max(200, round(1000 * area_scale))
    stars = sum(count >= threshold for count in counts)
    result_text = "MISSION RESULTS" in normalized
    result_visual = has_dark_result_panel(image) and stars > 0
    if result_text or result_visual:
        return Classification("success" if stars == 3 else "failure", stars)
    return Classification("unknown")


def capture_screen(adb: str, serial: str) -> bytes:
    result = subprocess.run(
        [adb, "-s", serial, "exec-out", "screencap", "-p"],
        check=False,
        capture_output=True,
        timeout=15,
    )
    if result.returncode != 0 or not result.stdout.startswith(b"\x89PNG"):
        error = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ADB screenshot failed: rc={result.returncode} {error}")
    return result.stdout


def recognize_english(png: bytes, tesseract: str) -> str:
    if not tesseract or not Path(tesseract).is_file():
        return ""
    result = subprocess.run(
        [tesseract, "stdin", "stdout", "-l", "eng", "--psm", "11"],
        input=png,
        check=False,
        capture_output=True,
        timeout=20,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.decode("utf-8", errors="replace")


def classify_capture(png: bytes, tesseract: str) -> Classification:
    with Image.open(io.BytesIO(png)) as image:
        image.load()
        return classify_result(image, recognize_english(png, tesseract))


def tap(adb: str, serial: str, x: int, y: int, width: int, height: int) -> None:
    result = subprocess.run(
        [
            adb,
            "-s",
            serial,
            "shell",
            "input",
            "tap",
            str(scale(x, width, REFERENCE_WIDTH)),
            str(scale(y, height, REFERENCE_HEIGHT)),
        ],
        check=False,
        capture_output=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"ADB tap failed: rc={result.returncode}")


def verify_live(adb: str, serial: str, tesseract: str, settle_seconds: float) -> Classification:
    png = capture_screen(adb, serial)
    with Image.open(io.BytesIO(png)) as image:
        width, height = image.size
    classification = classify_capture(png, tesseract)
    if classification.state != "unknown":
        return classification

    tap(adb, serial, 1760, 78, width, height)
    time.sleep(settle_seconds)
    png = capture_screen(adb, serial)
    classification = classify_capture(png, tesseract)
    if classification.state != "unknown":
        return classification

    tap(adb, serial, 1197, 693, width, height)
    time.sleep(settle_seconds * 2)
    png = capture_screen(adb, serial)
    return classify_capture(png, tesseract)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify an MAA copilot result on the connected device")
    parser.add_argument("--adb", default="/usr/bin/adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--tesseract", default="/home/linuxbrew/.linuxbrew/bin/tesseract")
    parser.add_argument("--settle-seconds", type=float, default=1.5)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        result = verify_live(args.adb, args.serial, args.tesseract, args.settle_seconds)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"copilot-result error: {error}", file=sys.stderr)
        return 2

    if result.state == "success":
        print(f"copilot-result success stars={result.stars}")
        return 0
    if result.state == "failure":
        print(f"copilot-result failure stars={result.stars}", file=sys.stderr)
        return 1
    print("copilot-result unknown", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
