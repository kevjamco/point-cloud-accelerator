// Copyright (c) 2026 Advanced Algorithms LLC
// SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
// filter.ml_noise GPU memory architecture — explanatory document.
// Compile: typst compile docs/MlNoiseGpuMemory.typ

#set document(
  title: "filter.ml_noise: GPU Memory Architecture and the Whole-Tile OOM",
  author: "pcax",
)
#set page(
  paper: "a4",
  margin: (x: 2.1cm, top: 2.2cm, bottom: 2.0cm),
  numbering: "1 / 1",
  header: context {
    if counter(page).get().first() > 1 [
      #set text(8pt, fill: luma(110))
      pcax · filter.ml_noise GPU memory architecture
      #h(1fr)
      docs/MlNoiseGpuMemory.typ
      #v(-0.6em)
      #line(length: 100%, stroke: 0.4pt + luma(200))
    ]
  },
)
#set text(
  font: ("New Computer Modern", "Latin Modern Roman", "DejaVu Serif", "Liberation Serif"),
  size: 10pt,
  lang: "en",
)
#set par(justify: true, leading: 0.62em, spacing: 0.9em)
#set heading(numbering: "1.1")
#show heading: set block(above: 1.4em, below: 0.75em)
#show heading.where(level: 1): it => {
  block(width: 100%)[
    #set text(15pt, weight: 700)
    #it
    #v(-0.55em)
    #line(length: 100%, stroke: 1pt + rgb("#1f4e79"))
  ]
}
#show heading.where(level: 2): set text(12pt, weight: 700, fill: rgb("#1f4e79"))
#show heading.where(level: 3): set text(10.5pt, weight: 700)
#show raw: set text(font: ("DejaVu Sans Mono", "Liberation Mono", "Menlo"), size: 8.4pt)
#show raw.where(block: true): it => block(
  width: 100%, fill: luma(248), stroke: 0.5pt + luma(215),
  inset: 8pt, radius: 3pt, it,
)
#show link: set text(fill: rgb("#1f4e79"))
#set table(stroke: 0.4pt + luma(190), inset: 5pt)
#show figure.caption: set text(8.6pt, fill: luma(80))
#show table: set par(justify: false)
#show figure: set block(breakable: true)

// ---- palette ---------------------------------------------------------------
#let cFeat  = rgb("#c0392b")   // d_feats        (whole-stage)
#let cKnn   = rgb("#e67e22")   // d_knnIdx       (the offender)
#let cGrid  = rgb("#2980b9")   // spatial grid
#let cDim   = rgb("#7f8c8d")   // uploaded dims
#let cScr   = rgb("#27ae60")   // scratch columns
#let cMod   = rgb("#8e44ad")   // model
#let cBg    = luma(245)

// ---- helpers ---------------------------------------------------------------
#let chip(body, fill: cBg, stroke: luma(150)) = box(
  fill: fill, stroke: 0.6pt + stroke, inset: (x: 6pt, y: 4pt),
  radius: 3pt, baseline: 25%,
)[#set text(8.5pt); #body]

#let nb(body) = box(
  fill: luma(250), stroke: (left: 2.5pt + rgb("#1f4e79")),
  inset: (x: 9pt, y: 7pt), width: 100%,
)[#body]

#let warn(body) = box(
  fill: rgb("#fdf3f2"), stroke: (left: 2.5pt + cFeat),
  inset: (x: 9pt, y: 7pt), width: 100%,
)[#body]

#let bar(v, vmax, color) = box(width: 100%, height: 11pt)[
  #place(left + horizon, rect(
    width: 100% * calc.min(v / vmax, 1.0), height: 11pt,
    fill: color, radius: 1.5pt, stroke: none,
  ))
]

#let dbox(body, fill: cBg, w: auto, stroke: luma(140)) = box(
  fill: fill, stroke: 0.7pt + stroke, inset: (x: 7pt, y: 6pt),
  radius: 3pt, width: w,
)[#set text(8.6pt); #set align(center); #body]

#let down = align(center)[#text(13pt, fill: luma(110))[$arrow.b$]]

// ============================================================================
#align(center)[
  #v(1.2cm)
  #text(21pt, weight: 700)[filter.ml_noise on the GPU]
  #v(0.25em)
  #text(14pt, fill: luma(90))[Data structures, algorithm, and the whole-tile\
  out-of-memory failure — diagnosis, fix, and measured result]
  #v(0.9em)
  #text(9.5pt, fill: luma(110))[
    pcax · #datetime.today().display("[year]-[month]-[day]") ·
    `src/filters/MlNoiseFilter.cu`
  ]
]
#v(0.8cm)

#nb[
  *What this document is.* On 2026-08-21 the `accuracy` test tier failed on all
  three Santa Clara tiles with `CUDA error: out of memory at
  src/filters/MlNoiseFilter.cu:689`. The immediate cause was memory
  contention — another process held 3.2 GiB of the card. The interesting
  cause is that `filter.ml_noise` needs *8.3 GiB* to classify a 23.6-million
  point tile on an 11 GiB card, and that number is a consequence of how the
  stage is structured, not of how big the tile is. This document builds up
  from the storage primitives to the algorithm to the memory profile, then
  proposes a fix and states honestly what the fix does and does not buy.
]

#v(0.6em)
#block(
  fill: rgb("#eef7ef"), stroke: (left: 2.5pt + rgb("#27ae60")),
  inset: (x: 9pt, y: 8pt), width: 100%,
)[
  *Status — RESOLVED 2026-08-21.* The fix described in @sec-fuse (fusing the
  kNN search and the eigenfeatures into one kernel, so the $N times 32$
  neighbour-index matrix is never materialised) is *implemented and merged*.
  Measured on the three Santa Clara tiles: peak device memory *8316 → 5436 MB*,
  *7806 → 5110 MB* and *8214 → 5374 MB* — 352 B/point down to 231 B/point, a
  34.6% reduction. The $N times 48$ feature matrix is byte-identical before and
  after (same md5), all 37 `ctest` tests pass, and the `accuracy` tier now
  passes *with* the 3.26 GiB co-tenant that caused the original failure still
  resident. Runtime change: ≈1%, inside the noise.

  Query-set chunking (@sec-chunk) was analysed here and is *not* implemented —
  fusion made it unnecessary. It remains the right tool if a future stage has a
  large scratch buffer that genuinely cannot be fused away.

  The analysis below is preserved as written, because the reasoning is the
  reusable part. Numbers describing the *pre-fix* stage are labelled as such.
]

#v(0.5em)
#outline(depth: 2, indent: 1.2em)
#pagebreak()

= Scope and summary

The `filter.ml_noise` stage classifies lidar noise points using a LightGBM
gradient-boosted tree ensemble (the "Run 9" model) over 48 hand-engineered
per-point features. Everything except model loading runs on the GPU.

The stage is written as a *whole-tile, fully-materialised dataflow*: every
intermediate is a dense column with one entry per point, allocated for all
$N$ points at once, and nothing is tiled, streamed, or spilled. Peak device
memory is therefore an affine function of $N$ with a large constant:

$ M_"peak" (N) approx 377 "bytes/point" times N + O(1) $

At $N = 23.6 times 10^6$ that is 8.3 GiB. The peak is reached at one specific
moment — when the $N times 48$ *feature matrix* (which must live for the
entire stage, because two of the feature groups are global order statistics
over the whole tile) is simultaneously resident with the $N times 32$ *k-nearest-neighbour
index matrix* (which is pure scratch, consumed by the very next kernel, and
needs no such lifetime).

