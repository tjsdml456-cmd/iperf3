#!/bin/bash
# iperf3 Dynamic 5QI Test (NAS) — UL 전용 + UE NAS MODIFY (PCF API 대신)
#
# PCF UL 스크립트와 동일 구조:
#   data-plane: UE0 (netns ue1) UDP UL + rate-change
#               (optional) UE1/UE2 TCP RR UL background — ENABLE_BG=1
#   control-plane: host socat -> UE AF_UNIX SOCK_DGRAM (MODIFY psi qfi 5qi gbr_dl gbr_ul mbr_dl mbr_ul)
#
# 5QI 변경 경로: UE NAS → AMF → SMF → … (REST/PCF 없음)
# ue.conf 예: 5g_control_socket = /tmp/srsue0_nas5g_control
# 실행 예:    export UE0_NAS_SOCKET=/tmp/srsue0_nas5g_control
#
# 필요 조건:
#   1) host/DN 에 SERVER_IP:6500 iperf3 server (BG면 6501/6502도)
#   2) srsUE 기동·PDU 세션 후 UE0_NAS_SOCKET 존재
#   3) 커스텀 iperf3 (--rate-change) 필요 (USE_RATE_CHANGE=1)
#
# 의존: socat, awk, date, ip netns

set -euo pipefail
export LC_ALL=C

# ---------- NAS control ----------
UE0_NAS_SOCKET=${UE0_NAS_SOCKET:-/tmp/srsue0_nas5g_control}
PSI=${PSI:-1}
QFI=${QFI:-1}
UE_LOG_FILE=${UE_LOG_FILE:-/tmp/ue1.log}
# ---------- 주소/namespace ----------
SERVER_IP=${SERVER_IP:-10.45.0.1}
UE0_NS=${UE0_NS:-ue1}
UE1_NS=${UE1_NS:-ue2}
UE2_NS=${UE2_NS:-ue3}
UE0_IP=${UE0_IP:-10.45.0.2}
UE1_IP=${UE1_IP:-10.45.0.3}
UE2_IP=${UE2_IP:-10.45.0.4}

# ---------- 실험 시간 ----------
STEP_SEC=${STEP_SEC:-0.5}
MIN_STEP_NAS=${MIN_STEP_NAS:-0}
CYCLES=${CYCLES:-40}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=120
TOTAL_DUR=${TOTAL_DUR:-55}

# ---------- QoS profile (NAS MODIFY bps) ----------
GBR_5QI66_DL=${GBR_5QI66_DL:-7000000}
GBR_5QI66_UL=${GBR_5QI66_UL:-7000000}
MBR_5QI66_DL=${MBR_5QI66_DL:-20000000}
MBR_5QI66_UL=${MBR_5QI66_UL:-20000000}
GBR_5QI84_DL=${GBR_5QI84_DL:-4000000}
GBR_5QI84_UL=${GBR_5QI84_UL:-4000000}
MBR_5QI84_DL=${MBR_5QI84_DL:-20000000}
MBR_5QI84_UL=${MBR_5QI84_UL:-20000000}

# ---------- traffic ----------
USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}
UE0_FIXED_BITRATE=${UE0_FIXED_BITRATE:-7M}
UE0_UDP_LENGTH=${UE0_UDP_LENGTH:-1200}
UE0_RATE_NON_GBR=${UE0_RATE_NON_GBR:-0.5M}
UE0_RATE_GBR=${UE0_RATE_GBR:-0.5M}
UE0_RATE_DC_GBR=${UE0_RATE_DC_GBR:-0.5M}

# UE1/UE2 background off by default (UE0 / netns ue1 only).
ENABLE_BG=${ENABLE_BG:-0}
BG_PROTO=${BG_PROTO:-tcp_rr}
BG_TCP_LEN=${BG_TCP_LEN:-1024}
UE1_BG_RATE=${UE1_BG_RATE:-3M}
UE2_BG_RATE=${UE2_BG_RATE:-3M}
UE1_BG_DSCP=${UE1_BG_DSCP:-0}
UE2_BG_DSCP=${UE2_BG_DSCP:-0}

