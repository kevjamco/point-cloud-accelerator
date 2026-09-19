// Copyright (c) 2026 Advanced Algorithms LLC
// SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
// pcax architecture — living reference. Compile:
//   typst compile docs/Architecture.typ
// Companion: docs/MlNoiseGpuMemory.typ (GPU memory case study)

#set document(
  title: "pcax Architecture — a GPU point-cloud framework, compared with PDAL",
  author: "pcax",
)
#set page(
  paper: "a4",
  margin: (x: 2.0cm, top: 2.2cm, bottom: 2.0cm),
  numbering: "1 / 1",
  header: context {
    if counter(page).get().first() > 1 [
      #set text(8pt, fill: luma(110))
      pcax architecture · CUDA · PDAL comparison
      #h(1fr)
      docs/Architecture.typ
      #v(-0.6em)
      #line(length: 100%, stroke: 0.4pt + luma(200))
    ]
  },
)
#set text(
  font: ("New Computer Modern", "DejaVu Serif", "Liberation Serif"),
  size: 10pt, lang: "en",
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
#show raw: set text(font: ("DejaVu Sans Mono", "Liberation Mono"), size: 8.2pt)
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
#let cPca  = rgb("#1f4e79")
#let cPdal = rgb("#8e6c1f")
#let cCuda = rgb("#2f7d32")
#let cWarn = rgb("#c0392b")
#let cAlt  = rgb("#7d3c98")
#let cGrey = rgb("#7f8c8d")

// ---- helpers ---------------------------------------------------------------
#let chip(body, fill: luma(245), stroke: luma(150)) = box(
  fill: fill, stroke: 0.6pt + stroke, inset: (x: 5pt, y: 3pt),
  radius: 3pt, baseline: 22%,
)[#set text(7.6pt); #body]

#let tPcax = chip(fill: cPca.lighten(88%), stroke: cPca.lighten(40%))[
  #text(fill: cPca, weight: 600)[pcax]]
#let tPdal = chip(fill: cPdal.lighten(88%), stroke: cPdal.lighten(40%))[
  #text(fill: cPdal, weight: 600)[PDAL]]
#let tCuda = chip(fill: cCuda.lighten(88%), stroke: cCuda.lighten(40%))[
  #text(fill: cCuda, weight: 600)[CUDA]]

#let nb(body, color: cPca) = block(
  fill: luma(250), stroke: (left: 2.5pt + color),
  inset: (x: 9pt, y: 7pt), width: 100%, breakable: true,
)[#body]

#let warn(body) = block(
  fill: rgb("#fdf3f2"), stroke: (left: 2.5pt + cWarn),
  inset: (x: 9pt, y: 7pt), width: 100%, breakable: true,
)[#body]

#let lesson(title, body) = block(
  fill: cCuda.lighten(95%), stroke: (left: 2.5pt + cCuda),
  inset: (x: 9pt, y: 7pt), width: 100%, breakable: true,
)[
  #text(8.6pt, weight: 700, fill: cCuda.darken(15%))[CUDA — #title]
  #v(0.25em)
  #body
]

#let dbox(body, fill: luma(245), w: auto, stroke: luma(140)) = box(
  fill: fill, stroke: 0.7pt + stroke, inset: (x: 7pt, y: 6pt),
  radius: 3pt, width: w,
)[#set text(8.4pt); #set align(center); #body]

#let rarr = text(13pt, fill: luma(130))[$arrow.r$]
#let darr = align(center)[#text(12pt, fill: luma(130))[$arrow.b$]]

// ============================================================================
#align(center)[
  #v(1.0cm)
  #text(22pt, weight: 700)[pcax Architecture]
  #v(0.3em)
  #text(13.5pt, fill: luma(90))[
    A GPU point-cloud framework — how it is built,\
    how it differs from PDAL, and the CUDA it is built on
  ]
  #v(1.0em)
  #box(width: 80%)[
    #set text(9pt, fill: luma(100))
    #set align(center)
    Living document · #datetime.today().display("[year]-[month]-[day]") ·
    covers 52 native stages, 62 CUDA kernels, 19 300 lines of C++/CUDA
  ]
]
#v(0.7cm)

#nb[
  *Who this is for.* Three readers at once. Someone who needs to *work on
  pcax* and wants the whole architecture in one place. Someone who knows
  *PDAL* and wants to know precisely where pcax agrees, where it diverges,
  and what that costs. And someone who writes C++ but not *CUDA*, and wants
  to learn it from code that is actually in production rather than from
  vector-addition toys.

  The three threads are marked in the margin: #tPcax architecture,
  #tPdal comparison, #tCuda teaching. CUDA concepts are introduced where the
  code first needs them, in green boxes, and every one of them is illustrated
  with a kernel that ships in this repository.
]

#v(0.5em)
#outline(depth: 2, indent: 1.1em)
#pagebreak()

= Orientation

== What a point-cloud framework has to do

An airborne lidar tile is 20–90 million points. Each point carries a
position and a dozen attributes — intensity, return number, GPS time, scan
angle, classification. Processing it means a *pipeline*: read a compressed
LAZ file, cull obvious junk, remove noise, reproject to a working coordinate
system, classify ground, compute derived geometry, rasterize to a DSM or
DTM, write the result.

Three properties make this domain unusual, and they drive every design
decision that follows:

/ The data is enormous but shallow: tens of millions of records, each tiny
  (30 bytes for LAS point format 6). Per-point overhead dominates. A virtual
  call per attribute access is not a rounding error; it is the program.
/ Coordinates need more precision than they look like they need: a UTM
  easting of 6 272 500 m needs millimetre resolution. That is eight
  significant digits — beyond FP32's 7.2, which is why naïve FP32 storage
  fails and why both frameworks think hard about coordinate representation.
/ Most of the expensive work is neighbourhood work: outlier removal, normals,
  eigenfeatures, clustering, ground classification, rasterization. All of it
  is "for each point, look at nearby points". That is embarrassingly
  parallel — which is what makes a GPU relevant at all.

== PDAL, in one page #h(1fr) #tPdal

PDAL (Point Data Abstraction Library) is the incumbent: BSD-licensed, C++17,
88 filters, 27 readers, 14 writers, and a JSON pipeline language. pcax is
deliberately file-level compatible with it, and its filter semantics are
pinned to PDAL's *source*, not its documentation.

PDAL's data model has three layers:

#figure(
  caption: [PDAL's storage model. A `PointTable` owns the bytes; `PointView`s
  are cheap index vectors over it; a `PointRef` is a cursor. Filters return
  sets of views, so branching and merging are natural.],
  kind: image, supplement: [Figure],
)[
  #box(width: 100%)[
    #grid(columns: (1fr, auto, 1fr, auto, 1fr), column-gutter: 6pt,
      align: horizon + center,
      dbox(fill: cPdal.lighten(88%))[
        *`PointTable`* \ owns the bytes \
        #text(7.5pt)[`RowPointTable` — AoS, \ 65 536-point blocks (default)] \
        #text(7.5pt)[`ColumnPointTable` — per-dim \ 16 384-point blocks]
      ],
      rarr,
      dbox(fill: cPdal.lighten(93%))[
        *`PointView`* \ `std::deque<PointId>` \
        #text(7.5pt)[an *index* into the table; \ `PointViewSet` = set of views]
      ],
      rarr,
      dbox(fill: cPdal.lighten(96%))[
        *`PointRef`* \ (view, id) cursor \
        #text(7.5pt)[`getFieldAs<T>(Id::X, i)`]
      ],
    )
  ]
]

A `PointLayout` registers dimensions dynamically at prepare time — any stage
may call `registerOrAssignDim("MyDim", Type::Double)` — and records, per
dimension, its type and byte offset within a point. Every field access goes
through that registry:

```cpp
// pdal/PointView.hpp — the central data-access path
template <class T>
inline T PointView::getFieldAs(Dimension::Id dim, PointId pointIndex) const {
    const Dimension::Detail *dd = m_layout->dimDetail(dim);   // registry lookup
    Everything e;
    PointId tableIdx = m_index[pointIndex];                   // deque indirection
    switch (dd->type()) {                                     // runtime type switch
    case Dimension::Type::Double:
        m_pointTable.getFieldInternal(dim, tableIdx, &e);     // VIRTUAL call
        ok = Utils::numericCast(e.d, retval);                 // checked conversion
        break;
    /* ... one case per dimension type ... */
    }
}
```

Reading one coordinate of one point costs: a layout lookup, a deque
indirection, a runtime type switch, a virtual function call, a `memcpy`, and
a range-checked numeric cast. That is the price of PDAL's genuine strength —
*any* stage can invent *any* dimension of *any* type at runtime, and every
other stage can read it without knowing it exists.

Execution comes in two modes. In *standard* mode, `Stage::execute(PointTableRef)`
returns a `PointViewSet`, and a filter may return more views than it received
(`filters.splitter`, `filters.chipper`) or fewer (`filters.merge`). In
*streaming* mode, a `Streamable` stage implements `processOne(PointRef&)` and
points flow through the whole pipeline in fixed-capacity chunks, so a file
larger than RAM can be processed. Neighbourhood queries use nanoflann KD-trees
via `KD2Index`/`KD3Index`.

== pcax, in one page #h(1fr) #tPcax

pcax is not a PDAL fork. It is a second implementation of the same *file*
contract with a different internal model, built so that the compute-heavy
half of a lidar pipeline can run on a GPU.

#figure(
  caption: [pcax's storage model. One typed array per dimension; a stage sees
  raw pointers. There is one cloud, mutated in place, with a device mirror.],
  kind: image, supplement: [Figure],
)[
  #box(width: 100%)[
    #grid(columns: (1fr, auto, 1fr, auto, 1fr), column-gutter: 6pt,
      align: horizon + center,
      dbox(fill: cPca.lighten(88%))[
        *`PointCloud`* \ `map<DimId, DimArray>` \
        #text(7.5pt)[· raw LAS records \ · `LasMetadata` \ · residency map]
      ],
      rarr,
      dbox(fill: cPca.lighten(93%))[
        *`DimArray`* \ one flat typed buffer \
        #text(7.5pt)[move-only, `void*` · count \ · `DimType`]
      ],
      rarr,
      dbox(fill: cPca.lighten(96%))[
        *access* \ `const float* px = ` \
        `cloud.dimData<float>(DimId::X)` \
        #text(7.5pt)[then `px[i]` — one load]
      ],
    )
  ]
]

The stage interface is deliberately smaller than PDAL's:

```cpp
class Stage {                                   // include/pca/Stage.hpp
    virtual std::string typeName() const = 0;
    virtual ExecutionTarget executionTarget() const { return CPU; }  // CPU or GPU
    virtual void addDimensions(PointCloud&) {}   // declare outputs
    virtual void prepared(PointCloud&) {}        // schema is final
    virtual void execute(PointCloud&) = 0;       // do the work, in place
    virtual void done() {}
};
```

`execute()` takes the whole cloud and mutates it. There is no view set, no
return value, no streaming. In exchange, a filter's inner loop is a raw
pointer walk, and a GPU filter can hand a device pointer straight to a kernel.

== The three claims, examined #h(1fr) #tPdal #tPcax

The README states three reasons PDAL cannot be the base for GPU work. All
three are true, but they are not equally fundamental, and it is worth being
precise about which is which.

#figure(
  caption: [The stated blockers, and what each really costs.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, 1fr),
    align: (left, left, left),
    table.header([*Claim*], [*Accurate?*], [*What it actually means*]),

    [FP64 decode at the reader],
    [Yes. `readers.las` applies `raw × scale + offset` into a `double`
     before any filter sees a point.],
    [8 B/point for X, Y, Z each — 24 B where pcax uses 12. More importantly
     the *original int32* is gone, so exact re-encode on write needs care.],

    [Row-oriented (AoS) storage],
    [Mostly. `RowPointTable` is the default, but `ColumnPointTable` exists and
     is column-blocked.],
    [The layout is not the real obstacle — the *access path* is. Even
     `ColumnPointTable` reaches its bytes through
     `getFieldInternal`, a virtual call per field.],

    [Single-threaded, synchronous],
    [Yes for the core loop. PDAL parallelises across *files*
     (`filters.merge`, tiling), not within a stage.],
    [No thread pool in the executor, no GPU offload path, and the streaming
     mode's per-point call chain is inherently serial.],
  )
]

#nb[
  *The honest summary.* The blocking property is not AoS, and not FP64 —
  it is that PDAL's data access is *polymorphic at the point level*. A CUDA
  kernel cannot call `getFieldInternal`; a GPU needs a `float*` it can index
  with `blockIdx.x * blockDim.x + threadIdx.x` and stream coalesced. Any
  design that keeps runtime-registered dimensions of runtime-chosen types
  behind a virtual accessor is unreachable from a kernel without a full copy
  and repack — which is exactly what pcax's own `pdal.filter` adapter does
  when it hosts a real PDAL filter, and exactly why that adapter has
  "latency issues".
]

== What pcax gives up

Being fair about the trade requires naming the losses, all of which are
consequences of the same simplification:

- *No streaming.* PDAL can process a file larger than RAM in fixed-size
  chunks. pcax loads the whole tile. The `filter.ml_noise` case study
  (`docs/MlNoiseGpuMemory.typ`) is what this costs in practice.
- *No branching dataflow.* The executor topo-sorts the stage DAG but then
  runs it linearly over one shared cloud (`m_clouds["default"]`). A
  `filters.merge` or `filters.splitter` port needs a multi-cloud executor
  first.
