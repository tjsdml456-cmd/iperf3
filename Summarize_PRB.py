import re, datetime as dt, collections, sys, pathlib

logfile = pathlib.Path("ue1.log")

# 정규식: ISO 시각 + prb=(a,b)
# 예: "2025-12-01T03:43:28.262564 ... prb=(0, 2) ..."
pat = re.compile(
    r'^(?P<ts>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+.*?prb=\((\d+),(\d+)\)'
)

per_sec = collections.Counter()

with logfile.open() as f:
    for line in f:
        m = pat.search(line)
        if not m:
            continue
        
        ts_str, a, b = m.group('ts'), int(m.group(2)), int(m.group(3))
        ts = dt.datetime.fromisoformat(ts_str)
        bucket = ts.replace(microsecond=0)  # 1초 단위
        per_sec[bucket] += (b - a)

# 원하는 구간 슬라이싱
# start = dt.datetime.fromisoformat('2025-12-01T03:43:15')
# end   = dt.datetime.fromisoformat('2025-12-01T03:43:54')

# 첫 번째 시간을 기준으로 상대 시간 계산
sorted_times = sorted(per_sec)
if sorted_times:
    first_time = sorted_times[0]
    
    for t in sorted_times:
        # if start <= t <= end:  # 구간 필터링 (필요하면 주석 해제)
        elapsed_seconds = int((t - first_time).total_seconds())
        prb_count = per_sec[t]
        print(f"{elapsed_seconds:>4}초", f"{prb_count:>4} PRB")

