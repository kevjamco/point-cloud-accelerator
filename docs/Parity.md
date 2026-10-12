# PDAL parity — what "matches PDAL" means in pcax

Every pcax stage with a PDAL counterpart is specified from PDAL's source
(not its documentation — the quirks matter) and verified against PDAL's
output on real USGS lidar with the comparator in [`compare/`](../compare/README.md).
The `parity` test tier (`ctest -L parity`, needs the `pdal` CLI on PATH)
re-runs the per-stage comparison on the committed fixture and encodes the
tolerances below as `PARITY_SLACK` in `tests/integration/test_pdal_parity.py`.
[`docs/PdalFeatureMatrix.md`](PdalFeatureMatrix.md) lists every stage with its
measured status; [`docs/Filters.md`](Filters.md) has per-filter semantics.

Most stages are **exact**: identical point sets and bit-identical dimension
statistics (`filter.range`, `crop`, `dem`, `assign`, `decimation`,
`transformation`, `stats`, `elm`, `voxeldownsize`, `hag_nn`, `hag_dem`,
`neighborclassifier`, `iqr`, `mad`, `gpstimeconvert`, `sort`, `mortonorder`,
`head`/`tail`, `fps`, `sample`, `sparsesurface`, text/PLY I/O; `write.copc`
records are byte-exact). The rest carry one of the documented tolerance
classes below. None of them is a bug; each has a root cause.

## Tolerance classes

### FP32 relative-coordinate storage

pcax stores coordinates as relative FP32 (`(raw - minRaw) * scale`), which
quantises positions to ~0.1–0.5 mm over a 4 km tile. Any predicate that
compares a point against a geometric threshold can flip when the point sits
within that quantum of the boundary:

- **writer.gdal_gpu rasters**: ~2–20 cells per million differ from
  `writers.gdal` where a point lies within FP32 quantisation of the radius
  cutoff or a cell edge — membership flips and the cell extreme swings by
  local relief. Root-caused with a worked example (16 µm margin).
- **SOR threshold ties and crop edges after reprojection**: points within
  ~µm of the outlier threshold or a crop edge flip either way (~1 point per
  1.5 M on the integration fixture).
- **COPC bounds queries**: a query edge coinciding with an octree node
  boundary within ~1e-5 m on a 200 m tile could flip a boundary point.
  On the fixtures, `readers.copc` returns identical point sets from the pcax
  and PDAL files.
- **Bounds at read** (`read.las` / `read.copc` `bounds`): exact. The test
  runs on absolute coordinates decoded from the int32 records, as
  `filter.crop` does before any reprojection, so the result is the same
  records in the same order as a full read plus `filter.crop`; PDAL's
  `readers.copc` returns the identical point set for the same window.
- **crop polygons with `a_srs`**: when PDAL reprojects the polygon, PROJ
  jitters vertices by ~1e-9 and exactly-on-edge points flip either way.

### Eigensolver and kNN near-ties

The GPU neighborhood filters share one device kNN + covariance + Jacobi
eigensolver (`src/filters/NeighborhoodMath.cuh`); PDAL uses Eigen's QL solver.
Distributions agree to ~1e-6, but points whose feature value sits at a
threshold can flip:

- **normal / eigenvalues / covariancefeatures**: occasional single-point
  flips; eigenvector-direction features (Verticality, DemantkeVerticality)
  are most sensitive when eigenvalues are near-degenerate.
  covariancefeatures threshold counts within ≤~13 points per 2.6 M; PDAL's
  own analytic unit test (line / square / tilted quad) reproduces exactly.
- **optimalneighborhood**: OptimalRadius near-exact (~1 pt / 2.6 M);
  OptimalKNN is an argmin over k, so adjacent-k near-ties flip ≤~31 pt / 544 K.
- **planefit ≤6 pt / 2.12 M, estimaterank ≤4 pt / 28 K** at eigensolver
  thresholds; **radialdensity ≤4 pt / 146 K, nndistance ≤8 pt / 2.49 M** at
  radius / FP32 boundary ties. PDAL's planefit and nndistance unit tests
  reproduce exactly; radialdensity is exact vs a brute-force radius count.
- **reciprocity ≤29 pt / 762 K, lof ≤4 pt / 2.6 M**: outputs depend on which
  point is the k-th neighbor, so kNN-boundary near-ties propagate.

### Tie-breaking order

- **SMRF**: ≤0.01% label disagreement, confined to void raster cells where
  8-NN inpainting has distance ties (PDAL breaks them by nanoflann traversal
  order). Shrinks to ~0 at larger cell sizes.
- **skewnessbalancing**: ground/non-ground *count* matches exactly, but LAS
  Z is quantised so the Z-sort has large equal-Z blocks straddling the cut;
  PDAL's `std::sort` is unstable, pcax ties by point index. ~1.1% boundary
  membership can differ.
- **cluster**: the connected-components partition is 99.994% identical
  (30 / 479 K points differ at FP32 tolerance-edge connectivity). ClusterID
  integers diverge ~13% because PDAL's sequential discovery-order numbering
  amplifies the few partition differences — labels are arbitrary and
  relabel-invariant, so this is not a clustering disagreement.

### By design

- **write.copc vs writers.copc**: point records are byte-exact (no
  tolerance); the octree layout differs on purpose (pcax anchors the cube at
  the header minimum and subsamples first-point-per-voxel; PDAL/untwine
  centres the cube and keeps a denser root).
- **filter.ml_noise**: has no PDAL equivalent. Its reference is the Python
  pipeline the model was trained with. Eigenfeatures and kNN-boundary stats
  (dz_knn16, dz_min/max32, below_frac32) differ on 0.01–1.5% of points —
  below the float16 resolution the model was trained at — and the decision
  mask was exact (0 / 2.6 M) with the reference model.
- **LAZ files without a usable chunk table** (writer interrupted, file cut
  short, corrupt table): PDAL (laz-perf) refuses them; `read.las` rebuilds
  the chunk layout from the point data as LASzip does and reads every
  complete chunk, logging the recovered count against the header's. On such
  a file the point set is what LAStools reads, not what PDAL reads.
- **GeoTIFF vertical datum codes** (`VerticalCSTypeGeoKey` 5101–5106) resolve
  to the vertical CRS for the datum and unit key, as GDAL's GeoTIFF reader
  and so PDAL resolve them (5103 + metre → EPSG:5703). Same CRS, no
  tolerance.

## Measuring it yourself

```bash
# one stage, any options, on your own tile
python3 compare/filter_parity.py --input tile.laz --name case \
  --pdal-filter '{"type":"filters.outlier","mean_k":8,"multiplier":2.0}' \
  --pcax-stage  'type: filter.outlier\nk: 8\nmultiplier: 2.0'

# full pipeline, with timings and resource use
python3 compare/pdal_compare.py --input tile.laz

# the committed fixture, as CI would
ctest --test-dir build -L parity --output-on-failure
```

Adding a stage follows the same discipline: pin PDAL's semantics from source,
port, run `filter_parity.py` on a real tile, and record any residual
difference here with its root cause before calling the port done.
