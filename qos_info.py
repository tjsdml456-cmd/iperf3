#!/usr/bin/env python3
"""
UE별 QoS 정보 (5QI, PDB, GBR) 추출 스크립트
"""
import re
import sys
from collections import defaultdict
from typing import Dict, Optional

def parse_qos_log(log_file: str) -> list:
    """
    로그 파일에서 모든 QoS 정보 추출 (시간 순서대로)
    
    Returns:
        list: QoS 정보 리스트 (시간 순서)
        [
            {
                'line': int,
                'timestamp': str,
                'ue_idx': int,
                'lcid': int,
                '5qi': Optional[int],
                'pdb_ms': Optional[int],
                'gbr_dl_bps': Optional[int],
                'gbr_ul_bps': Optional[int],
                'type': str,  # 'STEP6-SCHED' or 'SCHED-QoS'
            },
            ...
        ]
    """
    # 패턴 1: [STEP6-SCHED] QoS Info - UE0 LCID4 5QI=5QI=0x9 PDB=300ms GBR=None Type=non-GBR
    # 또는 [STEP6-SCHED] QoS Info - UE0 LCID4 5QI=5QI=0x9 PDB=300ms GBR_DL=128000bps GBR_UL=128000bps Type=GBR
    pattern1_gbr_none = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?\[STEP6-SCHED\] QoS Info - UE(\d+) LCID(\d+) 5QI=5QI=0x([0-9a-fA-F]+) PDB=(\d+)ms GBR=None Type=(\w+)'
    )
    pattern1_gbr_dl_ul = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?\[STEP6-SCHED\] QoS Info - UE(\d+) LCID(\d+) 5QI=5QI=0x([0-9a-fA-F]+) PDB=(\d+)ms GBR_DL=(\d+)bps GBR_UL=(\d+)bps Type=(\w+)'
    )
    
    # 패턴 2: [SCHED-QoS] UE1 LCID4 PDB=300ms GBR=None Type=non-GBR
    # 또는 [SCHED-QoS] UE1 LCID4 PDB=300ms GBR_DL=128000bps Type=GBR (used in scheduling)
    pattern2_gbr_none = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?\[SCHED-QoS\] UE(\d+) LCID(\d+) PDB=(\d+)ms GBR=None Type=(\w+)'
    )
    pattern2_gbr_dl = re.compile(
        r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+).*?\[SCHED-QoS\] UE(\d+) LCID(\d+) PDB=(\d+)ms GBR_DL=(\d+)bps Type=(\w+)'
    )
    
    entries = []
    
    with open(log_file, 'r', encoding='utf-8') as f:
        for line_num, line in enumerate(f, 1):
            # 패턴 1-1: GBR=None인 경우
            match1_none = pattern1_gbr_none.search(line)
            if match1_none:
                timestamp = match1_none.group(1)
                ue_idx = int(match1_none.group(2))
                lcid = int(match1_none.group(3))
                five_qi_hex = match1_none.group(4)
                pdb_ms = int(match1_none.group(5))
                res_type = match1_none.group(6)
                
                entry = {
                    'line': line_num,
                    'timestamp': timestamp,
                    'ue_idx': ue_idx,
                    'lcid': lcid,
                    '5qi': int(five_qi_hex, 16),
                    'pdb_ms': pdb_ms,
                    'gbr_dl_bps': None,
                    'gbr_ul_bps': None,
                    'res_type': res_type,
                    'type': 'STEP6-SCHED'
                }
                entries.append(entry)
                continue
            
            # 패턴 1-2: GBR_DL/UL 있는 경우
            match1_gbr = pattern1_gbr_dl_ul.search(line)
            if match1_gbr:
                timestamp = match1_gbr.group(1)
                ue_idx = int(match1_gbr.group(2))
                lcid = int(match1_gbr.group(3))
                five_qi_hex = match1_gbr.group(4)
                pdb_ms = int(match1_gbr.group(5))
                gbr_dl = int(match1_gbr.group(6))
                gbr_ul = int(match1_gbr.group(7))
                res_type = match1_gbr.group(8)
                
                entry = {
                    'line': line_num,
                    'timestamp': timestamp,
                    'ue_idx': ue_idx,
                    'lcid': lcid,
                    '5qi': int(five_qi_hex, 16),
                    'pdb_ms': pdb_ms,
                    'gbr_dl_bps': gbr_dl,
                    'gbr_ul_bps': gbr_ul,
                    'res_type': res_type,
                    'type': 'STEP6-SCHED'
                }
                entries.append(entry)
                continue
            
            # 패턴 2-1: GBR=None인 경우
            match2_none = pattern2_gbr_none.search(line)
            if match2_none:
                timestamp = match2_none.group(1)
                ue_idx = int(match2_none.group(2))
                lcid = int(match2_none.group(3))
                pdb_ms = int(match2_none.group(4))
                res_type = match2_none.group(5)
                
                entry = {
                    'line': line_num,
                    'timestamp': timestamp,
                    'ue_idx': ue_idx,
                    'lcid': lcid,
                    '5qi': None,
                    'pdb_ms': pdb_ms,
                    'gbr_dl_bps': None,
                    'gbr_ul_bps': None,
                    'res_type': res_type,
                    'type': 'SCHED-QoS'
                }
                entries.append(entry)
                continue
            
            # 패턴 2-2: GBR_DL 있는 경우
            match2_gbr = pattern2_gbr_dl.search(line)
            if match2_gbr:
                timestamp = match2_gbr.group(1)
                ue_idx = int(match2_gbr.group(2))
                lcid = int(match2_gbr.group(3))
                pdb_ms = int(match2_gbr.group(4))
                gbr_dl = int(match2_gbr.group(5))
                res_type = match2_gbr.group(6)
                
                entry = {
                    'line': line_num,
                    'timestamp': timestamp,
                    'ue_idx': ue_idx,
                    'lcid': lcid,
                    '5qi': None,
                    'pdb_ms': pdb_ms,
                    'gbr_dl_bps': gbr_dl,
                    'gbr_ul_bps': None,
                    'res_type': res_type,
                    'type': 'SCHED-QoS'
                }
                entries.append(entry)
    
    return entries

