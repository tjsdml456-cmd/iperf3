#!/usr/bin/env python3
"""
Expand a piecewise QoS schedule (rel_time_s + five_qi or dscp) into a fixed
time grid (default 0.01 s) with target rate, GBR, and PDB per row.

Default profiles (override with --profile or --profiles-json):
  5QI 66 / DSCP 44  GBR      target 7 Mbps   PDB 100 ms
  5QI 84 / DSCP 15  DC-GBR   target 4 Mbps   PDB  30 ms
  5QI 80 / DSCP 24  pdb-only no target rate  PDB  10 ms
  5QI  9 / DSCP  0  default  no target rate  PDB   -

Example:
  python3 expand_qos_schedule.py qos_schedule_dscp_replay.csv -o expanded.csv
  python3 expand_qos_schedule.py qos_schedule_dscp.csv --step 0.01
  python3 expand_qos_schedule.py schedule.csv \\
      --profile 66:7:7:100:GBR --profile 84:4:4:30:DC-GBR --profile 80:: :10:pdb-only
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, TextIO, Tuple

FIVE_QI_TO_DSCP = {80: 24, 66: 44, 84: 15, 9: 0}
DSCP_TO_FIVE_QI = {24: 80, 44: 66, 15: 84, 0: 9}


@dataclass
class QosProfile:
    five_qi: int
    dscp: int
    qos_class: str
    target_rate_mbps: Optional[float]
    gbr_mbps: Optional[float]
    pdb_ms: Optional[float]

    @classmethod
    def from_dict(cls, five_qi: int, data: dict) -> "QosProfile":
        dscp = int(data.get("dscp", FIVE_QI_TO_DSCP.get(five_qi, 0)))
        tr = data.get("target_rate_mbps")
        gbr = data.get("gbr_mbps")
        pdb = data.get("pdb_ms")
        return cls(
            five_qi=five_qi,
            dscp=dscp,
            qos_class=str(data.get("qos_class", data.get("class", "?"))),
            target_rate_mbps=None if tr in (None, "", "-") else float(tr),
            gbr_mbps=None if gbr in (None, "", "-") else float(gbr),
            pdb_ms=None if pdb in (None, "", "-") else float(pdb),
        )


DEFAULT_PROFILES: Dict[int, dict] = {
    66: {
        "dscp": 44,
        "qos_class": "GBR",
        "target_rate_mbps": 7.0,
        "gbr_mbps": 7.0,
        "pdb_ms": 100.0,
    },
    84: {
        "dscp": 15,
        "qos_class": "DC-GBR",
        "target_rate_mbps": 4.0,
        "gbr_mbps": 4.0,
        "pdb_ms": 30.0,
    },
    80: {
        "dscp": 24,
        "qos_class": "pdb-only",
        "target_rate_mbps": None,
        "gbr_mbps": None,
        "pdb_ms": 10.0,
    },
    9: {
        "dscp": 0,
        "qos_class": "default",
        "target_rate_mbps": None,
        "gbr_mbps": None,
        "pdb_ms": None,
    },
}


@dataclass(frozen=True)
class ScheduleEvent:
    rel_time_s: float
    five_qi: int


def _parse_profile_arg(spec: str) -> Tuple[int, dict]:
    # five_qi:target_rate:gbr:pdb_ms:qos_class  (empty fields allowed)
    parts = spec.split(":")
    if len(parts) < 5:
        raise ValueError(
            f"invalid --profile {spec!r}; use five_qi:target_mbps:gbr_mbps:pdb_ms:class"
        )
    five_qi = int(parts[0])

    def _num(s: str) -> Optional[float]:
        s = s.strip()
        if not s or s == "-":
            return None
        return float(s)

    return five_qi, {
        "target_rate_mbps": _num(parts[1]),
        "gbr_mbps": _num(parts[2]),
        "pdb_ms": _num(parts[3]),
        "qos_class": parts[4].strip() or "?",
        "dscp": FIVE_QI_TO_DSCP.get(five_qi, 0),
    }


def load_profiles(args: argparse.Namespace) -> Dict[int, QosProfile]:
    raw = {k: dict(v) for k, v in DEFAULT_PROFILES.items()}
    if args.profiles_json:
        extra = json.loads(Path(args.profiles_json).read_text(encoding="utf-8"))
        for k, v in extra.items():
            raw[int(k)] = {**raw.get(int(k), {}), **v}
    for spec in args.profile or []:
        five_qi, data = _parse_profile_arg(spec)
        raw[five_qi] = {**raw.get(five_qi, {}), **data}
    return {qi: QosProfile.from_dict(qi, data) for qi, data in raw.items()}


def load_schedule(path: Path) -> List[ScheduleEvent]:
    events: List[ScheduleEvent] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            lower = line.lower()
            if lower.startswith("rel_time") or lower.startswith("time_s"):
                continue
            t_s, val_s = line.split(",", 1)
            t = float(t_s.strip())
            val = int(val_s.strip())
            if val in FIVE_QI_TO_DSCP:
                five_qi = val
            elif val in DSCP_TO_FIVE_QI:
                five_qi = DSCP_TO_FIVE_QI[val]
            else:
                raise ValueError(f"unknown schedule value {val} at t={t}")
            events.append(ScheduleEvent(t, five_qi))
    if not events:
        raise ValueError(f"empty schedule: {path}")
    events.sort(key=lambda e: e.rel_time_s)
    return events


def align_schedule_events(
    events: List[ScheduleEvent],
    change_step: float,
    *,
    schedule_end: float,
    repeat: bool = True,
) -> List[ScheduleEvent]:
    """Place changes at 0, change_step, ... up to schedule_end (inclusive)."""
    if change_step <= 0:
        raise ValueError("change_step must be > 0")
    if schedule_end < 0:
        raise ValueError("schedule_end must be >= 0")
    n = int(round(schedule_end / change_step)) + 1
    if n < 1:
        n = 1
    if not repeat and n > len(events):
        raise ValueError(
            f"need {n} schedule points @ {change_step}s but only {len(events)} "
            f"(use --repeat or shorter --schedule-end)"
        )
    out: List[ScheduleEvent] = []
    for i in range(n):
        src = events[i % len(events)] if repeat else events[i]
        out.append(ScheduleEvent(round(i * change_step, 6), src.five_qi))
    return out


def write_schedule_csv(path: Path, events: List[ScheduleEvent], *, dscp: bool) -> None:
    lines = [
        "# rel_time_s,dscp" if dscp else "# rel_time_s,five_qi",
        "rel_time_s,dscp" if dscp else "rel_time_s,five_qi",
    ]
    for ev in events:
        val = FIVE_QI_TO_DSCP[ev.five_qi] if dscp else ev.five_qi
        lines.append(f"{ev.rel_time_s:g},{val}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def active_five_qi(events: List[ScheduleEvent], t: float) -> int:
    qi = events[0].five_qi
    for ev in events:
        if ev.rel_time_s > t + 1e-12:
            break
        qi = ev.five_qi
    return qi


def frange(start: float, stop: float, step: float) -> List[float]:
    if step <= 0:
        raise ValueError("step must be > 0")
    n = int(round((stop - start) / step))
    return [round(start + i * step, 10) for i in range(n + 1)]


def fmt_opt(v: Optional[float]) -> str:
    if v is None:
        return ""
    if abs(v - round(v)) < 1e-9:
        return str(int(round(v)))
    return f"{v:g}"


def write_expanded(
    out: TextIO,
    events: List[ScheduleEvent],
    profiles: Dict[int, QosProfile],
    *,
    step: float,
    end_time: float,
    header: bool,
) -> int:
    times = frange(0.0, end_time, step)
    fieldnames = [
        "rel_time_s",
        "five_qi",
        "dscp",
        "qos_class",
        "target_rate_mbps",
        "gbr_mbps",
        "pdb_ms",
    ]
    writer = csv.DictWriter(out, fieldnames=fieldnames, lineterminator="\n")
    if header:
        writer.writeheader()
    rows = 0
    for t in times:
        qi = active_five_qi(events, t)
        if qi not in profiles:
            raise KeyError(f"no profile for 5QI {qi} (t={t})")
        p = profiles[qi]
        writer.writerow(
            {
                "rel_time_s": f"{t:.2f}",
                "five_qi": p.five_qi,
                "dscp": p.dscp,
                "qos_class": p.qos_class,
                "target_rate_mbps": fmt_opt(p.target_rate_mbps),
                "gbr_mbps": fmt_opt(p.gbr_mbps),
                "pdb_ms": fmt_opt(p.pdb_ms),
            }
        )
        rows += 1
    return rows


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Expand QoS schedule to fixed time grid.")
    p.add_argument(
        "schedule",
        nargs="?",
        default="qos_schedule_dscp_replay.csv",
        help="CSV: rel_time_s,five_qi or rel_time_s,dscp",
    )
    p.add_argument("-o", "--output", help="output CSV (default: stdout)")
    p.add_argument("--step", type=float, default=0.01, help="grid step in seconds")
    p.add_argument(
        "--end-time",
        type=float,
        default=None,
        help="last time point (default: last schedule event time)",
    )
    p.add_argument(
        "--duration",
        type=float,
        default=None,
        help="alternative to --end-time: end = duration (e.g. 21)",
    )
    p.add_argument(
        "--profile",
        action="append",
        metavar="SPEC",
        help="five_qi:target_mbps:gbr_mbps:pdb_ms:qos_class (use - for empty)",
    )
    p.add_argument("--profiles-json", help="JSON file { \"66\": { ... }, ... }")
    p.add_argument(
        "--change-step",
        type=float,
        default=0.5,
        help="align QoS changes to exact multiples (default 0.5 s); 0 = use CSV times",
    )
    p.add_argument(
        "--schedule-end",
        type=float,
        default=20.0,
        help="last QoS change time when aligning (default 20 = 40 x 0.5s transitions)",
    )
    p.add_argument(
        "--no-repeat",
        action="store_true",
        help="do not repeat sequence when schedule-end needs more points than CSV",
    )
    p.add_argument(
        "--emit-schedule",
        metavar="PATH",
        help="also write aligned rel_time_s,five_qi (or dscp) schedule CSV",
    )
    p.add_argument("--no-header", action="store_true")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    schedule_path = Path(args.schedule)
    if not schedule_path.is_file():
        print(f"ERROR: schedule not found: {schedule_path}", file=sys.stderr)
        return 1

    events = load_schedule(schedule_path)
    if args.change_step and args.change_step > 0:
        events = align_schedule_events(
            events,
            args.change_step,
            schedule_end=args.schedule_end,
            repeat=not args.no_repeat,
        )

    profiles = load_profiles(args)

    if args.duration is not None:
        end_time = args.duration
    elif args.end_time is not None:
        end_time = args.end_time
    else:
        end_time = (
            21.0
            if (args.change_step and args.change_step > 0)
            else events[-1].rel_time_s
        )

    if args.emit_schedule:
        emit_path = Path(args.emit_schedule)
        use_dscp = "dscp" in schedule_path.name.lower() and "replay" not in schedule_path.name.lower()
        write_schedule_csv(emit_path, events, dscp=use_dscp)
        print(f"wrote aligned schedule -> {emit_path}", file=sys.stderr)

    if end_time < events[-1].rel_time_s:
        print(
            f"WARNING: end_time={end_time} < last event {events[-1].rel_time_s}",
            file=sys.stderr,
        )

    out_f: TextIO
    if args.output:
        out_f = Path(args.output).open("w", encoding="utf-8", newline="")
        close = True
    else:
        out_f = sys.stdout
        close = False

    try:
        n = write_expanded(
            out_f,
            events,
            profiles,
            step=args.step,
            end_time=end_time,
            header=not args.no_header,
        )
    finally:
        if close:
            out_f.close()

    if args.output:
        print(f"wrote {n} rows -> {args.output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
