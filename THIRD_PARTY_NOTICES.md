# Third-party notices

Point Cloud Accelerator (`pcax`) is © Advanced Algorithms LLC and distributed
under the source-available Point Cloud Accelerator License (see `LICENSE`).
It vendors or links the following third-party software, each of which keeps
its own open-source license, reproduced or linked where indicated; those
licenses are unaffected by ours.

## Vendored in this repository

| Component | Version | License | Location |
|---|---|---|---|
| laz-perf | 3.2.0 | Apache-2.0 | `extern/lazperf/` (`LICENSE`, `UPSTREAM.md`); `src/readers/LazLayeredDecoder.cpp` adapts its `detail/field_point14.cpp` |
| cpp-httplib | 0.53.1 | MIT | `extern/cpp-httplib/` (`LICENSE`, `UPSTREAM.md`) |
| metal-cpp | Xcode 15 release | Apache-2.0 | `extern/metal-cpp/` (`LICENSE.txt`, `UPSTREAM.md`) |
| Potree | 1.8.2 | BSD-2-Clause | `viewer/potree/` (`viewer/LICENSES/POTREE`, `viewer/UPSTREAM.md`) |
| three.js r124 (bundled inside `potree.js`) | as shipped with Potree 1.8.2 | MIT | `viewer/LICENSES/THREE` |
| d3, jQuery 3.1.1, jQuery UI, jsTree 3.3.8, i18next 1.8.0, OpenLayers 3, proj4js, Spectrum, tween.js, BinaryHeap.js | as shipped with Potree 1.8.2 | MIT / BSD-2 / BSD-3 | `viewer/libs/` (`viewer/LICENSES/*`, one file per library) |
| laz-perf WebAssembly build | as shipped with Potree 1.8.2 | Apache-2.0 | `viewer/libs/copc/` |

The `viewer/` tree is embedded into the `pcax` binary (`pcax serve`), so a
distributed `pcax` executable contains Potree and its bundled libraries.

## Optional: LAStools / LASlib (git submodule, not built by default)

`extern/LAStools` is an optional git submodule used only when configuring with
`-DPCA_LAZ_BACKEND=LASLIB`. LASlib and LASzip are licensed under the
**LGPL-2.1**; LAStools also contains closed-source components that pcax does
not use. A pcax binary built with the LASLIB backend links LASlib and is
therefore subject to the LGPL's relinking and source-availability
obligations, which apply to whoever distributes such a binary. When the
option is on, LASlib is built as a **shared** library so a distributor can
satisfy LGPL-2.1 §6(b) by shipping it alongside `pcax`.

**Advanced Algorithms LLC does not distribute binaries built with the LASLIB
backend.** Every artifact we publish (source releases, container images,
packages) uses the default laz-perf backend, which does not require the
submodule. Anyone who builds and redistributes a LASLIB variant is responsible
for LGPL-2.1 compliance for the LASlib/LASzip portion; the Point Cloud
Accelerator License (§5) does not restrict the rights the LGPL grants.

## Notices in distributed artifacts

Every artifact we distribute carries `LICENSE`, `NOTICE` and this file: they
are in the source tree, copied into the container image (`/usr/share/doc/pcax/`)
and referenced by `pcax --version`. They must stay with every copy (LICENSE §4).

## System libraries linked at build time

| Library | License |
|---|---|
| yaml-cpp | MIT |
| GDAL | MIT/X |
| PROJ | MIT/X |
| CUDA Toolkit (CUDA backend) | NVIDIA CUDA Toolkit EULA |
| Metal framework (Metal backend) | Apple SDK license |

## Reference implementations

PDAL (BSD-3-Clause, https://pdal.io) is the semantic reference for every
ported stage: option names, edge-case behaviour and output are matched to PDAL
and verified by the comparator in `compare/`. pcax does not link or bundle
PDAL. The optional `pdal.filter` adapter (`-DPCA_WITH_PDAL=ON`, off by
default) links the system `libpdalcpp`.
