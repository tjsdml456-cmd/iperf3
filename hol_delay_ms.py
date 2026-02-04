#!/usr/bin/env python3
"""
UE별 HOL Delay 정보 추출 스크립트
로그 파일에서 각 UE의 HOL (Head of Line) delay 정보를 추출합니다.
타임스탬프는 마이크로초 단위로 추출됩니다.
"""

import re
import sys
from collections import defaultdict
from typing import Dict, List, Optional
from datetime import datetime, timedelta

def parse_hol_delay_log(log_file: str) -> Dict[int, List[Dict]]:
    """
    로그 파일에서 UE별 HOL delay 정보를 파싱합니다.
    
    Args:
        log_file: 로그 파일 경로
        
    Returns:
        UE 인덱스를 키로 하고, HOL delay 정보 딕셔너리 리스트를 값으로 하는 딕셔너리
    """
    ue_data = defaultdict(list)
    
    # [DELAY-WEIGHT] 로그 패턴 (hol_delay_ms가 있는 경우만 파싱)
    # 예: [DELAY-WEIGHT] UE0 LCID4 hol_toa=1234 slot_tx=5678 hol_delay_ms=100 PDB=200ms delay_contrib=0.500 delay_weight=0.500
    # 타임스탬프: 마이크로초 단위 (예: 2026-02-04T07:00:53.900457)
    hol_delay_pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?'
        r'\[DELAY-WEIGHT\]\s+UE(\d+)\s+LCID\d+\s+'
        r'hol_toa=\d+\s+slot_tx=\d+\s+'
        r'hol_delay_ms=(\d+)'
    )
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                # hol_delay_ms가 있는 로그만 파싱
                match = hol_delay_pattern.search(line)
                if match:
                    timestamp_str = match.group(1)
                    ue_idx = int(match.group(2))
                    try:
                        timestamp = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        timestamp = None
                    
                    # 마이크로초 추출 (timestamp_str에서 . 이후 부분)
                    microsecond_str = ""
                    if '.' in timestamp_str:
                        microsecond_str = timestamp_str.split('.')[-1]
                        # 6자리 미만이면 0으로 패딩
                        microsecond_str = microsecond_str.ljust(6, '0')[:6]
                    
                    entry = {
                        'timestamp': timestamp,
                        'timestamp_str': timestamp_str,
                        'timestamp_us': int(microsecond_str) if microsecond_str else 0,
                        'hol_delay_ms': int(match.group(3))
                    }
                    ue_data[ue_idx].append(entry)
    except FileNotFoundError:
        print(f"Error: 파일 '{log_file}'을 찾을 수 없습니다.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: 파일 읽기 중 오류 발생: {e}")
        sys.exit(1)
    
    # 각 UE별로 타임스탬프 기준으로 정렬
    for ue_idx in ue_data.keys():
        ue_data[ue_idx] = sorted(
            ue_data[ue_idx], 
            key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max
        )
    
    return ue_data

def get_global_first_timestamp(ue_data: Dict[int, List[Dict]]) -> Optional[datetime]:
    """모든 UE의 레코드 중 가장 이른 타임스탬프를 찾습니다."""
    global_first = None
    for ue_idx, entries in ue_data.items():
        for entry in entries:
            if entry['timestamp'] is not None:
                if global_first is None or entry['timestamp'] < global_first:
                    global_first = entry['timestamp']
    return global_first

def print_hol_delay_summary(ue_data: Dict[int, List[Dict]]):
    """UE별 HOL delay 요약 정보를 출력합니다."""
    print("=" * 80)
    print("UE별 HOL Delay (큐잉 딜레이) 정보 요약")
    print("=" * 80)
    
    for ue_idx in sorted(ue_data.keys()):
        entries = ue_data[ue_idx]
        if not entries:
            continue
        
        hol_delays = [e['hol_delay_ms'] for e in entries]
        
        print(f"\n[UE{ue_idx}]")
        print("-" * 80)
        print(f"  총 레코드 수: {len(entries)}")
        print(f"\n  HOL Delay (큐잉 딜레이, ms):")
        print(f"    - 최소값: {min(hol_delays)} ms")
        print(f"    - 최대값: {max(hol_delays)} ms")
        print(f"    - 평균값: {sum(hol_delays) / len(hol_delays):.2f} ms")

