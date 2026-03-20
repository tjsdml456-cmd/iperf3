#!/bin/bash
# iperf3 DSCP Traffic Scenario (--dscp-change, --rate-change 사용) — DL 전용
# UE1: UDP, DSCP 0→44→24→15, 20·40·60초에 변경, 총 80초
#   DSCP: 0~20초=0, 20~40초=44, 40~60초=24, 60~80초=15
#   Rate: 0~40초=20M, 40~60초=1M, 60~80초=15M
# UE2/UE3: TCP, DSCP=0 고정 (DL만)

# set -e 제거 (에러가 발생해도 계속 진행)

EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# USE_RATE_CHANGE=0 이면 UE1은 --dscp-change만 (고정 10M). 60초에 rate 변경 없이 DSCP만 바꿔서 dl_bs=0 원인 구분용.
USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}

# IPERF3_DSCP_DEBUG=1 이면 iperf3에 전달. sudo/netns 사용 시 env로 명시해서 전달 (sudo는 기본적으로 환경변수 미전달).
IPERF3_ENV=""
[ -n "${IPERF3_DSCP_DEBUG}" ] && IPERF3_ENV="IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG}"

# 시나리오: DSCP 0→44→24→15, 20·40·60초에 변경, 총 80초
TOTAL_DUR=80
DSCP_CHANGE_ARGS="0,20,44,40,24,60,15"
RATE_CHANGE_ARGS="10M,20,20M,40,1M,60,15M"

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

LOG_FILE="/tmp/iperf3_dscp_traffic_scenario.log"
log_event() {
    local msg="$1"
    local ts
    ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}
show_progress() {
    local phase=$1
    local elapsed=$2
    local total=$3
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] 진행 중: [%-50s] %d%% (%d/%d초)" \
        "$(printf '#%.0s' $(seq 1 $((percent/2))))" "$percent" "$elapsed" "$total"
}

echo "==========================================" > "$LOG_FILE"
echo "  iperf3 DSCP Traffic Scenario (--dscp-change)" >> "$LOG_FILE"
echo "  시작 시간: $(timestamp_us)" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "=========================================="
echo "  iperf3 DSCP Traffic Scenario"
echo "  (--dscp-change 사용, UDP)"
echo "=========================================="
echo ""
echo "[$(timestamp)] 시나리오:"
if [ "$USE_RATE_CHANGE" = "0" ]; then
    echo "  - UE1 (UDP): --dscp-change만 (고정 10M)"
else
    echo "  - UE1 (UDP): --dscp-change + --rate-change"
    echo "    Rate: 0~40초=20M, 40~60초=1M, 60~80초=15M"
fi
echo "    DSCP: 0~20초=0, 20~40초=44, 40~60초=24, 60~80초=15"
echo "  - UE2/UE3 (TCP): -S 0 고정, ${TOTAL_DUR}초"
log_event "테스트 시작 (Traffic Scenario, --dscp-change, USE_RATE_CHANGE=$USE_RATE_CHANGE)"
echo ""

echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
log_event "기존 iperf3 프로세스 종료 시작"
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
log_event "기존 iperf3 프로세스 종료 완료"
echo ""

echo "[$(timestamp)] === UE iperf3 서버 시작 (DL 수신용) ==="
log_event "iperf3 서버 시작 (DL)"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || true
sleep 2

echo "=========================================="
echo "[$(timestamp)] === 트래픽 시작 (${TOTAL_DUR}초) — DL 전용 ==="
if [ "$USE_RATE_CHANGE" = "0" ]; then
    echo "  UE1 DL: UDP, --dscp-change만, -b 10M 고정"
else
    echo "  UE1 DL: UDP, --dscp-change \"$DSCP_CHANGE_ARGS\", --rate-change \"$RATE_CHANGE_ARGS\""
fi
echo "  UE2/3 DL: TCP, -S 0"
echo "=========================================="
log_event "트래픽 시작 (DL 전용): UE1 --dscp-change, USE_RATE_CHANGE=$USE_RATE_CHANGE"

