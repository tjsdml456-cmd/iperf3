#!/bin/bash
# iperf3 Dynamic 5QI Test Script (PCF Policy Authorization)
# UE0(UDP): 0.2초마다 5QI 전환, 패턴 9 -> 3 -> 80 -> 84 -> 9 반복
#   - 100주기 x 4전환 = 400 transitions (0.2s 간격, 마지막 전환 시각 80.0s)
#   - 총 트래픽 82초
# UE1/UE2(TCP): 기존 5QI 유지, DL background traffic
#
# PCF: ascReqData.afAppId = 5GC-QOS:<qfi>:<5qi>[:gbr_dl:gbr_ul]
# Flow: bash(AF) -> POST/PATCH app-sessions -> PCF -> SMF notify -> QoS flow modify

set -u
export LC_ALL=C

PCF_BASE=${PCF_BASE:-"http://127.0.0.13:7777/npcf-policyauthorization/v1/app-sessions"}
NOTIF_URI=${NOTIF_URI:-"http://127.0.0.1:9999/af/notify"}
SUPP_FEAT=${SUPP_FEAT:-"3"}
# Open5GS SBI = HTTP/2 cleartext (h2c). HTTP/1.1 curl -> nghttp2 bad client magic (-903)
CURL_OPTS=${CURL_OPTS:---http2-prior-knowledge}

UE0_IP=${UE0_IP:-"10.45.0.2"}
PSI=${PSI:-1}
QFI=${QFI:-1}

# 5QI 전환 주기/횟수
STEP_SEC=${STEP_SEC:-0.5}
CYCLES=${CYCLES:-10}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=40
TOTAL_DUR=${TOTAL_DUR:-22}

# GBR (bps) — 5QI 3: 20Mbps, 5QI 84 (delay-critical): 15Mbps
GBR_SENSOR_DL=${GBR_SENSOR_DL:-20000000}
GBR_SENSOR_UL=${GBR_SENSOR_UL:-20000000}
GBR_REMOTE_CTRL_DL=${GBR_REMOTE_CTRL_DL:-15000000}
GBR_REMOTE_CTRL_UL=${GBR_REMOTE_CTRL_UL:-15000000}

# 트래픽
UE0_UDP_RATE=${UE0_UDP_RATE:-20M}
UE1_IP=${UE1_IP:-10.45.0.3}
UE2_IP=${UE2_IP:-10.45.0.4}

ASYNC_SEND=${ASYNC_SEND:-0}
MAX_INFLIGHT=${MAX_INFLIGHT:-8}

LOG_FILE=${LOG_FILE:-/tmp/iperf3_dynamic_5qi_pcf.log}
UE0_LOG=${UE0_LOG:-/tmp/iperf3_dl0.log}
UE1_LOG=${UE1_LOG:-/tmp/iperf3_dl1.log}
UE2_LOG=${UE2_LOG:-/tmp/iperf3_dl2.log}
ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_dynamic_5qi_pcf_async.log}
APP_SESSION_ID_FILE=${APP_SESSION_ID_FILE:-"/tmp/pcf_app_session_id"}

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

af_app_id_for() {
    local five_qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    if [ "$gbr_dl" -gt 0 ] || [ "$gbr_ul" -gt 0 ]; then
        echo "5GC-QOS:${QFI}:${five_qi}:${gbr_dl}:${gbr_ul}"
    else
        echo "5GC-QOS:${QFI}:${five_qi}"
    fi
}

