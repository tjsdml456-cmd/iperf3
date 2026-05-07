#!/usr/bin/env python3
"""
Extract UL queueing-delay events from scheduler logs.

Features:
  - Parse "[UL-DELAY-WEIGHT] UEX ... ul_queue_delay_ms_sum=Y" lines
  - Filter by UE index
  - Optional --start-time filtering (full ISO or time-only)
  - Optional --relative-time output (seconds from base time)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


DELAY_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[UL-DELAY-WEIGHT\]\s+UE(?P<ue>\d+)\s+"
    r".*?ul_queue_delay_ms_sum=(?P<queue_ms>[-+]?\d+(?:\.\d+)?)"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    queue_ms: float


def parse_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only argument requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_entries(log_path: str, ue_filter: int, start_time: str | None = None) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = DELAY_RE.search(line)
            if not m:
                continue

            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            queue_ms = float(m.group("queue_ms"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = parse_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            entries.append(Entry(ts=ts, ue=ue, queue_ms=queue_ms))

    entries.sort(key=lambda e: e.ts)
    return entries


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract UL queueing delay from UL-DELAY-WEIGHT logs.")
    ap.add_argument("log_file", help="Path to scheduler log file")
    ap.add_argument("--ue", type=int, default=0, help="UE index to extract (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time. Format: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument("--relative-time", action="store_true", help="Output relative seconds")
    ap.add_argument("--no-header", action="store_true", help="Print only rows without header")
    args = ap.parse_args()

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if not entries:
        print(f"No UL-DELAY-WEIGHT entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = parse_time_arg(args.start_time, entries[0].ts)
    else:
        base = entries[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,ul_queue_delay_ms_sum")
        else:
            print("timestamp,ul_queue_delay_ms_sum")

    for e in entries:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.queue_ms:.3f}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.queue_ms:.3f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
