#!/usr/bin/env python3
"""
Extract CU-UP QoS modification events from gNB/CU logs.

Target pattern (example):
  [QoS-MODIFY] [CP-5QI] DRB modification received from control-plane ... drb_mod_count=1
  [QoS-MODIFY] [CP-5QI] Requested flow from control-plane ... five_qi=5QI=0x54

Output:
  - timestamp from "DRB modification received ..." line
  - five_qi from the following "Requested flow ..." line

Supports:
  - --ue
  - --start-time (ISO or time-only)
  - --relative-time
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


RE_RECEIVED = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"ue=(?P<ue>\d+).*?"
    r"\[QoS-MODIFY\]\s+\[CP-5QI\]\s+DRB modification received from control-plane\..*?"
    r"drb_mod_count=(?P<mod>\d+)\b"
)

RE_REQUESTED = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"ue=(?P<ue>\d+).*?"
    r"\[QoS-MODIFY\]\s+\[CP-5QI\]\s+Requested flow from control-plane\..*?"
    r"five_qi=5QI=(?P<fiveqi>0x[0-9a-fA-F]+|\d+)\b"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    five_qi_raw: str
    five_qi_dec: int


def _parse_start_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only --start-time requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def _parse_five_qi(raw: str) -> int:
    return int(raw, 16) if raw.lower().startswith("0x") else int(raw)


def parse_entries(log_path: str, ue_filter: int, start_time: str | None = None) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    # Timestamp from received line waiting for matching requested-flow line.
    pending_received_ts: datetime | None = None

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m_recv = RE_RECEIVED.search(line)
            if m_recv:
                ue = int(m_recv.group("ue"))
                if ue != ue_filter:
                    continue
                if int(m_recv.group("mod")) != 1:
                    # Ignore empty modifications (drb_mod_count=0).
                    pending_received_ts = None
                    continue

                ts = datetime.fromisoformat(m_recv.group("ts"))
                if first_ts is None:
                    first_ts = ts
                if start_time is not None and start_dt is None:
                    start_dt = _parse_start_time_arg(start_time, first_ts)
                if start_dt is not None and ts < start_dt:
                    pending_received_ts = None
                    continue

                pending_received_ts = ts
                continue

            m_req = RE_REQUESTED.search(line)
            if not m_req:
                continue

            ue = int(m_req.group("ue"))
            if ue != ue_filter or pending_received_ts is None:
                continue

            raw = m_req.group("fiveqi")
            entries.append(
                Entry(
                    ts=pending_received_ts,
                    ue=ue,
                    five_qi_raw=raw,
                    five_qi_dec=_parse_five_qi(raw),
                )
            )
            pending_received_ts = None

    entries.sort(key=lambda e: e.ts)
    return entries


def dedup_consecutive(entries: List[Entry], mode: str = "first") -> List[Entry]:
    if not entries:
        return entries
    if mode == "first":
        out: List[Entry] = [entries[0]]
        prev = entries[0].five_qi_dec
        for e in entries[1:]:
            if e.five_qi_dec == prev:
                continue
            out.append(e)
            prev = e.five_qi_dec
        return out

    if mode == "last":
        out: List[Entry] = []
        current = entries[0]
        for e in entries[1:]:
            if e.five_qi_dec == current.five_qi_dec:
                current = e
                continue
            out.append(current)
            current = e
        out.append(current)
        return out

    raise ValueError(f"Unsupported dedup mode: {mode}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract CU-UP QoS modify receive time + requested 5QI.")
    ap.add_argument("log_file", help="Path to CU log (e.g. gnb.log)")
    ap.add_argument("--ue", type=int, default=0, help="UE index to extract (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include events at/after this time. Format: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output x-axis as relative seconds from base time (0.0 at --start-time if set, else first row).",
    )
    ap.add_argument(
        "--dedup-consecutive",
        action="store_true",
        help="Drop consecutive rows with the same five_qi value.",
    )
    ap.add_argument(
        "--dedup-mode",
        choices=["first", "last"],
        default="first",
        help="When --dedup-consecutive is set: keep first or last row of each same-5QI run (default: first).",
    )
    ap.add_argument("--no-header", action="store_true", help="Print only rows without header")
    args = ap.parse_args()

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if args.dedup_consecutive:
        entries = dedup_consecutive(entries, args.dedup_mode)
    if not entries:
        print(f"No CU-UP QoS entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = _parse_start_time_arg(args.start_time, entries[0].ts)
    else:
        base = entries[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,five_qi_raw,five_qi_dec")
        else:
            print("timestamp,five_qi_raw,five_qi_dec")

    for e in entries:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.five_qi_raw},{e.five_qi_dec}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.five_qi_raw},{e.five_qi_dec}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

