# Plan: Protocol Buffers — completion and hardening

Traces [specs/protobuf-spec.md](../specs/protobuf-spec.md). Status: active.

## Description

Close the confirmed defects and the specified-but-missing features in
`dev.cajeta.codec.protobuf`. Bounds-safe, fail-loud parsing first (a truncated
message currently aborts the process); then a field-proportional index; then the
encoding options, float support, and repeated/packed fields that the typed facade
lacks; then the SIMD structural scan the framework spec designates.

## Systems

- **`dev.cajeta.codec.protobuf`** (this repo) — `ProtobufWire`, `ProtobufIndex`,
  `ProtobufCursor`, `ProtobufWriter`, `ProtoField`, `ProtobufParseException`.
- **`ProtobufSynthesizer.cpp`** at `~/code/cpp/cajeta/src/cajeta/codec/` — the
  toolchain-side emitter for `Protobuf.parse<T>` / `toBytes<T>`. The typed
  surface lives here, not in this repo. (`~/code/cpp/cajeta-two` is a stale fork
  carrying an identical copy — **do not edit it**.)
- **cajeta-unit** `@Test` discovery, via `./run-tests.sh`.
- **The library tour** (`samples/tour/`), CI-gated for public-surface coverage by
  `scripts/check-library-tour-coverage.sh`.
- **Protocol Buffers wire specification** — varint, zigzag, packed repeated, and
  the fixed-width encodings.

## Deliverables

- A protobuf reader that cannot be made to read outside its buffer, and raises
  `ProtobufParseException` with a byte position on every malformed input.
- A structural index whose allocation tracks field count, not message length.
- A typed facade covering floats, zigzag and fixed-width integers, and repeated
  and packed fields — and which fails compilation rather than dropping a field it
  cannot bind.
- A SIMD stage-1 scan validated against the scalar oracle, with a recorded bench.
- `docs/protobuf/README.md` limitations list emptied as each unit lands, and tour
  coverage for every new public entry point.

## Note

Units 3–5 span **two repositories**. Each change to the typed facade needs a
toolchain rebuild before this repo's tests can see it. Land the toolchain side
first within a unit, then the library side, then the tests.

Unit 1 is the priority: it fixes a live process abort. Units 2 and 6 are
library-only. Order is by dependency — 6 needs 1's rejection semantics settled so
the SIMD path can be checked against them, and 5 needs 3's encoding options.

---

## 1. Bounds-safe, fail-loud parsing  (spec 2.1–2.9, 1.6.1)  — this repo  ✅ DONE

- [x] **1.1 TDD** — new `ProtobufBoundsTest` (12 tests)
  - [x] 1.1.1 `truncatedVarintRaises` — `[0x08, 0x96]` with `n = 2` (continuation
        bit set on the final byte) raises `ProtobufParseException`, not an abort.
        This is the regression test for the confirmed crash.
  - [x] 1.1.2 `overlongVarintRaises` — eleven bytes each with the continuation bit
        set raises rather than shifting past 64 bits.
  - [x] 1.1.3 `lenBeyondBufferRaises` — a LEN field declaring 100 payload bytes
        with `n = 4` raises; before this it silently yielded `valueEnd = 102`.
  - [x] 1.1.4 `truncatedFixed32Raises` / `truncatedFixed64Raises` — an I32 or I64
        field with fewer than 4 or 8 bytes left before `n` raises.
  - [x] 1.1.5 `zeroFieldNumberRaises` — a tag decoding to field number 0 raises.
  - [x] 1.1.6 `everyPrefixOfAValidMessageRaisesOrParses` — for a known-good
        multi-field message, every proper prefix either parses cleanly or raises
        `ProtobufParseException`; none aborts. The systematic truncation sweep.
        Prefixes are real copies, so an overrun hits the end of its own
        allocation rather than reading bytes that happen to still be there.
  - [x] 1.1.7 `exceptionCarriesDefectPosition` (a truncated varint reports its own
        start, offset 1) and `lenOverrunReportsRecordStart` (a LEN overrun reports
        the record start, offset 3).
  - [x] 1.1.8 `cursorReadsStayInBuffer` — `readBytes` over an accepted index
        returns exactly the payload, inside `[0, n)`.
  - [x] 1.1.9 `wellFormedMessageStillIndexesUnchanged`, plus the pre-existing 214
        tests — the hardening adds rejections and changes no accepted parse.
  - [x] 1.1.10 `lengthBeyondArrayRaises` — an `n` longer than the array is
        rejected rather than trusted. (Added during the unit: every later bound
        check is derived from `n`, so `n` itself has to be validated first.)