- *No dynamic dimensions.* `DimId` is a compile-time enum. Adding a
  dimension means editing `Dimension.hpp` and recompiling. PDAL lets a
  pipeline invent one from a JSON string.
- *No plugin ecosystem.* PDAL stages are shared objects discovered at
  runtime; pcax stages are statically linked and registered at load.
- *Fewer stages.* 52 native vs PDAL's 129 (88 filters + 27 readers +
  14 writers), with `pdal.filter` as the escape hatch.

The rest of this document is about what the simplification buys.

#pagebreak()
= A CUDA primer, taught from this codebase #h(1fr) #tCuda

This part introduces every CUDA concept pcax uses, in the order the code
needs them. Nothing here is hypothetical — each idea is illustrated with a
kernel that ships in `src/`. If you already write CUDA, skim it for the
pcax-specific conventions and skip to @sec-datastructures.

== The execution model

A CUDA program has two sides. *Host* code runs on the CPU and looks like
ordinary C++. *Device* code runs on the GPU as a *kernel*: one function
executed by thousands of threads at once, each of which computes its own
index and works on its own slice of the data.

Threads are organised in a three-level hierarchy:

#figure(
  caption: [The launch hierarchy. pcax kernels use a 1-D grid of 1-D blocks
  throughout: one thread per point. Block sizes in the codebase are 128
  (`ML_BLOCK`, `CL_BLOCK`) or 256 (`BLOCK_SIZE`, `HAG_BLOCK`).],
  kind: image, supplement: [Figure],
)[
  #set text(8pt)
  #let th(c) = rect(width: 100%, height: 9pt, fill: c, radius: 1pt, stroke: none)
  #box(width: 100%)[
    #grid(columns: (auto, 1fr), column-gutter: 8pt, row-gutter: 5pt,
      align: (right + horizon, left + horizon),

      [*thread*],
      [#box(width: 22pt)[#th(cCuda.lighten(30%))] #h(4pt)
       #text(8.4pt)[one point · own registers · own `tid`]],

      [*warp*],
      [#grid(columns: 32, gutter: 1pt, ..range(32).map(i =>
         th(cCuda.lighten(45%))))
       #v(2pt)
       #text(8.4pt)[32 threads in *lockstep* — the real unit of execution;
       divergent branches serialise]],

      [*block*],
      [#grid(columns: 4, gutter: 3pt, ..range(4).map(i =>
         box(fill: cCuda.lighten(80%), stroke: 0.5pt + cCuda.lighten(35%),
             inset: 2pt, radius: 2pt)[#grid(columns: 8, gutter: 1pt,
             ..range(8).map(j => th(cCuda.lighten(45%))))]))
       #v(2pt)
       #text(8.4pt)[128 or 256 threads · shares `__shared__` memory ·
       can `__syncthreads()` · resident on one SM]],

      [*grid*],
      [#text(8.4pt)[`ceil(N / blockSize)` blocks — for a 23.6 M-point tile at
       128 threads/block, 184 241 blocks. Blocks are scheduled onto SMs in
       unspecified order and cannot synchronise with each other.]],
    )
  ]
]

Every pcax kernel opens with the same three lines, the *grid-stride-free
one-thread-one-point idiom*:

```cpp
__global__ void hag_nn_kernel(/* ... */, int N) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;   // this thread's point
    if (tid >= N) return;                              // guard the tail block
    // ... work on point tid ...
}
```

The guard matters: $N$ is almost never a multiple of the block size, so the
last block has idle threads that must not touch memory. The host side pairs
with it:

```cpp
int blocks = (N + ML_BLOCK - 1) / ML_BLOCK;      // ceiling division
ml_knn_stats_kernel<<<blocks, ML_BLOCK>>>(d_px, d_py, d_pz, /* ... */,
                                          d_feats, N);
```

The `<<<blocks, threads>>>` syntax is CUDA's launch operator. The call is
*asynchronous*: it returns immediately, having only queued the kernel on
the default stream. This has a consequence that shapes all error handling
below.

#lesson("function qualifiers")[
  `__global__` — a kernel: called from host, runs on device, must return
  `void`. `__device__` — callable only from device code. `__host__` —
  ordinary CPU function (the default). The two can be combined, which is how
  pcax compiles the *same* reprojection math for both sides:

  ```cpp
  #if defined(__CUDACC__)
  #define PCA_HD __host__ __device__ __forceinline__     // src/reproj/OpsImpl.hpp
  #else
  #define PCA_HD inline
  #endif
  ```

  `__forceinline__` overrides the compiler's inlining heuristic — worth it
  for small math helpers called in a deep loop, where a real call would spill
  registers.
]

== Memory: the hierarchy, and why layout is everything

#figure(
  caption: [The device memory hierarchy on an RTX 2080 Ti (compute capability
  7.5). The numbers that matter for pcax are the top and bottom rows: registers
  are ≈100× faster than global memory, and there are only 65 536 of them per SM
  to go around.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, auto, auto, 1fr),
    align: (left + horizon, center + horizon, center + horizon, left),
    table.header([*Space*], [*Scope*], [*Latency*], [*Used in pcax for*]),

    [registers], [thread], [≈1 cyc],
    [the top-$K$ neighbour list, accumulators, the whole reprojection op chain],
    [`__shared__`], [block], [≈30 cyc],
    [block-level min/max reduction in `chainKernel`],
    [L1 / L2], [SM / device], [≈30 / ≈200 cyc],
    [implicit — coalesced dimension streams hit L2 hard],
    [global], [device], [≈400 cyc],
    [every `DimArray` device mirror, the grid, all scratch buffers],
    [local], [thread], [global speed],
    [*spilled* registers — the failure mode to avoid (see @sec-occupancy)],
  )
]

Global memory is read in *transactions* covering an aligned 32-byte sector.
When the 32 threads of a warp read 32 consecutive `float`s, the hardware
merges them into four transactions and every byte fetched is used. When they
read one `float` each from 32 *structs* 30 bytes apart, it issues up to 32
transactions and discards most of each. This is *coalescing*, and it is the
single reason pcax stores structure-of-arrays.

#figure(
  caption: [Why SoA. Reading `X` for 8 consecutive points: SoA touches one
  contiguous run; AoS touches 8 scattered fragments of 8 different cache
  lines. At 30 B/record and a 32 B sector, the AoS read wastes ≈87% of its
  bandwidth.],
  kind: image, supplement: [Figure],
)[
  #set text(7.8pt)
  #let want = cCuda.lighten(35%)
  #let waste = luma(225)
  #box(width: 100%)[
    #grid(columns: (auto, 1fr), column-gutter: 8pt, row-gutter: 7pt,
      align: (right + horizon, left),

      [*SoA* #linebreak() #text(7pt, fill: luma(110))[pcax]],
      [#grid(columns: 24, gutter: 1pt,
         ..range(24).map(i => rect(width: 100%, height: 12pt, radius: 1pt,
            stroke: none, fill: if i < 8 { want } else { waste })))
       #v(2pt)
       #text(8pt)[`float X[]` — the 8 values a warp wants are adjacent.
       *1 transaction, 100% used.*]],

      [*AoS* #linebreak() #text(7pt, fill: luma(110))[PDAL `RowPointTable`]],
      [#grid(columns: 24, gutter: 1pt,
         ..range(24).map(i => rect(width: 100%, height: 12pt, radius: 1pt,
            stroke: none, fill: if calc.rem(i, 3) == 0 { want } else { waste })))
       #v(2pt)
       #text(8pt)[`struct Point { double x, y, z; uint16 intensity; ... }[]` —
       the wanted values are one per record. *8 transactions, ≈13% used.*]],
    )
  ]
]

#nb[
  *This is the crux of the whole design.* SoA is not a micro-optimisation
  bolted onto pcax; it is the reason `PointCloud` is a `map<DimId, DimArray>`
  and not a `vector<Point>`. Every other structural decision — relative FP32
  coordinates, per-dimension residency, raw-record passthrough — follows from
  committing to it.
]

== Registers, occupancy, and the top-$K$ pattern <sec-occupancy>

Each SM has a fixed register file (65 536 32-bit registers on CC 7.5). The
number of *resident* blocks per SM is bounded by

$ "blocks"_"SM" = floor( 65536 / ("registers per thread" times "threads per block") ) $

and *occupancy* — resident warps as a fraction of the maximum — is what
hides global-memory latency. When a warp stalls on a load, the SM runs
another; with too few resident warps, it stalls idle instead.

pcax leans hard on registers in its kNN kernels. Each thread keeps its
entire top-$K$ neighbour list in registers and insertion-sorts into it:

```cpp
// src/filters/SorFilter.cu — top-K entirely in registers
RealT top_k[MAX_K];                              // MAX_K = 32
for (int i = 0; i < K; i++) top_k[i] = REAL_MAX;

auto insert = [&](uint32_t idx) {
    RealT dist_sq = /* ... */;
    if (dist_sq < top_k[K - 1]) {                // reject fast: one compare
        top_k[K - 1] = dist_sq;
        for (int s = K - 2; s >= 0; s--) {       // bubble up one slot
            if (top_k[s + 1] < top_k[s]) { /* swap */ } else break;
        }
    }
};
```

Two things make this work, and both are fragile in a way worth understanding:

+ *The array must be indexed statically after unrolling.* A register is not
  addressable — there is no such thing as "register number `i`". The compiler
  can only keep `top_k` in registers if it fully unrolls every loop that
  touches it, turning `top_k[s]` into 32 distinct named values. Loops with
  compile-time trip counts (`K` is a runtime value here but bounded by
  `MAX_K`, and the inner loops are constant-bounded) permit that.
+ *If it fails, the array silently moves to "local" memory* — which despite
  the name is global memory, backed by DRAM. The code still works and gets
  several times slower. `nvcc -Xptxas -v` reports both the register count and
  any spill, and is the only way to know.

`ml_knn_stats_kernel` keeps `double topd[32]` (64 registers) plus
`uint32_t topi[32]` (32 more) live simultaneously — roughly 96 registers per
thread, giving 5 resident blocks per SM at 128 threads. That is a deliberate
trade: fewer resident warps, but zero global traffic for the neighbour list.

#lesson("shared memory and block reduction")[
  `__shared__` memory is a software-managed scratchpad, one allocation per
  block, visible to every thread in that block. Its classic use is reducing
  per-thread values to one per block before touching global memory.
  `chainKernel` in the reprojection stage does exactly this to compute the
  output bounding box:

  ```cpp
  __shared__ double sMin[3], sMax[3];       // src/filters/ReprojectFilter.cu
  __shared__ unsigned long long sFail;
  if (threadIdx.x == 0) { sMin[0] = HUGE_VAL; /* ... */ sFail = 0; }
  __syncthreads();                          // ALL threads wait here

  /* ... every thread transforms its point and atomically folds it into
         the block's sMin/sMax ... */

  __syncthreads();
  if (threadIdx.x == 0) {                   // one thread per block writes out
      atomicMinD(&bounds->minX, sMin[0]);   // 184 241 global atomics, not 23.6 M
  }
  ```

  `__syncthreads()` is a barrier for the block. It must be reached by *every*
  thread in the block — putting one inside a divergent `if` is undefined
  behaviour and a classic hang. Note how the guard `if (i < n)` in that kernel
  wraps only the *work*, not the barriers.
]

== Atomics

An atomic performs read-modify-write without interruption from other threads.
CUDA provides `atomicAdd`, `atomicMin`, `atomicMax`, `atomicCAS` and friends
for a fixed set of types. pcax uses them in three ways:

/ Counting: `atomicAdd(&sizes[label[tid]], 1)` in `cc_sizes` builds a
  cluster-size histogram in one pass.
/ Convergence flags: `*changed = 1` (a plain write, not even atomic — any
  thread setting it is enough) signals the host that another iteration is
  needed.
/ Types the hardware does not support: there is no `atomicMin` for `double`.
  pcax builds one out of `atomicCAS` on the bit pattern:

```cpp
__device__ void atomicMinD(double* addr, double val) {   // ReprojectFilter.cu
    unsigned long long* a = reinterpret_cast<unsigned long long*>(addr);
    unsigned long long old = *a, assumed;
    while (val < __longlong_as_double(old)) {   // only loop while we'd improve
        assumed = old;
        old = atomicCAS(a, assumed, __double_as_longlong(val));
        if (old == assumed) break;              // our exchange won
    }
}
```

This is the standard CAS retry loop: read, compute, attempt to swap, and
retry if someone else changed the value in between. `__longlong_as_double` is
a *bit reinterpretation*, not a conversion — it compiles to nothing.

#warn[
  *Atomics are a determinism hazard.* `atomicAdd` on floating point makes a
  kernel's result depend on thread scheduling order, because FP addition is
  not associative. pcax's documented parity tolerance for `filter.lloydkmeans`
  ("centroid FP differences — parallel sum order vs PDAL's sequential running
  mean") is exactly this effect. Where bit-exactness against PDAL matters,
  pcax reduces deterministically instead: `ml_noise`'s tile statistics use a
  sort plus an indexed read, never a float atomic.
]

== Errors, synchronisation, and timing

Because launches are asynchronous, a kernel's failure does not surface at the
launch. pcax handles this with one macro, defined identically in several
translation units:

```cpp
#define CUDA_CHECK(call) do {                                    \
    cudaError_t err = (call);                                     \
    if (err != cudaSuccess) {                                     \
        throw std::runtime_error(std::string("CUDA error: ") +    \
            cudaGetErrorString(err) + " at " +                    \
            __FILE__ + ":" + std::to_string(__LINE__));           \
    } } while(0)
```

Three usage rules follow, all visible in the codebase:

