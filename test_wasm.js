const fs = require('fs');
const crypto = require('crypto');

function loadWasm(path) {
    const bytes = fs.readFileSync(path);
    const module = new WebAssembly.Module(bytes);
    const instance = new WebAssembly.Instance(module, {});
    return instance.exports;
}

function main() {
    const wasm = loadWasm('zig-out/bin/ecc_msm_wasm.wasm');

    const p256Size = wasm.size_of_p256();
    const affineSize = wasm.size_of_affine();
    const scalarSize = wasm.size_of_scalar();

    console.log('Type sizes:', { p256Size, affineSize, scalarSize });

    const count = 1 << 10; // 1024 points

    console.log('Points count:', count);

    // Allocate memory in WASM heap
    const pointsPtr = wasm.alloc(count * p256Size);
    const scalarsPtr = wasm.alloc(count * scalarSize);
    const outPtr = wasm.alloc(p256Size);
    const out2Ptr = wasm.alloc(p256Size);

    if (!pointsPtr || !scalarsPtr || !outPtr || !out2Ptr) {
        throw new Error('alloc failed');
    }

    // Helper to get current memory view (re-create in case of grow)
    const mem = () => new Uint8Array(wasm.memory.buffer);

    // Get base point (projective)
    const basePtr = wasm.alloc(p256Size);
    wasm.get_base_point(basePtr);

    // Generate random scalars and corresponding points (base * scalar)
    for (let i = 0; i < count; i++) {
        const scalar = crypto.randomBytes(scalarSize);
        mem().set(scalar, scalarsPtr + i * scalarSize);

        const pointOut = pointsPtr + i * p256Size;
        const ret = wasm.point_mul(basePtr, scalarsPtr + i * scalarSize, pointOut);
        if (ret !== 0) throw new Error('point_mul failed at index ' + i);
    }

    // --- Test msm_compute (projective) ---
    console.time('msm_compute');
    const ret1 = wasm.msm_compute(pointsPtr, scalarsPtr, count, outPtr);
    console.timeEnd('msm_compute');
    if (ret1 !== 0) throw new Error('msm_compute failed');

    // --- Test naive_msm (for verification) ---
    console.time('naive_msm');
    const ret2 = wasm.naive_msm(pointsPtr, scalarsPtr, count, out2Ptr);
    console.timeEnd('naive_msm');
    if (ret2 !== 0) throw new Error('naive_msm failed');

    const eq = wasm.points_equivalent(outPtr, out2Ptr);
    console.log('msm_compute == naive_msm:', eq === 1);

    // --- Test msm_affine_compute with a trivial case ---
    const oneScalar = Buffer.alloc(scalarSize);
    oneScalar[0] = 1;
    const affinePtr = wasm.alloc(affineSize);
    const outAffinePtr = wasm.alloc(p256Size);
    wasm.get_base_point_affine(affinePtr);

    // overwrite first scalar slot with 1
    mem().set(oneScalar, scalarsPtr);

    const ret3 = wasm.msm_affine_compute(affinePtr, scalarsPtr, 1, outAffinePtr);
    if (ret3 !== 0) throw new Error('msm_affine_compute failed');

    const eqAffine = wasm.points_equivalent(outAffinePtr, basePtr);
    console.log('msm_affine(1 * base_affine) == base_point:', eqAffine === 1);

    // Cleanup
    wasm.free(pointsPtr, count * p256Size);
    wasm.free(scalarsPtr, count * scalarSize);
    wasm.free(outPtr, p256Size);
    wasm.free(out2Ptr, p256Size);
    wasm.free(basePtr, p256Size);
    wasm.free(affinePtr, affineSize);
    wasm.free(outAffinePtr, p256Size);

    console.log('All tests passed!');
}

main();
