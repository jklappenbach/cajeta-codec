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
| `String`, `int8[]` | LEN (2) |
| a nested message class | LEN (2), decoded by recursion |

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

- **`float32` / `float64` fields are silently dropped** by the typed facade —
  they neither encode nor decode, and no diagnostic is issued. Carry floats as
  their IEEE-754 bits in an integer field for now, or write them through
  `ProtobufWriter.writeFixed32Field` / `writeFixed64Field` directly.
- **Repeated fields inside a message are not bound** by the typed facade (only
  `int8[]`, which is `bytes`). Walk them through the cursor's successive slots.
- **Packed repeated encoding** is neither produced nor consumed.
- **`sint32`/`sint64` zigzag** and **`fixed`-width integer** encodings have no
  opt-in on `@ProtoField`; integers always use plain VARINT.
- **The structural scan is scalar.** The SIMD varint/tag boundary scan the
  framework spec calls for is not implemented.
- **`.proto` schema import** is a separate tooling track and does not exist.
