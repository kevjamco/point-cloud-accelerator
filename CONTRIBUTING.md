# Contributing to Point Cloud Accelerator

## Build and test

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel $(nproc)
ctest --test-dir build -L unit --output-on-failure      # C++ tests; -LE gpu without a device
```

Python-side tests (per-stage regression, PDAL parity, perf):

```bash
pip install -r requirements-dev.txt          # + GDAL bindings for the raster tests
cmake -B build                               # re-configure so ctest finds pytest
ctest --test-dir build -L integration        # ~5 s, pcax only
ctest --test-dir build -L parity             # needs `pdal` on PATH
```

Run the `unit` and `integration` labels for any stage or pipeline change.
After an *intentional* behavior change, regenerate the committed baselines
and commit the diff:

```bash
python3 -m pytest tests/integration --update-baselines
```

`docs/IntegrationTesting.md` explains the tiers, variants, tolerance policy
and how to add a stage to the suite.

## Adding a stage

The pattern that every ported stage followed is in `CLAUDE.md` ("Adding a
filter"): pin PDAL's semantics from its source, choose CPU or GPU by whether
the pass is memory-bound, register with `PCA_REGISTER_STAGE`, add the source
to `PCA_STAGE_SOURCES`, then parity-test on a real tile with
`compare/filter_parity.py` before calling it done. Record any residual
difference and its root cause in `docs/Parity.md`.

**Docs are part of the change.** A commit that adds or alters stage behavior,
options or measured numbers updates the affected docs in the same commit:
`docs/Filters.md`, the README stage table, `docs/PdalFeatureMatrix.md` (and
the `pcax convert` mapping table it mirrors — `test_pdal_convert` enforces
totality), `docs/Parity.md` for tolerances, and the relevant
`docs/pipeline-phases/*.md`.

## Style

- C++17, CUDA 13. Namespace `pca`. Match the surrounding file.
- Hand-rolled tests (`CHECK` macro, `main()` returns nonzero) — see any
  `tests/test_*.cpp`. Scratch files go through `tests/TestTmp.hpp`.
- Never edit vendored code under `extern/` or `viewer/` in place; refresh it
  with the documented fetch script and update its `UPSTREAM.md`.
- Commit messages: `area: what changed` on the first line, then why.

## Publishing (maintainers)

The canonical repository is private; GitHub receives a snapshot without the
`private/` directory. `tools/publish_public.sh` builds that snapshot on the
orphan `public` branch, runs a guardrail grep for private paths and hosts,
and pushes it to the `github` remote. See the script header for the flow and
`--dry-run`.

## License and contributor grant

Point Cloud Accelerator is source-available (see `LICENSE`): evaluation is
free for everyone, and every other use needs a commercial license; the
software is not redistributable (forking on GitHub to contribute back is
expressly allowed). Because Advanced Algorithms
LLC licenses the software commercially, it needs the right to do so for
contributed code too.

By submitting a contribution (pull request, patch, or otherwise) you certify
that you have the right to do so, and you grant Advanced Algorithms LLC a
perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to use,
reproduce, modify, sublicense and distribute your contribution as part of the
Software under the Point Cloud Accelerator License or any other terms,
including commercial ones. You keep the copyright in your contribution.
