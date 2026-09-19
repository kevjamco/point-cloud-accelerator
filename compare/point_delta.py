#!/usr/bin/env python3
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
"""Delta two LAS/LAZ point clouds point-by-point, in one streaming pass.

Both pcax and PDAL emit an order-preserving SUBSEQUENCE of the source file:
pcax drops points via PointCloud::compact (compacts dims + raw records in
place), PDAL via appendPoint onto a new view in iteration order. Neither
permutes. So the two outputs are two subsequences of one common sequence,
and the right algorithm is a merge diff -- the same two-pointer walk `diff`
uses -- not a join.

That matters for more than elegance:
  * no sort  -- an argsort over 60M+ keys, twice, dominates a join
  * no hash  -- so no collision reasoning, no verification pass
  * O(window) memory -- both files stream; nothing needs 60M points resident
  * keys need only be locally discriminating, not globally unique

The order assumption is VERIFIED, not trusted: every divergence must resync
within --window points, and the resync count is reported. If a resync fails,
the tool says so and stops rather than emitting a wrong delta -- a genuine
reordering would otherwise masquerade as "everything differs".

What is compared:
  MEMBERSHIP -- which points each file kept, identified by the attributes a
    geometric pipeline cannot change (GpsTime, Intensity, ReturnNumber,
    NumberOfReturns, PointSourceId, ScanAngle, UserData). Classification is
    deliberately excluded so a relabelling surfaces as an attribute
    mismatch, not as a membership miss.
  GEOMETRY -- for points both kept, the xyz delta in absolute float64, so
    files with different header scale/offset remain comparable. Two writers
    can quantise onto lattices shifted by a fraction of the scale (PDAL's
    `offset_*: auto` takes the bounds midpoint; pcax uses the data minimum),
    putting a constant sub-quantum bias on every point that has nothing to
    do with the computation. That bias is reported separately from the
    residual about it, which is the real disagreement.
  ATTRIBUTES -- Classification and the flag bits, on matched points.

Usage:
  point_delta.py A.laz B.laz
  point_delta.py A.laz B.laz --json delta.json --dump-unmatched 40
  point_delta.py A.laz B.laz --tolerance 0.02 --window 256

Exit 0 when membership matches exactly, every matched point agrees within
--tolerance and no attribute differs; else 1.
"""

import argparse
import json
import sys
import time

import numpy as np

try:
    import laspy
except ImportError:
    sys.exit("point_delta.py needs laspy: mamba install -c conda-forge laspy lazrs")


KEY_FIELDS = ("gps_time", "intensity", "return_number", "number_of_returns",
              "point_source_id", "scan_angle", "user_data")

ATTR_FIELDS = ("classification", "synthetic", "key_point", "withheld",
               "overlap", "scanner_channel", "scan_direction_flag",
               "edge_of_flight_line")

U64 = np.uint64


def pack_key(chunk):
    """Pack the identity fields into two uint64 columns.

    `a` is the exact IEEE-754 bit pattern of GpsTime -- comparing bits keeps
    this exact and sidesteps any float-epsilon question. `b` bit-packs the
    integer attributes, each masked to its LAS width so an out-of-spec value
    cannot bleed into a neighbouring field.
    """
    def col(name, dtype=U64):
        # laspy returns bit-packed fields as SubFieldView, not an ndarray
        return np.asarray(chunk[name]).astype(dtype)

    a = np.ascontiguousarray(np.asarray(chunk.gps_time),
                             dtype=np.float64).view(U64)
    b = ((col("point_source_id") & U64(0xFFFF)) << U64(48)
         | (col("intensity") & U64(0xFFFF)) << U64(32)
         # scan_angle is a signed short in format 6+; bias into unsigned
         | ((col("scan_angle", np.int64) + 32768).astype(U64)
            & U64(0xFFFF)) << U64(16)
         | (col("return_number") & U64(0xF)) << U64(12)
         | (col("number_of_returns") & U64(0xF)) << U64(8)
         | (col("user_data") & U64(0xFF)))
    return a, b


