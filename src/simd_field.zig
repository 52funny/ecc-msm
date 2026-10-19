//! Eight independent P256 field elements in radix 2^52 Montgomery form.
const std = @import("std");
const builtin = @import("builtin");
const StdFe = std.crypto.ecc.P256.Fe;

// Zig 0.16's native Debug backend cannot pass 512-bit inline-asm operands.
pub const available = builtin.zig_backend == .stage2_llvm and
    builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .avx512ifma);
pub const Vec = @Vector(8, u64);
pub const Mask = @Vector(8, bool);
pub const Limb = [5]u64;
const radix_bits = 52;
const limb_mask: u64 = (1 << radix_bits) - 1;
const modulus: u256 = StdFe.field_order;
const prime = split(modulus);

pub const Fe = struct {
    const Self = @This();
    limbs: [5]Vec,

    pub const zero = raw(0);
    pub const one = raw(@intCast((@as(u512, 1) << 260) % modulus));

    fn raw(comptime value: u256) Self {
        const words = split(value);
        var result: Self = undefined;
        inline for (0..5) |i| result.limbs[i] = @splat(words[i]);
        return result;
    }

    /// Convert R=2^256 to R=2^260, then broadcast to all eight lanes.
    pub fn splat(value: StdFe) Self {
        var adjusted = value;
        inline for (0..4) |_| adjusted = adjusted.dbl();
        const words = split(@bitCast(adjusted.limbs));
        var result: Self = undefined;
        inline for (0..5) |i| result.limbs[i] = @splat(words[i]);
        return result;
    }

    pub fn pack(values: [8]Limb) Self {
        var result: Self = undefined;
        inline for (0..5) |i| {
            var lanes: [8]u64 = undefined;
            for (values, &lanes) |value, *lane| lane.* = value[i];
            result.limbs[i] = lanes;
        }
        return result;
    }

    pub fn unpack(value: Self) [8]Limb {
        var result: [8]Limb = undefined;
        inline for (0..5) |i| {
            const lanes: [8]u64 = value.limbs[i];
            for (&result, lanes) |*words, lane| words[i] = lane;
        }
        return result;
    }

    pub fn toStd(value: Self) [8]StdFe {
        // Multiplication by the *raw* R256 changes the Montgomery radix back:
        // (a R260) R256 / R260 = a R256.
        const r256: u256 = @bitCast(StdFe.one.limbs);
        const words = value.mul(raw(r256)).unpack();
        var result: [8]StdFe = undefined;
        for (words, &result) |limbs, *out| out.* = .{ .limbs = @bitCast(join(limbs)) };
        return result;
    }

    pub fn select(mask: Mask, yes: Self, no: Self) Self {
        var result: Self = undefined;
        inline for (0..5) |i| result.limbs[i] = @select(u64, mask, yes.limbs[i], no.limbs[i]);
        return result;
    }

    pub fn isZero(value: Self) Mask {
        var bits: Vec = @splat(0);
        inline for (0..5) |i| bits |= value.limbs[i];
        return bits == @as(Vec, @splat(0));
    }

    pub fn add(a: Self, b: Self) Self {
        var result: Self = undefined;
        var carry: Vec = @splat(0);
        inline for (0..5) |i| {
            const word = a.limbs[i] + b.limbs[i] + carry;
            result.limbs[i] = word & @as(Vec, @splat(limb_mask));
            carry = word >> @as(Vec, @splat(radix_bits));
        }
        return reduce(result);
    }

    pub fn sub(a: Self, b: Self) Self {
        var result: Self = undefined;
        var borrow: Vec = @splat(0);
        inline for (0..5) |i| {
            const rhs = b.limbs[i] + borrow;
            result.limbs[i] = (a.limbs[i] -% rhs) & @as(Vec, @splat(limb_mask));
            borrow = @select(u64, a.limbs[i] < rhs, @as(Vec, @splat(1)), @as(Vec, @splat(0)));
        }
        const underflow = borrow != @as(Vec, @splat(0));
        var carry: Vec = @splat(0);
        inline for (0..5) |i| {
            const correction = @select(u64, underflow, @as(Vec, @splat(prime[i])), @as(Vec, @splat(0)));
            const word = result.limbs[i] + correction + carry;
            result.limbs[i] = word & @as(Vec, @splat(limb_mask));
            carry = word >> @as(Vec, @splat(radix_bits));
        }
        return result;
    }

    pub fn dbl(a: Self) Self {
        return a.add(a);
    }

    pub fn sq(a: Self) Self {
        return a.mul(a);
    }

    /// CIOS Montgomery multiplication, with normalized inputs and output < p.
    pub fn mul(a: Self, b: Self) Self {
        var t = [_]Vec{@splat(0)} ** 6;
        inline for (0..5) |i| {
            inline for (0..5) |j| {
                t[j] = madd52lo(t[j], a.limbs[j], b.limbs[i]);
                t[j + 1] = madd52hi(t[j + 1], a.limbs[j], b.limbs[i]);
            }

            // p[0] = -1 mod 2^52, hence -p[0]^-1 = 1 and q = t[0].
            const q = t[0] & @as(Vec, @splat(limb_mask));
            inline for (0..5) |j| {
                if (prime[j] != 0) {
                    t[j] = madd52lo(t[j], q, @splat(prime[j]));
                    t[j + 1] = madd52hi(t[j + 1], q, @splat(prime[j]));
                }
            }

            // The low limb is now zero mod 2^52. Propagate carries and drop it.
            var carry = t[0] >> @as(Vec, @splat(radix_bits));
            inline for (0..5) |j| {
                const word = t[j + 1] + carry;
                t[j] = word & @as(Vec, @splat(limb_mask));
                carry = word >> @as(Vec, @splat(radix_bits));
            }
            t[5] = carry;
        }
        return reduce(.{ .limbs = t[0..5].* });
    }

    fn reduce(value: Self) Self {
        var reduced: Self = undefined;
        var borrow: Vec = @splat(0);
        inline for (0..5) |i| {
            const rhs = @as(Vec, @splat(prime[i])) + borrow;
            reduced.limbs[i] = (value.limbs[i] -% rhs) & @as(Vec, @splat(limb_mask));
            borrow = @select(u64, value.limbs[i] < rhs, @as(Vec, @splat(1)), @as(Vec, @splat(0)));
        }
        return select(borrow == @as(Vec, @splat(0)), reduced, value);
    }
};