NAS_MODE=${NAS_MODE:-async}
MAX_INFLIGHT=${MAX_INFLIGHT:-8}
export IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG:-1}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NAS_USE_SCHEDULE=${NAS_USE_SCHEDULE:-1}
NAS_SCHEDULE_FILE=${NAS_SCHEDULE_FILE:-"$SCRIPT_DIR/qos_schedules/qos_schedule_5qi.csv"}
# shellcheck source=qos_random_common.sh
. "$SCRIPT_DIR/qos_random_common.sh"
QOS_RATE_NON_GBR=${QOS_RATE_NON_GBR:-$UE0_RATE_NON_GBR}
QOS_RATE_GBR=${QOS_RATE_GBR:-$UE0_RATE_GBR}
QOS_RATE_DC_GBR=${QOS_RATE_DC_GBR:-$UE0_RATE_DC_GBR}
QOS_RATE_INITIAL=${QOS_RATE_INITIAL:-$UE0_RATE_NON_GBR}

if [ -z "${IPERF3_BIN:-}" ]; then
    if [ -x "$SCRIPT_DIR/src/iperf3" ]; then
        IPERF3_BIN="$SCRIPT_DIR/src/iperf3"
    elif [ -x "$SCRIPT_DIR/../iperf_QoS-2/src/iperf3" ]; then
        IPERF3_BIN="$SCRIPT_DIR/../iperf_QoS-2/src/iperf3"
    else
        IPERF3_BIN=iperf3
    fi
fi

LOG_FILE=${LOG_FILE:-/tmp/iperf3_dynamic_5qi_nas_ul.log}
UE0_LOG=${UE0_LOG:-/tmp/iperf3_dynamic_5qi_nas_ul_ue0.log}
UE1_LOG=${UE1_LOG:-/tmp/iperf3_dynamic_5qi_nas_ul_ue1_bg.log}
UE2_LOG=${UE2_LOG:-/tmp/iperf3_dynamic_5qi_nas_ul_ue2_bg.log}
ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_dynamic_5qi_nas_ul_async.log}

# ---------- helpers ----------
timestamp() { date '+%H:%M:%S'; }
timestamp_us() { date '+%H:%M:%S.%N' | cut -b1-16; }

log_event() {
    local msg="$1"
    echo "[$(timestamp_us)] $msg" | tee -a "$LOG_FILE"
}

show_progress() {
    local elapsed=$1
    local total=$2
    local percent=$((elapsed * 100 / total))
    printf "\r[$(timestamp)] 진행: [%-50s] %d%% (%d/%d초)" \
        "$(printf '#%.0s' $(seq 1 $((percent / 2)) 2>/dev/null))" "$percent" "$elapsed" "$total"
}

wait_until_traffic_rel_s() {
    local rel_s=$1
    local target_ns wait_ns now_ns
    target_ns=$(awk -v t0="$TRAFFIC_START_EPOCH_NS" -v rel="$rel_s" \
        'BEGIN{printf "%.0f", t0 + rel * 1000000000}')
    while true; do
        now_ns=$(date +%s%N)
        wait_ns=$((target_ns - now_ns))
        if [ "$wait_ns" -le 0 ]; then
            break
        fi
        sleep "$(awk -v w="$wait_ns" 'BEGIN{printf "%.6f", w/1e9}')"
    done
}

dscp_to_tos_hex() {
    printf '0x%02x' $(($1 << 2))
}
UE1_BG_TOS=$(dscp_to_tos_hex "$UE1_BG_DSCP")
UE2_BG_TOS=$(dscp_to_tos_hex "$UE2_BG_DSCP")

traffic_pids_alive() {
    if ! kill -0 "$UL0_PID" 2>/dev/null; then
        return 1
    fi
    if [ "$ENABLE_BG" = "1" ]; then
        if ! kill -0 "$UL1_PID" 2>/dev/null || ! kill -0 "$UL2_PID" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}
rate_for_5qi() {
    case "$1" in
        66) echo "$UE0_RATE_GBR" ;;
        84) echo "$UE0_RATE_DC_GBR" ;;
        9)  echo "$QOS_RATE_INITIAL" ;;
        *)  echo "$UE0_RATE_NON_GBR" ;;
    esac
}

five_qi_label() {
    case "$1" in
        66) echo "GBR" ;;
        84) echo "DC-GBR" ;;
        80) echo "pdb-only" ;;
        9)  echo "default" ;;
        *)  echo "?" ;;
    esac
}