+ Wrap every *synchronous* API call: `cudaMalloc`, `cudaMemcpy`, `cudaFree`.
  These report their own failure immediately. This is where the OOM in
  `MlNoiseFilter.cu:689` came from.
+ After every *launch*, call `CUDA_CHECK(cudaGetLastError())` — it reports
  launch-configuration errors (too many threads, too much shared memory).
  pcax does this consistently.
+ Errors are *sticky*: once a context hits an error, most subsequent calls
  return it too. A retry loop must call `cudaGetLastError()` to clear the
  flag before trying again — which is why the chunk-size retry proposed in
  the memory case study does so explicitly.

Timing uses *events*, not host clocks, because host clocks would measure the
launch and not the work. pcax wraps a pair of events in an RAII object, so a
scope is a timed region:

```cpp
class GpuTimer {                              // src/filters/GpuTimer.cuh
    GpuTimer(const char* label) { cudaEventCreate(&m_start); /* ... */
                                  cudaEventRecord(m_start); }
    ~GpuTimer() { cudaEventRecord(m_stop);
                  cudaEventSynchronize(m_stop);       // blocks until done
                  cudaEventElapsedTime(&ms, m_start, m_stop);
                  Profiler::instance().add(/* label, ms, RAM, GPU bytes */); }
};

{ GpuTimer t("ml_noise: kNN + distance stats");       // ~ RAII scope
  ml_knn_stats_kernel<<<blocks, ML_BLOCK>>>(/* ... */); }
```

The destructor's `cudaEventSynchronize` is also the *only* place many pcax
kernels are waited on — which is why the profiler (`-d`) changes the shape of
the timeline it measures, and why the numbers are labelled snapshots rather
than a true profile.

== CUB and Thrust: not writing your own sort

CUB (CUDA UnBound) ships with the toolkit and provides device-wide primitives
that are far better tuned than hand-written equivalents. pcax uses four:

#figure(
  caption: [Device-wide primitives used in pcax and what each one is for.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, 1fr, auto),
    align: (left + horizon, left, left + horizon),
    table.header([*Primitive*], [*Used for*], [*Where*]),

    [`DeviceRadixSort::SortPairs`],
    [sort points by grid cell id; sort a feature column carrying point
     indices to produce percentile ranks],
    [`SpatialGrid.cuh`, \ `MlNoiseFilter.cu`],
    [`DeviceRadixSort::SortKeys`],
    [tile-wide medians / IQR / MAD via sort-then-index],
    [`MlNoiseFilter.cu`],
    [`DeviceScan::ExclusiveSum`],
    [turn per-cell counts into segment offsets for percentile extraction],
    [`GdalGpuWriter.cu`],
    [`DeviceSegmentedSort::SortKeys`],
    [sort each raster cell's values independently, in one launch, to read
     percentiles per cell],
    [`GdalGpuWriter.cu`],
  )
]

Every CUB call follows the same *two-call temp-storage idiom*, which is
unusual enough to trip up newcomers:

```cpp
void*  tmp   = nullptr;
size_t bytes = 0;
cub::DeviceRadixSort::SortPairs(tmp, bytes, d_keys, d_keysOut,   // call 1:
                                d_vals, d_valsOut, N);           //  tmp==null
                                                                 //  -> only
                                                                 //  sizes bytes
CUDA_CHECK(cudaMalloc(&tmp, bytes));                             // you allocate
cub::DeviceRadixSort::SortPairs(tmp, bytes, d_keys, d_keysOut,   // call 2:
                                d_vals, d_valsOut, N);           //  does the work
CUDA_CHECK(cudaFree(tmp));
```

CUB never allocates. The first call with a null pointer *queries* how much
scratch the algorithm needs; you allocate it and call again. This is why the
memory ledgers in this document and its companion have to estimate "CUB
scratch" rather than read it from the source — the number is computed at
runtime from $N$ and the key/value widths.

Thrust appears once, for a device-wide argmax with PDAL-matching tie-break:

```cpp
// FarthestPointSamplingFilter.cu — lowest-index tie-break == std::max_element
auto it = thrust::max_element(thrust::device_ptr<double>(d_minDist),
                              thrust::device_ptr<double>(d_minDist + N));
```

#lesson("CUDA 13 / CCCL migration")[
  CUDA 13 moved CUB, Thrust and libcu++ into the unified CCCL and removed
  long-deprecated pieces. Three break real code and bit this repository:

  - `cub::TransformInputIterator` is gone → use
    `cub::DeviceReduce::TransformReduce()` or `thrust::transform_iterator`.
  - `cub::Sum` is gone → use `::cuda::std::plus<>{}`.
  - Numeric limits in device code come from `<cuda/std/limits>`:
    `::cuda::std::numeric_limits<RealT>::max()`, as `SorFilter.cu` uses for
    its precision-templated sentinel.
]

== Iterative algorithms: the host-side convergence loop

Blocks cannot synchronise with each other, so an algorithm that must reach a
global fixed point cannot loop *inside* one kernel. The pattern instead is a
host loop launching one kernel per iteration, with a device flag copied back
each round. `filter.cluster` uses it for connected components:

```cpp
// label propagation: each component converges to its minimum point index
do {
    cudaMemset(d_changed, 0, sizeof(int));
    cc_propagate<<<blocks, CL_BLOCK>>>(/* ... */, d_label, d_changed);
    cc_compress<<<blocks, CL_BLOCK>>>(N, d_label);      // label[i] = label[label[i]]
    cudaMemcpy(&changed, d_changed, sizeof(int), cudaMemcpyDeviceToHost);
} while (changed);
```

Each `cc_propagate` pass lets every point adopt the smallest label in its
tolerance neighbourhood; `cc_compress` is pointer jumping, halving the
remaining chain depth per round. The same shape appears in `filter.dbscan`
(core-point propagation) and `filter.lloydkmeans` (assign / accumulate for a
fixed iteration count). The `cudaMemcpy` of a single `int` is a full
synchronisation point — cheap relative to the kernel, and the reason these
filters' timings are dominated by iteration *count*, not by work per
iteration.

== Templates for precision

A recurring pcax idiom is templating a kernel on the arithmetic type so one
source serves both precisions:

```cpp
template <typename RealT>                       // src/filters/SorFilter.cu
__global__ void knn_mean_dist(const float* __restrict__ px, /* ... */
                              RealT* __restrict__ mean_dist, /* ... */);
```

The *storage* is FP32 in both cases — only the distance accumulation, `sqrt`
and comparisons change. The host picks an instantiation at runtime from the
`precision` option. `__restrict__` on the pointer parameters is the other
half of the performance story: it promises the compiler that these arrays do
not alias, which is what allows loads to be hoisted and reordered across
stores.

The reprojection stage takes the same idea further, templating on `RealT` and
compiling the *identical source* for host and device (@sec-reproject), so the
CPU reference executor used by the accuracy tests is not a reimplementation
but the same lines of code.

#pagebreak()
= Data structures and C++ specifics <sec-datastructures>

== `DimArray` — one typed column

```cpp
class DimArray {                                    // include/pca/DimArray.hpp
public:
    DimArray(DimType type, size_t count);
    DimArray(DimArray&&) noexcept;                  // movable
    DimArray& operator=(DimArray&&) noexcept;
    DimArray(const DimArray&) = delete;             // NOT copyable
    DimArray& operator=(const DimArray&) = delete;

    template <typename T> T* as() { return static_cast<T*>(m_data); }
    size_t bytes() const { return m_count * dimTypeSize(m_type); }
private:
    void*   m_data  = nullptr;
    size_t  m_count = 0;
    DimType m_type  = DimType::None;
};
```

Three C++ decisions are packed into those twelve lines.

- *Type erasure with a runtime tag.* The buffer is `void*` plus a `DimType`.
  A template parameter would be cleaner but would make `PointCloud` a
  heterogeneous container — it must hold `UInt8`, `UInt16`, `Float32` and
  `Float64` columns in one map. The tag is checked at the boundary and then
  discarded: once a filter has called `as<float>()`, the inner loop is a raw
  `float*` with no dispatch. Contrast PDAL, where the type switch lives
  *inside* the accessor and runs per element.
- *Move-only, not copy-only.* Copying a 4 GiB column silently would be a
  performance bug, and deleting the copy constructor makes it a compile
  error. The consequence propagates: `PointCloud` owns `DimArray`s by value
  in a `std::map`, and is itself held by `unique_ptr` in the executor's
  cloud map.
- *Manual RAII.* `DimArray` allocates in its constructor and frees in its
  destructor, but stores `void*` rather than a smart pointer, because the
  element size is not known at compile time.

#nb[
  *A trap this codebase has hit.* `resize()` reallocates and zero-fills;
  `shrink()` truncates preserving data. They are not interchangeable, and
  using `resize()` where `shrink()` was meant silently zeroes a column. The
  same distinction appears one level up in `PointCloud`.
]

== `PointCloud` — the whole tile

```cpp
class PointCloud {                                // include/pca/PointCloud.hpp
    std::map<DimId, DimArray>   m_dims;           // the columns
    std::map<DimId, void*>      m_devicePtrs;     // device mirrors
    std::map<DimId, Residency>  m_residency;      // Host | Device | Both
    std::vector<char>           m_rawRecords;     // original LAS point records
    uint16_t                    m_rawRecordLen;
    LasMetadata                 m_metadata;       // scale/offset/minRaw/dataMin
    size_t                      m_count;
};
```

Four responsibilities live here, and they are worth separating.

=== Columns and the point count

`addDimension(id, type)` creates a column; `dimData<T>(id)` returns the raw
pointer. Three operations change the point count or order, and every filter
that alters membership must use exactly the right one:

#figure(
  caption: [The three point-set mutations. Choosing wrong corrupts the
  writer, because `LasWriter` asserts `rawRecordCount() == size()`.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, auto),
    align: (left + horizon, left, center + horizon),
    table.header([*Method*], [*Semantics*], [*Raw records*]),

    [`compact(keepMask)`],
    [drop points where mask is 0, preserving order; updates
     `metadata.pointCount`; frees device memory],
    [compacted too],
    [`shrink(count)`],
    [truncate to a prefix, preserving data],
    [truncated],
    [`reorder(perm)`],
    [permute in place, count unchanged — the gather sibling of `compact`,
     used by `filter.sort` and `filter.mortonorder`],
    [permuted too],
  )
]

=== Raw record passthrough

pcax keeps the *original LAS point records* alongside the decoded columns and
replays them on write, patching only what changed. This is how full fidelity
survives a pipeline that only understands a dozen dimensions: waveform data,
extra bytes, user-defined fields and NIR all round-trip untouched because
nobody ever decoded them.

It also creates the invariant that makes `compact()` mandatory: the writer
asserts one raw record per point. A filter that drops points by shrinking a
column and forgetting the records will fail loudly rather than write garbage
— a good example of a design that makes the dangerous thing hard.

=== Coordinates: relative FP32 over an FP64 origin

LAS stores $X$/$Y$/$Z$ as scaled integers: an `int32` raw value with per-file
`scale` and `offset`, where $"absolute" = "raw" times "scale" + "offset"$.
Absolute coordinates need up to eight significant digits; FP32 carries 7.2.
pcax's answer is to move the origin:

$ x_i^"rel" = ("raw"_i - "minRaw") times "scale" $

#figure(
  caption: [Coordinate representation, all three frameworks' choices side by
  side. pcax's relative FP32 gives 0.06 mm resolution over a 762 m tile at
  half the footprint of PDAL's decoded doubles.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, auto, auto, 1fr),
    align: (left + horizon, center + horizon, center + horizon, left),
    table.header([], [*Type*], [*B/pt (XYZ)*], [*Resolution over a 762 m tile*]),

    [LAS on disk], [`int32` + scale], [12], [exactly `scale` (1 mm here)],
    [PDAL in memory], [`double`], [24], [≈$10^(-10)$ m — far beyond the data],
    [pcax in memory], [`float` relative], [12], [$762 \/ 2^23 approx 0.09$ mm],
    [pcax if absolute], [`float`], [12], [$approx 0.5$ m — *unusable*],
  )
]

Two mechanisms guard the seams:

+ *Exact decode when it matters.* Predicate filters must agree with PDAL
  bit-for-bit, and PDAL compares against `raw × scale + offset` in `double`.
  `DimAccessor` (`include/pca/DimRange.hpp`) therefore decodes X/Y/Z straight
  from the raw records rather than from the FP32 column:
  ```cpp
  double at(size_t i) const {
      if (raw) {                                   // exact int32 path
          int32_t v; std::memcpy(&v, raw + i * stride + byteOff, 4);
          return v * scale + offset;               // bit-identical to PDAL
      }
      /* ... fall back to relative FP32 + dataMin ... */
  }
  ```
+ *A dirty flag for when it cannot.* Once a stage rewrites coordinates
  (`filter.reproject`, `filter.transformation`), the raw records hold stale
  values. Such a stage must set `metadata.coordsDirty = true` and renormalise
  (`offset == dataMin`, `minRaw == 0`); `DimAccessor` then refuses the raw
  path. This is a genuine sharp edge — a new coordinate-rewriting filter that
  forgets the flag produces subtly wrong range comparisons, not a crash.

=== Residency

```cpp
enum class Residency : uint8_t { Host, Device, Both };
void ensureDevice(DimId id);   // upload if Host
void ensureHost(DimId id);     // download if Device
void* devicePtr(DimId id);
```

`uploadToDevice` (`src/core/PointCloudGPU.cu`) does a `cudaMalloc` on first
use, a blocking `cudaMemcpy`, and marks the column `Both`. There is no pinned
host memory and no asynchronous copy — transfers are synchronous and the
device allocation is cached for the process lifetime of the cloud.

