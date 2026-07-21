#!/bin/bash
# iperf3 Dynamic 5QI Test (PCF) — UE0 UDP rate-change + UE1/UE2 TCP
#
# UE0: 한 세션 iperf (-t TOTAL_DUR) + --rate-change — 트래픽 중간에 끊지 않음.
# PCF 5QI는 iperf rate-change 와 같은 시각에 dispatch.
#
# 모드 1 (기본): PCF_USE_SCHEDULE=1 — qos_schedule_dscp_replay.csv 실측 시각·5QI 재생
# 모드 2: PCF_USE_SCHEDULE=0 — STEP_SEC마다 80/66/84 랜덤 (qos_random_common.sh)
#   5QI 9↔DSCP 0 | 5QI 80↔DSCP 24 | 5QI 66↔DSCP 44 | 5QI 84↔DSCP 15
# 타이밍 (트래픽 시작 t=0 = TRAFFIC_START_EPOCH_NS):
#   wait_until rel_time_s → PCF async/sync + iperf --rate-change @ 동일 t
#
# PCF_MODE=async → fire-and-forget (0.5s tick 테스트 권장)
# USE_RATE_CHANGE=0 → UE0 -b 7M 고정
# PCF: ascReqData.afAppId = 5GC-QOS:<qfi>:<5qi>[:gbr_dl:gbr_ul[:mbr_dl:mbr_ul]]
# 커스텀 iperf3 (--rate-change) 필요.

set -euo pipefail
export LC_ALL=C

PCF_BASE=${PCF_BASE:-"http://127.0.0.13:7777/npcf-policyauthorization/v1/app-sessions"}
NOTIF_URI=${NOTIF_URI:-"http://127.0.0.1:9999/af/notify"}
SUPP_FEAT=${SUPP_FEAT:-"3"}
CURL_OPTS=${CURL_OPTS:---http2-prior-knowledge}

UE0_IP=${UE0_IP:-"10.45.0.2"}
UE1_IP=${UE1_IP:-"10.45.0.3"}
UE2_IP=${UE2_IP:-"10.45.0.4"}
PSI=${PSI:-1}
QFI=${QFI:-1}

STEP_SEC=${STEP_SEC:-0.2}
MIN_STEP_PCF=${MIN_STEP_PCF:-0}
CYCLES=${CYCLES:-30}
TRANS_PER_CYCLE=4
TRANSITIONS=${TRANSITIONS:-$((CYCLES * TRANS_PER_CYCLE))}
MAX_TRANSITIONS=120
TOTAL_DUR=${TOTAL_DUR:-25}

GBR_5QI66_DL=${GBR_5QI66_DL:-7000000}
GBR_5QI66_UL=${GBR_5QI66_UL:-7000000}
MBR_5QI66_DL=${MBR_5QI66_DL:-9000000}
MBR_5QI66_UL=${MBR_5QI66_UL:-9000000}
GBR_5QI84_DL=${GBR_5QI84_DL:-4000000}
GBR_5QI84_UL=${GBR_5QI84_UL:-4000000}
MBR_5QI84_DL=${MBR_5QI84_DL:-6000000}
MBR_5QI84_UL=${MBR_5QI84_UL:-6000000}

USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}
UE0_FIXED_BITRATE=${UE0_FIXED_BITRATE:-7M}
UE0_UDP_LENGTH=${UE0_UDP_LENGTH:-1200}
UE0_RATE_NON_GBR=${UE0_RATE_NON_GBR:-0.5M}
UE0_RATE_GBR=${UE0_RATE_GBR:-7M}
UE0_RATE_DC_GBR=${UE0_RATE_DC_GBR:-4M}


PCF_MODE=${PCF_MODE:-async}

export IPERF3_DSCP_DEBUG=${IPERF3_DSCP_DEBUG:-1}
IPERF_BIDIR=${IPERF_BIDIR:-0}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PCF_USE_SCHEDULE=${PCF_USE_SCHEDULE:-1}
PCF_SCHEDULE_FILE=${PCF_SCHEDULE_FILE:-"$SCRIPT_DIR/qos_schedule_dscp_replay.csv"}
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

MAX_INFLIGHT=${MAX_INFLIGHT:-8}

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