build_rate_change_by_5qi() {
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        build_rate_change_from_schedule
        return
    fi
    local i r
    r=$(rate_for_step 0)
    printf "%s" "$r"
    for i in $(seq 1 "$TRANSITIONS"); do
        r=$(rate_for_step "$i")
        awk -v s="$STEP_SEC" -v n="$i" -v rate="$r" \
            'BEGIN{printf ",%.6f,%s", s*n, rate}'
    done
    printf "\n"
}

print_phase_timing_cheatsheet() {
    local i q t r mac label show_n d
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        show_n=$QOS_SCHEDULE_N
        if [ "$show_n" -gt 12 ]; then show_n=12; fi
        echo "  스케줄 파일: ${NAS_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"
        echo "  t        5QI   DSCP  rate       기대 MAC"
        for i in $(seq 0 $((show_n - 1))); do
            q=$(schedule_five_qi_at "$i")
            d=$(five_qi_to_dscp "$q")
            t=$(schedule_rel_time_at "$i")
            r=$(rate_for_5qi "$q")
            label=$(five_qi_label "$q")
            case "$q" in
                66) mac="~7M GBR (MBR 9M)" ;;
                84) mac="~4M DC-GBR (MBR 6M)" ;;
                80) mac="~0.5M pdb-only (non-GBR)" ;;
                *)  mac="초기 non-GBR" ;;
            esac
            printf "  %-8s %-5s %-5s %-9s %s (%s)\n" "$t" "$q" "$d" "$r" "$mac" "$label"
        done
        if [ "$QOS_SCHEDULE_N" -gt 12 ]; then
            echo "  ... (${QOS_SCHEDULE_N} schedule points total)"
        fi
        return
    fi
    show_n=$TRANSITIONS
    if [ "$show_n" -gt 8 ]; then show_n=8; fi
    echo "  STEP=${STEP_SEC}s — NAS·rate-change 동일 시각 (트래픽 시작 t=0)"
    echo "  t        5QI   DSCP  rate       기대 MAC"
    q=$(five_qi_for_step 0)
    d=$(dscp_for_step 0)
    r=$(rate_for_step 0)
    label=$(five_qi_label "$q")
    printf "  %-8s %-5s %-5s %-9s %s (%s)\n" "0.00" "$q" "$d" "$r" "초기" "$label"
    for i in $(seq 1 "$show_n"); do
        q=$(five_qi_for_step "$i")
        d=$(dscp_for_step "$i")
        t=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.2f", s*n}')
        r=$(rate_for_step "$i")
        label=$(five_qi_label "$q")
        case "$q" in
            66) mac="~7M GBR (MBR 9M)" ;;
            84) mac="~4M DC-GBR (MBR 6M)" ;;
            80) mac="~0.5M pdb-only (non-GBR)" ;;
            *)  mac="초기 non-GBR" ;;
        esac
        printf "  %-8s %-5s %-5s %-9s %s (%s)\n" "$t" "$q" "$d" "$r" "$mac" "$label"
    done
    if [ "$TRANSITIONS" -gt 8 ]; then
        echo "  ... (${TRANSITIONS} transitions total, RANDOM_SEED=${RANDOM_SEED:-auto})"
    fi
}

summarize_iperf_log() {
    local label=$1 file=$2
    echo "  [$label] $file"
    if [ ! -s "$file" ]; then
        echo "    (로그 없음)"
        return
    fi
    grep -iE '\[.*\].* (sender|receiver)' "$file" 2>/dev/null | tail -n 2 | sed 's/^/    /' || \
        tail -n 5 "$file" | sed 's/^/    /'
}

dump_ue0_log() {
    echo "  --- $UE0_LOG ---"
    if [ -s "$UE0_LOG" ]; then sed 's/^/    /' "$UE0_LOG"; else echo "    (비어 있음)"; fi
}

