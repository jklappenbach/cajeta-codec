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

## 4. Float fields, and fail-loud on unbindable types  (spec 5.1–5.6, 1.6.2)  — both repos  ✅ DONE

- [x] **4.1 TDD** — new `ProtobufFloatTest` (9 tests) + `ProtoFloatMsg`
  - [x] 4.1.1 `float64RoundTrips` — regression for the confirmed silent drop.
  - [x] 4.1.2 `float32RoundTrips` at single precision.
  - [x] 4.1.3 `floatWireTypeIsFixed` — wire type and value width read off the
        index: I64/8 bytes for `float64`, I32/4 for `float32`.
  - [x] 4.1.4 `negativeZeroSurvives`, `infinitiesSurvive`, `nanSurvives` — all
        assert on **bits**, since `-0.0 == 0.0` and `NaN != NaN` make value
        comparison blind to exactly what is being tested.
  - [x] 4.1.5 `absentFloatKeepsConstructorDefault`.
  - [x] 4.1.6 Verified by expected-failure build: a `boolean[]` field emits
        `CAJETA_ERROR_PROTO_FIELD_TYPE` at the field's line/column, listing the
        supported types, and produces no binary.
  - [x] 4.1.7 **Added** `floatBitsSeamRoundTrips` (the seam itself, asserting
        `toBits(19.5) != 19` — the exact distinction the old conversion missed)
        and `floatsCoexistWithOtherFields`.
- [x] **4.2 Coding**
  - [x] 4.2.1 ~~**No seam existed** — confirmed, not assumed.~~ **This claim was
        wrong.** `Cajeta.f64ToBits` / `bitsToF64` / `f32ToBits` / `bitsToF32`
        already existed as compiler intrinsics. The search that produced the
        claim covered the stdlib wrapper classes (`Float64.asInt64` is a numeric
        conversion; `__cajeta_hash_float64` is lossy by design) and the runtime
        C, but never the `Cajeta.*` intrinsic namespace — so "confirmed, not
        assumed" was asserted on an incomplete search. Found in unit 6 while
        enumerating `Cajeta.*` for SIMD intrinsics.
        **Corrected in 4.4:** the duplicate wrappers and their four `@Native` C
        functions are removed and the synthesizer emits the intrinsics, which
        lower to a bitcast rather than a call. (toolchain)
  - [x] 4.2.2 Synthesizer: `Float32Bits` / `Float64Bits` decode kinds, emitted on
        both arms. (toolchain)
  - [x] 4.2.3 Both `if (d == Unsupported) continue;` sites replaced by one
        `reportOrThrow` in the now-shared `collectBinds`. Unifying the two loops
        in unit 3 meant this fix landed once instead of twice. (toolchain)
  - [x] 4.2.4 Not needed — `writeFixed32Field`/`writeFixed64Field` and
        `readFixed32`/`readFixed64` already carried the fixed-width path; floats
        are those plus the bit reinterpretation.
- [x] **4.3 Acceptance**
  - [x] 4.3.1 Full suite green — **252 passed, 0 failed, 1 skipped** (243 + 9).
  - [x] 4.3.2 The probe that encoded a two-field float message to 2 bytes now
        reports `encoded 11 bytes` and `price PRESERVED = 19.5`.
  - [x] 4.3.3 No existing message changes on the wire — `defaultEncodingUnchanged`
        (byte comparison, unit 3) still passes.
  - [x] 4.3.4 Tour gained a `float64` field asserting both the round-trip and the
        eight-byte I64 encoding — 121 checks, 0 failures; coverage gate 52/52.
        Float bullet removed from the docs and floats added to the wire-type
        table.

### 4.4 Correction — use the existing intrinsics, drop the duplicate seam

- [x] 4.4.1 `ProtobufSynthesizer` emits `Cajeta.f64ToBits` / `bitsToF64` /
      `f32ToBits` / `bitsToF32` instead of the `Float*.toBits` wrappers.
- [x] 4.4.2 `Float64.toBits`/`fromBits`, `Float32.toBits`/`fromBits`, and the
      four `__cajeta_f*_bits` functions in `runtime/native/cajeta_rt_lang.c` are
      removed. They were a second way to do something the language already did,
      and the worse way: an intrinsic lowers to a bitcast, a `@Native` binding
      lowers to a call.
- [x] 4.4.3 `ProtobufFloatTest` pins the intrinsics directly, with a note on the
      file recording why the wrappers existed and went.
- [x] 4.4.4 Lesson for the remaining work: "no facility exists" is only true
      after searching the **intrinsic** namespace as well as the stdlib classes.
      `Cajeta.*` holds `ctz64`, `popcount64`, `vload16`, the float-bits pair, and
      more — none of it discoverable from the `runtime/src` tree.