#warn[
  *Two costs are visible here.* Pageable-memory `cudaMemcpy` runs at roughly
  half the bandwidth of pinned memory and cannot overlap with compute; and
  `Residency::Both` never invalidates, so a kernel that writes a device
  buffer must call `setResidency(id, Residency::Device)` explicitly or the
  next `ensureHost` will decide the host copy is already current and skip the
  download. `ml_noise` does this correctly for `Classification`; it is
  another sharp edge for new filters.
]

== C++ patterns worth knowing before editing

=== Self-registering stages

```cpp
struct StageRegistrar {                        // include/pca/StageFactory.hpp
    StageRegistrar(const std::string& typeName, StageFactory::Creator creator) {
        StageFactory::instance().registerStage(typeName, std::move(creator));
    }
};
#define PCA_REGISTER_STAGE(cls, type_str)                                \
    static ::pca::StageRegistrar s_registrar_##cls(                      \
        type_str, []() -> std::unique_ptr<::pca::Stage> {                \
            return std::make_unique<cls>(); })
```

A file-scope static object whose *constructor* performs the registration:
the type name appears in one place, next to the class. The catch is that a
static object in a static library is only initialised if the linker keeps
its translation unit — and nothing references it. Hence:

```cmake
target_link_libraries(pcax PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,pca_core>")
```

Without `WHOLE_ARCHIVE`, half the stage table silently disappears and
pipelines fail with "unknown stage type". This is the single most confusing
build-level failure mode in the project, and it is why every test executable
repeats the same generator expression.

#figure(
  caption: [PDAL solves the same problem differently, and the trade is
  visible in the failure modes.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [#tPcax], [#tPdal]),

    [mechanism], [static `StageRegistrar` + `WHOLE_ARCHIVE`],
      [`PluginManager` + `CREATE_STATIC_STAGE` / shared-object discovery],
    [when], [program load], [`PluginDirectory` scan at first use],
    [adding a stage], [edit `CMakeLists.txt`, recompile],
      [drop a `.so` in the plugin path],
    [failure mode], [stage silently missing if `WHOLE_ARCHIVE` is dropped],
      [stage silently missing if the `.so` is not found],
  )
]

=== Options are strings

`StageOptions` is a `map<string,string>` with typed getters
(`getInt`, `getDouble`, `getBool`). There is no schema, no validation of
unknown keys, and no help text. PDAL's `ProgramArgs`/`addArgs` registers each
option with a type, a default and a description, which is what makes
`pdal --options filters.smrf` possible. This is a real ergonomics gap in
pcax and a candidate for future work; today a typo in a YAML option key is
silently ignored.

=== `device:` is both a hint and an option

The YAML key `device:` sets `StageNode::device`, which the executor uses to
decide residency — *and* is passed through into `StageOptions`, because
`filter.reproject` reads `device: cpu` to force the host PROJ executor. Any
refactor of `Pipeline.cpp` must preserve both paths.

=== The thread pool

`include/pca/ThreadPool.hpp` is a 60-line textbook pool: a mutex, a condition
variable, a `std::queue<std::function<void()>>`, and an `enqueue` returning a
`std::future` via `std::packaged_task`. It exists for two purposes — parallel
LAZ chunk I/O and chunked CPU filters — and deliberately does no work
stealing, no priorities, and no affinity.

#pagebreak()
= The pipeline executor

== YAML to DAG to linear execution

```yaml
stages:
  read:      { type: read.las, filename: "${input}" }
  denoise:   { type: filter.outlier, input: read, device: gpu, k: 8 }
  write:     { type: write.las, input: denoise, filename: "${output}" }
```

`Pipeline::fromYAML` parses stages, substitutes `${var}` from the `vars:`
block and `-v key=val` overrides, instantiates each stage through the
factory, and builds the dependency graph. Ordering is Kahn's algorithm:

```cpp
for (size_t i = 0; i < n; i++)                       // src/core/Pipeline.cpp
    for (auto& inputName : m_stages[i].inputs) {
        dependents[m_nameToIndex[inputName]].push_back(i);
        inDegree[i]++;
    }
std::queue<size_t> ready;                            // in-degree 0 first
/* ... pop, emit, decrement dependents ... */
if (m_executionOrder.size() != n)
    throw std::runtime_error("Pipeline has a cycle in stage dependencies");
```

Then comes the design's central compromise:

#warn[
  *The graph is topologically sorted but linearly executed.* Every stage
  operates on the same `m_clouds["default"]`. The `input:` edges determine
  *order*, not *dataflow* — two stages naming different inputs still see the
  same single cloud. This is invisible for the linear pipelines pcax targets
  and would be actively wrong for a diamond. Porting `filters.merge` requires
  a multi-cloud executor first, and that is the largest single architectural
  gap versus PDAL.
]

== Preparation and residency

`prepare()` runs `addDimensions()` on every stage so the schema is complete,
then `prepared()` so stages can inspect the final schema. `execute()` then
loops in topological order, calling `ensureResidency` before each stage:

```cpp
bool needGpu = (node.device == ExecutionTarget::GPU) ||
               (node.stage->executionTarget() == ExecutionTarget::GPU);
if (needGpu)  for (auto& [id, arr] : cloud.dims()) cloud.ensureDevice(id);
else          for (auto& [id, arr] : cloud.dims())
                  if (cloud.residency(id) == Residency::Device) cloud.ensureHost(id);
```

This is correct and coarse. It uploads *every* dimension for a GPU stage
because `Stage` has no way to declare what it reads: for a format-6 tile that
is 33 B/point where `filter.ml_noise` uses 21, and it round-trips columns
across PCIe whenever the pipeline alternates CPU and GPU stages. A
`requiredDims()` hook is the obvious fix and is discussed in @sec-limits.

#figure(
  caption: [Executor comparison. PDAL's model is strictly more expressive;
  pcax's is strictly cheaper.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [#tPcax], [#tPdal]),

    [pipeline language], [YAML, named stages, `${var}` substitution],
      [JSON, array or object form, `--stage.x.opt=` overrides],
    [graph], [DAG, topo-sorted, *executed linearly over one cloud*],
      [true DAG; each stage returns a `PointViewSet`],
    [branch / merge], [not supported], [`filters.merge`, `splitter`, `chipper`,
      `divider`],
    [streaming], [none — whole tile in RAM],
      [`Streamable::processOne`, fixed-capacity `StreamPointTable`],
    [parallelism], [thread pool for I/O + chunked CPU filters; GPU for the rest],
      [none within a stage],
    [per-stage timing], [built-in profiler tree (`-d`), CUDA events for GPU],
      [`--metadata`, external timing],
  )
]

#pagebreak()
= The spatial index <sec-grid>

Almost every expensive stage in either framework is a neighbourhood query.
The choice of index is therefore the single most consequential algorithmic
decision below the data model, and the two frameworks choose differently.

== KD-tree versus uniform grid #h(1fr) #tPdal #tPcax

#figure(
  caption: [Index comparison. The grid wins on GPU not because it is a better
  index, but because it is a better *parallel* index: construction is two
  data-parallel passes, and traversal has no pointer chasing and no stack.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [#tPdal `KD3Index` (nanoflann)],
      [#tPcax `grid::DeviceGrid`]),

    [structure], [balanced binary tree over point ids],
      [flat array of points sorted by cell + `cellStart`/`cellEnd`],
    [build], [$O(N log N)$, recursive, sequential],
      [$O(N)$ + one radix sort; two kernels],
    [query], [descend + backtrack with a priority queue],
      [expand square rings of cells until a bound is met],
    [adapts to density], [yes — splits where points are],
      [no — one global cell size from mean density],
    [GPU friendliness], [poor: per-thread stack, divergent traversal,
      pointer chasing], [good: no stack, coalesced cell reads, uniform work],
    [memory], [≈$N$ ids + tree nodes], [8 B/point + $2 times$ cells],
  )
]

== Construction

```cpp
void DeviceGrid::build(const float* d_px, const float* d_py, int n,
                       const GridParams& p) {           // SpatialGrid.cuh
    compute_cell_indices<<<blocks, 256>>>(d_px, d_py,   // 1. cell id per point
                                          d_cellIndices, d_pointIndices, n, p);
    cub::DeviceRadixSort::SortPairs(tmp, bytes, d_cellIndices, sortedCells,
                                    d_pointIndices, sortedIndices, n);  // 2.
    find_cell_boundaries<<<blocks, 256>>>(sortedCells, cellStart, cellEnd, n);
}                                                       // 3. run boundaries
```

`find_cell_boundaries` is a neat data-parallel idiom worth internalising —
finding the start and end of every run in a sorted array without any
communication between threads:

```cpp
uint32_t cell = cell_indices_sorted[i];
if (i == 0     || cell != cell_indices_sorted[i - 1]) cell_start[cell] = i;
if (i == N - 1 || cell != cell_indices_sorted[i + 1]) cell_end[cell]   = i + 1;
```

Each thread compares only with its immediate neighbours; a thread at a
boundary writes it. Empty cells keep the zero-initialised `start == end == 0`
and are skipped by the `end <= start` test at query time.

Cell size is derived from mean spacing, so a cell holds about 16 points:

$ "cellSize" = 4 sqrt("area"_(x y) \/ N) $

== Exact kNN by expanding rings

The termination argument is the part that makes this an exact algorithm
rather than an approximation, and it is easy to get subtly wrong:

#nb[
  *The ring bound.* Cells at Chebyshev distance $d$ from the query cell
  contain no point closer than $(d - 1) dot c$ in XY, where $c$ is the cell
  size (the $-1$ because the query point may sit anywhere within its own
  cell). Because 3-D distance is at least XY distance, once the current
  $K$-th best distance satisfies $sqrt(d_K^2) <= d dot c$, no unvisited point
  can displace it. The search stops, and the result is *exactly* the
  $K$ nearest neighbours — the same set nanoflann returns.
]

```cpp
for (int d = 0; d <= maxRing; d++) {                  // SorFilter.cu
    grid::forEachRingNeighbor(cx, cy, d, p, cell_start, cell_end,
                              sorted_indices, insert);
    if (top_k[K - 1] < REAL_MAX &&
        sqrt(top_k[K - 1]) <= static_cast<RealT>(d) * cs) break;
}
```

`forEachRingNeighbor` visits *only the perimeter* of the square at distance
$d$, using a stride trick so interior rows skip their middles:

```cpp
int stepX = (dy == -r || dy == r) ? 1 : (r > 0 ? 2 * r : 1);
```

For the top and bottom rows of the ring, step by 1 (visit all); for the
middle rows, step by $2r$ (visit only the two edges). Without this, each ring
would re-scan everything inside it and the search would be $O(d^2)$ per ring
instead of $O(d)$.

#warn[
  *A bug this project has already made and fixed.* An earlier SOR
  implementation used a fixed radius and marked points without $K$ neighbours
  as isolated (`FLT_MAX`). That over-flagged sparse-but-valid points relative
  to PDAL's unbounded KD-tree and caused a visible DSM/DTM divergence in the
  Everglades pipeline. The current code searches unboundedly by default; the
  bounded mode survives only as an opt-in `search_radius` option, explicitly
  documented as *departing* from PDAL semantics. Cost of correctness:
  roughly 12× slower kNN on sparse tiles.
]

== The shared neighbourhood library

`src/filters/NeighborhoodMath.cuh` holds the five device functions that every
neighbourhood filter calls, so that ten filters share one bit-identical
implementation rather than ten near-copies:

#figure(
  caption: [`NeighborhoodMath.cuh` — the shared device library. Keeping one
  copy is what lets a dozen filters stay in lock-step with PDAL's
  `math::computeCovariance` + Eigen `SelfAdjointEigenSolver` results.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(
    columns: (auto, 1fr),
    align: (left + horizon, left),
    table.header([*Function*], [*What it does*]),

    [`knn3d`], [expanding-ring exact $K$-NN; fills `topd`/`topi`, returns the
      found count],
    [`neighborhoodCovariance`], [PDAL-style $3 times 3$ covariance from an
      explicit id list],
    [`eigen3x3`], [cyclic Jacobi eigendecomposition in `double`; eigenvalues
      ascending, eigenvectors in columns of `V`],
    [`radiusCount`], [count of neighbours within a radius (single ring pass)],
    [`radiusCovariance`], [covariance over a radius neighbourhood],
  )
]

The covariance routine deserves a close read, because its *mixed precision is
deliberate* and copying PDAL exactly is the whole point:

```cpp
double mx = 0, my = 0, mz = 0;
for (int j = 0; j < n; j++) {                  // Welford running mean, double
    double k = j + 1;
    mx += (px[i] - mx) / k;  /* ... */
}
for (int j = 0; j < n; j++) {
    float rx = static_cast<float>(px[i] - mx);      // residual DEMOTED to float
    A[0][0] += static_cast<double>(rx) * rx;        // outer product in double
    /* ... */
}
double inv = 1.0 / (n - 1);                    // sample covariance, not n
```

The centroid accumulates in `double` by Welford's method; the residuals are
then *demoted to `float`* before the outer product, which is promoted back to
`double`. No numerical analyst would design this. It is what
`pdal::math::computeCovariance` does, and reproducing it — including the
demotion — is what keeps `filter.normal` and its nine relatives matching PDAL
to $10^(-6)$ instead of drifting at the last bits.

#pagebreak()
= The kernel tour <sec-kernels>

