#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""Head-to-head benchmark: PDAL filters.reprojection (CPU/PROJ) vs pcax
filter.reproject (GPU op chain).

For each scenario the apparatus:
  1. synthesizes identical LAS input (las_synth),
  2. runs the PDAL pipeline and the pcax pipeline (fp64 and fp32) on it,
  3. measures wall time (best of N reps) and the pcax reproject-stage time,
  4. compares outputs point-by-point against the PDAL output (las_compare):
     max/RMS value drift, point-count mismatches, beyond-tolerance counts,
  5. emits <outdir>/report.md and <outdir>/report.json.

Requires the system `pdal` CLI on PATH and the pcax, las_synth and
las_compare build targets. See compare/README.md.

usage: python3 compare/reproject_bench.py [--points N] [--reps N] [--outdir DIR]
                                          [--scenario NAME ...]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")

SCENARIOS = [
    {
        "name": "utm56s_to_wgs84",
        "title": "UTM 56S -> WGS84 geographic",
        "src_epsg": 32756, "out_srs": "EPSG:4326",
        "bbox": (330000, 6240000, 360000, 6270000), "zrange": (0, 400),
        "in_scale": 0.01, "out_scale": 1e-7,
        # tolerance: quantization of both writers + f32 storage over ~0.3 deg
        "tolerance": 5e-7, "xy_unit": "deg",
    },
    {
        "name": "wgs84_to_utm56s",
        "title": "WGS84 geographic -> UTM 56S",
        "src_epsg": 4326, "out_srs": "EPSG:32756",
        "bbox": (150.6, -34.2, 151.4, -33.6), "zrange": (0, 400),
        "in_scale": 1e-7, "out_scale": 0.01,
        "tolerance": 0.05, "xy_unit": "m",
    },
    {
        "name": "webmerc_to_utm56s",
        "title": "Web Mercator -> UTM 56S",
        "src_epsg": 3857, "out_srs": "EPSG:32756",
        "bbox": (16770000, -4060000, 16860000, -3980000), "zrange": (0, 100),
        "in_scale": 0.01, "out_scale": 0.01,
        "tolerance": 0.05, "xy_unit": "m",
    },
    {
        "name": "nad83_to_conus_albers",
        "title": "NAD83 geographic -> CONUS Albers (aea)",
        "src_epsg": 4269, "out_srs": "EPSG:5070",
        "bbox": (-100.0, 38.0, -96.0, 41.0), "zrange": (0, 2000),
        "in_scale": 1e-7, "out_scale": 0.01,
        "tolerance": 0.1, "xy_unit": "m",
    },
    {
        "name": "wgs84_to_lambert93",
        "title": "WGS84 -> RGF93 Lambert-93 (lcc 2sp)",
        "src_epsg": 4326, "out_srs": "EPSG:2154",
        "bbox": (2.0, 47.5, 4.0, 49.0), "zrange": (0, 1000),
        "in_scale": 1e-7, "out_scale": 0.01,
        "tolerance": 0.1, "xy_unit": "m",
    },
]


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print(f"FAILED: {' '.join(cmd)}\nstdout: {r.stdout}\nstderr: {r.stderr}",
              file=sys.stderr)
        raise SystemExit(1)
    return r


def timed_best(cmd, reps):
    best = None
    for _ in range(reps):
        t0 = time.perf_counter()
        run(cmd)
        dt = time.perf_counter() - t0
        best = dt if best is None else min(best, dt)
    return best


