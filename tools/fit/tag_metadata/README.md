# Packed ARM9 tag metadata mapping gate

This tool reads source, QSF and fitter reports. It never starts Quartus, STA,
a simulation or a fit. A live PASS covers **packed-tag mapping only**; Root's
same-profile area, timing, functional and game gates remain separate.

For Root's completed combined build:

```
python3 tools/fit/tag_metadata/gate.py collect \
  --project "$TAG_FIT_PROJECT" --revision apf_top \
  --source-tree /home/user/Git/NDS_Pocket-codex-rc053-retained-integration \
  --source 492132a42885d6c39d78e917275824c1be69ed28 \
  --out /home/user/Git/NDS_Pocket/build/coordinator/tag-mapping-492132a4
python3 tools/fit/tag_metadata/gate.py check \
  /home/user/Git/NDS_Pocket/build/coordinator/tag-mapping-492132a4
```

`collect` is a source/report snapshot, not a compiler invocation. If an archived
QSF contains a different absolute source root, explicitly add
`--qsf-source-root /ABS/ORIGINAL_SOURCE_ROOT`. Unmapped paths, missing critical
sources, duplicate sources and working-tree bytes that differ from the requested
commit fail. The report/QSF pairing comes from Root's queued-build archive.
Existing output directories are rejected to avoid mixing evidence. Root supplies
`TAG_FIT_PROJECT` from queue8859/card`rc053room` (`compact-experiment`, seed`3asR`,
CLOCK_NS parameter10) after completion; this tool neither fetches nor polls it.

## Required source and physical organization

The selected CPU source was inspected in `codex/rc10-tags-production` at parent
`5f24526b`: `g_packed_tags` contains `u_packed_d` and `u_packed_i`, each an actual
`arm9_ram` with AW8 /LANES1 /LANE_W32 /FOLD0 and the original common clock,
independent D/I addresses, write enables, data and return signals. Its selected
guard is WAYS2 /DSB8 /ISB8 /SLOW /EVB /!EVBW /EARLYD /OPT1711268835.
The original fixture records that observed dirty source hash. Those exact bytes
are now confirmed in CPU production`53ebf291` and Root combined
`492132a42885d6c39d78e917275824c1be69ed28`; see `fixtures/pinned-source.json`.
This is source-intent confirmation. Live mapping still requires the successful
native report and its pinned QSF/source; no four-block credit comes from declarations.

With LANES1 and FOLD0, `arm9_ram` selects `lane[0].one.u_ram`: M10K,
BIDIR_DUAL_PORT, registered read addresses, unregistered outputs, CLOCK0 for both
ports, port-A full-word writes and port-B read only. The exact native source
parameters must retain NEW_DATA_NO_NBE_READ on each port and mixed-port DONT_CARE.
The fitter report must correspond to new-data A/B and mixed-port "Don't care".

The report gate requires:

- One uniquely successful fitter status and one complete RAM summary, parsed
  with the existing `resources.table` parser. Malformed or duplicate table rows
  and columns fail instead of being silently skipped.
- Exactly one D bank and one I bank under the same ARM9 controller, with the
  selected generate/native-lane names. No original `u_dtag`/`u_itag`, original-tag
  branch, unknown packed bank or extra tag RAM may remain. Unrelated ARM7 tags
  and data RAM are not mistaken for ARM9 metadata.
- Each bank is a 256×32 true-dual-port, single-clock M10K RAM with registered
  inputs, unregistered outputs, expected RDW, no external MIF and no ECC.
- Two M10K blocks and zero MLABs per bank. Each row lists exactly two assigned,
  distinct `M10K_X*_Y*_N0` sites. The total is four distinct sites, with no
  allocation collision against either bank or any other reported M10K RAM.
- Implementation depths stay256. Constant upper padding can be trimmed, while
  at least the21 D and25 I used bits must remain; reported implementation widths
  and bit totals must agree. Logical port widths remain32.

The source guard, native parameters/ports, report shape and all hashes are
checked again from the sealed bundle. The gate returns
`PASS_PACKED_TAG_REPORT_MAPPING_ONLY` only for native report bundles.
Mock origin is rejected by live checks, and the native report path also rejects
the fixture marker if its origin is relabeled. Fixture-only passes are
`MOCK_MAPPING_PASS_NOT_PHYSICAL` and cannot be promoted by the CLI.

## Lightweight fixtures

```
python3 tools/fit/tag_metadata/test_gate.py \
  --negative-report /home/user/Git/NDS_Pocket/build/coordinator/fit2170/apf_top.fit.rpt
```

69 cases cover complete mock mappings; missing/duplicate/wrong banks and old
tags; port/depth/clock/RDW/register/MIF/MLAB/implementation errors; unassigned,
duplicate or colliding locations; incomplete report tables; changed source
parameters/ports/native clocks; actual Git/QSF pinning and explicit archive-root
remapping; sealed artifact hash and origin guards. #2170 is used **only as a
negative**: its failed placement and unassigned RAM cannot establish legal tag
mapping. No native packed-tag report has passed this gate yet.

No RTL, I/O gate, canonical clock resolver or accepted proof was changed/rerun.
All operations here are lightweight source/report work; no heavy worker is needed.
