# Shared random / fixed QoS schedule for paired PCF(5QI) / DSCP experiments.
# Source this file from iperf scenario scripts.

QOS_RANDOM_SEED_FILE=${QOS_RANDOM_SEED_FILE:-/tmp/qos_random_seed}
QOS_WINDOW_SEC=${QOS_WINDOW_SEC:-20}
QOS_MAX_CONSECUTIVE=${QOS_MAX_CONSECUTIVE:-2}
QOS_POOL_SIZE=3
QOS_IDX_SEQ=()
QOS_IDX_SEQ_GENERATED=0

QOS_RATE_GBR=${QOS_RATE_GBR:-7M}
QOS_RATE_DC_GBR=${QOS_RATE_DC_GBR:-4M}
QOS_RATE_NON_GBR=${QOS_RATE_NON_GBR:-0.5M}
QOS_RATE_INITIAL=${QOS_RATE_INITIAL:-0.5M}

QOS_INITIAL_5QI=${QOS_INITIAL_5QI:-9}
QOS_INITIAL_DSCP=${QOS_INITIAL_DSCP:-0}

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
    local W c missing
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
    local attempt=0

    if [ "$QOS_IDX_SEQ_GENERATED" = "1" ]; then
        return 0
    fi
    init_qos_random_seed

    local W
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

five_qi_to_dscp() {
    case "$1" in
        80) echo 24 ;;
        66) echo 44 ;;
        84) echo 15 ;;
        9)  echo 0 ;;
        *)  echo 0 ;;
    esac
}

dscp_to_five_qi() {
    # Strip CR (Windows CSV) / spaces so "9\r" does not fall through to default 80.
    local d="${1%%$'\r'}"
    d="${d#"${d%%[![:space:]]*}"}"
    d="${d%"${d##*[![:space:]]}"}"
    case "$d" in
        24) echo 80 ;;
        44) echo 66 ;;
        15) echo 84 ;;
        0|9) echo 9 ;;
        *)  echo 80 ;;
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
        1) echo "$QOS_RATE_GBR" ;;
        2) echo "$QOS_RATE_DC_GBR" ;;
        *) echo "$QOS_RATE_NON_GBR" ;;
    esac
}

rate_for_dscp() {
    local d="${1%%$'\r'}"
    d="${d#"${d%%[![:space:]]*}"}"
    d="${d%"${d##*[![:space:]]}"}"
    case "$d" in
        44) echo "$QOS_RATE_GBR" ;;
        15) echo "$QOS_RATE_DC_GBR" ;;
        0|9) echo "$QOS_RATE_INITIAL" ;;
        *)  echo "$QOS_RATE_NON_GBR" ;;
    esac
}

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
        echo "$QOS_RATE_INITIAL"
    else
        rate_for_qos_idx "${QOS_IDX_SEQ[$((step - 1))]}"
    fi
}

# --- Fixed schedule replay ---
QOS_USE_SCHEDULE=0
QOS_SCHEDULE_MODE=""
QOS_SCHEDULE_REL=()
QOS_SCHEDULE_DSCP=()
QOS_SCHEDULE_5QI=()
QOS_SCHEDULE_N=0

