#!/usr/bin/env python3
"""
Extract UE throughput from gNB logs with optional time re-binning.

Default behavior:
  - Parse "UEX Throughput calc" lines
  - Filter UE0
  - Output timestamp + DL Mbps at 10ms bins

Also supports:
  - --bin-ms 50 / 100 / any positive integer
  - UL / TOTAL direction
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import List


THROUGHPUT_RE = re.compile(
    r"^(?:\d+:)?\s*(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?"
    r"UE(?P<ue>\d+)\s+Throughput calc:\s+"
    r"sum_dl_tb_bytes=(?P<dl_bytes>\d+),\s+period=(?P<period_ms>\d+)ms,\s+"
    r"dl_brate_kbps=(?P<dl_kbps>[\d.]+)\s+\(=(?P<dl_mbps>[\d.]+)Mbps\),\s+dl_nof_ok=(?P<dl_ok>\d+),\s+"
    r"ul_brate_kbps=(?P<ul_kbps>[\d.]+)\s+\(=(?P<ul_mbps>[\d.]+)Mbps\),\s+ul_nof_ok=(?P<ul_ok>\d+)"
)


@dataclass
class Entry:
    ts: datetime
    ue: int
    period_ms: int
    dl_bytes: int
    ul_kbps: float


@dataclass
class Bin:
    start: datetime
    dl_bytes: int = 0
    ul_bits: float = 0.0
    total_period_ms: int = 0


def _parse_start_time_arg(value: str, date_fallback: datetime | None) -> datetime:
    """
    Parse --start-time.
    Accepts either:
      - Full ISO time: 2026-04-26T09:16:29.553284
      - Time only:     09:16:29.553284 (date is inferred from first matched log line)
    """
    if "T" in value:
        return datetime.fromisoformat(value)
    if date_fallback is None:
        raise ValueError("time-only --start-time requires at least one matched log line to infer date")
    t = datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.combine(date_fallback.date(), t)


def parse_entries(log_path: str, ue_filter: int, start_time: str | None = None) -> List[Entry]:
    entries: List[Entry] = []
    first_ts: datetime | None = None
    start_dt: datetime | None = None
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = THROUGHPUT_RE.search(line)
            if not m:
                continue
            ue = int(m.group("ue"))
            if ue != ue_filter:
                continue
            ts = datetime.fromisoformat(m.group("ts"))
            period_ms = int(m.group("period_ms"))
            dl_bytes = int(m.group("dl_bytes"))
            ul_kbps = float(m.group("ul_kbps"))
            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time_arg(start_time, first_ts)
            if start_dt is not None and ts < start_dt:
                continue
            entries.append(Entry(ts=ts, ue=ue, period_ms=period_ms, dl_bytes=dl_bytes, ul_kbps=ul_kbps))
    entries.sort(key=lambda e: e.ts)
    return entries


def bin_entries(entries: List[Entry], bin_ms: int) -> List[Bin]:
    if not entries:
        return []

    base = entries[0].ts
    bins = {}
    for e in entries:
        delta_ms = (e.ts - base).total_seconds() * 1000.0
        idx = int(delta_ms // bin_ms)
        if idx not in bins:
            bins[idx] = Bin(start=base + timedelta(milliseconds=idx * bin_ms))
        bins[idx].dl_bytes += e.dl_bytes
        # ul_kbps is kilobits/sec and period_ms is milliseconds.
        # bits = kbps * period_ms (1000/1000 cancels out).
        bins[idx].ul_bits += e.ul_kbps * e.period_ms
        bins[idx].total_period_ms += e.period_ms

    return [bins[i] for i in sorted(bins.keys())]


def compute_mbps(b: Bin, direction: str) -> float:
    dl_bits = b.dl_bytes * 8.0
    ul_bits = b.ul_bits
    if direction == "dl":
        bits = dl_bits
    elif direction == "ul":
        bits = ul_bits
    else:
        bits = dl_bits + ul_bits
    if b.total_period_ms <= 0:
        return 0.0
    # Mbps = bits / (ms * 1000)
    return bits / (b.total_period_ms * 1000.0)


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract UE throughput with configurable bin size.")
    ap.add_argument("log_file", help="Path to gnb.log")
    ap.add_argument("--ue", type=int, default=0, help="UE index to extract (default: 0)")
    ap.add_argument("--bin-ms", type=int, default=10, help="Output bin in ms (default: 10)")
    ap.add_argument(
        "--start-time",
        type=str,
        default=None,
        help="Only include entries at/after this time. Format: HH:MM:SS.ffffff or YYYY-MM-DDTHH:MM:SS.ffffff",
    )
    ap.add_argument(
        "--direction",
        choices=["dl", "ul", "total"],
        default="dl",
        help="Throughput direction (default: dl)",
    )
    ap.add_argument(
        "--no-header",
        action="store_true",
        help="Print only rows without header",
    )
    ap.add_argument(
        "--relative-time",
        action="store_true",
        help="Output x-axis as relative seconds from first output row (starts at 0.0)",
    )
    ap.add_argument(
        "--plot",
        action="store_true",
        help="Generate throughput plot image (PNG)",
    )
    ap.add_argument(
        "--plot-file",
        type=str,
        default="throughput_plot.png",
        help="Output plot filename when --plot is set (default: throughput_plot.png)",
    )
    args = ap.parse_args()

    if args.bin_ms <= 0:
        print("ERROR: --bin-ms must be > 0", file=sys.stderr)
        return 2

    entries = parse_entries(args.log_file, args.ue, args.start_time)
    if not entries:
        print(f"No throughput entries found for UE{args.ue} in {args.log_file}", file=sys.stderr)
        return 1

    bins = bin_entries(entries, args.bin_ms)
    first_out_ts = bins[0].start if bins else None
    x_vals: List[float] = []
    y_vals: List[float] = []
    if not args.no_header:
        if args.relative_time:
            print("rel_time_s,throughput_mbps")
        else:
            print("timestamp,throughput_mbps")
    for b in bins:
        mbps = compute_mbps(b, args.direction)
        if args.relative_time:
            rel_s = (b.start - first_out_ts).total_seconds() if first_out_ts is not None else 0.0
            x_vals.append(rel_s)
            y_vals.append(mbps)
            print(f"{rel_s:.6f},{mbps:.2f}")
        else:
            if first_out_ts is not None:
                rel_s = (b.start - first_out_ts).total_seconds()
                x_vals.append(rel_s)
                y_vals.append(mbps)
            print(f"{b.start.strftime('%Y-%m-%dT%H:%M:%S.%f')},{mbps:.2f}")

    if args.plot:
        try:
            import matplotlib.pyplot as plt
        except Exception as e:
            print(f"ERROR: matplotlib import failed: {e}", file=sys.stderr)
            return 3

        plt.figure(figsize=(12, 4))
        plt.plot(x_vals, y_vals, linewidth=1.2)
        plt.xlabel("Time (s)")
        plt.ylabel("Throughput (Mbps)")
        plt.title(f"UE{args.ue} {args.direction.upper()} Throughput ({args.bin_ms}ms bin)")
        plt.grid(True, alpha=0.3)
        plt.tight_layout()
        plt.savefig(args.plot_file, dpi=150)
        print(f"# plot saved: {args.plot_file}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
