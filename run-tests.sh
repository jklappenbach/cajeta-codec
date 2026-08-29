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

# --- artifact discovery -------------------------------------------------
# Where a checkout's .cja is. Prefers `cajeta artifact-path`, which reads
# that project's OWN manifest -- so a project that moves its artifacts with
# settings.output is followed rather than guessed, and the version comes
# from details.version instead of whichever file happens to be newest.
#
# Falls back to the historical build/archive glob only when the toolchain
# does not HAVE the verb (it lands after 0.24.0), so this keeps working on
# an older cajeta and starts using the verb as soon as a newer one is on
# PATH -- no flag day.
#
# The gate is the CAPABILITY, not the outcome. A fallback keyed on "the
# verb failed" would silently mask a verb that ran and answered wrongly,
# which is the very failure this replaces; keyed on "the verb is absent",
# it cannot. An empty result still means "not in this checkout", exactly
# as the glob did, so callers' registry fallbacks are unchanged.
cajeta_artifact_path() {
    local dir="$1" name="$2"
    local cj="${CAJETA:-${CAJETA_BIN:-cajeta}}"
    if [[ -z "${_cajeta_has_ap:-}" ]]; then
        if "$cj" artifact-path --help 2>/dev/null \
                | grep -q 'artifact-path \[options\]'; then
            _cajeta_has_ap=yes
        else
            _cajeta_has_ap=no
        fi
    fi
    if [[ "$_cajeta_has_ap" == yes ]]; then
        # Only report a path that EXISTS. The verb answers where the
        # artifact would be even when nothing has built it, but the glob
        # this replaces returned empty in that case, and every caller
        # reads empty as "not in this checkout" and falls back to the
        # registry. Handing back a path to a missing file instead would
        # turn that into a confusing compile failure.
        local p
        p=$( cd "$dir" 2>/dev/null && "$cj" artifact-path 2>/dev/null ) || return 0
        [[ -n "$p" && -f "$p" ]] && printf '%s\n' "$p"
        return 0
    else
        ls -t "$dir"/build/archive/"$name"-*.cja 2>/dev/null | head -1
    fi
}

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
unit_cja="$(cajeta_artifact_path "$UNIT_REPO" dev.cajeta.unit 2>/dev/null)"
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
