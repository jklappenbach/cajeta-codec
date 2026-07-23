# Parquet writer ecosystem validation

`ParquetWriter` writes a complete file; pyarrow reads it back. The emitter main
is `dev.cajeta.codec.tools.ParquetWriteMain` (column `x` = [7,14,21,28,35]).

The rest of the tools tree may carry pre-slice-API breakage, so compile the one
main in isolation:

```
CAJ=/usr/bin/cajeta        # or .../cajeta/build/src/cajeta
out=$(mktemp -d)
mkdir -p "$out/toolsrc/dev/cajeta/codec/tools"
cp tools/src/dev/cajeta/codec/tools/ParquetWriteMain.cajeta "$out/toolsrc/dev/cajeta/codec/tools/"
$CAJ --emit=cja -o "$out/codec.cja" dev.cajeta.codec.protobuf.Protobuf.run src/main/cajeta "$out"
$CAJ --emit=exe --classpath="$out/codec.cja" -o "$out/pqwrite" \
    dev.cajeta.codec.tools.ParquetWriteMain.run "$out/toolsrc" "$out"
"$out/pqwrite"     # writes /tmp/our.parquet
python3 -c "import pyarrow.parquet as pq; print(pq.read_table('/tmp/our.parquet').to_pydict())"
```

Verified 2026-06-21: pyarrow reads `{'x':[7,14,21,28,35]}` from our writer's output.
Re-verified 2026-07-23 (U17), schema `x: int32 not null`.

## The reader direction (pyarrow -> cajeta)

The reader-widening suite goes the other way: every `Parquet*Test` fixture under
`src/test` is a real pyarrow-written file read back by `ParquetColumnReader`
(INT32/INT64/FLOAT/DOUBLE/BYTE_ARRAY, PLAIN + dictionary, definition-levels →
validity, multi-row-group). The typed `Table<R>` bridge (`run-bridge-test.sh`)
carries a pyarrow file with strings + nulls across two row groups into a
`Table<Tick>` over the Arrow C Data Interface.
