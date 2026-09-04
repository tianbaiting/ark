#!/usr/bin/env python3
"""Extract completed Depot or OperBox callbacks from maa-cli verbose logs."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator


PREFIXES = {
    "depot": "Depot:",
    "operbox": "OperBox:",
}


def iter_prefixed_json(text: str, prefix: str) -> Iterator[dict[str, Any]]:
    decoder = json.JSONDecoder()
    cursor = 0

    while True:
        prefix_pos = text.find(prefix, cursor)
        if prefix_pos < 0:
            return

        object_pos = text.find("{", prefix_pos + len(prefix))
        if object_pos < 0:
            return

        try:
            value, consumed = decoder.raw_decode(text[object_pos:])
        except json.JSONDecodeError:
            cursor = prefix_pos + len(prefix)
            continue

        cursor = object_pos + consumed
        if isinstance(value, dict):
            yield value


def completed_details(message: dict[str, Any]) -> dict[str, Any] | None:
    details = message.get("details")
    if isinstance(details, dict) and details.get("done") is True:
        return details
    return None


def extract_depot(text: str) -> dict[str, int]:
    result: dict[str, int] | None = None
    for message in iter_prefixed_json(text, PREFIXES["depot"]):
        details = completed_details(message)
        if details is None:
            continue

        raw_data = details.get("data")
        if isinstance(raw_data, str):
            try:
                raw_data = json.loads(raw_data)
            except json.JSONDecodeError:
                continue
        if not isinstance(raw_data, dict):
            continue

        parsed: dict[str, int] = {}
        for item_id, quantity in raw_data.items():
            if isinstance(item_id, str) and isinstance(quantity, (int, float)):
                parsed[item_id] = int(quantity)
        if parsed:
            result = parsed

    if result is None:
        raise ValueError("completed Depot callback not found")
    return result


def extract_operbox(text: str) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] | None = None
    for message in iter_prefixed_json(text, PREFIXES["operbox"]):
        details = completed_details(message)
        if details is None:
            continue

        # [EN] Core 6.17 renamed the callback field to all_opers; accept the legacy spelling for older installations. / [CN] Core 6.17 将回调字段改为 all_opers；同时兼容旧版本的字段名。
        all_opers = details.get("all_opers", details.get("all_oper"))
        own_opers = details.get("own_opers")
        if isinstance(all_opers, list) and isinstance(own_opers, list):
            result = {
                "all_opers": [entry for entry in all_opers if isinstance(entry, dict)],
                "own_opers": [entry for entry in own_opers if isinstance(entry, dict)],
            }

    if result is None:
        raise ValueError("completed OperBox callback not found")
    return result


def build_cache(kind: str, text: str) -> dict[str, Any]:
    timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
    if kind == "depot":
        return {"timestamp": timestamp, "items": extract_depot(text)}

    payload = extract_operbox(text)
    return {"timestamp": timestamp, **payload}


def write_atomic(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        # [EN] Readers see either the old complete cache or the new one, never a partial JSON file. / [CN] 读取方只会看到旧缓存或完整新缓存，不会读到半截 JSON。
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract inventory callbacks from maa-cli logs")
    parser.add_argument("kind", choices=sorted(PREFIXES))
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    try:
        text = args.input.read_text(encoding="utf-8", errors="replace")
        cache = build_cache(args.kind, text)
        write_atomic(args.output, cache)
    except (OSError, ValueError) as error:
        print(f"inventory extraction failed: {error}", file=sys.stderr)
        return 1

    count = len(cache["items"] if args.kind == "depot" else cache["own_opers"])
    print(f"inventory cache updated: kind={args.kind}, entries={count}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