## 5. Repeated and packed fields  (spec 6.1–6.8, UC-PB-3)  — both repos  ✅ DONE

- [x] **5.1 TDD** — new `ProtobufRepeatedTest` (16 tests) + `ProtoRepeatedMsg`
  - [x] 5.1.1 `repeatedScalarBindsInWireOrder`, plus
        `unpackedRepeatedWritesOneRecordPerElement` checking the wire shape.
  - [x] 5.1.2 `repeatedMessageBinds`, and `repeatedStringBinds` for LEN elements.
  - [x] 5.1.3 `absentRepeatedIsEmptyNotNull` across all four repeated shapes.
  - [x] 5.1.4 `packedWriteProducesSingleLenRecord` — one record, wire type 2,
        payload width checked off the index.
  - [x] 5.1.5 `packedReadDecodesAllElements`, including multi-byte varints.
  - [x] 5.1.6 `unpackedWireFormDecodesIdentically` **and** the mirror,
        `packedWireFormDecodesForUnpackedDeclaration` — conformance runs both
        ways. Plus `mixedPackedAndUnpackedConcatenate`, since one message may
        legitimately carry both forms of the same field number.
  - [x] 5.1.7 `packedPayloadNotDivisibleRaises` through the typed facade and
        `cursorRejectsRaggedPackedFixed32` straight off the cursor.
  - [x] 5.1.8 `packedZigzagRoundTrips` (asserting the payload really is one byte
        per element) and `packedFixed32RoundTrips` (four bytes per element).
  - [x] 5.1.9 **Added** `bytesFieldIsStillBytes` (5.3.3 as a test, not an
        inspection) and `allRepeatedShapesRoundTripTogether`.
  - [x] 5.1.10 **Added** `truncatedDelimitedStreamRaises` and
        `intactDelimitedStreamStillParses` in `ProtobufBoundsTest` — see 5.2.6.
- [x] **5.2 Coding**
  - [x] 5.2.1 `ProtoField` gained `packed`. (this repo)
  - [x] 5.2.2 `ProtobufWriter`: `writePackedVarintField`, `writePackedZigzagField`,
        `writePackedFixed32Field`, `writePackedFixed64Field`. Each encodes into a
        scratch writer first, since the length prefix is unknown until the
        payload exists. (this repo)
  - [x] 5.2.3 `ProtobufCursor`: `readRepeatedVarint` / `Zigzag` / `Fixed32` /
        `Fixed64`, plus `repeatedCount` and `slotOfNth` for LEN elements. The
        readers accept **either** wire form and concatenate across records, so a
        mixed message decodes correctly. `countFixedElements` enforces the
        whole-element rule. (this repo)
  - [x] 5.2.4 Synthesizer: `Bind` gained `repeated` / `packed`, `classify` split
        so a repeated field's **element** reuses the scalar classifier — a
        repeated int64 therefore encodes each element exactly as a scalar int64
        does, by construction rather than by a parallel code path. `int8[]`
        stays `bytes`. (toolchain)
  - [x] 5.2.5 `emitRepeatedParse` / `emitRepeatedEncode` cover all seven element
        kinds × packed/unpacked. Repeated decode is emitted **outside** the slot
        guard, because absent must yield empty rather than skip. (toolchain)
  - [x] 5.2.6 **Defect found and fixed, not in the original plan.** The
        synthesized `parse<T[]>` stream body read its frame lengths with the
        unbounded `decodeVarint(bytes, p)` and never checked that a frame fit,
        then allocated `heap int8[fln]` from a length it had already overrun. A
        journal truncated by a closed socket walked past the buffer. Unit 1
        hardened `ProtobufIndex`, but this framing lives in the synthesizer, so
        it was untouched. Now bounded by `length` with an explicit fit check.
        Recorded as spec 2.10. (toolchain)
- [x] **5.3 Acceptance**
  - [x] 5.3.1 Full suite green — **268 passed, 0 failed, 1 skipped** (252 + 16),
        before the two stream-truncation tests were added.
  - [x] 5.3.2 UC-PB-3 satisfied — packed repeated numeric fields decode, in both
        wire forms and under every element encoding.
  - [x] 5.3.3 `int8[]` still means `bytes` — one LEN record of three bytes, not
        three records, asserted off the index.
  - [x] 5.3.4 Tour gained a repeated/packed section printing the record-count
        contrast. Both bullets removed from the docs, replaced by a repeated
        section covering the packing rules.