def format_gbr(gbr_bps: Optional[int]) -> str:
    """GBR 값을 포맷팅"""
    if gbr_bps is None:
        return "None"
    else:
        return str(gbr_bps)

def print_qos_info(entries: list):
    """UE별로 QoS 정보 출력 (STEP6-SCHED만)"""
    if not entries:
        print("추출된 QoS 정보가 없습니다.")
        return
    
    # SCHED-QoS 타입 제외, STEP6-SCHED만 필터링
    filtered_entries = [e for e in entries if e['type'] == 'STEP6-SCHED']
    
    if not filtered_entries:
        print("STEP6-SCHED 타입의 QoS 정보가 없습니다.")
        return
    
    # UE별로 그룹화
    ue_groups = defaultdict(list)
    for entry in filtered_entries:
        ue_groups[entry['ue_idx']].append(entry)
    
    # UE별로 출력
    for ue_idx in sorted(ue_groups.keys()):
        ue_entries = ue_groups[ue_idx]
        print("\n" + "=" * 120)
        print(f"UE{ue_idx} ({len(ue_entries)}개 항목)")
        print("=" * 120)
        print(f"{'Line':<6} {'Timestamp':<28} {'LCID':<6} {'Type':<12} {'5QI':<6} {'PDB(ms)':<10} {'GBR_DL(bps)':<15} {'GBR_UL(bps)':<15} {'ResType':<15}")
        print("-" * 135)
        
        for entry in ue_entries:
            five_qi_str = str(entry['5qi']) if entry['5qi'] is not None else "N/A"
            pdb_str = str(entry['pdb_ms']) if entry['pdb_ms'] is not None else "N/A"
            gbr_dl_str = format_gbr(entry['gbr_dl_bps'])
            gbr_ul_str = format_gbr(entry['gbr_ul_bps'])
            res_type_str = entry.get('res_type', 'N/A')
            
            print(f"{entry['line']:<6} {entry['timestamp']:<28} {entry['lcid']:<6} "
                  f"{entry['type']:<12} {five_qi_str:<6} {pdb_str:<10} {gbr_dl_str:<15} {gbr_ul_str:<15} {res_type_str:<15}")
    
    print("\n" + "=" * 120)
    print(f"총 {len(filtered_entries)}개의 QoS 정보 추출 완료 (UE {len(ue_groups)}개, STEP6-SCHED만)")

def main():
    log_file = "gnb.log"
    
    if len(sys.argv) > 1:
        log_file = sys.argv[1]
    
    try:
        entries = parse_qos_log(log_file)
        print_qos_info(entries)
    except FileNotFoundError:
        print(f"에러: 로그 파일 '{log_file}'을(를) 찾을 수 없습니다.")
        sys.exit(1)
    except Exception as e:
        print(f"에러 발생: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()