LOG_FILE=${LOG_FILE:-/tmp/iperf3_dynamic_5qi_pcf_ue0_only.log}
UE0_LOG=${UE0_LOG:-/tmp/iperf3_dynamic_5qi_pcf_ue0_only_iperf.log}
UE1_LOG=${UE1_LOG:-/tmp/iperf3_dynamic_5qi_pcf_ue1_tcp.log}
UE2_LOG=${UE2_LOG:-/tmp/iperf3_dynamic_5qi_pcf_ue2_tcp.log}
ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_dynamic_5qi_pcf_ue0_only_async.log}
APP_SESSION_ID_FILE=${APP_SESSION_ID_FILE:-/tmp/pcf_app_session_id}

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

build_rate_change_by_5qi() {
    local i q r
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        r=$(rate_for_5qi "$(schedule_five_qi_at 0)")
        printf "%s" "$r"
        for i in $(seq 1 $((QOS_SCHEDULE_N - 1))); do
            q=$(schedule_five_qi_at "$i")
            r=$(rate_for_5qi "$q")
            awk -v t="$(schedule_rel_time_at "$i")" -v rate="$r" \
                'BEGIN{printf ",%.6f,%s", t+0, rate}'
        done
        printf "\n"
        return
    fi
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
        if [ "$show_n" -gt 12 ]; then
            show_n=12
        fi
        echo "  스케줄 파일: ${PCF_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"
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
    if [ "$show_n" -gt 8 ]; then
        show_n=8
    fi
    echo "  STEP=${STEP_SEC}s — PCF·rate-change 동일 시각 (트래픽 시작 t=0)"
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

print_5qi_sequence_summary() {
    print_5qi_sequence_from_idx
}

dump_ue0_log() {
    echo "  --- $UE0_LOG ---"
    if [ -s "$UE0_LOG" ]; then
        sed 's/^/    /' "$UE0_LOG"
    else
        echo "    (비어 있음)"
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

af_app_id_for() {
    local five_qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    local mbr_dl=${4:-0}
    local mbr_ul=${5:-0}
    if [ "$gbr_dl" -gt 0 ] || [ "$gbr_ul" -gt 0 ]; then
        if [ "$mbr_dl" -gt 0 ] || [ "$mbr_ul" -gt 0 ]; then
            echo "5GC-QOS:${QFI}:${five_qi}:${gbr_dl}:${gbr_ul}:${mbr_dl}:${mbr_ul}"
        else
            echo "5GC-QOS:${QFI}:${five_qi}:${gbr_dl}:${gbr_ul}"
        fi
    else
        echo "5GC-QOS:${QFI}:${five_qi}"
    fi
}

change_5qi_pcf() {
    local five_qi=$1
    local gbr_dl=${2:-0}
    local gbr_ul=${3:-0}
    local mbr_dl=${4:-0}
    local mbr_ul=${5:-0}
    local af_id
    local response http_status

    af_id=$(af_app_id_for "$five_qi" "$gbr_dl" "$gbr_ul" "$mbr_dl" "$mbr_ul")

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
        66) change_5qi_pcf "$q" "$GBR_5QI66_DL" "$GBR_5QI66_UL" "$MBR_5QI66_DL" "$MBR_5QI66_UL" ;;
        84) change_5qi_pcf "$q" "$GBR_5QI84_DL" "$GBR_5QI84_UL" "$MBR_5QI84_DL" "$MBR_5QI84_UL" ;;
        80) change_5qi_pcf "$q" ;;
        9)  change_5qi_pcf "$q" ;;
        *)  change_5qi_pcf "$q" 0 0 ;;
    esac
}

change_5qi_with_profile_sync() {
    local q=$1
    local rel=$2
    local idx=$3
    local rate pcf_t0_ns pcf_ms

    rate=$(rate_for_5qi "$q")
    pcf_t0_ns=$(date +%s%N)
    if change_5qi_with_profile "$q"; then
        pcf_ms=$(( ($(date +%s%N) - pcf_t0_ns) / 1000000 ))
        log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} PCF OK pcf_ms=${pcf_ms} (sync, iperf rate-change 동일 t)"
        return 0
    fi
    log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} PCF FAIL (sync)"
    return 1
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
        local rate pcf_t0_ns pcf_ms
        rate=$(rate_for_5qi "$q")
        pcf_t0_ns=$(date +%s%N)
        if change_5qi_with_profile "$q"; then
            pcf_ms=$(( ($(date +%s%N) - pcf_t0_ns) / 1000000 ))
            log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} PCF OK pcf_ms=${pcf_ms} (async)"
        else
            log_event "t=${rel}s transition#${idx} 5QI=${q} rate=${rate} PCF FAIL (async)"
        fi
    ) 2>&1 | tee -a "$ASYNC_LOG" >> "$LOG_FILE" &
}

