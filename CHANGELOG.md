# Changelog — Point Cloud Accelerator (`pcax`)

## 0.2.0b5 — 2026-10-12 (beta)

Release notes: docs/ReleaseNotes-0.2.0.md.

- **License check.** `pcax run` now needs a grant from the Advanced
  Algorithms license server before it executes (`validate`, `analyze`,
  `info`, `convert` and `serve` are unchanged). Evaluations activate once
  per machine with a verified email (`pcax activate you@example.com`) and
  contact the server on every run; commercial licenses use a token
  (`PCAX_LICENSE_TOKEN`) or an offline lease (`pcax license lease`,
  `PCAX_LICENSE_LEASE`). Every run is reported: stage types, point counts,
  duration, GPU, version, a machine fingerprint hash; never file names or
  data. New exit code 4 (no grant), new commands `pcax activate` and
  `pcax license status|deactivate|lease|privacy`. docs/Licensing.md.
- **Binary-only distribution.** The engine source is no longer published;
  the public repository keeps the docs, example pipelines and the PDAL
  comparator.

## 0.2.0b4 — 2026-10-02 (beta)

Release notes: docs/ReleaseNotes-0.2.0.md.

- `read.las` reads a LAZ file whose chunk table is unusable (compressor
  interrupted before writing it, file cut short, corrupt table): the chunk
  layout is rebuilt from the point data, as LASzip does, and every complete
  chunk is decoded, with a `WARN` giving the recovered point count against
  the header's. Was `unsupported chunk table version N` (N being the
  pointer's own position). Adaptive chunking cannot be rebuilt and is still
  refused.
- `filter.reproject`: a `pipeline` of `+proj=noop` with `out_srs` now
  relabels the output CRS; it returned before writing the CRS, so the
  writers used the file's own CRS. An `out_srs` PROJ cannot read is an
  error instead of being ignored; with `pipeline` the GeoTIFF key record is
  written as well as the WKT.
- `writer.gdal_gpu` no longer fails a finished run on a file CRS that GDAL
  cannot parse: the CRS is dropped with a `WARN` and the raster gets
  `default_srs`, else no CRS. `override_srs` and `default_srs` must parse,
  and all three are resolved before the gridding.
- GeoTIFF `VerticalCSTypeGeoKey` values that are vertical datum codes
  (5101–5106, the GeoTIFF 1.0 table; `EPSG:26914+5103` on 2006-era Texas
  tiles) resolve to the vertical CRS for the datum and unit key, as GDAL and
  PDAL resolve them (`EPSG:26914+5703`). Affects `in_srs` from the file and
  the CRS label of every writer.

## 0.2.0b3 — 2026-10-02 (beta)

Release notes: docs/ReleaseNotes-0.2.0.md.

- LAZ point formats 6–8 are decoded layer by layer (`read.las` and
  `read.copc`), with the same records as before: about 17–20 % less decode
  time on a full read.
- `read.las` `bounds` on formats 6–8 decodes a chunk's X/Y layer first and
  drops the chunk there if no point is inside the box. On a 73 M-point tile
  with a cell edge through it (10 % kept) the read takes 43 % less time.
- `read.las` / `read.copc` `layers`: decode only the record fields the
  pipeline needs (`layers: flags` for a classification + Withheld raster
  pipeline is about 40 % less decode time). Fields left out are zero, their
  attribute dims are not created, and `write.las` / `write.copc` refuse the
  cloud.

## 0.2.0b2 — 2026-10-01 (beta)

Release notes: docs/ReleaseNotes-0.2.0.md.

- Metal: every kernel now runs through a chunked, self-tuning, multi-queue
  `dispatch1D`, so no command buffer can trip the macOS GPU watchdog
  (`kIOGPUCommandBufferCallbackErrorImpactingInteractivity`); the grid packs
  coordinates in cell order for streaming kNN loops; `filter.outlier` finds
  isolated points' neighbors with a cooperative threadgroup pass. A 23.4 M-point
  topobathy tile that died in `filter.outlier` now runs end to end in ~25 s on
  M1 Max, bit-identical. Tunables: `PCAX_METAL_CHUNK_MS`, `PCAX_METAL_MIN_CHUNK`,
  `PCAX_METAL_MAX_CHUNK`, `PCAX_METAL_LANES` (docs/MetalBackend.md).
- `pcax run --profile-json FILE`: the profile as JSON — per stage: time, GPU
  flag, RAM and GPU memory, `points_in`/`points_out`, outcome, GPU sub-steps.
- `pcax run` exit codes: 0 every output written, 3 a writer had no points
  to write, 1 error. `writer.gdal_gpu` and `write.copc` no longer fail the
  run on an empty cloud; they warn and skip their file.
- `run`, `validate` and `analyze` reject unknown options instead of ignoring
  them.
- Consecutive `filter.range` / `filter.crop` / `filter.dem` stages are fused
  into one keep mask and one compaction (identical output). Compaction is
  chunk-parallel and keeps device-resident dims on the GPU, so a GPU stage
  after a dropping filter no longer re-uploads the cloud.
- `read.copc`: reads a COPC file through its octree; with `bounds` only the
  intersecting nodes are decoded. `read.las` gains `bounds` (points dropped
  as chunks decode). Both give exactly a full read plus `filter.crop`.
  `pcax convert` maps `readers.copc` (with `bounds`) to `read.copc`.
- `read.las` no longer has serial sections around the chunk decode: the
  file is memory-mapped, raw records are not zero-filled first, and
  coordinate conversion and attribute extraction run chunk-parallel
  (`write.las` attribute write-back too). Uncompressed LAS is read in
  parallel.
- `filter.reproject` runs PROJ's `+proj=gridshift` on the GPU (bilinear and
  NADCON5's biquadratic grids, height band, PROJ's inverse), so NAD83
  realization changes such as NAD83(2011) → NAD83 no longer fall back to
  host PROJ. The grids are read only over the data's extent.
- `filter.dem`: reads only the raster window under the cloud; new
  `interpolation: bilinear` and `reproject: true` (warp the raster to the
  cloud's CRS). Defaults are unchanged (PDAL semantics).
- `pcax run --batch jobs.jsonl [--batch-out results.jsonl]`: many jobs in
  one process (one GPU context); `pcax analyze --batch` reports the peak
  job's memory and how many workers fit.
- `writer.gdal_gpu`: `merge: true|first` folds the result into an existing
  raster on the same grid (min/max/count compose exactly); `grids` writes
  several fixed grids from one cloud.
- Thread pools size themselves to the CPUs the process may use (affinity
  mask, cgroup CPU quota) instead of the node's core count; `PCAX_THREADS`
  overrides.
- Ships the `writer.gdal_gpu` auto-extent fix listed under 0.1.0 below: it
  was committed after the 0.1.0 tag and is not in the 0.1.0 package.
- Fixed: `filter.assign`, `filter.elm`, `filter.smrf` and
  `filter.transformation` did not mark the dims they write as host-current,
  so a GPU stage after them could read a stale device copy when an earlier
  GPU stage had uploaded the cloud.

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
- Fixed: `writer.gdal_gpu` without an explicit `origin_x`/`origin_y`/
  `width`/`height` grid sized its raster from a stale host copy of X/Y
  when it directly followed a GPU `filter.reproject` (CUDA), producing a
  1×1 raster; the extent is now reduced on the device
  (`test_gdal_gpu_writer`).
