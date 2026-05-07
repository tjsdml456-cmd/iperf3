#!/usr/bin/env python3
"""
Extract UL throughput (Mbps) from [UL-TPUT-1MS] scheduler logs.

Features:
  - Parse "[UL-TPUT-1MS] UEX ... ul_brate_mbps=Y" lines
  - Filter by UE index
  - Optional --start-time filtering (full ISO or time-only)
  - Optional --relative-time output (seconds from base time)
  - Optional binning via --bin-ms (average Mbps per bin)
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List


TPUT_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[UL-TPUT-1MS\]\s+UE(?P<ue>\d+)\s+"
    r".*?ul_brate_mbps=(?P<mbps>[-+]?\d+(?:\.\d+)?)"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    mbps: float


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
            m = TPUT_RE.search(line)
            if not m:
                continue

            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            mbps = float(m.group("mbps"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = parse_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            entries.append(Entry(ts=ts, ue=ue, mbps=mbps))

    entries.sort(key=lambda e: e.ts)
    return entries


def aggregate_by_bin(entries: List[Entry], base: datetime, bin_ms: int) -> List[Entry]:
    if bin_ms <= 1:
        return entries

    buckets: Dict[int, List[float]] = {}
    for e in entries:
        rel_ms = int((e.ts - base).total_seconds() * 1000.0)
        if rel_ms < 0:
            continue
        idx = rel_ms // bin_ms
        buckets.setdefault(idx, []).append(e.mbps)

    out: List[Entry] = []
    for idx in sorted(buckets.keys()):
        values = buckets[idx]
        avg_mbps = sum(values) / len(values)
        ts_bin = base + timedelta(milliseconds=idx * bin_ms)
        out.append(Entry(ts=ts_bin, ue=entries[0].ue, mbps=avg_mbps))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract UL throughput (Mbps) from UL-TPUT-1MS logs.")
    ap.add_argument("log_file", help="Path to scheduler log file")
    ap.add_argument("--ue", type=int, default=0, help="UE index to extract (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time. Format: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument("--bin-ms", type=int, default=1, help="Bin size in milliseconds for averaging (default: 1)")
    ap.add_argument("--relative-time", action="store_true", help="Output relative seconds")
    ap.add_argument("--no-header", action="store_true", help="Print only rows without header")
    args = ap.parse_args()

    if args.bin_ms <= 0:
        print("ERROR: --bin-ms must be > 0", file=sys.stderr)
        return 2

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if not entries:
        print(f"No UL-TPUT-1MS entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = parse_time_arg(args.start_time, entries[0].ts)
    else:
        base = entries[0].ts

    entries = aggregate_by_bin(entries, base, args.bin_ms)

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,ul_brate_mbps")
        else:
            print("timestamp,ul_brate_mbps")

    for e in entries:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.mbps:.2f}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.mbps:.2f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
