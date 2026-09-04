#!/usr/bin/env python3

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "extract_maa_inventory.py"
SPEC = importlib.util.spec_from_file_location("extract_maa_inventory", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExtractMaaInventoryTest(unittest.TestCase):
    def test_extracts_last_completed_depot_callback(self) -> None:
        log = """
[INFO] Depot: {
  "taskchain": "Depot",
  "details": {"done": false, "data": "{\\"30011\\": 1}"}
}
[INFO] Depot: {
  "taskchain": "Depot",
  "details": {
    "done": true,
    "data": "{\\"30011\\":18000,\\"31043\\":317}"
  }
}
"""
        self.assertEqual(MODULE.extract_depot(log), {"30011": 18000, "31043": 317})

    def test_extracts_completed_operbox_callback(self) -> None:
        log = """
[INFO] OperBox: {
  "taskchain": "OperBox",
  "details": {
    "done": true,
    "all_oper": [{"id":"char_1","name":"能天使","own":true,"rarity":6}],
    "own_opers": [{"id":"char_1","name":"能天使","own":true,"elite":2,"level":90,"potential":1,"rarity":6}]
  }
}
"""
        result = MODULE.extract_operbox(log)
        self.assertEqual(result["own_opers"][0]["name"], "能天使")

    def test_atomic_output_is_valid_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "cache.json"
            MODULE.write_atomic(output, {"timestamp": "test", "items": {"30011": 2}})
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["items"]["30011"], 2)

    def test_rejects_incomplete_log(self) -> None:
        with self.assertRaises(ValueError):
            MODULE.extract_depot('[INFO] Depot: {"details":{"done":false,"data":"{}"}}')


if __name__ == "__main__":
    unittest.main()
