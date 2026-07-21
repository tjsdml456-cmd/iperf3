#!/usr/bin/env bash
# Compute QRT from PCF 5QI timeline vs scheduler prio_weight timeline.
#
#   Global one-to-one match: mapping[5QI]~=prio_weight, prio_time>=pcf_time,
#   smallest delta first; each PCF/prio row used once.
#   QRT (s) = rel_time_prio - rel_time_pcf
#
# Defaults:
#   PCF  : ~/srsRAN_main/open5gs/logs/pcf.txt
#   prio : ~/prio.txt
#   out  : ~/qrt.txt   (format: qrt_s,five_qi per line)
#
# Usage:
#   ./compute_qrt.sh
#   ./compute_qrt.sh -o ~/my_qrt.txt

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_PATH="${OUTPUT:-$HOME/qrt.txt}"
PRIO_PATH="${PRIO:-$HOME/prio.txt}"
PCF_PATH="${PCF:-$HOME/srsRAN_main/open5gs/logs/pcf.txt}"

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON=python
fi

has_output=0
has_prio=0
has_pcf=0
for a in "$@"; do
    case "$a" in
        -o|--output) has_output=1 ;;
        --prio) has_prio=1 ;;
        --pcf) has_pcf=1 ;;
    esac
done

extra_args=(--signal pcf)
[ "$has_pcf" -eq 0 ] && extra_args+=(--pcf "$PCF_PATH")
[ "$has_prio" -eq 0 ] && extra_args+=(--prio "$PRIO_PATH")

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