# ---------- NAS MODIFY ----------
change_5qi_nas() {
    local new_5qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    local mbr_dl=${4:-0}
    local mbr_ul=${5:-0}

    if [ -z "$UE0_NAS_SOCKET" ]; then
        echo "  NAS FAIL: UE0_NAS_SOCKET empty"
        return 1
    fi
    if [ ! -e "$UE0_NAS_SOCKET" ]; then
        echo "  NAS FAIL: socket missing: $UE0_NAS_SOCKET"
        return 1
    fi
    if ! command -v socat >/dev/null 2>&1; then
        echo "  NAS FAIL: socat required"
        return 1
    fi

    local line
    line=$(printf 'MODIFY %s %s %s %s %s %s %s' \
        "$PSI" "$QFI" "$new_5qi" "$gbr_dl" "$gbr_ul" "$mbr_dl" "$mbr_ul")

    local err
    if err=$(printf '%s\n' "$line" | socat - UNIX-SENDTO:"$UE0_NAS_SOCKET" 2>&1); then
        return 0
    fi
    if echo "$err" | grep -qi "Permission denied" && command -v sudo >/dev/null 2>&1; then
        if err=$(sudo bash -c "printf '%s\n' \"$line\" | socat - UNIX-SENDTO:\"$UE0_NAS_SOCKET\"" 2>&1); then
            return 0
        fi
    fi
    echo "  NAS FAIL 5QI=$new_5qi: $err"
    return 1
}

verify_modify_propagation() {
    local expected_5qi=$1
    if [ -r "$UE_LOG_FILE" ]; then
        if tail -n 200 "$UE_LOG_FILE" | grep -q "Sending PDU Session Modification Request"; then
            log_event "검증(UE): PDU Session Modification Request 송신 확인"
        else
            log_event "검증(UE): 송신 로그 미확인 (UE_LOG_FILE=$UE_LOG_FILE)"
        fi
    fi
    if [ -r "$SMF_LOG" ]; then
        if tail -n 200 "$SMF_LOG" | grep -q "5QI=${expected_5qi}"; then
            log_event "검증(SMF): 5QI=${expected_5qi} 반영 확인"
        else
            log_event "검증(SMF): 5QI=${expected_5qi} 미확인 (tail 200)"
        fi
    fi
}

change_5qi_with_profile() {
    local q=$1
    case "$q" in
        66) change_5qi_nas "$q" "$GBR_5QI66_DL" "$GBR_5QI66_UL" "$MBR_5QI66_DL" "$MBR_5QI66_UL" ;;
        84) change_5qi_nas "$q" "$GBR_5QI84_DL" "$GBR_5QI84_UL" "$MBR_5QI84_DL" "$MBR_5QI84_UL" ;;
        80|9) change_5qi_nas "$q" 0 0 0 0 ;;
        *)  change_5qi_nas "$q" 0 0 0 0 ;;
    esac
}

change_5qi_with_profile_sync() {
    local q=$1 rel=$2 idx=$3
    local rate nas_t0_ns nas_ms
    rate=$(rate_for_5qi "$q")
    nas_t0_ns=$(date +%s%N)
    if change_5qi_with_profile "$q"; then
        nas_ms=$(( ($(date +%s%N) - nas_t0_ns) / 1000000 ))
        log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} NAS OK nas_ms=${nas_ms} (sync)"
        verify_modify_propagation "$q"
        return 0
    fi
    log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} NAS FAIL (sync)"
    return 1
}

change_5qi_with_profile_async() {
    local q=$1 rel=$2 idx=$3
    while true; do
        local inflight
        inflight=$(jobs -rp | wc -l)
        if [ "$inflight" -lt "$MAX_INFLIGHT" ]; then break; fi
        sleep 0.02
    done
    (
        local rate nas_t0_ns nas_ms
        rate=$(rate_for_5qi "$q")
        nas_t0_ns=$(date +%s%N)
        if change_5qi_with_profile "$q"; then
            nas_ms=$(( ($(date +%s%N) - nas_t0_ns) / 1000000 ))
            log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} NAS OK nas_ms=${nas_ms} (async)"
        else
            log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} NAS FAIL (async)"
        fi
    ) 2>&1 | tee -a "$ASYNC_LOG" >> "$LOG_FILE" &
}

change_5qi_at_transition() {
    local q=$1 rel=$2 idx=$3
    if [ "$NAS_MODE" = "async" ]; then
        change_5qi_with_profile_async "$q" "$rel" "$idx"
    else
        change_5qi_with_profile_sync "$q" "$rel" "$idx"
    fi
}

# ---------- schedule 준비 ----------
if [ "$NAS_USE_SCHEDULE" = "1" ] && [ -f "$NAS_SCHEDULE_FILE" ]; then
    load_qos_schedule_file "$NAS_SCHEDULE_FILE"
    LAST_CHANGE_TIME=$(schedule_rel_time_at $((QOS_SCHEDULE_N - 1)))
