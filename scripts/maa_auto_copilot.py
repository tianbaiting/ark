#!/usr/bin/env python3
"""Plan one unattended event clear with a compatible PRTS Plus copilot job."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable


DEFAULT_API = "https://prts.maa.plus"
POSITIVE_WORDS = ("稳定", "挂机", "一摆到底", "低配", "单核", "少人")
RISK_WORDS = ("不稳定", "概率", "凹", "手动编队", "需要补人", "漏怪", "慎用", "失败重开")
UNATTENDED_BLOCKERS = (
    "没办法自动",
    "无法自动",
    "不能自动",
    "需手动",
    "需要手动",
    "手动选",
    "手动操作",
)
STAGE_CODE_RE = re.compile(r"^([A-Z][A-Z0-9]*)-(?:(EX|S)-)?(\d+)$")


@dataclass(frozen=True)
class ActiveEvent:
    title: str
    prefix: str


@dataclass(frozen=True)
class StageTarget:
    event_id: str
    event_title: str
    code: str
    stage_id: str
    raid: bool
    release_day: int
    sort_key: tuple[int, int, int]

    @property
    def state_key(self) -> str:
        return f"{self.code}:{'raid' if self.raid else 'normal'}"


def parse_active_events(text: str) -> list[ActiveEvent]:
    in_side_story = False
    current_title = ""
    prefixes_by_title: dict[str, set[str]] = {}

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if line.startswith("Opening side story stages:"):
            in_side_story = True
            current_title = ""
            continue
        if in_side_story and line.startswith("Opening "):
            break
        if not in_side_story:
            continue

        title_match = re.match(r"^-\s+(.+)$", line)
        if title_match:
            current_title = title_match.group(1).strip()
            prefixes_by_title.setdefault(current_title, set())
            continue

        stage_match = re.match(r"^\s+-\s+([^:]+):", line)
        if not stage_match or not current_title:
            continue
        code_match = STAGE_CODE_RE.match(stage_match.group(1).strip())
        if code_match:
            prefixes_by_title[current_title].add(code_match.group(1))

    return [
        ActiveEvent(title=title, prefix=prefix)
        for title, prefixes in prefixes_by_title.items()
        for prefix in sorted(prefixes)
    ]


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        # [EN] A killed cron job must not leave a half-written completion ledger. / [CN] cron 被中止时不能留下写到一半的完成状态账本。
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def parse_manifest_start(value: str, time_zone: int | float | str = 0) -> datetime | None:
    try:
        offset = float(time_zone or 0)
        local_zone = timezone(timedelta(hours=offset))
        return (
            datetime.strptime(value, "%Y/%m/%d %H:%M:%S")
            .replace(tzinfo=local_zone)
            .astimezone(timezone.utc)
        )
    except (TypeError, ValueError, OverflowError):
        return None


def discover_manifest_events(
    manifest: dict[str, Any], client: str, now: datetime
) -> list[ActiveEvent]:
    side_stories = manifest.get(client, {}).get("sideStoryStage", {})
    if not isinstance(side_stories, dict):
        return []

    current = now.astimezone(timezone.utc)
    discovered: set[tuple[str, str]] = set()
    for entry in side_stories.values():
        if not isinstance(entry, dict):
            continue
        activity = entry.get("Activity", {})
        if not isinstance(activity, dict):
            continue
        time_zone = activity.get("TimeZone", 0)
        start = parse_manifest_start(activity.get("UtcStartTime", ""), time_zone)
        expire = parse_manifest_start(activity.get("UtcExpireTime", ""), time_zone)
        if start is None or expire is None or current < start or current > expire:
            continue

        title = str(activity.get("Tip") or activity.get("StageName") or "").strip()
        if not title:
            continue
        for stage in entry.get("Stages", []):
            if not isinstance(stage, dict):
                continue
            value = stage.get("Value")
            if not isinstance(value, str):
                continue
            match = STAGE_CODE_RE.match(value)
            if match:
                discovered.add((title, match.group(1)))

    return [ActiveEvent(title, prefix) for title, prefix in sorted(discovered)]


def discover_active_events(
    activity_text: str, manifest: dict[str, Any], client: str, now: datetime
) -> list[ActiveEvent]:
    events = parse_active_events(activity_text) + discover_manifest_events(manifest, client, now)
    unique: dict[tuple[str, str], ActiveEvent] = {}
    for event in events:
        unique[(event.title, event.prefix)] = event
    return list(unique.values())


def manifest_identity(
    manifest: dict[str, Any], client: str, event: ActiveEvent, now: datetime
) -> tuple[str, int, bool]:
    side_stories = manifest.get(client, {}).get("sideStoryStage", {})
    best: tuple[str, int, bool] | None = None

    if not isinstance(side_stories, dict):
        return f"{event.prefix}:{event.title}", 0, "复刻" in event.title

    for manifest_key, entry in side_stories.items():
        if not isinstance(entry, dict):
            continue
        stages = entry.get("Stages", [])
        values = {
            stage.get("Value")
            for stage in stages
            if isinstance(stage, dict) and isinstance(stage.get("Value"), str)
        }
        if not any(
            value == f"SSReopen-{event.prefix}" or value.startswith(f"{event.prefix}-")
            for value in values
        ):
            continue

        activity = entry.get("Activity", {})
        if not isinstance(activity, dict):
            activity = {}
        start_text = activity.get("UtcStartTime", "")
        start = parse_manifest_start(start_text, activity.get("TimeZone", 0))
        elapsed_days = max(0, int((now - start).total_seconds() // 86400)) if start else 0
        event_id = f"{event.prefix}:{manifest_key}:{start_text or event.title}"
        is_reopen = str(manifest_key).lower().startswith("ssreopen") or "复刻" in event.title
        best = (event_id, elapsed_days, is_reopen)
        if activity.get("Tip") and str(activity["Tip"]) in event.title:
            break

    return best or (f"{event.prefix}:{event.title}", 0, "复刻" in event.title)


def build_targets(
    event: ActiveEvent,
    event_id: str,
    elapsed_days: int,
    is_reopen: bool,
    levels: Iterable[dict[str, Any]],
    scope: set[str],
    ex_delay_days: int,
    s_delay_days: int,
) -> list[StageTarget]:
    records: dict[tuple[str, bool], str] = {}

    for level in levels:
        code = level.get("cat_three")
        stage_id = level.get("stage_id")
        if not isinstance(code, str) or not isinstance(stage_id, str):
            continue
        match = STAGE_CODE_RE.match(code)
        if not match or match.group(1) != event.prefix:
            continue

        category = (match.group(2) or "normal").lower()
        if category not in scope:
            continue
        raid = stage_id.endswith("#f#")
        records[(code, raid)] = stage_id

    targets: list[StageTarget] = []
    category_order = {"normal": 0, "ex": 1, "s": 2}
    for (code, raid), stage_id in records.items():
        match = STAGE_CODE_RE.match(code)
        if match is None:
            continue
        category = (match.group(2) or "normal").lower()
        if category == "normal" and raid:
            continue
        delay = 0 if is_reopen else {"normal": 0, "ex": ex_delay_days, "s": s_delay_days}[category]
        if elapsed_days < delay:
            continue
        targets.append(
            StageTarget(
                event_id=event_id,
                event_title=event.title,
                code=code,
                stage_id=stage_id,
                raid=raid,
                release_day=delay,
                sort_key=(category_order[category], int(match.group(3)), int(raid)),
            )
        )

    return sorted(targets, key=lambda target: target.sort_key)


def http_json(url: str, timeout: int, retries: int, data: bytes | None = None) -> dict[str, Any]:
    last_error: Exception | None = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(
            url,
            data=data,
            headers={"User-Agent": "ark-maa-auto-copilot/1.0", "Accept": "application/json"},
            method="POST" if data is not None else "GET",
        )
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                value = json.loads(response.read())
            if not isinstance(value, dict):
                raise ValueError("API response is not an object")
            return value
        except (OSError, ValueError, urllib.error.URLError) as error:
            last_error = error
            if attempt < retries:
                time.sleep(1)
    raise RuntimeError(f"request failed after {retries} attempts: {url}: {last_error}")


def load_owned_operators(path: Path) -> dict[str, dict[str, Any]] | None:
    cache = read_json(path, {})
    entries = cache.get("own_opers") if isinstance(cache, dict) else None
    if not isinstance(entries, list) or not entries:
        return None
    return {
        entry["name"]: entry
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }


def operator_satisfies(owned: dict[str, Any] | None, required: dict[str, Any]) -> bool:
    if owned is None:
        return False
    requirements = required.get("requirements", {})
    if not isinstance(requirements, dict):
        return True

    required_elite = safe_int(requirements.get("elite", 0))
    owned_elite = safe_int(owned.get("elite", 0))
    if owned_elite < required_elite:
        return False
    required_level = safe_int(requirements.get("level", 0))
    owned_level = safe_int(owned.get("level", 0))
    return owned_elite > required_elite or owned_level >= required_level


def safe_int(value: Any, default: int = 0) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return default


def safe_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return default


def missing_slots(content: dict[str, Any], owned: dict[str, dict[str, Any]] | None) -> int:
    fixed = [oper for oper in content.get("opers", []) if isinstance(oper, dict)]
    groups = [group for group in content.get("groups", []) if isinstance(group, dict)]
    if owned is None:
        return len(fixed)

    missing = sum(
        not operator_satisfies(owned.get(str(oper.get("name", ""))), oper)
        for oper in fixed
    )
    for group in groups:
        alternatives = [oper for oper in group.get("opers", []) if isinstance(oper, dict)]
        if alternatives and not any(
            operator_satisfies(owned.get(str(oper.get("name", ""))), oper)
            for oper in alternatives
        ):
            missing += 1
    return missing


def candidate_score(candidate: dict[str, Any], content: dict[str, Any]) -> float:
    document = content.get("doc", {})
    title = str(document.get("title", "")) if isinstance(document, dict) else ""
    details = str(document.get("details", "")) if isinstance(document, dict) else ""
    searchable = f"{title}\n{details}"
    positive = sum(word in searchable for word in POSITIVE_WORDS)
    risky = sum(word in searchable for word in RISK_WORDS)
    likes = safe_float(candidate.get("like", 0))
    dislikes = safe_float(candidate.get("dislike", 0))
    hot_score = safe_float(candidate.get("hot_score", 0))
    fixed_count = len([oper for oper in content.get("opers", []) if isinstance(oper, dict)])
    module_slots = required_module_slots(content)
    approval = (likes + 1.0) / (likes + dislikes + 2.0)
    return (
        hot_score
        + 2.0 * math.log1p(likes)
        + 8.0 * approval
        + 2.5 * positive
        - 5.0 * risky
        - 0.4 * fixed_count
        - 1.5 * module_slots
    )


def required_module_slots(content: dict[str, Any]) -> int:
    def required(oper: dict[str, Any]) -> int:
        requirements = oper.get("requirements", {})
        if not isinstance(requirements, dict):
            return 0
        return int(safe_int(requirements.get("module", -1)) > 0)

    fixed = sum(required(oper) for oper in content.get("opers", []) if isinstance(oper, dict))
    groups = 0
    for group in content.get("groups", []):
        if not isinstance(group, dict):
            continue
        alternatives = [oper for oper in group.get("opers", []) if isinstance(oper, dict)]
        if alternatives:
            groups += min(required(oper) for oper in alternatives)
    return fixed + groups


def query_candidates(api: str, target: StageTarget, timeout: int, retries: int) -> list[dict[str, Any]]:
    query = urllib.parse.urlencode(
        {
            "page": 1,
            "limit": 50,
            "levelKeyword": target.stage_id,
            "orderBy": "hot",
            "desc": "true",
            "type": "PRTS",
        }
    )
    response = http_json(f"{api}/copilot/query?{query}", timeout, retries)
    data = response.get("data", {})
    return data.get("data", []) if isinstance(data, dict) and isinstance(data.get("data"), list) else []


def choose_candidate(
    candidates: Iterable[dict[str, Any]],
    target: StageTarget,
    owned: dict[str, dict[str, Any]] | None,
    failures: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any], int] | None:
    ranked: list[tuple[int, float, dict[str, Any], dict[str, Any], int]] = []
    for candidate in candidates:
        if candidate.get("available") is False or candidate.get("type") not in (None, "PRTS"):
            continue
        try:
            content = json.loads(candidate.get("content", "{}"))
        except (TypeError, json.JSONDecodeError):
            continue
        if not isinstance(content, dict) or content.get("stage_name") != target.stage_id:
            continue
        if content.get("type") == "SSS":
            continue
        document = content.get("doc", {})
        if isinstance(document, dict):
            searchable = f"{document.get('title', '')}\n{document.get('details', '')}"
            if any(blocker in searchable for blocker in UNATTENDED_BLOCKERS):
                continue
        missing = missing_slots(content, owned)
        if missing > 1:
            continue
        job_id = str(candidate.get("id", ""))
        failure_count = safe_int(failures.get(job_id, {}).get("count", 0)) if isinstance(failures.get(job_id), dict) else 0
        ranked.append((failure_count, -candidate_score(candidate, content), candidate, content, missing))

    if not ranked:
        return None
    _, _, candidate, content, missing = min(ranked, key=lambda row: (row[0], row[1]))
    return candidate, content, missing


def download_job(api: str, job_id: int, output: Path, timeout: int, retries: int) -> dict[str, Any]:
    response = http_json(f"{api}/copilot/get/{job_id}", timeout, retries)
    data = response.get("data", {})
    if not isinstance(data, dict):
        raise RuntimeError(f"copilot {job_id} has no data")
    raw_content = data.get("content")
    try:
        content = json.loads(raw_content)
    except (TypeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"copilot {job_id} has invalid content: {error}") from error
    if not isinstance(content, dict):
        raise RuntimeError(f"copilot {job_id} content is not an object")
    write_json_atomic(output, content)
    return content


def event_state(state: dict[str, Any], event_id: str) -> dict[str, Any]:
    events = state.setdefault("events", {})
    if not isinstance(events, dict):
        state["events"] = {}
        events = state["events"]
    value = events.setdefault(event_id, {"completed": {}, "failures": {}})
    if not isinstance(value, dict):
        value = {"completed": {}, "failures": {}}
        events[event_id] = value
    if not isinstance(value.get("completed"), dict):
        value["completed"] = {}
    if not isinstance(value.get("failures"), dict):
        value["failures"] = {}
    return value


def plan(args: argparse.Namespace) -> int:
    activity_text = args.activity_file.read_text(encoding="utf-8", errors="replace")
    manifest = read_json(args.activity_manifest, {})
    now = datetime.now(timezone.utc)
    active_events = discover_active_events(activity_text, manifest, args.client, now)
    if not active_events:
        return 0

    state = read_json(args.state, {"schema": 1, "events": {}})
    if not isinstance(state, dict):
        state = {"schema": 1, "events": {}}
    owned = load_owned_operators(args.operbox_cache)
    levels_response = http_json(f"{args.api}/arknights/level", args.timeout, args.retries)
    levels = levels_response.get("data", [])
    if not isinstance(levels, list):
        raise RuntimeError("stage API returned no level list")

    scope = {part.strip().lower() for part in args.scope.split(",") if part.strip()}
    for active_event in active_events:
        event_id, elapsed_days, is_reopen = manifest_identity(manifest, args.client, active_event, now)
        targets = build_targets(
            active_event,
            event_id,
            elapsed_days,
            is_reopen,
            levels,
            scope,
            args.ex_delay_days,
            args.s_delay_days,
        )
        ledger = event_state(state, event_id)
        completed = ledger.get("completed", {})
        failures_by_stage = ledger.get("failures", {})

        for target in targets:
            if target.state_key in completed:
                continue
            failures = failures_by_stage.get(target.state_key, {})
            if not isinstance(failures, dict):
                failures = {}
            candidates = query_candidates(args.api, target, args.timeout, args.retries)
            choice = choose_candidate(candidates, target, owned, failures)
            if choice is None:
                print(f"no compatible copilot found for {target.code} raid={target.raid}", file=sys.stderr)
                return 0

            candidate, _, missing = choice
            job_id = int(candidate["id"])
            event_dir = re.sub(r"[^A-Za-z0-9_.-]+", "_", event_id)
            stage_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", target.state_key)
            host_file = args.download_dir / event_dir / f"{stage_name}-{job_id}.json"
            full_content = download_job(args.api, job_id, host_file, args.timeout, args.retries)
            if full_content.get("stage_name") != target.stage_id:
                raise RuntimeError(f"copilot {job_id} stage changed during download")
            relative = host_file.relative_to(args.download_dir)
            container_file = args.container_download_dir.rstrip("/") + "/" + relative.as_posix()
            output = {
                "event_id": event_id,
                "event_title": active_event.title,
                "stage_key": target.state_key,
                "stage_code": target.code,
                "stage_id": target.stage_id,
                "raid": target.raid,
                "job_id": job_id,
                "missing_slots": missing,
                "host_file": str(host_file),
                "container_file": container_file,
            }
            print(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
            return 0

    return 0


def update_result(args: argparse.Namespace, success: bool) -> int:
    state = read_json(args.state, {"schema": 1, "events": {}})
    if not isinstance(state, dict):
        state = {"schema": 1, "events": {}}
    ledger = event_state(state, args.event_id)
    if success:
        ledger["completed"][args.stage_key] = {
            "job_id": args.job_id,
            "completed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        ledger["failures"].pop(args.stage_key, None)
    else:
        stage_failures = ledger["failures"].setdefault(args.stage_key, {})
        job = stage_failures.setdefault(str(args.job_id), {"count": 0})
        job["count"] = safe_int(job.get("count", 0)) + 1
        job["last_failed_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
    write_json_atomic(args.state, state)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Plan and track automatic event copilot jobs")
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--activity-file", type=Path, required=True)
    plan_parser.add_argument("--activity-manifest", type=Path, required=True)
    plan_parser.add_argument("--operbox-cache", type=Path, required=True)
    plan_parser.add_argument("--state", type=Path, required=True)
    plan_parser.add_argument("--download-dir", type=Path, required=True)
    plan_parser.add_argument("--container-download-dir", default="/root/.cache/maa/auto-copilot")
    plan_parser.add_argument("--client", default="Official")
    plan_parser.add_argument("--scope", default="normal,ex,s")
    plan_parser.add_argument("--ex-delay-days", type=int, default=7)
    plan_parser.add_argument("--s-delay-days", type=int, default=14)
    plan_parser.add_argument("--api", default=DEFAULT_API)
    plan_parser.add_argument("--timeout", type=int, default=20)
    plan_parser.add_argument("--retries", type=int, default=3)

    for command in ("success", "failure"):
        result_parser = subparsers.add_parser(command)
        result_parser.add_argument("--state", type=Path, required=True)
        result_parser.add_argument("--event-id", required=True)
        result_parser.add_argument("--stage-key", required=True)
        result_parser.add_argument("--job-id", type=int, required=True)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "plan":
            return plan(args)
        return update_result(args, success=args.command == "success")
    except (OSError, RuntimeError, ValueError) as error:
        print(f"auto-copilot error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
