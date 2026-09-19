# Changelog — Point Cloud Accelerator (`pcax`)

## 0.1.0 — 2026-09-19

First release, source-available under the Point Cloud Accelerator License:
evaluation is free for everyone, with no time limit; every other use needs a
commercial license; no redistribution.

- GPU point-cloud pipeline runner `pcax` (CUDA on Linux, Metal on Apple
  Silicon): YAML pipelines, `run` / `validate` / `analyze` / `info` /
  `convert` / `serve`.
- 50+ stages with PDAL-equivalent semantics, parity-tested against PDAL on
  USGS lidar (`docs/PdalFeatureMatrix.md`, `docs/Parity.md`); LightGBM noise
  classifier with a user-supplied model.
- Readers/writers: LAS/LAZ (parallel chunked laz-perf), COPC 1.0 (GPU octree,
  byte-exact records vs PDAL), GeoTIFF rasterisation, text, PLY.
- `pcax convert`: PDAL pipeline JSON → pcax YAML.
- `pcax serve`: range-request host with an embedded Potree viewer.
- Comparator (`compare/`) for head-to-head benchmarking and per-stage parity
  against the system PDAL.
- Conda packages for linux-64 (CUDA 13) and osx-arm64 (Metal) from
  `https://conda.adv-algos.net/pcax`; `cmake --install` installs the binary,
  the Metal kernel library (`share/pcax/pcax.metallib`, resolved relative to
  the executable) and the license notices. See docs/Install.md.
- Builds against GDAL 3.13; on macOS the deployment target is 14.0 (metal3.1),
  backend-neutral unit tests run under Metal, and `ml_noise` checksums fall
  back to `shasum -a 256`.
