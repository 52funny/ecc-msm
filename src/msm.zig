//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const simd = @import("msm_simd.zig");
pub const P256 = std.crypto.ecc.P256;
pub const AffineCoordinates = @TypeOf(P256.basePoint.affineCoordinates());
pub const Scalar = [32]u8;

const assert = std.debug.assert;
/// SIMD variants of the MSM functions. These are only available if the target architecture supports SIMD instructions.
pub const msmSimd = simd.msm;
/// SIMD variants of the MSM functions for affine coordinates. These are only available if the target architecture supports SIMD instructions.
pub const msmAffineSimd = simd.msm;

/// The window size for the MSM algorithm.
/// A larger window size will result in fewer iterations,
/// but will require more memory.
/// The size of the buckets array is 2^WINDOW_SIZE,
/// so a window size of 8 will require 256 buckets.
pub const WINDOW_SIZE = 8;

pub fn msm(points: []const P256, scalrs: []const Scalar) P256 {
    assert(points.len == scalrs.len);

    // Define the number of windows
    const num_windows: usize = @divFloor(@sizeOf(Scalar) * 8 + WINDOW_SIZE - 1, WINDOW_SIZE);

    // Result is zero at the beginning
    var result = P256.identityElement;

    var buckets: [1 << WINDOW_SIZE]P256 = undefined;

    var j = num_windows;
    while (j > 0) : (j -= 1) {
        // Initialize the buckets for this window, each bucket is the zero point at the beginning
        @memset(&buckets, P256.identityElement);

        // result = result * 2^WINDOW_SIZE
        for (0..WINDOW_SIZE) |_| {
            result = result.dbl();
        }

        for (points, scalrs) |p, s| {
            // Get the window value for this scalar
            const digit = get_window_value(usize, s, j - 1);

            // If the window value is not zero, add the point to the corresponding bucket
            if (digit != 0) {
                buckets[digit] = if (buckets[digit].z.isZero()) p else buckets[digit].add(p);
            }
        }

        var window_acc: P256 = P256.identityElement;
        var t: P256 = P256.identityElement;

        var k: usize = (1 << WINDOW_SIZE) - 1;
        while (k > 0) : (k -= 1) {
            t = t.add(buckets[k]);
            window_acc = window_acc.add(t);
        }
        result = result.add(window_acc);
    }
    return result;
}

pub fn msmAffine(points: []const AffineCoordinates, scalrs: []const Scalar) P256 {
    assert(points.len == scalrs.len);

    // Define the number of windows
    const num_windows: usize = @divFloor(@sizeOf(Scalar) * 8 + WINDOW_SIZE - 1, WINDOW_SIZE);

    // Result is zero at the beginning
    var result = P256.identityElement;

    var buckets: [1 << WINDOW_SIZE]P256 = undefined;

    var j = num_windows;
    while (j > 0) : (j -= 1) {
        // Initialize the buckets for this window, each bucket is the zero point at the beginning
        @memset(&buckets, P256.identityElement);

        // result = result * 2^WINDOW_SIZE
        for (0..WINDOW_SIZE) |_| {
            result = result.dbl();
        }

        for (points, scalrs) |p, s| {
            // Get the window value for this scalar
            const digit = get_window_value(usize, s, j - 1);

            // If the window value is not zero, add the point to the corresponding bucket
            if (digit != 0) {
                buckets[digit] = if (buckets[digit].z.isZero() and !p.x.isZero())
                    .{ .x = p.x, .y = p.y }
                else
                    buckets[digit].addMixed(p);
            }
        }

        var window_acc: P256 = P256.identityElement;
        var t: P256 = P256.identityElement;

        var k: usize = (1 << WINDOW_SIZE) - 1;
        while (k > 0) : (k -= 1) {
            t = t.add(buckets[k]);
            window_acc = window_acc.add(t);
        }
        result = result.add(window_acc);
    }
    return result;
}

inline fn get_window_value(comptime T: type, scalar: Scalar, window_index: usize) T {
    comptime {
        if (@typeInfo(T) != .int or @typeInfo(T).int.signedness != .unsigned)
            @compileError("T must be an unsigned integer type");
        if (WINDOW_SIZE == 0 or @bitSizeOf(T) < WINDOW_SIZE)
            @compileError("WINDOW_SIZE must be positive and fit in T");
    }

    const bit_offset = window_index * WINDOW_SIZE;
    const byte_offset = bit_offset / 8;

    if (byte_offset >= scalar.len) {
        return 0;
    }

    var window_value: T = 0;
    for (0..WINDOW_SIZE) |i| {
        const current_bit_index = bit_offset + i;
        const current_byte_index = current_bit_index / 8;
        const current_bit_in_byte: u3 = @intCast(current_bit_index % 8);

        if (current_byte_index < scalar.len) {
            const bit_value: T = @intCast((scalar[current_byte_index] >> current_bit_in_byte) & 1);
            window_value |= bit_value << @intCast(i);
        }
    }

    return window_value;
}

test "window extraction matches a little-endian integer" {
    const WindowValue = @Int(.unsigned, WINDOW_SIZE);
    var scalar: Scalar = undefined;
    for (&scalar, 0..) |*byte, i| {
        byte.* = @truncate(i * 73 + 0xab);
    }

    const value = std.mem.readInt(u256, &scalar, .little);
    const num_windows = (256 + WINDOW_SIZE - 1) / WINDOW_SIZE;
    for (0..num_windows + 1) |window_index| {
        const offset = window_index * WINDOW_SIZE;
        const expected: WindowValue = if (offset >= 256) 0 else @intCast(
            (value >> @intCast(offset)) & @as(u256, std.math.maxInt(WindowValue)),
        );
        try std.testing.expectEqual(expected, get_window_value(WindowValue, scalar, window_index));
        try std.testing.expectEqual(@as(u256, expected), get_window_value(u256, scalar, window_index));
    }
}

test "msm variants match the sum of scalar multiplications" {
    const points = [_]P256{ P256.basePoint, P256.basePoint.dbl() };
    const point_affines = [_]AffineCoordinates{
        points[0].affineCoordinates(),
        points[1].affineCoordinates(),
    };
    var scalars: [2]Scalar = @splat(@splat(0));
    scalars[0][0] = 1;
    for (&scalars[1], 0..) |*byte, i| {
        byte.* = @truncate(i * 73 + 0xab);
    }
    scalars[1][31] = 0x80;

    const expected = (try points[0].mul(scalars[0], .little)).add(
        try points[1].mul(scalars[1], .little),
    );
    try std.testing.expect(msm(&points, &scalars).equivalent(expected));
    try std.testing.expect(msmAffine(&point_affines, &scalars).equivalent(expected));
}

test "public entry points agree when automatic SIMD dispatch is used" {
    const size = 129;
    const points: [size]P256 = @splat(P256.basePoint);
    const affines: [size]AffineCoordinates = @splat(P256.basePoint.affineCoordinates());
    var one: Scalar = @splat(0);
    one[0] = 1;
    const scalars: [size]Scalar = @splat(one);
    var count: Scalar = @splat(0);
    count[0] = size;
    const expected = try P256.basePoint.mul(count, .little);
    try std.testing.expect(msm(&points, &scalars).equivalent(expected));
    try std.testing.expect(msmAffine(&affines, &scalars).equivalent(expected));
}