pcax ships *62 CUDA kernels* across 18 translation units. This part walks the
53 filter, reprojection and raster kernels, grouped by the pattern they share;
the 9 COPC octree kernels are covered with the writer in @sec-copc and all 62
are indexed in Appendix A. For each family: what it computes,
how threads map to data, and what its PDAL counterpart does.

== Family 1 — the spatial grid (2 kernels)

#figure(kind: table, supplement: [Table], caption: [`src/filters/SpatialGrid.cuh`])[
  #set text(8.3pt)
  #table(columns: (auto, auto, 1fr),
    align: (left + horizon, center + horizon, left),
    table.header([*Kernel*], [*Thread ↦*], [*Notes*]),
    [`compute_cell_indices`], [point],
      [`cx + cy * nx` into `cell_indices[i]`, identity into `point_indices[i]`],
    [`find_cell_boundaries`], [sorted slot],
      [neighbour-compare run detection; empty cells stay `0,0`],
  )
]

== Family 2 — statistical outlier removal (2 kernels)

`filter.outlier`, pcax's oldest GPU stage and its cleanest.

```cpp
template <typename RealT> __global__ void knn_mean_dist(/* ... */);
template <typename RealT> __global__ void classify_outliers(/* ... */);
```

Thread ↦ point. The first computes each point's mean distance to its $K$
nearest neighbours (top-$K$ in registers, expanding rings); the host then
reduces mean and standard deviation over all points — with the $N-1$
denominator, matching PDAL — and the second kernel flags
$overline(d)_i >= mu + m sigma$ as class 7. The `>=` is deliberate: PDAL's
test is `>=`, and getting it backwards changes the flagged set at ties.

Both kernels are templated on `RealT`, so `precision: fp64` changes only the
distance arithmetic. On real tiles the two precisions produce bit-identical
flagged sets, which is itself a useful result: the FP32 *storage* dominates,
not the FP32 *arithmetic*.

== Family 3 — covariance and eigenfeatures (10 kernels)

The largest family, and the one where PDAL parity is most delicate. All of
these are thread ↦ point, all call `knn3d` then `neighborhoodCovariance` then
`eigen3x3`, and all differ only in what they do with the eigenvalues
$lambda_1 >= lambda_2 >= lambda_3$ and eigenvectors.

#figure(
  caption: [The eigenfeature family. Every one of these is a PDAL filter port
  with a documented near-tie tolerance; see @sec-parity.],
  kind: table, supplement: [Table],
)[
  #set text(8.2pt)
  #table(
    columns: (auto, auto, 1fr),
    align: (left + horizon, left, left),
    table.header([*Kernel*], [*Stage*], [*Output*]),

    [`normal_kernel`], [`filter.normal`],
      [`NormalX/Y/Z` = eigenvector of $lambda_3$; `Curvature` =
       $lambda_3 \/ sum lambda$],
    [`eigenvalues_kernel`], [`filter.eigenvalues`], [`Eigenvalue0..2`],
    [`covfeat_kernel`], [`filter.covariancefeatures`],
      [11 features: linearity, planarity, scattering, verticality,
       omnivariance, anisotropy, eigenentropy, eigenvalue sum, surface
       variation, Demantké verticality, density],
    [`optneigh_kernel`], [`filter.optimalneighborhood`],
      [`OptimalKNN` = $arg min_k$ eigenentropy over $k in ["min_k", "max_k"]$;
       `OptimalRadius`],
    [`coplanar_kernel`], [`filter.approximatecoplanar`],
      [`Coplanar` 0/1 from an eigenvalue-ratio test],
    [`planefit_kernel`], [`filter.planefit`],
      [mean point-to-plane distance over the kNN neighbourhood],
    [`rank_kernel`], [`filter.estimaterank`],
      [SVD rank of the covariance: 1 = line, 2 = plane, 3 = volume],
    [`radialdensity_kernel`], [`filter.radialdensity`],
      [`radiusCount` normalised by sphere volume — no eigensolver],
    [`nndistance_kernel`], [`filter.nndistance`],
      [$k$-th or mean neighbour distance],
    [`reciprocity_kernel`], [`filter.reciprocity`],
      [% of a point's kNN that do *not* list it back — a kNN-of-kNN, and
       PDAL's single most expensive filter (pcax is ≈76× faster)],
  )
]

`optneigh_kernel` is the one that departs from the shared covariance routine,
and the comment in the source explains why: it accumulates an *incremental
Welford covariance in full double over `max_k` neighbours* — not the
float-residual `computeCovariance` — because that is what PDAL's
`filters.optimalneighborhood` does, and the entropy argmin is sensitive
enough that the difference is visible.

== Family 4 — height above ground and classification (2 kernels)

/ `hag_nn_kernel` (`filter.hag_nn`): thread ↦ non-ground point. The host
  first gathers the ground-classified subset into its own arrays and builds a
  grid *over the ground points only*; each thread then finds its nearest
  ground returns and interpolates. Splitting the index this way is what makes
  the query cheap — the alternative, filtering inside the kernel, would waste
  most of every cell read.
/ `neighborclassifier_kernel` (`filter.neighborclassifier`): thread ↦ point;
  kNN majority vote over neighbour classifications with a strict-majority
  rule and an optional domain restriction. Exact versus PDAL (0 differences
  in 2.6 M points), because the vote is over integers — no floating-point
  ties to break.

== Family 5 — local outlier factor (3 kernels)

`filter.lof` is the clearest example of a *multi-pass* GPU algorithm where
each pass depends on the previous pass's output for *other* points, not just
its own:

#figure(
  caption: [The three LOF passes. Pass 2 needs pass 1's result for the
  query's neighbours, and pass 3 needs pass 2's — so they cannot be fused,
  and the neighbour indices must be cached between them.],
  kind: image, supplement: [Figure],
)[
  #set text(8.3pt)
  #box(width: 100%)[
    #grid(columns: (1fr, auto, 1fr, auto, 1fr), column-gutter: 6pt,
      align: horizon + center,
      dbox(fill: cCuda.lighten(88%))[
        *`lof_pass1`* \ $k$-distance \
        #text(7.5pt)[`NNDistance(i)` = dist to \ the $m$-th neighbour;
        cache the $m$ ids]
      ],
      rarr,
      dbox(fill: cCuda.lighten(92%))[
        *`lof_pass2`* \ local reachability \
        #text(7.5pt)[$"lrd"(i) = 1 \/ overline("reachdist")(i,j)$, \
        $"reachdist" = max("NNDist"(j), d(i,j))$]
      ],
      rarr,
      dbox(fill: cCuda.lighten(96%))[
        *`lof_pass3`* \ the factor \
        #text(7.5pt)[$"LOF"(i) = overline("lrd"(j)) \/ "lrd"(i)$]
      ],
    )
  ]
]

Two details are worth copying in any similar port. Distances are
*recomputed* in pass 2 from the FP32 coordinates rather than cached — the
result is identical to what `knn3d` produced, and it trades a little
arithmetic for $N times m$ floats of memory not allocated. And all three means
use Welford's running form over all $m$ entries including self, bit-for-bit
as PDAL's `knnSearch` does.

== Family 6 — clustering (13 kernels)

Four stages, all built on the host-side convergence loop from the primer.

#figure(
  caption: [The clustering kernels. `cluster` and `dbscan` share the
  min-label-propagation core; `fps` and `lloydkmeans` share the FPS
  initialisation.],
  kind: table, supplement: [Table],
)[
  #set text(8.2pt)
  #table(
    columns: (auto, 1.05fr, 1.45fr),
    align: (left + horizon, left, left),
    table.header([*Stage*], [*Kernels*], [*Algorithm*]),

    [`filter.cluster`], [`cc_propagate`, `cc_compress`, `cc_sizes`],
      [connected components by min-label propagation over the tolerance graph;
       `cc_compress` is pointer jumping (`label[i] = label[label[i]]`); the
       host then ranks size-filtered components by ascending representative to
       reproduce PDAL's seed-discovery order],
    [`filter.dbscan`], [`db_core`, `db_propagate`, `db_compress`, `db_assign`],
      [(1) neighbour count → core flag; (2) min-label propagation *among core
       points only*; (3) border points adopt the minimum core-neighbour label,
       the rest become noise ($-1$)],
    [`filter.fps`], [`fps_dist_init`, `fps_dist_update`],
      [greedy farthest-point sampling, *brute force with no grid*: seed at
       point 0, then repeatedly `thrust::max_element` the min-distance array
       and update it. ≈2000× faster than PDAL and an exact set match],
    [`filter.lloydkmeans`], [`km_dist_init`, `km_dist_update`, `km_assign`,
      `km_accum`],
      [FPS initialisation (deterministic — PDAL uses the same), then assign /
       accumulate for `maxiters` rounds; empty clusters move to the origin,
       matching PDAL],
  )
]

#nb[
  *Why `filter.fps` gets a 2000× speedup and `filter.cluster` only 3×.*
  FPS is $O(N)$ work per iteration with perfect parallelism and no index —
  precisely the shape a GPU is built for, while PDAL runs the same $O(N k)$
  loop serially. Connected components, by contrast, needs several
  propagate/compress rounds whose count depends on the *diameter* of the
  cluster graph, and each round re-walks the grid. The lesson generalises:
  the speedup a stage gets is governed by how much of its work is independent
  per point, not by how expensive it is.
]

== Family 7 — machine-learned noise (13 kernels)

`filter.ml_noise` computes 48 per-point features and evaluates a 4 998-tree
LightGBM ensemble. Its kernels are covered in depth in the companion document
`docs/MlNoiseGpuMemory.typ`, including a full memory analysis; in brief:

#figure(kind: table, supplement: [Table], caption: [`src/filters/MlNoiseFilter.cu`])[
  #set text(8.2pt)
  #table(columns: (auto, 1fr),
    align: (left + horizon, left),
    table.header([*Group*], [*Kernels*]),
    [neighbourhood], [`ml_knn_stats_kernel` — exact 32-NN plus *both* the 14
      distance / intensity / return features and the $k = 16$ / $k = 32$
      eigenfeatures, all from registers in one pass (see @sec-fusion)],
    [cell statistics], [`ml_cell_keys_kernel`, `ml_cell_bounds_kernel`,
      `ml_cell_pct_kernel`, `ml_cell_scatter_kernel` — per-cell $z$
      percentiles at 10 m and 25 m],
    [tile statistics], [`ml_zabs_kernel`, `ml_u16_to_f32_kernel`,
      `ml_absdev_kernel`, `ml_gather_col_kernel`, `ml_iota_kernel`,
      `ml_rank_scatter_kernel` — medians, IQR, MAD, percentile ranks],
    [finish], [`ml_finalize_kernel` (normalisation + derived copies),
      `ml_infer_kernel` (tree traversal, thread ↦ point, all 4 998 trees)],
  )
]

Two techniques from this file are reusable elsewhere. The *composite sort
key* `(cellId << 32) | orderFloat(z)` sorts by cell and, within each cell, by
$z$ in a single radix sort — `orderFloat` being the standard IEEE-754
total-order bit transform. And `ml_infer_kernel` demonstrates that irregular,
branch-heavy work (walking a decision tree) *does* run acceptably on a GPU
when there is enough of it: warp divergence is severe, but 23.6 M independent
traversals still saturate the machine.

== Kernel fusion, worked through <sec-fusion>

`filter.ml_noise` used to run the search and the eigenfeatures as two
kernels, handing an $N times 32$ table of neighbour identities between them
through global memory. On a 23.6 M-point tile that table is 2.8 GiB, and it
sat alongside the 4.2 GiB feature matrix, putting the stage's peak at 8.3 GiB
— more than an 11 GiB card shared with any other process can give. It is
worth walking through why that table existed and why it did not have to,
because the reasoning transfers to any two-kernel neighbourhood pipeline.

*The table was a cache of a pure function.* A point's 32 nearest neighbours
are determined entirely by the coordinates and the grid — both already
resident, at 20 B/point. Spending 128 B/point to remember a result derivable
from 20 B/point is only worth it if you read it many times, or out of order.
Here it was read exactly once, immediately, in order.

*The obstacle was register pressure, not correctness.* At the end of the
search the neighbour ids are in registers. The naïve fusion — paste the eigen
kernel's body on the end — also inherits its `float nx/ny/nz[32]` staging
array, 96 registers of neighbour coordinates on top of everything the search
already holds. Past the hardware limit, the surplus spills to local memory,
which is global memory again: you would trade a buffer for a slower kernel.

*The fix is to stream the covariance instead of staging it.* Sweep the
neighbour list twice — once accumulating the centroid, once accumulating the
outer products against it — fetching each neighbour's coordinates from
`px/py/pz` on both sweeps and holding none. Those coordinates were just read
by the search, so they are cache-resident; the re-read is close to free. The
live register set stays where the search alone put it.

#figure(
  caption: [Measured effect of the fusion (RTX 2080 Ti, three Santa Clara
  tiles, best of two runs each). The speed change is inside the noise; the
  memory change is the point. Registers: 213 (old search) and 217 (old eigen)
  → 218 fused, no spill, so occupancy is unchanged.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, auto, auto, auto, auto, auto),
    align: (left + horizon, right + horizon, right + horizon, right + horizon,
            right + horizon, right + horizon),
    table.header([*tile*], [*points*], [*peak old*], [*peak new*],
      [*kernel(s) old*], [*fused new*]),
    [27259750], [23.58 M], [8316 MB], [5436 MB], [23012 ms], [22856 ms],
    [27509750], [23.26 M], [8214 MB], [5374 MB], [24261 ms], [23927 ms],
    [27759900], [22.08 M], [7806 MB], [5110 MB], [21248 ms], [20965 ms],
  )
]

