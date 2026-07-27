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
