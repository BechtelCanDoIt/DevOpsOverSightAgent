#!/usr/bin/env bash
# Builds the three real WSO2 product images that compose's --profile wso2 uses:
#   devops-poc/wso2mi:4.3.0   devops-poc/wso2am:4.2.0   devops-poc/wso2is:6.1.0
#
# It layers a LOCALLY-EXTRACTED product distribution onto a multi-arch Temurin 11
# base (compose/wso2/Dockerfile). Because WSO2 products are pure Java, the
# resulting image runs NATIVELY on arm64 or amd64 — no QEMU emulation, and no
# dependence on WSO2's amd64-only registry images. Verified building + booting
# all three native-aarch64 on Apple Silicon.
#
# Point it at the directory that holds your extracted product folders. Default
# layout (override with WSO2_SRC_DIR), matching the folders this was built from:
#   $WSO2_SRC_DIR/apim/wso2am-4.2.0
#   $WSO2_SRC_DIR/is/wso2is-6.1.0
#   $WSO2_SRC_DIR/mi/wso2mi-4.3.0
#
# Per-product overrides: AM_DIR / IS_DIR / MI_DIR (absolute paths to the
# extracted product roots). Use these if your versions/paths differ.
#
# Usage:
#   ./scripts/build-wso2-images.sh                 # uses WSO2_SRC_DIR (default ~/dev/wso2)
#   WSO2_SRC_DIR=/path/to/wso2 ./scripts/build-wso2-images.sh
#   MI_DIR=~/dev/wso2/mi/wso2mi-4.3.0 ./scripts/build-wso2-images.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/compose/wso2/Dockerfile"

WSO2_SRC_DIR="${WSO2_SRC_DIR:-$HOME/dev/wso2}"
AM_DIR="${AM_DIR:-$WSO2_SRC_DIR/apim/wso2am-4.2.0}"
IS_DIR="${IS_DIR:-$WSO2_SRC_DIR/is/wso2is-6.1.0}"
MI_DIR="${MI_DIR:-$WSO2_SRC_DIR/mi/wso2mi-4.3.0}"

# tag  product-dir  start-script  (one row per product)
build() {
    local tag="$1" dir="$2" start="$3" product_dir
    product_dir="$(basename "$dir")"
    if [ ! -x "$dir/$start" ] && [ ! -f "$dir/$start" ]; then
        echo "ERROR: '$dir/$start' not found — is $dir a valid extracted product?" >&2
        exit 1
    fi
    echo "==> Building $tag from $dir (native to this host's arch)..."
    docker build -f "$DOCKERFILE" \
        --build-arg PRODUCT_DIR="$product_dir" \
        --build-arg START_CMD="$start" \
        -t "$tag" "$dir"
}

build devops-poc/wso2mi:4.3.0 "$MI_DIR" bin/micro-integrator.sh
build devops-poc/wso2am:4.2.0 "$AM_DIR" bin/api-manager.sh
build devops-poc/wso2is:6.1.0 "$IS_DIR" bin/wso2server.sh

echo "==> Done. Start the real products in live mode with 'make wso2-up'."
