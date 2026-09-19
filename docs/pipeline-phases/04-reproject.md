# Phase 4 — Reproject (`filter.reproject`)

## What it does

Transforms coordinates from the source CRS to a target CRS. Here the source is
NAD83(2011) geographic (degrees) and the target is **UTM 17N + NAVD88**
(`EPSG:26917+5703`). The pipeline supplies a **raw PROJ pipeline string**
rather than letting pcax plan the operation from CRS endpoints — this is the
exact analogue of PDAL's `filters.projpipeline` with a `coord_op`.

`filter.reproject` runs on **GPU**: the PROJ pipeline is compiled step-by-step
into GPU op descriptors and applied in the chosen precision (`fp64` for full
accuracy; `fp32` is a ~metre-level dev-mode toggle). Any step outside the GPU
op set falls back to CPU PROJ with a warning. Because reprojection rewrites
XYZ, the stage sets `coordsDirty = true` and renormalizes (`offset == dataMin`,
`minRaw == 0`); the writer reconstructs exact int32 from there. See
[../Reprojection.md](../Reprojection.md).

When a raw `pipeline:` is given, `out_srs` is used **only** to label the output
CRS (the VLR/WKT written to file) — it does not re-plan the math. pcax logs a
warning to make that explicit. That label also becomes the cloud CRS
(`metadata().overrideCrsWkt`), which `writer.gdal_gpu` carries into rasters
automatically — compound codes like `EPSG:26917+5703` survive end-to-end, so
downstream writers need no `override_srs`.

## pcax

```yaml
reproject:
  type: filter.reproject
  input: keep_classes   # since 2026-06-12 reproject runs before denoise
  pipeline: "proj=pipeline step proj=unitconvert xy_in=deg xy_out=rad step proj=utm zone=17 ellps=GRS80"
  out_srs: "EPSG:26917+5703"
  precision: fp64
```

## PDAL equivalent

```json
{ "type": "filters.projpipeline",
  "coord_op": "proj=pipeline step proj=unitconvert xy_in=deg xy_out=rad step proj=utm zone=17 ellps=GRS80",
  "out_srs": "EPSG:26917+5703" }
```

## Following the run

```
reproject: 'pipeline' given, 'out_srs' used only for the CRS VLR
reproject: user pipeline (declared accuracy: unknown)
reproject: done (gpu, fp64)
```

- 35,106,991 points reprojected; degrees → UTM 17N metres.
- Phase time: 434 ms total (plan 20 ms, GPU op chain 86 ms; the rest is the
  residency download for the next CPU stage).
- After this phase, X/Y are easting/northing in the 532000–536000 /
  2796000–2800000 range expected by the crop in phase 5.