change_5qi_at_transition() {
    local q=$1
    local rel=$2
    local idx=$3

    if [ "$PCF_MODE" = "async" ]; then
        change_5qi_with_profile_async "$q" "$rel" "$idx"
    else
        change_5qi_with_profile_sync "$q" "$rel" "$idx"
    fi
}

if [ "$PCF_USE_SCHEDULE" = "1" ] && [ -f "$PCF_SCHEDULE_FILE" ]; then
    load_qos_schedule_file "$PCF_SCHEDULE_FILE"
    LAST_CHANGE_TIME=$(schedule_rel_time_at $((QOS_SCHEDULE_N - 1)))
else
    PCF_USE_SCHEDULE=0
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

rm -f "$APP_SESSION_ID_FILE"

{
    echo "=========================================="
    echo "  iperf3 Dynamic 5QI — UE0 UDP + UE1/UE2 TCP (한 세션 rate-change + PCF dispatch)"
    echo "  시작: $(timestamp_us)"
    echo "  IPERF3_BIN=$IPERF3_BIN"
    echo "  PCF_BASE=$PCF_BASE"
    echo "  STEP_SEC=$STEP_SEC CYCLES=$CYCLES TRANSITIONS=$TRANSITIONS TOTAL_DUR=$TOTAL_DUR"
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        echo "  PCF_USE_SCHEDULE=1 file=${PCF_SCHEDULE_FILE}"
        echo "  5QI 시퀀스: $(print_5qi_schedule_sequence)"
        echo "  DSCP 대응: $(print_dscp_schedule_sequence)"
    else
        echo "  RANDOM_SEED=$RANDOM_SEED (file=$QOS_RANDOM_SEED_FILE)"
        echo "  5QI 시퀀스: $(print_5qi_sequence_from_idx)"
        echo "  DSCP 대응: $(print_dscp_sequence_from_idx)"
        print_qos_pairing_check
    fi
    echo "  PCF_MODE=$PCF_MODE (iperf 세션 유지)"
    echo "  USE_RATE_CHANGE=$USE_RATE_CHANGE"
    echo "  UE0_UDP_LENGTH=$UE0_UDP_LENGTH"
    if [ "$QOS_USE_SCHEDULE" = "1" ]; then
        echo "  5QI: DSCP 실측 스케줄 재생 (${QOS_SCHEDULE_N} points, last @ ${LAST_CHANGE_TIME}s)"
    fi
    if [ "$USE_RATE_CHANGE" = "1" ]; then
        echo "  UE0: --rate-change ${RATE_CHANGE_ARGS}"
        echo "  초기(9)=${QOS_RATE_INITIAL} pdb-only(80)=${UE0_RATE_NON_GBR} GBR(66)=${UE0_RATE_GBR} DC-GBR(84)=${UE0_RATE_DC_GBR}"
    else
        echo "  UE0: -b ${UE0_FIXED_BITRATE}"
    fi
    echo "  UE1/UE2: TCP background (셀 경쟁)"
    print_phase_timing_cheatsheet
    echo "=========================================="
    echo ""
} >"$LOG_FILE"

if awk -v s="$STEP_SEC" -v m="$MIN_STEP_PCF" 'BEGIN{exit !(s+0 < m+0)}'; then
    echo "WARNING: STEP_SEC=${STEP_SEC}s < MIN_STEP_PCF=${MIN_STEP_PCF}s"
    echo "  PCF→RRC QRT(~200-400ms) 보다 STEP이 짧으면 큐잉 발산·throughput 0 구간 반복."
    echo "  STEP_SEC=5 권장 (이전에 정상 그래프). 강제: MIN_STEP_PCF=0 STEP_SEC=0.5"
    log_event "WARNING STEP_SEC=${STEP_SEC} < MIN_STEP_PCF=${MIN_STEP_PCF}"
fi

