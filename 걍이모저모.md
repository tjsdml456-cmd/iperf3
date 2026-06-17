4/20
ASYNC_SEND=1 MAX_INFLIGHT=200 ./run_5qi.sh
UE1_FIXED_BITRATE=40M UE1_UDP_LENGTH=200
grep "QOS-RECONFIG" gnb.log > du.log

rg -n 'ue=0' gnb.log | rg 'rrcReconfigurationComplete|FIRST-GRANT' > rrc.log


sudo ./srsue ue1_zmq.conf --nas.5g_control_socket=/tmp/srsue0_nas5g_control
rg 'UPF-DSCP.*N6-TUN-DL' upfd.log > core.log
python3 upf.py core.log --start-time 16:15:26.893623   --relative-time > upf.txt

python3 async.py iperf3_dscp_100cycles_dl.log --start-time 22:50:26.351730   --relative-time > async.txt

grep "UE0 Throughput calc" gnb.log > thro.log
grep 'UE0 Throughput 1ms' gnb.log > thro.log
python3 thro.py thro.log --start-time 07:15:26.893623 --bin-ms 50 --relative-time > thro.txt

grep "RLC-QUEUE-DELAY" gnb.log | grep "ue=0" > delay.log
python3 delay.py delay.log --relative-time --start-time 07:15:26.893623 > delay.txt

grep "prio_weight" gnb.log | grep "UE0" > prio.log
python3 prio.py prio.log  --start-time 03:24:46.537472  --relative-time > prio.txt

grep -n "\[GTPU\] DL SDU DSCP changed to" gnb.log > gtp.log
python3 gtp.py gtp.log --start-time 15:54:11.477748  --relative-time > gtp.txt

core
grep "UE0 Throughput 1ms:" gnb.log > thro.log

grep 'PCF-API-INGRESS' pcfd.log > pcf.log
python3 pcf.py pcf.log  --start-time 15:17:11.599257   --relative-time > pcf.txt

grep -nE '\[QoS-MODIFY\] \[CP-5QI\] DRB modification received from control-plane\.|\[QoS-MODIFY\] \[CP-5QI\] Requested flow from control-plane\.' gnb.log > up.log
python3 up.py up.log --ue 0 --start-time 08:44:04.208158 --relative-time --dedup-consecutive --dedup-mode first > up.txt

grep -nF '[DELAY-WEIGHT] UE0 LCID4' gnb.log  > delay.log
python3 core_delay.py delay.log  --relative-time --start-time 06:49:46.045596  --only-hol-pdb > delay.txt

grep -nE 'DL Priority calc: UE0 .*prio_weight=' gnb.log > prio.log
python3 core_prio.py prio.log --start-time 06:17:11.599257  --relative-time --exclude-prio-weight 0.001 > prio.txt

grep -E '\[NGAP-BUILD\].*(Building QoS Flow Modify Request|fill_qos_level_parameters):.*5QI=[0-9]+.*GBR_DL=[0-9]+.*GBR_UL=[0-9]+' smfd.log > prio.log
python3 prio.py prio.log --start-time 17:35:23.068 --relative-time > prio.txt

 python3 async.py iperf3_dynamic_5qi_100cycles_dl.log --mode success --relative-time  > async.txt
