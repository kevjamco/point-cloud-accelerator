# Integration testing

Per-stage validation of the canonical Everglades DSM/DTM pipeline on a
committed fixture, in three tiers. Lives in `tests/integration/`
(pytest), registered in ctest under labels `integration`, `parity`,
`perf` (CMakeLists.txt). Initial measurements: docs/Parity.md.

## Fixture

`tests/data/everglades_subset.laz` — 1,569,508 points (~10.5 MB), a
source-CRS crop of the full 35.46M-point tile covering the UTM 17N
window 533300–533450 E / 2797300–2797450 N (+30 m pad), with a matching
one-cell-padded crop of the 10 m base DTM. Provenance and regeneration:
`tests/data/README.md` / `make_fixtures.py`. The committed files are
canonical; LAZ bytes are not reproducible across PDAL versions.

## The canonical chain

`tests/integration/pipelines.py` is the single source of truth: the 11
stages of the Everglades DSM/DTM production pipeline (docs/pipeline-phases/)
with the grid/crop scaled to the fixture window (150×150 @ 1 m). Three
emitters produce runnable YAML:

- `emit_stats_checkpointed()` — a `filter.stats` stage with `json:`
  output after every cloud stage (Tier 1's capture: one pcax run = 9
  per-stage fingerprints + 2 rasters).
- `emit_las_checkpointed()` — `write.las` snapshots instead (Tier 2,
  so PDAL can diff full point sets).
- `emit_plain()` — no checkpoints (Tier 3; interleaved CPU stats stages
  force GPU↔host residency transfers and would skew timings).

## Variants

| variant | reproject | SOR | notes |
|---|---|---|---|
| `gpu-fp64` | GPU op-chain, fp64 | GPU, fp64 | canonical |
| `gpu-fp32` | GPU op-chain, fp32 | GPU, fp32 | |
| `cpu-fp64` | host PROJ (`device: cpu`) | GPU, fp64 | host PROJ is fp64-only |

SOR has no CPU path (`filter.outlier` is GPU-only), so there is no
device axis for it. Baselines are per-variant.

### Backend dimension (`--gpu-backend`)

