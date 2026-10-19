//! P256's complete homogeneous-coordinate formulas, evaluated in eight lanes.
const std = @import("std");
const field = @import("simd_field.zig");
const Fe = field.Fe;
const P256 = std.crypto.ecc.P256;
const AffineCoordinates = @TypeOf(P256.basePoint.affineCoordinates());

/// Scalar storage for one lane; all coordinates use radix-52 Montgomery form.
pub const Packed = struct {
    x: field.Limb,
    y: field.Limb,
    z: field.Limb,

    pub const identity = Packed{
        .x = .{0} ** 5,
        .y = Fe.one.unpack()[0],
        .z = .{0} ** 5,
    };
};

pub const Point = struct {
    const Self = @This();
    x: Fe,
    y: Fe,
    z: Fe,

    pub const identity = Self{ .x = Fe.zero, .y = Fe.one, .z = Fe.zero };
    const curve_b = Fe.splat(P256.B);

    pub fn broadcast(comptime T: type, point: T) Self {
        if (T == P256) {
            if (point.z.isZero()) return identity;
            return .{ .x = Fe.splat(point.x), .y = Fe.splat(point.y), .z = Fe.splat(point.z) };
        }
        if (point.x.isZero()) return identity;
        return .{ .x = Fe.splat(point.x), .y = Fe.splat(point.y), .z = Fe.one };
    }

    pub fn pack(points: [8]Packed) Self {
        var xs: [8]field.Limb = undefined;
        var ys: [8]field.Limb = undefined;
        var zs: [8]field.Limb = undefined;
        for (points, &xs, &ys, &zs) |point, *x, *y, *z| {
            x.* = point.x;
            y.* = point.y;
            z.* = point.z;
        }
        return .{ .x = Fe.pack(xs), .y = Fe.pack(ys), .z = Fe.pack(zs) };
    }

    pub fn unpack(point: Self) [8]Packed {
        const xs = point.x.unpack();
        const ys = point.y.unpack();
        const zs = point.z.unpack();
        var result: [8]Packed = undefined;
        for (&result, xs, ys, zs) |*out, x, y, z| out.* = .{ .x = x, .y = y, .z = z };
        return result;
    }

    pub fn toStd(point: Self) [8]P256 {
        const xs = point.x.toStd();
        const ys = point.y.toStd();
        const zs = point.z.toStd();
        var result: [8]P256 = undefined;
        for (&result, xs, ys, zs) |*out, x, y, z| out.* = .{ .x = x, .y = y, .z = z };
        return result;
    }

    /// Same formula as std.crypto.ecc.P256.add (Renes-Costello-Batina, alg. 4).
    pub fn add(p: Self, q: Self) Self {
        var t0 = p.x.mul(q.x);
        var t1 = p.y.mul(q.y);
        var t2 = p.z.mul(q.z);
        var t3 = p.x.add(p.y);
        var t4 = q.x.add(q.y);
        t3 = t3.mul(t4);
        t4 = t0.add(t1);
        t3 = t3.sub(t4);
        t4 = p.y.add(p.z);
        var x = q.y.add(q.z);
        t4 = t4.mul(x);
        x = t1.add(t2);
        t4 = t4.sub(x);
        x = p.x.add(p.z);
        var y = q.x.add(q.z);
        x = x.mul(y);
        y = t0.add(t2);
        y = x.sub(y);
        var z = curve_b.mul(t2);
        x = y.sub(z);
        z = x.dbl();
        x = x.add(z);
        z = t1.sub(x);
        x = t1.add(x);
        y = curve_b.mul(y);
        t1 = t2.dbl();
        t2 = t1.add(t2);
        y = y.sub(t2);
        y = y.sub(t0);
        t1 = y.dbl();
        y = t1.add(y);
        t1 = t0.dbl();
        t0 = t1.add(t0);
        t0 = t0.sub(t2);
        t1 = t4.mul(y);
        t2 = t0.mul(y);
        y = x.mul(z);
        y = y.add(t2);
        x = t3.mul(x);
        x = x.sub(t1);
        z = t4.mul(z);
        t1 = t3.mul(t0);
        z = z.add(t1);
        return .{ .x = x, .y = y, .z = z };
    }

    /// Same formula and affine-identity handling as P256.addMixed (alg. 5).
    pub fn addMixed(p: Self, q: Self) Self {
        var t0 = p.x.mul(q.x);
        var t1 = p.y.mul(q.y);
        var t3 = q.x.add(q.y);
        var t4 = p.x.add(p.y);
        t3 = t3.mul(t4);
        t4 = t0.add(t1);
        t3 = t3.sub(t4);
        t4 = q.y.mul(p.z);
        t4 = t4.add(p.y);
        var y = q.x.mul(p.z);
        y = y.add(p.x);
        var z = curve_b.mul(p.z);
        var x = y.sub(z);
        z = x.dbl();
        x = x.add(z);
        z = t1.sub(x);
        x = t1.add(x);
        y = curve_b.mul(y);
        t1 = p.z.dbl();
        var t2 = t1.add(p.z);
        y = y.sub(t2);
        y = y.sub(t0);
        t1 = y.dbl();
        y = t1.add(y);
        t1 = t0.dbl();
        t0 = t1.add(t0);
        t0 = t0.sub(t2);
        t1 = t4.mul(y);
        t2 = t0.mul(y);
        y = x.mul(z);
        y = y.add(t2);
        x = t3.mul(x);
        x = x.sub(t1);
        z = t4.mul(z);
        t1 = t3.mul(t0);
        z = z.add(t1);
        const is_identity = q.x.isZero();
        return .{
            .x = Fe.select(is_identity, p.x, x),
            .y = Fe.select(is_identity, p.y, y),
            .z = Fe.select(is_identity, p.z, z),
        };
    }
};

test "SIMD complete point additions agree in independent lanes" {
    if (!field.available) return error.SkipZigTest;
    var ps: [8]P256 = undefined;
    var qs: [8]P256 = undefined;
    var packed_p: [8]Packed = undefined;
    var packed_q: [8]Packed = undefined;
    var packed_affine_q: [8]Packed = undefined;
    for (0..8) |i| {
        var s = [_]u8{0} ** 32;
        s[0] = @intCast(i + 1);
        ps[i] = if (i == 0) P256.identityElement else try P256.basePoint.mul(s, .little);
        qs[i] = switch (i % 4) {
            0 => P256.identityElement,
            1 => ps[i],
            2 => ps[i].neg(),
            else => P256.basePoint,
        };
        packed_p[i] = Point.broadcast(P256, ps[i]).unpack()[0];
        packed_q[i] = Point.broadcast(P256, qs[i]).unpack()[0];
        packed_affine_q[i] = Point.broadcast(AffineCoordinates, qs[i].affineCoordinates()).unpack()[0];
    }
    const p = Point.pack(packed_p);
    const sums = p.add(Point.pack(packed_q)).toStd();
    const mixed = p.addMixed(Point.pack(packed_affine_q)).toStd();
    for (ps, qs, sums, mixed) |a, b, sum, mixed_sum| {
        try std.testing.expect(sum.equivalent(a.add(b)));
        try std.testing.expect(mixed_sum.equivalent(a.addMixed(b.affineCoordinates())));
    }
}