else
    NAS_USE_SCHEDULE=0
    if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then
        echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS."
        exit 1
    fi
    generate_qos_index_sequence
    LAST_CHANGE_TIME=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
fi

if [ "$TRANSITIONS" -gt "$MAX_TRANSITIONS" ]; then
    echo "ERROR: TRANSITIONS=$TRANSITIONS exceeds max $MAX_TRANSITIONS."
    exit 1
fi

TOTAL_DUR_MIN=$(awk -v t="$LAST_CHANGE_TIME" 'BEGIN{printf "%d", int(t)+1}')
if [ "$TOTAL_DUR" -lt "$TOTAL_DUR_MIN" ]; then
    echo "ERROR: TOTAL_DUR=$TOTAL_DUR is too short. Need >= $TOTAL_DUR_MIN (last change at ${LAST_CHANGE_TIME}s)."
    exit 1
fi

if [ "$USE_RATE_CHANGE" = "1" ]; then
    RATE_CHANGE_ARGS=$(build_rate_change_by_5qi)
    if ! "$IPERF3_BIN" --help 2>&1 | grep -q -- '--rate-change'; then
        echo "ERROR: USE_RATE_CHANGE=1 이지만 ${IPERF3_BIN} 에 --rate-change 가 없습니다."
        exit 1
    fi
fi

# ---------- 시작 로그 ----------
{
    echo "=========================================="
    echo "  iperf3 Dynamic 5QI UL NAS — traffic from UE namespace, 5QI via UE NAS MODIFY"
    echo "  시작: $(timestamp_us)"
    echo "  IPERF3_BIN=$IPERF3_BIN"
    echo "  SERVER_IP=$SERVER_IP"
    echo "  UE0_NAS_SOCKET=$UE0_NAS_SOCKET (no PCF REST)"
    echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR"
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        echo "  NAS_USE_SCHEDULE=1 file=${NAS_SCHEDULE_FILE}"
        echo "  5QI 시퀀스: $(print_5qi_schedule_sequence)"
        echo "  DSCP 대응: $(print_dscp_schedule_sequence)"
    else
        echo "  RANDOM_SEED=$RANDOM_SEED (file=$QOS_RANDOM_SEED_FILE)"
        print_qos_pairing_check
    fi
    echo "  NAS_MODE=$NAS_MODE USE_RATE_CHANGE=$USE_RATE_CHANGE ENABLE_BG=$ENABLE_BG BG_PROTO=$BG_PROTO"
    if [ "$USE_RATE_CHANGE" = "1" ]; then
        echo "  UE0: --rate-change ${RATE_CHANGE_ARGS}"
        echo "  초기(9)=${QOS_RATE_INITIAL} pdb-only(80)=${UE0_RATE_NON_GBR} GBR(66)=${UE0_RATE_GBR} DC-GBR(84)=${UE0_RATE_DC_GBR}"
    else
        echo "  UE0: -b ${UE0_FIXED_BITRATE}"
    fi
    print_phase_timing_cheatsheet
    echo "=========================================="
    echo ""
} >"$LOG_FILE"

if awk -v s="$STEP_SEC" -v m="$MIN_STEP_NAS" 'BEGIN{exit !(s+0 < m+0)}'; then
    echo "WARNING: STEP_SEC=${STEP_SEC}s < MIN_STEP_NAS=${MIN_STEP_NAS}s"
    log_event "WARNING STEP_SEC=${STEP_SEC} < MIN_STEP_NAS=${MIN_STEP_NAS}"
fi

echo "=========================================="
echo "  iperf3 Dynamic 5QI UL NAS"
echo "  traffic: UE0(${UE0_NS}) only -> ${SERVER_IP}"
echo "  5QI control: NAS MODIFY -> $UE0_NAS_SOCKET"
echo "=========================================="
echo "  iperf3: ${IPERF3_BIN}"
echo "  NAS_MODE=${NAS_MODE}  ENABLE_BG=${ENABLE_BG}  BG_PROTO=${BG_PROTO}  BG_TCP_LEN=${BG_TCP_LEN}"
if [ "$ENABLE_BG" != "1" ]; then
    echo "  background: OFF (UE1/UE2 미전송). 켜려면 ENABLE_BG=1"
