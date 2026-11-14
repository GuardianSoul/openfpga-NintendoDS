# Exact e63 render-service witness

This component uses the original accepted PS, cache, 2D-block, VRAM, native
memory and ring interfaces. It extracts the actual e63 raster/cache/ring
instantiations and uses the actual VRAM resolver, crossings, poster, FIFO,
bounded native scheduler, controller and pin memory. The input provider,
CPU/2D/video/capture traffic and admission schedule are synthetic. This is
not a game, a CPU-core test or a full 2D/video timing model.

The reference uses the same raster and polygon inputs with ideal texture
and palette responses. Complete generation-tagged reference frames permit
exact comparison when either renderer leads. Every produced pixel must
compare; every consumed pixel must equal its completed producer value.
Cancellation preserves an old consumer lease and already accepted returns.
Native read owners are recorded at controller acceptance and checked
through every beat, independently of the scheduler's current grant.

Use a checkout whose production files match e63:

```sh
python3 sim/ds/render_service/prepare.py build/render-service-example
python3 sim/ds/render_service/run.py lint --out build/render-service-example
python3 sim/ds/render_service/run.py build --out build/render-service-example
python3 sim/ds/render_service/run.py positive --out build/render-service-example
```

The unchanged policy **fails** the strict capture traffic budget on the
retained fixture. That command therefore exits unsuccessfully. A separate
`measure` action records every newly instrumented traffic-budget violation
while retaining all DUT, data, owner, refresh, FIFO and 3D-readiness guards.
Its result has `PASS=false` when any traffic budget fails. A completed
measurement is not deadline acceptance. `phase2487` is explicitly a separate
SYS/FAST clock-phase stress; it does not shift the production-clock result.

`native-owner`, `block-owner` and `deadline` inject actual owner-FIFO or
allocator faults into the copied DUT. The block-owner fault is caught first
by the original GPU no-inflight guard. The other faults are caught by the
independent native-owner and actual readiness-edge checks. Inverse edits
recover the exact production sources; no fault probe lands in production.

The runner admits one NI10/t1 worker against declared disk growth, other
owners' reservations, the shared disk floor and available RAM. Builds use
the shared C++ mutex and `-j1`. `analyze.py` checks complete uncapped traces
and joins accepted owners, addresses, counts, returns and publications.
Its accounting PASS is separate from traffic deadline acceptance. The
retained packet documents retries and exact source/model/input hashes.
