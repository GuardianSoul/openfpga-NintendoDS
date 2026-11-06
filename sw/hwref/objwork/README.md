# Standalone OBJ work discriminator

Eight finite cases and three preserved controls, described in
[the plan](../../../docs/objwork-probe-plan.md) and
[software qualification](../../../docs/objwork-v1.md). This reuses OBJv2's
known capture/BG state; the original producer and staged batch are unchanged.
Explicit standalone build only; not in the historical or speed-trip menus.
Output is `/hwref/objwork-v1` on a future hardware run.

All normal cases use bit23=0. Right clipping observes only the unoccluded
first32 columns of the right marker. The normal8bpp block uses tile512;
identity-affine ballast uses matrix0=(256,0,0,256) and no double-size.
The full24KiB OBJ input and all OAM/matrix/register state are checked.
The predictor's cost models are hypotheses; hardware can reject all of them.

Only a coordinator-allocated worker may build/simulate. The explicit
Makefile supports `OBJWORK_DEFS=-DOBJWORK_TEXEL_MUTANT` for the caught
negative software control, which must never enter the hardware selection.
No card deployment or hardware request is part of this source.
