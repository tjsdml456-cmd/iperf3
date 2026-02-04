#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# 외부 서버 IP 설정 (UL 서버)
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# 로그 파일 경로
LOG_FILE="/tmp/iperf3_dscp_test.log"

# 마이크로초 단위 타임스탬프 함수
timestamp() {
    date '+%H:%M:%S.%N'
}

# 로그에 타임스탬프와 메시지 기록 함수
log_event() {
    local message="$1"
    local ts=$(timestamp)
    echo "[$ts] $message" | tee -a "$LOG_FILE"
}

# 진행 상황 표시 함수
show_progress() {
    local phase=$1
    local elapsed=$2
    local total=$3
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] Phase $phase 진행 중: [%-50s] %d%% (%d/%d초)" \
        "$(printf '#%.0s' $(seq 1 $((percent/2))))" $percent $elapsed $total
}

# 로그 파일 초기화
> "$LOG_FILE"

log_event "=========================================="
log_event "  iperf3 Dynamic DSCP 테스트 시작"
log_event "  시작 시간: $(timestamp)"
log_event "=========================================="
echo ""

# iperf3 -S 옵션 동작/환경 확인 (정보용)
log_event "iperf3 -S 옵션 동작/환경 확인 중..."
echo "[$(timestamp)] iperf3 -S 옵션 동작/환경 확인 중..."
echo "  iperf3 버전: $(iperf3 -v 2>&1 | head -1)"
echo "  네트워크 스택 설정:"
echo "    - /proc/sys/net/ipv4/ip_no_pmtu_disc: $(cat /proc/sys/net/ipv4/ip_no_pmtu_disc 2>/dev/null || echo 'N/A')"
echo "    - /proc/sys/net/ipv4/ip_forward:      $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 'N/A')"
echo ""

# 기존 iperf3 프로세스 종료
log_event "기존 iperf3 프로세스 종료 중..."
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
log_event "프로세스 종료 완료"
echo "[$(timestamp)] 프로세스 종료 완료"
echo ""

log_event "=== 1단계: UE 네임스페이스에서 iperf3 서버 시작 (DL 수신용) ==="
echo "[$(timestamp)] === 1단계: UE 네임스페이스에서 iperf3 서버 시작 (DL 수신용) ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null && log_event "UE0(ue1) DL 서버 시작 성공 (포트 6500)" || log_event "⚠ UE0(ue1) DL 서버 시작 실패 (이미 실행 중일 수 있음)"
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null && log_event "UE1(ue2) DL 서버 시작 성공 (포트 6501)" || log_event "⚠ UE1(ue2) DL 서버 시작 실패 (이미 실행 중일 수 있음)"
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null && log_event "UE2(ue3) DL 서버 시작 성공 (포트 6502)" || log_event "⚠ UE2(ue3) DL 서버 시작 실패 (이미 실행 중일 수 있음)"

sleep 2

log_event "=== 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
echo "[$(timestamp)] === 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
iperf3 -s -p 6600 -D 2>/dev/null && log_event "포트 6600 서버 시작 성공" || log_event "⚠ 포트 6600 서버 시작 실패 (이미 실행 중일 수 있음)"
iperf3 -s -p 6601 -D 2>/dev/null && log_event "포트 6601 서버 시작 성공" || log_event "⚠ 포트 6601 서버 시작 실패 (이미 실행 중일 수 있음)"
iperf3 -s -p 6602 -D 2>/dev/null && log_event "포트 6602 서버 시작 성공" || log_event "⚠ 포트 6602 서버 시작 실패 (이미 실행 중일 수 있음)"

sleep 2
echo ""

log_event "=========================================="
log_event "=== UE0만 DSCP 동적 변경 테스트 (5QI 시나리오와 동일한 타임라인) ==="
log_event "  Phase 1: 0-20초  - UE0/UE1/UE2 모두 DSCP=0 (기본)"
log_event "  Phase 2: 20-30초 - UE0만 트래픽 중단, UE1/UE2는 계속"
log_event "  Phase 3: 30-50초 - UE0만 DSCP=32(0x80), UE1/UE2는 DSCP=0 유지"
log_event "  Phase 4: 50-60초 - UE0만 다시 중단, UE1/UE2는 계속"
log_event "  Phase 5: 60-80초 - UE0만 DSCP=14(0x38), UE1/UE2는 DSCP=0 유지"
log_event "=========================================="
echo "=========================================="
echo "[$(timestamp)] === UE0만 DSCP 동적 변경 테스트 (5QI 시나리오와 동일한 타임라인) ==="
echo "  Phase 1: 0-20초  - UE0/UE1/UE2 모두 DSCP=0 (기본)"
echo "  Phase 2: 20-30초 - UE0만 트래픽 중단, UE1/UE2는 계속"
echo "  Phase 3: 30-50초 - UE0만 DSCP=32(0x80), UE1/UE2는 DSCP=0 유지"
echo "  Phase 4: 50-60초 - UE0만 다시 중단, UE1/UE2는 계속"
echo "  Phase 5: 60-80초 - UE0만 DSCP=14(0x38), UE1/UE2는 DSCP=0 유지"
echo "=========================================="
echo ""

