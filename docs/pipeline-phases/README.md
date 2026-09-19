# pcax pipeline phases — a worked walkthrough

This folder traces a complete pcax pipeline phase by phase, describing what
each phase does, how it maps to the equivalent PDAL stage, and *following the
actual data* through it using a real run.

**Worked example.** The NOAA 2017 USGS Topobathy Lidar Everglades tile
(`laz_geoid18_..._17RNH330970.copc.laz`, 35.46 M points, NAD83(2011) geographic
+ NAVD88). The pipeline cleans and denoises the cloud, reprojects it to UTM
17N, crops to the tile box, filters by deviation from a base DTM, and writes a
DSM (max) and a DTM (min) raster. The pcax stage list is encoded in
`tests/integration/pipelines.py` (the integration suite runs it on a committed
150 m subset); the PDAL pipeline it mirrors is NOAA's published `*_pipeline.json`
for the tile.

End-to-end pcax wall time: **18.0 s** (profiler `-d`). The single-threaded PDAL
equivalent runs ~30+ min on the same tile — the motivation for pcax.

## Phases

| # | File | Phase | pcax stage(s) | PDAL stage(s) |
|---|------|-------|---------------|---------------|
| 1 | [01-read.md](01-read.md) | Read & normalize | `read.las` | `readers.las` |
| 2 | [02-prefilter-range.md](02-prefilter-range.md) | Pre-filter by range | `filter.range` ×2 | `filters.range` ×2 |
| 3 | [03-denoise-outlier.md](03-denoise-outlier.md) | Statistical denoise | `filter.outlier` + `filter.range` | `filters.outlier` + `filters.range` |
| 4 | [04-reproject.md](04-reproject.md) | Reproject (CRS) | `filter.reproject` | `filters.projpipeline` |

> **Stage-order note (2026-06-12):** the pcax sample yamls now run phase 4
> (reproject) *before* phase 3 (denoise) so SOR works in meters with
> `search_radius` — an accepted divergence from the PDAL JSON, which keeps
> the original order. The phase numbering follows the PDAL pipeline.
| 5 | [05-crop.md](05-crop.md) | Crop to polygon | `filter.crop` | `filters.crop` |
| 6 | [06-dem-filter.md](06-dem-filter.md) | DEM-deviation filter | `filter.dem` | `filters.dem` |
| 7 | [07-raster-dsm.md](07-raster-dsm.md) | Rasterize DSM (max) | `writer.gdal_gpu` | `writers.gdal` |
| 8 | [08-ground-water-range.md](08-ground-water-range.md) | Select ground+water | `filter.range` | `filters.range` |
| 9 | [09-raster-dtm.md](09-raster-dtm.md) | Rasterize DTM (min) | `writer.gdal_gpu` | `writers.gdal` |

## Execution model (read once)

pcax parses the YAML stages into a DAG by `input:` references, topo-sorts it,
then executes **linearly over one shared cloud** (`m_clouds["default"]`). There
is no branching or merge: each stage mutates the single cloud in place and the
next stage sees the result. The two raster writers (phases 7 and 9) therefore
read the cloud *at that point* in the chain — the DSM sees all surviving
points; the DTM sees only the ground+water subset selected in phase 8.

Residency is automatic: the executor uploads the dims a GPU stage needs and
downloads for CPU stages (visible as `Uploaded X to device …` / `Downloaded …`
lines under `-d`). Coordinates are stored as **relative FP32** (`(raw −
minRaw)·scale`); the data structures chapter of `docs/Architecture.typ`
walks the full read → GPU → write data path with exact types.

> Numbers in these files are from one real run and will drift slightly with
> input or parameter changes; treat them as illustrative, not golden.
