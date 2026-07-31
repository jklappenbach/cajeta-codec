# dev.cajeta.codec tour

Runnable, self-checking usage examples — one demo per codec surface. Each demo
walks a codec's public API with worked, realistic examples and **verifies its
own output**, so the tour doubles as a smoke test: a nonzero exit means a
`check()` failed.

```sh
CAJETA=/path/to/cajeta ./samples/tour/run-tour.sh
```

`run-tour.sh` builds the codec into a `.cja`, then builds the tour as an
executable with the codec on the classpath (the same recipe as `run-tests.sh`)
and runs it. The native zlib backend is linked in, so the compression demos
exercise the real fast path.

## What it covers

In tour order — the sequence is a learning path (compression → block codecs →
record formats → columnar encodings → columnar file formats):

| Demo | Surface | Package |
|------|---------|---------|
| `CompressDemo` | DEFLATE / gzip / zlib one-shot: round-trips, the destLen hint self-correcting, the level knob's real contract, native↔fallback interop, checksums, malformed-input handling | `dev.cajeta.codec.compress` |
| `StreamingCompressDemo` | `DeflateStream`/`InflateStream`: syncFlush segments, context takeover, chunked feed/drain, truncation at `endInput()`, `NativeZlib` direct | `dev.cajeta.codec.compress` |
| `SnappyDemo` | Snappy block codec on a columnar page (self-describing framing) | `dev.cajeta.codec.compress` |
| `Lz4Demo` | LZ4 block format as a container uses it: `(size, block)` pairs | `dev.cajeta.codec.compress` |
| `ProtobufDemo` | `@ProtoField` typed round-trips, delimited streams, manual writer, cursor projection, index + wire, `ProtobufParseException` | `dev.cajeta.codec.protobuf` |
| `IonDemo` | Name-bound typed round-trips, manual writer with symbol interning, cursor, symbol tables, index, `IonParseException` | `dev.cajeta.codec.ion` |
| `AvroDemo` | Positional typed round-trips, zigzag, manual writer/cursor, the Object Container File (block iteration, per-block codecs), `AvroParseException` | `dev.cajeta.codec.avro` |
| `ColumnarDemo` | The page-encoding toolkit: BitPack, RLE, Delta, FrameOfReference, Dictionary, parallel `ColumnOrchestrator` | `dev.cajeta.codec.columnar` |
| `ParquetDemo` | Write a column, read footer/column-info/values/validity, the pushdown contract, Thrift compact, `ParquetParseException` | `dev.cajeta.codec.parquet` |
| `OrcDemo` | Write a column, metadata, stats pushdown on a real pyarrow file, name-based projection, chunk decompression, RLEv2, `OrcParseException` | `dev.cajeta.codec.orc` |

Coverage is enforced: `scripts/check-library-tour-coverage.sh src/main/cajeta
samples/tour scripts/tour-coverage-ignore.txt` requires every public top-level
type to be exercised by the tour (the ignore file exempts genuine internals,
each with a stated reason) and runs in CI alongside the tour itself.

## Adding a demo

1. Write `NewDemo.cajeta` in `src/main/cajeta/codectour/` extending `DemoClass`,
   overriding `execute()` — print worked examples and assert each with
   `this.check(cond, "what")`.
2. Add one registration block to `CodecTour.main`:
   ```cajeta
   NewDemo d = heap NewDemo();
   d.execute();
   ```

`DemoClass` supplies the shared `check()` (counts failures) and a `sameBytes()`
buffer-compare helper.