The proposed fix is to slice the *query set* of the kNN/eigen phase rather
than the data: keep the spatial index over all $N$ points, but allocate the
neighbour-index scratch for a chunk of $C$ query points and loop. This is
bit-for-bit output-preserving, costs essentially nothing in runtime, and
moves the binding constraint from 377 B/point to 265 B/point — from a
30.5-million-point ceiling on an 11 GiB card to 43.4 million.

#pagebreak()

= Primitives

Before the memory analysis can mean anything, four pcax primitives need to be
on the table: how a point cloud is stored, how coordinates are encoded, how
data moves between host and device, and what a spatial index is.

== The point cloud is a struct of arrays

pcax does not store points. It stores *dimensions*.

A `DimArray` (`include/pca/DimArray.hpp`) is a typed, move-only, flat buffer:
a void pointer, an element count, and a `DimType` tag (`UInt8`, `UInt16`,
`Float32`, `Float64`, …). It knows nothing about points; it is one column.

A `PointCloud` (`include/pca/PointCloud.hpp`) is a `std::map<DimId, DimArray>`
plus a point count, plus `LasMetadata`, plus the original raw LAS point
records for writer passthrough. `DimId` is an enum of every dimension pcax
understands — the LAS-native ones (`X`, `Y`, `Z`, `Classification`,
`Intensity`, `ReturnNumber`, `NumberOfReturns`, `GpsTime`, `ScanAngle`, RGB,
the classification flag bits) and the derived, in-pipeline-only ones
(`HeightAboveGround`, `NormalX/Y/Z`, `Curvature`, `Eigenvalue0..2`,
`ClusterID`, and so on).

#figure(
  caption: [Structure-of-arrays layout. Point $i$ is a *coordinate* into 13
  independent columns, not an object. A GPU kernel that needs only $X$, $Y$,
  $Z$ touches three contiguous streams and reads nothing else.],
  kind: image,
  supplement: [Figure],
)[
  #box(width: 100%, inset: (y: 4pt))[
    #grid(
      columns: (auto, 1fr),
      column-gutter: 8pt,
      row-gutter: 3pt,
      align: (right + horizon, left + horizon),

      text(8.5pt)[`X` #h(3pt) `f32`],
      grid(columns: 8, gutter: 2pt, ..range(8).map(i =>
        rect(width: 100%, height: 13pt, fill: cGrid.lighten(72%),
             stroke: 0.4pt + cGrid.lighten(35%), radius: 1.5pt))),

      text(8.5pt)[`Y` #h(3pt) `f32`],
      grid(columns: 8, gutter: 2pt, ..range(8).map(i =>
        rect(width: 100%, height: 13pt, fill: cGrid.lighten(72%),
             stroke: 0.4pt + cGrid.lighten(35%), radius: 1.5pt))),

      text(8.5pt)[`Z` #h(3pt) `f32`],
      grid(columns: 8, gutter: 2pt, ..range(8).map(i =>
        rect(width: 100%, height: 13pt, fill: cGrid.lighten(72%),
             stroke: 0.4pt + cGrid.lighten(35%), radius: 1.5pt))),

      text(8.5pt)[`Intensity` #h(3pt) `u16`],
      grid(columns: 8, gutter: 2pt, ..range(8).map(i =>
        rect(width: 100%, height: 13pt, fill: cScr.lighten(75%),
             stroke: 0.4pt + cScr.lighten(35%), radius: 1.5pt))),

      text(8.5pt)[`GpsTime` #h(3pt) `f64`],
      grid(columns: 8, gutter: 2pt, ..range(8).map(i =>
        rect(width: 100%, height: 13pt, fill: cDim.lighten(72%),
             stroke: 0.4pt + cDim.lighten(30%), radius: 1.5pt))),

      text(8.5pt)[…],
      text(8.5pt, fill: luma(120))[8 more columns for a format-6 tile],
    )
  ]
]

Two consequences matter later:

+ *Adding a column costs $N times "sizeof"("type")$ bytes, always.* There is no
  sparse or optional storage. A dimension either exists for every point or
  not at all.
+ *`DimArray` is move-only*, so a `PointCloud` is held by `unique_ptr` inside
  containers, and dimension buffers are never silently copied.

== Coordinates: relative FP32 over an FP64 origin

LAS stores $X$/$Y$/$Z$ as *scaled integers*: a signed `int32` raw value, plus a
per-file `scale` and `offset`, with $"absolute" = "raw" times "scale" + "offset"$.
State-plane and UTM coordinates are large (the Santa Clara tiles start at
$6.2725 times 10^6$ ftUS easting), so storing absolute coordinates in FP32
would leave roughly 0.5 m of representable resolution — useless.

pcax therefore stores *relative FP32*: the reader finds the minimum raw value
per axis and every dimension array holds

$ x_i^"rel" = ("raw"_i - "minRaw") times "scale" $

with `LasMetadata` carrying `scale`, `offset`, `minRaw`, and `dataMin` (the
absolute FP64 position of that minimum). Over a 762 m tile the stored values
span $[0, 762]$, where FP32 has $approx 6 times 10^(-5)$ m of resolution.

#figure(
  caption: [Coordinate encoding. The FP64 origin lives once in the metadata;
  the $N$-sized array holds only the small relative offset. Writers rebuild the
  exact `int32` on output, so a round-trip is lossless.],
  kind: image, supplement: [Figure],
)[
  #box(width: 100%)[
    #grid(columns: (1fr, auto, 1fr, auto, 1fr), column-gutter: 7pt,
      align: horizon + center,
      dbox(fill: cDim.lighten(80%))[
        *LAS record* \ `int32 raw` \ #text(7.5pt, fill: luma(90))[6 272 500 000]
      ],
      text(13pt, fill: luma(120))[$arrow.r$],
      dbox(fill: cGrid.lighten(80%))[
        *metadata (FP64, $O(1)$)* \ `scale, offset` \ `minRaw, dataMin`
      ],
      text(13pt, fill: luma(120))[$arrow.r$],
      dbox(fill: cFeat.lighten(82%))[
        *`DimArray` (FP32, $O(N)$)* \ `(raw - minRaw) * scale` \
        #text(7.5pt, fill: luma(90))[$0.0 dots 762.0$]
      ],
    )
  ]
]

This is why the documented parity tolerances read the way they do: FP32
relative storage quantises to roughly 0.1–0.5 mm over a multi-kilometre tile,
which is enough to flip a point across a threshold or a cell edge. It is also
why `ml_noise` does its *arithmetic* in `double` on FP32 inputs — the storage
is FP32, the math is not.

== Residency: every column has a host copy and possibly a device copy

`PointCloud` tracks a `Residency` per dimension — `Host`, `Device`, or `Both` —
alongside a device pointer map. `ensureDevice(id)` uploads if the column is
host-only; `ensureHost(id)` downloads if it is device-only.

The pipeline executor (`src/core/Pipeline.cpp:207`, `ensureResidency`) applies
a blunt policy before every stage:

```cpp
bool needGpu = (node.device == ExecutionTarget::GPU) ||
               (node.stage->executionTarget() == ExecutionTarget::GPU);
if (needGpu) {
    for (auto& [id, arr] : cloud.dims())
        cloud.ensureDevice(id);          // ALL dimensions, unconditionally
} else {
    for (auto& [id, arr] : cloud.dims())
        if (cloud.residency(id) == Residency::Device)
            cloud.ensureHost(id);
}
```

