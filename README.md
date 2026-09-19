# Point Cloud Accelerator

[![ci](https://github.com/kevjamco/point-cloud-accelerator/actions/workflows/ci.yml/badge.svg)](https://github.com/kevjamco/point-cloud-accelerator/actions/workflows/ci.yml)
[![License: source-available](https://img.shields.io/badge/license-source--available-blue.svg)](LICENSE)
![status: alpha](https://img.shields.io/badge/status-alpha-orange.svg)

**Point Cloud Accelerator** (`pcax`) is a GPU-accelerated processing engine for
lidar point clouds: CUDA on Linux, Metal on Apple Silicon. You describe a
pipeline in YAML — read, denoise, reproject, classify, compute neighborhood
features, rasterize, write LAS/LAZ, COPC or GeoTIFF — and `pcax` runs it with
the compute-heavy stages on the GPU and the I/O in parallel on the host.

- **50+ stages**: statistical outlier removal, PROJ-based reprojection, SMRF
  ground classification, height-above-ground, normals/eigenfeatures, DBSCAN /
  k-means / Euclidean clustering, ML noise classification, voxel/Poisson/FPS
  sampling, range/crop/DEM filters, rasterization, and more.
- **Fast on real tiles**: 8–20× wall-clock speedups over CPU tools on
  1–70 M-point USGS tiles, with exact or documented-tolerance results
  ([docs/Parity.md](docs/Parity.md)).
- **Drops into existing workflows**: reads and writes the same LAS 1.2–1.4,
  LAZ, COPC 1.0 and GeoTIFF files as everything else; `pcax convert` imports
  pipelines written for PDAL (see [Working with PDAL](#working-with-pdal)).
- **Self-hosted 3D viewer**: `write.copc` + `pcax serve` puts a tile in the
  browser with class toggles, attribute colouring and clip boxes.
- **Resource planning**: `pcax analyze` predicts host and GPU memory before a
  run; `-d` prints a per-stage profiler tree.

> **Alpha.** The stages below are feature-complete and tested, but options,
> YAML shape and CLI flags may still change before 1.0. See
> [ROADMAP.md](ROADMAP.md) and [CHANGELOG.md](CHANGELOG.md).

## Features

- **LAS/LAZ reader/writer** — swappable backend (LASlib or laz-perf), full header/VLR/CRS passthrough
- **Coordinate normalization** — data-derived FP32 relative coords eliminate precision loss from large absolute coordinates (e.g., UTM eastings); lossless int32 roundtrip on write
- **Parallel LAZ I/O** — chunk-level parallel compress/decompress via laz-perf (configurable thread count)
- **GPU Statistical Outlier Removal** — uniform grid spatial index, kNN search, CUB radix sort
- **GPU Gridding Writer** — rasterize point clouds to GeoTIFF with PDAL `writers.gdal` feature parity (min/max/mean/stdev/count/IDW/percentiles), bin and radius modes. See [docs/GdalGpuWriter.md](docs/GdalGpuWriter.md)
- **YAML pipelines** — named stages, explicit data flow, variable substitution, GPU execution hints
- **Automatic GPU transfer** — residency tracking moves data between host and device as needed
- **Built-in profiler** — tree-structured timing with RAM and GPU memory tracking (`-d` flag)
- **COPC output + self-hosted 3D viewer** — `write.copc` builds the LOD octree on the GPU (byte-exact vs PDAL, ~11× faster); `pcax serve` hosts the files with range requests and an embedded Potree page: pick files, toggle classes, colour by any attribute (incl. derived dims), clip boxes. See [docs/CopcWriter.md](docs/CopcWriter.md), [docs/Serve.md](docs/Serve.md)

## Quick Start

### Install (conda)

Prebuilt packages for Linux x86-64 (CUDA) and Apple Silicon (Metal) come from
the Advanced Algorithms conda channel; dependencies come from conda-forge:

```bash
mamba install -c https://conda.adv-algos.net/pcax -c conda-forge pcax
pcax --version
```

Needs an NVIDIA driver for CUDA 13 (R580+) on Linux, or macOS 14+ on Apple
Silicon. See [docs/Install.md](docs/Install.md).

### GPU backend (CUDA vs Metal)

pcax has two GPU backends, chosen by platform:

| Backend | Platform | Notes |
|---|---|---|
| **CUDA** | Linux + NVIDIA | full filter set; FP32/FP64 |
| **Metal** | macOS / Apple Silicon | native Metal compute, **FP32-only** (any `precision: fp64` stage errors); unified memory removes host↔device copies |

Every GPU filter in the table below has Metal kernels — the neighborhood
filters, clustering, sampling, `filter.ml_noise` and `writer.gdal_gpu`
included. Two stages deliberately use their host paths on Metal:
`filter.reproject` (host PROJ, for FP64 accuracy) and `write.copc` (the
bit-identical host octree builder). Each matches the CUDA backend / PDAL within the
documented FP32 tolerance — e.g. `filter.outlier` is point-exact vs PDAL,
`filter.hag_nn` agrees to 2e-6 m, `writer.gdal_gpu` to ≥99.7% of cells,
`filter.ml_noise` inference to 1 point in 1.57 M — and clears the 5–10× perf
target (SOR 12.9×, normal ~15×, hag_nn ~12–20× faster than PDAL end-to-end on
a 1.6 M-point tile). See [docs/MetalBackend.md](docs/MetalBackend.md) for the
architecture, the per-filter CUDA/Metal porting pattern, measured results, and
follow-ups.

### Run

```bash
# Run a pipeline
pcax run pipeline.yaml

# Override variables
pcax run pipeline.yaml -v input=myfile.laz -v output=filtered.laz

# Validate without executing
pcax validate pipeline.yaml

# Header summary of a LAS/LAZ file (version, format, count, bounds, scale/offset; reads no points)
pcax info tile.laz

# Predict host/GPU memory before running (probes the LAS header; reads no points)
pcax analyze pipeline.yaml -v input=tile.laz     # or: make analyze
pcax analyze pipeline.yaml --json                # machine-readable
# exit 0 = fits, 2 = provably will not fit, 1 = point count undeterminable

# Debug logging + profiler tree (timing, RAM, GPU memory)
pcax run pipeline.yaml -d

# Host a directory of write.copc output + the embedded 3D viewer
pcax serve out/ --bind 0.0.0.0 --port 8080      # browse to http://host:8080/

# Translate an existing PDAL pipeline JSON into a pcax YAML pipeline
pcax convert pipeline.json -o pipeline.yaml     # stdout without -o
pcax convert pipeline.json --strict             # exit 2 if anything is lost
```

`pcax convert` accepts both PDAL forms (`{"pipeline": [...]}` and a bare
array, with or without `tag`/`inputs`, bare filename strings included) and
follows PDAL's own chaining and driver-inference rules. Stage and option
names are translated through one table (`src/core/PdalConvert.cpp`; e.g.
`filters.outlier mean_k` → `filter.outlier k`, `filters.projpipeline
coord_op` → `filter.reproject pipeline`, `writers.gdal` →
`writer.gdal_gpu`). A single reader/writer filename is hoisted to
`${input}`/`${output}` (`--no-vars` keeps it inline). Anything pcax cannot
express is kept visible rather than dropped silently: options become
`# unsupported: k=v` comments, whole stages become `# TODO` comments and
their consumers are re-chained around them (`--adapter` emits `pdal.filter`
stubs instead, for a `PCA_WITH_PDAL` build), and GPU-only knobs are
suggested as commented hints (`# precision: fp64`). For example:

```yaml
  write_points:
    type: write.las
    input: reproject
    filename: "out/points.laz"
    # unsupported: scale_x=0.01, offset_x=auto, a_srs=EPSG:3310+5703
```

Debug mode (`-d`) prints a profiler summary at the end of the pipeline:

```
├─ read (read.las)                              4280.0 ms  [RAM: 4088 MB]
├─ denoise (filter.outlier)                     2375.3 ms  [RAM: 4187 MB]
│  ├─ sor: upload X,Y,Z,Cls to GPU                    0.0 ms (gpu)  [RAM: 4187 MB, GPU: 4644 MB]
│  ├─ sor: allocate GPU buffers                       0.7 ms (gpu)  [RAM: 4187 MB, GPU: 6358 MB]
│  ├─ sor: kNN search                              1502.9 ms (gpu)  [RAM: 4187 MB, GPU: 6360 MB]
│  ├─ sor: compute stats (cpu)                      163.7 ms  [RAM: 4520 MB]
│  ├─ sor: download classification                    9.5 ms (gpu)  [RAM: 4520 MB, GPU: 6360 MB]
├─ write (write.las)                            2634.9 ms  [RAM: 4194 MB]
└─ total                                        9296.3 ms
```

Memory values are snapshots at the end of each step (not peak tracking).

## Pipeline Format

YAML with named stages and explicit data flow:

```yaml
version: 1

vars:
  input: input.laz
  output: filtered.laz
  k: 8
  multiplier: 2.0

stages:
  read:
    type: read.las
    filename: "${input}"

  denoise:
    type: filter.outlier
    input: read
    device: gpu
    method: statistical
    k: ${k}
    multiplier: ${multiplier}

  write:
    type: write.las
    input: denoise
    filename: "${output}"
```

## Stages

| Type | Description | Device |
|---|---|---|
| [`read.las`](docs/Filters.md#readlas) | Read LAS/LAZ, parallel chunk decompress (laz-perf); extracts Intensity/returns/GpsTime/RGB/ScanAngle + Synthetic/KeyPoint/Withheld/Overlap flag dims | CPU |
| [`filter.outlier`](docs/Filters.md#filteroutlier) | Statistical outlier removal (SOR) | GPU |
| [`filter.reproject`](docs/Filters.md#filterreproject) | CRS reprojection (arbitrary CRS via PROJ planning, datum shifts, GTG geoid grids, fp64/fp32 toggle). See [docs/Reprojection.md](docs/Reprojection.md) | GPU |
| [`filter.range`](docs/Filters.md#filterrange) | Cull by dimension ranges (PDAL `filters.range` grammar) | CPU |
| [`filter.crop`](docs/Filters.md#filtercrop) | Crop to bbox or WKT polygon (holes, `outside`) | CPU |
| [`filter.dem`](docs/Filters.md#filterdem) | Filter by deviation from a GDAL elevation raster | CPU |
| [`filter.smrf`](docs/Filters.md#filtersmrf) | SMRF ground classification (Pingel 2013, PDAL port) | CPU |
| [`filter.hag_nn`](docs/Filters.md#filterhag_nn) | Height above ground via nearest ground returns | GPU |
| [`filter.hag_dem`](docs/Filters.md#filterhag_dem) | Height above ground from a DEM raster | CPU |
| [`filter.normal`](docs/Filters.md#filternormal) | Surface normals + curvature (kNN covariance PCA) | GPU |
| [`filter.eigenvalues`](docs/Filters.md#filtereigenvalues) | Neighborhood covariance eigenvalues | GPU |
| [`filter.covariancefeatures`](docs/Filters.md#filtercovariancefeatures) | Local eigenfeatures (linearity/planarity/scattering/verticality/omnivariance/anisotropy/eigenentropy/eigenvaluesum/surfacevariation/demantkeverticality/density); knn/radius/optimized modes | GPU |
| [`filter.optimalneighborhood`](docs/Filters.md#filteroptimalneighborhood) | Per-point entropy-optimal neighborhood size → OptimalKNN/OptimalRadius (feeds covariancefeatures) | GPU |
| [`filter.approximatecoplanar`](docs/Filters.md#filterapproximatecoplanar) | Label points whose neighborhood is approximately planar (eigenvalue-ratio test) → Coplanar | GPU |
| [`filter.planefit`](docs/Filters.md#filterplanefit) | Point-to-plane fit criterion over kNN neighborhood → PlaneFit | GPU |
| [`filter.estimaterank`](docs/Filters.md#filterestimaterank) | SVD rank of the kNN covariance (1=line, 2=plane, 3=volume) → Rank | GPU |
| [`filter.radialdensity`](docs/Filters.md#filterradialdensity) | Neighbors-in-radius normalized by sphere volume → RadialDensity | GPU |
| [`filter.nndistance`](docs/Filters.md#filternndistance) | k-th or average nearest-neighbor distance → NNDistance | GPU |
| [`filter.reciprocity`](docs/Filters.md#filterreciprocity) | % of kNN neighbors that don't reciprocate (kNN-of-kNN) → Reciprocity | GPU |
| [`filter.lof`](docs/Filters.md#filterlof) | Local Outlier Factor (3-pass kNN density) → NNDistance/LocalReachabilityDistance/LocalOutlierFactor | GPU |
| [`filter.neighborclassifier`](docs/Filters.md#filterneighborclassifier) | kNN majority-vote relabel of Classification (strict majority, optional domain) | GPU |
| [`filter.ml_noise`](docs/Filters.md#filterml_noise) | LightGBM noise classifier (48 GPU features + tree-ensemble inference; user-supplied LightGBM model, local or S3 path). See [docs/MlNoiseFilter.md](docs/MlNoiseFilter.md) | GPU |
| [`filter.elm`](docs/Filters.md#filterelm) | Extended Local Minimum low-noise marking | CPU |
| [`filter.voxeldownsize`](docs/Filters.md#filtervoxeldownsize) | First/center voxel downsampling | CPU |
| [`filter.voxelcenternearestneighbor`](docs/Filters.md#filtervoxelcenternearestneighbor) | Keep point nearest each voxel center | CPU |
| [`filter.voxelcentroidnearestneighbor`](docs/Filters.md#filtervoxelcentroidnearestneighbor) | Keep point nearest each voxel centroid | CPU |
| [`filter.sample`](docs/Filters.md#filtersample) | Poisson-disk subsampling (min-distance thinning) | CPU |
| [`filter.fps`](docs/Filters.md#filterfps) | Farthest-point sampling to N points (GPU; ~2000× faster than PDAL) | GPU |
| [`filter.cluster`](docs/Filters.md#filtercluster) | Euclidean clustering via GPU connected components → ClusterID | GPU |
| [`filter.dbscan`](docs/Filters.md#filterdbscan) | Density-based clustering (DBSCAN) on GPU → ClusterID (-1=noise) | GPU |
| [`filter.lloydkmeans`](docs/Filters.md#filterlloydkmeans) | Lloyd's k-means (FPS init) on GPU → ClusterID | GPU |
| [`filter.assign`](docs/Filters.md#filterassign) | Assign dimension values by range + condition | CPU |
| [`filter.decimation`](docs/Filters.md#filterdecimation) | Keep every Nth point | CPU |
| [`filter.head`](docs/Filters.md#filterhead) | Keep first N points (or drop them with `invert`) | CPU |
| [`filter.tail`](docs/Filters.md#filtertail) | Keep last N points (or drop them with `invert`) | CPU |
| [`filter.gpstimeconvert`](docs/Filters.md#filtergpstimeconvert) | Convert GpsTime between gt/gst/gws/gds representations | CPU |
| [`filter.iqr`](docs/Filters.md#filteriqr) | Drop points outside the interquartile fence on a dimension | CPU |
| [`filter.mad`](docs/Filters.md#filtermad) | Drop points outside median ± k·MAD on a dimension | CPU |
| [`filter.skewnessbalancing`](docs/Filters.md#filterskewnessbalancing) | Skewness-balancing ground classification → Classification | CPU |
| [`filter.sparsesurface`](docs/Filters.md#filtersparsesurface) | Sparse-surface greedy noise marking → Classification | CPU |
| [`filter.sort`](docs/Filters.md#filtersort) | Sort points by one or more dimensions (ASC/DESC, stable) | CPU |
| [`filter.mortonorder`](docs/Filters.md#filtermortonorder) | Reorder points along the 2D Morton/Z-order curve | CPU |
| [`filter.transformation`](docs/Filters.md#filtertransformation) | 4x4 matrix transform | CPU |
| [`filter.stats`](docs/Filters.md#filterstats) | Per-dimension summary statistics (optional `json:` file output) | CPU |
| [`write.las`](docs/Filters.md#writelas) | Write LAS/LAZ, parallel chunk compress (laz-perf); writes back modified attr dims | CPU |
| [`write.copc`](docs/Filters.md#writecopc) | Write COPC 1.0 (`.copc.laz`) for LOD viewers: GPU octree + record assembly, one LAZ chunk per node, legacy formats upgraded to 6/7, `extra_dims` as extra bytes — byte-exact vs PDAL `writers.copc` ([docs/CopcWriter.md](docs/CopcWriter.md)) | GPU |
| [`read.text`](docs/Filters.md#readtext) | Read delimited text/CSV (header→dimension mapping) — PDAL `readers.text` | CPU |
| [`read.ply`](docs/Filters.md#readply) | Read PLY (ascii / binary_little_endian) — PDAL `readers.ply` | CPU |
| [`write.text`](docs/Filters.md#writetext) | Write delimited text/CSV (header, order, precision, delimiter) — PDAL `writers.text` | CPU |
| [`write.ply`](docs/Filters.md#writeply) | Write PLY (ascii / binary_little_endian) — PDAL `writers.ply` | CPU |
| [`writer.gdal_gpu`](docs/Filters.md#writergdal_gpu) | Rasterize to GeoTIFF (min/max/mean/stdev/count/IDW/percentiles) | GPU |
| [`pdal.filter`](docs/Filters.md#pdalfilter) | Run any PDAL `filters.*` in-process (opt-in build: `-DPCA_WITH_PDAL=ON`) | CPU |

Each stage links to its reference section in [docs/Filters.md](docs/Filters.md).
PDAL-equivalent stages are parity-tested on real USGS lidar
([docs/Parity.md](docs/Parity.md)).

Every stage's options, defaults, inputs/outputs and semantics are in
[docs/Filters.md](docs/Filters.md) (one linked section per stage; the summary
table there lists every option name).

## Architecture

```
LAS/LAZ → Reader → SoA PointCloud → GPU Upload → Filter/Writer → Download → LAS Writer
       (int32→rel f32)   (Host)       (Device)    (GPU kernels)    (Host)   (reconstruct int32)
                                                       ↓
                                                  GDAL GPU Writer → GeoTIFF
```

- **Coordinate normalization**: readers compute data-derived int32 min, store relative FP32 (`(raw - minRaw) * scale`). Writers reconstruct absolute int32 via `minRaw + lround(float / scale)`. Eliminates FP32 precision loss from large absolute coordinates
- **SoA storage**: one contiguous array per dimension (X, Y, Z, Classification)
- **Uniform grid**: cell size auto-computed from point density; exact kNN via expanding-ring search (terminates once the kth candidate is provably nearer than any unvisited cell)
- **CUB radix sort**: points sorted by grid cell for cache-coherent GPU access
- **Raw record passthrough**: LAS writers replay original point records with reconstructed XYZ and updated Classification
- **No source file re-open**: readers capture the file preamble (header + VLRs + EVLRs) at read time; writers reconstruct from stored bytes without touching the source file. Stages that change the CRS (`filter.reproject`) rewrite the CRS VLR in that preamble; everything else round-trips byte-for-byte

The full reference — data structures, the executor, the spatial index, every
CUDA kernel, the CUDA/Metal split and known limits — is
[docs/Architecture.typ](docs/Architecture.typ).

## Working with PDAL

Point Cloud Accelerator is a standalone engine — it does not link or require
[PDAL](https://pdal.io) — but it is designed to sit comfortably next to it.
Stage semantics and option names follow PDAL's where a counterpart exists,
each such stage is verified against PDAL's own output on real USGS lidar
([docs/PdalFeatureMatrix.md](docs/PdalFeatureMatrix.md),
[docs/Parity.md](docs/Parity.md)), and `pcax convert` turns an existing PDAL
pipeline JSON into pcax YAML:

```
PDAL (read → crop → merge → write intermediate.laz)
  ↓
pcax convert stage2.json -o stage2.yaml
pcax run stage2.yaml -v input=intermediate.laz -v output=filtered.laz
  ↓
PDAL (read filtered.laz → write output.laz)
```

Why a separate engine rather than a PDAL plugin: PDAL decodes coordinates to
`double` at the reader, stores points row-oriented, and runs filters
single-threaded — all reasonable choices for a CPU library, all at odds with
GPU execution. pcax keeps data-relative FP32 coordinates in
Structure-of-Arrays layout, decompresses and compresses LAZ chunks in
parallel, and runs compute-heavy stages as GPU kernels.

The only code in this repository that invokes PDAL is the optional comparator
in [`compare/`](compare/README.md), which uses whatever `pdal` binary is on
your PATH to measure parity and speed, and the opt-in `pdal.filter` adapter
([docs/PdalAdapter.md](docs/PdalAdapter.md)).

## Roadmap

Known gaps and planned work are in [ROADMAP.md](ROADMAP.md); the PDAL stages
without a native port are listed in
[docs/PdalFeatureMatrix.md](docs/PdalFeatureMatrix.md) §3.

## License

Copyright © 2026 Advanced Algorithms LLC. Point Cloud Accelerator is
**source-available** under the [Point Cloud Accelerator License](LICENSE):

- **Free to evaluate**, for everyone and with no time limit: assessing,
  testing and benchmarking pcax, and building a proof of concept, as long as
  it stays out of production and you deliver no result from it to anyone else.
- **Every other use needs a commercial license** — whatever your size, and
  whether or not you are a company. Email
  [kevin@adv-algos.com](mailto:kevin@adv-algos.com).
- **No redistribution**: use, modify and deploy it inside your organization;
  only Advanced Algorithms LLC distributes it. Forking here to contribute
  back is fine.

The full terms, including how eligibility is measured, are in
[LICENSE](LICENSE). Vendored third-party components keep
their own open-source licenses, listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Contributions are welcome;
see [CONTRIBUTING.md](CONTRIBUTING.md) for the contributor grant.