echo "=========================================="
echo "  iperf3 Dynamic 5QI — UE0 UDP + UE1/UE2 TCP"
echo "  (UE0 한 세션 rate-change + async PCF tick, UE1/UE2 TCP)"
echo "=========================================="
echo ""
echo "  iperf3: ${IPERF3_BIN}"
if ! "$IPERF3_BIN" --help 2>&1 | grep -q -- '--rate-change'; then
    echo "  WARNING: ${IPERF3_BIN} 에 --rate-change 없음 → 커스텀 iperf3 빌드 필요"
fi
echo "  UE0 (UDP): 한 세션 -t ${TOTAL_DUR} + --rate-change (끊지 않음)"
echo "  PCF_MODE=${PCF_MODE} — 5QI @ 스케줄 시각 (= iperf rate-change)"
if [ "$QOS_USE_SCHEDULE" = "1" ]; then
    echo "    스케줄: ${PCF_SCHEDULE_FILE} (${QOS_SCHEDULE_N} points)"
    echo "    5QI: $(print_5qi_schedule_sequence)"
else
    echo "    5QI: t=0 → 9, 이후 80/66/84 랜덤 (${TRANSITIONS}회, STEP=${STEP_SEC}s)"
    echo "    시퀀스: $(print_5qi_sequence_from_idx)"
fi
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "  + --rate-change (target rate; 5QI MAC throughput은 QRT만큼 지연)"
    echo "    초기(9)=${QOS_RATE_INITIAL}  pdb-only(80)=${UE0_RATE_NON_GBR}  GBR(66)=${UE0_RATE_GBR}  DC-GBR(84)=${UE0_RATE_DC_GBR}"
    echo "    -l ${UE0_UDP_LENGTH}  args: ${RATE_CHANGE_ARGS}"
else
    echo "  -b ${UE0_FIXED_BITRATE} 고정"
fi
echo "  UE1: TCP -> ${UE1_IP}:6501"
echo "  UE2: TCP -> ${UE2_IP}:6502"
echo "  5QI 66 GBR/MBR: ${GBR_5QI66_DL}/${MBR_5QI66_DL} bps DL"
echo "  5QI 84 GBR/MBR: ${GBR_5QI84_DL}/${MBR_5QI84_DL} bps DL"
echo "  5QI 80 pdb-only (non-GBR, no GBR/MBR)"
echo "  5QI 9  초기 (DSCP 0 대응, no GBR/MBR)"
echo ""
echo "  [타이밍 치트시트 — 1사이클]"
print_phase_timing_cheatsheet
echo ""

log_event "테스트 시작 USE_RATE_CHANGE=$USE_RATE_CHANGE PCF_MODE=$PCF_MODE schedule=${QOS_USE_SCHEDULE} 5QI_SEQ=$(if [ "$QOS_USE_SCHEDULE" = "1" ]; then print_5qi_schedule_sequence; else print_5qi_sequence_from_idx; fi)"

echo "[$(timestamp)] 기존 iperf3 종료..."
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1
sleep 1
log_event "기존 iperf3 종료 완료"

echo "[$(timestamp)] UE iperf3 서버 (DL 수신)"
sudo ip netns exec ue1 "$IPERF3_BIN" -s -p 6500 -D 2>/dev/null || true
sudo ip netns exec ue2 "$IPERF3_BIN" -s -p 6501 -D 2>/dev/null || true
sudo ip netns exec ue3 "$IPERF3_BIN" -s -p 6502 -D 2>/dev/null || true
sleep 2

echo "=========================================="
echo "[$(timestamp)] DL 트래픽 시작 (${TOTAL_DUR}초)"
if [ "$USE_RATE_CHANGE" = "1" ]; then
    echo "  UE0: UDP --rate-change \"${RATE_CHANGE_ARGS}\" -l ${UE0_UDP_LENGTH}"
else
    echo "  UE0: UDP -b ${UE0_FIXED_BITRATE} -l ${UE0_UDP_LENGTH}"
fi
echo "  UE1: TCP  UE2: TCP"
echo "=========================================="
log_event "DL 시작 PCF_MODE=$PCF_MODE rate-change=${USE_RATE_CHANGE} transitions=${TRANSITIONS}"

