#!/usr/bin/env python3

from __future__ import annotations

import argparse
import io
import subprocess
import sys
import time
from datetime import datetime
from zoneinfo import ZoneInfo

from PIL import Image, ImageStat

from verify_maa_copilot_result import REFERENCE_HEIGHT, REFERENCE_WIDTH, capture_screen, scale, tap


DEFAULT_START = "2026-09-04T12:00:00+08:00"
DEFAULT_END = "2026-09-18T03:59:59+08:00"


def open_image(png: bytes) -> Image.Image:
    with Image.open(io.BytesIO(png)) as image:
        image.load()
        return image.convert("RGB")


def region_mean(image: Image.Image, box: tuple[int, int, int, int]) -> tuple[float, float, float]:
    width, height = image.size
    scaled = (
        scale(box[0], width, REFERENCE_WIDTH),
        scale(box[1], height, REFERENCE_HEIGHT),
        scale(box[2], width, REFERENCE_WIDTH),
        scale(box[3], height, REFERENCE_HEIGHT),
    )
    red, green, blue = ImageStat.Stat(image.crop(scaled)).mean
    return red, green, blue


def pixel(image: Image.Image, x: int, y: int) -> tuple[int, int, int]:
    return image.getpixel(
        (
            scale(x, image.width, REFERENCE_WIDTH),
            scale(y, image.height, REFERENCE_HEIGHT),
        )
    )


def is_event_hub(image: Image.Image) -> bool:
    top_red, top_green, top_blue = region_mean(image, (1450, 220, 1800, 330))
    bottom_red, bottom_green, bottom_blue = region_mean(image, (1400, 920, 1820, 1040))
    return (
        60 < top_red < 150
        and 70 < top_green < 150
        and 80 < top_blue < 170
        and bottom_red < 70
        and bottom_green < 105
        and 75 < bottom_blue < 170
    )


def has_travel_claim(image: Image.Image) -> bool:
    red, green, blue = pixel(image, 1660, 270)
    return red > 170 and green < 90 and blue < 90


def has_active_tarot_spread(image: Image.Image) -> bool:
    red, green, blue = region_mean(image, (0, 800, 280, 1080))
    return blue > 170 and blue - red > 65 and blue - green > 50


def press(adb: str, serial: str, image: Image.Image, x: int, y: int) -> None:
    tap(adb, serial, x, y, image.width, image.height)


def current_screen(adb: str, serial: str) -> Image.Image:
    return open_image(capture_screen(adb, serial))


def navigate_to_hub(adb: str, serial: str, settle_seconds: float) -> Image.Image | None:
    image = current_screen(adb, serial)
    for attempt in range(4):
        if is_event_hub(image):
            return image
        if attempt == 0:
            press(adb, serial, image, 1575, 335)
            time.sleep(settle_seconds)
            image = current_screen(adb, serial)
            if is_event_hub(image):
                return image
        press(adb, serial, image, 70, 60)
        time.sleep(settle_seconds)
        image = current_screen(adb, serial)
    return image if is_event_hub(image) else None


def claim_travel(adb: str, serial: str, hub: Image.Image, settle_seconds: float) -> bool:
    press(adb, serial, hub, 1630, 285)
    time.sleep(settle_seconds)
    image = current_screen(adb, serial)
    claimed = has_travel_claim(image)
    if claimed:
        press(adb, serial, image, 1660, 270)
        time.sleep(settle_seconds * 2)
        image = current_screen(adb, serial)
        press(adb, serial, image, 1800, 1000)
        time.sleep(settle_seconds)
        image = current_screen(adb, serial)
        press(adb, serial, image, 960, 960)
        time.sleep(settle_seconds)

    image = current_screen(adb, serial)
    press(adb, serial, image, 70, 60)
    time.sleep(settle_seconds)
    return claimed


def claim_tarot(adb: str, serial: str, hub: Image.Image, settle_seconds: float) -> bool:
    press(adb, serial, hub, 180, 880)
    time.sleep(settle_seconds)
    image = current_screen(adb, serial)
    active = has_active_tarot_spread(image)
    if active:
        press(adb, serial, image, 120, 990)
        time.sleep(settle_seconds * 2)
        image = current_screen(adb, serial)
        press(adb, serial, image, 1750, 80)
        time.sleep(settle_seconds)
        image = current_screen(adb, serial)
        press(adb, serial, image, 1750, 80)
        time.sleep(settle_seconds)
        image = current_screen(adb, serial)
        press(adb, serial, image, 960, 960)
        time.sleep(settle_seconds)
    return active


def in_event_window(now: datetime, start_text: str, end_text: str) -> bool:
    start = datetime.fromisoformat(start_text)
    end = datetime.fromisoformat(end_text)
    if start.tzinfo is None or end.tzinfo is None:
        raise ValueError("event timestamps must include UTC offsets")
    return start <= now.astimezone(start.tzinfo) <= end


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Claim rewards for the active SR event")
    parser.add_argument("--adb", default="/usr/bin/adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--start", default=DEFAULT_START)
    parser.add_argument("--end", default=DEFAULT_END)
    parser.add_argument("--settle-seconds", type=float, default=1.5)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    now = datetime.now(ZoneInfo("Asia/Shanghai"))
    try:
        if not in_event_window(now, args.start, args.end):
            print("sr-event-rewards skipped: outside event window")
            return 0
        hub = navigate_to_hub(args.adb, args.serial, args.settle_seconds)
        if hub is None:
            print("sr-event-rewards skipped: event hub not recognized", file=sys.stderr)
            return 2
        travel_claimed = claim_travel(args.adb, args.serial, hub, args.settle_seconds)
        hub = navigate_to_hub(args.adb, args.serial, args.settle_seconds)
        if hub is None:
            print("sr-event-rewards partial: event hub lost after travel", file=sys.stderr)
            return 2
        tarot_claimed = claim_tarot(args.adb, args.serial, hub, args.settle_seconds)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"sr-event-rewards error: {error}", file=sys.stderr)
        return 2

    print(f"sr-event-rewards completed: travel={travel_claimed} tarot={tarot_claimed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
