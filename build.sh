#!/bin/sh
# Build a patched single-node VictoriaMetrics release for linux-amd64.
#
# usage: ./build.sh <tag> [path-to-VictoriaMetrics-checkout]
#   ./build.sh v1.148.0
#
# If no checkout path is given, the upstream repo is cloned into ./work/.
# Output: dist/victoria-metrics-linux-amd64-<tag>-downsampling.tar.gz
set -eu

TAG="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${2:-$HERE/work/VictoriaMetrics}"

if [ ! -d "$SRC" ]; then
    mkdir -p "$HERE/work"
    git clone --depth 1 --branch "$TAG" https://github.com/VictoriaMetrics/VictoriaMetrics "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin tag "$TAG"
git -C "$SRC" checkout -f "$TAG"
git -C "$SRC" checkout -- .

# strict apply first; fall back to patch(1) with fuzz for tags with drifted context
if git -C "$SRC" apply --check "$HERE/vm-downsampling.patch" 2>/dev/null; then
    git -C "$SRC" apply "$HERE/vm-downsampling.patch"
else
    (cd "$SRC" && patch -p1 --fuzz=3 < "$HERE/vm-downsampling.patch")
fi
cp "$HERE/downsampling_test.go" "$SRC/lib/storage/"

cd "$SRC"
go test ./lib/storage/ -run 'Downsampling|DedupInterval' -count=1

DATEINFO_TAG="$(date -u +%Y%m%d-%H%M%S)"
LDFLAGS="-X 'github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=victoria-metrics-$DATEINFO_TAG-$TAG-downsampling'"
mkdir -p "$HERE/dist"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "$LDFLAGS" \
    -o "$HERE/dist/victoria-metrics-prod" ./app/victoria-metrics

# clean the working copy for the next tag
git -C "$SRC" checkout -- .
rm -f "$SRC/lib/storage/downsampling.go" "$SRC/lib/storage/downsampling_test.go"

cd "$HERE/dist"
tar czf "victoria-metrics-linux-amd64-$TAG-downsampling.tar.gz" victoria-metrics-prod
rm victoria-metrics-prod
echo "built: dist/victoria-metrics-linux-amd64-$TAG-downsampling.tar.gz"
