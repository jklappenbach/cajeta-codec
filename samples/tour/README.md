# dev.cajeta.codec tour

Runnable, self-checking usage examples — one demo per codec. Each demo walks a
codec's public API with worked examples and **verifies its own output**, so the
tour doubles as a smoke test: a nonzero exit means a `check()` failed.

```sh
CAJETA=/path/to/cajeta ./samples/tour/run-tour.sh
```

`run-tour.sh` builds the codec into a `.cja`, then builds the tour as an
executable with the codec on the classpath (the same recipe as `run-tests.sh`)
and runs it. The native zlib backend is linked in, so the compression demos
exercise the real fast path.

## What it covers

| Demo | Codec | Package |
|------|-------|---------|
| `CompressDemo` | DEFLATE / gzip / zlib — round-trips, the level knob, native↔fallback interop, checksums, malformed-input handling | `dev.cajeta.codec.compress` |
| `SnappyDemo`   | Snappy (self-describing block codec) | `dev.cajeta.codec.compress` |
| `Lz4Demo`      | LZ4 block format (destLen-supplied) | `dev.cajeta.codec.compress` |

The structured formats (`protobuf`, `ion`, `avro`, `parquet`, `orc`) and the
columnar tier are demoed by their test suites today (`src/test/.../selftest`);
tour demos for them are the natural next additions.

## Adding a demo

1. Write `NewDemo.cajeta` in `src/main/cajeta/codectour/` extending `DemoClass`,
   overriding `execute()` — print worked examples and assert each with
   `this.check(cond, "what")`.
2. Add one line to `CodecTour.main`:
   ```cajeta
   NewDemo d = heap NewDemo();
   d.execute();
   ```

`DemoClass` supplies the shared `check()` (counts failures) and a `sameBytes()`
buffer-compare helper.
