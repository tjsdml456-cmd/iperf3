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
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# GBR/MBR 설정 (GBR 20Mbps, delay_critical GBR 15Mbps)
GBR_NORMAL_DL=${GBR_NORMAL_DL:-20000000}
GBR_NORMAL_UL=${GBR_NORMAL_UL:-20000000}
GBR_DELAY_CRITICAL_DL=${GBR_DELAY_CRITICAL_DL:-15000000}
GBR_DELAY_CRITICAL_UL=${GBR_DELAY_CRITICAL_UL:-15000000}

# UE0 UDP 비트레이트 (Phase별): 9/66=20Mbps, 80=1Mbps, 84=15Mbps
UE0_UDP_RATE_P1=${UE0_UDP_RATE_P1:-20M}
UE0_UDP_RATE_P2=${UE0_UDP_RATE_P2:-20M}
UE0_UDP_RATE_P3=${UE0_UDP_RATE_P3:-1M}
UE0_UDP_RATE_P4=${UE0_UDP_RATE_P4:-15M}

# 타임스탬프 함수
timestamp() {
    date '+%H:%M:%S'
}

# 마이크로초 단위 타임스탬프 함수
timestamp_us() {
    date '+%H:%M:%S.%N' | cut -b1-16
}

# 로그 파일 경로
LOG_FILE="/tmp/iperf3_dynamic_5qi_test.log"

