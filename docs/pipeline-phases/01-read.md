# Phase 1 — Read & normalize (`read.las`)

## What it does

Reads the LAS/LAZ file into pcax's Structure-of-Arrays `PointCloud`. With the
laz-perf backend (the default `-DPCA_LAZ_BACKEND=LAZPERF`), LAZ chunks
decompress **in parallel** across a thread pool — each 50 K-point chunk has its
own arithmetic-coder state, so there is zero shared state between threads.

During the read, coordinates are **normalized to relative FP32**: the reader
subtracts the data-derived integer minimum and applies the LAS scale, storing
`(raw − minRaw)·scale` per X/Y/Z. Absolute origin (`scale`, `offset`, `minRaw`,
`dataMin`) is carried in `LasMetadata` so the writer can reconstruct exact
int32 records, and `DimAccessor` can decode bit-identically to PDAL when
needed. Attribute dims (Intensity, ReturnNumber, NumberOfReturns, GpsTime, RGB)
are extracted from the raw records here; the original records are retained for
loss-free passthrough on write.

## pcax

```yaml
read:
  type: read.las
  filename: "${input}"
```

## PDAL equivalent

```json
{ "type": "readers.las", "filename": "...copc.laz" }
```

Key difference: PDAL's `readers.las` decodes `int32·scale + offset` into
**float64** before any filter runs. pcax keeps relative FP32 in SoA layout —
GPU-friendly and precision-stable for large UTM coordinates.

## Following the run

```
Reading 35462132 points ... (format 6, LAZ)
LAZ: 182 chunks, 16 threads, parallel decompress
Read 35462132 points
```

- 35,462,132 points, LAS point format 6.
- 182 LAZ chunks decompressed across 16 threads.
- Phase time: **4239 ms** (the largest single cost in the pipeline; I/O-bound).
- Input CRS read from the file: `NAD83(2011)` geographic + `NAVD88 height`
  (compound), units degrees.
