# compress benchmark

Throughput micro-benchmark for the DEFLATE/INFLATE hot paths. Self-contained
(generates a realistic text-like payload in code) and correctness-checked
(each decode is verified byte-exact).

```sh
CJ=/path/to/cajeta          # a toolchain that builds the codec
CODEC=/tmp/codec.cja
"$CJ" --emit=cja -o "$CODEC" '*' src/main/cajeta /tmp/codecbuild
"$CJ" dev.cajeta.codec.bench.CompressBench::main bench/src /tmp/cbench \
    --emit=exe --opt=O3 --classpath="$CODEC" -o /tmp/compress-bench
/tmp/compress-bench
```

Measures, for a 128 KiB payload:
- **COMPRESS** — `DeflateStream` (the permessage-deflate send/echo path, pure
  cajeta — streaming is not routed to the native backend).
- **NATIVE COMPRESS Lx** — `Deflate.deflate` → native zlib (the gzip/zlib/
  content-coding one-shot path).
- **INFLATE stream** — `InflateStream` (the permessage-deflate receive path).
- **NATIVE INFLATE one-shot** — `Deflate.inflate` → native zlib.

Build **`--opt=O3`** — at `-O0` (debug) the numbers are lower and unrepresentative.

## Native vs raw zlib (Unit 6 perf gate)

`run-native-vs-zlib.sh` builds the codec with the native archive linked, runs
`CompressBench`, then builds + runs the C raw-zlib reference (`zlib_ref.c`, the
byte-identical payload through zlib's one-shot raw-DEFLATE at levels 1/6/9). The
gate: **native ≥ 0.8× raw zlib MB/s** on the same machine.

```sh
CAJETA=/path/to/cajeta ./bench/run-native-vs-zlib.sh
```

### Result — dev host (`x86_64-linux-gnu`, `--opt=O3`, 128 KiB, 200 iters)

| path        | native (codec) | raw zlib | ratio | gate |
|-------------|---------------:|---------:|------:|:----:|
| COMPRESS L1 |     187 MB/s   | 197 MB/s | 0.95× |  ✅  |
| COMPRESS L6 |      29 MB/s   |  30 MB/s | 0.97× |  ✅  |
| COMPRESS L9 |      13 MB/s   |  13 MB/s | 0.98× |  ✅  |
| INFLATE     |     999 MB/s   | 983 MB/s | 1.02× |  ✅  |

All paths clear ≥ 0.8×; the codec's native backend runs at parity with the
library it wraps. Native compress also matches zlib's **ratio** byte-for-byte
(L6 19% vs the old pure-cajeta 25%).

**Key tuning:** the first inflate run came in at 0.37× — `NativeZlib.uncompress`
inflated into a sized buffer and then `exact()`-copied the whole output into a
right-sized array (raw zlib inflates into a reused buffer, no copy). When the
caller's `destLen` is exact (`r == cap`, the common gzip/zlib case) the buffer is
now handed back directly, eliminating a redundant 128 KiB copy on the fast path
→ 0.37× to 1.02×.

## Packed repeated-varint scan (protobuf unit 6)

`PackedScanBench` compares the vectorized packed-payload element count against
the scalar walk it replaced. Both are run over the same bytes and their totals
are compared, so a mismatch fails loudly rather than flattering the new path.

```sh
CJ=/path/to/cajeta
CODEC=/tmp/codec.cja
"$CJ" --emit=cja --opt=O3 -o "$CODEC" \
    dev.cajeta.codec.protobuf.Protobuf.run src/main/cajeta /tmp/codecbuild
"$CJ" --emit=exe --opt=O3 --classpath="$CODEC" -o /tmp/packed-bench \
    dev.cajeta.codec.bench.PackedScanBench.run bench/src /tmp/codecbuild
/tmp/packed-bench
```

This is the only structural scan in protobuf that vectorizes. The field walk
cannot: tag-length-value framing makes "where does the next field start"
a serial dependency, with no context-free byte to compare against. A packed
payload is different — a run of varints delimited by continuation bits, which
one compare-and-popcount classifies 16 bytes at a time.

Measured (AMD Ryzen AI Max+ 395, `--opt=O3`, count only):

| payload | scalar | vectorized |
|---|---|---|
| 64 KiB, 1-byte varints | 44 MB/s | 3126 MB/s |
| 192 KiB, 3-byte varints | 102 MB/s | 2251 MB/s |
| 320 KiB, 5-byte varints | 128 MB/s | 2501 MB/s |

The scalar reference paid a non-inlined `varintLen` call per element, which the
block loop amortizes over 16 bytes — so this is the gain on this code path, not
a pure instruction-count ratio.