# UE0/1/2 동시 fork → t=0 정렬 (iperf 한 세션 유지, phase마다 restart 없음)
"$IPERF3_BIN" -c "$UE1_IP" -t "$TOTAL_DUR" -p 6501 -i 1 >"$UE1_LOG" 2>&1 &
DL1_PID=$!
"$IPERF3_BIN" -c "$UE2_IP" -t "$TOTAL_DUR" -p 6502 -i 1 >"$UE2_LOG" 2>&1 &
DL2_PID=$!

if [ "$USE_RATE_CHANGE" = "1" ]; then
    UE0_EXTRA_ARGS=""
    if [ "$IPERF_BIDIR" = "1" ]; then
        UE0_EXTRA_ARGS="-d"
    fi
    env IPERF3_DSCP_DEBUG="$IPERF3_DSCP_DEBUG" \
        "$IPERF3_BIN" -c "$UE0_IP" -u -l "$UE0_UDP_LENGTH" -t "$TOTAL_DUR" -p 6500 -i 1 $UE0_EXTRA_ARGS \
        --rate-change "${RATE_CHANGE_ARGS}" \
        >"$UE0_LOG" 2>&1 &
else
    "$IPERF3_BIN" -c "$UE0_IP" -u -b "$UE0_FIXED_BITRATE" -l "$UE0_UDP_LENGTH" \
        -t "$TOTAL_DUR" -p 6500 -i 1 \
        >"$UE0_LOG" 2>&1 &
fi
DL0_PID=$!
TRAFFIC_START_EPOCH_NS=$(date +%s%N)
log_event "PIDs UE0=$DL0_PID UE1=$DL1_PID UE2=$DL2_PID EPOCH_NS=$TRAFFIC_START_EPOCH_NS"
log_event "throughput: MAC-THP-DL / QRT: QOS-RECONFIG-* vs Changed rate in $UE0_LOG"

next_progress_sec=1
EARLY_EXIT=0
PCF_FAIL=0

# PCF 5QI dispatch — 스케줄 또는 고정 STEP tick
if [ "$QOS_USE_SCHEDULE" = "1" ]; then
    for i in $(seq 0 $((QOS_SCHEDULE_N - 1))); do
        rel_sec=$(schedule_rel_time_at "$i")
        wait_until_traffic_rel_s "$rel_sec"

        q=$(schedule_five_qi_at "$i")

        log_event "QRT-T0 transition#${i} t_rel=${rel_sec} five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS"
        change_5qi_at_transition "$q" "$rel_sec" "$i" || PCF_FAIL=1

        elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
        if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
            show_progress "$elapsed_int" "$TOTAL_DUR"
            next_progress_sec=$((elapsed_int + 1))
        fi

        if ! kill -0 "$DL0_PID" 2>/dev/null || ! kill -0 "$DL1_PID" 2>/dev/null || ! kill -0 "$DL2_PID" 2>/dev/null; then
            EARLY_EXIT=1
            break
        fi
    done
else
    wait_until_traffic_rel_s 0
    q=$(five_qi_for_step 0)
    log_event "QRT-T0 transition#0 t_rel=0.000000 five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS"
    change_5qi_at_transition "$q" "0.0000" 0 || PCF_FAIL=1

    for i in $(seq 1 "$TRANSITIONS"); do
        rel_sec=$(awk -v s="$STEP_SEC" -v n="$i" 'BEGIN{printf "%.6f", s*n}')
        wait_until_traffic_rel_s "$rel_sec"

        q=$(five_qi_for_step "$i")

        log_event "QRT-T0 transition#${i} t_rel=${rel_sec} five_qi=${q} epoch_ns=$TRAFFIC_START_EPOCH_NS"
        change_5qi_at_transition "$q" "$rel_sec" "$i" || PCF_FAIL=1

        elapsed_int=$(awk -v e="$rel_sec" 'BEGIN{printf "%d", int(e)}')
        if [ "$elapsed_int" -ge "$next_progress_sec" ]; then
            show_progress "$elapsed_int" "$TOTAL_DUR"
            next_progress_sec=$((elapsed_int + 1))
        fi

        if ! kill -0 "$DL0_PID" 2>/dev/null || ! kill -0 "$DL1_PID" 2>/dev/null || ! kill -0 "$DL2_PID" 2>/dev/null; then
            EARLY_EXIT=1
            break
        fi
    done
fi

