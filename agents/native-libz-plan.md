# Plan: Native libz backend for DEFLATE / gzip / zlib

Traces [specs/native-libz-spec.md](../specs/native-libz-spec.md). Status: draft.

## Description

Delegate the one-shot DEFLATE/gzip/zlib compress+inflate paths (and
crc32/adler32) to a vendored, statically-linked **zlib** through a thin C shim
bound with `@Native`, keeping the pure-cajeta encoder as a software fallback
selected transparently. Same public API; drop-in faster; all six target triples.

## Systems

- **zlib** 1.3.1 (vendored source, static). Simple buffer API only:
  `compress2`, `uncompress`, `crc32`, `adler32`, and gzip/raw framing via
  `deflateInit2`/`inflateInit2` `windowBits` (still one-shot, no streaming).
- **cajeta `@Native`** FFI → C shim symbols (`__cajeta_zlib_*`), the OpenSSL/TLS
  binding pattern.
- **Native-dependency subsystem** (`native-libraries.json` + `NativeLink`) for
  per-target static linking.
- Existing pure-cajeta `Deflate` / `Gzip` / `Zlib` / `DynDeflate` (the fallback).

## Deliverables

- A native zlib backend behind the unchanged public API, used by default when
  linked, with a pure-cajeta fallback.
- Vendored zlib + shim building static for all six triples.
- Differential (native-vs-cajeta) + interop (system gzip/zlib) test coverage.
- A `THIRD-PARTY` notice for vendored zlib; a bench comparing native to raw zlib.

## Note

Unit 1 is a **spike**: it proves the `@Native → vendored-static-zlib` link and
build mechanism on the smallest surface (`crc32`). Its findings may reshape the
build wiring in later units — that is expected; update this plan if so.

---

## 1. Spike — `@Native → vendored static zlib`, proven via crc32  (spec 2.1–2.3, 3.5)  ✅ DONE

- [x] **1.1 TDD**
  - [x] 1.1.1 `NativeZlibTest::crc32MatchesReference` — crc32("hello world") == 0x0D4A1185.
  - [x] 1.1.2 `NativeZlibTest::crc32MatchesCajeta` — equals `Gzip.crc32` over a buffer.
- [x] **1.2 Coding**
  - [x] 1.2.1 Vendored zlib 1.3.1 under `native/zlib/` (buffer-API TU set; the
        `gz*` file-I/O sources dropped — they need `configure`'s unistd/lseek
        path and the codec uses none of it). `native/zlib/VENDORED.txt`.
  - [x] 1.2.2 `native/cajeta_zlib_shim.c` — `__cajeta_zlib_crc32(hdr, len)`;
        cajeta `int8[]` data is at `hdr + 8`.
  - [x] 1.2.3 `native/build.sh` compiles shim + vendored zlib →
        `native/<platform>/libcajeta_zlib.a`; `run-tests.sh` runs it and exports
        `CAJETA_NATIVE_PATH=native/`. (Recipe in **1.3.3**.)
  - [x] 1.2.4 `NativeZlib.cajeta` — `@Native(symbol="__cajeta_zlib_crc32",
        lib="cajeta_zlib")`.
- [x] **1.3 Acceptance**
  - [x] 1.3.1 Test exe builds, statically links the vendored zlib, runs on host.
  - [x] 1.3.2 198 tests pass (196 + 2 native), 0 fail.
  - [x] 1.3.3 **Build recipe** (reused by units 2–4):
        1. `native/build.sh` → `native/<platform>/libcajeta_zlib.a` (host `cc`,
           `-O3`; platform id `os-arch` matches cajeta `NativeLink`).
        2. Bind: `@Native(symbol="__cajeta_zlib_<fn>", lib="cajeta_zlib")` on a
           `final` class; the annotation alone records the requirement (no
           `cajeta.json` edit). The requirement is DCE-gated (unused → no link
           dep).
        3. Build the exe/test with `CAJETA_NATIVE_PATH=<repo>/native` — the
           resolver finds `<platform>/libcajeta_zlib.a`. No CLI link flags.
        4. cajeta `int8[]` → C ABI: pointer to `{ int64 count; int8 data[] }`,
           data at `+8`. Shims take flat buffers; no `z_stream` crosses the FFI.

## 2. One-shot compress / inflate shim + bindings  (spec 2.3, 3.1–3.4, 3.6)  ✅ DONE

- [x] **2.1 TDD** (`NativeZlibTest`, 12 tests)
  - [x] 2.1.1 Native raw-DEFLATE (RFC 1951) round-trips byte-exact
        (`rawRoundTrips`, `emptyRoundTrips`).
  - [x] 2.1.2 Native zlib (RFC 1950) round-trips and the pure-cajeta
        `Zlib.decompress` decodes it (`zlibRoundTrips`).
  - [x] 2.1.3 Native gzip (RFC 1952) round-trips; the pure-cajeta `Gzip.decompress`
        decodes native output and native decodes a cajeta gzip member
        (`gzipRoundTrips`, `nativeDecodesCajetaGzip`). System-`gzip`-member interop
        is covered by `DeflateHardeningTest` (stock `gzip -c` fixture); the native
        path emits standard zlib framing, so system-tool interop is inherent.
  - [x] 2.1.4 Levels 1..9 honored — L9 ≤ L1, both round-trip (`levelsHonored`).
  - [x] 2.1.5 Truncated/corrupt input raises `DeflateException`, no crash
        (`truncatedRaises`, `corruptGzipRaises`).
  - [x] 2.1.6 `adler32` matches cajeta (`adler32MatchesCajeta`); crc32 too.
