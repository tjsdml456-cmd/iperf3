#!/bin/bash

# iperf3 DSCP 시나리오 (UL 전용) — UE1 UDP cycle + UE2/UE3 TCP background

#

# iperf3_dscp_100cycles_dl_ue1_only.sh 와 동일 + TCP 2개 (셀 용량 경쟁)

#

# 모드 1 (기본): DSCP_USE_SCHEDULE=1 — qos_schedule_dscp.csv 실측 시각·DSCP 재생

# 모드 2: DSCP_USE_SCHEDULE=0 — t=0 DSCP 0 → 이후 24/15/44 랜덤 (qos_random_common)

#   DSCP 24↔5QI 80 | DSCP 44↔5QI 66 | DSCP 15↔5QI 84 | DSCP 0↔5QI 9

# 타이밍 (iperf 내부 타이머 — t=0 = UE1 UDP connect 직후):

#   --dscp-change / --rate-change @ 스케줄 rel_time_s 또는 STEP_SEC*i

# UE2/UE3: TCP 고정 DSCP (기본 0), UE1과 동시 fork (t=0 정렬)

#

# 커스텀 iperf3 (--dscp-change, --rate-change) 필요.



set -euo pipefail

export LC_ALL=C



# UL에서는 UE namespace 안의 iperf3 client가 이 SERVER_IP(host/DN 쪽 iperf3 server)로 접속한다.

# 환경에 맞게 SERVER_IP를 바꿔서 실행: SERVER_IP=<host_or_dn_ip> bash iperf3_dscp_100cycles_ul.sh

SERVER_IP=${SERVER_IP:-10.45.0.1}



UE1_IP=${UE1_IP:-10.45.0.2}

UE2_IP=${UE2_IP:-10.45.0.3}

UE3_IP=${UE3_IP:-10.45.0.4}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -z "${IPERF3_BIN:-}" ]; then

    if [ -x "$SCRIPT_DIR/src/iperf3" ]; then

        IPERF3_BIN="$SCRIPT_DIR/src/iperf3"

    elif [ -x "$SCRIPT_DIR/../iperf_QoS-2/src/iperf3" ]; then

        IPERF3_BIN="$SCRIPT_DIR/../iperf_QoS-2/src/iperf3"

    else

        IPERF3_BIN=iperf3

    fi

fi



STEP_SEC=${STEP_SEC:-0.2}

CYCLES=${CYCLES:-30}

TRANS_PER_CYCLE=4

TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}

MAX_TRANSITIONS=120



TOTAL_DUR=${TOTAL_DUR:-26}



USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}

UE1_FIXED_BITRATE=${UE1_FIXED_BITRATE:-10M}

UE1_UDP_LENGTH=${UE1_UDP_LENGTH:-1200}

UE1_RATE_NON_GBR=${UE1_RATE_NON_GBR:-1.5M}

UE1_RATE_GBR=${UE1_RATE_GBR:-8M}

UE1_RATE_DC_GBR=${UE1_RATE_DC_GBR:-5M}



# shellcheck source=qos_random_common.sh

. "$SCRIPT_DIR/qos_random_common.sh"

DSCP_USE_SCHEDULE=${DSCP_USE_SCHEDULE:-1}

DSCP_SCHEDULE_FILE=${DSCP_SCHEDULE_FILE:-"$SCRIPT_DIR/qos_schedule_dscp.csv"}

QOS_RATE_NON_GBR=${QOS_RATE_NON_GBR:-$UE1_RATE_NON_GBR}

QOS_RATE_GBR=${QOS_RATE_GBR:-$UE1_RATE_GBR}

QOS_RATE_DC_GBR=${QOS_RATE_DC_GBR:-$UE1_RATE_DC_GBR}

QOS_RATE_INITIAL=${QOS_RATE_INITIAL:-$UE1_RATE_NON_GBR}

UE2_DSCP=${UE2_DSCP:-0}

UE3_DSCP=${UE3_DSCP:-0}



dscp_to_tos_hex() {

    printf '0x%02x' $(($1 << 2))

}

