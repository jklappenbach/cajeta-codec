# Spec: Protocol Buffers — completion and hardening

Status: active

## 1. Definition

1.1 **Purpose.** Bring `dev.cajeta.codec.protobuf` from "reader + writer that
works on well-formed input" to the surface the codec framework spec
(`cajeta/docs/specification/codec/Codecs.md` §8.2) actually specifies: safe on
hostile input, complete across the scalar type set, capable of repeated and
packed fields, and SIMD on the structural scan.

1.2 **Problem.** The format shipped its happy path — wire primitives, structural
index, lazy cursor, writer, and a synthesized typed facade covering scalars,
nested messages, and delimited streams (UC-PB-1, UC-PB-2, UC-PB-4). Four gaps
were confirmed by direct probe against the built library, not by reading:

- **1.2.1** A truncated varint **aborts the process**. `ProtobufWire.varintLen`
  and `decodeVarint` walk until a byte without the continuation bit, with no
  bound. Given `[0x08, 0x96]` and `n = 2`, the scan runs off the array and the
  runtime bounds check turns it into `SIGABRT`. The library's stated contract —
  "malformed input raises `ProtobufParseException`, never a crash" — is violated,
  and under `--bounds=off` this is an out-of-bounds read instead.
- **1.2.2** A LEN field whose declared length exceeds the buffer is **accepted
  silently**. Given a field claiming 100 payload bytes with 4 bytes supplied,
  `ProtobufIndex.build` returns `valueEnd = 102` for `n = 4`. Every later read
  through that slot is out of range.
- **1.2.3** A `float32` / `float64` `@ProtoField` is **silently dropped**, both
  directions, with no diagnostic at compile time or run time. The synthesizer
  classifies floats as `Unsupported` and `continue`s past them
  (`ProtobufSynthesizer.cpp:94`, `:224`). A two-field message encoded to 2 bytes
  in the probe; the float never reached the wire.
- **1.2.4** `ProtobufIndex.build` allocates `n + 1` slots across four parallel
  arrays — 24 bytes of index per input byte. A 472-byte message measured 11,352
  bytes of index. This is eager work in the type whose purpose is laziness.

Beyond the defects, the specified feature set is incomplete: no repeated fields,
no packed repeated (UC-PB-3), no zigzag or fixed-width integer opt-in, and the
structural scan is scalar where §8.2 designates it a SIMD site.

1.3 **Approach.** Six units in dependency order. Bounds safety first — it is a
live crash and every later unit builds on a trustworthy index. Then index
footprint, then the annotation's encoding options, then floats, then repeated and
packed fields, then SIMD over a locked scalar oracle.

1.4 **Scope.** `dev.cajeta.codec.protobuf` in this repo, **and** the per-`T`
synthesizer at `~/code/cpp/cajeta/src/cajeta/codec/ProtobufSynthesizer.cpp` in
the toolchain repo. The typed facade is emitted there, so the typed-surface
requirements (§4, §5, §6) cannot be met from this repo alone. Units state which
repo they land in.

1.5 **Non-goals.**
- **1.5.1** `.proto` schema import / codegen (UC-PB-5). The framework spec §10
  decides this is "a later, separate tooling track"; annotation-described
  messages come first. Out of scope here.
- **1.5.2** `@Encoding(ProtobufEncoder<T>.class)`. Listed in framework spec §8.2's
  access surface and absent from the repo, but it is a cross-format tier
  concern — the same hole exists for Ion and Avro — and belongs to a framework
  unit, not a protobuf one. Recorded here so it is not lost.