fi
if [ "$QOS_USE_SCHEDULE" = "1" ]; then
    echo "  스케줄: ${NAS_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"
    echo "  5QI: $(print_5qi_schedule_sequence)"
else
    echo "  5QI: t=0 → 9, 이후 랜덤 (${TRANSITIONS}회, STEP=${STEP_SEC}s)"
fi
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "  UE0 UDP --rate-change: ${RATE_CHANGE_ARGS}"
else
    echo "  UE0 UDP fixed: ${UE0_FIXED_BITRATE}"
fi
echo ""
echo "  [타이밍 치트시트]"
print_phase_timing_cheatsheet
echo ""
echo "  수동 테스트: printf 'MODIFY ${PSI} ${QFI} 66 7000000 7000000 9000000 9000000\\n' | socat - UNIX-SENDTO:$UE0_NAS_SOCKET"
echo ""

log_event "테스트 시작 UL traffic + NAS MODIFY"

# ---------- 기존 iperf 정리 ----------
echo "[$(timestamp)] 기존 iperf3 종료..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
log_event "기존 iperf3 종료 완료"

# ---------- host/DN iperf server ----------
echo "[$(timestamp)] host/DN iperf3 server 시작 (UL 수신)"
"$IPERF3_BIN" -s -p 6500 -D 2>/dev/null || true
if [ "$ENABLE_BG" = "1" ]; then
    "$IPERF3_BIN" -s -p 6501 -D 2>/dev/null || true
    "$IPERF3_BIN" -s -p 6502 -D 2>/dev/null || true
fi
sleep 2

# ---------- traffic 시작 ----------
echo "=========================================="
echo "[$(timestamp)] UL 트래픽 시작 (${TOTAL_DUR}초)"
echo "  UE0(${UE0_NS}): UDP 5QI target traffic"
if [ "$ENABLE_BG" = "1" ]; then
    echo "  UE1(${UE1_NS})/UE2(${UE2_NS}): BG ${BG_PROTO} (UL)"
else
    echo "  background: OFF"
fi
echo "=========================================="
log_event "UL traffic start ENABLE_BG=${ENABLE_BG} BG_PROTO=${BG_PROTO}"

UL1_PID=""
UL2_PID=""
if [ "$ENABLE_BG" = "1" ]; then
    if [ "$BG_PROTO" = "udp" ]; then
        sudo ip netns exec "$UE1_NS" "$IPERF3_BIN" -c "$SERVER_IP" -u -b "$UE1_BG_RATE" \
            -t "$TOTAL_DUR" -p 6501 -i 1 -S "$UE1_BG_TOS" >"$UE1_LOG" 2>&1 &
        UL1_PID=$!
        sudo ip netns exec "$UE2_NS" "$IPERF3_BIN" -c "$SERVER_IP" -u -b "$UE2_BG_RATE" \
            -t "$TOTAL_DUR" -p 6502 -i 1 -S "$UE2_BG_TOS" >"$UE2_LOG" 2>&1 &
        UL2_PID=$!
    else
        # tcp / tcp_rr: TCP UL from UE netns (small -l for RR-style segments)
        sudo ip netns exec "$UE1_NS" "$IPERF3_BIN" -c "$SERVER_IP" \
            -t "$TOTAL_DUR" -p 6501 -i 1 -l "$BG_TCP_LEN" -S "$UE1_BG_TOS" >"$UE1_LOG" 2>&1 &
        UL1_PID=$!
        sudo ip netns exec "$UE2_NS" "$IPERF3_BIN" -c "$SERVER_IP" \
            -t "$TOTAL_DUR" -p 6502 -i 1 -l "$BG_TCP_LEN" -S "$UE2_BG_TOS" >"$UE2_LOG" 2>&1 &
        UL2_PID=$!
    fi
fi

if [ "$USE_RATE_CHANGE" = "1" ]; then
    sudo ip netns exec "$UE0_NS" env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \
        "$IPERF3_BIN" -c "$SERVER_IP" -u -l "$UE0_UDP_LENGTH" -t "$TOTAL_DUR" -p 6500 -i 1 \
        --rate-change "${RATE_CHANGE_ARGS}" \
        >"$UE0_LOG" 2>&1 &
else
    sudo ip netns exec "$UE0_NS" "$IPERF3_BIN" -c "$SERVER_IP" -u -b "$UE0_FIXED_BITRATE" -l "$UE0_UDP_LENGTH" \
        -t "$TOTAL_DUR" -p 6500 -i 1 \
        >"$UE0_LOG" 2>&1 &
