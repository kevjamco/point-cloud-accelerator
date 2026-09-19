# pcax stage reference

Every stage `pcax` can run, one section each: what it reads and writes, whether
it changes the point count, its PDAL counterpart, **every option the stage
reads with its exact default**, and a minimal YAML snippet. The facts are taken
from the stage's source (the `m_options` reads, `executionTarget()`, the
dimensions it touches); the file path is in each section. Section headings are
the stage type string, so `docs/Filters.md#filtervoxeldownsize` links straight
to `filter.voxeldownsize`.

Conventions used throughout:

- **Kind / device.** `CPU` stages run on the host (`(threaded)` = chunked over
  the internal thread pool); `GPU` stages run on CUDA or Metal and the executor
  uploads/downloads dimensions around them. The Metal backend is FP32-only:
  `precision: fp64` on a GPU stage errors there.
- **Reads / Writes.** Dimensions consumed and modified or added. Derived
  dimensions (e.g. `HeightAboveGround`, `NormalX`, `ClusterID`) exist in the
  pipeline and can drive `filter.range`, but `write.las` does not write them;
  `write.copc` can, via `extra_dims`.
- **Point count.** *reduced* stages drop points (`PointCloud::compact`),
  *reordered* stages permute them, *unchanged* stages only edit dimensions.
- **Radius and distance options** (`radius`, `eps`, `tolerance`,
  `search_radius`, …) are Euclidean in CRS units and require a **projected
  CRS**; on a geographic (degree) CRS the stage refuses to run — reproject
  first with `filter.reproject`. kNN options are unit-invariant.
- **Options** are all strings in YAML; types below say how each is parsed.
  Booleans marked *literal `true`* accept only that spelling. Every option
  value may use `${var}` substitution.
- **Parity** is the measured agreement with PDAL on real USGS lidar; the
  tolerance classes are explained in [Parity.md](Parity.md).

## Summary

