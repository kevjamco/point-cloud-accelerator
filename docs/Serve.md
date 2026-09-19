# pcax serve — self-hosted 3D viewer for COPC output

`pcax serve <dir>` hosts the `.copc.laz` files in a directory over HTTP
(byte-range requests + CORS, which is what COPC viewers need) together with
an embedded [Potree](https://github.com/potree/potree) page. Point a
browser at `http://host:8080/`, pick a file, and you get a level-of-detail
3D view with classification toggles, colour-by-attribute (including
`write.copc` `extra_dims` such as HeightAboveGround), clip boxes, EDL, and
Potree's own sidebar (measurements, profiles, camera, export).

```bash
pcax run pipeline.yaml -v input=tile.laz -v output=out/tile   # write.copc -> out/tile.copc.laz
pcax serve out/ --bind 0.0.0.0 --port 8080                    # then browse to http://host:8080/
```

It is one binary: the viewer assets (~6.5 MB, Potree 1.8.2 trimmed to the
COPC path — `viewer/`, `tools/fetch_viewer.sh`) are embedded at build time
with assembler `.incbin` (`cmake/EmbedAssets.cmake`), so the Docker runtime
image needs nothing beyond `pcax`. `-DPCA_WITH_SERVE=OFF` builds without it.

## CLI

```
pcax serve <dir> [--port N] [--bind ADDR] [--viewer-dir DIR] [--cors ORIGIN|none] [--threads N] [-d]
```

| Flag | Default | Meaning |
|---|---|---|
| `--bind` | `127.0.0.1` (env `PCAX_SERVE_BIND`) | Listen address; `0.0.0.0` to expose on the network / in a container |
| `--port` | `8080` (env `PCAX_SERVE_PORT`) | `0` = ephemeral; the chosen port is printed as `listening on http://ADDR:PORT/` |
| `--viewer-dir` | embedded | Serve the viewer page and assets from a directory instead (viewer development: edit `viewer/pcax.js`, reload) |
| `--cors` | `*` | `Access-Control-Allow-Origin` value; `none` disables CORS headers |
| `--threads` | max(4, cores) | HTTP worker threads |
| `-d` | | Debug logging |

`SIGINT`/`SIGTERM` stop the server cleanly. Only files whose name matches
`[A-Za-z0-9][A-Za-z0-9._-]*.copc.laz` directly inside `<dir>` are exposed
(no recursion, no symlink escapes: the resolved path must stay under the
canonical root); everything else is a 404.

## Endpoints

| Method | Path | Response |
|---|---|---|
| GET | `/` | the viewer page (`viewer/index.html`, no-cache) |
| GET | `/viewer/<asset>` | embedded asset by exact path; MIME by extension (`.wasm` → `application/wasm`); `max-age=86400` |
| GET | `/api/files` | `{"root": "...", "files": [entry, ...]}` — rescans the directory (one `stat` per file; header/VLR re-read only when size or mtime changed) |
| GET | `/api/files/<name>` | one entry, 404 otherwise |
| GET / HEAD | `/data/<name>` | the file; `Accept-Ranges: bytes`, `ETag "<size>-<mtime>"`; `Range` → `206` + `Content-Range` (multipart ranges supported), unsatisfiable → `416` |
| OPTIONS | `*` | `204` with the CORS headers |
| GET | `/healthz` | `ok` (liveness/readiness) |

Entry schema (`/api/files`):

```json
{"name": "tile.copc.laz", "url": "/data/tile.copc.laz", "bytes": 452368178, "mtime": 1787800000,
 "points": 72990132, "format": 6, "version": "1.4",
 "bounds": [minx, miny, minz, maxx, maxy, maxz], "scale": [sx, sy, sz], "offset": [ox, oy, oz],
 "copc": {"center": [cx, cy, cz], "halfsize": 499.99, "spacing": 7.81,
          "rootHierOffset": 452368000, "rootHierSize": 78560, "gpsTime": [min, max]},
 "crs": {"definition": "EPSG:6339+5703", "wkt": "COMPD_CS[...]"}}
```

CORS headers on every response (unless `--cors none`):
`Access-Control-Allow-Origin`, `Allow-Methods: GET, HEAD, OPTIONS`,
`Allow-Headers: Range, Content-Type, If-None-Match`,
`Expose-Headers: Content-Range, Content-Length, Accept-Ranges, ETag`. `/data`
responses are never compressed (that would break ranges).

## The viewer page

`viewer/index.html` + `viewer/pcax.js` + `viewer/pcax.css` are pcax's; the
rest of `viewer/` is vendored Potree (BSD-2, `viewer/LICENSES/`, pinned in
`viewer/UPSTREAM.md`). The page loads the index, shows a file picker (points,
size, CRS on hover; `?f=a.copc.laz,b.copc.laz` preselects), and maps the
panel to Potree's API:

| Control | Potree |
|---|---|
| file checkbox | `Potree.loadPointCloud(url)` (CopcLoader → copc.js `Range` fetches) / `pointcloud.visible` |
| colour by | `material.activeAttributeName` — RGB, elevation (TURBO gradient), classification, intensity, returns, GPS time, point source, level of detail, and every extra-bytes attribute the file carries |
| range min/max/auto | `material.elevationRange` / `intensityRange` / `setRange(name, [a, b])` |
| classes | `viewer.setClassificationVisibility(code, bool)` (chips; all / none) |
| clip: add box / draw / clear / mode | `Potree.BoxVolume` with `clip = true` sized to the visible cloud, `viewer.volumeTool.startInsertion({clip: true})`, `viewer.setClipTask(SHOW_INSIDE | SHOW_OUTSIDE | HIGHLIGHT | NONE)` |
| EDL / budget / size | `setEDLEnabled`, `setPointBudget` (default 10M), `material.size` (adaptive point size) |

Potree's sidebar (appearance, tools: measure, profile, clip, camera) is
available via the menu button.

## Deployment

- Docker: the runtime image exposes 8080 —
  `docker run --rm -p 8080:8080 -v /tiles:/data pcax serve /data --bind 0.0.0.0`.
  TLS/auth belong to the ingress in front of it.
- Any static host works too: COPC only needs `Range` + CORS. `pcax serve`
  is the batteries-included option; nginx/caddy/S3 serve the same files.

## Tests

- `ctest -L serve`: `test_copc_index` (name validation, header/VLR probe,
  JSON) and `tests/serve/test_serve.sh` (a live server on an ephemeral port:
  index, HEAD, single / suffix / multipart ranges byte-compared with `dd`,
  416, CORS preflight, traversal and non-COPC names → 404, viewer assets +
  WASM MIME, 16 concurrent range fetches).
- `tests/integration/test_serve.py` (`serve` marker): the same contract from
  Python against a `write.copc` output of the fixture.