fi
UL0_PID=$!
TRAFFIC_START_EPOCH_NS=$(date +%s%N)
if [ "$ENABLE_BG" = "1" ]; then
    log_event "PIDs UE0=$UL0_PID UE1=$UL1_PID UE2=$UL2_PID EPOCH_NS=$TRAFFIC_START_EPOCH_NS"
else
    log_event "PIDs UE0=$UL0_PID (BG off) EPOCH_NS=$TRAFFIC_START_EPOCH_NS"
fi
log_event "throughput: MAC-THP-UL / QRT: QRT-T0-UL-NAS vs UL scheduler active"

next_progress_sec=1
EARLY_EXIT=0
NAS_FAIL=0

# ---------- NAS dispatch (PCF dispatch 자리) ----------
if [ "$QOS_USE_SCHEDULE" = "1" ]; then
    for i in $(seq 0 $((QOS_SCHEDULE_N - 1))); do
        rel_sec=$(schedule_rel_time_at "$i")
        wait_until_traffic_rel_s "$rel_sec"
        q=$(schedule_five_qi_at "$i")

        log_event "QRT-T0-UL-NAS transition#${i} t_rel=${rel_sec} five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS socket=$UE0_NAS_SOCKET"
        change_5qi_at_transition "$q" "$rel_sec" "$i" || NAS_FAIL=1

        elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
        if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
            show_progress "$elapsed_int" "$TOTAL_DUR"
            next_progress_sec=$((elapsed_int + 1))
        fi

        if ! traffic_pids_alive; then
            EARLY_EXIT=1
            break
        fi
    done
else
    wait_until_traffic_rel_s 0
    q=$(five_qi_for_step 0)
    log_event "QRT-T0-UL-NAS transition#0 t_rel=0.000000 five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS socket=$UE0_NAS_SOCKET"
    change_5qi_at_transition "$q" "0.0000" 0 || NAS_FAIL=1

    for i in $(seq 1 "$TRANSITIONS"); do
        rel_sec=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.6f", s*n}')
        wait_until_traffic_rel_s "$rel_sec"
        q=$(five_qi_for_step "$i")

        log_event "QRT-T0-UL-NAS transition#${i} t_rel=${rel_sec} five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS socket=$UE0_NAS_SOCKET"
        change_5qi_at_transition "$q" "$rel_sec" "$i" || NAS_FAIL=1

        elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
        if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
            show_progress "$elapsed_int" "$TOTAL_DUR"
            next_progress_sec=$((elapsed_int + 1))
        fi

        if ! traffic_pids_alive; then
            EARLY_EXIT=1
            break
        fi
    done
fi

if [ "$NAS_MODE" = "async" ]; then
    wait 2>/dev/null || true
fi

if [ "$QOS_USE_SCHEDULE" = "1" ]; then
    elapsed_after_switch=$(schedule_rel_time_at $((QOS_SCHEDULE_N - 1)))
else
    elapsed_after_switch=$(awk -v s="$STEP_SEC" -v n="$TRANSITIONS" 'BEGIN{printf "%.6f", s*n}')
fi
remaining=$(awk -v t="$TOTAL_DUR" -v e="$elapsed_after_switch" 'BEGIN{r=t-e; if (r<0) r=0; printf "%.6f", r}')
remaining_int=$(awk -v r="$remaining" 'BEGIN{printf "%d", int(r+0.999999)}')

for i in $(seq 1 "$remaining_int"); do
    if ! traffic_pids_alive; then
        EARLY_EXIT=1
        break
    fi
    show_progress "$((TOTAL_DUR - remaining_int + i))" "$TOTAL_DUR"
    sleep 1
done
printf "\n"

set +e
wait "$UL0_PID"
UL0_RC=$?
BG_RC=0
if [ "$ENABLE_BG" = "1" ]; then
    wait "$UL1_PID" "$UL2_PID"
    BG_RC=$?
fi
set -e

if [ "$EARLY_EXIT" -eq 1 ] || [ "$UL0_RC" -ne 0 ]; then
    echo "[$(timestamp)] ERROR: iperf3 조기 종료 (UE0 rc=${UL0_RC})"
    dump_ue0_log | tee -a "$LOG_FILE"
    exit "${UL0_RC:-1}"
