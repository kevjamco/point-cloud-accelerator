#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""COPC writer parity: pcax write.copc vs PDAL writers.copc on the same input.

    python3 compare/copc_parity.py --input FILE [--out-dir DIR] [--keep]
                                   [--max-node-points N] [--extra-dims ...]

Runs both writers, then checks

  1. point data  — every record (XYZ int32, intensity, returns, flags,
                   classification, scan angle, user data, point source,
                   gps time, RGB/NIR if present, extra bytes) read back
                   through PDAL readers.copc; sorted, must match exactly
                   (only the point ORDER may differ between the two files).
  2. structure   — both files are COPC (pdal info), a bounds window query
                   through readers.copc returns the same point count from
                   both, and a resolution-limited (LOD) read is non-empty.
                   Octree layouts are reported side by side, not compared
                   (PDAL's tree is different by design).
  3. timings     — wall time of each writer (+ pcax -d GPU sections).

Exit 0 on parity, 1 on mismatch. Importable: run_parity(...) returns a
dict used by tests/integration/test_copc.py.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np

PCAX = os.environ.get("PCAX", os.path.join(os.path.dirname(__file__), "..", "build", "pcax"))


def run(cmd, **kw):
    t0 = time.perf_counter()
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    dt = time.perf_counter() - t0
    if r.returncode != 0:
        raise RuntimeError(f"FAIL: {' '.join(cmd)}\n{r.stdout[-3000:]}\n{r.stderr[-3000:]}")
    return r.stdout + r.stderr, dt


def pdal_metadata(path, driver=None):
    cmd = ["pdal", "info", "--metadata", path]
    if driver:
        cmd += ["--driver", driver]
    out, _ = run(cmd)
    return json.loads(out)["metadata"]


def pdal_count(path, driver="readers.copc", **reader_opts):
    """Points a readers.copc query returns. (`pdal info --summary` only
    reads the header, so the query has to go through a real read.)"""
    out_las = path + ".query.las"
    cmd = ["pdal", "translate", "--driver", driver, path, out_las]
    for k, v in reader_opts.items():
        cmd.append(f"--{driver}.{k}={v}")
    run(cmd)
    out, _ = run(["pdal", "info", "--summary", out_las])
    os.remove(out_las)
    return json.loads(out)["summary"]["num_points"]


def write_pcax(pcax, src, dst, max_node_points, extra_dims, debug=True):
    yaml = (
        "version: 1\nstages:\n"
        "  read:\n    type: read.las\n    filename: \"%s\"\n"
        "  copc:\n    type: write.copc\n    input: read\n    filename: \"%s\"\n"
        "    max_node_points: %d\n" % (src, dst, max_node_points)
    )
    if extra_dims:
        yaml += "    extra_dims: \"%s\"\n" % extra_dims
    ypath = dst + ".yaml"
    with open(ypath, "w") as f:
        f.write(yaml)
    cmd = [pcax, "run", ypath]
    if debug:
        cmd.append("-d")
    log, dt = run(cmd)
    return log, dt


def write_pdal(src, dst):
    cmd = ["pdal", "translate", src, dst, "--writers.copc.forward=all"]
    log, dt = run(cmd)
    return log, dt


def to_las(copc, las):
    """readers.copc -> uncompressed LAS (all points, extra dims kept)."""
    run(["pdal", "translate", "--driver", "readers.copc", copc, las,
         "--writers.las.forward=all", "--writers.las.extra_dims=all"])


def load_records(las_path):
    """Structured array of every stored field (raw int32 coords)."""
    import laspy
    f = laspy.read(las_path)
    h = f.header
    names = ["X", "Y", "Z", "intensity", "return_number", "number_of_returns",
             "classification", "scan_angle", "user_data", "point_source_id",
             "gps_time", "synthetic", "key_point", "withheld", "overlap",
             "scanner_channel", "scan_direction_flag", "edge_of_flight_line"]
    if h.point_format.id in (7, 8, 10):
        names += ["red", "green", "blue"]
    if h.point_format.id in (8, 10):
        names.append("nir")
    names += [d.name for d in h.point_format.extra_dimensions]
    cols = []
    dtype = []
    for nm in names:
        a = np.asarray(f[nm])
        if a.dtype == np.bool_:
            a = a.astype(np.uint8)
        cols.append(a)
        dtype.append((nm, a.dtype))
    rec = np.empty(len(f.points), dtype=dtype)
    for nm, a in zip(names, cols):
        rec[nm] = a
    return rec, h


def sort_records(rec):
    keys = [rec[n] for n in reversed(["X", "Y", "Z", "gps_time", "intensity",
                                       "return_number", "point_source_id"])]
    return rec[np.lexsort(keys)]


def compare_points(a, b):
    """Per-field mismatch counts between two sorted record arrays."""
    errs = {}
    if len(a) != len(b):
        errs["count"] = (len(a), len(b))
        return errs
    for nm in a.dtype.names:
        if nm not in b.dtype.names:
            errs[nm] = "missing in b"
            continue
        n = int(np.count_nonzero(a[nm] != b[nm]))
        if n:
            errs[nm] = n
    for nm in b.dtype.names:
        if nm not in a.dtype.names:
            errs[nm] = "missing in a"
    return errs


def read_hierarchy(path):
    """Walk the COPC hierarchy (all pages). Returns list of
    (d, x, y, z, offset, size, count)."""
    with open(path, "rb") as f:
        hdr = f.read(375)
        vlr_count = struct.unpack_from("<I", hdr, 100)[0]
        p = 375
        f.seek(p)
        info = None
        for _ in range(vlr_count):
            vh = f.read(54)
            uid = vh[2:18].split(b"\0")[0].decode()
            rid, ln = struct.unpack_from("<HH", vh, 18)
            data = f.read(ln)
            if uid == "copc" and rid == 1 and info is None:
                info = struct.unpack_from("<5d2Q2d", data, 0)
        root_off, root_size = info[5], info[6]
        entries = []

        def page(off, size):
            f.seek(off)
            buf = f.read(size)
            for k in range(size // 32):
                d, x, y, z, o, s, c = struct.unpack_from("<4iqii", buf, k * 32)
                if c == -1:
                    page(o, s)
                else:
                    entries.append((d, x, y, z, o, s, c))
        page(root_off, root_size)
    return info, entries


def structure_summary(path):
    info, entries = read_hierarchy(path)
    counts = [e[6] for e in entries if e[6] > 0]
    return {
        "nodes": len(entries),
        "empty_nodes": sum(1 for e in entries if e[6] == 0),
        "depth": max(e[0] for e in entries),
        "max_node_points": max(counts) if counts else 0,
        "median_node_points": int(np.median(counts)) if counts else 0,
        "points": sum(counts),
        "halfsize": info[3],
        "spacing": info[4],
        "file_bytes": os.path.getsize(path),
    }


def gpu_sections(log):
    """pcax -d profile lines for the copc stage."""
    out = {}
    for line in log.splitlines():
        m = re.search(r"(copc: [^\d]+?)\s+([\d.]+)\s*ms", line)
        if m:
            out[m.group(1).strip()] = float(m.group(2))
    return out


def run_parity(src, out_dir, pcax=PCAX, max_node_points=100000, extra_dims=None,
               log=print):
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.splitext(os.path.basename(src))[0]
    if base.endswith(".copc"):
        base = base[:-5]
    pcax_copc = os.path.join(out_dir, base + ".pcax.copc.laz")
    pdal_copc = os.path.join(out_dir, base + ".pdal.copc.laz")

    log(f"[copc_parity] input: {src}")
    pcax_log, t_pcax = write_pcax(pcax, src, pcax_copc, max_node_points, extra_dims)
    log(f"[copc_parity] pcax write.copc: {t_pcax:.2f} s")
    _, t_pdal = write_pdal(src, pdal_copc)
    log(f"[copc_parity] pdal writers.copc: {t_pdal:.2f} s")

    result = {"input": src, "pcax": pcax_copc, "pdal": pdal_copc,
              "t_pcax": t_pcax, "t_pdal": t_pdal,
              "gpu_sections": gpu_sections(pcax_log), "errors": []}

    # --- structure -------------------------------------------------------
    for label, path in (("pcax", pcax_copc), ("pdal", pdal_copc)):
        md = pdal_metadata(path)
        if not md.get("copc"):
            result["errors"].append(f"{label}: pdal info reports copc=false")
        s = structure_summary(path)
        s["pdal_count"] = md["count"]
        s["format"] = md["dataformat_id"]
        s["minor_version"] = md["minor_version"]
        result[label + "_structure"] = s
        log(f"[copc_parity] {label}: {s}")
        if s["points"] != md["count"]:
            result["errors"].append(f"{label}: hierarchy sums to {s['points']}, header {md['count']}")

    # --- point data --------------------------------------------------------
    pcax_las = os.path.join(out_dir, base + ".pcax.las")
    pdal_las = os.path.join(out_dir, base + ".pdal.las")
    to_las(pcax_copc, pcax_las)
    to_las(pdal_copc, pdal_las)
    a, ha = load_records(pcax_las)
    b, hb = load_records(pdal_las)
    if (ha.scales != hb.scales).any() or (ha.offsets != hb.offsets).any():
        result["errors"].append(f"scale/offset differ: {ha.scales}/{ha.offsets} vs {hb.scales}/{hb.offsets}")
    a = sort_records(a)
    b = sort_records(b)
    diffs = compare_points(a, b)
    result["point_diffs"] = diffs
    result["points"] = len(a)
    if diffs:
        result["errors"].append(f"point data differs: {diffs}")
    log(f"[copc_parity] point records compared: {len(a)} — "
        f"{'EXACT' if not diffs else diffs}")
    for p in (pcax_las, pdal_las):
        os.remove(p)

    # --- viewer-style queries ---------------------------------------------
    mins, maxs = ha.mins, ha.maxs
    w = [(float(mins[i] + 0.375 * (maxs[i] - mins[i])), float(mins[i] + 0.625 * (maxs[i] - mins[i])))
         for i in range(2)]
    bounds = f"([{w[0][0]!r},{w[0][1]!r}],[{w[1][0]!r},{w[1][1]!r}])"
    ca = pdal_count(pcax_copc, bounds=bounds)
    cb = pdal_count(pdal_copc, bounds=bounds)
    result["window_counts"] = (ca, cb)
    if ca != cb:
        result["errors"].append(f"bounds window: pcax {ca} vs pdal {cb}")
    log(f"[copc_parity] readers.copc bounds window: pcax {ca}, pdal {cb}")
    res = float(maxs[0] - mins[0]) / 64.0
    la = pdal_count(pcax_copc, resolution=res)
    lb = pdal_count(pdal_copc, resolution=res)
    result["lod_counts"] = (la, lb)
    if la == 0 or lb == 0:
        result["errors"].append(f"LOD read empty: pcax {la}, pdal {lb}")
    log(f"[copc_parity] readers.copc resolution={res:.4g}: pcax {la}, pdal {lb}")
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True)
    ap.add_argument("--out-dir", default=None)
    ap.add_argument("--pcax", default=PCAX)
    ap.add_argument("--max-node-points", type=int, default=100000)
    ap.add_argument("--extra-dims", default=None)
    ap.add_argument("--keep", action="store_true", help="keep the output files")
    ap.add_argument("--json", default=None, help="write the result dict here")
    args = ap.parse_args()

    tmp = None
    out_dir = args.out_dir
    if out_dir is None:
        tmp = tempfile.mkdtemp(prefix="copc_parity_")
        out_dir = tmp
    try:
        r = run_parity(args.input, out_dir, args.pcax, args.max_node_points, args.extra_dims)
    finally:
        if tmp and not args.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(r, f, indent=2, default=str)
    print(f"\npcax {r['t_pcax']:.2f} s  |  pdal {r['t_pdal']:.2f} s  |  "
          f"{r['points']} points  |  nodes pcax {r['pcax_structure']['nodes']} "
          f"/ pdal {r['pdal_structure']['nodes']}")
    if r["gpu_sections"]:
        print("gpu sections: " + ", ".join(f"{k} {v:.1f} ms" for k, v in r["gpu_sections"].items()))
    if r["errors"]:
        print("MISMATCH:\n  " + "\n  ".join(r["errors"]))
        sys.exit(1)
    print("PARITY OK")


if __name__ == "__main__":
    main()
