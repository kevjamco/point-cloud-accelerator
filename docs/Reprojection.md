# filter.reproject — GPU Coordinate Reprojection

Full CRS-to-CRS reprojection with PDAL/PROJ-equivalent semantics, executed on
the GPU. Supports arbitrary CRS pairs: cartographic projections, geodetic
datum transformations (Helmert, grid-based), and compound/vertical CRS with
Geodetic TIFF Grids (geoids).

## How it works

**Planning (host, libproj).** PROJ is two things: a *planner* (proj.db
lookups, operation selection, grid resolution — runs once, in microseconds)
and an *executor* (per-point math — runs once per point). pcax links real
libproj for planning: `proj_create_operations()` selects the best coordinate
operation for the data's bounding box exactly as PDAL/GDAL would, the
operation is normalized to GIS axis order, and its PROJ pipeline string is
compiled step-by-step into GPU op descriptors with all parameters
(projection series coefficients, Helmert matrices, unit factors) precomputed
in fp64 on the host. proj.db is never ported — it stays a host-side planning
database.

**Execution (GPU).** One fused kernel walks the op chain per point entirely
in registers:

```
relative f32 → absolute RealT (denormalize) → op chain → bounds reduce
                                  ↓
             renormalize kernel → relative f32 against new origin
```

Absolute coordinates exist only in registers and temp buffers — the SoA
storage format stays relative float32 on both sides, so the precision toggle
changes zero bytes of memory layout.

**CPU fallback.** A pipeline step outside the GPU op set (rare projections
like `omerc`, time-dependent ops needing per-point epochs) makes the stage
fall back to host PROJ execution, multithreaded over the SoA arrays —
always correct, just not GPU-fast.

Whenever the stage does **not** run on the GPU op-chain it emits a
`[WARN] reproject: NOT using the GPU op-chain — falling back to host PROJ
(CPU, FP64). Reason: …` line to the console, naming the cause — an
unsupported pipeline step, `device: cpu`, or the Metal backend (FP32-only;
the GPU op-chain is CUDA-only). The fallback is never silent: if you expect
CUDA and get CPU, the console always says so and why. When it *does* run on
the GPU op-chain it logs a matching `[INFO] reproject: running on the GPU
op-chain (fp64|fp32)`. A runtime CUDA failure (e.g. allocation) does not
silently fall back — it aborts with an error so a real GPU problem is never
masked.

## GPU-supported operations

