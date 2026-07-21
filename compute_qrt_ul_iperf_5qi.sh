#!/usr/bin/env bash
# Compute QRT: iperf 5QI timeline vs srsUE ul.txt NAS 5QI timeline.
#
#   /tmp/iperf.txt : rel_time_s,transition,five_qi   (or rel_time_s,five_qi)
#   /tmp/ul.txt    : rel_time_s,seq,five_qi,psi,qfi
#
#   Sequential one-to-one: same five_qi, ul_time >= iperf_time (phase changes only).
#   QRT (s) = rel_time_ul - rel_time_iperf
#
# Usage:
#   ./compute_qrt_ul_iperf_5qi.sh
#   ./compute_qrt_ul_iperf_5qi.sh --iperf /tmp/iperf.txt --ul /tmp/ul.txt -o ~/qrt_ul_iperf_5qi.txt

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_PATH="${OUTPUT:-$HOME/qrt_ul_iperf_5qi.txt}"
UL_PATH="${UL:-/tmp/ul.txt}"
IPERF_PATH="${IPERF:-/tmp/iperf.txt}"

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON=python
fi

has_output=0
has_ul=0
has_iperf=0
for a in "$@"; do
    case "$a" in
        -o|--output) has_output=1 ;;
        --ul) has_ul=1 ;;
        --iperf) has_iperf=1 ;;
    esac
done

extra_args=(--signal ul-iperf-5qi)
[ "$has_ul" -eq 0 ] && extra_args+=(--ul "$UL_PATH")
[ "$has_iperf" -eq 0 ] && extra_args+=(--iperf "$IPERF_PATH")

if [ "$has_output" -eq 0 ]; then
    set -- -o "$OUT_PATH" "${extra_args[@]}" "$@"
else
    i=1
    while [ $i -le $# ]; do
        arg=${!i}
        if [ "$arg" = "-o" ] || [ "$arg" = "--output" ]; then
            next=$((i + 1))
            if [ "$next" -le $# ]; then
                OUT_PATH=${!next}
            fi
            break
        fi
        i=$((i + 1))
    done
    set -- "${extra_args[@]}" "$@"
fi

"$PYTHON" "$SCRIPT_DIR/compute_qrt.py" "$@"
echo "Saved: $OUT_PATH"
