# Spec: Native libz backend for DEFLATE / gzip / zlib

Status: active

## 1. Definition

1.1 **Purpose.** Give `dev.cajeta.codec` zlib-class compression throughput by
delegating the DEFLATE / gzip / zlib family to the reference **zlib** library
through cajeta's `@Native` FFI, while keeping the existing pure-cajeta
implementation as a software fallback.

1.2 **Problem.** The pure-cajeta encoder matches zlib's *ratio* (dynamic Huffman
+ lazy matching) but runs ~10× slower on compress (one-shot L6 3 MB/s vs zlib
33) and ~4× slower on inflate (68 vs ~250 MB/s). DEFLATE's bitstream is serial,
so cajeta-side optimization cannot close the gap soon. Measured this session:
no build flag (`--opt`, `--bounds=off`, `--cpu=native`, `--lto`) moves it — the
cost is genuine per-byte work.

1.3 **Approach.** A thin C shim (`__cajeta_zlib_*`) wraps zlib's simple
buffer-in/buffer-out API; cajeta methods `@Native`-bind the shim (the pattern the
stdlib already uses for OpenSSL/TLS). zlib is **vendored and statically linked
per target** via the native-dependency subsystem, so the codec depends on no
system libz. A selector routes each call to the native path when present, else
the cajeta fallback.

1.4 **Scope.** The DEFLATE (RFC 1951), zlib (RFC 1950), and gzip (RFC 1952)
one-shot compress/inflate paths, plus `crc32` / `adler32`.

1.5 **Non-goals.**
- Reimplementing zlib faster in cajeta — deferred ("one day, a cajeta zlib that
  competes"); the pure-cajeta encoder is the seed and stays as the fallback.
- Binding zlib's streaming `z_stream` API. The streaming surface
  (`DeflateStream` / `InflateStream`, used by WebSocket permessage-deflate and
  chunked gzip) stays pure-cajeta for now; a native streaming backend is a
  follow-on (§7).
- Changing the public API. The native backend is a drop-in speed-up behind the
  same signatures.
- The non-DEFLATE codecs (Snappy, LZ4, Avro/Parquet/columnar) — untouched.

1.6 **Constraints.**
- Output stays byte-exact-valid, RFC-correct, and interoperable with system
  gzip/zlib (already true of the cajeta path; must remain so).
- Must build and link for all six target triples: Linux x86-64, Linux ARM64,
  Windows x86, macOS x86-64, macOS ARM64, Linux RISC-V.
- Malformed input raises the codec's `DeflateException` — never a trap/crash.
- zlib's license notice is retained for the vendored source (§6).

## 2. Native binding and per-target build

2.1 Requirements. A C shim over zlib's one-shot API exposes flat
`(ptr, len) → (ptr, len, status)` functions; cajeta `@Native`-binds them. zlib
source is vendored and compiled static for the active target; the
native-dependency metadata (`native-libraries.json` / `NativeLink`) links it.

2.2 As the codec build, when compiling for any of the six target triples, then
vendored zlib is built static for that triple and linked, with **no** dependency
on a system-installed libz.

2.3 As a cajeta caller, when a shim-bound `@Native` method is invoked, then it
calls into zlib and returns the correct result across the C ABI using flat byte
buffers — no `z_stream` struct is marshaled across the boundary.

2.4 As a maintainer cross-compiling to a target, when I build, then the vendored
zlib and shim compile for that target with no host-specific assumptions.

## 3. Compression / decompression parity

3.1 Requirements. The native path is byte-exact-valid, RFC-correct,
zlib-interoperable, and behind the identical public API.

3.2 As a caller, when I gzip-compress then decompress, then I recover the input
byte-exact; the output also decodes under system `gzip`, and a system-`gzip`
member decodes under the codec.

3.3 As a caller, when I use the zlib (RFC 1950) or raw DEFLATE (RFC 1951) form,
then it round-trips and interoperates with `zlib.decompress` / `-15`.

3.4 As a caller, when I request compression level 1..9, then the level is honored
and the ratio matches zlib at that level.

3.5 As a caller, when I compute `crc32` or `adler32`, then the value matches both
the pure-cajeta result and the reference checksum.

3.6 As a caller, when I feed malformed/truncated input, then a
`DeflateException` is raised (the shim translates zlib's `Z_*` error codes) —
never an abort or memory fault.

## 4. Fast-path / fallback selection

4.1 Requirements. A selector picks the native backend when it is linked in, else
the pure-cajeta backend, transparently to callers.

4.2 As a caller on a native-capable build, when I compress or inflate, then the
native path runs.

4.3 As a caller on a fallback-only build (no native backend), when I compress or
inflate, then the pure-cajeta path runs — correct, slower.

4.4 As a test, when I force each backend explicitly, then both yield identical
round-trip results on a shared corpus (differential parity).

## 5. Testing and validation

5.1 As CI on the build host, when the suite runs, then native round-trip +
system-`gzip`/`zlib` interop pass.

5.2 As a differential test, when a corpus (text, binary, empty, incompressible,
highly-repetitive, large) is run through native and cajeta, then every case
round-trips byte-exact on both.

5.3 As a release check, when the codec is built for each of the six triples,
then it compiles and links; it runs where hardware or emulation is available.

5.4 As a performance gate, when the native compress path is benched, then it is
within a stated margin of raw zlib on the reference payload (e.g. ≥ 0.8× zlib
MB/s).

## 6. Licensing

6.1 As a distributor, when the codec ships the vendored zlib source, then zlib's
license notice is retained verbatim and recorded in a repo `THIRD-PARTY` notice
(zlib is permissive; static linking is allowed with the notice kept).

## 7. Follow-ons (out of scope here)

7.1 Native **streaming** backend (`z_stream`) for `DeflateStream` /
`InflateStream` → WebSocket permessage-deflate and chunked gzip at native speed.

7.2 A future optimized **pure-cajeta** encoder that competes with zlib (the
deferred "cajeta zlib") — the current fallback is its starting point.