- **1.5.3** Auditing Ion, Avro, Parquet, and ORC for the defect classes found
  here. Widening this spec to four more formats would bury the protobuf work, so
  a follow-on spec should sweep them. What is already known, from grepping the
  shift sites while fixing §4:
  - `IonWriter.cajeta:104` does `t = t >> 7` in its varint loop with **no**
    sign mask — the same non-terminating encode protobuf had, reachable if `t`
    can go negative.
  - `AvroBinary.zigzagDecode:43` and `ThriftCompactReader.cajeta:104` both do
    `(raw >> 1)` arithmetically, so they mis-decode any zigzag value with bit 63
    set, exactly as protobuf's did.
  - `AvroWriter.cajeta:48` and `ThriftCompactWriter.cajeta:42` are **not**
    affected: they mask with `& 0x01FFFFFFFFFFFFFF` after the shift, which is a
    correct workaround for an arithmetic `>>`.
  - Truncation hardening (§2) has not been checked for any of them.
- **1.5.4** Group wire types (3, 4). Deprecated in the format itself; fail-loud
  rejection is the correct and current behavior.
- **1.5.5** Changing any existing public signature. Every change is additive or
  internal; the 214-test suite must stay green throughout.

1.6 **Constraints.**
- **1.6.1** Malformed, truncated, or hostile input raises
  `ProtobufParseException` with a byte position. Never a crash, never a silent
  partial read — including under `--bounds=off`.
- **1.6.2** Unsupported is never silent. A construct the implementation cannot
  handle fails loud, naming what it could not handle.
- **1.6.3** Wire output stays byte-compatible with the protobuf specification and
  interoperable with other implementations.
- **1.6.4** SIMD is applied only to the structural scan, per the framework spec's
  SIMD policy — never to a serial dependency chain.
- **1.6.5** Every new public type or method appears in the library tour
  (`samples/tour/`), which CI gates for coverage.

## 2. Bounds safety and fail-loud parsing

2.1 **Requirements.** Every read is bounded by the caller-supplied length `n`.
The index rejects any record that does not fit entirely within `[0, n)`, at the
position where the overrun is detected. No input, however malformed, reaches an
array access outside the buffer.

- **2.2** When a varint's continuation bit is set on the last byte within `n`,
  the message is rejected as truncated at the varint's start offset.
- **2.3** When a varint exceeds ten bytes — longer than any 64-bit value can
  encode — it is rejected as malformed, rather than shifting past the width.
- **2.4** When a LEN field's declared length would place its payload end beyond
  `n`, the message is rejected at the field's start offset.
- **2.5** When an I32 or I64 field has fewer than 4 or 8 bytes remaining before
  `n`, the message is rejected.
- **2.6** When a tag's field number is zero, the message is rejected — zero is
  not a legal protobuf field number and usually means the reader has lost sync.
- **2.7** When a message is truncated at any byte offset, parsing it raises
  `ProtobufParseException` rather than aborting, for every prefix of a
  well-formed message.
- **2.8** When a cursor reads a slot, the bytes it returns lie within the buffer
  the cursor was built over.
- **2.9** When the index rejects input, the exception's `position` identifies the
  byte where the defect was found, so a caller can log or seek to it.

## 3. Index footprint

3.1 **Requirements. ** The structural index allocates in proportion to the number
of fields present, not to the byte length of the message. Building an index over
a large message must not cost a multiple of the message itself.

- **3.2** When a message of `n` bytes holding `f` top-level fields is indexed,
  the index's allocation is proportional to `f`, not to `n`.
- **3.3** When a message is indexed, the resulting field numbers, wire types, and
  value bounds are identical to those the current implementation produces for
  every input it accepts.
- **3.4** When a message has more fields than the initial allocation holds, the
  index grows without loss and without a quadratic copy.

## 4. Encoding options on `@ProtoField`

4.1 **Requirements.** The annotation carries the wire-encoding choices protobuf
offers for a given Cajeta type, so a message class can describe `sint32`,
`fixed64`, and packed repeated fields. Defaults preserve today's behavior:
integers are plain VARINT unless told otherwise.

- **4.2** When a field declares no encoding option, it encodes exactly as it does
  today — no existing message changes on the wire.
