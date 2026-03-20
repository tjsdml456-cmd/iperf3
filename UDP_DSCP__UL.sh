#!/bin/bash
# iperf3 DSCP Traffic Scenario (--dscp-change, --rate-change 사용) — UL 전용(UE→서버)
#
# UE1: UDP UL, DSCP 0→32→24→15, 20·40·60초에 변경, 총 80초
#   DSCP: 0~20초=0, 20~40초=32, 40~60초=24, 60~80초=15
#   Rate: 0~40초=20M, 40~60초=1M, 60~80초=15M
# UE2/UE3: TCP UL, DSCP=0 고정
#
# NOTE:
# - iperf3 서버(-s)는 "-u" 옵션을 받지 않습니다. (UDP는 클라이언트가 -u로 보내면 됨)
# - UDP 테스트도 "컨트롤 연결"은 TCP로 붙습니다. 따라서 서버의 TCP/UDP 포트가 모두 통과되어야 함(방화벽).
# - gNB에서 UL DSCP 확인: [GTPU][UL-TX] inner_dscp=32/24/15 로그를 grep.

set -u

EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# Debug/override flags:
# - SKIP_PKILL=1 : 스크립트 시작/종료 시 'sudo pkill -x iperf3'를 수행하지 않음
# - SKIP_SERVER_START=1 : 호스트(10.45.0.1) iperf3 서버 시작을 수행하지 않음
SKIP_PKILL=${SKIP_PKILL:-0}
SKIP_SERVER_START=${SKIP_SERVER_START:-0}

# USE_RATE_CHANGE=0 이면 UE1은 --dscp-change만 (고정 10M)
USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}

# IPERF3_DSCP_DEBUG=1이면 iperf3에 전달(환경변수)
IPERF3_ENV=""
[ -n "${IPERF3_DSCP_DEBUG:-}" ] && IPERF3_ENV="IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG}"

TOTAL_DUR=80
DSCP_CHANGE_ARGS="0,20,32,40,24,60,15"
RATE_CHANGE_ARGS="10M,20,20M,40,1M,60,15M"

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

LOG_FILE="/tmp/iperf3_dscp_traffic_scenario_ul.log"
UL0_LOG="/tmp/iperf3_dscp_scenario_ul0.log"
UL1_LOG="/tmp/iperf3_dscp_scenario_ul1.log"
UL2_LOG="/tmp/iperf3_dscp_scenario_ul2.log"

SRV6600_ERR="/tmp/iperf3_server_6600.err"
SRV6601_ERR="/tmp/iperf3_server_6601.err"
SRV6602_ERR="/tmp/iperf3_server_6602.err"

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
  printf "\r[$(timestamp)] 진행 중(UL): [%-50s] %d%% (%d/%d초)" \
    "$(printf '#%.0s' $(seq 1 $((percent/2))))" "$percent" "$elapsed" "$total"
}

echo "==========================================" > "$LOG_FILE"
echo "  iperf3 DSCP Traffic Scenario (UL, UE→서버)" >> "$LOG_FILE"
echo "  시작 시간: $(timestamp_us)" >> "$LOG_FILE"
echo "  EXTERNAL_SERVER_IP: ${EXTERNAL_SERVER_IP}" >> "$LOG_FILE"
echo "  DSCP_CHANGE_ARGS: ${DSCP_CHANGE_ARGS}" >> "$LOG_FILE"
echo "  USE_RATE_CHANGE: ${USE_RATE_CHANGE}" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "=========================================="
echo "  iperf3 DSCP Traffic Scenario (UL)"
echo "=========================================="
echo "[$(timestamp)] 시나리오:"
if [ "$USE_RATE_CHANGE" = "0" ]; then
  echo "  - UE1 (UDP UL): --dscp-change만 (고정 10M)"
else
  echo "  - UE1 (UDP UL): --dscp-change + --rate-change"
  echo "    Rate: 0~40초=20M, 40~60초=1M, 60~80초=15M"
fi
echo "    DSCP: 0~20초=0, 20~40초=32, 40~60초=24, 60~80초=15"
echo "  - UE2/UE3 (TCP UL): -S 0 고정, ${TOTAL_DUR}초"
echo ""

log_event "기존 iperf3 프로세스 종료 시작"
if [ "${SKIP_PKILL}" != "1" ]; then
  sudo pkill -x iperf3 2>/dev/null || true
fi
sleep 1
log_event "기존 iperf3 프로세스 종료 완료"

echo "[$(timestamp)] === iperf3 서버 시작 (UL 수신용) ==="
log_event "iperf3 서버 시작 (UL 수신용, ports 6600/6601/6602)"

# 서버는 TCP 컨트롤을 받는 리스너. UDP 데이터는 클라이언트(-u)가 시작하면 동일 포트로 들어옴.
# -B 로 바인드 주소를 고정(ogstun IP)하면 netns(UE)에서 접속 시 'connection refused' 이슈 줄어듦.
if [ "${SKIP_SERVER_START}" != "1" ]; then
  iperf3 -s -p 6600 -B "${EXTERNAL_SERVER_IP}" -D 2>>"$SRV6600_ERR" || true
  iperf3 -s -p 6601 -B "${EXTERNAL_SERVER_IP}" -D 2>>"$SRV6601_ERR" || true
  iperf3 -s -p 6602 -B "${EXTERNAL_SERVER_IP}" -D 2>>"$SRV6602_ERR" || true