#warn[
  *This is the first hidden cost.* The executor has no idea which dimensions a
  GPU stage actually reads, so it uploads all of them. For a format-6 tile the
  reader extracts 13 columns totalling 33 B/point; `ml_noise` reads 8 of them,
  totalling 21 B/point. The other 12 B/point — `GpsTime` (8 B) and the four
  classification flag bits (4 B) — are uploaded, occupy 270 MiB, and are never
  touched.
]

== The uniform spatial grid

Nearest-neighbour queries need a spatial index. pcax uses one shared structure
for all neighbourhood filters: a *2-D uniform grid* over $X$/$Y$
(`src/filters/SpatialGrid.cuh`).

Construction is four steps: compute each point's cell id, radix-sort
(cell id, point index) pairs by cell, scan the sorted cell ids for run
boundaries to fill `cellStart`/`cellEnd`, and keep `sortedIndices`. Cell size
is derived from density, $"cellSize" = 4 sqrt("area" \/ N)$, so a cell holds
$approx 16$ points on average.

#figure(
  caption: [Expanding-ring kNN. After finishing the ring at Chebyshev distance
  $d$, every unvisited point lies in a cell at distance $> d$ and so is no
  closer than $d dot "cellSize"$ in XY. The search stops as soon as the current
  32#super[nd] best distance is within that bound — which makes it *exact*, not
  approximate.],
  kind: image, supplement: [Figure],
)[
  #let cell(r) = rect(width: 20pt, height: 20pt, radius: 1.5pt,
    stroke: 0.4pt + luma(170),
    fill: if r == 0 { cFeat.lighten(60%) }
          else if r == 1 { cKnn.lighten(65%) }
          else if r == 2 { cGrid.lighten(70%) }
          else { luma(252) })
  #box[
    #grid(columns: 7, gutter: 2pt,
      ..range(49).map(i => {
        let x = calc.rem(i, 7) - 3
        let y = calc.quo(i, 7) - 3
        cell(calc.max(calc.abs(x), calc.abs(y)))
      })
    )
  ]
  #h(18pt)
  #box(width: 46%, baseline: -26pt)[
    #set text(8.6pt)
    #chip(fill: cFeat.lighten(60%))[ring 0] query cell \
    #v(3pt)
    #chip(fill: cKnn.lighten(65%))[ring 1] 8 cells, all within $1 dot c$ \
    #v(3pt)
    #chip(fill: cGrid.lighten(70%))[ring 2] 16 cells, bound $2 dot c$ \
    #v(5pt)
    #text(fill: luma(90))[
      Stop when $sqrt(d^2_(32)) <= d dot c$. \
      Typically 2–3 rings at 16 pts/cell.
    ]
  ]
]

The important structural property: *the grid indexes all $N$ points and cannot
be partitioned by query*. A point's neighbours can live anywhere; the index has
to be whole. Fortunately it is cheap — 8 B/point persistent.

#pagebreak()
= What the stage computes

== The task

Airborne lidar contains *noise*: birds, low-flying aircraft, atmospheric
returns, multipath, and sensor artefacts, conventionally labelled class 7
(low noise) and 18 (high noise). Classical filters — statistical outlier
removal, extended local minimum — are geometric thresholds and miss
structured noise. `filter.ml_noise` instead evaluates a trained LightGBM
ensemble per point and writes `Classification = 7` where the predicted
probability meets a calibrated threshold.

The model is fixed and external: 4 998 trees, 629 748 internal nodes, and a
*pinned 48-feature contract*. The feature order is part of the model, so
column indices in the code are an ABI, not a convention. The reference
implementation is the Python `noise_filter` pipeline the model was trained
with, not PDAL — this stage has no PDAL equivalent.

== The feature vector

The 48 features fall into four *locality classes*. This taxonomy is the whole
argument of this document, so it is worth stating precisely: a feature's
locality class is the smallest set of points whose values it depends on.

#figure(
  caption: [The 48 model features by locality class. Only class $cal(N)$ is
  chunkable by query; class $cal(G)$ is what forces the feature matrix to be
  whole-tile resident.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, auto, 1fr, auto),
    align: (left + horizon, center + horizon, left, center + horizon),
    table.header(
      [*Class*], [*\#*], [*Features*], [*Depends on*],
    ),

    [$cal(P)$ point-local], [7],
    [`return_number`, `num_returns`, `is_last`, `is_single`, `scan_angle`,
     `intensity_z`, `z_tile_norm`],
    [own record\ (+ tile scalars)],

    [$cal(N)$ neighbourhood], [24],
    [`mean_d{8,16,32}`, `r{8,16,32}`, `std_d32`, `dz_knn16`, `below_frac32`,
     `dz_{min,max}32`, `int_vs_nb16`, `int_nb_std16`, `nr_nb_mean16`;
     `{lin,plan,sph,vert}{16,32}`, `eig_sum32`, `curv32`],
    [the 32 nearest\ neighbours],

    [$cal(C)$ cell], [5],
    [`dz_p05_10m`, `dz_med_10m`, `dz_p95_10m`, `cell_count_10m`,
     `dz_p05_25m`],
    [all points in the\ same 10 m / 25 m cell],

    [$cal(G)$ tile-global], [12],
    [10 density-normalised copies (`*_n`, divided by the tile median of
     `r8`); 2 quantile ranks (`mean_d8_q`, `dz_med_10m_q`)],
    [*every point\ in the tile*],
  )
]

#nb[
  *The load-bearing fact.* Twelve of the 48 columns are order statistics over
  the entire tile: two are the point's percentile *rank* within the tile for a
  given column, and ten are divided by the tile-wide median of the `r8`
  column. A rank cannot be computed from a subset — computing it on a chunk
  yields the rank *within the chunk*, which is a different number and a
  different model input. Therefore every point's $cal(N)$ and $cal(C)$ features
  must already exist, for all $N$ points, before the $cal(G)$ features can be
  computed at all. That is what pins the feature matrix in memory.
]

== The feature matrix

Features live in a single dense, row-major $N times 48$ FP32 matrix, `d_feats`:

$ "d_feats"[i times 48 + c] = "feature " c "of point " i $

Row-major means each point's 48 features are contiguous — good for the
inference kernel, which reads all 48 into registers per thread. It is bad for
the column operations (`ml_gather_col_kernel`, `ml_rank_scatter_kernel`),
which stride by 192 bytes and therefore touch one cache line per element; the
code accepts this because those passes are few.

#figure(
  caption: [The feature matrix, and which phase fills which columns. Column
  groups are contiguous by construction because the model's feature order is
  fixed; the phases fill them out of order.],
  kind: image, supplement: [Figure],
)[
  #set text(8pt)
  #let seg(w, c, label) = box(width: w, height: 26pt, fill: c.lighten(72%),
    stroke: 0.5pt + c.lighten(25%), radius: 2pt, inset: 3pt)[
      #set align(center + horizon); #text(7.5pt)[#label]]
  #box(width: 100%)[
    #grid(columns: (auto, 1fr), column-gutter: 6pt, align: horizon,
      text(8.5pt)[
        row $i$ \ #text(7pt, fill: luma(120))[192 B]
      ],
      stack(dir: ltr, spacing: 2pt,
        seg(23%, cKnn, [cols 0–10 \ kNN distance stats]),
        seg(15%, cGrid, [11–16 \ eigen]),
        seg(12%, cScr, [17–21 \ cell]),
        seg(18%, cDim, [22–35 \ per-point + kNN]),
        seg(21%, cFeat, [36–45 \ density-norm.]),
        seg(9%, cMod, [46–47 \ rank]),
      )
    )
    #v(4pt)
    #align(center)[#text(7.5pt, fill: luma(110))[
      $N = 23 thin 582 thin 873$ rows $times$ 48 columns $times$ 4 B
      $=$ *4.217 GiB*
    ]]
  ]
]

