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

## Provisioning a full CI host

    # Linux cross (compile + link, run under qemu-user):
    apt install gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu qemu-user
    # Windows cross (compile + link, run under wine):
    apt install gcc-mingw-w64-x86-64 wine64
    # macOS cross: osxcross with a macOS SDK, or build on Apple hardware.

With those present, `./native/cross-build.sh` builds all six archives.

## "Link" vs "run"

- **Archive build** (this script): compile the vendored TUs for the target and
  `ar` them — the gate this script enforces. `llvm-ar` archives ELF/COFF/Mach-O
  objects uniformly.
- **Full cross-link + run**: linking the archive into a cajeta executable for a
  foreign target additionally needs the cajeta compiler to *emit* for that
  triple (LLVM target backend) and a target linker/sysroot — a CI concern beyond
  this script. The host triple runs the full codec suite (Units 1–3, 214 tests).

## Snapshot — dev host (`x86_64-linux-gnu`)

Toolchains for the five cross targets are **not installed on this host** (no
cross-gcc, no sysroots, no qemu; the local clang is an x86-only ROCm build), so
they record as SKIP here. This is a provisioning gap, not a portability one — the
sources are ISO-C over zlib's portable buffer API.

| platform        | result on this host                                  |
|-----------------|------------------------------------------------------|
| `linux-x64`     | **BUILT** (124K) + full suite verified (214 tests)   |
| `linux-arm64`   | SKIP — no `aarch64-linux-gnu-gcc`, no sysroot         |
| `linux-riscv64` | SKIP — no `riscv64-linux-gnu-gcc`, no sysroot         |
| `windows-x64`   | SKIP — no mingw-w64 toolchain/sysroot                 |
| `macos-x64`     | SKIP — no macOS SDK                                   |
| `macos-arm64`   | SKIP — no macOS SDK                                   |

Re-run `./native/cross-build.sh` after provisioning to fill the matrix.
