#!/usr/bin/env bash
# Deliberate bugs in the new side that sim/arm/tools/a7arch_test.sh must catch.
#   a7arch_mutate.sh REF
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
ref=${1:?REF}
muts=(
  "s/K_MULL: cin = es == ES_LAST \&\& mc;/K_MULL: cin = 1'b0;/"                         # the low word's carry dropped
  "s/4'h5:       begin cin = nzcv\[1\]; arith/4'h5:       begin cin = 1'b0; arith/"     # ADC without the carry
  "s/if (rrx) sho_u\[31\] = nzcv\[1\];/if (rrx) sho_u[31] = 1'b0;/"                     # RRX without the carry
  "s/else if (al\[0\])   ldv = {r\[31:24\], 16'h0, r\[7:0\]};/else if (al[0])   ldv = {16'h0, r[15:0]};/"   # an odd LDRH not rotated
  "s/rf_we = is_load ? br != 4'hF : first \&\& ins\[21\];/rf_we = is_load ? br != 4'hF : ins[21];/"    # STM writes the base at every step
  "s/(ins\[21\] \&\& (!e_blk || !blist\[rn\]))/ins[21]/"   # LDM writes a base in its list
  "s/wire         z_now = z_en ? z_d : cpsr\[11\];/wire         z_now = cpsr[11];/"      # MRS misses Z landing
  "s/(x ? 31'd2 : pa_back/(x ? 31'd0 : pa_back/"                                         # an interrupt's LR
  "s/wire  \[4:0\]  bmode = (b_usr \&\& es == ES_MEM) ? M_USR : mode;/wire  [4:0]  bmode = mode;/"   # STM^\/LDM^ not the user bank
  "s/if (i_rot) shc_u = (ins\[11:8\] == 4'h0) ? nzcv\[1\] : sho_u\[31\];/if (i_rot) shc_u = nzcv[1];/"   # the rotated immediate's carry
)
fail=0
for m in "${muts[@]}"; do
  if "$root/sim/arm/tools/a7arch_test.sh" "$ref" 200 "2" "$m" > /tmp/a7m.$$ 2>&1; then echo "NOT CAUGHT: $m"; fail=1
  else grep -q "mutation changed nothing" /tmp/a7m.$$ && { echo "DID NOT APPLY: $m"; fail=1; } || echo "caught: ${m:0:60} ($(grep -c DIFF /tmp/a7m.$$) shown)"; fi
done
rm -f /tmp/a7m.$$
exit $fail
