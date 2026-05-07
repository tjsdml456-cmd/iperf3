#!/bin/bash
# iperf3 Dynamic 5QI Test Script (NAS only, no SMF REST) - UL version
set -u
export LC_ALL=C

UE0_NAS_SOCKET=${UE0_NAS_SOCKET:-/tmp/srsue0_nas5g_control}
PSI=${PSI:-1}
QFI=${QFI:-1}
STEP_SEC=${STEP_SEC:-0.2}
CYCLES=${CYCLES:-100}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=400
TOTAL_DUR=${TOTAL_DUR:-82}
GBR_SENSOR_DL=${GBR_SENSOR_DL:-20000000}
GBR_SENSOR_UL=${GBR_SENSOR_UL:-20000000}
GBR_REMOTE_CTRL_DL=${GBR_REMOTE_CTRL_DL:-15000000}
GBR_REMOTE_CTRL_UL=${GBR_REMOTE_CTRL_UL:-15000000}

# UL target (host/UPF side)
SERVER_IP=${SERVER_IP:-10.45.0.1}
UE0_UDP_RATE=${UE0_UDP_RATE:-20M}

# Namespace mapping (adjust if different)
UE0_NS=${UE0_NS:-ue1}
UE1_NS=${UE1_NS:-ue2}
UE2_NS=${UE2_NS:-ue3}

# Ports
UE0_PORT=${UE0_PORT:-6500}
UE1_PORT=${UE1_PORT:-6501}
UE2_PORT=${UE2_PORT:-6502}

ASYNC_SEND=${ASYNC_SEND:-0}
MAX_INFLIGHT=${MAX_INFLIGHT:-8}

LOG_FILE=${LOG_FILE:-/tmp/iperf3_dynamic_5qi_100cycles_ul.log}
UE0_LOG=${UE0_LOG:-/tmp/iperf3_ul0.log}
UE1_LOG=${UE1_LOG:-/tmp/iperf3_ul1.log}
UE2_LOG=${UE2_LOG:-/tmp/iperf3_ul2.log}
ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_dynamic_5qi_async_send_ul.log}

timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

log_event() {
  local msg="$1"
  echo "[$(timestamp_us)] $msg" | tee -a "$LOG_FILE"
}

show_progress() {
  local elapsed=$1 total=$2
  local percent=$((elapsed * 100 / total))
  printf "\r[$(timestamp)] 진행: [%-50s] %d%% (%d/%d초)" \
    "$(printf '#%.0s' $(seq 1 $((percent / 2)) 2>/dev/null))" "$percent" "$elapsed" "$total"
}

change_5qi_ue0() {
  local new_5qi=$1
  local gbr_dl=${2:-0}
  local gbr_ul=${3:-0}
  local mbr_dl=${4:-0}
  local mbr_ul=${5:-0}

  [ -e "$UE0_NAS_SOCKET" ] || { echo "✗ UE0 socket 없음: $UE0_NAS_SOCKET"; return 1; }
  command -v socat >/dev/null 2>&1 || { echo "✗ socat 필요"; return 1; }

  local line err err2
  line=$(printf 'MODIFY %s %s %s %s %s %s %s' "$PSI" "$QFI" "$new_5qi" "$gbr_dl" "$gbr_ul" "$mbr_dl" "$mbr_ul")
  echo "[$(timestamp)] UE0 NAS MODIFY: $line"

  if err=$(printf '%s\n' "$line" | socat - UNIX-SENDTO:"$UE0_NAS_SOCKET" 2>&1); then
    return 0
  fi
  if echo "$err" | grep -qi "Permission denied" && command -v sudo >/dev/null 2>&1; then
    if err2=$(sudo bash -c "printf '%s\n' \"$line\" | socat - UNIX-SENDTO:\"$UE0_NAS_SOCKET\"" 2>&1); then
      return 0
    fi
    echo "✗ socat(sudo) 실패: $err2"
    return 1
  fi
  echo "✗ socat 실패: $err"
  return 1
}

