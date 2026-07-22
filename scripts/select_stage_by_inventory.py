#!/usr/bin/env python3
"""Select the event stage whose primary drop material has the lowest depot inventory.

Usage:
    echo "TD-8 TD-7 TD-6" | python3 select_stage_by_inventory.py [--depot-cache PATH]

Reads stage codes from stdin (space-separated), outputs the best stage code to stdout.
If no depot cache exists or no drop data is available, falls back to the first stage.
"""

import argparse
import json
import re
import sys
import urllib.request
import urllib.error
from collections import defaultdict
from typing import Optional


PENGUIN_STAGES_URL = "https://penguin-stats.io/PenguinStats/api/v2/stages"
PENGUIN_MATRIX_URL = "https://penguin-stats.io/PenguinStats/api/v2/result/matrix?server=CN"
PENGUIN_ITEMS_URL = "https://penguin-stats.io/PenguinStats/api/v2/items"

CACHE_TIMEOUT_SECONDS = 8 * 86400  # 8 days for local depot cache

# T3/T4 material item IDs start with "3" and have length 5, or are 4-digit T4 materials.
# We want rarity >= 3 materials for meaningful selection.
# Common low-value items to skip: exp cards (2xxx), gold (3003), orundum (4003), etc.
SKIP_ITEM_TYPES = {"CARD_EXP", "DIAMOND_SHD", "DIAMOND", "GOLD", "TKT_RECRUIT", "TKT_GACHA",
                   "TKT_INST_FIN", "TKT_EPOCH", "FURN", "ACTIVITY_ITEM", "ACTIVITY_COIN"}


def load_depot_cache(path: str) -> Optional[dict]:
    try:
        with open(path) as f:
            cache = json.load(f)
        items = cache.get("items", {})
        if not items:
            return None
        return items
    except (FileNotFoundError, json.JSONDecodeError, KeyError):
        return None


def fetch_json(url: str, timeout: int = 30) -> Optional[object]:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ark-maa-scripts/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        print(f"[warn] fetch {url} failed: {e}", file=sys.stderr)
        return None


def build_code_to_all_ids(stages_data: list) -> dict:
    mapping = {}
    for s in stages_data:
        code = s.get("code", "")
        stage_id = s.get("stageId", "")
        if code and stage_id:
            mapping.setdefault(code, set()).add(stage_id)
            mapping.setdefault(code, set()).add(f"{stage_id}_perm")
    return mapping


def get_stage_drops(matrix_data: dict, stage_ids: set) -> list:
    matrix = matrix_data.get("matrix", [])
    drops = []
    for entry in matrix:
        sid = entry.get("stageId", "")
        if sid in stage_ids:
            item_id = entry.get("itemId", "")
            quantity = entry.get("quantity", 0)
            times = entry.get("times", 1)
            if times > 0 and quantity > 0:
                drops.append({
                    "itemId": item_id,
                    "rate": quantity / times,
                    "quantity": quantity,
                    "times": times,
                })
    return drops


def get_items_by_type(stages_data: list, stage_ids: set) -> list:
    items = []
    for s in stages_data:
        if s.get("stageId") in stage_ids or f"{s.get('stageId')}_perm" in stage_ids:
            for d in s.get("dropInfos", []):
                if d.get("dropType") == "NORMAL_DROP":
                    items.append(d.get("itemId", ""))
    return items


def build_item_type_map(items_data: list) -> dict:
    type_map = {}
    for item in items_data:
        type_map[item.get("itemId", "")] = item.get("itemType", "")
    return type_map


def find_primary_material(drops: list, item_type_map: dict) -> Optional[str]:
    if not drops:
        return None
    filtered = [d for d in drops if item_type_map.get(d["itemId"], "") not in SKIP_ITEM_TYPES]
    if not filtered:
        filtered = drops
    filtered.sort(key=lambda d: d["rate"], reverse=True)
    return filtered[0]["itemId"]


def select_best_stage(stage_codes: list, depot_items: Optional[dict],
                      penguin_stages: list, penguin_matrix: dict,
                      item_type_map: dict) -> str:
    if not stage_codes:
        return ""

    if not depot_items:
        print("[info] no depot cache, selecting first event stage", file=sys.stderr)
        return stage_codes[0]

    code_to_ids = build_code_to_all_ids(penguin_stages)

    stage_materials = {}
    for code in stage_codes:
        stage_ids = code_to_ids.get(code, set())
        if not stage_ids:
            continue

        drops = get_stage_drops(penguin_matrix, stage_ids)
        primary = find_primary_material(drops, item_type_map)

        if not primary:
            drop_ids = get_items_by_type(penguin_stages, stage_ids)
            material_ids = [i for i in drop_ids if item_type_map.get(i, "") not in SKIP_ITEM_TYPES]
            primary = material_ids[0] if material_ids else None

        if primary:
            stage_materials[code] = primary

    if not stage_materials:
        print("[info] no material data for event stages, selecting first", file=sys.stderr)
        return stage_codes[0]

    scored = []
    for code, mat_id in stage_materials.items():
        qty = depot_items.get(mat_id, 0)
        scored.append((qty, code, mat_id))
        print(f"[info] {code}: primary material {mat_id}, depot qty={qty}", file=sys.stderr)

    scored.sort(key=lambda x: x[0])
    best_qty, best_code, best_mat = scored[0]
    print(f"[info] selected {best_code} (material {best_mat} has lowest qty={best_qty})", file=sys.stderr)
    return best_code


def main():
    parser = argparse.ArgumentParser(description="Select event stage by depot inventory")
    parser.add_argument("--depot-cache", default="/home/tian/ark/depot_cache.json",
                        help="Path to depot_cache.json")
    parser.add_argument("--no-fetch", action="store_true",
                        help="Skip fetching Penguin Stats data (use cached or fallback)")
    args = parser.parse_args()

    input_text = sys.stdin.read().strip()
    stage_codes = [s for s in re.split(r'[\s,]+', input_text) if s and re.match(r'^[A-Z]+-\d+$', s)]

    if not stage_codes:
        print("[warn] no valid stage codes from input", file=sys.stderr)
        sys.exit(1)

    depot_items = load_depot_cache(args.depot_cache)
    if depot_items:
        print(f"[info] loaded {len(depot_items)} items from depot cache", file=sys.stderr)
    else:
        print("[info] depot cache empty or missing", file=sys.stderr)

    if args.no_fetch:
        penguin_stages = []
        penguin_matrix = {"matrix": []}
        item_type_map = {}
    else:
        print("[info] fetching Penguin Stats data...", file=sys.stderr)
        penguin_stages = fetch_json(PENGUIN_STAGES_URL) or []
        penguin_matrix = fetch_json(PENGUIN_MATRIX_URL) or {"matrix": []}
        items_data = fetch_json(PENGUIN_ITEMS_URL) or []
        item_type_map = build_item_type_map(items_data)

    best = select_best_stage(stage_codes, depot_items, penguin_stages, penguin_matrix, item_type_map)
    print(best)


if __name__ == "__main__":
    main()
