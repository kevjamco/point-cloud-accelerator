# Metal backend — native macOS / Apple Silicon GPU support

pcax was built CUDA-first. This document describes the **Metal compute
backend** that lets pcax run natively on macOS (Apple Silicon), the
GPU-backend abstraction that makes CUDA and Metal interchangeable per
filter, and the FP32-only contract Metal enforces.

> **Status:** living document — tracks the design and the port progress.
> Newest decisions are reflected inline; the progress checklist at the
> bottom is the source of truth for what is implemented vs stubbed.

## Why a backend abstraction (not a rewrite)

The CUDA code already had a clean shape: a `PointCloud` that owns SoA
dimension arrays plus per-dimension device residency
(`uploadToDevice`/`downloadFromDevice`/`devicePtr`), a shared uniform
grid (`SpatialGrid.cuh`), and per-filter `.cu` kernels invoked from a
host `.cpp`. The split between **host orchestration** (residency, option
parsing, grid bookkeeping, stats) and **device kernels** (`__global__`
functions) is exactly the seam a second backend plugs into.

CUDA and Metal cannot share kernel *source* (CUDA C++ `<<<>>>` vs MSL
compiled to a `.metallib` and dispatched through command encoders), so
the abstraction draws the line at the **host API**:

```
        ┌─────────────────────────────────────────────┐
        │ Filter host code  (XFilter.cpp)              │  shared, backend-agnostic
        │  - option parse, FP32 guard, residency       │
        │  - calls xFilterRun(cloud, params)           │
        └───────────────────┬─────────────────────────┘
                            │  declared in XFilterGpu.hpp
            ┌───────────────┴───────────────┐
            ▼                               ▼
   XFilter.cu  (CUDA kernels)   XFilter.metal.cpp + XFilter.metal
   <<<grid,block>>>                  MSL kernels, encoder dispatch
            │                               │
            └──────────────┬────────────────┘
                          ▼
              pca::gpu  abstraction (include/pca/gpu/)
   Context · Buffer · Encoder · primitives (sortPairsU32, scan, reduce)
            ┌───────────────┴───────────────┐
            ▼                               ▼
        cuda backend                   metal backend
   (CUDA runtime, CUB, Thrust)   (metal-cpp, vendored MSL primitives)
```

### Adding a GPU filter that supports both backends

1. Put the backend-agnostic host code in `XFilter.cpp` (registration,
   option parsing, FP32 guard, residency). It calls a single entry point
   declared in `XFilterGpu.hpp`, e.g.
   `void xFilterRun(PointCloud&, const XParams&);`
2. Implement that entry point twice:
   - `XFilter.cu` — CUDA kernels + `<<<>>>` launches.
   - `XFilter.metal.cpp` (host dispatch via `pca::gpu`) + `XFilter.metal`
     (MSL kernels). Reuse `pca::gpu` primitives (grid build, sort, scan)
     so only the genuinely filter-specific kernels are rewritten.
3. Register the source files in `CMakeLists.txt` under the right backend
   list (`PCA_GPU_SOURCES_CUDA` / `PCA_GPU_SOURCES_METAL`). The shared
   `.cpp` goes in `PCA_STAGE_SOURCES`.

## Backend selection (build)

`CMakeLists.txt` chooses the backend at configure time:

| Platform | `PCA_GPU_BACKEND` default | Languages | Deps added |
|---|---|---|---|
| Apple    | `METAL` | `CXX` | metal-cpp (vendored, `extern/metal-cpp`), Metal/Foundation frameworks, `.metal`→`.metallib` build step |
| other    | `CUDA`  | `CXX CUDA` | CUDA toolkit, CUB/Thrust |

You can force a backend with `-DPCA_GPU_BACKEND=METAL|CUDA`. There is no
runtime backend switch — it is compile-time, like the LAZ backend.

The Metal toolchain (for `xcrun metal`) ships separately on recent Xcode:
`xcodebuild -downloadComponent MetalToolchain`. CMake probes for it at
configure time and fails with a clear message if missing.

## The `pca::gpu` abstraction (`include/pca/gpu/`)

- **`Buffer`** — opaque device allocation. CUDA: a `cudaMalloc` pointer.
  Metal: an `MTL::Buffer` (`StorageModeShared`, so it is also host-visible
  at `contents()`). `PointCloud` stores one `gpu::Buffer` per resident
  dimension. `devicePtr(id)` returns the kernel-facing pointer (CUDA
  device ptr / Metal host-visible contents); `gpuBuffer(id)` exposes the
  backend handle that encoders bind.
