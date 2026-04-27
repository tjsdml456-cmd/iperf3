#!/bin/bash
# iperf3 DSCP 시나리오 (DL 전용) — 단일 UDP 세션, 0.5초마다 DSCP 전환
#
# 패턴: 0->32->24->15->0 를 100주기 반복 (총 400 transitions)
# 시각: 0.5, 1.0, ..., 200.0초
#
# UE1: UDP + --dscp-change (커스텀 iperf_QoS-1: 최대 400전환)
# UE2/UE3: TCP -S 0 고정 (DL만)
#
# iperf3 -t 는 정수 초만 허용 -> 기본 TOTAL_DUR=201 (200초 이후 여유)

set -euo pipefail
export LC_ALL=C

UE1_IP=${UE1_IP:-10.45.0.2}
UE2_IP=${UE2_IP:-10.45.0.3}
UE3_IP=${UE3_IP:-10.45.0.4}

# 전환 간격(초)
STEP_SEC=${STEP_SEC:-0.5}

# 주기 수 / 전환 수
CYCLES=${CYCLES:-100}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=400

# 테스트 길이(정수 초): 마지막 전환 시각보다 커야 함.
TOTAL_DUR=${TOTAL_DUR:-201}

USE_RATE_CHANGE=${USE_RATE_CHANGE:-0}
UE1_FIXED_BITRATE=${UE1_FIXED_BITRATE:-20M}
RATE_BASE_M=${RATE_BASE_M:-20}

IPERF3_ENV=""
[ -n "${IPERF3_DSCP_DEBUG:-}" ] && IPERF3_ENV="IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG}"

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

LOG_FILE="/tmp/iperf3_dscp_100cycles_dl.log"
UE1_LOG="/tmp/iperf3_dscp_100cycles_dl_ue1.log"
UE2_LOG="/tmp/iperf3_dscp_100cycles_dl_ue2.log"
UE3_LOG="/tmp/iperf3_dscp_100cycles_dl_ue3.log"

log_event() {
    local msg="$1"
    local ts
    ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

show_progress() {
    local elapsed=$1
    local total=$2
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] 진행: [%-50s] %d%% (%d/%d초)" \
        "$(printf '#%.0s' $(seq 1 $((percent / 2))))" "$percent" "$elapsed" "$total"
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

build_rate_change_matched() {
    awk -v step="$STEP_SEC" -v n="$TRANSITIONS" -v base="$RATE_BASE_M" 'BEGIN {
        rlow = int(base / 10); if (rlow < 1) rlow = 1
        rmid = int(base / 20); if (rmid < 1) rmid = 1
        rhigh = int(base * 3 / 4); if (rhigh < 1) rhigh = 1
        printf "%dM", base
        for (i = 1; i <= n; i++) {
            m = i % 4
            if (m == 1)      rv = rlow "M"
            else if (m == 2) rv = rmid "M"
            else if (m == 3) rv = rhigh "M"
            else             rv = base "M"
            printf ",%.6f,%s", step * i, rv
        }
        printf "\n"
    }'
}

if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then
    echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS for current iperf build."
    echo "       Lower CYCLES/TRANSITIONS or raise IPERF_MAX_DSCP_TRANSITIONS in src/iperf.h."
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
    RATE_CHANGE_ARGS=$(build_rate_change_matched)
fi

echo "==========================================" > "$LOG_FILE"
echo "  iperf3 DSCP 100 cycles (DL, single UDP)" >> "$LOG_FILE"
echo "  시작: $(timestamp_us)" >> "$LOG_FILE"
echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR" >> "$LOG_FILE"
echo "  --dscp-change ${DSCP_CHANGE_ARGS}" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "=========================================="
echo "  iperf3 DSCP — ${STEP_SEC}s 간격 ${CYCLES}주기 (DL)"
echo "=========================================="
echo ""
echo "  UE1 (UDP): --dscp-change 한 세션 (${TRANSITIONS}회 전환)"
echo "    패턴: 0->32->24->15->0 반복"
echo "    마지막 전환 시각: ${LAST_CHANGE_TIME}s"
echo "  UE2/UE3 (TCP): -S 0, ${TOTAL_DUR}초"
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "  UE1: + --rate-change (전환 시각 동일)"
fi
echo ""
log_event "시작 USE_RATE_CHANGE=$USE_RATE_CHANGE"

