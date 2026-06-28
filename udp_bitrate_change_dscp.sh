#!/bin/bash
# iperf3 DSCP 시나리오 (DL 전용) — UE1 UDP cycle + UE2/UE3 TCP background
#
# iperf3_dscp_100cycles_dl_ue1_only.sh 와 동일 + TCP 2개 (셀 용량 경쟁)
#
# 패턴: 0->32->24->15->0 반복 (UE1만, STEP_SEC마다)
# 타이밍 (iperf 내부 타이머 — t=0 = UE1 UDP connect 직후):
#   --dscp-change @ t = STEP_SEC * i
#   --rate-change @ 동일 t = STEP_SEC * i  (USE_RATE_CHANGE=1)
#   non-GBR (0/24): UE1_RATE_NON_GBR  |  GBR (32): UE1_RATE_GBR  |  DC-GBR (15): UE1_RATE_DC_GBR
# UE2/UE3: TCP 고정 DSCP (기본 0), UE1과 동시 fork (t=0 정렬)
#
# 커스텀 iperf3 (--dscp-change, --rate-change) 필요.

set -euo pipefail
export LC_ALL=C

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

STEP_SEC=${STEP_SEC:-0.5}
CYCLES=${CYCLES:-10}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=40

TOTAL_DUR=${TOTAL_DUR:-21}

USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}
UE1_FIXED_BITRATE=${UE1_FIXED_BITRATE:-10M}
UE1_UDP_LENGTH=${UE1_UDP_LENGTH:-1200}
UE1_RATE_NON_GBR=${UE1_RATE_NON_GBR:-0.5M}
UE1_RATE_GBR=${UE1_RATE_GBR:-6.5M}
UE1_RATE_DC_GBR=${UE1_RATE_DC_GBR:-3.5M}

UE2_DSCP=${UE2_DSCP:-0}
UE3_DSCP=${UE3_DSCP:-0}

dscp_to_tos_hex() {
    printf '0x%02x' $(($1 << 2))
}
UE2_TOS=$(dscp_to_tos_hex "$UE2_DSCP")
UE3_TOS=$(dscp_to_tos_hex "$UE3_DSCP")

export IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG:-1}

LOG_FILE="/tmp/iperf3_dscp_100cycles_dl.log"
UE1_LOG="/tmp/iperf3_dscp_100cycles_dl_ue1.log"
UE2_LOG="/tmp/iperf3_dscp_100cycles_dl_ue2.log"
UE3_LOG="/tmp/iperf3_dscp_100cycles_dl_ue3.log"

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

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
    awk -v step="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN {
        seq[0]=0; seq[1]=32; seq[2]=24; seq[3]=15
        printf "%d", seq[0]
        for (i = 1; i <= n; i++) {
            printf ",%.6f,%d", step * i, seq[i % 4]
        }
        printf "\n"
    }'
}

build_rate_change_by_dscp() {
    awk -v step="$STEP_SEC" -v n="$TRANSITIONS" \
        -v r0="$UE1_RATE_NON_GBR" -v r32="$UE1_RATE_GBR" -v r15="$UE1_RATE_DC_GBR" 'BEGIN {
        dscp[0]=0; dscp[1]=32; dscp[2]=24; dscp[3]=15
        rate[0]=r0; rate[24]=r0; rate[32]=r32; rate[15]=r15
        printf "%s", rate[dscp[0]]
        for (i = 1; i <= n; i++) {
            d = dscp[i % 4]
            printf ",%.6f,%s", step * i, rate[d]
        }
        printf "\n"
    }'
}

print_phase_timing_cheatsheet() {
    local pattern=(0 32 24 15) i idx d t r mac
    echo "  STEP=${STEP_SEC}s — dscp-change·rate-change 동일 t (UE1 iperf t=0)"
    echo "  t        DSCP  rate       기대 MAC"
    echo "  0.00     0     ${UE1_RATE_NON_GBR}    non-GBR"
    for i in 1 2 3 4; do
        idx=$((i % 4))
        d="${pattern[$idx]}"
        t=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.2f", s*n}')
        case "$d" in
            32) r="$UE1_RATE_GBR";     mac="~7M GBR" ;;
            15) r="$UE1_RATE_DC_GBR";  mac="~5M DC-GBR" ;;
            24) r="$UE1_RATE_NON_GBR"; mac="non-GBR (5QI80)" ;;
            *)  r="$UE1_RATE_NON_GBR"; mac="non-GBR" ;;
        esac
        printf "  %-8s %-5s %-9s %s\n" "$t" "$d" "$r" "$mac"
    done
}

dump_ue1_log() {
    echo "  --- $UE1_LOG ---"
    if [ -s "$UE1_LOG" ]; then
        sed 's/^/    /' "$UE1_LOG"
    else
        echo "    (비어 있음)"
    fi
}

if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then
    echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS for current iperf build."
    exit 1
fi

LAST_CHANGE_TIME=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
TOTAL_DUR_MIN=$(awk -v t="$LAST_CHANGE_TIME" 'BEGIN{printf "%d", int(t)+1}')
if [ "$TOTAL_DUR" -lt "$TOTAL_DUR_MIN" ]; then
    echo "ERROR: TOTAL_DUR=$TOTAL_DUR is too short. Need >= $TOTAL_DUR_MIN (last change at ${LAST_CHANGE_TIME}s)."
    exit 1
