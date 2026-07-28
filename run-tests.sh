#!/usr/bin/env bash
# Build + run the cajeta-codec unit tests.
#
# The suite lives under src/test/cajeta and is driven by cajeta-unit's
# reflective @Test discovery (dev.cajeta.unit.Runner). It compiles ONLY the
# test sources into an executable, with the codec library and cajeta-unit both
# supplied as .cja classpath dependencies — the compiler links their bitcode
# into the test binary (requires a toolchain with classpath-bitcode linking,
# cajeta >= 0.7.1-dev with that fix).
#
# Until `cajeta test` can resolve a dev-dependency + the project's own lib onto
# the test classpath, this script is the supported entry point.
#
# Override paths via env:
#   CAJETA    — compiler binary (default: cajeta on PATH)
#   UNIT_REPO — path to the cajeta-unit checkout (default: ../cajeta-unit)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"
UNIT_REPO="${UNIT_REPO:-$here/../cajeta-unit}"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# cajeta-unit's version lives in ITS manifest — never hardcode it here. This
# used to name dev.cajeta.unit-0.1.0.cja outright and only rebuild when that
# exact file was missing, which failed two ways: a stale archive silently won
# (a months-old one broke the suite after the bracket-literal migration), and
# any version bump left this pointing at a file that would never exist again.
# Build unconditionally (the build is incremental, so a no-op is cheap) and
# resolve whatever version it produced.
echo ">> building cajeta-unit .cja ($UNIT_REPO)"
( cd "$UNIT_REPO" && "$CAJETA" build >/dev/null )
unit_cja="$(ls -t "$UNIT_REPO"/build/archive/dev.cajeta.unit-*.cja 2>/dev/null | head -1)"
if [[ -z "$unit_cja" ]]; then
    echo "no dev.cajeta.unit-*.cja under $UNIT_REPO/build/archive" >&2
    exit 1
fi

echo ">> building native zlib backend (vendored zlib + shim -> native/<platform>/)"
"$here/native/build.sh" >/dev/null
# The @Native(lib="cajeta_zlib") bindings resolve libcajeta_zlib.a from here.
export CAJETA_NATIVE_PATH="$here/native"

echo ">> building codec library .cja"
"$CAJETA" --emit=cja -o "$out/codec.cja" \
    dev.cajeta.codec.protobuf.Protobuf.run "$here/src/main/cajeta" "$out" >/dev/null

echo ">> building + running the test binary"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$out/codec.cja,$unit_cja" \
    -o "$out/codectests" \
    dev.cajeta.codec.selftest.TestMain.run "$here/src/test/cajeta" "$out" >/dev/null

"$out/codectests"
