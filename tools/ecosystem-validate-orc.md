# ORC writer ecosystem validation

Build a tiny main that writes via `OrcWriter` to disk, then read with pyarrow:

```
CAJ=.../cajeta-two/build/src/cajeta
out=$(mktemp -d)
$CAJ --emit=cja -o "$out/codec.cja" dev.cajeta.codec.protobuf.Protobuf.run src/main/cajeta "$out"
$CAJ --emit=exe --classpath="$out/codec.cja" -o "$out/orcwrite" \
    dev.cajeta.codec.tools.OrcWriteMain.run tools/src "$out"
"$out/orcwrite"     # writes /tmp/our.orc
python3 -c "import pyarrow.orc as orc; print(orc.read_table('/tmp/our.orc').to_pydict())"
```

Verified 2026-06-21: pyarrow reads `{'x': [7, 14, 21, 28, 35]}` from our writer's
output (single LONG column, RLE-v2 DIRECT, uncompressed, no nulls).
