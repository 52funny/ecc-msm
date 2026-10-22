const std = @import("std");
const msm = @import("ecc_msm");

// 16MB statically allocated buffer for WASM memory allocations
var buffer: [16 * 1024 * 1024]u8 align(16) = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
const allocator = fba.allocator();

/// Allocate `size` bytes from the WASM heap. Returns pointer or 0 on failure.
export fn alloc(size: usize) usize {
    const ptr = allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(ptr.ptr);
}

/// Free memory previously allocated with `alloc`.
export fn free(ptr: usize, size: usize) void {
    if (ptr == 0) return;
    const slice: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..size];
    allocator.free(slice);
}

/// Copy the P256 base point (projective) into `out_ptr`.
export fn get_base_point(out_ptr: [*]u8) void {
    const out = out_ptr[0..@sizeOf(msm.P256)];
    @memcpy(out, std.mem.asBytes(&msm.P256.basePoint));
}

/// Copy the P256 base point (affine) into `out_ptr`.
export fn get_base_point_affine(out_ptr: [*]u8) void {
    const out = out_ptr[0..@sizeOf(msm.AffineCoordinates)];
    @memcpy(out, std.mem.asBytes(&msm.P256.basePoint.affineCoordinates()));
}

/// Scalar multiplication: result = point * scalar
/// `point_ptr` must point to `@sizeOf(P256)` bytes.
/// `scalar_ptr` must point to `@sizeOf(Scalar)` (32) bytes.
/// `out_ptr` must point to `@sizeOf(P256)` bytes.
/// Returns 0 on success, -1 on error.
export fn point_mul(point_ptr: [*]const u8, scalar_ptr: [*]const u8, out_ptr: [*]u8) i32 {
    const point = std.mem.bytesToValue(msm.P256, point_ptr[0..@sizeOf(msm.P256)]);
    const scalar = std.mem.bytesToValue(msm.Scalar, scalar_ptr[0..@sizeOf(msm.Scalar)]);

    const result = point.mul(scalar, .little) catch return -1;

    const out = out_ptr[0..@sizeOf(msm.P256)];
    @memcpy(out, std.mem.asBytes(&result));
    return 0;
}

/// MSM using projective P256 points.
/// `points_ptr` -> `count * size_of_p256()` bytes
/// `scalars_ptr` -> `count * size_of_scalar()` bytes
/// `out_ptr` -> `size_of_p256()` bytes for result
export fn msm_compute(points_ptr: [*]const u8, scalars_ptr: [*]const u8, count: usize, out_ptr: [*]u8) i32 {
    const points_bytes = points_ptr[0..count * @sizeOf(msm.P256)];
    const scalars_bytes = scalars_ptr[0..count * @sizeOf(msm.Scalar)];

    const points_aligned: []align(@alignOf(msm.P256)) const u8 = @alignCast(points_bytes);
    const scalars_aligned: []align(@alignOf(msm.Scalar)) const u8 = @alignCast(scalars_bytes);

    const points = std.mem.bytesAsSlice(msm.P256, points_aligned);
    const scalars = std.mem.bytesAsSlice(msm.Scalar, scalars_aligned);

    const result = msm.msm(points, scalars);

    const out = out_ptr[0..@sizeOf(msm.P256)];
    @memcpy(out, std.mem.asBytes(&result));
    return 0;
}

/// MSM using affine coordinates.
/// `points_ptr` -> `count * size_of_affine()` bytes
/// `scalars_ptr` -> `count * size_of_scalar()` bytes
/// `out_ptr` -> `size_of_p256()` bytes for result
export fn msm_affine_compute(points_ptr: [*]const u8, scalars_ptr: [*]const u8, count: usize, out_ptr: [*]u8) i32 {
    const points_bytes = points_ptr[0..count * @sizeOf(msm.AffineCoordinates)];
    const scalars_bytes = scalars_ptr[0..count * @sizeOf(msm.Scalar)];

    const points_aligned: []align(@alignOf(msm.AffineCoordinates)) const u8 = @alignCast(points_bytes);
    const scalars_aligned: []align(@alignOf(msm.Scalar)) const u8 = @alignCast(scalars_bytes);

    const points = std.mem.bytesAsSlice(msm.AffineCoordinates, points_aligned);
    const scalars = std.mem.bytesAsSlice(msm.Scalar, scalars_aligned);

    const result = msm.msmAffine(points, scalars);

    const out = out_ptr[0..@sizeOf(msm.P256)];
    @memcpy(out, std.mem.asBytes(&result));
    return 0;
}

/// Naive O(N) MSM for verification: sum(point_i * scalar_i)
export fn naive_msm(points_ptr: [*]const u8, scalars_ptr: [*]const u8, count: usize, out_ptr: [*]u8) i32 {
    const points_bytes = points_ptr[0..count * @sizeOf(msm.P256)];
    const scalars_bytes = scalars_ptr[0..count * @sizeOf(msm.Scalar)];

    const points_aligned: []align(@alignOf(msm.P256)) const u8 = @alignCast(points_bytes);
    const scalars_aligned: []align(@alignOf(msm.Scalar)) const u8 = @alignCast(scalars_bytes);

    const points = std.mem.bytesAsSlice(msm.P256, points_aligned);
    const scalars = std.mem.bytesAsSlice(msm.Scalar, scalars_aligned);

    var acc = msm.P256.identityElement;
    for (points, scalars) |p, s| {
        acc = acc.add(p.mul(s, .little) catch return -1);
    }

    const out = out_ptr[0..@sizeOf(msm.P256)];
    @memcpy(out, std.mem.asBytes(&acc));
    return 0;
}

/// Return 1 if two projective points are equivalent, 0 otherwise.
export fn points_equivalent(a_ptr: [*]const u8, b_ptr: [*]const u8) i32 {
    const a = std.mem.bytesToValue(msm.P256, a_ptr[0..@sizeOf(msm.P256)]);
    const b = std.mem.bytesToValue(msm.P256, b_ptr[0..@sizeOf(msm.P256)]);
    return if (a.equivalent(b)) 1 else 0;
}

// Size helpers for JS side
export fn size_of_p256() usize { return @sizeOf(msm.P256); }
export fn size_of_affine() usize { return @sizeOf(msm.AffineCoordinates); }
export fn size_of_scalar() usize { return @sizeOf(msm.Scalar); }
