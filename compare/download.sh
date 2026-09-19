#!/usr/bin/env bash
# Copyright (c) 2026 Advanced Algorithms LLC
# SPDX-License-Identifier: LicenseRef-PointCloudAccelerator-1.0
# Fetch the default head-to-head tile into compare/data/ (gitignored).
#
# USGS 3DEP lidar is public domain, hosted in the requester-pays bucket
# s3://usgs-lidar (us-west-2). Needs the AWS CLI with any valid credentials;
# the transfer (~438 MiB) is billed to the requester.
set -euo pipefail

DEST="$(cd "$(dirname "$0")" && pwd)/data"
TILE="USGS_LPC_CA_NorthernCA_B22_10TEL7280.laz"
KEY="Projects/CA_NorthernCA_B22/CA_NorthernCA_4_B22/LAZ/${TILE}"

mkdir -p "$DEST"
if [ -s "$DEST/$TILE" ]; then
    echo "have    $DEST/$TILE"
    exit 0
fi
aws s3 cp --request-payer requester --region us-west-2 \
    "s3://usgs-lidar/${KEY}" "$DEST/$TILE"
echo "fetched $DEST/$TILE"
