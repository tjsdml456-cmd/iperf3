#!/bin/bash
# iperf3 Dynamic 5QI Test Script (NAS only, no SMF REST)
# UE0(UDP): 1초마다 5QI 전환, 패턴 9 -> 3 -> 80 -> 84 -> 9 반복
#   - 기본: 100주기, 총 400 transitions (1초 간격, 마지막 전환 시각 400.0초)
# UE1/UE2(TCP): 기존 5QI 유지, DL background traffic
# 의존: socat, awk, date

# set -e 미사용: 중간 실패가 있어도 테스트 지속
set -u
export LC_ALL=C

UE0_NAS_SOCKET=${UE0_NAS_SOCKET:-/tmp/srsue0_nas5g_control}
PSI=${PSI:-1}
QFI=${QFI:-1}

# 5QI 전환 주기/횟수
STEP_SEC=${STEP_SEC:-0.2}
CYCLES=${CYCLES:-100}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=400
TOTAL_DUR=${TOTAL_DUR:-82}

# GBR/MBR 설정 (bps, NAS MODIFY용)
GBR_SENSOR_DL=${GBR_SENSOR_DL:-20000000}
GBR_SENSOR_UL=${GBR_SENSOR_UL:-20000000}
GBR_REMOTE_CTRL_DL=${GBR_REMOTE_CTRL_DL:-15000000}
GBR_REMOTE_CTRL_UL=${GBR_REMOTE_CTRL_UL:-15000000}

# 트래픽 설정
UE0_UDP_RATE=${UE0_UDP_RATE:-20M}
UE1_IP=${UE1_IP:-10.45.0.3}
UE2_IP=${UE2_IP:-10.45.0.4}

# 전송 모드 설정
# ASYNC_SEND=1 이면 MODIFY 전송을 백그라운드로 던지고 루프는 대기 없이 진행.
ASYNC_SEND=${ASYNC_SEND:-0}
MAX_INFLIGHT=${MAX_INFLIGHT:-8}

LOG_FILE=${LOG_FILE:-/tmp/iperf3_dynamic_5qi_100cycles_dl.log}
UE0_LOG=${UE0_LOG:-/tmp/iperf3_dl0.log}
UE1_LOG=${UE1_LOG:-/tmp/iperf3_dl1.log}
UE2_LOG=${UE2_LOG:-/tmp/iperf3_dl2.log}
ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_dynamic_5qi_async_send.log}

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

log_event() {
    local msg="$1"
    local ts
    ts=$(timestamp_us)
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

show_progress() {
    local elapsed=$1
    local total=$2
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] 진행: [%-50s] %d%% (%d/%d초)" \
        "$(printf '#%.0s' $(seq 1 $((percent / 2)) 2>/dev/null))" "$percent" "$elapsed" "$total"
}

# UE NAS: MODIFY <psi> <qfi> <5qi> <gbr_dl> <gbr_ul> <mbr_dl> <mbr_ul>
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
        echo "  ✗ $ue_name: srsUE 제어 소켓이 없음: $UE0_NAS_SOCKET"
        return 1
    fi
    if ! command -v socat >/dev/null 2>&1; then
        echo "  ✗ socat 필요 (apt install socat)"
        return 1
    fi

    local line
    line=$(printf 'MODIFY %s %s %s %s %s %s %s' "$PSI" "$QFI" "$new_5qi" "$gbr_dl" "$gbr_ul" "$mbr_dl" "$mbr_ul")
    echo "[$(timestamp)] $ue_name NAS MODIFY: $line"

    if err=$(printf '%s\n' "$line" | socat - UNIX-SENDTO:"$UE0_NAS_SOCKET" 2>&1); then
        return 0
    fi
    if echo "$err" | grep -qi "Permission denied" && command -v sudo >/dev/null 2>&1; then
        if err2=$(sudo bash -c "printf '%s\n' \"$line\" | socat - UNIX-SENDTO:\"$UE0_NAS_SOCKET\"" 2>&1); then
            return 0
        fi
        echo "  ✗ $ue_name socat(sudo) 실패: $err2"
        return 1
    fi
    echo "  ✗ $ue_name socat 실패: $err"
    return 1
}

change_5qi_with_profile() {
    local q=$1
    case "$q" in
        3)  change_5qi_ue0 "$q" "$GBR_SENSOR_DL" "$GBR_SENSOR_UL" 0 0 ;;
        84) change_5qi_ue0 "$q" "$GBR_REMOTE_CTRL_DL" "$GBR_REMOTE_CTRL_UL" 0 0 ;;
        *)  change_5qi_ue0 "$q" 0 0 0 0 ;;
    esac
}

change_5qi_with_profile_async() {
    local q=$1
    local rel=$2
    local idx=$3

    # 너무 많은 전송이 동시에 쌓이지 않도록 상한선 적용
    while true; do
        local inflight
        inflight=$(jobs -rp | wc -l)
        if [ "$inflight" -lt "$MAX_INFLIGHT" ]; then
            break
        fi
        sleep 0.02
    done

    (
        if change_5qi_with_profile "$q"; then
            log_event "t=${rel}s transition#${idx} 5QI=${q} 성공 (async)"
        else
            log_event "t=${rel}s transition#${idx} 5QI=${q} 실패 (async)"
        fi
    ) >> "$ASYNC_LOG" 2>&1 &
}