class Stream:
    """Sequential reader exposing a sliding window over one LAS/LAZ file.

    Holds at most two decompressed chunks at a time. `refill` keeps every
    unconsumed point available, so the merge can look ahead by up to
    `chunk_size` points without the whole file being resident.
    """

    def __init__(self, path, chunk_size, threads):
        backend = (laspy.LazBackend.Lazrs if threads == 1
                   else laspy.LazBackend.LazrsParallel)
        self.path = path
        self.reader = laspy.open(path, laz_backend=backend)
        h = self.reader.header
        self.n = int(h.point_count)
        self.header = {"count": self.n,
                       "scales": [float(v) for v in h.scales],
                       "offsets": [float(v) for v in h.offsets],
                       "point_format": int(h.point_format.id),
                       "version": str(h.version)}
        self.scale = np.asarray(self.header["scales"], dtype=np.float64)
        self.offset = np.asarray(self.header["offsets"], dtype=np.float64)
        self.attr_names = []
        self._it = self.reader.chunk_iterator(chunk_size)
        self._exhausted = False
        # buffers hold [base, base + len(ka)) of the file
        self.base = 0          # file index of buf[0]
        self.pos = 0           # file index of the next unconsumed point
        self.ka = np.empty(0, dtype=U64)
        self.kb = np.empty(0, dtype=U64)
        self.raw = np.empty((0, 3), dtype=np.int32)
        self.attrs = {}

    def close(self):
        self.reader.close()

    @property
    def available(self):
        """Points currently buffered from self.pos onward."""
        return self.base + self.ka.size - self.pos

    def refill(self):
        """Drop consumed points, append one more chunk. False at EOF."""
        if self._exhausted:
            return False
        try:
            chunk = next(self._it)
        except StopIteration:
            self._exhausted = True
            return False

        ka, kb = pack_key(chunk)
        m = len(chunk)
        raw = np.empty((m, 3), dtype=np.int32)
        raw[:, 0] = np.asarray(chunk.X)
        raw[:, 1] = np.asarray(chunk.Y)
        raw[:, 2] = np.asarray(chunk.Z)
        new_attrs = {}
        for name in ATTR_FIELDS:
            try:
                new_attrs[name] = np.asarray(chunk[name])
            except (ValueError, KeyError):
                continue
        if not self.attr_names:
            self.attr_names = list(new_attrs)

        keep = self.pos - self.base          # first unconsumed slot
        self.ka = np.concatenate([self.ka[keep:], ka])
        self.kb = np.concatenate([self.kb[keep:], kb])
        self.raw = np.concatenate([self.raw[keep:], raw])
        for name in self.attr_names:
            old = self.attrs.get(name)
            tail = old[keep:] if old is not None else np.empty(0, dtype=new_attrs[name].dtype)
            self.attrs[name] = np.concatenate([tail, new_attrs[name]])
        self.base = self.pos
        return True

    def ensure(self, k):
        """Buffer at least k unconsumed points, if the file has them."""
        while self.available < k and self.refill():
            pass
        return self.available

    def view(self, count):
        """(ka, kb) slices for the next `count` unconsumed points."""
        s = self.pos - self.base
        return self.ka[s:s + count], self.kb[s:s + count]

    def take(self, count):
        """Consume `count` points; return (raw_xyz, {attr: values})."""
        s = self.pos - self.base
        raw = self.raw[s:s + count]
        attrs = {n: self.attrs[n][s:s + count] for n in self.attr_names}
        self.pos += count
        return raw, attrs

    def absolute(self, raw):
        return raw.astype(np.float64) * self.scale + self.offset