- **`Context`** (Metal) — singleton owning `MTL::Device`, a shared
  `MTL::CommandQueue`, and the compiled `MTL::Library` (loaded from the
  embedded `pcax.metallib`). Caches `MTL::ComputePipelineState` by kernel
  name. Carries a capability struct (`hasFloatAtomics`,
  `hasSimdReduction`, `unifiedMemory`) — all true on M1 Max (Apple7).
- **`Encoder`** (Metal) — thin wrapper over `MTL::ComputeCommandEncoder`
  with verbs `setPipeline(name)`, `setBuffer(buf, idx)`,
  `setBytes(&v, n, idx)`, `dispatch(nThreads)` /
  `dispatch1D(n, tgSize)`. Modeled on MLX's `CommandEncoder`.
- **Parallel primitives** (`pca::gpu::prim`) — the CUB/Thrust gap. Metal
  has no MPS sort and no Thrust, so these are vendored MSL kernels driven
  from the host:
  - `sortPairsU32(keys, values, n)` — LSB radix sort of (uint32,uint32)
    pairs (grid binning). CUDA: `cub::DeviceRadixSort::SortPairs`.
  - `exclusiveScanU32(in, out, n)` — CUDA: `cub::DeviceScan::ExclusiveSum`.
  - `reduce*` — built on `simd_sum` + threadgroup partials (Apple7+).

## Unified memory

On Apple Silicon CPU and GPU share physical memory. `gpu::Buffer` uses
`MTL::ResourceStorageModeShared`, so `uploadToDevice`/`downloadFromDevice`
become *no-ops on the data path* (the bytes are already visible to both);
they only flip residency bookkeeping. This removes the largest source of
overhead in the CUDA path (PCIe copies) and is why the Metal numbers beat
both PDAL and, on I/O-bound stages, the discrete-GPU CUDA path.

## FP32-only contract

The Metal backend is **FP32-only by design** (Apple GPUs are FP32-first;
FP64 is emulated and slow, and pcax's relative-coordinate storage is FP32
anyway). The contract:

- Any stage option `precision: fp64` → hard error on the Metal backend,
  naming the stage, before any GPU work.
- Filters whose CUDA path *only* exists in FP64 (none ship that way after
  this port — `filter.normal`, `filter.eigenvalues`, `filter.hag_nn`,
  `filter.ml_noise` get FP32 Metal kernels) document their parity under
  FP32 in `docs/Filters.md`.
- The guard lives in one place: `pca::gpu::requireFp32(stageName, opts)`
  (`include/pca/gpu/Fp32Guard.hpp`), called by every GPU stage's option
  parse. On CUDA it is a no-op.

## Parity & performance targets

- **Correctness:** Metal output is validated against the committed
  integration baselines and against PDAL on real tiles, same as CUDA.
  FP32-storage tolerances already documented in `CLAUDE.md` apply; Metal
  adds no new divergence class beyond FP32 distance math (which CUDA's
  `precision: fp32` path already exercises and which is measured
  bit-comparable on real tiles for SOR).
- **Performance:** every stage must beat PDAL, target 5–10×. Benchmarks
  live in the `perf` integration tier and `compare/pdal_compare.py`; numbers
  are logged in docs/Parity.md.

## Measured results

