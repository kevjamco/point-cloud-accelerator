# pcax 0.2.0 — release notes

Status: **beta 5** (`0.2.0b5`, 2026-10-12; beta 4 and beta 3 were published
2026-10-02, beta 2 on 2026-10-01, beta 1 was tagged but never published).
Beta 5 is the first build with the license check; the earlier betas have
been withdrawn from the channel. Install the pre-release with
`conda install -c https://conda.adv-algos.net/pcax -c conda-forge pcax=0.2.0b5`
(see [Install.md](Install.md)). Option names and the CLI may still change
before 0.2.0 final.

0.2.0 is about throughput on real production runs — many files per job,
tiles that straddle output cells, pipelines dominated by decode and point
filters rather than by GPU kernels. The headline numbers below were
measured on an 11.9 M-point tile (LAZ, point format 3) on an i9-9900K with
an RTX 2080 Ti; every one of them leaves the output byte-identical.

| | 0.1.0 | 0.2.0 |
|---|---|---|
| crop → range ×3 → crop chain | 1610 ms | 205 ms |
| `read.las`, LAZ | 1010 ms | 630 ms |
| `read.las`, uncompressed LAS | 1000 ms | 124 ms |
| read a 7.8 % window of a COPC file | 823 ms (read + crop) | 172 ms (`read.copc` `bounds`) |
| NAD83(2011) → NAD83 UTM, 11 M points | 1086 ms (host PROJ) | 298 ms (GPU) |
| per-file process overhead | 0.63 s per small file | 0.33 s in a batch |

Beta 3 adds a faster LAZ decode for point formats 6–8, measured on a
73 M-point USGS 3DEP tile (LAZ, point format 6), 8 threads, against beta 2;
the decoded records are byte-identical:

| | 0.2.0b2 | 0.2.0b3 | with `layers: flags` |
|---|---|---|---|
| `read.las`, whole tile | 3632 ms | 2950 ms | 2073 ms |
| `read.las` `bounds`, a strip 10 % of the tile wide | 3467 ms | 1966 ms | 1626 ms |

## New

### License check and activation (beta 5)

- **`pcax run` is granted by the license server.** Evaluations activate
  once per machine with a verified email (`pcax activate you@example.com`,
  a 6-digit code by email) and need network access to
  `license.adv-algos.net` on every run. Commercial licenses use a token
  (`PCAX_LICENSE_TOKEN`) or an offline lease (`pcax license lease`,
  `PCAX_LICENSE_LEASE`) for air-gapped hosts. `validate`, `analyze`,
  `info`, `convert` and `serve` need no license. No grant → exit code 4
  with the reason and the command to run.
- **Every run is reported** (and the run prints one stderr line saying so):
  stage types, point counts, duration, GPU, pcax version, OS, a machine
  fingerprint hash, your email and, as with any HTTPS request, your IP.
  Never file names, paths, data or stage options. `pcax license privacy`
  prints the same list; [Licensing.md](Licensing.md) has the details and
  the environment variables.
- **Binary-only distribution.** The engine source is no longer published.

### Spatial subset at read time

- **`read.copc`** reads a COPC file through its octree. With `bounds`, only
  the nodes that intersect the query are decoded, then trimmed point by
  point. The result is exactly a full read followed by `filter.crop` — same
  records, same order — and the same point set PDAL's `readers.copc` returns
  for that window. `pcax convert` now maps `readers.copc` to it.
- **`read.las` `bounds`** drops points as each chunk is decoded, so the file
  is never fully resident. A plain LAZ file has no spatial index, so every
  chunk has to be looked at. For point formats 6–8 only a chunk's X/Y layer
  is decoded first, and a chunk with no point inside the box is dropped
  there *(beta 3)*; formats 0–5 are decoded in full. Use `read.copc` when
  the file has an octree.

### Decoding only what the pipeline needs *(beta 3)*

- **`read.las` / `read.copc` `layers`** (LAZ point formats 6–8) lists the
  optional record fields to decode: `flags`, `intensity`, `scanangle`,
  `userdata`, `pointsource`, `gpstime`, `rgb`, `nir`, `extrabytes`, or `all`
  (the default) / `none`. X, Y, Z, return numbers, scanner channel and
  classification are always decoded. A raster pipeline that filters on
  classification and the Withheld flag needs only `layers: flags`, which is
  about 40 % less decode time. Fields left out are zero in the point
  records, their attribute dimensions are not created, and `write.las` /
  `write.copc` refuse the cloud rather than write the zeros.

### Damaged LAZ files *(beta 4)*

