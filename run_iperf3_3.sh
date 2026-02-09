#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# 외부 서버 IP 설정 (UL 서버)
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# GTP-U UDP 포트 (표준 포트 2152)
GTPU_PORT=${GTPU_PORT:-2152}

# UPF IP 주소 (N3 GTP-U 패킷의 **소스** IP)
# gNB 로그에서 확인: grep "\[IPTABLES-DSCP\] Extracted outer" gnb.log → src= 이 값
# 예: 같은 PC면 192.168.0.3, dummy 사용 시 10.53.1.2
# 주의: netstat으로 2152 리스닝 주소를 보면 gNB 바인드 주소이지 UPF 소스가 아님
UPF_IP=${UPF_IP:-192.168.0.3}

# gNB IP 주소 (참고용, 스크립트 내 필수 아님)
GNB_IP=${GNB_IP:-$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)}

# 타임스탬프 함수 (초 단위)
timestamp() {
    date '+%H:%M:%S'
}

# 마이크로초 단위 타임스탬프 함수 (6자리 마이크로초)
timestamp_us() {
    date '+%H:%M:%S.%N' | cut -b1-16
}

# 로그 파일 경로
LOG_FILE="/tmp/iperf3_dynamic_dscp_test.log"

# 이벤트 로그 함수 (타임스탬프 + 메시지를 로그 파일에 기록)
log_event() {
    local msg="$1"
    local ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

# iptables 규칙 확인 함수
check_iptables_rules() {
    echo "[$(timestamp)] Checking iptables rules..."
    echo "=== PREROUTING chain (DL traffic - GTP-U UDP port $GTPU_PORT) ==="
    sudo iptables -t mangle -L PREROUTING -n -v | head -20
    echo ""
    echo "=== INPUT chain (DL traffic - GTP-U UDP port $GTPU_PORT) ==="
    sudo iptables -t mangle -L INPUT -n -v | head -20
    echo ""
    echo "=== POSTROUTING chain in UE namespaces (UL traffic) ==="
    for ns in ue1 ue2 ue3; do
        echo "--- $ns namespace ---"
        sudo ip netns exec $ns iptables -t mangle -L POSTROUTING -n -v 2>/dev/null | head -10 || echo "No rules found"
    done
    echo ""
    echo "=== 패킷 카운터 확인 (규칙이 매칭되는지 확인) ==="
    echo "PREROUTING 체인에서 UDP 포트 $GTPU_PORT 규칙:"
    sudo iptables -t mangle -L PREROUTING -n -v | grep -E "udp.*$GTPU_PORT" || echo "규칙을 찾을 수 없음"
    echo ""
}

# GTP-U 내부 IP 목적지 오프셋. 기본 56(GTP-U 확장 4바이트 가정). 52=확장 없음. pkts=0이면 U32_OFFSET=52 또는 56 시도.
U32_OFFSET=${U32_OFFSET:-56}
# u32: "56=0x0A2D0002" = 4바이트가 10.45.0.2 (UE1). 같은 호스트 N3는 PREROUTING 안 타고 INPUT만 탈 수 있음 → INPUT 규칙이 실제 적용.
ue_u32_match=("${U32_OFFSET}=0x0A2D0002" "${U32_OFFSET}=0x0A2D0003" "${U32_OFFSET}=0x0A2D0004")

# DL UE별 적용 (u32만). fallback 없음 → u32에 안 맞는 패킷은 ToS 유지(0), UE별로만 DSCP 적용.
set_dl_dscp_per_ue() {
    local d1=$1 d2=$2 d3=$3
    local upf_ip="$UPF_IP"
    if [ -z "$upf_ip" ]; then return 1; fi
    local base="-s $upf_ip -p udp --dport $GTPU_PORT"
    for ue_idx in 0 1 2; do
        local u32="${ue_u32_match[$ue_idx]}"
        for dscp in 0 14 32; do
            sudo iptables -t mangle -D PREROUTING $base -m u32 --u32 "$u32" -j DSCP --set-dscp $dscp 2>/dev/null || true
            sudo iptables -t mangle -D INPUT $base -m u32 --u32 "$u32" -j DSCP --set-dscp $dscp 2>/dev/null || true
        done
    done
    for dscp in 0 14 32; do
        sudo iptables -t mangle -D PREROUTING $base -j DSCP --set-dscp $dscp 2>/dev/null || true
        sudo iptables -t mangle -D INPUT $base -j DSCP --set-dscp $dscp 2>/dev/null || true
    done
    for chain in PREROUTING INPUT; do
        sudo iptables -t mangle -A $chain $base -m u32 --u32 "${ue_u32_match[0]}" -j DSCP --set-dscp $d1 2>/dev/null || true
        sudo iptables -t mangle -A $chain $base -m u32 --u32 "${ue_u32_match[1]}" -j DSCP --set-dscp $d2 2>/dev/null || true
        sudo iptables -t mangle -A $chain $base -m u32 --u32 "${ue_u32_match[2]}" -j DSCP --set-dscp $d3 2>/dev/null || true
    done
    log_event "DL per UE: UE1=$d1 UE2=$d2 UE3=$d3 (u32만, offset=$U32_OFFSET)"
    echo "  ✓ DL per UE: UE1=$d1 UE2=$d2 UE3=$d3 (u32 offset=$U32_OFFSET)"
}

# DL: -s UPF_IP 한 규칙 (u32 불가 시 폴백). N3 전체 동일 DSCP.
set_dl_dscp_all() {
    local dscp_value=$1
    local upf_ip="$UPF_IP"
    if [ -z "$upf_ip" ]; then return 1; fi
    for dscp in 0 14 32; do
        sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp $dscp 2>/dev/null || true
        sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp $dscp 2>/dev/null || true
    done
    sudo iptables -t mangle -A PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    sudo iptables -t mangle -A INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    log_event "DL DSCP (N3 전체) = $dscp_value (-s $upf_ip)"
    echo "  ✓ DL DSCP = $dscp_value (N3 전체)"
}

# UL: UE별로 DSCP 설정 (네임스페이스별이라 UE0만 32/14, UE1/2는 0 유지 가능)
set_ul_dscp_ue() {
    local ue_index=$1
    local dscp_value=$2
    local ue_netns=("ue1" "ue2" "ue3")
    local ue_ul_ports=(6600 6601 6602)
    local ue_ns=${ue_netns[$ue_index]}
    local ul_port=${ue_ul_ports[$ue_index]}
    for dscp in 0 14 32; do
        sudo ip netns exec "$ue_ns" iptables -t mangle -D POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp $dscp 2>/dev/null || true
    done
    sudo ip netns exec "$ue_ns" iptables -t mangle -A POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    log_event "UL DSCP UE$ue_index = $dscp_value"
}

# iptables 규칙 정리 (DL: u32 + -s UPF_IP, UL: UE1 POSTROUTING)
cleanup_iptables_rules() {
    echo "[$(timestamp)] iptables 규칙 정리 중..."
    log_event "iptables 규칙 정리 시작"
    local upf_ip="${UPF_IP:-192.168.0.3}"
    local base="-s $upf_ip -p udp --dport $GTPU_PORT"
    for ue_idx in 0 1 2; do
        local u32="${ue_u32_match[$ue_idx]}"
        for dscp in 0 14 32; do
            sudo iptables -t mangle -D PREROUTING $base -m u32 --u32 "$u32" -j DSCP --set-dscp $dscp 2>/dev/null || true
            sudo iptables -t mangle -D INPUT $base -m u32 --u32 "$u32" -j DSCP --set-dscp $dscp 2>/dev/null || true
        done
    done
    for dscp in 0 14 32; do
        sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp $dscp 2>/dev/null || true
        sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp $dscp 2>/dev/null || true
    done
    for dscp in 0 14 32; do
        sudo ip netns exec ue1 iptables -t mangle -D POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport 6600 -j DSCP --set-dscp $dscp 2>/dev/null || true
    done
    log_event "iptables 규칙 정리 완료"
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

# 로그 파일 초기화
echo "==========================================" > "$LOG_FILE"
echo "  iperf3 Dynamic DSCP 테스트 로그" >> "$LOG_FILE"
echo "  시작 시간: $(timestamp_us)" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic DSCP 테스트 시작"
echo "=========================================="
echo ""
echo "[$(timestamp)] UPF_IP=$UPF_IP (N3 소스 IP, 다르면 export UPF_IP=... 로 설정)"
log_event "테스트 시작 (UPF_IP=$UPF_IP)"
echo ""

# 기존 iperf3 프로세스 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
log_event "기존 iperf3 프로세스 종료 시작"
{ sudo pkill -x iperf3 2>/dev/null || true; }
sleep 1
echo "[$(timestamp)] 프로세스 종료 완료"
log_event "기존 iperf3 프로세스 종료 완료"
echo ""

echo "[$(timestamp)] === 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="
log_event "Phase 0: iperf3 서버 시작 (DL 수신용)"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || echo "  ⚠ UE0 (ue1) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "UE0 (ue1) iperf3 서버 시작 - 포트 6500"
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || echo "  ⚠ UE1 (ue2) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "UE1 (ue2) iperf3 서버 시작 - 포트 6501"
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || echo "  ⚠ UE2 (ue3) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "UE2 (ue3) iperf3 서버 시작 - 포트 6502"

sleep 2

echo "[$(timestamp)] === 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
log_event "Phase 0: iperf3 서버 시작 (UL 수신용)"
iperf3 -s -p 6600 -D 2>/dev/null || echo "  ⚠ 포트 6600 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "외부 서버 iperf3 서버 시작 - 포트 6600"
iperf3 -s -p 6601 -D 2>/dev/null || echo "  ⚠ 포트 6601 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "외부 서버 iperf3 서버 시작 - 포트 6601"
iperf3 -s -p 6602 -D 2>/dev/null || echo "  ⚠ 포트 6602 서버 시작 실패 (이미 실행 중일 수 있음)"
log_event "외부 서버 iperf3 서버 시작 - 포트 6602"

sleep 2
echo ""

echo "=========================================="
echo "[$(timestamp)] === DSCP 시나리오: UE2/3 -S 0, UE1만 iptables (DL은 u32 또는 -s) ==="
echo "  DL: u32 가능 시 UE1만 32→14, UE2/3=0 / 불가 시 N3 전체 0→32→14"
echo "  UL: UE2/3 iperf -S 0, UE1만 iptables로 0→32→14"
echo "  DSCP가 안 들어가면: sudo modprobe xt_u32 후 재실행"
echo "=========================================="
echo ""

upf_ip="$UPF_IP"
if [ -z "$upf_ip" ]; then
    echo "  ✗ UPF_IP가 비어 있습니다. export UPF_IP=192.168.0.3 등으로 설정 후 재실행하세요."
    exit 1
fi

# u32 사용 가능 여부 (xt_u32 로드 후 규칙 1개 추가 시도)
USE_U32=0
sudo modprobe xt_u32 2>/dev/null || true
if sudo iptables -t mangle -A PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "52=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null; then
    sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "52=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null || true
    USE_U32=1
    echo "[$(timestamp)] xt_u32 사용 가능 → 오프셋 자동 probe (52 vs 56)..."
    log_event "u32 사용 가능, 오프셋 probe 시작"

    # 트래픽 켠 뒤 INPUT에서 52/56 중 pkts 오르는 오프셋 선택 (같은 호스트는 INPUT만 탐)
    iperf3 -c 10.45.0.2 -t 12 -p 6500 -i 1 >/dev/null 2>&1 &
    iperf3 -c 10.45.0.3 -t 12 -p 6501 -i 1 -S 0 >/dev/null 2>&1 &
    iperf3 -c 10.45.0.4 -t 12 -p 6502 -i 1 -S 0 >/dev/null 2>&1 &
    sleep 2
    sudo iptables -t mangle -A INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "52=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null || true
    sleep 5
    pkts52=$(sudo iptables -t mangle -L INPUT -n -v -x 2>/dev/null | grep -iE "0x34=0xa2d0002" | head -1 | awk '{print $1}')
    sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "52=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null || true
    pkts52=${pkts52:-0}

    sudo iptables -t mangle -A INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "56=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null || true
    sleep 5
    pkts56=$(sudo iptables -t mangle -L INPUT -n -v -x 2>/dev/null | grep -iE "0x38=0xa2d0002" | head -1 | awk '{print $1}')
    sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -m u32 --u32 "56=0x0A2D0002" -j DSCP --set-dscp 0 2>/dev/null || true
    pkts56=${pkts56:-0}

    wait 2>/dev/null || true
    if [ "${pkts52:-0}" -gt 0 ] 2>/dev/null; then
        U32_OFFSET=52
        echo "[$(timestamp)] probe 결과: offset 52 pkts=$pkts52 → U32_OFFSET=52 사용"
    elif [ "${pkts56:-0}" -gt 0 ] 2>/dev/null; then
        U32_OFFSET=56
        echo "[$(timestamp)] probe 결과: offset 56 pkts=$pkts56 → U32_OFFSET=56 사용"
    else
        U32_OFFSET=56
        echo "[$(timestamp)] probe 결과: 52/56 모두 pkts=0 → U32_OFFSET=56 유지 (fallback -s로 DSCP는 적용됨)"
    fi
    ue_u32_match=("${U32_OFFSET}=0x0A2D0002" "${U32_OFFSET}=0x0A2D0003" "${U32_OFFSET}=0x0A2D0004")
    log_event "U32_OFFSET=$U32_OFFSET (pkts52=$pkts52 pkts56=$pkts56)"
    echo ""
else
    echo "[$(timestamp)] xt_u32 불가 → DL은 N3 전체 동일값 (0→32→14)"
    echo "  (DSCP가 안 들어가면: sudo modprobe xt_u32 후 재실행)"
    log_event "u32 미사용 (DL N3 전체)"
fi
echo ""

# Phase 1: DL UE1/2/3=0 또는 N3 전체=0, UL UE1=0
echo "[$(timestamp)] Phase 1: DL=0, UL UE1=0 / UE2,3=-S 0 (20초)..."
log_event "Phase 1 시작: DL=0, UL UE1=0"
if [ "$USE_U32" = "1" ]; then
    set_dl_dscp_per_ue 0 0 0
else
    set_dl_dscp_all 0
fi
set_ul_dscp_ue 0 0
echo ""

# DL: UE1은 iptables로 바꿈. UE2/3는 -S 0 (DSCP 0 고정)
# UL: UE1은 iptables로 0→32→14. UE2/3는 -S 0 고정
echo "[$(timestamp)] DL/UL 트래픽 시작 (80초, UE2/3 -S 0)..."
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 -S 0 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 -S 0 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
sudo ip netns exec ue1 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6600 -i 1 > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
sudo ip netns exec ue2 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6601 -i 1 -S 0 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
sudo ip netns exec ue3 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6602 -i 1 -S 0 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
log_event "모든 UE DL/UL 트래픽 시작 (80초)"
echo "  ✓ 모든 UE 트래픽 시작됨 (DL/UL PIDs: $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID)"
echo ""

for i in {1..20}; do
    show_progress 1 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 1 완료 (20초 경과)"
log_event "Phase 1 완료 (20초 경과)"
echo ""

# Phase 2: DL UE1=32 UE2/3=0 (u32) 또는 N3 전체=32, UL UE1=32 UE2/3=0
echo "[$(timestamp)] Phase 2: DL UE1=32 UE2/3=0, UL UE1=32 (30초)..."
log_event "Phase 2 시작: DL UE1=32 UE2/3=0, UL UE1=32"
if [ "$USE_U32" = "1" ]; then
    set_dl_dscp_per_ue 32 0 0
else
    set_dl_dscp_all 32
fi
set_ul_dscp_ue 0 32
check_iptables_rules | tee -a "$LOG_FILE"
log_event "Phase 2 적용 완료"
echo ""

for i in {1..30}; do
    show_progress 2 $i 30
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 2 완료 (50초 경과)"
log_event "Phase 2 완료 (50초 경과)"
echo ""

# Phase 3: DL UE1=14 UE2/3=0 (u32) 또는 N3 전체=14, UL UE1=14 UE2/3=0
echo "[$(timestamp)] Phase 3: DL UE1=14 UE2/3=0, UL UE1=14 (30초)..."
log_event "Phase 3 시작: DL UE1=14 UE2/3=0, UL UE1=14"
if [ "$USE_U32" = "1" ]; then
    set_dl_dscp_per_ue 14 0 0
else
    set_dl_dscp_all 14
fi
set_ul_dscp_ue 0 14
check_iptables_rules | tee -a "$LOG_FILE"
log_event "Phase 3 적용 완료"
echo ""

for i in {1..30}; do
    show_progress 3 $i 30
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 3 완료 (80초 경과)"
log_event "Phase 3 완료 (80초 경과)"
echo ""

# 정리
echo "[$(timestamp)] 테스트 완료 - 모든 트래픽 중단 및 iptables 정리..."
log_event "테스트 완료 - 정리 시작"
cleanup_iptables_rules
kill $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
log_event "iperf3 클라이언트 종료 시도"
sleep 2
kill -9 $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
sudo pkill -x iperf3 2>/dev/null || true
log_event "정리 완료"
sleep 1
echo "  ✓ 모든 트래픽 중단 및 iptables 정리됨"
echo ""

echo "=========================================="
echo "[$(timestamp)] 테스트 완료!"
echo "=========================================="
log_event "테스트 완료 - 종료 시간: $(timestamp_us)"
echo ""
echo "[$(timestamp)] 로그 파일: $LOG_FILE"
echo "  확인: cat $LOG_FILE"
echo ""