# 이벤트 로그 함수
log_event() {
    local msg="$1"
    local ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
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

# HTTP/2 클라이언트 확인 함수
check_http2_client() {
    if command -v python3 >/dev/null 2>&1 && python3 -c "import httpx" 2>/dev/null; then
        echo "✓ Python httpx 설치됨 (HTTP/2 지원)"
        return 0
    elif command -v nghttp >/dev/null 2>&1; then
        echo "✓ nghttp2 클라이언트 설치됨"
        return 0
    else
        echo "⚠ HTTP/2 클라이언트가 없습니다"
        echo ""
        echo "  설치 방법 (선택 1):"
        echo "    pip3 install httpx --break-system-packages"
        echo ""
        echo "  설치 방법 (선택 2):"
        echo "    sudo apt-get install python3-httpx"
        echo ""
        echo "  설치 방법 (선택 3):"
        echo "    sudo apt-get install nghttp2-client"
        echo ""
        return 1
    fi
}

# 5QI 변경 함수 (GBR/MBR 포함)
change_5qi() {
    local supi=$1
    local new_5qi=$2
    local ue_name=$3
    local gbr_dl=${4:-0}
    local gbr_ul=${5:-0}
    local mbr_dl=${6:-0}
    local mbr_ul=${7:-0}

    echo "[$(timestamp)] $ue_name 5QI 변경 요청: 5QI=$new_5qi"

    # GBR QoS Flow인 경우 안내 메시지
    if ((new_5qi >= 1 && new_5qi <= 4)) || ((new_5qi >= 65 && new_5qi <= 67)) || ((new_5qi >= 82 && new_5qi <= 85)); then
        if [ $gbr_dl -eq 0 ] && [ $gbr_ul -eq 0 ]; then
            echo "  ⚠ GBR QoS Flow (5QI=$new_5qi)이지만 GBR 값이 제공되지 않았습니다."
            echo "     SMF가 PCF에서 GBR 값을 가져오거나 기존 값을 유지합니다."
        else
            echo "  GBR 값 제공: GBR_DL=${gbr_dl} bps ($(echo "scale=2; $gbr_dl/1000000" | bc 2>/dev/null || echo "$(($gbr_dl/1000000))") Mbps), GBR_UL=${gbr_ul} bps ($(echo "scale=2; $gbr_ul/1000000" | bc 2>/dev/null || echo "$(($gbr_ul/1000000))") Mbps)"
        fi
    fi
    
    # MBR 값이 제공된 경우 안내 메시지
    if [ $mbr_dl -gt 0 ] || [ $mbr_ul -gt 0 ]; then
        echo "  MBR 값 제공: MBR_DL=${mbr_dl} bps ($(echo "scale=2; $mbr_dl/1000000" | bc 2>/dev/null || echo "$(($mbr_dl/1000000))") Mbps), MBR_UL=${mbr_ul} bps ($(echo "scale=2; $mbr_ul/1000000" | bc 2>/dev/null || echo "$(($mbr_ul/1000000))") Mbps)"
    fi

    # Python httpx 사용 시도
    if command -v python3 >/dev/null 2>&1; then
        echo "  Python httpx 사용 중..."
        python3 << PYTHON_EOF
import sys
import json
import os

api_url = "$SMF_API"
supi = "$supi"
psi = $PSI
qfi = $QFI
new_5qi = $new_5qi
gbr_dl = $gbr_dl
gbr_ul = $gbr_ul
mbr_dl = $mbr_dl
mbr_ul = $mbr_ul

try:
    import httpx
    client = httpx.Client(http2=True)
    request_data = {"supi": supi, "psi": psi, "qfi": qfi, "5qi": new_5qi}
    if gbr_dl > 0 or gbr_ul > 0:
        request_data["gbr_dl"] = gbr_dl
        request_data["gbr_ul"] = gbr_ul
    if mbr_dl > 0 or mbr_ul > 0:
        request_data["mbr_dl"] = mbr_dl
        request_data["mbr_ul"] = mbr_ul
    response = client.post(
        api_url,
        headers={"Content-Type": "application/json"},
        json=request_data,
        timeout=5.0
    )
    print(f"HTTP_STATUS:{response.status_code}")
    sys.exit(0 if response.status_code in [200, 204] else 1)
except ImportError:
    print("ERROR: httpx 모듈이 필요합니다 (HTTP/2 지원)")
    print("설치: pip3 install httpx")
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYTHON_EOF
        python_exit_code=$?
        if [ $python_exit_code -eq 0 ]; then
            echo "  ✓ $ue_name 5QI 변경 성공 (Python httpx)"
            return 0
        else
            echo "  ⚠ Python httpx 실패 - httpx 설치 필요"
        fi
    fi

    # nghttp2 클라이언트 사용 시도
    if command -v nghttp >/dev/null 2>&1; then
        echo "  nghttp2 클라이언트 사용 중..."
        json_data=$(mktemp)
        json_obj="{\"supi\": \"$supi\", \"psi\": $PSI, \"qfi\": $QFI, \"5qi\": $new_5qi"
        if [ $gbr_dl -gt 0 ] || [ $gbr_ul -gt 0 ]; then
            json_obj="${json_obj}, \"gbr_dl\": $gbr_dl, \"gbr_ul\": $gbr_ul"
        fi
        if [ $mbr_dl -gt 0 ] || [ $mbr_ul -gt 0 ]; then
            json_obj="${json_obj}, \"mbr_dl\": $mbr_dl, \"mbr_ul\": $mbr_ul"
        fi
        json_obj="${json_obj}}"
        echo "$json_obj" > "$json_data"

        response=$(nghttp -v -n \
            -H ":method: POST" \
            -H ":path: /nsmf-pdusession/v1/qos-modify" \
            -H "Content-Type: application/json" \
            --data="$json_data" \
            "$SMF_API" 2>&1)

        rm -f "$json_data"
        http_status=$(echo "$response" | grep -E ":status:|< HTTP" | grep -oE "[0-9]{3}" | head -1)

        if echo "$response" | grep -q "RST_STREAM\|GOAWAY\|INTERNAL_ERROR"; then
            echo "  ✗ nghttp2 연결 오류 발생"
        elif [ "$http_status" = "204" ] || [ "$http_status" = "200" ]; then
            echo "  ✓ $ue_name 5QI 변경 성공 (HTTP $http_status)"
            return 0
        else
            echo "  ⚠ nghttp2 응답: HTTP ${http_status:-'알 수 없음'}"
        fi
    fi

    # curl 시도
    echo "  curl 사용 중 (HTTP/2 업그레이드 시도)..."
    json_obj="{\"supi\": \"$supi\", \"psi\": $PSI, \"qfi\": $QFI, \"5qi\": $new_5qi"
    if [ $gbr_dl -gt 0 ] || [ $gbr_ul -gt 0 ]; then
        json_obj="${json_obj}, \"gbr_dl\": $gbr_dl, \"gbr_ul\": $gbr_ul"
    fi
    if [ $mbr_dl -gt 0 ] || [ $mbr_ul -gt 0 ]; then
        json_obj="${json_obj}, \"mbr_dl\": $mbr_dl, \"mbr_ul\": $mbr_ul"
    fi
    json_obj="${json_obj}}"
    response=$(curl --http2 -X POST "$SMF_API" \
        -H "Content-Type: application/json" \
        -d "$json_obj" \
        -w "\nHTTP_STATUS:%{http_code}" \
        -s 2>&1)

    http_status=$(echo "$response" | grep "HTTP_STATUS" | cut -d: -f2 | tr -d ' ' || echo "")
    connection_success=$(echo "$response" | grep -c "Connected to\|Empty reply" 2>/dev/null || echo "0")

    if [ -n "$http_status" ] && [ "$http_status" != "" ] && [ "$http_status" != "000" ]; then
        if [ "$http_status" = "204" ] || [ "$http_status" = "200" ]; then
            echo "  ✓ $ue_name 5QI 변경 성공 (HTTP $http_status)"
            return 0
        else
            echo "  ✗ $ue_name 5QI 변경 실패 (HTTP $http_status)"
            return 1
        fi
    elif [ "$connection_success" -gt 0 ]; then
        echo "  ⚠ $ue_name 5QI 변경 요청 전송됨 (연결 성공, HTTP 상태 코드 없음)"
        return 0
    else
        echo "  ✗ $ue_name 5QI 변경 실패 (연결 실패)"
        return 1
    fi
}

# 로그 파일 초기화
echo "==========================================" > "$LOG_FILE"
echo "  iperf3 Dynamic 5QI 테스트 로그" >> "$LOG_FILE"
echo "  UE0 UDP 20/20/1/15Mbps, UE1/2 TCP, GBR 20Mbps delay_critical 15Mbps (80초)" >> "$LOG_FILE"
echo "  UE1/2: 기존 5QI 유지" >> "$LOG_FILE"
echo "  시작 시간: $(timestamp_us)" >> "$LOG_FILE"
echo "==========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "  (UE0만 동적 5QI 변경)"
echo "=========================================="
echo ""
echo "[$(timestamp)] 5QI 시나리오:"
echo "  - UE0 (ue1): UDP, 5QI 9/66/80/84, 비트레이트 20/20/1/15 Mbps"
echo "  - UE1 (ue2)/UE2 (ue3): TCP, 기존 5QI 유지"
echo "  - GBR 20Mbps (66), delay_critical GBR 15Mbps (84), 테스트 80초"
log_event "테스트 시작 (UE0 동적 5QI 변경)"
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
echo "[$(timestamp)] === 5QI 시나리오: UE0만 동적 변경 (9→66→80→84) ==="
echo "  Phase 1: 0-20초  - UE0 5QI=9"
echo "  Phase 2: 20-40초 - UE0 5QI=66 (GBR, 20Mbps)"
echo "  Phase 3: 40-60초 - UE0 5QI=80 (non-GBR, 1Mbps)"
echo "  Phase 4: 60-80초 - UE0 5QI=84 (delay_critical GBR, 15Mbps)"
echo "  UE0=UDP(구간별 비트레이트), UE1/2=TCP, 테스트 시간: 80초"
echo "=========================================="
echo ""

# DL/UL 트래픽 시작 (80초, UE0만 동적 5QI 변경)
echo "[$(timestamp)] === DL/UL 트래픽 시작 (80초) ==="
echo "  UE0 UDP Phase1 ${UE0_UDP_RATE_P1}, UE1/2 TCP (기존 5QI 유지)"
log_event "트래픽 시작: UE0 동적 5QI, UE1/2 기존 5QI 유지"

# UE0 DL: UDP Phase1 20초
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -u -b ${UE0_UDP_RATE_P1} > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
log_event "UE0 DL 시작 (PID=$DL0_PID): UDP ${UE0_UDP_RATE_P1}"

# UE0 UL: UDP Phase1 20초
sudo ip netns exec ue1 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 20 -p 6600 -i 1 -u -b ${UE0_UDP_RATE_P1} > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
log_event "UE0 UL 시작 (PID=$UL0_PID): UDP ${UE0_UDP_RATE_P1}"

# UE1 DL: TCP 80초, 기존 5QI 유지
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
log_event "UE1 DL 시작 (PID=$DL1_PID): 기존 5QI 유지"

# UE1 UL: TCP 80초, 기존 5QI 유지
sudo ip netns exec ue2 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6601 -i 1 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
log_event "UE1 UL 시작 (PID=$UL1_PID): 기존 5QI 유지"

# UE2 DL: TCP 80초, 기존 5QI 유지
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!
log_event "UE2 DL 시작 (PID=$DL2_PID): 기존 5QI 유지"

# UE2 UL: TCP 80초, 기존 5QI 유지
sudo ip netns exec ue3 iperf3 -c "${EXTERNAL_SERVER_IP}" -t 80 -p 6602 -i 1 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!
log_event "UE2 UL 시작 (PID=$UL2_PID): 기존 5QI 유지"

echo "  ✓ 모든 UE 트래픽 시작됨"
echo "    DL PIDs: $DL0_PID $DL1_PID $DL2_PID"
echo "    UL PIDs: $UL0_PID $UL1_PID $UL2_PID"
echo ""
echo "  [예상 동작]"
echo "    UE0: UDP 구간별 20/20/1/15Mbps, 5QI 9→66→80→84"
echo "    UE1/2: TCP 70초, 기존 5QI 유지"
echo ""

# Phase 1: UE0 5QI=9 (0-20초)
echo "[$(timestamp)] Phase 1: UE0 5QI=9 설정 (20초)..."
log_event "Phase 1: UE0 5QI=9 변경 시작"
change_5qi "$UE0_SUPI" 9 "UE0" 0 0 0 0
CHANGE_RESULT=$?
if [ $CHANGE_RESULT -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI=9 설정 성공"
    log_event "UE0 5QI 변경 성공 (5QI=9) - 시점: $(timestamp_us)"
else
    echo "[$(timestamp)] ✗ UE0 5QI=9 설정 실패 - 스크립트 계속 진행"
    log_event "UE0 5QI 변경 실패 (5QI=9) - 시점: $(timestamp_us)"
fi
echo ""

for i in {1..20}; do
    show_progress 1 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 1 완료 (20초 경과)"
log_event "Phase 1 완료 (20초 경과)"
echo ""

# Phase 2: UE0 5QI=66 (20-40초), UE0 UDP 세그먼트 2 (20Mbps)
echo "[$(timestamp)] Phase 2: UE0 5QI=66 (GBR 20Mbps)로 변경, UE0 UDP ${UE0_UDP_RATE_P2} (20초)..."
log_event "Phase 2: UE0 5QI=66 변경 시작"
change_5qi "$UE0_SUPI" 66 "UE0" "$GBR_NORMAL_DL" "$GBR_NORMAL_UL" 0 0
CHANGE_RESULT=$?
if [ $CHANGE_RESULT -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI=66 변경 성공 (GBR 20Mbps)"
    log_event "UE0 5QI 변경 성공 (5QI=66) - 시점: $(timestamp_us)"
else
    echo "[$(timestamp)] ✗ UE0 5QI=66 변경 실패 - 스크립트 계속 진행"
    log_event "UE0 5QI 변경 실패 (5QI=66) - 시점: $(timestamp_us)"
fi
# UE0 UDP Phase2 20초
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -u -b ${UE0_UDP_RATE_P2} >> /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -u -b ${UE0_UDP_RATE_P2} >> /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
echo "  ✓ UE0 UDP Phase2 (${UE0_UDP_RATE_P2}) 시작"
echo ""

for i in {1..20}; do
    show_progress 2 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 2 완료 (40초 경과)"
log_event "Phase 2 완료 (40초 경과)"
echo ""

# Phase 3: UE0 5QI=80 (40-60초, non-GBR), UE0 UDP 세그먼트 3 (1Mbps)
echo "[$(timestamp)] Phase 3: UE0 5QI=80 (non-GBR)로 변경, UE0 UDP ${UE0_UDP_RATE_P3} (20초)..."
log_event "Phase 3: UE0 5QI=80 (non-GBR) 변경 시작"
change_5qi "$UE0_SUPI" 80 "UE0" 0 0 0 0
CHANGE_RESULT=$?
if [ $CHANGE_RESULT -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI=80 변경 성공 (non-GBR, 1Mbps)"
    log_event "UE0 5QI 변경 성공 (5QI=80, non-GBR) - 시점: $(timestamp_us)"
else
    echo "[$(timestamp)] ✗ UE0 5QI=80 변경 실패 - 스크립트 계속 진행"
    log_event "UE0 5QI 변경 실패 (5QI=80) - 시점: $(timestamp_us)"
fi
# UE0 UDP Phase3 20초
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -u -b ${UE0_UDP_RATE_P3} >> /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -u -b ${UE0_UDP_RATE_P3} >> /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
echo "  ✓ UE0 UDP Phase3 (${UE0_UDP_RATE_P3}) 시작"
echo ""

for i in {1..20}; do
    show_progress 3 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 3 완료 (60초 경과)"
log_event "Phase 3 완료 (60초 경과)"
echo ""

# Phase 4: UE0 5QI=84 (60-80초, delay_critical GBR), UE0 UDP 세그먼트 4 (15Mbps)
echo "[$(timestamp)] Phase 4: UE0 5QI=84 (delay_critical GBR 15Mbps)로 변경, UE0 UDP ${UE0_UDP_RATE_P4} (20초)..."
log_event "Phase 4: UE0 5QI=84 (delay_critical GBR) 변경 시작"
change_5qi "$UE0_SUPI" 84 "UE0" "$GBR_DELAY_CRITICAL_DL" "$GBR_DELAY_CRITICAL_UL" 0 0
CHANGE_RESULT=$?
if [ $CHANGE_RESULT -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI=84 변경 성공 (delay_critical GBR 15Mbps)"
    log_event "UE0 5QI 변경 성공 (5QI=84, delay_critical GBR) - 시점: $(timestamp_us)"
else
    echo "[$(timestamp)] ✗ UE0 5QI=84 변경 실패 - 스크립트 계속 진행"
    log_event "UE0 5QI 변경 실패 (5QI=84) - 시점: $(timestamp_us)"
fi
# UE0 UDP Phase4 20초
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 -u -b ${UE0_UDP_RATE_P4} >> /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 -u -b ${UE0_UDP_RATE_P4} >> /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
echo "  ✓ UE0 UDP Phase4 (${UE0_UDP_RATE_P4}) 시작"
echo ""

for i in {1..20}; do
    show_progress 4 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] 테스트 완료 (80초 경과)"
log_event "테스트 완료 (80초 경과)"
echo ""

# 정리
echo "[$(timestamp)] 테스트 완료 - 모든 트래픽 중단 중..."
log_event "테스트 완료 - 정리 시작"

# iperf3 프로세스 종료
kill $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
log_event "iperf3 클라이언트 종료 시도"
sleep 2
kill -9 $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
log_event "정리 완료"
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

# UE0 5QI 변경 시점 확인 (동적 테스트용)
echo "[$(timestamp)] === UE0 5QI 변경 시점 확인 ==="
if grep -i "5QI 변경" "$LOG_FILE" 2>/dev/null | grep -i "성공\|시작" > /dev/null; then
    echo "  ✓ UE0 5QI 변경 로그 확인됨"
    PHASE1_TIME=$(grep -i "Phase 1.*5QI.*변경\|5QI=9" "$LOG_FILE" 2>/dev/null | head -1 | grep -oE "\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\]" | head -1)
    PHASE2_TIME=$(grep -i "Phase 2.*5QI.*변경\|5QI=66" "$LOG_FILE" 2>/dev/null | head -1 | grep -oE "\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\]" | head -1)
    PHASE3_TIME=$(grep -i "Phase 3.*5QI.*변경\|5QI=80" "$LOG_FILE" 2>/dev/null | head -1 | grep -oE "\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\]" | head -1)
    PHASE4_TIME=$(grep -i "Phase 4.*5QI.*변경\|5QI=84" "$LOG_FILE" 2>/dev/null | head -1 | grep -oE "\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+\]" | head -1)
    [ -n "$PHASE1_TIME" ] && echo "    Phase 1 (5QI=9): $PHASE1_TIME"
    [ -n "$PHASE2_TIME" ] && echo "    Phase 2 (5QI=66): $PHASE2_TIME"
    [ -n "$PHASE3_TIME" ] && echo "    Phase 3 (5QI=80): $PHASE3_TIME"
    [ -n "$PHASE4_TIME" ] && echo "    Phase 4 (5QI=84): $PHASE4_TIME"
else
    echo "  ⚠ UE0 5QI 변경 로그 확인 실패"
fi
SMF_LOG="/var/log/open5gs/smf.log"
if [ -r "$SMF_LOG" ]; then
    SMF_CHANGES=$(sudo grep -i "modifying qos flow\|5qi.*$UE0_SUPI" "$SMF_LOG" 2>/dev/null | tail -3)
    [ -n "$SMF_CHANGES" ] && echo "  ✓ SMF 로그 5QI 변경 (최근 3건 확인)"
fi
echo ""

