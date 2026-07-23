#!/usr/bin/env bash
# Build + run the cross-repo Arrow BRIDGE test (nucleo-frame U17).
#
# Unlike run-tests.sh (the pure-codec suite, which builds against a RELEASED
# cajeta toolchain), the bridge exercises the parquet -> Arrow C Data Interface
# -> typed `Table<R>` path, so it depends on `cajeta.nucleo.column` and
# `cajeta.nucleo.frame` — which are UNRELEASED (cajeta feature-branch) at
# authoring time. It therefore builds against a FROM-SOURCE cajeta toolchain,
# and is intentionally NOT part of run-tests.sh: adding a nucleo import to the
# released-toolchain suite would fail the whole build, not just this test.
#
# CI stays green on run-tests.sh today; this target goes green in cajeta-codec
# CI once a cajeta release ships nucleo — then point CAJETA at it and fold this
# into run-tests.sh.
#
# Env:
#   CAJETA             from-source cajeta compiler
#                        (default: ../cajeta/build/src/cajeta)
#   CAJETA_SOURCE_ROOT  the cajeta repo root the compiler reads the runtime
#                        (incl. nucleo.*) from (default: ../cajeta)
#   UNIT_REPO           cajeta-unit checkout (default: ../cajeta-unit)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-$here/../cajeta/build/src/cajeta}"
UNIT_REPO="${UNIT_REPO:-$here/../cajeta-unit}"

# A from-source compiler reads the runtime (incl. nucleo.*) from a repo root; a
# released .deb bundles its own runtime and needs none. Export the source root
# only when it actually exists, so the same script serves both: locally against
# ../cajeta/build/src/cajeta, and in CI against an installed `cajeta` once a
# release carries nucleo.
SRC_ROOT="${CAJETA_SOURCE_ROOT:-$here/../cajeta}"
if [[ -d "$SRC_ROOT" ]]; then export CAJETA_SOURCE_ROOT="$SRC_ROOT"; fi

# Resolve `cajeta` on PATH if the default from-source binary is absent (CI).
if [[ ! -x "$CAJETA" ]]; then
    if command -v cajeta >/dev/null 2>&1; then
        CAJETA="$(command -v cajeta)"
    else
        echo "!! no cajeta compiler found (set CAJETA or build ../cajeta)" >&2
        exit 1
    fi
fi
echo ">> toolchain: $("$CAJETA" --version 2>/dev/null || echo "$CAJETA")"
echo ">> runtime source root: ${CAJETA_SOURCE_ROOT:-<bundled>}"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# cajeta-unit + the codec library, both built with the SAME from-source
# toolchain (ABI must match the bridge binary).
echo ">> building cajeta-unit .cja"
"$CAJETA" --emit=cja -o "$out/unit.cja" \
    dev.cajeta.unit.Runner.run "$UNIT_REPO/src/main/cajeta" "$out" >/dev/null

echo ">> building codec library .cja"
"$CAJETA" --emit=cja -o "$out/codec.cja" \
    dev.cajeta.codec.protobuf.Protobuf.run "$here/src/main/cajeta" "$out" >/dev/null

echo ">> building + running the bridge test binary"
"$CAJETA" --emit=exe --profile=test \
    --classpath="$out/codec.cja,$out/unit.cja" \
    -o "$out/bridgetest" \
    dev.cajeta.codec.bridge.BridgeMain.run "$here/src/bridge/cajeta" "$out" >/dev/null

"$out/bridgetest"
