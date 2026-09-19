#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""Compare GeoTIFF rasters for functional equivalence.

Built to answer two questions at once about a pair (or set) of rasters:
  1. Are they functionally identical? (size, CRS, geotransform, nodata,
     dtype, band layout, and data-coverage overlap via IoU)
  2. If the values differ, by how much? — reported so that a SINGLE
     anomalous cell is as visible as a systematic bias:
       * bias            -> signed mean / median difference
       * spread          -> std, RMSE, MAE
       * worst outlier   -> max |diff| with its world coordinate + both
                            values, plus the top-K offenders
       * distribution    -> |diff| percentiles (50/90/95/99/99.9/max)
       * threshold tail  -> count & fraction of cells over each tolerance

Grid handling: the two rasters need not share an origin or size. The tool
intersects their world extents and compares cell-to-cell on the overlap.
When the grids are pixel-aligned (same resolution, integer cell offset) the
overlap is sliced EXACTLY -- no resampling -- so a lone outlier cell is
preserved. If they are not aligned, the candidate is warped onto the
reference grid (default bilinear; --resample nearest to preserve extrema)
and the report flags that resampling occurred.

Usage:
  compare_geotiffs.py REF.tif CAND.tif [CAND2.tif ...]
  compare_geotiffs.py --dir-a DIR_A --dir-b DIR_B   # match by basename

  --atol FLOAT          max |diff| for "identical" verdict   (default 1e-3)
  --iou-threshold FLOAT min coverage IoU for "identical"     (default 0.999)
  --align-eps FLOAT     px frac offset tolerated as aligned  (default 0.02)
  --resample {bilinear,nearest,cubic}  used only when unaligned (default bilinear)
  --top-k INT           number of worst-diff cells to list   (default 10)
  --band-match {auto,name,index}  how to pair bands          (default auto)
  --diff-out DIR        write (ref - cand) difference GeoTIFFs here
  --json PATH           also emit a machine-readable JSON report

