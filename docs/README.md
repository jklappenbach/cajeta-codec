# cajeta-codec docs

**User-facing documentation only** — the guide and reference for using the
codec library. Engineering work specs are workflow artifacts and live in
`../specs/`, never here; plans live in `../agents/`.

- **Framework spec** — the cross-format design (staged-access convention,
  packaging split, fail-loud + conformance discipline, SIMD policy) lives in the
  toolchain at `docs/specification/codec/Codecs.md`. This library implements
  Part B (§1.4) of it.
- **Per-format reference** — one subdirectory per format:
  - [`protobuf/`](protobuf/) — Protocol Buffers
  - `ion/`, `avro/`, `parquet/`, `orc/` — to be written

The runnable counterpart to these documents is the library tour under
`../samples/tour/`, which every public type must appear in (CI-gated by
`scripts/check-library-tour-coverage.sh`).
