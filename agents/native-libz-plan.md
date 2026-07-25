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

## 3. Selector + wire public API to native, cajeta as fallback  (spec 4.1–4.4)  ✅ DONE

- [x] **3.1 TDD** (`DeflateBackendTest`, 6 tests)
  - [x] 3.1.1 Differential: native vs forced-cajeta round-trip identical on the
        corpus — text / repetitive / incompressible(LCG) / empty / large(40 KB),
        each raw+zlib+gzip through both backends *and* cross-backend decode.
  - [x] 3.1.2 `selectorSwitchesBackends` proves `forceFallback` routes to a
        different encoder (byte streams differ, both round-trip).
  - [x] 3.1.3 The existing suite passes unchanged (native now the default path;
        214 total, 0 fail).
- [x] **3.2 Coding**
  - [x] 3.2.1 `DeflateBackend` selector — `useNative()` + `forceFallback()` test
        hook. (No runtime "native absent": `@Native` reference makes the artifact
        a link requirement; a native-free build is a compile-time variant, Unit 4.)
  - [x] 3.2.2 Routed `Deflate.deflate`/`inflate`/`inflateGrow`, `Gzip.compress`/
        `decompress`, `Zlib.compress`/`decompress` through the selector; cajeta
        bodies are the fallback branch. Native honors the codec contract:
        level clamp [1,9], strict-framing (reject trailing input).
  - [x] 3.2.3 `deflateFixed` / `DynDeflate` stay reachable (public + fallback).
- [x] **3.3 Acceptance**
  - [x] 3.3.1 Default build uses native; API unchanged; suite green (214/1 skip).
  - [x] 3.3.2 Fallback round-trips correctly — fixed a latent `ensure()` infinite
        loop on a zero-capacity output buffer (`inflate(.., 0)` / `Zlib.decompress
        (.., 0)`) surfaced by the empty-corpus fallback case.

## 4. Per-target static build + cross-compile smoke  (spec 2.2, 2.4, 5.3)  ✅ DONE (4/6 built locally; macOS×2 via native-macos CI → all six verifiable)

- [x] **4.1 TDD**
  - [x] 4.1.1 `native/cross-build.sh` builds the archive for each of the six
        triples (linux-x64/arm64/riscv64, windows-x64, macos-x64/arm64), choosing
        a per-target compiler and **recording SKIP (never faking)** where the
        toolchain is absent. Host triple builds + runs the full suite.
- [x] **4.2 Coding**
  - [x] 4.2.1 Per-target vendored-zlib static build (matrix in `cross-build.sh`),
        no system-libz assumption; `llvm-ar` archives ELF/COFF/Mach-O uniformly.
  - [x] 4.2.2 Target-specific knobs: **none needed** — dropping the `gz*` TUs
        (Unit 1) removed the unistd/lseek/large-file surface, so identical flags
        compile on every triple. Documented in `native/CROSS-BUILD.md`.
- [x] **4.3 Acceptance**
  - [x] 4.3.1 **4 of 6 built + object-arch verified** on this host via `clang-21`
        (full LLVM backends) + sudo-free extracted sysroots (`apt-get download` +
        `dpkg-deb -x`): linux-x64 (x86-64 ELF), linux-arm64 (AArch64 ELF),
        linux-riscv64 (RISC-V ELF), windows-x64 (x86-64 COFF) — all three ISAs
        and both non-Apple object formats. Host triple also **runs the full suite**
        (214). Enabled via the new `CC_<platform>` override. macOS×2 (the only
        Linux-side SKIP — Apple SDK is a licensing gate) are built + Mach-O-arch
        verified by the `native-macos` GitHub Actions workflow (`macos-14` runner,
        arm64 + x86_64), so **all six are verifiable in CI**.
  - [x] 4.3.2 Results recorded — matrix, sudo-free + apt provisioning, and this
        host's per-arch snapshot in `native/CROSS-BUILD.md`.

## 5. Licensing + docs  (spec 6.1)  ✅ DONE

- [x] **5.1 Coding**
  - [x] 5.1.1 `THIRD-PARTY.md` retains zlib's full license notice verbatim +
        version (1.3.1) + vendored scope (buffer-API subset, `gz*` omitted).
        `native/zlib/LICENSE` + `VENDORED.txt` present.
  - [x] 5.1.2 README: refined the "our own code" principle to name the one
        vendored exception, and added a **License** section (Apache-2.0 codec +
        zlib-licensed vendored zlib, → `THIRD-PARTY.md` / `CROSS-BUILD.md`).
  - [x] 5.1.3 `cajeta.json` header comment describes the native backend +
        transparent pure-cajeta fallback and the mixed-license surface.