`axisswap`, `unitconvert`, `cart` (geodetic↔geocentric), `helmert`
(3/7/14-parameter, position-vector and coordinate-frame conventions),
`tmerc`/`utm`/`etmerc` (exact Poder/Engsager, identical to PROJ's default),
`merc`, `webmerc`, `lcc` (1sp/2sp), `aea`, `hgridshift`, `vgridshift`,
`gridshift`, `push`/`pop`.

`gridshift` is PROJ's generic grid operation, the one it selects for NAD83
realization changes through NADCON5 — NAD83(2011) → NAD83 is four chained
`+inv +proj=gridshift` steps. The op follows PROJ's implementation
(`src/transformations/gridshift.cpp`): the grid's own `interpolation_method`
(NADCON5 declares `biquadratic`: NOAA's 3×3 scheme whose window moves by one
node at each half cell; otherwise bilinear), `+interpolation` and
`+no_z_transform`, the height band of `GEOGRAPHIC_3D_OFFSET` grids, and
PROJ's inverse — one non-iterated step for biquadratic grids, an iteration
for bilinear ones. Against host PROJ on 20 000 points across CONUS the fp64
chain agrees to 8·10⁻⁸ m in both directions. The supported subset is one
geographic grid per step, of type `GEOGRAPHIC_3D_OFFSET` or
`HORIZONTAL_OFFSET`, with arc-second/metre bands and no nodata; anything
else (grid lists, projected grids, vertical-only grids) runs on host PROJ
with the reason logged.

## Geodetic TIFF Grids

Grid-based datum shifts and geoid models load through GDAL (multi-subgrid
GTG supported — ca_nrc_ntv2_0 expands to 114 subgrids — with finest-first
selection per point; NTv2 accuracy bands and `positive_value=west`
longitude conventions handled), are uploaded to GPU memory, and are sampled
with software bilinear interpolation in the compute precision — matching
CPU PROJ, which also interpolates fp32 grid nodes in fp64. Hardware texture
filtering is deliberately not used (9-bit fixed-point interpolation
weights).

`gridshift` grids are continental (a NADCON5 CONUS file is 3541 × 1561
nodes × 3 bands), so they are read only over the data's extent: the source
bounding box is run through the steps ahead of the grid step, widened by
0.05° and a four-node guard band, and that window alone is read and
uploaded (tens of nodes a side for a lidar tile, a few ms). Results are
identical to loading the whole grid.

### Managing grids (add / remove / change)

Grids live in a plain directory; the stage option `grids_path` prepends it
to PROJ's search paths for operation selection and grid resolution:

```yaml
reproject:
  type: filter.reproject
  input: read
  out_srs: "EPSG:4326+5773"     # WGS84 + EGM96 orthometric height
  grids_path: ./grids
```

- **Add**: drop a GTG file into the directory (`compare/fetch_grids.sh`
  downloads the test set from cdn.proj.org; `projsync --file <name>` works
  too). PROJ's operation selection sees it immediately and prefers precise
  grid operations over ballpark Helmert fallbacks.
- **Remove**: delete the file. The planner re-ranks operations — for
  example DHDN→ETRS89 falls back from the BETA2007 grid to the proj.db
  7-parameter Helmert, exactly as CPU PROJ would. An explicit `pipeline:`
  naming a missing grid fails loudly instead.
- **Change**: which geoid applies is determined by the target CRS (e.g.
  `EPSG:4326+5773` selects EGM96, `EPSG:7844+5711` selects AUSGeoid2020) —
  swap geoids by swapping `out_srs`, keeping both grids in the directory.

Without `grids_path`, grids resolve through the standard `PROJ_DATA`
locations. For cloud deployments, bake the needed grids into the Docker
image (offline-first; PROJ's CDN networking is not used by the GPU path).
Verified against real grids in `tests/test_reproj_grids_real.cpp` (EGM96,
AUSGeoid2020, BETA2007, NTv2 — all ≤ 1e-13 m vs PROJ on the host chain,
storage-quantization-level end-to-end; NADCON5 `gridshift` ≤ 1e-7 m; skips
when `grids/` is absent).

## Precision: fp64 vs fp32

| | fp64 (default) | fp32 (`precision: fp32`) |
|---|---|---|
| transform error vs PROJ | < 10⁻⁸ m (per-op), output limited only by storage quantization | ~1–4 m horizontal |
| intended use | production | development on consumer GPUs |

The fp32 error is representation, not arithmetic: fp32 ulp at longitude 150°
is ≈ 0.8 m. The stage logs a loud warning when fp32 is selected.

**Storage quantization (both modes):** output coordinates are stored as
relative float32, so resolution is bounded by `output_span / 2^23` —
≈ 4 mm for a 30 km tile, ≈ 1.3 cm per degree of geographic span. The auto
scale policy picks the next power of ten above that bound, which also
guarantees exact int32 round-trip through the writer.

## Options

| Option | Default | Description |
|---|---|---|
| `out_srs` | *(required)* | Target CRS — anything PROJ accepts (`EPSG:32756`, WKT, compound `EPSG:6344+5703`, …) |
| `in_srs` | *(from file)* | Source CRS override. By default parsed from the file's WKT VLR or GeoTIFF keys |
| `pipeline` | — | Raw PROJ pipeline string; bypasses CRS planning (power users / tests) |
| `precision` | `fp64` | `fp64` or `fp32` (dev mode, reduced accuracy) |
| `device` | `gpu` | `cpu` forces host PROJ execution |
| `on_error` | `drop` | `drop` failed points (PDAL streaming parity), `fail`, or `keep` |
| `out_scale` | `auto` | Output x/y quantization scale, or a number |
| `out_scale_z` | `out_scale` | Output z quantization scale |
| `grids_path` | — | Directory of GTG grids, prepended to PROJ's search paths |
| `write_crs` | `true` | Rewrite the output CRS VLRs (WKT 2112 + EPSG GeoTIFF keys) |

## Example

```yaml
version: 1
stages:
  read:
    type: read.las
    filename: input.laz
  reproject:
    type: filter.reproject
    input: read
    out_srs: EPSG:4326
    precision: fp64
  write:
    type: write.las
    input: reproject
    filename: output.laz
```

## Metadata handling

The stage recomputes the normalization metadata (`scale`, `offset`,
`minRaw`, `dataMin`) for the output CRS; the LAS writers take scale/offset
from metadata and replace the source CRS VLRs/EVLRs (GeoTIFF keys 34735-37,
WKT 2111/2112) with a WKT VLR for the target CRS, setting the LAS 1.4
global-encoding WKT bit where applicable. When the target CRS has an EPSG
identifier, a GeoTIFF key directory VLR is written alongside the WKT —
pre-1.4 readers (including PDAL) only consult GeoTIFF keys, so this is what
makes the output CRS round-trip through other tools.

Points PROJ cannot transform (outside grid coverage, out of projection
domain) are flagged per point on the GPU — the failure mask matches host
PROJ point-for-point — and dropped by default with a warning count.

## Verification

Three test layers gate accuracy against libproj executing the identical
pipeline (`ctest`):

1. **`test_reproj_ops`** (host) — the templated op-chain code compiled for
   CPU, compared per-op and per-pipeline against PROJ over thousands of
   random points. Gate: fp64 < 0.1 mm (observed: < 10 nm for projections,
   < 10⁻¹³ m for grid shifts). fp32 deviation reported.
2. **`test_reproj_gpu`** — the actual CUDA kernels, both precisions,
   including device grid sampling and failure-mask agreement with PROJ.
   Gate: fp64 within storage quantization (mm-level).
3. **`test_reproj_stage`** — end-to-end LAS → reproject → LAS, CRS VLR
   rewrite, identity short-circuit, missing-CRS errors, fp32 mode, CPU/GPU
   agreement, failed-point dropping.

## Head-to-head vs PDAL

`compare/reproject_bench.py` synthesizes identical inputs, runs
`pdal pipeline` (filters.reprojection) and `pcax` (fp64 + fp32) on them,
measures wall time and stage time, and compares outputs point-by-point
(max/RMS drift, beyond-tolerance counts, point-count mismatches). Reports
land in `compare/out/reproject/report.md` / `report.json`.

```bash
python3 compare/reproject_bench.py                  # 5 scenarios × 10M points
python3 compare/reproject_bench.py --points 1000000 --scenario utm56s_to_wgs84
```

## Known limitations

- For a target CRS without an EPSG identifier (custom WKT/proj string), only
  the WKT VLR is written; pre-1.4 readers that ignore WKT will see no CRS.
- Time-dependent Helmert transforms are evaluated at their reference epoch
  (LAS points carry no coordinate epoch). An `epoch` option can be added
  when needed.
- Unsupported pipeline steps (e.g. `omerc`, `krovak`, deformation models)
  execute via the CPU PROJ fallback.