change_5qi_with_profile() {
  case "$1" in
    3)  change_5qi_ue0 "$1" "$GBR_SENSOR_DL" "$GBR_SENSOR_UL" 0 0 ;;
    84) change_5qi_ue0 "$1" "$GBR_REMOTE_CTRL_DL" "$GBR_REMOTE_CTRL_UL" 0 0 ;;
    *)  change_5qi_ue0 "$1" 0 0 0 0 ;;
  esac
}

change_5qi_with_profile_async() {
  local q=$1 rel=$2 idx=$3
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_INFLIGHT" ]; do sleep 0.02; done
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

[ "$TRANSITIONS" -le "$MAX_TRANSITIONS" ] || { echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds $MAX_TRANSITIONS"; exit 1; }
[ "$TOTAL_DUR" -ge "$TOTAL_DUR_MIN" ] || { echo "ERROR: TOTAL_DUR=$TOTAL_DUR, need >= $TOTAL_DUR_MIN"; exit 1; }

{
  echo "=========================================="
  echo "  iperf3 Dynamic 5QI 테스트 로그 (UL)"
  echo "  시작 시간: $(timestamp_us)"
  echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR"
  echo "  SERVER_IP=$SERVER_IP"
  echo "=========================================="
  echo ""
} > "$LOG_FILE"

echo "[$(timestamp)] 기존 iperf3 종료..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
log_event "기존 iperf3 종료 완료"

echo "[$(timestamp)] Host iperf3 서버 시작 (UL 수신)"
iperf3 -s -p "$UE0_PORT" -D 2>/dev/null || true
iperf3 -s -p "$UE1_PORT" -D 2>/dev/null || true
iperf3 -s -p "$UE2_PORT" -D 2>/dev/null || true
sleep 2

log_event "UL 트래픽 시작"

sudo ip netns exec "$UE0_NS" iperf3 -c "$SERVER_IP" -t "$TOTAL_DUR" -p "$UE0_PORT" -i 1 -u -b "$UE0_UDP_RATE" > "$UE0_LOG" 2>&1 & UL0_PID=$!
sudo ip netns exec "$UE1_NS" iperf3 -c "$SERVER_IP" -t "$TOTAL_DUR" -p "$UE1_PORT" -i 1 > "$UE1_LOG" 2>&1 & UL1_PID=$!
sudo ip netns exec "$UE2_NS" iperf3 -c "$SERVER_IP" -t "$TOTAL_DUR" -p "$UE2_PORT" -i 1 > "$UE2_LOG" 2>&1 & UL2_PID=$!

log_event "UL PID: $UL0_PID $UL1_PID $UL2_PID"
log_event "트래픽 기준 시각(EPOCH_NS): $(date +%s%N)"

change_5qi_with_profile 9 && log_event "t=0.0000s 5QI=9 적용" || log_event "t=0.0000s 5QI=9 적용 실패"

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
    change_5qi_with_profile "$q" && \
      log_event "t=${rel_sec}s transition#${i} 5QI=${q} 성공" || \
      log_event "t=${rel_sec}s transition#${i} 5QI=${q} 실패"
  fi

  elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
  if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
    show_progress "$elapsed_int" "$TOTAL_DUR"
    next_progress_sec=$((elapsed_int + 1))
  fi
done

[ "$ASYNC_SEND" = "1" ] && wait 2>/dev/null || true

elapsed_after_switch=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
remaining_int=$(awk -v t="$TOTAL_DUR" -v e="$elapsed_after_switch" 'BEGIN{r=t-e; if(r<0)r=0; printf "%d", int(r+0.999999)}')
for i in $(seq 1 "$remaining_int"); do
  show_progress "$((TOTAL_DUR - remaining_int + i))" "$TOTAL_DUR"
  sleep 1
done
printf "\n"

wait "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true

log_event "정리 시작"
kill "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
sleep 2
kill -9 "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
log_event "정리 완료"

echo "=========================================="
echo "[$(timestamp)] 테스트 완료 (UL)"
echo "  로그: $LOG_FILE"
echo "  UE0: $UE0_LOG"
echo "  UE1: $UE1_LOG"
echo "  UE2: $UE2_LOG"
echo "=========================================="