fn split(value: u256) Limb {
    var result: Limb = undefined;
    inline for (0..5) |i| result[i] = @as(u64, @truncate(value >> (i * radix_bits))) & limb_mask;
    return result;
}

fn join(words: Limb) u256 {
    var result: u256 = 0;
    inline for (0..5) |i| result |= @as(u256, words[i]) << (i * radix_bits);
    return result;
}

inline fn madd52lo(acc: Vec, a: Vec, b: Vec) Vec {
    return asm ("vpmadd52luq %[b], %[a], %[result]"
        : [result] "=v" (-> Vec),
        : [acc] "0" (acc),
          [a] "v" (a),
          [b] "v" (b),
    );
}

inline fn madd52hi(acc: Vec, a: Vec, b: Vec) Vec {
    return asm ("vpmadd52huq %[b], %[a], %[result]"
        : [result] "=v" (-> Vec),
        : [acc] "0" (acc),
          [a] "v" (a),
          [b] "v" (b),
    );
}

test "SIMD field operations agree with the standard P256 field in every lane" {
    if (!available) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    for (0..128) |sample| {
        var a: [8]StdFe = undefined;
        var b: [8]StdFe = undefined;
        var packed_a: [8]Limb = undefined;
        var packed_b: [8]Limb = undefined;
        for (&a, &b, &packed_a, &packed_b, 0..) |*x, *y, *px, *py, lane| {
            var bytes: [32]u8 = undefined;
            random.bytes(&bytes);
            var ai = std.mem.readInt(u256, &bytes, .little) % modulus;
            random.bytes(&bytes);
            var bi = std.mem.readInt(u256, &bytes, .little) % modulus;
            if (sample == 0) {
                ai = switch (lane) {
                    0 => 0,
                    1 => 1,
                    2 => modulus - 1,
                    3 => modulus - 2,
                    else => ai,
                };
                bi = switch (lane) {
                    0 => 0,
                    1 => modulus - 1,
                    2 => modulus - 1,
                    3 => 2,
                    else => bi,
                };
            }
            std.mem.writeInt(u256, &bytes, ai, .little);
            x.* = try StdFe.fromBytes(bytes, .little);
            std.mem.writeInt(u256, &bytes, bi, .little);
            y.* = try StdFe.fromBytes(bytes, .little);
            px.* = Fe.splat(x.*).unpack()[0];
            py.* = Fe.splat(y.*).unpack()[0];
        }
        const x = Fe.pack(packed_a);
        const y = Fe.pack(packed_b);
        const back = x.toStd();
        const sums = x.add(y).toStd();
        const differences = x.sub(y).toStd();
        const products = x.mul(y).toStd();
        const squares = x.sq().toStd();
        for (0..8) |lane| {
            try std.testing.expect(back[lane].equivalent(a[lane]));
            try std.testing.expect(sums[lane].equivalent(a[lane].add(b[lane])));
            try std.testing.expect(differences[lane].equivalent(a[lane].sub(b[lane])));
            try std.testing.expect(products[lane].equivalent(a[lane].mul(b[lane])));
            try std.testing.expect(squares[lane].equivalent(a[lane].sq()));
        }
    }
}
