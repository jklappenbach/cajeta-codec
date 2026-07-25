#!/usr/bin/env bash
#
# Unit 6 perf gate — cajeta native zlib backend vs raw zlib on the same 128 KiB
# payload, same machine. Builds the codec .cja with the native archive linked,
# builds + runs the cajeta CompressBench (--opt=O3), then builds + runs the C
# raw-zlib reference (bench/zlib_ref.c) against the same vendored zlib.
#
#   CAJETA=/path/to/cajeta ./bench/run-native-vs-zlib.sh
#
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
CJ="${CAJETA:-cajeta}"
CC="${CC:-cc}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> building native zlib archive"
"$here/native/build.sh" >/dev/null
export CAJETA_NATIVE_PATH="$here/native"

# platform id, to find the archive for the C reference link.
case "$(uname -s)" in Linux) os=linux;; Darwin) os=macos;; *) os=linux;; esac
case "$(uname -m)" in x86_64|amd64) arch=x64;; aarch64|arm64) arch=arm64;; riscv64) arch=riscv64;; *) arch="$(uname -m)";; esac
archive="$here/native/$os-$arch/libcajeta_zlib.a"

echo ">> building codec .cja"
"$CJ" --emit=cja -o "$tmp/codec.cja" \
    dev.cajeta.codec.protobuf.Protobuf.run "$here/src/main/cajeta" "$tmp" >/dev/null

echo ">> building CompressBench (--opt=O3)"
"$CJ" --emit=exe --opt=O3 --classpath="$tmp/codec.cja" -o "$tmp/cbench" \
    dev.cajeta.codec.bench.CompressBench.main "$here/bench/src" "$tmp" >/dev/null

echo ">> building zlib_ref (raw zlib)"
"$CC" -O3 -DNDEBUG -I"$here/native/zlib" "$here/bench/zlib_ref.c" "$archive" -o "$tmp/zref"

echo
echo "=========================================================="
echo " cajeta codec — native zlib backend"
echo "=========================================================="
"$tmp/cbench"

echo
echo "=========================================================="
echo " raw zlib reference (same payload, same machine)"
echo "=========================================================="
"$tmp/zref"
