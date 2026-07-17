#!/usr/bin/env python3
"""Extract slot,dscp_new from QRT-PROF GNB_SCHED_SLOT log lines."""

from __future__ import annotations

import argparse
import re
import sys

GNB_RE = re.compile(
    r"QRT-PROF GNB_SCHED_SLOT\b.*?dscp_new=(?P<dscp>\d+)\b.*?slot=(?P<slot>\d+)\b"
)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", help="gNB log file (or - for stdin)")
    ap.add_argument("-o", "--output", help="output CSV path (default: stdout)")
    args = ap.parse_args()

    inf = sys.stdin if args.log == "-" else open(args.log, "r", encoding="utf-8", errors="replace")
    outf = open(args.output, "w", encoding="utf-8") if args.output else sys.stdout

    try:
        outf.write("slot,dscp_new\n")
        for line in inf:
            m = GNB_RE.search(line)
            if m:
                outf.write(f"{m.group('slot')},{m.group('dscp')}\n")
    finally:
        if args.log != "-":
            inf.close()
        if args.output:
            outf.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