Exit code is 0 when every comparison is functionally identical, else 1.
"""

import argparse
import json
import math
import os
import sys

import numpy as np

try:
    from osgeo import gdal, osr
except ImportError:
    sys.exit("error: GDAL Python bindings (osgeo) required")

gdal.UseExceptions()

RESAMPLE = {
    "nearest": gdal.GRA_NearestNeighbour,
    "bilinear": gdal.GRA_Bilinear,
    "cubic": gdal.GRA_Cubic,
}


# ---------------------------------------------------------------------------
# Profile (everything except the pixel values)
# ---------------------------------------------------------------------------

def read_profile(path):
    ds = gdal.Open(path)
    if ds is None:
        raise RuntimeError(f"cannot open {path}")
    gt = ds.GetGeoTransform()
    srs = osr.SpatialReference()
    wkt = ds.GetProjection()
    epsg = None
    if wkt:
        srs.ImportFromWkt(wkt)
        srs.AutoIdentifyEPSG()
        epsg = srs.GetAuthorityCode(None)
    bands = []
    for b in range(1, ds.RasterCount + 1):
        band = ds.GetRasterBand(b)
        bands.append({
            "index": b,
            "desc": band.GetDescription() or "",
            "dtype": gdal.GetDataTypeName(band.DataType),
            "nodata": band.GetNoDataValue(),
        })
    prof = {
        "path": path,
        "file_bytes": os.path.getsize(path),
        "width": ds.RasterXSize,
        "height": ds.RasterYSize,
        "bands": bands,
        "band_count": ds.RasterCount,
        "geotransform": list(gt),
        "pixel_w": gt[1],
        "pixel_h": -gt[5],
        "rotated": gt[2] != 0.0 or gt[4] != 0.0,
        "crs_wkt": wkt,
        "epsg": epsg,
        "extent": raster_extent(gt, ds.RasterXSize, ds.RasterYSize),
        "_srs": srs,
        "_ds": ds,
    }
    return prof


def raster_extent(gt, nx, ny):
    """(xmin, ymin, xmax, ymax) for a north-up geotransform."""
    xmin = gt[0]
    xmax = gt[0] + nx * gt[1]
    ymax = gt[3]
    ymin = gt[3] + ny * gt[5]
    return (xmin, ymin, xmax, ymax)


def crs_equal(a, b):
    if not a["crs_wkt"] and not b["crs_wkt"]:
        return True
    if not a["crs_wkt"] or not b["crs_wkt"]:
        return False
    return bool(a["_srs"].IsSame(b["_srs"]))


# ---------------------------------------------------------------------------
# Value extraction over the shared overlap
# ---------------------------------------------------------------------------

def valid_mask(arr, nodata):
    m = np.isfinite(arr)
    if nodata is not None and not (isinstance(nodata, float) and math.isnan(nodata)):
        m &= (arr != nodata)
    return m


def overlap_arrays(ref, cand, ref_band, cand_band, align_eps, resample):
    """Return (a, b, origin_x, origin_y, px, py, resampled, note) where a/b are
    float64 arrays of identical shape covering the geographic overlap, sampled
    cell-for-cell. origin_x/origin_y is the top-left corner of the window."""
    gtA, gtB = ref["geotransform"], cand["geotransform"]
    pxA, pyA = ref["pixel_w"], ref["pixel_h"]
    pxB, pyB = cand["pixel_w"], cand["pixel_h"]

    same_res = (abs(pxA - pxB) < 1e-9 and abs(pyA - pyB) < 1e-9)
    # integer cell offset between origins?
    fx = (gtB[0] - gtA[0]) / pxA
    fy = (gtA[3] - gtB[3]) / pyA
    aligned = (same_res and not ref["rotated"] and not cand["rotated"]
               and abs(fx - round(fx)) <= align_eps
               and abs(fy - round(fy)) <= align_eps)

    xminA, yminA, xmaxA, ymaxA = ref["extent"]
    xminB, yminB, xmaxB, ymaxB = cand["extent"]
    ox = max(xminA, xminB)
    oy_top = min(ymaxA, ymaxB)
    ex = min(xmaxA, xmaxB)
    oy_bot = max(yminA, yminB)
    if ex - ox <= 0 or oy_top - oy_bot <= 0:
        return None  # no overlap

    if aligned:
        w = int(round((ex - ox) / pxA))
        h = int(round((oy_top - oy_bot) / pyA))
        cA = int(round((ox - xminA) / pxA)); rA = int(round((ymaxA - oy_top) / pyA))
        cB = int(round((ox - xminB) / pxB)); rB = int(round((ymaxB - oy_top) / pyB))
        a = ref["_ds"].GetRasterBand(ref_band).ReadAsArray(cA, rA, w, h).astype(np.float64)
        b = cand["_ds"].GetRasterBand(cand_band).ReadAsArray(cB, rB, w, h).astype(np.float64)
        return a, b, ox, oy_top, pxA, pyA, False, "exact slice (pixel-aligned)"

    # unaligned: warp candidate onto the reference grid, then slice the overlap
    warped = gdal.Warp("", cand["_ds"], format="MEM", outputBounds=(xminA, yminA, xmaxA, ymaxA),
                       width=ref["width"], height=ref["height"],
                       resampleAlg=RESAMPLE[resample], srcBands=[cand_band], dstBands=[1])
    a = ref["_ds"].GetRasterBand(ref_band).ReadAsArray().astype(np.float64)
    b = warped.GetRasterBand(1).ReadAsArray().astype(np.float64)
    note = (f"resampled candidate -> reference grid ({resample}); "
            f"origin offset {fx:.3f},{fy:.3f} px, same_res={same_res}")
    return a, b, xminA, ymaxA, pxA, pyA, True, note


# ---------------------------------------------------------------------------
# Per-band comparison
# ---------------------------------------------------------------------------

def compare_band(ref, cand, ref_band, cand_band, args):
    nd_ref = next(x["nodata"] for x in ref["bands"] if x["index"] == ref_band)
    nd_cand = next(x["nodata"] for x in cand["bands"] if x["index"] == cand_band)

    ov = overlap_arrays(ref, cand, ref_band, cand_band, args.align_eps, args.resample)
    if ov is None:
        return {"overlap": False}
    a, b, ox, oy, px, py, resampled, note = ov

    ma = valid_mask(a, nd_ref)
    mb = valid_mask(b, nd_cand)
    both = ma & mb
    inter = int(both.sum())
    union = int((ma | mb).sum())
    iou = (inter / union) if union else float("nan")

    res = {
        "overlap": True,
        "resampled": resampled,
        "note": note,
        "overlap_cells": int(a.size),
        "valid_ref": int(ma.sum()),
        "valid_cand": int(mb.sum()),
        "valid_both": inter,
        "only_ref": int((ma & ~mb).sum()),
        "only_cand": int((mb & ~ma).sum()),
        "iou": iou,
    }
    if inter == 0:
        res["diff"] = None
        return res

    diff = a[both] - b[both]
    adiff = np.abs(diff)
    # locate the single worst cell
    flat_idx = np.flatnonzero(both)
    worst_local = int(np.argmax(adiff))
    worst_flat = int(flat_idx[worst_local])
    wr, wc = np.unravel_index(worst_flat, a.shape)
    wx = ox + (wc + 0.5) * px
    wy = oy - (wr + 0.5) * py

    def frac_over(t):
        return float((adiff > t).sum()) / adiff.size

    res["diff"] = {
        "n": int(diff.size),
        "bias_mean": float(diff.mean()),
        "bias_median": float(np.median(diff)),
        "std": float(diff.std()),
        "rmse": float(np.sqrt((diff ** 2).mean())),
        "mae": float(adiff.mean()),
        "min_signed": float(diff.min()),
        "max_signed": float(diff.max()),
        "max_abs": float(adiff.max()),
        "corr": (float(np.corrcoef(a[both], b[both])[0, 1]) if diff.size > 1
                 and a[both].std() > 0 and b[both].std() > 0 else float("nan")),
        "pctile_abs": {
            "p50": float(np.percentile(adiff, 50)),
            "p90": float(np.percentile(adiff, 90)),
            "p95": float(np.percentile(adiff, 95)),
            "p99": float(np.percentile(adiff, 99)),
            "p99.9": float(np.percentile(adiff, 99.9)),
        },
        "tail": {f"gt_{t}": frac_over(t) for t in (args.atol, 0.01, 0.1, 1.0)},
        "worst": {
            "abs_diff": float(adiff[worst_local]),
            "ref_value": float(a[both][worst_local]),
            "cand_value": float(b[both][worst_local]),
            "row": int(wr), "col": int(wc),
            "x": float(wx), "y": float(wy),
        },
        "top_k": top_k_outliers(diff, adiff, flat_idx, a, b, both, ox, oy, px, py, args.top_k),
    }
    if args.diff_out:
        write_diff(ref, a, b, both, ref_band, cand_band, args)
    return res


def top_k_outliers(diff, adiff, flat_idx, a, b, both, ox, oy, px, py, k):
    order = np.argsort(adiff)[::-1][:k]
    out = []
    aboth = a[both]; bboth = b[both]
    for j in order:
        f = int(flat_idx[int(j)])
        r, c = np.unravel_index(f, a.shape)
        out.append({
            "abs_diff": float(adiff[int(j)]),
            "signed": float(diff[int(j)]),
            "ref": float(aboth[int(j)]), "cand": float(bboth[int(j)]),
            "x": float(ox + (c + 0.5) * px), "y": float(oy - (r + 0.5) * py),
        })
    return out


def write_diff(ref, a, b, both, ref_band, cand_band, args):
    os.makedirs(args.diff_out, exist_ok=True)
    stem = os.path.splitext(os.path.basename(ref["path"]))[0]
    out = os.path.join(args.diff_out, f"{stem}_b{ref_band}_diff.tif")
    d = np.full(a.shape, np.nan, np.float32)
    d[both] = (a[both] - b[both]).astype(np.float32)
    drv = gdal.GetDriverByName("GTiff")
    # diff is on the reference grid only when not resampled; use ref grid gt
    ds = drv.Create(out, a.shape[1], a.shape[0], 1, gdal.GDT_Float32,
                    ["COMPRESS=DEFLATE", "TILED=YES"])
    ds.SetGeoTransform(ref["geotransform"])
    ds.SetProjection(ref["crs_wkt"])
    bd = ds.GetRasterBand(1); bd.SetNoDataValue(float("nan")); bd.WriteArray(d)
    ds = None


# ---------------------------------------------------------------------------
# Band pairing
# ---------------------------------------------------------------------------

def pair_bands(ref, cand, mode):
    ra, ca = ref["bands"], cand["bands"]
    if mode in ("auto", "name"):
        rd = {x["desc"]: x["index"] for x in ra if x["desc"]}
        cd = {x["desc"]: x["index"] for x in ca if x["desc"]}
        common = [d for d in rd if d in cd]
        if common and (mode == "name" or len(common) == max(len(ra), len(ca))):
            return [(d, rd[d], cd[d]) for d in common]
        if mode == "name":
            return [(d, rd[d], cd[d]) for d in common]
    n = min(len(ra), len(ca))
    return [(f"band{i+1}", ra[i]["index"], ca[i]["index"]) for i in range(n)]


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def fmt(v, p=6):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        if math.isnan(v):
            return "nan"
        return f"{v:.{p}g}"
    return str(v)


def compare_pair(ref_path, cand_path, args):
    ref = read_profile(ref_path)
    cand = read_profile(cand_path)
    print("=" * 78)
    print(f"REF : {ref_path}")
    print(f"CAND: {cand_path}")
    print("-" * 78)

    # --- structure ---
    same_size = (ref["width"], ref["height"]) == (cand["width"], cand["height"])
    same_px = abs(ref["pixel_w"] - cand["pixel_w"]) < 1e-9 and abs(ref["pixel_h"] - cand["pixel_h"]) < 1e-9
    same_crs = crs_equal(ref, cand)
    print(f"  size        ref {ref['width']}x{ref['height']}  cand {cand['width']}x{cand['height']}   "
          f"{'MATCH' if same_size else 'DIFFER'}")
    print(f"  file bytes  ref {ref['file_bytes']:,}  cand {cand['file_bytes']:,}")
    print(f"  pixel size  ref {fmt(ref['pixel_w'])}x{fmt(ref['pixel_h'])}  "
          f"cand {fmt(cand['pixel_w'])}x{fmt(cand['pixel_h'])}   {'MATCH' if same_px else 'DIFFER'}")
    print(f"  CRS         ref EPSG:{ref['epsg']}  cand EPSG:{cand['epsg']}   "
          f"{'MATCH (semantic)' if same_crs else 'DIFFER'}")
    print(f"  extent ref  {tuple(round(v,3) for v in ref['extent'])}")
    print(f"  extent cand {tuple(round(v,3) for v in cand['extent'])}")
    print(f"  bands       ref {[b['desc'] or b['index'] for b in ref['bands']]}  "
          f"cand {[b['desc'] or b['index'] for b in cand['bands']]}")

    pairs = pair_bands(ref, cand, args.band_match)
    if not pairs:
        print("  !! no comparable bands")
        return False, {"error": "no comparable bands"}

    band_reports = {}
    band_ok = []
    for name, rb, cb in pairs:
        r = compare_band(ref, cand, rb, cb, args)
        band_reports[name] = r
        print("-" * 78)
        print(f"  band [{name}]  (ref #{rb} vs cand #{cb})")
        if not r["overlap"]:
            print("    !! extents do not overlap")
            band_ok.append(False)
            continue
        print(f"    {r['note']}")
        print(f"    coverage    valid ref {r['valid_ref']:,}  cand {r['valid_cand']:,}  "
              f"both {r['valid_both']:,}")
        print(f"    coverage    only-ref {r['only_ref']:,}  only-cand {r['only_cand']:,}  "
              f"IoU {fmt(r['iou'])}")
        d = r["diff"]
        if d is None:
            print("    !! no co-valid cells to compare")
            band_ok.append(False)
            continue
        print(f"    bias        mean {fmt(d['bias_mean'])}  median {fmt(d['bias_median'])}")
        print(f"    spread      std {fmt(d['std'])}  rmse {fmt(d['rmse'])}  mae {fmt(d['mae'])}")
        print(f"    range       signed [{fmt(d['min_signed'])}, {fmt(d['max_signed'])}]  "
              f"corr {fmt(d['corr'])}")
        p = d["pctile_abs"]
        print(f"    |diff| pct  p50 {fmt(p['p50'])}  p90 {fmt(p['p90'])}  p95 {fmt(p['p95'])}  "
              f"p99 {fmt(p['p99'])}  p99.9 {fmt(p['p99.9'])}  max {fmt(d['max_abs'])}")
        t = d["tail"]
        print(f"    tail frac   " + "  ".join(f"|d|>{k.split('_')[1]}: {fmt(v)}" for k, v in t.items()))
        w = d["worst"]
        print(f"    worst cell  |diff| {fmt(w['abs_diff'])}  ref {fmt(w['ref_value'])}  "
              f"cand {fmt(w['cand_value'])}  @ ({fmt(w['x'],8)}, {fmt(w['y'],8)})")
        ok = (d["max_abs"] <= args.atol) and (r["iou"] >= args.iou_threshold)
        band_ok.append(ok)
        print(f"    verdict     max|diff| {fmt(d['max_abs'])} <= atol {args.atol}? "
              f"{d['max_abs'] <= args.atol}   IoU >= {args.iou_threshold}? "
              f"{r['iou'] >= args.iou_threshold}   -> {'IDENTICAL' if ok else 'DIFFERS'}")

    identical = same_crs and same_px and all(band_ok)
    print("=" * 78)
    print(f"  FUNCTIONALLY IDENTICAL: {identical}   "
          f"(CRS {same_crs}, pixel {same_px}, bands {sum(band_ok)}/{len(band_ok)} ok)")
    print()
    return identical, {
        "ref": ref_path, "cand": cand_path,
        "same_size": same_size, "same_pixel": same_px, "same_crs": same_crs,
        "ref_epsg": ref["epsg"], "cand_epsg": cand["epsg"],
        "bands": band_reports, "functionally_identical": identical,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rasters", nargs="*", help="REF CAND [CAND ...]")
    ap.add_argument("--dir-a")
    ap.add_argument("--dir-b")
    ap.add_argument("--atol", type=float, default=1e-3)
    ap.add_argument("--iou-threshold", type=float, default=0.999)
    ap.add_argument("--align-eps", type=float, default=0.02)
    ap.add_argument("--resample", choices=list(RESAMPLE), default="bilinear")
    ap.add_argument("--top-k", type=int, default=10)
    ap.add_argument("--band-match", choices=["auto", "name", "index"], default="auto")
    ap.add_argument("--diff-out")
    ap.add_argument("--json")
    args = ap.parse_args()

    jobs = []
    if args.dir_a and args.dir_b:
        a_files = {f for f in os.listdir(args.dir_a) if f.lower().endswith((".tif", ".tiff"))}
        b_files = {f for f in os.listdir(args.dir_b) if f.lower().endswith((".tif", ".tiff"))}
        for f in sorted(a_files & b_files):
            jobs.append((os.path.join(args.dir_a, f), os.path.join(args.dir_b, f)))
        if not jobs:
            sys.exit("error: no common basenames between --dir-a and --dir-b")
    elif len(args.rasters) >= 2:
        ref = args.rasters[0]
        jobs = [(ref, c) for c in args.rasters[1:]]
    else:
        ap.error("provide REF CAND [...] or --dir-a/--dir-b")

    all_ok = True
    reports = []
    for ref, cand in jobs:
        ok, rep = compare_pair(ref, cand, args)
        all_ok &= ok
        reports.append(rep)

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(reports, fh, indent=2)
        print(f"wrote {args.json}")

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
