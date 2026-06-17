#!/usr/bin/env python3
"""
Parse UE{n} [MAC-THP-DL] — token-bucket-shaped MAC SDU payload (allocate_mac_sdu sdu_size).

  grep "MAC-THP-DL" gnb.log > mac_thp_dl.log
  python3 extract_mac_thp_dl.py mac_thp_dl.log --bin-ms 500 --relative-time --start-time ...
  python3 extract_mac_thp_dl.py mac_thp_dl.log --ue0 --ue1 --ue2 --bin-ms 500 --relative-time
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Set

MAC_THP_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"UE(?P<ue>\d+)\s+\[MAC-THP-DL\]\s+"
    r"window_ms=(?P<window_ms>[0-9.]+)\s+"
    r"vol_bytes=(?P<vol_bytes>\d+)\s+"
    r"thp_kbps=(?P<thp_kbps>[0-9.]+)",
    re.IGNORECASE,
)

UE_FLAG_NAMES = ("ue0", "ue1", "ue2", "ue3")


@dataclass
class Sample:
    ts: datetime
    ue: int
    window_ms: float
    vol_bytes: int


def _parse_start_time(value: str, date_fallback: datetime) -> datetime:
    if "T" in value:
        return datetime.fromisoformat(value)
    t = (
        datetime.strptime(value, "%H:%M:%S.%f").time()
        if "." in value
        else datetime.strptime(value, "%H:%M:%S").time()
    )
    return datetime.combine(date_fallback.date(), t)


def resolve_ue_set(args: argparse.Namespace) -> Set[int]:
    selected: Set[int] = set()
    for name in UE_FLAG_NAMES:
        if getattr(args, name, False):
            selected.add(int(name[2:]))
    if selected:
        return selected
    return {args.ue}


def parse_samples(log_path: str, ue_filter: Set[int], start_time: Optional[str]) -> Dict[int, List[Sample]]:
    by_ue: Dict[int, List[Sample]] = {ue: [] for ue in ue_filter}
    first_ts: Optional[datetime] = None
    start_dt: Optional[datetime] = None

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = MAC_THP_RE.search(line)
            if not m:
                continue
            ue = int(m.group("ue"))
            if ue not in ue_filter:
                continue
            ts = datetime.fromisoformat(m.group("ts"))
            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue
            by_ue[ue].append(
                Sample(ts=ts, ue=ue, window_ms=float(m.group("window_ms")), vol_bytes=int(m.group("vol_bytes")))
            )

    for ue in ue_filter:
        by_ue[ue].sort(key=lambda s: s.ts)
    return by_ue


def bin_samples(samples: List[Sample], bin_ms: int, bin_base: datetime) -> List[tuple[int, int]]:
    if not samples:
        return []

    accum: dict[int, int] = {}
    last_idx = 0
    for s in samples:
        t_end = s.ts
        t_start = t_end - timedelta(milliseconds=s.window_ms)
        duration_ms = s.window_ms if s.window_ms > 0 else 10.0
        end_idx = int((t_end - bin_base).total_seconds() * 1000.0 // bin_ms)
        last_idx = max(last_idx, end_idx)
        idx = int(max(0.0, (t_start - bin_base).total_seconds() * 1000.0) // bin_ms)
        while idx <= end_idx:
            b_start = bin_base + timedelta(milliseconds=idx * bin_ms)
            b_end = b_start + timedelta(milliseconds=bin_ms)
            o_start = max(t_start, b_start)
            o_end = min(t_end, b_end)
            if o_end > o_start:
                overlap_ms = (o_end - o_start).total_seconds() * 1000.0
                accum[idx] = accum.get(idx, 0) + int(round(s.vol_bytes * overlap_ms / duration_ms))
            idx += 1

    return [(i, accum.get(i, 0)) for i in range(0, last_idx + 1)]


def _bin_base(start_time: Optional[str], by_ue: Dict[int, List[Sample]]) -> datetime:
    all_samples = [s for samples in by_ue.values() for s in samples]
    if not all_samples:
        raise ValueError("no samples")
    if start_time is not None:
        return _parse_start_time(start_time, all_samples[0].ts)
    return min(s.ts for s in all_samples)


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract [MAC-THP-DL] shaped throughput CSV")
    ap.add_argument("log_file")
    ap.add_argument("--ue", type=int, default=0, help="UE index when no --ueN flag (default: 0)")
    for name in UE_FLAG_NAMES:
        ap.add_argument(f"--{name}", action="store_true", help=f"Include UE{int(name[2:])}")
    ap.add_argument("--bin-ms", type=int, default=None, help="Re-bin (50= DSCP step, 500=0.5s)")
    ap.add_argument("--start-time", type=str, default=None)
    ap.add_argument("--relative-time", action="store_true")
    ap.add_argument("--no-header", action="store_true")
    args = ap.parse_args()

    ue_set = resolve_ue_set(args)
    by_ue = parse_samples(args.log_file, ue_set, args.start_time)

    nonempty = {ue: samples for ue, samples in by_ue.items() if samples}
    if not nonempty:
        ue_list = ",".join(f"UE{u}" for u in sorted(ue_set))
        print(f"No [MAC-THP-DL] lines for {ue_list}", file=sys.stderr)
        return 1

    multi_ue = len(ue_set) > 1
    bin_base = _bin_base(args.start_time, nonempty)

    if not args.no_header:
        if multi_ue:
            cols = "rel_time_s,ue,throughput_mbps" if args.relative_time else "timestamp,ue,throughput_mbps"
        else:
            cols = "rel_time_s,throughput_mbps" if args.relative_time else "timestamp,throughput_mbps"
        print(cols)

    if args.bin_ms is not None:
        if args.bin_ms <= 0:
            print("ERROR: --bin-ms must be > 0", file=sys.stderr)
            return 2

        binned: Dict[int, List[tuple[int, int]]] = {}
        max_bins = 0
        for ue in sorted(ue_set):
            bins = bin_samples(by_ue.get(ue, []), args.bin_ms, bin_base)
            binned[ue] = bins
            max_bins = max(max_bins, len(bins))

        step_s = args.bin_ms / 1000.0
        stats: List[str] = []
        for idx in range(max_bins):
            for ue in sorted(ue_set):
                bins = binned[ue]
                nbytes = bins[idx][1] if idx < len(bins) else 0
                mbps = (nbytes * 8.0) / step_s / 1_000_000.0
                if args.relative_time:
                    rel = idx * step_s
                    if multi_ue:
                        print(f"{rel:.6f},{ue},{mbps:.6f}")
                    else:
                        print(f"{rel:.6f},{mbps:.6f}")
                else:
                    ts = bin_base + timedelta(milliseconds=idx * args.bin_ms)
                    if multi_ue:
                        print(f"{ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{ue},{mbps:.6f}")
                    else:
                        print(f"{ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{mbps:.6f}")

        for ue in sorted(ue_set):
            bins = binned[ue]
            total = sum(n for _, n in bins)
            dur = len(bins) * step_s
            avg = (total * 8.0 / dur / 1_000_000.0) if dur > 0 else 0.0
            stats.append(f"UE{ue}: lines={len(by_ue.get(ue, []))} bins={len(bins)} avg_mbps={avg:.3f}")
        print(f"# bin_ms={args.bin_ms} " + " | ".join(stats), file=sys.stderr)
    else:
        for ue in sorted(ue_set):
            for s in by_ue.get(ue, []):
                mbps = (s.vol_bytes * 8.0) / (s.window_ms / 1000.0) / 1_000_000.0
                if args.relative_time:
                    rel = (s.ts - bin_base).total_seconds()
                    if multi_ue:
                        print(f"{rel:.6f},{ue},{mbps:.6f}")
                    else:
                        print(f"{rel:.6f},{mbps:.6f}")
                else:
                    if multi_ue:
                        print(f"{s.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{ue},{mbps:.6f}")
                    else:
                        print(f"{s.ts.strftime('%Y-%m-%dT%H:%M:%S.%f')},{mbps:.6f}")
        stats = [f"UE{ue}: lines={len(by_ue.get(ue, []))}" for ue in sorted(ue_set)]
        print("# " + " | ".join(stats), file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