*The result is bit-identical*, not merely equivalent: accumulation order,
promotions and the $k$ divisor are unchanged, so the $N times 48$ feature
matrix dumped from both binaries has the same md5. That is the property to
insist on when fusing — if a fusion changes results, it has changed the
arithmetic, and the change should be justified on its own terms rather than
smuggled in.

Two lessons generalise. *A buffer written by one kernel and read only by the
next is usually a missing fusion, not a necessary allocation.* And *the
memory win is often larger than the speed win* — here the stage is dominated
by the search itself (≈22 s) and tree inference (≈18 s), so removing 6 GiB of
traffic bought about 1%. Peak memory fell by a third. Full analysis and the
allocation ledger: `docs/MlNoiseGpuMemory.typ`; measurements: docs/Parity.md.

== Family 8 — reprojection (2 kernels) and rasterization (6 kernels)

These two are architecturally distinct enough to get their own parts:
@sec-reproject and @sec-gdal.

#pagebreak()
= Reprojection: PROJ on the GPU <sec-reproject>

`filter.reproject` is the most architecturally interesting stage in pcax,
because it does something that sounds impossible: it runs PROJ's coordinate
math on a GPU without porting PROJ.

== The insight: PROJ is two programs

#nb[
  PROJ is a *planner* and an *executor* wearing one name. The planner reads
  `proj.db`, ranks candidate coordinate operations for a given source CRS,
  target CRS and area of interest, resolves grid files, and emits a pipeline
  string — a few hundred microseconds, once. The executor evaluates that
  pipeline per point — hundreds of millions of times. Only the second half
  needs to be on the GPU, and the second half is a few thousand lines of
  closed-form mathematics with no database, no I/O and no allocation.
]

pcax links real libproj for planning and compiles the resulting pipeline into
GPU op descriptors:

#figure(
  caption: [The reprojection pipeline. `proj.db` is never ported; the planner
  runs once on the host and produces a flat array of `OpDesc` structs with all
  coefficients precomputed in FP64.],
  kind: image, supplement: [Figure],
)[
  #set text(8.2pt)
  #box(width: 100%)[
    #stack(dir: ttb, spacing: 5pt,
      grid(columns: (1fr, auto, 1fr, auto, 1fr), column-gutter: 5pt,
        align: horizon + center,
        dbox(fill: cAlt.lighten(88%))[
          *libproj planner* (host) \
          #text(7.5pt)[`proj_create_operations()` \ · bbox as area of interest]
        ],
        rarr,
        dbox(fill: cAlt.lighten(92%))[
          *PROJ pipeline string* \
          #text(7.5pt)[`+step +inv +proj=lcc ...` \ normalised to GIS axis order]
        ],
        rarr,
        dbox(fill: cAlt.lighten(96%))[
          *`compileSteps`* \
          #text(7.5pt)[one `OpDesc` per `+step`; \ coefficients in FP64]
        ],
      ),
      align(center)[#text(11pt, fill: luma(130))[$arrow.b$]],
      grid(columns: (1fr, auto, 1fr), column-gutter: 5pt,
        align: horizon + center,
        dbox(fill: cCuda.lighten(88%))[
          *`chainKernel`* (device) \
          #text(7.5pt)[denormalise → walk the op chain in registers →
          block-reduce bounds]
        ],
        rarr,
        dbox(fill: cCuda.lighten(93%))[
          *`renormKernel`* \
          #text(7.5pt)[absolute → relative FP32 \ against the new origin]
        ],
      ),
    )
  ]
]

== The op set

```cpp
enum class OpType : int32_t {            // include/pca/reproj/Plan.hpp
    Noop, AxisSwap, UnitConvert, Cart, Helmert, Tmerc, Merc, Webmerc,
    Lcc, Aea, HGridShift, VGridShift, PushV, PopV,
};
struct OpDesc {
    OpType  type;  int32_t inverse;            // +inv on this step
    double  a, es, one_es;                     // ellipsoid
    double  p[32];  int32_t ip[8];             // per-op parameter slots
};
```

Fixed-size parameter slots rather than a variant or a virtual hierarchy —
because `OpDesc` must be memcpy-able to the device and readable by a kernel
with no pointer chasing. Slots 26–30 are a shared "projection frame"
(`lam0`, `x0`, `y0`, `k0`, `fr_meter`) mirroring PROJ's generic
forward/inverse wrapper, so every projection op can be entered and left
uniformly.

A pipeline containing a step outside this set — `omerc`, time-dependent
transforms needing per-point epochs — sets `gpuCompatible = false` with a
reason, and the stage falls back to host PROJ, multithreaded over the SoA
arrays.

#warn[
  *The fallback is never silent.* This is a deliberate operational decision
  worth copying. Whenever the stage does not use the GPU op chain it logs
  `[WARN] reproject: NOT using the GPU op-chain — falling back to host PROJ
  (CPU, FP64). Reason: …` naming the cause, and when it does it logs the
  matching `[INFO] … running on the GPU op-chain (fp64|fp32)`. A runtime CUDA
  failure does *not* fall back — it aborts, so a real GPU problem can never
  be mistaken for a slow day.
]

== One implementation, two compilers

The op math lives in `src/reproj/OpsImpl.hpp` and is compiled *twice*: by
`nvcc` into the kernel, and by the host compiler into the CPU reference
executor the accuracy tests compare against.

```cpp
#if defined(__CUDACC__)
#define PCA_HD __host__ __device__ __forceinline__
#else
#define PCA_HD inline
using std::sin; using std::cos; /* ... */   // pick up the float overloads
#endif

template <typename T> struct Eps;                  // precision-dependent
template <> struct Eps<double> { static constexpr double phi2 = 1e-15;
                                 static constexpr int iters = 15; };
template <> struct Eps<float>  { static constexpr float  phi2 = 1e-7f;
                                 static constexpr int iters = 8; };

template <typename T> PCA_HD bool opTmerc(const OpDesc& op, T& x, T& y, T& z);
```

Three C++ techniques are doing real work here:

+ *`PCA_HD` dual compilation.* The CPU reference is not a reimplementation —
  it is the same tokens. A test that finds a discrepancy has found a
  hardware or precision difference, never a transcription error.
+ *Traits for precision-dependent constants.* Convergence tolerances and
  iteration caps cannot be shared between `float` and `double`; a
  specialised `Eps<T>` keeps them next to each other instead of scattered
  through `if constexpr`.
+ *The `using std::sin` block.* Under host compilation, an unqualified
  `sin(x)` on a `float` would find C's `::sin(double)` and silently promote,
  breaking the FP32 instantiation. Pulling the `std` overloads into scope
  makes overload resolution pick `std::sin(float)`. This is a genuinely
  obscure trap and the comment in the source says so.

The transverse Mercator implementation is the exact Poder/Engsager algorithm
PROJ uses in `tmerc.cpp`, including its Clenshaw complex summation — chosen
so results can be validated against libproj rather than merely be close.

== The fused kernel

```cpp
template <typename T> __global__ void chainKernel(
    const float* relX, /* ... */, double dataMinX, /* ... */,
    const OpDesc* ops, int nops, const GridData* grids,
    T* absX, T* absY, T* absZ, uint8_t* mask, DevBounds* bounds, size_t n)
{
    T x = T(dataMinX) + T(relX[i]);              // denormalise to absolute
    T y = T(dataMinY) + T(relY[i]);
    T z = T(dataMinZ) + T(relZ[i]);
    bool ok = execChain<T>(ops, nops, grids, x, y, z);   // ENTIRE pipeline,
    ok = ok && isfinite(x) && isfinite(y) && isfinite(z);// in registers
    /* ... write out, mask failures, fold into shared-memory bounds ... */
}
```

The whole coordinate operation — axis swap, unit conversion, inverse
projection, geocentric conversion, Helmert, grid shift, forward projection —
runs for one point entirely in registers, with a single global read at the
start and a single write at the end. Intermediate absolute coordinates never
touch memory. That is why the SoA storage format is unchanged by the
precision toggle: the `precision` option changes the *register* type, not one
byte of layout.

The bounds reduction is the shared-memory pattern from the primer, and it is
needed because the output origin is not known until every point has been
transformed — which is also why this stage cannot be fused with the
renormalisation into one kernel.

== Grids, failure, and precision

Grid-based datum shifts and geoid models (Geodetic TIFF Grids) load through
GDAL on the host, upload as band-sequential FP32, and are sampled with
*software bilinear interpolation in the compute precision*. Hardware texture
filtering is deliberately not used: texture units interpolate with 9-bit
fixed-point weights, which would introduce error PROJ does not have. Multi-
subgrid files are supported with finest-first selection per point
(`ca_nrc_ntv2_0` expands to 114 subgrids).

Points PROJ cannot transform get `mask[i] = 1`, and the failure mask matches
host PROJ point-for-point. The default `on_error: drop` then compacts them
out, matching PDAL's streaming behaviour.

#figure(
  caption: [Precision modes. The FP32 error is *representation*, not
  arithmetic — one ulp of FP32 at longitude 150° is about 0.8 m.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [*fp64* (default)], [*fp32*]),
    [error vs PROJ], [$< 10^(-8)$ m per op; output limited only by storage
      quantisation], [≈1–4 m horizontal],
    [use], [production], [development on consumer GPUs; logs a loud warning],
  )
]

Storage quantisation bounds both modes: output is relative FP32, so
resolution is `output_span / 2^23` — about 4 mm over a 30 km tile. The auto
scale policy picks the next power of ten above that bound, which also
guarantees exact `int32` round-trip through the writer.

== Versus PDAL #h(1fr) #tPdal

`filters.reprojection` wraps a `PJ*` and calls into libproj *per point*. It
is correct, it is the reference pcax validates against, and it is
single-threaded. The architectural difference is not "GPU versus CPU" — it is
that pcax pays PROJ's planning cost once and then evaluates a flat,
branch-predictable op array, while PDAL re-enters libproj's generic
pipeline dispatch for every one of 23 million points.

#figure(
  caption: [Reprojection, side by side.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [#tPcax], [#tPdal `filters.reprojection`]),
    [planning], [libproj, once, host], [libproj, once, host],
    [execution], [compiled op array; GPU kernel or multithreaded host],
      [`proj_trans` per point, single-threaded],
    [precision], [fp64 or fp32, selectable], [fp64],
    [grids], [uploaded to device, software bilinear], [libproj's own],
    [unsupported ops], [automatic host-PROJ fallback, loudly logged],
      [n/a — always libproj],
    [verification], [3 ctest layers vs libproj on the same pipeline, plus
      `compare/reproject_bench.py`], [is the reference],
  )
]

#pagebreak()
= The GDAL GPU writer <sec-gdal>

`writer.gdal_gpu` rasterizes a point cloud to a GeoTIFF with PDAL
`writers.gdal` feature parity: min, max, mean, standard deviation, count,
IDW and arbitrary percentiles, in both *bin* and *radius* mode. It is the
only writer in pcax that runs on the GPU, and it shows a different set of
CUDA patterns from the filters.

#figure(kind: table, supplement: [Table],
  caption: [`src/writers/GdalGpuWriter.cu` — six kernels.])[
  #set text(8.2pt)
  #table(columns: (auto, auto, 1fr),
    align: (left + horizon, center + horizon, left),
    table.header([*Kernel*], [*Thread ↦*], [*Role*]),
    [`grid_compute_cell_indices`], [point],
      [raster cell id; *out-of-window points route to a sentinel overflow
       cell* that the stats kernels never read — required once the window can
       be fixed or snapped],
    [`grid_find_cell_boundaries`], [sorted slot], [run boundaries, as in the
      spatial grid],
    [`grid_stats_bin`], [*cell*], [bin mode: one thread reduces the points
      that fall in its own cell],
    [`grid_stats_radius`], [*window cell*], [radius mode: searches a
      halo-expanded binning grid so points *outside* the window still
      contribute to edge cells — PDAL `writers.gdal` semantics],
    [`scatter_values`], [point], [copy each cell's values into a contiguous
      segment ahead of a segmented sort],
    [`extract_percentile`], [cell], [index into the sorted segment],
  )
]

Two things distinguish it from the filter kernels.

*Thread ↦ cell, not thread ↦ point.* Once points are sorted by cell, the
natural parallel decomposition inverts: each thread owns an output cell and
reduces the points inside it. This makes the reduction trivially
deterministic — no atomics, no ordering dependence — at the cost of load
imbalance when cell occupancy varies, which for lidar it does.

*Percentiles need a segmented sort.* A percentile is not a reduction; you
need each cell's values in order. The sequence is `DeviceScan::ExclusiveSum`
over per-cell counts to build segment offsets, `scatter_values` to make the
segments contiguous, then `DeviceSegmentedSort::SortKeys` to sort every cell
independently in one launch, then an indexed read. This is the canonical way
to do "group by, then order within group" on a GPU and it generalises far
beyond rasters.

The halo in radius mode is a correctness detail that is easy to miss: the
binning grid is the output window padded by `halo` cells per side, and window
cell $("col", "row")$ sits at bin cell $("col" + "halo", "row" + "halo")$.
Without it, points just outside the window would be dropped and every edge
cell of the raster would be subtly wrong.

The documented parity result is ≈2–20 cells per million differing from PDAL,
where a point sits within FP32 relative-coordinate quantisation of a radius
cutoff or a cell edge — a worked example with a 16 µm margin is in
docs/Parity.md.

#pagebreak()
= Two GPU backends: CUDA and Metal

pcax runs on NVIDIA GPUs through CUDA and on Apple Silicon through Metal.
The backend is chosen at *configure* time, like the LAZ backend — there is no
runtime switch and no abstraction penalty.

