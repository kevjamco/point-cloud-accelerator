# Phase 2 — Pre-filter by range (`filter.range`)

## What it does

Two `filter.range` stages cull points before the expensive denoise/reproject
work:

1. **Drop null-island points** at exactly (0, 0) — a common artifact of bad
   GPS/echo records.
2. **Keep only valid classifications** for this product, dropping classes that
   should never feed the surface (e.g. high/low noise, overlap-only buckets
   outside the kept ranges).

`filter.range` implements PDAL's `filters.range` grammar exactly: ranges on the
**same** dimension are OR'd; ranges on **different** dimensions are AND'd.
`[a:b]` is inclusive, `!` negates, and open/exclusive bounds are supported. It
runs on CPU with `ThreadPool` chunking — a memory-bound single pass where GPU
upload would not pay off. Dropped points are removed with
`PointCloud::compact(keepMask)`, which compacts both dims and raw records and
updates `metadata.pointCount`.

## pcax

```yaml
drop_origin:                       # X![0:0] AND Y![0:0]  → drop (0,0)
  type: filter.range
  input: read
  limits: "X![0:0],Y![0:0]"

keep_classes:                      # Classification in {0..6, 9..11, 13..17}
  type: filter.range
  input: drop_origin
  limits: "Classification[0:6],Classification[9:11],Classification[13:17]"
```

## PDAL equivalent

```json
{ "type": "filters.range", "limits": "X![0:0],Y![0:0]" },
{ "type": "filters.range", "limits": "Classification[0:6],Classification[9:11],Classification[13:17]" }
```

## Following the run

```
filter.range: kept 35462132 of 35462132 points (X![0:0],Y![0:0])
filter.range: kept 35456586 of 35462132 points (Classification[0:6],Classification[9:11],Classification[13:17])
```

- No (0,0) points in this tile (35,462,132 → 35,462,132).
- Class filter dropped 5,546 points (35,462,132 → 35,456,586).
- Phase time: 371 ms + 1319 ms.
