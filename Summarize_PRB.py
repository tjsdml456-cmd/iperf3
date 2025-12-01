import re, datetime as dt, collections, sys, pathlib

logfile = pathlib.Path("ue1.log")

# 정규식 : ISO 시각 + prb=(a,b)
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
        ts = dt.datetime.fromisoformat(ts_str)  # 2025-06-29T07:45:24
        bucket = ts.replace(microsecond=0)      # 1초 단위
        per_sec[bucket] += (b - a)

# ▶ 원하는 구간 슬라이싱
start = dt.datetime.fromisoformat('2025-06-30T15:09:26')
end   = dt.datetime.fromisoformat('2025-06-30T15:21:44')

for t in sorted(per_sec):
    if start <= t <= end:
        print(t.time(), f"{per_sec[t]:>4} PRB")