UE2_TOS=$(dscp_to_tos_hex "$UE2_DSCP")

UE3_TOS=$(dscp_to_tos_hex "$UE3_DSCP")



export IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG:-1}



LOG_FILE="/tmp/iperf3_dscp_100cycles_ul.log"

UE1_LOG="/tmp/iperf3_dscp_100cycles_ul_ue1.log"

UE2_LOG="/tmp/iperf3_dscp_100cycles_ul_ue2.log"

UE3_LOG="/tmp/iperf3_dscp_100cycles_ul_ue3.log"

DSCP_WALLCLOCK_LOG="/tmp/iperf3_dscp_100cycles_ul_wallclock.txt"

DSCP_WALLCLOCK_PID=""



wallclock_us() {

    local ns

    ns=$(date '+%N' 2>/dev/null || echo 0)

    printf '%s.%06d' "$(date '+%H:%M:%S')" $((10#$ns / 1000))

}



# iperf debug logs TOS (= DSCP*4) on the wire; map back to DSCP 9/0/44/24/15.

_normalize_dscp_value() {

    local v=$1 dscp

    [ -n "$v" ] || return 0

    case "$v" in

        0|36)   dscp=9 ;;

        9|15|24|44) dscp=$v ;;

        60)   dscp=15 ;;

        96)   dscp=24 ;;

        176)  dscp=44 ;;

        *)

            if [ "$((v % 4))" -eq 0 ]; then

                dscp=$((v / 4))

            else

                dscp=$v

            fi

            if [ "$dscp" -eq 0 ]; then

                dscp=9

            fi

            ;;

    esac

    printf '%s' "$dscp"

}