fi
if [ "$ENABLE_BG" = "1" ] && [ "$BG_RC" -ne 0 ]; then
    echo "[$(timestamp)] WARNING: background rc=$BG_RC"
fi

# ---------- 결과 요약 ----------
echo ""
echo "[$(timestamp)] iperf3 결과 요약"
summarize_iperf_log "UE0 UL UDP 5QI+rate-change" "$UE0_LOG" | tee -a "$LOG_FILE"
if [ "$ENABLE_BG" = "1" ]; then
    summarize_iperf_log "UE1 UL ${BG_PROTO}" "$UE1_LOG" | tee -a "$LOG_FILE"
    summarize_iperf_log "UE2 UL ${BG_PROTO}" "$UE2_LOG" | tee -a "$LOG_FILE"
fi

if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "[$(timestamp)] UE0 rate-change 로그 요약"
    if grep -qi "Changed rate" "$UE0_LOG" 2>/dev/null; then
        echo "  Changed rate 줄 수: $(grep -ci "Changed rate" "$UE0_LOG")"
        grep -i "Changed rate" "$UE0_LOG" | sed 's/^/    /' | tee -a "$LOG_FILE"
    else
        echo "  ERROR: Changed rate 없음 — --rate-change 미적용 (커스텀 iperf3 확인)"
        echo "         IPERF3_BIN=${IPERF3_BIN}"
        grep -i "RATE_TIMER" "$UE0_LOG" 2>/dev/null | head -5 | sed 's/^/    /' || true
        dump_ue0_log | head -30 | tee -a "$LOG_FILE"
    fi
fi

echo "[$(timestamp)] NAS 전환 요약"
NAS_OK_N=$(grep -c 'NAS OK' "$LOG_FILE" 2>/dev/null || echo 0)
NAS_FAIL_N=$(grep -c 'NAS FAIL' "$LOG_FILE" 2>/dev/null || echo 0)
echo "  NAS OK=${NAS_OK_N}  NAS FAIL=${NAS_FAIL_N}  (grep $LOG_FILE)"
if [ "$NAS_OK_N" -eq 0 ]; then
    echo "  ERROR: NAS OK 없음 — UE0_NAS_SOCKET / srsUE 기동 / socat 확인"
    grep -E 'NAS FAIL|QRT-T0' "$LOG_FILE" 2>/dev/null | tail -10 | sed 's/^/    /' || true
fi

echo ""
echo "[$(timestamp)] 확인용 grep"
echo "  test log: rg 'QRT-T0-UL-NAS|NAS OK|NAS FAIL' $LOG_FILE"
echo "  gNB UL : rg 'MAC-THP-UL|QOS-RECONFIG|UL|5QI|QFI' \${GNBS_LOG:-/tmp/gnb.log}"
echo "  SMF    : rg '5QI=|QoS' \${SMF_LOG:-/tmp/smf.log}"
echo "  QRT    : ./compute_qrt_ul_5qi.sh  (ul.txt 5QI vs /tmp/prio.txt)"
echo ""

log_event "정리"
if [ "$ENABLE_BG" = "1" ]; then
    kill "$UL0_PID" "$UL1_PID" "$UL2_PID" 2>/dev/null || true
else
    kill "$UL0_PID" 2>/dev/null || true
fi
sleep 1
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

echo "=========================================="
echo "[$(timestamp)] 테스트 완료"
echo "  로그: $LOG_FILE"
echo "  UE0: $UE0_LOG"
if [ "$ENABLE_BG" = "1" ]; then
    echo "  UE1: $UE1_LOG"
    echo "  UE2: $UE2_LOG"
fi
echo ""
echo "  QRT 정의:"
echo "    t0 = QRT-T0-UL-NAS in this log (NAS MODIFY 전송 시각)"
echo "    t1 = gNB UL scheduler prio_weight 반영 (prio.txt)"
echo "    QRT = t1 - t0  →  ./compute_qrt_ul_5qi.sh"
echo "  MAC: grep 'MAC-THP-UL' \${GNBS_LOG:-/tmp/gnb.log}"
echo "=========================================="
if [ "$NAS_FAIL" -ne 0 ]; then
    echo "  WARNING: NAS 전환 일부 실패 — $LOG_FILE 확인"
fi
log_event "종료"
