# pdal.filter — PDAL Filter Adapter

Bridge stage that wraps any PDAL filter for use in a pcax pipeline.

## Build

Requires the `PCA_WITH_PDAL` CMake option:

```bash
cmake -B build -DPCA_WITH_PDAL=ON
```

This links against the system `pdalcpp` library and defines `PCA_HAVE_PDAL=1`.

## YAML Usage

```yaml
stages:
  classify:
    type: pdal.filter
    input: read
    pdal_type: filters.smrf    # any PDAL filter name
    slope: 0.2                 # all other keys forwarded to PDAL
    window: 16
    threshold: 0.45
```

- `pdal_type` (required): the PDAL filter to invoke (e.g. `filters.smrf`, `filters.range`, `filters.elm`).
- All other keys are forwarded as PDAL options verbatim.

### Example: Remove noise-labeled points

```yaml
remove_noise:
  type: pdal.filter
  input: read
  pdal_type: filters.range
  limits: "Classification![7:7]"
```

### Example: SMRF ground classification

```yaml
classify:
  type: pdal.filter
  input: read
  pdal_type: filters.smrf
  slope: 0.2
  window: 16
  threshold: 0.45
```

## How It Works

1. Registers all pcax dimensions into a PDAL `PointTable`. XYZ are registered as `Double` (PDAL's native type); others match their pcax types.
2. Copies pcax SoA arrays into a PDAL `PointView` (AoS), converting XYZ from relative float32 to absolute double using `LasMetadata::dataMin{X,Y,Z}`.
3. A hidden `PcaxOrigIndex` dimension tracks each point's original index.
4. Creates the PDAL filter via `pdal::StageFactory`, forwards options, and executes.
5. Uses `PcaxOrigIndex` to compact raw records when points are removed.
6. Copies results back from the PDAL `PointView` into pcax SoA arrays, converting XYZ back to relative float32.

## Dimension Mapping

All 11 pcax dimensions have 1:1 PDAL equivalents:

| pcax | PDAL |
|---|---|
| X, Y, Z | X, Y, Z |
| Classification | Classification |
| Intensity | Intensity |
| ReturnNumber | ReturnNumber |
| NumberOfReturns | NumberOfReturns |
| GpsTime | GpsTime |
| Red, Green, Blue | Red, Green, Blue |

Dimensions that PDAL adds (e.g. `HeightAboveGround`) are not carried back into pcax.

## Performance Constraints

The adapter performs a full copy between pcax's SoA storage and PDAL's AoS `PointView`. This is a per-point, per-dimension operation using PDAL's `setField`/`getFieldAs` API, which involves type dispatch on every call.

**Measured overhead** (87M points, 5 active dims, AMD Ryzen 9 5950X):

| Phase | Time |
|---|---|
| Read (lazperf, 16 threads) | 10.8s |
| **PDAL adapter (filters.range)** | **95.3s** |
| Write (lazperf) | 5.3s |

The adapter stage dominates at ~90% of total pipeline time. The actual filter execution (range predicate evaluation) is ~5s; the remaining ~90s is SoA-to-AoS and AoS-to-SoA conversion overhead. Peak RAM roughly doubles since both the pcax cloud and the PDAL PointView are held simultaneously.

For small-to-medium point clouds (under ~10M points), this overhead is minor. For large clouds, consider native pcax filter implementations where available (e.g. `filter.outlier` for SOR).

## Edge Cases

| Situation | Behavior |
|---|---|
| PDAL returns empty result | Cloud resized to 0, warning logged |
| PDAL returns multiple PointViews | Largest view used, warning logged |
| PDAL adds new points | New points get zeroed raw records, warning logged |
| PDAL modifies XYZ | Converted back to relative float32 (precision loss possible) |
| Cloud has no raw records | Raw record compaction skipped |
| Unknown PDAL dimension in result | Silently discarded |
| Missing `pdal_type` | Throws `std::runtime_error` |
| Invalid PDAL filter name | Throws `std::runtime_error` |

## Files

| File | Role |
|---|---|
| `include/pca/PdalDimMapping.hpp` | Dimension and type mapping functions |
| `src/filters/PdalFilterAdapter.cpp` | Adapter implementation |
| `tests/test_pdal_adapter.cpp` | Unit tests (9 cases) |
| `pipelines/ground_classify.yaml` | Example SMRF pipeline |
| `pipelines/noise_removal.yaml` | Example noise removal pipeline |
