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

  **Resolved 2026-08-12** — swept and fixed on branch `wire-extremes`; see
  `WireExtremesTest`. Two corrections to the analysis above, both found by
  probing rather than reading:
  - The `ThriftCompactWriter` bullet was **wrong**. The mask does make its
    shift logical, but the loop is gated on `t >= (int64) 128`, a *signed*
    compare — so a bit-63-set word looked already-small and a 10-byte varint
    was written as one byte. Parquet i64 statistics past ±2^62 were silently
    truncated on write. `AvroWriter` is genuinely unaffected: its loop tests
    `t != 0`, not a magnitude. Masking the shift is not sufficient; the loop
    bound has to be unsigned too.
  - `IonWriter` was worse than "reachable if `t` can go negative".
    `uintMagLen` / `varUIntLenOf` answered **0** for a bit-63-set value, and
    fixing them exposed that `writeIntValue(int64Min)` computes `0 - v`, which
    overflows and **traps (SIGILL) in release builds, not only under
    `--profile=test`**. Ion stores sign and magnitude separately and 2^63 is a
    legal magnitude, so the value has a correct encoding: `0x38` + eight bytes
    of `0x80 00…`.

  Also learned, and the reason the sweep could not be done by grep alone: `>>`
  semantics are **toolchain-version-dependent for `uint64`**. Through cajeta
  0.17.0 `>>` was arithmetic on `uint64` as well as `int64`; from 0.19.0 it is
  logical on `uint64` and arithmetic only on `int64`. So `OrcRleV2.bitLen` and
  the DEFLATE bit accumulators were latent non-terminating loops that the
  *compiler* fixed underneath them. `bitLen` now says `>>>` explicitly, which
  means unsigned on every toolchain.
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
- **2.10** When a length-delimited **stream** (`parse<T[]>`) is truncated — a
  frame header claiming more bytes than remain — it is rejected at the frame's
  start offset. Found during §6: the synthesized stream body read its frame
  lengths unbounded and then allocated from a length it had already overrun, so
  a journal cut short by a closed socket walked past the buffer. Same defect
  class as §2.1, in the synthesizer rather than the index, which is why §2's
  index hardening did not cover it.

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
- **6.5** When a repeated numeric field is written, `toBytes<T>` emits a single
  LEN record holding the concatenated values — packed is the **default**, as in
  proto3 and edition 2023 (`features.repeated_field_encoding = PACKED`); only
  proto2 defaulted to expanded. `packed = false` opts back out. This reverses
  the spec's original wording ("when declared packed"), decided after the
  implementation landed: matching the format's own default is worth more than
  the opt-in, and the change is wire-safe because 6.6 requires readers to accept
  both forms. Flipping it later would have silently changed users' bytes, so it
  was done while nothing yet depended on it.
- **6.5b** When a repeated field's elements are String, bytes, or messages, it is
  never packed — they carry their own length and protobuf defines no packed form
  for them — and asking for `packed` there, or on a non-repeated field, fails
  compilation.
- **6.6** When a packed repeated field is read, its values decode from the one
  LEN payload — and an unpacked wire form of the same field decodes identically,
  because peers may send either.
- **6.7** When a packed field's payload does not divide evenly into its element
  width, the message is rejected rather than yielding a truncated last element.
- **6.8** When a repeated field of a fixed-width or zigzag encoding is packed,
  the element encoding declared in §4 governs each element.

## 7. SIMD over packed payloads

7.1 **Why not the field scan.** This section originally required SIMD on the
stage-1 tag/varint boundary scan, following framework spec §8.2. **That is not
achievable for protobuf's field walk, and the requirement is withdrawn.** JSON
and CSV vectorize because their structural bytes are context-free — `{`, `,`,
`"` are identifiable by value alone, so a comparison against 16 bytes at once is
meaningful. Protobuf is tag-length-value: whether byte *k* begins a tag depends
on having decoded every field before it, and no byte value marks a boundary
(`0x08` is as likely to be payload as a tag). The walk is a genuine serial
dependency chain, which is why simdjson exists and no "simdproto" does.
Speculating and validating buys nothing, because validation *is* the serial walk.

7.2 **What is vectorizable.** A **packed repeated payload** is context-free: a
run of varints with no interleaved framing, whose element boundaries are given
by the continuation bit of each byte. That is framework §8.2's second SIMD
clause — "bulk packed-repeated primitive fields" — and it is what serves UC-PB-3.
The scalar path remains as both fallback and correctness oracle.

- **7.3** When a packed varint payload is scanned on a SIMD-capable target, the
  element count and the decoded values are identical to the scalar path's, for
  every input the scalar path accepts.
- **7.4** When a packed payload is malformed — a truncated trailing varint, a
  ragged fixed-width tail — the SIMD path rejects it identically to the scalar
  path: same exception, same position. Vectorization must not open a hole §2 or
  §6.7 closed.
- **7.5** When a payload is shorter than one vector, or an exact multiple of the
  vector width, it decodes correctly — the tail path and the block path agree at
  their boundary.
- **7.6** When packed-payload decoding is benchmarked over a large repeated
  field, the SIMD path is compared against the scalar path and the result is
  recorded, whichever way it falls. A vectorization that does not pay is
  reported as such rather than kept for appearance.
- **7.7** When the available vector surface lacks an operation the algorithm
  wants, the gap is recorded rather than worked around silently. As of this
  writing `Vector<T,N>` implements `eqMask`, `dot`, `length`, `normalize`,
  `compressStore`, and mask `all`/`any`/`select`; the `splat`, `mask()`
  (movemask), `tableLookup`, and `i8x16`-style aliases described in
  `docs/specification/math/Simd.md` and its tour are **not** implemented. A
  constant array loaded through `Cajeta.vload16` substitutes for `splat`.

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