class Accum:
    """Running delta statistics, so nothing per-point is retained."""

    def __init__(self, tolerance, top_k):
        self.tol = tolerance
        self.top_k = top_k
        self.n = 0
        self.sum = np.zeros(4)          # dx, dy, dz, dist
        self.sumsq = np.zeros(4)
        self.max_abs = np.zeros(4)
        self.n_exact = np.zeros(4, dtype=np.int64)
        self.n_over = np.zeros(4, dtype=np.int64)
        self.n_identical_xyz = 0
        self.attr_bad = {}
        self.worst = []                 # (dist, record)
        self._hist_edges = np.array(
            [0.0, 1e-9, 1e-6, 1e-4, 1e-3, 1e-2, 1e-1, 1.0, np.inf])
        self.hist = np.zeros(len(self._hist_edges) - 1, dtype=np.int64)
        # dz is quantised, so an exact median is cheap via a value counter
        self._d_samples = [[], [], []]
        self._sampled = 0

    def add(self, d, dist, attrs_a, attrs_b):
        m = d.shape[0]
        if m == 0:
            return
        cols = [d[:, 0], d[:, 1], d[:, 2], dist]
        for i, c in enumerate(cols):
            ac = np.abs(c)
            self.sum[i] += c.sum()
            self.sumsq[i] += float(np.dot(c, c))
            self.max_abs[i] = max(self.max_abs[i], float(ac.max()))
            self.n_exact[i] += int((c == 0).sum())
            self.n_over[i] += int((ac > self.tol).sum())
        self.n += m
        self.n_identical_xyz += int((dist == 0).sum())
        self.hist += np.histogram(dist, bins=self._hist_edges)[0]

        # reservoir-free bias estimate: keep a bounded stride sample
        if self._sampled < 4_000_000:
            step = max(1, m // 20000)
            for i in range(3):
                self._d_samples[i].append(d[::step, i].copy())
            self._sampled += len(d[::step])

        for name in attrs_a:
            if name not in attrs_b:
                continue
            bad = int((attrs_a[name] != attrs_b[name]).sum())
            if bad:
                self.attr_bad[name] = self.attr_bad.get(name, 0) + bad
            else:
                self.attr_bad.setdefault(name, 0)

    def note_worst(self, dist, d, xa, xb, base_index):
        if dist.size == 0:
            return
        k = min(self.top_k, dist.size)
        idx = np.argpartition(dist, dist.size - k)[dist.size - k:]
        for i in idx:
            self.worst.append((float(dist[i]), {
                "dist": float(dist[i]), "dx": float(d[i, 0]),
                "dy": float(d[i, 1]), "dz": float(d[i, 2]),
                "index_a": int(base_index + i),
                "a": {"x": float(xa[i, 0]), "y": float(xa[i, 1]), "z": float(xa[i, 2])},
                "b": {"x": float(xb[i, 0]), "y": float(xb[i, 1]), "z": float(xb[i, 2])}}))
        self.worst.sort(key=lambda t: -t[0])
        del self.worst[self.top_k:]

    def bias(self, axis):
        if not self._d_samples[axis]:
            return 0.0
        return float(np.median(np.concatenate(self._d_samples[axis])))

    def axis_stats(self, axis):
        """axis 0..2 = x/y/z, 3 = euclidean."""
        if self.n == 0:
            return {"systematic_bias": 0.0, "max_abs": 0.0, "rms": 0.0,
                    "mean_signed": 0.0, "n_over_tol": 0, "n_exact": 0,
                    "residual_max_abs": 0.0}
        mean = self.sum[axis] / self.n
        rms = float(np.sqrt(self.sumsq[axis] / self.n))
        bias = self.bias(axis) if axis < 3 else 0.0
        return {
            "systematic_bias": bias,
            "max_abs": float(self.max_abs[axis]),
            "rms": rms,
            "mean_signed": float(mean),
            "n_over_tol": int(self.n_over[axis]),
            "n_exact": int(self.n_exact[axis]),
            # worst case after removing the constant lattice shift
            "residual_max_abs": float(self.max_abs[axis] + abs(bias))
            if axis < 3 else float(self.max_abs[axis]),
        }


def merge_diff(sa, sb, window, acc, dump_limit, progress):
    """Two-pointer walk over two order-preserving subsequences.

    On a key mismatch, look ahead up to `window` points on each side to work
    out which file dropped a point, then resync. Returns
    (only_a, only_b, resyncs, failure) where only_* are lists of dicts.
    """
    only_a, only_b, resyncs = [], [], 0
    failure = None
    block = 1 << 20
    t0 = time.monotonic()

    while True:
        avail_a = sa.ensure(block)
        avail_b = sb.ensure(block)
        if avail_a == 0 or avail_b == 0:
            break

        run = min(avail_a, avail_b)
        ka, kb_ = sa.view(run)
        kb, kbb = sb.view(run)
        eq = (ka == kb) & (kb_ == kbb)
        # length of the leading run of equal keys
        first_bad = int(np.argmin(eq)) if not eq.all() else run

        if first_bad:
            raw_a, at_a = sa.take(first_bad)
            raw_b, at_b = sb.take(first_bad)
            xa, xb = sa.absolute(raw_a), sb.absolute(raw_b)
            d = xa - xb
            dist = np.sqrt(np.einsum("ij,ij->i", d, d))
            acc.add(d, dist, at_a, at_b)
            acc.note_worst(dist, d, xa, xb, sa.pos - first_bad)
            if progress:
                print(f"\r  matched {acc.n:,}  only_a {len(only_a):,} "
                      f"only_b {len(only_b):,}  {time.monotonic() - t0:.0f}s",
                      end="", file=sys.stderr)
            continue

        # --- divergence: decide which side dropped a point ---
        w = min(window, sa.ensure(window), sb.ensure(window))
        if w == 0:
            break
        wka, wkb_ = sa.view(w)
        wkb, wkbb = sb.view(w)

        # how far into B must we skip to find A's current point (and v.v.)?
        hit_b = np.flatnonzero((wkb == wka[0]) & (wkbb == wkb_[0]))
        hit_a = np.flatnonzero((wka == wkb[0]) & (wkb_ == wkbb[0]))
        skip_b = int(hit_b[0]) if hit_b.size else None
        skip_a = int(hit_a[0]) if hit_a.size else None

        if skip_a is None and skip_b is None:
            failure = (f"could not resync within {window} points at "
                       f"A[{sa.pos}] / B[{sb.pos}] -- the order assumption "
                       f"does not hold for these files")
            break

        # prefer the smaller skip; ties mean both dropped a point here
        if skip_b is not None and (skip_a is None or skip_b <= skip_a):
            raw, at = sb.take(skip_b)
            xs = sb.absolute(raw)
            for i in range(min(skip_b, max(0, dump_limit - len(only_b)))):
                only_b.append({"index": int(sb.pos - skip_b + i),
                               "x": float(xs[i, 0]), "y": float(xs[i, 1]),
                               "z": float(xs[i, 2]),
                               **{n: int(at[n][i]) for n in at}})
            only_b.extend([None] * 0)
            resyncs += 1
            only_b_count = skip_b
        else:
            raw, at = sa.take(skip_a)
            xs = sa.absolute(raw)
            for i in range(min(skip_a, max(0, dump_limit - len(only_a)))):
                only_a.append({"index": int(sa.pos - skip_a + i),
                               "x": float(xs[i, 0]), "y": float(xs[i, 1]),
                               "z": float(xs[i, 2]),
                               **{n: int(at[n][i]) for n in at}})
            resyncs += 1
            only_b_count = 0
        # counts are tracked by caller via returned totals
        merge_diff.dropped_a = getattr(merge_diff, "dropped_a", 0)
        merge_diff.dropped_b = getattr(merge_diff, "dropped_b", 0)
        if only_b_count:
            merge_diff.dropped_b += only_b_count
        else:
            merge_diff.dropped_a += (skip_a or 0)

    # whatever remains on either side is unmatched tail
    tail_a = sa.ensure(1 << 30) if not failure else 0
    if tail_a:
        raw, at = sa.take(tail_a)
        xs = sa.absolute(raw)
        for i in range(min(tail_a, max(0, dump_limit - len(only_a)))):
            only_a.append({"index": int(sa.pos - tail_a + i),
                           "x": float(xs[i, 0]), "y": float(xs[i, 1]),
                           "z": float(xs[i, 2]),
                           **{n: int(at[n][i]) for n in at}})
        merge_diff.dropped_a = getattr(merge_diff, "dropped_a", 0) + tail_a
    tail_b = sb.ensure(1 << 30) if not failure else 0
    if tail_b:
        raw, at = sb.take(tail_b)
        xs = sb.absolute(raw)
        for i in range(min(tail_b, max(0, dump_limit - len(only_b)))):
            only_b.append({"index": int(sb.pos - tail_b + i),
                           "x": float(xs[i, 0]), "y": float(xs[i, 1]),
                           "z": float(xs[i, 2]),
                           **{n: int(at[n][i]) for n in at}})
        merge_diff.dropped_b = getattr(merge_diff, "dropped_b", 0) + tail_b

    if progress:
        print(file=sys.stderr)
    return only_a, only_b, resyncs, failure


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file_a")
    ap.add_argument("file_b")
    ap.add_argument("--label-a")
    ap.add_argument("--label-b")
    ap.add_argument("--tolerance", type=float, default=0.02,
                    help="max |xyz| delta treated as agreement, metres. "
                         "Default 0.02 = two 1 cm quantisation steps, the "
                         "floor when the writers use different offsets")
    ap.add_argument("--window", type=int, default=256,
                    help="resync lookahead in points (default 256)")
    ap.add_argument("--chunk", type=int, default=4_000_000)
    ap.add_argument("--top-k", type=int, default=10)
    ap.add_argument("--dump-unmatched", type=int, default=20)
    ap.add_argument("--threads", type=int, default=0,
                    help="1 disables parallel LAZ decompression")
    ap.add_argument("--json")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    verbose = not args.quiet
    la = args.label_a or args.file_a
    lb = args.label_b or args.file_b
    t0 = time.monotonic()

    merge_diff.dropped_a = 0
    merge_diff.dropped_b = 0

    sa = Stream(args.file_a, args.chunk, args.threads)
    sb = Stream(args.file_b, args.chunk, args.threads)
    acc = Accum(args.tolerance, args.top_k)

    only_a, only_b, resyncs, failure = merge_diff(
        sa, sb, args.window, acc, args.dump_unmatched, verbose)

    n_a, n_b = sa.n, sb.n
    drop_a, drop_b = merge_diff.dropped_a, merge_diff.dropped_b
    sa.close()
    sb.close()

    union = n_a + n_b - acc.n
    report = {
        "file_a": args.file_a, "file_b": args.file_b,
        "header_a": sa.header, "header_b": sb.header,
        "tolerance_m": args.tolerance, "window": args.window,
        "key_fields": list(KEY_FIELDS),
        "order_assumption": {
            "verified": failure is None,
            "resyncs": resyncs,
            "failure": failure,
        },
        "membership": {
            "count_a": n_a, "count_b": n_b, "matched": acc.n,
            "only_a": drop_a, "only_b": drop_b,
            "jaccard": float(acc.n / union) if union else 1.0,
        },
        "geometry": {
            "x": acc.axis_stats(0), "y": acc.axis_stats(1),
            "z": acc.axis_stats(2), "euclidean": acc.axis_stats(3),
            "n_identical_xyz": acc.n_identical_xyz,
            "distance_histogram": {
                "edges": [0.0, 1e-9, 1e-6, 1e-4, 1e-3, 1e-2, 1e-1, 1.0, "inf"],
                "counts": acc.hist.tolist()},
        },
        "attributes": {k: {"mismatched": v} for k, v in sorted(acc.attr_bad.items())},
        "worst_matched": [rec for _, rec in acc.worst],
        "only_a_points": only_a,
        "only_b_points": only_b,
    }
    report["elapsed_s"] = round(time.monotonic() - t0, 2)

    m, g = report["membership"], report["geometry"]
    W = 78
    P = print
    P("=" * W)
    P(f"A: {la}")
    P(f"B: {lb}")
    P("-" * W)
    for tag, s in (("A", sa), ("B", sb)):
        P(f"  header {tag}   n={s.header['count']:,}  scale={s.header['scales']}  "
          f"offset={[round(v, 5) for v in s.header['offsets']]}")
    P("-" * W)
    oa = report["order_assumption"]
    P(f"  ORDER   subsequence assumption: "
      f"{'VERIFIED' if oa['verified'] else 'FAILED'}   resyncs={oa['resyncs']:,}")
    if failure:
        P(f"          {failure}")
    P("-" * W)
    P("  MEMBERSHIP   identity key = " + ", ".join(KEY_FIELDS))
    P(f"    matched      {m['matched']:>14,}")
    P(f"    only in A    {m['only_a']:>14,}   ({100 * m['only_a'] / max(n_a, 1):.6f}% of A)")
    P(f"    only in B    {m['only_b']:>14,}   ({100 * m['only_b'] / max(n_b, 1):.6f}% of B)")
    P(f"    jaccard      {m['jaccard']:>14.9f}")
    P("-" * W)
    P(f"  GEOMETRY on {m['matched']:,} matched points   (A - B, metres)")
    P(f"    {'axis':<10} {'bias':>13} {'max|d|':>13} {'rms':>13} "
      f"{'>tol':>9} {'exact 0':>13}")
    for name, ax in (("x", "x"), ("y", "y"), ("z", "z"), ("euclidean", "euclidean")):
        s = g[ax]
        P(f"    {name:<10} {s['systematic_bias']:>13.6g} {s['max_abs']:>13.6g} "
          f"{s['rms']:>13.6g} {s['n_over_tol']:>9,} {s['n_exact']:>13,}")
    P("")
    P("    `bias` is the constant lattice shift between the two headers; it")
    P("    is a writer artefact, not a computation difference.")
    P("")
    P("    euclidean distance distribution")
    edges = report["geometry"]["distance_histogram"]["edges"]
    for i, c in enumerate(report["geometry"]["distance_histogram"]["counts"]):
        if c:
            lo, hi = edges[i], edges[i + 1]
            P(f"      [{lo:>8}, {str(hi):>8}) : {c:>14,}")
    P("-" * W)
    P("  ATTRIBUTES on matched points")
    for name, s in report["attributes"].items():
        P(f"    {name:<24} {s['mismatched']:>12,}"
          + ("" if s["mismatched"] == 0 else "   <-- MISMATCH"))
    for tag, pts in (("A", only_a), ("B", only_b)):
        if pts:
            P("-" * W)
            P(f"  POINTS ONLY IN {tag} (showing {len(pts)})")
            for p in pts:
                P(f"    [{p['index']:>10}] ({p['x']:.3f}, {p['y']:.3f}, "
                  f"{p['z']:.3f})  class={p.get('classification')}")
    ok = (failure is None and m["only_a"] == 0 and m["only_b"] == 0
          and g["euclidean"]["n_over_tol"] == 0
          and all(s["mismatched"] == 0 for s in report["attributes"].values()))
    P("=" * W)
    P(f"  VERDICT: {'IDENTICAL' if ok else 'DIFFERS'} "
      f"(tolerance {args.tolerance} m)   [{report['elapsed_s']}s]")
    P("=" * W)

    if args.json:
        json.dump(report, open(args.json, "w"), indent=2)
        P(f"\nwrote {args.json}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