_dscp_from_iperf_line() {

    local line=$1 v

    # Prefer the *new* value after "Changed ... to N" (often TOS, e.g. 176 -> DSCP 44).

    v=$(printf '%s\n' "$line" | sed -n 's/.*[Cc]hanged[^0-9]*.*\b[Tt][Oo]\b[= ]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)

    if [ -z "$v" ]; then

        v=$(printf '%s\n' "$line" | sed -n 's/.*\b[Tt][Oo][Ss]\b[= ]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)

    fi

    if [ -z "$v" ]; then

        v=$(printf '%s\n' "$line" | sed -n 's/.*[Dd][Ss][Cc][Pp][^0-9]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)

    fi

    if [ -z "$v" ]; then

        v=$(printf '%s\n' "$line" | grep -oE '[0-9]+' | tail -n 1)

    fi

    _normalize_dscp_value "$v"

}



get_initial_dscp() {

    local d

    d=$(printf '%s' "$DSCP_CHANGE_ARGS" | awk -F, '{print $1}')

    _normalize_dscp_value "$d"

}



# t=0 initial DSCP is not logged by iperf (only logs on *change*); record explicitly.

record_initial_dscp_wallclock() {

    local d=$1 out=$2 ts

    d=$(_normalize_dscp_value "$d")

    [ -n "$d" ] || return 0

    ts=$(wallclock_us)

    printf '%s,%s\n' "$ts" "$d" >>"$out"

    log_event "초기 DSCP wall-clock: ${ts},${d} (t=0 — iperf는 Changed 미출력)"

}



start_dscp_wallclock_monitor() {

    local iperf_log=$1 out=${2:-$DSCP_WALLCLOCK_LOG}

    stop_dscp_wallclock_monitor 2>/dev/null || true

    : >"$out"

    printf '%s\n' '# wall_time,dscp' >>"$out"

    (

        while [ ! -f "$iperf_log" ]; do sleep 0.05; done

        tail -n 0 -F "$iperf_log" 2>/dev/null | while IFS= read -r line; do

            case "$line" in

                *[Cc]hanged\ [Dd][Ss][Cc][Pp]*|*[Cc]hanged\ DSCP*)

                    d=$(_dscp_from_iperf_line "$line")

                    [ -n "$d" ] || continue

                    printf '%s,%s\n' "$(wallclock_us)" "$d" >>"$out"

                    ;;

            esac

        done

    ) &

    DSCP_WALLCLOCK_PID=$!

}



stop_dscp_wallclock_monitor() {

    if [ -n "${DSCP_WALLCLOCK_PID:-}" ] && kill -0 "$DSCP_WALLCLOCK_PID" 2>/dev/null; then

        kill "$DSCP_WALLCLOCK_PID" 2>/dev/null || true

        wait "$DSCP_WALLCLOCK_PID" 2>/dev/null || true

    fi

    DSCP_WALLCLOCK_PID=""

}



summarize_dscp_wallclock_log() {

    local out=${1:-$DSCP_WALLCLOCK_LOG}

    echo "  DSCP wall-clock: $out"

    if [ ! -s "$out" ]; then

        echo "    (비어 있음 — IPERF3_DSCP_DEBUG=1 및 Changed DSCP 로그 확인)"

        return

    fi

    grep -v '^#' "$out" | sed 's/^/    /'

}



timestamp() { date '+%H:%M:%S'; }

timestamp_us() { wallclock_us; }



log_event() {

    local msg="$1"

    echo "[$(timestamp_us)] $msg" | tee -a "$LOG_FILE"

}



show_progress() {

    local elapsed=$1

    local total=$2

    local percent=$((elapsed * 100 / total))

    printf "\r[$(timestamp)] 진행: [%-50s] %d%% (%d/%d초)" \

        "$(printf '#%.0s' $(seq 1 $((percent / 2)) 2>/dev/null))" "$percent" "$elapsed" "$total"

}



summarize_iperf_log() {

    local label=$1 file=$2

    echo "  [$label] $file"

    if [ ! -s "$file" ]; then

        echo "    (로그 없음)"

        return

    fi

    grep -iE '\[.*\].* (sender|receiver)' "$file" 2>/dev/null | tail -n 2 | sed 's/^/    /' || \

        tail -n 5 "$file" | sed 's/^/    /'

}



build_dscp_change() {

    local i d

    if [ "$QOS_USE_SCHEDULE" = "1" ] && [ "$QOS_SCHEDULE_MODE" = "dscp" ]; then

        d=$(schedule_dscp_at 0)

        printf "%d" "$d"

        for i in $(seq 1 $((QOS_SCHEDULE_N - 1))); do

            d=$(schedule_dscp_at "$i")

            awk -v t="$(schedule_rel_time_at "$i")" -v d="$d" \

                'BEGIN{printf ",%.6f,%d", t+0, d}'

        done

        printf "\n"

        return

    fi

    printf "%d" "$(dscp_for_step 0)"

    for i in $(seq 1 "$TRANSITIONS"); do

        d=$(dscp_for_step "$i")

        awk -v s="$STEP_SEC" -v n="$i" -v d="$d" \

            'BEGIN{printf ",%.6f,%d", s*n, d}'

    done

    printf "\n"

}



build_rate_change_by_qos() {

    local i d r

    if [ "$QOS_USE_SCHEDULE" = "1" ] && [ "$QOS_SCHEDULE_MODE" = "dscp" ]; then

        r=$(rate_for_dscp "$(schedule_dscp_at 0)")

        printf "%s" "$r"

        for i in $(seq 1 $((QOS_SCHEDULE_N - 1))); do

            r=$(rate_for_dscp "$(schedule_dscp_at "$i")")

            awk -v t="$(schedule_rel_time_at "$i")" -v rate="$r" \

                'BEGIN{printf ",%.6f,%s", t+0, rate}'

        done

        printf "\n"

        return

    fi

    r=$(rate_for_step 0)

    printf "%s" "$r"

    for i in $(seq 1 "$TRANSITIONS"); do

        r=$(rate_for_step "$i")

        awk -v s="$STEP_SEC" -v n="$i" -v rate="$r" \

            'BEGIN{printf ",%.6f,%s", s*n, rate}'

    done

    printf "\n"

}



print_phase_timing_cheatsheet() {

    local i d t r mac q show_n

    if [ "$QOS_USE_SCHEDULE" = "1" ] && [ "$QOS_SCHEDULE_MODE" = "dscp" ]; then

        show_n=$QOS_SCHEDULE_N

        if [ "$show_n" -gt 12 ]; then

            show_n=12

        fi

        echo "  스케줄: ${DSCP_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"

        echo "  t        DSCP  5QI  rate       기대 MAC"

        for i in $(seq 0 $((show_n - 1))); do

            d=$(schedule_dscp_at "$i")

            q=$(dscp_to_five_qi "$d")

            t=$(schedule_rel_time_at "$i")

            r=$(rate_for_dscp "$d")

            case "$d" in

                44) mac="~7M GBR" ;;

                15) mac="~4M DC-GBR" ;;

                24) mac="pdb-only (5QI80)" ;;

                *)  mac="non-GBR" ;;

            esac

            printf "  %-8s %-5s %-4s %-9s %s\n" "$t" "$d" "$q" "$r" "$mac"

        done

        if [ "$QOS_SCHEDULE_N" -gt 12 ]; then

            echo "  ... (${QOS_SCHEDULE_N} schedule points total)"

        fi

        return

    fi

    show_n=$TRANSITIONS

    if [ "$show_n" -gt 8 ]; then

        show_n=8

    fi

    echo "  STEP=${STEP_SEC}s — dscp-change·rate-change 동일 t (UE1 iperf t=0)"

    echo "  t        DSCP  5QI  rate       기대 MAC"

    d=$(dscp_for_step 0)

    q=$(five_qi_for_step 0)

    r=$(rate_for_step 0)

    printf "  %-8s %-5s %-4s %-9s %s\n" "0.00" "$d" "$q" "$r" "초기 (5QI9)"

    for i in $(seq 1 "$show_n"); do

        d=$(dscp_for_step "$i")

        q=$(five_qi_for_step "$i")

        t=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.2f", s*n}')

        r=$(rate_for_step "$i")

        case "$d" in

            44) mac="~7M GBR" ;;

            15) mac="~4M DC-GBR" ;;

            24) mac="pdb-only (5QI80)" ;;

            *)  mac="non-GBR" ;;

        esac

        printf "  %-8s %-5s %-4s %-9s %s\n" "$t" "$d" "$q" "$r" "$mac"

    done

    if [ "$TRANSITIONS" -gt 8 ]; then

        echo "  ... (${TRANSITIONS} transitions total, RANDOM_SEED=${RANDOM_SEED:-auto})"

    fi

}

