//! Each SIMD lane owns a different scalar window, so bucket writes cannot collide.
const std = @import("std");
const field = @import("simd_field.zig");
const point = @import("simd_point.zig");
const Point8 = point.Point;
const Packed = point.Packed;
const P256 = std.crypto.ecc.P256;
const AffineCoordinates = @TypeOf(P256.basePoint.affineCoordinates());
const Scalar = [32]u8;

pub const available = field.available;

/// Internal backend shared by the two existing public entry points.
/// Limit the window to eight bits so the stack workspace is at most 1 MiB.
pub fn msm(comptime T: type, comptime window_size: usize, points: []const T, scalars: []const Scalar) P256 {
    std.debug.assert(points.len == scalars.len);
    comptime std.debug.assert(window_size > 0 and window_size <= 8);
    if (points.len == 0) return P256.identityElement;

    const num_windows = (256 + window_size - 1) / window_size;
    const num_groups = (num_windows + 7) / 8;
    const bucket_count = 1 << window_size;
    // Layout: group -> digit -> lane/window. Adjacent lanes stay together
    // during bucket reduction; indexed gathers below never share a destination.
    var buckets: [num_groups][bucket_count][8]Packed = undefined;
    for (&buckets) |*group| {
        for (group) |*bucket| @memset(bucket, Packed.identity);
    }

    for (points, scalars) |p, scalar| {
        // Convert each input only once, then reuse it for every window group.
        const broadcast = Point8.broadcast(T, p);
        for (&buckets, 0..) |*group, g| {
            var digits: [8]usize = undefined;
            var selected: [8]Packed = undefined;
            inline for (0..8) |lane| {
                const window = g * 8 + lane;
                digits[lane] = if (window < num_windows) windowValue(window_size, scalar, window) else 0;
                selected[lane] = group[digits[lane]][lane];
            }
            const previous = Point8.pack(selected);
            const updated = if (T == P256) previous.add(broadcast) else previous.addMixed(broadcast);
            const unpacked = updated.unpack();
            inline for (0..8) |lane| {
                if (digits[lane] != 0) group[digits[lane]][lane] = unpacked[lane];
            }
        }
    }

    var result = P256.identityElement;
    var g: usize = num_groups;
    while (g > 0) {
        g -= 1;
        var running = Point8.identity;
        var sum = Point8.identity;
        var k: usize = bucket_count;
        while (k > 1) {
            k -= 1;
            running = running.add(Point8.pack(buckets[g][k]));
            sum = sum.add(running);
        }

        // Window weights differ: combine them in descending order, rather
        // than performing a horizontal sum across the SIMD lanes.
        const windows = sum.toStd();
        var lane: usize = 8;
        while (lane > 0) {
            lane -= 1;
            if (g * 8 + lane >= num_windows) continue;
            for (0..window_size) |_| result = result.dbl();
            result = result.add(windows[lane]);
        }
    }
    return result;
}

fn windowValue(comptime width: usize, scalar: Scalar, window: usize) usize {
    const bit = window * width;
    const byte = bit / 8;
    const shift: u3 = @intCast(bit % 8);
    var word: u16 = scalar[byte];
    if (byte + 1 < scalar.len) word |= @as(u16, scalar[byte + 1]) << 8;
    return (word >> shift) & ((1 << width) - 1);
}

test "SIMD MSM matches scalar multiplication for tails, identities and all scalar bits" {
    if (!available) return error.SkipZigTest;
    const size = 129;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    var points: [size]P256 = undefined;
    var affines: [size]AffineCoordinates = undefined;
    var scalars: [size]Scalar = undefined;
    for (&points, &affines, &scalars, 0..) |*p, *affine, *s, i| {
        var scalar: Scalar = @splat(0);
        scalar[0] = @intCast(i + 1);
        p.* = if (i % 17 == 0) P256.identityElement else try P256.basePoint.mul(scalar, .little);
        affine.* = p.affineCoordinates();
        random.bytes(s);
    }
    scalars[0] = @splat(0xff);
    scalars[1] = @splat(0xff);
    scalars[2] = @splat(0);
    scalars[3] = @splat(0);
    scalars[3][31] = 0x80;
    std.mem.writeInt(u256, &scalars[4], P256.scalar.field_order, .little);
    points[5] = points[6].neg();
    affines[5] = points[5].affineCoordinates();
    scalars[5] = scalars[6];

    inline for (.{ 3, 8 }) |width| {
        for ([_]usize{ 0, 1, 2, 7, 8, 9, 31, size }) |count| {
            var expected = P256.identityElement;
            for (points[0..count], scalars[0..count]) |p, s| {
                expected = expected.add(p.mul(s, .little) catch P256.identityElement);
            }
            try std.testing.expect(msm(P256, width, points[0..count], scalars[0..count]).equivalent(expected));
            try std.testing.expect(msm(AffineCoordinates, width, affines[0..count], scalars[0..count]).equivalent(expected));
        }
    }

    const cancel = [_]P256{ P256.basePoint, P256.basePoint.neg() };
    const cancel_affines = [_]AffineCoordinates{ cancel[0].affineCoordinates(), cancel[1].affineCoordinates() };
    var cancel_scalars: [2]Scalar = @splat(@splat(0xff));
    try std.testing.expect(msm(P256, 8, &cancel, &cancel_scalars).equivalent(P256.identityElement));
    try std.testing.expect(msm(AffineCoordinates, 8, &cancel_affines, &cancel_scalars).equivalent(P256.identityElement));
    @memset(&cancel_scalars, @splat(0));
    try std.testing.expect(msm(P256, 8, &cancel, &cancel_scalars).equivalent(P256.identityElement));
    try std.testing.expect(msm(AffineCoordinates, 8, &cancel_affines, &cancel_scalars).equivalent(P256.identityElement));
}