== Where the seam is

CUDA and Metal cannot share kernel source: CUDA C++ with `<<<>>>` launches
versus Metal Shading Language compiled into a `.metallib` and dispatched
through command encoders. The abstraction therefore draws the line at the
*host API*, which works because the code was already split that way:

#figure(
  caption: [The per-filter backend split. The seam is a single entry point
  declared in a `*Gpu.hpp` header; everything above it is shared.],
  kind: image, supplement: [Figure],
)[
  #set text(8.2pt)
  #box(width: 100%)[
    #stack(dir: ttb, spacing: 5pt,
      dbox(w: 100%, fill: cPca.lighten(90%))[
        *`XFilter.cpp`* — backend-agnostic host \
        #text(7.5pt)[registration · option parsing · FP32 guard · residency ·
        `cloud.compact` · calls `xFilterRun(cloud, params)`]
      ],
      align(center)[#text(11pt, fill: luma(130))[$arrow.b$]
        #h(4pt) #text(7.5pt, fill: luma(110))[declared in `XFilterGpu.hpp`]],
      grid(columns: (1fr, 1fr), column-gutter: 8pt,
        dbox(w: 100%, fill: cCuda.lighten(90%))[
          *`XFilter.cu`* \
          #text(7.5pt)[`__global__` kernels, `<<<grid, block>>>`, CUB / Thrust]
        ],
        dbox(w: 100%, fill: cGrey.lighten(80%))[
          *`XFilter.metal.cpp`* + *`x.metal`* \
          #text(7.5pt)[MSL kernels in `pcax.metallib`, encoder dispatch]
        ],
      ),
    )
  ]
]

Concretely: `ClusterFilter.cpp` holds the stage class, registration and
options; `ClusterFilter.cu` holds `clusterGpu()` with `cc_propagate` and
friends; `ClusterFilter.metal.cpp` holds the Metal `clusterGpu()`; and
`src/gpu/metal/kernels/cluster.metal` holds the MSL. `CMakeLists.txt` puts
the shared `.cpp` in `PCA_STAGE_SOURCES` and the backend files in the
backend-specific list.

== What differs

#figure(
  caption: [Backend comparison. The FP32 restriction is a hardware fact, not
  a porting shortcut — FP64 on Apple GPUs is emulated and extremely slow.],
  kind: table, supplement: [Table],
)[
  #set text(8.4pt)
  #table(columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([], [*CUDA*], [*Metal*]),

    [platform], [Linux + NVIDIA], [macOS / Apple Silicon (the default there)],
    [kernel language], [CUDA C++, JIT/AOT via `nvcc`],
      [MSL → `pcax.metallib` via `xcrun metal`],
    [memory], [discrete: explicit `cudaMemcpy` both ways],
      [unified: `MTL::Buffer` removes host↔device copies entirely],
    [precision], [FP32 and FP64], [*FP32 only* — `precision: fp64` throws],
    [primitives], [CUB, Thrust], [vendored MSL sort/scan in `pca::gpu`],
    [`filter.reproject`], [GPU op chain], [host PROJ (FP64 accuracy matters
      more than speed here)],
  )
]

The FP32 contract is enforced in one place so every stage refuses
identically, and compiles to nothing on CUDA:

```cpp
inline void requireFp32(const std::string& stage, const StageOptions& opts) {
#ifdef PCA_GPU_METAL                             // include/pca/gpu/Fp32Guard.hpp
    if (opts.get("precision", "fp32") == "fp64")
        throw std::runtime_error(stage + ": precision: fp64 is not supported "
            "on the Metal (macOS) backend — Apple GPUs are FP32-only. ...");
#else
    (void)stage; (void)opts;
#endif
}
```

#nb[
  *Unified memory changes the arithmetic of this document.* On Apple Silicon
  there is no upload, no download, and no separate device allocation — the
  `PointCloud`'s dimension arrays *are* the GPU's arrays. The memory pressure
  analysed in `docs/MlNoiseGpuMemory.typ` is a discrete-GPU problem;
  on Metal the same stage competes with the system for one pool instead.
]

#pagebreak()
= Parity as an engineering discipline <sec-parity>

pcax is a reimplementation of stages whose reference behaviour is another
program's source code. That makes numerical agreement a first-class
requirement rather than a nice-to-have, and the project treats disagreement
as something to *characterise and document*, not to hand-wave.

== Why exact parity is sometimes impossible

Four independent mechanisms produce small, principled divergence. Recognising
which one you are looking at is most of the work of triaging a parity report.

#figure(
  caption: [The four root causes of pcax↔PDAL divergence. None is a bug;
  each has a bounded, documented magnitude.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(
    columns: (auto, 1fr, 1fr),
    align: (left + horizon, left, left),
    table.header([*Cause*], [*Mechanism*], [*Typical magnitude*]),

    [FP32 storage quantisation],
    [pcax stores relative FP32 (≈0.1–0.5 mm over a multi-km tile); PDAL
     carries FP64. A point within that margin of a threshold, radius cutoff
     or cell edge lands on either side.],
    [≈1 point per 1.5 M (SOR, crop); 2–20 raster cells per million],

    [Eigensolver differences],
    [cyclic Jacobi (pcax, device) vs Eigen's `SelfAdjointEigenSolver` (PDAL).
     Distributions agree to $10^(-6)$; near-degenerate eigenvalues make
     eigenvector-direction features flip.],
    [≤13 points per 2.6 M; worst on verticality-type features],

    [Tie-breaking and ordering],
    [`std::sort` is not stable and $z$ is quantised, so equal-value blocks
     order arbitrarily in PDAL; pcax ties by point index deterministically.
     kNN-boundary ties likewise change which point is the $k$-th neighbour.],
    [`skewnessbalancing`: exact *count*, ≈1.1% boundary membership;
     `reciprocity` ≤29 per 762 K],

    [Parallel reduction order],
    [FP addition is not associative, so a parallel sum differs from PDAL's
     sequential running mean.],
    [`lloydkmeans` centroids at the last bits],
  )
]

#nb[
  *A relabelling is not a disagreement.* `filter.cluster`'s partition is
  99.994% identical to PDAL, but the *ClusterID integers* diverge by ≈13%.
  Both facts are in the tolerance list because they measure different things:
  IDs come from sequential discovery order, so 30 differing points out of
  479 K renumber everything downstream of them. Cluster labels are arbitrary
  and the comparison must be relabel-invariant.
]

== The verification stack

#figure(
  caption: [Four layers of verification, from unit tests to real-tile PDAL
  comparison. Tier 1 runs in ≈5 seconds and is expected for any stage change.],
  kind: table, supplement: [Table],
)[
  #set text(8.3pt)
  #table(columns: (auto, 1fr, auto),
    align: (left + horizon, left, left + horizon),
    table.header([*Layer*], [*What it checks*], [*Invocation*]),

    [unit], [ported PDAL unit tests (analytic geometry: line, square, tilted
      quad), plus pcax-specific structure tests],
      [`ctest`],
    [integration \ Tier 1], [per-stage fingerprints + output rasters vs
      committed baselines on a 1.57 M-point fixture, in three variants
      (gpu-fp64 / gpu-fp32 / cpu-fp64)],
      [`ctest -L integration`],
    [parity \ Tier 2], [per-stage comparison against PDAL itself on the same
      fixture, with the documented slack encoded as `PARITY_SLACK`],
      [`ctest -L parity`],
    [accuracy \ Tier 4], [`filter.ml_noise` precision/recall vs vendor noise
      labels on held-out Santa Clara tiles],
      [`ctest -L accuracy`],
  )
]

For new work the harness is `compare/filter_parity.py`, which runs both
implementations on a real tile and diffs counts plus every dimension's
statistics:

```bash
python3 compare/filter_parity.py --input tile.laz \
  --name case --pdal-filter '{"type":"filters.x", ...}' \
  --pcax-stage 'type: filter.x\n...'
```

The workflow that produced the current tolerance list is worth stating as a
rule, because it is what keeps the list trustworthy: *pin the semantics from
PDAL's source, not its documentation*. The quirks are where the divergence
lives — `filters.dem` subtracts the lower limit; `filters.decimation`'s
streaming path differs from its bulk path; `filters.elm` floors before
dividing; `filters.crop` uses GEOS `covers` and is boundary-inclusive.

#pagebreak()
= The COPC writer <sec-copc>

`write.copc` is the pipeline's visualization output: a COPC 1.0 file — LAS
1.4, point format 6–8, LAZ — whose chunks are octree nodes, with the COPC
info VLR and a hierarchy EVLR so a viewer (Potree, QGIS, PDAL `readers.copc`)
fetches only the nodes in view by HTTP range request. It is the second GPU
writer, and the first stage that does *not* replay the raw records in
place: the records are gathered in octree order and, for legacy formats,
converted on the way. `docs/CopcWriter.md` is the user-facing reference;
this section is about the build.

== The recipe, and why it is deterministic

The octree is a fixed recipe (`include/pca/CopcOctree.hpp`) implemented
twice — a host reference (`src/core/CopcOctree.cpp`, also the CPU/Metal
path) and the CUDA build (`src/writers/CopcOctree.cu`) — and
`tests/test_copc_octree_gpu.cu` holds them to the same permutation and node
table on random clouds and the Everglades fixture. That equivalence is
what makes the GPU path trustworthy, so every decision that affects the
result is arithmetic both sides can reproduce:

+ *Cube.* Origin at the relative-coordinate minimum (which is the header
  minimum: relative coordinates start at exactly 0), edge = the largest
  extent *snapped to the LAS scale lattice in double* — the FP32 maximum can
  fall a few µm short of the true int32 extent, and the VLR cube must agree
  exactly with the keys or a point on a node boundary ends up in the wrong
  box (the 66-point window-query discrepancy in docs/Parity.md was
  exactly this, from an ulp of padding).
