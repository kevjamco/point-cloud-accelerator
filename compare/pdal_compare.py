#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""pcax vs PDAL head-to-head: run twin pipelines, benchmark, compare outputs.

Runs a pcax YAML pipeline and its PDAL JSON twin back to back on the same
input (default twins: compare/pipelines/northernca_dsm_dtm.{yaml,json}),
sampling CPU / RSS / GPU while each runs, then compares every output
three ways:

  1. `pdal info` dimension statistics on points.laz   (functional equivalence)
  2. cell-by-cell raster diff on dsm.tif / dtm.tif    (via compare_geotiffs.py)
  3. sha256 / byte-level comparison of every artefact

On (3): a cross-tool byte match on LAZ is not achievable and is not the
point -- the two writers differ in chunk layout, software id and VLR set.
The byte check earns its keep as a DETERMINISM test: with --reps > 1 each
tool is compared against its own previous run, where any difference is a
real bug. The cross-tool byte line is reported as information.

Requires the system `pdal` CLI on PATH (or --pdal) and a built pcax
(--pcax, default build/pcax). See compare/README.md.

Usage:
    python3 compare/pdal_compare.py --input tile.laz          # 1 rep each
    python3 compare/pdal_compare.py --input tile.laz --reps 3
    python3 compare/pdal_compare.py --input tile.laz --limit 5000000
    python3 compare/pdal_compare.py --input tile.laz --skip-pdal
