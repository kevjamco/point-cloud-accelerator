# `writer.gdal_gpu` — GPU Gridding Writer

GPU-accelerated point cloud rasterizer with full PDAL `writers.gdal` feature parity. Produces GeoTIFF (or other GDAL-supported formats) with configurable statistics bands.

## Quick Start

```yaml
stages:
  read:
    type: read.las
    filename: "${input}"

  grid:
    type: writer.gdal_gpu
    input: read
    filename: "output.tif"
    resolution: 1.0
    output_type: all
    override_srs: "EPSG:32610"
    gdalopts: "COMPRESS=DEFLATE,TILED=YES"
```

```bash
pcax run pipeline.yaml -v input=myfile.laz
```

## Options

| Option | Default | Description |
|---|---|---|
| `filename` | *(required)* | Output raster path |
| `resolution` | `1.0` | Cell size in CRS units (meters for projected CRS) |
| `dimension` | `Z` | Dimension to grid (`X`, `Y`, `Z`, `Intensity`, `Classification`) |
| `output_type` | `all` | Comma-separated: `min`, `max`, `mean`, `stdev`, `count`, `idw`, `all`, `pNN` |
| `binmode` | `false` | If `true`, only points falling in the cell contribute (no radius search) |
| `radius` | `resolution * √2` | Search radius for radius mode (ignored in binmode) |
| `power` | `1.0` | IDW exponent |
| `window_size` | `0` | Fill empty cells using inverse-distance window (0 = disabled) |
| `nodata` | `NaN` | NoData value for empty cells |
| `override_srs` | *(none)* | CRS as `EPSG:NNNNN` or WKT string |
| `default_srs` | *(none)* | Fallback CRS (used if `override_srs` is empty) |
| `gdaldriver` | `GTiff` | GDAL driver name |
| `gdalopts` | *(none)* | GDAL creation options, comma-separated (e.g., `COMPRESS=DEFLATE,TILED=YES`) |
| `data_type` | `float32` | Output data type: `float32`, `float64`, `int32`, `int16`, `uint8` |

| `merge` | `false` | `true`: fold the result into the raster already at `filename` (same grid) instead of replacing it, each band by its own statistic. `first`: keep existing values, fill only cells without data. |
| `grids` | *(none)* | A list of fixed grids, each `{origin_x, origin_y, width, height, filename}`; replaces `filename` and the single-grid options. |

A cloud with no points is not an error: the writer logs a warning, writes
no file, and `pcax run` exits 3 (README, "exit codes"). A file already at
`filename` is left untouched.

## Merging into an existing raster

With `merge: true` the writer opens the raster at `filename`, if there is
one, and combines it with the new result band by band: `min` by minimum,
`max` by maximum, `count` by sum. Those statistics compose exactly — the
merged raster of two disjoint sets of points equals the raster of their
union, in bin mode and in radius mode — so a mosaic can be built by running
one file after another into the same raster. `mean`, `stdev`, `idw` and
percentiles do not compose and are refused with `merge: true`.
`merge: first` works for any statistic: cells that already hold data keep
it, the others take the new value.

The target must be on exactly the same grid (size, geotransform, band
count and band names), so merging needs a fixed grid (`origin_x`,
`origin_y`, `width`, `height`, or `grids`). When no file exists yet it is
created as usual. One writer at a time: two processes merging into the same
file concurrently will lose updates — run them through one
`pcax run --batch`, or serialise them.

```yaml
  dsm:
    type: writer.gdal_gpu
    input: clean
    filename: "cell_dsm.tif"
    resolution: 1.0
    output_type: max
    origin_x: 610000
    origin_y: 3500000
    width: 10000
    height: 10000
    merge: true
```

## Several grids from one cloud

`grids` rasters the same cloud into several fixed windows in one stage —
every cell a boundary tile touches, without reading or filtering the tile
again. Each entry names its own file. A grid the cloud does not reach
produces no file (and no merge); if none is reached the run exits 3.
`merge` applies to each grid.

```yaml
  dsm:
    type: writer.gdal_gpu
    input: clean
    resolution: 1.0
    output_type: max
    merge: true
    grids:
      - {origin_x: 600000, origin_y: 3500000, width: 10000, height: 10000, filename: "u14_e060_n350.tif"}
      - {origin_x: 610000, origin_y: 3500000, width: 10000, height: 10000, filename: "u14_e061_n350.tif"}
```

