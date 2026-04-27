#!/usr/bin/env python3
"""
Extract HOL delay and PDB values from [DELAY-WEIGHT] scheduler logs.

Example:
  python3 scripts/extract_hol_pdb.py /tmp/gnb.log --ue 0 --lcid 4 --relative-time > hol_pdb.csv
  python3 scripts/extract_hol_pdb.py /tmp/gnb.log --start-time 08:01:31.109559 --relative-time --only-hol-pdb
  python3 scripts/extract_hol_pdb.py /tmp/gnb.log --relative-time --relative-base-time 08:01:31.109559
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional


DELAY_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[DELAY-WEIGHT\]\s+UE(?P<ue>\d+)\s+LCID(?P<lcid>\d+).*?"
    r"hol_delay_ms=(?P<hol>[\d.]+)\s+PDB=(?P<pdb>\d+)ms\s+"
    r"delay_contrib=(?P<contrib>[\d.]+)\s+delay_weight=(?P<weight>[\d.]+)"
)


@dataclass
class DelayRow:
    ts: datetime
    ue: int
    lcid: int
    hol_delay_ms: float
    pdb_ms: int
    delay_contrib: float
    delay_weight: float


def parse_time_arg(value: str, date_fallback: Optional[datetime]) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only value requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_rows(
    log_file: str,
    ue_filter: Optional[int],
    lcid_filter: Optional[int],
    start_time: Optional[str],
) -> List[DelayRow]:
    rows: List[DelayRow] = []
    first_ts: Optional[datetime] = None
    start_dt: Optional[datetime] = None

    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = DELAY_RE.search(line)
            if not m:
                continue

            ts = datetime.fromisoformat(m.group("ts"))
            ue = int(m.group("ue"))
            lcid = int(m.group("lcid"))
            hol = float(m.group("hol"))
            pdb = int(m.group("pdb"))
            contrib = float(m.group("contrib"))
            weight = float(m.group("weight"))

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = parse_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue
            if ue_filter is not None and ue != ue_filter:
                continue
            if lcid_filter is not None and lcid != lcid_filter:
                continue

            rows.append(
                DelayRow(
                    ts=ts,
                    ue=ue,
                    lcid=lcid,
                    hol_delay_ms=hol,
                    pdb_ms=pdb,
                    delay_contrib=contrib,
                    delay_weight=weight,
                )
            )

    rows.sort(key=lambda r: r.ts)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract HOL delay/PDB from [DELAY-WEIGHT] logs.")
    ap.add_argument("log_file", help="Path to gnb.log")
    ap.add_argument("--ue", type=int, default=None, help="Filter UE index (e.g. 0)")
    ap.add_argument("--lcid", type=int, default=None, help="Filter LCID (e.g. 4)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include rows at/after this time. HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output x-axis as relative seconds.",
    )
    ap.add_argument(
        "--relative-base-time",
        type=str,
        default=None,
        help="Base time for --relative-time. HH:MM:SS.ffffff or ISO. Default: --start-time if set, else first row.",
    )
    ap.add_argument(
        "--only-hol-pdb",
        action="store_true",
        help="Output only time + hol_delay_ms + pdb_ms columns",
    )
    ap.add_argument("--no-header", action="store_true", help="Print only rows without header")
    args = ap.parse_args()

    rows = parse_rows(args.log_file, args.ue, args.lcid, args.start_time)
    if not rows:
        print("No [DELAY-WEIGHT] rows matched the given filters.", file=sys.stderr)
        return 1

    if args.relative_base_time is not None:
        base_ts = parse_time_arg(args.relative_base_time, rows[0].ts)
    elif args.start_time is not None:
        base_ts = parse_time_arg(args.start_time, rows[0].ts)
    else:
        base_ts = rows[0].ts

    if not args.no_header:
        if args.relative_time:
            if args.only_hol_pdb:
                print("rel_time_s,hol_delay_ms,pdb_ms")
            else:
                print("rel_time_s,hol_delay_ms,pdb_ms,delay_contrib,delay_weight,ue,lcid")
        else:
            if args.only_hol_pdb:
                print("timestamp,hol_delay_ms,pdb_ms")
            else:
                print("timestamp,hol_delay_ms,pdb_ms,delay_contrib,delay_weight,ue,lcid")

    for r in rows:
        if args.relative_time:
            rel = (r.ts - base_ts).total_seconds()
            if args.only_hol_pdb:
                print(f"{rel:.6f},{r.hol_delay_ms:.3f},{r.pdb_ms}")
            else:
                print(
                    f"{rel:.6f},{r.hol_delay_ms:.3f},{r.pdb_ms},{r.delay_contrib:.3f},{r.delay_weight:.3f},{r.ue},{r.lcid}"
                )
        else:
            if args.only_hol_pdb:
                print(f"{r.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{r.hol_delay_ms:.3f},{r.pdb_ms}")
            else:
                print(
                    f"{r.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{r.hol_delay_ms:.3f},{r.pdb_ms},"
                    f"{r.delay_contrib:.3f},{r.delay_weight:.3f},{r.ue},{r.lcid}"
                )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

