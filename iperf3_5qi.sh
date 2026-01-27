#!/bin/bash
# set -e 제거 (에러가 발생해도 계속 진행)

# SMF API 설정
# 기본값: http://127.0.0.4:7777/nsmf-pdusession/v1/qos-modify
# SMF는 127.0.0.4:7777에서 리스닝 (netstat으로 확인됨)
# 실제 주소가 다르면 환경변수로 설정: SMF_API=http://실제주소:포트/nsmf-pdusession/v1/qos-modify
SMF_API=${SMF_API:-"http://127.0.0.4:7777/nsmf-pdusession/v1/qos-modify"}

# UE 정보 설정
# UE0: imsi = 001010123456780 (설정 파일에서 확인)
# UE1: imsi = 001010123456790 (설정 파일에서 확인)
# UE2: imsi = 001010123456791 (설정 파일에서 확인)
UE0_SUPI=${UE0_SUPI:-"imsi-001010123456780"}
UE1_SUPI=${UE1_SUPI:-"imsi-001010123456790"}
UE2_SUPI=${UE2_SUPI:-"imsi-001010123456791"}
PSI=${PSI:-1}  # 기본값: 1 (Open5GS에서 첫 번째 PDU 세션의 PSI는 1)
QFI=${QFI:-1}

# 외부 서버 IP 설정
EXTERNAL_SERVER_IP=${EXTERNAL_SERVER_IP:-10.45.0.1}