The suite takes a `--gpu-backend cuda|metal` option (CMake passes the
build's `PCA_GPU_BACKEND`; default `cuda`). It selects two things:

- **Baseline set.** CUDA (FP64) baselines live at `baselines/<variant>.json`;
  Metal (FP32) baselines at `baselines/metal/<variant>.json`. The two
  backends never overwrite each other — `--update-baselines` writes to the
  set for the backend you pass.
- **fp64 GPU variants.** Apple GPUs are FP32-only, so on `--gpu-backend metal`
  the `gpu-fp64` / `cpu-fp64` variants (both drive the GPU-only
  `filter.outlier` at `precision: fp64`) are **skipped** in the variant
  fixtures — they cannot run — and the single `test_metal_fp32_guard`
  asserts that such a pipeline fails via `pca::gpu::requireFp32` instead of
  silently running. On CUDA all three variants run as before and that guard
  test skips. The parity tier runs pcax at fp32 on Metal (vs PDAL's fp64
  reference); the divergence stays inside `PARITY_SLACK`, the same FP32
  class as CUDA.

The Metal FP32 baselines are committed and verified self-consistent
across runs on Apple Silicon (M1 Max); the helpers are
`conftest.baselines_for` / `conftest.fp64_unsupported_on`.

## Tier 1 — regression (label `integration`, ~5 s)

Each variant's stage fingerprints (count + per-dim min/max/mean/stddev)
are compared against `tests/integration/baselines/<variant>.json`;
DSM/DTM rasters are compared cell-for-cell against committed golden
GeoTIFFs via `compare/compare_geotiffs.py`. Tolerances
(`tolerances.py`): counts exact, stats rtol 1e-9 (stddev 1e-7), raster
atol 1e-3 m at IoU 1.0 — justified because all three variants are
**byte-identical across runs** (measured 3×, 2026-06-12). Shape
invariants (monotone counts, drop_origin neutrality, SOR
relabels-not-drops) hold independent of baselines.
`test_origin_drop.py` covers the drop-origin semantics on a synthetic
las_synth file, since the fixture has no on-axis points.

After an intentional behavior change, regenerate with
`pytest tests/integration --update-baselines` and commit the diff —
the baseline diff *is* the reviewable behavior change.

## Tier 2 — PDAL parity (label `parity`, ~30 s, needs pdal)

`pdal_map.py` derives the equivalent PDAL pipeline (per the reference
NOAA JSON, reordered to pcax's canonical SOR-after-reproject) with
interleaved `writers.las`; each checkpoint pair is compared via
`pdal info --stats`. The pcax side runs `search_radius: 0` (exact
unbounded kNN = PDAL's method). Measured envelope on this fixture
(encoded in `test_pdal_parity.py`, measured 2026-06-12):

- read → reproject: exact parity (float tol 1e-8).
- denoise: counts equal; **one** classification flip in 1.57M — a point
  whose mean 3-NN distance sits 0.97 µm (2.5e-6 relative) above the
  threshold; FP32 relative-coordinate storage lands it just below.
  Budget: ≤5 flips.
- crop: **one** point 6.9 µm inside the window edge flips out under
  FP32 quantization. Count slack ≤3 for drop_noise/crop/dem_filter.
- keep_ground_water onward: exact parity again (both stray points are
  class 1).

Both single-point flips are instances of the documented FP32-storage-
at-boundaries tolerance (CLAUDE.md). A separate test monitors the
*canonical* (search_radius=1.5) SOR divergence vs PDAL as a recorded
envelope: pcax 0.016620 vs PDAL 0.016608 flagged, band ±0.002.

## Tier 3 — perf (label `perf`, advisory)

Parses the `-d` profiler tree of plain-pipeline runs and compares
per-stage timings against a machine-local baseline in
`tests/integration/.perf/<hostname>.json` (gitignored). Warns at >1.5×;
never fails. Paste notable shifts into docs/Parity.md.

## Accuracy tier (label `accuracy`, slow)

`test_ml_noise_accuracy.py` scores filter.ml_noise against vendor noise
labels (classes 7/18) on held-out USGS Santa Clara County 2020 tiles
(public 3DEP data, not committed, ~180 MB each; directory from
`PCAX_NOISE_TILES`). Per-tile
precision/recall/F1 floors are pinned just under the values measured in
docs/Parity.md — a drift tripwire for the port, not a model-quality
gate (the reference model's recall on this unseen project is genuinely
low). Excluded from Tier 1; run with `ctest -L accuracy`
(~141 s, needs the GPU, the tiles and the model artifact — skips
otherwise).

## Stages outside the canonical chain

`filter.ml_noise` has its own template, test and baseline
(`test_ml_noise.py`, `baselines/ml_noise.json`): it is not part of the
production Everglades pipeline, has no PDAL mapping (its parity reference
is the Python pipeline the model was trained with — docs/MlNoiseFilter.md), and runs
double feature math on GPU regardless of the precision variants, so it
gets a single non-variant baseline. The test skips unless `PCAX_ML_MODEL`
points at a model (the model is user-supplied; the committed baseline was
generated with the reference model named in its `_meta`). `--update-baselines` regenerates its baseline
along with the canonical ones.

`write.copc` (`test_copc.py`) also runs its own two-stage pipelines rather
than joining the canonical chain: it needs a projected-CRS fixture
(`tests/data/northernca_subset.laz`, 2.77M points, UTM 10N — the geographic
Everglades cube is Z-dominated and degenerates to a column) and its parity
check is structural, not statistical. Tier 1 asserts the output is COPC per
`pdal info`, LAS 1.4 / PF6, that `readers.copc` reads every point back, and
covers the reprojected (`coordsDirty`) path. Tier 2 (`parity`) runs
`compare/copc_parity.py` on both fixtures: every record read through
`readers.copc` must match PDAL `writers.copc` **exactly** (sorted; only the
order differs), and a `bounds` window query must return the same point
count from both files. The full 73M-point NorthernCA tile is a manual run
recorded in docs/Parity.md, not part of the suite.

`pcax serve` (`test_serve.py`, marker `serve`, ctest `integration_serve`)
is not a stage at all: it starts the server on an ephemeral port over a
`write.copc` output of the fixture and asserts the HTTP contract COPC viewers
rely on (index JSON, `HEAD`, single/suffix/multipart `Range` → 206 with the
exact bytes, 416, CORS preflight, traversal and non-COPC names → 404, the
embedded viewer assets + WASM MIME, concurrent range fetches). The shell twin
`tests/serve/test_serve.sh` runs as the `test_serve_http` ctest.

## Extending to a new stage

1. Add the stage to `pipelines.STAGES` (or a new template) — Tier 1
   checkpoints and invariants pick it up automatically.
2. Add its PDAL mapping in `pdal_map._map_stage` for Tier 2.
3. Run `--update-baselines`, eyeball the new fingerprints, commit.
4. If it diverges from PDAL by design, encode the measured envelope in
   `PARITY_SLACK`/`tolerances.OVERRIDES` with a docs/Parity.md entry.
