# Shared random QoS index sequence for paired PCF(5QI) / DSCP experiments.
#
# Timeline (t=0 = traffic start):
#   t=0           → 5QI 9 / DSCP 0  (fixed initial 0.5s phase)
#   t=STEP*i (i≥1) → random from pool below (TRANSITIONS changes)
#
# Mapping (same bitrate tier, different signaling):
#   idx 0 → 5QI 80 / DSCP 24  (pdb-only / non-GBR)
#   idx 1 → 5QI 66 / DSCP 44  (GBR)
#   idx 2 → 5QI 84 / DSCP 15  (DC-GBR)
#
# Sequence constraints (STEP_SEC, TRANSITIONS required before generate):
#   - TRANSITIONS random picks (not including initial 5QI9/DSCP0)
#   - Every QOS_WINDOW_SEC (default 20s) sliding window: all 3 idx appear ≥1
#   - Same idx at most QOS_MAX_CONSECUTIVE (default 2) times in a row
#
# Seed file lets the second script replay the first script's random order.
#   QOS_NEW_SEED=1 ./script.sh   → new random seed, overwrite file
#   RANDOM_SEED=12345 ./script.sh → fixed seed, write to file
#   ./script.sh (no env)          → reuse file if present, else create new

QOS_RANDOM_SEED_FILE=${QOS_RANDOM_SEED_FILE:-/tmp/qos_random_seed}
QOS_WINDOW_SEC=${QOS_WINDOW_SEC:-20}
QOS_MAX_CONSECUTIVE=${QOS_MAX_CONSECUTIVE:-2}
QOS_POOL_SIZE=3
QOS_IDX_SEQ=()
QOS_IDX_SEQ_GENERATED=0

init_qos_random_seed() {
    if [ "${QOS_NEW_SEED:-0}" = "1" ]; then
        RANDOM_SEED=$RANDOM
        echo "$RANDOM_SEED" >"$QOS_RANDOM_SEED_FILE"
    elif [ -n "${RANDOM_SEED:-}" ]; then
        echo "$RANDOM_SEED" >"$QOS_RANDOM_SEED_FILE"
    elif [ -f "$QOS_RANDOM_SEED_FILE" ]; then
        RANDOM_SEED=$(cat "$QOS_RANDOM_SEED_FILE")
    else
        RANDOM_SEED=$RANDOM
        echo "$RANDOM_SEED" >"$QOS_RANDOM_SEED_FILE"
    fi
    export RANDOM_SEED
}

qos_window_slots() {
    awk -v s="${STEP_SEC:-0.5}" -v w="$QOS_WINDOW_SEC" \
        'BEGIN{n=int(w/s); if(n<1)n=1; print n}'
}

