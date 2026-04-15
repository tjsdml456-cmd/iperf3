#!/bin/bash
# iperf3 Dynamic 5QI Test Script
# UE0만 동적 5QI 변경: 20초 5QI=9 → 20초 5QI=3(GBR) → 20초 5QI=80(non-GBR) → 20초 5QI=84(GBR) (총 80초)
#
# 5QI 변경은 SMF REST가 아니라 UE NAS(PDU Session Modification Request) → AMF → SMF → … 경로만 사용.
# srsUE AF_UNIX SOCK_DGRAM 으로 한 줄 전송: MODIFY <psi> <qfi> <5qi> <gbr_dl> <gbr_ul> <mbr_dl> <mbr_ul>
#
# ue.conf 예: 5g_control_socket = /tmp/srsue0_nas5g_control
# 실행 예:    export UE0_NAS_SOCKET=/tmp/srsue0_nas5g_control
#
# 트래픽: DL만 (호스트 iperf 클라 → UE netns iperf 서버). UL iperf 없음.
# 의존: socat, awk, date

# set -e 제거 (에러가 발생해도 계속 진행)

# srsUE nas.5g_control_socket / ue.conf 5g_control_socket 과 동일 경로
UE0_NAS_SOCKET=${UE0_NAS_SOCKET:-/tmp/srsue0_nas5g_control}

PSI=${PSI:-1}
QFI=${QFI:-1}

# GBR/MBR 설정 (bps, NAS MODIFY용)
GBR_SENSOR_DL=${GBR_SENSOR_DL:-20000000}
GBR_SENSOR_UL=${GBR_SENSOR_UL:-20000000}
GBR_REMOTE_CTRL_DL=${GBR_REMOTE_CTRL_DL:-15000000}
GBR_REMOTE_CTRL_UL=${GBR_REMOTE_CTRL_UL:-15000000}

# UE0 UDP 비트레이트 (실제 트래픽은 80초 연속 20M 유지)
UE0_UDP_RATE=${UE0_UDP_RATE:-20M}

# 로그 파일 경로
LOG_FILE="/tmp/iperf3_dynamic_5qi_test.log"
# UE 런타임 로그 경로(선택): MODIFY 전송 직후 UE NAS 전송 로그 확인용
UE_LOG_FILE=${UE_LOG_FILE:-"/tmp/ue1.log"}

# 트래픽 시작 기준 시각(ns 단위)
TRAFFIC_START_EPOCH_NS=""

timestamp() {
    date '+%H:%M:%S'
}

timestamp_us() {
    date '+%H:%M:%S.%N' | cut -b1-16
}