# GBR/MBR 설정 (기본값, 환경변수로 오버라이드 가능)
# 일반 GBR 5QI (예: 5QI=3): GBR 5Mbps (srsRAN 스케줄러에서 dl_gbr = 5Mbps로 사용)
# delay_critical GBR 5QI (예: 5QI=85): GBR 25Mbps (srsRAN 스케줄러에서 dl_gbr = 25Mbps로 사용)
GBR_NORMAL_DL=${GBR_NORMAL_DL:-5000000}   # 일반 GBR DL (5 Mbps)
GBR_NORMAL_UL=${GBR_NORMAL_UL:-5000000}   # 일반 GBR UL (5 Mbps)
GBR_DELAY_CRITICAL_DL=${GBR_DELAY_CRITICAL_DL:-25000000}  # delay_critical GBR DL (25 Mbps)
GBR_DELAY_CRITICAL_UL=${GBR_DELAY_CRITICAL_UL:-25000000}  # delay_critical GBR UL (25 Mbps)

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
    local gbr_dl=${4:-0}  # Optional: GBR DL (bps), default 0
    local gbr_ul=${5:-0}  # Optional: GBR UL (bps), default 0
    local mbr_dl=${6:-0}  # Optional: MBR DL (bps), default 0
    local mbr_ul=${7:-0}  # Optional: MBR UL (bps), default 0

    echo "[$(timestamp)] $ue_name 5QI 변경 요청: 5QI=$new_5qi"

    # GBR QoS Flow (5QI 1-4, 65-67, 82-85)인 경우 안내 메시지
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

    # Python httpx 사용 시도 (HTTP/2 지원, 가장 안정적) - 우선순위 1
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
    # httpx가 없으면 설치 안내
    print("ERROR: httpx 모듈이 필요합니다 (HTTP/2 지원)")
    print("설치: pip3 install httpx")
    print("참고: requests는 HTTP/2를 지원하지 않아 Open5GS SMF와 호환되지 않습니다")
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
            echo "    설치: pip3 install httpx --break-system-packages"
            echo "    또는: sudo apt-get install python3-httpx"
        fi
    fi

    # nghttp2 클라이언트 사용 시도 (HTTP/2 네이티브 지원) - 우선순위 2
    if command -v nghttp >/dev/null 2>&1; then
        echo "  nghttp2 클라이언트 사용 중..."
        # JSON 데이터를 임시 파일로 생성
        json_data=$(mktemp)
        # JSON 객체 생성 (GBR/MBR 값이 제공된 경우에만 포함)
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

        # 임시 파일 삭제
        rm -f "$json_data"

        # nghttp 응답에서 HTTP 상태 코드 추출
        # nghttp는 ":status: 204" 형식으로 출력
        http_status=$(echo "$response" | grep -E ":status:|< HTTP" | grep -oE "[0-9]{3}" | head -1)

        # 에러 체크
        if echo "$response" | grep -q "RST_STREAM\|GOAWAY\|INTERNAL_ERROR"; then
            echo "  ✗ nghttp2 연결 오류 발생"
            echo "  응답 일부:"
            echo "$response" | grep -E "RST_STREAM|GOAWAY|INTERNAL_ERROR|error" | head -3
        elif [ "$http_status" = "204" ] || [ "$http_status" = "200" ]; then
            echo "  ✓ $ue_name 5QI 변경 성공 (HTTP $http_status)"
            return 0
        else
            echo "  ⚠ nghttp2 응답: HTTP ${http_status:-'알 수 없음'}"
            echo "  응답 일부:"
            echo "$response" | grep -E ":status:|HTTP|error|Error" | head -5
        fi
    fi

    # 마지막으로 curl 시도 (HTTP/2 업그레이드) - 우선순위 3
    echo "  curl 사용 중 (HTTP/2 업그레이드 시도)..."
    # JSON 객체 생성
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

    # HTTP 상태 코드가 유효한 숫자인지 확인
    if [ -n "$http_status" ] && [ "$http_status" != "" ] && [ "$http_status" != "000" ]; then
        if [ "$http_status" = "204" ] || [ "$http_status" = "200" ]; then
            echo "  ✓ $ue_name 5QI 변경 성공 (HTTP $http_status)"
            return 0
        else
            echo "  ✗ $ue_name 5QI 변경 실패 (HTTP $http_status)"
            echo "  응답: $response"
            return 1
        fi
    elif [ "$connection_success" -gt 0 ]; then
        echo "  ⚠ $ue_name 5QI 변경 요청 전송됨 (연결 성공, HTTP 상태 코드 없음)"
        echo "  참고: SMF 로그에서 'Modifying QoS Flow' 메시지 확인 필요"
        echo "  명령: sudo tail -f /var/log/open5gs/smf.log | grep -E 'Modifying QoS Flow|5QI|QFI'"
        return 0
    else
        echo "  ✗ $ue_name 5QI 변경 실패 (연결 실패)"
        echo "  응답: $response"
        echo ""
        echo "  해결 방법:"
        echo "  1. Python httpx 설치: pip3 install httpx --break-system-packages"
        echo "  2. 또는 시스템 패키지: sudo apt-get install python3-httpx"
        echo "  3. 또는 nghttp2 클라이언트: sudo apt-get install nghttp2-client"
        return 1
    fi
}

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "=========================================="
echo ""
echo "[$(timestamp)] HTTP/2 클라이언트 확인 중..."
check_http2_client
echo ""
echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "  시작 시간: $(timestamp)"
echo "=========================================="
echo ""

# SMF API 연결 확인
echo "[$(timestamp)] SMF API 연결 확인 중..."
    echo "  API 주소: $SMF_API"
    echo "  참고: Open5GS SMF는 HTTP/2를 사용합니다 (--http2 옵션 필요)"
    echo "  확인 방법:"
    echo "    - SMF 로그에서 SBI 서버 주소 확인"
    echo "    - netstat -tlnp | grep 7777 (또는 실제 포트)"
    echo "    - curl --http2 -v $SMF_API (연결 테스트)"
    echo ""
# 실제 연결 테스트 (HTTP/2 사용)
http_code=$(curl --http2 -s -o /dev/null -w "%{http_code}" -X POST "$SMF_API" \
    -H "Content-Type: application/json" \
    -d '{"supi":"test","psi":1,"qfi":1,"5qi":1}' 2>/dev/null || echo "000")
if [ "$http_code" != "000" ] && [ "$http_code" != "" ]; then
    echo "  ✓ SMF API 응답 (HTTP $http_code)"