_qos_shuffle_array() {
    local -n _arr=$1
    local i j tmp n=${#_arr[@]}
    for ((i = n - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        tmp=${_arr[i]}
        _arr[i]=${_arr[j]}
        _arr[j]=$tmp
    done
}

_qos_window_missing_types() {
    local win_start=$1 pos=$2
    local t j found missing=""
    for t in 0 1 2; do
        found=0
        for ((j = win_start; j < pos; j++)); do
            if [ "${QOS_IDX_SEQ[$j]}" -eq "$t" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            missing="$missing $t"
        fi
    done
    echo "$missing"
}

_qos_build_candidates() {
    local pos=$1
    local W c missing required
    local -a cands=() filtered=()

    W=$(qos_window_slots)

    for c in 0 1 2; do
        if [ "$pos" -ge "$QOS_MAX_CONSECUTIVE" ]; then
            local all_same=1 k
            for ((k = 1; k <= QOS_MAX_CONSECUTIVE; k++)); do
                if [ "${QOS_IDX_SEQ[$((pos - k))]}" -ne "$c" ]; then
                    all_same=0
                    break
                fi
            done
            if [ "$all_same" -eq 1 ]; then
                continue
            fi
        fi
        cands+=("$c")
    done

    if [ ${#cands[@]} -eq 0 ]; then
        return 1
    fi

    if [ "$pos" -ge $((W - 1)) ]; then
        local win_start=$((pos - W + 1))
        missing=$(_qos_window_missing_types "$win_start" "$pos")
        if [ -n "$missing" ]; then
            for c in $missing; do
                local ok=0 x
                for x in "${cands[@]}"; do
                    if [ "$x" -eq "$c" ]; then
                        ok=1
                        break
                    fi
                done
                if [ "$ok" -eq 1 ]; then
                    filtered+=("$c")
                fi
            done
            if [ ${#filtered[@]} -eq 0 ]; then
                return 1
            fi
            cands=("${filtered[@]}")
        fi
    fi

    _qos_shuffle_array cands
    echo "${cands[@]}"
}

_qos_bt_generate() {
    local pos=$1
    local cands_str c

    if [ "$pos" -ge "$TRANSITIONS" ]; then
        return 0
    fi

    cands_str=$(_qos_build_candidates "$pos") || return 1
    local -a cands
    read -ra cands <<<"$cands_str"

    for c in "${cands[@]}"; do
        QOS_IDX_SEQ[$pos]=$c
        if _qos_bt_generate $((pos + 1)); then
            return 0
        fi
    done
    return 1
}

_qos_validate_sequence() {
    local W i win_start t j run

    W=$(qos_window_slots)

    if [ "$TRANSITIONS" -le 1 ]; then
        return 0
    fi

    run=1
    for ((i = 1; i < TRANSITIONS; i++)); do
        if [ "${QOS_IDX_SEQ[$i]}" -eq "${QOS_IDX_SEQ[$((i - 1))]}" ]; then
            run=$((run + 1))
            if [ "$run" -gt "$QOS_MAX_CONSECUTIVE" ]; then
                return 1
            fi
        else
            run=1
        fi
    done

    for ((i = W - 1; i < TRANSITIONS; i++)); do
        win_start=$((i - W + 1))
        for t in 0 1 2; do
            local found=0
            for ((j = win_start; j <= i; j++)); do
                if [ "${QOS_IDX_SEQ[$j]}" -eq "$t" ]; then
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                return 1
            fi
        done
    done
    return 0
}

generate_qos_index_sequence() {
    local W attempt=0

    if [ "$QOS_IDX_SEQ_GENERATED" = "1" ]; then
        return 0
    fi
    init_qos_random_seed

    W=$(qos_window_slots)
    if [ "$W" -lt "$QOS_POOL_SIZE" ]; then
        echo "ERROR: ${QOS_WINDOW_SEC}s window (${W} slots @ STEP_SEC=${STEP_SEC:-?}) < ${QOS_POOL_SIZE} QoS types." >&2
        exit 1
    fi

    while [ "$attempt" -lt 32 ]; do
        RANDOM=$((RANDOM_SEED + attempt))
        QOS_IDX_SEQ=()
        if _qos_bt_generate 0 && _qos_validate_sequence; then
            QOS_IDX_SEQ_GENERATED=1
            return 0
        fi
        attempt=$((attempt + 1))
    done

    echo "ERROR: constrained QoS sequence generation failed (TRANSITIONS=$TRANSITIONS STEP_SEC=${STEP_SEC:-?})." >&2
    exit 1
}

idx_to_5qi() {
    case "$1" in
        0) echo 80 ;;
        1) echo 66 ;;
        2) echo 84 ;;
        *) echo 80 ;;
    esac
}

idx_to_dscp() {
    case "$1" in
        0) echo 24 ;;
        1) echo 44 ;;
        2) echo 15 ;;
        *) echo 24 ;;
    esac
}

qos_label_for_idx() {
    case "$1" in
        0) echo "pdb-only" ;;
        1) echo "GBR" ;;
        2) echo "DC-GBR" ;;
        *) echo "?" ;;
    esac
}

rate_for_qos_idx() {
    case "$1" in
        1) echo "${QOS_RATE_GBR:-7M}" ;;
        2) echo "${QOS_RATE_DC_GBR:-4M}" ;;
        *) echo "${QOS_RATE_NON_GBR:-0.5M}" ;;
    esac
}

QOS_INITIAL_5QI=${QOS_INITIAL_5QI:-9}
QOS_INITIAL_DSCP=${QOS_INITIAL_DSCP:-0}

five_qi_for_step() {
    local step=$1
    if [ "$step" -eq 0 ]; then
        echo "$QOS_INITIAL_5QI"
    else
        idx_to_5qi "${QOS_IDX_SEQ[$((step - 1))]}"
    fi
}

dscp_for_step() {
    local step=$1
    if [ "$step" -eq 0 ]; then
        echo "$QOS_INITIAL_DSCP"
    else
        idx_to_dscp "${QOS_IDX_SEQ[$((step - 1))]}"
    fi
}

