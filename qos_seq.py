#!/usr/bin/env python3
"""
Extract (time, seq, five_qi) from DU-QOS-TRACE sched_cfg_build logs.

Supports:
  - --start-time (ISO or time-only HH:MM:SS.ffffff)
  - --relative-time
  - --ue filtering (default UE0)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


LINE_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[DU-QOS-TRACE\]\s+ue=(?P<ue>\d+)\s+seq=(?P<seq>\d+)\s+stage=sched_cfg_build.*?"
    r"five_qi=(?P<five_qi>\d+)"
)


@dataclass
class Row:
    ts: datetime
    ue: int
    seq: int
    five_qi: int


def parse_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only --start-time requires at least one matched row")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_rows(path: str, ue_filter: int, start_time: str | None) -> List[Row]:
    out: List[Row] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE_RE.search(line)
            if not m:
                continue

            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            seq = int(m.group("seq"))
            five_qi = int(m.group("five_qi"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = parse_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            out.append(Row(ts=ts, ue=ue, seq=seq, five_qi=five_qi))

    out.sort(key=lambda r: r.ts)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract seq and 5QI from sched_cfg_build logs.")
    ap.add_argument("log_file", help="Path to gnb.log")
    ap.add_argument("--ue", type=int, default=0, help="UE index (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Start time: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument("--relative-time", action="store_true", help="Output relative seconds from base time")
    ap.add_argument("--no-header", action="store_true", help="Print rows only")
    args = ap.parse_args()

    rows = parse_rows(args.log_file, args.ue, args.start_time)
    if not rows:
        print(f"No sched_cfg_build rows found for UE{args.ue}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = parse_time_arg(args.start_time, rows[0].ts)
    else:
        base = rows[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,seq,five_qi")
        else:
            print("timestamp,seq,five_qi")

    for r in rows:
        if args.relative_time:
            rel = (r.ts - base).total_seconds()
            print(f"{rel:.6f},{r.seq},{r.five_qi}")
        else:
            print(f"{r.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{r.seq},{r.five_qi}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