| Stage | Test | Result |
|---|---|---|
| foundation | `test_metal_hello` (M1 Max) | PASS — vec-add 100k in 0.039 ms; unified/simd/float-atomics all present |
| `filter.outlier` (SOR) | parity vs PDAL `filters.outlier` (k=8, mult=2.0) on `everglades_subset.laz` (1,569,508 pts) | **point-exact**: both flag 38 noise points, 1,569,508/1,569,508 agreement (0 disagreements) |
| `filter.outlier` (SOR) | perf vs PDAL, same pipeline (read→outlier→write) | pcax **3.28 s** total (read 103 ms · SOR 3.05 s · write 90 ms) vs PDAL **42.2 s** → **12.9× faster** |
| `filter.normal` | distribution vs PDAL `filters.normal` (knn=8), 1.57 M pts | NormalZ mean 0.999655 (identical), std 0.018549 vs 0.018553; NormalX/Y match to ~3 dp; Curvature max 0.001137 vs 0.0011, std 2e-6 (identical) — FP32-precision parity (FP32 eigensolve vs PDAL double; no exact-match expected, same tolerance class as CUDA) |
| `filter.normal` | perf vs PDAL | pcax **2.83 s** (normal stage) vs PDAL **44.7 s** → **~15× faster** |
| `filter.eigenvalues` | sanity, 1.57 M pts | λ0≈0 (planar), ascending; runs in 2.80 s |
| `filter.hag_nn` | parity vs PDAL `filters.hag_nn` (count=1), 1.57 M pts (297,588 ground) | HAG mean 0.376035 vs PDAL 0.376033 (Δ 2e-6); std/min/max identical (0.984405 / −88.77 / 35.07) — point-accurate |
| `filter.hag_nn` | perf vs PDAL | pcax **131 ms** (hag stage) / 241 ms total vs PDAL **2.95 s** → ~12–20× faster |
| `filter.reproject` | parity vs PDAL `filters.reprojection` (NAD83(2011)+NAVD88 → EPSG:32617), 1.57 M pts | X/Y means identical; max\|Δ\| 0.5 mm (FP32 1 mm-scale storage quantum), Z exact — host PROJ FP64 transform, matches PDAL to storage resolution |
| `filter.reproject` | timing | reproject stage 102 ms (plan 22 ms + host PROJ 43 ms); runs on CPU PROJ on Metal by design (FP64 accuracy) |
| `writer.gdal_gpu` | parity vs PDAL `writers.gdal` (radius, fixed grid), 1.57 M pts | grid dims + geotransform exact, nodata mask identical; cells matching: min 99.99% · max 99.91% · mean 99.85% · idw 99.94% · stdev 99.74% · count 96.89% (rest = FP32 cell-edge/radius flips, documented tolerance) |
| `writer.gdal_gpu` | timing | stats kernel 36–127 ms; full read→raster ~275 ms vs PDAL ~0.8 s |
| `filter.ml_noise` | inference vs `lightgbm.Booster.predict` on GPU features, 1.57 M pts | **1 mask flip / 1,569,508** (0.00006%, one near-threshold FP32 leaf-sum tie) |
| `filter.ml_noise` | Tier-1 regression vs CUDA baseline | Classification.mean 1.2029253753405527 vs baseline 1.2029253753406128 — matches to 13 sig figs (PASS) |
| `filter.ml_noise` | end-to-end, 1.57 M pts | runs (24,571 noise, 1.566%) in 11.2 s (kNN 6.9 s + inference 2.3 s); reference is the Python `noise_filter`, not PDAL |
| **Phase 9 — PDAL-parity neighborhood filters (Apple M1 Max, FP32)** — all parity numbers below are on `everglades_subset.laz` (1,569,508 pts, geographic CRS), via `compare/filter_parity.py`; derived dims are not written to LAS, so each chains a `filter.range` on the derived dim and the surviving COUNT is the parity signal. | | |
| `filter.planefit` | parity vs PDAL `filters.planefit` (knn=8), surviving `PlaneFit[0.2:]` | pcax **487** vs PDAL **484** (Δ 3 / 1.57 M, **99.99981%**) — eigensolver near-tie class (CLAUDE.md ≤6/2.12 M). **PASS** |
| `filter.estimaterank` | parity vs PDAL `filters.estimaterank` (knn=8, thresh=0.01), surviving `Rank[1:1]` (the rare non-planar set — the most threshold-sensitive subset) | pcax **989** vs PDAL **1060** (Δ 71 / 1.57 M, **99.99547%**) — degenerate-eigenvalue near-ties at the rank boundary; proportional to the documented ≤4/28 K. **PASS** |
| `filter.radialdensity` | parity vs PDAL `filters.radialdensity` (radius=0.00002 deg ≈ 2 m), surviving `RadialDensity[1e15:]` | pcax **227,715** vs PDAL **227,743** (Δ 28 / 1.57 M, **99.99822%**) — FP32 radius-cutoff near-ties (documented ≤4/146 K). **PASS** |
| `filter.nndistance` | parity vs PDAL `filters.nndistance` (mode=kth, k=10), surviving `NNDistance[1e-4:]` | pcax **31,082** vs PDAL **31,082** — **point-exact** at this threshold. **PASS** |
| `filter.reciprocity` | parity vs PDAL `filters.reciprocity` (knn=8), surviving `Reciprocity[0.001:]` | pcax **1,037,291** vs PDAL **1,037,346** (Δ 55 / 1.57 M, **99.99650%**) — kNN-boundary near-ties (documented ≤29/762 K). **PASS** (required a watchdog fix — see below) |
| `filter.optimalneighborhood` | parity vs PDAL `filters.optimalneighborhood` (min_k=10, max_k=14), surviving `OptimalKNN[12:14]` | pcax **886** vs PDAL **895** (Δ 9 / 1.57 M, **99.99943%**) — OptimalKNN entropy-argmin adjacent-k flips (documented ≤31/544 K). **PASS** |
| `filter.lof` | parity vs PDAL `filters.lof` (minpts=10), surviving `LocalOutlierFactor[1.5:]` | pcax **11,271** vs PDAL **11,272** (Δ 1 / 1.57 M, **99.99994%**) — kNN-of-kNN boundary near-tie (documented ≤4/2.6 M). **PASS** |
| `filter.neighborclassifier` | parity vs PDAL `filters.neighborclassifier` (k=10), full Classification (the exact-mask filter — Classification is written to LAS, so compared point-for-point) | count **exact** (1,569,508); **15** per-point class flips (all 1↔2 ground/unclassified vote ties at kNN boundaries), **99.99904%** agreement; mean 1.173700 vs 1.173701. **PASS** (FP32 kNN tie-break vs PDAL nanoflann; sub-1-point-in-100K) |
| `filter.fps` | smoke + count vs PDAL `filters.fps` (count=5000); fps drops points, so the count is compared directly | pcax-Metal runs cleanly (`kept 5000 of 1,569,508`) and outputs **exactly 5000** points — matches PDAL's structural output count (both keep exactly `count`; seed-0 greedy with lowest-index tie-break, identical to `Segmentation::farthestPointSampling`). **PASS**. Note: PDAL's CPU FPS is O(N·count) single-threaded (~20+ min on this tile); the pcax-Metal path does the same all-pairs argmax via per-iteration GPU dispatch + host argmax. |
| `filter.reciprocity` | Metal watchdog fix | reciprocity is kNN-of-kNN: each thread runs 1+knn full kNN searches (~knn× the per-thread cost of the other neighborhood kernels), so a single command buffer over all 1.57 M points exceeded the macOS GPU watchdog (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`). Fixed by `dispatch1DChunked` (MetalContext) — the grid is split into 64 K-point chunks, each its own command buffer, with the kernel reading a `base` offset (`tid = base + thread_position_in_grid`). Math is identical to the single-dispatch path. The other four neighborhood kernels, `lof`, and `optimalneighborhood` stay single-dispatch (they complete well under the watchdog). |

The SOR kNN kernel (~3 s) dominates and has headroom (the CUDA path does
the same search in ~1.5 s); read/write are already 100×-class faster than
PDAL thanks to laz-perf parallel I/O. Even so the full pipeline clears the
5–10× target. See docs/Parity.md for the dated run log.

## Progress checklist

- [x] **Phase 1** — build foundation: CMake dual-backend (`PCA_GPU_BACKEND`),
      metal-cpp vendored, `MetalContext` (device/queue/library/PSO cache/
      caps), unified-memory `PointCloud` residency, FP32 guard, metallib
      build step, `test_metal_hello`. Green build; all CPU stages + read/
      write work on Metal.
- [x] **Phase 2** — Metal uniform grid: counting-sort build (atomic
      cell-counts + host exclusive scan over unified memory + atomic
      scatter; `grid.metal` + `SpatialGridMetal`). Equivalent to the CUDA
      CUB-radix grid; intra-cell order differs but every query is
      order-independent.
- [x] **Phase 3** — `filter.outlier` (SOR) on Metal: expanding-ring kNN
      kernel (`sor.metal`), host stats, host classify. Point-exact vs PDAL,
      12.9× faster (see table above).
- [x] **Phase 4** — `filter.normal` / `filter.eigenvalues` on Metal (FP32
      Jacobi eigensolve, 3D ring kNN; `normal.metal` + `NormalFilters.metal.cpp`).
      Split `NormalFilters.cu` into neutral `NormalFilters.cpp` (classes +
      registration) + CUDA entry functions in `NormalFilters.cu`. Output dims
      stay Float64 (widened from FP32 on write). FP32-precision parity with
      PDAL, ~15× faster (see table).
- [x] **Phase 5** — `filter.hag_nn` on Metal (`hag.metal` +
      `HagFilters.metal.cpp`): grid on ground points, kNN-to-ground HAG.
      Split `HagFilters.cu`; the CPU `filter.hag_dem` moved to the neutral
      `HagFilters.cpp` (now available on Metal too). Point-accurate vs PDAL,
      ~12–20× faster (see table).
- [x] **Phase 6** — `writer.gdal_gpu` on Metal (`gdal.metal` +
      `GdalGpuWriter.metal.cpp`). One-thread-per-cell stats (bin + radius
      modes; min/max/mean/stdev/count/idw) so no float atomic-min/max is
      needed; **shifted FP32 accumulation** (`Σ(v−v0)`) avoids variance
      cancellation (no device FP64); percentiles sorted per-cell on the host
      (no segmented sort on Metal). `GdalGpuGridParams` extracted to a shared
      `GdalGpuGridParams.hpp` (removes the prior .cpp/.cu duplication). Parity
      vs PDAL `writers.gdal`: grid dims + geotransform exact, nodata mask
      identical, ≥99.7% of cells match for min/max/mean/idw/stdev (count
      ≥96.9%); the rest are FP32 cell-edge/radius-cutoff flips (documented
      tolerance). Writer stage ~36–175 ms; several× faster than PDAL.
- [x] **Phase 7** — `filter.reproject` on Metal. Reprojecting real-world
      coordinates needs FP64 (the CUDA path defaults to fp64), which Apple
      GPUs lack, so on Metal reproject runs on the existing host PROJ
      executor (FP64-accurate, multithreaded) — the CUDA GPU chain is
      `#ifdef PCA_GPU_CUDA`. Sub-mm parity vs PDAL (see table). This is the
      one GPU-tagged stage that deliberately executes on the host on Metal.
- [x] **Phase 8** — `filter.ml_noise` on Metal (`mlnoise.metal` +
      `MlNoiseFilter.metal.cpp`): FP32 ports of the 48-feature kernels (kNN
      stats, k=16/32 covariance eigenfeatures) + the LightGBM ensemble tree
      walk; the 2D-cell percentile features and tile-level stats run on the
      host over unified memory (no segmented sort on Metal). Inference 1 flip
      / 1.57 M vs `lightgbm.predict`; Tier-1 baseline matches CUDA to 13 sig
      figs (see table).

**All eight phases are complete — every GPU stage runs on Metal.**

- [x] **Phase 9** — the PDAL-parity GPU filters get Metal kernels:
      `filter.approximatecoplanar`, `filter.covariancefeatures`,
      `filter.optimalneighborhood`, `filter.planefit`, `filter.estimaterank`,
      `filter.radialdensity`, `filter.nndistance`, `filter.reciprocity`,
      `filter.neighborclassifier`, `filter.lof`, `filter.fps`,
      `filter.cluster`, `filter.dbscan`, `filter.lloydkmeans`. Each uses the
      established trio split (backend-neutral `*.cpp` class + registration,
      CUDA `*.cu`, Metal `*.metal.cpp` + `kernels/*.metal`) and the shared
      FP32 helpers in `kernels/NeighborhoodMath.h` (the MSL counterpart of
      `src/filters/NeighborhoodMath.cuh`: `knn3d`, `eigen3x3`,
      `neighborhoodCovariance`, `radiusCount`, `radiusCovariance`).
      Metal-specific choices: `fps`/`lloydkmeans` replace `thrust::max_element`
      with a host argmax over unified memory; `lloydkmeans` accumulates
      centroids host-side in double; `cluster`/`dbscan` use Metal integer
      atomics (`atomic_fetch_min`/`atomic_fetch_or`) with the host driving the
      label-propagation convergence loop.
      **Status: VERIFIED on Apple M1 Max (`-DPCA_GPU_BACKEND=METAL`, FP32).
      The 9 neighborhood/sampling filters
      (`optimalneighborhood`, `planefit`, `estimaterank`, `radialdensity`,
      `nndistance`, `reciprocity`, `neighborclassifier`, `lof`, `fps`) each
      run on Metal and match PDAL within the documented FP32 near-tie
      tolerance — see the Phase 9 rows in the results table above
      (≥99.99% point agreement; `nndistance` point-exact). One real bug was
      found and fixed in the process: `filter.reciprocity` (kNN-of-kNN, ~knn×
      the per-thread work) tripped the macOS GPU watchdog in a single command
      buffer; fixed with chunked dispatch (`dispatch1DChunked`). The
      `approximatecoplanar`/`covariancefeatures`/`cluster`/`dbscan`/
      `lloydkmeans` Metal kernels were verified in earlier Phase-9 commits.**

### Remaining follow-ups (not blockers)

- [ ] Metal-aware integration tier: the committed Tier-1/parity baselines
      were generated on CUDA (FP64 default). On Metal the FP32 SOR/normal
      paths diverge from those baselines within the documented FP32 tolerance
      (per-stage parity vs PDAL is verified above); the `gpu-fp64` variant
      should assert the FP32-guard error rather than run. Regenerate
      Metal baselines with `pytest tests/integration --update-baselines` on
      an Apple machine, or add a backend dimension to the suite.
- [ ] SOR kNN kernel optimization (~3 s; CUDA does ~1.5 s) — register-pressure
      / threadgroup tuning; already 12.9× faster than PDAL end-to-end.
</invoke>