- [x] **1.2 Coding**
  - [x] 1.2.1 `ProtobufWire.varintLen` / `decodeVarint` gained bounded
        `(b, pos, limit)` overloads that stop at `limit`, raise on truncation, and
        cap the scan at ten bytes (`maxVarintBytes()`). The existing `(b, pos)`
        forms now delegate with the array's own length as the limit — no
        signature change, and they became safe too.
  - [x] 1.2.2 `ProtobufIndex.build` validates every record against `n` before
        recording it: `n` within the buffer, non-negative; field number non-zero;
        varint, I32, I64, and LEN payload ends all within `n`; negative length
        prefixes rejected. Each raises at the defect offset.
  - [x] 1.2.3 Group / unknown wire-type rejection kept, folded into the same
        validation path.
  - [x] 1.2.4 `ProtobufParseException` and `ProtobufIndex` doc comments corrected
        — the former claimed truncation coverage the code did not implement.
- [x] **1.3 Acceptance**
  - [x] 1.3.1 Full suite green — **226 passed, 0 failed, 1 skipped** (214 + 12).
  - [x] 1.3.2 The probe that produced `SIGABRT` now prints
        `RAISED: truncated protobuf varint`; the LEN overrun prints
        `RAISED: protobuf LEN payload runs past the message`.
  - [x] 1.3.3 Byte-identical probe output under `--bounds=off` — the rejection is
        the codec's own, not the runtime's array guard.
  - [x] 1.3.4 Tour extended with a truncated varint (asserting the reported
        offset) and an over-long LEN. Tour: 115 checks, 0 failures; coverage gate
        52/52.
  - [x] 1.3.5 Truncation bullet removed from `docs/protobuf/README.md`; the
        Errors section now states the full rejection set.

## 2. Field-proportional index allocation  (spec 3.1–3.4)  — this repo  ✅ DONE

- [x] **2.1 TDD** — 5 tests added to `ProtobufIndexTest`
  - [x] 2.1.1 `indexMatchesLegacyBoundsAcrossCorpus` — a five-field message
        covering all four wire types; field numbers, wire types, and value bounds
        all unchanged, including LEN payload sitting after its length prefix and
        each field starting where the previous ended.
  - [x] 2.1.2 `indexGrowsBeyondInitialCapacity` — 300 fields (well past the
        initial 8) index completely; first, middle, and last intact after the
        growth, and values still decode at the recorded bounds.
  - [x] 2.1.3 `largeMessageIndexIsProportionalToFieldCount` — two fields wrapping
        a 1000-byte payload keep the index at its initial allocation.
  - [x] 2.1.4 `capacityCoversFieldCount` and `emptyMessageIndexesToNoFields` —
        the invariant and the degenerate case.
- [x] **2.2 Coding**
  - [x] 2.2.1 Growable, not a counting pre-pass: a counting pass would double the
        structural scan, which is the very work unit 6 sets out to vectorize.
        `ProtobufIndex` grows its **own fields** through `ensureCapacity` /
        `append` (initial 8, doubling) — the `AvroWriter` / `ProtobufWriter`
        pattern. Growth is on fields rather than `build`'s locals deliberately:
        every `#=` in this repo is on a field, and a plain store of a fresh array
        into a local leaves it dangling at scope exit.
  - [x] 2.2.2 All existing accessors and the 5-arg constructor unchanged.
  - [x] 2.2.3 **Added public API** (not in the original plan): `capacity()`.
        Spec 3.2 states allocation as a requirement, and a requirement with no
        observable cannot be tested — this is that observable, documented as
        diagnostic.
- [x] **2.3 Acceptance**
  - [x] 2.3.1 Full suite green — **231 passed, 0 failed, 1 skipped** (226 + 5).
  - [x] 2.3.2 Measured, four parallel arrays at 24 B/slot:
        - 2 fields wrapping a 4 KB payload: **96,144 B → 192 B** (501×). This is
          the case the cursor exists for.
        - 200 small fields: 11,352 B → 6,144 B.
  - [x] 2.3.3 Eager-allocation bullet removed from `docs/protobuf/README.md`; the
        index section now states the sizing rule and cites the measurement. Tour
        exercises `capacity()` — 116 checks, 0 failures; coverage gate 52/52.

## 3. Encoding options on `@ProtoField`  (spec 4.1–4.6)  — both repos  ✅ DONE

- [x] **3.1 TDD** — new `ProtobufEncodingTest` (12 tests) + `ProtoEncodingMsg`
  - [x] 3.1.1 `defaultEncodingUnchanged` — byte-for-byte comparison of
        `toBytes<ProtoScalarMsg>` against the same message written by hand with
        the plain writer calls.
  - [x] 3.1.2 `zigzagRoundTripsNegatives`, `zigzagRoundTripsLargeNegative`, and
        `zigzagRoundTripsAcrossRange` (both signed extremes).
  - [x] 3.1.3 `zigzagIsCompactForSmallNegatives` — −1 is 2 bytes zigzag, 11 plain.
  - [x] 3.1.4 `fixedWidthUsesI32AndI64` — wire type and value width read off the
        index.
  - [x] 3.1.5 `fixedWidthRoundTrips`, plus `allEncodingsRoundTripTogether` (4.6)
        and `absentOptionedFieldsKeepDefaults`.
  - [x] 3.1.6 Verified by expected-failure build: zigzag on a `String` field
        emits `CAJETA_ERROR_PROTO_ENCODING` at the field's line/column naming
        class, field, type, and reason — and produces no binary.
  - [x] 3.1.7 **Added** `negativePlainVarintTerminatesAndRoundTrips` and
        `negativeTypedFieldRoundTrips` — regressions for 3.2.6 below.
