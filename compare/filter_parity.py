#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""Filter parity harness: run a PDAL pipeline and an equivalent pcax pipeline
on the same input, then compare outputs (point count + per-dimension stats).

Usage:
  python3 filter_parity.py --input FILE --name CASE \
      --pdal-filter '{"type":"filters.range","limits":"Classification![7:7]"}' \
      --pcax-stage  'type: filter.range\nlimits: "Classification![7:7]"'

Multiple --pdal-filter/--pcax-stage pairs chain in order.
Exits 0 on parity, 1 on mismatch.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

PCAX = os.environ.get("PCAX", os.path.join(os.path.dirname(__file__), "..", "build", "pcax"))


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print(f"FAIL: {' '.join(cmd)}\n{r.stdout}\n{r.stderr}", file=sys.stderr)
        sys.exit(2)
    return r.stdout


def pdal_stats(path):
    out = run(["pdal", "info", "--stats", path])
    d = json.loads(out)
    stats = {}
    for s in d["stats"]["statistic"]:
        stats[s["name"]] = (s.get("count"), s.get("minimum"), s.get("maximum"),
                            s.get("average"))
    return stats


def compare(a, b, float_tol=1e-9, skip=()):
    """Compare stats dicts; returns list of mismatch strings."""
    errs = []
    for name in sorted(set(a) | set(b)):
        if name in skip:
            continue
        if name not in a or name not in b:
            errs.append(f"dimension {name} missing from one output")
            continue
        ca, cb = a[name], b[name]
        if ca[0] != cb[0]:
            errs.append(f"{name}: count {ca[0]} != {cb[0]}")
            continue
        for label, va, vb in zip(("min", "max", "avg"), ca[1:], cb[1:]):
            if va is None and vb is None:
                continue
            if va is None or vb is None:
                errs.append(f"{name}.{label}: {va} != {vb}")
                continue
            denom = max(abs(va), abs(vb), 1.0)
            if abs(va - vb) / denom > float_tol:
                errs.append(f"{name}.{label}: {va} != {vb}")
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--pdal-filter", action="append", required=True,
                    help="JSON object for one PDAL filter stage")
    ap.add_argument("--pcax-stage", action="append", required=True,
                    help="YAML body (without name/input) for one pcax stage; "
                         "use \\n for newlines")
    ap.add_argument("--float-tol", type=float, default=1e-9)
    ap.add_argument("--keep", action="store_true", help="keep temp outputs")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix=f"parity_{args.name}_")
    pdal_out = os.path.join(tmp, "pdal.laz")
    pcax_out = os.path.join(tmp, "pcax.laz")

    # PDAL pipeline
    writer = {"type": "writers.las", "filename": pdal_out, "forward": "all"}
    pipeline = [args.input] + [json.loads(f) for f in args.pdal_filter] + [writer]
    pdal_json = os.path.join(tmp, "pdal.json")
    with open(pdal_json, "w") as f:
        json.dump({"pipeline": pipeline}, f)
    run(["pdal", "pipeline", pdal_json])

    # pcax pipeline
    stages = [f"  read:\n    type: read.las\n    filename: \"{args.input}\""]
    prev = "read"
    for i, body in enumerate(args.pcax_stage):
        name = f"f{i}"
        indented = "\n".join("    " + line for line in body.split("\\n"))
        stages.append(f"  {name}:\n{indented}\n    input: {prev}")
        prev = name
    stages.append(f"  write:\n    type: write.las\n    input: {prev}\n"
                  f"    filename: \"{pcax_out}\"")
    pcax_yaml = os.path.join(tmp, "pcax.yaml")
    with open(pcax_yaml, "w") as f:
        f.write("version: 1\n\nstages:\n" + "\n".join(stages) + "\n")
    run([PCAX, "run", pcax_yaml])

    sa, sb = pdal_stats(pdal_out), pdal_stats(pcax_out)
    errs = compare(sa, sb, args.float_tol)
    npts = sa.get("X", (None,))[0]
    if errs:
        print(f"[{args.name}] MISMATCH ({npts} pts PDAL):")
        for e in errs:
            print(f"  {e}")
        print(f"  outputs kept in {tmp}")
        sys.exit(1)
    print(f"[{args.name}] PARITY OK — {npts} points, all dim stats match")
    if not args.keep:
        for p in (pdal_out, pcax_out, pdal_json, pcax_yaml):
            os.unlink(p)
        os.rmdir(tmp)


if __name__ == "__main__":
    main()
