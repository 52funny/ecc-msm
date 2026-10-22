const fs = require('fs');
const crypto = require('crypto');

function loadWasm(path) {
    const bytes = fs.readFileSync(path);
    const module = new WebAssembly.Module(bytes);
    const instance = new WebAssembly.Instance(module, {});
    return instance.exports;
}

function bench(count, wasm) {
    const p256Size = wasm.size_of_p256();
    const scalarSize = wasm.size_of_scalar();

    const pointsPtr = wasm.alloc(count * p256Size);
    const scalarsPtr = wasm.alloc(count * scalarSize);
    const outMsm = wasm.alloc(p256Size);
    const outNaive = wasm.alloc(p256Size);

    const mem = () => new Uint8Array(wasm.memory.buffer);

    const basePtr = wasm.alloc(p256Size);
    wasm.get_base_point(basePtr);

    for (let i = 0; i < count; i++) {
        const scalar = crypto.randomBytes(scalarSize);
        mem().set(scalar, scalarsPtr + i * scalarSize);
        wasm.point_mul(basePtr, scalarsPtr + i * scalarSize, pointsPtr + i * p256Size);
    }

    // Warm-up
    wasm.msm_compute(pointsPtr, scalarsPtr, count, outMsm);
    wasm.naive_msm(pointsPtr, scalarsPtr, count, outNaive);

    const runs = 10;
    let msmTotal = 0;
    let naiveTotal = 0;

    for (let r = 0; r < runs; r++) {
        const t0 = performance.now();
        wasm.msm_compute(pointsPtr, scalarsPtr, count, outMsm);
        const t1 = performance.now();
        wasm.naive_msm(pointsPtr, scalarsPtr, count, outNaive);
        const t2 = performance.now();
        msmTotal += (t1 - t0);
        naiveTotal += (t2 - t1);
    }

    const eq = wasm.points_equivalent(outMsm, outNaive);

    wasm.free(pointsPtr, count * p256Size);
    wasm.free(scalarsPtr, count * scalarSize);
    wasm.free(outMsm, p256Size);
    wasm.free(outNaive, p256Size);
    wasm.free(basePtr, p256Size);

    return {
        count,
        msmAvg: (msmTotal / runs).toFixed(2),
        naiveAvg: (naiveTotal / runs).toFixed(2),
        match: eq === 1,
    };
}

function main() {
    const wasm = loadWasm('zig-out/bin/ecc_msm_wasm.wasm');
    console.log('Benchmarking WASM MSM vs Naive...\n');

    const sizes = [8, 16, 32, 64, 128, 256, 512, 1024, 2048];
    for (const n of sizes) {
        const r = bench(n, wasm);
        const speedup = (parseFloat(r.naiveAvg) / parseFloat(r.msmAvg)).toFixed(2);
        console.log(
            `N=${String(n).padStart(4)}  msm=${r.msmAvg.padStart(8)}ms  naive=${r.naiveAvg.padStart(8)}ms  ` +
            `speedup=${speedup}x  match=${r.match}`
        );
    }
}

main();
