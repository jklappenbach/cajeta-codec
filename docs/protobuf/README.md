# Protocol Buffers — `dev.cajeta.codec.protobuf`

Reader and writer for the Protocol Buffers wire format, built on the library's
**staged-access convention**: the type in your hand names the pipeline stage,
and its methods are the only legal next steps. Pick the shallowest stage that
answers your question.

| Stage | Type | What it gives you |
|---|---|---|
| Typed | `Protobuf.parse<T>` / `toBytes<T>` | whole-message bind to an annotated class |
| Cursor | `ProtobufCursor` | lazy projection — decode only the fields you touch |
| Index | `ProtobufIndex` | field map: `(number, wire type, byte span)`, values undecoded |
| Wire | `ProtobufWire` | raw vocabulary — tags and varints |
| Encode | `ProtobufWriter` | append tag-length-value records to a growable buffer |

A runnable version of everything below is
[`samples/tour/src/main/cajeta/codectour/ProtobufDemo.cajeta`](../../samples/tour/src/main/cajeta/codectour/ProtobufDemo.cajeta).

## Typed messages

Annotate fields with `@ProtoField(N)`, where `N` is the protobuf field number.
Field numbers are part of the wire contract — sparse, non-sequential, stable
across schema versions — so they are declared explicitly rather than inferred
from declaration order. A field without `@ProtoField` is not bound.

```cajeta
public class OrderEvent {
    @ProtoField(1) public int64   orderId;
    @ProtoField(2) public String  symbol;
    @ProtoField(3) public boolean buy;
    @ProtoField(4) public int32   quantity;

    public OrderEvent() {
        this.orderId = (int64) 0;
        this.symbol = null;
        this.buy = false;
        this.quantity = 0;
    }
}

int8[] wire = Protobuf.toBytes<OrderEvent>(e);
OrderEvent back = Protobuf.parse<OrderEvent>(wire, (int64) wire.count());
```

The no-arg constructor sets the defaults a parse keeps when a field is **absent**
from the wire — protobuf has no "null" for scalars, so absence means "whatever
the constructor set". This is how forward compatibility works: a peer that does
not know field 4 simply leaves your default in place.

`parse<T>` and `toBytes<T>` bodies are **synthesized per-`T` at the call site**
by the toolchain, not written by hand. The library-side methods are failsafes
that raise `ProtobufParseException` if the synthesizer does not engage, so a
missing synthesizer surfaces as a throw rather than a zeroed result.

### Wire types inferred from the Cajeta type

| Cajeta type | Wire type |
|---|---|
| `int8`/`int16`/`int32`/`int64`, `uint*` | VARINT (0) |
| `boolean` | VARINT (0) |
| `float32` (protobuf `float`) | I32 (5), raw IEEE-754 bits |
| `float64` (protobuf `double`) | I64 (1), raw IEEE-754 bits |
| `String`, `int8[]` | LEN (2) |
| a nested message class | LEN (2), decoded by recursion |

Floats carry their **bit pattern**, not a numeric conversion, so `-0.0` keeps
its sign and NaN keeps its payload across a round-trip. A field type with no
protobuf mapping is a compile error naming the class, field, and type — never a
field quietly missing from the wire.

### Choosing an integer encoding

Integers default to plain VARINT. That is the wrong choice for values that are
often negative: protobuf sign-extends a negative to the full ten bytes, so `-1`
costs as much as a number in the quintillions. The `encoding` option picks an
alternative:

| `encoding` | Protobuf type | Wire type | Use when |
|---|---|---|---|
| *(absent)* | `int32` / `int64` | VARINT | values are usually small and non-negative |
| `"zigzag"` | `sint32` / `sint64` | VARINT | values are often negative — `-1` costs one byte |
| `"fixed"` | `fixed32` / `fixed64` | I32 / I64 | values are large or uniformly distributed |

```cajeta
public class Reading {
    @ProtoField(1)                              public int64 id;
    @ProtoField(value = 2, encoding = "zigzag") public int64 delta;
    @ProtoField(value = 3, encoding = "fixed")  public int32 epochSecs;
}
```

**Declare the option in the all-named form.** Cajeta's annotation grammar takes
either one unnamed value or a list of `key = value` pairs, never a mix, so
`@ProtoField(2, encoding = "zigzag")` does not parse. `@ProtoField(1)` remains
shorthand for `@ProtoField(value = 1)`, so fields that declare no option are
untouched — and encode byte-for-byte as they did before the option existed.

An option the field's type cannot carry — zigzag on a `String` — fails
compilation naming the class, field, and conflict. It is never ignored, because
a silently wrong encoding surfaces as garbage at the far end of the wire.

Zigzag rides on wire type VARINT, so nothing on the wire marks it. Both peers
must agree on the field's declared type, exactly as they must for `sint64` in a
`.proto` file.

### Repeated fields

An array field is a repeated field. `int8[]` is the one exception — it means
protobuf `bytes`, a single LEN record, not a repeated `int8`.

```cajeta
@ProtoField(2)                         public int64[] scores;   // packed
@ProtoField(value = 3, packed = false) public int32[] counts;   // expanded
@ProtoField(6)                         public String[] tags;
@ProtoField(7)                         public Reading[] items;
```