else
    echo "  ⚠ SMF API 연결 실패 - 주소/포트를 확인하세요"
    echo "  일반적인 주소:"
    echo "    - http://127.0.0.4:7777/nsmf-pdusession/v1/qos-modify (기본값)"
    echo "    - http://localhost:7777/nsmf-pdusession/v1/qos-modify"
    echo "    - http://127.0.0.1:7777/nsmf-pdusession/v1/qos-modify"
    echo "  환경변수로 설정: SMF_API=http://실제주소:포트/nsmf-pdusession/v1/qos-modify"
fi
echo ""

# UE 정보 출력
echo "[$(timestamp)] UE 정보:"
echo "  UE0 SUPI: $UE0_SUPI"
echo "  UE1 SUPI: $UE1_SUPI"
echo "  UE2 SUPI: $UE2_SUPI"
echo "  PDU Session Identity (PSI): $PSI"
echo "  QoS Flow Identifier (QFI): $QFI"
echo ""

# GBR/MBR 설정 출력
echo "[$(timestamp)] GBR/MBR 설정 (srsRAN 스케줄러용):"
echo "  non-GBR 5QI (예: 5QI=9):"
echo "    MBR_DL: ${MBR_NON_GBR_DL} bps ($(echo "scale=2; ${MBR_NON_GBR_DL}/1000000" | bc 2>/dev/null || echo "$((${MBR_NON_GBR_DL}/1000000))") Mbps)"
echo "    MBR_UL: ${MBR_NON_GBR_UL} bps ($(echo "scale=2; ${MBR_NON_GBR_UL}/1000000" | bc 2>/dev/null || echo "$((${MBR_NON_GBR_UL}/1000000))") Mbps)"
echo "  delay_critical GBR 5QI (예: 5QI=85):"
echo "    GBR_DL: ${GBR_DELAY_CRITICAL_DL} bps ($(echo "scale=2; ${GBR_DELAY_CRITICAL_DL}/1000000" | bc 2>/dev/null || echo "$((${GBR_DELAY_CRITICAL_DL}/1000000))") Mbps)"
echo "    GBR_UL: ${GBR_DELAY_CRITICAL_UL} bps ($(echo "scale=2; ${GBR_DELAY_CRITICAL_UL}/1000000" | bc 2>/dev/null || echo "$((${GBR_DELAY_CRITICAL_UL}/1000000))") Mbps)"
echo "  참고: 환경변수로 값 변경 가능"
echo "    MBR_NON_GBR_DL=5000000 MBR_NON_GBR_UL=5000000 \\"
echo "    GBR_DELAY_CRITICAL_DL=25000000 GBR_DELAY_CRITICAL_UL=25000000 $0"
echo ""

# 기존 iperf3 프로세스 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
echo "[$(timestamp)] 프로세스 종료 완료"
echo ""

echo "[$(timestamp)] === 1단계: UE에서 iperf3 서버 시작 (DL 수신용) ==="
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || echo "  ⚠ UE0 (ue1) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || echo "  ⚠ UE1 (ue2) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || echo "  ⚠ UE2 (ue3) iperf3 서버 시작 실패 (이미 실행 중일 수 있음)"

sleep 2

echo "[$(timestamp)] === 2단계: 외부 서버에서 iperf3 서버 시작 (UL 수신용) ==="
iperf3 -s -p 6600 -D 2>/dev/null || echo "  ⚠ 포트 6600 서버 시작 실패 (이미 실행 중일 수 있음)"
iperf3 -s -p 6601 -D 2>/dev/null || echo "  ⚠ 포트 6601 서버 시작 실패 (이미 실행 중일 수 있음)"
iperf3 -s -p 6602 -D 2>/dev/null || echo "  ⚠ 포트 6602 서버 시작 실패 (이미 실행 중일 수 있음)"

sleep 2
echo ""