A filename in `grids` cannot contain `,` or `;`.

## Output Bands

Bands are written in this order (only those requested via `output_type`):

1. **min** — Minimum value in cell
2. **max** — Maximum value in cell
3. **mean** — Arithmetic mean
4. **idw** — Inverse distance weighted interpolation
5. **count** — Number of points in cell
6. **stdev** — Population standard deviation
7. **pNN** — Percentile (e.g., `p50`, `p95`). Requires `binmode: true`

`output_type: all` enables min, max, mean, idw, count, and stdev (not percentiles).

## Modes

### Bin Mode (`binmode: true`)

Each raster cell uses only points whose XY coordinates fall within that cell. One GPU thread per cell iterates the sorted point list for that cell. Fast — O(points) total work.

Percentiles are only available in bin mode. They use a GPU pipeline:
1. CUB exclusive prefix sum for per-cell scatter offsets
2. Scatter values into contiguous segments
3. CUB segmented radix sort
4. Extract percentile with linear interpolation

### Radius Mode (`binmode: false`, default)

Each cell searches all points within `radius` of the cell center. One GPU thread per cell, searching neighboring grid cells. Supports IDW interpolation with configurable power.

Default radius is `resolution * √2`, matching PDAL's default.

## Coordinate Handling

pcax stores coordinates as relative FP32 values (offset-subtracted at read time). The gridding writer:

- Builds the raster grid in relative coordinate space
- Sets the GeoTransform origin using the absolute FP64 `dataMinX/Y` from metadata
- Restores absolute values in the output raster (adds `dataMinZ` back to Z-based bands)

This means the output GeoTIFF has correct absolute georeferencing despite internal FP32 storage.

## Window Fill

When `window_size > 0`, empty cells (count = 0) are filled using inverse-distance weighting from nearby populated cells within a `window_size` pixel radius. Applied on CPU after GPU rasterization. Matches PDAL's `GDALGrid::windowFill()` behavior.

## GPU Pipeline

All heavy computation runs on GPU via CUDA:

```
Host X/Y arrays → Bounding box → Grid dimensions
       ↓
Device X/Y/Z → Cell index kernel → CUB radix sort → Cell boundary kernel
       ↓
Statistics kernel (bin or radius mode) → [Percentile pipeline] → Download → GDAL write
```

When preceded by another GPU stage (e.g., `filter.outlier`), data stays on device — no redundant upload (via `ensureDevice` residency tracking).

### Profiler Output

```
├─ grid (writer.gdal_gpu)                      10215.5 ms
│  ├─ gdal_gpu: upload dims to GPU                    0.0 ms (gpu)
│  ├─ gdal_gpu: allocate grid buffers                 0.9 ms (gpu)
│  ├─ gdal_gpu: compute cell indices                  3.3 ms (gpu)
│  ├─ gdal_gpu: radix sort                           17.4 ms (gpu)
│  ├─ gdal_gpu: find cell boundaries                  1.3 ms (gpu)
│  ├─ gdal_gpu: allocate raster buffers               1.3 ms (gpu)
│  ├─ gdal_gpu: radius-mode stats                   698.4 ms (gpu)
│  ├─ gdal_gpu: download rasters                    309.2 ms (gpu)
```

## Examples

### Elevation raster (1m, binmode)

```yaml
grid:
  type: writer.gdal_gpu
  input: read
  filename: "dem.tif"
  resolution: 1.0
  binmode: true
  output_type: mean
  override_srs: "EPSG:32610"
```

### DSM with percentiles

```yaml
grid:
  type: writer.gdal_gpu
  input: read
  filename: "dsm.tif"
  resolution: 0.5
  binmode: true
  output_type: "max,p95,count"
  override_srs: "EPSG:32610"
  gdalopts: "COMPRESS=LZW"
```

### IDW interpolation with gap filling

```yaml
grid:
  type: writer.gdal_gpu
  input: denoise
  filename: "idw_surface.tif"
  resolution: 2.0
  output_type: idw
  power: 2.0
  window_size: 5
  override_srs: "EPSG:3857"
```

### Intensity raster

```yaml
grid:
  type: writer.gdal_gpu
  input: read
  filename: "intensity.tif"
  resolution: 1.0
  dimension: Intensity
  binmode: true
  output_type: mean
```
