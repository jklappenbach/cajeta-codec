# cajeta-codec

Standalone codec library for Cajeta — Part B of the codec framework. Formats
live under `src/main/cajeta/dev/cajeta/codec/<format>/`; the cajeta-unit `@Test`
suites under `src/test/cajeta/dev/cajeta/codec/selftest/`.

@td-project-workflow.md

## Build & test

```sh
./run-tests.sh        # builds the lib + cajeta-unit, links, runs @Test discovery
```

`run-tests.sh` expects a `cajeta-unit` checkout beside this repo (`UNIT_REPO=`
overrides) and builds the native zlib backend, exporting `CAJETA_NATIVE_PATH`.

## Toolchain coupling

The typed facades (`Protobuf.parse<T>` / `toBytes<T>`, and the Ion/Avro twins)
are **compile-time synthesized** — their bodies are emitted per-`T` by
synthesizers in the toolchain repo at `~/code/cpp/cajeta`
(`src/cajeta/codec/*Synthesizer.cpp`), not by anything in this repo. The stubs
here are failsafes that throw when the synthesizer does not engage. Work on the
typed surface therefore spans both repos. (`~/code/cpp/cajeta-two` is a stale
fork — do not edit it.)

The framework spec that governs every format is in the toolchain at
`docs/specification/codec/Codecs.md`.