# UE1 DL: UDP, 동적 DSCP (+ 선택적으로 rate 변경)
if [ "$USE_RATE_CHANGE" = "0" ]; then
    iperf3 -c 10.45.0.2 -u -b 10M -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        > /tmp/iperf3_dscp_scenario_dl0.log 2>&1 &
else
    iperf3 -c 10.45.0.2 -u -t "$TOTAL_DUR" -p 6500 -i 1 -d \
        --dscp-change "${DSCP_CHANGE_ARGS}" \
        --rate-change "${RATE_CHANGE_ARGS}" \
        > /tmp/iperf3_dscp_scenario_dl0.log 2>&1 &
fi
DL0_PID=$!
log_event "UE1 DL 시작 (PID=$DL0_PID): UDP, --dscp-change"

# UE2 DL: TCP, DSCP 0
iperf3 -c 10.45.0.3 -t "$TOTAL_DUR" -p 6501 -i 1 -S 0 \
    > /tmp/iperf3_dscp_scenario_dl1.log 2>&1 &
DL1_PID=$!

# UE3 DL: TCP, DSCP 0
iperf3 -c 10.45.0.4 -t "$TOTAL_DUR" -p 6502 -i 1 -S 0 \
    > /tmp/iperf3_dscp_scenario_dl2.log 2>&1 &
DL2_PID=$!

echo "  ✓ DL 트래픽만 시작됨 (UE1/2/3 DL)"
echo "    DL PIDs: $DL0_PID $DL1_PID $DL2_PID"
echo ""

echo "[$(timestamp)] 테스트 진행 중 (${TOTAL_DUR}초)..."
log_event "테스트 진행 시작 (${TOTAL_DUR}초 대기)"

LAST_DL_CHANGE_COUNT=0
for i in $(seq 1 "$TOTAL_DUR"); do
    show_progress "전체" "$i" "$TOTAL_DUR"
    [ "$i" -eq 20 ] && log_event "20초: UE1 DSCP 0→44 예정"
    [ "$i" -eq 40 ] && log_event "40초: UE1 DSCP 44→24 예정"
    [ "$i" -eq 60 ] && log_event "60초: UE1 DSCP 24→15 예정"

    if [ -f /tmp/iperf3_dscp_scenario_dl0.log ]; then
        CURRENT_DL_CHANGES=$(grep -i "Changed DSCP" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null | wc -l)
        if [ "$CURRENT_DL_CHANGES" -gt "$LAST_DL_CHANGE_COUNT" ]; then
            NEW_CHANGE=$(grep -i "Changed DSCP" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null | tail -n +"$((LAST_DL_CHANGE_COUNT + 1))" | head -1)
            if [ -n "$NEW_CHANGE" ]; then
                CHANGE_TIME=$(echo "$NEW_CHANGE" | grep -oE "at [0-9]+\.[0-9]+ seconds" | grep -oE "[0-9]+\.[0-9]+")
                [ -n "$CHANGE_TIME" ] && log_event "→ iperf3 실제 변경 시점 (UE1 DL): ${CHANGE_TIME}초"
            fi
            LAST_DL_CHANGE_COUNT=$CURRENT_DL_CHANGES
        fi
    fi
    sleep 1
done
printf "\n"

echo "[$(timestamp)] 테스트 완료 (${TOTAL_DUR}초 경과)"
log_event "테스트 완료 (${TOTAL_DUR}초 경과)"
echo ""

