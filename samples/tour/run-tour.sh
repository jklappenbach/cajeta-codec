#!/usr/bin/env bash
# Build + run the dev.cajeta.codec tour.
#
# Compiles the codec library into a .cja, then builds the tour as an executable
# with the codec on the classpath (same recipe as run-tests.sh), and runs it.
# The tour verifies its own output — a nonzero exit means a check() failed.
#
#   CAJETA=/path/to/cajeta ./samples/tour/run-tour.sh
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root
CAJETA="${CAJETA:-cajeta}"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

echo ">> building native zlib backend"
"$here/native/build.sh" >/dev/null
export CAJETA_NATIVE_PATH="$here/native"

echo ">> building codec library .cja"
"$CAJETA" --emit=cja -o "$out/codec.cja" \
    dev.cajeta.codec.protobuf.Protobuf.run "$here/src/main/cajeta" "$out" >/dev/null

echo ">> building + running the tour"
"$CAJETA" --emit=exe --classpath="$out/codec.cja" -o "$out/codec-tour" \
    codectour.CodecTour.main "$here/samples/tour/src/main/cajeta" "$out" >/dev/null

"$out/codec-tour"
