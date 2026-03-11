#!/bin/bash
# iperf3 Dynamic 5QI Test Script
# UE0만 동적 5QI 변경: 20초 5QI=9 → 20초 5QI=66(GBR) → 20초 5QI=80(non-GBR) → 20초 5QI=84(delay_critical GBR) (총 80초)

# set -e 제거 (에러가 발생해도 계속 진행)

# SMF API 설정
SMF_API=${SMF_API:-"http://127.0.0.4:7777/nsmf-pdusession/v1/qos-modify"}

# UE 정보 설정
UE0_SUPI=${UE0_SUPI:-"imsi-001010123456780"}
UE1_SUPI=${UE1_SUPI:-"imsi-001010123456790"}
UE2_SUPI=${UE2_SUPI:-"imsi-001010123456791"}
PSI=${PSI:-1}
QFI=${QFI:-1}

# 외부 서버 IP 설정
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-"10.45.0.1"}

# GBR/MBR 설정
GBR_NORMAL_DL=${GBR_NORMAL_DL:-20000000}
GBR_NORMAL_UL=${GBR_NORMAL_UL:-20000000}
GBR_DELAY_CRITICAL_DL=${GBR_DELAY_CRITICAL_DL:-15000000}
GBR_DELAY_CRITICAL_UL=${GBR_DELAY_CRITICAL_UL:-15000000}

# UE0 UDP 비트레이트 (실제 트래픽은 80초 연속 20M 유지)
# 주의: iperf3는 실행 중간에 -b 변경이 안 되므로, 여기서는 5QI만 동적 변경
UE0_UDP_RATE=${UE0_UDP_RATE:-20M}

# 로그 파일 경로
LOG_FILE="/tmp/iperf3_dynamic_5qi_test.log"

# 트래픽 시작 기준 시각(ns 단위)
TRAFFIC_START_EPOCH_NS=""

timestamp() {
    date '+%H:%M:%S'
}

timestamp_us() {
    date '+%H:%M:%S.%N' | cut -b1-16
}

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
    local bars=$((percent / 2))
    local barstr
    barstr=$(printf '#%.0s' $(seq 1 $bars 2>/dev/null))
    printf "\r[$(timestamp)] Phase %s 진행 중: [%-50s] %d%% (%d/%d초)" \
        "$phase" "$barstr" "$percent" "$elapsed" "$total"
}

# HTTP/2 prior knowledge 방식으로만 QoS 변경
change_5qi() {
    local supi=$1
    local new_5qi=$2
    local ue_name=$3
    local gbr_dl=${4:-0}
    local gbr_ul=${5:-0}
    local mbr_dl=${6:-0}
    local mbr_ul=${7:-0}

    echo "[$(timestamp)] $ue_name 5QI 변경 요청: 5QI=$new_5qi"

    json_obj="{\"supi\": \"$supi\", \"psi\": $PSI, \"qfi\": $QFI, \"5qi\": $new_5qi"

    if [ "$gbr_dl" -gt 0 ] || [ "$gbr_ul" -gt 0 ]; then
        json_obj="${json_obj}, \"gbr_dl\": $gbr_dl, \"gbr_ul\": $gbr_ul"
    fi

    if [ "$mbr_dl" -gt 0 ] || [ "$mbr_ul" -gt 0 ]; then
        json_obj="${json_obj}, \"mbr_dl\": $mbr_dl, \"mbr_ul\": $mbr_ul"
    fi

    json_obj="${json_obj}}"

    echo "  curl HTTP/2 prior knowledge 사용 중..."

    response=$(curl --http2-prior-knowledge -X POST "$SMF_API" \
        -H "Content-Type: application/json" \
        -d "$json_obj" \
        -w "\nHTTP_STATUS:%{http_code}" \
        -s 2>&1)

    http_status=$(echo "$response" | grep "HTTP_STATUS" | tail -1 | cut -d: -f2 | tr -d ' ')

    if [ "$http_status" = "200" ] || [ "$http_status" = "204" ]; then
        echo "  ✓ $ue_name 5QI 변경 성공 (HTTP $http_status)"
        return 0
    else
        echo "  ✗ $ue_name 5QI 변경 실패 (HTTP ${http_status:-unknown})"
        echo "  응답: $(echo "$response" | sed '/HTTP_STATUS:/d')"
        return 1
    fi
}

# 로그 초기화
{
echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 로그"
echo "  시작 시간: $(timestamp_us)"
echo "=========================================="
echo ""
} > "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "  (UE0만 동적 5QI 변경)"
echo "=========================================="
echo ""
echo "[$(timestamp)] 시나리오:"
echo "  - UE0 (ue1): UDP, 80초 연속 ${UE0_UDP_RATE}, 5QI 9 → 66 → 80 → 84"
echo "  - UE1 (ue2), UE2 (ue3): TCP, 기존 5QI 유지"
echo "  - 테스트 시간: 총 80초"
echo ""