# PCF Policy Authorization: POST (첫 번째) / PATCH (이후)
change_5qi_pcf() {
    local five_qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    local af_id
    local response http_status

    af_id=$(af_app_id_for "$five_qi" "$gbr_dl" "$gbr_ul")

    if [ -f "$APP_SESSION_ID_FILE" ] && [ -s "$APP_SESSION_ID_FILE" ]; then
        local app_id
        app_id=$(cat "$APP_SESSION_ID_FILE")
        response=$(curl -s $CURL_OPTS -w "\nHTTP_STATUS:%{http_code}" -X PATCH \
            "${PCF_BASE}/${app_id}" \
            -H "Content-Type: application/json" \
            -d "{\"ascReqData\":{\"afAppId\":\"$af_id\"}}")
    else
        response=$(curl -s $CURL_OPTS -D /tmp/pcf_create_headers.txt -w "\nHTTP_STATUS:%{http_code}" \
            -X POST "$PCF_BASE" \
            -H "Content-Type: application/json" \
            -d "{\"ascReqData\":{\"ueIpv4\":\"$UE0_IP\",\"notifUri\":\"$NOTIF_URI\",\"suppFeat\":\"$SUPP_FEAT\",\"afAppId\":\"$af_id\"}}")

        loc=$(grep -i '^location:' /tmp/pcf_create_headers.txt 2>/dev/null | tail -1 | tr -d '\r')
        if [ -n "$loc" ]; then
            echo "${loc##*/}" > "$APP_SESSION_ID_FILE"
        fi
    fi

    http_status=$(echo "$response" | grep "HTTP_STATUS" | tail -1 | cut -d: -f2 | tr -d ' ')
    if [ "$http_status" = "200" ] || [ "$http_status" = "201" ] || [ "$http_status" = "204" ]; then
        return 0
    fi
    echo "  PCF FAIL 5QI=$five_qi HTTP=${http_status:-?} $(echo "$response" | sed '/HTTP_STATUS:/d' | head -c 200)"
    return 1
}

change_5qi_with_profile() {
    local q=$1
    case "$q" in
        3)  change_5qi_pcf "$q" "$GBR_SENSOR_DL" "$GBR_SENSOR_UL" ;;
        84) change_5qi_pcf "$q" "$GBR_REMOTE_CTRL_DL" "$GBR_REMOTE_CTRL_UL" ;;
        *)  change_5qi_pcf "$q" 0 0 ;;
    esac
}

change_5qi_with_profile_async() {
    local q=$1
    local rel=$2
    local idx=$3

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

# --- main (직접 실행할 때만) ---
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    return 0 2>/dev/null || true
fi

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

rm -f "$APP_SESSION_ID_FILE"

{
echo "=========================================="
echo "  iperf3 Dynamic 5QI (PCF Policy Authorization)"
echo "  시작: $(timestamp_us)"
echo "  PCF_BASE=$PCF_BASE"
echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR"
echo "  패턴: 9 -> 3(GBR20M) -> 80 -> 84(GBR15M)"
echo "=========================================="
echo ""
} > "$LOG_FILE"

echo "=========================================="
echo "  iperf3 Dynamic 5QI 테스트 (PCF)"
echo "  UE0: 9 -> 3 -> 80 -> 84 반복 (${STEP_SEC}s)"
echo "=========================================="
echo ""
echo "  - 전환: ${TRANSITIONS}회 x ${STEP_SEC}s (마지막 전환 ${LAST_CHANGE_TIME}s)"
echo "  - 트래픽: ${TOTAL_DUR}s"
echo "  - 5QI 3 GBR: ${GBR_SENSOR_DL} bps DL/UL"
echo "  - 5QI 84 GBR: ${GBR_REMOTE_CTRL_DL} bps DL/UL"
echo "  - ASYNC_SEND=${ASYNC_SEND}"
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
echo "[$(timestamp)] DL 트래픽 시작 (${TOTAL_DUR}s)"
echo "=========================================="
log_event "DL 트래픽 시작"

iperf3 -c "$UE0_IP" -t "$TOTAL_DUR" -p 6500 -i 1 -u -b "${UE0_UDP_RATE}" > "$UE0_LOG" 2>&1 &
DL0_PID=$!
iperf3 -c "$UE1_IP" -t "$TOTAL_DUR" -p 6501 -i 1 > "$UE1_LOG" 2>&1 &
DL1_PID=$!
iperf3 -c "$UE2_IP" -t "$TOTAL_DUR" -p 6502 -i 1 > "$UE2_LOG" 2>&1 &
DL2_PID=$!

echo "[$(timestamp)] DL PID: $DL0_PID $DL1_PID $DL2_PID"
TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "트래픽 기준 EPOCH_NS: $TRAFFIC_START_EPOCH_NS"

# t=0: 5QI=9
if change_5qi_with_profile 9; then
    log_event "t=0.0000s 5QI=9 성공 (PCF POST/PATCH)"
else
    log_event "t=0.0000s 5QI=9 실패"
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
        log_event "t=${rel_sec}s transition#${i} 5QI=${q} dispatch (async)"
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
echo "  appSession: $(cat "$APP_SESSION_ID_FILE" 2>/dev/null || echo n/a)"
echo "=========================================="