############################
# Phase 1: 0-20초 (DSCP=0) #
############################
log_event "Phase 1 시작: 모든 UE 트래픽 시작 (DSCP=0, 20초)"
echo "[$(timestamp)] Phase 1: 모든 UE 트래픽 시작 (DSCP=0, 20초)..."
echo "  참고: UE0=ue1, UE1=ue2, UE2=ue3, DL IP=10.45.0.2/3/4"

# DL 트래픽 (모든 UE, DSCP=0, 전체 기간 80초)
log_event "UE0 DL 트래픽 시작 (DSCP=0, 80초)"
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 -S 0x00 > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
log_event "UE0 DL 트래픽 시작됨 (PID=$DL0_PID)"

log_event "UE1 DL 트래픽 시작 (DSCP=0, 80초)"
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 -S 0x00 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
log_event "UE1 DL 트래픽 시작됨 (PID=$DL1_PID)"

log_event "UE2 DL 트래픽 시작 (DSCP=0, 80초)"
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 -S 0x00 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
log_event "UE2 DL 트래픽 시작됨 (PID=$DL2_PID)"

# UL 트래픽 (모든 UE, DSCP=0, 80초)
log_event "UE0 UL 트래픽 시작 (DSCP=0, 80초)"
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6600 -i 1 -S 0x00 > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
log_event "UE0 UL 트래픽 시작됨 (PID=$UL0_PID)"

log_event "UE1 UL 트래픽 시작 (DSCP=0, 80초)"
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6601 -i 1 -S 0x00 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
log_event "UE1 UL 트래픽 시작됨 (PID=$UL1_PID)"

log_event "UE2 UL 트래픽 시작 (DSCP=0, 80초)"
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6602 -i 1 -S 0x00 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
log_event "UE2 UL 트래픽 시작됨 (PID=$UL2_PID)"

echo "  ✓ 모든 UE 트래픽 시작됨 (UE0/UE1/UE2 모두 DSCP=0)"
echo "  DL PIDs: UE0=$DL0_PID, UE1=$DL1_PID, UE2=$DL2_PID"
echo "  UL PIDs: UE0=$UL0_PID, UE1=$UL1_PID, UE2=$UL2_PID"
echo ""

# 0-20초 진행
for i in {1..20}; do
    show_progress 1 $i 20
    sleep 1
done
printf "\n"
log_event "Phase 1 완료 (20초 경과)"
echo "[$(timestamp)] Phase 1 완료 (20초 경과)"
echo ""

############################################
# Phase 2: 20-30초 (UE0만 중단, UE1/UE2 유지) #
############################################
log_event "Phase 2 시작: UE0만 10초 중단, UE1/UE2는 계속 실행"
echo "[$(timestamp)] Phase 2: UE0만 10초 중단, UE1/UE2는 계속 실행..."
log_event "UE0 DL 트래픽 중단 (PID=$DL0_PID)"
log_event "UE0 UL 트래픽 중단 (PID=$UL0_PID)"
kill $DL0_PID $UL0_PID 2>/dev/null || true
log_event "UE0 트래픽 중단 완료"
echo "  ✓ UE0 트래픽 중단됨 (DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 20-30초 진행 (10초)
for i in {1..10}; do
    show_progress 2 $i 10
    sleep 1
done
printf "\n"
log_event "Phase 2 완료 (30초 경과)"
echo "[$(timestamp)] Phase 2 완료 (30초 경과)"
echo ""

#####################################################
# Phase 3: 30-50초 (UE0 DSCP=32, UE1/UE2 DSCP=0 유지) #
#####################################################
log_event "Phase 3 시작: UE0만 DSCP=32(0x80), UE1/UE2는 DSCP=0으로 20초 실행"
echo "[$(timestamp)] Phase 3: UE0만 DSCP=32(0x80), UE1/UE2는 DSCP=0으로 20초 실행..."
echo "  (DL/UL 둘 다 UE0만 DSCP 32로 변경)"

# UE0 DL/UL 재시작 (20초, DSCP=32)
log_event "UE0 DL 트래픽 재시작 (DSCP=32/ToS=0x80, 20초)"
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -S 0x80 > /tmp/iperf3_dl0_phase3.log 2>&1 &
DL0_PID=$!
log_event "UE0 DL 트래픽 재시작됨 (PID=$DL0_PID, DSCP=32)"

