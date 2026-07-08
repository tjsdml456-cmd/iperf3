#!/usr/bin/env python3
"""
Parse UPF [UPF-DSCP] lines and emit DSCP vs time.

  grep "UPF-DSCP" upf.log > upf_dscp.log
  python3 extract_upf_dscp.py upf.log --bin-ms 500 --relative-time \\
      --start-time 18:59:39.866793 --year 2026
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import List, Optional, Tuple

# Strip ANSI colour codes (some terminals / log collectors keep them).
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# Primary: user's open5gs gtp-path.c format.
UPF_DSCP_FULL_RE = re.compile(
    r"(?:(?P<date>\d{2}/\d{2})\s+)?"
    r"(?:(?P<prefix_ts>\d{2}:\d{2}:\d{2}\.\d+):)?"
    r".*?\[UPF-DSCP\]\s*"
    r"(?:\[(?P<dir>[^\]]+)\]\s*)?"
    r"DSCP\s*=\s*(?P<dscp>\d+)\s*"
    r"(?:TOS\s*=\s*(?P<tos>0x[0-9a-fA-F]+)\s*)?"
    r"(?:wall\s*=\s*(?P<wall>\d{2}:\d{2}:\d{2}\.\d+))?",
    re.IGNORECASE,
)

ISO_TS_RE = re.compile(
    r"(?P<iso>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)"
)
TIME_OF_DAY_RE = re.compile(r"(?P<t>\d{2}:\d{2}:\d{2}\.\d+)")
DSCP_LOOSE_RE = re.compile(r"DSCP\s*=\s*(?P<dscp>\d+)", re.IGNORECASE)
TOS_LOOSE_RE = re.compile(r"TOS\s*=\s*(?P<tos>0x[0-9a-fA-F]+)", re.IGNORECASE)
DIR_LOOSE_RE = re.compile(r"\[UPF-DSCP\]\s*\[([^\]]+)\]", re.IGNORECASE)


@dataclass
class DscpSample:
    ts: datetime
    dscp: int
    tos: int
    direction: str


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


def _parse_line(line: str, year: int, fallback: datetime) -> Optional[Tuple[datetime, int, int, str]]:
    raw = ANSI_RE.sub("", line).rstrip("\n")
    if "UPF-DSCP" not in raw:
        return None

    m = UPF_DSCP_FULL_RE.search(raw)
    if m:
        dscp = int(m.group("dscp"))
        tos_s = m.group("tos")
        tos = int(tos_s, 16) if tos_s else dscp << 2
        direction = m.group("dir") or "unknown"
        ts = _resolve_timestamp(
            raw,
            m.group("date"),
            m.group("wall"),
            m.group("prefix_ts"),
            year,
            fallback,
        )
        return ts, dscp, tos, direction

    dscp_m = DSCP_LOOSE_RE.search(raw)
    if not dscp_m:
        return None
    dscp = int(dscp_m.group("dscp"))
    tos_m = TOS_LOOSE_RE.search(raw)
    tos = int(tos_m.group("tos"), 16) if tos_m else dscp << 2
    dir_m = DIR_LOOSE_RE.search(raw)
    direction = dir_m.group(1) if dir_m else "unknown"
    date_m = re.search(r"(?P<date>\d{2}/\d{2})", raw)
    date_mmdd = date_m.group("date") if date_m else None
    wall_m = re.search(r"wall\s*=\s*(?P<wall>\d{2}:\d{2}:\d{2}\.\d+)", raw, re.I)
    prefix_m = re.search(r"(?P<prefix>\d{2}:\d{2}:\d{2}\.\d+):", raw)
    ts = _resolve_timestamp(
        raw,
        date_mmdd,
        wall_m.group("wall") if wall_m else None,
        prefix_m.group("prefix") if prefix_m else None,
        year,
        fallback,
    )
    return ts, dscp, tos, direction


def parse_samples(
    log_path: str,
    start_time: Optional[str],
    year: Optional[int],
    direction: Optional[str],
    stats: Optional[ParseStats] = None,
) -> List[DscpSample]:
    samples: List[DscpSample] = []
    first_ts: Optional[datetime] = None
    start_dt: Optional[datetime] = None
    use_year = year or datetime.now().year
    st = stats if stats is not None else ParseStats()

    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            st.lines_read += 1
            if "UPF-DSCP" in ANSI_RE.sub("", line):
                st.marker_hits += 1

            try:
                parsed = _parse_line(line, use_year, first_ts or datetime.now())
            except ValueError:
                continue
            if parsed is None:
                continue

            st.parsed += 1
            ts, dscp, tos, dir_name = parsed
            if direction is not None and dir_name != direction:
                continue

            if first_ts is None:
                first_ts = ts
            if start_time is not None and start_dt is None:
                start_dt = _parse_start_time(start_time, ts)
            if start_dt is not None and ts < start_dt:
                continue

            st.after_start_filter += 1
            samples.append(DscpSample(ts=ts, dscp=dscp, tos=tos, direction=dir_name))

    samples.sort(key=lambda s: s.ts)
    return samples


def bin_samples_last(samples: List[DscpSample], bin_ms: int, bin_base: datetime) -> List[tuple[int, int, int]]:
    if not samples:
        return []

    by_bin: dict[int, DscpSample] = {}
    last_idx = 0
    for s in samples:
        idx = int(max(0.0, (s.ts - bin_base).total_seconds() * 1000.0) // bin_ms)
        by_bin[idx] = s
        last_idx = max(last_idx, idx)

    return [(idx, by_bin[idx].dscp, by_bin[idx].tos) for idx in range(0, last_idx + 1) if idx in by_bin]


def bin_samples_mode(samples: List[DscpSample], bin_ms: int, bin_base: datetime) -> List[tuple[int, int, int]]:
    if not samples:
        return []

    counts: dict[int, Counter[int]] = {}
    last: dict[int, DscpSample] = {}
    last_idx = 0
    for s in samples:
        idx = int(max(0.0, (s.ts - bin_base).total_seconds() * 1000.0) // bin_ms)
        counts.setdefault(idx, Counter())[s.dscp] += 1
        last[idx] = s
        last_idx = max(last_idx, idx)

    out: List[tuple[int, int, int]] = []
    for idx in range(0, last_idx + 1):
        if idx not in counts:
            continue
        dscp = counts[idx].most_common(1)[0][0]
        out.append((idx, dscp, last[idx].tos))
    return out


def _bin_base(start_time: Optional[str], samples: List[DscpSample]) -> datetime:
    if not samples:
        raise ValueError("no samples")
    if start_time is not None:
        return _parse_start_time(start_time, samples[0].ts)
    return samples[0].ts


def _print_no_match_help(log_path: str, stats: ParseStats) -> None:
    print("No [UPF-DSCP] output rows.", file=sys.stderr)
    print(
        f"  read={stats.lines_read}  UPF-DSCP_marker={stats.marker_hits}  "
        f"parsed={stats.parsed}  after_start_filter={stats.after_start_filter}",
        file=sys.stderr,
    )
    if stats.marker_hits > 0 and stats.parsed == 0:
        print("  Lines contain UPF-DSCP but parser failed — paste one line for regex fix.", file=sys.stderr)
    elif stats.parsed > 0 and stats.after_start_filter == 0:
        print("  Parsed lines exist but --start-time filtered all — check --year / --start-time.", file=sys.stderr)
    elif stats.marker_hits == 0:
        print("  No 'UPF-DSCP' in file — try: grep UPF-DSCP core.log | head", file=sys.stderr)

    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "UPF-DSCP" in line:
                    print(f"  example: {ANSI_RE.sub('', line).rstrip()[:200]}", file=sys.stderr)
                    break
    except OSError:
        pass


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract [UPF-DSCP] DSCP vs time CSV")
    ap.add_argument("log_file")
    ap.add_argument("--bin-ms", type=int, default=None, help="Bin width (500 = 0.5s iperf step)")
    ap.add_argument(
        "--bin-mode",
        choices=("last", "mode"),
        default="last",
        help="Per-bin DSCP: last sample or most common (default: last)",
    )
    ap.add_argument("--start-time", type=str, default=None, help="e.g. 18:59:39.866793 or ISO")
    ap.add_argument("--relative-time", action="store_true")
    ap.add_argument("--year", type=int, default=None, help="Year for MM/DD log prefix (default: today)")
    ap.add_argument("--direction", type=str, default=None, help="Filter e.g. N6-TUN-DL")
    ap.add_argument("--no-header", action="store_true")
    ap.add_argument("--include-tos", action="store_true", help="Add TOS column")
    args = ap.parse_args()

    stats = ParseStats()
    samples = parse_samples(args.log_file, args.start_time, args.year, args.direction, stats)
    if not samples:
        _print_no_match_help(args.log_file, stats)
        return 1

    bin_base = _bin_base(args.start_time, samples)

    if not args.no_header:
        if args.include_tos:
            cols = "rel_time_s,dscp,tos" if args.relative_time else "timestamp,dscp,tos"
        else:
            cols = "rel_time_s,dscp" if args.relative_time else "timestamp,dscp"
        print(cols)

    if args.bin_ms is not None:
        if args.bin_ms <= 0:
            print("ERROR: --bin-ms must be > 0", file=sys.stderr)
            return 2

        bins = (
            bin_samples_mode(samples, args.bin_ms, bin_base)
            if args.bin_mode == "mode"
            else bin_samples_last(samples, args.bin_ms, bin_base)
        )
        step_s = args.bin_ms / 1000.0
        for idx, dscp, tos in bins:
            if args.relative_time:
                rel = idx * step_s
                if args.include_tos:
                    print(f"{rel:.6f},{dscp},{tos}")
                else:
                    print(f"{rel:.6f},{dscp}")
            else:
                ts = bin_base + timedelta(milliseconds=idx * args.bin_ms)
                ts_s = ts.strftime("%Y-%m-%dT%H:%M:%S.%f")
                if args.include_tos:
                    print(f"{ts_s},{dscp},{tos}")
                else:
                    print(f"{ts_s},{dscp}")

        dscp_counts = Counter(s.dscp for s in samples)
        print(
            f"# bin_ms={args.bin_ms} bin_mode={args.bin_mode} "
            f"lines={len(samples)} bins={len(bins)} "
            f"dscp_hist={dict(sorted(dscp_counts.items()))}",
            file=sys.stderr,
        )
    else:
        for s in samples:
            if args.relative_time:
                rel = (s.ts - bin_base).total_seconds()
                if args.include_tos:
                    print(f"{rel:.6f},{s.dscp},{s.tos}")
                else:
                    print(f"{rel:.6f},{s.dscp}")
            else:
                ts_s = s.ts.strftime("%Y-%m-%dT%H:%M:%S.%f")
                if args.include_tos:
                    print(f"{ts_s},{s.dscp},{s.tos}")
                else:
                    print(f"{ts_s},{s.dscp}")

        dscp_counts = Counter(s.dscp for s in samples)
        print(f"# lines={len(samples)} dscp_hist={dict(sorted(dscp_counts.items()))}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
