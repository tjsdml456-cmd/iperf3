#!/usr/bin/env bash
# Compatibility wrapper.
# Existing scripts source qos_random_common.sh; actual implementation lives in qos_schedule_lib.sh.

_qos_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qos_schedule_lib.sh
. "$_qos_common_dir/qos_schedule_lib.sh"
unset _qos_common_dir
