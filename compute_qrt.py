#!/usr/bin/env python3
"""
Compare QoS signal timeline (PCF five_qi, UPF dscp, srsUE ul.txt, or iperf wall_time,dscp)
vs scheduler prio_weight (prio.txt).

Matching (sequential, one-to-one):
  - Walk signal rows in time order.
  - For each row, take the first unused prio row with prio_rel_time >= signal_rel_time
    and round(prio_weight, 3) ~= mapping[five_qi].
  - QRT (s) = rel_time_prio - rel_time_signal

DSCP -> 5QI (UPF, same as qos_schedule_dscp / qos_schedule_5qi):
  9/0 -> 9 | 44 -> 66 | 24 -> 80 | 15 -> 84
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, TextIO

DEFAULT_FIVE_QI_TO_PRIO = {
    9: 0.622,
    66: 0.916,
    80: 0.715,
    84: 0.899,
}

DEFAULT_DSCP_TO_FIVE_QI = {
    0: 9,
    9: 9,
    24: 80,
    44: 66,
    15: 84,
}


@dataclass(frozen=True)
class SignalRow:
    rel_time_s: float
    five_qi: int
    dscp: int | None = None


@dataclass(frozen=True)
class PrioRow:
    rel_time_s: float
    seq: int
    prio_weight: float


@dataclass(frozen=True)
class QrtRow:
    rel_time_signal: float
    five_qi: int
    expected_prio_weight: float
    rel_time_prio: float
    seq: int
    prio_weight: float
    qrt_s: float
    dscp: int | None = None


def expand_path(path: str) -> str:
    if path == "-":
        return path
    return str(Path(path).expanduser())


def _open_text(path: str) -> TextIO:
    if path == "-":
        return sys.stdin
    resolved = expand_path(path)
    return open(resolved, encoding="utf-8", errors="replace")


def _parse_float(value: str) -> float:
    return float(value.strip())


def _parse_int(value: str) -> int:
    return int(value.strip())


def read_pcf_rows(stream: Iterable[str]) -> list[SignalRow]:
    rows: list[SignalRow] = []
    for raw in stream:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("rel_time") or lower.startswith("time"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        rows.append(SignalRow(rel_time_s=_parse_float(parts[0]), five_qi=_parse_int(parts[1])))
    return rows


def _wall_time_to_seconds(wall_time: str) -> float:
    """Parse HH:MM:SS[.ffffff] to seconds since midnight."""
    wall_time = wall_time.strip()
    m = re.fullmatch(r"(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?", wall_time)
    if not m:
        raise ValueError(f"invalid wall_time: {wall_time!r}")
    hour, minute, second, frac = m.groups()
    secs = int(hour) * 3600 + int(minute) * 60 + int(second)
    if frac:
        secs += int(frac.ljust(6, "0")[:6]) / 1_000_000.0
    return secs


def read_iperf_wallclock_rows(
    stream: Iterable[str],
    dscp_to_five_qi: dict[int, int],
    anchor_dscp: int | None = 44,
) -> tuple[list[SignalRow], list[str]]:
    """Parse wall_time,dscp; rel_time_s = wall_s - first anchor_dscp event."""
    raw: list[tuple[float, int]] = []
    warnings: list[str] = []
    for raw_line in stream:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("wall_time") or lower.startswith("rel_time") or lower.startswith("time"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        try:
            wall_s = _wall_time_to_seconds(parts[0])
            dscp = _parse_int(parts[1])
        except (ValueError, IndexError) as exc:
            warnings.append(f"skip iperf line: {line!r} ({exc})")
            continue
        raw.append((wall_s, dscp))

    if not raw:
        return [], warnings

    t0: float | None = None
    if anchor_dscp is not None:
        for wall_s, dscp in raw:
            if dscp == anchor_dscp:
                t0 = wall_s
                break
        if t0 is None:
            warnings.append(f"anchor DSCP {anchor_dscp} not found; using first row as t=0")
    if t0 is None:
        t0 = raw[0][0]

    rows: list[SignalRow] = []
    skipped_pre_anchor = 0
    for wall_s, dscp in raw:
        rel_time_s = wall_s - t0
        # Anchor DSCP = t=0: drop earlier phases (e.g. initial DSCP 9 before first 44).
        if anchor_dscp is not None and rel_time_s < -1e-9:
            skipped_pre_anchor += 1
            continue
        five_qi = dscp_to_five_qi.get(dscp)
        if five_qi is None:
            warnings.append(f"skip iperf t={rel_time_s:.6f}s: unknown DSCP {dscp}")
            continue
        rows.append(SignalRow(rel_time_s=rel_time_s, five_qi=five_qi, dscp=dscp))
    if skipped_pre_anchor:
        warnings.append(
            f"skipped {skipped_pre_anchor} iperf row(s) before anchor DSCP {anchor_dscp} (rel_time < 0)"
        )
    return rows, warnings


def read_ul_rows(
    stream: Iterable[str],
    dscp_to_five_qi: dict[int, int],
) -> tuple[list[SignalRow], list[str]]:
    """Parse ul.txt; same as UPF timeline except drop DSCP 0 and repeated same phase."""
    rows: list[SignalRow] = []
    warnings: list[str] = []
    last_five_qi: int | None = None

    for raw_line in stream:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("rel_time") or lower.startswith("time"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            rel_time_s = _parse_float(parts[0])
            dscp = _parse_int(parts[2])
        except (ValueError, IndexError) as exc:
            warnings.append(f"skip ul line: {line!r} ({exc})")
            continue
        if dscp == 0:
            continue
        five_qi = dscp_to_five_qi.get(dscp)
        if five_qi is None:
            warnings.append(f"skip ul t={rel_time_s:.6f}s: unknown DSCP {dscp}")
            continue
        if last_five_qi is not None and five_qi == last_five_qi:
            continue
        rows.append(SignalRow(rel_time_s=rel_time_s, five_qi=five_qi, dscp=dscp))
        last_five_qi = five_qi
    return rows, warnings


def read_upf_rows(
    stream: Iterable[str],
    dscp_to_five_qi: dict[int, int],
) -> tuple[list[SignalRow], list[str]]:
    rows: list[SignalRow] = []
    warnings: list[str] = []
    for raw in stream:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("rel_time") or lower.startswith("time"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 2:
            continue
        rel_time_s = _parse_float(parts[0])
        dscp = _parse_int(parts[1])
        five_qi = dscp_to_five_qi.get(dscp)
        if five_qi is None:
            warnings.append(f"skip UPF t={rel_time_s:.6f}s: unknown DSCP {dscp}")
            continue
        rows.append(SignalRow(rel_time_s=rel_time_s, five_qi=five_qi, dscp=dscp))
    return rows, warnings


def read_prio_rows(stream: Iterable[str]) -> list[PrioRow]:
    rows: list[PrioRow] = []
    for raw in stream:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        lower = line.lower()
        if lower.startswith("rel_time") or lower.startswith("time"):
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        rows.append(
            PrioRow(
                rel_time_s=_parse_float(parts[0]),
                seq=_parse_int(parts[1]),
                prio_weight=_parse_float(parts[2]),
            )
        )
    return rows


def compress_signal_changes(rows: list[SignalRow]) -> list[SignalRow]:
    if not rows:
        return []
    out = [rows[0]]
    for row in rows[1:]:
        if row.five_qi != out[-1].five_qi:
            out.append(row)
    return out


def _round_prio_weight(value: float, decimals: int) -> float:
    return round(value, decimals)


def prio_matches(expected: float, actual: float, tol: float, prio_decimals: int = 3) -> bool:
    exp_r = _round_prio_weight(expected, prio_decimals)
    act_r = _round_prio_weight(actual, prio_decimals)
    return abs(act_r - exp_r) <= tol


def compute_qrt(
    signal_rows: list[SignalRow],
    prio_rows: list[PrioRow],
    mapping: dict[int, float],
    tol: float,
    signal_label: str = "signal",
    prio_decimals: int = 3,
) -> tuple[list[QrtRow], list[str]]:
    events = compress_signal_changes(signal_rows)
    if not events:
        return [], []

    used_prio: set[int] = set()
    results: list[QrtRow] = []

    for sig in events:
        expected = mapping.get(sig.five_qi)
        if expected is None:
            continue
        matched_idx: int | None = None
        for j, prio in enumerate(prio_rows):
            if j in used_prio:
                continue
            if prio.rel_time_s < sig.rel_time_s:
                continue
            if not prio_matches(expected, prio.prio_weight, tol, prio_decimals):
                continue
            matched_idx = j
            break
        if matched_idx is None:
            continue
        used_prio.add(matched_idx)
        prio = prio_rows[matched_idx]
        results.append(
            QrtRow(
                rel_time_signal=sig.rel_time_s,
                five_qi=sig.five_qi,
                expected_prio_weight=expected,
                rel_time_prio=prio.rel_time_s,
                seq=prio.seq,
                prio_weight=prio.prio_weight,
                qrt_s=prio.rel_time_s - sig.rel_time_s,
                dscp=sig.dscp,
            )
        )

    warnings: list[str] = []
    matched_signal_times = {r.rel_time_signal for r in results}
    for sig in events:
        if sig.rel_time_s in matched_signal_times:
            continue
        expected = mapping.get(sig.five_qi)
        dscp_note = f" DSCP={sig.dscp}" if sig.dscp is not None else ""
        if expected is None:
            warnings.append(
                f"unmatched {signal_label} t={sig.rel_time_s:.6f}s: unknown 5QI {sig.five_qi}{dscp_note}"
            )
        else:
            warnings.append(
                f"unmatched {signal_label} t={sig.rel_time_s:.6f}s 5QI={sig.five_qi}{dscp_note} "
                f"(expected prio_weight={_round_prio_weight(expected, prio_decimals):.{prio_decimals}f}, "
                f"no prio at/after signal)"
            )

    results.sort(key=lambda r: r.rel_time_signal)
    return results, warnings


def parse_mapping_arg(items: list[str]) -> dict[int, float]:
    out: dict[int, float] = {}
    for item in items:
        five_qi_s, prio_s = item.split("=", 1)
        out[int(five_qi_s)] = float(prio_s)
    return out


def main() -> int:
    home = Path.home()
    ap = argparse.ArgumentParser(description="Compute QRT = prio rel_time - signal rel_time.")
    ap.add_argument(
        "--signal",
        choices=("pcf", "upf", "iperf", "ul"),
        default="pcf",
        help="Signal: pcf, upf, iperf (wall_time,dscp), or ul (srsUE rel_time,dscp)",
    )
    ap.add_argument(
        "--pcf",
        default=str(home / "srsRAN_main" / "open5gs" / "logs" / "pcf.txt"),
        help="PCF timeline CSV (rel_time_s,five_qi)",
    )
    ap.add_argument(
        "--upf",
        default=str(home / "srsRAN_main" / "open5gs" / "logs" / "upf.txt"),
        help="UPF timeline CSV (rel_time_s,dscp)",
    )
    ap.add_argument(
        "--iperf",
        default=str(home / "iperf3_dscp_100cycles_ul_wallclock.txt"),
        help="iperf wall-clock CSV (wall_time,dscp)",
    )
    ap.add_argument(
        "--ul",
        default="/tmp/ul.txt",
        help="srsUE UL DSCP CSV (rel_time_s,seq,dscp,tos,length,ipver)",
    )
    ap.add_argument(
        "--anchor-dscp",
        type=int,
        default=44,
        help="iperf: first DSCP N event is rel_time_s=0; earlier changes skipped (iperf only)",
    )
    ap.add_argument(
        "--prio-decimals",
        type=int,
        default=3,
        help="Round prio_weight to N decimals for DSCP/5QI mapping match (default: 3)",
    )
    ap.add_argument(
        "--prio",
        default=str(home / "prio.txt"),
        help="Scheduler prio timeline CSV (default: ~/prio.txt)",
    )
    ap.add_argument(
        "-o",
        "--output",
        default=None,
        help="Output path (default: ~/qrt.txt, ~/qrt_upf.txt, ~/qrt_iperf.txt, ~/qrt_ul.txt)",
    )
    ap.add_argument(
        "--tol",
        type=float,
        default=0.001,
        help="Absolute tolerance for prio_weight match (default: 0.001)",
    )
    ap.add_argument(
        "--map",
        action="append",
        default=[],
        metavar="5QI=PRIO",
        help="Override mapping, e.g. --map 80=0.715 (repeatable)",
    )
    args = ap.parse_args()

    if args.output is None:
        default_name = {
            "upf": "qrt_upf.txt",
            "iperf": "qrt_iperf.txt",
            "ul": "qrt_ul.txt",
            "pcf": "qrt.txt",
        }[args.signal]
        output_path = expand_path(str(home / default_name))
    else:
        output_path = expand_path(args.output)

    prio_path = expand_path(args.prio)
    if args.signal == "upf":
        signal_path = expand_path(args.upf)
        signal_label = "UPF"
    elif args.signal == "iperf":
        signal_path = expand_path(args.iperf)
        if not Path(signal_path).is_file():
            alt = Path("/tmp/iperf3_dscp_100cycles_ul_wallclock.txt")
            if alt.is_file():
                signal_path = str(alt)
        signal_label = "iperf"
    elif args.signal == "ul":
        signal_path = expand_path(args.ul)
        signal_label = "ul"
    else:
        signal_path = expand_path(args.pcf)
        signal_label = "PCF"

    mapping = dict(DEFAULT_FIVE_QI_TO_PRIO)
    for item in args.map:
        mapping.update(parse_mapping_arg([item]))

    dscp_map = dict(DEFAULT_DSCP_TO_FIVE_QI)

    if not Path(signal_path).is_file():
        print(f"ERROR: {signal_label} file not found: {signal_path}", file=sys.stderr)
        return 1
    if not Path(prio_path).is_file():
        print(f"ERROR: prio file not found: {prio_path}", file=sys.stderr)
        print("       Run extract_ue0_gnb_logs.sh first or pass --prio PATH", file=sys.stderr)
        return 1

    parse_warnings: list[str] = []
    with _open_text(signal_path) as f:
        if args.signal == "upf":
            signal_rows, parse_warnings = read_upf_rows(f, dscp_map)
        elif args.signal == "iperf":
            signal_rows, parse_warnings = read_iperf_wallclock_rows(
                f, dscp_map, anchor_dscp=args.anchor_dscp
            )
        elif args.signal == "ul":
            signal_rows, parse_warnings = read_ul_rows(f, dscp_map)
        else:
            signal_rows = read_pcf_rows(f)
    with _open_text(prio_path) as f:
        prio_rows = read_prio_rows(f)

    if not signal_rows:
        print(f"ERROR: no {signal_label} rows in {signal_path}", file=sys.stderr)
        return 1
    if not prio_rows:
        print(f"ERROR: no prio rows in {prio_path}", file=sys.stderr)
        return 1

    results, warnings = compute_qrt(
        signal_rows, prio_rows, mapping, args.tol, signal_label=signal_label, prio_decimals=args.prio_decimals
    )
    warnings = parse_warnings + warnings

    out_stream: TextIO
    close_out = False
    if output_path == "-":
        out_stream = sys.stdout
    else:
        out_parent = Path(output_path).parent
        if str(out_parent) not in ("", "."):
            out_parent.mkdir(parents=True, exist_ok=True)
        out_stream = open(output_path, "w", encoding="utf-8", newline="")
        close_out = True

    try:
        for row in results:
            if args.signal in ("upf", "iperf", "ul"):
                dscp_out = row.dscp if row.dscp is not None else row.five_qi
                out_stream.write(f"{row.qrt_s:.6f},{dscp_out}\n")
            else:
                out_stream.write(f"{row.qrt_s:.6f},{row.five_qi}\n")
    finally:
        if close_out:
            out_stream.close()

    print(f"signal={signal_label} file={signal_path}", file=sys.stderr)
    print(f"prio={prio_path}", file=sys.stderr)
    print(f"output={output_path}", file=sys.stderr)

    for w in warnings:
        print(f"WARN: {w}", file=sys.stderr)

    if not results:
        print("ERROR: no QRT rows produced", file=sys.stderr)
        return 1

    matched = len(results)
    qrt_vals = [r.qrt_s for r in results]
    print(
        f"matched={matched} qrt_ms: min={min(qrt_vals)*1000:.3f} "
        f"avg={sum(qrt_vals)/len(qrt_vals)*1000:.3f} max={max(qrt_vals)*1000:.3f}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
