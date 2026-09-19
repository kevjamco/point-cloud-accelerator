# Phase 5 — Crop to polygon (`filter.crop`)

## What it does

Keeps only points inside a WKT polygon (or bbox). Here the polygon is the
square tile boundary in UTM 17N (532000–536000 E, 2796000–2800000 N).
`filter.crop` uses GEOS `covers` semantics — the polygon boundary counts as
inside — matching PDAL's `filters.crop` when no polygon reprojection occurs.
Holes and an `outside` (invert) mode are supported.

It runs on **CPU** with `ThreadPool` chunking. Note the residency lines in the
log: the executor downloads X/Y/Z from the GPU (left there by the reproject
phase) so the CPU predicate can read them.

## pcax

```yaml
crop:
  type: filter.crop
  input: reproject
  polygon: "POLYGON ((532000 2796000, 532000 2800000, 536000 2800000, 536000 2796000, 532000 2796000))"
```

## PDAL equivalent

```json
{ "type": "filters.crop",
  "polygon": "POLYGON ((532000 2796000, 532000 2800000, 536000 2800000, 536000 2796000, 532000 2796000))" }
```

## Following the run

```
filter.crop: kept 35106991 of 35106991 points
```

- All 35,106,991 points fell inside the polygon — the tile's reprojected extent
  is fully contained in the crop box (the input spanned only ~0.01° ≈ 1 km), so
  nothing was removed here.
- Phase time: 430 ms (most of it the GPU→host download of X/Y/Z).

### Parity note

When PDAL reprojects the crop polygon (`a_srs` ≠ point SRS), PROJ jitters the
vertices by ~1e-9 and points lying exactly on an edge can flip either way. Here
the polygon is already in the point CRS, so `covers` is exact.