def pcax_stage_ms(stdout):
    """Extract the reproject stage time from pcax -d profiler output."""
    for line in stdout.splitlines():
        if "(filter.reproject)" in line and "ms" in line:
            try:
                return float(line.split("ms")[0].split()[-1])
            except ValueError:
                pass
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points", type=int, default=10_000_000)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--outdir",
                    default=os.path.join(ROOT, "compare", "out", "reproject"))
    ap.add_argument("--scenario", action="append",
                    help="run only the named scenario(s)")
    args = ap.parse_args()

    las_synth = os.path.join(BUILD, "las_synth")
    las_compare = os.path.join(BUILD, "las_compare")
    pcax = os.path.join(BUILD, "pcax")
    pdal = shutil.which("pdal")
    for exe, name in [(las_synth, "las_synth"), (las_compare, "las_compare"),
                      (pcax, "pcax")]:
        if not os.path.exists(exe):
            raise SystemExit(f"{name} not built — run cmake --build build first")
    if not pdal:
        raise SystemExit("pdal not found in PATH")

    os.makedirs(args.outdir, exist_ok=True)
    results = []

    scenarios = [s for s in SCENARIOS
                 if not args.scenario or s["name"] in args.scenario]

    for sc in scenarios:
        name = sc["name"]
        print(f"\n=== {sc['title']} ({args.points:,} points) ===")
        d = os.path.join(args.outdir, name)
        os.makedirs(d, exist_ok=True)
        src = os.path.join(d, "input.las")
        bbox = sc["bbox"]

        run([las_synth, src, str(sc["src_epsg"]),
             str(bbox[0]), str(bbox[1]), str(bbox[2]), str(bbox[3]),
             str(sc["zrange"][0]), str(sc["zrange"][1]),
             str(sc["in_scale"]), str(args.points), "0.01"])

        # --- PDAL pipeline ---------------------------------------------------
        pdal_out = os.path.join(d, "out_pdal.las")
        pdal_json = os.path.join(d, "pdal.json")
        with open(pdal_json, "w") as f:
            json.dump([
                {"type": "readers.las", "filename": src},
                {"type": "filters.reprojection", "out_srs": sc["out_srs"]},
                {"type": "writers.las", "filename": pdal_out,
                 "scale_x": sc["out_scale"], "scale_y": sc["out_scale"],
                 "scale_z": 0.01,
                 "offset_x": "auto", "offset_y": "auto", "offset_z": "auto"},
            ], f)
        t_pdal = timed_best([pdal, "pipeline", pdal_json], args.reps)
        print(f"  pdal:        {t_pdal:8.2f} s")

        # --- pcax pipelines (fp64 + fp32) -------------------------------------
        row = {"name": name, "title": sc["title"], "points": args.points,
               "pdal_wall_s": t_pdal}
        for precision in ("fp64", "fp32"):
            pcax_out = os.path.join(d, f"out_pcax_{precision}.las")
            yaml_path = os.path.join(d, f"pcax_{precision}.yaml")
            with open(yaml_path, "w") as f:
                f.write(f"""version: 1
stages:
  read:
    type: read.las
    filename: "{src}"
  reproject:
    type: filter.reproject
    input: read
    out_srs: "{sc['out_srs']}"
    precision: {precision}
    out_scale: {sc['out_scale']}
    out_scale_z: 0.01
  write:
    type: write.las
    input: reproject
    filename: "{pcax_out}"
""")
            t_pcax = timed_best([pcax, "run", yaml_path], args.reps)
            prof = run([pcax, "run", yaml_path, "-d"])
            stage_ms = pcax_stage_ms(prof.stdout)
            print(f"  pcax {precision}:   {t_pcax:8.2f} s"
                  f"   (reproject stage: {stage_ms or float('nan'):.0f} ms)")

            cmp_json = os.path.join(d, f"compare_{precision}.json")
            cmp = subprocess.run(
                [las_compare, pdal_out, pcax_out,
                 "--tolerance", str(sc["tolerance"]), "--json", cmp_json],
                capture_output=True, text=True)
            print("    " + "\n    ".join(cmp.stdout.strip().splitlines()[1:]))
            with open(cmp_json) as f:
                drift = json.load(f)

            row[f"pcax_{precision}_wall_s"] = t_pcax
            row[f"pcax_{precision}_stage_ms"] = stage_ms
            row[f"drift_{precision}"] = drift
            row[f"match_{precision}"] = (cmp.returncode == 0)

        row["speedup_vs_pdal"] = t_pdal / row["pcax_fp64_wall_s"]
        results.append(row)

    # ---- report --------------------------------------------------------------
    report_json = os.path.join(args.outdir, "report.json")
    with open(report_json, "w") as f:
        json.dump(results, f, indent=2)

    lines = [
        "# pcax vs PDAL reprojection — head-to-head report", "",
        f"Points per scenario: {args.points:,}; wall times are best of "
        f"{args.reps} runs. Drift is measured against the PDAL output "
        "(max over x/y/z, CRS units). `ok` means point counts match and no "
        "point exceeds the scenario tolerance.", "",
        "| scenario | pdal (s) | pcax fp64 (s) | stage (ms) | speedup | "
        "fp64 max drift | fp64 ok | fp32 max drift |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in results:
        d64 = r["drift_fp64"]
        d32 = r["drift_fp32"]
        max64 = max(d64["max_dx"], d64["max_dy"], d64["max_dz"])
        max32 = max(d32["max_dx"], d32["max_dy"], d32["max_dz"])
        lines.append(
            f"| {r['title']} | {r['pdal_wall_s']:.2f} | "
            f"{r['pcax_fp64_wall_s']:.2f} | "
            f"{r['pcax_fp64_stage_ms'] or 0:.0f} | "
            f"{r['speedup_vs_pdal']:.1f}x | {max64:.2e} | "
            f"{'yes' if r['match_fp64'] else 'NO'} | {max32:.2e} |")
    report_md = os.path.join(args.outdir, "report.md")
    with open(report_md, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nreport: {report_md}\n        {report_json}")
    bad = [r["name"] for r in results if not r["match_fp64"]]
    if bad:
        print(f"FP64 MISMATCH in: {', '.join(bad)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