echo "[$(timestamp)] === UE1 DL DSCP/Rate 변경 로그 확인 ==="
FIRST_DSCP_CHANGE_TIME=""
FIRST_DSCP_VALUE=""
if grep -i "Changed DSCP" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null; then
    echo "  ✓ UE1 DL DSCP 변경 확인됨"
    CHANGE_TIMES=$(grep -i "Changed DSCP" /tmp/iperf3_dscp_scenario_dl0.log | grep -oE "at [0-9]+\.[0-9]+ seconds" | grep -oE "[0-9]+\.[0-9]+")
    if [ -n "$CHANGE_TIMES" ]; then
        echo "  → 실제 변경 시점들:"
        for time in $CHANGE_TIMES; do
            echo "    - ${time}초"
            if [ -z "$FIRST_DSCP_CHANGE_TIME" ]; then
                FIRST_DSCP_CHANGE_TIME="$time"
                FIRST_DSCP_LINE=$(grep -i "Changed DSCP" /tmp/iperf3_dscp_scenario_dl0.log | head -1)
                FIRST_DSCP_VALUE=$(echo "$FIRST_DSCP_LINE" | grep -oE "to [0-9]+" | grep -oE "[0-9]+" | head -1)
            fi
        done
        log_event "UE1 DL DSCP 변경 확인됨 (시점들: $CHANGE_TIMES)"
    else
        log_event "UE1 DL DSCP 변경 로그 확인됨"
    fi
else
    echo "  ⚠ UE1 DL DSCP 변경 로그 없음 (디버그 모드 필요: -d 옵션)"
    log_event "UE1 DL DSCP 변경 로그 없음"
fi
if grep -i "First packet with DSCP" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null; then
    echo "  ✓ UE1 DL 새 DSCP 첫 전송 시점"
    grep -i "First packet with DSCP" /tmp/iperf3_dscp_scenario_dl0.log | sed 's/^/    /'
    grep "First packet with DSCP" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null | while read -r line; do
        grep -Fq "$line" "$LOG_FILE" 2>/dev/null || log_event "  UE1 DL (첫 전송): $line"
    done
fi
if grep -i "Changed rate" /tmp/iperf3_dscp_scenario_dl0.log 2>/dev/null; then
    echo "  ✓ UE1 DL Rate 변경 확인"
    grep -i "Changed rate" /tmp/iperf3_dscp_scenario_dl0.log | sed 's/^/    /'
else
    echo "  ⚠ UE1 DL Rate 변경 로그 없음"
fi

if [ -n "$FIRST_DSCP_CHANGE_TIME" ]; then
    echo ""
    echo "  [DSCP 변경 요약]"
    echo "  → 첫 번째 DSCP 변경 시점: ${FIRST_DSCP_CHANGE_TIME}초"
    if [ -n "$FIRST_DSCP_VALUE" ]; then
        echo "  → 새로운 DSCP 값($FIRST_DSCP_VALUE)으로 패킷 전송 시작 시점"
        log_event "=========================================="
        log_event "첫 번째 DSCP 변경 완료 시점: ${FIRST_DSCP_CHANGE_TIME}초"
        log_event "→ DSCP가 0에서 $FIRST_DSCP_VALUE로 변경되어 새로운 DSCP로 패킷 전송 시작"
        log_event "=========================================="
    else
        echo "  → 새로운 DSCP 값으로 패킷 전송 시작 시점"
        log_event "=========================================="
        log_event "첫 번째 DSCP 변경 완료 시점: ${FIRST_DSCP_CHANGE_TIME}초"
        log_event "→ 새로운 DSCP로 패킷 전송 시작"
        log_event "=========================================="
    fi
fi
echo ""

echo "[$(timestamp)] 정리 중..."
log_event "정리 시작"
kill "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } > /dev/null 2>&1
log_event "정리 완료"
sleep 1
echo "  ✓ DL 트래픽 중단됨"
echo ""

echo "=========================================="
echo "[$(timestamp)] 테스트 완료!"
echo "=========================================="
log_event "테스트 완료 - 종료 시간: $(timestamp_us)"
echo ""
echo "[$(timestamp)] 시나리오 요약:"
if [ "$USE_RATE_CHANGE" = "0" ]; then
    echo "  UE1 (UDP): --dscp-change만, 10M 고정 (DSCP 0→44→24→15, 총 80초)"
else
    echo "  UE1 (UDP): --dscp-change + --rate-change (DSCP 0→44→24→15, Rate 20M→1M→15M, 총 80초)"
fi
echo "  UE2/UE3 (TCP): -S 0 고정"
echo ""
echo "  로그: $LOG_FILE"
echo "  UE1 DL: /tmp/iperf3_dscp_scenario_dl0.log (UE2/3: dl1.log, dl2.log)"
echo ""