load_qos_schedule_file() {
    local f=$1 line t q n=0 col=dscp
    if [ ! -f "$f" ]; then
        echo "ERROR: QoS schedule file not found: $f" >&2
        exit 1
    fi
    QOS_SCHEDULE_REL=()
    QOS_SCHEDULE_DSCP=()
    QOS_SCHEDULE_5QI=()
    while IFS= read -r line || [ -n "$line" ]; do
        # Allow commented headers: "# rel_time_s,five_qi"
        line="${line%%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            '#'*)
                line="${line#\#}"
                line="${line#"${line%%[![:space:]]*}"}"
                case "$line" in
                    rel_time_s,dscp) col=dscp; continue ;;
                    rel_time_s,five_qi) col=five_qi; continue ;;
                esac
                continue
                ;;
        esac
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in
            rel_time_s,dscp) col=dscp; continue ;;
            rel_time_s,five_qi) col=five_qi; continue ;;
            rel_time_s,*|time_s,*|t,*|rel_time,*) continue ;;
        esac
        t="${line%%,*}"
        q="${line##*,}"
        t="${t%%$'\r'}"
        q="${q%%$'\r'}"
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        q="${q#"${q%%[![:space:]]*}"}"
        q="${q%"${q##*[![:space:]]}"}"
        if ! awk -v t="$t" 'BEGIN{exit !(t+0==t)}'; then
            echo "ERROR: invalid schedule time: $line" >&2
            exit 1
        fi
        QOS_SCHEDULE_REL[$n]=$t
        if [ "$col" = "dscp" ]; then
            QOS_SCHEDULE_DSCP[$n]=$q
            QOS_SCHEDULE_5QI[$n]=$(dscp_to_five_qi "$q")
        else
            QOS_SCHEDULE_5QI[$n]=$q
            QOS_SCHEDULE_DSCP[$n]=$(five_qi_to_dscp "$q")
        fi
        n=$((n + 1))
    done <"$f"
    if [ "$n" -lt 1 ]; then
        echo "ERROR: empty QoS schedule: $f" >&2
        exit 1
    fi
    QOS_SCHEDULE_N=$n
    QOS_USE_SCHEDULE=1
    QOS_SCHEDULE_MODE=$col
    QOS_IDX_SEQ_GENERATED=1
    TRANSITIONS=$((n - 1))
}

load_dscp_schedule_file() {
    load_qos_schedule_file "$1"
    QOS_SCHEDULE_MODE=dscp
}

schedule_dscp_at() {
    echo "${QOS_SCHEDULE_DSCP[$1]}"
}

schedule_five_qi_at() {
    echo "${QOS_SCHEDULE_5QI[$1]}"
}

schedule_rel_time_at() {
    echo "${QOS_SCHEDULE_REL[$1]}"
}

# iperf3 --dscp-change: initial_dscp,t1,dscp1,t2,dscp2,...
build_dscp_change_from_schedule() {
    local i initial next_t next_d out
    initial=${QOS_SCHEDULE_DSCP[0]}
    out="$initial"
    for ((i = 1; i < QOS_SCHEDULE_N; i++)); do
        next_t=${QOS_SCHEDULE_REL[$i]}
        next_d=${QOS_SCHEDULE_DSCP[$i]}
        out="${out},${next_t},${next_d}"
    done
    echo "$out"
}

# iperf3 --rate-change: initial_rate,t1,rate1,...
build_rate_change_from_schedule() {
    local i initial next_t next_r out
    initial=$(rate_for_dscp "${QOS_SCHEDULE_DSCP[0]}")
    out="$initial"
    for ((i = 1; i < QOS_SCHEDULE_N; i++)); do
        next_t=${QOS_SCHEDULE_REL[$i]}
        next_r=$(rate_for_dscp "${QOS_SCHEDULE_DSCP[$i]}")
        out="${out},${next_t},${next_r}"
    done
    echo "$out"
}

schedule_last_change_time() {
    echo "${QOS_SCHEDULE_REL[$((QOS_SCHEDULE_N - 1))]}"
}

print_dscp_schedule_sequence() {
    local i seq=""
    for i in $(seq 0 $((QOS_SCHEDULE_N - 1))); do
        if [ -n "$seq" ]; then
            seq="${seq} -> "
        fi
        seq="${seq}${QOS_SCHEDULE_DSCP[$i]}@${QOS_SCHEDULE_REL[$i]}s"
    done
    echo "$seq"
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

print_qos_pairing_check() {
    echo "  매핑: 5QI 80↔DSCP 24 (0.5M) | 5QI 66↔DSCP 44 (7M) | 5QI 84↔DSCP 15 (4M) | 5QI 9↔DSCP 0"
}

print_dscp_sequence_from_idx() {
    local i seq
    seq=$(dscp_for_step 0)
    for i in $(seq 1 "$TRANSITIONS"); do
        seq="${seq} -> $(dscp_for_step "$i")"
    done
    echo "$seq"
}

print_5qi_sequence_from_idx() {
    local i seq
    seq=$(five_qi_for_step 0)
    for i in $(seq 1 "$TRANSITIONS"); do
        seq="${seq} -> $(five_qi_for_step "$i")"
    done
    echo "$seq"
}
