#!/bin/sh
# Build in a fresh checkout; never reset an existing checkout or accept fuzzy patches.
set -eu

TAG=${1:?usage: ./build.sh <upstream-tag> [pristine-upstream-checkout]}
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "invalid release tag: $TAG" >&2; exit 1 ;; esac
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HERE/work" "$HERE/dist"
if [ "$#" -gt 1 ]; then
  SRC=$(CDPATH= cd -- "$2" && pwd)
  test -z "$(git -C "$SRC" status --porcelain)" || { echo "checkout must be clean" >&2; exit 1; }
  test "$(git -C "$SRC" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse "$TAG^{commit}")" || { echo "checkout must be at $TAG" >&2; exit 1; }
else
  SRC=$(mktemp -d "$HERE/work/build-$TAG.XXXXXX")
  git clone --depth 1 --branch "$TAG" https://github.com/VictoriaMetrics/VictoriaMetrics.git "$SRC"
fi
git -C "$SRC" apply --check "$HERE/vm-downsampling.patch"
git -C "$SRC" apply "$HERE/vm-downsampling.patch"
cp "$HERE/downsampling_test.go" "$SRC/lib/storage/"
cd "$SRC"
go test ./lib/storage ./app/vmselect/netstorage -count=1
VERSION="victoria-metrics-$(date -u +%Y%m%d-%H%M%S)-$TAG-downsampling"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-X github.com/VictoriaMetrics/VictoriaMetrics/lib/buildinfo.Version=$VERSION" \
  -o "$HERE/dist/victoria-metrics-prod" ./app/victoria-metrics
cd "$HERE/dist"
python3 "$HERE/smoke-test.py" ./victoria-metrics-prod
tar czf "victoria-metrics-linux-amd64-$TAG-downsampling.tar.gz" victoria-metrics-prod
sha256sum "victoria-metrics-linux-amd64-$TAG-downsampling.tar.gz" > "victoria-metrics-linux-amd64-$TAG-downsampling.tar.gz.sha256"
printf 'Built %s from %s\nSource checkout retained at %s\n' "$VERSION" "$TAG" "$SRC"
