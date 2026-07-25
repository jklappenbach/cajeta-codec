#!/usr/bin/env bash
#
# Cross-build the native zlib backend (vendored zlib + the cajeta shim) into a
# per-target static archive for every supported triple:
#
#     native/<platform>/libcajeta_zlib.a
#
# The six targets (cajeta NativeLink platform id  <-  target triple):
#     linux-x64      x86_64-linux-gnu
#     linux-arm64    aarch64-linux-gnu
#     linux-riscv64  riscv64-linux-gnu
#     windows-x64    x86_64-w64-mingw32     (windows-x86 = i686-w64-mingw32, same recipe)
#     macos-x64      x86_64-apple-macos11
#     macos-arm64    arm64-apple-macos11
#
# For each target a compiler is chosen in this order:
#   0. a per-target override  CC_<platform>  (dashes -> underscores), a full
#      compiler command — e.g.
#        CC_linux_arm64="clang-21 -target aarch64-linux-gnu --sysroot=/path"
#      This is the sudo-free route: a full-backend clang (Ubuntu's llvm-N clang
#      has every LLVM target) + a target sysroot extracted without root via
#        apt-get download libc6-dev-<arch>-cross linux-libc-dev-<arch>-cross
#        dpkg-deb -x <pkg>.deb <dir>          # sysroot at <dir>/usr/<triple>
#   1. a target-prefixed gcc/clang on PATH  (e.g. aarch64-linux-gnu-gcc)
#   2. the host `cc` (for the host triple)
#   3. clang -target <triple>               (needs the LLVM backend + a sysroot)
#
# A target with no working toolchain is SKIPPED and recorded — never faked.
# On a fully-provisioned CI host all six build; on a bare dev box typically only
# the host triple does. Exit status is 0 as long as the HOST target builds.
#
# Portability note: because the vendored set is zlib's in-memory buffer API only
# (the gz* file-I/O TUs were dropped, Unit 1), there are NO per-target build
# knobs — no unistd/lseek/large-file surface. The same flags compile everywhere.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# zlib buffer-API TUs (no gz*) + the shim.
srcs=(adler32 compress crc32 deflate infback inffast inflate inftrees trees uncompr zutil)

# Archiver: llvm-ar handles ELF/COFF/Mach-O objects uniformly; fall back to ar.
AR="$(command -v llvm-ar || command -v ar)"

host_triple="$( (command -v cc >/dev/null && cc -dumpmachine) 2>/dev/null || echo x86_64-linux-gnu)"

# platform|triple  (no per-target cflags needed — see portability note above)
targets=(
    "linux-x64|x86_64-linux-gnu"
    "linux-arm64|aarch64-linux-gnu"
    "linux-riscv64|riscv64-linux-gnu"
    "windows-x64|x86_64-w64-mingw32"
    "macos-x64|x86_64-apple-macos11"
    "macos-arm64|arm64-apple-macos11"
)

pick_cc() {   # $1=triple -> echoes a compiler command, or nothing
    local triple="$1" c
    for c in "${triple}-gcc" "${triple}-clang"; do
        command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
    done
    if [ "$triple" = "$host_triple" ]; then echo "${CC:-cc}"; return; fi
    # clang with an explicit target: only usable if the backend AND a sysroot
    # for the target are present. Probed for real when we compile below.
    if command -v clang >/dev/null 2>&1; then echo "clang -target $triple"; fi
}

results=()
host_ok=1

for entry in "${targets[@]}"; do
    plat="${entry%%|*}"; triple="${entry#*|}"
    # Per-target override CC_<platform> (dashes -> underscores) wins.
    override_var="CC_${plat//-/_}"
    cc="${!override_var:-}"
    [ -z "$cc" ] && cc="$(pick_cc "$triple")"
    if [ -z "$cc" ]; then
        results+=("SKIP   $plat  ($triple) — no toolchain found")
        [ "$triple" = "$host_triple" ] && host_ok=0
        continue
    fi

    out="$here/$plat"; mkdir -p "$out"
    obj="$(mktemp -d)"; ok=1; reason=""
    for s in "${srcs[@]}" cajeta_zlib_shim; do
        src="$here/zlib/$s.c"; [ "$s" = cajeta_zlib_shim ] && src="$here/$s.c"
        if ! $cc -O3 -DNDEBUG -I"$here/zlib" -c "$src" -o "$obj/$s.o" 2>"$obj/err"; then
            ok=0; reason="$(head -1 "$obj/err")"; break
        fi
    done
    if [ "$ok" = 1 ]; then
        rm -f "$out/libcajeta_zlib.a"
        "$AR" rcs "$out/libcajeta_zlib.a" "$obj"/*.o
        sz="$(du -h "$out/libcajeta_zlib.a" | cut -f1)"
        results+=("BUILT  $plat  ($triple) via ${cc%% *}...  -> $sz")
    else
        results+=("SKIP   $plat  ($triple) via ${cc%% *} — $reason")
        [ "$triple" = "$host_triple" ] && host_ok=0
    fi
    rm -rf "$obj"
done

echo "== native zlib cross-build (host: $host_triple) =="
for r in "${results[@]}"; do echo "  $r"; done

if [ "$host_ok" != 1 ]; then
    echo "ERROR: the host target ($host_triple) failed to build." >&2
    exit 1
fi