fi

DSCP_CHANGE_ARGS=$(build_dscp_change)
if [ "$USE_RATE_CHANGE" = "1" ]; then
    RATE_CHANGE_ARGS=$(build_rate_change_by_dscp)
    if ! "$IPERF3_BIN" --help 2>&1 | grep -q -- '--rate-change'; then
        echo "ERROR: USE_RATE_CHANGE=1 이지만 ${IPERF3_BIN} 에 --rate-change 가 없습니다."
        exit 1
    fi
fi

echo "==========================================" >"$LOG_FILE"
echo "  iperf3 DSCP cycles (DL, 3UE)" >>"$LOG_FILE"
echo "  시작: $(timestamp_us)" >>"$LOG_FILE"
echo "  IPERF3_BIN=$IPERF3_BIN STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR" >>"$LOG_FILE"
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
echo "  iperf3 DSCP — 3UE (${TOTAL_DUR}초)"
echo "=========================================="
echo ""
echo "  iperf3: ${IPERF3_BIN}"
echo "  UE1 (UDP): --dscp-change (${TRANSITIONS}회 전환)"
echo "    패턴: 0->32->24->15->0 반복 (STEP=${STEP_SEC}s)"
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "  + --rate-change (DSCP phase별 입력)"
    echo "    non-GBR(0/24)=${UE1_RATE_NON_GBR}  GBR(32)=${UE1_RATE_GBR}  dc-GBR(15)=${UE1_RATE_DC_GBR}"
    echo "    args: ${RATE_CHANGE_ARGS}"
else
    echo "  -b ${UE1_FIXED_BITRATE} 고정 (-l ${UE1_UDP_LENGTH})"
fi
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

echo "[$(timestamp)] UE iperf3 서버 (DL 수신)"
sudo ip netns exec ue1 "$IPERF3_BIN" -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 "$IPERF3_BIN" -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 "$IPERF3_BIN" -s -p 6502 -D 2>/dev/null || true
sleep 2

echo "=========================================="
echo "[$(timestamp)] 트래픽 시작 (${TOTAL_DUR}초) — DL"
echo "  UE1: --dscp-change \"${DSCP_CHANGE_ARGS}\""
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "       --rate-change \"${RATE_CHANGE_ARGS}\""
    echo "       -l ${UE1_UDP_LENGTH}"
else
    echo "       -b ${UE1_FIXED_BITRATE} -l ${UE1_UDP_LENGTH}"
fi
echo "  UE2: TCP -S ${UE2_TOS}  UE3: TCP -S ${UE3_TOS}"
echo "=========================================="
log_event "DL 시작 (UE1 cycle + UE2/UE3 TCP, 동시 fork)"

# UE1/2/3 동시 시작 → t=0 정렬 (DSCP/rate-change는 UE1 iperf 타이머)
if [ "$USE_RATE_CHANGE" = "1" ]; then
    env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \
        "$IPERF3_BIN" -c "$UE1_IP" -u -l "$UE1_UDP_LENGTH" -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        --rate-change "${RATE_CHANGE_ARGS}" \
        >"$UE1_LOG" 2>&1 &
else
    env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \
        "$IPERF3_BIN" -c "$UE1_IP" -u -b "$UE1_FIXED_BITRATE" -l "$UE1_UDP_LENGTH" \
        -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        >"$UE1_LOG" 2>&1 &
fi
UE1_PID=$!
"$IPERF3_BIN" -c "$UE2_IP" -t "$TOTAL_DUR" -p 6501 -i 1 -S "$UE2_TOS" >"$UE2_LOG" 2>&1 &
UE2_PID=$!
"$IPERF3_BIN" -c "$UE3_IP" -t "$TOTAL_DUR" -p 6502 -i 1 -S "$UE3_TOS" >"$UE3_LOG" 2>&1 &
UE3_PID=$!
TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "PIDs UE1=$UE1_PID UE2=$UE2_PID UE3=$UE3_PID"
log_event "트래픽 기준 EPOCH_NS: $TRAFFIC_START_EPOCH_NS"
log_event "throughput 추출: MAC-THP-DL / UE0(=UE1) UE1(=UE2) UE2(=UE3)"

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
set -e

if [ "$EARLY_EXIT" -eq 1 ] || [ "$UE1_RC" -ne 0 ]; then
    echo "[$(timestamp)] ERROR: iperf3 조기 종료 (UE1 rc=${UE1_RC}, UE2/3 rc=${TCP_RC})"
    dump_ue1_log | tee -a "$LOG_FILE"
    exit "${UE1_RC:-1}"
fi

echo "[$(timestamp)] UE1 DSCP/Rate 로그 요약"
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
echo "    python3 extract_throughput_log.py gnb.log --ue0 --ue1 --ue2 --bin-ms 500 --relative-time --start-time <시작>"
echo "  측정 구간 (phase 중앙):"
echo "    GBR(32)  ~7M: t in [1*STEP+0.1, 2*STEP-0.1]"
echo "    non-GBR(24)   : t in [2*STEP+0.1, 3*STEP-0.1]"
echo "    DC(15)   ~5M: t in [3*STEP+0.1, 4*STEP-0.1]"
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
echo "=========================================="
log_event "종료 $(timestamp_us)"
