#!/usr/bin/env python3
"""
Extract scheduler HOL delay from gNB logs ([DELAY-WEIGHT] only).

  grep "DELAY-WEIGHT" gnb.log | grep "UE0" > hol_delay.log
  python3 hol_delay.py hol_delay.log --relative-time
  python3 hol_delay.py hol_delay.log --header --relative-time --start-time 16:31:39.575
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime, time
from typing import List, Optional, Set


DELAY_WEIGHT_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"\[DELAY-WEIGHT\]\s+"
    r"UE(?P<ue>\d+)\s+"
    r"LCID\d+\s+"
    r"hol_toa=\d+\s+"
    r"slot_tx=\d+\s+"
    r"hol_delay_ms=(?P<hol_delay_ms>[\d.]+)",
    re.IGNORECASE,
)

UE_FLAG_NAMES = ("ue0", "ue1", "ue2", "ue3")


@dataclass
class Row:
    ts: datetime
    ue: int
    hol_delay_ms: float


def _clip_frac6(s: str) -> str:
    if "." not in s:
        return s
    base, frac = s.split(".", 1)
    digits = "".join(c for c in frac if c.isdigit())
    digits = (digits + "000000")[:6]
    return f"{base}.{digits}"


def _is_time_only(value: str) -> bool:
    v = value.strip()
    return "T" not in v and len(v) <= 15 and v.count(":") >= 2


def parse_start_time(value: str, date_fallback: datetime) -> tuple[datetime, Optional[time]]:
    v = _clip_frac6(value.strip())
    if "T" in v:
        return datetime.fromisoformat(v), None
    t = datetime.strptime(v, "%H:%M:%S.%f").time() if "." in v else datetime.strptime(v, "%H:%M:%S").time()
    return datetime.combine(date_fallback.date(), t), t


def row_passes_start(
    r: Row, start_abs: datetime, start_tod: Optional[time], match_time_of_day: bool
) -> bool:
    if match_time_of_day and start_tod is not None:
        return r.ts.time() >= start_tod
    return r.ts >= start_abs


def resolve_ue_set(args: argparse.Namespace) -> Set[int]:
    selected: Set[int] = set()
    for name in UE_FLAG_NAMES:
        if getattr(args, name, False):
            selected.add(int(name[2:]))
    if selected:
        return selected
    if args.ue is not None:
        return {args.ue}
    return {0}


def parse_log(path: str, ue_filter: Set[int]) -> List[Row]:
    rows: List[Row] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            m = DELAY_WEIGHT_RE.search(raw)
            if not m:
                continue
            ue = int(m.group("ue"))
            if ue not in ue_filter:
                continue
            rows.append(
                Row(
                    ts=datetime.fromisoformat(m.group("ts")),
                    ue=ue,
                    hol_delay_ms=float(m.group("hol_delay_ms")),
                )
            )
    rows.sort(key=lambda r: r.ts)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract time + hol_delay_ms from [DELAY-WEIGHT] scheduler logs."
    )
    ap.add_argument("log_file", help="gnb.log or: grep DELAY-WEIGHT gnb.log | grep UE0")
    ap.add_argument("--ue", type=int, default=None, help="UE index filter (default UE0)")
    for name in UE_FLAG_NAMES:
        ap.add_argument(f"--{name}", action="store_true", help=f"Include UE{int(name[2:])}")
    ap.add_argument("--start-time", type=str, default=None)
    ap.add_argument("--match-time-of-day", action="store_true")
    ap.add_argument("--relative-time", action="store_true")
    ap.add_argument("--header", action="store_true")
    args = ap.parse_args()

    ue_set = resolve_ue_set(args)
    rows = parse_log(args.log_file, ue_set)
    if not rows:
        ue_list = ",".join(f"UE{u}" for u in sorted(ue_set))
        print(f"No [DELAY-WEIGHT] lines found for {ue_list}.", file=sys.stderr)
        print('  grep "DELAY-WEIGHT" gnb.log | grep "UE0" > hol_delay.log', file=sys.stderr)
        return 1

    if args.start_time is not None:
        start_abs, start_tod = parse_start_time(args.start_time, rows[0].ts)
        match_tod = args.match_time_of_day or (
            _is_time_only(args.start_time) and start_tod is not None and start_abs > rows[-1].ts
        )
        filtered = [r for r in rows if row_passes_start(r, start_abs, start_tod, match_tod)]
        if not filtered:
            print("No rows after --start-time filter.", file=sys.stderr)
            return 1
        rows = filtered

    if args.header:
        ts_col = "rel_time_s" if args.relative_time else "timestamp"
        print(f"{ts_col},hol_delay_ms")

    base_ts = rows[0].ts
    for r in rows:
        if args.relative_time:
            ts_field = f"{(r.ts - base_ts).total_seconds():.6f}"
        else:
            ts_field = r.ts.strftime("%Y-%m-%dT%H:%M:%S.%f")
        print(f"{ts_field},{r.hol_delay_ms:.3f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
