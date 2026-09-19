# write.copc — Cloud-Optimized Point Cloud writer

`write.copc` writes a [COPC 1.0](https://copc.io) file: a LAS 1.4 /
point-format 6–8 LAZ whose chunks are octree nodes, with the COPC info VLR
and the hierarchy EVLR that level-of-detail viewers (Potree, QGIS, Cesium
via tiling, PDAL `readers.copc`, `pcax serve`) use to fetch only the nodes
in view via HTTP range requests. It is the pipeline's visualization
output: run your filters, then `write.copc`, then point a viewer at the file.

The octree build, point ordering and output-record assembly run on the
GPU; LAZ entropy coding (laz-perf's sequential arithmetic coder) runs one
node per host thread, exactly as `write.las` does. Point data is
**byte-exact** vs PDAL `writers.copc` (only the point order and the tree
layout differ — docs/Parity.md.

## Quick start

```yaml
version: 1
stages:
  read:
    type: read.las
    filename: "${input}"
  hag:
    type: filter.hag_nn
    input: read
  copc:
    type: write.copc
    input: hag
    filename: "${output}.copc.laz"
    extra_dims: [HeightAboveGround]     # viewer can colour by it
```

```bash
pcax run pipeline.yaml -v input=tile.laz -v output=tile -d
pdal info --metadata tile.copc.laz | grep '"copc"'     # true
```

## Options

| Option | Default | Description |
|---|---|---|
| `filename` | *(required)* | Output path; must end in `.laz`, should end in `.copc.laz` (viewers key on the suffix; a warning is logged otherwise) |
| `extra_dims` | none | Derived dims to append as LAS extra bytes: a YAML list or comma string of PDAL-style names (`HeightAboveGround, ClusterID`), or `all` for every non-native dim present. Native LAS fields are always written and cannot be listed. ≤ 32 dims |
| `max_node_points` | `100000` | A node with at most this many remaining points becomes a leaf; also sizes the automatic depth cap |
| `max_depth` | auto | Deepest tree level (≤ 16). Auto = ⌈log₄(n / max_node_points)⌉ + 2 — sized for 2.5D lidar, where nodes shrink ~4× per level |
| `grid_size` | `128` | Subsample grid per node axis (power of two). Each non-leaf node keeps the first point of every occupied `grid_size³` voxel; COPC `spacing` = 2·halfsize / grid_size. Trades first-paint latency against far-view density: `64` paints fastest over a slow link (root chunk ~¼ the bytes), `256` is ~4× denser but ~7× more bytes before the first frame (measured, see below) |
| `node_order` | `gpstime` | Point order inside each node: `gpstime` (scan order — LAZ's predictors compress it 15–40 % better than spatial order; what PDAL does) or `input` |
| `format` | auto | Output point format: 6 (no colour) or 7 (RGB) from the source; `8` forces the NIR-capable record |
| `threads` | hardware concurrency | Host threads for the per-node LAZ compression |
| `a_srs` | none | CRS (WKT or `EPSG:n[+v]`) used only when the source has no WKT / GeoTIFF-key CRS. COPC requires a WKT VLR |
| `device` | `gpu` | `cpu` runs the host octree + assembly (the reference implementation; byte-identical output) |

## What the file contains

```
LAS 1.4 header (375 B)   PF | 0x80, legacy count 0, count_14 = n, points_by_return_14
VLR copc/1  (160 B)      first VLR: cube center/halfsize, spacing, hierarchy offset/size, GPS range
source VLRs              minus laszip, copc, and CRS records replaced by filter.reproject
VLR LASF_Projection/2112 WKT (from the reprojected CRS, the source WKT, converted GeoTIFF keys, or a_srs)
VLR LASF_Spec/4          extra-bytes descriptors (source fields, then extra_dims)
VLR laszip/22204         variable chunk size
int64 chunk-table offset | one LAZ chunk per node, DFS pre-order | chunk table
EVLR copc/1000           hierarchy page: 32-byte {d,x,y,z, offset, byteSize, pointCount} per node
source EVLRs             minus copc and replaced CRS records
```

Single hierarchy page (fine up to millions of nodes). The COPC cube is
anchored at the header minimum with edge = the largest extent, snapped to
the LAS scale lattice, so node boxes derived from the VLR agree exactly
with the keys the writer used — a point on a node boundary is in the node
the hierarchy says (verified: readers.copc bounds windows return the same
point set from pcax and PDAL files).

## Point format upgrade

COPC allows only formats 6–8. Legacy records are converted
(`include/pca/LasRecordConvert.hpp`, host + device):

| legacy (0–5) | → 6/7 |
|---|---|
| returns @14 bits 0-2 / 3-5 | @14 bits 0-3 / 4-7 |
| scan direction / edge @14 bits 6-7 | @15 bits 6-7 |
| Synthetic/KeyPoint/Withheld @15 bits 5-7 | @15 bits 0-2 |
| class == 12 (legacy overlap) | Overlap flag @15 bit 3, class from the Classification dim (0) |
| classification @15 bits 0-4 | @16 |
| scan angle int8 degrees @16 | int16 0.006° units @18 (`lround(deg / 0.006)`) |
| user data / point source | @17 / @20 |
| GPS time @20 (1,3,4,5) | @22 (0 when absent) |
| RGB @20 (2) / @28 (3,5) → format 7 | @30 |
| wave packets (4,5,9,10) | dropped |

Formats 6–10 keep their 30-byte core; 9/10 lose the waveform packet.
Source extra bytes are carried verbatim; `extra_dims` are appended after
them with LAS data types mapped from the pcax `DimType`.

## The octree (host and GPU, bit-identical)

`include/pca/CopcOctree.hpp` documents the recipe; `src/core/CopcOctree.cpp`
is the reference, `src/writers/CopcOctree.cu` the CUDA build that
`tests/test_copc_octree_gpu.cu` holds to the same `perm` and node table.

1. **Keys** — one 48-bit Morton key per point at depth `K = D + log2(grid_size)`
   (≤ 16), so every tree node down to depth `D` has a full `grid_size³`
   subsample grid below it. Cell = `trunc((x − min) · 2^K / side)` in
   double: one multiply and a truncating cast, so host and device agree
   without FMA-contraction concerns.
2. **Sort** — CUB radix sort of (key, index); stable, so equal keys keep
   original order (the host uses `stable_sort`).
3. **Levels** — for `d = 0 … D−1` over the still-unassigned points in key
   order: run boundaries by node prefix (`DeviceSelect::Flagged` + scan), a
   node with ≤ `max_node_points` points is a leaf and takes them all,
   otherwise the first point of every occupied voxel is promoted to depth
   `d`. Survivors are compacted; the loop runs at most 16 times.
4. **Order** — the points are first put in GPS-time order (a radix sort of
   the sortable-double key over the input order; `node_order: input` skips
   it), then a stable radix sort by `(node prefix padded to K, depth)` gives
   DFS pre-order with every node contiguous and scan order inside; a
   run-length encode of that key yields the node table. Scan order matters:
   on the Everglades fixture Morton order inside nodes gave a 10.4 MB file,
   input order the same, GPS order 6.9 MB (PDAL: 7.3 MB).
5. **Assembly** — the raw LAS records are uploaded once; a kernel gathers via
   `perm`, converts the format, writes `minRaw + lround(x / scale)` for
   XYZ (the write.las rule), the Classification dim, and the extra-byte
   fields, in 16M-point slices downloaded straight into the host buffer the
   compressor threads read.

Measured (RTX 2080 Ti, `-d`, docs/Parity.md: NorthernCA full
tile, 73M points — bounds 4 ms, keys + sort 30 ms, levels 55 ms, order sorts
+ node table ~0.2 s, assembly 0.84 s, LAZ compress 2.4 s (host, 16 threads);
~11 s end to end including the 438 MB LAZ read, vs 122 s for PDAL
`writers.copc`. Output 16–20 % smaller than PDAL's on the fixtures.

## Tuning for a viewer over the network

Measured with Potree (2M point budget) over Tailscale on the 73M-point
NorthernCA tile, from `pcax serve -d` request logs (docs/Parity.md:

| encoding | requests to budget | bytes before first frame | root chunk | felt |
|---|---|---|---|---|
| `grid_size: 256, max_node_points: 25000` | 24 | 46.6 MB | 4.2 MB | slowest |
| default (`128` / `100000`) | 13 | 6.8 MB | 0.9 MB | ok |
| `grid_size: 64` | — | — | ~0.25 MB | fastest first paint |

The server side is ~1 ms per range; what the user waits for is transfer
plus laz-perf WASM decode of the coarse levels, so a sparser root wins for
interactive first paint and refines as the camera moves. Use `grid_size: 64`
for tiles served over WAN links; `128` (PDAL-like) for LAN/local.

## Memory (`pcax analyze`)

Device, sequential peaks: sort working set ≈ 36 B/pt, level pass ≈ 30 B/pt,
order sort ≈ 45 B/pt, then raw-record upload (record length) + one 16M-point
output slice. Host: the assembled output records (record length per point)
for the compression phase, plus ~3 MiB per compressor thread.

## Limits / notes

- Single hierarchy page; `pointCount` per node is int32 (COPC spec).
- Geographic-CRS input (degrees × metres): the cube edge is the Z extent, so
  the tree is a narrow column that splits mostly in Z — same for PDAL.
  Reproject to a projected CRS first for a useful LOD tree.
- The GPU path needs CUDA; on Metal or with `device: cpu` the host builder
  runs (same output). LASLIB backend builds register the stage but it
  errors at execute (`-DPCA_LAZ_BACKEND=LAZPERF` required).
- `write.las` after `read.las` of a COPC file drops the stale `copc`
  VLR/EVLR (the plain LAZ has no octree).
- Parity: `compare/copc_parity.py --input tile.laz` — writes both files,
  compares every record through `readers.copc`, a bounds window and an
  LOD read; `tests/integration/test_copc.py` runs it on the two fixtures.
