#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""LAZ decode benchmark: read.las / read.copc alone, and inside a pipeline.

Two modes, both pcax only (no PDAL):

  decode    one process, a reader-only pipeline, per file x threads x window.
            Reports the decode sub-step (`las: LAZ decode[ + bounds]`) and
            ns of worker time per decoded point (ms x threads / points).

  pipeline  N concurrent pcax processes (a tile worker pool on one node), each
            running read(bounds) -> range -> SOR -> DSM -> range -> DTM with
            PCAX_THREADS capped per process. Reports wall time and the summed
            per-stage times, which is how a tile-per-process job sees decode.

Windows are fractions of the file's X extent from its minimum-X edge (a cell
edge through the tile); 0 means no `bounds`.

usage:
  python3 compare/decode_bench.py decode --file a.laz [--file b.laz ...]
      [--pcax build/pcax] [--threads 1,2,4,8,16] [--windows 0,0.25] [--reps 2]
      [--layers all]
  python3 compare/decode_bench.py pipeline --file a.laz [--workers 8]
      [--pcax-threads 2,4,0] [--window 0.25] [--reps 1] [--layers flags]
"""

import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

READ_YAML = """version: 1
stages:
  read:
    type: {reader}
    filename: "{input}"
    threads: {threads}
    layers: "{layers}"
{bounds}"""

PIPELINE_YAML = """version: 1
stages:
  read:
    type: {reader}
    filename: "{input}"
    layers: "{layers}"
{bounds}
  drop_noise:
    type: filter.range
    input: read
    limits: "Classification[0:6],Classification[8:17],Withheld[0:0]"
  denoise:
    type: filter.outlier
    input: drop_noise
    device: gpu
    method: statistical
    k: 8
    multiplier: 3.0
  write_dsm:
    type: writer.gdal_gpu
    input: denoise
    filename: "{out}/dsm.tif"
    resolution: {resolution}
    output_type: max
    data_type: float32
    nodata: -9999
  keep_ground:
    type: filter.range
    input: write_dsm
    limits: "Classification[2:2]"
  write_dtm:
    type: writer.gdal_gpu
    input: keep_ground
    filename: "{out}/dtm.tif"
    resolution: {resolution}
    output_type: min
    data_type: float32
    nodata: -9999