- **4.3** When a field declares zigzag encoding, its value round-trips through
  the `sint32`/`sint64` transform, so small negative numbers cost few bytes
  instead of ten.
- **4.4** When a field declares fixed-width encoding, it uses wire type I32 or
  I64 matching its declared width, and interoperates with a peer's
  `fixed32`/`sfixed64`.
- **4.5** When a field declares an encoding its Cajeta type cannot carry — zigzag
  on a `String`, say — compilation fails naming the field and the conflict.
- **4.6** When a field declares an encoding, the same choice governs both decode
  and encode, so a round-trip through the typed facade is lossless.

## 5. Floating-point fields

5.1 **Requirements.** `float32` and `float64` fields bind through the typed
facade as protobuf `float` and `double`: wire types I32 and I64 carrying IEEE-754
bits, little-endian.

- **5.2** When a message has a `float64` field, `toBytes<T>` writes it as an I64
  field and `parse<T>` reads it back to the same value.
- **5.3** When a message has a `float32` field, it round-trips through wire type
  I32 at single precision.
- **5.4** When a float field carries a special value — negative zero, an
  infinity, a NaN — the bit pattern survives the round-trip.
- **5.5** When a float field is absent from the wire, the constructor's default
  is kept, matching the absence contract for every other type.
- **5.6** When the synthesizer meets a field type it cannot bind, compilation
  fails naming the class, the field, and the type — no field is ever dropped in
  silence. This closes the general case behind 1.2.3, not just floats.

## 6. Repeated and packed fields

6.1 **Requirements.** A repeated field binds to a Cajeta array through the typed
facade, in both directions. Repeated primitives support protobuf's packed
encoding — one LEN record holding the concatenated values — on write, and both
encodings on read, since a conforming reader must accept either.

- **6.2** When a message has a repeated scalar field, every occurrence on the
  wire binds into the array in wire order.
- **6.3** When a message has a repeated message field, each occurrence is decoded
  as a nested message into the array.
- **6.4** When a repeated field is absent from the wire, it binds as an empty
  array rather than null, matching protobuf's "repeated fields are never absent,
  only empty" contract.
- **6.5** When a repeated numeric field is declared packed, `toBytes<T>` writes a
  single LEN record holding the concatenated values.
- **6.6** When a packed repeated field is read, its values decode from the one
  LEN payload — and an unpacked wire form of the same field decodes identically,
  because peers may send either.
- **6.7** When a packed field's payload does not divide evenly into its element
  width, the message is rejected rather than yielding a truncated last element.
- **6.8** When a repeated field of a fixed-width or zigzag encoding is packed,
  the element encoding declared in §4 governs each element.

## 7. SIMD structural scan

7.1 **Requirements.** The stage-1 scan — locating tag and varint boundaries —
uses SIMD where the target supports it, and is validated against the scalar
implementation as the oracle. The scalar path remains, both as fallback and as
the correctness reference.

- **7.2** When a message is indexed on a SIMD-capable target, the index produced
  is byte-for-byte identical to the scalar index for the same input.
- **7.3** When a message is indexed on a target without SIMD support, the scalar
  path produces the same result.
- **7.4** When malformed input is scanned, the SIMD path rejects it identically
  to the scalar path — same exception, same position. Vectorization must not open
  a hole that §2 closed.
- **7.5** When the scan is benchmarked over a large message, the SIMD path is
  measurably faster than the scalar path, and the comparison is recorded.

## 8. Documentation and tour

8.1 **Requirements.** The public documentation describes what the library
actually does, and the tour exercises every public entry point.

- **8.2** When a limitation is removed, the corresponding entry in
  `docs/protobuf/README.md`'s limitations section is removed with it, in the same
  commit.
- **8.3** When a public type or method is added, it appears in the library tour,
  which CI gates.
- **8.4** When the tour runs, its protobuf demo asserts the new behavior rather
  than merely calling it.
