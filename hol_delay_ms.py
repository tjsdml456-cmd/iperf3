#!/usr/bin/env python3
"""
Extract [DELAY-WEIGHT] rows from gNB scheduler logs.

Example line:
  2026-05-18T07:40:41.550290 [SCHED] [I] [168.4] [DELAY-WEIGHT] UE0 LCID4
    hol_toa=227 slot_tx=1684 hol_delay_ms=1457 PDB=30ms delay_contrib=48.567 delay_weight=48.567

Default output (CSV, no header):
  timestamp,hol_delay_ms,pdb_ms
  ...

With --relative-time, first column is seconds from first emitted row (wall clock).
With --start-time, only rows at/after that timestamp are included.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional


LINE_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[DELAY-WEIGHT\]\s+"
    r"UE(?P<ue>\d+)\s+"
    r"LCID\d+\s+"
    r"hol_toa=\d+\s+slot_tx=\d+\s+"
    r"hol_delay_ms=(?P<hol_ms>[\d.]+)\s+"
    r"PDB=(?P<pdb>\d+)ms",
    re.IGNORECASE,
)


@dataclass
class Row:
    ts: datetime
    ue: int
    hol_delay_ms: float
    pdb_ms: int


def _clip_frac6(s: str) -> str:
    if "." not in s:
        return s
    base, frac = s.split(".", 1)
    digits = "".join(c for c in frac if c.isdigit())
    digits = (digits + "000000")[:6]
    return f"{base}.{digits}"


def parse_wall(value: str, date_fallback: Optional[datetime]) -> datetime:
    v = _clip_frac6(value)
    if "T" in v:
        return datetime.fromisoformat(v)
    if date_fallback is None:
        raise ValueError("time-only --start-time requires at least one matched log line")
    t = datetime.strptime(v, "%H:%M:%S.%f").time() if "." in v else datetime.strptime(v, "%H:%M:%S").time()
    return datetime.combine(date_fallback.date(), t)


def parse_log(path: str, ue_filter: int) -> List[Row]:
    rows: List[Row] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            m = LINE_RE.search(raw)
            if not m:
                continue
            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue
            ts = datetime.fromisoformat(m.group("ts"))
            rows.append(
                Row(
                    ts=ts,
                    ue=ue,
                    hol_delay_ms=float(m.group("hol_ms")),
                    pdb_ms=int(m.group("pdb")),
                )
            )
    rows.sort(key=lambda r: r.ts)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract hol_delay_ms and PDB from [DELAY-WEIGHT] log lines."
    )
    ap.add_argument("log_file", help="Path to gnb.log")
    ap.add_argument("--ue", type=int, default=0, help="UE index (default: 0)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only rows at/after this time (HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff)",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="First column: relative seconds from first emitted row",
    )
    ap.add_argument("--header", action="store_true", help="Print CSV header")
    args = ap.parse_args()

    rows = parse_log(args.log_file, args.ue)
    if not rows:
        print(f"No [DELAY-WEIGHT] lines found for UE{args.ue}.", file=sys.stderr)
        return 1

    if args.start_time is not None:
        start_dt = parse_wall(args.start_time, rows[0].ts)
        rows = [r for r in rows if r.ts >= start_dt]
        if not rows:
            print("No rows after --start-time filter.", file=sys.stderr)
            return 1

    if args.header:
        if args.relative_time:
            print("rel_time_s,pdb_ms,hol_delay_ms")
        else:
            print("timestamp,pdb_ms,hol_delay_ms")

    base_ts = rows[0].ts
    for r in rows:
        if args.relative_time:
            rel = (r.ts - base_ts).total_seconds()
            print(f"{rel:.6f},{r.pdb_ms},{r.hol_delay_ms:.3f}")
        else:
            print(
                f"{r.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{r.pdb_ms},{r.hol_delay_ms:.3f}"
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