LAST_CHANGE_TIME=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
TOTAL_DUR_MIN=$(awk -v t="$LAST_CHANGE_TIME" 'BEGIN{printf "%d", int(t)+1}')
if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then
    echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS."
    exit 1
fi
if [ "$TOTAL_DUR" -lt "$TOTAL_DUR_MIN" ]; then
    echo "ERROR: TOTAL_DUR=$TOTAL_DUR is too short. Need >= $TOTAL_DUR_MIN."
    exit 1
fi

{
echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 로그 (1s switching)"
echo "  시작 시간: $(timestamp_us)"
echo "  UE0_NAS_SOCKET=$UE0_NAS_SOCKET (UE NAS only)"
echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR"
echo "=========================================="
echo ""
} > "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 시작"
echo "  UE0 NAS 5QI 전환: 9 -> 3 -> 80 -> 84 -> 9 반복"
echo "=========================================="
echo ""
echo "  - 전환 간격: ${STEP_SEC}s"
echo "  - 주기 수: ${CYCLES} (총 전환 ${TRANSITIONS}회)"
echo "  - 마지막 전환 시각: ${LAST_CHANGE_TIME}s"
echo "  - 트래픽 총 길이: ${TOTAL_DUR}s"
echo "  - 전송 모드: ASYNC_SEND=${ASYNC_SEND} (MAX_INFLIGHT=${MAX_INFLIGHT})"
echo ""

log_event "테스트 시작"

echo "[$(timestamp)] 기존 iperf3 종료..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
log_event "기존 iperf3 종료 완료"

echo "[$(timestamp)] UE iperf3 서버 시작"
sudo ip netns exec ue1 iperf3 -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 iperf3 -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 iperf3 -s -p 6502 -D 2>/dev/null || true
sleep 2

echo "=========================================="
echo "[$(timestamp)] 트래픽 시작 (${TOTAL_DUR}초) — DL"
echo "  UE0: UDP ${UE0_UDP_RATE}, NAS 5QI switching"
echo "  UE1/UE2: TCP background"
echo "=========================================="
log_event "DL 트래픽 시작"

iperf3 -c 10.45.0.2 -t "$TOTAL_DUR" -p 6500 -i 1 -u -b "${UE0_UDP_RATE}" > "$UE0_LOG" 2>&1 &
DL0_PID=$!
iperf3 -c "$UE1_IP" -t "$TOTAL_DUR" -p 6501 -i 1 > "$UE1_LOG" 2>&1 &
DL1_PID=$!
iperf3 -c "$UE2_IP" -t "$TOTAL_DUR" -p 6502 -i 1 > "$UE2_LOG" 2>&1 &
DL2_PID=$!

echo "[$(timestamp)] DL PID: $DL0_PID $DL1_PID $DL2_PID"

TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "트래픽 기준 시각(EPOCH_NS): ${TRAFFIC_START_EPOCH_NS}"

# 초기 상태(t=0): 5QI=9
change_5qi_with_profile 9
if [ $? -eq 0 ]; then
    log_event "t=0.0000s 5QI=9 적용"
else
    log_event "t=0.0000s 5QI=9 적용 실패"
fi

pattern=(9 3 80 84)
next_progress_sec=1

for i in $(seq 1 "$TRANSITIONS"); do
    sleep "$STEP_SEC"

    idx=$((i % 4))
    q="${pattern[$idx]}"
    rel_sec=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.4f", s*n}')

    if [ "$ASYNC_SEND" = "1" ]; then
        change_5qi_with_profile_async "$q" "$rel_sec" "$i"
        log_event "t=${rel_sec}s transition#${i} 5QI=${q} 전송 (async dispatch)"
    else
        if change_5qi_with_profile "$q"; then
            log_event "t=${rel_sec}s transition#${i} 5QI=${q} 성공"
        else
            log_event "t=${rel_sec}s transition#${i} 5QI=${q} 실패"
        fi
    fi

    elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
    if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
        show_progress "$elapsed_int" "$TOTAL_DUR"
        next_progress_sec=$((elapsed_int + 1))
    fi
done

# 백그라운드 async 전송들이 남아 있으면 정리 전에 잠깐 대기
if [ "$ASYNC_SEND" = "1" ]; then
    wait 2>/dev/null || true
fi

elapsed_after_switch=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
remaining=$(awk -v t="$TOTAL_DUR" -v e="$elapsed_after_switch" 'BEGIN{r=t-e; if (r<0) r=0; printf "%.6f", r}')
remaining_int=$(awk -v r="$remaining" 'BEGIN{printf "%d", int(r+0.999999)}')

for i in $(seq 1 "$remaining_int"); do
    show_progress "$((TOTAL_DUR - remaining_int + i))" "$TOTAL_DUR"
    sleep 1
done
printf "\n"

wait "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true

log_event "정리 시작"
kill "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
log_event "정리 완료"

echo "=========================================="
echo "[$(timestamp)] 테스트 완료"
echo "  로그: $LOG_FILE"
echo "  UE0: $UE0_LOG"
echo "  UE1: $UE1_LOG"
echo "  UE2: $UE2_LOG"
echo "=========================================="
