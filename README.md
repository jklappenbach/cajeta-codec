# cajeta-codec

Standalone codec library for [Cajeta](https://cajeta.org) — Part B of the codec
framework. The core stdlib ships `cajeta.codec.{json, csv}`; this library adds
the specialized formats most programs never touch, under the `dev.cajeta.*`
namespace (the convention for our own non-stdlib libraries — a standalone `.cja`
cannot extend the stdlib-owned `cajeta.codec.*` namespace through classpath
linking):

| Package | Format | Status |
|---|---|---|
| `dev.cajeta.codec.protobuf` | Protocol Buffers | reader + writer + typed facade; [gaps tracked](specs/protobuf-spec.md) |
| `dev.cajeta.codec.ion`      | Amazon Ion       | reader + writer + typed facade |
| `dev.cajeta.codec.avro`     | Apache Avro      | reader + writer + typed facade, OCF containers |
| `dev.cajeta.codec.parquet`  | Apache Parquet   | reader + writer, dictionary/nullable/multi-row-group |
| `dev.cajeta.codec.orc`      | Apache ORC       | reader + writer, RLE v2, column stats |

Every format above ships both directions with `@Test` coverage in the suite.
"Status" here means *implemented and tested*, not *complete against the format
spec* — protobuf is the only one audited gap-by-gap so far
([spec](specs/protobuf-spec.md), [plan](agents/protobuf-plan.md)).

Plus the columnar tier (`XFile` / `ColumnVector<T>`) and the compression codecs
(`Compressor` / `Decompressor`). The DEFLATE / gzip / zlib family has a native
[zlib](native/) fast path with a pure-cajeta fallback (see **License** below).

## Principles

- **Our own code is the reference — one vendored exception.** Every format
  implementation is ours; completeness is carried by *our implementation + a
  conformance corpus (golden fixtures generated offline by reference tools,
  never linked) + fail-loud*: an unimplemented feature raises
  `UnsupportedFeatureException` naming the encoding/type/version, never a silent
  miscode or partial read. The sole third-party component is **vendored zlib**,
  statically linked as the optional native DEFLATE backend for zlib-class
  throughput; the pure-cajeta encoder/decoder remains as the transparent
  fallback, so the guarantee holds functionally with or without the native lib.
- **Read *and* write in v1** — writers ship with readers.
- **SIMD the structural scan** (varint/tag index) and the columnar integer
  encodings; never SIMD the LZ match-copy chain.
- **The staged-access convention** — the type in your hand names the pipeline
  stage; its methods are the only legal next steps.

## Layout

```
cajeta.json                      # library manifest (no entry-method → emits .cja)
src/main/cajeta/dev/cajeta/codec # library sources, by format subpackage
src/test/cajeta/dev/cajeta/codec # cajeta-unit @Test suites
docs/                            # user-facing format documentation
specs/                           # engineering work specs + INDEX (active work)
agents/                          # work plans + this clone's focus stack
samples/tour/                    # the runnable, self-checking library tour
native/                          # vendored zlib + shim, per-target static libs
run-tests.sh                     # build lib + cajeta-unit, link, run the suite
```

Work in flight is tracked as a **spec** (`specs/<name>-spec.md`, the *why* and
*what*) plus a **plan** (`agents/<name>-plan.md`, the TDD work breakdown whose
checkboxes are the source of truth for progress). `specs/INDEX.md` lists only
active work; both documents move to `archive/` when the plan closes. See
[`td-project-workflow.md`](td-project-workflow.md).

## Build & test

```sh
cajeta build          # → build/archive/cajeta.codec-0.1.0.cja
./run-tests.sh        # build + link cajeta-unit + run @Test discovery
```

`run-tests.sh` expects a `cajeta-unit` checkout beside this repo (override with
`UNIT_REPO=...`). It uses classpath-bitcode linking, so a toolchain with that
fix (cajeta ≥ 0.7.1-dev) is required.

## Framework reference

The codec framework spec lives in the toolchain at
`docs/specification/codec/Codecs.md`; this library implements its Part B (§1.4).
The typed facades (`Protobuf.parse<T>` and its Ion/Avro twins) are synthesized
per-`T` by the toolchain's `src/cajeta/codec/*Synthesizer.cpp` — the bodies in
this repo are failsafes that throw if the synthesizer does not engage, so work
on the typed surface spans both repos. The core tier interfaces
(`cajeta.wire.{Encoder, SchemaEncoder, StreamingEncoder, Compressor,
Decompressor}`) and the JSON/CSV reference implementations are in the core
stdlib.

## License

`dev.cajeta.codec` is **Apache-2.0**. It has one mixed-license surface: the
optional native DEFLATE backend statically links **vendored zlib 1.3.1**
(`native/zlib/`), which is under the permissive **zlib License** — static
linking is allowed with the notice retained. The full notice and the exact
vendored scope are in [`THIRD-PARTY.md`](THIRD-PARTY.md); per-target builds are
described in [`native/CROSS-BUILD.md`](native/CROSS-BUILD.md). The native path is
a drop-in speed-up: with the artifact unlinked, the pure-cajeta backend (all
Apache-2.0) serves the same public API.
