# Native zlib backend — per-target build

`native/cross-build.sh` compiles the vendored zlib (buffer API) + the cajeta
shim into a static archive per target:

    native/<platform>/libcajeta_zlib.a

The cajeta native-dependency resolver (`NativeLink`) picks the archive whose
`<platform>` matches the build target. At publish time these archives are baked
into the `.cja` (INV-3), so a consumer links offline on any of the six targets.

## Target matrix

| platform id     | target triple          | toolchain to provision (Debian/Ubuntu)     |
|-----------------|------------------------|--------------------------------------------|
| `linux-x64`     | `x86_64-linux-gnu`     | host `cc` / `gcc` (baseline)               |
| `linux-arm64`   | `aarch64-linux-gnu`   | `gcc-aarch64-linux-gnu`                     |
| `linux-riscv64` | `riscv64-linux-gnu`   | `gcc-riscv64-linux-gnu`                     |
| `windows-x64`   | `x86_64-w64-mingw32`  | `gcc-mingw-w64-x86-64`                      |
| `macos-x64`     | `x86_64-apple-macos11`| clang + macOS SDK (osxcross) or a Mac host  |
| `macos-arm64`   | `arm64-apple-macos11` | clang + macOS SDK (osxcross) or a Mac host  |

`windows-x86` (32-bit, `i686-w64-mingw32`, `gcc-mingw-w64-i686`) is the same
recipe with the 32-bit triple; add a row to `targets` in `cross-build.sh` if a
32-bit Windows artifact is needed.

The script chooses a compiler per target as: a `<triple>-gcc`/`-clang` on PATH,
else the host `cc` (host triple only), else `clang -target <triple>` (which also
needs the LLVM backend **and** a target sysroot). A target with no working
toolchain is **SKIPPED and recorded — never faked**.

## No per-target build knobs

Because Unit 1 vendored only zlib's **in-memory buffer API** (the `gz*` file-I/O
TUs were dropped), there is no `unistd`/`lseek`/large-file surface, and thus no
per-target `configure` knobs: the same `-O3 -DNDEBUG` flags compile on every
triple. (This is spec §2.4 / plan 4.2.2 — resolved by having nothing to resolve.)

## Provisioning

### Sudo-free (a full-backend clang + extracted sysroots)

Ubuntu's `llvm-N` clang (`clang-21`, `clang-20`, …) ships **every** LLVM target
backend. All that's missing to cross-compile is each target's libc/SDK headers,
which can be fetched and extracted **without root**:

    # aarch64 example — repeat with riscv64 / x86-64 for the others
    apt-get download libc6-dev-arm64-cross linux-libc-dev-arm64-cross
    dpkg-deb -x libc6-dev-arm64-cross_*.deb   sysroots/arm64
    dpkg-deb -x linux-libc-dev-arm64-cross_*.deb sysroots/arm64
    # Windows headers come from the mingw-w64 dev packages:
    apt-get download mingw-w64-x86-64-dev mingw-w64-common
    dpkg-deb -x mingw-w64-x86-64-dev_*.deb sysroots/win64
    dpkg-deb -x mingw-w64-common_*.deb     sysroots/win64

Then point the per-target `CC_<platform>` overrides at `clang-N -target … --sysroot`:

    CC_linux_arm64="clang-21 -target aarch64-linux-gnu --sysroot=sysroots/arm64/usr/aarch64-linux-gnu" \
    CC_linux_riscv64="clang-21 -target riscv64-linux-gnu --sysroot=sysroots/riscv64/usr/riscv64-linux-gnu" \
    CC_windows_x64="clang-21 -target x86_64-w64-windows-gnu --sysroot=sysroots/win64/usr/x86_64-w64-mingw32" \
    ./native/cross-build.sh

macOS needs Apple's SDK, which isn't apt-installable and whose license restricts
it to Apple hardware. The **`native-macos` GitHub Actions workflow**
(`.github/workflows/native-macos.yml`) closes both macOS targets on a hosted
`macos-14` runner: one Apple-silicon runner cross-builds `macos-arm64` (native)
and `macos-x64` (`-arch x86_64`) from the runner's SDK via the same
`CC_<platform>` overrides, and verifies each archive's Mach-O arch. To build
them locally instead, run on a Mac (Command Line Tools) or an osxcross image with
a legitimately-sourced SDK, using the same overrides with `-isysroot <SDK>`.

### With sudo (apt cross-toolchains)

    apt install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu gcc-mingw-w64-x86-64
    # to RUN the cross builds: qemu-user (linux targets) / wine64 (windows)

`cross-build.sh` auto-detects the `<triple>-gcc` these provide.

## Consuming the native backend (e.g. cajeta-http)

The published `.cja` **bakes** `native/<platform>/libcajeta_zlib.a` (spec §3.3,
verified). But on the current toolchain (v0.9.5) the consumer's linker does **not
auto-extract** native artifacts from a classpath `.cja` (spec §3.2.2 is
unimplemented) — it searches only `CAJETA_NATIVE_PATH`, the project `native/`
dir, and `~/.cajeta/native`. So a consumer bridges the gap by extracting the
`native/` tree from the `.cja` it already has and pointing the resolver at it —
**offline, no vendoring, no network**:

    CJA=~/.olla/dev.cajeta.codec/<ver>/dev.cajeta.codec-<ver>.cja
    cajeta archive extract "$CJA" -C .cajeta-native      # -> .cajeta-native/native/<platform>/…
    export CAJETA_NATIVE_PATH="$PWD/.cajeta-native/native"
    cajeta test        # or build — links the native backend from the extracted archive

Verified end-to-end: a codec consumer linked and ran the native path with every
other archive source hidden, resolving solely from the extracted tree. When the
toolchain implements §3.2.2, this extract step goes away and the baked `.cja`
links directly.

## "Link" vs "run"

- **Archive build** (this script): compile the vendored TUs for the target and
  `ar` them — the gate this script enforces. `llvm-ar` archives ELF/COFF/Mach-O
  objects uniformly.
- **Full cross-link + run**: linking the archive into a cajeta executable for a
  foreign target additionally needs the cajeta compiler to *emit* for that
  triple (LLVM target backend) and a target linker/sysroot — a CI concern beyond
  this script. The host triple runs the full codec suite (Units 1–3, 214 tests).

## Snapshot — dev host (`x86_64-linux-gnu`)

Built with `clang-21` + sysroots extracted sudo-free (above). Four of six targets
compile+archive with the correct object format verified (`ar p … | file`); the
two macOS targets are gated only on Apple's SDK.

| platform        | result on this host                                        |
|-----------------|------------------------------------------------------------|
| `linux-x64`     | **BUILT** (124K, x86-64 ELF) + full suite verified (214)   |
| `linux-arm64`   | **BUILT** (112K, AArch64 ELF) — clang-21 + arm64 sysroot   |
| `linux-riscv64` | **BUILT** (160K, RISC-V ELF)  — clang-21 + riscv64 sysroot |
| `windows-x64`   | **BUILT** (100K, x86-64 COFF) — clang-21 + mingw sysroot   |
| `macos-x64`     | SKIP here → built + verified by the `native-macos` CI       |
| `macos-arm64`   | SKIP here → built + verified by the `native-macos` CI       |

All three ISAs (x86-64, AArch64, RISC-V) and both non-Apple object formats (ELF,
COFF) are verified on this box; only the host triple *runs* here (no qemu/wine
installed). The two macOS targets are covered by the `native-macos` GitHub
Actions workflow (Mach-O arm64 + x86_64), so all six are verifiable in CI.