- [x] **5.2 Acceptance**
  - [x] 5.2.1 Notice present and accurate (scope matches the vendored tree —
        buffer-API subset verified); mixed license surface documented in README,
        `cajeta.json`, `THIRD-PARTY.md`, `VENDORED.txt`.

## 6. Performance validation  (spec 5.4)  ✅ DONE

- [x] **6.1 TDD**
  - [x] 6.1.1 `bench/zlib_ref.c` benches raw zlib (one-shot raw-DEFLATE, L1/6/9 +
        inflate) on the byte-identical 128 KiB payload; `CompressBench` gained a
        NATIVE COMPRESS L1/6/9 block + native one-shot inflate. Same machine.
- [x] **6.2 Coding**
  - [x] 6.2.1 `bench/run-native-vs-zlib.sh` builds+runs both; numbers recorded in
        `bench/README.md`.
- [x] **6.3 Acceptance**
  - [x] 6.3.1 **PASS** — native/zlib ratio: compress L1 0.95×, L6 0.97×, L9 0.98×,
        inflate 1.02× (all ≥ 0.8×). Inflate first measured 0.37× (redundant
        exact()-copy); fixed by returning the buffer directly on an exact-fit
        `destLen` (`r == cap`) → 1.02×. Suite still 214/214.

## 7. Publish integration — self-contained `.cja` (spec §3.3)  ✅ BAKE VERIFIED (v0.9.5); release wiring + cajeta-http bump remain

The native backend links locally (`CAJETA_NATIVE_PATH`), and a *published* `.cja`
must carry the per-platform artifact so consumers (cajeta-http) link offline.

- [x] **7.1** Declare `cajeta_zlib` in `cajeta.json` `settings.native-libraries`
      (version 1.3.1, license Zlib, redistributable, static, six platforms) —
      parses, embeds in the `.cja` metadata (`03b840e`).
- [x] **7.2** Bake the per-platform `libcajeta_zlib.a` into the `.cja`
      `native/<platform>/` tree (spec §3.3). **VERIFIED on v0.9.5:** `cajeta build`
      with the native-libraries block + a resolvable archive bakes
      `native/linux-x64/libcajeta_zlib.a` **byte-identical** (sha256
      `de575ef5…` == source) plus `native/native-libraries.json`
      (`{"requires":["cajeta_zlib"],…}`). Confirmed via `cajeta archive
      list`/`cat` — the entry-level truth. (My earlier "not baked" call was a
      **false negative**: the `.cja` is zstd-compressed, so the size-based A/B
      masked the delta. The size test was wrong; the artifact IS baked.)
- [x] **7.3** v0.9.5 (the installed CI toolchain) implements §3.3 baking — no
      separate explicit-bake step needed; the artifact must simply be resolvable
      when `cajeta build` runs.
- [x] **7.4** Release wiring: `release.yml`'s `.cja` build has **all six**
      `native/<platform>/*.a` present so all six bake. `native-linux` job
      (cross-gcc + `cross-build.sh` → linux×3 + windows) and `native-macos` job
      (SDK + `cross-build.sh`) upload archives; the build/publish job downloads
      them into `native/` and sets `CAJETA_NATIVE_PATH` before the build +
      verifies the six baked entries.
- [x] **7.5 — END-TO-END FINDING.** The consumer link **does NOT auto-extract**
      native from a classpath `.cja` (spec §3.2.2 unimplemented in v0.9.5):
      `--emit=exe --classpath=<codec.cja>` errors `native library 'cajeta_zlib'
      not found; searched: CAJETA_NATIVE_PATH / project native/ / ~/.cajeta/native`.
      **The working path (verified, tour consumer, 11/11 offline):** the `.cja`
      *carries* the artifact, so the consumer extracts it — `cajeta archive
      extract <codec.cja>` → `CAJETA_NATIVE_PATH=<dir>/native` → links offline,
      no vendoring, no network. cajeta-http adopts this extract-bridge in its
      build.
- [ ] **7.6** Toolchain gap (out of codec scope): implement §3.2.2 — the
      consumer resolver should search dependency `.cja` `native/` trees directly,
      so the extract-bridge becomes unnecessary. File against the compiler.
