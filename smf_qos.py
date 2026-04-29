#!/usr/bin/env python3
"""
Extract QoS events (timestamp, 5QI, GBR) from Open5GS SMF logs.

Supported lines:
  - [NGAP-BUILD] fill_qos_level_parameters: 5QI=..., include_gbr=..., GBR_DL=..., ...

Features:
  - Extract timestamp + 5QI + GBR_DL + GBR_UL
  - Optional start-time filtering
  - Optional relative-time output
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List


TIME_RE = re.compile(r"(?P<mm>\d{1,2})/(?P<dd>\d{1,2})\s+(?P<hms>\d{2}:\d{2}:\d{2}\.\d{3})")
Q5_RE = re.compile(r"\b5QI=(?P<qos_5qi>\d+)\b")
GBR_DL_RE = re.compile(r"\bGBR_DL=(?P<gbr_dl>\d+)\b")
GBR_UL_RE = re.compile(r"\bGBR_UL=(?P<gbr_ul>\d+)\b")


@dataclass
class Entry:
    ts: datetime
    qos_5qi: int
    gbr_dl: int
    gbr_ul: int


def parse_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    """
    Parse start time.
    Accepts:
      - Full ISO: YYYY-MM-DDTHH:MM:SS.ffffff
      - Time only: HH:MM:SS.ffffff or HH:MM:SS.mmm (date inferred from first matched line)
    """
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only argument requires at least one matched log line to infer date")

    time_formats = ("%H:%M:%S.%f", "%H:%M:%S")
    parsed_time = None
    for fmt in time_formats:
        try:
            parsed_time = datetime.strptime(value, fmt).time()
            break
        except ValueError:
            continue
    if parsed_time is None:
        raise ValueError("time-only argument format must be HH:MM:SS[.ffffff]")

    return datetime.combine(date_fallback.date(), parsed_time)


def parse_entries(log_path: str, year: int, start_time: str | None = None) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            # Some deployments include extra tags/colors; parse fields independently.
            if "[NGAP-BUILD]" not in line:
                continue
            if "fill_qos_level_parameters" not in line:
                continue

            t = TIME_RE.search(line)
            q = Q5_RE.search(line)
            dl = GBR_DL_RE.search(line)
            ul = GBR_UL_RE.search(line)
            if not (t and q and dl and ul):
                continue

            month = int(t.group("mm"))
            day = int(t.group("dd"))
            hms = t.group("hms")
            ts = datetime.strptime(f"{year:04d}-{month:02d}-{day:02d} {hms}", "%Y-%m-%d %H:%M:%S.%f")

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = parse_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue

            entries.append(
                Entry(
                    ts=ts,
                    qos_5qi=int(q.group("qos_5qi")),
                    gbr_dl=int(dl.group("gbr_dl")),
                    gbr_ul=int(ul.group("gbr_ul")),
                )
            )

    entries.sort(key=lambda e: e.ts)
    return entries


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract timestamp/5QI/GBR from SMF fill_qos_level_parameters logs."
    )
    ap.add_argument("log_file", help="Path to log file")
    ap.add_argument(
        "--year",
        type=int,
        default=datetime.now().year,
        help="Year to apply to MM/DD timestamps (default: current year)",
    )
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time. Format: HH:MM:SS[.ffffff] or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output relative seconds. Base is --start-time if provided, otherwise first output row.",
    )
    ap.add_argument(
        "--no-header",
        action="store_true",
        help="Print only rows without header",
    )
    args = ap.parse_args()

    entries = parse_entries(args.log_file, args.year, args.start_time)
    if not entries:
        print(f"No matching fill_qos_level_parameters 5QI/GBR entries found in {args.log_file}", file=sys.stderr)
        return 1

    if args.start_time is not None:
        base = parse_time_arg(args.start_time, entries[0].ts)
    else:
        base = entries[0].ts

    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,5qi,gbr_dl,gbr_ul")
        else:
            print("timestamp,5qi,gbr_dl,gbr_ul")

    for e in entries:
        if args.relative_time:
            rel_s = (e.ts - base).total_seconds()
            print(f"{rel_s:.6f},{e.qos_5qi},{e.gbr_dl},{e.gbr_ul}")
        else:
            print(f"{e.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{e.qos_5qi},{e.gbr_dl},{e.gbr_ul}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
