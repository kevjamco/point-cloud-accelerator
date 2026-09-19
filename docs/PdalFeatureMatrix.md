# pcax ↔ PDAL feature matrix

Comparison of pcax's native stage set against PDAL (cloned at
`reference/PDAL`: 88 filters, 27 readers, 14 writers). pcax ships **52
native stages** plus a `pdal.filter` adapter that embeds PDAL, so any PDAL
filter not yet ported is still reachable (on CPU, via PDAL's own code).

> **Port progress** (goal: port all of PDAL, GPU-optimized, ≥ PDAL
> functionality, faster than PDAL). Newest first:
> - ✅ `write.copc` (writers.copc) — GPU octree (CUB radix sorts + level
>   subsampling) and device record assembly, host laz-perf coder per node;
>   **byte-exact point records** vs PDAL on 1.57M / 2.77M / 73M points,
>   3–6× faster; readers.copc window queries return identical point sets.
> - ✅ `filter.sparsesurface` — CPU greedy noise marking; counts within
>   39/2.6M of PDAL, ~3.9× faster (Z-tie label tolerance).
> - ✅ `filter.lloydkmeans` — GPU k-means (FPS init); **exact ClusterID** vs
>   PDAL (100K), ~27× faster (full tile: PDAL >19 min vs pcax seconds).
> - ✅ `filter.dbscan` — GPU density clustering; identical cluster count,
>   99.99% noise+membership agreement vs PDAL, ~10× faster.
> - ✅ `filter.cluster` — GPU Euclidean clustering (connected components via
>   min-label propagation); partition 99.994% identical to PDAL, ~3× faster.
> - ✅ `read.ply` (readers.ply) — ascii + binary_le PLY reader; reads pcax
>   AND PDAL-written PLY exactly (cross-tool interop, 100K points).
> - ✅ `write.ply` (writers.ply) — ascii + binary_little_endian PLY; PDAL
>   reads pcax output exactly (X/Y/Z + Intensity match) on 100K points.
> - ✅ `filter.fps` — GPU farthest-point sampling; **exact set vs PDAL**
>   (0 diff) and **~2000× faster** (0.31s vs 631s on 100K, count 1000).
> - ✅ `filter.sample` — CPU Poisson-disk subsampling; exact vs PDAL,
>   ~1.6× faster (flat-array voxel linked-lists beat per-voxel heap vectors).
> - ✅ `filter.voxelcentroidnearestneighbor` — CPU; count exact vs PDAL,
>   8/1.62M kept-set diff (FP32 voxel-boundary near-ties).
> - ✅ `read.text` (readers.text) — CSV/delimited reader; read.text→write.text
>   round-trips exactly on 2.6M points (X/Y/Z FP32-relative model).
> - ✅ `write.text` (writers.text) — CSV/delimited writer; values bit-exact
>   vs PDAL on 2.6M points, slightly faster. First I/O port beyond LAS/raster.
> - ✅ `filter.mortonorder` — CPU 2D Z-order reordering via reorder; output
>   bit-identical to PDAL on 2.6M points, ~3.6× faster.
> - ✅ `PointCloud::reorder` + `filter.sort` — new core point-permute (dims +
>   raw records) unblocks ordering filters; sort verified monotonic on 2.6M.
> - ✅ `filter.skewnessbalancing` — CPU ground classification; ground count
>   bit-exact vs PDAL (Z-tie boundary membership tolerance documented).
> - ✅ `filter.iqr` / `filter.mad` — CPU IQR/MAD outlier culling; bit-exact
>   vs PDAL on the real tile (Z, Intensity).
> - ✅ `filter.gpstimeconvert` — CPU, gt/gst/gws/gds conversions; 4 conversions
>   bit-exact vs PDAL on the real tile (mktime date math replicated).
> - ✅ `filter.neighborclassifier` — GPU kNN majority-vote relabel, ~27×
>   faster; **exact** (0/2.6M differ). domain supported; candidate-file not.
> - ✅ `filter.lof` — GPU 3-pass Local Outlier Factor, ~43× faster (1.0s vs
>   44.7s); ≤4 pt/2.6M at thresholds, analytic outlier=11.5/interior=1.0.
> - ✅ `filter.head` / `filter.tail` — CPU compact, PDAL HeadTailFilterTest
>   ported exact (count + invert).
> - ✅ `filter.reciprocity` — GPU kNN-of-kNN, **~76× faster** (1.8s vs
>   137s — PDAL's most expensive neighborhood filter); analytic exact.
> - ✅ `filter.planefit` / `estimaterank` / `radialdensity` / `nndistance`
>   — GPU neighborhood scalars, 17–34× faster; PDAL planefit & nndistance
>   unit tests ported exact, others analytic + real-tile parity.
> - ✅ `filter.approximatecoplanar` — GPU, eigenvalue-ratio planarity label,
>   ~27× faster (1.14s vs 30.85s); 3 pt/1.87M at thresholds, analytic exact.
> - ✅ `filter.optimalneighborhood` — GPU, entropy-optimal k, ~31× faster
>   (1.30s vs 40.95s); OptimalRadius exact, OptimalKNN within entropy
>   near-tie tolerance. Unlocks covariancefeatures `Density`/`optimized`.
> - ✅ `filter.covariancefeatures` — GPU, 11 eigenfeatures, ~28× faster
>   end-to-end; PDAL unit test ported + real-tile parity within the
>   eigensolver-noise tolerance.

Legend — **Device**: where pcax runs the stage. **Parity**: validated
agreement with PDAL on real USGS lidar (`compare/filter_parity.py`,
2.6M-point CO tile) per `docs/Filters.md`.

---

## 1. Stages pcax implements natively (with PDAL parity)

This mapping is executable: `pcax convert <pdal.json>` translates a PDAL
pipeline into pcax YAML through the table in `src/core/PdalConvert.cpp`
(`pdalStageMappings()`), which carries per-stage option renames
(`mean_k`→`k`, `coord_op`→`pipeline`, `error_on_failure`→`on_error`,
`spatialreference`→`override_srs`), the PDAL options pcax cannot honour
(emitted as `# unsupported:` comments, or a `--strict` failure) and the
semantic guards that turn a stage into a `# TODO` stub (e.g.
`filters.outlier method=radius`, `filters.sample dimension`,
`filters.neighborclassifier candidate`). `tests/test_pdal_convert.cpp`
asserts the table is total over every PDAL type in this section and in the
§3 "done" list, and that every target is a registered pcax stage — add a
row here and a table entry there in the same change.

| pcax stage | PDAL equivalent | Device | Parity vs PDAL |
|---|---|---|---|
| `read.las` | `readers.las` | CPU (parallel chunk decompress) | byte-exact records |
| `write.las` | `writers.las` | CPU (parallel chunk compress) | byte-exact records |
| `write.copc` | `writers.copc` | **GPU** (octree + record assembly; host LAZ coder) | byte-exact records (order + tree layout differ by design); readers.copc window queries identical |
| `writer.gdal_gpu` | `writers.gdal` | **GPU** | ~2–20 cells/M differ (FP32 quantization, documented) |
| `filter.range` | `filters.range` | CPU (threaded) | exact (4 cases) |
| `filter.crop` | `filters.crop` | CPU (threaded) | exact (bbox, outside, polygon+hole) |
| `filter.dem` | `filters.dem` | CPU (threaded) | exact |
| `filter.assign` | `filters.assign` | CPU | exact (incl. `condition`) |
| `filter.decimation` | `filters.decimation` | CPU | exact (streaming semantics) |
| `filter.transformation` | `filters.transformation` | CPU (threaded) | exact @ 1e-7 (FP32 storage) |
| `filter.stats` | `filters.stats` | CPU | exact |
| `filter.elm` | `filters.elm` | CPU | exact (2 configs) |
| `filter.voxeldownsize` | `filters.voxeldownsize` | CPU | exact (first + center modes) |
| `filter.voxelcenternearestneighbor` | `filters.voxelcenternearestneighbor` | CPU | exact (point set) |
| `filter.outlier` (SOR) | `filters.outlier` | **GPU** | exact kNN; ~1 pt/1.5M threshold-tie (FP32, documented) |
| `filter.reproject` | `filters.reprojection` | **GPU** (+CPU PROJ) | matches PROJ; GTG geoid grids, FP64/FP32 toggle |
| `filter.hag_nn` | `filters.hag_nn` | **GPU** | exact |
| `filter.hag_dem` | `filters.hag_dem` | CPU (threaded) | exact |
| `filter.normal` | `filters.normal` | **GPU** | distributions ≤1e-6; occasional threshold flip |
| `filter.eigenvalues` | `filters.eigenvalues` | **GPU** | 1 pt/2.28M (eigensolver noise) |
| `filter.covariancefeatures` | `filters.covariancefeatures` | **GPU** | ≤~13 pt/2.6M at thresholds; analytic values exact (PDAL test ported) |
| `filter.smrf` | `filters.smrf` | CPU | ≥99.99% labels (void-cell tie inpainting) |

**GPU stages** (this table + §2 ml_noise + the newly ported neighborhood
filters listed in §3 as "native (GPU) done"): gdal_gpu, outlier, reproject,
hag_nn, normal, eigenvalues, covariancefeatures, ml_noise,
optimalneighborhood, approximatecoplanar, planefit, estimaterank,
radialdensity, nndistance, reciprocity, lof, neighborclassifier, fps, cluster, dbscan, lloydkmeans, copc — **22 GPU stages**. The remaining native stages
are deliberately CPU: memory-bound single passes where uploading every
dimension would cost more than the compute saves. (New ports are appended to
§3 with a "done" marker rather than relocated, to keep the gap list honest.)

## 2. Stages pcax has that PDAL does NOT

| pcax stage | What it does | Device |
|---|---|---|
| `filter.ml_noise` | LightGBM noise classifier — 48 GPU-computed neighborhood features + hand-rolled tree-ensemble inference (user-supplied LightGBM model). Reference is the Python pipeline, not PDAL; exact decision masks on the CO tile. | **GPU** |

---

## 3. PDAL filters NOT yet native in pcax

All are reachable today via the `pdal.filter` adapter (CPU, PDAL's
implementation). "GPU-amenable" = neighborhood/raster/clustering/linear-
algebra heavy — a candidate for a native GPU port that would beat PDAL.

### Ground / terrain classification
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.pmf` | adapter | **yes** | Progressive morphological — same raster machinery as our SMRF |
| `filters.csf` (cloth sim) | adapter | **yes** | Iterative cloth relaxation — embarrassingly parallel grid |
| `filters.skewnessbalancing` | **native (CPU)** | done | `filter.skewnessbalancing` — ground count bit-exact (Z-tie tolerance) |
| `filters.sparsesurface` | **native (CPU)** | done | `filter.sparsesurface` — greedy noise marking, ~3.9× faster |

### Neighborhood / geometric features (all share our kNN grid)
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.covariancefeatures` | **native (GPU)** | done | `filter.covariancefeatures` — 11 eigenfeatures, knn/radius/optimized modes, ~28× faster than PDAL end-to-end |
| `filters.optimalneighborhood` | **native (GPU)** | done | `filter.optimalneighborhood` — entropy-optimal k, ~31× faster; feeds covariancefeatures Density/optimized |
| `filters.approximatecoplanar` | **native (GPU)** | done | `filter.approximatecoplanar` — eigenvalue-ratio planarity label, ~27× faster |
| `filters.planefit` | **native (GPU)** | done | `filter.planefit` — point-to-plane fit criterion, ~34× faster |
| `filters.radialdensity` | **native (GPU)** | done | `filter.radialdensity` — count-in-radius / volume, ~17× faster |
| `filters.nndistance` | **native (GPU)** | done | `filter.nndistance` — kth/avg neighbor distance, ~27× faster |
| `filters.estimaterank` | **native (GPU)** | done | `filter.estimaterank` — SVD rank per neighborhood, ~25× faster |
| `filters.reciprocity` | **native (GPU)** | done | `filter.reciprocity` — reciprocal-NN test, ~76× faster |
| `filters.miniball` | adapter | yes | Min bounding sphere per neighborhood |
| `filters.lof` | **native (GPU)** | done | `filter.lof` — Local Outlier Factor, 3-pass, ~43× faster |
| `filters.neighborclassifier` | **native (GPU)** | done | `filter.neighborclassifier` — kNN majority-vote relabel, ~27× faster, exact (candidate-file via adapter) |
| `filters.zsmooth` | adapter | yes | Neighborhood Z smoothing |

### Clustering / segmentation
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.dbscan` | **native (GPU)** | done | `filter.dbscan` — density clustering, 99.99% agreement, ~10× faster |
| `filters.cluster` | **native (GPU)** | done | `filter.cluster` — connected components, partition 99.994% match, ~3× faster |
| `filters.supervoxel` | adapter | yes | Over-segmentation |
| `filters.litree` | adapter | yes | Tree segmentation (Li 2012) |
| `filters.lloydkmeans` | **native (GPU)** | done | `filter.lloydkmeans` — exact ClusterID, ~27× faster |

### Resampling / reordering
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.voxelcentroidnearestneighbor` | **native (CPU)** | done | `filter.voxelcentroidnearestneighbor` — count exact vs PDAL |
| `filters.sample` (Poisson-disk) | **native (CPU)** | done | `filter.sample` — exact vs PDAL, ~1.6× faster |
| `filters.fps` (farthest point) | **native (GPU)** | done | `filter.fps` — exact set, ~2000× faster |
| `filters.mortonorder` | **native (CPU)** | done | `filter.mortonorder` — 2D Z-order, bit-exact order vs PDAL |
| `filters.sort` | **native (CPU)** | done | `filter.sort` — multi-dim ASC/DESC/stable, via PointCloud::reorder |
| `filters.randomize` | adapter | no | |
| `filters.griddecimation` | adapter | no | 2D grid min/max |
| `filters.relaxationdartthrowing` | adapter | yes | |
| `filters.chipper` / `filters.divider` / `filters.splitter` | adapter | no | Tiling/partitioning (needs multi-cloud executor) |
| `filters.separatescanline` | adapter | no | |

### Attribute / selection / utility
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.ferry` | adapter | no | Dim copy/rename — easy native add |
| `filters.expression` / `filters.mongoexpression` | adapter | no | Expression engine; `filter.assign` covers the common case |
| `filters.returns` | adapter | no | Return-class split — trivial native add |
| `filters.head` / `filters.tail` | **native (CPU)** | done | `filter.head` / `filter.tail` — count + invert, PDAL test ported |
| `filters.colorization` | adapter | no | Raster→RGB sampling (like `filter.dem`) |
| `filters.colorinterp` | adapter | no | Color ramp |
| `filters.overlay` | adapter | no | Polygon→attribute (GEOS, like crop) |
| `filters.radiusassign` / `filters.geomdistance` | adapter | yes | Distance-to-geometry |
| `filters.gpstimeconvert` | **native (CPU)** | done | `filter.gpstimeconvert` — gt/gst/gws/gds, bit-exact |
| `filters.labelduplicates` | adapter | no | |
| `filters.iqr` / `filters.mad` | **native (CPU)** | done | `filter.iqr` / `filter.mad` — robust outlier culling, bit-exact |
| `filters.groupby` | adapter | no | (needs multi-cloud executor) |
| `filters.merge` | **not supported** | no | **Executor limitation** — single shared cloud, no branch/merge DAG |

### Coordinate / geometry
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.projpipeline` | **native (GPU)** | done | `filter.reproject` with `pipeline:` (PDAL `coord_op`) — the explicit PROJ pipeline compiles into the GPU op-chain; `pcax convert` maps it |
| `filters.georeference` | adapter | yes | Trajectory→ECEF |
| `filters.straighten` | adapter | no | |
| `filters.h3` / `filters.hexbin` | adapter | no | Spatial indexing/binning |

### Surface / mesh (pcax has none; emits point clouds + rasters, not meshes)
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.delaunay` | adapter | yes | 2.5D triangulation |
| `filters.poisson` | adapter | **yes** | Screened Poisson reconstruction |
| `filters.greedyprojection` | adapter | yes | |
| `filters.faceraster` | adapter | no | Mesh→raster |
| `filters.hag_delaunay` | adapter | yes | TIN-based HAG |

### Registration / change detection (pcax has none)
| PDAL filter | Native? | GPU-amenable | Notes |
|---|---|---|---|
| `filters.icp` | adapter | **yes** | ICP registration — large GPU win |
| `filters.cpd` (if built) | adapter | yes | Coherent point drift |
| `filters.m3c2` | adapter | **yes** | Multiscale cloud-to-cloud change |

### Metadata / info
| PDAL filter | Native? | Notes |
|---|---|---|
| `filters.info` / `filters.locate` / `filters.expressionstats` | adapter | Inspection — `filter.stats` covers summary stats |

---

## 4. I/O format coverage

| Format | Read | Write | pcax native | PDAL |
|---|---|---|---|---|
| LAS / LAZ | ✅ | ✅ | **native (parallel laz-perf)** | ✅ |
| GDAL raster (DSM/DTM) | — | ✅ | **native GPU (`writer.gdal_gpu`)** | ✅ (`writers.gdal`, CPU) |
| COPC | ✅ (as LAZ; hierarchy ignored) | ✅ | **native GPU write (`write.copc`) + viewer host (`pcax serve`)** | ✅ (`writers.copc`, CPU; no viewer) |
| EPT | adapter only | — | ❌ | ✅ |
| Text / CSV | **native (`read.text`)** | ✅ | **native (`read.text` / `write.text`)** | ✅ |
| PLY | **native (`read.ply`)** | ✅ | **native (`read.ply` / `write.ply`, ascii+binary_le)** | ✅ |
| PCD / OBJ / BPF / E57-via-plugins / I3S / SLPK / GeoTIFF-points / SBET / TerraSolid | adapter only | adapter only | ❌ | ✅ (27 readers / 14 writers) |

pcax's format breadth is intentionally narrow: it targets the
compute-heavy LAS/LAZ + raster lidar path. Everything else is delegated to
PDAL via the adapter or left to a PDAL pre/post step.

---

## 5. Where pcax already beats PDAL

- **GPU SOR / reproject / HAG / normals / eigenvalues / ml_noise / DSM-DTM
  rasterization.** PDAL runs all of these single-threaded on CPU. pcax's
  end-to-end LAZ→SOR→LAZ pipeline is ~6× faster than the LASlib path on a
  2.6M tile (README), and the heavy neighborhood stages move from
  minutes to seconds on GPU.
- **Parallel chunked LAZ I/O** (laz-perf, 16 threads): 7–8× over
  single-thread read/write — PDAL's `readers.las` is serial.
- **Built-in ML noise classification** with on-GPU feature extraction —
  no PDAL equivalent.
- **Profiler-first design** (`pcax run -d`): per-stage time + RAM,
  GPU timers built into the neighborhood kernels.

## 6. Where pcax can *genuinely* do better — GPU-native roadmap

Ranked by leverage (reuses existing infra × demand × PDAL pain):

1. **CovarianceFeatures** ✅ and **OptimalNeighborhood** ✅ done.
   **ApproximateCoplanar, PlaneFit, EstimateRank, RadialDensity,
   NNDistance** ✅ all done. The GPU covariance/eigensolver,
   the shared `NeighborhoodMath.cuh` kNN, and the streaming `radiusCovariance`
   now exist. This is the feature set ML segmentation pipelines consume — and
   PDAL computes it one point at a time.
2. **GPU PMF + CSF ground filters.** SMRF's GPU-ready raster machinery
   (diamond erosion, gradients, inpainting) is already mostly here on CPU;
   PMF shares it and CSF is an iterative grid relaxation — both are
   textbook GPU wins. Would give pcax all three major ground filters
   GPU-native.
3. **GPU radialdensity / nndistance / lof / dbscan / cluster.** All ride
   the existing `SpatialGrid.cuh` uniform-grid kNN. Density and clustering
   are where PDAL is slowest on big tiles; connected-components and LOF
   parallelize cleanly.
4. **GPU ICP + M3C2 change detection.** No native registration today.
   ICP (kNN correspondence + SVD per iteration) and M3C2 (cylinder
   neighborhood projections) are both GPU-shaped and are the marquee
   change-detection workloads — a strong differentiator vs PDAL.
5. **GPU resampling: Poisson-disk `sample`, farthest-point, Morton sort.**
   Common preprocessing; GPU radix sort + grid make these trivial wins.
6. **Multi-cloud executor** (unblocks `merge`, `groupby`, `chipper`,
   `divider`, tiling). Currently the executor runs one shared cloud with
   no branch/merge — the single biggest structural gap vs PDAL's DAG.
   Prerequisite for tiled out-of-core processing of clouds larger than GPU
   memory.
7. **Cheap native ports** (no GPU needed, just close the gap):
   `ferry`, `returns`, `head`/`tail`, `colorization`, `overlay` — small
   CPU stages that remove adapter round-trips.

**Strategic framing:** pcax should not chase PDAL's 88-filter breadth.
The win is owning the *compute-bound* core — neighborhood features, ground
classification, density/clustering, registration, ML — on GPU, while
delegating format breadth and bookkeeping filters to PDAL via the adapter.
Items 1–3 alone would make pcax the fastest path for the
features→ground→density preprocessing stack that feeds ML and DSM/DTM
products.