echo "[$(timestamp)] 기존 iperf3 종료..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
log_event "기존 iperf3 종료 완료"

echo "[$(timestamp)] UE iperf3 서버 (DL 수신)"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || true
sleep 2

echo "=========================================="
echo "[$(timestamp)] 트래픽 시작 (${TOTAL_DUR}초) — DL"
echo "  UE1: --dscp-change \"${DSCP_CHANGE_ARGS}\""
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "       --rate-change \"${RATE_CHANGE_ARGS}\""
else
    echo "       -b ${UE1_FIXED_BITRATE} 고정"
fi
echo "  UE2/3: TCP -S 0"
echo "=========================================="
log_event "UE1 DL 시작 (단일 UDP, ${TRANSITIONS}전환)"

# UE2/UE3는 병행 트래픽 유지를 위해 백그라운드로 실행
iperf3 -c "$UE2_IP" -t "$TOTAL_DUR" -p 6501 -i 1 -S 0 > "$UE2_LOG" 2>&1 &
DL1_PID=$!
iperf3 -c "$UE3_IP" -t "$TOTAL_DUR" -p 6502 -i 1 -S 0 > "$UE3_LOG" 2>&1 &
DL2_PID=$!

echo "  DL PIDs: UE2=$DL1_PID UE3=$DL2_PID"
echo ""

# UE1은 백그라운드 실행(상세 출력은 파일로만 저장) + 1초 진행상황 표시
echo "[$(timestamp)] UE1 iperf3 상세 로그는 파일에 저장되고, 진행률만 표시합니다."
if [ "$USE_RATE_CHANGE" = "1" ]; then
    env ${IPERF3_ENV} iperf3 -c "$UE1_IP" -u -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        --rate-change "${RATE_CHANGE_ARGS}" \
        >"$UE1_LOG" 2>&1 &
else
    env ${IPERF3_ENV} iperf3 -c "$UE1_IP" -u -b "$UE1_FIXED_BITRATE" -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        >"$UE1_LOG" 2>&1 &
fi
DL0_PID=$!

for i in $(seq 1 "$TOTAL_DUR"); do
    if ! kill -0 "$DL0_PID" 2>/dev/null; then
        break
    fi
    show_progress "$i" "$TOTAL_DUR"
    sleep 1
done
printf "\n"

wait "$DL0_PID" 2>/dev/null || true

# UE2/UE3 종료 대기 (이미 끝났을 수도 있음)
wait "$DL1_PID" "$DL2_PID" 2>/dev/null || true

echo "[$(timestamp)] UE1 DSCP/Rate 로그 요약"
if grep -qi "Changed DSCP" "$UE1_LOG" 2>/dev/null; then
    echo "  Changed DSCP 줄 수: $(grep -ci "Changed DSCP" "$UE1_LOG")"
    grep -i "Changed DSCP" "$UE1_LOG" | sed 's/^/    /' | tee -a "$LOG_FILE"
else
    echo "  (Changed DSCP 없음 — -d 및 IPERF3_DSCP_DEBUG 확인)"
fi
if [ "$USE_RATE_CHANGE" = "1" ] && grep -qi "Changed rate" "$UE1_LOG" 2>/dev/null; then
    grep -i "Changed rate" "$UE1_LOG" | sed 's/^/    /' | tee -a "$LOG_FILE"
fi
echo ""

log_event "정리 (클라이언트/서버)"
kill "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

echo "=========================================="
echo "완료"
echo "  로그: $LOG_FILE"
echo "  UE1: $UE1_LOG"
echo "  UE2: $UE2_LOG"
echo "  UE3: $UE3_LOG"
echo "=========================================="
log_event "종료 $(timestamp_us)"
