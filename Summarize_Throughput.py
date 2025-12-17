import re, datetime as dt, collections

logfile = "gnb.log"
pat = re.compile(r'^(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+.*?UE(\d+) Throughput calc:.*?dl_brate_kbps=(\d+\.\d+)')

per_ue_per_sec = collections.defaultdict(lambda: collections.Counter())

with open(logfile) as f:
    for line in f:
        m = pat.search(line)
        if m:
            ts_str, ue_idx, kbps = m.groups()
            ts = dt.datetime.fromisoformat(ts_str)
            bucket = ts.replace(microsecond=0)  # 1초 단위
            per_ue_per_sec[int(ue_idx)][bucket] = float(kbps)  # 마지막 값 저장 (또는 평균 계산 가능)

# UE별로 시간대별 throughput 출력
for ue_idx in sorted(per_ue_per_sec.keys()):
    print(f"\n=== UE{ue_idx} ===")
    sorted_times = sorted(per_ue_per_sec[ue_idx].keys())
    if sorted_times:
        first_time = sorted_times[0]
        for t in sorted_times:
            elapsed_seconds = int((t - first_time).total_seconds())
            kbps = per_ue_per_sec[ue_idx][t]
            mbps = kbps / 1000.0
            print(f"{elapsed_seconds:>4}초: {mbps:>6.2f} Mbps (kbps={kbps:.2f})")
    
    # 평균 계산
    kbps_list = list(per_ue_per_sec[ue_idx].values())
    avg_kbps = sum(kbps_list) / len(kbps_list)
    avg_mbps = avg_kbps / 1000.0
    print(f"평균: {avg_mbps:.2f} Mbps (측정 횟수: {len(kbps_list)})")