- [x] **2.2 Coding**
  - [x] 2.2.1 Shim: `__cajeta_zlib_compress(dst, dstcap, src, len, level, wbits)`
        and `__cajeta_zlib_uncompress(dst, dstcap, src, len, wbits)`, `wbits`
        selecting raw(−15)/zlib(15)/gzip(31) via `deflateInit2`/`inflateInit2`;
        negative return = `Z_*` code. `__cajeta_zlib_compress_bound` sizes dst.
  - [x] 2.2.2 `__cajeta_zlib_adler32`.
  - [x] 2.2.3 Grow-and-retry for unknown inflate size: `Z_BUF_ERROR` (dst full,
        not stream-end) → double cap and retry; terminal errors → `DeflateException`.
  - [x] 2.2.4 `NativeZlib` bindings + `Z_*` → `DeflateException` translation
        (`error()`); framing wrappers `deflate`/`inflate`/`gzip*`/`zlib*`.
- [x] **2.3 Acceptance**
  - [x] 2.3.1 All 2.1 tests pass (208 suite total, 0 fail).
  - [x] 2.3.2 Interop proven both directions with the cajeta decoders (themselves
        validated against python `zlib`/`gzip`); native emits standard RFC framing.

## 3. Selector + wire public API to native, cajeta as fallback  (spec 4.1–4.4)

- [ ] **3.1 TDD**
  - [ ] 3.1.1 Differential: native vs forced-cajeta round-trip identical on the
        corpus (text/binary/empty/incompressible/repetitive/large).
  - [ ] 3.1.2 The selector picks native on a native-linked build; forcing
        fallback runs cajeta.
  - [ ] 3.1.3 The existing codec suite (196 tests) still passes unchanged.
- [ ] **3.2 Coding**
  - [ ] 3.2.1 A `DeflateBackend` selector (native-present flag; env/force hook
        for tests).
  - [ ] 3.2.2 Route `Deflate.deflate/inflate`, `Gzip.compress/decompress`,
        `Zlib.compress/decompress` through the selector; the current cajeta
        bodies become the fallback branch.
  - [ ] 3.2.3 Keep `deflateFixed` / `DynDeflate` reachable for the fallback +
        differential tests.
- [ ] **3.3 Acceptance**
  - [ ] 3.3.1 Default build uses native; API unchanged; 196 + new tests green.
  - [ ] 3.3.2 Fallback build (no native) round-trips correctly.

## 4. Per-target static build + cross-compile smoke  (spec 2.2, 2.4, 5.3)

- [ ] **4.1 TDD**
  - [ ] 4.1.1 A smoke script builds+links the native backend for each triple:
        linux-x86_64, linux-arm64, windows-x86, macos-x86_64, macos-arm64,
        linux-riscv64 (compile+link gate; run where hardware/emulation exists).
- [ ] **4.2 Coding**
  - [ ] 4.2.1 Per-platform native-lib declaration; vendored-zlib static build
        per target (no system libz assumption).
  - [ ] 4.2.2 Resolve any target-specific zlib build knobs (e.g. `Z_HAVE_UNISTD`,
        large-file, RISC-V/Windows quirks).
- [ ] **4.3 Acceptance**
  - [ ] 4.3.1 All six link; at least the host triple runs the full suite.
  - [ ] 4.3.2 Cross-build results recorded (which ran vs link-only).

## 5. Licensing + docs  (spec 6.1)

- [ ] **5.1 Coding**
  - [ ] 5.1.1 `THIRD-PARTY` (or `native/zlib/README`) retaining zlib's license
        notice verbatim + the vendored version.
  - [ ] 5.1.2 Note the mixed license surface (Apache-2.0 codec + vendored
        zlib-licensed native dep) in the repo README.
  - [ ] 5.1.3 Update `cajeta.json` doc comments to describe the native backend +
        fallback.
- [ ] **5.2 Acceptance**
  - [ ] 5.2.1 Notice present and accurate; license surface documented.

## 6. Performance validation  (spec 5.4)

- [ ] **6.1 TDD**
  - [ ] 6.1.1 Bench: native compress (L1/L6/L9) + inflate on the 128 KiB
        reference payload, reported vs raw zlib on the same machine.
- [ ] **6.2 Coding**
  - [ ] 6.2.1 Extend `bench/` with a native-vs-zlib comparison; record numbers
        in `bench/README.md`.
- [ ] **6.3 Acceptance**
  - [ ] 6.3.1 Native compress ≥ 0.8× raw zlib MB/s on the reference payload
        (perf gate); if not met, record why + next lever.
