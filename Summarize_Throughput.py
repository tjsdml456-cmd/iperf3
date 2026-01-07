#!/usr/bin/env python3
"""
UE별 Throughput 정보 추출 스크립트
로그 파일에서 각 UE의 throughput 정보를 추출합니다.
"""

import re
import sys
from collections import defaultdict
from typing import Dict, List
from datetime import datetime

def parse_throughput_log(log_file: str) -> Dict[int, List[Dict]]:
    """
    로그 파일에서 UE별 throughput 정보를 파싱합니다.
    
    Throughput calc 로그만 파싱 (시스템에서 계산된 정확한 값, 동적 period 사용)
    
    Args:
        log_file: 로그 파일 경로
        
    Returns:
        UE 인덱스를 키로 하고, throughput 정보 딕셔너리 리스트를 값으로 하는 딕셔너리
    """
    ue_data = defaultdict(list)
    
    # Throughput calc 로그 패턴 (DL + UL 모두 파싱)
    # 예: UE0 Throughput calc: sum_dl_tb_bytes=1000000, period=1000ms, dl_brate_kbps=8000.00 (=8.00Mbps), dl_nof_ok=100, ul_brate_kbps=5000.00 (=5.00Mbps), ul_nof_ok=50
    throughput_pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?'
        r'UE(\d+)\s+Throughput calc:\s+'
        r'sum_dl_tb_bytes=(\d+),\s+period=(\d+)ms,\s+'
        r'dl_brate_kbps=([\d.]+)\s+\(=([\d.]+)Mbps\),\s+dl_nof_ok=(\d+)'
        r'(?:,\s+ul_brate_kbps=([\d.]+)\s+\(=([\d.]+)Mbps\),\s+ul_nof_ok=(\d+))?'
    )
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                # Throughput calc 로그 파싱
                match = throughput_pattern.search(line)
                if match:
                    timestamp_str = match.group(1)
                    ue_idx = int(match.group(2))
                    try:
                        timestamp = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        timestamp = None
                    
                    # DL 정보
                    sum_dl_tb_bytes = int(match.group(3))
                    period_ms = int(match.group(4))
                    dl_brate_kbps = float(match.group(5))
                    dl_brate_mbps = float(match.group(6))
                    dl_nof_ok = int(match.group(7))
                    
                    # UL 정보 (있을 수도, 없을 수도 있음)
                    ul_brate_kbps = float(match.group(8)) if match.group(8) else 0.0
                    ul_brate_mbps = float(match.group(9)) if match.group(9) else 0.0
                    ul_nof_ok = int(match.group(10)) if match.group(10) else 0
                    
                    # Total (DL + UL) 계산
                    total_brate_kbps = dl_brate_kbps + ul_brate_kbps
                    total_brate_mbps = dl_brate_mbps + ul_brate_mbps
                    
                    entry = {
                        'line': line_num,
                        'timestamp': timestamp,
                        'timestamp_str': timestamp_str,
                        'type': 'calculated',
                        'sum_dl_tb_bytes': sum_dl_tb_bytes,
                        'period_ms': period_ms,
                        'dl_brate_kbps': dl_brate_kbps,
                        'dl_brate_mbps': dl_brate_mbps,
                        'dl_nof_ok': dl_nof_ok,
                        'ul_brate_kbps': ul_brate_kbps,
                        'ul_brate_mbps': ul_brate_mbps,
                        'ul_nof_ok': ul_nof_ok,
                        'total_brate_kbps': total_brate_kbps,
                        'total_brate_mbps': total_brate_mbps,
                        'raw_line': line.strip()
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

def get_global_first_timestamp(ue_data: Dict[int, List[Dict]]) -> datetime:
    """모든 UE의 레코드 중 가장 이른 타임스탬프를 찾습니다."""
    global_first = None
    for ue_idx, entries in ue_data.items():
        for entry in entries:
            if entry['timestamp'] is not None:
                if global_first is None or entry['timestamp'] < global_first:
                    global_first = entry['timestamp']
    return global_first

def calculate_throughput_from_tbs(ue_data: Dict[int, List[Dict]], time_window_ms: int = 1000) -> Dict[int, List[Dict]]:
    """
    HARQ ACK 로그로부터 정확한 throughput을 계산합니다.
    성공한 전송(ACK=1)만 누적하여 계산합니다.
    
    Args:
        ue_data: HARQ ACK 로그 데이터
        time_window_ms: Throughput 계산 시간 윈도우 (밀리초)
    
    Returns:
        계산된 throughput 정보를 추가한 데이터
    """
    for ue_idx, entries in ue_data.items():
        # HARQ ACK 로그만 필터링 (성공한 전송만 이미 필터링됨)
        harq_ack_entries = [e for e in entries if e['type'] == 'harq_ack_dl']
        
        if not harq_ack_entries:
            continue
        
        # 타임스탬프 기준으로 정렬
        harq_entries_sorted = sorted(
            harq_ack_entries,
            key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max
        )
        
        # 시간 윈도우를 기반으로 throughput 계산
        calculated_throughputs = []
        
        for i, entry in enumerate(harq_entries_sorted):
            if entry['timestamp'] is None:
                continue
            
            window_start = entry['timestamp']
            window_end = window_start + timedelta(milliseconds=time_window_ms)
            
            # 윈도우 내의 성공한 TBS 합계 계산
            total_bytes = 0
            count = 0
            
            for harq_entry in harq_entries_sorted[i:]:
                if harq_entry['timestamp'] is None:
                    continue
                if harq_entry['timestamp'] > window_end:
                    break
                # 이미 성공한 전송만 저장되어 있음
                total_bytes += harq_entry['tbs_bytes']
                count += 1
            
            # Throughput 계산: (bytes * 8) / time_window_ms = kbps
            throughput_kbps = (total_bytes * 8.0) / time_window_ms
            throughput_mbps = throughput_kbps / 1000.0
            
            calculated_throughputs.append({
                'timestamp': entry['timestamp'],
                'calculated_throughput_kbps': throughput_kbps,
                'calculated_throughput_mbps': throughput_mbps,
                'window_bytes': total_bytes,
                'window_count': count,
                'window_start': window_start,
                'window_end': window_end
            })
        
        # 계산된 throughput을 데이터에 추가
        for calc in calculated_throughputs:
            ue_data[ue_idx].append({
                'line': 0,
                'timestamp': calc['timestamp'],
                'timestamp_str': calc['timestamp'].isoformat() if calc['timestamp'] else '',
                'type': 'calculated_from_harq',
                'dl_brate_kbps': calc['calculated_throughput_kbps'],
                'dl_brate_mbps': calc['calculated_throughput_mbps'],
                'sum_dl_tb_bytes': calc['window_bytes'],
                'period_ms': time_window_ms,
                'dl_nof_ok': calc['window_count'],
                'total_brate_kbps': calc['calculated_throughput_kbps'],
                'total_brate_mbps': calc['calculated_throughput_mbps'],
                'ul_brate_kbps': 0.0,
                'ul_brate_mbps': 0.0,
                'ul_nof_ok': 0
            })
    
    return ue_data

def calculate_throughput_from_tbs(ue_data: Dict[int, List[Dict]], time_window_ms: int = 1000) -> Dict[int, List[Dict]]:
    """
    TBS 로그로부터 throughput을 계산합니다.
    
    Args:
        ue_data: TBS 로그 데이터
        time_window_ms: Throughput 계산 시간 윈도우 (밀리초)
    
    Returns:
        계산된 throughput 정보를 추가한 데이터
    """
    
    for ue_idx, entries in ue_data.items():
        # TBS 로그만 필터링
        tbs_entries = [e for e in entries if e['type'].startswith('tbs_')]
        calculated_entries = [e for e in entries if e['type'] == 'calculated']
        
        if not tbs_entries:
            continue
        
        # 타임스탬프 기준으로 정렬
        tbs_entries_sorted = sorted(
            tbs_entries,
            key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max
        )
        
        # 시간 윈도우를 기반으로 throughput 계산
        for i, entry in enumerate(tbs_entries_sorted):
            if entry['timestamp'] is None:
                continue
            
            window_start = entry['timestamp']
            window_end = window_start + timedelta(milliseconds=time_window_ms)
            
            # 윈도우 내의 TBS 합계 계산
            total_bytes = 0
            count = 0
            
            for tbs_entry in tbs_entries_sorted[i:]:
                if tbs_entry['timestamp'] is None:
                    continue
                if tbs_entry['timestamp'] > window_end:
                    break
                if tbs_entry['direction'] == 'DL':  # DL만 계산 (또는 UL만)
                    total_bytes += tbs_entry['tbs_bytes']
                    count += 1
            
            # Throughput 계산: (bytes * 8) / time_window_ms = kbps
            throughput_kbps = (total_bytes * 8.0) / time_window_ms
            throughput_mbps = throughput_kbps / 1000.0
            
            entry['calculated_throughput_kbps'] = throughput_kbps
            entry['calculated_throughput_mbps'] = throughput_mbps
            entry['window_bytes'] = total_bytes
            entry['window_count'] = count
    
    return ue_data

def print_throughput_summary(ue_data: Dict[int, List[Dict]]):
    """UE별 throughput 요약 정보를 출력합니다."""
    print("=" * 100)
    print("UE별 Throughput 정보 요약")
    print("=" * 100)
    
    for ue_idx in sorted(ue_data.keys()):
        entries = ue_data[ue_idx]
        if not entries:
            continue
        
        calculated_entries = [e for e in entries if e['type'] == 'calculated']
        
        print(f"\n[UE{ue_idx}]")
        print("-" * 100)
        
        if calculated_entries:
            dl_throughputs = [e['dl_brate_mbps'] for e in calculated_entries]
            ul_throughputs = [e['ul_brate_mbps'] for e in calculated_entries if e['ul_brate_mbps'] > 0]
            total_throughputs = [e['total_brate_mbps'] for e in calculated_entries]
            
            print(f"  계산된 Throughput (시스템 계산값, 동적 period):")
            print(f"    DL Throughput:")
            print(f"      - 최소값: {min(dl_throughputs):.2f} Mbps")
            print(f"      - 최대값: {max(dl_throughputs):.2f} Mbps")
            print(f"      - 평균값: {sum(dl_throughputs) / len(dl_throughputs):.2f} Mbps")
            if ul_throughputs:
                print(f"    UL Throughput:")
                print(f"      - 최소값: {min(ul_throughputs):.2f} Mbps")
                print(f"      - 최대값: {max(ul_throughputs):.2f} Mbps")
                print(f"      - 평균값: {sum(ul_throughputs) / len(ul_throughputs):.2f} Mbps")
            print(f"    Total (DL+UL) Throughput:")
            print(f"      - 최소값: {min(total_throughputs):.2f} Mbps")
            print(f"      - 최대값: {max(total_throughputs):.2f} Mbps")
            print(f"      - 평균값: {sum(total_throughputs) / len(total_throughputs):.2f} Mbps")
            print(f"    - 레코드 수: {len(calculated_entries)}")

def print_throughput_detailed(ue_data: Dict[int, List[Dict]], ue_idx: int = None, use_global_time: bool = True):
    """특정 UE의 상세 throughput 정보를 출력합니다."""
    if ue_idx is not None:
        ues_to_print = [ue_idx] if ue_idx in ue_data else []
    else:
        ues_to_print = sorted(ue_data.keys())
    
    # 공통 기준 시간 계산
    global_first_timestamp = None
    if use_global_time:
        global_first_timestamp = get_global_first_timestamp(ue_data)
        if global_first_timestamp:
            print(f"\n{'=' * 100}")
            print(f"[공통 기준 시간] {global_first_timestamp.isoformat()}")
            print(f"{'=' * 100}")
    
    for ue in ues_to_print:
        entries = ue_data[ue]
        if not entries:
            continue
        
        entries_sorted = sorted(entries, key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max)
        
        # 기준 시간 선택
        if use_global_time and global_first_timestamp is not None:
            first_timestamp = global_first_timestamp
            time_label = "공통 기준 시간"
        else:
            first_timestamp = None
            for entry in entries_sorted:
                if entry['timestamp'] is not None:
                    first_timestamp = entry['timestamp']
                    break
            time_label = "UE별 기준 시간"
        
        if first_timestamp is None:
            print(f"\n[경고] UE{ue}: 유효한 타임스탬프가 없습니다.")
            continue
        
        # Throughput calc 로그만 필터링
        calculated_entries = [e for e in entries_sorted if e['type'] == 'calculated']
        
        if not calculated_entries:
            print(f"\n[경고] UE{ue}: Throughput calc 로그가 없습니다.")
            continue
        
        print(f"\n{'=' * 100}")
        print(f"UE{ue} Throughput 상세 정보 (시스템 계산값, 동적 period)")
        print(f"전체 {len(calculated_entries)}개 | {time_label}: {first_timestamp.isoformat()}")
        print(f"{'=' * 100}")
        print(f"{'시간(분:초)':<15} {'DL (Mbps)':<12} {'UL (Mbps)':<12} {'Total (Mbps)':<15} {'Period (ms)':<12} {'DL Bytes':<12} {'HARQ OK':<10}")
        print("-" * 100)
        
        for entry in calculated_entries:
            if entry['timestamp'] is not None:
                minutes = entry['timestamp'].minute
                seconds = entry['timestamp'].second + entry['timestamp'].microsecond / 1000000.0
                abs_time_str = f"{minutes:02d}:{seconds:05.2f}"
            else:
                abs_time_str = "N/A"
            
            ul_display = f"{entry['ul_brate_mbps']:.2f}" if entry['ul_brate_mbps'] > 0 else "N/A"
            
            print(f"{abs_time_str:<15} "
                  f"{entry['dl_brate_mbps']:<12.2f} "
                  f"{ul_display:<12} "
                  f"{entry['total_brate_mbps']:<15.2f} "
                  f"{entry['period_ms']:<12} "
                  f"{entry['sum_dl_tb_bytes']:<12} "
                  f"{entry['dl_nof_ok']:<10}")
        
        for entry in calculated_entries:
            if entry['timestamp'] is not None:
                minutes = entry['timestamp'].minute
                seconds = entry['timestamp'].second + entry['timestamp'].microsecond / 1000000.0
                abs_time_str = f"{minutes:02d}:{seconds:05.2f}"
            else:
                abs_time_str = "N/A"
            
            ul_display = f"{entry['ul_brate_mbps']:.2f}" if entry['ul_brate_mbps'] > 0 else "N/A"
            
            print(f"{abs_time_str:<15} "
                  f"{entry['dl_brate_mbps']:<12.2f} "
                  f"{ul_display:<12} "
                  f"{entry['total_brate_mbps']:<15.2f} "
                  f"{entry['period_ms']:<12} "
                  f"{entry['sum_dl_tb_bytes']:<12} "
                  f"{entry['dl_nof_ok']:<10}")

def main():
    default_log_file = 'gnb.log'
    
    if len(sys.argv) >= 2 and sys.argv[1] in ['-h', '--help']:
        print("Usage: python extract_ue_throughput.py [log_file] [options]")
        print(f"\nArguments:")
        print(f"  log_file       로그 파일 경로 (기본값: {default_log_file})")
        print("\nOptions:")
        print("  -u <ue_idx>    특정 UE만 출력 (예: -u 0)")
        print("  -g, --global   모든 UE를 공통 기준 시간으로 정렬 (기본값)")
        print("  -h, --help     도움말 출력")
        sys.exit(0)
    
    if len(sys.argv) >= 2 and not sys.argv[1].startswith('-'):
        log_file = sys.argv[1]
        opt_start = 2
    else:
        log_file = default_log_file
        opt_start = 1
    
    ue_idx = None
    use_global_time = True
    
    i = opt_start
    while i < len(sys.argv):
        if sys.argv[i] == '-u' and i + 1 < len(sys.argv):
            ue_idx = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] in ['-g', '--global']:
            use_global_time = True
            i += 1
        else:
            print(f"Warning: 알 수 없는 옵션 '{sys.argv[i]}' (무시됨)")
            i += 1
    
    print(f"로그 파일 파싱 중: {log_file}")
    ue_data = parse_throughput_log(log_file)
    
    if not ue_data:
        print("추출된 데이터가 없습니다.")
        sys.exit(1)
    
    # Throughput calc 로그 확인
    has_calculated = any(
        any(e['type'] == 'calculated' for e in entries)
        for entries in ue_data.values()
    )
    
    if not has_calculated:
        print("\n[경고] Throughput calc 로그가 없습니다.")
        print("  시스템에서 계산된 throughput 정보가 로그에 포함되어야 합니다.")
    
    # 요약 정보 출력
    print_throughput_summary(ue_data)
    
    # 상세 정보 출력
    print_throughput_detailed(ue_data, ue_idx, use_global_time)

if __name__ == '__main__':
    main()

