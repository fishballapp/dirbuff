#!/usr/bin/env bash
# Builds the restic pinned in pin.env from its checked source release: a universal (arm64 +
# x86_64) `restic` and its `LICENSE`, in apps/mac/.restic/. The app's build phase puts them in the
# bundle, and the runner's tests run against this binary.
#
# Needs Go 1.25 or newer (the toolchain go.mod asks for is fetched if the local one is older).
# Does nothing when this pin is already built, so CI caches apps/mac/.restic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.restic"
# shellcheck source=pin.env
source "$SCRIPT_DIR/pin.env"

if [[ "$(cat "$OUT_DIR/pin" 2>/dev/null || true)" == "$RESTIC_SOURCE_SHA256" ]]; then
  echo "restic $RESTIC_VERSION is already built in $OUT_DIR"
  exit 0
fi

WORK_DIR="$(mktemp -d -t dirbuff-restic-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

TARBALL="$WORK_DIR/restic-$RESTIC_VERSION.tar.gz"
echo "--> Downloading restic $RESTIC_VERSION..."
curl --fail --silent --show-error --location --output "$TARBALL" \
  "https://github.com/restic/restic/releases/download/v$RESTIC_VERSION/restic-$RESTIC_VERSION.tar.gz"

echo "--> Checking its SHA-256..."
echo "$RESTIC_SOURCE_SHA256  $TARBALL" | shasum -a 256 -c -

SOURCE_DIR="$WORK_DIR/source"
mkdir "$SOURCE_DIR"
tar -xzf "$TARBALL" -C "$SOURCE_DIR" --strip-components=1

# Upstream's own release flags (build.go), less its `selfupdate` tag: a bundled binary must never
# replace itself inside a signed app.
build() {
  local arch="$1"
  echo "--> Building restic for $arch..."
  (
    cd "$SOURCE_DIR"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -trimpath \
      -tags disable_grpc_modules \
      -ldflags "-s -w -X main.version=$RESTIC_VERSION" \
      -o "$WORK_DIR/restic-$arch" ./cmd/restic
  )
}
build arm64
build amd64

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
lipo -create "$WORK_DIR/restic-arm64" "$WORK_DIR/restic-amd64" -output "$OUT_DIR/restic"
cp "$SOURCE_DIR/LICENSE" "$OUT_DIR/LICENSE"

echo "--> Checking the build..."
lipo -archs "$OUT_DIR/restic"
"$OUT_DIR/restic" version | grep -F "restic $RESTIC_VERSION " >/dev/null

echo "$RESTIC_SOURCE_SHA256" > "$OUT_DIR/pin"
echo "Built restic $RESTIC_VERSION: $OUT_DIR/restic"