- **`read.las` reads a LAZ file whose chunk table is unusable** — the
  compressor was interrupted before writing it (the pointer at the start of
  the point data still holds its own position; the file ends wherever the
  writer stopped), the pointer leads past the end of the file, or the table
  is corrupt. The chunk layout is rebuilt from the point data, as LASzip
  does, and every chunk that is complete is decoded; a `WARN` gives the
  recovered point count against the header's, and the cloud's count is the
  recovered one. Point formats 6–8 carry each chunk's size in the chunk, so
  the rebuild is free; formats 0–5 are decoded once sequentially to find
  the boundaries. Adaptive chunking cannot be rebuilt and is still refused.
  PDAL refuses all of these files (`Invalid version N found in LAZ chunk
  table`, N being the pointer's own position). Found on eight
  `TX_CentralEast_A23` tiles on `usgs-lidar`, each holding 23–93 % of its
  declared points.

### Batch runs

- **`pcax run pipeline.yaml --batch jobs.jsonl`** runs one job per line (a
  JSON object of pipeline variables) in a single process, paying for the
  GPU context, kernel images and the PROJ database once. A failed job does
  not stop the batch; `--batch-out` writes one result line per job.
- **`pcax analyze --batch jobs.jsonl`** reports the largest job's host and
  GPU memory and how many such workers fit right now.

### Rasters across files and cells

- **`writer.gdal_gpu` `merge: true`** folds the result into the raster
  already at `filename` (same grid): min by minimum, max by maximum, count
  by sum. Two halves merged equal the raster of the whole, exactly.
  `merge: first` keeps existing values and fills only empty cells.
- **`writer.gdal_gpu` `grids`** rasters one cloud into several fixed grids
  in one stage, each to its own file — every cell a boundary tile touches,
  with one read.

### Machine-readable runs

- **`pcax run --profile-json FILE`**: per stage, time, GPU flag, RAM and GPU
  memory, `points_in` / `points_out`, outcome, and the GPU sub-steps.
- **Exit codes for `pcax run`**: 0 every output written; 3 the run succeeded
  but a writer had no points to write; 1 error.

### `filter.reproject`

- PROJ's **`+proj=gridshift`** now runs on the GPU chain, including
  NADCON5's biquadratic grids and their height band. NAD83 realization
  changes (NAD83(2011) → NAD83 and back) no longer fall back to host PROJ;
  the fp64 chain agrees with PROJ to better than 1e-7 m. The grids must be
  available (`grids_path` or `PROJ_DATA`); `compare/fetch_grids.sh` fetches
  the CONUS set. Grids are read only over the data's extent.

### `filter.dem`

- `interpolation: bilinear` samples between pixel centres instead of taking
  the containing pixel; `reproject: true` warps the raster to the cloud's
  CRS. Only the raster window under the cloud is read. Defaults are
  unchanged and match PDAL.

## Faster, same output

- Consecutive `filter.range` / `filter.crop` / `filter.dem` stages are fused:
  one keep mask, one compaction. `PCAX_FUSE_PREDICATES=0` turns the fusion
  off for comparison.
- Compaction is chunk-parallel, and dimensions that live on the GPU are
  compacted there, so a GPU stage after a dropping filter no longer
  re-uploads the cloud.
- `read.las` no longer has serial sections around the chunk decode
  (memory-mapped file, parallel coordinate conversion and attribute
  extraction); uncompressed LAS is read in parallel.
- LAZ point formats 6–8 are decoded layer by layer, in `read.las` and
  `read.copc`: 17–20 % less decode time for the same records *(beta 3)*.
- Thread pools size themselves to the CPUs the process may actually use —
  the affinity mask and the cgroup CPU quota — instead of the node's core
  count. `PCAX_THREADS=N` overrides.
- Metal: every kernel runs through a chunked, self-tuning dispatch, so large
  tiles no longer trip the macOS GPU watchdog (see
  [MetalBackend.md](MetalBackend.md)).

## Changed behaviour

- **An empty cloud is no longer an error for `writer.gdal_gpu` and
  `write.copc`.** They log a warning and write no file; the run continues
  and exits 3. A file already at that path is left as it was. Scripts that
  matched the old `no points to write` error should test the exit code.
- **Unknown options to `run`, `validate` and `analyze` are rejected**; they
  were silently ignored.
- **`pcax convert`** emits `read.copc` for `readers.copc` (was `read.las`),
  and passes `bounds` through.
- `-d` output is unchanged; `read.las` now also reports sub-steps.

## Fixed

- `filter.reproject` with `pipeline: "+proj=noop"` and `out_srs` returned
  before writing the CRS, so the output kept the file's own CRS instead of
  `out_srs`; a run whose file CRS did not parse then failed in
  `writer.gdal_gpu`. It now relabels the output (WKT and GeoTIFF keys), and
  an `out_srs` PROJ cannot read is an error instead of being ignored.
  *(beta 4)*
- `writer.gdal_gpu` failed a finished run when the cloud's CRS, inferred
  from the file, did not parse (`cannot parse SRS: EPSG:26914+5103`). A CRS
  the file supplies is only a label: it is now dropped with a `WARN` and the
  raster gets `default_srs`, else no CRS. `override_srs` / `default_srs`
  must parse, and all three are resolved before the gridding. *(beta 4)*
- GeoTIFF `VerticalCSTypeGeoKey` values that are vertical *datum* codes
  (5101–5106, as GeoTIFF 1.0 listed them; `26914 + 5103` on 2006-era Texas
  tiles) now resolve to the vertical CRS for the datum and unit key, as GDAL
  and PDAL resolve them (`EPSG:26914+5703`). *(beta 4)*
- `filter.assign`, `filter.elm`, `filter.smrf` and `filter.transformation`
  wrote their result on the host without invalidating the GPU copy. When a
  GPU stage ran before and after one of them, the second GPU stage used the
  stale copy and the change was lost. Present in 0.1.0.
- `writer.gdal_gpu` without an explicit grid, directly after a GPU
  `filter.reproject`, sized its raster from stale coordinates (a 1×1
  raster). Listed in the 0.1.0 changelog but not in the 0.1.0 package; it
  ships in this release.

## Known issues

- `writer.gdal_gpu` with `dimension: Classification` reads the 8-bit
  dimension as 32-bit floats on the GPU and produces wrong values or a CUDA
  error. Grid `Z` or `Intensity`, or use `filter.stats`.
- `read.las` / `read.copc` take `bounds` only; `polygon` and `resolution`
  queries are not supported yet.
- `pcax analyze` does not take `layers` into account: with a partial decode
  it budgets for attribute dimensions that are not created, so its host
  memory figure is high.
- `merge` is not safe for two processes writing the same raster at once.

Parity statements and tolerances: [Parity.md](Parity.md). Full list of
changes: [CHANGELOG.md](../CHANGELOG.md).
