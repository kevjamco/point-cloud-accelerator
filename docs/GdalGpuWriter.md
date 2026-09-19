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
