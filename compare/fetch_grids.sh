#!/usr/bin/env bash
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
# Fetch the PROJ geoid/datum grids used by tests and benchmarks into grids/
# (gitignored). Grids come from the PROJ CDN; add or remove names below to
# change the set — filter.reproject picks up anything in this directory via
# the grids_path option, or set PROJ_DATA to include it.
set -euo pipefail

GRID_DIR="$(dirname "$0")/../grids"
mkdir -p "$GRID_DIR"

GRIDS=(
    us_nga_egm96_15.tif                 # EGM96 global geoid (EPSG:5773)
    au_ga_AUSGeoid2020_20180201.tif     # AUSGeoid2020: GDA2020 -> AHD (EPSG:5711)
    de_adv_BETA2007.tif                 # DHDN -> ETRS89 precise datum grid
    ca_nrc_ntv2_0.tif                   # NAD27 -> NAD83 Canada (multi-subgrid NTv2)
    # NADCON5 (+proj=gridshift, biquadratic): NAD83(1986) <-> NAD83(2011), CONUS
    us_noaa_nadcon5_nad83_1986_nad83_harn_conus.tif
    us_noaa_nadcon5_nad83_harn_nad83_fbn_conus.tif
    us_noaa_nadcon5_nad83_fbn_nad83_2007_conus.tif
    us_noaa_nadcon5_nad83_2007_nad83_2011_conus.tif
)

for g in "${GRIDS[@]}"; do
    if [ -s "$GRID_DIR/$g" ]; then
        echo "have    $g"
    else
        echo "fetch   $g"
        curl -sf -o "$GRID_DIR/$g" "https://cdn.proj.org/$g"
    fi
done
echo "grids in $GRID_DIR:"
ls -l "$GRID_DIR"
