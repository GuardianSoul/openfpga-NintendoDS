# Video counter width experiment

The candidate narrows hc to11bits, saturating at2047 after all live output windows; lc narrows to11bits for its existing0..1399 range. No output or memory timing is intended to change.

`sim/pocket/video_reset/run.py --out NEW` runs the unchanged C++276reset/36public-pin matrix against401ebad; original --revert/--expect-reset-failure are explicitly unavailable here because that reference already fixes reset. Separate counter controls deliberately narrow hc too far or reset lc early, and require actual output mismatch.

The additional public-pin miter stresses long/missing line_start intervals, anchors around output/saturation boundaries, mode/rotation writes, reset widths1..9 and delayed/cancelled memory responses. It compares outputs every cycle, including blank RGB and idle memory payloads. These stress traces check equivalence, not correctness of upstream behavior under arbitrary VCOUNT jumps or impossible memory service.

No new RAM/DSP/state is added; mapped resource saving and whole-board fit remain unmeasured.