fi
sleep 1

echo "[$(timestamp)] === UE에서 iperf3 서버 시작 (DL 수신용: 선택) ==="
log_event "UE iperf3 서버 시작 (DL 수신용, ports 6500/6501/6502)"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || true
sleep 1

echo "=========================================="
echo "[$(timestamp)] === UL 트래픽 시작 (${TOTAL_DUR}초) ==="
echo "  UE1 UL: UDP, --dscp-change \"${DSCP_CHANGE_ARGS}\""
[ "$USE_RATE_CHANGE" != "0" ] && echo "       + --rate-change \"${RATE_CHANGE_ARGS}\""
echo "  UE2/3 UL: TCP, -S 0"
echo "=========================================="
log_event "UL 트래픽 시작: UE1 UDP DSCP-change, UE2/3 TCP UL"

# UE1 UL: UDP, DSCP change (+ optional rate change). UL DSCP 확인을 위해 -d(양방향) 사용하지 않음.
if [ "$USE_RATE_CHANGE" = "0" ]; then
  sudo ip netns exec ue1 env ${IPERF3_ENV} iperf3 -c "${EXTERNAL_SERVER_IP}" -u -b 10M -t "$TOTAL_DUR" -p 6600 -i 1 \
    --dscp-change "${DSCP_CHANGE_ARGS}" \
    > "$UL0_LOG" 2>&1 &
else
  sudo ip netns exec ue1 env ${IPERF3_ENV} iperf3 -c "${EXTERNAL_SERVER_IP}" -u -t "$TOTAL_DUR" -p 6600 -i 1 \
    --dscp-change "${DSCP_CHANGE_ARGS}" \
    --rate-change "${RATE_CHANGE_ARGS}" \
    > "$UL0_LOG" 2>&1 &
fi
UL0_PID=$!
log_event "UE1 UL 시작 (PID=$UL0_PID) log=$UL0_LOG"

# UE2 UL: TCP, DSCP 0
sudo ip netns exec ue2 env ${IPERF3_ENV} iperf3 -c "${EXTERNAL_SERVER_IP}" -t "$TOTAL_DUR" -p 6601 -i 1 -S 0 \
  > "$UL1_LOG" 2>&1 &
UL1_PID=$!

# UE3 UL: TCP, DSCP 0
sudo ip netns exec ue3 env ${IPERF3_ENV} iperf3 -c "${EXTERNAL_SERVER_IP}" -t "$TOTAL_DUR" -p 6602 -i 1 -S 0 \
  > "$UL2_LOG" 2>&1 &
UL2_PID=$!

echo "  ✓ UL 트래픽 시작됨"
echo "    UL PIDs: UE1=$UL0_PID UE2=$UL1_PID UE3=$UL2_PID"
echo ""

log_event "테스트 진행 시작 (${TOTAL_DUR}초 대기)"
LAST_UL_CHANGE_COUNT=0
for i in $(seq 1 "$TOTAL_DUR"); do
  show_progress "$i" "$TOTAL_DUR"
  [ "$i" -eq 20 ] && log_event "20초: UE1 DSCP 0→32 예정 (UL)"
  [ "$i" -eq 40 ] && log_event "40초: UE1 DSCP 32→24 예정 (UL)"
  [ "$i" -eq 60 ] && log_event "60초: UE1 DSCP 24→15 예정 (UL)"

  if [ -f "$UL0_LOG" ]; then
    CURRENT_UL_CHANGES=$(grep -i "Changed DSCP" "$UL0_LOG" 2>/dev/null | wc -l)
    if [ "$CURRENT_UL_CHANGES" -gt "$LAST_UL_CHANGE_COUNT" ]; then
      NEW_CHANGE=$(grep -i "Changed DSCP" "$UL0_LOG" 2>/dev/null | tail -n +"$((LAST_UL_CHANGE_COUNT + 1))" | head -1)
      if [ -n "$NEW_CHANGE" ]; then
        CHANGE_TIME=$(echo "$NEW_CHANGE" | grep -oE "at [0-9]+\.[0-9]+ seconds" | grep -oE "[0-9]+\.[0-9]+")
        [ -n "$CHANGE_TIME" ] && log_event "→ iperf3 실제 변경 시점 (UE1 UL): ${CHANGE_TIME}초"
      fi
      LAST_UL_CHANGE_COUNT=$CURRENT_UL_CHANGES
    fi
  fi
  sleep 1
done
printf "\n"

log_event "테스트 완료 (${TOTAL_DUR}초 경과)"

echo "[$(timestamp)] === UE1 UL DSCP 변경 로그 요약(iperf3) ==="
grep -i "Changed DSCP" "$UL0_LOG" 2>/dev/null | tail -20 || true
echo ""

echo "[$(timestamp)] 정리 중..."
log_event "정리 시작"
kill "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
if [ "${SKIP_PKILL}" != "1" ]; then
  sudo pkill -x iperf3 2>/dev/null || true
fi
log_event "정리 완료"

echo "=========================================="
echo "[$(timestamp)] 테스트 완료!"
echo "=========================================="
echo "  로그: $LOG_FILE"
echo "  UE1 UL: $UL0_LOG"
echo "  UE2 UL: $UL1_LOG"
echo "  UE3 UL: $UL2_LOG"
echo "  server err: $SRV6600_ERR (6601/6602도 동일)"
echo ""
