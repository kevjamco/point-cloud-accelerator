# Phase 8 — Select ground + water (`filter.range`)

## What it does

Narrows the shared cloud to the points that define the *terrain* surface before
the DTM is gridded: Classification 2 (ground) and 9 (water). This is the same
`filter.range` machinery as phase 2 (PDAL grammar, CPU, `compact`), placed here
— **between the two raster writers** — precisely because pcax executes linearly
over one shared cloud. The DSM writer (phase 7) already ran on the full
surviving cloud; this range filter then strips everything but ground/water so
the DTM writer (phase 9) sees only terrain.

This ordering is the pcax expression of what PDAL does with the same stage
sequence: a `filters.range` sandwiched between the DSM `writers.gdal` and the
DTM `writers.gdal`.

## pcax

```yaml
keep_ground_water:
  type: filter.range
  input: write_dsm            # chained after the DSM writer
  limits: "Classification[2:2],Classification[9:9]"
```

## PDAL equivalent

```json
{ "type": "filters.range", "limits": "Classification[2:2],Classification[9:9]" }
```

## Following the run

```
filter.range: kept 6808888 of 35106991 points (Classification[2:2],Classification[9:9])
```

- 6,808,888 of 35,106,991 points are ground or water (~19%); the rest
  (vegetation, structures, unclassified) are dropped for the terrain model.
- Phase time: 1034 ms.

> Because writers read the cloud *in place*, the relative order of phase 7, 8,
> and 9 matters: swapping phase 8 before phase 7 would make the DSM a
> ground-only max surface, not a true first-surface DSM.
