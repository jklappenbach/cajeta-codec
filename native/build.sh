#!/usr/bin/env bash
#
# Build the native zlib backend — vendored zlib (native/zlib/) + the cajeta shim
# (cajeta_zlib_shim.c) — into a static archive the cajeta linker resolves:
#
#     native/<platform>/libcajeta_zlib.a
#
# The `<platform>` id matches cajeta's NativeLink (os-arch): linux-x64,
# linux-arm64, macos-x64, macos-arm64, windows-x64, linux-riscv64. Point
# CAJETA_NATIVE_PATH at this native/ dir when building an --emit=exe (or the
# test suite) that uses the NativeZlib binding; `cajeta build` bakes the
# artifact into the .cja at publish time instead.
#
# Override the C compiler with $CC (defaults to cc). For cross-compilation set
# $CC to a target clang and pass the target's sysroot via $CFLAGS.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC="${CC:-cc}"

case "$(uname -s)" in
    Linux)                os=linux   ;;
    Darwin)               os=macos   ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *)                    os=linux   ;;
esac
case "$(uname -m)" in
    x86_64|amd64)   arch=x64     ;;
    aarch64|arm64)  arch=arm64   ;;
    riscv64)        arch=riscv64 ;;
    *)              arch="$(uname -m)" ;;
esac
platform="$os-$arch"
out="$here/$platform"
mkdir -p "$out"

obj="$(mktemp -d)"
trap 'rm -rf "$obj"' EXIT

# zlib's in-memory buffer API only (no gz* file I/O — the codec needs none of
# it, and it would drag in the configure-gated unistd/lseek path).
srcs=(adler32 compress crc32 deflate \
      infback inffast inflate inftrees trees uncompr zutil)
objs=()
for s in "${srcs[@]}"; do
    $CC -O3 -DNDEBUG ${CFLAGS:-} -c -I"$here/zlib" "$here/zlib/$s.c" -o "$obj/$s.o"
    objs+=("$obj/$s.o")
done
$CC -O3 -DNDEBUG ${CFLAGS:-} -c -I"$here/zlib" "$here/cajeta_zlib_shim.c" -o "$obj/cajeta_zlib_shim.o"
objs+=("$obj/cajeta_zlib_shim.o")

rm -f "$out/libcajeta_zlib.a"
ar rcs "$out/libcajeta_zlib.a" "${objs[@]}"
echo "built $out/libcajeta_zlib.a ($(du -h "$out/libcajeta_zlib.a" | cut -f1))"