log_event() {
    local msg="$1"
    local ts
    ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

show_progress() {
    local phase=$1
    local elapsed=$2
    local total=$3
    local percent=$((elapsed * 100 / total))
    local bars=$((percent / 2))
    local barstr
    barstr=$(printf '#%.0s' $(seq 1 $bars 2>/dev/null))
    printf "\r[$(timestamp)] Phase %s 진행 중: [%-50s] %d%% (%d/%d초)" \
        "$phase" "$barstr" "$percent" "$elapsed" "$total"
}

# UE NAS: MODIFY <psi> <qfi> <5qi> <gbr_dl> <gbr_ul> <mbr_dl> <mbr_ul> (bps; 0 = NAS에서 GBR/MBR 생략)
change_5qi_ue0() {
    local new_5qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    local mbr_dl=${4:-0}
    local mbr_ul=${5:-0}
    local ue_name="UE0"

    if [ -z "$UE0_NAS_SOCKET" ]; then
        echo "  ✗ $ue_name: UE0_NAS_SOCKET 이 비어 있음"
        return 1
    fi
    if [ ! -e "$UE0_NAS_SOCKET" ]; then
        echo "  ✗ $ue_name: srsUE 제어 소켓이 아직 없음: $UE0_NAS_SOCKET (UE 기동·PDU 세션 수립 후 경로 생성)"
        return 1
    fi

    echo "[$(timestamp)] $ue_name NAS → AMF 경로: MODIFY psi=$PSI qfi=$QFI 5qi=$new_5qi gbr_dl=$gbr_dl gbr_ul=$gbr_ul mbr_dl=$mbr_dl mbr_ul=$mbr_ul"

    if ! command -v socat >/dev/null 2>&1; then
        echo "  ✗ socat 이 필요합니다 (apt install socat)"
        return 1
    fi

    local line
    line=$(printf 'MODIFY %s %s %s %s %s %s %s' "$PSI" "$QFI" "$new_5qi" "$gbr_dl" "$gbr_ul" "$mbr_dl" "$mbr_ul")

    if err=$(printf '%s\n' "$line" | socat - UNIX-SENDTO:"$UE0_NAS_SOCKET" 2>&1); then
        echo "  ✓ $ue_name MODIFY 전송 완료 (UE NAS)"
        return 0
    fi
    if echo "$err" | grep -qi "Permission denied" && command -v sudo >/dev/null 2>&1; then
        echo "  ⚠ 소켓 권한 문제로 sudo 재시도..."
        if err2=$(sudo bash -c "printf '%s\n' \"$line\" | socat - UNIX-SENDTO:\"$UE0_NAS_SOCKET\"" 2>&1); then
            echo "  ✓ $ue_name MODIFY 전송 완료 (UE NAS, sudo)"
            return 0
        fi
        echo "  ✗ $ue_name socat(sudo) 전송 실패: $err2"
        return 1
    fi
    echo "  ✗ $ue_name socat 전송 실패: $err"
    return 1
}

verify_modify_propagation() {
    local expected_5qi=$1

    # UE 측에서 실제 NAS Modify 송신 여부 확인
    if [ -r "$UE_LOG_FILE" ]; then
        if tail -n 200 "$UE_LOG_FILE" | grep -q "Sending PDU Session Modification Request"; then
            log_event "검증(UE): PDU Session Modification Request 송신 로그 확인"
        else
            log_event "검증(UE): 송신 로그 미확인 (UE_LOG_FILE=$UE_LOG_FILE)"
        fi
    else
        log_event "검증(UE): UE 로그 파일 접근 불가 (UE_LOG_FILE=$UE_LOG_FILE)"
    fi

    # SMF 측에서 5QI 반영 여부 확인
    if [ -r "$SMF_LOG" ]; then
        if tail -n 200 "$SMF_LOG" | grep -q "5QI=${expected_5qi}"; then
            log_event "검증(SMF): 5QI=${expected_5qi} 반영 로그 확인"
        else
            log_event "검증(SMF): 5QI=${expected_5qi} 로그 미확인 (tail 200 기준)"
        fi
    else
        log_event "검증(SMF): SMF 로그 접근 불가 (SMF_LOG=$SMF_LOG)"
    fi
}

# 로그 초기화
{
echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 로그"
echo "  시작 시간: $(timestamp_us)"
echo "  UE0_NAS_SOCKET=$UE0_NAS_SOCKET (UE NAS only, no SMF REST)"
echo "  Traffic: DL only (host iperf -c → UE netns iperf -s)"
echo "=========================================="
echo ""
} > "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "  (UE0만 동적 5QI 변경 — NAS → AMF → SMF)"
echo "  UE0_NAS_SOCKET=$UE0_NAS_SOCKET"
echo "=========================================="
echo ""
echo "[$(timestamp)] 시나리오 (DL만):"
echo "  - UE0 (ue1): UDP DL, 80초 연속 ${UE0_UDP_RATE}, 5QI 9 → 3 → 80 → 84"
echo "    * 5QI=9  : Best-effort (PDB 300ms, non-GBR)"
echo "    * 5QI=3  : Sensor streaming (PDB 50ms, GBR 20Mbps)"
echo "    * 5QI=80 : Emergency braking (PDB 10ms, non-GBR)"
echo "    * 5QI=84 : Remote control (PDB 30ms, GBR 15Mbps)"
echo "  - UE1 (ue2), UE2 (ue3): TCP DL, 기존 5QI 유지"
echo "  - 테스트 시간: 총 80초"
echo ""
echo "[$(timestamp)] srsUE ue.conf: 5g_control_socket=$UE0_NAS_SOCKET (또는 --nas.5g_control_socket)"
echo "  수동 테스트: printf 'MODIFY 1 1 9 0 0 0 0\\n' | socat - UNIX-SENDTO:$UE0_NAS_SOCKET"
echo ""

log_event "테스트 시작"
SMF_LOG="/var/log/open5gs/smf.log"
# 기존 iperf3 종료
echo "[$(timestamp)] 기존 iperf3 프로세스 종료 중..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
echo "[$(timestamp)] 기존 iperf3 종료 완료"
log_event "기존 iperf3 종료 완료"
echo ""

# UE 쪽 서버 시작 (DL 수신용)
echo "[$(timestamp)] UE iperf3 서버 시작"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || echo "  ⚠ ue1 서버 이미 실행 중"
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || echo "  ⚠ ue2 서버 이미 실행 중"
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || echo "  ⚠ ue3 서버 이미 실행 중"
log_event "UE iperf3 서버 시작 완료"

sleep 2
echo ""

echo "=========================================="
echo "[$(timestamp)] 트래픽 시작"
echo "  Phase 1: 0-20초   UE0 5QI=9"
echo "  Phase 2: 20-40초  UE0 5QI=3 (GBR 20Mbps)"
echo "  Phase 3: 40-60초  UE0 5QI=80 (non-GBR)"
echo "  Phase 4: 60-80초  UE0 5QI=84 (GBR 15Mbps)"
echo "=========================================="
echo ""

TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "트래픽 기준 시각(EPOCH_NS): ${TRAFFIC_START_EPOCH_NS}"

# UE0 UDP DL 80초 (호스트 → UE)
iperf3 -c 10.45.0.2 -t 80 -p 6500 -i 1 -u -b "${UE0_UDP_RATE}" > /tmp/iperf3_dl0.log 2>&1 &
DL0_PID=$!

# UE1 TCP DL 80초
iperf3 -c 10.45.0.3 -t 80 -p 6501 -i 1 > /tmp/iperf3_dl1.log 2>&1 &
DL1_PID=$!

# UE2 TCP DL 80초
iperf3 -c 10.45.0.4 -t 80 -p 6502 -i 1 > /tmp/iperf3_dl2.log 2>&1 &
DL2_PID=$!

echo "[$(timestamp)] DL 트래픽 시작 완료"
echo "  DL PID: $DL0_PID $DL1_PID $DL2_PID"
log_event "DL 트래픽 시작 완료"
echo ""

# Phase 1
echo "[$(timestamp)] Phase 1: UE0 5QI=9"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 1 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi_ue0 9 0 0 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=9 변경 성공"
    sleep 1
    verify_modify_propagation 9
else
    log_event "UE0 5QI=9 변경 실패"
fi

for i in {1..20}; do
    show_progress 1 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 1 완료"
echo ""

# Phase 2
echo "[$(timestamp)] Phase 2: UE0 5QI=3 (Sensor streaming, GBR 20Mbps)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 2 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi_ue0 3 "$GBR_SENSOR_DL" "$GBR_SENSOR_UL" 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=3 변경 성공"
    sleep 1
    verify_modify_propagation 3
else
    log_event "UE0 5QI=3 변경 실패"
fi

for i in {1..20}; do
    show_progress 2 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 2 완료"
echo ""

# Phase 3
echo "[$(timestamp)] Phase 3: UE0 5QI=80 (non-GBR)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 3 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi_ue0 80 0 0 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=80 변경 성공"
    sleep 1
    verify_modify_propagation 80
else
    log_event "UE0 5QI=80 변경 실패"
fi

for i in {1..20}; do
    show_progress 3 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 3 완료"
echo ""

# Phase 4
echo "[$(timestamp)] Phase 4: UE0 5QI=84 (Remote control, GBR 15Mbps)"
PHASE_EPOCH_NS=$(date +%s%N)
REL_SEC=$(awk "BEGIN {printf \"%.4f\", ($PHASE_EPOCH_NS - $TRAFFIC_START_EPOCH_NS)/1000000000}")
log_event "Phase 4 시작 (트래픽 시작 후 ${REL_SEC}초)"
change_5qi_ue0 84 "$GBR_REMOTE_CTRL_DL" "$GBR_REMOTE_CTRL_UL" 0 0
if [ $? -eq 0 ]; then
    log_event "UE0 5QI=84 변경 성공"
    sleep 1
    verify_modify_propagation 84
else
    log_event "UE0 5QI=84 변경 실패"
fi

for i in {1..20}; do
    show_progress 4 "$i" 20
    sleep 1
done
printf "\n"
log_event "Phase 4 완료"
echo ""

# 정리
echo "[$(timestamp)] 테스트 완료 - 정리 중..."
log_event "정리 시작"

kill "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

log_event "정리 완료"

echo ""
echo "=========================================="
echo "[$(timestamp)] 테스트 완료"
echo "=========================================="
echo "로그 파일: $LOG_FILE"
echo "확인 명령: cat $LOG_FILE"
echo ""

# NAS → AMF → SMF 이후 코어에서 처리됐는지 참고용 (REST 호출 없음)
if [ -r "$SMF_LOG" ]; then
    echo "[$(timestamp)] 최근 SMF 로그 (UE NAS로 유발된 절차 확인용):"
    sudo tail -n 20 "$SMF_LOG"
else
    echo "[$(timestamp)] SMF 로그 생략 ($SMF_LOG 없음 또는 권한)"
fi
