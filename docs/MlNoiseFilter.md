# filter.ml_noise — LightGBM noise classifier

GPU stage that scores every point with a LightGBM tree ensemble over 48
neighbourhood/tile features and marks points above a calibrated threshold as
noise (`Classification = 7`). The feature definitions were pinned from the
reference Python `noise_filter` pipeline the model was trained with; that
Python pipeline — not PDAL — is the parity reference for this stage. This
document records the exact contract the CUDA port honours.

## Model

The model is **user-supplied**: pcax ships the feature computation and the
inference kernel, not a trained model. Any LightGBM *text* model
(`Booster.save_model`) that satisfies the contract below will load:

- `objective=binary` (sigmoid output), numerical splits only (no categorical
  features), `max_feature_idx=47` — exactly the 48 features of the next
  section, in that order.
- A `feature_names` header. The filter validates it against its own computed
  feature order at load time and refuses to run on a mismatch, so a model
  trained on a different feature set fails loudly rather than silently.
- Any tree count / leaf count. The reference model (`lgbm_scale21_20260612_033040`,
  val F1 0.7649 / AP 0.7895, threshold 0.9336) has 4,998 trees of ≤127 leaves
  and a 70 MB text file; parsing takes ~0.3 s.

Training your own: compute the 48 features per point exactly as specified
below (`debug_features:` dumps pcax's own N × 48 float32 matrix so you can
train on pcax-computed features directly), label noise/non-noise, fit a
LightGBM binary classifier, `save_model()` to text, and choose a threshold
from your validation set. Set `threshold:` on the stage to your calibrated
value.

## Stage contract

- `type: filter.ml_noise`, GPU execution target. No CPU variant initially
  (integration cpu-fp64 variant skipped).
- Options:
  - `model` (required): local path or `s3://` URI. S3 models download once to
    `$XDG_CACHE_HOME/pcax/models/` (default `~/.cache/pcax/models/`), keyed by
    URI hash; verified against a `<uri>.sha256` sidecar object when present;
    reused on later runs. The download shells out to `aws s3 cp`, so s3://
    models need the AWS CLI on PATH with read access to the bucket.
  - `threshold` (default 0.9336, the reference model's calibrated value —
    recalibrate for your own model).
- Output: points with `prob >= threshold` get `Classification = 7`. Nothing
  else is modified (no 7/18 split, no resetting prior noise to 1 — deliberate
  simplification vs `predict.py`; parity is checked on the noise *mask*).
- Tile-stateful: features include tile-level statistics (median r8, z
  median/IQR, intensity MAD, quantile ranks). Run it on a full tile or an AOI
  of ≳1M points; for small crops add ~10 m margin before, crop after.

## The 48 features (model column order)

Base features are computed per point from the k=33 nearest-neighbor query
(self excluded → 32 neighbors, ascending by distance). Coordinates: kNN,
covariances and dz use point positions; the Python reference computes in
FP64 absolute coordinates — the port computes distances on relative coords
(translation-invariant) and **cell indices from absolute FP64 coords**
(`floor(x_abs / cell)`), since cell-boundary membership is not
translation-invariant.