dump_ue1_log() {

    echo "  --- $UE1_LOG ---"

    if [ -s "$UE1_LOG" ]; then

        sed 's/^/    /' "$UE1_LOG"

    else

        echo "    (비어 있음)"

    fi

}



if [ "$DSCP_USE_SCHEDULE" = "1" ] && [ -f "$DSCP_SCHEDULE_FILE" ]; then

    load_dscp_schedule_file "$DSCP_SCHEDULE_FILE"

    LAST_CHANGE_TIME=$(schedule_rel_time_at $((QOS_SCHEDULE_N - 1)))

else

    DSCP_USE_SCHEDULE=0

    if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then

        echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS for current iperf build."

        exit 1

    fi

    generate_qos_index_sequence

    LAST_CHANGE_TIME=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')

fi



if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then

    echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS for current iperf build."

    exit 1

fi



TOTAL_DUR_MIN=$(awk -v t="$LAST_CHANGE_TIME" 'BEGIN{printf "%d", int(t)+1}')

if [ "$TOTAL_DUR" -lt "$TOTAL_DUR_MIN" ]; then

    echo "ERROR: TOTAL_DUR=$TOTAL_DUR is too short. Need >= $TOTAL_DUR_MIN (last change at ${LAST_CHANGE_TIME}s)."

    exit 1

fi



DSCP_CHANGE_ARGS=$(build_dscp_change)

if [ "$USE_RATE_CHANGE" = "1" ]; then

    RATE_CHANGE_ARGS=$(build_rate_change_by_qos)

    if ! "$IPERF3_BIN" --help 2>&1 | grep -q -- '--rate-change'; then

        echo "ERROR: USE_RATE_CHANGE=1 이지만 ${IPERF3_BIN} 에 --rate-change 가 없습니다."

        exit 1

    fi

