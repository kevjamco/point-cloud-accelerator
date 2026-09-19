# Roadmap

pcax is an alpha. The stages listed in the README are feature-complete and
parity-tested; the items below are known gaps and planned work, roughly in
priority order. Issues and pull requests welcome.

## Executor

- **Multi-cloud executor.** Pipelines are a DAG in YAML but execute linearly
  over one shared cloud. Branch/merge (and a `filters.merge` port) needs the
  executor to hold several clouds.
- **Stage-lifetime device arena.** Each GPU stage `cudaMalloc`s independently,
  so `pcax analyze` can say "fits" and a fragmented pool can still refuse one
  large request. One arena per stage, sized from the analyzer's own
  coefficients, would make the prediction self-enforcing.
- **`pcax analyze` soft spots.** CUB scratch sizes are estimated rather than
  queried; the CUDA context overhead is a measured constant; `hag_nn`'s
  ground subset is bounded by N. All err conservative.

## Stages

- **`pcax convert --to-pdal`.** The reverse direction of `pcax convert`, from
  the same mapping table, so the comparator's twin pipelines are generated
  rather than hand-kept in lockstep.
- **SOR kNN two-pass compaction.** The exact expanding-ring kNN is correct but
  slow on sparse tiles (warp divergence from sparse lanes). Pass 1 bounded,
  compact the unfinished points, pass 2 unbounded over those only.
- **write.copc**: Metal port of the GPU octree (Metal builds use the host
  reference path today); multi-page hierarchy for > ~1 M nodes; optional
  denser coarse levels (centroid-nearest voxel pick); the LAZ coder is the
  wall-clock bottleneck on tiles with few large nodes.
- **filter.ml_noise on Metal**: port the fused kNN/eigen kernel (CUDA: 352 →
  231 B/point); the Metal path still materialises the N × 32 index matrix.
- **filter.ml_noise grid ordering**: sorting points into grid order before the
  fused kNN kernel measured ~11% faster; do it inside the stage.
- **writer.gdal_gpu**: more `writers.gdal` options (`bounds`, `metadata`);
  grid-aligned output helpers.
- Remaining PDAL stages without a native port are listed in
  `docs/PdalFeatureMatrix.md` §3.

## Testing & release

- Metal-backend integration baselines (`baselines/metal/`) need regenerating
  on Apple hardware after each GPU stage change; the gpu-fp64 variant should
  assert the FP32-guard error there.
- A self-hosted GPU runner for CI (`.github/workflows/ci.yml` has the opt-in
  job); hosted runners build CUDA and run the device-free unit tests only.
- **Distribution.** Now: source on GitHub plus tagged Releases, and the
  CUDA container image on GitHub Container Registry. Next: an `adv-algos`
  conda channel (Linux + macOS builds against conda-forge GDAL/PROJ/CUDA) and
  a Homebrew tap for the Metal build. conda-forge and Homebrew core are ruled
  out by the source-available license.
