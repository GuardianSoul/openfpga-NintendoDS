#!/usr/bin/env bash
# Mutation check for the SPI/RTC test bench: copy rtl/ds, apply one sed
# expression to one file, rebuild and expect tb_ds_dev to fail.
#   sim/ds_dev/mutate.sh                         the standard set below
#   sim/ds_dev/mutate.sh <file> '<sed expr>' [tb args...]
# Exit 0 when every mutation is caught, 1 when one is not.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
verilator=${VERILATOR:-build/tools/oss-cad-suite/bin/verilator}
fw=${DSDEV_FW:-$HOME/Git/NDS_Pocket/roms/firmware.bin}
[ -f "$fw" ] || { echo "firmware image $fw missing: the fw mutations need it" >&2; exit 2; }
one() {
    local file=$1 expr=$2; shift 2
    local work=$root/build/ds_dev/mutant
    rm -rf "$work"; mkdir -p "$work/rtl"
    cp "$root"/rtl/ds/*.sv "$work/rtl/"
    local before; before=$(md5sum "$work/rtl/$file")
    sed -i -e "$expr" "$work/rtl/$file"
    [ "$before" != "$(md5sum "$work/rtl/$file")" ] || { echo "mutation did not change $file: $expr" >&2; exit 2; }
    "$verilator" --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
      -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL --Mdir "$work/obj" --top-module tb_ds_dev \
      -CFLAGS "-std=c++20 -O2" "$root/rtl/ds/nds_dsp_add.sv" "$work/rtl/nds_spi.sv" "$work/rtl/nds_rtc.sv" "$root/sim/ds_dev/tb_ds_dev.sv" \
      "$root/sim/ds_dev/tb_ds_dev.cpp" >"$work/verilator.log" 2>&1 || { tail -20 "$work/verilator.log"; exit 2; }
    if timeout 300 "$work/obj/Vtb_ds_dev" --fw "$fw" "$@" > "$work/run.log" 2>&1; then
        echo "NOT CAUGHT: $file: $expr"; return 1
    fi
    echo "caught: $file: $expr -> $(tail -1 "$work/run.log" | sed 's/ (seed.*//'); first: $(grep -m1 '^FAIL \[' "$work/run.log" | cut -c1-110)"
}
if [ $# -ge 2 ]; then one "$@"; exit; fi
rc=0
one nds_spi.sv "s/f_pos == 3'd2 ? 8'h40/f_pos == 3'd2 ? 8'h41/" --only fw                    || rc=1  # RDID value
one nds_spi.sv "s/2'd1: f_byte = q0\[15:8\]/2'd1: f_byte = q0[23:16]/" --only fw             || rc=1  # byte lane
one nds_spi.sv "s/else if (!f_wait) begin busy <= 1'b0/else begin busy <= 1'b0/" --only fw  || rc=1  # no stretch
one nds_spi.sv "s/(f_stream || f_wait) \&\& qn != 2'd2/f_wait \&\& qn == 2'd0/" --only fw    || rc=1  # no prefetch
one nds_spi.sv "s/if (fw_req \&\& !fw_ack) f_drop <= 1'b1;/if (1'b0) f_drop <= 1'b1;/" --only fw || rc=1  # stale fetch kept
one nds_spi.sv "s/|| (wcnt \&\& en \&\& !io_wdata\[15\])//" --only fw                         || rc=1  # disable no release
one nds_spi.sv "s/{2'b0, t_prd\[23:8\]}/{2'b0, t_prd[22:7]}/" --only tsc                     || rc=1  # TSC scale
one nds_spi.sv "s/3'd5:    t_res = pen ? t_raw : 12'h000/3'd5:    t_res = pen ? t_raw : 12'hFFF/" --only tsc || rc=1  # pen-up X
one nds_spi.sv "s/3'd4: p_val = {4'h4, p_r4}/3'd4: p_val = {4'h0, p_r4}/" --only spi         || rc=1  # backlight default
one nds_spi.sv "s/tmr <= (9'd64 << n_baud)/tmr <= (9'd32 << n_baud)/" --only spi             || rc=1  # transfer time
one nds_rtc.sv "s/y\[3:0\] == 4'h4 ||/y[3:0] == 4'h5 ||/" --only rtc                         || rc=1  # leap years
one nds_rtc.sv "s/5'h04, 5'h06, 5'h09, 5'h11:/5'h04, 5'h06, 5'h09:/" --only rtc              || rc=1  # November 31 days
one nds_rtc.sv "s/v\[7:4\] == 4'h9 ? 4'h0/v[7:4] == 4'h9 ? 4'h1/" --only rtc                 || rc=1  # BCD 99 wrap
one nds_rtc.sv "s/n_hr = 8'h00; n_day = pm; n_pm = !pm;/n_hr = 8'h00; n_day = !pm; n_pm = !pm;/" --only rtc || rc=1  # 12h day carry
one nds_rtc.sv "s/8'h05:               cm = 3'd1;/8'h05:               cm = 3'd2;/" --only rtc || rc=1  # day of week, May
one nds_rtc.sv "s/if (stop \&\& c_ok/if (1'b0 \&\& c_ok/" --only rtc                            || rc=1  # power-on flag kept
one nds_rtc.sv "s/if (pend \&\& !io\[2\])/if (pend)/" --only rtc                                || rc=1  # count during a read
exit $rc