#pagebreak()
= The algorithm, phase by phase

`mlNoiseFilterGpu()` (`src/filters/MlNoiseFilter.cu:634`) executes eight
phases. The table below is the whole stage; the sections that follow explain
the phases that matter for memory.

#figure(
  caption: [Execution phases. "Locality" is the class of feature the phase
  produces; "chunkable" answers whether the phase could process a subset of
  query points independently.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, 1fr, auto, auto, auto),
    align: (center + horizon, left, center + horizon, center + horizon, center + horizon),
    table.header([*\#*], [*Phase / kernel*], [*Class*], [*Chunkable*], [*Line*]),

    [0], [Upload all dimensions (executor) + `ensureDevice` of the 8 used], [—],
      [n/a], [`:645`],
    [1], [`DeviceGrid::build` — cell ids, radix sort, run boundaries], [—],
      [*no* (index must be whole)], [`:694`],
    [2], [`ml_knn_stats_kernel` — exact 32-NN + 14 distance/attribute features],
      [$cal(N)$], [*yes*], [`:699`],
    [3], [`ml_eigen_kernel` — 3×3 covariance + Jacobi at $k=16,32$],
      [$cal(N)$], [*yes*], [`:706`],
    [4], [`ml_zabs_kernel` + `runCellFeatures` ×2 (10 m, 25 m)],
      [$cal(C)$], [partly (by cell)], [`:713`],
    [5], [tile stats: 4 full-column sorts + 2 rank scatters],
      [$cal(G)$], [*no*], [`:727`],
    [6], [`ml_finalize_kernel` — normalisation and derived copies],
      [$cal(G)$], [yes (after 5)], [`:790`],
    [7], [`ml_infer_kernel` — 4 998-tree ensemble traversal],
      [—], [yes], [`:849`],
    [8], [Download `Classification`, count], [—], [n/a], [`:869`],
  )
]

== Phase 2 — exact 32-nearest-neighbour search

Each thread owns one query point and maintains a sorted top-32 list *in
registers*: `double topd[32]` (squared distances) and `uint32_t topi[32]`
(indices). It walks expanding rings of grid cells, insertion-sorting
candidates into the list, and stops when the ring bound proves no unvisited
point can beat the current 32#super[nd].

Because the sorted distances are already in registers at the end of the walk,
the kernel computes all 14 distance-derived features *in place* and never
materialises an $N times 32$ distance matrix. The code comments this
explicitly — the authors were already thinking about memory here.

But it does write the neighbour *indices*:

```cpp
for (int i = 0; i < ML_K; i++)
    knnIdx[size_t(tid) * ML_K + i] = topi[i];   // N x 32 x u32 = 2.811 GiB
```

== Phase 3 — eigenfeatures

Phase 3 reads those indices straight back:

```cpp
float nx[ML_K], ny[ML_K], nz[ML_K];
for (int i = 0; i < ML_K; i++) {
    uint32_t j = knnIdx[size_t(tid) * ML_K + i];   // <- only use of knnIdx
    nx[i] = px[j]; ny[i] = py[j]; nz[i] = pz[j];
}
```

then builds the 3×3 covariance of the neighbour set (query point excluded,
centred on the neighbour mean, in `double`), runs a cyclic Jacobi
eigendecomposition, and derives linearity, planarity, sphericity,
verticality, eigenvalue sum, and curvature at $k=16$ and $k=32$.

#warn[
  *`d_knnIdx` exists solely to carry $N times 32$ indices from phase 2 to phase
  3.* It is allocated at line 689, written by one kernel, read by the next,
  and freed at line 709. Its useful lifetime is two kernel launches — but it
  is sized for the whole tile, and it is allocated *before* the grid is built,
  while `d_feats` is already resident.
]

== Phase 4 — cell percentile features

For each of two cell sizes (10 m and 25 m) the stage bins points into
absolute-coordinate cells, builds a 64-bit composite key
`(cellId << 32) | orderFloat(z)`, radix-sorts it, and reads percentiles
directly out of the sorted run for each cell — a neat trick, since sorting by
the composite key sorts *within* each cell by $z$ for free.

The order-preserving float transform makes this valid:

```cpp
uint32_t orderFloat(float f) {          // IEEE-754 total order as u32
    uint32_t b = __float_as_uint(f);
    return (b & 0x80000000u) ? ~b : (b | 0x80000000u);
}
```

This phase allocates four $N$-sized arrays plus CUB sort scratch — 24 B/point
plus roughly 12 B/point of temporary — all while `d_feats` is live.

== Phase 5 — tile statistics and quantile ranks

Five global reductions, each a full-column radix sort followed by host-side
percentile reads: the tile $z$ median and IQR, the intensity median and MAD,
and the median of the `r8` column (the density scale). Then, for two columns,
a stable sort-by-value produces each point's percentile rank:

```cpp
// rank[idxSortedByValue[pos]] = pos / (N-1)
feats[size_t(sortedIdx[pos]) * NF + col] = (float)pos / (N - 1);
```

*This is the phase that makes the stage whole-tile.* A rank is a statement
about a point's position among all $N$ values. There is no chunked formulation
that yields the same numbers.

== Phase 7 — inference

Each thread loads its 48 features into registers and walks all 4 998 trees,
accumulating leaf values, then applies the logistic link and the threshold.
Node thresholds are `double` and are compared against the FP32 feature
promoted to `double`, which is why narrowing the feature matrix to FP16 would
change decisions at ties.

#pagebreak()
= The memory constraint

== Definitions and cost model

Let $N$ be the point count and $B_"pt"$ the *per-point byte coefficient* of a
buffer — its size divided by $N$. Every buffer in the stage is either $O(N)$
with a fixed coefficient, or $O(1)$-ish (the model, the cell arrays). The
stage's peak is then

$ M_"peak" = max_(p in "phases") ( sum_(b thin "live at" thin p) B_"pt" (b) ) times N + O(1) $

All figures below are for tile `27259750`: $N = 23 thin 582 thin 873$ points,
format 6, a $762 times 762$ m tile after reprojection to UTM 10N, i.e.
$approx 40.6$ points/m². Grid cell size resolves to 0.628 m, giving
$1 thin 478 thin 656$ grid cells. Sizes are in GiB ($2^30$ bytes), matching
what `nvidia-smi` reports.

