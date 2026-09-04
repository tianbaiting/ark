#!/usr/bin/env python3

import importlib.util
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "maa_auto_copilot.py"
SPEC = importlib.util.spec_from_file_location("maa_auto_copilot", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class MaaAutoCopilotTest(unittest.TestCase):
    def test_parses_only_side_story_stage_codes(self) -> None:
        text = """Opening side story stages:
- SideStory「墟」复刻
  - SSReopen-AT: 代理1~8关
  - AT-8: 类凝结核
  - AT-4: 搓玉效率0.91
Opening mini games:
- AT-相谈室
"""
        self.assertEqual(MODULE.parse_active_events(text), [MODULE.ActiveEvent("SideStory「墟」复刻", "AT")])

    def test_builds_normal_then_ex_and_raid_targets(self) -> None:
        event = MODULE.ActiveEvent("SideStory test", "XY")
        levels = [
            {"cat_three": "XY-2", "stage_id": "act_02"},
            {"cat_three": "XY-1", "stage_id": "act_01"},
            {"cat_three": "XY-EX-1", "stage_id": "act_ex01#f#"},
            {"cat_three": "XY-EX-1", "stage_id": "act_ex01"},
            {"cat_three": "XY-S-1", "stage_id": "act_s01"},
        ]
        targets = MODULE.build_targets(event, "event", 8, False, levels, {"normal", "ex", "s"}, 7, 14)
        self.assertEqual([target.state_key for target in targets], ["XY-1:normal", "XY-2:normal", "XY-EX-1:normal", "XY-EX-1:raid"])

    def test_reopen_unlocks_all_sections_immediately(self) -> None:
        event = MODULE.ActiveEvent("SideStory test 复刻", "XY")
        levels = [{"cat_three": "XY-S-1", "stage_id": "act_s01"}]
        targets = MODULE.build_targets(event, "event", 0, True, levels, {"s"}, 7, 14)
        self.assertEqual([target.code for target in targets], ["XY-S-1"])

    def test_manifest_identity_uses_activity_start(self) -> None:
        manifest = {
            "Official": {
                "sideStoryStage": {
                    "XY": {
                        "Activity": {"Tip": "SideStory test", "UtcStartTime": "2026/08/01 12:00:00"},
                        "Stages": [{"Value": "XY-8"}],
                    }
                }
            }
        }
        event_id, elapsed, reopen = MODULE.manifest_identity(
            manifest,
            "Official",
            MODULE.ActiveEvent("SideStory test", "XY"),
            datetime(2026, 8, 9, 12, tzinfo=timezone.utc),
        )
        self.assertEqual(event_id, "XY:XY:2026/08/01 12:00:00")
        self.assertEqual(elapsed, 8)
        self.assertFalse(reopen)

    def test_discovers_current_manifest_event_when_cli_activity_is_stale(self) -> None:
        manifest = {
            "Official": {
                "sideStoryStage": {
                    "SR": {
                        "Activity": {
                            "Tip": "SideStory「月行水上」",
                            "UtcStartTime": "2026/09/04 12:00:00",
                            "UtcExpireTime": "2026/09/18 03:59:59",
                            "TimeZone": 8,
                        },
                        "Stages": [{"Value": "SR-8"}, {"Value": "SR-5"}],
                    }
                }
            }
        }
        events = MODULE.discover_active_events(
            "Opening side story stages:\n",
            manifest,
            "Official",
            datetime(2026, 9, 4, 9, tzinfo=timezone.utc),
        )
        self.assertEqual(events, [MODULE.ActiveEvent("SideStory「月行水上」", "SR")])

    def test_does_not_discover_expired_manifest_event(self) -> None:
        manifest = {
            "Official": {
                "sideStoryStage": {
                    "XY": {
                        "Activity": {
                            "Tip": "SideStory old",
                            "UtcStartTime": "2026/08/01 12:00:00",
                            "UtcExpireTime": "2026/08/10 03:59:59",
                            "TimeZone": 8,
                        },
                        "Stages": [{"Value": "XY-8"}],
                    }
                }
            }
        }
        events = MODULE.discover_active_events(
            "",
            manifest,
            "Official",
            datetime(2026, 9, 4, 9, tzinfo=timezone.utc),
        )
        self.assertEqual(events, [])

    def test_prefers_owned_compatible_job_before_failed_job(self) -> None:
        target = MODULE.StageTarget("event", "title", "XY-1", "act_01", False, 0, (0, 1, 0))
        candidates = [
            {
                "id": 1,
                "type": "PRTS",
                "available": True,
                "hot_score": 100,
                "like": 1000,
                "content": '{"stage_name":"act_01","opers":[{"name":"未持有"}]}',
            },
            {
                "id": 2,
                "type": "PRTS",
                "available": True,
                "hot_score": 10,
                "like": 100,
                "content": '{"stage_name":"act_01","doc":{"title":"稳定挂机"},"opers":[{"name":"能天使","requirements":{"elite":2,"level":60}}]}',
            },
        ]
        owned = {"能天使": {"name": "能天使", "elite": 2, "level": 90}}
        choice = MODULE.choose_candidate(candidates, target, owned, {"1": {"count": 2}})
        self.assertIsNotNone(choice)
        self.assertEqual(choice[0]["id"], 2)
        self.assertEqual(choice[2], 0)

    def test_skips_job_that_explicitly_requires_manual_intervention(self) -> None:
        target = MODULE.StageTarget(
            "event", "title", "XY-1", "act_01", False, 0, (0, 1, 0)
        )
        candidates = [
            {
                "id": 1,
                "type": "PRTS",
                "available": True,
                "hot_score": 100,
                "like": 1000,
                "content": '{"stage_name":"act_01","doc":{"details":"本关没办法自动，需要手动选择"}}',
            },
            {
                "id": 2,
                "type": "PRTS",
                "available": True,
                "hot_score": 1,
                "like": 1,
                "content": '{"stage_name":"act_01","doc":{"details":"稳定挂机"}}',
            },
        ]
        choice = MODULE.choose_candidate(candidates, target, {}, {})
        self.assertIsNotNone(choice)
        self.assertEqual(choice[0]["id"], 2)

    def test_penalizes_unverifiable_module_requirements(self) -> None:
        base = {"stage_name": "act_01", "doc": {}, "groups": []}
        no_module = {**base, "opers": [{"name": "A", "requirements": {"module": -1}}]}
        three_modules = {
            **base,
            "opers": [
                {"name": "A", "requirements": {"module": 1}},
                {"name": "B", "requirements": {"module": 2}},
                {"name": "C", "requirements": {"module": 1}},
            ],
        }
        candidate = {"like": 10, "dislike": 0, "hot_score": 0}
        self.assertGreater(
            MODULE.candidate_score(candidate, no_module),
            MODULE.candidate_score(candidate, three_modules),
        )

    def test_success_result_persists_completion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            args = type(
                "Args",
                (),
                {"state": state, "event_id": "event", "stage_key": "XY-1:normal", "job_id": 7},
            )()
            self.assertEqual(MODULE.update_result(args, success=True), 0)
            stored = MODULE.read_json(state, {})
            self.assertEqual(stored["events"]["event"]["completed"]["XY-1:normal"]["job_id"], 7)


if __name__ == "__main__":
    unittest.main()