"""


def las_header(path):
    """Point count, point format and XY extent from the LAS header."""
    with open(path, "rb") as f:
        h = f.read(375)
    minor = h[25]
    fmt = h[104] & 0x3F
    count = struct.unpack_from("<I", h, 107)[0]
    if minor >= 4 and len(h) >= 255:
        count14 = struct.unpack_from("<Q", h, 247)[0]
        if count14:
            count = count14
    max_x, min_x, max_y, min_y = struct.unpack_from("<4d", h, 179)
    return {"points": count, "format": fmt, "x": (min_x, max_x), "y": (min_y, max_y)}


def bounds_line(hdr, window):
    if not window:
        return ""
    x0, x1 = hdr["x"]
    y0, y1 = hdr["y"]
    return '    bounds: "([%.6f,%.6f],[%.6f,%.6f])"\n' % (x0, x0 + window * (x1 - x0), y0, y1)


def reader_type(path, copc):
    return "read.copc" if copc and path.endswith(".copc.laz") else "read.las"


def run_pcax(pcax, yaml_path, profile, env=None):
    return subprocess.Popen([pcax, "run", yaml_path, "--profile-json", profile],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
                            env=env)


def wait(proc, what):
    _, err = proc.communicate()
    # exit 3 = empty output, a valid outcome for an empty window
    if proc.returncode not in (0, 3):
        print(f"FAILED ({proc.returncode}): {what}\n{err}", file=sys.stderr)
        raise SystemExit(1)


def load_profile(path):
    with open(path) as f:
        return json.load(f)


def decode_step(profile):
    """(decode ms, whole read stage ms, points out) of the reader stage."""
    st = profile["stages"][0]
    ms = None
    for step in st["steps"]:
        if step["label"].startswith(("las: LAZ decode", "las: copy records",
                                     "las: scan records")):
            ms = step["ms"]
    return ms, st["ms"], st.get("points_out", 0)


def cmd_decode(args):
    tmp = tempfile.mkdtemp(prefix="pcax-decode-bench-")
    rows = []
    try:
        for path in args.file:
            hdr = las_header(path)
            for window in args.windows:
                for threads in args.threads:
                    yaml_path = os.path.join(tmp, "read.yaml")
                    with open(yaml_path, "w") as f:
                        f.write(READ_YAML.format(reader=reader_type(path, args.copc),
                                                 input=path, threads=threads,
                                                 layers=args.layers,
                                                 bounds=bounds_line(hdr, window)))
                    best = None
                    for _ in range(args.reps):
                        prof = os.path.join(tmp, "p.json")
                        wait(run_pcax(args.pcax, yaml_path, prof), path)
                        ms, stage_ms, kept = decode_step(load_profile(prof))
                        if ms is None:   # backend without the sub-step
                            ms = stage_ms
                        if best is None or ms < best[0]:
                            best = (ms, stage_ms, kept)
                    ms, stage_ms, kept = best
                    rows.append({
                        "file": os.path.basename(path), "format": hdr["format"],
                        "points": hdr["points"], "window": window, "threads": threads,
                        "kept": kept, "decode_ms": ms, "read_ms": stage_ms,
                        # worker time per point in the file; with read.copc
                        # bounds fewer points are decoded, so this drops
                        "ns_per_point": ms * 1e6 * max(threads, 1) / hdr["points"]
                                        if threads else None,
                    })
                    r = rows[-1]
                    print("%-44s PF%d  window %-5s threads %-2s  decode %9.1f ms  read %9.1f ms"
                          "  kept %10d  %s" %
                          (r["file"][:44], r["format"], window or "-", threads or "all",
                           ms, stage_ms, kept,
                           "%.0f ns/pt/thread" % r["ns_per_point"] if threads else ""),
                          flush=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rows, f, indent=1)


def cmd_pipeline(args):
    tmp = tempfile.mkdtemp(prefix="pcax-decode-bench-")
    rows = []
    try:
        hdr = las_header(args.file[0])
        for cap in args.pcax_threads:
            best = None
            for _ in range(args.reps):
                procs = []
                t0 = time.perf_counter()
                for w in range(args.workers):
                    path = args.file[w % len(args.file)]
                    out = os.path.join(tmp, f"w{w}")
                    os.makedirs(out, exist_ok=True)
                    yaml_path = os.path.join(out, "pipe.yaml")
                    with open(yaml_path, "w") as f:
                        f.write(PIPELINE_YAML.format(
                            reader=reader_type(path, args.copc), input=path, out=out,
                            layers=args.layers,
                            bounds=bounds_line(las_header(path), args.window),
                            resolution=args.resolution))
                    env = dict(os.environ)
                    env.pop("PCAX_THREADS", None)
                    if cap:
                        env["PCAX_THREADS"] = str(cap)
                    procs.append((run_pcax(args.pcax, yaml_path,
                                           os.path.join(out, "p.json"), env), out))
                for p, _ in procs:
                    wait(p, "pipeline worker")
                wall = time.perf_counter() - t0
                read = total = 0.0
                for _, out in procs:
                    prof = load_profile(os.path.join(out, "p.json"))
                    total += prof["total_ms"]
                    read += prof["stages"][0]["ms"]
                if best is None or wall < best["wall_s"]:
                    best = {"pcax_threads": cap, "workers": args.workers,
                            "wall_s": wall, "sum_total_s": total / 1e3,
                            "sum_read_s": read / 1e3}
            rows.append(best)
            print("workers %d  PCAX_THREADS %-5s wall %7.2f s  sum pcax %7.2f s  "
                  "sum read %7.2f s (%.0f %%)" %
                  (args.workers, cap or "unset", best["wall_s"], best["sum_total_s"],
                   best["sum_read_s"], 100 * best["sum_read_s"] / best["sum_total_s"]),
                  flush=True)
        print("tile: %d points, PF%d, window %s" % (hdr["points"], hdr["format"],
                                                    args.window or "-"))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(rows, f, indent=1)


def int_list(s):
    return [int(v) for v in s.split(",")]


def float_list(s):
    return [float(v) for v in s.split(",")]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    for name in ("decode", "pipeline"):
        p = sub.add_parser(name)
        p.add_argument("--pcax", default=os.path.join(ROOT, "build", "pcax"))
        p.add_argument("--file", action="append", required=True)
        p.add_argument("--copc", action="store_true",
                       help="read *.copc.laz files with read.copc")
        p.add_argument("--layers", default="all",
                       help="reader `layers` (pipeline mode needs at least flags)")
        p.add_argument("--json", help="write the result rows here")
    d = sub.choices["decode"]
    d.add_argument("--threads", type=int_list, default=[1, 2, 4, 8, 16],
                   help="read.las `threads` values; 0 = the default pool")
    d.add_argument("--windows", type=float_list, default=[0.0])
    d.add_argument("--reps", type=int, default=2)
    p = sub.choices["pipeline"]
    p.add_argument("--workers", type=int, default=8)
    p.add_argument("--pcax-threads", type=int_list, default=[2, 4, 0],
                   help="PCAX_THREADS per process; 0 = unset")
    p.add_argument("--window", type=float, default=0.25)
    p.add_argument("--resolution", type=float, default=1.0)
    p.add_argument("--reps", type=int, default=1)
    args = ap.parse_args()
    (cmd_decode if args.mode == "decode" else cmd_pipeline)(args)


if __name__ == "__main__":
    main()