#figure(
  caption: [Every device allocation in the stage. "Transient" buffers are
  allocated and freed inside a single phase; CUB scratch sizes are queried at
  runtime and estimated here from key/value widths.],
  kind: table, supplement: [Table],
)[
  #set text(8.2pt)
  #table(
    columns: (auto, 1fr, auto, auto, auto),
    align: (left, left, right + horizon, right + horizon, center + horizon),
    table.header([*Buffer*], [*Contents*], [*B/pt*], [*GiB*], [*Phases*]),

    [`dims` (13)], [uploaded dimension columns (executor policy)],
      [33], [0.725], [0–8],
    table.hline(stroke: 0.3pt + luma(220)),
    [`d_feats`], [the $N times 48$ FP32 feature matrix],
      [192], [*4.217*], [1–7],
    [`d_knnIdx`], [the $N times 32$ neighbour index matrix],
      [128], [*2.811*], [1–3],
    table.hline(stroke: 0.3pt + luma(220)),
    [grid (kept)], [`sortedCells`, `sortedIndices`, `cellStart/End`],
      [8 #super[†]], [0.187], [1–3],
    [grid (transient)], [`cellIndices`, `pointIndices`, CUB scratch],
      [16], [0.351], [1],
    table.hline(stroke: 0.3pt + luma(220)),
    [`d_zabs`], [absolute FP32 $z$ (cell binning + $z$-normalisation)],
      [4], [0.088], [4–6],
    [cell sort], [`keys`, `keysSorted` (u64), `vals`, `valsSorted` (u32)],
      [24], [0.527], [4],
    [cell scratch], [CUB `SortPairs` temp (u64 key, u32 value)],
      [12], [0.264], [4],
    table.hline(stroke: 0.3pt + luma(220)),
    [tile scratch], [`d_a`, `d_b`, `d_idx`, `d_idxSorted`],
      [16], [0.351], [5],
    [tile sort temp], [CUB `SortKeys` / `SortPairs` temp],
      [8], [0.176], [5],
    table.hline(stroke: 0.3pt + luma(220)),
    [model], [629 748 nodes × 14 B + 634 746 leaves × 8 B + offsets],
      [—], [0.013], [7],
  )
  #v(3pt)
  #set text(7.6pt, fill: luma(100))
  #align(left)[† plus 11.8 MiB for the $1.48 times 10^6$ cell-boundary arrays,
  which do not scale with $N$.]
]

== Buffer lifetimes

The peak is not about totals; it is about *overlap*. The chart below is the
whole problem in one picture.

#figure(
  caption: [Device buffer lifetimes across the eight phases. Solid = live,
  hatched = transient within the phase. The red column marks the peak: the
  4.217 GiB feature matrix and the 2.811 GiB neighbour-index matrix are
  co-resident for exactly two kernels.],
  kind: image, supplement: [Figure],
)[
  #set text(7.6pt)
  #let ph = ("0 up", "1 grid", "2 kNN", "3 eig", "4 cell", "5 tile", "6 fin", "7 inf", "8 dl")
  #let cellw = 1fr
  #let live(c) = rect(width: 100%, height: 11pt, fill: c, radius: 1pt, stroke: none)
  #let trans(c) = rect(width: 100%, height: 11pt, fill: c.lighten(60%),
    radius: 1pt, stroke: (paint: c.lighten(20%), thickness: 0.5pt, dash: "dotted"))
  #let none_ = rect(width: 100%, height: 11pt, fill: luma(250), stroke: none)
  #let row(name, size, color, spec) = (
    align(right + horizon)[#name],
    align(right + horizon)[#text(fill: luma(110))[#size]],
    ..spec.map(s => if s == 1 { live(color) } else if s == 2 { trans(color) } else { none_ }),
  )
  #box(width: 100%)[
    #grid(
      columns: (auto, auto, ..range(9).map(i => 1fr)),
      column-gutter: 2pt, row-gutter: 2.5pt,
      align: horizon,

      [], [], ..ph.map(p => align(center)[#text(7pt, fill: luma(90))[#p]]),

      ..row([`dims`], [0.725], cDim, (1,1,1,1,1,1,1,1,1)),
      ..row([`d_feats`], [4.217], cFeat, (0,1,1,1,1,1,1,1,0)),
      ..row([`d_knnIdx`], [2.811], cKnn, (0,1,1,1,0,0,0,0,0)),
      ..row([grid], [0.187], cGrid, (0,1,1,1,0,0,0,0,0)),
      ..row([grid tmp], [0.351], cGrid, (0,2,0,0,0,0,0,0,0)),
      ..row([`d_zabs`], [0.088], cScr, (0,0,0,0,1,1,1,0,0)),
      ..row([cell bufs], [0.791], cScr, (0,0,0,0,2,0,0,0,0)),
      ..row([tile scratch], [0.527], cScr, (0,0,0,0,0,2,0,0,0)),
      ..row([model], [0.013], cMod, (0,0,0,0,0,0,0,2,0)),

      [], [],
      ..(("0.725", "8.291", "7.940", "7.940", "5.820", "5.557", "5.030",
          "4.955", "0.725").map(v => align(center)[
           #text(7pt, weight: if v == "8.291" { 700 } else { 400 },
                 fill: if v == "8.291" { cFeat } else { luma(90) })[#v]
         ])),
    )
  ]
  #v(3pt)
  #align(center)[#text(7.6pt, fill: luma(100))[
    bottom row: total live device memory in GiB
  ]]
]

Four distinct peaks emerge:

