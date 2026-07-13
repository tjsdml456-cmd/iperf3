#!/usr/bin/env bash
# Compute QRT from srsUE UL DSCP timeline vs scheduler prio_weight.
#
#   Same as compute_qrt_upf.sh (sequential match, QRT = rel_time_prio - rel_time_signal),
#   plus ul.txt filter: skip DSCP 0; skip repeated same DSCP until next phase.
#
# Defaults:
#   ul   : /tmp/ul.txt
#   prio : /tmp/prio.txt
#   out  : ~/qrt_ul.txt   (format: qrt_s,dscp per line)
#
# Usage:
#   ./compute_qrt_ul.sh

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_PATH="${OUTPUT:-$HOME/qrt_ul.txt}"
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

extra_args=(--signal ul)
[ "$has_ul" -eq 0 ] && extra_args+=(--ul "$UL_PATH")
[ "$has_prio" -eq 0 ] && extra_args+=(--prio "$PRIO_PATH")

if [ "$has_output" -eq 0 ]; then
    set -- -o "$OUT_PATH" "${extra_args[@]}" "$@"
else
    set -- "${extra_args[@]}" "$@"
fi

"$PYTHON" "$SCRIPT_DIR/compute_qrt.py" "$@"
echo "Saved: $OUT_PATH"
