#!/usr/bin/env python3
import argparse
import re
from datetime import datetime


LINE_RE = re.compile(
    r"(?P<ts>\d{4}-\d{2}-\d{2}T(?P<tod>\d{2}:\d{2}:\d{2}\.\d+)).*"
    r"\[UL-SR-BOOST\] UE(?P<ue>\d+)\s+has_pending_sr=(?P<pending>true|false)\s+"
    r"avg_ul_rate=(?P<avg>[0-9.]+)\s+estim_ul_rate=(?P<estim>[0-9.]+)"
)


def parse_args():
    p = argparse.ArgumentParser(description="Extract UL-SR-BOOST logs.")
    p.add_argument("logfile", help="Path to gnb log or filtered UL-SR-BOOST log")
    p.add_argument("--ue", type=int, default=None, help="Filter by UE index (e.g. 0)")
    p.add_argument("--start-time", default=None, help="HH:MM:SS.ffffff")
    p.add_argument("--relative-time", action="store_true", help="Print relative time in seconds")
    return p.parse_args()


def parse_start_time(start_time_str):
    if start_time_str is None:
        return None
    return datetime.strptime(start_time_str, "%H:%M:%S.%f")


def relative_seconds(cur_tod: str, start_dt: datetime) -> float:
    cur_dt = datetime.strptime(cur_tod, "%H:%M:%S.%f")
    rel = (cur_dt - start_dt).total_seconds()
    if rel < 0:
        rel += 24.0 * 3600.0
    return rel


def main():
    args = parse_args()
    start_dt = parse_start_time(args.start_time)

    header = ["time", "ue", "has_pending_sr", "avg_ul_rate", "estim_ul_rate"]
    print("\t".join(header))

    with open(args.logfile, "r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            m = LINE_RE.search(raw)
            if not m:
                continue

            ue = int(m.group("ue"))
            if args.ue is not None and ue != args.ue:
                continue

            tod = m.group("tod")
            if args.relative_time and start_dt is not None:
                t = f"{relative_seconds(tod, start_dt):.6f}"
            elif args.relative_time and start_dt is None:
                # If relative mode is requested without start time, keep original ToD.
                t = tod
            else:
                t = tod

            print(
                "\t".join(
                    [
                        t,
                        str(ue),
                        m.group("pending"),
                        m.group("avg"),
                        m.group("estim"),
                    ]
                )
            )


if __name__ == "__main__":
    main()