#figure(
  caption: [Peak device memory by phase, against an 11 GiB RTX 2080 Ti with
  $approx 0.30$ GiB of CUDA context overhead. The two grey rows are the memory
  that was actually free when the test ran, and the card total.],
  kind: image, supplement: [Figure],
)[
  #set text(8.3pt)
  #let VMAX = 11.0
  #table(
    columns: (auto, 1fr, auto, auto),
    stroke: none,
    align: (left + horizon, horizon, right + horizon, left + horizon),
    inset: (x: 4pt, y: 3pt),

    [*A* phase 1 — grid build], bar(8.291, VMAX, cFeat), [8.291 GiB],
      [#text(fill: cFeat, weight: 700)[over budget]],
    [*B* phase 4 — cell sort], bar(5.820, VMAX, cKnn), [5.820 GiB], [],
    [*C* phase 5 — tile stats], bar(5.557, VMAX, cGrid), [5.557 GiB], [],
    [*D* phase 7 — inference], bar(4.955, VMAX, cMod), [4.955 GiB], [],
    table.hline(stroke: 0.4pt + luma(190)),
    [free at run time], bar(7.369, VMAX, luma(200)), [7.369 GiB],
      [#text(fill: luma(110))[3.26 GiB held elsewhere]],
    [card total], bar(11.0, VMAX, luma(225)), [11.0 GiB], [],
  )
]

Peak A exceeds peak B by 2.47 GiB, and *the entire excess is `d_knnIdx`*. The
stage's memory requirement is set by a scratch buffer that lives for two
kernels.

== The failure, traced

The allocations happen in a fixed order. Reconstructing it against the 7.369
GiB that was free:

#figure(
  caption: [Allocation trace for tile `27259750`. The stage does not fail
  because the tile is too big; it fails because it asks for its largest two
  buffers back to back before doing any work.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, 1fr, auto, auto, auto),
    align: (center + horizon, left, right + horizon, right + horizon, left + horizon),
    table.header([*\#*], [*Action*], [*Size*], [*Cumulative*], [*Free left*]),

    [1], [CUDA context creation], [≈0.30], [0.30], [7.07],
    [2], [`filter.reproject` FP64 op-chain buffers (freed on exit)],
      [—], [0.30], [7.07],
    [3], [executor uploads all 13 dimension columns], [0.725], [1.025], [6.34],
    [4], [`cudaMalloc(&d_feats, N*48*4)` #h(4pt) `:688`], [4.217], [5.242], [2.13],
    [5], [`cudaMalloc(&d_knnIdx, N*32*4)` #h(4pt) `:689`], [*2.811*], [8.053],
      [#text(fill: cFeat, weight: 700)[−0.68 → OOM]],
  )
]

The error surfaces at line 689 because that is the first request large enough
to be refused. Line 688 is equally responsible; had the two been swapped, the
report would name 688 instead. This is worth stating plainly because the line
number in the error message invites the wrong conclusion — nothing is wrong
with the kNN index buffer's *code*, only with its *size and lifetime*.

Two secondary effects deserve a mention. First, `filter.reproject` ran an FP64
GPU op-chain immediately before and released several $N$-sized FP64 buffers;
CUDA's allocator can return that memory to a pool without coalescing it, so a
single contiguous 4.2 GiB request can fail even when the arithmetic says it
fits. Second, the 0.30 GiB context estimate is nominal — driver version, CUDA
module count, and the metallib/PTX images loaded all move it.

== Why this is structural, not incidental

Summing the coefficients at each peak gives the stage's scaling law:

#figure(
  caption: [Per-point byte coefficients at each peak, and the resulting point
  ceiling on 10.70 GiB of usable device memory.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, auto, auto),
    align: (left + horizon, left, right + horizon, right + horizon),
    table.header([*Peak*], [*Composition*], [*B/pt*], [*$N_max$*]),

    [A phase 1], [33 dims + 192 feats + 128 knn + 8 grid + 16 grid tmp],
      [*377*], [*30.4 M*],
    [B phase 4], [33 + 192 + 4 zabs + 24 cell + 12 tmp], [265], [43.4 M],
    [C phase 5], [33 + 192 + 4 + 16 + 8], [253], [45.4 M],
    [D phase 7], [33 + 192], [225], [51.1 M],
  )
]

At 40 points/m² — routine for modern QL0/QL1 collections — 30.4 million points
is a 870 m square. The stage as written cannot process a standard USGS tile at
that density on an 11 GiB card *even with the card entirely to itself*, and
peak A is the only reason. Every other phase would clear 43 million points.

#nb[
  The failure the test surfaced is contention. The failure the test *revealed*
  is that `filter.ml_noise` carries a 40% memory tax on every run, paid to a
  buffer whose lifetime is two kernel launches.
]

#pagebreak()
= The fix <sec-fix>

== Option 1 — slice the query set, not the data <sec-chunk>

Phase 2 and phase 3 are the only phases whose *output for a point depends
only on that point's neighbourhood*. Every thread reads the shared spatial
index and writes its own row of `d_feats` and its own row of `d_knnIdx`. There
is no cross-query communication, no reduction, no ordering dependency.

That means the phases can be run over any partition of the *query* points,
in any order, with identical results — provided the spatial index still covers
all $N$ points, because a query's neighbours may lie anywhere in the tile.

#figure(
  caption: [Chunking the query set. The index (blue) stays whole-tile; only the
  neighbour-index scratch (orange) shrinks, from $N times 32$ to $C times 32$.
  Feature rows are written at the global row offset, so `d_feats` is unchanged.],
  kind: image, supplement: [Figure],
)[
  #set text(8pt)
  #grid(columns: (1fr, auto, 1fr), column-gutter: 12pt, align: top,

    box(width: 100%)[
      #align(center)[#text(8.6pt, weight: 700)[now]]
      #v(4pt)
      #stack(dir: ttb, spacing: 3pt,
        dbox(w: 100%, fill: cGrid.lighten(78%))[grid over $N$ — 0.187 GiB],
        dbox(w: 100%, fill: cKnn.lighten(70%))[
          `d_knnIdx` — $N times 32$ \ *2.811 GiB*],
        dbox(w: 100%, fill: cFeat.lighten(80%))[`d_feats` — $N times 48$ — 4.217 GiB],
      )
      #v(5pt)
      #align(center)[#text(7.6pt, fill: luma(100))[
        one launch of each kernel over all $N$ threads
      ]]
    ],

    align(horizon)[#text(15pt, fill: luma(130))[$arrow.r$]],

    box(width: 100%)[
      #align(center)[#text(8.6pt, weight: 700)[proposed]]
      #v(4pt)
      #stack(dir: ttb, spacing: 3pt,
        dbox(w: 100%, fill: cGrid.lighten(78%))[grid over $N$ — 0.187 GiB #text(7pt)[(unchanged)]],
        dbox(w: 55%, fill: cKnn.lighten(70%))[
          `d_knnIdx` — $C times 32$ \ *0.500 GiB*],
        dbox(w: 100%, fill: cFeat.lighten(80%))[`d_feats` — $N times 48$ — 4.217 GiB #text(7pt)[(unchanged)]],
      )
      #v(5pt)
      #align(center)[#text(7.6pt, fill: luma(100))[
        $ceil(N \/ C) = 6$ launches of each kernel
      ]]
    ],
  )
]

=== The change

Both kernels take a `base` offset; the neighbour buffer is indexed locally and
the feature matrix globally.

```cpp
// ml_knn_stats_kernel / ml_eigen_kernel: same body, two-line preamble change
int local = blockIdx.x * blockDim.x + threadIdx.x;
if (local >= count) return;
int tid = base + local;                       // global: coords, feats
...
knnIdx[size_t(local) * ML_K + i] = topi[i];   // local:  scratch row
float* f = feats + size_t(tid) * NF;          // global: feature row
```

The host side sizes the chunk from what is actually free, and reorders the
allocations so the grid's transient buffers do not overlap `d_feats`:

```cpp
grid::DeviceGrid dgrid;
dgrid.build(d_px, d_py, N, gp);                     // build FIRST: transients
                                                     // no longer overlap feats
CUDA_CHECK(cudaMalloc(&d_feats, size_t(N) * NF * sizeof(float)));

size_t freeB = 0, totalB = 0;
CUDA_CHECK(cudaMemGetInfo(&freeB, &totalB));
size_t reserve = freeB / 8 + (size_t(64) << 20);     // headroom + slack
size_t budget  = freeB > reserve ? freeB - reserve : 0;
int chunk = int(std::min<size_t>(size_t(N),
                std::max<size_t>(size_t(1) << 20,    // floor: 1 Mi queries
                                 budget / (ML_K * sizeof(uint32_t)))));

uint32_t* d_knnIdx = nullptr;
while (cudaMalloc(&d_knnIdx, size_t(chunk) * ML_K * sizeof(uint32_t))
         != cudaSuccess && chunk > (1 << 18)) {
    cudaGetLastError();                              // clear the sticky error
    chunk /= 2;                                      // contention retry
}

for (int base = 0; base < N; base += chunk) {
    int count = std::min(chunk, N - base);
    int cb = (count + ML_BLOCK - 1) / ML_BLOCK;
    ml_knn_stats_kernel<<<cb, ML_BLOCK>>>(..., d_knnIdx, d_feats, base, count);
    ml_eigen_kernel<<<cb, ML_BLOCK>>>(..., d_knnIdx, d_feats, base, count);
}
```

Note the two kernels stay *inside* the same chunk iteration: `d_knnIdx` holds
only the current chunk's neighbours, so phase 3 must consume them before phase
2 overwrites them for the next chunk.

=== What it buys

#figure(
  caption: [Peak device memory before and after, at $C = 4$ Mi queries
  (0.500 GiB of scratch). Chunking plus the allocation reordering removes
  2.66 GiB from the peak and makes the profile flat — the stage is no longer
  dominated by one phase.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #let VMAX = 9.0
  #table(
    columns: (auto, auto, 1fr, auto, 1fr, auto),
    align: (left + horizon, center + horizon, horizon, right + horizon, horizon, right + horizon),
    table.header(
      [*Peak*], [], table.cell(colspan: 2)[*now*], table.cell(colspan: 2)[*proposed*],
    ),

    [A phase 1–3], [], bar(8.291, VMAX, cFeat), [8.291],
      bar(5.629, VMAX, cScr), [5.629],
    [B phase 4], [], bar(5.820, VMAX, cKnn), [5.820],
      bar(5.820, VMAX, cScr), [5.820],
    [C phase 5], [], bar(5.557, VMAX, cGrid), [5.557],
      bar(5.557, VMAX, cScr), [5.557],
    [D phase 7], [], bar(4.955, VMAX, cMod), [4.955],
      bar(4.955, VMAX, cScr), [4.955],
    table.hline(stroke: 0.4pt + luma(190)),
    [*stage peak*], [], bar(8.291, VMAX, cFeat), [*8.291*],
      bar(5.820, VMAX, cScr), [*5.820*],
    [*$N_max$ @ 10.70 GiB*], [], [], [30.4 M], [], [43.4 M],
  )
]

