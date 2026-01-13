#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# 기존 iperf3 프로세스 종료
echo "기존 iperf3 프로세스 종료 중..."
sudo pkill -f "iperf3" || true
sleep 3

echo "=== 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D
sudo ip netns exec ue2 iperf3 -s -p 6501 -D
sudo ip netns exec ue3 iperf3 -s -p 6502 -D

sleep 2

echo "=== 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
iperf3 -s -p 6600 -D &
iperf3 -s -p 6601 -D &
iperf3 -s -p 6602 -D &

sleep 2

echo ""
echo "=== Phase 1: 초기 상태 - 모든 UE DSCP 없음 (30초) ==="
echo "0-30초: 모든 UE DSCP 없음 (기본값)"

# DL 트래픽
iperf3 -c 10.45.0.2 -b 5M -t 30 -p 6500 -i 1 > /dev/null 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.3 -b 5M -t 30 -p 6501 -i 1 > /dev/null 2>&1 &
DL2_PID=$!
iperf3 -c 10.45.0.4 -b 5M -t 30 -p 6502 -i 1 > /dev/null 2>&1 &
DL3_PID=$!

sleep 2

# UL 트래픽
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6600 -i 1 > /dev/null 2>&1 &
UL1_PID=$!
sudo ip netns exec ue2 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6601 -i 1 > /dev/null 2>&1 &
UL2_PID=$!
sudo ip netns exec ue3 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6602 -i 1 > /dev/null 2>&1 &
UL3_PID=$!

echo "Phase 1 실행 중... (30초 대기)"
wait $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2

echo ""
echo "=== Phase 2: UE1에 5QI 3 (GBR) DSCP 적용 (30초) ==="
echo "30-60초: UE1=5QI 3 (DSCP 0x20), UE2/UE3=기본값"

# DL 트래픽
iperf3 -c 10.45.0.2 -b 5M -t 30 -p 6500 -i 1 -S 0x20 > /dev/null 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.3 -b 5M -t 30 -p 6501 -i 1 > /dev/null 2>&1 &
DL2_PID=$!
iperf3 -c 10.45.0.4 -b 5M -t 30 -p 6502 -i 1 > /dev/null 2>&1 &
DL3_PID=$!

sleep 2

# UL 트래픽
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6600 -i 1 -S 0x20 > /dev/null 2>&1 &
UL1_PID=$!
sudo ip netns exec ue2 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6601 -i 1 > /dev/null 2>&1 &
UL2_PID=$!
sudo ip netns exec ue3 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6602 -i 1 > /dev/null 2>&1 &
UL3_PID=$!

echo "Phase 2 실행 중... (30초 대기)"
wait $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2

echo ""
echo "=== Phase 3: UE1 DSCP 제거 (30초) ==="
echo "60-90초: 모든 UE DSCP 없음 (기본값)"

# DL 트래픽
iperf3 -c 10.45.0.2 -b 5M -t 30 -p 6500 -i 1 > /dev/null 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.3 -b 5M -t 30 -p 6501 -i 1 > /dev/null 2>&1 &
DL2_PID=$!
iperf3 -c 10.45.0.4 -b 5M -t 30 -p 6502 -i 1 > /dev/null 2>&1 &
DL3_PID=$!

sleep 2

# UL 트래픽
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6600 -i 1 > /dev/null 2>&1 &
UL1_PID=$!
sudo ip netns exec ue2 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6601 -i 1 > /dev/null 2>&1 &
UL2_PID=$!
sudo ip netns exec ue3 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6602 -i 1 > /dev/null 2>&1 &
UL3_PID=$!

echo "Phase 3 실행 중... (30초 대기)"
wait $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2

echo ""
echo "=== Phase 4: UE1에 5QI 85 (Delay Critical GBR) DSCP 적용 (30초) ==="
echo "90-120초: UE1=5QI 85 (DSCP 0x0E), UE2/UE3=기본값"

# DL 트래픽
iperf3 -c 10.45.0.2 -b 5M -t 30 -p 6500 -i 1 -S 0x0E > /dev/null 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.3 -b 5M -t 30 -p 6501 -i 1 > /dev/null 2>&1 &
DL2_PID=$!
iperf3 -c 10.45.0.4 -b 5M -t 30 -p 6502 -i 1 > /dev/null 2>&1 &
DL3_PID=$!

sleep 2

# UL 트래픽
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6600 -i 1 -S 0x0E > /dev/null 2>&1 &
UL1_PID=$!
sudo ip netns exec ue2 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6601 -i 1 > /dev/null 2>&1 &
UL2_PID=$!
sudo ip netns exec ue3 iperf3 -c 10.45.0.1 -b 5M -t 30 -p 6602 -i 1 > /dev/null 2>&1 &
UL3_PID=$!

echo "Phase 4 실행 중... (30초 대기)"
wait $DL1_PID $DL2_PID $DL3_PID $UL1_PID $UL2_PID $UL3_PID 2>/dev/null || true
sleep 2

echo ""
echo "트래픽 전송 완료! 다른 터미널에서 로그 확인:"
echo "  tail -f /tmp/gnb.log | grep 'Extracted DSCP'"
echo "  tail -f /tmp/gnb.log | grep 'F1-U CU-UP: Attaching DSCP'"
echo ""
echo "테스트 완료!"