"""

import argparse
import copy
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_INPUT = os.path.join(HERE, "data", "USGS_LPC_CA_NorthernCA_B22_10TEL7280.laz")
DEFAULT_PCAX_PIPELINE = os.path.join(HERE, "pipelines", "northernca_dsm_dtm.yaml")
DEFAULT_PDAL_PIPELINE = os.path.join(HERE, "pipelines", "northernca_dsm_dtm.json")
COMPARE_GEOTIFFS = os.path.join(HERE, "compare_geotiffs.py")
POINT_DELTA = os.path.join(HERE, "point_delta.py")

ARTEFACTS = ["points.laz", "dsm.tif", "dtm.tif"]
STAT_DIMS = "X,Y,Z,Intensity,ReturnNumber,NumberOfReturns,Classification,GpsTime,ScanAngleRank,PointSourceId"


# --------------------------------------------------------------------------
# resource sampling
# --------------------------------------------------------------------------

class Sampler(threading.Thread):
    """Polls the child process tree for CPU/RSS and the GPU for util/memory.

    RSS is summed over the whole tree each tick and the peak kept. GPU memory
    is attributed per-process via `nvidia-smi --query-compute-apps`, so a
    neighbouring process on the same card does not inflate the number; GPU
    utilisation is device-wide (nvidia-smi exposes no per-process split) and
    is reported as such.
    """

    def __init__(self, pid, interval=0.1, gpu_every=5):
        super().__init__(daemon=True)
        self.pid = pid
        self.interval = interval
        # nvidia-smi costs ~50-100 ms per invocation, so poll the GPU once
        # every `gpu_every` RSS ticks rather than perturbing the measured run
        self.gpu_every = gpu_every
        self.stop_flag = threading.Event()
        self.peak_rss_mib = 0.0
        self.peak_gpu_mem_mib = 0.0
        self.gpu_utils = []
        self.samples = 0
        self.gpu_samples = 0
        self.gpu_available = shutil.which("nvidia-smi") is not None

    def _tree(self):
        pids, frontier = set(), [self.pid]
        while frontier:
            p = frontier.pop()
            if p in pids:
                continue
            pids.add(p)
            try:
                with open(f"/proc/{p}/task/{p}/children") as f:
                    frontier.extend(int(c) for c in f.read().split())
            except (OSError, ValueError):
                pass
        return pids

    @staticmethod
    def _rss_kib(pid):
        try:
            with open(f"/proc/{pid}/statm") as f:
                # field 2 = resident pages
                return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE") // 1024
        except (OSError, ValueError, IndexError):
            return 0

    def _gpu(self, pids):
        if not self.gpu_available:
            return
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-compute-apps=pid,used_gpu_memory",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5).stdout
            mine = 0.0
            for line in out.splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) == 2 and parts[0].isdigit() and int(parts[0]) in pids:
                    mine += float(parts[1])
            self.peak_gpu_mem_mib = max(self.peak_gpu_mem_mib, mine)

            util = subprocess.run(
                ["nvidia-smi", "--query-gpu=utilization.gpu",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5).stdout.strip()
            if util:
                self.gpu_utils.append(float(util.splitlines()[0]))
        except (subprocess.SubprocessError, ValueError, OSError):
            pass

    def run(self):
        while not self.stop_flag.is_set():
            pids = self._tree()
            if not pids:
                break
            rss = sum(self._rss_kib(p) for p in pids) / 1024.0
            self.peak_rss_mib = max(self.peak_rss_mib, rss)
            if self.samples % self.gpu_every == 0:
                self._gpu(pids)
                self.gpu_samples += 1
            self.samples += 1
            self.stop_flag.wait(self.interval)

    def result(self):
        return {
            "peak_rss_mib": round(self.peak_rss_mib, 1),
            "peak_gpu_mem_mib": round(self.peak_gpu_mem_mib, 1) if self.gpu_available else None,
            "gpu_util_mean_pct": round(statistics.fmean(self.gpu_utils), 1) if self.gpu_utils else None,
            "gpu_util_max_pct": round(max(self.gpu_utils), 1) if self.gpu_utils else None,
            "rss_samples": self.samples,
            "gpu_samples": self.gpu_samples,
        }


def run_measured(cmd, cwd, label, log_path):
    """Run cmd, sampling resources; return a metrics dict."""
    print(f"  running {label}: {' '.join(cmd)}")
    before = os.times()
    t0 = time.monotonic()
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, cwd=cwd, stdout=log,
                                stderr=subprocess.STDOUT)
        sampler = Sampler(proc.pid)
        sampler.start()
        rc = proc.wait()
        sampler.stop_flag.set()
        sampler.join(timeout=2)
    wall = time.monotonic() - t0
    after = os.times()

    metrics = {
        "label": label,
        "cmd": cmd,
        "returncode": rc,
        "wall_s": round(wall, 3),
        # children_user/system deltas cover the whole subprocess tree
        "cpu_user_s": round(after.children_user - before.children_user, 3),
        "cpu_sys_s": round(after.children_system - before.children_system, 3),
        "log": os.path.relpath(log_path, HERE),
    }
    cpu = metrics["cpu_user_s"] + metrics["cpu_sys_s"]
    metrics["cpu_total_s"] = round(cpu, 3)
    metrics["cpu_efficiency_x"] = round(cpu / wall, 2) if wall > 0 else None
    metrics.update(sampler.result())
    if rc != 0:
        print(f"  !! {label} exited {rc} -- see {log_path}")
    return metrics


# --------------------------------------------------------------------------
# pcax profiler parsing
# --------------------------------------------------------------------------

_STAGE_RE = re.compile(r"^├─ (\w+) \(([\w.]+)\)\s+([\d.]+) ms")
_TOTAL_RE = re.compile(r"^└─ total\s+([\d.]+) ms")


_RAM_RE = re.compile(r"RAM:\s*([\d.]+) MB")
_GPUMEM_RE = re.compile(r"GPU:\s*([\d.]+) MB")


def parse_pcax_profile(path):
    stages, total = [], None
    peak_ram, peak_gpu = 0.0, 0.0
    for line in open(path, errors="replace"):
        m = _RAM_RE.search(line)
        if m:
            peak_ram = max(peak_ram, float(m.group(1)))
        m = _GPUMEM_RE.search(line)
        if m:
            peak_gpu = max(peak_gpu, float(m.group(1)))
        m = _STAGE_RE.match(line)
        if m:
            stages.append({"stage": m.group(1), "type": m.group(2),
                           "ms": float(m.group(3))})
            continue
        m = _TOTAL_RE.match(line)
        if m:
            total = float(m.group(1))
    return {"stages": stages, "total_ms": total,
            "profiler_peak_ram_mib": round(peak_ram, 1) or None,
            "profiler_peak_gpu_mib": round(peak_gpu, 1) or None}


def pcax_reproject_backend(path):
    """Which path filter.reproject actually took -- the benchmark is void if
    it silently fell back to host PROJ."""
    for line in open(path, errors="replace"):
        if "reproject: running on the GPU op-chain" in line:
            return line.strip().split("reproject:", 1)[1].strip()
        if "reproject: NOT using the GPU op-chain" in line:
            return "CPU FALLBACK -- " + line.strip().split("Reason:", 1)[-1].strip()
    return "unknown (no reproject log line found)"


# --------------------------------------------------------------------------
# comparison
# --------------------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def first_diff_offset(a, b):
    with open(a, "rb") as fa, open(b, "rb") as fb:
        off = 0
        while True:
            ba, bb = fa.read(1 << 20), fb.read(1 << 20)
            if not ba and not bb:
                return None
            if ba != bb:
                for i in range(min(len(ba), len(bb))):
                    if ba[i] != bb[i]:
                        return off + i
                return off + min(len(ba), len(bb))
            off += len(ba)


def byte_compare(a, b):
    if not (os.path.exists(a) and os.path.exists(b)):
        return {"status": "missing"}
    sa, sb = os.path.getsize(a), os.path.getsize(b)
    ha, hb = sha256(a), sha256(b)
    out = {"size_a": sa, "size_b": sb, "sha256_a": ha, "sha256_b": hb,
           "identical": ha == hb}
    if not out["identical"]:
        out["size_delta"] = sb - sa
        out["first_diff_offset"] = first_diff_offset(a, b)
    return out


def pdal_stats(path, pdal_bin):
    r = subprocess.run([pdal_bin, "info", "--stats", "--dimensions", STAT_DIMS, path],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip()[:400]
    d = json.loads(r.stdout)
    stats = {}
    for s in d["stats"]["statistic"]:
        stats[s["name"]] = {k: s[k] for k in
                            ("count", "minimum", "maximum", "average", "stddev")
                            if k in s}
    return stats, None


def compare_stats(a, b, rtol=1e-6, atol=1e-6):
    rows = []
    for dim in sorted(set(a) | set(b)):
        sa, sb = a.get(dim), b.get(dim)
        if sa is None or sb is None:
            rows.append({"dim": dim, "status": "missing on " +
                         ("pcax" if sa is None else "pdal")})
            continue
        row = {"dim": dim, "status": "match"}
        for key in ("count", "minimum", "maximum", "average", "stddev"):
            va, vb = sa.get(key), sb.get(key)
            if va is None or vb is None:
                continue
            row[key + "_pcax"], row[key + "_pdal"] = va, vb
            delta = vb - va
            row[key + "_delta"] = delta
            tol = atol + rtol * max(abs(va), abs(vb))
            if abs(delta) > tol:
                row["status"] = "DIFFERS"
        rows.append(row)
    return rows


def compare_points(pcax_dir, pdal_dir, out_json, tolerance):
    """Exact point-set delta: which points each tool kept, and how far the
    shared ones moved. This is what `pdal info` statistics cannot answer --
    matching moments do not prove matching point sets."""
    a = os.path.join(pcax_dir, "points.laz")
    b = os.path.join(pdal_dir, "points.laz")
    if not (os.path.exists(a) and os.path.exists(b)):
        return {"status": "missing"}
    r = subprocess.run([sys.executable, POINT_DELTA, a, b,
                        "--label-a", "pcax", "--label-b", "pdal",
                        "--tolerance", str(tolerance),
                        "--json", out_json, "--quiet"],
                       capture_output=True, text=True)
    payload = {}
    if os.path.exists(out_json):
        try:
            payload = json.load(open(out_json))
        except json.JSONDecodeError:
            pass
    return {"exit": r.returncode, "identical": r.returncode == 0,
            "report": payload, "text": r.stdout[-6000:],
            "stderr": r.stderr[-1000:]}


def compare_rasters(pcax_dir, pdal_dir, name, out_json):
    ref, cand = os.path.join(pcax_dir, name), os.path.join(pdal_dir, name)
    if not (os.path.exists(ref) and os.path.exists(cand)):
        return {"status": "missing"}
    # pdal is the reference; pcax is the candidate under test
    r = subprocess.run([sys.executable, COMPARE_GEOTIFFS, cand, ref,
                        "--json", out_json, "--atol", "1e-3"],
                       capture_output=True, text=True)
    payload = {}
    if os.path.exists(out_json):
        try:
            payload = json.load(open(out_json))
        except json.JSONDecodeError:
            pass
    return {"exit": r.returncode, "identical": r.returncode == 0,
            "report": payload, "text": r.stdout[-4000:]}


# --------------------------------------------------------------------------
# pipeline preparation
# --------------------------------------------------------------------------

def prepare_pdal_pipeline(src, dst, input_path, out_dir, limit, threads=None):
    spec = json.load(open(src))
    stages = spec["pipeline"]
    for st in stages:
        if st.get("tag") == "read":
            st["filename"] = input_path
            # readers.las `threads` (default 7) is the ONLY threading option
            # anywhere in this pipeline: it sizes the pool that decompresses
            # LAZ chunks. writers.las has no threads option (its compressor is
            # serial), filters.outlier has none, and PDAL uses OpenMP only in
            # filters.csf -- so OMP_NUM_THREADS does nothing here.
            if threads:
                st["threads"] = threads
        if st.get("type", "").startswith("writers."):
            st["filename"] = os.path.join(out_dir, os.path.basename(st["filename"]))
    if limit:
        head = {"tag": "limit", "type": "filters.head",
                "inputs": ["read"], "count": limit}
        for st in stages:
            if st.get("inputs") == ["read"] and st.get("tag") != "limit":
                st["inputs"] = ["limit"]
        stages.insert(1, head)
    json.dump(spec, open(dst, "w"), indent=2)


def prepare_pcax_pipeline(src, dst, limit):
    text = open(src).read()
    if limit:
        # insert filter.head immediately after read and rewire the first
        # live consumer of `read` (keep_classes; drop_origin is disabled)
        head = (f"  limit:\n    type: filter.head\n    input: read\n"
                f"    count: {limit}\n\n")
        text = text.replace("  keep_classes:\n", head + "  keep_classes:\n", 1)
        text = text.replace("    input: read\n    limits: \"Classification[0:6]",
                            "    input: limit\n    limits: \"Classification[0:6]")
    open(dst, "w").write(text)


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def fmt_metrics_table(runs):
    hdr = ("| tool | wall (s) | CPU total (s) | CPU eff | peak RSS (MiB) | "
           "peak GPU mem (MiB) | GPU util mean/max (%) |")
    sep = "|---|---|---|---|---|---|---|"
    lines = [hdr, sep]
    for m in runs:
        gm = m.get("peak_gpu_mem_mib")
        um, ux = m.get("gpu_util_mean_pct"), m.get("gpu_util_max_pct")
        lines.append(
            f"| {m['label']} | {m['wall_s']:.2f} | {m['cpu_total_s']:.2f} | "
            f"{m['cpu_efficiency_x']}x | {m['peak_rss_mib']:.0f} | "
            f"{'-' if gm is None else f'{gm:.0f}'} | "
            f"{'-' if um is None else f'{um:.0f} / {ux:.0f}'} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=DEFAULT_INPUT,
                    help="source LAS/LAZ (default: the NorthernCA tile "
                         "fetched by compare/download.sh)")
    ap.add_argument("--pipeline", default=DEFAULT_PCAX_PIPELINE,
                    help="pcax YAML pipeline (uses vars input/out_dir/"
                         "sor_radius/precision)")
    ap.add_argument("--pdal-pipeline", default=DEFAULT_PDAL_PIPELINE,
                    help="PDAL JSON twin of --pipeline (reader tagged 'read')")
    ap.add_argument("--outdir", default=os.path.join(HERE, "out"),
                    help="run artefacts + report (default compare/out/, "
                         "gitignored)")
    ap.add_argument("--reps", type=int, default=1,
                    help="runs per tool; best wall time reported, "
                         "outputs checked for run-to-run determinism")
    ap.add_argument("--limit", type=int, default=0,
                    help="cap to the first N points on BOTH sides "
                         "(inserts filter.head / filters.head)")
    ap.add_argument("--sor-radius", default="0",
                    help="pcax filter.outlier search_radius; 0 = unbounded "
                         "exact kNN (PDAL parity). >0 has no PDAL equivalent")
    ap.add_argument("--precision", default="fp64", choices=["fp64", "fp32"])
    ap.add_argument("--pcax", default=os.path.join(ROOT, "build", "pcax"))
    ap.add_argument("--pdal", default="pdal")
    ap.add_argument("--pdal-threads", type=int, default=0,
                    help="readers.las thread pool size (PDAL default 7). "
                         "The only in-pipeline threading knob PDAL has here")
    ap.add_argument("--xyz-tolerance", type=float, default=0.02,
                    help="point_delta agreement threshold in metres "
                         "(default 0.02 = two 1 cm quantisation steps)")
    ap.add_argument("--compare-only", action="store_true",
                    help="skip both runs; just compare whatever is already "
                         "in --outdir (and report timings from a prior JSON)")
    ap.add_argument("--skip-pdal", action="store_true")
    ap.add_argument("--skip-pcax", action="store_true")
    ap.add_argument("--report", default=None,
                    help="markdown report path (default <outdir>/report.md; "
                         "a .json twin is written beside it)")
    args = ap.parse_args()
    if args.report is None:
        args.report = os.path.join(args.outdir, "report.md")

    input_path = os.path.abspath(args.input)
    if not os.path.exists(input_path):
        sys.exit(f"input not found: {input_path}\n"
                 f"(fetch the default tile with compare/download.sh, or pass --input)")
    if not shutil.which(args.pdal) and not args.skip_pdal:
        sys.exit(f"pdal not found ({args.pdal}); install PDAL or pass --skip-pdal")

    pcax_dir = os.path.join(args.outdir, "pcax")
    pdal_dir = os.path.join(args.outdir, "pdal")
    log_dir = os.path.join(args.outdir, "logs")
    for d in (pcax_dir, pdal_dir, log_dir):
        os.makedirs(d, exist_ok=True)

    gen = os.path.join(args.outdir, "generated")
    os.makedirs(gen, exist_ok=True)
    pcax_yaml = os.path.join(gen, "pipeline_pcax.yaml")
    pdal_json = os.path.join(gen, "pipeline_pdal.json")
    prepare_pcax_pipeline(args.pipeline, pcax_yaml, args.limit)
    prepare_pdal_pipeline(args.pdal_pipeline, pdal_json,
                          input_path, pdal_dir, args.limit, args.pdal_threads)

    results = {"input": input_path,
               "input_size_bytes": os.path.getsize(input_path),
               "limit": args.limit, "sor_radius": args.sor_radius,
               "pdal_reader_threads": args.pdal_threads or 7,
               "precision": args.precision, "reps": args.reps,
               "host": {}, "runs": {"pcax": [], "pdal": []},
               "determinism": {}, "comparison": {}}

    # host / device inventory, so a report is interpretable months later
    try:
        results["host"]["cpu"] = subprocess.run(
            ["bash", "-lc", "lscpu | sed -n 's/^Model name:[[:space:]]*//p'"],
            capture_output=True, text=True).stdout.strip()
        results["host"]["cores"] = os.cpu_count()
        results["host"]["ram_gib"] = round(
            os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 2**30, 1)
        if shutil.which("nvidia-smi"):
            results["host"]["gpu"] = subprocess.run(
                ["nvidia-smi", "--query-gpu=name,memory.total,driver_version",
                 "--format=csv,noheader"], capture_output=True, text=True).stdout.strip()
    except OSError:
        pass

    hashes = {"pcax": [], "pdal": []}

    if args.compare_only:
        args.reps = 0
        # reuse the timings from the previous run so --compare-only still
        # emits a complete report (useful after extending the comparison code)
        prior_path = os.path.splitext(args.report)[0] + ".json"
        if os.path.exists(prior_path):
            try:
                prior = json.load(open(prior_path))
                results["runs"] = prior.get("runs", results["runs"])
                results["determinism"] = prior.get("determinism", {})
                results["reps"] = prior.get("reps", 0)
                results["timings_reused_from"] = prior_path
                print(f"  reusing timings from {prior_path}")
            except json.JSONDecodeError:
                pass

    for rep in range(args.reps):
        if not args.skip_pcax:
            print(f"[rep {rep + 1}/{args.reps}] pcax")
            log = os.path.join(log_dir, f"pcax_rep{rep}.log")
            m = run_measured(
                [args.pcax, "run", pcax_yaml, "-d",
                 "-v", f"input={input_path}",
                 "-v", f"out_dir={pcax_dir}",
                 "-v", f"sor_radius={args.sor_radius}",
                 "-v", f"precision={args.precision}"],
                HERE, "pcax", log)
            m["profile"] = parse_pcax_profile(log)
            m["reproject_backend"] = pcax_reproject_backend(log)
            # pcax's own profiler instruments every stage, so prefer its
            # peaks over whatever the 2 Hz nvidia-smi sampler happened to see
            prof_gpu = m["profile"].get("profiler_peak_gpu_mib")
            if prof_gpu:
                m["peak_gpu_mem_mib"] = max(m.get("peak_gpu_mem_mib") or 0.0,
                                            prof_gpu)
                m["peak_gpu_source"] = "pcax -d profiler"
            results["runs"]["pcax"].append(m)
            hashes["pcax"].append({a: sha256(os.path.join(pcax_dir, a))
                                   for a in ARTEFACTS
                                   if os.path.exists(os.path.join(pcax_dir, a))})

        if not args.skip_pdal:
            print(f"[rep {rep + 1}/{args.reps}] pdal")
            log = os.path.join(log_dir, f"pdal_rep{rep}.log")
            m = run_measured([args.pdal, "pipeline", pdal_json], HERE, "pdal", log)
            results["runs"]["pdal"].append(m)
            hashes["pdal"].append({a: sha256(os.path.join(pdal_dir, a))
                                   for a in ARTEFACTS
                                   if os.path.exists(os.path.join(pdal_dir, a))})

    # run-to-run determinism (this is what byte equality is genuinely for)
    for tool, hs in hashes.items():
        if len(hs) < 2:
            results["determinism"][tool] = "not tested (needs --reps > 1)"
            continue
        unstable = [a for a in ARTEFACTS
                    if len({h.get(a) for h in hs}) > 1]
        results["determinism"][tool] = ("deterministic" if not unstable
                                        else f"NON-DETERMINISTIC: {unstable}")

    # cross-tool comparison
    if (not args.skip_pcax and not args.skip_pdal) or args.compare_only:
        print("comparing outputs ...")
        results["comparison"]["bytes"] = {
            a: byte_compare(os.path.join(pcax_dir, a), os.path.join(pdal_dir, a))
            for a in ARTEFACTS}

        pa, ea = pdal_stats(os.path.join(pcax_dir, "points.laz"), args.pdal)
        pb, eb = pdal_stats(os.path.join(pdal_dir, "points.laz"), args.pdal)
        if pa and pb:
            results["comparison"]["point_stats"] = compare_stats(pa, pb)
        else:
            results["comparison"]["point_stats_error"] = ea or eb

        results["comparison"]["point_delta"] = compare_points(
            pcax_dir, pdal_dir,
            os.path.join(args.outdir, "point_delta.json"), args.xyz_tolerance)

        results["comparison"]["rasters"] = {
            name: compare_rasters(pcax_dir, pdal_dir, name,
                                  os.path.join(args.outdir, f"{name}.diff.json"))
            for name in ("dsm.tif", "dtm.tif")}

    json_path = os.path.splitext(args.report)[0] + ".json"
    os.makedirs(os.path.dirname(os.path.abspath(args.report)), exist_ok=True)
    json.dump(results, open(json_path, "w"), indent=2)
    write_report(results, args, args.report)
    print(f"\nreport: {args.report}\n        {json_path}")

    ok = all(m["returncode"] == 0
             for runs in results["runs"].values() for m in runs)
    return 0 if ok else 1


def write_report(r, args, path):
    L = []
    A = L.append
    A("# pcax vs PDAL — head-to-head\n")
    A(f"- pipelines: `{os.path.basename(args.pipeline)}` / "
      f"`{os.path.basename(args.pdal_pipeline)}`")
    h = r["host"]
    A(f"- input: `{os.path.basename(r['input'])}` "
      f"({r['input_size_bytes'] / 2**20:.0f} MiB)")
    A(f"- point limit: {r['limit'] or 'none (full tile)'}")
    A(f"- pcax SOR search_radius: {r['sor_radius']} "
      f"({'unbounded exact kNN — PDAL parity' if r['sor_radius'] in ('0', 0) else 'bounded — pcax-native, NO PDAL equivalent'})")
    A(f"- pcax precision: {r['precision']}")
    A(f"- reps: {r['reps']}")
    if r.get("timings_reused_from"):
        A(f"- timings reused from `{os.path.basename(r['timings_reused_from'])}` "
          f"(comparison re-run without re-executing the pipelines)")
    A(f"- PDAL `readers.las` threads: {r.get('pdal_reader_threads', 7)} "
      f"(PDAL's only in-pipeline threading knob; `writers.las` and "
      f"`filters.outlier` have none)")
    if h:
        A(f"- host: {h.get('cpu', '?')} ({h.get('cores')} cores, "
          f"{h.get('ram_gib')} GiB RAM)")
        if h.get("gpu"):
            A(f"- gpu: {h['gpu']}")
    A("")

    A("## Resource benchmark\n")
    best = []
    for tool in ("pcax", "pdal"):
        runs = r["runs"][tool]
        if not runs:
            continue
        b = min(runs, key=lambda m: m["wall_s"])
        best.append(b)
    if best:
        A(fmt_metrics_table(best))
        A("")
        A("`CPU eff` is CPU-seconds per wall-second — a proxy for thread "
          "parallelism (1.0x = single-threaded). Peak RSS is the sum over the "
          "process tree, sampled at 10 Hz.")
        srcs = {m["label"]: m.get("peak_gpu_source", "nvidia-smi sampler (2 Hz)")
                for m in best}
        A("Peak GPU memory source — " +
          "; ".join(f"{k}: {v}" for k, v in srcs.items()) +
          ". The nvidia-smi sampler is attributed to our pids via "
          "`--query-compute-apps` but polls at 2 Hz, so it can miss a short "
          "allocation spike; pcax's own `-d` profiler instruments every stage "
          "and is exact. GPU utilisation is device-wide (nvidia-smi exposes "
          "no per-process split) and is a floor, not a duty cycle.")
        A("")
    if len(best) == 2:
        pc, pd = best[0], best[1]
        if pc["wall_s"] > 0:
            A(f"**Wall-clock speedup: {pd['wall_s'] / pc['wall_s']:.2f}x** "
              f"(pdal {pd['wall_s']:.2f} s -> pcax {pc['wall_s']:.2f} s)")
            A(f"**CPU-seconds ratio: {pd['cpu_total_s'] / max(pc['cpu_total_s'], 1e-9):.2f}x** "
              f"— total processor work, the fairer energy proxy")
            A("")

    for tool in ("pcax", "pdal"):
        runs = r["runs"][tool]
        if len(runs) > 1:
            walls = [m["wall_s"] for m in runs]
            A(f"- {tool} wall times across reps: "
              f"{', '.join(f'{w:.2f}' for w in walls)} s "
              f"(min {min(walls):.2f}, median {statistics.median(walls):.2f})")
    A("")

    pcax_runs = r["runs"]["pcax"]
    if pcax_runs:
        A(f"**pcax reproject backend:** {pcax_runs[0]['reproject_backend']}")
        A("")
        prof = min(pcax_runs, key=lambda m: m["wall_s"])["profile"]
        if prof["stages"]:
            A("### pcax per-stage profile (best run)\n")
            A("| stage | type | ms | % |")
            A("|---|---|---|---|")
            tot = prof["total_ms"] or sum(s["ms"] for s in prof["stages"])
            for s in prof["stages"]:
                A(f"| {s['stage']} | `{s['type']}` | {s['ms']:.1f} | "
                  f"{100 * s['ms'] / tot:.1f}% |")
            A(f"| **total** | | **{tot:.1f}** | |")
            A("")

    A("## Determinism (byte-identical across reps)\n")
    for tool, verdict in r["determinism"].items():
        A(f"- **{tool}**: {verdict}")
    A("")

    comp = r.get("comparison", {})
    if comp:
        A("## Cross-tool byte comparison\n")
        A("| artefact | identical | pcax bytes | pdal bytes | delta | first diff @ |")
        A("|---|---|---|---|---|---|")
        for a, c in comp.get("bytes", {}).items():
            if c.get("status") == "missing":
                A(f"| {a} | missing | | | | |")
                continue
            A(f"| {a} | {'YES' if c['identical'] else 'no'} | {c['size_a']:,} | "
              f"{c['size_b']:,} | {c.get('size_delta', 0):+,} | "
              f"{c.get('first_diff_offset', '-')} |")
        A("")
        A("A byte difference on `points.laz` is expected and not a defect: "
          "the two writers differ in LAZ chunk layout, software id and VLR "
          "set. Functional equivalence is decided by the two sections below.")
        A("")

        rows = comp.get("point_stats")
        if rows:
            A("## points.laz — `pdal info --stats` comparison\n")
            A("| dim | status | count (pcax/pdal) | min Δ | max Δ | mean Δ | stddev Δ |")
            A("|---|---|---|---|---|---|---|")
            for row in rows:
                if "count_pcax" not in row:
                    A(f"| {row['dim']} | {row['status']} | | | | | |")
                    continue
                A(f"| {row['dim']} | {row['status']} | "
                  f"{row['count_pcax']:,} / {row['count_pdal']:,} | "
                  f"{row.get('minimum_delta', 0):.6g} | "
                  f"{row.get('maximum_delta', 0):.6g} | "
                  f"{row.get('average_delta', 0):.6g} | "
                  f"{row.get('stddev_delta', 0):.6g} |")
            A("")
            A("Δ is pdal − pcax.")
            A("")
        elif comp.get("point_stats_error"):
            A(f"points.laz stats comparison failed: "
              f"`{comp['point_stats_error']}`\n")

        pd_res = comp.get("point_delta")
        if pd_res and pd_res.get("status") != "missing":
            A("## points.laz — exact point-set delta\n")
            rep = pd_res.get("report", {})
            mem = rep.get("membership", {})
            if mem:
                A(f"- matched: **{mem['matched']:,}**")
                A(f"- only in pcax: **{mem['only_a']:,}**  "
                  f"({100 * mem['only_a'] / max(mem['count_a'], 1):.6f}%)")
                A(f"- only in pdal: **{mem['only_b']:,}**  "
                  f"({100 * mem['only_b'] / max(mem['count_b'], 1):.6f}%)")
                A(f"- Jaccard: {mem['jaccard']:.9f}")
                A("")
            A("```")
            A(pd_res.get("text", "").strip())
            A("```")
            A("")

        rasters = comp.get("rasters", {})
        if rasters:
            A("## Rasters — cell-by-cell comparison\n")
            for name, res in rasters.items():
                A(f"### {name}\n")
                if res.get("status") == "missing":
                    A("missing on one side\n")
                    continue
                A(f"verdict: **{'identical' if res['identical'] else 'differs'}** "
                  f"(atol 1e-3)\n")
                A("```")
                A(res.get("text", "").strip())
                A("```")
                A("")

    open(path, "w").write("\n".join(L) + "\n")


if __name__ == "__main__":
    sys.exit(main())