Three properties are worth being explicit about:

/ Bit-identical output: the neighbour search per query is unchanged — same
  grid, same rings, same insertion order, same termination test. No baseline
  regeneration, no parity re-validation, no new tolerance entry.
/ Negligible runtime cost: the same total work in 6 launches instead of 1.
  At $C = 4$ Mi, each launch still fills the device many times over, so
  occupancy and tail effects are immaterial. The grid is still built once.
/ It would have passed this test run: 5.82 GiB fits comfortably in the 7.07
  GiB that was free even with the competing process resident.

== Option 2 (IMPLEMENTED) — fuse phases 2 and 3, eliminating the buffer <sec-fuse>

The stronger version of the same observation: `d_knnIdx` need not exist at all.
At the end of phase 2 the 32 neighbour indices are already in registers
(`topi[32]`), and phase 3's first act is to load them back from global memory.
Fusing the two kernels removes the buffer *and* $2 times 3.0$ GiB of memory
traffic.

The obstacle is register pressure — and it is real. Phase 3 as originally
written stages the neighbour coordinates into `float nx/ny/nz[32]`, 96
registers, on top of everything the search already holds. Pasted onto the end
of phase 2 that overflows, and the surplus spills to local memory, which is
device memory again: a slower kernel in exchange for the buffer.

*The resolution is to stream the covariance rather than stage it.* Sweep the
neighbour list twice — once accumulating the centroid, once accumulating the
outer products against it — reading each neighbour's coordinates from
`px`/`py`/`pz` on both sweeps and holding none of them:

```cpp
for (int pass = 0; pass < 2; pass++) {
    int kk = pass == 0 ? 16 : 32;
    double mx = 0, my = 0, mz = 0;
    for (int i = 0; i < kk; i++) {            // sweep 1: centroid
        uint32_t j = topi[i];                 // still in registers
        mx += px[j]; my += py[j]; mz += pz[j];
    }
    mx /= kk; my /= kk; mz /= kk;
    double A[3][3] = {{0,0,0},{0,0,0},{0,0,0}};
    for (int i = 0; i < kk; i++) {            // sweep 2: covariance
        uint32_t j = topi[i];
        double cx = px[j] - mx, cy = py[j] - my, cz = pz[j] - mz;
        A[0][0] += cx * cx; /* ... */
    }
    /* ... divide by kk, Jacobi, write the ten features ... */
}
```

Those coordinates were read by the search moments earlier, so they are
cache-resident and the re-read is nearly free.

#figure(
  caption: [Register pressure, `nvcc -Xptxas -v`, sm_75. The fused kernel is
  five registers above the larger of the two it replaces, with no spill — both
  old kernels were already at 2 resident blocks per SM at `ML_BLOCK = 128`, so
  occupancy is unchanged.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(columns: (1fr, auto, auto, auto),
    align: (left + horizon, right + horizon, center + horizon, right + horizon),
    table.header([*kernel*], [*registers*], [*spill st / ld*], [*stack*]),
    [`ml_knn_stats_kernel` (before)], [213], [0 / 0], [64 B],
    [`ml_eigen_kernel` (before)], [217], [0 / 0], [96 B],
    [*fused* `ml_knn_stats_kernel`], [*218*], [*0 / 0*], [160 B],
  )
]

=== Measured result

#figure(
  caption: [Before/after on the three Santa Clara tiles (RTX 2080 Ti, GPU
  otherwise idle, best of two runs, full read → assign → reproject(fp64) →
  ml_noise → write pipeline). "kernel(s)" is the old kNN plus eigen kernels
  against the single fused kernel.],
  kind: table, supplement: [Table],
)[
  #set text(8.2pt)
  #table(
    columns: (auto, auto, auto, auto, auto, auto, auto),
    align: (left + horizon, right + horizon, right + horizon, right + horizon,
            right + horizon, right + horizon, right + horizon),
    table.header([*tile*], [*points*], [*peak before*], [*peak after*],
      [*Δ*], [*kernel(s) before*], [*fused after*]),
    [27259750], [23.58 M], [8316 MB], [5436 MB], [−34.6%], [23012 ms], [22856 ms],
    [27509750], [23.26 M], [8214 MB], [5374 MB], [−34.6%], [24261 ms], [23927 ms],
    [27759900], [22.08 M], [7806 MB], [5110 MB], [−34.5%], [21248 ms], [20965 ms],
  )
]

The separate eigen kernel cost 215–230 ms; the fused kernel absorbs that work
for a net saving of 156–334 ms, about *1%* of the stage. That is the honest
result, and it was predicted: the stage is dominated by the search itself
(≈21–24 s) and by tree inference (≈17–18 s), so removing six gigabytes of
traffic barely registers. *The memory reduction is the win.*

Correctness held exactly as the argument required. On the committed Everglades
fixture the $N times 48$ FP32 feature matrix dumped via `debug_features` is
byte-identical before and after — 301 345 536 bytes, md5
`38f246eb58ffea4847dc8cdf4f9e0691` in both cases — and the output LAZ matches
byte-for-byte. Noise counts on the three Santa Clara tiles are identical
(23 305 / 49 197 / 12 021). Accumulation order, promotions and the $k$ divisor
were left untouched, so this is a consequence of the design, not a lucky
outcome.

One further change went in alongside it: `DeviceGrid::build` now runs *before*
the `d_feats` allocation, so the grid's ≈24 B/point of transient scratch no
longer overlaps the feature matrix. Visible in the profiler as the grid-build
step reporting 1116 MB rather than 8316 MB.

#nb[
  *What the new ceiling is.* With the neighbour table gone, the tightest moment
  in the stage moves to phase 4 — the 10 m / 25 m cell-feature sort, where four
  $N$-sized arrays and CUB scratch coexist with the feature matrix. Measured
  5110–5436 MB. Any further memory work on this stage should start there, and
  the cheapest available saving is noted in @sec-drawbacks: the cell sort uses
  `SortPairs` where the sorted *values* are never read.
]

== Option 3 — two cheap secondary wins

/ Preflight and diagnose: query `cudaMemGetInfo` at stage entry, compute the
  requirement from $N$, and fail with `ml_noise: needs ~8.3 GiB, 7.4 GiB free
  (3.3 GiB held by other processes)` instead of `CUDA error: out of memory at
  MlNoiseFilter.cu:689`. The current message actively misleads: it names a
  line whose only fault is being second in line.
/ Trim the dimension upload: the executor uploads all 13 columns for any GPU
  stage; `ml_noise` reads 8. Adding an optional `requiredDims()` to `Stage`,
  defaulting to "all", would save 0.264 GiB here and more on RGB-bearing
  formats. The risk is a stage that under-declares and silently reads a stale
  device pointer, so the default must stay permissive and the opt-in explicit.

== Rejected alternatives

