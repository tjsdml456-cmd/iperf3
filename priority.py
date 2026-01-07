#!/usr/bin/env python3
"""
UE별 Priority 정보 추출 스크립트
로그 파일에서 각 UE의 min_combined_prio, prio_weight 등의 정보를 추출합니다.
"""

import re
import sys
from collections import defaultdict
from typing import Dict, List
from datetime import datetime

def parse_priority_log(log_file: str) -> Dict[int, List[Dict]]:
    """
    로그 파일에서 UE별 priority 정보를 파싱합니다.
    
    Args:
        log_file: 로그 파일 경로
        
    Returns:
        UE 인덱스를 키로 하고, priority 정보 딕셔너리 리스트를 값으로 하는 딕셔너리
    """
    ue_data = defaultdict(list)
    
    # 로그 라인 패턴: timestamp + UE{번호} min_combined_prio={값}, prio_weight={값}, ...
    # 예: 2025-12-27T07:13:44.846214 [SCHED   ] [I] [   998.3] DL Priority calc: UE2 min_combined_prio=80, ...
    pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?'
        r'UE(\d+)\s+min_combined_prio=(\d+),\s+prio_weight=([\d.]+),\s+'
        r'pf_weight=([\d.]+),\s+gbr_weight=([\d.]+),\s+delay_weight=([\d.]+)'
    )
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                match = pattern.search(line)
                if match:
                    timestamp_str = match.group(1)
                    ue_idx = int(match.group(2))
                    try:
                        # ISO format timestamp 파싱
                        timestamp = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        # 파싱 실패 시 기본값 사용
                        timestamp = None
                    
                    entry = {
                        'line': line_num,
                        'timestamp': timestamp,
                        'timestamp_str': timestamp_str,
                        'min_combined_prio': int(match.group(3)),
                        'prio_weight': float(match.group(4)),
                        'pf_weight': float(match.group(5)),
                        'gbr_weight': float(match.group(6)),
                        'delay_weight': float(match.group(7)),
                        'raw_line': line.strip()
                    }
                    ue_data[ue_idx].append(entry)
    except FileNotFoundError:
        print(f"Error: 파일 '{log_file}'을 찾을 수 없습니다.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: 파일 읽기 중 오류 발생: {e}")
        sys.exit(1)
    
    # 각 UE별로 타임스탬프 기준으로 정렬 (None 값은 마지막에)
    for ue_idx in ue_data.keys():
        ue_data[ue_idx] = sorted(
            ue_data[ue_idx], 
            key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max
        )
    
    return ue_data

def print_summary(ue_data: Dict[int, List[Dict]]):
    """UE별 요약 정보를 출력합니다."""
    print("=" * 80)
    print("UE별 Priority 정보 요약")
    print("=" * 80)
    
    for ue_idx in sorted(ue_data.keys()):
        entries = ue_data[ue_idx]
        if not entries:
            continue
            
        print(f"\n[UE{ue_idx}] 총 {len(entries)}개의 레코드")
        print("-" * 80)
        
        # 통계 계산
        min_combined_prios = [e['min_combined_prio'] for e in entries]
        prio_weights = [e['prio_weight'] for e in entries]
        pf_weights = [e['pf_weight'] for e in entries]
        
        print(f"  min_combined_prio:")
        print(f"    - 최소값: {min(min_combined_prios)}")
        print(f"    - 최대값: {max(min_combined_prios)}")
        print(f"    - 평균값: {sum(min_combined_prios) / len(min_combined_prios):.2f}")
        unique_prios = sorted(set(min_combined_prios))
        print(f"    - 고유값: {unique_prios}")
        
        print(f"  prio_weight:")
        print(f"    - 최소값: {min(prio_weights):.3f}")
        print(f"    - 최대값: {max(prio_weights):.3f}")
        print(f"    - 평균값: {sum(prio_weights) / len(prio_weights):.3f}")
        
        print(f"  pf_weight:")
        print(f"    - 최소값: {min(pf_weights):.6f}")
        print(f"    - 최대값: {max(pf_weights):.6f}")
        print(f"    - 평균값: {sum(pf_weights) / len(pf_weights):.6f}")

def get_global_first_timestamp(ue_data: Dict[int, List[Dict]]) -> datetime:
    """모든 UE의 레코드 중 가장 이른 타임스탬프를 찾습니다."""
    global_first = None
    for ue_idx, entries in ue_data.items():
        for entry in entries:
            if entry['timestamp'] is not None:
                if global_first is None or entry['timestamp'] < global_first:
                    global_first = entry['timestamp']
    return global_first