- [x] **3.2 Coding**
  - [x] 3.2.1 `ProtoField` gained `encoding`, declared **all-named**:
        `@ProtoField(value = 2, encoding = "zigzag")`. Cajeta's annotation
        grammar (`CajetaParser.g4:481`) is `( elementValuePairs | elementValue )`
        — either one unnamed value or a list of pairs, never a mix — so
        `@ProtoField(2, encoding = ...)` does not parse. `@ProtoField(1)` stays
        shorthand for `value = 1`, so the default path is untouched. (this repo)
  - [x] 3.2.2 `ProtobufWire.zigzagEncode` / `zigzagDecode`;
        `ProtobufWriter.writeZigzagField`. (this repo)
  - [x] 3.2.3 `ProtobufCursor.readZigzag`. (this repo)
  - [x] 3.2.4 Synthesizer: `Encoding` option read per field, `Decode` extended
        with `ZigzagVarint` / `Fixed32Int` / `Fixed64Int`, emitted on both arms.
        The parse arm now shares `collectBinds` with the encode arm — they had
        duplicate bind loops that would have drifted the moment one gained the
        option. (toolchain)
  - [x] 3.2.5 `applyEncoding` rejects an option the field's type cannot carry, and
        an unknown option value, via `reportOrThrow` with the field's declared
        line/column. (toolchain)
  - [x] 3.2.6 **Defect found and fixed, not in the original plan.**
        `ProtobufWriter.writeVarint` shifted with `>>`, which cajeta emits as
        `AShr` for *every* type — the `uint64` cast does not make it logical,
        because signedness lives on the operator (`>>>` → `LShr`), not the
        value. For any negative input the sign bit refilled from the left and
        the encode loop **never terminated**. Shipped, and reachable from any
        signed `@ProtoField`; nothing caught it because no test had ever written
        a negative varint. Found when the suite hung at 100% CPU. Same fix
        applied to `zigzagDecode`, which needed the logical shift for `sint64`
        below −2^62. (this repo)
- [x] **3.3 Acceptance**
  - [x] 3.3.1 Full suite green against the rebuilt toolchain (0.17.4 from
        `~/code/cpp/cajeta`) — **243 passed, 0 failed, 1 skipped** (231 + 12).
  - [x] 3.3.2 Existing messages byte-identical — 3.1.1 compares bytes, it does
        not assume.
  - [x] 3.3.3 Tour gained an `encoding` section printing the measured payoff
        (`-3 as sint64 = 2 bytes, as int64 = 11 bytes`) — 119 checks, 0 failures;
        coverage gate 52/52. Zigzag/fixed-width bullet removed from the docs and
        an encoding-choice table added.

### Note — a cajeta shift rule worth carrying forward

`>>` is arithmetic on **every** cajeta type; `>>>` is the only logical shift.
Casting to `uint64` changes nothing, because the operation carries the
signedness rather than the operand. Two consequences seen here: a varint encode
loop that never terminates, and a zigzag decode that mis-reads its top-bit
cases. `AvroWriter` and `ThriftCompactWriter` already work around this by
masking after the shift; `IonWriter` does not. Recorded in spec §1.5.3.

## 4. Float fields, and fail-loud on unbindable types  (spec 5.1–5.6, 1.6.2)  — both repos

- [ ] **4.1 TDD**
  - [ ] 4.1.1 `float64RoundTrips` — a `float64 @ProtoField` survives
        `toBytes<T>` → `parse<T>`. Regression for the confirmed silent drop.
  - [ ] 4.1.2 `float32RoundTrips` — same at single precision, wire type I32.
  - [ ] 4.1.3 `floatWireTypeIsFixed` — verified through `ProtobufIndex`: wire
        type 1 for `float64`, 5 for `float32`.
  - [ ] 4.1.4 `floatSpecialValuesSurvive` — negative zero, +∞, −∞, and NaN keep
        their bit patterns.
  - [ ] 4.1.5 `absentFloatKeepsConstructorDefault`.
  - [ ] 4.1.6 An unbindable field type fails compilation naming class, field, and
        type — expected-failure build.