/ Spatial tiling of the whole stage: process the tile in blocks with halos.
  This *changes the answer*. The tile median, IQR, intensity MAD, density
  scale, and both quantile ranks are defined over the tile; computed per block
  they become different features, and every downstream decision shifts. The
  model was trained against tile-level statistics.
/ Narrowing `d_feats` to FP16: saves 2.1 GiB but the inference kernel compares
  feature values promoted to `double` against `double` node thresholds. FP16
  would move points across split boundaries — a parity change for a saving
  chunking provides for free.
/ Streaming `d_feats` to host between phases: the $cal(G)$ phases need random
  access to whole columns, so this trades 4.2 GiB of device memory for
  repeated 4.2 GiB PCIe round-trips. Only worth considering above 43 M points,
  where nothing else works either.

#pagebreak()
= Drawbacks, risks, and what this does not fix <sec-drawbacks>

Stating the limits precisely matters more than the win, because the win is
modest and bounded.

- *It buys 43% more points, not unbounded scale.* Chunking removes `d_knnIdx`
  from the peak but leaves a 265 B/point floor: 33 B of uploaded dimensions,
  192 B of feature matrix, and 40 B of cell-sort machinery. The ceiling moves
  from 30.4 M to 43.4 M points on an 11 GiB card and then stops. A 60 M point
  tile still fails, and the next structural step — out-of-core processing with
  tile-level statistics computed in a first pass — is a much larger change.
- *The new binding constraint is phase 4, not phase 2.* After the fix the
  stage peaks in the cell-feature sort (5.820 GiB), where four $N$-sized arrays
  and CUB scratch coexist with the feature matrix. Two of those four
  (`d_vals`, `d_valsSorted`) are only needed because `SortPairs` is used where
  the sorted values are never read — the composite key already carries the
  ordering. Dropping to `SortKeys` would save a further 0.176 GiB. That is a
  separate, smaller cleanup, and it should be verified that `d_valsSorted` is
  genuinely dead before removing it.
- *Sizing from free memory is racy.* `cudaMemGetInfo` reports a snapshot; another
  process can allocate between the query and the `cudaMalloc`. The retry loop
  in the sketch handles this, but a retry loop that halves the chunk can spin
  down to the floor and then fail anyway. The honest behaviour under heavy
  contention is to fail early with a clear message, not to degrade silently
  into a 256 Ki-query chunk that takes 90 launches.
- *It does not fix fragmentation.* The 4.217 GiB `d_feats` request is a single
  contiguous allocation. Following an FP64 reprojection that has just freed
  several $N$-sized buffers, that request can fail while the arithmetic says it
  fits. Chunking makes the *second* large request small; it does nothing for
  the first. A stage-lifetime arena allocated once and sub-allocated would, but
  that is a framework-level change affecting every GPU filter.
- *Chunk-boundary indexing is the one real correctness risk.* The change
  introduces two different index spaces in the same kernel — global for
  coordinates and features, local for the scratch row. Getting one wrong
  produces plausible-looking output with a few million wrong feature rows,
  which the accuracy tier's precision/recall floors might not catch. The
  mitigation is cheap and should be mandatory: the stage already supports a
  `debug_features` dump of the raw $N times 48$ matrix, so a test that runs one
  tile at $C = N$ and at $C = N \/ 4$ and asserts the two dumps are
  byte-identical pins the invariant exactly.
- *Determinism across machines changes shape, not value.* Chunk size derived
  from free memory means two machines run different launch geometries. Output
  is unaffected — each query is independent — but a bug report saying "it
  differs on my box" becomes harder to reason about. Logging the chosen chunk
  size at `Info` costs nothing and removes the ambiguity.
- *The accuracy tier remains contention-sensitive.* Even at 5.820 GiB, a
  co-tenant holding 6 GiB will still fail the run. The tier is an accuracy
  gate, not a memory-pressure gate, and it should probably skip with a clear
  message rather than fail when the card cannot host the requirement — with
  the preflight from option 3, that distinction becomes mechanical.

#warn[
  *One thing to not conclude.* None of this is evidence that the current code
  is wrong. Every buffer here is correctly sized, correctly freed, and
  correctly used; the kNN kernel already avoids materialising an $N times 32$
  *distance* matrix, which shows the memory question was considered. What the
  design did not anticipate is a 40 point/m² tile on a consumer card shared
  with another process. The fix is a refinement of an already-careful stage,
  not a repair.
]

= Resolution

The fusion (@sec-fuse) shipped on 2026-08-21 and the `accuracy` tier now passes
*with* the 3.26 GiB co-tenant that caused the original failure still resident —
the stage needs 5.1–5.4 GB against the 7.4 GB that was free.

For the record, the pre-fix binary also recovers by freeing the card, which is
how these three tiles were validated on 2026-06-12:

```bash
nvidia-smi --query-compute-apps=pid,used_memory,name --format=csv
ctest --test-dir build -L accuracy
```

The pre-fix stage needed 7.8–8.3 GB of an 11 GiB card, a 2.4 GB margin —
enough for a dedicated card, not for a shared one or a denser tile. That
margin is now 5.4 GB.

#v(1em)

#counter(heading).update(0)
#set heading(numbering: "A.1")

= Reference numbers

#figure(
  caption: [Constants and derived quantities used throughout.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, auto),
    align: (left + horizon, left, right + horizon),
    table.header([*Symbol*], [*Meaning*], [*Value*]),

    [`ML_K`], [neighbours per point], [32],
    [`NF`], [model feature count], [48],
    [`ML_BLOCK`], [threads per block, kNN and eigen kernels], [128],
    [$N$], [points, tile `27259750`], [23 582 873],
    [—], [LAS point format / record length], [6 / 30 B],
    [—], [tile extent (state plane ftUS)], [2500 × 2500],
    [—], [tile extent after reprojection to UTM 10N], [≈762 × 762 m],
    [—], [point density], [40.6 pt/m#super[2]],
    [—], [grid cell size, $4 sqrt("area"\/N)$], [0.628 m],
    [—], [grid cells], [1 478 656],
    [—], [model trees / internal nodes], [4 998 / 629 748],
    [—], [decision threshold], [0.9336],
    [—], [device], [RTX 2080 Ti, 11.0 GiB],
  )
]

= Reproducing the measurements

```bash
# per-stage GPU timings and the allocation sequence
build/pcax run pipeline.yaml -d -v input=tile.laz -v model=$MODEL -v output=out.laz

# live device memory while the stage runs
nvidia-smi --query-gpu=memory.used,memory.free --format=csv -l 1

# the feature matrix itself (N x 48 float32, row-major)
#   add `debug_features: /path/feats.bin` to the filter.ml_noise stage
python3 -c "import numpy as np; \
  a = np.fromfile('/path/feats.bin', dtype=np.float32).reshape(-1, 48); \
  print(a.shape, a.nbytes / 2**30, 'GiB')"
```

Buffer sizes in this document are computed directly from the `cudaMalloc`
calls in `src/filters/MlNoiseFilter.cu` and `src/filters/SpatialGrid.cuh`;
CUB scratch sizes are estimates from key/value widths, since the actual values
are queried at runtime by the two-call `SortPairs`/`SortKeys` idiom. Dimension
count and widths come from `src/core/LasAttrs.cpp` for point format 6.

= Related documentation

- `docs/MlNoiseFilter.md` — the 48-feature contract, model provenance and
  cache behaviour, parity status against the Python reference.
- `docs/IntegrationTesting.md` — the test tiers, including `accuracy`.
- docs/Parity.md — the original validation of these three tiles.
- `CLAUDE.md` — SoA storage, coordinate encoding, and residency rules.
