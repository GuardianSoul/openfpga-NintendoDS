#!/usr/bin/env bash
# Compatibility entry point. Sanitation and 12-hour conversion intentionally
# differ from the old RTC: equivalence covers valid 24-hour traffic only.
# Invalid-byte/12-hour behavior is checked by --only rtc-exhaust, against an
# independent decimal oracle, rather than the old implementation.
set -euo pipefail
cd "$(dirname "$0")/../../.."
exec sim/ds_dev/equiv/rtc_eq2.sh bbf3e35 "${1:-rtl/ds/nds_rtc.sv}" "${2:-40}"
