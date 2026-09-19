# Phase 7 — Rasterize DSM (`writer.gdal_gpu`, max)

## What it does

Rasterizes the surviving points to a GeoTIFF, taking the **maximum** Z per cell
— a Digital Surface Model (first-surface / canopy-top). This reads the cloud at
its current state in the chain (after denoise → reproject → crop → DEM filter),
so it is the *full* surviving cloud, not yet narrowed to ground.

It runs on **GPU**: points are binned to a uniform grid, radix-sorted by cell,
cell boundaries found, and per-cell statistics computed. `output_type` selects
the band(s): `min`, `max`, `mean`, `stdev`, `count`, `idw`, percentiles
(`pNN`), or `all`. See [../GdalGpuWriter.md](../GdalGpuWriter.md).

### Grid window

Three ways to size the grid (PDAL `writers.gdal` parity pinned from
GDALWriter.cpp; validated 2026-06-11, see docs/Parity.md):

1. **Fixed window** — `origin_x`/`origin_y`/`width`/`height` (all-or-none),
   exactly PDAL's fixed-tile semantics: lower-left origin, geotransform
   top-left Y = `origin_y + height·res`. Out-of-window points still contribute
   to edge cells within `radius` (halo-expanded binning, matching PDAL's
   clamped quadrant walks); bin mode drops them, as PDAL does.
2. **`snap: true`** — data bbox rounded outward onto the resolution lattice
   (pcax extension); no +1 cell, so adjacent tiles abut exactly.
3. **Neither** — extent is data-derived from the point bounding box.

CRS is carried automatically: `override_srs` → cloud CRS (set by
`filter.reproject`, else the source LAS VLRs) → `default_srs`. Compound codes
(`EPSG:hhhh+vvvv`) work; the Everglades rasters carry
"NAD83 / UTM zone 17N + NAVD88 height" with no `override_srs` in the YAML.

**Orientation note.** The GPU kernel fills grid row 0 at the *southern* edge,
but the GeoTransform is north-up (row 0 = max Y). The writer flips rows
north-to-south in `writeBand` before `GDALRasterIO`. (Was a real bug, fixed.)

## pcax

```yaml
write_dsm:
  type: writer.gdal_gpu
  input: dem_filter
  filename: "${dsm}"
  resolution: 1.0
  output_type: max
  data_type: float32
  nodata: -9999
  origin_x: 532000      # fixed window — drop these four (or use snap: true)
  origin_y: 2796000     # for a data-derived extent
  width: 4000
  height: 4000
```

## PDAL equivalent

```json
{ "type": "writers.gdal", "output_type": "max", "resolution": "1.0",
  "data_type": "float32", "nodata": -9999,
  "origin_x": 532000, "origin_y": 2796000, "width": 4000, "height": 4000 }
```

## Following the run

```
Wrote 4000x4000 raster (1 bands) to A3B2D4_pcax_DSM.tif
```

- DSM grid 4000×4000 at 1 m, single `max` band, nodata −9999, compound CRS
  carried from the cloud; geotransform top-left (532000, 2800000) — identical
  to PDAL's, byte-for-byte equal file size.
- Phase time: well under a second (radius-mode stats ~0.5 s on GPU).

## Parity vs PDAL (Everglades, 2026-06-11)

Coverage IoU **1.000** (zero one-sided cells), values RMSE **1 mm**,
mean |Δ| ~7 µm, corr 1.0. The residual ~20 cells/million (max ~0.4 m) is the
documented FP32-storage boundary tolerance: a point within ~0.1–0.5 mm of the
radius cutoff or a cell edge can flip membership vs PDAL's FP64 path and swing
the cell extreme by local relief (root-caused with a 16 µm worked example —
docs/Parity.md, and the tolerance list in the repo `CLAUDE.md`).
