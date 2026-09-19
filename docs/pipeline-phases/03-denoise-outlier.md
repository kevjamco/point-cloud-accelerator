# Phase 3 — Statistical denoise (`filter.outlier` + `filter.range`)

## What it does

Statistical Outlier Removal (SOR), then a range filter to drop what SOR
flagged. For each point, SOR finds its `k` nearest neighbours and computes the
mean neighbour distance; points whose mean distance is `>=`
`global_mean + multiplier · global_stddev` are reclassified as noise
(Classification 7), matching PDAL's `filters.outlier` method `statistical`
(PDAL keeps strictly-below-threshold points).

This is a **GPU** stage. The executor uploads the dims, then the filter builds
a uniform spatial grid (`SpatialGrid.cuh`) and runs an **exact kNN search via
expanding cell rings**: after completing ring d, any unvisited point lies in a
cell at Chebyshev distance ≥ d+1 and is therefore no closer than d·cellSize in
XY, so the search stops once the kth candidate is within that bound. This
matches PDAL's unbounded KD-tree search — every point gets a true mean-kNN
distance; there is no "isolated point" special case. Global mean/stddev
(sample, N−1, like PDAL) are computed on CPU; classification happens on GPU.
SOR marks but does not remove; the following
`filter.range "Classification![7:7]"` does the removal via `compact`.

## pcax

```yaml
denoise:
  type: filter.outlier
  input: reproject     # NOTE: sample yamls run SOR AFTER reprojection (meters)
  device: gpu
  method: statistical
  k: 3                 # PDAL mean_k
  multiplier: 3
  search_radius: 1.5   # only neighbours within 1.5 m count; < k of them -> noise.
                       # No PDAL equivalent (its statistical method is unbounded;
                       # its `radius` method has no statistical threshold).
  # optional:
  # precision: fp64    # distance math in double — measured bit-identical
  #                    # to fp32 on this pipeline (docs/Parity.md; default fp32

drop_noise:
  type: filter.range
  input: denoise
  limits: "Classification![7:7]"
```

## PDAL equivalent

```json
{ "type": "filters.outlier", "method": "statistical", "mean_k": 3, "multiplier": 3 },
{ "type": "filters.range", "limits": "Classification![7:7]" }
```

Note the param rename: PDAL `mean_k` → pcax `k`. With `search_radius` unset
and the PDAL stage order (SOR before reproject), parity is exact: on the
Colorado tile the flagged sets are point-for-point identical to PDAL
(see docs/Parity.md, "SOR exact kNN").

**The sample yamls intentionally diverge** (since 2026-06-12): SOR runs after
`reproject` so distances are in meters, with `search_radius: 1.5`. That makes
the filter more aggressive than PDAL's mixed-unit SOR (~1.6% vs ~0.2% flagged
on this tile, DSM mean +5 cm, DTM −3.4% coverage) — an accepted divergence;
the meter-space stats are arguably the more principled ones.

## Following the run

```
SOR filter: k=3, multiplier=3.0, precision=fp32, search_radius=1.5, points=35456586
SOR: mean=0.18898195, stddev=0.0746350437, threshold=0.412887096 (valid=35455751/35456586)
SOR: 569907 outliers classified (1.6%)
filter.range: kept 34886679 of 35456586 points (Classification![7:7])
```

- 569,907 points (1.6%) flagged; 835 of those are "give-ups" (< 3 neighbours
  within 1.5 m), the rest exceed the meter-space statistical threshold.
- kNN cost: **~6 s** on the GPU for 35.4 M points (meter space terminates the
  ring search at 1–2 rings).
- For the PDAL-order variant (SOR before reproject, no search_radius): flags
  56,273 (0.2%), parity-exact, but the kNN costs ~74 s — a mixed-units
  artifact (XY degrees vs Z meters defeats the XY-based termination bound).
  Two-pass compaction for that path is scoped in ROADMAP.md.

Even so, this remains the heaviest phase and the main reason the PDAL
equivalent (single-threaded FP64 KD-tree kNN over 35 M points) takes tens of
minutes while pcax takes seconds-to-a-minute.
