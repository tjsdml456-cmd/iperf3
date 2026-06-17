#!/bin/bash
# set -e 제거 (하나 죽어도 나머지는 떠야 함)
BASE_DIR="$HOME/srsRAN_main/open5gs"
BIN_DIR="$BASE_DIR/install/bin"
CONF_DIR="$BASE_DIR/install/etc/open5gs"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$LOG_DIR"
cd "$BASE_DIR"

# ogstun 먼저 보장
if ! ip link show ogstun &>/dev/null; then
  echo "[+] ogstun 생성"
  sudo ip tuntap add name ogstun mode tun
  sudo ip addr add 10.45.0.1/16 dev ogstun
  sudo ip link set ogstun up
fi

# NRF를 가장 먼저 띄우고 잠깐 대기
$BIN_DIR/open5gs-nrfd -c "$CONF_DIR/nrf.yaml" 2>&1 | tee "$LOG_DIR/nrfd.log" &
sleep 2

NFS=(
  udmd:udm.yaml ausfd:ausf.yaml pcfd:pcf.yaml amfd:amf.yaml
  smfd:smf.yaml upfd:upf.yaml bsfd:bsf.yaml nssfd:nssf.yaml
  scpd:scp.yaml udrd:udr.yaml
  hssd:hss.yaml mmed:mme.yaml pcrfd:pcrf.yaml
  sgwcd:sgwc.yaml sgwud:sgwu.yaml
)
for item in "${NFS[@]}"; do
  bin="open5gs-${item%%:*}"
  conf="$CONF_DIR/${item##*:}"
  log="$LOG_DIR/${item%%:*}.log"
  echo "[실행] $bin"
  $BIN_DIR/$bin -c "$conf" 2>&1 | tee "$log" &
  sleep 0.3
done

echo "[+] Open5GS 실행 완료"
echo "    중지: pkill -f open5gs-"
wait
