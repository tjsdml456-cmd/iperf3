#!/bin/bash
set -e

# 기존 iperf3 프로세스 종료
sudo pkill -f "iperf3 -s" || true
sleep 1

echo "=== 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D
sudo ip netns exec ue2 iperf3 -s -p 6501 -D
sudo ip netns exec ue3 iperf3 -s -p 6502 -D

sleep 2

echo "=== 2단계: 외부 서버에서 UE로 DSCP 설정된 DL 트래픽 전송 ==="
iperf3 -c 10.45.0.2 -t 30 -p 6500 -i 1 &

iperf3 -c 10.45.0.3 -t 30 -p 6501 -i 1 -S 0x80 &

iperf3 -c 10.45.0.4 -t 30 -p 6502 -i 1 -S 0x38 &

echo ""
echo "트래픽 전송 중... 다른 터미널에서 로그 확인:"
echo "  tail -f /tmp/gnb.log | grep 'Extracted DSCP'"
echo "  tail -f /tmp/gnb.log | grep 'F1-U CU-UP: Attaching DSCP'"

wait
echo "테스트 완료!"
