#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# 외부 서버 IP 설정 (UL 서버)
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# GTP-U UDP 포트 (표준 포트 2152)
GTPU_PORT=${GTPU_PORT:-2152}

# UPF IP 주소 (GTP-U 트래픽이 오는 소스 IP)
# UPF가 실제 네트워크 IP를 사용하도록 설정된 경우
UPF_IP=${UPF_IP:-10.53.1.1}

# gNB IP 주소 (GTP-U 트래픽이 들어오는 주소)
# 이 값은 실제 gNB 설정에 맞게 조정해야 합니다
GNB_IP=${GNB_IP:-$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' | head -1)}

# 타임스탬프 함수 (초 단위)
timestamp() {
    date '+%H:%M:%S'
}

# 마이크로초 단위 타임스탬프 함수 (6자리 마이크로초)
timestamp_us() {
    # date '+%H:%M:%S.%N'는 나노초까지 출력하므로, 처음 16자리만 사용 (HH:MM:SS.ffffff)
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
    sudo iptables -t mangle -L PREROUTING -n -v | grep -A1 "udp.*$GTPU_PORT" || echo "규칙을 찾을 수 없음"
    echo ""
}

# iptables를 사용한 DSCP 변경 함수
# 사용법: change_dscp_via_iptables <ue_index> <dscp_value>
# 예: change_dscp_via_iptables 0 32 (UE0의 DSCP를 32로 변경)
# 주의: DSCP 값은 0-63 범위 (6비트)
#       DL 트래픽: INPUT 체인 (gNB로 들어오는 패킷에 적용)
#       UL 트래픽: POSTROUTING 체인 (UE 네임스페이스에서 나가는 패킷)
change_dscp_via_iptables() {
    local ue_index=$1
    local dscp_value=$2  # DSCP 값 (0-63)
    
    # UE별 IP 주소 매핑
    local ue_ips=("10.45.0.2" "10.45.0.3" "10.45.0.4")
    local ue_netns=("ue1" "ue2" "ue3")
    local ue_dl_ports=(6500 6501 6502)
    local ue_ul_ports=(6600 6601 6602)
    
    local ue_ip=${ue_ips[$ue_index]}
    local ue_ns=${ue_netns[$ue_index]}
    local dl_port=${ue_dl_ports[$ue_index]}
    local ul_port=${ue_ul_ports[$ue_index]}
    
    # DL 트래픽: 외부에서 UE로 가는 트래픽
    # 실제로는 GTP-U UDP 패킷(포트 2152)의 ToS를 변경해야 합니다
    # PREROUTING 체인 사용 (라우팅 전에 적용, 외부에서 들어오는 패킷에 적용)
    # 기존 규칙 삭제 (에러 무시)
    # TCP 포트 규칙 삭제 (이전 버전 호환성)
    sudo iptables -t mangle -D PREROUTING -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp 0 2>/dev/null || true
    sudo iptables -t mangle -D PREROUTING -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    sudo iptables -t mangle -D INPUT -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp 0 2>/dev/null || true
    sudo iptables -t mangle -D INPUT -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    # UPF IP 자동 감지 (netstat로 확인)
    local upf_ip="$UPF_IP"
    if [ -z "$upf_ip" ] || [ "$upf_ip" = "auto" ]; then
        upf_ip=$(sudo netstat -ulnp 2>/dev/null | grep 2152 | grep -v "127.0.0" | awk '{print $4}' | cut -d: -f1 | head -1)
        if [ -z "$upf_ip" ]; then
            upf_ip="10.53.1.1"  # 기본값
        fi
    fi
    
    log_event "UPF IP: $upf_ip (DSCP 변경: $dscp_value)"
    
    # GTP-U UDP 포트 규칙 삭제 (UPF IP로 필터링)
    sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp 0 2>/dev/null || true
    sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp 0 2>/dev/null || true
    sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    # 새 규칙 추가 (PREROUTING 체인 - UPF에서 오는 GTP-U UDP 패킷에 DSCP 설정)
    local result1=$(sudo iptables -t mangle -A PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>&1)
    if [ $? -eq 0 ]; then
        log_event "iptables 규칙 추가 성공: PREROUTING -s $upf_ip -p udp --dport $GTPU_PORT -j DSCP --set-dscp $dscp_value"
        echo "  ✓ PREROUTING 규칙 추가됨 (UPF IP: $upf_ip)"
    else
        log_event "iptables 규칙 추가 실패: PREROUTING -s $upf_ip -p udp --dport $GTPU_PORT -j DSCP --set-dscp $dscp_value (에러: $result1)"
        echo "  ✗ PREROUTING 규칙 추가 실패: $result1"
    fi
    
    # INPUT 체인에도 추가 (로컬로 들어오는 패킷의 경우)
    local result2=$(sudo iptables -t mangle -A INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp_value" 2>&1)
    if [ $? -eq 0 ]; then
        log_event "iptables 규칙 추가 성공: INPUT -s $upf_ip -p udp --dport $GTPU_PORT -j DSCP --set-dscp $dscp_value"
        echo "  ✓ INPUT 규칙 추가됨"
    else
        log_event "iptables 규칙 추가 실패: INPUT -s $upf_ip -p udp --dport $GTPU_PORT -j DSCP --set-dscp $dscp_value (에러: $result2)"
        echo "  ✗ INPUT 규칙 추가 실패: $result2"
    fi
    
    # 규칙이 실제로 추가되었는지 확인
    echo "  규칙 확인:"
    sudo iptables -t mangle -L PREROUTING -n -v | grep -E "$upf_ip.*$GTPU_PORT.*DSCP" | head -1 || echo "    ✗ PREROUTING 규칙을 찾을 수 없음"
    sudo iptables -t mangle -L INPUT -n -v | grep -E "$upf_ip.*$GTPU_PORT.*DSCP" | head -1 || echo "    ✗ INPUT 규칙을 찾을 수 없음"
    
    # UL 트래픽: UE 네임스페이스에서 나가는 트래픽 (POSTROUTING 체인)
    # 기존 규칙 삭제 (에러 무시)
    sudo ip netns exec "$ue_ns" iptables -t mangle -D POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp 0 2>/dev/null || true
    sudo ip netns exec "$ue_ns" iptables -t mangle -D POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp "$dscp_value" 2>/dev/null || true
    # 새 규칙 추가
    sudo ip netns exec "$ue_ns" iptables -t mangle -A POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp "$dscp_value"
    
    log_event "DSCP 변경 (iptables): UE$ue_index, DSCP=$dscp_value (ToS=$((dscp_value << 2))) - DL:PREROUTING(UDP:$GTPU_PORT), UL:POSTROUTING"
}

# iptables 규칙 정리 함수
cleanup_iptables_rules() {
    echo "[$(timestamp)] iptables 규칙 정리 중..."
    log_event "iptables 규칙 정리 시작"
    
    # UPF IP 확인
    upf_ip="$UPF_IP"
    if [ -z "$upf_ip" ] || [ "$upf_ip" = "auto" ]; then
        upf_ip=$(sudo netstat -ulnp 2>/dev/null | grep 2152 | grep -v "127.0.0" | awk '{print $4}' | cut -d: -f1 | head -1)
        if [ -z "$upf_ip" ]; then
            upf_ip="10.53.1.1"  # 기본값
        fi
    fi
    
    # UE별 IP 주소 및 포트 매핑
    local ue_ips=("10.45.0.2" "10.45.0.3" "10.45.0.4")
    local ue_netns=("ue1" "ue2" "ue3")
    local ue_dl_ports=(6500 6501 6502)
    local ue_ul_ports=(6600 6601 6602)
    
    # GTP-U UDP 포트 규칙 삭제 (UPF IP로 필터링)
    for dscp in 0 14 32; do
        sudo iptables -t mangle -D PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp" 2>/dev/null || true
        sudo iptables -t mangle -D INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp "$dscp" 2>/dev/null || true
    done
    
    # 모든 가능한 DSCP 값에 대해 규칙 삭제 시도
    for ue_idx in 0 1 2; do
        local ue_ip=${ue_ips[$ue_idx]}
        local ue_ns=${ue_netns[$ue_idx]}
        local dl_port=${ue_dl_ports[$ue_idx]}
        local ul_port=${ue_ul_ports[$ue_idx]}
        
        # DL 트래픽 규칙 삭제 (PREROUTING 체인 - 이전 버전 호환성)
        for dscp in 0 14 32; do
            sudo iptables -t mangle -D PREROUTING -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp "$dscp" 2>/dev/null || true
            sudo iptables -t mangle -D INPUT -d "$ue_ip" -p tcp --dport "$dl_port" -j DSCP --set-dscp "$dscp" 2>/dev/null || true
        done
        
        # UL 트래픽 규칙 삭제 (UE 네임스페이스, POSTROUTING 체인)
        for dscp in 0 14 32; do
            sudo ip netns exec "$ue_ns" iptables -t mangle -D POSTROUTING -d "$EXTERNAL_SERVER_IP" -p tcp --dport "$ul_port" -j DSCP --set-dscp "$dscp" 2>/dev/null || true
        done
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
echo "[$(timestamp)] HTTP/2 클라이언트 확인 중..."
log_event "테스트 시작"
echo ""

# 기존 iperf3 프로세스 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
log_event "기존 iperf3 프로세스 종료 시작"
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
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
echo "[$(timestamp)] === UE0 DSCP 변경 패턴 테스트 (iptables 사용) ==="
echo "  Phase 1: 0-20초 - 모든 UE 트래픽 시작 (UE0/UE1/UE2 모두 DSCP=0)"
echo "  Phase 2: 20초 - UE0 DSCP=32로 변경 (iptables 사용, 중단 없음)"
echo "  Phase 3: 50초 - UE0 DSCP=14로 변경 (iptables 사용, 중단 없음)"
echo "  총 실행 시간: 80초"
echo "  방법: iptables를 사용하여 외부 IP 패킷의 DSCP를 동적으로 변경"
echo "        DSCP 변경 시 iperf3를 재시작하지 않음 (중단 없음)"
echo "        DL 트래픽: PREROUTING 체인 (라우팅 전에 적용, 외부에서 들어오는 패킷)"
echo "        UL 트래픽: POSTROUTING 체인 (UE 네임스페이스에서 나가는 패킷)"
echo "  참고: DSCP 값은 0-63 범위 (6비트)"
echo "        ToS = DSCP << 2 (예: DSCP=32 → ToS=0x80, DSCP=14 → ToS=0x38)"
echo "        srsRAN은 ToS 필드에서 (tos >> 2) & 0x3F로 DSCP를 추출함"
echo "        외부 IP 패킷의 DSCP가 내부 IP 패킷의 ToS로 복사됨 (코드 수정 완료)"
echo "=========================================="
echo ""

# Phase 1: 모든 UE 기존 DSCP (0-20초)
echo "[$(timestamp)] Phase 1: 모든 UE 트래픽 시작 (기존 DSCP=0, 20초)..."
log_event "Phase 1 시작: 모든 UE 트래픽 시작 (기존 DSCP=0, 0-20초)"
echo "  참고: 초기 DSCP는 0입니다."
echo ""

# DL 트래픽 시작 (모든 UE, iptables로 DSCP 마킹)
# UE0: 80초 동안 계속 실행 (중단 없음)
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
log_event "Phase 1: UE0 DL 트래픽 시작 (PID=$DL0_PID, DSCP=0 via iptables PREROUTING, 80초 동안 계속)"
# 초기 DSCP=0 설정 (iptables PREROUTING 체인 - UPF에서 오는 GTP-U UDP 패킷)
echo "  초기 iptables 규칙 추가 중 (DSCP=0)..."
# UPF IP 자동 감지
upf_ip="$UPF_IP"
if [ -z "$upf_ip" ] || [ "$upf_ip" = "auto" ]; then
    upf_ip=$(sudo netstat -ulnp 2>/dev/null | grep 2152 | grep -v "127.0.0" | awk '{print $4}' | cut -d: -f1 | head -1)
    if [ -z "$upf_ip" ]; then
        upf_ip="10.53.1.1"  # 기본값
    fi
fi
log_event "초기 UPF IP: $upf_ip"
if sudo iptables -t mangle -A PREROUTING -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp 0 2>&1; then
    log_event "초기 PREROUTING 규칙 추가 성공 (DSCP=0, UPF IP: $upf_ip)"
    echo "    ✓ PREROUTING 규칙 추가됨 (UPF IP: $upf_ip)"
else
    log_event "초기 PREROUTING 규칙 추가 실패 (DSCP=0, UPF IP: $upf_ip)"
    echo "    ✗ PREROUTING 규칙 추가 실패"
fi
if sudo iptables -t mangle -A INPUT -s "$upf_ip" -p udp --dport "$GTPU_PORT" -j DSCP --set-dscp 0 2>&1; then
    log_event "초기 INPUT 규칙 추가 성공 (DSCP=0, UPF IP: $upf_ip)"
    echo "    ✓ INPUT 규칙 추가됨"
else
    log_event "초기 INPUT 규칙 추가 실패 (DSCP=0, UPF IP: $upf_ip)"
    echo "    ✗ INPUT 규칙 추가 실패"
fi
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
log_event "Phase 1: UE1 DL 트래픽 시작 (PID=$DL1_PID, DSCP=0, 80초)"
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
log_event "Phase 1: UE2 DL 트래픽 시작 (PID=$DL2_PID, DSCP=0, 80초)"

# UL 트래픽 시작 (모든 UE, iptables로 DSCP 마킹)
# UE0: 80초 동안 계속 실행 (중단 없음)
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6600 -i 1 > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
log_event "Phase 1: UE0 UL 트래픽 시작 (PID=$UL0_PID, DSCP=0 via iptables POSTROUTING, 80초 동안 계속)"
# 초기 DSCP=0 설정 (iptables POSTROUTING 체인 - 라우팅 후 적용)
sudo ip netns exec ue1 iptables -t mangle -A POSTROUTING -d ${EXTERNAL_SERVER_IP} -p tcp --dport 6600 -j DSCP --set-dscp 0 2>/dev/null || true
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6601 -i 1 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
log_event "Phase 1: UE1 UL 트래픽 시작 (PID=$UL1_PID, DSCP=0, 80초)"
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6602 -i 1 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
log_event "Phase 1: UE2 UL 트래픽 시작 (PID=$UL2_PID, DSCP=0, 80초)"

echo "  ✓ 모든 UE 트래픽 시작됨 (UE0/UE1/UE2 모두 DSCP=0)"
echo "  DL PIDs: UE0=$DL0_PID, UE1=$DL1_PID, UE2=$DL2_PID"
echo "  UL PIDs: UE0=$UL0_PID, UE1=$UL1_PID, UE2=$UL2_PID"
echo ""

# 0-20초 진행 (Phase 1: DSCP=0)
for i in {1..20}; do
    show_progress 1 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 1 완료 (20초 경과, UE0은 계속 실행 중)"
log_event "Phase 1 완료 (20초 경과, UE0은 계속 실행 중)"
echo ""

# Phase 2: UE0 DSCP=32 변경 (20초, UE0은 계속 실행 중, 중단 없음)
echo "[$(timestamp)] Phase 2: UE0 DSCP=32로 변경 (iptables 사용, 중단 없음)..."
log_event "Phase 2 시작: UE0 DSCP=32 변경 (20초, iptables 사용)"
echo "  방법: iptables 규칙만 변경하여 패킷의 DSCP를 변경합니다"
echo "  UE0 프로세스는 계속 실행 중 (중단 없음)"
echo "  참고: DSCP=32는 ToS=0x80 (128 = 32 << 2)에 해당합니다"
echo ""
# iptables 규칙 변경 (DSCP=32)
change_dscp_via_iptables 0 32
# iptables 규칙 확인
check_iptables_rules | tee -a "$LOG_FILE"
log_event "Phase 2: UE0 DSCP 변경 완료 (iptables, DSCP=32, ToS=0x80, 중단 없음)"
echo "  ✓ UE0 DSCP 변경됨 (DSCP=32, ToS=0x80, 중단 없음 - iptables 사용)"
echo "  UE0 프로세스는 계속 실행 중 (PID: DL=$DL0_PID, UL=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 20-50초 진행 (Phase 2: DSCP=32, 30초)
for i in {1..30}; do
    show_progress 2 $i 30
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 2 완료 (50초 경과, UE0은 계속 실행 중)"
log_event "Phase 2 완료 (50초 경과, UE0은 계속 실행 중)"
echo ""

# Phase 3: UE0 DSCP=14 변경 (50초, UE0은 계속 실행 중, 중단 없음)
echo "[$(timestamp)] Phase 3: UE0 DSCP=14로 변경 (iptables 사용, 중단 없음)..."
log_event "Phase 3 시작: UE0 DSCP=14 변경 (50초, iptables 사용)"
echo "  방법: iptables 규칙만 변경하여 패킷의 DSCP를 변경합니다"
echo "  UE0 프로세스는 계속 실행 중 (중단 없음)"
echo "  참고: DSCP=14는 ToS=0x38 (56 = 14 << 2)에 해당합니다"
echo ""
# iptables 규칙 변경 (DSCP=14)
change_dscp_via_iptables 0 14
# iptables 규칙 확인
check_iptables_rules | tee -a "$LOG_FILE"
log_event "Phase 3: UE0 DSCP 변경 완료 (iptables, DSCP=14, ToS=0x38, 중단 없음)"
echo "  ✓ UE0 DSCP 변경됨 (DSCP=14, ToS=0x38, 중단 없음 - iptables 사용)"
echo "  UE0 프로세스는 계속 실행 중 (PID: DL=$DL0_PID, UL=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 50-80초 진행 (Phase 3: DSCP=14, 30초)
for i in {1..30}; do
    show_progress 3 $i 30
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 3 완료 (80초 경과)"
log_event "Phase 3 완료 (80초 경과)"
echo ""

# 모든 프로세스 종료
echo "[$(timestamp)] 테스트 완료 - 모든 트래픽 중단 중..."
log_event "테스트 완료 - 모든 트래픽 중단 시작"
# iptables 규칙 정리
cleanup_iptables_rules
kill $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
log_event "모든 iperf3 클라이언트 프로세스 종료 시도"
sleep 2
# 강제 종료 확인
{ kill -9 $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true; } > /dev/null 2>&1
sleep 1

# 모든 iperf3 프로세스 종료
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
log_event "모든 iperf3 프로세스 강제 종료 완료"
sleep 1
echo "  ✓ 모든 트래픽 중단됨"
echo ""

echo "=========================================="
echo "[$(timestamp)] 테스트 완료!"
echo "=========================================="
log_event "테스트 완료 - 종료 시간: $(timestamp_us)"
echo ""
echo "[$(timestamp)] 로그 파일 저장 위치: $LOG_FILE"
echo "  로그 확인: cat $LOG_FILE"
echo ""