if [ "$PCF_MODE" = "async" ]; then
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
    if ! kill -0 "$DL0_PID" 2>/dev/null || ! kill -0 "$DL1_PID" 2>/dev/null || ! kill -0 "$DL2_PID" 2>/dev/null; then
        EARLY_EXIT=1
        break
    fi
    show_progress "$((TOTAL_DUR - remaining_int + i))" "$TOTAL_DUR"
    sleep 1
done
printf "\n"

set +e
wait "$DL0_PID"
DL0_RC=$?
wait "$DL1_PID" "$DL2_PID"
TCP_RC=$?
set -e

if [ "$EARLY_EXIT" -eq 1 ] || [ "$DL0_RC" -ne 0 ]; then
    echo "[$(timestamp)] ERROR: iperf3 조기 종료 (UE0 rc=${DL0_RC})"
    dump_ue0_log | tee -a "$LOG_FILE"
    exit "${DL0_RC:-1}"
fi
if [ "$TCP_RC" -ne 0 ]; then
    echo "[$(timestamp)] WARNING: UE1/UE2 TCP rc=$TCP_RC"
fi

echo ""
echo "[$(timestamp)] iperf3 결과 요약"
summarize_iperf_log "UE0 UDP 5QI+rate-change" "$UE0_LOG" | tee -a "$LOG_FILE"
summarize_iperf_log "UE1 TCP" "$UE1_LOG" | tee -a "$LOG_FILE"
summarize_iperf_log "UE2 TCP" "$UE2_LOG" | tee -a "$LOG_FILE"

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

echo "[$(timestamp)] PCF 전환 요약"
PCF_OK_N=$(grep -c 'PCF OK' "$LOG_FILE" 2>/dev/null || echo 0)
PCF_FAIL_N=$(grep -c 'PCF FAIL' "$LOG_FILE" 2>/dev/null || echo 0)
echo "  PCF OK=${PCF_OK_N}  PCF FAIL=${PCF_FAIL_N}  (grep $LOG_FILE)"
if [ "$PCF_OK_N" -eq 0 ]; then
    echo "  ERROR: PCF OK 없음 — retun 오타/PCF 연결/구버전 스크립트 확인"
    grep -E 'PCF FAIL|PCF pre-create' "$LOG_FILE" 2>/dev/null | tail -5 | sed 's/^/    /' || true
fi
echo ""

log_event "정리"
kill "$DL0_PID" "$DL1_PID" "$DL2_PID" 2>/dev/null || true
sleep 1
{ sudo pkill -x iperf3 2>/dev/null || true; } >/dev/null 2>&1

echo "=========================================="
echo "[$(timestamp)] 테스트 완료"
echo "  로그: $LOG_FILE"
echo "  UE0: $UE0_LOG"
echo "  UE1: $UE1_LOG"
echo "  UE2: $UE2_LOG"
echo "  appSession: $(cat "$APP_SESSION_ID_FILE" 2>/dev/null || echo n/a)"
echo ""
echo "  QRT (슬라이드): iperf Changed rate → QOS-RECONFIG-ACTIVE (~250ms PCF)"
echo "    python3 $SCRIPT_DIR/analyze_qrt.py --mode pcf --test-log $LOG_FILE \\"
echo "      --ue0-log $UE0_LOG --gnb-log \${GNBS_LOG:-/tmp/gnb.log} --ue 0"
echo "  MAC: grep 'MAC-THP-DL' \${GNBS_LOG:-/tmp/gnb.log}"
echo "  phase 중앙 (STEP=${STEP_SEC}): 66 ~7M GBR, 84 ~4M DC-GBR, 80 ~0.5M pdb-only, 9 초기"
GNBS_LOG=${GNBS_LOG:-/tmp/gnb.log}
if [ -f "$GNBS_LOG" ] && [ -f "$SCRIPT_DIR/analyze_qrt.py" ]; then
    echo ""
    echo "[$(timestamp)] QRT 분석 (PCF, target ~250ms active)"
    python3 "$SCRIPT_DIR/analyze_qrt.py" --mode pcf --test-log "$LOG_FILE" \
        --ue0-log "$UE0_LOG" --gnb-log "$GNBS_LOG" --ue 0 || true
fi
if [ "$PCF_FAIL" -ne 0 ]; then
    echo "  WARNING: PCF 전환 일부 실패 — $LOG_FILE 확인"
fi
echo "=========================================="
log_event "종료"
