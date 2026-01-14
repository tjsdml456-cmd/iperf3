#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# 외부 서버 IP 설정
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# 타임스탬프 함수
timestamp() {
    date '+%H:%M:%S'
}

# 진행 상황 표시 함수
show_progress() {
    local phase=$1
    local elapsed=$2
    local total=$3
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] Phase $phase 진행 중: [%-50s] %d%% (%d/%d초)" \
        $(printf '#%.0s' $(seq 1 $((percent/2)))) $percent $elapsed $total
}

echo "=========================================="
echo "  iperf3 Dynamic DSCP 테스트 시작"
echo "  시작 시간: $(timestamp)"
echo "=========================================="
echo ""

# iperf3 -S 옵션 동작 확인
echo "[$(timestamp)] iperf3 -S 옵션 동작 확인 중..."
echo "  iperf3 버전: $(iperf3 -v 2>&1 | head -1)"
echo "  네트워크 스택 ToS 설정 확인:"
echo "    - /proc/sys/net/ipv4/ip_no_pmtu_disc: $(cat /proc/sys/net/ipv4/ip_no_pmtu_disc 2>/dev/null || echo 'N/A')"
echo "    - /proc/sys/net/ipv4/ip_forward: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 'N/A')"
echo ""

# 기존 iperf3 프로세스 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
# 스크립트 자체는 제외하고 iperf3 프로세스만 종료
# 모든 출력과 에러를 숨기고 안전하게 처리
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
echo "[$(timestamp)] 프로세스 종료 완료"
echo ""

echo "[$(timestamp)] === 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D
sudo ip netns exec ue2 iperf3 -s -p 6501 -D
sudo ip netns exec ue3 iperf3 -s -p 6502 -D

sleep 2

echo "[$(timestamp)] === 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
iperf3 -s -p 6600 -D &
iperf3 -s -p 6601 -D &
iperf3 -s -p 6602 -D &

sleep 2
echo ""

echo "=========================================="
echo "[$(timestamp)] === UE1만 DSCP 동적 변경 테스트 ==="
echo "  Phase 1: 0-10초 - 모든 UE DSCP=0"
echo "  대기: 10초 (트래픽 중단)"
echo "  Phase 2: 20-40초 - UE1만 DSCP=32 (0x80), UE2/UE3는 DSCP=0"
echo "  대기: 20초 (트래픽 중단)"
echo "  Phase 3: 60-80초 - UE1만 DSCP=14 (0x38), UE2/UE3는 DSCP=0"
echo "=========================================="

# Phase 1: 모든 UE DSCP=0 (10초)
echo "[$(timestamp)] Phase 1: 모든 UE 트래픽 시작 (DSCP=0, 10초)..."
# DL 트래픽
iperf3 -c 10.45.0.2 -t 10 -p 6500 -i 1 -S 0x00 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.3 -t 10 -p 6501 -i 1 -S 0x00 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
iperf3 -c 10.45.0.4 -t 10 -p 6502 -i 1 -S 0x00 > /tmp/iperf3_dl3.log 2>&1 &
DL3_PID=$!

# UL 트래픽
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 10 -p 6600 -i 1 -S 0x00 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 10 -p 6601 -i 1 -S 0x00 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 10 -p 6602 -i 1 -S 0x00 > /tmp/iperf3_ul3.log 2>&1 &
UL3_PID=$!
echo "  ✓ 모든 UE 트래픽 시작됨 (UE1/UE2/UE3 모두 DSCP=0)"

# 0-10초 진행
for i in {1..10}; do
    show_progress 1 $i 10
    sleep 1
done
printf "\n"

# 모든 프로세스 종료
echo "[$(timestamp)] Phase 1 완료 - 모든 트래픽 중단 중..."
kill $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2
# 강제 종료 확인
{ kill -9 $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true; } > /dev/null 2>&1
sleep 1
echo "  ✓ 모든 트래픽 중단됨"
echo ""

# 10초 대기
echo "[$(timestamp)] 대기 중... (10초)"
for i in {1..10}; do
    printf "\r[$(timestamp)] 대기 중... (%d/10초)" $i
    sleep 1
done
printf "\n"
echo ""

# Phase 2: UE1만 DSCP=32, UE2/UE3는 DSCP=0 (20초)
echo "[$(timestamp)] Phase 2: UE1만 DSCP=32, UE2/UE3는 DSCP=0으로 트래픽 시작 (20초)..."
# UE1 DL 트래픽 (DSCP=32)
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -S 0x80 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
sleep 1
if kill -0 $DL1_PID 2>/dev/null; then
    echo "  ✓ UE1 DL 트래픽 시작됨 (PID: $DL1_PID, DSCP 32/ToS 0x80)"
else
    echo "  ✗ UE1 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl1.log | tail -10
fi

# UE2 DL 트래픽 (DSCP=0)
iperf3 -c 10.45.0.3 -t 20 -p 6501 -i 1 -S 0x00 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
sleep 1
if kill -0 $DL2_PID 2>/dev/null; then
    echo "  ✓ UE2 DL 트래픽 시작됨 (PID: $DL2_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE2 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl2.log | tail -10
fi