echo "=========================================="
echo "[$(timestamp)] === UE0만 5QI 동적 변경 테스트 (srsRAN 스케줄러용) ==="
echo "  Phase 1: 0-20초 - 모든 UE 기존 5QI (기본값 5QI=9, UE0/UE1/UE2 모두 실행)"
echo "  Phase 2: 20-30초 - UE0만 10초 중단 (UE1/UE2는 계속 실행)"
echo "  Phase 3: 30-50초 - UE0만 5QI=3 (GBR, GBR=${GBR_NORMAL_DL}/${GBR_NORMAL_UL} bps)로 변경하여 20초 실행 (UE1/UE2는 계속)"
echo "  Phase 4: 50-60초 - UE0만 10초 중단 (UE1/UE2는 계속 실행)"
echo "  Phase 5: 60-80초 - UE0만 5QI=85 (delay_critical GBR, GBR=${GBR_DELAY_CRITICAL_DL}/${GBR_DELAY_CRITICAL_UL} bps)로 변경하여 20초 실행 (UE1/UE2는 계속)"
echo "=========================================="
echo ""

# Phase 1: 모든 UE 기존 5QI (0-20초)
echo "[$(timestamp)] Phase 1: 모든 UE 트래픽 시작 (기존 5QI, 20초)..."
echo "  참고: 초기 5QI는 PDU Session 생성 시 설정된 값입니다."
echo ""

# DL 트래픽 시작 (모든 UE)
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!

# UL 트래픽 시작 (모든 UE)
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6600 -i 1 > /tmp/iperf3_ul0.log 2>&1 &
UL0_PID=$!
sudo ip netns exec ue2 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6601 -i 1 > /tmp/iperf3_ul1.log 2>&1 &
UL1_PID=$!
sudo ip netns exec ue3 iperf3 -c ${EXTERNAL_SERVER_IP} -t 80 -p 6602 -i 1 > /tmp/iperf3_ul2.log 2>&1 &
UL2_PID=$!

echo "  ✓ 모든 UE 트래픽 시작됨 (UE0/UE1/UE2 모두 기존 5QI)"
echo "  DL PIDs: UE0=$DL0_PID, UE1=$DL1_PID, UE2=$DL2_PID"
echo "  UL PIDs: UE0=$UL0_PID, UE1=$UL1_PID, UE2=$UL2_PID"
echo ""

# 0-20초 진행
for i in {1..20}; do
    show_progress 1 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 1 완료 (20초 경과)"
echo ""

# Phase 2: UE0만 10초 중단 (20-30초)
echo "[$(timestamp)] Phase 2: UE0만 10초 중단, UE1/UE2는 계속 실행..."
kill $DL0_PID $UL0_PID 2>/dev/null || true
echo "  ✓ UE0 트래픽 중단됨 (DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 20-30초 진행 (10초)
for i in {1..10}; do
    show_progress 2 $i 10
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 2 완료 (30초 경과)"
echo ""

