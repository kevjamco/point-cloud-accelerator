# compare/ — the pcax ↔ PDAL comparator

pcax does not depend on [PDAL](https://pdal.io). PDAL is the *reference*: every
ported stage is specified from PDAL's source semantics and verified against
PDAL's output. The scripts in this directory are the only part of the repo
that invokes PDAL, and they use whatever `pdal` binary is on your `PATH`
(system package, conda, or a container). Nothing here is needed to build or
run pcax; the `parity` test tier and these tools skip when `pdal` is absent.

| Tool | What it answers | Needs |
|---|---|---|
| `pdal_compare.py` | Full-pipeline head-to-head on one tile: wall/CPU/RSS/GPU per tool, `pdal info --stats` deltas, exact point-set delta, cell-by-cell raster diff, run-to-run determinism. | `pdal`, `nvidia-smi` (optional), GDAL Python bindings |
| `filter_parity.py` | Does pcax stage X produce the same point set and dimension statistics as PDAL stage Y? The harness used when porting a stage. | `pdal` |
| `copc_parity.py` | Are `write.copc` records byte-exact vs `writers.copc`, and do `readers.copc` window queries agree? | `pdal` |
| `reproject_bench.py` | Reprojection micro-benchmark on synthetic tiles: PDAL `filters.reprojection` vs pcax `filter.reproject` (fp64/fp32), per-point drift. | `pdal`, `build/las_synth`, `build/las_compare` |
| `decode_bench.py` | LAZ decode cost: `read.las`/`read.copc` per file, thread count and `bounds` window, and the read share when several pcax processes share a node. pcax only. | `build/pcax` |
| `point_delta.py` | Streaming point-by-point delta of two LAS/LAZ files (membership, geometry, attributes). Tool-agnostic. | `laspy`, `numpy` |
| `compare_geotiffs.py` | Raster equivalence: CRS/geotransform/nodata, IoU, bias/RMSE, worst cells. Tool-agnostic; also used by the integration tests. | GDAL Python bindings |
| `fetch_grids.sh` | PROJ geoid/datum grids for the reprojection tests into `grids/`. | `curl` |
| `download.sh` | The default head-to-head tile (USGS 3DEP, public domain, requester-pays S3). | AWS CLI |

Outputs go under `compare/out/` and inputs under `compare/data/`; both are
gitignored. Python dependencies are listed in `requirements-dev.txt`.

## Head-to-head on a full USGS tile

```bash
compare/download.sh                                  # ~438 MiB into compare/data/
python3 compare/pdal_compare.py                      # both tools, 1 rep
python3 compare/pdal_compare.py --reps 3             # + determinism check
python3 compare/pdal_compare.py --limit 5000000      # first 5M points, both sides
python3 compare/pdal_compare.py --skip-pdal          # pcax only
python3 compare/pdal_compare.py --input other.laz \
    --pipeline my.yaml --pdal-pipeline my.json       # your own twins
```

The report lands in `compare/out/report.md` (+ `report.json`).

The default twins are `pipelines/northernca_dsm_dtm.yaml` (pcax) and
`pipelines/northernca_dsm_dtm.json` (PDAL). They must stay in lockstep: every
stage, option and constant appears in both. The pcax side is commented with
its PDAL equivalents. Until `pcax convert` grows a reverse direction, twins
are kept by hand.

### The pipeline

| # | pcax | PDAL | notes |
|---|---|---|---|
| 1 | `read.las` | `readers.las` | parallel chunked LAZ (pcax) vs `threads` pool (PDAL) |
| 2 | `filter.range Classification[...]` | `filters.range` | keep valid classes, drop pre-labelled noise |
| 3 | `filter.reproject` | `filters.projpipeline` | pinned PROJ pipeline (see below) |
| 4 | `write.las` | `writers.las` | `points.laz` |
| 5 | `writer.gdal_gpu` | `writers.gdal` | `dsm.tif`, `output_type=max`, fixed 960×960 grid |
| 6 | `filter.range Classification[2:2],[9:9]` | `filters.range` | ground + water |
| 7 | `writer.gdal_gpu` | `writers.gdal` | `dtm.tif`, `output_type=min` |

Held-out stages (SOR denoise, drop-flagged, crop, Z band) stay commented in
the YAML; re-enable them on **both** sides together. PDAL's `filters.outlier`
is a single-threaded kNN over the full tile and dominates its wall clock.

**Why the reprojection is pinned.** The source tile is already UTM
(`EPSG:6339+5703`). An identity reproject is short-circuited by both tools
and measures nothing, and `out_srs` alone lets PROJ pick a NADCON5 grid
chain that depends on which grids are installed, so the two tools can
silently run different operations. Both sides therefore pin
`UTM 10N → California Albers (EPSG:3310)` as an explicit PROJ pipeline, which
compiles wholly into pcax's GPU op chain. The runner checks pcax's log for
`running on the GPU op-chain` and reports `CPU FALLBACK` if it did not.

### What the comparison proves

1. **`pdal info --stats` on `points.laz`** — per-dimension count/min/max/
   mean/stddev with deltas against a relative tolerance.
2. **Exact point-set delta** (`point_delta.py`) — which points each tool
   kept and how far shared points moved. Moments matching does not prove
   point sets match; this does.
3. **Cell-by-cell raster diff** (`compare_geotiffs.py`) — expect a handful
   of cells per million to differ: pcax stores relative FP32 coordinates, so
   a point within ~0.1–0.5 mm of a cell edge can flip membership
   (documented in docs/Parity.md).
4. **sha256** — cross-tool LAZ byte equality is *not* expected (chunk layout,
   software id, VLR set differ). Within-tool across `--reps` it is a real
   determinism test.

### What gets benchmarked

Sampled at 10 Hz over the whole process tree: wall time, CPU user/sys
seconds and CPU efficiency (CPU-s per wall-s; 1.0× = single-threaded), peak
RSS, peak GPU memory (`nvidia-smi --query-compute-apps` filtered to our pids,
superseded by pcax's own `-d` profiler peaks), device-wide GPU utilisation,
and pcax per-stage timings from `-d`. CPU-seconds is the fairer cross-tool
number; wall-clock speedup partly reflects pcax's multi-threaded LAZ I/O.

## Per-stage parity while porting

```bash
python3 compare/filter_parity.py --input tile.laz --name case \
  --pdal-filter '{"type":"filters.range","limits":"Classification![7:7]"}' \
  --pcax-stage  'type: filter.range\nlimits: "Classification![7:7]"'
```

Multiple `--pdal-filter/--pcax-stage` pairs chain in order. The harness writes
both outputs and diffs counts plus every dimension's statistics; for derived
dims that are not written to LAS, chain a `filters.range` on the derived dim
so the surviving count is the signal. Exit 0 = parity, 1 = mismatch, 2 = a
tool failed. `PCAX=/path/to/pcax` overrides the binary.

## COPC parity

```bash
python3 compare/copc_parity.py --input tests/data/everglades_subset.laz
```

Records must match exactly after sorting (order and octree layout differ by
design); window queries through `readers.copc` must return equal counts.
`tests/integration/test_copc.py` imports `run_parity()` in the `parity` tier.
