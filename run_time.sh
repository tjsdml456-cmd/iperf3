#!/bin/bash

set -e

# 기존 iperf3 프로세스 종료
sudo pkill -f "iperf3 -s" || true
sudo pkill -f "iperf3 -c" || true

sleep 1

echo "=== 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="

sudo ip netns exec ue1 iperf3 -s -p 6500 -D
sudo ip netns exec ue2 iperf3 -s -p 6501 -D
sudo ip netns exec ue3 iperf3 -s -p 6502 -D

sleep 2

echo "=== 2단계: 시간에 따라 DSCP 값이 변동하는 DL 트래픽 전송 ==="
echo ""
echo "모든 UE가 동일한 단계를 동시에 시작 (단계별 동기화)"
echo ""

# 1단계: 모든 UE의 첫 번째 DSCP 값 동시 시작
echo "→ 1단계: 모든 UE의 첫 번째 DSCP 값 전송"
echo "  UE1: DSCP=63 (0xFC)"
iperf3 -c 10.45.0.2 -u -b 5M -t 30 -p 6500 -i 1 -S 0xFC &
echo "  UE2: DSCP=30 (0x78)"
iperf3 -c 10.45.0.3 -u -b 5M -t 30 -p 6501 -i 1 -S 0x78 &
echo "  UE3: DSCP=0 (0x00)"
iperf3 -c 10.45.0.4 -u -b 5M -t 30 -p 6502 -i 1 -S 0x00 &
wait  # 모든 UE의 1단계 완료 대기
echo "  1단계 완료"
sleep 2  # 2초 대기

# 2단계: 모든 UE의 두 번째 DSCP 값 동시 시작
echo ""
echo "→ 2단계: 모든 UE의 두 번째 DSCP 값 전송"
echo "  UE1: DSCP=30 (0x78)"
iperf3 -c 10.45.0.2 -u -b 5M -t 30 -p 6500 -i 1 -S 0x78 &
echo "  UE2: DSCP=0 (0x00)"
iperf3 -c 10.45.0.3 -u -b 5M -t 30 -p 6501 -i 1 -S 0x00 &
echo "  UE3: DSCP=63 (0xFC)"
iperf3 -c 10.45.0.4 -u -b 5M -t 30 -p 6502 -i 1 -S 0xFC &
wait  # 모든 UE의 2단계 완료 대기
echo "  2단계 완료"
sleep 2  # 2초 대기

# 3단계: 모든 UE의 세 번째 DSCP 값 동시 시작
echo ""
echo "→ 3단계: 모든 UE의 세 번째 DSCP 값 전송"
echo "  UE1: DSCP=0 (0x00)"
iperf3 -c 10.45.0.2 -u -b 5M -t 30 -p 6500 -i 1 -S 0x00 &
echo "  UE2: DSCP=63 (0xFC)"
iperf3 -c 10.45.0.3 -u -b 5M -t 30 -p 6501 -i 1 -S 0xFC &
echo "  UE3: DSCP=30 (0x78)"
iperf3 -c 10.45.0.4 -u -b 5M -t 30 -p 6502 -i 1 -S 0x78 &
wait  # 모든 UE의 3단계 완료 대기
echo "  3단계 완료"

echo ""
echo "트래픽 전송 중... 다른 터미널에서 로그 확인:"
echo "  tail -f /tmp/gnb.log | grep 'Extracted DSCP'"
echo "  tail -f /tmp/gnb.log | grep 'F1-U CU-UP: Attaching DSCP'"
echo "  tail -f /tmp/gnb.log | grep 'STEP6-SCHED.*DSCP'"
echo ""
echo "시간대별 DSCP 변경 (모든 UE가 동일한 단계를 동시에 시작):"
echo "  - 1단계 (0-10초): UE1(DSCP=63), UE2(DSCP=30), UE3(DSCP=0) 동시 시작"
echo "  - 2초 대기"
echo "  - 2단계 (10-20초): UE1(DSCP=30), UE2(DSCP=0),  UE3(DSCP=63) 동시 시작"
echo "  - 2초 대기"
echo "  - 3단계 (20-30초): UE1(DSCP=0),  UE2(DSCP=63), UE3(DSCP=30) 동시 시작"

echo ""
echo "테스트 완료!"