fi



echo "==========================================" >"$LOG_FILE"

echo "  iperf3 DSCP cycles (UL, 3UE)" >>"$LOG_FILE"

echo "  시작: $(timestamp_us)" >>"$LOG_FILE"

echo "  IPERF3_BIN=$IPERF3_BIN STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR" >>"$LOG_FILE"

if [ "$QOS_USE_SCHEDULE" = "1" ] && [ "$QOS_SCHEDULE_MODE" = "dscp" ]; then

    echo "  DSCP_USE_SCHEDULE=1 file=${DSCP_SCHEDULE_FILE}" >>"$LOG_FILE"

    echo "  DSCP 시퀀스: $(print_dscp_schedule_sequence)" >>"$LOG_FILE"

    echo "  5QI 대응: $(print_5qi_schedule_sequence)" >>"$LOG_FILE"

else

    echo "  RANDOM_SEED=$RANDOM_SEED (file=$QOS_RANDOM_SEED_FILE)" >>"$LOG_FILE"

    echo "  DSCP 시퀀스: $(print_dscp_sequence_from_idx)" >>"$LOG_FILE"

    echo "  5QI 대응: $(print_5qi_sequence_from_idx)" >>"$LOG_FILE"

    print_qos_pairing_check >>"$LOG_FILE"

fi

echo "  --dscp-change ${DSCP_CHANGE_ARGS}" >>"$LOG_FILE"

if [ "$USE_RATE_CHANGE" = "1" ]; then

    echo "  --rate-change ${RATE_CHANGE_ARGS}" >>"$LOG_FILE"

fi

echo "  UE2 TCP DSCP=${UE2_DSCP} TOS=${UE2_TOS}" >>"$LOG_FILE"

echo "  UE3 TCP DSCP=${UE3_DSCP} TOS=${UE3_TOS}" >>"$LOG_FILE"

print_phase_timing_cheatsheet >>"$LOG_FILE"

echo "==========================================" >>"$LOG_FILE"

echo "" >>"$LOG_FILE"



echo "=========================================="

echo "  iperf3 DSCP UL — 3UE (${TOTAL_DUR}초)"

echo "=========================================="

echo ""

echo "  iperf3: ${IPERF3_BIN}"

echo "  UE1 UL (UDP): --dscp-change (${TRANSITIONS}회 전환)"

if [ "$QOS_USE_SCHEDULE" = "1" ] && [ "$QOS_SCHEDULE_MODE" = "dscp" ]; then

    echo "    스케줄: ${DSCP_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"

    echo "    DSCP: $(print_dscp_schedule_sequence)"

else

    echo "    t=0 DSCP 0 → 이후 24/15/44 랜덤 (STEP=${STEP_SEC}s)"

    echo "    시퀀스: $(print_dscp_sequence_from_idx)"

fi

if [ "$USE_RATE_CHANGE" = "1" ]; then

    echo "  + --rate-change (QoS phase별 입력)"

    echo "    초기(0)=${QOS_RATE_INITIAL}  pdb-only(24)=${UE1_RATE_NON_GBR}  GBR(44)=${UE1_RATE_GBR}  DC-GBR(15)=${UE1_RATE_DC_GBR}"

    echo "    args: ${RATE_CHANGE_ARGS}"

else

    echo "  -b ${UE1_FIXED_BITRATE} 고정 (-l ${UE1_UDP_LENGTH})"

fi

echo "  SERVER_IP=${SERVER_IP}"

echo "  UE2 (TCP): DSCP ${UE2_DSCP} -S ${UE2_TOS}"

echo "  UE3 (TCP): DSCP ${UE3_DSCP} -S ${UE3_TOS}"

echo "  셀 max ≈ 15M | UE2/UE3가 용량 경쟁"

echo ""

echo "  [타이밍 치트시트 — 1사이클]"

