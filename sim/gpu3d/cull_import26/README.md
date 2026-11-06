# Cull25 changed-cache import regression

`runtime_import_gx_context.svh` still uses the same 2,632-word context.
Only words2500..2511 (four W, four X, four Y) now pass through the generated
`runtime_import_cull_cache.svh`. Define `RUNTIME_CULL_MLAB_ENABLED` around
an include for a CULL_MLAB=1 instance; absence fails preflight against the
actual parameter. Default-off retains the original twelve FF assignments.
`python3 sim/ds/runtime_cull_context.py --check` checks the generated helper.

The enabled helper takes just twelve words and deposits groups0..3 in all
nine portable simulation backing arrays. It checks all36 cells on readback;
groups4..31 are untouched. It never writes clocks, reset, epoch/seen, valid,
held group or held data. A stopped pre-M snapshot must agree with the logical
post-SYS imported image, so its unchanged pending write safely replays that
value. A conflict fails before the full-context importer writes any field.
A post-M stale valid is already consumed and does not require an empty hold.
Native Quartus imports remain explicitly unsupported, as in the accepted
clip bridge. No production RTL, clock, reset, arithmetic or profile changed.

On allocated Desktop D1 (one worker, nice10, jobs1, threads1):

```
python3 sim/gpu3d/cull_import26/source.py
python3 sim/gpu3d/cull_import26/prepare.py
python3 sim/gpu3d/cull_import26/run.py
```

The test binds current production RTL to the retained accepted context and
clip witness, imports both CULL0/CULL1 through the existing full wrapper, and
then issues ordinary identity/triangle commands. It pauses the naturally
reached first cull, captures the old FF twelve-word image, poisons arbitrary
target backing, and imports only that cache image. It tests post-M and pre-M
with the same101 metadata bits/time and compares the next actual cull operand
and outcome at exact SYS dates. Two faults change actual target backing or
the actual held M payload after import; they must reach both the first operand
and outcome. A separate preflight-conflict case must fail before import.
This is a changed-cache regression, not a new qualification of the old full
RF/clip import, host mapping source, games, timing or general savestates.

The initial wrong-copy test used a non-distinct Y value and ran before M,
which also replays that group. The first operand/outcome stayed equal, so the
sensitivity assertion failed. Its retained log records the test failure.
The corrected wrong-copy case uses distinct X after M. The independent
pending-M fault changes held X before M.
