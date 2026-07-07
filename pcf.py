#!/usr/bin/env python3
"""
Parse PCF [PCF-API-INGRESS] lines and emit 5QI vs time.

  grep "PCF-API-INGRESS" pcf.log > pcf_ingress.log
  python3 extract_pcf_5qi.py pcf.log --bin-ms 500 --relative-time \\
      --start-time 21:27:24.646004 --year 2026

Consecutive identical five_qi values are collapsed to the first occurrence only
(default). Use --no-collapse-consecutive to keep every log line.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import List, Optional, Tuple

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

PCF_INGRESS_RE = re.compile(
    r"(?:(?P<date>\d{2}/\d{2})\s+)?"
    r"(?:(?P<prefix_ts>\d{2}:\d{2}:\d{2}\.\d+):)?"
    r".*?\[PCF-API-INGRESS\]\s+"
    r"(?P<method>POST|PATCH)\s+"
    r"wall\s*=\s*(?P<wall>\d{2}:\d{2}:\d{2}\.\d+)\s+"
    r"afAppId\s*=\s*(?P<af_app_id>5GC-QOS:[^\s]+)",
    re.IGNORECASE,
)

ISO_TS_RE = re.compile(
    r"(?P<iso>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"
)
TIME_OF_DAY_RE = re.compile(r"(?P<t>\d{2}:\d{2}:\d{2}\.\d+)")
AF_APP_ID_LOOSE_RE = re.compile(r"afAppId\s*=\s*(5GC-QOS:[^\s]+)", re.IGNORECASE)
WALL_LOOSE_RE = re.compile(r"wall\s*=\s*(?P<wall>\d{2}:\d{2}:\d{2}\.\d+)", re.IGNORECASE)
METHOD_LOOSE_RE = re.compile(r"\[PCF-API-INGRESS\]\s+(POST|PATCH)", re.IGNORECASE)


@dataclass
class PcfSample:
    ts: datetime
    five_qi: int
    qfi: int
    method: str
    gbr_dl: Optional[int]
    gbr_ul: Optional[int]
    mbr_dl: Optional[int]
    mbr_ul: Optional[int]


@dataclass
class ParseStats:
    lines_read: int = 0
    marker_hits: int = 0
    parsed: int = 0
    after_start_filter: int = 0


def _parse_time_of_day(value: str) -> datetime.time:
    if "." in value:
        return datetime.strptime(value, "%H:%M:%S.%f").time()
    return datetime.strptime(value, "%H:%M:%S").time()


def _parse_start_time(value: str, date_fallback: datetime) -> datetime:
    if "T" in value or re.match(r"\d{4}-\d{2}-\d{2}", value):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    t = _parse_time_of_day(value)
    return datetime.combine(date_fallback.date(), t)


def _combine_ts(date_mmdd: Optional[str], wall: str, year: int, fallback_date: datetime) -> datetime:
    t = _parse_time_of_day(wall)
    if date_mmdd:
        month, day = map(int, date_mmdd.split("/"))
        return datetime(year, month, day, t.hour, t.minute, t.second, t.microsecond)
    return datetime.combine(fallback_date.date(), t)


def _parse_iso_ts(value: str) -> datetime:
    v = value.replace("Z", "+00:00")
    if " " in v and "T" not in v:
        v = v.replace(" ", "T", 1)
    return datetime.fromisoformat(v)


def _resolve_timestamp(
    line: str,
    date_mmdd: Optional[str],
    wall: Optional[str],
    prefix_ts: Optional[str],
    year: int,
    fallback: datetime,
) -> datetime:
    if wall:
        return _combine_ts(date_mmdd, wall, year, fallback)
    iso_m = ISO_TS_RE.search(line)
    if iso_m:
        return _parse_iso_ts(iso_m.group("iso"))
    if prefix_ts:
        return _combine_ts(date_mmdd, prefix_ts, year, fallback)
    tod_m = TIME_OF_DAY_RE.search(line)
    if tod_m:
        return _combine_ts(date_mmdd, tod_m.group("t"), year, fallback)
    raise ValueError(f"no timestamp in line: {line[:120]!r}")


def _parse_af_app_id(af_app_id: str) -> Tuple[int, int, Optional[int], Optional[int], Optional[int], Optional[int]]:
    parts = af_app_id.split(":")
    if len(parts) < 3 or parts[0] != "5GC-QOS":
        raise ValueError(f"bad afAppId: {af_app_id!r}")
    qfi = int(parts[1])
    five_qi = int(parts[2])
    gbr_dl = gbr_ul = mbr_dl = mbr_ul = None
    if len(parts) >= 5:
        gbr_dl = int(parts[3])
        gbr_ul = int(parts[4])
    if len(parts) >= 7:
        mbr_dl = int(parts[5])
        mbr_ul = int(parts[6])
    return five_qi, qfi, gbr_dl, gbr_ul, mbr_dl, mbr_ul


def _parse_line(line: str, year: int, fallback: datetime) -> Optional[PcfSample]:
    raw = ANSI_RE.sub("", line).rstrip("\r\n")
    if "PCF-API-INGRESS" not in raw:
        return None

    m = PCF_INGRESS_RE.search(raw)
    method = "?"
    af_app_id = None
    date_mmdd = None
    wall = None
    prefix_ts = None

    if m:
        method = m.group("method").upper()
        af_app_id = m.group("af_app_id")
        date_mmdd = m.group("date")
        wall = m.group("wall")
        prefix_ts = m.group("prefix_ts")
    else:
        af_m = AF_APP_ID_LOOSE_RE.search(raw)
        if not af_m:
            return None
        af_app_id = af_m.group(1)
        method_m = METHOD_LOOSE_RE.search(raw)
        method = method_m.group(1).upper() if method_m else "?"
        wall_m = WALL_LOOSE_RE.search(raw)
        wall = wall_m.group("wall") if wall_m else None
        date_m = re.search(r"(?P<date>\d{2}/\d{2})", raw)
        date_mmdd = date_m.group("date") if date_m else None
        prefix_m = re.search(r"(?P<prefix>\d{2}:\d{2}:\d{2}\.\d+):", raw)
        prefix_ts = prefix_m.group("prefix") if prefix_m else None

    five_qi, qfi, gbr_dl, gbr_ul, mbr_dl, mbr_ul = _parse_af_app_id(af_app_id)
    ts = _resolve_timestamp(raw, date_mmdd, wall, prefix_ts, year, fallback)
    return PcfSample(
        ts=ts,
        five_qi=five_qi,
        qfi=qfi,
        method=method,
        gbr_dl=gbr_dl,
        gbr_ul=gbr_ul,
        mbr_dl=mbr_dl,
        mbr_ul=mbr_ul,
    )


def parse_samples(
    log_path: str,
    start_time: Optional[str],
    year: Optional[int],
    stats: Optional[ParseStats] = None,
) -> List[PcfSample]:
    samples: List[PcfSample] = []
    first_ts: Optional[datetime] = None
    start_dt: Optional[datetime] = None
    use_year = year or datetime.now().year
    st = stats if stats is not None else ParseStats()

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            st.lines_read += 1
            if "PCF-API-INGRESS" in ANSI_RE.sub("", line):
                st.marker_hits += 1
            try:
                sample = _parse_line(line, use_year, first_ts or datetime.now())
            except ValueError:
                continue
            if sample is None:
                continue

            st.parsed += 1
            if first_ts is None:
                first_ts = sample.ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time(start_time, sample.ts)
            if start_dt is not None and sample.ts < start_dt:
                continue

            st.after_start_filter += 1
            samples.append(sample)

    samples.sort(key=lambda s: s.ts)
    return samples


def collapse_consecutive_five_qi(samples: List[PcfSample]) -> List[PcfSample]:
    """Keep only the first sample when five_qi repeats back-to-back."""
    if not samples:
        return []
    out = [samples[0]]
    for s in samples[1:]:
        if s.five_qi != out[-1].five_qi:
            out.append(s)
    return out


def collapse_consecutive_bins(
    bins: List[tuple[int, PcfSample]],
) -> List[tuple[int, PcfSample]]:
    """Keep only the first bin when five_qi repeats in adjacent bins."""
    if not bins:
        return []
    out = [bins[0]]
    for item in bins[1:]:
        if item[1].five_qi != out[-1][1].five_qi:
            out.append(item)
    return out


def bin_samples_last(samples: List[PcfSample], bin_ms: int, bin_base: datetime) -> List[tuple[int, PcfSample]]:
    if not samples:
        return []

    by_bin: dict[int, PcfSample] = {}
    last_idx = 0
    for s in samples:
        idx = int(max(0.0, (s.ts - bin_base).total_seconds() * 1000.0) // bin_ms)
        by_bin[idx] = s
        last_idx = max(last_idx, idx)

    return [(idx, by_bin[idx]) for idx in range(0, last_idx + 1) if idx in by_bin]


def bin_samples_mode(samples: List[PcfSample], bin_ms: int, bin_base: datetime) -> List[tuple[int, PcfSample]]:
    if not samples:
        return []

    counts: dict[int, Counter[int]] = {}
    last: dict[int, PcfSample] = {}
    last_idx = 0
    for s in samples:
        idx = int(max(0.0, (s.ts - bin_base).total_seconds() * 1000.0) // bin_ms)
        counts.setdefault(idx, Counter())[s.five_qi] += 1
        last[idx] = s
        last_idx = max(last_idx, idx)

    out: List[tuple[int, PcfSample]] = []
    for idx in range(0, last_idx + 1):
        if idx not in counts:
            continue
        five_qi = counts[idx].most_common(1)[0][0]
        s = last[idx]
        out.append(
            (
                idx,
                PcfSample(
                    ts=s.ts,
                    five_qi=five_qi,
                    qfi=s.qfi,
                    method=s.method,
                    gbr_dl=s.gbr_dl if s.five_qi == five_qi else None,
                    gbr_ul=s.gbr_ul if s.five_qi == five_qi else None,
                    mbr_dl=s.mbr_dl if s.five_qi == five_qi else None,
                    mbr_ul=s.mbr_ul if s.five_qi == five_qi else None,
                ),
            )
        )
    return out


def _bin_base(start_time: Optional[str], samples: List[PcfSample]) -> datetime:
    if not samples:
        raise ValueError("no samples")
    if start_time is not None:
        return _parse_start_time(start_time, samples[0].ts)
    return samples[0].ts


def _print_row(
    rel_or_ts: str,
    sample: PcfSample,
    include_gbr: bool,
    include_method: bool,
) -> None:
    cols = [rel_or_ts, str(sample.five_qi)]
    if include_method:
        cols.append(sample.method)
    if include_gbr:
        cols.extend(
            [
                "" if sample.gbr_dl is None else str(sample.gbr_dl),
                "" if sample.mbr_dl is None else str(sample.mbr_dl),
            ]
        )
    print(",".join(cols))


def _print_no_match_help(log_path: str, stats: ParseStats) -> None:
    print("No [PCF-API-INGRESS] output rows.", file=sys.stderr)
    print(
        f"  read={stats.lines_read}  marker={stats.marker_hits}  "
        f"parsed={stats.parsed}  after_start_filter={stats.after_start_filter}",
        file=sys.stderr,
    )
    if stats.marker_hits > 0 and stats.parsed == 0:
        print("  Lines contain PCF-API-INGRESS but parser failed.", file=sys.stderr)
    elif stats.parsed > 0 and stats.after_start_filter == 0:
        print("  Parsed but --start-time filtered all — check --year / --start-time.", file=sys.stderr)
    elif stats.marker_hits == 0:
        print("  No PCF-API-INGRESS in file.", file=sys.stderr)

    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "PCF-API-INGRESS" in line:
                    print(f"  example: {ANSI_RE.sub('', line).rstrip()[:220]}", file=sys.stderr)
                    break
    except OSError:
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract [PCF-API-INGRESS] 5QI vs time CSV")
    ap.add_argument("log_file")
    ap.add_argument("--bin-ms", type=int, default=None, help="Bin width (500 = 0.5s iperf step)")
    ap.add_argument("--bin-mode", choices=("last", "mode"), default="last")
    ap.add_argument("--start-time", type=str, default=None, help="e.g. 21:27:24.646004 or ISO")
    ap.add_argument("--relative-time", action="store_true")
    ap.add_argument("--year", type=int, default=None, help="Year for MM/DD log prefix")
    ap.add_argument("--include-gbr", action="store_true", help="Add gbr_dl,mbr_dl columns")
    ap.add_argument("--include-method", action="store_true", help="Add POST/PATCH column")
    ap.add_argument("--no-header", action="store_true")
    ap.add_argument(
        "--no-collapse-consecutive",
        action="store_true",
        help="Keep every row even when five_qi is unchanged from the previous row",
    )
    args = ap.parse_args()

    stats = ParseStats()
    samples = parse_samples(args.log_file, args.start_time, args.year, stats)
    if not samples:
        _print_no_match_help(args.log_file, stats)
        return 1

    raw_count = len(samples)
    if not args.no_collapse_consecutive:
        samples = collapse_consecutive_five_qi(samples)

    bin_base = _bin_base(args.start_time, samples)

    if not args.no_header:
        cols = ["rel_time_s" if args.relative_time else "timestamp", "five_qi"]
        if args.include_method:
            cols.append("method")
        if args.include_gbr:
            cols.extend(["gbr_dl", "mbr_dl"])
        print(",".join(cols))

    if args.bin_ms is not None:
        if args.bin_ms <= 0:
            print("ERROR: --bin-ms must be > 0", file=sys.stderr)
            return 2
        bins = (
            bin_samples_mode(samples, args.bin_ms, bin_base)
            if args.bin_mode == "mode"
            else bin_samples_last(samples, args.bin_ms, bin_base)
        )
        if not args.no_collapse_consecutive:
            bins = collapse_consecutive_bins(bins)
        step_s = args.bin_ms / 1000.0
        for idx, s in bins:
            if args.relative_time:
                _print_row(f"{idx * step_s:.6f}", s, args.include_gbr, args.include_method)
            else:
                ts = bin_base + timedelta(milliseconds=idx * args.bin_ms)
                _print_row(ts.strftime("%Y-%m-%dT%H:%M:%S.%f"), s, args.include_gbr, args.include_method)

        qi_counts = Counter(s.five_qi for s in samples)
        print(
            f"# bin_ms={args.bin_ms} lines={raw_count} collapsed={len(samples)} bins={len(bins)} "
            f"5qi_hist={dict(sorted(qi_counts.items()))}",
            file=sys.stderr,
        )
    else:
        for s in samples:
            if args.relative_time:
                rel = (s.ts - bin_base).total_seconds()
                _print_row(f"{rel:.6f}", s, args.include_gbr, args.include_method)
            else:
                _print_row(s.ts.strftime("%Y-%m-%dT%H:%M:%S.%f"), s, args.include_gbr, args.include_method)

        qi_counts = Counter(s.five_qi for s in samples)
        print(
            f"# lines={raw_count} collapsed={len(samples)} "
            f"5qi_hist={dict(sorted(qi_counts.items()))}",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