rate_for_step() {
    local step=$1
    if [ "$step" -eq 0 ]; then
        echo "${QOS_RATE_INITIAL:-${QOS_RATE_NON_GBR:-0.5M}}"
    else
        rate_for_qos_idx "${QOS_IDX_SEQ[$((step - 1))]}"
    fi
}

print_qos_index_sequence_summary() {
    local i seq=""
    for i in $(seq 0 $((TRANSITIONS - 1))); do
        if [ -n "$seq" ]; then
            seq="${seq} -> "
        fi
        seq="${seq}${QOS_IDX_SEQ[$i]}"
    done
    echo "$seq"
}

print_5qi_sequence_from_idx() {
    local i seq="$QOS_INITIAL_5QI"
    for i in $(seq 0 $((TRANSITIONS - 1))); do
        seq="${seq} -> $(idx_to_5qi "${QOS_IDX_SEQ[$i]}")"
    done
    echo "$seq"
}

print_dscp_sequence_from_idx() {
    local i seq="$QOS_INITIAL_DSCP"
    for i in $(seq 0 $((TRANSITIONS - 1))); do
        seq="${seq} -> $(idx_to_dscp "${QOS_IDX_SEQ[$i]}")"
    done
    echo "$seq"
}

print_qos_pairing_check() {
    echo "  초기(t=0): 5QI ${QOS_INITIAL_5QI} ↔ DSCP ${QOS_INITIAL_DSCP}"
    echo "  랜덤 풀: 5QI 80↔DSCP 24 | 5QI 66↔DSCP 44 | 5QI 84↔DSCP 15"
}

# --- Fixed schedule replay (PCF / paired DSCP) ---
# CSV columns: rel_time_s,five_qi  (comments and header lines skipped)
QOS_USE_SCHEDULE=0
QOS_SCHEDULE_REL=()
QOS_SCHEDULE_5QI=()
QOS_SCHEDULE_N=0

five_qi_to_dscp() {
    case "$1" in
        80) echo 24 ;;
        66) echo 44 ;;
        84) echo 15 ;;
        9)  echo 0 ;;
        *)  echo 0 ;;
    esac
}

load_qos_schedule_file() {
    local f=$1 line t q n=0
    if [ ! -f "$f" ]; then
        echo "ERROR: QoS schedule file not found: $f" >&2
        exit 1
    fi
    QOS_SCHEDULE_REL=()
    QOS_SCHEDULE_5QI=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in
            rel_time_s,*|time_s,*|t,*|rel_time,*five_qi*) continue ;;
        esac
        t="${line%%,*}"
        q="${line##*,}"
        if ! awk -v t="$t" -v q="$q" 'BEGIN{exit !(t+0==t && q+0==q && q>0)}'; then
            echo "ERROR: invalid schedule line: $line" >&2
            exit 1
        fi
        QOS_SCHEDULE_REL[$n]=$t
        QOS_SCHEDULE_5QI[$n]=$q
        n=$((n + 1))
    done <"$f"
    if [ "$n" -lt 1 ]; then
        echo "ERROR: empty QoS schedule: $f" >&2
        exit 1
    fi
    QOS_SCHEDULE_N=$n
    QOS_USE_SCHEDULE=1
    QOS_IDX_SEQ_GENERATED=1
    TRANSITIONS=$((n - 1))
}

schedule_rel_time_at() {
    echo "${QOS_SCHEDULE_REL[$1]}"
}

schedule_five_qi_at() {
    echo "${QOS_SCHEDULE_5QI[$1]}"
}

print_5qi_schedule_sequence() {
    local i seq=""
    for i in $(seq 0 $((QOS_SCHEDULE_N - 1))); do
        if [ -n "$seq" ]; then
            seq="${seq} -> "
        fi
        seq="${seq}${QOS_SCHEDULE_5QI[$i]}"
    done
    echo "$seq"
}

print_dscp_schedule_sequence() {
    local i seq=""
    for i in $(seq 0 $((QOS_SCHEDULE_N - 1))); do
        if [ -n "$seq" ]; then
            seq="${seq} -> "
        fi
        seq="${seq}$(five_qi_to_dscp "${QOS_SCHEDULE_5QI[$i]}")"
    done
    echo "$seq"
}
