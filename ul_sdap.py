#!/usr/bin/env python3
"""
Extract DSCP values and timestamps from SDAP [STEP1-SDAP] logs.

Example:
  2026-07-08T02:47:22.906140 [SDAP   ] [I] ue=0 ... DRB1 UL: [STEP1-SDAP] DSCP 추출 성공 ... DSCP=15 (0x0f) pdu_len=1228

Usage:
  python scripts/extract_sdap_dscp.py gnb.log --ue 0
  python scripts/extract_sdap_dscp.py gnb.log --start-time 11:47:22.906730 --relative-time
  python scripts/extract_sdap_dscp.py gnb.log --direction UL --changes-only
  grep STEP1-SDAP gnb.log | python scripts/extract_sdap_dscp.py - --all
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Iterable, List, TextIO


SDAP_DSCP_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[SDAP\s*\].*?"
    r"ue=(?P<ue>\d+)\s+.*?"
    r"DRB\d+\s+(?P<dir>DL|UL):\s+\[STEP1-SDAP\]\s+DSCP 추출 성공.*?"
    r"DSCP=(?P<dscp>\d+)\s+\(0x[0-9a-fA-F]+\)\s+"
    r"pdu_len=(?P<pdu_len>\d+)"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    direction: str
    dscp: int
    pdu_len: int


def parse_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only argument requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_lines(
    lines: Iterable[str],
    ue_filter: int,
    direction: str | None,
    start_time: str | None = None,
) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    for line in lines:
        m = SDAP_DSCP_RE.search(line)
        if not m:
            continue

        ue = int(m.group("ue"))
        if ue != ue_filter:
            continue

        dir_ = m.group("dir")
        if direction is not None and dir_ != direction:
            continue

        ts = datetime.fromisoformat(m.group("ts"))
        dscp = int(m.group("dscp"))
        pdu_len = int(m.group("pdu_len"))

        if first_ts is None:
            first_ts = ts
        if start_time is not None and start_dt is None:
            start_dt = parse_time_arg(start_time, first_ts)
        if start_dt is not None and ts < start_dt:
            continue

        entries.append(Entry(ts=ts, ue=ue, direction=dir_, dscp=dscp, pdu_len=pdu_len))

    entries.sort(key=lambda e: (e.ts, e.direction))
    return entries


def parse_entries(log_path: str, ue_filter: int, direction: str | None, start_time: str | None = None) -> List[Entry]:
    with open(log_path, encoding="utf-8", errors="replace") as f:
        return parse_lines(f, ue_filter, direction, start_time)


def extract_changes(entries: List[Entry], per_direction: bool) -> List[Entry]:
    if not entries:
        return []

    out: List[Entry] = []
    last: dict[str, int] = {}

    for e in entries:
        key = e.direction if per_direction else "*"
        prev = last.get(key)
        if prev is None or prev != e.dscp:
            out.append(e)
            last[key] = e.dscp
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract DSCP and time from SDAP STEP1-SDAP logs.")
    ap.add_argument("log_file", help="Log file path, or '-' for stdin")
    ap.add_argument("--ue", type=int, default=0, help="UE index (default: 0)")
    ap.add_argument(
        "--direction",
        choices=("DL", "UL"),
        default=None,
        help="Filter DL or UL only (default: both)",
    )
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time (HH:MM:SS.ffffff or full ISO)",
    )
    ap.add_argument("--relative-time", action="store_true", help="Output seconds from base time.")
    ap.add_argument(
        "--changes-only",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Emit only when DSCP changes (default: true)",
    )
    ap.add_argument(
        "--per-direction",
        action="store_true",
        help="Track DSCP changes separately for DL and UL (default: combined)",
    )
    ap.add_argument("--all", action="store_true", help="Alias for --no-changes-only")
    ap.add_argument("--no-header", action="store_true", help="Print only rows without header")
    ap.add_argument("--min-pdu-len", type=int, default=0, help="Ignore pdu_len below this")
    args = ap.parse_args()

    if args.log_file == "-":
        entries = parse_lines(sys.stdin, args.ue, args.direction, args.start_time)
    else:
        entries = parse_entries(args.log_file, args.ue, args.direction, args.start_time)

    if args.min_pdu_len > 0:
        entries = [e for e in entries if e.pdu_len >= args.min_pdu_len]

    if not entries:
        print(f"No SDAP DSCP entries for UE{args.ue}", file=sys.stderr)
        return 1

    changes_only = args.changes_only and not args.all
    rows = extract_changes(entries, args.per_direction) if changes_only else entries
    if not rows:
        print(f"No DSCP changes for UE{args.ue}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = parse_time_arg(args.start_time, rows[0].ts)
    else:
        base = rows[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,direction,dscp,pdu_len")
        else:
            print("timestamp,direction,dscp,pdu_len")

    for e in rows:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.direction},{e.dscp},{e.pdu_len}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.direction},{e.dscp},{e.pdu_len}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