def print_detailed(ue_data: Dict[int, List[Dict]], ue_idx: int = None, use_global_time: bool = True):
    """특정 UE의 상세 정보를 시간 순서대로 전체 출력합니다.
    
    Args:
        ue_data: UE별 데이터
        ue_idx: 특정 UE만 출력 (None이면 모두)
        use_global_time: True면 모든 UE의 가장 이른 시간을 기준으로 사용 (기본값: True)
    """
    if ue_idx is not None:
        ues_to_print = [ue_idx] if ue_idx in ue_data else []
    else:
        ues_to_print = sorted(ue_data.keys())
    
    # 공통 기준 시간 계산 (기본값으로 활성화)
    global_first_timestamp = None
    if use_global_time:
        global_first_timestamp = get_global_first_timestamp(ue_data)
        if global_first_timestamp:
            print(f"\n{'=' * 80}")
            print(f"[공통 기준 시간] {global_first_timestamp.isoformat()}")
            print(f"모든 UE의 시간은 이 기준 시간으로부터의 경과 시간(초)입니다.")
            print(f"{'=' * 80}")
    
    for ue in ues_to_print:
        entries = ue_data[ue]
        if not entries:
            continue
        
        # 이미 parse_priority_log에서 정렬되었지만, 다시 확인
        # timestamp 기준으로 정렬 (None 값은 마지막에 배치)
        entries_sorted = sorted(entries, key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max)
        
        # 기준 시간 선택: 공통 시간 사용 옵션이 켜져 있으면 그것을, 아니면 UE별 첫 시간 사용
        if use_global_time and global_first_timestamp is not None:
            first_timestamp = global_first_timestamp
            time_label = "공통 기준 시간"
        else:
            # 정렬된 리스트의 첫 번째 유효한 타임스탬프를 기준으로 사용
            first_timestamp = None
            for entry in entries_sorted:
                if entry['timestamp'] is not None:
                    first_timestamp = entry['timestamp']
                    break
            time_label = "UE별 기준 시간"
        
        if first_timestamp is None:
            print(f"\n[경고] UE{ue}: 유효한 타임스탬프가 없습니다.")
            first_timestamp = datetime.now()  # fallback
        
        print(f"\n{'=' * 80}")
        print(f"UE{ue} 상세 정보 (전체 {len(entries_sorted)}개, 시간 순서대로 정렬)")
        print(f"{time_label}: {first_timestamp.isoformat()}")
        print(f"{'=' * 80}")
        print(f"{'시간(분:초)':<15} {'min_combined_prio':<18} {'prio_weight':<12} {'pf_weight':<12} {'gbr_weight':<12} {'delay_weight':<12}")
        print("-" * 80)
        
        for entry in entries_sorted:
            if entry['timestamp'] is not None:
                # 분:초.XX 형식으로 표시 (시간 제외, 소수점 둘째 자리)
                minutes = entry['timestamp'].minute
                seconds = entry['timestamp'].second + entry['timestamp'].microsecond / 1000000.0
                abs_time_str = f"{minutes:02d}:{seconds:05.2f}"
            else:
                abs_time_str = "N/A"
            print(f"{abs_time_str:<15} {entry['min_combined_prio']:<18} "
                  f"{entry['prio_weight']:<12.3f} {entry['pf_weight']:<12.6f} "
                  f"{entry['gbr_weight']:<12.3f} {entry['delay_weight']:<12.3f}")

def export_to_csv(ue_data: Dict[int, List[Dict]], output_file: str):
    """UE별 데이터를 시간 순서대로 CSV 파일로 저장합니다."""
    import csv
    
    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['UE', '시간(초)', 'min_combined_prio', 'prio_weight', 
                        'pf_weight', 'gbr_weight', 'delay_weight'])
        
        for ue_idx in sorted(ue_data.keys()):
            entries = ue_data[ue_idx]
            # 이미 정렬되어 있지만 다시 확인
            entries_sorted = sorted(entries, key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max)
            
            # 정렬된 리스트의 첫 번째 유효한 타임스탬프를 기준으로 사용
            first_timestamp = None
            for entry in entries_sorted:
                if entry['timestamp'] is not None:
                    first_timestamp = entry['timestamp']
                    break
            
            if first_timestamp is None:
                first_timestamp = datetime.now()  # fallback
            
            for entry in entries_sorted:
                if entry['timestamp'] is not None:
                    elapsed_seconds = (entry['timestamp'] - first_timestamp).total_seconds()
                else:
                    elapsed_seconds = None
                writer.writerow([
                    ue_idx,
                    f"{elapsed_seconds:.1f}" if elapsed_seconds is not None else "",
                    entry['min_combined_prio'],
                    entry['prio_weight'],
                    entry['pf_weight'],
                    entry['gbr_weight'],
                    entry['delay_weight']
                ])
    
    print(f"\n데이터가 '{output_file}'에 저장되었습니다.")

def main():
    # 기본 로그 파일명
    default_log_file = 'gnb.log'
    
    # Help 체크
    if len(sys.argv) >= 2 and sys.argv[1] in ['-h', '--help']:
        print("Usage: python extract_ue_priority.py [log_file] [options]")
        print(f"\nArguments:")
        print(f"  log_file       로그 파일 경로 (기본값: {default_log_file})")
        print("\nOptions:")
        print("  -u <ue_idx>    특정 UE만 출력 (예: -u 0)")
        print("  -c <csv_file>  CSV 파일로 저장")
        print("  -g, --global   모든 UE를 공통 기준 시간으로 정렬")
        print("  -h, --help     도움말 출력")
        sys.exit(0)
    
    # 로그 파일명 결정
    if len(sys.argv) >= 2 and not sys.argv[1].startswith('-'):
        log_file = sys.argv[1]
        opt_start = 2
    else:
        log_file = default_log_file
        opt_start = 1
    
    ue_idx = None
    csv_file = None
    use_global_time = False
    
    # 옵션 파싱
    i = opt_start
    while i < len(sys.argv):
        if sys.argv[i] == '-u' and i + 1 < len(sys.argv):
            ue_idx = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == '-c' and i + 1 < len(sys.argv):
            csv_file = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] in ['-g', '--global']:
            use_global_time = True
            i += 1
        else:
            print(f"Warning: 알 수 없는 옵션 '{sys.argv[i]}' (무시됨)")
            i += 1
    
    # 데이터 파싱
    print(f"로그 파일 파싱 중: {log_file}")
    ue_data = parse_priority_log(log_file)
    
    if not ue_data:
        print("추출된 데이터가 없습니다.")
        sys.exit(1)
    
    # 전체 상세 정보 출력
    print_detailed(ue_data, ue_idx, use_global_time)
    
    # CSV 저장
    if csv_file:
        export_to_csv(ue_data, csv_file)

if __name__ == '__main__':
    main()

