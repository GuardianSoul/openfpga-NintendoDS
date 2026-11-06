#!/usr/bin/env python3
"""Compare census runs: report.py build/census/<game> ... > tables.md"""
import json
import sys
from pathlib import Path

runs = []
for d in sys.argv[1:]:
    s = json.loads(Path(d, "summary.json").read_text())
    runs.append((Path(d).name, s))


def row(label, fn):
    cells = []
    for _, s in runs:
        try:
            cells.append(fn(s))
        except (KeyError, ZeroDivisionError):
            cells.append("—")
    print(f"| {label} | " + " | ".join(str(c) for c in cells) + " |")


def k(x):
    return f"{x / 1024:.0f}K" if x >= 10240 else f"{x:.0f}"


def pct(s, name, key):
    return s[name][key]


def share(s, hist, key, total):
    t = total(s)
    return f"{100 * s[hist].get(key, 0) / t:.0f}%" if t else "—"


flushes = lambda s: s["disp3dcnt_flushes"].get("flushes_with_polygons", 0)
polys = lambda s: sum(s["polygon_modes"].values())

print("| | " + " | ".join(n for n, _ in runs) + " |")
print("| --- |" + " ---: |" * len(runs))
row("frames", lambda s: s["frames"])
print("| **3D** |" + " |" * len(runs))
row("frames with a 3D flush", lambda s: f"{100 * s['frames_with_flush'] / s['frames']:.0f}%")
row("polygons per flush p50 / p99 / max",
    lambda s: f"{pct(s,'polys_per_flush','p50'):.0f} / {pct(s,'polys_per_flush','p99'):.0f} / {pct(s,'polys_per_flush','max'):.0f}")
row("vertices per flush p99 / max",
    lambda s: f"{pct(s,'verts_per_flush','p99'):.0f} / {pct(s,'verts_per_flush','max'):.0f}")
row("flushes over the 2048/6144 limit", lambda s: s["overflow_flushes"])
row("GX FIFO entries per frame p99", lambda s: k(pct(s, "gx_entries_per_frame", "p99")))
row("pixel area per flush p99 (overdraw incl.)", lambda s: k(pct(s, "area_px_per_flush", "p99")))
row("unique texture bytes per flush p99", lambda s: k(pct(s, "unique_texture_bytes_per_flush", "p99")))
for feat in ["texture", "alpha_blend", "alpha_test", "antialias", "edge_mark", "fog", "fog_alpha_only",
             "toon_highlight_select", "rear_plane_bitmap", "w_buffer", "manual_translucent_sort"]:
    row(f"DISP3DCNT {feat} (share of flushes)", lambda s, f=feat: share(s, "disp3dcnt_flushes", f, flushes))
for mode in ["modulate", "decal", "toon_highlight", "shadow"]:
    row(f"polygon mode {mode}", lambda s, m=mode: share(s, "polygon_modes", m, polys))
for flag in ["translucent", "wireframe", "shadow_mask", "line", "depth_equal", "fog_enable",
             "translucent_depth_write", "one_dot_draw", "far_plane_draw"]:
    row(f"polygons {flag}", lambda s, f=flag: share(s, "polygon_flags", f, polys))
row("texture formats (by area)", lambda s: ", ".join(
    f"{n} {100 * v / sum(s['texture_formats_area_px'].values()):.0f}%"
    for n, v in sorted(s["texture_formats_area_px"].items(), key=lambda kv: -kv[1])))