def print_hol_delay_detailed(ue_data: Dict[int, List[Dict]], ue_idx: Optional[int] = None, use_global_time: bool = True):
    """특정 UE의 상세 HOL delay 정보를 출력합니다. (마이크로초 단위 타임스탬프)"""
    if ue_idx is not None:
        ues_to_print = [ue_idx] if ue_idx in ue_data else []
    else:
        ues_to_print = sorted(ue_data.keys())
    
    for ue in ues_to_print:
        entries = ue_data[ue]
        if not entries:
            continue
        
        entries_sorted = sorted(entries, key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max)
        
        print(f"\n{'=' * 80}")
        print(f"UE{ue} HOL Delay (큐잉 딜레이) 상세 정보")
        print(f"전체 {len(entries_sorted)}개 (타임스탬프: 마이크로초 단위)")
        print(f"{'=' * 80}")
        print(f"{'시스템 시간 (시:분:초.마이크로초)':<45} {'HOL Delay (ms)':<20}")
        print("-" * 80)
        
        for entry in entries_sorted:
            if entry['timestamp'] is not None:
                # 마이크로초 단위로 표시 (%f는 마이크로초 6자리)
                time_str = entry['timestamp'].strftime("%H:%M:%S.%f")
            else:
                time_str = "N/A"
            
            hol_delay_str = f"{entry['hol_delay_ms']}"
            
            print(f"{time_str:<45} {hol_delay_str:<20}")

def export_to_csv(ue_data: Dict[int, List[Dict]], output_file: str):
    """UE별 HOL delay 데이터를 CSV 파일로 저장합니다. (마이크로초 단위 타임스탬프)"""
    import csv
    
    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['UE', '시스템 시간 (마이크로초)', 'HOL Delay (ms)'])
        
        for ue_idx in sorted(ue_data.keys()):
            entries = ue_data[ue_idx]
            entries_sorted = sorted(entries, key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max)
            
            for entry in entries_sorted:
                if entry['timestamp'] is not None:
                    # ISO 형식 (마이크로초 포함, 예: 2026-02-04T07:00:53.900457)
                    time_str = entry['timestamp'].isoformat()
                else:
                    time_str = ""
                
                writer.writerow([
                    ue_idx,
                    time_str,
                    entry['hol_delay_ms']
                ])
    
    print(f"\n데이터가 '{output_file}'에 저장되었습니다.")

def main():
    default_log_file = 'gnb.log'
    
    if len(sys.argv) >= 2 and sys.argv[1] in ['-h', '--help']:
        print("Usage: python extract_ue_hol_delay.py [log_file] [options]")
        print(f"\nArguments:")
        print(f"  log_file       로그 파일 경로 (기본값: {default_log_file})")
        print("\nOptions:")
        print("  -u <ue_idx>    특정 UE만 출력 (기본값: 0, 예: -u 1)")
        print("  -c <csv_file>  CSV 파일로 저장")
        print("  -g, --global   모든 UE를 공통 기준 시간으로 정렬 (기본값)")
        print("  -h, --help     도움말 출력")
        print("\n타임스탬프는 마이크로초 단위로 추출/출력됩니다.")
        sys.exit(0)
    
    if len(sys.argv) >= 2 and not sys.argv[1].startswith('-'):
        log_file = sys.argv[1]
        opt_start = 2
    else:
        log_file = default_log_file
        opt_start = 1
    
    ue_idx = 0  # 기본값: UE0만 추출
    csv_file = None
    use_global_time = True
    
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
    
    print(f"로그 파일 파싱 중: {log_file} (타임스탬프: 마이크로초 단위)")
    ue_data = parse_hol_delay_log(log_file)
    
    if not ue_data:
        print("추출된 데이터가 없습니다.")
        sys.exit(1)
    
    # 요약 정보 출력
    print_hol_delay_summary(ue_data)
    
    # 상세 정보 출력
    print_hol_delay_detailed(ue_data, ue_idx, use_global_time)
    
    # CSV 저장
    if csv_file:
        # 지정된 UE만 CSV 저장
        to_export = {ue_idx: ue_data[ue_idx]} if ue_idx in ue_data else ue_data
        export_to_csv(to_export, csv_file)

if __name__ == '__main__':
    main()
