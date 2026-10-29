#!/usr/bin/env bash
set -euo pipefail

LIBRARY="$1"
VERSION="$2"
TARGET="$3"
OUTPUT="$4"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Rustler uses its default nif_version_2_15 feature. The build host's OTP
# version does not describe the minimum ABI of the compiled library.
NIF_VERSION=2.15
NAME="libvastlint_nif-v${VERSION}-nif-${NIF_VERSION}-${TARGET}.so"
NIF_STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$NIF_STAGE_DIR"' EXIT
mkdir -p "$OUTPUT"
cp "$LIBRARY" "$NIF_STAGE_DIR/$NAME"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$NIF_STAGE_DIR/"
tar -czf "$OUTPUT/$NAME.tar.gz" -C "$NIF_STAGE_DIR" "$NAME" LICENSE NOTICE
printf '%s\n' "$NAME.tar.gz"
