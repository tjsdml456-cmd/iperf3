#!/bin/bash
set -e

echo "=== STEP 0: 기존 iperf3 프로세스 종료 ==="
sudo pkill -f "iperf3" || true
sleep 1

###############################
# 1) UE에서 DL용 iperf3 서버 실행
###############################
echo "=== STEP 1: UE에서 DL 수신용 iperf3 서버 실행 ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D
sudo ip netns exec ue2 iperf3 -s -p 6501 -D
sudo ip netns exec ue3 iperf3 -s -p 6502 -D

###############################
# 2) 외부에서 UL용 iperf3 서버 실행
###############################
echo "=== STEP 2: 외부에서 UL 수신용 iperf3 서버 실행 ==="
iperf3 -s -p 7000 -D
iperf3 -s -p 7001 -D
iperf3 -s -p 7002 -D

sleep 2

###############################
# 3) DL 트래픽 (외부 → UE)
###############################
echo "=== STEP 3: DL(DN→UE) DSCP 기반 트래픽 ==="
echo "→ UE1 DSCP=46 (EF)"
iperf3 -c 10.45.0.2 -u -b 5M -t 30 -p 6500 -S 0xE0 -i 1 &

echo "→ UE2 DSCP=34 (AF31)"
iperf3 -c 10.45.0.3 -u -b 5M -t 30 -p 6501 -S 0x68 -i 1 &

echo "→ UE3 DSCP=0 (BE)"
iperf3 -c 10.45.0.4 -u -b 5M -t 30 -p 6502 -S 0x00 -i 1 &

###############################
# 4) UL 트래픽 (UE → 외부)
###############################
echo "=== STEP 4: UL(UE→DN) DSCP 기반 트래픽 ==="
echo "→ UE1 → 서버 DSCP=46"
sudo ip netns exec ue1 iperf3 -c 10.45.0.1 -u -b 2M -t 30 -p 7000 -S 0xE0 -i 1 &

echo "→ UE2 → 서버 DSCP=34"
sudo ip netns exec ue2 iperf3 -c 10.45.0.1 -u -b 2M -t 30 -p 7001 -S 0x68 -i 1 &

echo "→ UE3 → 서버 DSCP=0"
sudo ip netns exec ue3 iperf3 -c 10.45.0.1 -u -b 2M -t 30 -p 7002 -S 0x00 -i 1 &

echo ""
echo "=== 실험 시작! DeepFlow에서 E2E/Queueing latency 확인 ==="
echo "DL 로그 확인:"
echo "  tail -f /tmp/gnb.log | grep 'Extracted DSCP'"
echo "UL 로그 확인:"
echo "  tail -f /tmp/gnb.log | grep 'UL DSCP'"
echo ""

wait
echo "=== 테스트 완료 ==="