log_event "UE0 UL 트래픽 재시작 (DSCP=32/ToS=0x80, 20초)"
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -S 0x80 > /tmp/iperf3_ul0_phase3.log 2>&1 &
UL0_PID=$!
log_event "UE0 UL 트래픽 재시작됨 (PID=$UL0_PID, DSCP=32)"
echo "  ✓ UE0 트래픽 재시작됨 (DSCP=32/ToS=0x80, DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 DSCP=0으로 실행 중..."
echo ""

# 30-50초 진행 (20초)
for i in {1..20}; do
    show_progress 3 $i 20
    sleep 1
done
printf "\n"
log_event "Phase 3 완료 (50초 경과)"
echo "[$(timestamp)] Phase 3 완료 (50초 경과)"
echo ""

############################################
# Phase 4: 50-60초 (UE0만 다시 중단)       #
############################################
log_event "Phase 4 시작: UE0만 10초 중단, UE1/UE2는 계속 실행"
echo "[$(timestamp)] Phase 4: UE0만 10초 중단, UE1/UE2는 계속 실행..."
log_event "UE0 DL 트래픽 중단 (PID=$DL0_PID)"
log_event "UE0 UL 트래픽 중단 (PID=$UL0_PID)"
kill $DL0_PID $UL0_PID 2>/dev/null || true
log_event "UE0 트래픽 중단 완료"
echo "  ✓ UE0 트래픽 중단됨 (DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 50-60초 진행 (10초)
for i in {1..10}; do
    show_progress 4 $i 10
    sleep 1
done
printf "\n"
log_event "Phase 4 완료 (60초 경과)"
echo "[$(timestamp)] Phase 4 완료 (60초 경과)"
echo ""

#####################################################
# Phase 5: 60-80초 (UE0 DSCP=14, UE1/UE2 DSCP=0 유지) #
#####################################################
log_event "Phase 5 시작: UE0만 DSCP=14(0x38), UE1/UE2는 DSCP=0으로 20초 실행"
echo "[$(timestamp)] Phase 5: UE0만 DSCP=14(0x38), UE1/UE2는 DSCP=0으로 20초 실행..."
echo "  (DL/UL 둘 다 UE0만 DSCP 14로 변경)"

# UE0 DL/UL 재시작 (20초, DSCP=14)
log_event "UE0 DL 트래픽 재시작 (DSCP=14/ToS=0x38, 20초)"
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -S 0x38 > /tmp/iperf3_dl0_phase5.log 2>&1 &
DL0_PID=$!
log_event "UE0 DL 트래픽 재시작됨 (PID=$DL0_PID, DSCP=14)"

log_event "UE0 UL 트래픽 재시작 (DSCP=14/ToS=0x38, 20초)"
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -S 0x38 > /tmp/iperf3_ul0_phase5.log 2>&1 &
UL0_PID=$!
log_event "UE0 UL 트래픽 재시작됨 (PID=$UL0_PID, DSCP=14)"
echo "  ✓ UE0 트래픽 재시작됨 (DSCP=14/ToS=0x38, DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 DSCP=0으로 실행 중..."
echo ""

# 60-80초 진행 (20초)
for i in {1..20}; do
    show_progress 5 $i 20
    sleep 1
done
printf "\n"
log_event "Phase 5 완료 (80초 경과)"
echo "[$(timestamp)] Phase 5 완료 (80초 경과)"
echo ""

#########################
# 모든 프로세스 종료   #
#########################
log_event "테스트 완료 - 모든 트래픽 중단 시작"
echo "[$(timestamp)] 테스트 완료 - 모든 트래픽 중단 중..."
log_event "모든 트래픽 프로세스 종료 시도 (PIDs: DL0=$DL0_PID, DL1=$DL1_PID, DL2=$DL2_PID, UL0=$UL0_PID, UL1=$UL1_PID, UL2=$UL2_PID)"
kill $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
sleep 2
{ kill -9 $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true; } > /dev/null 2>&1
sleep 1

# 안전하게 모든 iperf3 프로세스 종료
log_event "모든 iperf3 프로세스 강제 종료"
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
log_event "모든 트래픽 중단 완료"
echo "  ✓ 모든 트래픽 중단됨"
echo ""

log_event "=========================================="
log_event "DSCP 테스트 완료!"
log_event "=========================================="
echo "=========================================="
echo "[$(timestamp)] DSCP 테스트 완료!"
echo "=========================================="
echo ""
echo "로그 파일 위치: $LOG_FILE"
echo "로그 예시 확인:"
echo "  tail -f /tmp/gnb.log | grep \"DELAY-WEIGHT\""
echo "  tail -f /tmp/gnb.log | grep \"Throughput calc\""
echo "  cat $LOG_FILE"
