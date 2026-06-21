#!/usr/bin/env bash
# Phase 9.1 — build + run the GPU columnar-decode oracle test.
#
# The GPU kernels live under gpu/src and are built with the XPU backend (default
# cpu — a real vectorized backend, so this validates correctness with no GPU
# hardware; pass amdgpu/cuda/vulkan to run on a device). The codec library is
# supplied as a .cja classpath dep for the scalar BitPack oracle.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CAJETA="${CAJETA:-cajeta}"
XPU="${1:-cpu}"
out="$(mktemp -d)"; mkdir -p "$out/obj"
trap 'rm -rf "$out"' EXIT

echo ">> building codec library .cja"
"$CAJETA" --emit=cja -o "$out/codec.cja" \
    dev.cajeta.codec.protobuf.Protobuf.run "$here/src/main/cajeta" "$out" >/dev/null

echo ">> building GPU decode oracle (--xpu-backend=$XPU)"
"$CAJETA" --emit=exe --xpu-backend="$XPU" --classpath="$out/codec.cja" \
    -o "$out/gpudecode" \
    dev.cajeta.codec.gpu.GpuColumnarMain.run "$here/gpu/src" "$out/obj" >/dev/null

echo ">> running"
"$out/gpudecode"