# UE3 DL 트래픽 (DSCP=0)
iperf3 -c 10.45.0.4 -t 20 -p 6502 -i 1 -S 0x00 > /tmp/iperf3_dl3.log 2>&1 &
DL3_PID=$!
sleep 1
if kill -0 $DL3_PID 2>/dev/null; then
    echo "  ✓ UE3 DL 트래픽 시작됨 (PID: $DL3_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE3 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl3.log | tail -10
fi

# UE1 UL 트래픽 (DSCP=32)
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -S 0x80 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
sleep 1
if kill -0 $UL1_PID 2>/dev/null; then
    echo "  ✓ UE1 UL 트래픽 시작됨 (PID: $UL1_PID, DSCP 32/ToS 0x80)"
else
    echo "  ✗ UE1 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul1.log | tail -10
fi

# UE2 UL 트래픽 (DSCP=0)
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6601 -i 1 -S 0x00 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
sleep 1
if kill -0 $UL2_PID 2>/dev/null; then
    echo "  ✓ UE2 UL 트래픽 시작됨 (PID: $UL2_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE2 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul2.log | tail -10
fi

# UE3 UL 트래픽 (DSCP=0)
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6602 -i 1 -S 0x00 > /tmp/iperf3_ul3.log 2>&1 &
UL3_PID=$!
sleep 1
if kill -0 $UL3_PID 2>/dev/null; then
    echo "  ✓ UE3 UL 트래픽 시작됨 (PID: $UL3_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE3 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul3.log | tail -10
fi
echo ""

# 20초 진행
for i in {1..20}; do
    show_progress 2 $i 20
    sleep 1
done
printf "\n"

# 프로세스 종료
echo "[$(timestamp)] Phase 2 완료 - 모든 트래픽 중단 중..."
kill $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2
{ kill -9 $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true; } > /dev/null 2>&1
sleep 1
echo "  ✓ 모든 트래픽 중단됨"
echo ""

# 20초 대기
echo "[$(timestamp)] 대기 중... (20초)"
for i in {1..20}; do
    printf "\r[$(timestamp)] 대기 중... (%d/20초)" $i
    sleep 1
done
printf "\n"
echo ""

# Phase 3: UE1만 DSCP=14, UE2/UE3는 DSCP=0 (20초)
echo "[$(timestamp)] Phase 3: UE1만 DSCP=14, UE2/UE3는 DSCP=0으로 트래픽 시작 (20초)..."
# UE1 DL 트래픽 (DSCP=14)
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -S 0x38 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
sleep 1
if kill -0 $DL1_PID 2>/dev/null; then
    echo "  ✓ UE1 DL 트래픽 시작됨 (PID: $DL1_PID, DSCP 14/ToS 0x38)"
else
    echo "  ✗ UE1 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl1.log | tail -10
fi

# UE2 DL 트래픽 (DSCP=0)
iperf3 -c 10.45.0.3 -t 20 -p 6501 -i 1 -S 0x00 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
sleep 1
if kill -0 $DL2_PID 2>/dev/null; then
    echo "  ✓ UE2 DL 트래픽 시작됨 (PID: $DL2_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE2 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl2.log | tail -10
fi

# UE3 DL 트래픽 (DSCP=0)
iperf3 -c 10.45.0.4 -t 20 -p 6502 -i 1 -S 0x00 > /tmp/iperf3_dl3.log 2>&1 &
DL3_PID=$!
sleep 1
if kill -0 $DL3_PID 2>/dev/null; then
    echo "  ✓ UE3 DL 트래픽 시작됨 (PID: $DL3_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE3 DL 트래픽 시작 실패!"
    cat /tmp/iperf3_dl3.log | tail -10
fi

# UE1 UL 트래픽 (DSCP=14)
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -S 0x38 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
sleep 1
if kill -0 $UL1_PID 2>/dev/null; then
    echo "  ✓ UE1 UL 트래픽 시작됨 (PID: $UL1_PID, DSCP 14/ToS 0x38)"
else
    echo "  ✗ UE1 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul1.log | tail -10
fi

# UE2 UL 트래픽 (DSCP=0)
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6601 -i 1 -S 0x00 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
sleep 1
if kill -0 $UL2_PID 2>/dev/null; then
    echo "  ✓ UE2 UL 트래픽 시작됨 (PID: $UL2_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE2 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul2.log | tail -10
fi

# UE3 UL 트래픽 (DSCP=0)
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6602 -i 1 -S 0x00 > /tmp/iperf3_ul3.log 2>&1 &
UL3_PID=$!
sleep 1
if kill -0 $UL3_PID 2>/dev/null; then
    echo "  ✓ UE3 UL 트래픽 시작됨 (PID: $UL3_PID, DSCP 0/ToS 0x00)"
else
    echo "  ✗ UE3 UL 트래픽 시작 실패!"
    cat /tmp/iperf3_ul3.log | tail -10
fi
echo ""

# 20초 진행
for i in {1..20}; do
    show_progress 3 $i 20
    sleep 1
done
printf "\n"

echo "[$(timestamp)] 테스트 완료 - 모든 프로세스 종료 중..."
# 모든 iperf3 프로세스 종료
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 2
echo ""

echo "[$(timestamp)] 테스트 완료!"
echo ""
echo "로그 확인:"
echo "  tail -f /tmp/gnb.log | grep \"STEP1-SDAP\""
echo "  tail -f /tmp/gnb.log | grep \"STEP6-SCHED\""










