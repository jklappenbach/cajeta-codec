# GPU columnar decode (Phase 9.1)

Gated throughput offload for bulk columnar scans (codec spec §6). `GpuColumnar`
provides a fixed-width **bit-unpack** `@Kernel` (the most SIMT-friendly columnar
primitive — one independent thread per value) plus a host `unpackOnGpu` wrapper
and the `shouldOffload` gate (size threshold + cuDF "data already on the GPU"
signal).

Kept out of the core codec `.cja` (which builds with no XPU backend); built
separately with `--xpu-backend=<cpu|amdgpu|cuda|vulkan>`. The CPU backend is a
real vectorized backend, so correctness is provable with no GPU hardware.

```
CAJETA=.../cajeta-two/build/src/cajeta ./run-gpu-decode.sh        # cpu oracle
CAJETA=...                              ./run-gpu-decode.sh amdgpu  # on a device
```

Verified 2026-06-21 (cpu backend): `GPU-DECODE-PASS widths=9 count=1000` — the
kernel is bit-exact to the scalar `BitPack` oracle across widths 1,7,8,13,16,17,
24,31,32 (incl. the 1<<32 mask edge), and the gate engages only for large +
GPU-bound reads. RLE/dict/delta kernels + on-device throughput measurement are
follow-ups (P-GPU-MORE / P-GPU-BENCH).
