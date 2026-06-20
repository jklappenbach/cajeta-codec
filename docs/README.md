# cajeta-codec docs

Public specs for the codec library live here.

- **Framework spec** — the cross-format design (staged-access convention,
  packaging split, fail-loud + conformance discipline, SIMD policy) is the
  toolchain's `docs/specification/codec/Codecs.md`. This library implements
  Part B (§1.4) of it.
- **Per-format specs** — one subdirectory per format as it lands:
  - `protobuf/` — Protocol Buffers (Phase 2)
  - `ion/`, `avro/`, `parquet/`, `orc/` — added with each phase.

Per-format specs are authored (via the design workflow) before that format's
implementation begins; the framework spec governs all of them.
