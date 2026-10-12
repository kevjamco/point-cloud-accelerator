# Contributing to Point Cloud Accelerator

This repository is the public face of pcax: documentation, example
pipelines, the PDAL comparator (`compare/`) and the license texts. The
engine source is not published; pcax ships as a conda binary
([docs/Install.md](docs/Install.md)).

## What you can contribute here

- **Issues**: bugs, parity differences against PDAL (please attach the
  `compare/filter_parity.py` output and the pcax version), feature
  requests, documentation errors.
- **Pull requests** against anything in this repository: docs,
  `pipelines/`, the comparator scripts.
- **Parity reports**: `compare/README.md` explains how to run pcax and PDAL
  head-to-head on your own data and what to send.

## Style

- Docs state what the current release does; a doc that quotes superseded
  numbers or removed options is a bug. Cite `docs/Parity.md` for tolerances.
- Commit messages: `area: what changed` on the first line, then why.

## Publishing (maintainers)

The canonical repository is private; GitHub receives a snapshot of the
allow-listed paths only. `tools/publish_public.sh` builds that snapshot on
the orphan `public` branch, refuses any source or build file and any private
identifier, and pushes it to the `github` remote. See the script header for
the flow and `--dry-run`.

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
