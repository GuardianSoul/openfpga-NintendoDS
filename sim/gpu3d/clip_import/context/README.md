# Full RF/context wrapper capture and first use

This closes the narrow missing wrapper gate on the c47 clip-import bridge,
with the exact default Geometry source/profile in `input.json`. It does not
refresh the canonical seed binding or qualify games, STA, or general savestates.
The existing canonical seed still lacks the complete witness and is rejected.

The retained clean MKDS packet is unchanged: 2,632 words, parent atomic SHA256
`47df641bb07b7889a5220c4a32314d6e2701a6aaac2d5fe0ab035c251b59744d`.
`prepare.py` verifies its original manifest. Both full Geometry instances use
the same production leaves and options; only clip STORE0/STORE1 differs.
Normal cold initialization reaches a drained post-M boundary at cycle 10008,
last-E RF write absent, both clocks low. Source import/readback then captures
all 160 late cells and ten held reads from the actual default representation;
no missing groups or O/I values are invented. Target import deposits the
complete witness without clocks or phase/metadata changes. Both 2,048-word RF
replicas, all context words, and sidecar readback agree immediately.

The first 16 ordinary lazy MMIO matrix reads match the retained independent
expected values. Subsequent normal GX matrix-mode/identity commands from the
existing caller recipe precede a clipping quad. These are compared future
inputs after the original observations, not backdoor state repair. The first
clip/public-consumer sequence matches through cycle 10843: two clip starts,
119 clip writes, 294 RF writes, four polygons. Public outputs and RF order/data
are compared before E, after E, and after M. Original matrix-only vertex trials
correctly far-rejected and did not satisfy clip coverage; their logs are kept.

The accepted finalize-group implementation had replaced four old replicas with
two TDP copies (fit1154). The simulation-only explicit
`RUNTIME_FINALIZE_GROUP_PUMP` adapter maps old port n to pair n/2, checks all
four old canonical replicas and their RF source before writing, deposits the
64 captured addresses into both copies, and verifies all 256 canonical rows.
It preserves epoch, pending write, and held-read metadata. Macro absent, the
old import/verify body is unchanged. Production RTL is unchanged.

Run with the approved main helper on an allocated L2 slot:

```
python3 sim/gpu3d/clip_import/context/prepare.py
FETCH=out /home/user/Git/NDS_Pocket/tools/laptop-run.sh /home/user/Git/NDS_Pocket/build/clip16-context-l2 -- python3 worker.py
```

One worker, NI10, jobs1/threads1, 512MiB scratch cap, 1GiB free-space floor,
240-second stage limit. Task-local no-PCH/O0 host compilation avoids the earlier
PCH time-budget failure; simulation events and inputs are unchanged. Owned
process groups are reaped and object trees pruned. The successful positive
run peaked at 56,903,786 bytes. No fit was queued by this owner.

`evidence.tar.gz` retains exact source/packet/profile/freeze binding, captured
sidecar, positive and deliberate-mutation logs and receipts. `verify.py`
checks its hashes offline. The mutation changes only the target adapter's
pair1 address0 deposit to address1; unmodified readback must catch
`FINALIZE_GROUP_READBACK oldport2 addr0`.
