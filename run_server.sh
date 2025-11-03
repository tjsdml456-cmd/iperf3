                                                         run_server.sh
#!/bin/bash
set -e

# 기존 iperf3 서버 종료
sudo pkill -f iperf3

# 서버 재시작 (클라이언트 프로토콜에 자동 대응)
iperf3 -s  -B 10.99.0.2 -p 5500 -i 1 &
iperf3 -s  -B 10.99.0.3 -p 5501 -i 1 &
iperf3 -s  -B 10.99.0.4 -p 5502 -i 1 &
