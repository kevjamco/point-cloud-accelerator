# Phase 6 — DEM-deviation filter (`filter.dem`)

## What it does

Drops points whose elevation deviates too far from a reference DEM raster —
used here to reject gross blunders relative to a coarse base DTM before
gridding. The keep test is, per PDAL `filters.dem`:

```
raster(x,y) − lower  ≤  Z  ≤  raster(x,y) + upper
```

where `lower`/`upper` come from the `limits` range (`Z[20:600]` → lower 20,
upper 600). The raster is sampled at the **containing pixel** (no
interpolation), and points falling outside the raster extent are dropped. It
runs on **CPU** with `ThreadPool` chunking.

The reference raster (`base_dtm/A3B2D4.tif`) is a ~10 m NAD83/UTM 17N DTM
covering the tile box.

## pcax

```yaml
dem_filter:
  type: filter.dem
  input: crop
  raster: "${dem}"          # ./base_dtm/A3B2D4.tif
  limits: "Z[20:600]"
```

## PDAL equivalent

```json
{ "type": "filters.dem", "raster": "./base_dtm/A3B2D4.tif", "limits": "Z[20:600]" }
```

## Following the run

```
filter.dem: kept 35106991 of 35106991 points
```

- All 35,106,991 points fell within `[raster − 20, raster + 600]` and inside the
  raster extent, so none were dropped on this tile.
- Phase time: 442 ms.

> The wide band (`[20:600]`) plus a base DTM near sea level means this acts as a
> coarse blunder gate rather than a tight surface filter; on noisier tiles it is
> where spikes far above/below the reference get removed.
