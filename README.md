# Nist P256 Elliptic Curve MSM Algorithm


You should have Zig (v0.16.0), and then execute it. If you architecture is `x86_64` and CPU has `AVX512-IFMA` extension, the SIMD option will enabled by default.

```bash
zig build run -Doptimize=ReleaseFast
```

The output is:

```bash
Mode: ReleaseFast, points: 4096, window size: 8, simd: true
The val: 03f731159057dfa6705ae04b029d171b5ccdbaa8264db06650815426bd46dc25c2
The acc: 03f731159057dfa6705ae04b029d171b5ccdbaa8264db06650815426bd46dc25c2
The val_affine: 03f731159057dfa6705ae04b029d171b5ccdbaa8264db06650815426bd46dc25c2
The val_simd: 03f731159057dfa6705ae04b029d171b5ccdbaa8264db06650815426bd46dc25c2
The val_affine_simd: 03f731159057dfa6705ae04b029d171b5ccdbaa8264db06650815426bd46dc25c2
Results match: true
The MSM time elapsed: 108856 us
The MSM offine time elasped: 85186 us
The MSM simd time elapsed: 15792 us
The MSM offine simd time elapsed: 13477 us
The acc time elapsed: 950674 us
MSM projective speedup: 8.73x
MSM affine speedup: 11.16x
MSM projective simd speedup: 60.20x
MSM affine simd speedup: 70.54x
```
