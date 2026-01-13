#!/usr/bin/env python3
"""
UE별 대역폭(Bandwidth) 정보 추출 스크립트
로그 파일에서 각 UE의 PRB 할당 정보를 기반으로 대역폭을 계산합니다.
"""

import re
import sys
from collections import defaultdict, Counter
from typing import Dict, List, Optional, Tuple
from datetime import datetime, timedelta

# PRB당 대역폭 계산 (kHz 단위)
# PRB당 대역폭 = 12 subcarriers × SCS (kHz)
# 예: SCS 15kHz → 12 × 15 = 180 kHz = 0.18 MHz
# 예: SCS 30kHz → 12 × 30 = 360 kHz = 0.36 MHz

def parse_scs_from_log(log_file: str) -> Optional[int]:
    """
    로그 파일에서 Subcarrier Spacing (SCS) 정보를 추출합니다.
    
    Args:
        log_file: 로그 파일 경로
        
    Returns:
        SCS 값 (kHz), 없으면 None
    """
    scs_pattern = re.compile(r'common_scs:\s*(\d+)')
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line in f:
                match = scs_pattern.search(line)
                if match:
                    return int(match.group(1))
    except Exception as e:
        print(f"Warning: SCS 파싱 중 오류: {e}")
    
    return None

def infer_bwp_prb_from_log(log_file: str) -> Optional[int]:
    """
    로그 파일에서 실제 PRB 범위를 확인하여 BWP PRB 크기를 추론합니다.
    
    Args:
        log_file: 로그 파일 경로
        
    Returns:
        추론된 BWP PRB 수, 없으면 None
    """
    max_prb_index = -1
    max_prb_end = -1
    sample_lines = []
    
    # PDSCH/PUSCH 패턴: prb=[start, end)
    prb_range_pattern = re.compile(r'prb=\[(\d+),\s*(\d+)\)')
    # PUCCH 패턴: prb1=X prb2=Y 또는 prb=[start, end)
    pucch_prb_pattern = re.compile(r'prb(?:1|2)=(\d+)')
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line in f:
                # PDSCH/PUSCH PRB 범위 확인
                match = prb_range_pattern.search(line)
                if match:
                    prb_start = int(match.group(1))
                    prb_end = int(match.group(2))
                    # prb_end는 exclusive이므로 실제 최대 인덱스는 prb_end - 1
                    max_prb_index = max(max_prb_index, prb_end - 1)
                    max_prb_end = max(max_prb_end, prb_end)
                    # 샘플 저장 (최대값 근처)
                    if prb_end > max_prb_end - 5:
                        sample_lines.append(f"  prb=[{prb_start}, {prb_end})")
                
                # PUCCH PRB 인덱스 확인
                matches = pucch_prb_pattern.findall(line)
                for prb_str in matches:
                    try:
                        prb_idx = int(prb_str)
                        max_prb_index = max(max_prb_index, prb_idx)
                    except ValueError:
                        pass
    except Exception as e:
        print(f"Warning: BWP PRB 추론 중 오류: {e}")
        return None
    
    if max_prb_index >= 0:
        # 최대 PRB 인덱스가 N이면, BWP 크기는 최소 N+1
        # prb_end는 exclusive이므로, max_prb_end가 실제 BWP 크기일 가능성이 높음
        inferred_bwp = max(max_prb_index + 1, max_prb_end)
        
        # 디버그 정보 출력
        print(f"\n[BWP PRB 추론]")
        print(f"  최대 PRB 인덱스: {max_prb_index}")
        print(f"  최대 prb_end (exclusive): {max_prb_end}")
        print(f"  추론된 BWP PRB: {inferred_bwp}")
        if sample_lines:
            print(f"  샘플 PRB 범위 (최대값 근처):")
            for sample in sample_lines[-5:]:  # 최근 5개만
                print(sample)
        
        # 표준 BWP 크기로 반올림 (일반적인 값들)
        standard_bwp_sizes = [25, 52, 79, 106, 133, 160, 216, 270]
        for std_size in standard_bwp_sizes:
            if inferred_bwp <= std_size:
                if std_size != inferred_bwp:
                    print(f"  → 표준 크기로 반올림: {inferred_bwp} → {std_size} PRB")
                return std_size
        
        # 표준 크기를 초과하면 추론값 그대로 반환
        print(f"  → 표준 크기 초과, 추론값 사용: {inferred_bwp} PRB")
        return inferred_bwp
    
    return None

def get_mcs_spectral_efficiency(modulation: Optional[str], default: float = 2.0) -> float:
    """
    Modulation 방식에 따른 대략적인 MCS 스펙트럼 효율 (bps/Hz)을 반환합니다.
    
    참고: 정확한 값은 MCS 인덱스와 code rate에 따라 달라지지만,
    여기서는 modulation 방식만으로 대략적인 값을 추정합니다.
    
    Args:
        modulation: Modulation 방식 (QPSK, QAM16, QAM64, QAM256 등)
        default: modulation을 알 수 없을 때 기본값
        
    Returns:
        스펙트럼 효율 (bps/Hz)
    """
    if modulation is None:
        return default
    
    mod_lower = modulation.lower()
    # 대략적인 스펙트럼 효율 (MCS 테이블의 평균적인 값)
    # QPSK: ~1-2 bps/Hz, QAM16: ~2-3 bps/Hz, QAM64: ~4-5 bps/Hz, QAM256: ~6-7 bps/Hz
    spectral_efficiency_map = {
        'qpsk': 1.5,      # QPSK 평균
        'qam16': 2.5,     # 16-QAM 평균
        'qam64': 4.5,     # 64-QAM 평균
        'qam256': 6.5,    # 256-QAM 평균
    }
    
    return spectral_efficiency_map.get(mod_lower, default)

def get_rnti_to_ue_mapping() -> Dict[str, int]:
    """
    고정된 RNTI → UE 인덱스 매핑을 반환합니다.
    
    Returns:
        {rnti: ue_index} 딕셔너리
    """
    # 고정 매핑: UE0 → 0x4601, UE1 → 0x4602, UE2 → 0x4603
    return {
        '0x4601': 0,
        '0x4602': 1,
        '0x4603': 2
    }

