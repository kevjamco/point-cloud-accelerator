# Installing pcax

pcax is distributed as conda packages from the Advanced Algorithms channel.
pcax is free to evaluate, with no time limit; every other use needs a
commercial license (kevin@adv-algos.com). Under the [license](../LICENSE) (§4)
only Advanced Algorithms LLC distributes pcax, so the packages are not on
conda-forge or PyPI. Their dependencies
(GDAL, PROJ, yaml-cpp, the CUDA runtime) come from conda-forge.

```bash
mamba install -c https://conda.adv-algos.net/pcax -c conda-forge pcax
# or: conda install -c https://conda.adv-algos.net/pcax -c conda-forge pcax
# or: pixi add pcax  (with both channels in your manifest)
pcax activate you@example.com     # once per machine; see Licensing.md
```

`pcax run` needs an activated evaluation (a verified email, network access
to the license server on every run) or a commercial license token or lease.
[Licensing.md](Licensing.md) has the flow, what is reported to the server
and the environment variables for CI and air-gapped hosts.

## Platforms

| Platform | GPU backend | Requirements |
|---|---|---|
| `linux-64` | CUDA 13 (FP64 + FP32) | NVIDIA driver R580+ (CUDA 13); GPU compute capability 7.5+ (Turing, Ampere, Ada, Blackwell); glibc 2.28+ |
| `osx-arm64` | Metal (FP32 only) | Apple Silicon (M1+), macOS 14+ |

- The Linux package installs without a driver (`device: cpu` pipelines still
  run). With a driver present, the solver requires it to support CUDA 13.
- Metal is FP32-only: stages with `precision: fp64` fail with a clear error.
  See [MetalBackend.md](MetalBackend.md).

## What's in the package

| Path | Contents |
|---|---|
| `bin/pcax` | the CLI; the `pcax serve` viewer is embedded |
| `share/pcax/pcax.metallib` | Metal kernels (osx-arm64 only), found next to the binary; `PCAX_METALLIB` overrides the location |
| `share/doc/pcax/` | `LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES.md` |

- **Reprojection grids:** PROJ grid files are not bundled. Either install
  `proj-data` from conda-forge (large), point `grids_path` at a local copy
  (`compare/fetch_grids.sh`), or enable PROJ's network access
  (`PROJ_NETWORK=ON`).
- **`filter.ml_noise`:** the model is always user-supplied; see
  [MlNoiseFilter.md](MlNoiseFilter.md).

## How releases are made

Each release tag is built and tested on real hardware for both backends
before anything is published:
- the full unit, integration and PDAL-parity suites, first from source,
- then again against the installed package.

A release is published only if both backends pass. Published packages are
never overwritten, so a fix ships as a new version or build number.

## Source

pcax is distributed as a binary only. The public repository carries the
documentation, the example pipelines and the PDAL comparator; the engine
source is not published.
