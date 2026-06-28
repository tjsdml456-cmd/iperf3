#!/bin/bash
# UE0 단독 — 0.5s 5QI 사이클, PDB/GBR/MBR "어느 정도 충족" 프로파일
#
# 설계 원칙 (기존 5s 스크립트 대비):
#   1) iperf offer < GBR (약 70~75%) → MFBR policer·큐 발산 완화
#   2) MBR = GBR × 1.3~1.4 (headroom) → 100ms window policer 여유
#   3) UE0 only → 3UE RB 1/3 경쟁 제거 (PDB 검증용)
#   4) STEP=0.5s → QRT(~250ms) 후 ~250ms만 steady; 분석은 phase 중후반만
#
# 실행:
#   ./iperf3_dynamic_5qi_pcf_ue0_compliant_500ms.sh
#   GNB_LOG=/tmp/gnb.log ./iperf3_dynamic_5qi_pcf_ue0_compliant_500ms.sh
#
# 사후 검증 (phase 중앙 구간, QRT 0.35s 이후):
#   grep 'MAC-THP-DL' "$GNB_LOG" | grep UE0
#   grep 'DELAY-WEIGHT' "$GNB_LOG" | grep UE0
#   grep 'RLC-QUEUE-DELAY' "$GNB_LOG" | grep 'ue=0'

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- 0.5s QoS tick ---
export STEP_SEC=${STEP_SEC:-0.5}
export MIN_STEP_PCF=${MIN_STEP_PCF:-0}
export CYCLES=${CYCLES:-6}
export PCF_MODE=${PCF_MODE:-async}
export MAX_INFLIGHT=${MAX_INFLIGHT:-16}

# 6 cycles × 4 transitions = 24; last change @ 12.0s
export TRANSITIONS=${TRANSITIONS:-$((CYCLES * 4))}
export TOTAL_DUR=${TOTAL_DUR:-16}

# --- PCF GBR/MBR (bps): offer보다 크게, MBR은 GBR보다 여유 ---
export GBR_5QI3_DL=${GBR_5QI3_DL:-4000000}
export GBR_5QI3_UL=${GBR_5QI3_UL:-4000000}
export MBR_5QI3_DL=${MBR_5QI3_DL:-5500000}
export MBR_5QI3_UL=${MBR_5QI3_UL:-5500000}

export GBR_5QI84_DL=${GBR_5QI84_DL:-3000000}
export GBR_5QI84_UL=${GBR_5QI84_UL:-3000000}
export MBR_5QI84_DL=${MBR_5QI84_DL:-4200000}
export MBR_5QI84_UL=${MBR_5QI84_UL:-4200000}

# --- iperf offer: GBR의 ~70~75% (큐·PDB 여유) ---
export USE_RATE_CHANGE=${USE_RATE_CHANGE:-1}
export UE0_UDP_LENGTH=${UE0_UDP_LENGTH:-800}
export UE0_RATE_NON_GBR=${UE0_RATE_NON_GBR:-800k}
export UE0_RATE_GBR=${UE0_RATE_GBR:-3M}
export UE0_RATE_DC_GBR=${UE0_RATE_DC_GBR:-2.2M}

export LOG_FILE=${LOG_FILE:-/tmp/iperf3_compliant_500ms.log}
export UE0_LOG=${UE0_LOG:-/tmp/iperf3_compliant_500ms_iperf.log}
export ASYNC_LOG=${ASYNC_LOG:-/tmp/iperf3_compliant_500ms_async.log}

echo "=========================================="
echo "  Compliant 500ms profile → UE0 rate-change"
echo "=========================================="
echo "  STEP_SEC=${STEP_SEC}s  CYCLES=${CYCLES}  TOTAL_DUR=${TOTAL_DUR}s"
echo "  5QI 3  GBR/MBR DL: ${GBR_5QI3_DL}/${MBR_5QI3_DL}  iperf: ${UE0_RATE_GBR}"
echo "  5QI 84 GBR/MBR DL: ${GBR_5QI84_DL}/${MBR_5QI84_DL}  iperf: ${UE0_RATE_DC_GBR}"
echo "  5QI 9/8 non-GBR iperf: ${UE0_RATE_NON_GBR}"
echo ""
echo "  [기대 — UE0 only, phase 중후반 t+0.35~t+0.48s]"
echo "    MAC-THP-DL: non-GBR ~0.8M | GBR ~2.5-3.5M | DC-GBR ~2.0-2.5M"
echo "    hol_delay_ms < PDB (5QI3~50ms, 9/8~300ms — 표준값 기준)"
echo "    RLC-QUEUE-DELAY queue_delay_ms < PDB (dequeue 샘플)"
echo ""
echo "  WARNING: STEP=0.5s → QRT(~250ms) 후 steady ~250ms만. 위반은 전환 직후 0.2s는 제외."
echo "=========================================="
echo ""

exec "$SCRIPT_DIR/iperf3_dynamic_5qi_pcf_ue0_only_rate_change.sh"
