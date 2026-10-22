const std = @import("std");
const msm = @import("ecc_msm");
const Io = std.Io;

const assert = std.debug.assert;

const Scalar = msm.Scalar;
const P256 = msm.P256;
const AffineCoordinates = msm.AffineCoordinates;

pub fn main(init: std.process.Init) !void {
    const size = 1 << 12;

    var prng = std.Random.DefaultPrng.init(0);
    var random = prng.random();

    var scalars: [size]Scalar = undefined;
    var points: [size]P256 = undefined;
    var point_affines: [size]AffineCoordinates = undefined;

    for (&points, &point_affines, &scalars) |*point, *point_affine, *scalar| {
        var s: Scalar = undefined;
        random.bytes(&(scalar.*));
        random.bytes(&s);

        point.* = try P256.basePoint.mul(s, .little);
        point_affine.* = point.*.affineCoordinates();
    }

    var before = Io.Clock.now(.awake, init.io);
    const val = msm.msm(&points, &scalars);
    var after = Io.Clock.now(.awake, init.io);
    const msm_ns = before.durationTo(after).nanoseconds;

    before = Io.Clock.now(.awake, init.io);
    const val_affine = msm.msmAffine(&point_affines, &scalars);
    after = Io.Clock.now(.awake, init.io);
    const msm_affine_ns = before.durationTo(after).nanoseconds;

    before = Io.Clock.now(.awake, init.io);
    const val_simd = if (comptime msm.simd.available and msm.WINDOW_SIZE > 0 and msm.WINDOW_SIZE <= 8 and points.len > 32)
        msm.simd.msm(P256, msm.WINDOW_SIZE, &points, &scalars)
    else fallback: {
        std.log.warn("SIMD MSM not available or not applicable for this configuration. Falling back to standard MSM.\n", .{});
        break :fallback msm.msm(&points, &scalars);
    };
    after = Io.Clock.now(.awake, init.io);
    const msm_simd_ns = before.durationTo(after).nanoseconds;

    before = Io.Clock.now(.awake, init.io);
    const val_affine_simd = if (comptime msm.simd.available and msm.WINDOW_SIZE > 0 and msm.WINDOW_SIZE <= 8 and points.len > 32)
        msm.simd.msm(AffineCoordinates, msm.WINDOW_SIZE, &point_affines, &scalars)
    else fallback: {
        std.log.warn("SIMD MSM for affine coordinates not available or not applicable for this configuration. Falling back to standard MSM.\n", .{});
        break :fallback msm.msmAffine(&point_affines, &scalars);
    };
    after = Io.Clock.now(.awake, init.io);
    const msm_affine_simd_ns = before.durationTo(after).nanoseconds;

    var acc: P256 = P256.identityElement;
    before = Io.Clock.now(.awake, init.io);
    for (points, scalars) |p, s| {
        acc = acc.add(try p.mul(s, .little));
    }
    after = Io.Clock.now(.awake, init.io);
    const naive_ns = before.durationTo(after).nanoseconds;

    if (!val.equivalent(acc) or !val_affine.equivalent(acc)) return error.ResultMismatch;

    if (!val_simd.equivalent(acc) or !val_affine_simd.equivalent(acc)) return error.ResultMismatch;

    std.debug.print("Mode: {s}, points: {}, window size: {}, simd: {}\n", .{
        @tagName(@import("builtin").mode), points.len, msm.WINDOW_SIZE, msm.simd.available,
    });

    std.debug.print("The val: {x}\n", .{val.toCompressedSec1()});
    std.debug.print("The acc: {x}\n", .{acc.toCompressedSec1()});
    std.debug.print("The val_affine: {x}\n", .{val_affine.toCompressedSec1()});
    std.debug.print("The val_simd: {x}\n", .{val_simd.toCompressedSec1()});
    std.debug.print("The val_affine_simd: {x}\n", .{val_affine_simd.toCompressedSec1()});

    std.debug.print("Results match: true\n", .{});
    std.debug.print("The MSM time elapsed: {} us\n", .{@divTrunc(msm_ns, 1000)});
    std.debug.print("The MSM offine time elasped: {} us\n", .{@divTrunc(msm_affine_ns, 1000)});
    std.debug.print("The MSM simd time elapsed: {} us\n", .{@divTrunc(msm_simd_ns, 1000)});
    std.debug.print("The MSM offine simd time elapsed: {} us\n", .{@divTrunc(msm_affine_simd_ns, 1000)});
    std.debug.print("The acc time elapsed: {} us\n", .{@divTrunc(naive_ns, 1000)});

    const speedup = @as(f64, @floatFromInt(naive_ns)) / @as(f64, @floatFromInt(msm_ns));
    std.debug.print("MSM projective speedup: {d:.2}x\n", .{speedup});
    std.debug.print("MSM affine speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(naive_ns)) / @as(f64, @floatFromInt(msm_affine_ns))});
    std.debug.print("MSM projective simd speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(naive_ns)) / @as(f64, @floatFromInt(msm_simd_ns))});
    std.debug.print("MSM affine simd speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(naive_ns)) / @as(f64, @floatFromInt(msm_affine_simd_ns))});
}
