#!/usr/bin/env bash
# Compute QRT from srsUE UL NAS 5QI timeline vs scheduler prio_weight.
#
#   ul.txt format: rel_time_s,seq,five_qi,psi,qfi
#   Same sequential match as compute_qrt_ul.sh / PCF mode:
#     QRT = rel_time_prio - rel_time_ul  (mapping[5QI] ~= round(prio_weight,3))
#
# Defaults (same paths as compute_qrt_ul.sh):
#   ul   : /tmp/ul.txt
#   prio : /tmp/prio.txt
#   out  : ~/qrt_ul_5qi.txt   (format: qrt_s,five_qi per line)
#
# Usage:
#   ./compute_qrt_ul_5qi.sh
#   ./compute_qrt_ul_5qi.sh -o ~/my_qrt_ul_5qi.txt

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_PATH="${OUTPUT:-$HOME/qrt_ul_5qi.txt}"
PRIO_PATH="${PRIO:-/tmp/prio.txt}"
UL_PATH="${UL:-/tmp/ul.txt}"

PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
    PYTHON=python
fi

has_output=0
has_prio=0
has_ul=0
for a in "$@"; do
    case "$a" in
        -o|--output) has_output=1 ;;
        --prio) has_prio=1 ;;
        --ul) has_ul=1 ;;
    esac
done

extra_args=(--signal ul-5qi)
[ "$has_ul" -eq 0 ] && extra_args+=(--ul "$UL_PATH")
[ "$has_prio" -eq 0 ] && extra_args+=(--prio "$PRIO_PATH")

if [ "$has_output" -eq 0 ]; then
    set -- -o "$OUT_PATH" "${extra_args[@]}" "$@"
else
    set -- "${extra_args[@]}" "$@"
fi

"$PYTHON" "$SCRIPT_DIR/compute_qrt.py" "$@"
echo "Saved: $OUT_PATH"