# Phase 3: UE0만 5QI=3 (GBR)로 변경하여 20초 실행 (30-50초) - GBR 포함
echo "[$(timestamp)] Phase 3: UE0만 5QI=3 (GBR, GBR=${GBR_NORMAL_DL}/${GBR_NORMAL_UL} bps)로 변경하여 20초 실행, UE1/UE2는 계속..."
echo "[$(timestamp)] API 호출 전 - SMF 로그 확인 권장: tail -f /var/log/open5gs/smf.log | grep 'Modifying QoS Flow'"
change_5qi "$UE0_SUPI" 3 "UE0" "$GBR_NORMAL_DL" "$GBR_NORMAL_UL" 0 0
if [ $? -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI 변경 API 호출 성공 (5QI=3, GBR_DL=${GBR_NORMAL_DL} bps, GBR_UL=${GBR_NORMAL_UL} bps)"
    echo "[$(timestamp)] gNB에서 QoS Flow Modification 메시지 수신 확인 필요"
    echo "[$(timestamp)] 자원 할당 변경 확인: srsRAN 스케줄러에서 GBR 값 사용 확인 (기본 5QI=9에서 5QI=3 GBR로 변경)"
else
    echo "[$(timestamp)] ✗ UE0 5QI 변경 API 호출 실패 - 스크립트 계속 진행"
fi
echo ""

# UE0 트래픽 재시작
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 > /tmp/iperf3_dl0_phase3.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 > /tmp/iperf3_ul0_phase3.log 2>&1 &
UL0_PID=$!
echo "  ✓ UE0 트래픽 재시작됨 (5QI=3, GBR=${GBR_NORMAL_DL}/${GBR_NORMAL_UL} bps, DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 30-50초 진행 (20초)
for i in {1..20}; do
    show_progress 3 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 3 완료 (50초 경과)"
echo ""

# Phase 4: UE0만 10초 중단 (50-60초)
echo "[$(timestamp)] Phase 4: UE0만 10초 중단, UE1/UE2는 계속 실행..."
kill $DL0_PID $UL0_PID 2>/dev/null || true
echo "  ✓ UE0 트래픽 중단됨 (DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 50-60초 진행 (10초)
for i in {1..10}; do
    show_progress 4 $i 10
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 4 완료 (60초 경과)"
echo ""

# Phase 5: UE0만 5QI=85 (delay_critical GBR)로 변경하여 20초 실행 (60-80초) - GBR 포함
echo "[$(timestamp)] Phase 5: UE0만 5QI=85 (delay_critical GBR, GBR=${GBR_DELAY_CRITICAL_DL}/${GBR_DELAY_CRITICAL_UL} bps)로 변경하여 20초 실행, UE1/UE2는 계속..."
echo "[$(timestamp)] API 호출 전 - SMF 로그 확인 권장: tail -f /var/log/open5gs/smf.log | grep 'Modifying QoS Flow'"
change_5qi "$UE0_SUPI" 85 "UE0" "$GBR_DELAY_CRITICAL_DL" "$GBR_DELAY_CRITICAL_UL" 0 0
if [ $? -eq 0 ]; then
    echo "[$(timestamp)] ✓ UE0 5QI 변경 API 호출 성공 (5QI=85, GBR_DL=${GBR_DELAY_CRITICAL_DL} bps, GBR_UL=${GBR_DELAY_CRITICAL_UL} bps)"
    echo "[$(timestamp)] gNB에서 QoS Flow Modification 메시지 수신 확인 필요"
    echo "[$(timestamp)] 자원 할당 변경 확인: srsRAN 스케줄러에서 GBR 값 변경 확인 (5QI=3에서 5QI=85로, 일반 GBR에서 delay_critical GBR로)"
else
    echo "[$(timestamp)] ✗ UE0 5QI 변경 API 호출 실패 - 스크립트 계속 진행"
fi
echo ""

# UE0 트래픽 재시작
iperf3 -c 10.45.0.2 -t 20 -p 6500 -i 1 > /tmp/iperf3_dl0_phase5.log 2>&1 &
DL0_PID=$!
sudo ip netns exec ue1 iperf3 -c ${EXTERNAL_SERVER_IP} -t 20 -p 6600 -i 1 > /tmp/iperf3_ul0_phase5.log 2>&1 &
UL0_PID=$!
echo "  ✓ UE0 트래픽 재시작됨 (5QI=85, GBR=${GBR_DELAY_CRITICAL_DL}/${GBR_DELAY_CRITICAL_UL} bps, DL PID=$DL0_PID, UL PID=$UL0_PID)"
echo "  UE1/UE2는 계속 실행 중..."
echo ""

# 60-80초 진행 (20초)
for i in {1..20}; do
    show_progress 5 $i 20
    sleep 1
done
printf "\n"
echo "[$(timestamp)] Phase 5 완료 (80초 경과)"
echo ""

# 모든 프로세스 종료
echo "[$(timestamp)] 테스트 완료 - 모든 트래픽 중단 중..."
kill $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true
sleep 2
# 강제 종료 확인
{ kill -9 $DL0_PID $DL1_PID $DL2_PID $UL0_PID $UL1_PID $UL2_PID 2>/dev/null || true; } > /dev/null 2>&1
sleep 1

# 모든 iperf3 프로세스 종료
{ sudo pkill -x iperf3 2>&1 || true; } > /dev/null 2>&1
sleep 1
echo "  ✓ 모든 트래픽 중단됨"
echo ""

echo "=========================================="
echo "[$(timestamp)] 테스트 완료!"
echo "=========================================="
echo ""