- [ ] **4.2 Coding**
  - [ ] 4.2.1 Establish the float-bits seam the synthesizer comment says is
        missing: `float64` ↔ `int64` and `float32` ↔ `int32` reinterpretation.
        Confirm whether the toolchain already offers one before adding it.
  - [ ] 4.2.2 Synthesizer: classify `float32` → I32 and `float64` → I64 rather
        than `Unsupported`. (toolchain)
  - [ ] 4.2.3 Synthesizer: replace both `if (d == Unsupported) continue;` sites
        (`:94`, `:224`) with a diagnostic. This is the actual fix for the silent
        drop — float support alone would leave the next unbindable type silent.
        (toolchain)
  - [ ] 4.2.4 `ProtobufWriter` / `ProtobufCursor` float field helpers if the
        bit-level path needs them. (this repo)
- [ ] **4.3 Acceptance**
  - [ ] 4.3.1 Full suite green against the rebuilt toolchain.
  - [ ] 4.3.2 The probe that encoded a two-field float message to 2 bytes now
        encodes both fields.
  - [ ] 4.3.3 No existing message changes on the wire.
  - [ ] 4.3.4 Tour covers a float field; the float bullet leaves the docs.

## 5. Repeated and packed fields  (spec 6.1–6.8, UC-PB-3)  — both repos

- [ ] **5.1 TDD**
  - [ ] 5.1.1 `repeatedScalarBindsInWireOrder` — successive occurrences of one
        field number bind into an array in order.
  - [ ] 5.1.2 `repeatedMessageBinds` — repeated nested messages bind to an array.
  - [ ] 5.1.3 `absentRepeatedIsEmptyNotNull`.
  - [ ] 5.1.4 `packedWriteProducesSingleLenRecord` — verified through the index:
        one record, wire type 2.
  - [ ] 5.1.5 `packedReadDecodesAllElements`.
  - [ ] 5.1.6 `unpackedWireFormDecodesIdentically` — the same field sent unpacked
        yields the same array. Conformance: readers must accept both.
  - [ ] 5.1.7 `packedPayloadNotDivisibleRaises` — a fixed-width packed payload
        that does not divide evenly is rejected.
  - [ ] 5.1.8 `packedRespectsElementEncoding` — packed zigzag and packed
        fixed-width elements round-trip under unit 3's options.
- [ ] **5.2 Coding**
  - [ ] 5.2.1 `ProtoField` packed option. (this repo)
  - [ ] 5.2.2 `ProtobufWriter`: packed repeated field emit. (this repo)
  - [ ] 5.2.3 `ProtobufCursor`: walk repeated slots, and decode a packed payload
        into elements. (this repo)
  - [ ] 5.2.4 Synthesizer: classify array-typed fields (other than `int8[]`, which
        stays `bytes`) as repeated, and emit both arms. (toolchain)
  - [ ] 5.2.5 Synthesizer: honor the packed option on write; accept either form on
        read. (toolchain)
- [ ] **5.3 Acceptance**
  - [ ] 5.3.1 Full suite green.
  - [ ] 5.3.2 UC-PB-3 satisfied — packed repeated numeric fields decode.
  - [ ] 5.3.3 `int8[]` still means `bytes`, not a repeated `int8` — verified.
  - [ ] 5.3.4 Tour covers a repeated and a packed field; both bullets leave the
        docs.

## 6. SIMD structural scan  (spec 7.1–7.5, framework §8.2)  — this repo

- [ ] **6.1 TDD**
  - [ ] 6.1.1 `simdIndexMatchesScalarAcrossCorpus` — over a corpus spanning field
        counts, wire types, and varint widths, the SIMD index equals the scalar
        index field-for-field. The scalar path is the oracle.
  - [ ] 6.1.2 `simdRejectsMalformedIdentically` — every unit-1 rejection case
        raises the same exception at the same position through the SIMD path.
  - [ ] 6.1.3 `scalarFallbackProducesSameIndex` — targets without SIMD agree.
  - [ ] 6.1.4 Boundary cases: a message shorter than one vector, and one whose
        length is an exact vector multiple.
- [ ] **6.2 Coding**
  - [ ] 6.2.1 Vectorized varint/tag boundary scan for stage 1, following the
        Deflate/BitPack SIMD precedent already in this repo.
  - [ ] 6.2.2 Runtime or compile-time selection with the scalar path retained as
        fallback and reference.
  - [ ] 6.2.3 Bench under `bench/`, comparing SIMD to scalar over a large message.
- [ ] **6.3 Acceptance**
  - [ ] 6.3.1 Full suite green on both paths.
  - [ ] 6.3.2 Bench recorded showing a measured speed-up.
  - [ ] 6.3.3 Vectorization opens no hole that unit 1 closed — 6.1.2 is the gate.
  - [ ] 6.3.4 The scalar-scan bullet leaves the docs; framework §8.2's SIMD
        designation is satisfied.
