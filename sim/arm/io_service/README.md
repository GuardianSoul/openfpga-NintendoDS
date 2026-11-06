# Passive ordinary-I/O service observation

This is a source-only observer for the existing joined52 production source
`2246c468c0d9bbd968ccdff7823f32df1c8d8f5f`. It appends one bind file to the
already composed compile command. It changes no RTL, testbench, guest code,
input or parameter. Actual elaboration/runtime are pending the coordinator's
single model; no separate build or qualification run is requested.

Append `observer.sv` once. Activate only for canonical unitmem and DS41 with
`+iocause=/absolute/fresh/prefix`. Files are `prefix.cpu.csv` and
`prefix.bus.csv`; existing files are refused. `prepare.py INCOMING.json
SOURCE_ROOT NEW.json` checks all153 production RTL hashes and creates a new
argv/receipt without invoking a compiler. Existing arguments remain identical.

Targets are aligned DISPSTAT04000004, BG0OFS04000010 and TM204000108/10A.
CPU rows record presented requests, WB readiness, captured pending descriptor,
NCNB ownership/ACK/push, read return/replay, holds and pipeline continuation.
Bus rows record held ARM9 bus requests, actual grants/ACKs, I/O request/device
select and timer state/commit. A speculative or held E3 presentation is not an
accepted physical transaction. On an early I/O grant, owner comes from the
grant vector; `mst` can still contain the previous owner. `disp_req` observes
the display acceptance edge; it does not independently verify scroll RAM data.

Rows sample live preposedge values, with unshifted picosecond time and separate
physical clock-edge counters. SYS-module edges run at67MHz here, not the DS
33MHz timer rate. Timer count/control values in bus rows are preedge values;
DS41's existing witness retains the following-negedge timer-state observation.
Each CPU target activity keeps15 further edges. Longer inactive gaps are not
continuous CPU coverage. Neither an internal DS phase nor a new timing law is
inferred from these fields.

The CPU/bus limits are250000/150000 rows. The final `END,rows,dropped` records
must exist with dropped=0 before treating a trace as complete. Truncation only
stops host logging; it never stalls/stops the DUT. No plusarg means no files.
The module has input ports only and changes private observer state/files.

Static checks cover CSV field/argument counts, the input-only/bind inventory,
all153 source hashes and exact removal of the appended argv argument. They are
not an elaboration, passivity runtime comparison or timing result. The existing
single-model source/profile/input/data guards remain required.