print("| **CPU and memory** |" + " |" * len(runs))
row("ARM9 busy p50 / p95", lambda s: f"{pct(s,'arm9_busy_pct','p50'):.0f}% / {pct(s,'arm9_busy_pct','p95'):.0f}%")
row("ARM7 busy p50 / p95", lambda s: f"{pct(s,'arm7_busy_pct','p50'):.0f}% / {pct(s,'arm7_busy_pct','p95'):.0f}%")
row("I-cache hit (per-frame mean)", lambda s: f"{s['icache_hit_pct_per_frame']['mean']:.1f}%")
row("D-cache hit (per-frame mean)", lambda s: f"{s['dcache_hit_pct_per_frame']['mean']:.1f}%")
row("ARM9 main-RAM bytes per frame p99", lambda s: k(pct(s, "arm9_main_bus_bytes_per_frame", "p99")))
row("ARM7 main-RAM bytes per frame p99", lambda s: k(pct(s, "arm7_main_bus_bytes_per_frame", "p99")))
row("ARM9 DMA bytes per frame p99", lambda s: k(pct(s, "dma9_bytes_per_frame", "p99")))
row("  of which GX FIFO DMA p99", lambda s: k(pct(s, "gxfifo_dma_bytes_per_frame", "p99")))
row("ARM7 DMA bytes per frame p99", lambda s: k(pct(s, "dma7_bytes_per_frame", "p99")))
print("| **2D** |" + " |" * len(runs))
for e in "AB":
    row(f"engine {e} OBJs on a line max (drawn within budget)",
        lambda s, e=e: f"{pct(s,f'obj{e}_per_line_max','max'):.0f} ({pct(s,f'obj{e}_drawn_per_line_max','max'):.0f})")
    row(f"engine {e} OBJ cycles on a line max: asked / through last on-screen OBJ / spent",
        lambda s, e=e: f"{pct(s,f'obj{e}_demand_cycles_line_max','max'):.0f} / {pct(s,f'obj{e}_need_cycles_line_max','max'):.0f} / {pct(s,f'obj{e}_cycles_line_max','max'):.0f}")
    row(f"engine {e} lines over budget / losing an on-screen OBJ",
        lambda s, e=e: f"{s[f'obj{e}_over_budget_lines']} / {s[f'obj{e}_drop_visible_lines']}")
print("| **VRAM reads (renderer fetches)** |" + " |" * len(runs))
MBs = lambda b: f"{b * 60 / 1e6:.1f}"
row("all banks, MB/s at p50 / p99 frame", lambda s: f"{MBs(pct(s,'vram_bytes_per_frame','p50'))} / {MBs(pct(s,'vram_bytes_per_frame','p99'))}")
row("all banks, worst line bytes p99 / max", lambda s: f"{pct(s,'vram_bytes_line_max','p99'):.0f} / {pct(s,'vram_bytes_line_max','max'):.0f}")
row("8-byte fetches without a cache, per frame p99 (MB/s)", lambda s: f"{k(pct(s, 'vram_seq8_per_frame', 'p99'))} ({MBs(8 * pct(s, 'vram_seq8_per_frame', 'p99'))})")
row("32-byte blocks per line cache, per frame p99", lambda s: k(pct(s, "vram_b32_per_frame", "p99")))
for u, name in [("2da", "2D engine A"), ("2db", "2D engine B"), ("3d", "3D textures"), ("cap", "capture")]:
    row(f"{name}, MB/s p99 (worst line max)",
        lambda s, u=u: f"{MBs(pct(s,f'vram_{u}_bytes_per_frame','p99'))} ({pct(s,f'vram_{u}_bytes_line_max','max'):.0f})")
for b in "ABCDEFGHI":
    row(f"bank {b}, MB/s p99 (worst line max)",
        lambda s, b=b: "—" if not pct(s, f"vram_bank{b}_bytes_per_frame", "max") else
        f"{MBs(pct(s,f'vram_bank{b}_bytes_per_frame','p99'))} ({pct(s,f'vram_bank{b}_bytes_line_max','max'):.0f})")
row("unmapped-space reads (not counted above), bytes per frame p99", lambda s: k(pct(s, "vram_bankx_bytes_per_frame", "p99")))
row("distinct VRAMCNT configurations", lambda s: len(s["vramcnt_frames"]))
row("frames with display capture", lambda s: sum(s["display_capture_frames"].values()))
print("| **Cartridge and sound** |" + " |" * len(runs))
row("cartridge bytes per frame p99 / max",
    lambda s: f"{k(pct(s,'cart_bytes_per_frame','p99'))} / {k(pct(s,'cart_bytes_per_frame','max'))}")
row("cartridge reads, sequential share",
    lambda s: f"{s['cart_reads']}, {100 * s['cart_sequential_reads'] / s['cart_reads']:.0f}%")
row("cartridge read sizes", lambda s: ", ".join(f"{n} B" for n in s["cart_read_sizes"]))
row("sound channels active max", lambda s: f"{pct(s,'snd_channels_max_per_frame','max'):.0f}")
row("sound formats seen", lambda s: ", ".join(s["sound_formats_frames"]))