- [x] **5.4 Follow-up — packed is the default** (spec 6.5, revised)
  - [x] 5.4.1 Shipped opt-in per the spec as approved, then flagged the
        divergence: proto3 and edition 2023 both default repeated numeric
        fields to packed; only proto2 defaulted to expanded. Reversed on
        Glenn's call.
  - [x] 5.4.2 `packed` is now tri-state in the synthesizer, read through
        `findArg` so unset is distinguishable from an explicit `false`. Unset on
        a repeated numeric field means packed; `packed = false` forces expanded.
        Non-numeric elements are never packed whatever is declared.
  - [x] 5.4.3 `ProtoRepeatedMsg` reshaped so all three states are covered by
        tests rather than by inspection: field 2 `packed = false`, field 3
        defaulted, field 5 explicit `packed = true`. New
        `defaultIsPackedForRepeatedNumeric` pins the default;
        `packedFalseStaysExpanded` pins the opt-out.
  - [x] 5.4.4 Timing was the argument for doing it now rather than later:
        repeated fields had existed for under a day, so nothing depended on the
        byte layout. Once a message class exists in a user's tree, flipping the
        default silently changes their wire output.

## 6. SIMD over packed payloads  (spec 7.1–7.7, framework §8.2)  — this repo  ✅ DONE

**Scope changed before implementation.** The unit was written to vectorize the
stage-1 tag/varint boundary scan. That is not achievable: protobuf's TLV framing
makes "where does the next field begin" a serial dependency with no context-free
byte to compare against, unlike JSON's braces or CSV's commas. Spec §7 was
rewritten to withdraw the requirement and record why, and the unit re-aimed at
framework §8.2's *second* SIMD clause — bulk packed-repeated primitive fields —
which is real, vectorizable, and the one that serves UC-PB-3.

- [x] **6.1 TDD** — 4 tests added to `ProtobufRepeatedTest`
  - [x] 6.1.1 `packedCountMatchesAcrossVectorBoundaries` — element counts swept
        1..40 with single-byte varints, so payloads shorter than one 16-byte
        block, exactly one block, and block+tail are all covered.
  - [x] 6.1.2 `packedCountMatchesForMultiByteVarints` — three-byte varints, so
        block boundaries fall mid-element and the popcount has to handle
        terminators that do not align with blocks.
  - [x] 6.1.3 `truncatedPackedVarintStillRaises` and
        `overlongPackedVarintStillRaises` — spec 7.4, the gate that
        vectorization opened no hole.
  - [x] 6.1.4 Scalar/SIMD agreement is also asserted *inside the bench*: both
        paths run over the same bytes and their totals are compared, so a
        divergence fails loudly rather than flattering the new path.
- [x] **6.2 Coding**
  - [x] 6.2.1 `ProtobufCursor.countPackedVarints` — every varint ends in exactly
        one byte with the continuation bit clear, so the element count is a
        popcount of that mask per 16-byte block. `Vector` has no `splat`, so the
        0x80 comparand is a constant array through `Cajeta.vload16`; `and` +
        `eqMask` gives the continuation mask.
  - [x] 6.2.2 Scalar tail for the final <16 bytes; the scalar walk survives in
        the bench as the reference implementation.
  - [x] 6.2.3 `bench/src/dev/cajeta/codec/bench/PackedScanBench.cajeta` +
        `bench/README.md` section.
  - [x] 6.2.4 **Defect caught by the suite, and a corrected assumption.** The
        first cut left counting permissive on the theory that the decode pass
        would reject malformed input "before storing anything". It does not: on
        a truncated payload the count returns one element fewer than the walk
        produces, and the **array bounds check on `out[w]` fires before** the
        `decodeVarint` call that would have raised — `array index 16 out of
        bounds for dimension size 16`. The real invariant is stricter: count and
        walk must agree on element count for every input either accepts, because
        the count sizes the array the walk fills. Truncation is now rejected in
        the count, walking back to the incomplete varint's start so the reported
        position still matches the scalar path. An overlong varint needs no such
        check — it carries exactly one terminator, so the count stays right and
        the decode pass raises.
- [x] **6.3 Acceptance**
  - [x] 6.3.1 Full suite green — **275 passed, 0 failed, 1 skipped** (271 + 4).
  - [x] 6.3.2 Bench recorded (`--opt=O3`), count only:
        64 KiB / 1-byte varints **44 → 3126 MB/s**; 192 KiB / 3-byte
        **102 → 2251**; 320 KiB / 5-byte **128 → 2501**; 16 B **39 → 160**.
        Reported with the caveat that the scalar path paid a non-inlined
        `varintLen` call per element which the block loop amortizes, so this is
        the gain on this code path rather than a pure instruction-count ratio.
  - [x] 6.3.3 No hole opened — 6.1.3 is the gate and both cases raise.
  - [x] 6.3.4 Docs bullet replaced with a section explaining why the field walk
        is serial and what vectorizes instead, carrying the measured table.
        Framework §8.2's first SIMD clause is withdrawn with reasons in spec §7.1
        rather than left looking unmet.