| # | name | definition |
|---|------|------------|
| 0–2 | `mean_d8/16/32` | mean of first 8/16/32 neighbor distances |
| 3–5 | `r8/16/32` | distance to 8th/16th/32nd neighbor (`d[7]`, `d[15]`, `d[31]`) |
| 6 | `std_d32` | population std (ddof=0) of the 32 distances |
| 7–10 | `linearity16, planarity16, sphericity16, verticality16` | from covariance of the 16 **neighbors only** (point itself excluded), centered on neighbor mean, divided by k; eigenvalues ascending, clamped ≥0; λ1≥λ2≥λ3: lin=(λ1−λ2)/λ1, plan=(λ2−λ3)/λ1, sph=λ3/λ1 (λ1 floored at 1e-12); vert=\|z-component of the smallest-eigenvalue eigenvector\| |
| 11–14 | same at k=32 |
| 15 | `eig_sum32` | λ1+λ2+λ3 at k=32 |
| 16 | `curvature32` | λ3 / max(Σλ, 1e-12) at k=32 |
| 17–19 | `dz_p05_10m, dz_med_10m, dz_p95_10m` | z − {5th, 50th, 95th} percentile of z over the point's 10 m × 10 m cell (`np.percentile` linear interpolation) |
| 20 | `dz_p05_25m` | z − 5th percentile, 25 m cell |
| 21 | `cell_count_10m` | point count of the 10 m cell |
| 22 | `z_tile_norm` | (z − tile median z) / max(tile z IQR, 1.0) |
| 23 | `dz_knn16` | mean over 16 nearest of (z − z_neighbor) |
| 24 | `intensity_z` | (intensity − tile median) / MAD, MAD = max(median(\|i − med\|), 1.0) |
| 25–26 | `return_number, num_returns` | raw LAS values as float |
| 27 | `is_last` | return_number == num_returns |
| 28 | `is_single` | num_returns == 1 |
| 29 | `scan_angle` | formats 6+: raw int16 (0.006° units); formats ≤5: scan_angle_rank (degrees) / 0.006 |
| 30 | `below_frac32` | fraction of 32 neighbors with (z − z_nb) > 0.5 |
| 31 | `dz_min32` | z − min neighbor z |
| 32 | `dz_max32` | z − max neighbor z |
| 33 | `int_vs_nb16` | (intensity − median of 16 neighbors' intensity) / tile MAD |
| 34 | `int_nb_std16` | population std of 16 neighbors' intensity / tile MAD |
| 35 | `nr_nb_mean16` | mean num_returns over 16 nearest |
| 36–45 | `*_n` | features {0,1,2,3,4,5,6,23,31,32} divided by tile scale = max(median of the r8 column, 1e-6) |
| 46–47 | `mean_d8_q, dz_med_10m_q` | per-tile rank: stable sort by value (ties broken by point index), rank = position / (N−1) |

Reference quirks that must be preserved:

- Neighbor stats use the *sorted* neighbor list; r8 is literally the 8th
  element, so the kNN must return exact, distance-ascending neighbors
  (expanding-ring search, like SOR's exact kNN).
- Self-exclusion drops exactly one zero-distance entry; coincident duplicate
  points therefore appear as distance-0 neighbors.
- All stds are ddof=0 (population), unlike SOR's N−1 convention.
- Percentiles are numpy default linear interpolation.
- The quantile ranks are **not** tie-averaged: stable argsort gives ties
  distinct ranks in point order.
- Tile medians (z, intensity, r8) are computed over all points;
  `np.median` averages the two middle values for even N.
- Features were cached/trained in **float16**; FP32 features are finer than
  the training data, so small near-threshold prediction flips vs the Python
  pipeline are expected and tolerated (PARITY_SLACK-class, like SOR/crop).

## Inference

Hand-rolled CUDA traversal (no new dependencies): the `.txt` model parses
into flat per-node arrays (split feature, threshold, default-left bit from
`decision_type`, children, leaf values; all features numerical — the model
contains no categorical splits). One thread per point walks all 4,998 trees,
sums leaf values, applies sigmoid. LightGBM split rule: go left if
`value <= threshold` (NaN follows the default-left bit; our features are
never NaN). Scores are parity-checked against `lightgbm.Booster.predict`.
Model parse is ~0.3 s for the 70 MB file — fast enough that no pre-parsed
binary cache is needed.

## Usage

```yaml
stages:
  read:
    type: read.las
    filename: "${input}"
  noise:
    type: filter.ml_noise
    input: read
    device: gpu
    model: "${model}"          # local path or s3:// URI of your LightGBM text model
    # threshold: 0.9336        # default; calibrate for your model
    # debug_features: feats.bin  # optional N x 48 float32 dump for parity work
  drop_noise:                  # optional: the filter only marks class 7
    type: filter.range
    input: noise
    limits: "Classification![7:7]"
```

## Validation (reference model)

On a 2.6M-point USGS Colorado tile vs the Python reference
(`features.py` + `lightgbm.Booster.predict`):

- **Decision parity: exact** — 293 noise points from both, 0/2,607,453 mask
  disagreements at threshold 0.9336.
- **Inference kernel: exact** — `lightgbm` CPU predict on the GPU-computed
  feature matrix reproduces the kernel's mask with 0 disagreements.
- Feature-level diffs are the documented FP32-storage/neighbor-tie class:
  eigenfeatures and kNN-boundary stats (`dz_knn16`, `dz_min/max32`,
  `below_frac32`) differ on 0.01–1.5% of points where near-equidistant
  neighbors swap at the k=16/32 boundary or degenerate neighborhoods tickle
  eigensolver noise; 99.9% of points agree to ≤3e-2 relative on the worst
  column, and the model was trained on float16-cached features anyway.
- Throughput (RTX 2080 Ti): 4.7 s for 2.6M points (~18 s/10M) — kNN 2.2 s,
  inference 2.2 s, everything else <60 ms.
- GPU memory: **231 B/point peak** (measured 5110–5436 MB on 22–23.6M-point
  tiles). The kNN search and the k=16/32 eigenfeatures
  run in ONE fused kernel — the neighbour ids stay in registers and the
  covariance streams the neighbour coords back out of X/Y/Z — so no N x 32
  index matrix is materialised. Before the fusion that buffer cost 128 B/point
  (2.8 GiB on a 23.6M-pt tile) and put the peak at 352 B/point, which did not
  fit an 11 GiB card shared with another process. The binding phase is now the
  10 m/25 m cell-feature sort, not the kNN phase. Full analysis:
  `docs/MlNoiseGpuMemory.typ`. (The Metal backend still uses the two-kernel
  form.)

Tier-1 regression: `tests/integration/test_ml_noise.py`, separate baseline
`baselines/ml_noise.json` (read → reproject(fp64) → ml_noise on the
committed fixture; GPU-only, no precision variants; runs only when
`PCAX_ML_MODEL` points at a model, and the committed baseline matches the
reference model only).

## Held-out accuracy (reference model)

Scored against vendor labels (classes 7/18) on three ~23M-point tiles from a
2020 California county project absent from the training corpus: precision
0.71–0.92, recall 0.17–0.39, F1 0.27–0.55 at the calibrated threshold.
Class-18 (high noise) recall reaches 0.92 where labeling is geometric;
class-7 (low noise) recall is 2–5% — those labels encode non-geometric
vendor criteria, and a threshold sweep to 0.5 barely moves recall, so the
gap is model-, not threshold-limited. Note those tiles are State Plane ftUS:
reproject to meters before this filter — the feature definitions are metric.
