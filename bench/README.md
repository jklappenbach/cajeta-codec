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
- **COMPRESS** — `DeflateStream` (the permessage-deflate send/echo path).
- **INFLATE stream** — `InflateStream` (the permessage-deflate receive path).
- **INFLATE one-shot** — `Deflate.inflate` (the gzip/zlib decode path).

Build **`--opt=O3`** — at `-O0` (debug) the numbers are lower and unrepresentative.
