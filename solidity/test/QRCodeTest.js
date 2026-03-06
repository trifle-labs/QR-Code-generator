/*
 * QR Code generator test suite (Solidity)
 *
 * Deploys QRCodeDemo to a local Hardhat network and validates the output of
 * every demo function against known-good values produced by the C reference
 * implementation in this repository.
 *
 * Run with:  npx hardhat test
 *       or:  npm test
 *
 * Gas note: On-chain QR Code generation for small inputs costs 3–9 million gas.
 * Auto-mask selection evaluates all 8 mask patterns and can exceed Hardhat's
 * default per-transaction gas cap (16 777 216 gas, `FUSAKA_TRANSACTION_GAS_LIMIT`
 * in hardhat/src/internal/constants.ts). The fixed-mask demo functions
 * (doBasicDemoFixedMask, doNumericDemoFixedMask, etc.) are provided specifically
 * to allow byte-exact comparison against the C reference output without triggering
 * the 8-pass auto-mask penalty scoring.
 *
 * The expected byte strings were obtained by compiling and running the C reference
 * implementation (c/qrcodegen.c) with identical parameters.
 */

import { expect } from "chai";
import hre from "hardhat";

// ---------------------------------------------------------------------------
// Utility: read a single module from raw QR Code bytes (JS-side helper)
// ---------------------------------------------------------------------------
function getModule(buf, x, y) {
    const size    = buf[0];
    if (x < 0 || x >= size || y < 0 || y >= size) return false;
    const index   = y * size + x;
    const byteIdx = (index >> 3) + 1;   // +1 because buf[0] is the size
    const bitIdx  = index & 7;
    return ((buf[byteIdx] >> bitIdx) & 1) !== 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function hexToBytes(hex) {
    const h = hex.startsWith("0x") ? hex.slice(2) : hex;
    return Buffer.from(h, "hex");
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------
describe("QRCode library", function () {

    let demo;

    before(async function () {
        const Demo = await hre.ethers.getContractFactory("QRCodeDemo");
        demo = await Demo.deploy();
        await demo.waitForDeployment();
    });


    // -----------------------------------------------------------------------
    // 1. Byte-for-byte comparison against C reference output
    //    (all use explicit fixed masks to stay within the ~16 M gas cap)
    // -----------------------------------------------------------------------

    it("'Hello, world!' ECC_LOW MASK_2 matches C reference", async function () {
        // C: qrcodegen_encodeText("Hello, world!", …, Ecc_LOW, 1, 40, Mask_2, true)
        // MASK_AUTO also selects mask 2 for this input (verified with C reference).
        const expected = "157fd03f48097675ddaea0db3575839ee05ff50728007dce0733e622dd39535eb3170d01c2c79f3d0baa755d7bb9ab70747d93209af3b79400";
        const qr = await demo.doBasicDemoFixedMask();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("50-digit π string ECC_MEDIUM MASK_3 matches C reference", async function () {
        // MASK_AUTO also selects mask 3 for this input (verified with C reference).
        const expected = "197f41fc83ea0a7611d7eddaa9db254f3748a2e05f557f805c00edcaa4617a999dd9898804a9aaad4452e225bb57d5dcc4bb4fcc2fbf006a23fd7d540aba8ad6a5fbbb6ba668d7eead20c1617fd14e01";
        const qr = await demo.doNumericDemoFixedMask();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("version-5 HIGH MASK_2 no-boost matches C reference", async function () {
        const expected = "257f6508cf3f68a7ef0b76d55b29dd2e744aa6db45deac748376fdbee05f5555f507a8bfda005ce991fd9c56ef6a79bb0b047f44571c56f6bd2fdcd60729a7e6d607fb4ef64f6d0de054fc70fa2cadfe0049104b434d6803d3564d9e3aa5a6151aa557908cc828520456b6cbd5f0e92f5e4ab1c06ae47eee8f7667cc18ba8e62973892567445bf00e64f32f61fc408d60de234ab085d4516f1b52bb7cf93765dfcded820496061fe874add2601";
        const qr = await demo.doVersionConstraintDemo();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("'https://www.nayuki.io/' ECC_HIGH MASK_3 matches C reference", async function () {
        const expected = "1d7f90d53fc8bc0b76c951dd2ee7afdb55aa7483a0b0e05f55f507987000cc016961224f2cbe770339c40188488dcbeb3b9591ad9c95ee96c5f9dbcdfbb45bc469d014f35c0b1057f52b9e4cdf015630f65ffc560b229c085d60f7b76b01e175c556c220cab8f5a7c48b00";
        const qr = await demo.doFixedMaskDemo();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("binary 'Hello, world!' ECC_MEDIUM MASK_0 matches C reference", async function () {
        const expected = "157fd63f680a7669dd2eacdb557583ace05ff507e000550869272153c1fe024274661100b2db1f4c0f62045dbda88bb77565d42086f4d78801";
        const qr = await demo.doBinaryDemoFixedMask();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("mixed alphanumeric+numeric segment ECC_LOW MASK_0 matches C reference", async function () {
        const expected = "1d7fc4cd3f68280b76e104dd2ea0acdb75d87583809de05f55f507b0a00055e00849c1cc499d5da07ccf6115830593916751f86e70bc0e548c7038efad85dd322d311707051055dd499ec7645f012e2cca1fc9d50fc29c285d15f4ad8bb19d75955ede202034fe37173401";
        const qr = await demo.doSegmentDemoFixedMask();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });

    it("ECI(26)+UTF-8 bytes ECC_MEDIUM MASK_0 matches C reference", async function () {
        const expected = "157fc93f88097609ddaea3db657583ace05ff507c000742df291a763e1e7504154374201c6df1fe30eaaf15d53a48bfb748dc720ccfa07ea01";
        const qr = await demo.doEciDemoFixedMask();
        expect(hexToBytes(qr).toString("hex")).to.equal(expected);
    });


    // -----------------------------------------------------------------------
    // 2. Size / structural invariants for fixed-mask functions
    // -----------------------------------------------------------------------

    it("doBasicDemoFixedMask: size is 21 modules (version 1)", async function () {
        const qr   = await demo.doBasicDemoFixedMask();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(21);
    });

    it("doNumericDemoFixedMask: size is 25 modules (version 2)", async function () {
        const qr   = await demo.doNumericDemoFixedMask();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(25);
    });

    it("doVersionConstraintDemo: size is 37 modules (version 5)", async function () {
        const qr   = await demo.doVersionConstraintDemo();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(37);
    });

    it("doFixedMaskDemo: size is 29 modules (version 3)", async function () {
        const qr   = await demo.doFixedMaskDemo();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(29);
    });

    it("doSegmentDemoFixedMask: size is 29 modules (version 3)", async function () {
        const qr   = await demo.doSegmentDemoFixedMask();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(29);
    });

    it("doEciDemoFixedMask: size is 21 modules (version 1)", async function () {
        const qr   = await demo.doEciDemoFixedMask();
        const size = hexToBytes(qr)[0];
        expect(size).to.equal(21);
    });


    // -----------------------------------------------------------------------
    // 3. Buffer-length invariant: length == 1 + ceil(size² / 8)
    // -----------------------------------------------------------------------

    const lengthCheckCases = [
        ["doBasicDemoFixedMask",    (d) => d.doBasicDemoFixedMask()],
        ["doNumericDemoFixedMask",  (d) => d.doNumericDemoFixedMask()],
        ["doVersionConstraintDemo", (d) => d.doVersionConstraintDemo()],
        ["doFixedMaskDemo",         (d) => d.doFixedMaskDemo()],
        ["doSegmentDemoFixedMask",  (d) => d.doSegmentDemoFixedMask()],
        ["doEciDemoFixedMask",      (d) => d.doEciDemoFixedMask()],
    ];

    for (const [name, fn] of lengthCheckCases) {
        it(`${name}: buffer length equals 1 + ceil(size² / 8)`, async function () {
            const qr       = await fn(demo);
            const buf      = hexToBytes(qr);
            const size     = buf[0];
            const expected = 1 + Math.ceil(size * size / 8);
            expect(buf.length).to.equal(expected);
        });
    }


    // -----------------------------------------------------------------------
    // 4. Finder-pattern module checks (version 1, top-left corner)
    // -----------------------------------------------------------------------

    it("finder pattern: outer corners dark, separator ring light, centre dark", async function () {
        const qr  = await demo.doBasicDemoFixedMask();
        const buf = hexToBytes(qr);

        // Top-left finder outer corners must be dark
        expect(getModule(buf, 0, 0)).to.be.true;
        expect(getModule(buf, 6, 0)).to.be.true;
        expect(getModule(buf, 0, 6)).to.be.true;
        expect(getModule(buf, 6, 6)).to.be.true;

        // Inner dark 3×3 centre
        expect(getModule(buf, 3, 3)).to.be.true;

        // Separator ring (Chebyshev distance 2 from centre (3,3)) must be light
        expect(getModule(buf, 1, 1)).to.be.false;
        expect(getModule(buf, 5, 1)).to.be.false;
        expect(getModule(buf, 1, 5)).to.be.false;
        expect(getModule(buf, 5, 5)).to.be.false;
    });


    // -----------------------------------------------------------------------
    // 5. Determinism: calling the same function twice gives the same output
    // -----------------------------------------------------------------------

    it("encodeText is deterministic", async function () {
        const qr1 = await demo.doBasicDemoFixedMask();
        const qr2 = await demo.doBasicDemoFixedMask();
        expect(qr1).to.equal(qr2);
    });


    // -----------------------------------------------------------------------
    // 6. SVG output
    // -----------------------------------------------------------------------

    it("toSvgString returns well-formed SVG", async function () {
        const qr  = await demo.doBasicDemoFixedMask();
        const svg = await demo.toSvgString(qr, 4);
        expect(svg).to.include('<svg');
        expect(svg).to.include('</svg>');
        expect(svg).to.include('fill="#000000"');
        expect(svg).to.include('fill="#FFFFFF"');
        // viewBox = size + 2*border = 21 + 8 = 29
        expect(svg).to.include('viewBox="0 0 29 29"');
    });

});