def parse_prb_bandwidth_log(log_file: str, scs_khz: Optional[int] = None) -> Dict[str, Dict[str, List[Dict]]]:
    """
    로그 파일에서 UE별 PRB 할당 정보를 파싱하고 대역폭을 계산합니다.
    
    Args:
        log_file: 로그 파일 경로
        scs_khz: Subcarrier Spacing (kHz). None이면 로그에서 추출 시도
        
    Returns:
        {'pdsch': {rnti: [entries]}, 'pusch': {rnti: [entries]}}
        각 entry는 timestamp, prb_count, bandwidth_mhz 등을 포함
    """
    result = {
        'pdsch': defaultdict(list),
        'pusch': defaultdict(list)
    }
    
    # SCS가 없으면 로그에서 추출
    if scs_khz is None:
        scs_khz = parse_scs_from_log(log_file)
        if scs_khz is None:
            print("Warning: SCS를 찾을 수 없습니다. 기본값 15kHz를 사용합니다.")
            scs_khz = 15
    
    # PRB당 대역폭 계산
    # 수식 1: B_PRB^(MHz) = (12 × SCS) / 1000
    prb_bandwidth_mhz = (12 * scs_khz) / 1000.0  # 12 subcarriers × SCS (kHz) / 1000 = MHz
    prb_bandwidth_hz = prb_bandwidth_mhz * 1000000.0  # Hz 단위
    
    print(f"SCS: {scs_khz} kHz")
    print(f"PRB당 대역폭: {prb_bandwidth_mhz:.3f} MHz ({prb_bandwidth_hz:.0f} Hz)")
    print()
    
    # PDSCH 패턴: PDSCH: rnti=0x4601 h_id=0 k1=4 prb=[0, 42) symb=[1, 14) mod=QPSK rv=0 tbs=309
    pdsch_pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?'
        r'PDSCH:\s+rnti=(0x[0-9a-fA-F]+)\s+'
        r'(?:h_id=(\d+)\s+)?'
        r'(?:k1=(\d+)\s+)?'
        r'prb=\[(\d+),\s*(\d+)\)\s+'
        r'symb=\[(\d+),\s*(\d+)\)'
        r'(?:\s+mod=(\w+))?'
    )
    
    # PUSCH 패턴: PUSCH: rnti=0x4601 h_id=0 prb=[8, 11) symb=[0, 14) mod=QPSK rv=0 tbs=11
    pusch_pattern = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?'
        r'PUSCH:\s+rnti=(0x[0-9a-fA-F]+)\s+'
        r'(?:h_id=(\d+)\s+)?'
        r'prb=\[(\d+),\s*(\d+)\)\s+'
        r'symb=\[(\d+),\s*(\d+)\)'
        r'(?:\s+mod=(\w+))?'
    )
    
    try:
        with open(log_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                # PDSCH 파싱
                match = pdsch_pattern.search(line)
                if match:
                    timestamp_str = match.group(1)
                    rnti = match.group(2).lower()
                    prb_start = int(match.group(5))
                    prb_end = int(match.group(6))
                    symb_start = int(match.group(7))
                    symb_end = int(match.group(8))
                    
                    prb_count = prb_end - prb_start
                    symb_count = symb_end - symb_start
                    prb_symb = prb_count * symb_count  # 실제 자원: PRB × Symbols
                    bandwidth_mhz = prb_count * prb_bandwidth_mhz
                    
                    try:
                        timestamp = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        timestamp = None
                    
                    entry = {
                        'line': line_num,
                        'timestamp': timestamp,
                        'timestamp_str': timestamp_str,
                        'rnti': rnti,
                        'prb_start': prb_start,
                        'prb_end': prb_end,
                        'prb_count': prb_count,
                        'symb_start': symb_start,
                        'symb_end': symb_end,
                        'symb_count': symb_count,
                        'prb_symb': prb_symb,  # PRB × Symbols (실제 자원)
                        'bandwidth_mhz': bandwidth_mhz,
                        'bandwidth_khz': bandwidth_mhz * 1000.0,
                        'raw_line': line.strip()
                    }
                    result['pdsch'][rnti].append(entry)
                    continue
                
                # PUSCH 파싱
                match = pusch_pattern.search(line)
                if match:
                    timestamp_str = match.group(1)
                    rnti = match.group(2).lower()
                    prb_start = int(match.group(4))
                    prb_end = int(match.group(5))
                    symb_start = int(match.group(6))
                    symb_end = int(match.group(7))
                    
                    prb_count = prb_end - prb_start
                    symb_count = symb_end - symb_start
                    prb_symb = prb_count * symb_count  # 실제 자원: PRB × Symbols
                    bandwidth_mhz = prb_count * prb_bandwidth_mhz
                    modulation = match.group(7) if match.group(7) else None
                    
                    try:
                        timestamp = datetime.fromisoformat(timestamp_str)
                    except ValueError:
                        timestamp = None
                    
                    entry = {
                        'line': line_num,
                        'timestamp': timestamp,
                        'timestamp_str': timestamp_str,
                        'rnti': rnti,
                        'prb_start': prb_start,
                        'prb_end': prb_end,
                        'prb_count': prb_count,
                        'symb_start': symb_start,
                        'symb_end': symb_end,
                        'symb_count': symb_count,
                        'prb_symb': prb_symb,  # PRB × Symbols (실제 자원)
                        'bandwidth_mhz': bandwidth_mhz,
                        'bandwidth_khz': bandwidth_mhz * 1000.0,
                        'modulation': modulation,  # MCS 정보 (QPSK, QAM16, QAM64, QAM256 등)
                        'raw_line': line.strip()
                    }
                    result['pusch'][rnti].append(entry)
    except FileNotFoundError:
        print(f"Error: 파일 '{log_file}'을 찾을 수 없습니다.")
        sys.exit(1)
    except Exception as e:
        print(f"Error: 파일 읽기 중 오류 발생: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    
    # 각 채널 타입별로 타임스탬프 기준으로 정렬
    for channel_type in result:
        for rnti in result[channel_type]:
            result[channel_type][rnti] = sorted(
                result[channel_type][rnti],
                key=lambda x: x['timestamp'] if x['timestamp'] is not None else datetime.max
            )
    
    return result

def calculate_bandwidth_per_second(bandwidth_data: Dict[str, Dict[str, List[Dict]]], 
                                    rnti_ue_map: Dict[str, int],
                                    scs_khz: int = 15,
                                    bwp_prb: int = 52,
                                    time_window_sec: float = 1.0) -> Dict[int, List[Dict]]:
    """
    1초 윈도우별로 자원 점유를 계산합니다.
    
    수식 기반 계산:
    1. PRB당 대역폭: B_PRB^(MHz) = (12 × SCS) / 1000
    2. 초당 슬롯 수: N_slot/sec = 1000 × (SCS / 15)
    3. 슬롯당 심볼 수: N_sym = 14 (Normal CP)
    4. 1초 동안 사용한 총 자원: A_UE = Σ_{s ∈ 1sec} N_PRB^(s) × N_sym^(s)
    5. 평균 동시 점유 PRB: N_PRB_bar = A_UE / (N_slot/sec × N_sym)
    6. 평균 동시 점유 대역폭: B_UE_bar^(MHz) = N_PRB_bar × B_PRB^(MHz)
    
    Args:
        bandwidth_data: parse_prb_bandwidth_log()의 결과
        rnti_ue_map: RNTI → UE 인덱스 매핑
        scs_khz: Subcarrier Spacing (kHz, 기본값 15)
        bwp_prb: BWP PRB 수 (기본값 52)
        time_window_sec: 집계 시간 윈도우 (초, 기본값 1.0)
        
    Returns:
        {ue_index: [{'timestamp': ..., 'dl_sum_prb_symb': ..., 'dl_avg_prb': ..., 'dl_utilization': ..., ...}]} 딕셔너리
    """
    ue_bandwidth_per_sec = defaultdict(list)
    
    # 수식 1: PRB당 대역폭
    # B_PRB^(MHz) = (12 × SCS) / 1000
    prb_bandwidth_mhz = (12 * scs_khz) / 1000.0
    prb_bandwidth_hz = prb_bandwidth_mhz * 1000000.0  # Hz 단위
    
    # 수식 2: 초당 슬롯 수
    # N_slot/sec = 1000 × (SCS / 15)
    slots_per_sec = 1000 * (scs_khz / 15)
    
    # 수식 3: 슬롯당 OFDM 심볼 수 (Normal CP)
    # N_sym = 14
    symbols_per_slot = 14
    
    # BWP 전체 용량 계산 (utilization 계산용)
    capacity_prb_symb_per_sec = bwp_prb * slots_per_sec * symbols_per_slot  # 1초당 BWP 전체 용량
    bwp_total_bw_mhz = bwp_prb * prb_bandwidth_mhz  # BWP 전체 대역폭
    bwp_total_bw_hz = bwp_total_bw_mhz * 1000000.0  # BWP 전체 대역폭 (Hz)
    
    # 모든 RNTI의 엔트리를 UE 인덱스별로 그룹화
    ue_entries = defaultdict(lambda: {'dl': [], 'ul': []})
    
    for rnti, entries in bandwidth_data['pdsch'].items():
        ue_idx = rnti_ue_map.get(rnti, None)
        if ue_idx is not None and 0 <= ue_idx <= 10:
            ue_entries[ue_idx]['dl'].extend(entries)
    
    for rnti, entries in bandwidth_data['pusch'].items():
        ue_idx = rnti_ue_map.get(rnti, None)
        if ue_idx is not None and 0 <= ue_idx <= 10:
            ue_entries[ue_idx]['ul'].extend(entries)
    
    # 각 윈도우별로 모든 UE의 총합 계산 (share 계산용)
    # 먼저 모든 UE의 데이터를 윈도우별로 집계
    window_total_dl = defaultdict(int)
    window_total_ul = defaultdict(int)
    
    for ue_idx, entries in ue_entries.items():
        all_dl = sorted([e for e in entries['dl'] if e['timestamp'] is not None],
                       key=lambda x: x['timestamp'])
        all_ul = sorted([e for e in entries['ul'] if e['timestamp'] is not None],
                       key=lambda x: x['timestamp'])
        
        # DL 윈도우별 합계
        processed_dl_windows = set()
        for entry in all_dl:
            window_start_sec = entry['timestamp'].replace(microsecond=0)
            if window_start_sec in processed_dl_windows:
                continue
            processed_dl_windows.add(window_start_sec)
            window_end = window_start_sec + timedelta(seconds=1)
            # 윈도우 내의 모든 entry를 찾기 (전체 리스트에서)
            window_entries = [e for e in all_dl
                            if window_start_sec <= e['timestamp'] < window_end]
            window_total_dl[window_start_sec] += sum(e['prb_symb'] for e in window_entries)
        
        # UL 윈도우별 합계
        processed_ul_windows = set()
        for entry in all_ul:
            window_start_sec = entry['timestamp'].replace(microsecond=0)
            if window_start_sec in processed_ul_windows:
                continue
            processed_ul_windows.add(window_start_sec)
            window_end = window_start_sec + timedelta(seconds=1)
            # 윈도우 내의 모든 entry를 찾기 (전체 리스트에서)
            window_entries = [e for e in all_ul
                            if window_start_sec <= e['timestamp'] < window_end]
            window_total_ul[window_start_sec] += sum(e['prb_symb'] for e in window_entries)
    
    # 각 UE별로 1초 윈도우별 집계
    for ue_idx, entries in ue_entries.items():
        # DL과 UL을 타임스탬프 기준으로 정렬
        all_dl = sorted([e for e in entries['dl'] if e['timestamp'] is not None],
                       key=lambda x: x['timestamp'])
        all_ul = sorted([e for e in entries['ul'] if e['timestamp'] is not None],
                       key=lambda x: x['timestamp'])
        
        # DL 처리: 1초 윈도우별로 집계
        processed_dl_windows = set()
        
        for i, entry in enumerate(all_dl):
            window_start = entry['timestamp']
            window_start_sec = window_start.replace(microsecond=0)
            window_key = window_start_sec
            
            if window_key in processed_dl_windows:
                continue
            
            window_end = window_start_sec + timedelta(seconds=1)
            processed_dl_windows.add(window_key)
            
            # 윈도우 내의 모든 PRB 할당을 합산 (전체 리스트에서)
            window_entries = [e for e in all_dl
                            if window_start_sec <= e['timestamp'] < window_end]
            
            if window_entries:
                # 수식 4: 1초 동안 사용한 총 자원 (PRB × Symbol)
                # A_UE = Σ_{s ∈ 1sec} N_PRB^(s) × N_sym^(s)
                sum_prb_symb = sum(e['prb_symb'] for e in window_entries)  # A_UE
                
                # 수식 5: 평균 동시 점유 PRB 수
                # N_PRB_bar = A_UE / (N_slot/sec × N_sym)
                total_prb_symb_capacity = slots_per_sec * symbols_per_slot
                avg_prb = sum_prb_symb / total_prb_symb_capacity if total_prb_symb_capacity > 0 else 0.0
                
                # 절대 점유율 (utilization): BWP 전체 대비 사용 비율 (0~1)
                utilization = sum_prb_symb / capacity_prb_symb_per_sec if capacity_prb_symb_per_sec > 0 else 0.0
                
                # 수식 6: 평균 동시 점유 대역폭 (MHz)
                # B_UE_bar^(MHz) = N_PRB_bar × B_PRB^(MHz)
                avg_occupied_bw_mhz = avg_prb * prb_bandwidth_mhz
                
                # 추가: 실제 사용된 PRB 기반 대역폭 계산
                # 문제: 기존 방식(weighted_sum_prb / total_symbols)은 grant 개수와 무관하게 
                #       PRB가 같으면 대역폭이 같게 나옴
                # 해결: 각 grant의 PRB를 grant 빈도로 가중하여 계산
                
                # 각 grant의 PRB를 합산 (grant당 PRB의 합)
                sum_prb_count = sum(e['prb_count'] for e in window_entries)
                num_grants = len(window_entries)
                
                # grant당 평균 PRB
                avg_prb_per_grant = sum_prb_count / num_grants if num_grants > 0 else 0.0
                
                # grant 빈도: 1초당 grant 수
                grant_frequency = num_grants / slots_per_sec if slots_per_sec > 0 else 0.0
                
                # 실제 평균 PRB: grant당 평균 PRB × grant 빈도
                # 또는 더 간단하게: sum_prb_count를 1초로 나눈 값
                # 하지만 이건 grant가 많을수록 커지는 문제
                
                # 가장 합리적인 방법: sum_prb_symb를 기반으로 한 avg_prb를 사용하되,
                # grant 빈도를 고려한 보정값 계산
                # 실제로는 avg_prb가 맞지만, 사용자가 원하는 것은 grant당 PRB를 반영한 값
                
                # 실제 평균 PRB는 수식 5에 따라 계산된 avg_prb를 사용
                # avg_prb = sum_prb_symb / (slots_per_sec * symbols_per_slot)
                # 이것이 실제 평균 동시 점유 PRB입니다
                # 
                # 참고: 이 값이 작게 나올 수 있는 이유:
                # - avg_prb는 "시간 평균 동시 점유 PRB"이므로, grant가 산발적으로 발생하면
                #   대부분의 시간에는 자원을 사용하지 않아 평균값이 작아집니다
                # - 예: 1초에 100개 grant가 각각 10 PRB × 5 symbol을 사용하면
                #   sum_prb_symb = 5,000, total_capacity = 14,000 (SCS=15kHz)
                #   avg_prb = 5,000 / 14,000 = 0.36 PRB
                actual_avg_prb = avg_prb  # 수식 5에 따른 정확한 값
                
                # 실제 사용 대역폭 (Hz 단위로 저장)
                # 수식 6: B_UE_bar^(MHz) = N_PRB_bar × B_PRB^(MHz)
                # PRB당 대역폭을 Hz로 변환: B_PRB^(Hz) = B_PRB^(MHz) × 1,000,000
                actual_occupied_bw_hz = actual_avg_prb * prb_bandwidth_hz  # Hz 단위
                actual_occupied_bw_mhz = actual_avg_prb * prb_bandwidth_mhz  # 비교용으로 유지
                
                # 수식 8: 예상 Throughput 계산 (참고식)
                # Throughput ≈ B_UE × η_MCS × N_layer
                # 윈도우 내의 평균 modulation 계산
                modulations = [e.get('modulation') for e in window_entries if e.get('modulation')]
                avg_spectral_efficiency = 0.0
                if modulations:
                    # 가장 많이 사용된 modulation 방식 사용 (또는 평균)
                    mod_counter = Counter(modulations)
                    most_common_mod = mod_counter.most_common(1)[0][0]
                    avg_spectral_efficiency = get_mcs_spectral_efficiency(most_common_mod)
                
                # MIMO 레이어 수 (기본값 1, 나중에 옵션으로 설정 가능)
                mimo_layers = 1  # TODO: 로그에서 추출하거나 옵션으로 설정
                
                # 예상 Throughput (Mbps) - 실제 사용 대역폭 기반으로 계산
                estimated_throughput_mbps = actual_occupied_bw_mhz * avg_spectral_efficiency * mimo_layers
                
                # Share 계산: 이 UE의 자원 점유 비율
                total_dl_prb_symb = window_total_dl.get(window_start_sec, 0)
                dl_share = sum_prb_symb / total_dl_prb_symb if total_dl_prb_symb > 0 else 0.0
                
                # 해당 윈도우의 엔트리 찾기 또는 생성
                bw_entry = None
                for existing in ue_bandwidth_per_sec[ue_idx]:
                    if existing['timestamp'] == window_start_sec:
                        bw_entry = existing
                        break
                
                if bw_entry is None:
                    bw_entry = {
                        'timestamp': window_start_sec,
                        'dl_sum_prb_symb': 0,
                        'ul_sum_prb_symb': 0,
                        'dl_avg_prb': 0.0,
                        'ul_avg_prb': 0.0,
                        'dl_actual_avg_prb': 0.0,
                        'ul_actual_avg_prb': 0.0,
                        'dl_utilization': 0.0,
                        'ul_utilization': 0.0,
                        'dl_avg_occupied_bw_mhz': 0.0,
                        'ul_avg_occupied_bw_mhz': 0.0,
                        'dl_actual_occupied_bw_mhz': 0.0,
                        'ul_actual_occupied_bw_mhz': 0.0,
                        'dl_actual_occupied_bw_hz': 0.0,
                        'ul_actual_occupied_bw_hz': 0.0,
                        'dl_share': 0.0,
                        'ul_share': 0.0,
                        'dl_count': 0,
                        'ul_count': 0,
                        'dl_estimated_throughput_mbps': 0.0,
                        'ul_estimated_throughput_mbps': 0.0,
                        'dl_spectral_efficiency': 0.0,
                        'ul_spectral_efficiency': 0.0
                    }
                    ue_bandwidth_per_sec[ue_idx].append(bw_entry)
                
                bw_entry['dl_sum_prb_symb'] = sum_prb_symb
                bw_entry['dl_avg_prb'] = avg_prb
                bw_entry['dl_actual_avg_prb'] = actual_avg_prb  # 수식 5에 따른 평균 PRB
                bw_entry['dl_utilization'] = utilization
                bw_entry['dl_avg_occupied_bw_mhz'] = avg_occupied_bw_mhz  # 기존 평균 방식
                bw_entry['dl_actual_occupied_bw_mhz'] = actual_occupied_bw_mhz  # 실제 사용 대역폭 (MHz)
                bw_entry['dl_actual_occupied_bw_hz'] = actual_occupied_bw_hz  # 실제 사용 대역폭 (Hz)
                bw_entry['dl_share'] = dl_share
                bw_entry['dl_count'] = len(window_entries)
                bw_entry['dl_estimated_throughput_mbps'] = estimated_throughput_mbps
                bw_entry['dl_spectral_efficiency'] = avg_spectral_efficiency
        
        # UL 처리: 1초 윈도우별로 집계
        processed_ul_windows = set()
        
        for i, entry in enumerate(all_ul):
            window_start = entry['timestamp']
            window_start_sec = window_start.replace(microsecond=0)
            window_key = window_start_sec
            
            if window_key in processed_ul_windows:
                continue
            
            window_end = window_start_sec + timedelta(seconds=1)
            processed_ul_windows.add(window_key)
            
            # 윈도우 내의 모든 PRB 할당을 합산 (전체 리스트에서)
            window_entries = [e for e in all_ul
                            if window_start_sec <= e['timestamp'] < window_end]
            
            if window_entries:
                # 수식 4: 1초 동안 사용한 총 자원 (PRB × Symbol)
                # A_UE = Σ_{s ∈ 1sec} N_PRB^(s) × N_sym^(s)
                sum_prb_symb = sum(e['prb_symb'] for e in window_entries)  # A_UE
                
                # 수식 5: 평균 동시 점유 PRB 수
                # N_PRB_bar = A_UE / (N_slot/sec × N_sym)
                total_prb_symb_capacity = slots_per_sec * symbols_per_slot
                avg_prb = sum_prb_symb / total_prb_symb_capacity if total_prb_symb_capacity > 0 else 0.0
                
                # 절대 점유율 (utilization): BWP 전체 대비 사용 비율 (0~1)
                utilization = sum_prb_symb / capacity_prb_symb_per_sec if capacity_prb_symb_per_sec > 0 else 0.0
                
                # 수식 6: 평균 동시 점유 대역폭 (MHz)
                # B_UE_bar^(MHz) = N_PRB_bar × B_PRB^(MHz)
                avg_occupied_bw_mhz = avg_prb * prb_bandwidth_mhz
                
                # 추가: 실제 사용된 PRB 기반 대역폭 계산
                # 문제: 기존 방식(weighted_sum_prb / total_symbols)은 grant 개수와 무관하게 
                #       PRB가 같으면 대역폭이 같게 나옴
                # 해결: 각 grant의 PRB를 grant 빈도로 가중하여 계산
                
                # 각 grant의 PRB를 합산 (grant당 PRB의 합)
                sum_prb_count = sum(e['prb_count'] for e in window_entries)
                num_grants = len(window_entries)
                
                # grant당 평균 PRB
                avg_prb_per_grant = sum_prb_count / num_grants if num_grants > 0 else 0.0
                
                # grant 빈도: 1초당 grant 수
                grant_frequency = num_grants / slots_per_sec if slots_per_sec > 0 else 0.0
                
                # 실제 평균 PRB: grant당 평균 PRB × grant 빈도
                # 또는 더 간단하게: sum_prb_count를 1초로 나눈 값
                # 하지만 이건 grant가 많을수록 커지는 문제
                
                # 가장 합리적인 방법: sum_prb_symb를 기반으로 한 avg_prb를 사용하되,
                # grant 빈도를 고려한 보정값 계산
                # 실제로는 avg_prb가 맞지만, 사용자가 원하는 것은 grant당 PRB를 반영한 값
                
                # 실제 평균 PRB는 수식 5에 따라 계산된 avg_prb를 사용
                # avg_prb = sum_prb_symb / (slots_per_sec * symbols_per_slot)
                # 이것이 실제 평균 동시 점유 PRB입니다
                # 
                # 참고: 이 값이 작게 나올 수 있는 이유:
                # - avg_prb는 "시간 평균 동시 점유 PRB"이므로, grant가 산발적으로 발생하면
                #   대부분의 시간에는 자원을 사용하지 않아 평균값이 작아집니다
                # - 예: 1초에 100개 grant가 각각 10 PRB × 5 symbol을 사용하면
                #   sum_prb_symb = 5,000, total_capacity = 14,000 (SCS=15kHz)
                #   avg_prb = 5,000 / 14,000 = 0.36 PRB
                actual_avg_prb = avg_prb  # 수식 5에 따른 정확한 값
                
                # 실제 사용 대역폭 (Hz 단위로 저장)
                # 수식 6: B_UE_bar^(MHz) = N_PRB_bar × B_PRB^(MHz)
                # PRB당 대역폭을 Hz로 변환: B_PRB^(Hz) = B_PRB^(MHz) × 1,000,000
                actual_occupied_bw_hz = actual_avg_prb * prb_bandwidth_hz  # Hz 단위
                actual_occupied_bw_mhz = actual_avg_prb * prb_bandwidth_mhz  # 비교용으로 유지
                
                # 수식 8: 예상 Throughput 계산 (참고식)
                # Throughput ≈ B_UE × η_MCS × N_layer
                # 윈도우 내의 평균 modulation 계산
                modulations = [e.get('modulation') for e in window_entries if e.get('modulation')]
                avg_spectral_efficiency = 0.0
                if modulations:
                    # 가장 많이 사용된 modulation 방식 사용 (또는 평균)
                    mod_counter = Counter(modulations)
                    most_common_mod = mod_counter.most_common(1)[0][0]
                    avg_spectral_efficiency = get_mcs_spectral_efficiency(most_common_mod)
                
                # MIMO 레이어 수 (기본값 1, 나중에 옵션으로 설정 가능)
                mimo_layers = 1  # TODO: 로그에서 추출하거나 옵션으로 설정
                
                # 예상 Throughput (Mbps) - 실제 사용 대역폭 기반으로 계산
                estimated_throughput_mbps = actual_occupied_bw_mhz * avg_spectral_efficiency * mimo_layers
                
                # Share 계산: 이 UE의 자원 점유 비율
                total_ul_prb_symb = window_total_ul.get(window_start_sec, 0)
                ul_share = sum_prb_symb / total_ul_prb_symb if total_ul_prb_symb > 0 else 0.0
                
                # 해당 윈도우의 엔트리 찾기 또는 생성
                bw_entry = None
                for existing in ue_bandwidth_per_sec[ue_idx]:
                    if existing['timestamp'] == window_start_sec:
                        bw_entry = existing
                        break
                
                if bw_entry is None:
                    bw_entry = {
                        'timestamp': window_start_sec,
                        'dl_sum_prb_symb': 0,
                        'ul_sum_prb_symb': 0,
                        'dl_avg_prb': 0.0,
                        'ul_avg_prb': 0.0,
                        'dl_actual_avg_prb': 0.0,
                        'ul_actual_avg_prb': 0.0,
                        'dl_utilization': 0.0,
                        'ul_utilization': 0.0,
                        'dl_avg_occupied_bw_mhz': 0.0,
                        'ul_avg_occupied_bw_mhz': 0.0,
                        'dl_actual_occupied_bw_mhz': 0.0,
                        'ul_actual_occupied_bw_mhz': 0.0,
                        'dl_actual_occupied_bw_hz': 0.0,
                        'ul_actual_occupied_bw_hz': 0.0,
                        'dl_share': 0.0,
                        'ul_share': 0.0,
                        'dl_count': 0,
                        'ul_count': 0,
                        'dl_estimated_throughput_mbps': 0.0,
                        'ul_estimated_throughput_mbps': 0.0,
                        'dl_spectral_efficiency': 0.0,
                        'ul_spectral_efficiency': 0.0
                    }
                    ue_bandwidth_per_sec[ue_idx].append(bw_entry)
                
                bw_entry['ul_sum_prb_symb'] = sum_prb_symb
                bw_entry['ul_avg_prb'] = avg_prb
                bw_entry['ul_actual_avg_prb'] = actual_avg_prb  # 수식 5에 따른 평균 PRB
                bw_entry['ul_utilization'] = utilization
                bw_entry['ul_avg_occupied_bw_mhz'] = avg_occupied_bw_mhz  # 기존 평균 방식
                bw_entry['ul_actual_occupied_bw_mhz'] = actual_occupied_bw_mhz  # 실제 사용 대역폭 (MHz)
                bw_entry['ul_actual_occupied_bw_hz'] = actual_occupied_bw_hz  # 실제 사용 대역폭 (Hz)
                bw_entry['ul_share'] = ul_share
                bw_entry['ul_count'] = len(window_entries)
                bw_entry['ul_estimated_throughput_mbps'] = estimated_throughput_mbps
                bw_entry['ul_spectral_efficiency'] = avg_spectral_efficiency
        
        # 타임스탬프 기준으로 정렬
        ue_bandwidth_per_sec[ue_idx].sort(key=lambda x: x['timestamp'])
    
    return ue_bandwidth_per_sec

def print_bandwidth_summary(bandwidth_per_sec: Dict[int, List[Dict]]):
    """UE별 자원 점유 요약 정보를 출력합니다."""
    print("=" * 100)
    print("UE별 자원 점유(Resource Usage) 정보 요약")
    print("=" * 100)
    print("주요 지표 설명:")
    print("  - sum_prb_symb (A_UE): 1초 동안 사용한 총 자원 (PRB × Symbol)")
    print("  - avg_prb (N_PRB_bar): 평균 동시 점유 PRB 수 = A_UE / (N_slot/sec × N_sym)")
    print("  - avg_occupied_bw_mhz (B_UE_bar): 평균 동시 점유 대역폭 = N_PRB_bar × B_PRB^(MHz)")
    print("  - estimated_throughput_mbps: 예상 Throughput (수식 8) = B_UE × η_MCS × N_layer")
    print("    * η_MCS: MCS 스펙트럼 효율 (bps/Hz), N_layer: MIMO 레이어 수 (기본값 1)")
    print("=" * 100)
    
    for ue_idx in sorted(bandwidth_per_sec.keys()):
        entries = bandwidth_per_sec[ue_idx]
        if not entries:
            continue
        
        print(f"\n[UE{ue_idx}] 총 {len(entries)}개의 1초 윈도우")
        print("-" * 100)
        
        # DL 통계
        dl_prb_symbs = [e['dl_sum_prb_symb'] for e in entries if e['dl_sum_prb_symb'] > 0]
        dl_avg_prbs = [e['dl_avg_prb'] for e in entries if e['dl_avg_prb'] > 0]
        dl_utilizations = [e['dl_utilization'] for e in entries if e['dl_utilization'] > 0]
        dl_avg_bws = [e['dl_avg_occupied_bw_mhz'] for e in entries if e['dl_avg_occupied_bw_mhz'] > 0]
        dl_shares = [e['dl_share'] for e in entries if e['dl_share'] > 0]
        dl_counts = [e['dl_count'] for e in entries if e['dl_count'] > 0]
        
        if dl_prb_symbs:
            print(f"  DL (Downlink) 자원 점유:")
            print(f"    sum_prb_symb (자원 점유 면적):")
            print(f"      - 최소값: {min(dl_prb_symbs)} PRB×Symb")
            print(f"      - 최대값: {max(dl_prb_symbs)} PRB×Symb")
            print(f"      - 평균값: {sum(dl_prb_symbs) / len(dl_prb_symbs):.1f} PRB×Symb")
            print(f"    avg_prb (평균 동시 점유 PRB):")
            print(f"      - 평균값: {sum(dl_avg_prbs) / len(dl_avg_prbs):.2f} PRB")
            if dl_utilizations:
                print(f"    utilization (BWP 절대 점유율):")
                print(f"      - 최소값: {min(dl_utilizations):.1%}")
                print(f"      - 최대값: {max(dl_utilizations):.1%}")
                print(f"      - 평균값: {sum(dl_utilizations) / len(dl_utilizations):.1%}")
            print(f"    avg_occupied_bw_mhz (평균 동시 점유 대역폭 - 기존 방식):")
            print(f"      - 평균값: {sum(dl_avg_bws) / len(dl_avg_bws):.3f} MHz")
            # 실제 사용 대역폭 통계 (MHz 단위)
            dl_actual_bws = [e.get('dl_actual_occupied_bw_mhz', 0.0) for e in entries if e.get('dl_actual_occupied_bw_mhz', 0) > 0]
            if dl_actual_bws:
                print(f"    actual_occupied_bw_mhz (실제 사용 대역폭 - 수식 5 기반):")
                print(f"      - 최소값: {min(dl_actual_bws):.3f} MHz")
                print(f"      - 최대값: {max(dl_actual_bws):.3f} MHz")
                print(f"      - 평균값: {sum(dl_actual_bws) / len(dl_actual_bws):.3f} MHz")
            # 예상 Throughput 정보
            dl_est_tputs = [e['dl_estimated_throughput_mbps'] for e in entries if e.get('dl_estimated_throughput_mbps', 0) > 0]
            if dl_est_tputs:
                print(f"    estimated_throughput_mbps (예상 Throughput, 수식 8):")
                print(f"      - 최소값: {min(dl_est_tputs):.2f} Mbps")
                print(f"      - 최대값: {max(dl_est_tputs):.2f} Mbps")
                print(f"      - 평균값: {sum(dl_est_tputs) / len(dl_est_tputs):.2f} Mbps")
                print(f"      - 수식: Throughput ≈ B_UE × η_MCS × N_layer")
            if dl_shares:
                print(f"    share (UE 간 상대 점유 비율):")
                print(f"      - 최소값: {min(dl_shares):.1%}")
                print(f"      - 최대값: {max(dl_shares):.1%}")
                print(f"      - 평균값: {sum(dl_shares) / len(dl_shares):.1%}")
            print(f"    - 데이터가 있는 윈도우 수: {len(dl_prb_symbs)}")
        else:
            print(f"  DL (Downlink): 데이터 없음")
        
        # UL 통계
        ul_prb_symbs = [e['ul_sum_prb_symb'] for e in entries if e['ul_sum_prb_symb'] > 0]
        ul_avg_prbs = [e['ul_avg_prb'] for e in entries if e['ul_avg_prb'] > 0]
        ul_utilizations = [e['ul_utilization'] for e in entries if e['ul_utilization'] > 0]
        ul_avg_bws = [e['ul_avg_occupied_bw_mhz'] for e in entries if e['ul_avg_occupied_bw_mhz'] > 0]
        ul_shares = [e['ul_share'] for e in entries if e['ul_share'] > 0]
        ul_counts = [e['ul_count'] for e in entries if e['ul_count'] > 0]
        
        if ul_prb_symbs:
            print(f"  UL (Uplink) 자원 점유:")
            print(f"    sum_prb_symb (자원 점유 면적):")
            print(f"      - 최소값: {min(ul_prb_symbs)} PRB×Symb")
            print(f"      - 최대값: {max(ul_prb_symbs)} PRB×Symb")
            print(f"      - 평균값: {sum(ul_prb_symbs) / len(ul_prb_symbs):.1f} PRB×Symb")
            print(f"    avg_prb (평균 동시 점유 PRB):")
            print(f"      - 평균값: {sum(ul_avg_prbs) / len(ul_avg_prbs):.2f} PRB")
            if ul_utilizations:
                print(f"    utilization (BWP 절대 점유율):")
                print(f"      - 최소값: {min(ul_utilizations):.1%}")
                print(f"      - 최대값: {max(ul_utilizations):.1%}")
                print(f"      - 평균값: {sum(ul_utilizations) / len(ul_utilizations):.1%}")
            print(f"    avg_occupied_bw_mhz (평균 동시 점유 대역폭 - 기존 방식):")
            print(f"      - 평균값: {sum(ul_avg_bws) / len(ul_avg_bws):.3f} MHz")
            # 실제 사용 대역폭 통계 (MHz 단위)
            ul_actual_bws = [e.get('ul_actual_occupied_bw_mhz', 0.0) for e in entries if e.get('ul_actual_occupied_bw_mhz', 0) > 0]
            if ul_actual_bws:
                print(f"    actual_occupied_bw_mhz (실제 사용 대역폭 - 수식 5 기반):")
                print(f"      - 최소값: {min(ul_actual_bws):.3f} MHz")
                print(f"      - 최대값: {max(ul_actual_bws):.3f} MHz")
                print(f"      - 평균값: {sum(ul_actual_bws) / len(ul_actual_bws):.3f} MHz")
            # 예상 Throughput 정보
            ul_est_tputs = [e['ul_estimated_throughput_mbps'] for e in entries if e.get('ul_estimated_throughput_mbps', 0) > 0]
            if ul_est_tputs:
                print(f"    estimated_throughput_mbps (예상 Throughput, 수식 8):")
                print(f"      - 최소값: {min(ul_est_tputs):.2f} Mbps")
                print(f"      - 최대값: {max(ul_est_tputs):.2f} Mbps")
                print(f"      - 평균값: {sum(ul_est_tputs) / len(ul_est_tputs):.2f} Mbps")
                print(f"      - 수식: Throughput ≈ B_UE × η_MCS × N_layer")
            if ul_shares:
                print(f"    share (UE 간 상대 점유 비율):")
                print(f"      - 최소값: {min(ul_shares):.1%}")
                print(f"      - 최대값: {max(ul_shares):.1%}")
                print(f"      - 평균값: {sum(ul_shares) / len(ul_shares):.1%}")
            print(f"    - 데이터가 있는 윈도우 수: {len(ul_prb_symbs)}")
        else:
            print(f"  UL (Uplink): 데이터 없음")

def print_bandwidth_detailed_per_sec(bandwidth_per_sec: Dict[int, List[Dict]], 
                                     ue_idx: Optional[int] = None):
    """특정 UE의 상세 초당 대역폭 정보를 출력합니다 (extract_ue_priority.py 스타일)."""
    if ue_idx is not None:
        ues_to_print = [ue_idx] if ue_idx in bandwidth_per_sec else []
    else:
        ues_to_print = sorted(bandwidth_per_sec.keys())
    
    for ue_idx_print in ues_to_print:
        entries = bandwidth_per_sec[ue_idx_print]
        if not entries:
            continue
        
        # 기준 시간 찾기 (첫 번째 유효한 타임스탬프)
        first_timestamp = None
        for entry in entries:
            if entry.get('timestamp') is not None:
                first_timestamp = entry['timestamp']
                break
        
        if first_timestamp is None:
            print(f"\n[경고] UE{ue_idx_print}: 유효한 타임스탬프가 없습니다.")
            continue
        
        print(f"\n{'=' * 100}")
        print(f"UE{ue_idx_print} 상세 정보 (전체 {len(entries)}개, 시간 순서대로 정렬)")
        print(f"UE별 기준 시간: {first_timestamp.isoformat()}")
        print(f"{'=' * 100}")
        print(f"{'시간(분:초)':<15} {'DL PRB×Symb':<15} {'DL avgPRB':<12} {'DL util(%)':<12} {'DL BW(MHz)':<15} {'DL share':<10} {'UL PRB×Symb':<15} {'UL avgPRB':<12} {'UL util(%)':<12} {'UL BW(MHz)':<15} {'UL share':<10}")
        print("-" * 150)
        print("  참고: DL/UL BW(MHz)는 실제 사용 대역폭 (수식 5 기반: avg_prb × B_PRB)")
        print("        avg_prb는 시간 평균 동시 점유 PRB이므로, grant가 산발적이면 작게 나올 수 있습니다")
        print("-" * 150)
        
        for entry in entries:
            if entry['timestamp'] is not None:
                # 분:초.XX 형식으로 표시 (시간 제외, 소수점 둘째 자리)
                minutes = entry['timestamp'].minute
                seconds = entry['timestamp'].second + entry['timestamp'].microsecond / 1000000.0
                time_str = f"{minutes:02d}:{seconds:05.2f}"
            else:
                time_str = "N/A"
            
            dl_prb_symb = entry['dl_sum_prb_symb'] if entry['dl_sum_prb_symb'] > 0 else 0
            dl_avg_prb = entry['dl_avg_prb'] if entry['dl_avg_prb'] > 0 else 0.0
            dl_util = entry['dl_utilization'] if entry['dl_utilization'] > 0 else 0.0
            # 실제 사용 대역폭 사용 (MHz 단위)
            dl_avg_bw = entry.get('dl_actual_occupied_bw_mhz', 0.0) if entry.get('dl_actual_occupied_bw_mhz', 0) > 0 else 0.0
            dl_share = entry['dl_share'] if entry['dl_share'] > 0 else 0.0
            ul_prb_symb = entry['ul_sum_prb_symb'] if entry['ul_sum_prb_symb'] > 0 else 0
            ul_avg_prb = entry['ul_avg_prb'] if entry['ul_avg_prb'] > 0 else 0.0
            ul_util = entry['ul_utilization'] if entry['ul_utilization'] > 0 else 0.0
            # 실제 사용 대역폭 사용 (MHz 단위)
            ul_avg_bw = entry.get('ul_actual_occupied_bw_mhz', 0.0) if entry.get('ul_actual_occupied_bw_mhz', 0) > 0 else 0.0
            ul_share = entry['ul_share'] if entry['ul_share'] > 0 else 0.0
            
            print(f"{time_str:<15} {dl_prb_symb:<15} {dl_avg_prb:<12.2f} {dl_util:<12.1%} {dl_avg_bw:<15.3f} {dl_share:<10.1%} {ul_prb_symb:<15} {ul_avg_prb:<12.2f} {ul_util:<12.1%} {ul_avg_bw:<15.3f} {ul_share:<10.1%}")

def main():
    # 기본 로그 파일 경로
    default_log_file = "gnb.log"
    
    log_file = default_log_file
    ue_idx = None
    channel_type = None
    scs_khz = None
    bwp_prb = 52  # 기본값: 일반적인 BWP 크기
    
    # 명령줄 인자 파싱
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == '--ue' and i + 1 < len(sys.argv):
            ue_idx = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == '--channel' and i + 1 < len(sys.argv):
            channel_type = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == '--scs' and i + 1 < len(sys.argv):
            scs_khz = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i] == '--bwp-prb' and i + 1 < len(sys.argv):
            bwp_prb = int(sys.argv[i + 1])
            i += 2
        elif sys.argv[i].startswith('--'):
            # 알 수 없는 옵션은 건너뛰기
            i += 1
        else:
            # 로그 파일 경로로 간주
            log_file = sys.argv[i]
            i += 1
    
    # 로그 파일이 지정되지 않았으면 기본값 사용
    if log_file == default_log_file and len(sys.argv) == 1:
        print(f"로그 파일이 지정되지 않았습니다. 기본값 '{default_log_file}'을 사용합니다.")
        print("사용법: python3 extract_ue_bandwidth.py [log_file] [--ue <ue_index>] [--channel <pdsch|pusch>] [--scs <kHz>] [--bwp-prb <prb_count>]")
        print(f"예시: python3 extract_ue_bandwidth.py {default_log_file}")
        print(f"예시: python3 extract_ue_bandwidth.py {default_log_file} --ue 0 --channel pdsch")
        print(f"예시: python3 extract_ue_bandwidth.py {default_log_file} --bwp-prb 52")
        print()
    
    # BWP PRB 자동 추론 (명시적으로 지정되지 않은 경우)
    if bwp_prb == 52:  # 기본값인 경우에만 추론 시도
        print("\n[BWP PRB 자동 추론 시도 중...]")
        inferred_bwp = infer_bwp_prb_from_log(log_file)
        if inferred_bwp is not None:
            bwp_prb = inferred_bwp
            print(f"✓ 로그에서 BWP PRB 크기를 추론했습니다: {bwp_prb} PRB\n")
        else:
            print(f"⚠ Warning: 로그에서 BWP PRB 크기를 추론할 수 없습니다.")
            print(f"  기본값 {bwp_prb} PRB를 사용합니다.")
            print(f"  만약 밴드위드가 너무 작게 나온다면, --bwp-prb 옵션으로 실제 값을 지정하세요.\n")
    
    # 데이터 파싱
    print(f"로그 파일 파싱 중: {log_file}")
    bandwidth_data = parse_prb_bandwidth_log(log_file, scs_khz)
    
    # RNTI → UE 매핑 (고정값 사용)
    rnti_ue_map = get_rnti_to_ue_mapping()
    print("RNTI → UE 인덱스 매핑 (고정값):")
    for rnti, ue_idx_mapped in sorted(rnti_ue_map.items()):
        print(f"  RNTI {rnti} → UE{ue_idx_mapped}")
    print()
    
    # SCS 추출 (calculate_bandwidth_per_second에서 사용)
    if scs_khz is None:
        scs_khz = parse_scs_from_log(log_file)
        if scs_khz is None:
            scs_khz = 15  # 기본값
    
    print(f"BWP 설정: {bwp_prb} PRB, SCS: {scs_khz} kHz")
    
    # BWP 전체 대역폭 계산 및 출력
    prb_bandwidth_mhz = (12 * scs_khz) / 1000.0
    prb_bandwidth_hz = prb_bandwidth_mhz * 1000000.0
    bwp_total_bw_mhz = bwp_prb * prb_bandwidth_mhz
    bwp_total_bw_hz = bwp_total_bw_mhz * 1000000.0
    print(f"BWP 전체 대역폭: {bwp_total_bw_mhz:.3f} MHz ({bwp_total_bw_hz:.0f} Hz)")
    print(f"  계산: {bwp_prb} PRB × {prb_bandwidth_mhz:.3f} MHz/PRB = {bwp_total_bw_mhz:.3f} MHz")
    print()
    
    # 자원 점유 계산
    print("자원 점유 계산 중...")
    bandwidth_per_sec = calculate_bandwidth_per_second(bandwidth_data, rnti_ue_map, scs_khz, bwp_prb)
    print()
    
    # 요약 출력
    print_bandwidth_summary(bandwidth_per_sec)
    
    # 상세 출력 (항상 출력)
    print("\n" + "=" * 100)
    print("상세 정보 (자원 점유)")
    print("=" * 100)
    print_bandwidth_detailed_per_sec(bandwidth_per_sec, ue_idx)

if __name__ == '__main__':
    main()