print_phase_timing_cheatsheet

echo ""

log_event "시작 USE_RATE_CHANGE=$USE_RATE_CHANGE"



echo "[$(timestamp)] 기존 iperf3 종료..."

{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

sleep 1

log_event "기존 iperf3 종료 완료"



echo "[$(timestamp)] host/DN iperf3 서버 시작 (UL 수신)"

"$IPERF3_BIN" -s -p 6500 -D 2>/dev/null || true

"$IPERF3_BIN" -s -p 6501 -D 2>/dev/null || true

"$IPERF3_BIN" -s -p 6502 -D 2>/dev/null || true

sleep 2



echo "=========================================="

echo "[$(timestamp)] 트래픽 시작 (${TOTAL_DUR}초) — UL"

echo "  UE1: --dscp-change \"${DSCP_CHANGE_ARGS}\""

if [ "$USE_RATE_CHANGE" = "1" ]; then

    echo "       --rate-change \"${RATE_CHANGE_ARGS}\""

    echo "       -l ${UE1_UDP_LENGTH}"

else

    echo "       -b ${UE1_FIXED_BITRATE} -l ${UE1_UDP_LENGTH}"

fi

echo "  SERVER_IP=${SERVER_IP}"

echo "  UE2: TCP -S ${UE2_TOS}  UE3: TCP -S ${UE3_TOS}"

echo "=========================================="

log_event "UL 시작 (UE1 cycle + UE2/UE3 TCP, 동시 fork)"



# DSCP 변경 시 벽시계 시각 기록 (03:44:30.590756,dscp)

: >"$UE1_LOG"

start_dscp_wallclock_monitor "$UE1_LOG" "$DSCP_WALLCLOCK_LOG"

log_event "DSCP wall-clock monitor -> $DSCP_WALLCLOCK_LOG"



# UE1/2/3 동시 시작 → t=0 정렬 (DSCP/rate-change는 UE1 iperf 타이머)

if [ "$USE_RATE_CHANGE" = "1" ]; then

    sudo ip netns exec ue1 env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \

        "$IPERF3_BIN" -c "$SERVER_IP" -u -l "$UE1_UDP_LENGTH" -t "$TOTAL_DUR" -p 6500 -i 1 -d \

        --dscp-change "${DSCP_CHANGE_ARGS}" \

        --rate-change "${RATE_CHANGE_ARGS}" \

        >"$UE1_LOG" 2>&1 &

else

    sudo ip netns exec ue1 env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \

        "$IPERF3_BIN" -c "$SERVER_IP" -u -b "$UE1_FIXED_BITRATE" -l "$UE1_UDP_LENGTH" \

        -t "$TOTAL_DUR" -p 6500 -i 1 -d \

        --dscp-change "${DSCP_CHANGE_ARGS}" \

        >"$UE1_LOG" 2>&1 &

fi

UE1_PID=$!

sudo ip netns exec ue2 "$IPERF3_BIN" -c "$SERVER_IP" -t "$TOTAL_DUR" -p 6501 -i 1 -S "$UE2_TOS" >"$UE2_LOG" 2>&1 &

UE2_PID=$!

sudo ip netns exec ue3 "$IPERF3_BIN" -c "$SERVER_IP" -t "$TOTAL_DUR" -p 6502 -i 1 -S "$UE3_TOS" >"$UE3_LOG" 2>&1 &

UE3_PID=$!

TRAFFIC_START_EPOCH_NS=$(date +%s%N)

record_initial_dscp_wallclock "$(get_initial_dscp)" "$DSCP_WALLCLOCK_LOG"

log_event "PIDs UE1=$UE1_PID UE2=$UE2_PID UE3=$UE3_PID"

log_event "트래픽 기준 EPOCH_NS: $TRAFFIC_START_EPOCH_NS"

log_event "throughput 추출: MAC-THP-UL / UE0(=UE1) UE1(=UE2) UE2(=UE3)"



echo "[$(timestamp)] UE1 iperf3 상세 로그는 파일에 저장되고, 진행률만 표시합니다."



EARLY_EXIT=0

for i in $(seq 1 "$TOTAL_DUR"); do

    if ! kill -0 "$UE1_PID" 2>/dev/null; then

        EARLY_EXIT=1

        break

    fi

    if ! kill -0 "$UE2_PID" 2>/dev/null || ! kill -0 "$UE3_PID" 2>/dev/null; then

        EARLY_EXIT=1

        break

    fi

    show_progress "$i" "$TOTAL_DUR"

    sleep 1

done

printf "\n"



set +e

wait "$UE1_PID"

UE1_RC=$?

wait "$UE2_PID" "$UE3_PID"

TCP_RC=$?

stop_dscp_wallclock_monitor

set -e



if [ "$EARLY_EXIT" -eq 1 ] || [ "$UE1_RC" -ne 0 ]; then

    echo "[$(timestamp)] ERROR: iperf3 조기 종료 (UE1 rc=${UE1_RC}, UE2/3 rc=${TCP_RC})"

    dump_ue1_log | tee -a "$LOG_FILE"

    exit "${UE1_RC:-1}"

fi



echo "[$(timestamp)] UE1 DSCP/Rate 로그 요약"

summarize_dscp_wallclock_log "$DSCP_WALLCLOCK_LOG" | tee -a "$LOG_FILE"

if grep -qi "Changed DSCP" "$UE1_LOG" 2>/dev/null; then

    echo "  Changed DSCP 줄 수: $(grep -ci "Changed DSCP" "$UE1_LOG")"

    grep -i "Changed DSCP" "$UE1_LOG" | sed 's/^/    /' | tee -a "$LOG_FILE"

fi

if [ "$USE_RATE_CHANGE" = "1" ] && grep -qi "Changed rate" "$UE1_LOG" 2>/dev/null; then

    echo "  Changed rate 줄 수: $(grep -ci "Changed rate" "$UE1_LOG")"

    grep -i "Changed rate" "$UE1_LOG" | sed 's/^/    /' | tee -a "$LOG_FILE"

elif [ "$USE_RATE_CHANGE" = "1" ]; then

    echo "  ERROR: Changed rate 없음 — --rate-change 미적용 또는 iperf 재빌드 필요"

    grep -i "RATE_TIMER" "$UE1_LOG" 2>/dev/null | head -3 | sed 's/^/    /' || true

fi



echo ""

echo "[$(timestamp)] iperf3 결과 요약"

summarize_iperf_log "UE1 UDP QoS cycle" "$UE1_LOG" | tee -a "$LOG_FILE"

summarize_iperf_log "UE2 TCP DSCP${UE2_DSCP}" "$UE2_LOG" | tee -a "$LOG_FILE"

summarize_iperf_log "UE3 TCP DSCP${UE3_DSCP}" "$UE3_LOG" | tee -a "$LOG_FILE"

echo ""

echo "  gNB throughput (STEP=${STEP_SEC}, t=0 = EPOCH_NS in log):"

echo "    python3 extract_throughput_log.py gnb.log --ue0 --ue1 --ue2 --bin-ms 500 --relative-time --start-time <시작>  # UL 로그 기준 옵션 확인"

echo "  측정 구간 (phase 중앙, STEP=${STEP_SEC}):"

echo "    GBR(44)  ~7M: t in [i*STEP+0.1, (i+1)*STEP-0.1] when DSCP=44"

echo "    pdb-only(24)   : t in [...] when DSCP=24"

echo "    DC(15)   ~4M: t in [...] when DSCP=15"

echo ""



log_event "정리 (클라이언트/서버)"

kill "$UE1_PID" "$UE2_PID" "$UE3_PID" 2>/dev/null || true

sleep 1

{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1



echo "=========================================="

echo "완료"

echo "  로그: $LOG_FILE"

echo "  UE1: $UE1_LOG"

echo "  UE2: $UE2_LOG"

echo "  UE3: $UE3_LOG"

echo "  DSCP wall-clock: $DSCP_WALLCLOCK_LOG"

echo "=========================================="

log_event "종료 $(timestamp_us)"