+ *Keys.* One 48-bit Morton key per point at depth $K = D + log_2(#[grid])$,
  capped at 16: the tree stops at depth $D$, but every node needs a full
  $"grid"^3$ voxel grid below it for subsampling. The cell index is
  `trunc((x − min) · 2^K / side)` — one double multiply and a truncating
  cast. No FMA can contract it, so host and device agree bit for bit.
+ *Stable sort.* CUB's radix sort is stable; the host uses `stable_sort`.
  Equal keys (duplicate points) keep original order on both.
+ *Level pass.* For $d = 0 … D-1$, over the still-unassigned points in key
  order: run boundaries by node prefix (a flag kernel, `DeviceSelect::Flagged`
  on a counting iterator for the run starts, an in-place `InclusiveSum` for
  the run id), then one kernel decides: a node with ≤ `max_node_points`
  points is a leaf and takes them all; otherwise the *first* point of every
  occupied voxel is promoted to depth $d$. Survivors are compacted with
  `DeviceSelect::Flagged`. At most 16 iterations, each a handful of launches.
+ *Order.* The points are first put in GPS-time order (a radix sort of the
  sortable-double key; ties keep input order), then a second stable radix
  sort by `(node prefix padded to K, depth)` is DFS pre-order with every node
  contiguous and *scan order* inside; `DeviceRunLengthEncode` on that key is
  the node table. Scan order is not cosmetic: LAZ's layered predictors work
  from the previous point, and on the Everglades fixture Morton order inside
  nodes produced a 10.4 MB file where GPS order produces 6.9 MB (PDAL,
  which also sorts by GPS time: 7.3 MB).

== Record assembly on the device

The raw LAS records are uploaded once (`n × recordLength`). `k_assemble`
gathers via the permutation, copies or converts the record
(`include/pca/LasRecordConvert.hpp` is `__host__ __device__`), writes XYZ as
`minRaw + lround(x / scale)` — the write.las rule, so a reprojected cloud
(`coordsDirty`, minRaw = 0) takes the same path — the Classification dim,
and any `extra_dims` fields gathered from their device arrays. Output is
produced in 16M-point slices and copied straight into the host buffer the
compressor threads read: no host gather pass. Memory is therefore bounded
by the raw upload plus one slice, not by two full copies; `pcax analyze`
models the three sequential peaks (sort, level pass, assembly).

What stays on the host is the LAZ entropy coder: laz-perf's arithmetic
coder is inherently sequential per chunk, so one node is one `ThreadPool`
job, exactly as `write.las` chunks are. That is also the wall-clock
bottleneck — on the 73M-point NorthernCA tile the whole GPU build is well
under a second and the coder is several — and it is why the tree shape
matters: a geographic-CRS tile (degrees × metres) has a Z-dominated cube,
seven nodes, and seven busy threads.

== Parity

Point records are byte-exact vs PDAL `writers.copc` (every field, sorted,
through `readers.copc`; 1.57M, 2.77M and 73M points); `readers.copc`
bounds-window queries return identical point sets from both files. The
tree layout is not compared — PDAL centres its cube on the bounds midpoint
and untwine's sampling keeps a denser root — and `docs/CopcWriter.md` says
so. `compare/copc_parity.py` is the harness; `tests/integration/test_copc.py`
runs it on both fixtures.

= Serving COPC to a browser <sec-serve>

`pcax serve <dir>` closes the loop from pipeline to picture: it hosts the
`.copc.laz` files in a directory over HTTP and serves an embedded Potree
page that streams them. It is deliberately small — `src/serve/` is ~500
lines on top of the vendored single-header cpp-httplib — because COPC
viewers need exactly two things from a server: *byte-range requests*
(`Range: bytes=a-b` → `206` with `Content-Range`, including the multipart
form) and *CORS* headers so a page can fetch from another origin. The
`/data/<name>` route streams the file through a `pread` content provider
that cpp-httplib slices per range; `/api/files` is a JSON index built from
the LAS header and the COPC info VLR only (`CopcIndex.cpp`, cached by
size + mtime), so a directory of hundreds of tiles lists instantly.

Two design points worth keeping:

- *One binary.* The viewer tree (`viewer/`: Potree 1.8.2 trimmed to the COPC
  path by `tools/fetch_viewer.sh`, ~6.5 MB, plus pcax's `index.html`,
  `pcax.js`, `pcax.css`) is embedded at build time with assembler `.incbin`
  (`cmake/EmbedAssets.cmake` writes a `.S` and a lookup table). That keeps
  the Docker runtime contract — copy `pcax`, nothing else — and avoids
  compiling megabytes of hex arrays. `--viewer-dir` serves the same tree from
  disk for viewer development.
- *A narrow surface.* Only regular files directly in the root whose name
  matches `[A-Za-z0-9][A-Za-z0-9._-]*.copc.laz` and whose canonical path
  stays under the canonical root are reachable; everything else is a 404,
  never a 403. The default bind is loopback; TLS and auth are the ingress's
  job.

The page itself (`viewer/pcax.js`) is a thin layer over Potree's API: file
checkboxes call `Potree.loadPointCloud` (its `CopcLoader` fetches the
hierarchy and nodes by range through copc.js + laz-perf.wasm and decodes
nodes in a worker), colour-by maps to `material.activeAttributeName` — every
extra-bytes dimension `write.copc` wrote appears there — classification
chips call `setClassificationVisibility`, and clip boxes are
`Potree.BoxVolume` with `clip = true` under `setClipTask`. Nothing vendored
is edited; upgrading Potree is re-running the fetch script.

`ctest -L serve` runs the index unit test and a live curl contract test
(ranges byte-compared with `dd`, 416, preflight, traversal, WASM MIME,
concurrent fetches); `tests/integration/test_serve.py` is the pytest twin.
`docs/Serve.md` has the endpoint table.

= Known limits and where the architecture goes next <sec-limits>

This section is the roadmap, ordered by how much of the design each item
touches. It is the part of this document most likely to change.

== Bounded by the whole-tile model

/ Streaming: pcax has none. Every stage assumes the tile is resident. This
  caps input size at host RAM and, for GPU stages, at device memory.
- *Device memory ceilings.* `filter.ml_noise` peaked at 377 B/point, capping
  an 11 GiB card at ~30 M points, until the kNN and eigen passes were fused
  (2026-08-21) — measured 231 B/point since, with the ceiling now set by the
  cell-feature sort rather than the neighbourhood search. The analysis is in
  `docs/MlNoiseGpuMemory.typ`. The general lesson applies to any future stage:
  *a scratch buffer's lifetime, not its size, is what makes it expensive* —
  and a buffer that is written by one kernel and read by the next is usually
  a missing fusion, not a necessary allocation.
/ No arena allocator: every stage `cudaMalloc`s and `cudaFree`s
  independently, so a large contiguous request can fail on fragmentation even
  when the total is available. A stage-lifetime arena would fix this for all
  GPU filters at once.

== Bounded by the single-cloud executor

/ No branch or merge: the executor topo-sorts but runs linearly over
  `m_clouds["default"]`. `filters.merge`, `splitter`, `chipper` and
  `divider` all need a multi-cloud executor first. This is the largest
  functional gap versus PDAL.
/ No `requiredDims()`: `ensureResidency` uploads every dimension for every
  GPU stage. A per-stage declaration would cut transfers measurably (12 of
  33 B/point are dead weight for `ml_noise`), with the risk that an
  under-declaring stage reads a stale device pointer — so the default must
  stay permissive.

== Bounded by transfer mechanics

/ Pageable, synchronous copies: `uploadToDevice` uses plain `cudaMemcpy` on
  pageable memory — roughly half the achievable bandwidth, and no overlap
  with compute. Pinned staging buffers plus `cudaMemcpyAsync` on a stream
  would let the next stage's upload overlap the current stage's kernels.
/ One default stream: pcax uses no CUDA streams, so there is no concurrency
  between independent kernels or between transfer and compute.
/ Residency never invalidates: `Both` is set on upload and download alike,
  so a kernel that writes a buffer must call `setResidency(..., Device)` by
  hand. A dirty-bit per side would make this automatic.

== Ergonomics and coverage

/ Options have no schema: `StageOptions` is `map<string,string>`; unknown
  keys are silently ignored and there is no `--options` introspection. PDAL's
  `ProgramArgs` is the model to copy.
/ Dimensions are a compile-time enum: adding one means editing
  `Dimension.hpp`. PDAL's `registerOrAssignDim` is strictly more flexible; the
  trade bought the raw-pointer inner loop, and is unlikely to be reversed.
/ 51 stages versus PDAL's 129: the port roadmap and progress log live in
  `docs/PdalFeatureMatrix.md`, and `pdal.filter` remains the escape hatch
  (at a real latency cost, since it repacks the whole cloud into a
  `PointTable` and back).

== Metal follow-ups

- *`filter.reproject`* runs on host PROJ on Metal; the GPU op chain is
  CUDA-only.
- *The committed integration baselines are CUDA-FP64.* They need regenerating
  on Apple (`--update-baselines`) or a backend dimension added, and the
  gpu-fp64 variant should assert the FP32-guard error rather than skip.

#pagebreak()
= Appendix A — Kernel index

#figure(
  caption: [All 62 CUDA kernels, by translation unit.],
  kind: table, supplement: [Table],
)[
  #set text(7.9pt)
  #table(
    columns: (auto, auto, 1fr),
    align: (left + horizon, center + horizon, left),
    table.header([*File*], [*\#*], [*Kernels*]),

    [`SpatialGrid.cuh`], [2],
      [`compute_cell_indices`, `find_cell_boundaries`],
    [`SorFilter.cu`], [2], [`knn_mean_dist`, `classify_outliers`],
    [`NormalFilters.cu`], [2], [`normal_kernel`, `eigenvalues_kernel`],
    [`CovarianceFeaturesFilter.cu`], [1], [`covfeat_kernel`],
    [`OptimalNeighborhoodFilter.cu`], [1], [`optneigh_kernel`],
    [`ApproximateCoplanarFilter.cu`], [1], [`coplanar_kernel`],
    [`NeighborhoodFeatureFilters.cu`], [5],
      [`planefit_kernel`, `rank_kernel`, `radialdensity_kernel`,
       `nndistance_kernel`, `reciprocity_kernel`],
    [`NeighborClassifierFilter.cu`], [1], [`neighborclassifier_kernel`],
    [`HagFilters.cu`], [1], [`hag_nn_kernel`],
    [`LOFFilter.cu`], [3], [`lof_pass1`, `lof_pass2`, `lof_pass3`],
    [`ClusterFilter.cu`], [3], [`cc_propagate`, `cc_compress`, `cc_sizes`],
    [`DBSCANFilter.cu`], [4],
      [`db_core`, `db_propagate`, `db_compress`, `db_assign`],
    [`LloydKMeansFilter.cu`], [4],
      [`km_dist_init`, `km_dist_update`, `km_assign`, `km_accum`],
    [`FarthestPointSamplingFilter.cu`], [2],
      [`fps_dist_init`, `fps_dist_update`],
    [`MlNoiseFilter.cu`], [13],
      [`ml_knn_stats_kernel` (search + eigenfeatures, fused),
       `ml_cell_keys_kernel`,
       `ml_cell_bounds_kernel`, `ml_cell_pct_kernel`, `ml_cell_scatter_kernel`,
       `ml_zabs_kernel`, `ml_u16_to_f32_kernel`, `ml_absdev_kernel`,
       `ml_gather_col_kernel`, `ml_iota_kernel`, `ml_rank_scatter_kernel`,
       `ml_finalize_kernel`, `ml_infer_kernel`],
    [`ReprojectFilter.cu`], [2], [`chainKernel`, `renormKernel`],
    [`GdalGpuWriter.cu`], [6],
      [`grid_compute_cell_indices`, `grid_find_cell_boundaries`,
       `grid_stats_bin`, `grid_stats_radius`, `scatter_values`,
       `extract_percentile`],
    [`CopcOctree.cu`], [9],
      [`k_keys`, `k_iota`, `k_run_flags`, `k_assign`, `k_assign_rest`,
       `k_gps_keys`, `k_gather_u64` (GPS-time ordering inside nodes),
       `k_order_keys`, `k_assemble`],
  )
]

= Appendix B — Build and test reference

```bash
# configure + build (LAZPERF is the default LAZ backend; -DPCA_LAZ_BACKEND=LASLIB opts in)
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel $(nproc)

# GPU backend is compile-time and platform-chosen; force it with:
#   -DPCA_GPU_BACKEND=CUDA|METAL
# On macOS also pass -DCMAKE_PREFIX_PATH=$CONDA_PREFIX so GDAL/PROJ/yaml-cpp
# resolve from your conda env.

ctest --test-dir build -L unit             # C++ unit + GPU tests (-LE gpu without a device)
ctest --test-dir build -R copc                 # write.copc: host octree, GPU==host, writer
ctest --test-dir build -L serve                # pcax serve: index + live HTTP contract (curl)

# host write.copc output + the embedded 3D viewer (-DPCA_WITH_SERVE=ON, default)
pcax serve out/ --bind 0.0.0.0 --port 8080

# python side: pip install -r requirements-dev.txt (+ GDAL bindings)
ctest --test-dir build -L integration   # Tier 1, ~5 s
ctest --test-dir build -L parity        # Tier 2, vs the system pdal CLI
ctest --test-dir build -L perf          # advisory timings
ctest --test-dir build -L accuracy      # ml_noise scoring (PCAX_ML_MODEL + tiles)

# after an intentional behaviour change
python3 -m pytest tests/integration --update-baselines

# run a pipeline, with the profiler tree
pcax run pipeline.yaml -v input=a.laz -v output=b.laz -d
pcax validate pipeline.yaml
```

*Adding a GPU filter*, in the order the codebase expects:

+ Pin the PDAL semantics from PDAL's *source*.
+ Decide the device. Memory-bound single passes (`range`/`crop`/`assign`
  style) stay on the CPU with `ThreadPool` chunking — a GPU port would upload
  every dimension for no gain. Neighbourhood and compute filters go to the
  GPU on the shared uniform grid.
+ Write `XFilter.cpp` (class, `PCA_REGISTER_STAGE`, options, FP32 guard) and
  `XFilter.cu` (kernels + the `xGpu()` entry declared in `XFilterGpu.hpp`).
+ Add both to `PCA_STAGE_SOURCES` / the backend list in `CMakeLists.txt`.
+ Parity-test on real data with `compare/filter_parity.py` before calling it
  done, and record the result in docs/Parity.md.
+ Update `docs/Filters.md`, the README stage table, `docs/PdalFeatureMatrix.md`
  and — if the tolerance is new — the list in `CLAUDE.md`, *in the same
  commit*.

= Appendix C — Glossary

#figure(kind: table, supplement: [Table], caption: [Terms used throughout.])[
  #set text(8.3pt)
  #table(columns: (auto, 1fr),
    align: (left + horizon, left),
    [*AoS / SoA*], [array-of-structs / struct-of-arrays memory layout],
    [*coalescing*], [merging a warp's global-memory accesses into the fewest
      possible transactions],
    [*occupancy*], [resident warps per SM as a fraction of the hardware
      maximum; the mechanism that hides memory latency],
    [*local memory*], [per-thread storage that lives in global DRAM — where
      spilled registers go; not fast],
    [*warp*], [32 threads executing in lockstep; the real unit of scheduling],
    [*SM*], [streaming multiprocessor — the GPU core that hosts resident
      blocks],
    [*CUB / CCCL*], [CUDA's device-wide primitive library, unified into CCCL
      in CUDA 13],
    [*GTG*], [Geodetic TIFF Grid — PROJ's grid format for datum and geoid
      shifts],
    [*PDRF*], [LAS point data record format (6 = the modern 30-byte record
      with GPS time)],
    [*relative FP32*], [pcax's coordinate storage: `(raw - minRaw) * scale`],
    [*residency*], [which side (host, device, both) currently holds a
      dimension's data],
    [*parity*], [numerical agreement with PDAL on the same input],
  )
]

= Appendix D — Maintaining this document

This is a *living document*. It describes the code as it is, so a statement
here that no longer matches `src/` is a defect, not merely stale prose.

- *Kernel count and index* (@sec-kernels, Appendix A) must match
  `grep -r __global__ src/`.
- *Architectural claims* about PDAL are pinned to headers in
  `$CONDA_PREFIX/include/pdal/`; re-check them when the pinned PDAL version
  moves.
- *Numbers* — per-point byte coefficients, speedups, tolerance magnitudes —
  come from docs/Parity.md and `docs/PdalFeatureMatrix.md`. Those are the
  sources of truth; this document quotes them.
- When a change alters stage behaviour, options or semantics, update this
  document in the same commit as `docs/Filters.md`, the README stage table
  and the affected `docs/pipeline-phases/*.md`, per the rule in `CLAUDE.md`.

*Companion documents.* `docs/MlNoiseGpuMemory.typ` — the GPU memory case
study this one refers to throughout. `docs/Reprojection.md`,
`docs/MetalBackend.md`, `docs/GdalGpuWriter.md`, `docs/MlNoiseFilter.md` —
per-subsystem detail. `docs/PdalFeatureMatrix.md` — the stage-by-stage
coverage matrix and port progress. docs/Parity.md — the append-only
validation log. `docs/IntegrationTesting.md` — the test tier design.
