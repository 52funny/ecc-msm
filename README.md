# Nist P256 Elliptic Curve MSM Algorithm


You should have Zig (v0.17.0), and then execute it.

If you architecture is `x86_64` and CPU has `AVX512-IFMA` extension, the SIMD option will enabled by default.

```bash
zig build run -Doptimize=ReleaseFast
```

The output is:

```bash
Mode: fast, points: 4096, window size: 8, simd: true
The val: 0295eadd9a7989f568d2fc639156e523d7cd37611e4f04c67ef4dc882831302734
The acc: 0295eadd9a7989f568d2fc639156e523d7cd37611e4f04c67ef4dc882831302734
The val_affine: 0295eadd9a7989f568d2fc639156e523d7cd37611e4f04c67ef4dc882831302734
The val_simd: 0295eadd9a7989f568d2fc639156e523d7cd37611e4f04c67ef4dc882831302734
The val_affine_simd: 0295eadd9a7989f568d2fc639156e523d7cd37611e4f04c67ef4dc882831302734
Results match: true
The MSM time elapsed: 44943 us
The MSM offine time elasped: 65634 us
The MSM simd time elapsed: 15292 us
The MSM offine simd time elapsed: 16404 us
The acc time elapsed: 402755 us
MSM projective speedup: 8.96x
MSM affine speedup: 6.14x
MSM projective simd speedup: 26.34x
MSM affine simd speedup: 24.55x
```