**Repeated numeric fields are packed by default** — one LEN record holding the
values concatenated with no tags, instead of one tagged record per value. That
is roughly a byte per element rather than two for a run of small numbers, and it
matches proto3 and edition 2023 (`features.repeated_field_encoding = PACKED`);
only proto2 defaulted to expanded.

`packed = false` opts back out. Packing applies only to repeated numeric fields
— strings, bytes, and messages carry their own length and have no packed form,
so they are never packed and asking for it is a compile error, as is asking on a
non-repeated field. It composes with `encoding`, so packed zigzag and packed
fixed-width both work.

**Reading accepts either wire form**, whatever the field declares, and copes
with a message that mixes them — values concatenate in wire order. This is
required of conforming parsers, which is what makes the default safe to rely on:
a peer that sends the expanded form still reads correctly here, and vice versa.
The declaration only chooses what this side writes.

A repeated field is never null after a parse. Protobuf cannot distinguish an
absent repeated field from an empty one, so absent decodes to an empty array.

### Streams of messages

`T[]` reads and writes the de-facto **delimited** framing — each message
prefixed by its varint length, the shape used for journal and log files.

```cajeta
int8[] journal = Protobuf.toBytes<OrderEvent[]>(batch);
OrderEvent[] replay = Protobuf.parse<OrderEvent[]>(journal, (int64) journal.count());
```

## Projection with the cursor

When you need two fields of a large message, do not bind the whole thing. The
cursor indexes structure once, then decodes only what you ask for; skipping is
pure offset arithmetic over the index.

```cajeta
ProtobufCursor cur = heap ProtobufCursor(wire, (int64) wire.count());
int32 slot = cur.slotOf(4);            // -1 if the field is absent
int64 qty  = cur.readVarint(slot);     // field 2's bytes are never touched
```

`slotOf` returns the **first** occurrence of a field number; repeated fields are
walked through their successive index slots. `has(n)` probes presence. Decode by
wire type: `readVarint`, `readBytes` (LEN payload), `readFixed32`, `readFixed64`
(little-endian).

## Index and wire primitives

`ProtobufIndex.build(bytes, n)` records, per top-level field in wire order, its
number, wire type, and value bounds `[valueStart, valueEnd)` — without decoding a
single value. `ProtobufWire` then decodes exactly the span you name.

```cajeta
ProtobufIndex idx = ProtobufIndex.build(wire, (int64) wire.count());
int64 v = ProtobufWire.decodeVarint(wire, idx.valueStart(0));
```

Value bounds by wire type: VARINT → the varint bytes; I64 → 8 bytes; I32 → 4
bytes; LEN → the payload *after* its length prefix.

The index allocates by **field count, not message length** — `capacity()`
reports its slots. Two fields wrapping a 4 KB payload cost 192 bytes of index,
not 96 KB, so projecting a couple of fields out of a large message stays cheap.

## Errors

Malformed input raises `ProtobufParseException`, carrying the byte `position`
where the problem was noticed — never a crash, and never a silent partial read.
Rejected: a truncated record (a varint, I32, I64, or LEN payload needing bytes
past the length you passed), an overlong varint, field number 0, a declared
length longer than the buffer, deprecated group wire types (3, 4), and unknown
wire types (6, 7).

Every record an index accepts fits entirely within `[0, n)`, so spans it hands
back can be read without a further bound check of your own. This holds under
`--bounds=off` as well — the rejection is the codec's own, not the runtime's
array guard.

## Current limitations

These are known gaps, tracked in
[`specs/protobuf-spec.md`](../../specs/protobuf-spec.md) and
[`agents/protobuf-plan.md`](../../agents/protobuf-plan.md):

- **The field walk is scalar, and stays that way.** See below — this is a
  property of the format, not a missing optimization.
- **`.proto` schema import** is a separate tooling track and does not exist.

## Why the field walk is not vectorized

JSON and CSV vectorize their structural scans because their structural bytes are
context-free: `{`, `,` and `"` are identifiable by value alone, so comparing 16
bytes at once tells you something true. Protobuf is tag-length-value. Whether
byte *k* begins a tag depends on having decoded every field before it, and no
byte value marks a boundary — `0x08` is as likely to be payload as a tag. The
walk is a genuine serial dependency chain, which is why simdjson exists and
nothing equivalent does for protobuf. Speculating and validating buys nothing,
because the validation *is* the walk.

What does vectorize is a **packed repeated payload** — a context-free run of
varints whose element boundaries are the bytes with the continuation bit clear.
Counting them is a compare-and-popcount over 16 bytes at a time instead of a
walk per element, which is what `ProtobufCursor` does. Measured on this machine
(`bench/`, `--opt=O3`, count only — decoding values remains a serial pass):

| payload | elements | scalar | vectorized |
|---|---|---|---|
| 64 KiB, 1-byte varints | 65536 | 44 MB/s | **3126 MB/s** |
| 192 KiB, 3-byte varints | 65536 | 102 MB/s | **2251 MB/s** |
| 320 KiB, 5-byte varints | 65536 | 128 MB/s | **2501 MB/s** |
| 16 B, 1-byte varints | 16 | 39 MB/s | **160 MB/s** |

Part of that ratio is that the scalar path paid a non-inlined call per varint,
which the block loop amortizes over 16 bytes — so read it as the improvement to
this code path rather than as a pure instruction-level speedup.