| Stage | Device | Reads | Writes | Point count | PDAL equivalent | Options |
|---|---|---|---|---|---|---|
| [`read.las`](#readlas) | CPU (threaded) | LAS 1.2–1.4 / LAZ file | adds `X`, `Y`, `Z`, `Classification` · per `attr_dims`: `In… | set to N | `readers.las` | `filename`, `threads`, `attr_dims` |
| [`read.text`](#readtext) | CPU | delimited text / CSV file: a header line of PDAL dimension… | adds `X`, `Y`, `Z` · every other recognised header column a… | set to N | `readers.text` | `filename`, `separator`, `header`, `skip` |
| [`read.ply`](#readply) | CPU | PLY file, `ascii` or `binary_little_endian`; the `vertex` e… | adds `X`, `Y`, `Z` · every other recognised property as a F… | set to N | `readers.ply` | `filename` |
| [`filter.range`](#filterrange) | CPU (threaded) | every dimension named in `limits` | `none` | reduced | `filters.range` | `limits` |
| [`filter.crop`](#filtercrop) | CPU (threaded) | `X`, `Y`, `Z` | `none` | reduced | `filters.crop` | `bounds`, `polygon`, `outside` |
| [`filter.dem`](#filterdem) | CPU (threaded) | `X`, `Y`, the dimension named in `limits` | `none` | reduced | `filters.dem` | `raster`, `limits`, `band` |
| [`filter.assign`](#filterassign) | CPU | the dimension of each assignment; the `condition` dimension | the dimension of each assignment | unchanged | `filters.assign` | `assignment`, `condition` |
| [`filter.decimation`](#filterdecimation) | CPU | `none` | `none` | reduced | `filters.decimation` | `step`, `offset`, `limit` |
| [`filter.head`](#filterhead) | CPU | `none` | `none` | reduced | `filters.head` | `count`, `invert` |
| [`filter.tail`](#filtertail) | CPU | `none` | `none` | reduced | `filters.tail` | `count`, `invert` |
| [`filter.gpstimeconvert`](#filtergpstimeconvert) | CPU | `GpsTime` | `GpsTime` | unchanged | `filters.gpstimeconvert` | `conversion`, `in_time`, `out_time`, `start_date`, `wrap`, `wrapped`, `wrapped_tolerance` |
| [`filter.iqr`](#filteriqr) | CPU | the `dimension` named | `none` | reduced | `filters.iqr` | `dimension`, `k` |
| [`filter.mad`](#filtermad) | CPU | the `dimension` named | `none` | reduced | `filters.mad` | `dimension`, `k`, `mad_multiplier` |
| [`filter.skewnessbalancing`](#filterskewnessbalancing) | CPU | `Z`, `Classification` | `Classification` | unchanged | `filters.skewnessbalancing` | `ground_class`, `other_class`, `only_ground` |
| [`filter.sparsesurface`](#filtersparsesurface) | CPU | `X`, `Y`, `Z`, `Classification` | `Classification` | unchanged | `filters.sparsesurface` | `radius`, `ground_class`, `low_point_class` |
| [`filter.sort`](#filtersort) | CPU | the sort dimension | `none` | reordered | `filters.sort` | `dimensions`, `dimension`, `order`, `algorithm` |
| [`filter.mortonorder`](#filtermortonorder) | CPU | `X`, `Y` | `none` | reordered | `filters.mortonorder` | `reverse` |
| [`filter.transformation`](#filtertransformation) | CPU (threaded) | `X`, `Y`, `Z` | `X`, `Y`, `Z` | unchanged | `filters.transformation` | `matrix`, `invert` |
| [`filter.stats`](#filterstats) | CPU | the selected dimensions | `none` | unchanged | `filters.stats` | `dimensions`, `json` |
| [`filter.elm`](#filterelm) | CPU | `X`, `Y`, `Z`, `Classification` | `Classification` | unchanged | `filters.elm` | `cell`, `class`, `threshold` |
| [`filter.voxeldownsize`](#filtervoxeldownsize) | CPU | `X`, `Y`, `Z` | `none` in `first` mode; `X`, `Y`, `Z` snapped to voxel cent… | reduced | `filters.voxeldownsize` | `cell`, `mode` |
| [`filter.voxelcenternearestneighbor`](#filtervoxelcenternearestneighbor) | CPU | `X`, `Y`, `Z` | `none` | reduced | `filters.voxelcenternearestneighbor` | `cell` |
| [`filter.voxelcentroidnearestneighbor`](#filtervoxelcentroidnearestneighbor) | CPU | `X`, `Y`, `Z` | `none` | reduced | `filters.voxelcentroidnearestneighbor` | `cell` |
| [`filter.sample`](#filtersample) | CPU | `X`, `Y`, `Z` | `none` | reduced | `filters.sample` | `radius`, `cell`, `origin_x`, `origin_y`, `origin_z`, `dimension` |
| [`filter.smrf`](#filtersmrf) | CPU | `X`, `Y`, `Z`, `ReturnNumber`, `NumberOfReturns`, `Classifi… | `Classification` | unchanged | `filters.smrf` | `cell`, `slope`, `scalar`, `threshold`, `cut`, `window`, `returns`, `ignore`, `ground_class`, `other_class`, `only_ground` |
| [`filter.hag_dem`](#filterhag_dem) | CPU (threaded) | `X`, `Y`, `Z`, `Classification` | adds `HeightAboveGround` | unchanged | `filters.hag_dem` | `raster`, `band`, `zero_ground`, `min_clamp`, `max_clamp`, `nodata_hag`, `class` |
| [`filter.outlier`](#filteroutlier) | GPU | `X`, `Y`, `Z`, `Classification` | `Classification` | unchanged | `filters.outlier` | `method`, `k`, `multiplier`, `precision`, `search_radius` |
| [`filter.reproject`](#filterreproject) | GPU (CPU fallback) | `X`, `Y`, `Z` | `X`, `Y`, `Z`; output CRS VLRs when `write_crs` | reduced when `on_error:… | `filters.reprojection` | `out_srs`, `in_srs`, `pipeline`, `precision`, `device`, `on_error`, `out_scale`, `out_scale_z`, `grids_path`, `write_crs`, `threads` |
| [`filter.hag_nn`](#filterhag_nn) | GPU | `X`, `Y`, `Z`, `Classification` | adds `HeightAboveGround` | unchanged | `filters.hag_nn` | `count`, `max_distance`, `allow_extrapolation`, `class`, `precision` |
| [`filter.normal`](#filternormal) | GPU | `X`, `Y`, `Z` | adds `NormalX`, `NormalY`, `NormalZ`, `Curvature` | unchanged | `filters.normal` | `knn`, `always_up`, `precision` |
| [`filter.eigenvalues`](#filtereigenvalues) | GPU | `X`, `Y`, `Z` | adds `Eigenvalue0`, `Eigenvalue1`, `Eigenvalue2` | unchanged | `filters.eigenvalues` | `knn`, `normalize`, `precision` |
| [`filter.covariancefeatures`](#filtercovariancefeatures) | GPU | `X`, `Y`, `Z`; `OptimalKNN` when `optimized` or `density`… | adds the requested features: `Linearity`, `Planarity`, `Sca… | unchanged | `filters.covariancefeatures` | `knn`, `stride`, `min_k`, `radius`, `mode`, `feature_set`, `optimized` |
| [`filter.optimalneighborhood`](#filteroptimalneighborhood) | GPU | `X`, `Y`, `Z` | adds `OptimalKNN`, `OptimalRadius` | unchanged | `filters.optimalneighborhood` | `min_k`, `max_k` |
| [`filter.approximatecoplanar`](#filterapproximatecoplanar) | GPU | `X`, `Y`, `Z` | adds `Coplanar` | unchanged | `filters.approximatecoplanar` | `knn`, `thresh1`, `thresh2` |
| [`filter.planefit`](#filterplanefit) | GPU | `X`, `Y`, `Z` | adds `PlaneFit` | unchanged | `filters.planefit` | `knn` |
| [`filter.estimaterank`](#filterestimaterank) | GPU | `X`, `Y`, `Z` | adds `Rank` | unchanged | `filters.estimaterank` | `knn`, `thresh` |
| [`filter.radialdensity`](#filterradialdensity) | GPU | `X`, `Y`, `Z` | adds `RadialDensity` | unchanged | `filters.radialdensity` | `radius`, `precision` |
| [`filter.nndistance`](#filternndistance) | GPU | `X`, `Y`, `Z` | adds `NNDistance` | unchanged | `filters.nndistance` | `mode`, `k`, `precision` |
| [`filter.reciprocity`](#filterreciprocity) | GPU | `X`, `Y`, `Z` | adds `Reciprocity` | unchanged | `filters.reciprocity` | `knn`, `precision` |
| [`filter.lof`](#filterlof) | GPU | `X`, `Y`, `Z` | adds `NNDistance`, `LocalReachabilityDistance`, `LocalOutli… | unchanged | `filters.lof` | `minpts`, `precision` |
| [`filter.neighborclassifier`](#filterneighborclassifier) | GPU | `X`, `Y`, `Z`, the `dimension` being voted on, any dims nam… | `dimension` — relabels in place | unchanged | `filters.neighborclassifier` | `k`, `dimension`, `domain`, `candidate`, `precision` |
| [`filter.fps`](#filterfps) | GPU | `X`, `Y`, `Z` | none | reduced — set to `count… | `filters.fps` | `count`, `precision` |
| [`filter.cluster`](#filtercluster) | GPU | `X`, `Y`, `Z` | adds `ClusterID` | unchanged | `filters.cluster` | `tolerance`, `min_points`, `max_points`, `is3d`, `precision` |
| [`filter.dbscan`](#filterdbscan) | GPU | `X`, `Y`, `Z` | adds `ClusterID` | unchanged | `filters.dbscan` | `eps`, `min_points`, `precision` |
| [`filter.lloydkmeans`](#filterlloydkmeans) | GPU | `X`, `Y`, `Z` | adds `ClusterID` | unchanged | `filters.lloydkmeans` | `k`, `maxiters`, `precision` |
| [`filter.ml_noise`](#filterml_noise) | GPU | `X`, `Y`, `Z`, `Classification`, `Intensity`, `ReturnNumber… | `Classification` | unchanged | `none` | `model`, `threshold`, `debug_features` |
| [`write.las`](#writelas) | CPU (threaded) | `all` — replays the raw records; `X`, `Y`, `Z` are re-encod… | `none` | unchanged | `writers.las` | `filename`, `threads` |
| [`write.copc`](#writecopc) | GPU (CPU fallback) | `all` — raw records + `X`, `Y`, `Z`, `Classification`, `Ove… | `none` | unchanged | `writers.copc` | `filename`, `extra_dims`, `max_node_points`, `max_depth`, `grid_size`, `node_order`, `format`, `threads`, `a_srs`, `device` |
| [`write.text`](#writetext) | CPU | `all` present dims through `DimAccessor` — `X`/`Y`/`Z` deco… | `none` | unchanged | `writers.text` | `filename`, `format`, `delimiter`, `precision`, `write_header`, `quote_header`, `newline`, `order`, `keep_unspecified` |
| [`write.ply`](#writeply) | CPU | `all` present dims through `DimAccessor` | `none` | unchanged | `writers.ply` | `filename`, `storage_mode`, `dims`, `precision` |
| [`writer.gdal_gpu`](#writergdal_gpu) | GPU | `X`, `Y`, and the `dimension` dim | `none` | unchanged | `writers.gdal` | `filename`, `resolution`, `dimension`, `output_type`, `binmode`, `radius`, `power`, `window_size`, `nodata`, `data_type`, `gdaldriver`, `gdalopts`, `override_srs`, `default_srs`, `origin_x`, `origin_y`, `width`, `height`, `snap` |
| [`pdal.filter`](#pdalfilter) | CPU | the mapped dims: `X`, `Y`, `Z`, `Classification`, `Intensit… | the same mapped dims, as the PDAL filter left them · adds `… | set to N | any `filters.*` | `pdal_type` |

## Readers
### read.las

| | |
|---|---|
| **Kind** | reader · **CPU** (threaded LAZ chunk decompression) |
| **Source** | `src/readers/LasReader_lazperf.cpp` (LASLIB build: `src/readers/LasReader_laslib.cpp`) |
| **PDAL equivalent** | `readers.las` (also `readers.copc` — a COPC file is read as plain LAZ; the hierarchy and `bounds`/`resolution` queries are ignored) |
| **Reads** | LAS 1.2–1.4 / LAZ file (point formats 0–10; LAZ compressor 1 sequential, 2/3 parallel per chunk, fixed or variable chunks) |
| **Writes** | adds `X`, `Y`, `Z` (float32, relative), `Classification` (uint8) · per `attr_dims`: `Intensity` (uint16), `ReturnNumber`, `NumberOfReturns` (uint8), `GpsTime` (double; formats with GPS), `ScanAngle` (float32), `Synthetic`, `KeyPoint`, `Withheld`, `Overlap` (uint8), `Red`, `Green`, `Blue` (uint16; formats with RGB) · keeps the raw point records |
| **Point count** | set to N (header count; shrunk with a warning if fewer points decode) |
| **Parity** | byte-exact records (`docs/PdalFeatureMatrix.md`) |

Coordinates are stored relative to the data-derived int32 minimum
(`(raw - minRaw) * scale`); `LasMetadata` keeps scale/offset/minRaw/dataMin,
the header + VLR preamble and the EVLRs so `write.las`/`write.copc` can
replay them. Classification follows PDAL: formats ≤5 keep only the 5 class
bits and a raw class of 12 becomes class 0 with `Overlap = 1`; formats ≥6
read the four flag bits from the flag byte (`src/core/LasAttrs.cpp`).
`ScanAngle` is stored in the LAS 1.4 extended units (0.006°) for every
format (legacy int8 degrees are divided by 0.006). The LASLIB variant reads
sequentially with LASlib and does not read `threads`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Input LAS/LAZ path. One file; globs are not expanded. |
| `threads` | int | `0` | Worker threads for chunked LAZ decompression; `0` = hardware concurrency. Ignored for uncompressed LAS and compressor-1 LAZ. |
| `attr_dims` | list | `all` | Attribute dims to extract from the raw records: `all`, `none`, or a comma list of `intensity`, `returnnumber`, `numberofreturns`, `gpstime`, `scanangle`, `synthetic`, `keypoint`, `withheld`, `overlap`, `rgb`. |

```yaml
  read:
    type: read.las
    filename: "${input}"
```

---

### read.text

| | |
|---|---|
| **Kind** | reader · **CPU** |
| **Source** | `src/readers/TextReader.cpp` |
| **PDAL equivalent** | `readers.text` |
| **Reads** | delimited text / CSV file: a header line of PDAL dimension names, one row per point |
| **Writes** | adds `X`, `Y`, `Z` (float32, relative to the data minimum) · every other recognised header column as a Float64 dim (names per `dimIdFromName`, case-insensitive: `Classification`, `Intensity`, `GpsTime`, `HeightAboveGround`, …); unrecognised columns are discarded · no raw records |
| **Point count** | set to N (data rows; blank lines and rows with fewer fields than the header are skipped) |
| **Parity** | exact — `read.text → write.text` round-trips bit-exactly on 2.6M points (`docs/PdalFeatureMatrix.md`) |

The header must contain `X`, `Y` and `Z` (error otherwise). Coordinates are
stored FP32-relative with `dataMin` in the metadata and `coordsDirty` set, so
`DimAccessor`/writers reconstruct absolute values; scale is 1.0. The cloud
carries no raw LAS records, so it can feed filters, `write.text`, `write.ply`
and `writer.gdal_gpu` but not `write.las`/`write.copc`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Input text file. |
| `separator` | string | `auto` | `auto` = comma if the header line contains one, else runs of whitespace; `" "`, `"\t"`, `tab`, `space`, `whitespace` = whitespace; any other string: its first character is the delimiter. |
| `header` | string | *(none)* | Column names to use instead of the file's first line (the file then has no header line; all remaining lines are data). |
| `skip` | int | `0` | Lines to skip before the header. |

```yaml
  read:
    type: read.text
    filename: "${input}"
    separator: ","
```

---

### read.ply

| | |
|---|---|
| **Kind** | reader · **CPU** |
| **Source** | `src/readers/PlyReader.cpp` |
| **PDAL equivalent** | `readers.ply` |
| **Reads** | PLY file, `ascii` or `binary_little_endian`; the `vertex` element with scalar properties of type `char/uchar/short/ushort/int/uint/float/double` (or `int8 … float64`) |
| **Writes** | adds `X`, `Y`, `Z` (float32, relative to the data minimum) · every other recognised property as a Float64 dim (PDAL names, case-insensitive); unrecognised properties are read and discarded · no raw records |
| **Point count** | set to N (the `vertex` element count) |
| **Parity** | exact — reads pcax- and PDAL-written PLY identically on 100K points (`docs/PdalFeatureMatrix.md`) |

`binary_big_endian` and `list` vertex properties raise an error; face and
other elements are ignored (only the vertex body is read). The vertex element
must carry `X`, `Y`, `Z`. Same FP32-relative + `coordsDirty` storage as
`read.text`; no raw records, so `write.las`/`write.copc` cannot follow it.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Input PLY path. |

```yaml
  read:
    type: read.ply
    filename: "${input}"
```

## Filters — CPU
### filter.range

| | |
|---|---|
| **Kind** | filter · **CPU** (threaded) |
| **Source** | `src/filters/RangeFilter.cpp` (grammar: `include/pca/DimRange.hpp`, `src/core/DimRange.cpp`) |
| **PDAL equivalent** | `filters.range` |
| **Reads** | every dimension named in `limits` (X/Y/Z decoded exactly from the raw int32 records via `DimAccessor`) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (4 cases incl. negation, exclusive/open bounds) |

Culls points by PDAL range predicates. Ranges on the **same** dimension OR together; ranges on **different** dimensions AND together; a point that fails any dimension's group is dropped. Grammar (comma-separated list): `Dim[lo:hi]` — `Dim` is any pcax dimension name, case-insensitive (`X`, `Y`, `Z`, `Classification`, `Intensity`, `ReturnNumber`, `NumberOfReturns`, `GpsTime`, `Red`/`Green`/`Blue`, `ScanAngle`, `Synthetic`/`KeyPoint`/`Withheld`/`Overlap`, plus every derived dim such as `HeightAboveGround`, `Planarity`, `ClusterID`); `!` before the bracket negates the range; `[`/`]` are inclusive and `(`/`)` exclusive bounds; either bound may be omitted for an open range (`Z[6800:]`, `Z(:6900)`). Both bounds default to ±infinity. Unknown dimension names and malformed specs throw.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `limits` | string | *required* | Range list, e.g. `"Classification![7:7], Intensity[100:2000], Z(6800:6900]"`. |

```yaml
  keep_ground:
    type: filter.range
    input: read
    limits: "Classification[2:2], Withheld[0:0]"
```

---

### filter.crop

| | |
|---|---|
| **Kind** | filter · **CPU** (threaded) |
| **Source** | `src/filters/CropFilter.cpp` |
| **PDAL equivalent** | `filters.crop` |
| **Reads** | `X`, `Y`, `Z` (Z only for 3D `bounds`) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (bbox, `outside`, polygon with hole); on-edge points after reprojection or with PDAL `a_srs` are the FP32-storage class — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

Keeps points inside (or, with `outside: true`, outside) either an axis-aligned box or a WKT polygon; exactly one of `bounds`/`polygon` must be given. `bounds` is boundary-inclusive on every axis; a 2-group spec ignores Z, a 3-group spec also tests Z. `polygon` accepts `POLYGON` or `MULTIPOLYGON` (exterior + holes) and is tested in 2D with GEOS `covers` semantics — points exactly on an exterior or hole edge count as **inside**, matching PDAL when PDAL does not reproject the polygon. PDAL's `a_srs`, `point`/`distance` and `ogr` modes are not supported. `outside` is enabled only by the literal string `true`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `bounds` | string | — | PDAL bounds: `([xmin,xmax],[ymin,ymax])` or `([xmin,xmax],[ymin,ymax],[zmin,zmax])`; any 4 or 6 numbers in the string are taken in that order. |
| `polygon` | string | — | WKT `POLYGON`/`MULTIPOLYGON` in the point CRS. |
| `outside` | bool | `false` | Keep the points that fail the test instead. |

```yaml
  clip:
    type: filter.crop
    input: read
    bounds: "([500000,500500],[4400000,4400500])"
```

---

### filter.dem

| | |
|---|---|
| **Kind** | filter · **CPU** (threaded) |
| **Source** | `src/filters/DemFilter.cpp` |
| **PDAL equivalent** | `filters.dem` |
| **Reads** | `X`, `Y`, the dimension named in `limits` (usually `Z`) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact |

Keeps a point when its value lies in the band `raster − lower ≤ value ≤ raster + upper`, where `lower`/`upper` are the two numbers of the single `limits` range — the **lower limit is subtracted, the upper added** (PDAL's asymmetry: `Z[2:5]` keeps points from 2 below to 5 above the surface). The raster is sampled at the containing pixel (no interpolation); points falling outside the raster extent are dropped. Both band edges are inclusive regardless of bracket style, and a `!` prefix has no effect.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `raster` | string | *required* | GDAL-readable elevation raster with a geotransform. |
| `limits` | string | *required* | Exactly one range, e.g. `"Z[2:5]"`: `lower:upper` offsets from the raster surface. |
| `band` | int | `1` | Raster band to sample (≥ 1). |

```yaml
  near_ground:
    type: filter.dem
    input: read
    raster: dtm.tif
    limits: "Z[1:3]"
```

---

### filter.assign

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/AssignFilter.cpp` |
| **PDAL equivalent** | `filters.assign` (classic `assignment` form; expression-style `value` is not supported) |
| **Reads** | the dimension of each assignment; the `condition` dimension |
| **Writes** | the dimension of each assignment (in place; X/Y/Z rejected) |
| **Point count** | unchanged |
| **Parity** | exact (incl. `condition`) |

For each `Dim[range]=value` item (comma-separated), every point whose `Dim` passes the range gets `Dim` set to `value`; ranges use the `filter.range` grammar (negation and open bounds allowed). An optional `condition` range on any dimension must also hold for a point to be touched. The value is parsed as a double and stored with a plain cast to the dimension's type. Assigning to `X`/`Y`/`Z` throws. Single-threaded.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `assignment` | string | *required* | Comma list of `Dim[lo:hi]=value`, e.g. `"Classification[2:7]=0"`. One range per item. |
| `condition` | string | — | One extra range that must pass for the assignment to apply, e.g. `"Intensity[0:10]"`. |

```yaml
  reset_classes:
    type: filter.assign
    input: read
    assignment: "Classification[1:255]=0"
```

---

### filter.decimation

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/DecimationFilter.cpp` |
| **PDAL equivalent** | `filters.decimation` |
| **Reads** | `none` (index-based) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (streaming semantics) |

Keeps the points at indices `offset + llround(k · step)` for `k = 0, 1, …` while the index is `< min(limit, n)`. This reproduces PDAL's **streaming** `processOne()` path — what CLI pipelines run; PDAL's bulk `decimate()` rounds the total count and can differ by one point. `step < 1.0` throws.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `step` | double | `1.0` | Index stride between kept points (non-integer steps allowed). |
| `offset` | int | `0` | First index considered. |
| `limit` | int | `0` | One past the last index considered; `0` means no limit. |

```yaml
  thin:
    type: filter.decimation
    input: read
    step: 10
```

---

### filter.head

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/HeadTailFilters.cpp` |
| **PDAL equivalent** | `filters.head` |
| **Reads** | `none` (index-based) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (PDAL test ported; invert) |

Keeps the first `count` points in current cloud order; `invert: true` drops them and keeps the rest. Fewer than `count` points keeps everything (or, inverted, nothing).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `count` | int | `10` | Number of leading points to keep. |
| `invert` | bool | `false` | Drop the first `count` points instead of keeping them. |

```yaml
  first_1000:
    type: filter.head
    input: read
    count: 1000
```

---

### filter.tail

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/HeadTailFilters.cpp` |
| **PDAL equivalent** | `filters.tail` |
| **Reads** | `none` (index-based) |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (PDAL test ported; invert) |

Keeps the last `count` points in current cloud order (`count` is clamped to the cloud size); `invert: true` drops them and keeps the rest.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `count` | int | `10` | Number of trailing points to keep. |
| `invert` | bool | `false` | Drop the last `count` points instead of keeping them. |

```yaml
  last_1000:
    type: filter.tail
    input: read
    count: 1000
```

---

### filter.gpstimeconvert

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/GpsTimeConvertFilter.cpp` |
| **PDAL equivalent** | `filters.gpstimeconvert` |
| **Reads** | `GpsTime` |
| **Writes** | `GpsTime` (in place, double) |
| **Point count** | unchanged |
| **Parity** | exact (gt/gst/gws/gds; 4 conversions bit-exact on real tile) |

Converts `GpsTime` between `gt` (seconds since the GPS epoch 1980-01-06), `gst` (adjusted standard time, `gt − 1e9`), `gws` (GPS week seconds) and `gds` (GPS day seconds). Operation-for-operation port of PDAL, including its `std::mktime` date arithmetic (the local-timezone offset cancels), one shared `numSeconds` offset computed from `start_date` (gws/gds input) or from the **first point's** date (gt/gst input), and the serial unwrap (`wrapped`, adds a period whenever time drops by more than `wrapped_tolerance` below the previous point) and wrap (`wrap`, folds output into `[0, period)`) — so results depend on point order. Type names are case-insensitive; the cloud must have a `GpsTime` dimension.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `conversion` | string | — | `"{in}2{out}"`, e.g. `gt2gws`. Mutually exclusive with `in_time`/`out_time`. |
| `in_time` | enum(gt\|gst\|gws\|gds) | — | Input representation (use together with `out_time`). |
| `out_time` | enum(gt\|gst\|gws\|gds) | — | Output representation. |
| `start_date` | string | — | `YYYY-MM-DD`; required when the input is `gws` or `gds`. |
| `wrap` | bool | `false` | Wrap week/day-seconds output into one period. |
| `wrapped` | bool | `false` | Input week/day seconds have wrapped; unwrap them serially. |
| `wrapped_tolerance` | double | `1.0` | Seconds of backward jitter tolerated before an unwrap is triggered. |

```yaml
  to_week_seconds:
    type: filter.gpstimeconvert
    input: read
    conversion: gst2gws
```

---

### filter.iqr

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/IqrMadFilters.cpp` |
| **PDAL equivalent** | `filters.iqr` |
| **Reads** | the `dimension` named |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (Z & Intensity on real tile) |

Drops points whose value lies outside the open interval `(Q1 − k·IQR, Q3 + k·IQR)` — the bounds themselves are dropped (strict `>`/`<`). Quartiles are taken by `nth_element` at indices `int(n·0.25)` and `int(n·0.75)`, exactly as PDAL.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `dimension` | string | *required* | Dimension to test (must exist on the cloud). |
| `k` | double | `1.5` | Fence multiplier on the interquartile range. |

```yaml
  z_fence:
    type: filter.iqr
    input: read
    dimension: Z
    k: 1.5
```

---

### filter.mad

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/IqrMadFilters.cpp` |
| **PDAL equivalent** | `filters.mad` |
| **Reads** | the `dimension` named |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (Z on real tile) |

Drops points with `|v − median| / mad ≥ k`, where `mad = median(|v − median|) · mad_multiplier`. Both medians use `nth_element` at index `n/2`, as PDAL.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `dimension` | string | *required* | Dimension to test (must exist on the cloud). |
| `k` | double | `2.0` | Deviation threshold in scaled-MAD units. |
| `mad_multiplier` | double | `1.4862` | Scale applied to the raw MAD (normal-consistency constant). |

```yaml
  z_mad:
    type: filter.mad
    input: read
    dimension: Z
    k: 3.0
```

---

### filter.skewnessbalancing

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/SkewnessBalancingFilter.cpp` |
| **PDAL equivalent** | `filters.skewnessbalancing` |
| **Reads** | `Z`, `Classification` |
| **Writes** | `Classification` (relabels every point unless `only_ground`) |
| **Point count** | unchanged |
| **Parity** | ground **count exact**; ~1.1% boundary membership differs (Z-tie ordering) — [Parity.md](Parity.md#tie-breaking-order) |

Bartels & Wei (2006) ground classification: points are visited in ascending Z while the running skewness of the Z distribution (Welford M1/M2/M3) is tracked; each non-positive→positive crossing closes a block labeled `ground_class`, and the trailing block gets `other_class` (skipped when `only_ground`). pcax argsorts indices instead of reordering the cloud, so the skewness sequence equals PDAL's. Equal-Z ties are ordered by point index (PDAL's `std::sort` is unstable), which is the only source of label differences. Requires a `Classification` dimension.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `ground_class` | int | `2` | Class written to ground blocks. |
| `other_class` | int | `1` | Class written to the trailing non-ground block. |
| `only_ground` | bool | `false` | Write only ground labels; leave other points' classes untouched. |

```yaml
  ground:
    type: filter.skewnessbalancing
    input: read
```

---

### filter.sparsesurface

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/SparseSurfaceFilter.cpp` (radius guard: `src/filters/RadiusGuard.hpp`) |
| **PDAL equivalent** | `filters.sparsesurface` |
| **Reads** | `X`, `Y`, `Z`, `Classification` |
| **Writes** | `Classification` (every point relabeled) |
| **Point count** | unchanged |
| **Parity** | ground/noise counts within 39/2.6M; 99.5% labels exact (Z-tie greedy order) — [Parity.md](Parity.md#tie-breaking-order) |

Greedy sparse-surface noise marking (Wimmer): all points are first set to a computed "unclassified" value adjacent to `ground_class`/`low_point_class`; then, in ascending Z, the lowest still-unlabeled point becomes `ground_class` and every still-unlabeled point within `radius` of it in 2D (`≤ radius`) becomes `low_point_class`. Serial by nature (labels depend on lower points); a host uniform grid with cell = `radius` serves the radius queries. Z ties are ordered by point index. **Requires a projected CRS** and a radius smaller than the XY extent (the shared radius guard throws otherwise).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `radius` | double | `1.0` | 2D neighbourhood radius in CRS units (> 0). |
| `ground_class` | int | `2` | Class for the lowest point of each neighbourhood. |
| `low_point_class` | int | `7` | Class for points within `radius` of a ground point. |

```yaml
  low_noise:
    type: filter.sparsesurface
    input: read
    radius: 1.0
```

---

### filter.sort

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/SortFilter.cpp` |
| **PDAL equivalent** | `filters.sort` |
| **Reads** | the sort dimension(s) |
| **Writes** | `none` (all dims + raw records permuted together via `reorder`) |
| **Point count** | reordered |
| **Parity** | output sorted by dim(s) (ASC/DESC, NORMAL/STABLE); verified monotonic + dim-aligned |

Reorders points by one or more dimensions. `dimensions` (or `dimension`) is a comma-, semicolon- or space-separated list of pcax dimension names (case-insensitive; every name must exist on the cloud). With several dimensions the first is sorted, then each subsequent one is **stable-sorted**, so the **last listed dimension is the primary key** — PDAL's behaviour; in that case `algorithm` is ignored (first pass `std::sort`, later passes `std::stable_sort`). For a single dimension `algorithm: STABLE` preserves input order among equal values; `NORMAL` uses `std::sort`. `order` accepts `ASC` or `DESC`/`DESCENDING` (case-insensitive; anything else sorts ascending). Implemented as an argsort of an index array followed by `PointCloud::reorder`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `dimensions` | list | *required* (or `dimension`) | Dimension name(s) to sort by; last listed = primary key. |
| `dimension` | string | — | Single-dimension alias, used when `dimensions` is absent. |
| `order` | enum(ASC\|DESC) | `ASC` | Sort direction (applies to all listed dimensions). |
| `algorithm` | enum(NORMAL\|STABLE) | `NORMAL` | `STABLE` keeps input order among ties (single dimension only). |

```yaml
  by_time:
    type: filter.sort
    input: read
    dimensions: GpsTime
    order: ASC
```

---

### filter.mortonorder

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/MortonOrderFilter.cpp` |
| **PDAL equivalent** | `filters.mortonorder` |
| **Reads** | `X`, `Y` |
| **Writes** | `none` (all dims + raw records permuted together via `reorder`) |
| **Point count** | reordered |
| **Parity** | **bit-exact order** vs PDAL (2.6M points, default Z-order) |

Reorders points along the 2D Morton (Z-order) curve for spatial locality. Port of PDAL's default path: X/Y are normalized to `[0,1]` over the cloud's bounds, scaled by `INT_MAX` and truncated to `int`, then ordered by PDAL's most-significant-differing-bit comparator; `std::stable_sort` reproduces PDAL's `multimap` equal-key (ascending index) order. `reverse: true` (PDAL's bucketed reverse encoding) is not ported and throws — use `pdal.filter` for it.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `reverse` | bool | `false` | Reverse Morton encoding; **not supported** (throws when true). |

```yaml
  zorder:
    type: filter.mortonorder
    input: read
```

---

### filter.transformation

| | |
|---|---|
| **Kind** | filter · **CPU** (threaded) |
| **Source** | `src/filters/TransformationFilter.cpp` |
| **PDAL equivalent** | `filters.transformation` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | `X`, `Y`, `Z` (rewritten; metadata offset/dataMin/minRaw renormalized, `coordsDirty` set) |
| **Point count** | unchanged |
| **Parity** | exact at 1e-7 (fp32 storage) |

Applies a 4×4 homogeneous matrix to XYZ in absolute (double) coordinates, then renormalizes the cloud's FP32 storage against the new data minimum (offset == dataMin, minRaw == 0 — the same pattern as `filter.reproject`), marking raw records stale so downstream predicates and the writer use the transformed values. Only the first three matrix rows affect the result (no perspective divide). `invert` (literal `true`) applies the inverse; a singular matrix throws. PDAL's `override_srs` is not supported.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `matrix` | string | *required* | 16 whitespace-separated numbers, row-major `m00 m01 m02 m03 m10 … m33`. |
| `invert` | bool | `false` | Apply the inverse of `matrix`. |

```yaml
  shift_up:
    type: filter.transformation
    input: read
    matrix: "1 0 0 0  0 1 0 0  0 0 1 10  0 0 0 1"
```

---

### filter.stats

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/StatsFilter.cpp` |
| **PDAL equivalent** | `filters.stats` (`enumerate`/`global`/`count`/`advanced`/`commonsrs` not supported) |
| **Reads** | the selected dimensions (default: all present) |
| **Writes** | `none` (pass-through) |
| **Point count** | unchanged |
| **Parity** | exact |

Logs `count`/`min`/`max`/`mean`/`stddev` per dimension (Welford; stddev in sample form, `n−1`, like PDAL) and leaves the cloud untouched. With `json`, the same numbers are written as a JSON object (`{"count": N, "dims": {"Z": {"min", "max", "mean", "stddev"}, …}}`) at full double precision (`%.17g`) — the integration suite's per-stage fingerprint. Unknown dimension names throw.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `dimensions` | list | all dimensions present | Comma-separated dimension names to summarize. |
| `json` | string | — | Path of a JSON file to write the statistics to. |

```yaml
  stats:
    type: filter.stats
    input: read
    dimensions: X, Y, Z, Intensity
    json: stats.json
```

---

### filter.elm

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/ElmFilter.cpp` |
| **PDAL equivalent** | `filters.elm` |
| **Reads** | `X`, `Y`, `Z`, `Classification` |
| **Writes** | `Classification` (noise points set to `class`) |
| **Point count** | unchanged |
| **Parity** | exact (2 configs) |

Extended Local Minimum low-noise marking. Points are binned into XY cells; within each cell holding more than one point, elevations are walked from the lowest upward and each point is marked `class` while the gap to the next-lowest point is `≥ threshold`; the walk stops at the first gap `< threshold`. The cell index preserves PDAL's floor-before-divide quirk: `col = (size_t)(floor(x − minx) / cell)`. Cell sorting is stable, so equal-Z points keep input order.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `cell` | double | `10.0` | XY cell size in CRS units. |
| `class` | int | `7` | Classification written to detected low-noise points. |
| `threshold` | double | `1.0` | Minimum elevation gap that marks the lower point as noise. |

```yaml
  low_noise:
    type: filter.elm
    input: read
    cell: 10.0
    threshold: 1.0
```

---

### filter.voxeldownsize

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/VoxelFilters.cpp` |
| **PDAL equivalent** | `filters.voxeldownsize` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | `none` in `first` mode; `X`, `Y`, `Z` snapped to voxel centres in `center` mode (renormalized, `coordsDirty` set) |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (first + center modes) |

Keeps the first point (input order) seen in each voxel. Voxel origin follows PDAL: the **first point minus `cell/2`** on each axis. In `center` mode the kept point's coordinates are replaced by its voxel centre and the cloud's FP32 storage is renormalized (offset == dataMin, minRaw == 0). Output preserves input order. `cell ≤ 0` or an unknown `mode` throws.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `cell` | double | `0.001` | Voxel edge length in CRS units. |
| `mode` | enum(center\|first) | `center` | `first` keeps the first point's own coordinates; `center` snaps it to the voxel centre. |

```yaml
  downsize:
    type: filter.voxeldownsize
    input: read
    cell: 0.5
    mode: first
```

---

### filter.voxelcenternearestneighbor

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/VoxelFilters.cpp` |
| **PDAL equivalent** | `filters.voxelcenternearestneighbor` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (point set; output keeps input order) |

Keeps, per voxel, the point nearest the voxel centre (squared Euclidean distance; on an exact tie the earlier point wins). Voxel origin is the cloud's data minimum (`LasMetadata::dataMin`), i.e. the bounds minimum as in PDAL. pcax emits the kept points in input order, whereas PDAL emits voxel-sorted order — the kept **set** is identical.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `cell` | double | `1.0` | Voxel edge length in CRS units (> 0). |

```yaml
  vcnn:
    type: filter.voxelcenternearestneighbor
    input: read
    cell: 1.0
```

---

### filter.voxelcentroidnearestneighbor

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/VoxelFilters.cpp` |
| **PDAL equivalent** | `filters.voxelcentroidnearestneighbor` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | count exact; 8/1.62M kept-set diff (FP32 voxel-boundary near-ties) — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

One point per voxel: a lone point is kept; with two points the one nearer the voxel **centre** is kept (on equal distance the second, as PDAL); with more, the one nearest the voxel **centroid** (mean of its points), first-achieving-the-minimum on ties. Voxel origin is the **first point** (PDAL convention — different from voxelcenternearestneighbor's bounds minimum). Output keeps input order.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `cell` | double | `1.0` | Voxel edge length in CRS units (> 0). |

```yaml
  vcentroid:
    type: filter.voxelcentroidnearestneighbor
    input: read
    cell: 1.0
```

---

### filter.sample

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/SampleFilter.cpp` |
| **PDAL equivalent** | `filters.sample` (`dimension` mark-don't-cull mode not supported) |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | `none` |
| **Point count** | reduced (drops points; `compact`) |
| **Parity** | exact (count + stats, 2 radii); ~1.6× faster than PDAL |

Poisson-disk subsampling: points are visited in input order and a point is kept only if no already-kept point lies strictly within `radius` (3D). Give `radius` **or** `cell` — `cell = 2·radius/√3` (so the 3×3×3 voxel neighbourhood covers the radius) and each derives the other; `radius` wins if both are set. The voxel-hash origin defaults to the first point, replicating PDAL's quirk that the default **Z origin is the first point's Y** (set `origin_z` to override). Inherently serial (order-dependent). Setting `dimension` throws — use `pdal.filter`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `radius` | double | — (one of `radius`/`cell` required) | Minimum distance between kept points, CRS units. |
| `cell` | double | — | Voxel size; radius derived as `cell/2·√3`. |
| `origin_x` | double | first point's X | Voxel-hash origin X. |
| `origin_y` | double | first point's Y | Voxel-hash origin Y. |
| `origin_z` | double | first point's **Y** (PDAL quirk) | Voxel-hash origin Z. |
| `dimension` | string | — | Mark-instead-of-cull mode; **not supported** (throws when set). |

```yaml
  poisson:
    type: filter.sample
    input: read
    radius: 0.5
```

---

### filter.smrf

| | |
|---|---|
| **Kind** | filter · **CPU** |
| **Source** | `src/filters/SmrfFilter.cpp` (morphology: `src/filters/Morphology.hpp`) |
| **PDAL equivalent** | `filters.smrf` (`dir`, `classbits` not supported) |
| **Reads** | `X`, `Y`, `Z`, `ReturnNumber`, `NumberOfReturns`, `Classification`, any dims named in `ignore` |
| **Writes** | `Classification` (inlier points relabeled `ground_class`/`other_class`; ignored/non-selected returns untouched) |
| **Point count** | unchanged |
| **Parity** | ≥99.99% label agreement, confined to void raster cells (8-NN inpainting ties; shrinks to ~0 at larger cells) — [Parity.md](Parity.md#tie-breaking-order) |

Simple Morphological Filter (Pingel et al. 2013), ported operation-for-operation from PDAL: column-major rasters, cumulative diamond erosion in the progressive filter, MATLAB-style gradients and 8-nearest-cell running-mean inpainting of voids. Segmentation first: points passing any `ignore` range are excluded, then only the `returns` categories are kept (`first` = r==1 & n>1, `intermediate` = 1<r<n, `last` = r==n & n>1, `only` = n==1); if the return dims are missing or all zero, return segmentation is skipped with a warning; zero inliers throws. Unless `only_ground`, all inliers start as `other_class`. Pipeline over the inlier bounds at `cell`: per-cell min-Z raster → inpaint → low-outlier mask (progressive filter on the inverted surface, slope 5.0) → optional net cutting (`cut > 0`: every `ceil(cut/cell)`-th row/column replaced by an opening of radius `2·ceil(cut/cell)`) → object mask via progressive opening up to `window` with per-radius threshold `slope·cell·radius` → provisional DEM (object/low/net cells voided, re-inpainted) → per-cell threshold `threshold + scalar·|∇(DEM/cell)|`. An inlier is ground when `|DEM(cell) − z| ≤` that threshold. `only_ground` is enabled only by the literal string `true`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `cell` | double | `1.0` | Raster cell size in CRS units. |
| `slope` | double | `0.15` | Slope tolerance (rise/run) feeding the progressive-filter threshold `slope·cell·radius`. |
| `scalar` | double | `1.25` | Multiplier on the DEM gradient in the elevation threshold. |
| `threshold` | double | `0.5` | Base elevation threshold (CRS units) above the provisional DEM. |
| `cut` | double | `0.0` | Net-cutting spacing; `0` disables. |
| `window` | double | `18 · cell` | Maximum opening window (CRS units) of the progressive filter. |
| `returns` | list | `last,only` | Return categories used: any of `first`, `intermediate`, `last`, `only`. |
| `ignore` | string | — | `filter.range`-grammar ranges; points passing any are excluded from processing. |
| `ground_class` | int | `2` | Class written to ground inliers. |
| `other_class` | int | `1` | Class written to non-ground inliers (unless `only_ground`). |
| `only_ground` | bool | `false` | Write only ground labels; leave other classes untouched. |

```yaml
  ground:
    type: filter.smrf
    input: read
    cell: 1.0
    slope: 0.15
    ignore: "Classification[7:7]"
```

---

### filter.hag_dem

| | |
|---|---|
| **Kind** | filter · **CPU** (threaded) |
| **Source** | `src/filters/HagFilters.cpp` |
| **PDAL equivalent** | `filters.hag_dem` |
| **Reads** | `X`, `Y`, `Z`, `Classification` |
| **Writes** | adds `HeightAboveGround` (double) |
| **Point count** | unchanged |
| **Parity** | exact |

Height above ground from a raster: `HAG = Z − raster(containing pixel)`, no interpolation, clamped to `[min_clamp, max_clamp]`. Points classified `class` get `0` when `zero_ground` (default) is on. Points outside the raster extent, or whose pixel equals the band's nodata value, get `nodata_hag`. The result is an in-pipeline dimension (usable by `filter.range`, not written to LAS). `zero_ground` is disabled by any value other than the literal `true`.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `raster` | string | *required* | GDAL-readable ground raster with a geotransform. |
| `band` | int | `1` | Raster band to sample. |
| `zero_ground` | bool | `true` | Set HAG to 0 for points of class `class` instead of sampling. |
| `min_clamp` | double | none | Lower clamp on HAG. |
| `max_clamp` | double | none | Upper clamp on HAG. |
| `nodata_hag` | double | `0.0` | HAG for points outside the raster or on nodata pixels. |
| `class` | int | `2` | Ground classification code used by `zero_ground`. |

```yaml
  hag:
    type: filter.hag_dem
    input: read
    raster: dtm.tif
```

## Filters — GPU
### filter.outlier

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/SorFilter.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.outlier` (`mean_k` → `k`) |
| **Reads** | `X`, `Y`, `Z`, `Classification` |
| **Writes** | `Classification` (outliers set to 7, LowPoint/noise) |
| **Point count** | unchanged |
| **Parity** | point-identical flagged set in exact mode; post-reproject threshold ties within ~µm flip either way (~1 pt/1.5M) — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

Statistical outlier removal (SOR): per point, the mean 3D distance to its `k`
nearest neighbours (query excluded); globally `threshold = mean + multiplier ·
stddev` over all points' mean distances (sample stddev, N−1); a point is
flagged noise when `mean_dist >= threshold`. The kNN search is exact
(expanding grid rings until the k-th distance is within `d · cellSize`),
matching PDAL's unbounded KD-tree. `search_radius > 0` switches to a
pcax-native bounded mode with no PDAL equivalent: only neighbours within the
radius count, points without `k` of them are flagged noise outright and
excluded from the statistics; this mode requires a projected CRS and a radius
smaller than the data's XY extent (`RadiusGuard.hpp`). Only `method:
statistical` is implemented; PDAL's `class`/`min_k`/`radius` are not honoured
(outliers are always class 7). `k` is capped at 32. Metal: FP32 kernels only
(`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `method` | enum(statistical) | `statistical` | Only `statistical` is accepted; anything else errors. |
| `k` | int | `8` | Number of nearest neighbours (PDAL `mean_k`); max 32. |
| `multiplier` | double | `2.0` | Standard-deviation multiplier for the threshold. |
| `precision` | enum(fp32\|fp64) | `fp32` | `fp64` runs the distance/threshold math in double (coords stay FP32 either way); rejected on Metal. |
| `search_radius` | double | `0.0` | `0` = exact unbounded kNN (PDAL parity). `>0` = bounded mode in CRS units: neighbours beyond the radius are ignored and points lacking `k` neighbours are flagged noise. Needs a projected CRS. |

```yaml
  denoise:
    type: filter.outlier
    input: read
    k: 8
    multiplier: 2.0
```

---

### filter.reproject

| | |
|---|---|
| **Kind** | filter · **GPU** (CPU fallback: host PROJ when a pipeline step is not GPU-supported, `device: cpu`, or on the Metal backend) |
| **Source** | `src/filters/ReprojectFilter.cpp` (+ `.cu`, `src/reproj/`) |
| **PDAL equivalent** | `filters.reprojection` (`error_on_failure` → `on_error`); `filters.projpipeline` (`coord_op` → `pipeline`) |
| **Reads** | `X`, `Y`, `Z` (+ the file's CRS VLRs for `in_srs`) |
| **Writes** | `X`, `Y`, `Z` (rewritten; renormalizes scale/offset, sets `coordsDirty`); output CRS VLRs when `write_crs` |
| **Point count** | reduced when `on_error: drop` (default) and PROJ fails on some points; otherwise unchanged |
| **Parity** | fp64: < 1e-8 m per-op vs PROJ, output limited by storage quantization; failure mask matches host PROJ point-for-point — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

Full CRS-to-CRS reprojection. Planning runs on the host through libproj
(operation selection for the data bbox, GIS axis order, grid resolution); the
compiled op chain executes in one fused GPU kernel when every step is
supported, otherwise on multithreaded host PROJ (FP64, always correct). A CPU
fallback is never silent: the stage logs a `WARN … NOT using the GPU op-chain`
line with the reason. If source and target CRS are equivalent the stage is a
no-op. Output coordinates are renormalized (`offset == dataMin`, `minRaw == 0`)
with an `auto` scale = next power of ten above `span / 2^23` (exact int32
round-trip through the writer). With `on_error: keep`, failed points stay with
coordinates at the new origin. Metal: the GPU op-chain is CUDA-only, so
reprojection always runs on host PROJ (FP64) there.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `out_srs` | string | *required* unless `pipeline` is given | Target CRS — anything PROJ accepts (`EPSG:32756`, WKT, compound `EPSG:6344+5703`). With `pipeline`, used only for the output CRS VLR. |
| `in_srs` | string | *(from file)* | Source CRS override; default is parsed from the file's WKT VLR / GeoTIFF keys (error if none). |
| `pipeline` | string | — | Raw PROJ pipeline string; bypasses CRS planning. |
| `precision` | enum(fp64\|fp32) | `fp64` | `fp32` is a reduced-accuracy dev mode (~metre-level horizontal error, loud warning). |
| `device` | enum(gpu\|cpu) | `gpu` | `cpu` forces the host PROJ path (FP64). Also the executor residency hint. |
| `on_error` | enum(drop\|fail\|keep) | `drop` | What to do with points PROJ cannot transform: drop them (PDAL streaming parity), abort, or keep them at the origin. |
| `out_scale` | string | `auto` | Output X/Y quantization scale: `auto` or a positive number. |
| `out_scale_z` | string | `out_scale` | Output Z quantization scale: `auto` or a positive number. |
| `grids_path` | string | — | Directory of GTG grids, prepended to PROJ's search paths. |
| `write_crs` | bool | `true` | Rewrite the output CRS VLRs (WKT + EPSG GeoTIFF key directory). |
| `threads` | int | `0` | Thread count for the host PROJ fallback (`0` = hardware concurrency). Not documented in Reprojection.md. |

```yaml
  reproject:
    type: filter.reproject
    input: read
    out_srs: "EPSG:6344+5703"
```

---

### filter.hag_nn

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/HagFilters.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.hag_nn` |
| **Reads** | `X`, `Y`, `Z`, `Classification` |
| **Writes** | adds `HeightAboveGround` (double) |
| **Point count** | unchanged |
| **Parity** | exact (verified via a downstream `filter.range` on HAG) — [Parity.md](Parity.md) |

Height above ground from nearest ground returns. Ground points (`class`) get
HAG 0; every other point finds its `count` nearest ground points in 2D
(expanding-ring search over a grid built on the ground points) and takes
`Z − z_ground`, where `z_ground` is the nearest ground Z (`count: 1`, or when
the query shares XY with a ground point) or the 1/d²-weighted mean of the
neighbours (`count > 1`), stopping at the first neighbour beyond
`max_distance`; with `allow_extrapolation: false`, points outside the ground
XY bounds get HAG 0. Mirrors PDAL's HagNnFilter. Errors (logged, no dim
values) when no point carries the ground class. Metal: FP32 kernels
(`precision: fp64` errors); agrees with CUDA to ~2e-6 m.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `count` | int | `1` | Number of nearest ground points; 1 = nearest Z, >1 = inverse-distance-squared weighted surface. Range 1..16. |
| `max_distance` | double | `0.0` | Ignore ground neighbours farther than this (2D, CRS units); `0` = no cutoff. |
| `allow_extrapolation` | bool | `true` | When `false`, points outside the ground XY bounding box get HAG 0. |
| `class` | int | `2` | Classification value treated as ground. |
| `precision` | enum(fp32) | `fp32` | The kernel is FP32 on both backends; `fp64` is rejected on Metal and accepted-but-ignored on CUDA. |

```yaml
  hag:
    type: filter.hag_nn
    input: read
    count: 1
```

---

### filter.normal

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NormalFilters.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.normal` (`radius`/`viewpoint`/`refine` unsupported) |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `NormalX`, `NormalY`, `NormalZ`, `Curvature` (double) |
| **Point count** | unchanged |
| **Parity** | distributions agree to ~1e-6; occasional single-point flips at thresholds (Jacobi vs Eigen QL) — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Per point, finds `knn`+1 nearest neighbours in 3D (query included, as in
PDAL), builds the sample covariance with residuals passed through float
(replicating PDAL's `computeCovariance`) and Jacobi-eigendecomposes it. The
normal is the eigenvector of the smallest eigenvalue, flipped to +Z when
`always_up`; `Curvature = |λ0 / Σλ|` (0 when the sum is 0). Shares the device
kNN/covariance/eigensolver with the other neighbourhood filters
(`NeighborhoodMath.cuh`). Metal: covariance/eigensolve in FP32
(`precision: fp64` errors); outputs stay Float64.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Number of neighbours (query point added on top). |
| `always_up` | bool | `true` | Orient normals so `NormalZ >= 0`. |
| `precision` | enum(fp32) | `fp32` | The kernel is FP32 on both backends; `fp64` is rejected on Metal and accepted-but-ignored on CUDA. |

```yaml
  normals:
    type: filter.normal
    input: read
    knn: 8
```

---

### filter.eigenvalues

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NormalFilters.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.eigenvalues` (`stride`/`radius`/`min_k` unsupported) |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `Eigenvalue0`, `Eigenvalue1`, `Eigenvalue2` (double, ascending) |
| **Point count** | unchanged |
| **Parity** | 1 pt/2.28M at a threshold (eigensolver noise) — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Same neighbourhood covariance as `filter.normal` (`knn`+1 neighbours, query
included, float-residual covariance, Jacobi eigensolver); writes the three
eigenvalues in ascending order. `normalize` divides each by their sum. Metal:
FP32 kernels (`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Number of neighbours (query point added on top). |
| `normalize` | bool | `false` | Divide eigenvalues by their sum. |
| `precision` | enum(fp32) | `fp32` | The kernel is FP32 on both backends; `fp64` is rejected on Metal and accepted-but-ignored on CUDA. |

```yaml
  eig:
    type: filter.eigenvalues
    input: read
    knn: 8
```

---

### filter.covariancefeatures

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/CovarianceFeaturesFilter.cpp` (+ `.cu`, `.metal.cpp`, `CovarianceFeaturesParams.hpp`) |
| **PDAL equivalent** | `filters.covariancefeatures` (`threads` ignored) |
| **Reads** | `X`, `Y`, `Z`; `OptimalKNN` when `optimized` or `density`; `OptimalRadius` when `density` |
| **Writes** | adds the requested features (double): `Linearity`, `Planarity`, `Scattering`, `Verticality`, `Omnivariance`, `Anisotropy`, `Eigenentropy`, `EigenvalueSum`, `SurfaceVariation`, `DemantkeVerticality`, `Density` |
| **Point count** | unchanged |
| **Parity** | ≤~13 pt/2.6M at feature thresholds (eigensolver/eigenvector noise; Verticality/DemantkeVerticality most sensitive near-degenerate); PDAL's analytic unit test reproduces exactly — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Local geometric descriptors from the neighbourhood-covariance eigen-
decomposition (Guinard & Landrieu 2017; Demantke 2011). Eigenvalues
`l0 >= l1 >= l2` are clamped to `>= 0`, then `mode` is applied before the
feature formulas (`Linearity (l0−l1)/l0`, `Planarity (l1−l2)/l0`,
`Scattering l2/l0`, `Omnivariance cbrt(l0·l1·l2)`, `Anisotropy (l0−l2)/l0`,
`Eigenentropy −Σ li ln li`, `Verticality` = z of the unary vector,
`DemantkeVerticality 1−|e3.z|`, `Density (kopt+1)/((4/3)π ropt³)`);
`EigenvalueSum` and `SurfaceVariation l2/sum` use the raw sum, as in PDAL.
Neighbour selection mirrors PDAL: `knn` mode keeps every `stride`-th of the
`(knn+1)·stride` nearest; `radius` mode (set when `radius` is present) uses
all neighbours within `radius`, needs a projected CRS (`RadiusGuard.hpp`);
`optimized` uses each point's `OptimalKNN`. Neighbourhoods with fewer than
`max(min_k, 3)` points leave the features at 0. Metal: all-FP32 kernel
(`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `10` | Neighbours per point; `(knn+1)·stride` must be ≤ 64 (unless radius/optimized). |
| `stride` | int | `1` | Keep every `stride`-th of the nearest neighbours (values < 1 → 1). |
| `min_k` | int | `3` | Minimum neighbours required to compute features. |
| `radius` | double | — | Presence switches to radius mode (CRS units, projected CRS required). |
| `mode` | enum(raw\|sqrt\|normalized) | `sqrt` | Transform applied to the clamped eigenvalues before the feature formulas (case-insensitive). |
| `feature_set` | list | `dimensionality` | Comma/space/semicolon list, case-insensitive: `dimensionality` (Linearity, Planarity, Scattering, Verticality), `all`, or any of `linearity`, `planarity`, `scattering`, `verticality`, `omnivariance`, `anisotropy`, `eigenentropy`, `eigenvaluesum`, `surfacevariation`, `demantkeverticality`, `density`. Unknown names error. |
| `optimized` | bool | `false` | Use per-point `OptimalKNN` (run `filter.optimalneighborhood` first). |

```yaml
  covfeat:
    type: filter.covariancefeatures
    input: read
    knn: 10
    feature_set: dimensionality
```

---

### filter.optimalneighborhood

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/OptimalNeighborhoodFilter.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.optimalneighborhood` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `OptimalKNN` (double, integer-valued), `OptimalRadius` (double) |
| **Point count** | unchanged |
| **Parity** | OptimalRadius near-exact (~1 pt/2.6M); OptimalKNN is an argmin so adjacent-k near-ties flip ≤~31 pt/544K — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Per point, picks the neighbourhood size `k` in `[min_k, max_k]` that
minimizes the normalized-eigenvalue Shannon entropy (Weinmann et al. 2015):
an operation-for-operation port of PDAL — incremental double Welford
covariance over full double coordinates, per-k eigen-decomposition of
`B/(n−1)`, eigenvalues normalized by their sum. Writes `OptimalKNN = k` and
`OptimalRadius` = distance to that k-th neighbour. Feeds
`filter.covariancefeatures` (`optimized` and `Density`). Metal: Welford/entropy
in FP32 (CUDA runs them in double), so single-point k flips at near-ties are
expected; `precision: fp64` errors.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `min_k` | int | `10` | Smallest k tried (must be ≥ 2). |
| `max_k` | int | `14` | Largest k tried (≥ `min_k`, ≤ 64). |

```yaml
  optneigh:
    type: filter.optimalneighborhood
    input: read
    min_k: 10
    max_k: 14
```

---

### filter.approximatecoplanar

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/ApproximateCoplanarFilter.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.approximatecoplanar` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `Coplanar` (double, 0/1) |
| **Point count** | unchanged |
| **Parity** | 3 pt/1.87M at the eigenvalue-ratio thresholds (eigensolver noise); analytic cases exact — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Labels `Coplanar = 1` when the `knn` (query point included) covariance
eigenvalues `ev0 <= ev1 <= ev2` satisfy `ev1 > thresh1·ev0` and
`thresh2·ev1 > ev2` — a flat, not-too-elongated neighbourhood. Raw
eigenvalues (not clamped), float-residual covariance, as in PDAL. Metal:
all-FP32 kernel (`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Neighbours per point, in `[1, 64]`. |
| `thresh1` | double | `25.0` | Lower ratio: requires `ev1 > thresh1 · ev0`. |
| `thresh2` | double | `6.0` | Upper ratio: requires `thresh2 · ev1 > ev2`. |

```yaml
  coplanar:
    type: filter.approximatecoplanar
    input: read
    knn: 8
```

---

### filter.planefit

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborhoodFeatureFilters.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.planefit` (`threads` ignored) |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `PlaneFit` (double) |
| **Point count** | unchanged |
| **Parity** | ≤6 pt/2.12M at thresholds (eigensolver noise); PDAL's unit test reproduces exactly — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Fits the least-squares plane to the `knn` neighbours (query **excluded**;
float-residual covariance, smallest-eigenvalue normal), then
`PlaneFit = d / (d + d_bar)` where `d` is the query's point-to-plane distance
and `d_bar` is the neighbours' summed plane distance divided by `knn` (PDAL
divides by the option, not the count) — 0 on a perfect plane, → 1 for an
off-plane apex. Metal: FP32 kernel (`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Neighbours used for the plane fit, in `[2, 64]`. |

```yaml
  planefit:
    type: filter.planefit
    input: read
    knn: 8
```

---

### filter.estimaterank

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborhoodFeatureFilters.cpp` (+ `.cu`, `.metal.cpp`) |
| **PDAL equivalent** | `filters.estimaterank` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `Rank` (double, 0–3) |
| **Point count** | unchanged |
| **Parity** | ≤4 pt/28K at SVD-rank thresholds (eigensolver noise); analytic line/plane/volume exact — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

`Rank` = SVD rank of the `knn` (query included) neighbourhood covariance:
the singular values of the symmetric PSD matrix are its |eigenvalues|, and
the rank is the count `>= thresh · largest` (Eigen `JacobiSVD::rank`
semantics) — 1 = line, 2 = plane, 3 = volume. Metal: FP32 kernel
(`precision: fp64` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Neighbours per point (query included), in `[2, 65]`. |
| `thresh` | double | `0.01` | Relative singular-value cutoff for counting rank. |

```yaml
  rank:
    type: filter.estimaterank
    input: read
    knn: 8
    thresh: 0.01
```

---

### filter.radialdensity

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborhoodFeatureFilters.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.radialdensity` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `RadialDensity` (double) |
| **Point count** | unchanged |
| **Parity** | ≤4 points/146K at radius-boundary FP32 ties; exact vs a brute-force radius count — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

`RadialDensity` = (number of neighbours within `radius`, the point itself included) / `((4/3)·π·radius³)`, using PDAL's literal `3.14159` rather than `M_PI` so values match. Requires a projected CRS: a geographic (degree) cloud, or a radius larger than the data's XY extent, is refused before any GPU work (`src/filters/RadiusGuard.hpp`). On Metal the count runs in FP32 kernels and is widened into the Float64 dim — same result as the CUDA path since coordinates are FP32-stored on both.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `radius` | double | `1.0` | Search radius in CRS units; must be > 0. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error (FP32-only GPU); the CUDA path does not consult it. |

```yaml
  density:
    type: filter.radialdensity
    input: read
    radius: 2.0
```

---

### filter.nndistance

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborhoodFeatureFilters.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.nndistance` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `NNDistance` (double) |
| **Point count** | unchanged |
| **Parity** | ≤8 points/2.49M at FP32 boundary ties; PDAL's grid unit test reproduces exactly — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Distance statistic over each point's `k` nearest neighbours, the query point excluded (the kNN search fetches `k+1` and drops self, as PDAL's `knnSearch`). `mode: kth` writes the distance to the k-th neighbour; `mode: avg` the mean distance to the k nearest. kNN is units-invariant, so no CRS guard applies. Metal runs the same search in FP32 and widens to Float64.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `mode` | enum(kth\|avg) | `kth` | `kth` = k-th neighbour distance; `avg` (also accepts `average`) = mean over the k nearest. Case-insensitive first letter. |
| `k` | int | `10` | Neighbour count, in `[1, 64]`. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  nnd:
    type: filter.nndistance
    input: read
    mode: avg
    k: 8
```

---

### filter.reciprocity

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborhoodFeatureFilters.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.reciprocity` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `Reciprocity` (double) |
| **Point count** | unchanged |
| **Parity** | ≤29 points/762K at kNN-boundary near-ties; analytic outlier/interior cases exact — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

`Reciprocity` = percentage of a point's `knn` nearest neighbours that do **not** have the point among their own `knn` neighbours (`100 · uni / knn`) — high for points whose neighbourhood relationship is one-directional (outliers, edges). A kNN-of-kNN search, so which point lands exactly k-th matters: near-ties at the kNN boundary are the documented tolerance. PDAL's `threads` option has no effect and is ignored by the converter. Metal: FP32 kernels, widened to Float64.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `knn` | int | `8` | Neighbour count, in `[1, 64]`. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  recip:
    type: filter.reciprocity
    input: read
    knn: 8
```

---

### filter.lof

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/LOFFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.lof` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `NNDistance`, `LocalReachabilityDistance`, `LocalOutlierFactor` (all double) |
| **Point count** | unchanged |
| **Parity** | ≤4 points/2.6M at LOF thresholds (kNN-boundary near-ties); analytic outlier/interior behaviour exact — [Parity.md](Parity.md#eigensolver-and-knn-near-ties) |

Local Outlier Factor (Breunig et al. 2000) as a three-pass GPU algorithm over the `minpts+1` nearest neighbours (query point included, as PDAL's `knnSearch`): (1) `NNDistance` = k-distance; (2) `LocalReachabilityDistance` = 1 / mean reachability distance; (3) `LocalOutlierFactor` = mean neighbour-lrd / own-lrd (≈1 in uniform density, ≫1 for outliers). Running means use the same Welford update as PDAL; neighbour distances are recomputed from coordinates so only indices and k-distances are cached. Metal: FP32 three-pass, widened to Float64.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `minpts` | int | `10` | Neighbourhood size, in `[1, 64]`. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  lof:
    type: filter.lof
    input: read
    minpts: 20
```

---

### filter.neighborclassifier

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/NeighborClassifierFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.neighborclassifier` |
| **Reads** | `X`, `Y`, `Z`, the `dimension` being voted on, any dims named in `domain` |
| **Writes** | `dimension` (default `Classification`) — relabels in place |
| **Point count** | unchanged |
| **Parity** | exact (0/2.6M `Classification` differ — strict majority is robust to kNN-boundary ties) |

kNN majority-vote relabeling of an integer dimension: for each point take its `k` nearest neighbours (self included, as PDAL's `kdi.neighbors(p, k)`), tally the integer values of `dimension` (truncated like PDAL's `getFieldAs<int>`), and if one value holds a strict majority (`> k/2`) and differs from the current value, relabel to it. Vote-count ties break toward the smallest value (PDAL's `max_element` over a key-ordered map). Two-phase like PDAL: all votes read the original values, writes are applied afterwards. `domain` (PDAL DimRange grammar, OR across ranges) restricts which points may be relabeled; everything still votes. The external `candidate`-file mode is **not supported**: setting `candidate` is an error (use `pdal.filter`). Metal: FP32 kNN with integer votes — same result as CUDA.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `k` | int | `10` | Neighbours per vote (self included), in `[1, 64]`. |
| `dimension` | string | `Classification` | Integer-valued dimension to vote on and relabel; must exist on the cloud. |
| `domain` | string | `""` | Optional DimRange list (e.g. `Classification[1:2]`) — only points passing any range are eligible for relabeling. |
| `candidate` | string | `""` | Rejected if set: external candidate file is not supported natively. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  smooth:
    type: filter.neighborclassifier
    input: read
    k: 10
    domain: "Classification[2:6]"
```

---

### filter.fps

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/FarthestPointSamplingFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.fps` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | none |
| **Point count** | reduced (drops points) — set to `count` when the cloud has ≥ `count` points |
| **Parity** | exact set (0 diff on 100K, count 1000); ~2000× faster than PDAL |

Greedy farthest-point sampling, an operation-for-operation port of PDAL's `Segmentation::farthestPointSampling`: seed with point 0, then repeatedly add the point whose distance to the already-selected set is largest, until `count` points are kept. Each iteration's all-points min-distance update and argmax run on the GPU (lowest-index tie-break like PDAL's `std::max_element`). Count semantics follow PDAL: a cloud with **fewer** than `count` points passes through unchanged; otherwise exactly `count` points survive and the rest are dropped via `PointCloud::compact` (dims and raw LAS records together). Metal: FP32 min-distance buffer in unified memory with a host argmax — same selection.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `count` | int | `1000` | Number of points to keep; no-op if the cloud is smaller than this. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  sample:
    type: filter.fps
    input: read
    count: 5000
```

---

### filter.cluster

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/ClusterFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.cluster` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `ClusterID` (double) |
| **Point count** | unchanged |
| **Parity** | partition 99.994% identical (FP32 tolerance-edge connectivity); `ClusterID` integers diverge ~13% by sequential-numbering amplification, labels are relabel-invariant — [Parity.md](Parity.md#tie-breaking-order) |

Euclidean clustering: points within `tolerance` of each other (3D, or 2D XY when `is3d: false`) are connected; computed on the GPU by min-label propagation with path compression over the uniform grid, so each component converges to its minimum point index. Components with size in `[min_points, max_points]` get a `ClusterID` numbered **1-based** by ascending representative index — exactly PDAL's seed-discovery order — and every other point gets `ClusterID = 0`. Requires a projected CRS: a geographic (degree) cloud, or a tolerance larger than the data's XY extent, is refused (`src/filters/RadiusGuard.hpp`). The few points that differ from PDAL sit at FP32 tolerance-edge connectivity; because numbering is sequential, one merged/split component shifts every later ID, hence the large integer divergence that is not a clustering disagreement. Metal: FP32 distance test, identical relabel.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `tolerance` | double | `1.0` | Connection distance in CRS units; must be > 0. |
| `min_points` | int | `1` | Smallest component size that receives a ClusterID. |
| `max_points` | int | *unbounded* | Largest component size that receives a ClusterID; unset = no upper bound. |
| `is3d` | bool | `true` | `true` = 3D Euclidean distance; `false` = 2D (XY only). |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  cluster:
    type: filter.cluster
    input: read
    tolerance: 0.5
    min_points: 20
```

---

### filter.dbscan

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/DBSCANFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.dbscan` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `ClusterID` (double) |
| **Point count** | unchanged |
| **Parity** | identical cluster count; 99.999% noise + 99.988% membership agreement (border points are order-dependent in PDAL; FP32 tolerance-edge) — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

DBSCAN (Ester et al. 1996): a point is *core* if it has at least `min_points` neighbours within `eps` (itself included); core points within `eps` of each other form clusters (GPU min-label propagation over the grid); non-core points within `eps` of a core point are *border* points joined to that cluster (adopting the minimum core-neighbour label); everything else is noise, `ClusterID = -1`. Clusters are numbered **0-based** by ascending core-representative index (PDAL's discovery order). Clustering is 3D on X/Y/Z only — PDAL's `dimensions` option is not supported natively. Requires a projected CRS: a geographic (degree) cloud, or `eps` larger than the data's XY extent, is refused (`src/filters/RadiusGuard.hpp`). Metal: FP32 distance math, integer atomics for labels, same numbering.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `eps` | double | `1.0` | Neighbourhood radius in CRS units; must be > 0. |
| `min_points` | int | `6` | Minimum neighbours (self included) within `eps` for a point to be core. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  dbscan:
    type: filter.dbscan
    input: read
    eps: 1.0
    min_points: 6
```

---

### filter.lloydkmeans

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/LloydKMeansFilter.cpp` (+ `.cu` / `.metal.cpp`) |
| **PDAL equivalent** | `filters.lloydkmeans` |
| **Reads** | `X`, `Y`, `Z` |
| **Writes** | adds `ClusterID` (double) |
| **Point count** | unchanged |
| **Parity** | exact `ClusterID` (0 diff on 100K); ~27× faster |

Lloyd's k-means in 3D (X/Y/Z). Initial centres come from farthest-point sampling — the `filter.fps` logic, deterministic with seed point 0, matching PDAL's `Segmentation::farthestPointSampling` — so the initialization is identical and the result is exact. Then `maxiters` rounds of assign-each-point-to-nearest-centre and recompute-centroid, all on the GPU; `ClusterID` = centre index (0-based). Empty clusters move to the origin, as in PDAL. If the cloud has fewer than `k` points (or `k < 1`) the `ClusterID` dim is added but the stage returns without assigning. PDAL's `dimensions` option is not supported natively. Metal: assignment on the GPU in FP32, centroid sums accumulated on the host in double (no float atomics) — matches the CUDA double accumulation.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `k` | int | `10` | Number of clusters. |
| `maxiters` | int | `10` | Number of Lloyd iterations. |
| `precision` | enum(fp32\|fp64) | `fp32` | Checked only on the Metal backend, where `fp64` is an error; the CUDA path does not consult it. |

```yaml
  kmeans:
    type: filter.lloydkmeans
    input: read
    k: 8
    maxiters: 20
```

---

### filter.ml_noise

| | |
|---|---|
| **Kind** | filter · **GPU** |
| **Source** | `src/filters/MlNoiseFilter.cpp` (+ `.cu` / `.metal.cpp`; model loader `src/filters/MlNoiseModel.cpp`) |
| **PDAL equivalent** | `none` |
| **Reads** | `X`, `Y`, `Z`, `Classification`, `Intensity`, `ReturnNumber`, `NumberOfReturns`, `ScanAngle` (attribute dims are extracted from raw LAS records if the reader did not) |
| **Writes** | `Classification` (sets 7 on predicted noise; nothing else is modified) |
| **Point count** | unchanged |
| **Parity** | no PDAL equivalent; reference is the Python `noise_filter` pipeline — decision mask exact (0/2.6M) with the reference model, features differ on 0.01–1.5% of points below float16 training resolution — [Parity.md](Parity.md#by-design) |

LightGBM noise classifier: computes 48 per-point neighbourhood/tile features on the GPU, walks the tree ensemble, and marks points with `prob >= threshold` as `Classification = 7` (no 7/18 split, prior noise is not reset). The model is **user-supplied** — pcax ships the feature computation and inference kernel, not a trained model. Any LightGBM text model (`Booster.save_model`) whose 48 feature names match the pinned Run-9 contract loads; the names and order are verified at load time and a mismatch is an error (see [MlNoiseFilter.md](MlNoiseFilter.md)). Tile-stateful: features include tile-level normalizations, so run it on a full tile or an AOI of ≳1M points; clouds of ≤32 points error. Metal: all feature math and the tree walk are FP32 (CUDA keeps neighbour/eigen math, thresholds and leaf values in double) and the kNN/eigen step is the unfused two-kernel form — documented FP32 tolerance class.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `model` | string | *required* | Local path or `s3://` URI of a LightGBM text model. S3 models download once (via `aws s3 cp`) to `$XDG_CACHE_HOME/pcax/models/` (default `~/.cache/pcax/models/`), keyed by URI hash, and are reused. |
| `threshold` | double | `0.9336` | Noise-probability cut (`prob >= threshold` → class 7). The default is the reference model's calibrated value; recalibrate for your own model. |
| `debug_features` | string | `""` | If set, writes the raw N × 48 float32 row-major feature matrix to this path for parity work (`np.fromfile(..., dtype=np.float32).reshape(-1, 48)`). |

```yaml
  noise:
    type: filter.ml_noise
    input: read
    model: "s3://my-bucket/models/lgbm_noise.txt"
    threshold: 0.9336
```

## Writers
### write.las

| | |
|---|---|
| **Kind** | writer · **CPU** (threaded LAZ chunk compression) |
| **Source** | `src/writers/LasWriter_lazperf.cpp` (LASLIB build: `src/writers/LasWriter_laslib.cpp`) |
| **PDAL equivalent** | `writers.las` |
| **Reads** | `all` — replays the raw records; `X`, `Y`, `Z` are re-encoded as `minRaw + lround(v / scale)`; `Classification` (and `Overlap` for formats ≤5) rewrite the class byte; `applyAttrDims()` writes back `Intensity`, `ReturnNumber`, `NumberOfReturns`, `GpsTime`, `ScanAngle`, `Synthetic`, `KeyPoint`, `Withheld`, `Overlap`, `Red`, `Green`, `Blue`. Derived dims (`HeightAboveGround`, `NormalX/Y/Z`, `Curvature`, `Eigenvalue0-2`, `ClusterID`, …) are not written |
| **Writes** | `none` (file only) |
| **Point count** | unchanged |
| **Parity** | byte-exact records (`docs/PdalFeatureMatrix.md`) |

Requires a cloud that came from `read.las` (asserts `rawRecordCount() == size()`
and a stored source preamble). Compression is inferred from the extension:
`.laz` → LAZ (laz-perf default chunk size), anything else → uncompressed.
The header is the source header with scale/offset taken from metadata
(reprojection rewrites them), bounds and point counts recomputed. Source VLRs
are replayed minus the `laszip` VLR, the `copc` VLR/EVLR (a plain LAZ has no
octree) and — when `filter.reproject` set a new CRS — the CRS records, which
are replaced by a WKT VLR (2112), the GeoTIFF keys (34735) and global-encoding
bit 4 on LAS 1.4. Formats ≤5: class bits are merged under the flag bits 5–7,
and `Overlap = 1` on a class-0 point is written as class 12 (PDAL convention).
LASLIB variant: sequential LASlib writer, `threads` unread, only the `laszip`
VLR is dropped (the `copc` VLR is kept).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Output path; `.laz` selects LAZ compression. |
| `threads` | int | `0` | Threads for parallel LAZ chunk compression; `0` = hardware concurrency. LAZ output only. |

```yaml
  write:
    type: write.las
    input: read
    filename: "${output}"
```

---

### write.copc

| | |
|---|---|
| **Kind** | writer · **GPU** (CPU fallback: `device: cpu`, Metal, or non-CUDA builds run the host octree/assembly — byte-identical output) |
| **Source** | `src/writers/CopcWriter.cpp` (+ `src/writers/CopcOctree.cu`, `src/writers/CopcGpu.hpp`; host reference `src/core/CopcOctree.cpp`; LASLIB build: `src/writers/CopcWriter_laslib.cpp` stub) |
| **PDAL equivalent** | `writers.copc` |
| **Reads** | `all` — raw records + `X`, `Y`, `Z`, `Classification`, `Overlap` (legacy formats), `GpsTime` (node ordering), the `extra_dims` dims; `applyAttrDims()` writes attribute dims back first |
| **Writes** | `none` (file only; the in-memory cloud is not reordered) |
| **Point count** | unchanged |
| **Parity** | point records byte-exact vs `writers.copc`; octree layout differs by design — [Parity.md](Parity.md#by-design) |

Writes a COPC 1.0 file: LAS 1.4, point format 6–8, one LAZ chunk per octree
node (variable chunk table), COPC info VLR first, a single hierarchy EVLR
page, surviving source VLRs/EVLRs. Legacy formats 0–5 are converted to 6/7
(`include/pca/LasRecordConvert.hpp`). COPC requires a WKT CRS: priority is
the reprojected CRS, the source WKT VLR, converted GeoTIFF keys, then
`a_srs` (warning if none). Requires raw records + source preamble (`read.las`
input), at least one point and fewer than 2^31. Under the LASLIB backend the
stage registers but throws at execute (laz-perf required).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Output path; must end in `.laz`, should end in `.copc.laz` (warning otherwise). |
| `extra_dims` | list | *(none)* | Non-native dims to append as LAS extra bytes (PDAL names, or `all` for every non-native dim present). Native LAS fields are rejected; at most 32. |
| `max_node_points` | int | `100000` | A node with at most this many remaining points becomes a leaf; must be > 0. Also sizes the automatic depth cap. |
| `max_depth` | int | `-1` | Deepest octree level; `-1` = auto (≤ 16, sized from `max_node_points` — see `docs/CopcWriter.md`). |
| `grid_size` | int | `128` | Per-node subsample grid per axis (power of two); COPC `spacing` = 2·halfsize / grid_size. |
| `node_order` | enum(gpstime\|input) | `gpstime` | Point order inside a node; `gpstime` falls back to input order when the cloud has no `GpsTime` dim. |
| `format` | int | auto | Output point format 6, 7 or 8 (auto: 6, or 7 when the source has RGB; a lower value warns that RGB/NIR is dropped). |
| `threads` | int | `0` | Host threads for per-node LAZ compression; `0` = hardware concurrency. |
| `a_srs` | string | *(none)* | CRS (WKT / `EPSG:n` / `EPSG:h+v`) used only when the source carries no CRS. |
| `device` | enum(gpu\|cpu) | `gpu` | `cpu` runs the host octree + record assembly (identical output). Also the executor residency hint. |

```yaml
  copc:
    type: write.copc
    input: read
    filename: "${output}.copc.laz"
    extra_dims: [HeightAboveGround]
```

---

### write.text

| | |
|---|---|
| **Kind** | writer · **CPU** |
| **Source** | `src/writers/TextWriter.cpp` |
| **PDAL equivalent** | `writers.text` |
| **Reads** | `all` present dims (or the `order` subset) through `DimAccessor` — `X`/`Y`/`Z` decode to absolute coordinates bit-identically to the LAS reader |
| **Writes** | `none` (file only) |
| **Point count** | unchanged |
| **Parity** | exact — values bit-exact vs `writers.text` on 2.6M points (`docs/PdalFeatureMatrix.md`) |

One header line of dimension names, then one delimited row per point,
`std::fixed` at the configured precision. Column order is the `order` list
first, then (with `keep_unspecified`) every remaining present dim in `DimId`
order. Only `format: csv` is implemented (PDAL's `geojson` errors).

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Output text path. |
| `format` | enum(csv) | `csv` | Output format; only `csv` is supported. |
| `delimiter` | string | `,` | Field separator. |
| `precision` | int | `3` | Decimal places for every column not given a per-dim precision. |
| `write_header` | bool | `true` | Emit the header line of dimension names. |
| `quote_header` | bool | `true` | Wrap each header name in double quotes. |
| `newline` | string | `\n` | Line terminator (empty falls back to `\n`). |
| `order` | list | *(none)* | Leading columns, comma- or semicolon-separated; `Name:p` sets a per-dim precision. Unknown/missing dims error. |
| `keep_unspecified` | bool | `true` | Append the dims not listed in `order` after it; `false` writes only the `order` columns. |

```yaml
  csv:
    type: write.text
    input: read
    filename: "${output}.csv"
    order: "X:3,Y:3,Z:3,Classification:0"
```

---

### write.ply

| | |
|---|---|
| **Kind** | writer · **CPU** |
| **Source** | `src/writers/PlyWriter.cpp` |
| **PDAL equivalent** | `writers.ply` |
| **Reads** | `all` present dims (or the `dims` subset) through `DimAccessor` |
| **Writes** | `none` (file only) |
| **Point count** | unchanged |
| **Parity** | exact — PDAL reads pcax output exactly (X/Y/Z + Intensity) on 100K points (`docs/PdalFeatureMatrix.md`) |

Writes a single `vertex` element with one property per dimension. `X`/`Y`/`Z`
are emitted as `float64` absolute coordinates; every other dim keeps its
pcax type (`uint8`, `uint16`, `float32`, …). In `ascii` mode float values use
`precision` and integer types print as integers. No faces are written.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Output PLY path. |
| `storage_mode` | enum(ascii\|binary_little_endian) | `ascii` | Body encoding (`default` = ascii; `little`/`binary` = binary_little_endian). |
| `dims` | list | *(all present)* | Dims to write, comma- or semicolon-separated; unknown/missing dims error. |
| `precision` | int | `3` | Decimal places for floating-point values in `ascii` mode. |

```yaml
  ply:
    type: write.ply
    input: read
    filename: "${output}.ply"
    storage_mode: binary_little_endian
```

---

### writer.gdal_gpu

| | |
|---|---|
| **Kind** | writer · **GPU** (CUDA; Metal runs the same FP32 kernels with host-side percentiles) |
| **Source** | `src/writers/GdalGpuWriter.cpp` + `src/writers/GdalGpuWriter.cu` / `src/writers/GdalGpuWriter.metal.cpp` (`src/writers/GdalGpuGridParams.hpp`) |
| **PDAL equivalent** | `writers.gdal` (`spatialreference` → `override_srs`) |
| **Reads** | `X`, `Y`, and the `dimension` dim (`Z` by default) |
| **Writes** | `none` (raster file only) |
| **Point count** | unchanged |
| **Parity** | ~2–20 cells per million differ from `writers.gdal` where a point sits within FP32 quantisation of the radius cutoff or a cell edge — [Parity.md](Parity.md#fp32-relative-coordinate-storage) |

Rasterises one dimension to a north-up GDAL raster, one band per requested
statistic, in the band order `min, max, mean, idw, count, stdev, pNN…`.
**Grid window**: default is the data bbox with `nx = floor(extent/res) + 1`;
`snap: true` rounds the bbox outward onto the resolution lattice (no +1, so
adjacent snapped tiles abut); `origin_x/origin_y/width/height` (all four or
none, not with `snap`) fix the window like PDAL. **Radius mode** (default): a
cell takes every point with distance to the cell centre `< radius`; points
outside the window still feed edge cells (halo binning). IDW weights
`1/d^power`; a point exactly on the centre wins outright. **Bin mode**
(`binmode: true`): only points whose XY fall in the cell; out-of-window points
are dropped; `idw` is the last point's value; percentiles (`pNN`) are
available only here, linearly interpolated at `(NN/100)·(count-1)`. `stdev`
is the population value. Empty cells are `nodata`; `window_size > 0` fills
them on the CPU by inverse Chebyshev-distance weighting of populated cells
within that pixel window. SRS priority: `override_srs`, the cloud's CRS
(reprojected WKT, else source VLR WKT / GeoTIFF keys), `default_srs`; parsed
by `OSRSetFromUserInput` (WKT, `EPSG:n`, `EPSG:h+v`).
TODO(verify): `dimension: Intensity|Classification` are accepted, but the
kernels read the device buffer as float32 while those dims are uint16/uint8
— no conversion was found in the CUDA or Metal paths.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `filename` | string | *required* | Output raster path. |
| `resolution` | double | `1.0` | Cell size in CRS units. |
| `dimension` | enum(X\|Y\|Z\|Intensity\|Classification) | `Z` | Dimension to grid. |
| `output_type` | list | `all` | Comma list of `min`, `max`, `mean`, `stdev`, `count`, `idw`, `all`, `pNN` (NN = 0–100, needs `binmode: true`). `all` = min,max,mean,idw,count,stdev (no percentiles). Unknown tokens error. |
| `binmode` | bool | `false` | `true` = cell-membership statistics (no radius search). |
| `radius` | double | `resolution·√2` | Radius-mode search radius (any negative value = default). Ignored in bin mode. |
| `power` | double | `1.0` | IDW distance exponent. |
| `window_size` | int | `0` | Empty-cell fill window in pixels; `0` disables. |
| `nodata` | double | `NaN` | Value written for empty cells and set as the band NoData. |
| `data_type` | enum(float32\|float64\|int32\|int16\|uint8) | `float32` | Raster data type (GDAL converts from the float32 buffers; unknown strings fall back to float32). |
| `gdaldriver` | string | `GTiff` | GDAL driver name. |
| `gdalopts` | list | *(none)* | GDAL creation options, comma-separated (`COMPRESS=DEFLATE,TILED=YES`). |
| `override_srs` | string | *(none)* | CRS that beats the cloud's own CRS. |
| `default_srs` | string | *(none)* | CRS used only when none can be inferred. |
| `origin_x` | double | *(none)* | Fixed-grid lower-left X (absolute); requires the other three. |
| `origin_y` | double | *(none)* | Fixed-grid lower-left Y (absolute). |
| `width` | int | *(none)* | Fixed-grid columns (> 0). |
| `height` | int | *(none)* | Fixed-grid rows (> 0). |
| `snap` | bool | `false` | Round the data bbox outward onto the resolution lattice; incompatible with a fixed grid. |

```yaml
  dsm:
    type: writer.gdal_gpu
    input: read
    filename: "${output}.tif"
    resolution: 1.0
    output_type: max
    binmode: true
```

## Adapter
### pdal.filter

| | |
|---|---|
| **Kind** | filter · **CPU** (opt-in: built only with `-DPCA_WITH_PDAL=ON` / `PCA_HAVE_PDAL`) |
| **Source** | `src/filters/PdalFilterAdapter.cpp` (+ `include/pca/PdalDimMapping.hpp`) |
| **PDAL equivalent** | any `filters.*` — the one named by `pdal_type` |
| **Reads** | the mapped dims: `X`, `Y`, `Z`, `Classification`, `Intensity`, `ReturnNumber`, `NumberOfReturns`, `GpsTime`, `Red`, `Green`, `Blue` (other pcax dims are not passed to PDAL) |
| **Writes** | the same mapped dims, as the PDAL filter left them (`X`/`Y`/`Z` converted back to relative float32) · adds `Classification` (uint8) if absent · dims PDAL adds (e.g. `HeightAboveGround`) are not carried back |
| **Point count** | set to N (the PDAL output view size; raw records compacted by original index, points PDAL adds get zeroed raw records, an empty result gives 0 points) |
| **Parity** | PDAL's own output by construction, up to the FP32 round-trip of XYZ (`docs/PdalAdapter.md`) |

Copies the cloud into a PDAL `PointView` (XYZ as absolute doubles via
`dataMin`), runs the filter through `pdal::StageFactory`, and copies the
largest result view back, tracking original indices with a hidden
`PcaxOrigIndex` dim. The copy is per-point/per-dim `setField`/`getFieldAs`
and dominates runtime on large clouds; prefer a native `filter.*` where one
exists. `pcax convert --adapter` emits this stage for PDAL filters pcax does
not map.

**Options**

| Option | Type | Default | Description |
|---|---|---|---|
| `pdal_type` | string | *required* | PDAL filter name (`filters.smrf`, `filters.range`, …). Unknown names error. |
| *(any other key)* | string | — | Forwarded verbatim to the PDAL filter as an option. |

```yaml
  classify:
    type: pdal.filter
    input: read
    pdal_type: filters.smrf
    slope: 0.2
```

## Parity on real data

Measured with `compare/filter_parity.py` on a 2.6M-point LAS 1.4 format-6 USGS
tile (`USGS_LPC_CO_EasternColorado_2018_A18_LD32371524.laz`) unless the row
says otherwise; the tolerance classes are explained in [Parity.md](Parity.md).

| Stage | PDAL equivalent | Device | Parity on real data |
|---|---|---|---|
| `filter.range` | `filters.range` | CPU (threaded) | exact (4 cases incl. negation, exclusive/open bounds) |
| `filter.crop` | `filters.crop` | CPU (threaded) | exact (bbox, `outside`, polygon with hole) |
| `filter.dem` | `filters.dem` | CPU (threaded) | exact |
| `filter.assign` | `filters.assign` | CPU | exact (incl. `condition`) |
| `filter.decimation` | `filters.decimation` | CPU | exact (streaming semantics) |
| `filter.head` | `filters.head` | CPU | exact (PDAL test ported; invert) |
| `filter.tail` | `filters.tail` | CPU | exact (PDAL test ported; invert) |
| `filter.gpstimeconvert` | `filters.gpstimeconvert` | CPU | exact (gt/gst/gws/gds; 4 conversions bit-exact on real tile) |
| `filter.iqr` | `filters.iqr` | CPU | exact (Z & Intensity on real tile) |
| `filter.mad` | `filters.mad` | CPU | exact (Z on real tile) |
| `filter.skewnessbalancing` | `filters.skewnessbalancing` | CPU | ground **count exact** (2553120/2.6M); ~1.1% boundary membership differs (Z-tie ordering — see below) |
| `filter.sparsesurface` | `filters.sparsesurface` | CPU | ground/noise counts within 39/2.6M; 99.5% labels exact (Z-tie greedy order); ~3.9× faster |
| `filter.sort` | `filters.sort` | CPU | output sorted by dim(s) (ASC/DESC, NORMAL/STABLE); verified monotonic + dim-aligned |
| `filter.mortonorder` | `filters.mortonorder` | CPU | **bit-exact order** vs PDAL (2.6M points, default Z-order) |
| `filter.transformation` | `filters.transformation` | CPU (threaded) | exact at 1e-7 (fp32 storage) |
| `filter.stats` | `filters.stats` | CPU | exact |
| `filter.elm` | `filters.elm` | CPU | exact (2 configs) |
| `filter.voxeldownsize` | `filters.voxeldownsize` | CPU | exact (first + center modes) |
| `filter.voxelcenternearestneighbor` | `filters.voxelcenternearestneighbor` | CPU | exact (point set; output keeps input order) |
| `filter.voxelcentroidnearestneighbor` | `filters.voxelcentroidnearestneighbor` | CPU | count exact; 8/1.62M kept-set diff (FP32 voxel-boundary near-ties) |
| `filter.sample` | `filters.sample` | CPU | exact (count + stats, 2 radii); **~1.6× faster** than PDAL |
| `filter.fps` | `filters.fps` | **GPU** | **exact set** (0 diff on 100K, count 1000); **~2000× faster** than PDAL |
| `filter.cluster` | `filters.cluster` | **GPU** | partition 99.994% identical (FP32 tolerance-edge); ~3× faster. ClusterID *numbers* diverge (sequential-numbering amplification) — see below |
| `filter.dbscan` | `filters.dbscan` | **GPU** | identical cluster count; 99.999% noise + 99.988% membership agreement; **~10× faster** |
| `filter.lloydkmeans` | `filters.lloydkmeans` | **GPU** | **exact ClusterID** (0 diff on 100K); ~27× faster (full tile: PDAL >19 min vs seconds) |
| `filter.hag_nn` | `filters.hag_nn` | **GPU** | exact (via downstream range on HAG) |
| `filter.hag_dem` | `filters.hag_dem` | CPU (threaded) | exact |
| `filter.normal` | `filters.normal` | **GPU** | distributions ≤1e-6; threshold-count exact in test case |
| `filter.eigenvalues` | `filters.eigenvalues` | **GPU** | 1 point / 2.28M at threshold (eigensolver noise) |
| `filter.covariancefeatures` | `filters.covariancefeatures` | **GPU** | ≤~13 points/2.6M at feature thresholds (eigensolver/eigenvector noise); analytic values exact (PDAL unit test ported) |
| `filter.optimalneighborhood` | `filters.optimalneighborhood` | **GPU** | OptimalRadius exact (~1 pt/2.6M); OptimalKNN argmin ≤~31 pt/544K at entropy near-ties |
| `filter.approximatecoplanar` | `filters.approximatecoplanar` | **GPU** | 3 points/1.87M at the eigenvalue-ratio thresholds (eigensolver noise); analytic cases exact |
| `filter.planefit` | `filters.planefit` | **GPU** | ≤6 points/2.12M at thresholds (eigensolver noise); PDAL unit test ported exact |
| `filter.estimaterank` | `filters.estimaterank` | **GPU** | ≤4 points/28K at SVD-rank thresholds (eigensolver noise); analytic line/plane/volume exact |
| `filter.radialdensity` | `filters.radialdensity` | **GPU** | ≤4 points/146K at radius-boundary FP32 ties; exact vs brute-force count |
| `filter.nndistance` | `filters.nndistance` | **GPU** | ≤8 points/2.49M at thresholds; PDAL grid test ported exact |
| `filter.reciprocity` | `filters.reciprocity` | **GPU** | ≤29 points/762K at kNN-boundary near-ties; analytic outlier/interior exact |
| `filter.lof` | `filters.lof` | **GPU** | ≤4 points/2.6M at LOF thresholds (kNN-boundary near-ties); analytic outlier/interior behavior exact |
| `filter.neighborclassifier` | `filters.neighborclassifier` | **GPU** | **exact** (0/2.6M Classification differ — strict majority is robust to kNN-boundary ties) |
| `filter.smrf` | `filters.smrf` | CPU | ≥99.99% label agreement (see below) |

`filter.ml_noise` (GPU LightGBM noise classifier with a
user-supplied model) has no PDAL equivalent and is documented in
[MlNoiseFilter.md](MlNoiseFilter.md); its parity reference is the Python
`noise_filter` pipeline, not PDAL (validated 0 decision disagreements on
a 2.6M-point USGS Colorado tile with the reference model).

CPU filters parallelize over point chunks with the internal thread pool.
Predicate-style filters (range/crop/dem) are deliberately CPU: they are
memory-bound single passes, and a GPU version would force uploading every
dimension for no compute win. The neighborhood filters (hag_nn, normal,
eigenvalues, covariancefeatures) run on the GPU via the shared uniform-grid
spatial index (`src/filters/SpatialGrid.cuh`), the same index used by the
SOR filter. They share one device-side kNN + covariance + Jacobi
eigensolver implementation (`src/filters/NeighborhoodMath.cuh`), so their
eigenvalues track PDAL's `math::computeCovariance` + `SelfAdjointEigenSolver`
to eigensolver noise.

## Running the parity harness

```bash
# needs the `pdal` CLI on PATH
python3 compare/filter_parity.py \
  --input USGS_LPC_CO_EasternColorado_2018_A18_LD32371524.laz \
  --name range_cls \
  --pdal-filter '{"type":"filters.range","limits":"Classification![7:7]"}' \
  --pcax-stage  'type: filter.range\nlimits: "Classification![7:7]"'
```

Chain multiple `--pdal-filter`/`--pcax-stage` pairs to test stages whose
outputs are non-LAS dimensions (e.g. hag_nn followed by a range on
HeightAboveGround).
