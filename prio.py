#!/usr/bin/env python3
"""
Extract DL prio_weight change events from scheduler logs.

Features:
  - Parse "DL Priority calc: UEX ... prio_weight=Y" lines
  - Filter by UE index
  - Emit only rows where prio_weight changes from previous value
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


PRIO_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"DL Priority calc:\s+UE(?P<ue>\d+)\s+.*?"
    r"prio_weight=(?P<prio_weight>[-+]?\d+(?:\.\d+)?)"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    prio_weight: float


def _parse_start_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    """
    Parse --start-time.
    Accepts either:
      - Full ISO time: 2026-04-26T12:11:58.038531
      - Time only:     12:11:58.038531 (date inferred from first matched log line)
    """
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only --start-time requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_entries(log_path: str, ue_filter: int, start_time: str | None = None) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = PRIO_RE.search(line)
            if not m:
                continue

            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            prio_weight = float(m.group("prio_weight"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            entries.append(Entry(ts=ts, ue=ue, prio_weight=prio_weight))

    entries.sort(key=lambda e: e.ts)
    return entries


def extract_changes(entries: List[Entry], epsilon: float) -> List[Entry]:
    if not entries:
        return []

    out: List[Entry] = []
    prev = entries[0].prio_weight
    out.append(entries[0])

    for e in entries[1:]:
        if abs(e.prio_weight - prev) > epsilon:
            out.append(e)
            prev = e.prio_weight
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract prio_weight change events from scheduler logs.")
    ap.add_argument("log_file", help="Path to scheduler log file")
    ap.add_argument("--ue", type=int, default=0, help="UE index to extract (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time. Format: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output relative seconds. Base is --start-time if provided, otherwise first output row.",
    )
    ap.add_argument(
        "--epsilon",
        type=float,
        default=1e-12,
        help="Minimum absolute difference to treat as a change (default: 1e-12)",
    )
    ap.add_argument(
        "--no-header",
        action="store_true",
        help="Print only rows without header",
    )
    args = ap.parse_args()

    if args.epsilon < 0:
        print("ERROR: --epsilon must be >= 0", file=sys.stderr)
        return 2

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if not entries:
        print(f"No priority entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    changed = extract_changes(entries, args.epsilon)
    if not changed:
        print(f"No prio_weight changes found for UE{args.ue}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = _parse_start_time_arg(args.start_time, changed[0].ts)
    else:
        base = changed[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,prio_weight")
        else:
            print("timestamp,prio_weight")

    for e in changed:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.prio_weight:.6f}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.prio_weight:.6f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
