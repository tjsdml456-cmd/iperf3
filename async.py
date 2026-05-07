#!/usr/bin/env python3
"""Extract event rows: time, transition, 5QI, status."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


LINE_RE = re.compile(
    r"\[(?P<wall>[^\]]+)\].*?transition#(?P<idx>\d+).*?5QI=(?P<q>\d+).*?(?P<action>전송|성공|실패)\s+\((?P<tag>async dispatch|async)\)",
    re.IGNORECASE,
)


@dataclass
class EventRow:
    wall: str
    transition: int
    five_qi: int
    status: str  # 전송 | 성공 | 실패


def parse_wall_time(value: str) -> datetime:
    m = re.match(r"^(?P<hms>\d{2}:\d{2}:\d{2})(?:\.(?P<frac>\d+))?$", value)
    if not m:
        raise ValueError(f"invalid wall time format: {value}")
    hms = m.group("hms")
    frac = m.group("frac") or "0"
    frac6 = (frac + "000000")[:6]
    return datetime.strptime(f"{hms}.{frac6}", "%H:%M:%S.%f")


def parse_log(path: str) -> List[EventRow]:
    rows: List[EventRow] = []

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.strip()
            m = LINE_RE.search(line)
            if not m:
                continue

            idx = int(m.group("idx"))
            wall = m.group("wall")
            rows.append(
                EventRow(
                    wall=wall,
                    transition=idx,
                    five_qi=int(m.group("q")),
                    status=m.group("action"),
                )
            )

    return rows


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract event rows: time, transition, 5QI, status."
    )
    ap.add_argument("log_file", help="Path to dynamic 5QI log file")
    ap.add_argument(
        "--mode",
        choices=("all", "dispatch", "success", "fail"),
        default="all",
        help="Filter status: all | dispatch | success | fail (default: all)",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output relative seconds from first matched row time",
    )
    args = ap.parse_args()

    rows = parse_log(args.log_file)
    if not rows:
        print("No async dispatch/success/fail lines found.", file=sys.stderr)
        return 1

    if args.relative_time:
        base = parse_wall_time(rows[0].wall)
        print("rel_time_s,transition,5qi,status")
    else:
        print("time,transition,5qi,status")

    for r in rows:
        status_en = {"전송": "dispatch", "성공": "success", "실패": "fail"}.get(
            r.status, r.status
        )
        if args.mode != "all" and status_en != args.mode:
            continue
        if args.relative_time:
            rel = (parse_wall_time(r.wall) - base).total_seconds()
            print(f"{rel:.6f},{r.transition},{r.five_qi},{status_en}")
        else:
            print(f"{r.wall},{r.transition},{r.five_qi},{status_en}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
