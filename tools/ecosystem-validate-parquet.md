# Parquet writer ecosystem validation

Build a tiny main that writes via `ParquetWriter` to disk, then read with pyarrow:

```
CAJ=.../cajeta-two/build/src/cajeta
out=$(mktemp -d)
$CAJ --emit=cja -o "$out/codec.cja" dev.cajeta.codec.protobuf.Protobuf.run src/main/cajeta "$out"
$CAJ --emit=exe --classpath="$out/codec.cja" -o "$out/pqwrite" \
    dev.cajeta.codec.tools.ParquetWriteMain.run <toolsrc> "$out"
"$out/pqwrite"     # writes /tmp/our.parquet
python3 -c "import pyarrow.parquet as pq; print(pq.read_table('/tmp/our.parquet').to_pydict())"
```

Verified 2026-06-21: pyarrow reads `{'x':[7,14,21,28,35]}` from our writer's output.
