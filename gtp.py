#!/usr/bin/env python3
"""
Extract GTP-U DSCP change events from gNB logs.

Default behavior:
  - Parse "[GTPU] DL SDU DSCP changed to X" lines
  - Filter UE0
  - Output timestamp + changed DSCP value

Also supports:
  - --start-time (ISO or time-only)
  - --relative-time (seconds from base time)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


DSCP_CHANGE_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"ue=(?P<ue>\d+).*?"
    r"\[GTPU\]\s+DL SDU DSCP changed to\s+(?P<dscp>\d+)\b"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    dscp: int


def _parse_start_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    """
    Parse --start-time.
    Accepts either:
      - Full ISO time: 2026-04-26T12:12:02.874250
      - Time only:     12:12:02.874250 (date inferred from first matched log line)
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
            m = DSCP_CHANGE_RE.search(line)
            if not m:
                continue

            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            dscp = int(m.group("dscp"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            entries.append(Entry(ts=ts, ue=ue, dscp=dscp))

    entries.sort(key=lambda e: e.ts)
    return entries


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract GTP-U DSCP change events.")
    ap.add_argument("log_file", help="Path to gnb.log")
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
        help="Output x-axis as relative seconds from base time (0.0 at --start-time if set, else first row).",
    )
    ap.add_argument(
        "--no-header",
        action="store_true",
        help="Print only rows without header",
    )
    args = ap.parse_args()

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if not entries:
        print(f"No GTP-U DSCP change entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = _parse_start_time_arg(args.start_time, entries[0].ts)
    else:
        base = entries[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,dscp")
        else:
            print("timestamp,dscp")

    for e in entries:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.dscp}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.dscp}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