log_event "테스트 시작"

# 기존 iperf3 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
echo "[$(timestamp)] 기존 iperf3 종료 완료"
log_event "기존 iperf3 종료 완료"
echo ""

# UE 쪽 서버 시작 (DL 수신용)
echo "[$(timestamp)] UE iperf3 서버 시작"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || echo "  ⚠ ue1 서버 이미 실행 중"
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || echo "  ⚠ ue2 서버 이미 실행 중"
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || echo "  ⚠ ue3 서버 이미 실행 중"
log_event "UE iperf3 서버 시작 완료"

sleep 2

# 외부 서버 시작 (UL 수신용)
echo "[$(timestamp)] 외부 iperf3 서버 시작"
iperf3 -s -p 6600 -D 2>/dev/null || echo "  ⚠ 6600 서버 이미 실행 중"
iperf3 -s -p 6601 -D 2>/dev/null || echo "  ⚠ 6601 서버 이미 실행 중"
iperf3 -s -p 6602 -D 2>/dev/null || echo "  ⚠ 6602 서버 이미 실행 중"
log_event "외부 iperf3 서버 시작 완료"

sleep 2
echo ""

echo "=========================================="
echo "[$(timestamp)] 트래픽 시작"
echo "  Phase 1: 0-20초   UE0 5QI=9"
echo "  Phase 2: 20-40초  UE0 5QI=66 (GBR)"
echo "  Phase 3: 40-60초  UE0 5QI=80 (non-GBR)"
echo "  Phase 4: 60-80초  UE0 5QI=84 (delay-critical GBR)"
echo "=========================================="
echo ""

TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "트래픽 기준 시각(EPOCH_NS): ${TRAFFIC_START_EPOCH_NS}"

# UE0 UDP 80초 연속
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 -u -b "${UE0_UDP_RATE}" > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6600 -i 1 -u -b "${UE0_UDP_RATE}" > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!

# UE1 TCP 80초
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
sudo ip netns exec ue2 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6601 -i 1 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!

# UE2 TCP 80초
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
sudo ip netns exec ue3 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6602 -i 1 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!

echo "[$(timestamp)] 모든 트래픽 시작 완료"
echo "  DL PID: $DL0_PID $DL1_PID $DL2_PID"
echo "  UL PID: $UL0_PID $UL1_PID $UL2_PID"
log_event "모든 트래픽 시작 완료"
echo ""

# Phase 1
echo "[$(timestamp)] Phase 1: UE0 5QI=9"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 1 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi "$UE0_SUPI" 9 "UE0" 0 0 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=9 변경 성공"
else
    log_event "UE0 5QI=9 변경 실패"
fi

for i in {1..20}; do
    show_progress 1 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 1 완료"
echo ""

# Phase 2
echo "[$(timestamp)] Phase 2: UE0 5QI=66 (GBR 20Mbps)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 2 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi "$UE0_SUPI" 66 "UE0" "$GBR_NORMAL_DL" "$GBR_NORMAL_UL" 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=66 변경 성공"
else
    log_event "UE0 5QI=66 변경 실패"
fi

for i in {1..20}; do
    show_progress 2 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 2 완료"
echo ""

# Phase 3
echo "[$(timestamp)] Phase 3: UE0 5QI=80 (non-GBR)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 3 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi "$UE0_SUPI" 80 "UE0" 0 0 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=80 변경 성공"
else
    log_event "UE0 5QI=80 변경 실패"
fi

for i in {1..20}; do
    show_progress 3 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 3 완료"
echo ""

# Phase 4
echo "[$(timestamp)] Phase 4: UE0 5QI=84 (delay-critical GBR 15Mbps)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 4 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi "$UE0_SUPI" 84 "UE0" "$GBR_DELAY_CRITICAL_DL" "$GBR_DELAY_CRITICAL_UL" 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=84 변경 성공"
else
    log_event "UE0 5QI=84 변경 실패"
fi

for i in {1..20}; do
    show_progress 4 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 4 완료"
echo ""

# 정리
echo "[$(timestamp)] 테스트 완료 - 정리 중..."
log_event "정리 시작"

kill "$DL0_PID" "$DL1_PID" "$DL2_PID" "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$DL0_PID" "$DL1_PID" "$DL2_PID" "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

log_event "정리 완료"

echo ""
echo "=========================================="
echo "[$(timestamp)] 테스트 완료"
echo "=========================================="
echo "로그 파일: $LOG_FILE"
echo "확인 명령: cat $LOG_FILE"
echo ""

SMF_LOG="/var/log/open5gs/smf.log"
if [ -r "$SMF_LOG" ]; then
    echo "[$(timestamp)] 최근 SMF 관련 로그:"
    sudo tail -n 20 "$SMF_LOG"
fi
