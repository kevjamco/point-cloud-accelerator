# Phase 9 — Rasterize DTM (`writer.gdal_gpu`, min)

## What it does

Rasterizes the ground+water cloud (from phase 8) to a GeoTIFF taking the
**minimum** Z per cell — a Digital Terrain Model (bare-earth surface). Same GPU
gridding path as the DSM writer (phase 7); only the cloud state (terrain-only)
and `output_type` (`min` vs `max`) differ.

All the phase-7 notes apply: fixed window via `origin_x/origin_y/width/height`
(PDAL parity) or `snap: true`, automatic compound-CRS carry, and the north-up
row flip in `writeBand`.

## pcax

```yaml
write_dtm:
  type: writer.gdal_gpu
  input: keep_ground_water
  filename: "${dtm}"
  resolution: 1.0
  output_type: min
  data_type: float32
  nodata: -9999
  origin_x: 532000
  origin_y: 2796000
  width: 4000
  height: 4000
```

## PDAL equivalent

```json
{ "type": "writers.gdal", "output_type": "min", "resolution": "1.0",
  "data_type": "float32", "nodata": -9999,
  "origin_x": 532000, "origin_y": 2796000, "width": 4000, "height": 4000 }
```

## Following the run

```
Wrote 4000x4000 raster (1 bands) to A3B2D4_pcax_DTM.tif
```

- DTM grid 4000×4000 at 1 m, single `min` band, nodata −9999, compound CRS.
- 999,149 cells populated (sparser than the DSM — ground/water returns only).
- Phase time: ~150 ms (fewer points than the DSM → faster).

## Validating against PDAL

Compare with the grid-aware comparison tool:

```bash
python3 compare/compare_geotiffs.py A3B2D4_..._DTM.tif A3B2D4_pcax_DTM.tif
```

Result (Everglades, 2026-06-11, after the SOR exact-kNN fix): coverage IoU
**1.000** — every cell PDAL fills, pcax fills, and vice versa — values RMSE
**0.19 mm**, p99.9 |Δ| ≈ 4 µm (FP32 epsilon). Residual ~2 cells/million
(max 0.11 m) from the FP32-storage boundary tolerance documented in the repo
`CLAUDE.md` and root-caused in docs/Parity.md. The earlier 12,692-cell
coverage gap was the old SOR kernel over-flagging sparse returns (phase 3) —
fixed; and the earlier sub-pixel grid offset was closed by the fixed
window/snapping above.
