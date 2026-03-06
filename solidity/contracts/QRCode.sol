/*
 * QR Code generator library (Solidity)
 *
 * Solidity port and EVM optimizations copyright (c) trifle-labs contributors.
 * Based on the C implementation by Project Nayuki (MIT License).
 * https://www.nayuki.io/page/qr-code-generator-library
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 * - The above copyright notice and this permission notice shall be included in
 *   all copies or substantial portions of the Software.
 * - The Software is provided "as is", without warranty of any kind, express or
 *   implied, including but not limited to the warranties of merchantability,
 *   fitness for a particular purpose and noninfringement. In no event shall the
 *   authors or copyright holders be liable for any claim, damages or other
 *   liability, whether in an action of contract, tort or otherwise, arising from,
 *   out of or in connection with the Software or the use or other dealings in the
 *   Software.
 */

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
 * This library creates QR Code symbols, which is a type of two-dimensional barcode.
 * Invented by Denso Wave and described in the ISO/IEC 18004 standard.
 * A QR Code structure is an immutable square grid of dark and light cells.
 * The library provides functions to create a QR Code from text or binary data.
 * The library covers the QR Code Model 2 specification, supporting all versions (sizes)
 * from 1 to 40, all 4 error correction levels, and 4 character encoding modes.
 *
 * Ways to create a QR Code:
 * - High level: Take the payload data and call encodeText() or encodeBinary().
 * - Low level: Custom-make the list of segments and call
 *   encodeSegments() or encodeSegmentsAdvanced().
 *
 * Output format — the returned bytes value:
 *   qrcode[0]   : side length of the QR Code in modules (e.g. 21 for version 1)
 *   qrcode[1..] : packed module bits, row-major order.
 *                 Module at (x, y) is at bit index y*size + x, stored in byte at
 *                 index (y*size + x)/8 + 1, at bit position (y*size + x) % 8 (LSB=0).
 *                 A set bit means a dark (black) module.
 * An invalid/failed encoding is represented as bytes of length 1 with qrcode[0] == 0.
 *
 * Gas optimisations over the C-port baseline:
 *   1. Pre-computed lookup tables (GF256 log/exp, alphanumeric map, ECC tables) stored
 *      as `bytes constant` so they live in bytecode and never allocate heap memory.
 *   2. Internal module grid represented as uint256[] rows (one uint256 per row) so
 *      every module read/write is a single bit-shift instead of a multiply + byte index.
 *      All-column operations (mask application, rectangle fill) work on whole rows.
 *   3. Yul inline assembly for the Reed-Solomon remainder inner loop and for the
 *      vectorised penalty-scoring (N2 2x2 block check and N4 dark-module count).
 */
library QRCode {

    /*---- Error correction level constants ----*/

    uint8 internal constant ECC_LOW      = 0;  // ~7%  error tolerance
    uint8 internal constant ECC_MEDIUM   = 1;  // ~15% error tolerance
    uint8 internal constant ECC_QUARTILE = 2;  // ~25% error tolerance
    uint8 internal constant ECC_HIGH     = 3;  // ~30% error tolerance

    /*---- Mask pattern constants ----*/

    uint8 internal constant MASK_AUTO = 0xFF;  // Library selects the best mask
    uint8 internal constant MASK_0    = 0;
    uint8 internal constant MASK_1    = 1;
    uint8 internal constant MASK_2    = 2;
    uint8 internal constant MASK_3    = 3;
    uint8 internal constant MASK_4    = 4;
    uint8 internal constant MASK_5    = 5;
    uint8 internal constant MASK_6    = 6;
    uint8 internal constant MASK_7    = 7;

    /*---- Segment mode constants ----*/

    uint8 internal constant MODE_NUMERIC      = 0x1;
    uint8 internal constant MODE_ALPHANUMERIC = 0x2;
    uint8 internal constant MODE_BYTE         = 0x4;
    uint8 internal constant MODE_KANJI        = 0x8;
    uint8 internal constant MODE_ECI          = 0x7;

    /*---- Version range ----*/

    uint8 internal constant VERSION_MIN = 1;
    uint8 internal constant VERSION_MAX = 40;

    /*---- Penalty score constants (used by auto mask selection) ----*/

    uint internal constant PENALTY_N1 =  3;
    uint internal constant PENALTY_N2 =  3;
    uint internal constant PENALTY_N3 = 40;
    uint internal constant PENALTY_N4 = 10;

    // Sentinel returned by _calcSegmentBitLength/_getTotalBits on overflow
    int internal constant LENGTH_OVERFLOW = type(int256).min;


    /*======== Pre-computed lookup tables (stored in bytecode, zero heap allocation) ========*/

    /*
     * GF(2^8) exponentiation table over polynomial 0x11D: GF256_EXP[i] = 2^i.
     * 256 bytes.  Replaces the 8-iteration Russian-peasant multiply with 3 lookups.
     */
    bytes private constant GF256_EXP =
        hex"01020408102040801d3a74e8cd8713264c982d5ab475eac98f03060c183060c0"
        hex"9d274e9c254a94356ad4b577eec19f23468c050a142850a05dba69d2b96fdea1"
        hex"5fbe61c2992f5ebc65ca890f1e3c78f0fde7d3bb6bd6b17ffee1dfa35bb671e2"
        hex"d9af4386112244880d1a3468d0bd67ce811f3e7cf8edc7933b76ecc5973366cc"
        hex"85172e5cb86ddaa94f9e214284152a54a84d9a2952a455aa49923972e4d5b773"
        hex"e6d1bf63c6913f7efce5d7b37bf6f1ffe3dbab4b963162c495376edca557ae41"
        hex"82193264c88d070e1c3870e0dda753a651a259b279f2f9efc39b2b56ac458a09"
        hex"122448903d7af4f5f7f3fbebcb8b0b162c58b07dfae9cf831b366cd8ad478e01";

    /*
     * GF(2^8) discrete-log table: GF256_LOG[x] = log_2(x) mod 0x11D.
     * GF256_LOG[0] is undefined; _gf256Mul guards against zero inputs.
     */
    bytes private constant GF256_LOG =
        hex"0000011902321ac603df33ee1b68c74b0464e00e348def811cc169f8c8084c71"
        hex"058a652fe1240f2135938edaf01282451db5c27d6a27f9b9c99a09784de472a6"
        hex"06bf8b6266dd30fde29825b31091228836d094ce8f96dbbdf1d2135c83384640"
        hex"1e42b6a3c3487e6e6b3a2854fa85ba3dca5e9b9f0a15792b4ed4e5ac73f3a757"
        hex"0770c0f78c80630d674adeed31c5fe18e3a5997726b8b47c114492d92320892e"
        hex"373fd15b95bccfcd908797b2dcfcbe61f256d3ab142a5d9e843c3953476d41a2"
        hex"1f2d43d8b77ba476c41749ec7f0c6ff66ca13b52299d55aafb6086b1bbcc3e5a"
        hex"cb595fb09ca9a0510bf516eb7a752cd74faed5e9e6e7ade874d6f4eaa85058af";

    /*
     * Alphanumeric character map, indexed by (c - 0x20) for c in [0x20, 0x5A].
     * Stored value = (QR alphanumeric index + 1), 0 = invalid character.
     * Reduces the original 11-branch if-else chain to two range checks + one read.
     */
    bytes private constant ALPHA_MAP =
        hex"250000002627000000002829002a2b2c0102030405060708090a2d"
        hex"0000000000000b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222324";

    /*
     * ECC codewords per block [version 0..40], one table per ECC level.
     * Index 0 = 0xFF sentinel.  `bytes constant` means bytecode storage,
     * no heap allocation per call (unlike the original function-local hex literals).
     */
    bytes private constant _ECPB_LOW  = hex"ff070a0f141a1214181e1214181a1e16181c1e1c1c1c1c1e1e1a1c1e1e1e1e1e1e1e1e1e1e1e1e1e1e";
    bytes private constant _ECPB_MED  = hex"ff0a101a1218101216161a1e161618181c1c1a1a1a1a1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c";
    bytes private constant _ECPB_QRT  = hex"ff0d16121a1218121614181c1a18141e181c1c1a1e1c1e1e1e1e1c1e1e1e1e1e1e1e1e1e1e1e1e1e1e";
    bytes private constant _ECPB_HIGH = hex"ff111c1610161c1a1a181c181c1618181e1c1c1a1c1e181e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e";

    /*
     * Number of error-correction blocks [version 0..40], one table per ECC level.
     */
    bytes private constant _NECB_LOW  = hex"ff01010101010202020204040404040606060607080809090a0c0c0c0d0e0f10111213131415161819";
    bytes private constant _NECB_MED  = hex"ff01010102020404040505050809090a0a0b0d0e10111112141517191a1c1d1f21232526282b2d2f31";
    bytes private constant _NECB_QRT  = hex"ff01010202040406060808080a0c100c11101215141717191b1d22222326282b2d303335383b3e4144";
    bytes private constant _NECB_HIGH = hex"ff010102040404050608080b0b101012101315191919221e202325282a2d303336393c3f42464a4d51";

    /*
     * Vectorised 256-bit mask-pattern constants.
     * Bit x is set iff column x satisfies the mask formula for that row category.
     * Verified against per-pixel formula for all qrsize values 1..177.
     */
    // Mask 0: (x+y)%2==0  — even row: even x; odd row: odd x
    uint256 private constant _MASK0_EVEN =
        0x5555555555555555555555555555555555555555555555555555555555555555;
    uint256 private constant _MASK0_ODD =
        0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    // Period-3 column patterns (masks 2, 3, 5, 6, 7)
    uint256 private constant _MP0 =  // x%3==0
        0x9249249249249249249249249249249249249249249249249249249249249249;
    uint256 private constant _MP1 =  // x%3==1
        0x2492492492492492492492492492492492492492492492492492492492492492;
    uint256 private constant _MP2 =  // x%3==2
        0x4924924924924924924924924924924924924924924924924924924924924924;
    // Period-6 column patterns (masks 4, 6, 7)
    uint256 private constant _MPA =  // x%6 in {0,1,2}
        0x71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c7;
    uint256 private constant _MPB =  // x%6 in {3,4,5}
        0x8e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38;
    uint256 private constant _MP6 =  // x%6==0 (mask 5)
        0x1041041041041041041041041041041041041041041041041041041041041041;
    uint256 private constant _MPC =  // x%6 in {0,4,5} (masks 6, 7)
        0x1c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71c71;
    uint256 private constant _MPD =  // x%6 in {1,2,3} (masks 6, 7)
        0xe38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e38e;


    /*---- Segment struct ----*/

    /*
     * A segment of character/binary/control data.
     *   mode      : One of the MODE_* constants above
     *   numChars  : Character count (bytes for MODE_BYTE, 0 for MODE_ECI)
     *   data      : Encoded data bits, packed in bitwise big-endian order
     *   bitLength : Number of valid data bits in `data`
     */
    struct Segment {
        uint8 mode;
        uint  numChars;
        bytes data;
        uint  bitLength;
    }


    /*---- Buffer length helper ----*/

    // Returns the number of bytes needed to store a QR Code of the given version.
    function bufferLenForVersion(uint ver) internal pure returns (uint) {
        return ((ver * 4 + 17) * (ver * 4 + 17) + 7) / 8 + 1;
    }


    /*======== High-level encoding API ========*/

    /*
     * Encodes the given text to a QR Code.
     * Returns bytes of length 1 with qrcode[0]==0 on failure (data too long).
     */
    function encodeText(
        string memory text,
        uint8  ecl,
        uint8  minVersion,
        uint8  maxVersion,
        uint8  mask,
        bool   boostEcl
    ) internal pure returns (bytes memory) {
        bytes memory tb = bytes(text);
        if (tb.length == 0)
            return encodeSegmentsAdvanced(new Segment[](0), ecl, minVersion, maxVersion, mask, boostEcl);

        Segment[] memory segs = new Segment[](1);
        if (isNumericBytes(tb))
            segs[0] = makeNumeric(tb);
        else if (isAlphanumericBytes(tb))
            segs[0] = makeAlphanumeric(tb);
        else
            segs[0] = makeBytes(tb);

        return encodeSegmentsAdvanced(segs, ecl, minVersion, maxVersion, mask, boostEcl);
    }

    /*
     * Encodes the given binary data to a QR Code using byte mode.
     * Returns bytes of length 1 with qrcode[0]==0 on failure.
     */
    function encodeBinary(
        bytes memory data,
        uint8 ecl,
        uint8 minVersion,
        uint8 maxVersion,
        uint8 mask,
        bool  boostEcl
    ) internal pure returns (bytes memory) {
        Segment[] memory segs = new Segment[](1);
        segs[0] = makeBytes(data);
        return encodeSegmentsAdvanced(segs, ecl, minVersion, maxVersion, mask, boostEcl);
    }


    /*======== Low-level encoding API ========*/

    /*
     * Encodes segments to a QR Code using sensible defaults:
     *   minVersion=1, maxVersion=40, mask=MASK_AUTO, boostEcl=true.
     */
    function encodeSegments(
        Segment[] memory segs,
        uint8 ecl
    ) internal pure returns (bytes memory) {
        return encodeSegmentsAdvanced(segs, ecl, VERSION_MIN, VERSION_MAX, MASK_AUTO, true);
    }

    /*
     * Encodes segments to a QR Code with full parameter control.
     * Returns bytes of length 1 with qrcode[0]==0 if the data does not fit.
     */
    function encodeSegmentsAdvanced(
        Segment[] memory segs,
        uint8 ecl,
        uint8 minVersion,
        uint8 maxVersion,
        uint8 mask,
        bool  boostEcl
    ) internal pure returns (bytes memory) {
        uint8 version;
        uint8 finalEcl;
        {
            bool found;
            uint dataUsedBits;
            (found, version, dataUsedBits) = _findMinVersion(segs, ecl, minVersion, maxVersion);
            if (!found) {
                bytes memory empty = new bytes(1);
                return empty;
            }
            finalEcl = _boostEccLevel(ecl, version, dataUsedBits, boostEcl);
        }
        return _buildQrCode(segs, version, finalEcl, mask);
    }


    /*======== Segment factory functions ========*/

    /*
     * Returns a segment representing the given binary data encoded in byte mode.
     */
    function makeBytes(bytes memory data) internal pure returns (Segment memory seg) {
        int bl = _calcSegmentBitLength(MODE_BYTE, data.length);
        require(bl != LENGTH_OVERFLOW, "QRCode: byte segment too long");
        seg.mode      = MODE_BYTE;
        seg.numChars  = data.length;
        seg.bitLength = uint(bl);
        seg.data      = data;
    }

    /*
     * Returns a segment representing the given string of decimal digits in numeric mode.
     */
    function makeNumeric(bytes memory digits) internal pure returns (Segment memory seg) {
        uint len = digits.length;
        int bl = _calcSegmentBitLength(MODE_NUMERIC, len);
        require(bl != LENGTH_OVERFLOW, "QRCode: numeric segment too long");
        seg.mode      = MODE_NUMERIC;
        seg.numChars  = len;
        seg.bitLength = 0;

        bytes memory buf = new bytes((uint(bl) + 7) / 8);
        uint accumData  = 0;
        uint accumCount = 0;
        for (uint i = 0; i < len; i++) {
            uint8 c = uint8(digits[i]);
            require(c >= 0x30 && c <= 0x39, "QRCode: non-digit in numeric segment");
            accumData  = accumData * 10 + uint(c - 0x30);
            accumCount++;
            if (accumCount == 3) {
                seg.bitLength = _appendBitsToBuffer(accumData, 10, buf, seg.bitLength);
                accumData  = 0;
                accumCount = 0;
            }
        }
        if (accumCount > 0)
            seg.bitLength = _appendBitsToBuffer(accumData, accumCount * 3 + 1, buf, seg.bitLength);
        seg.data = buf;
    }

    /*
     * Returns a segment representing the given text in alphanumeric mode.
     * Valid characters: 0-9, A-Z (uppercase only), space, $, %, *, +, -, ., /, :
     */
    function makeAlphanumeric(bytes memory text) internal pure returns (Segment memory seg) {
        uint len = text.length;
        int bl = _calcSegmentBitLength(MODE_ALPHANUMERIC, len);
        require(bl != LENGTH_OVERFLOW, "QRCode: alphanumeric segment too long");
        seg.mode      = MODE_ALPHANUMERIC;
        seg.numChars  = len;
        seg.bitLength = 0;

        bytes memory buf = new bytes((uint(bl) + 7) / 8);
        uint accumData  = 0;
        uint accumCount = 0;
        for (uint i = 0; i < len; i++) {
            (bool ok, uint idx) = _alphanumericCharIndex(uint8(text[i]));
            require(ok, "QRCode: invalid char in alphanumeric segment");
            accumData  = accumData * 45 + idx;
            accumCount++;
            if (accumCount == 2) {
                seg.bitLength = _appendBitsToBuffer(accumData, 11, buf, seg.bitLength);
                accumData  = 0;
                accumCount = 0;
            }
        }
        if (accumCount > 0)
            seg.bitLength = _appendBitsToBuffer(accumData, 6, buf, seg.bitLength);
        seg.data = buf;
    }

    /*
     * Returns a segment representing an Extended Channel Interpretation (ECI) designator.
     * assignVal must be in [0, 999999].
     */
    function makeEci(uint256 assignVal) internal pure returns (Segment memory seg) {
        require(assignVal < 1000000, "QRCode: ECI value out of range");
        seg.mode     = MODE_ECI;
        seg.numChars = 0;
        bytes memory buf;
        uint bl;
        if (assignVal < (1 << 7)) {
            buf = new bytes(1);
            bl  = _appendBitsToBuffer(assignVal, 8, buf, 0);
        } else if (assignVal < (1 << 14)) {
            buf = new bytes(2);
            bl  = _appendBitsToBuffer(2, 2, buf, 0);
            bl  = _appendBitsToBuffer(assignVal, 14, buf, bl);
        } else {
            buf = new bytes(3);
            bl  = _appendBitsToBuffer(6, 3, buf, 0);
            bl  = _appendBitsToBuffer(assignVal >> 10, 11, buf, bl);
            bl  = _appendBitsToBuffer(assignVal & 0x3FF, 10, buf, bl);
        }
        seg.bitLength = bl;
        seg.data      = buf;
    }


    /*======== QR Code output query functions ========*/

    /*
     * Returns the side length of the QR Code in modules.
     * Result is in [21, 177]. qrcode[0] must be nonzero (valid QR Code).
     */
    function getSize(bytes memory qrcode) internal pure returns (uint) {
        require(qrcode.length > 0 && uint8(qrcode[0]) != 0, "QRCode: invalid qrcode");
        return uint8(qrcode[0]);
    }

    /*
     * Returns true if and only if the module at coordinates (x, y) is dark.
     * Out-of-bounds coordinates return false (light).
     */
    function getModule(bytes memory qrcode, uint x, uint y) internal pure returns (bool) {
        uint qrsize = uint8(qrcode[0]);
        if (x >= qrsize || y >= qrsize) return false;
        return _getModuleBounded(qrcode, x, y);
    }


    /*======== Character set helpers ========*/

    /*
     * Returns true iff every byte in text is an ASCII decimal digit (0x30-0x39).
     */
    function isNumericBytes(bytes memory text) internal pure returns (bool) {
        for (uint i = 0; i < text.length; i++) {
            uint8 c = uint8(text[i]);
            if (c < 0x30 || c > 0x39) return false;
        }
        return true;
    }

    /*
     * Returns true iff every byte in text is a valid alphanumeric-mode character.
     */
    function isAlphanumericBytes(bytes memory text) internal pure returns (bool) {
        for (uint i = 0; i < text.length; i++) {
            (bool ok,) = _alphanumericCharIndex(uint8(text[i]));
            if (!ok) return false;
        }
        return true;
    }

    /*
     * Returns the number of bytes needed for a segment data buffer.
     * Returns type(uint).max on overflow.
     */
    function calcSegmentBufferSize(uint8 mode, uint numChars) internal pure returns (uint) {
        int temp = _calcSegmentBitLength(mode, numChars);
        if (temp == LENGTH_OVERFLOW) return type(uint).max;
        return (uint(temp) + 7) / 8;
    }


    /*======== Private: core encode pipeline ========*/

    /*
     * Builds the QR Code symbol from already-determined version and ECC level.
     *
     * The module grid is kept as uint256[] rows internally (bit x of rows[y] = module
     * at column x, row y).  This eliminates the y*size multiplication on every module
     * access and enables whole-row operations for rectangle fills, mask application,
     * and penalty scoring.  The grid is converted to the standard packed-bytes output
     * format only in the final _gridToBytes call.
     */
    function _buildQrCode(
        Segment[] memory segs,
        uint8 version,
        uint8 ecl,
        uint8 mask
    ) private pure returns (bytes memory) {
        uint qrsize = uint(version) * 4 + 17;
        uint bufLen = bufferLenForVersion(version);

        // Phase 1-2: encode segment bits, pad, compute ECC — all in packed bytes.
        bytes memory scratch = new bytes(bufLen);
        bytes memory eccBuf  = new bytes(bufLen);
        uint bitLen = _appendSegmentBits(segs, version, scratch);
        bitLen = _addTerminatorAndPad(scratch, bitLen, version, ecl);
        _addEccAndInterleave(scratch, version, ecl, eccBuf);

        // Phase 3: build and finalise the module grid as uint256[].
        uint256[] memory rows  = new uint256[](qrsize);
        uint256[] memory frows = new uint256[](qrsize);

        _initFuncModules(version, qrsize, rows);
        _drawCodewords(eccBuf, _getNumRawDataModules(version) / 8, qrsize, rows);
        _drawLightFuncModules(qrsize, version, rows);
        _initFuncModules(version, qrsize, frows);

        if (mask == MASK_AUTO)
            mask = _chooseBestMask(frows, rows, qrsize, ecl);
        _applyMask(frows, rows, qrsize, mask);
        _drawFormatBits(ecl, mask, qrsize, rows);

        return _gridToBytes(rows, qrsize);
    }

    function _findMinVersion(
        Segment[] memory segs,
        uint8 ecl,
        uint8 minVersion,
        uint8 maxVersion
    ) private pure returns (bool success, uint8 version, uint dataUsedBits) {
        for (version = minVersion; ; version++) {
            uint cap  = _getNumDataCodewords(version, ecl) * 8;
            int  bits = _getTotalBits(segs, version);
            if (bits >= 0 && uint(bits) <= cap) {
                dataUsedBits = uint(bits);
                return (true, version, dataUsedBits);
            }
            if (version >= maxVersion) return (false, 0, 0);
        }
    }

    function _boostEccLevel(
        uint8 ecl,
        uint8 version,
        uint  dataUsedBits,
        bool  boostEcl
    ) private pure returns (uint8) {
        if (!boostEcl) return ecl;
        for (uint8 i = ECC_MEDIUM; i <= ECC_HIGH; i++) {
            if (dataUsedBits <= _getNumDataCodewords(version, i) * 8)
                ecl = i;
        }
        return ecl;
    }

    function _appendSegmentBits(
        Segment[] memory segs,
        uint8 version,
        bytes memory qrcode
    ) private pure returns (uint bitLen) {
        bitLen = 0;
        for (uint i = 0; i < segs.length; i++) {
            Segment memory seg = segs[i];
            bitLen = _appendBitsToBuffer(uint(seg.mode), 4, qrcode, bitLen);
            bitLen = _appendBitsToBuffer(seg.numChars, _numCharCountBits(seg.mode, version), qrcode, bitLen);
            for (uint j = 0; j < seg.bitLength; j++) {
                uint bit = (uint8(seg.data[j >> 3]) >> (7 - (j & 7))) & 1;
                bitLen   = _appendBitsToBuffer(bit, 1, qrcode, bitLen);
            }
        }
    }

    function _addTerminatorAndPad(
        bytes memory qrcode,
        uint  bitLen,
        uint8 version,
        uint8 ecl
    ) private pure returns (uint) {
        uint cap  = _getNumDataCodewords(version, ecl) * 8;
        uint term = cap - bitLen;
        if (term > 4) term = 4;
        bitLen = _appendBitsToBuffer(0, term, qrcode, bitLen);
        bitLen = _appendBitsToBuffer(0, (8 - bitLen % 8) % 8, qrcode, bitLen);

        uint8 padByte = 0xEC;
        while (bitLen < cap) {
            bitLen  = _appendBitsToBuffer(padByte, 8, qrcode, bitLen);
            padByte = (padByte == 0xEC) ? 0x11 : 0xEC;
        }
        return bitLen;
    }


    /*======== Private: ECC computation and interleaving ========*/

    function _addEccAndInterleave(
        bytes memory data,
        uint8 version,
        uint8 ecl,
        bytes memory result
    ) private pure {
        uint numBlocks         = _numErrCorrBlocks(ecl, version);
        uint blockEccLen       = _eccCodewordsPerBlock(ecl, version);
        uint rawCodewords      = _getNumRawDataModules(version) / 8;
        uint dataLen           = _getNumDataCodewords(version, ecl);
        uint numShortBlocks    = numBlocks - rawCodewords % numBlocks;
        uint shortBlockDataLen = rawCodewords / numBlocks - blockEccLen;

        bytes memory rsdiv = _reedSolomonComputeDivisor(blockEccLen);
        uint datOffset = 0;

        for (uint i = 0; i < numBlocks; i++) {
            uint datLen = shortBlockDataLen + (i < numShortBlocks ? 0 : 1);
            _interleaveBlock(
                data, datOffset, datLen, rsdiv, blockEccLen,
                result, i, numBlocks, numShortBlocks, shortBlockDataLen, dataLen
            );
            datOffset += datLen;
        }
    }

    function _interleaveBlock(
        bytes memory data,
        uint  datOffset,
        uint  datLen,
        bytes memory rsdiv,
        uint  blockEccLen,
        bytes memory result,
        uint  blockIdx,
        uint  numBlocks,
        uint  numShortBlocks,
        uint  shortBlockDataLen,
        uint  dataLen
    ) private pure {
        bytes memory ecc = _reedSolomonComputeRemainder(data, datOffset, datLen, rsdiv, blockEccLen);

        for (uint j = 0; j < datLen; j++) {
            uint k = blockIdx + j * numBlocks;
            if (j >= shortBlockDataLen) k -= numShortBlocks;
            result[k] = data[datOffset + j];
        }
        for (uint j = 0; j < blockEccLen; j++)
            result[dataLen + blockIdx + j * numBlocks] = ecc[j];
    }

    function _getNumDataCodewords(uint8 version, uint8 ecl) private pure returns (uint) {
        return _getNumRawDataModules(version) / 8
            - _eccCodewordsPerBlock(ecl, version) * _numErrCorrBlocks(ecl, version);
    }

    function _getNumRawDataModules(uint8 version) private pure returns (uint) {
        uint v      = version;
        uint result = (16 * v + 128) * v + 64;
        if (v >= 2) {
            uint numAlign = v / 7 + 2;
            result -= (25 * numAlign - 10) * numAlign - 55;
            if (v >= 7) result -= 36;
        }
        return result;
    }


    /*======== Private: Reed-Solomon ECC ========*/

    /*
     * GF(2^8) multiply using the pre-computed log/exp constant tables.
     * Three table lookups replace the 8-iteration Russian-peasant loop.
     */
    function _gf256Mul(uint8 x, uint8 y) private pure returns (uint8 z) {
        if (x == 0 || y == 0) return 0;
        uint ix = uint8(GF256_LOG[x]);
        uint iy = uint8(GF256_LOG[y]);
        unchecked {
            uint s = ix + iy;
            if (s >= 255) s -= 255;
            z = uint8(GF256_EXP[s]);
        }
    }

    // Returns the RS generator polynomial of the given degree.
    function _reedSolomonComputeDivisor(uint degree) private pure returns (bytes memory result) {
        require(degree >= 1 && degree <= 30, "QRCode: RS degree out of range");
        result = new bytes(degree);
        result[degree - 1] = 0x01;

        uint8 root = 1;
        for (uint i = 0; i < degree; i++) {
            for (uint j = 0; j < degree; j++) {
                result[j] = bytes1(_gf256Mul(uint8(result[j]), root));
                if (j + 1 < degree)
                    result[j] = bytes1(uint8(result[j]) ^ uint8(result[j + 1]));
            }
            root = _gf256Mul(root, 0x02);
        }
    }

    /*
     * Computes the RS remainder of data[offset..offset+dataLen-1] divided by the generator.
     *
     * The inner loop runs in Yul assembly to eliminate per-byte bounds-check overhead
     * and to inline the GF(256) multiply directly from memory-resident log/exp tables,
     * avoiding Solidity function-call overhead on the hot multiply path.
     */
    function _reedSolomonComputeRemainder(
        bytes memory data,
        uint  dataOffset,
        uint  dataLen,
        bytes memory generator,
        uint  degree
    ) private pure returns (bytes memory result) {
        result = new bytes(degree);
        bytes memory expMem = GF256_EXP;  // load constants to memory once
        bytes memory logMem = GF256_LOG;
        assembly {
            let resPtr  := add(result,    0x20)
            let genPtr  := add(generator, 0x20)
            let datPtr  := add(add(data,  0x20), dataOffset)
            let expBase := add(expMem,    0x20)
            let logBase := add(logMem,    0x20)

            for { let i := 0 } lt(i, dataLen) { i := add(i, 1) } {
                // factor = data[i] XOR result[0]
                let factor := xor(byte(0, mload(datPtr)), byte(0, mload(resPtr)))
                datPtr := add(datPtr, 1)

                // Shift result left by 1; zero the last byte.
                let deg1 := sub(degree, 1)
                for { let k := 0 } lt(k, deg1) { k := add(k, 1) } {
                    mstore8(add(resPtr, k), byte(0, mload(add(resPtr, add(k, 1)))))
                }
                mstore8(add(resPtr, deg1), 0)

                // result[j] ^= gf256Mul(generator[j], factor)
                for { let j := 0 } lt(j, degree) { j := add(j, 1) } {
                    let g := byte(0, mload(add(genPtr, j)))
                    // mul(g, factor) is nonzero iff both g and factor are nonzero
                    // (each <= 255, product <= 65025, no 256-bit overflow).
                    if mul(g, factor) {
                        let lg   := byte(0, mload(add(logBase, g)))
                        let lf   := byte(0, mload(add(logBase, factor)))
                        let s    := add(lg, lf)
                        if gt(s, 254) { s := sub(s, 255) }
                        let prod := byte(0, mload(add(expBase, s)))
                        let addr := add(resPtr, j)
                        mstore8(addr, xor(byte(0, mload(addr)), prod))
                    }
                }
            }
        }
    }


    /*======== Private: Function module drawing (uint256[] grid) ========*/

    /*
     * Zeros rows[], then marks every function-module position as dark (bit set).
     * Grid convention: bit x of rows[y] = module (column x, row y).
     */
    function _initFuncModules(uint8 version, uint qrsize, uint256[] memory rows) private pure {
        // new uint256[] is already zero-initialised.

        // Timing patterns
        _fillRect(6, 0, 1, qrsize, rows);   // vertical:   col 6, all rows
        _fillRect(0, 6, qrsize, 1, rows);   // horizontal: row 6, all cols

        // Finder patterns + format bit areas
        _fillRect(0,          0,          9, 9, rows);
        _fillRect(qrsize - 8, 0,          8, 9, rows);
        _fillRect(0,          qrsize - 8, 9, 8, rows);

        // Alignment patterns
        {
            (bytes memory ap, uint n) = _getAlignmentPatternPositions(version);
            for (uint i = 0; i < n; i++) {
                for (uint j = 0; j < n; j++) {
                    if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0))
                        continue;
                    _fillRect(uint(uint8(ap[i])) - 2, uint(uint8(ap[j])) - 2, 5, 5, rows);
                }
            }
        }

        // Version information blocks (version >= 7)
        if (version >= 7) {
            _fillRect(qrsize - 11, 0,           3, 6, rows);
            _fillRect(0,           qrsize - 11, 6, 3, rows);
        }
    }

    /*
     * Draws the light (white) parts of the function modules: timing gaps, finder
     * separator rings, alignment pattern interiors, and version information bits.
     */
    function _drawLightFuncModules(uint qrsize, uint8 version, uint256[] memory rows) private pure {
        // Timing gap: every other module starting at index 7
        {
            uint i = 7;
            while (i < qrsize - 7) {
                _clearMod(rows, 6, i);
                _clearMod(rows, i, 6);
                i += 2;
            }
        }

        // Finder pattern separator rings (Chebyshev distance 2 and 4 from each center)
        for (int dy = -4; dy <= 4; dy++) {
            for (int dx = -4; dx <= 4; dx++) {
                int adx  = dx < 0 ? -dx : dx;
                int ady  = dy < 0 ? -dy : dy;
                int dist = adx > ady ? adx : ady;
                if (dist == 2 || dist == 4) {
                    _setModU(rows, qrsize, int(3) + dx,          int(3) + dy,          false);
                    _setModU(rows, qrsize, int(qrsize) - 4 + dx, int(3) + dy,          false);
                    _setModU(rows, qrsize, int(3) + dx,          int(qrsize) - 4 + dy, false);
                }
            }
        }

        // Alignment pattern interiors
        {
            (bytes memory ap, uint n) = _getAlignmentPatternPositions(version);
            for (uint i = 0; i < n; i++) {
                for (uint j = 0; j < n; j++) {
                    if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0))
                        continue;
                    for (int dy2 = -1; dy2 <= 1; dy2++) {
                        for (int dx2 = -1; dx2 <= 1; dx2++) {
                            _setMod(rows,
                                uint(int(uint(uint8(ap[i]))) + dx2),
                                uint(int(uint(uint8(ap[j]))) + dy2),
                                dx2 == 0 && dy2 == 0);
                        }
                    }
                }
            }
        }

        // Version information modules (version >= 7)
        if (version >= 7) {
            uint rem = version;
            for (uint i = 0; i < 12; i++)
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            uint bits = (uint(version) << 12) | rem;

            for (uint i = 0; i < 6; i++) {
                for (uint j = 0; j < 3; j++) {
                    uint p = qrsize - 11 + j;
                    _setMod(rows, p, i, (bits & 1) != 0);
                    _setMod(rows, i, p, (bits & 1) != 0);
                    bits >>= 1;
                }
            }
        }
    }

    // Draws two copies of the 15-bit format information (including its own ECC).
    function _drawFormatBits(uint8 ecl, uint8 mask, uint qrsize, uint256[] memory rows) private pure {
        // Remap ECC level: LOW->1, MEDIUM->0, QUARTILE->3, HIGH->2
        uint8[4] memory table;
        table[0] = 1;  table[1] = 0;  table[2] = 3;  table[3] = 2;
        uint data = (uint(table[ecl]) << 3) | uint(mask);
        uint rem  = data;
        for (uint i = 0; i < 10; i++)
            rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        uint bits = (data << 10 | rem) ^ 0x5412;

        // First copy (around the top-left finder)
        for (uint i = 0; i <= 5; i++) _setMod(rows, 8, i, _getBit(bits, i));
        _setMod(rows, 8, 7, _getBit(bits, 6));
        _setMod(rows, 8, 8, _getBit(bits, 7));
        _setMod(rows, 7, 8, _getBit(bits, 8));
        for (uint i = 9; i < 15; i++) _setMod(rows, 14 - i, 8, _getBit(bits, i));

        // Second copy (top-right and bottom-left finders)
        for (uint i = 0; i < 8; i++)  _setMod(rows, qrsize - 1 - i, 8, _getBit(bits, i));
        for (uint i = 8; i < 15; i++) _setMod(rows, 8, qrsize - 15 + i, _getBit(bits, i));
        _setMod(rows, 8, qrsize - 8, true);  // Always dark
    }

    // Returns the sorted list of alignment pattern centre positions for `version`.
    function _getAlignmentPatternPositions(uint8 version)
        private pure returns (bytes memory result, uint numAlign)
    {
        result = new bytes(7);
        if (version == 1) return (result, 0);
        numAlign = uint(version) / 7 + 2;
        uint step = ((uint(version) * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
        {
            uint pos = uint(version) * 4 + 10;
            uint i   = numAlign - 1;
            while (true) {
                result[i] = bytes1(uint8(pos));
                if (i == 1) break;
                i--;
                pos -= step;
            }
        }
        result[0] = 0x06;
    }

    /*
     * Sets all modules in [left, left+width) x [top, top+height) to dark.
     * Vectorised: computes a column bitmask and ORs it into each row word —
     * height OR operations instead of width*height individual bit sets.
     */
    function _fillRect(uint left, uint top, uint width, uint height, uint256[] memory rows) private pure {
        uint256 colBits = ((uint256(1) << width) - 1) << left;
        unchecked {
            for (uint dy = 0; dy < height; dy++)
                rows[top + dy] |= colBits;
        }
    }


    /*======== Private: Codeword drawing and masking ========*/

    function _drawCodewords(
        bytes memory data,
        uint  dataLen,
        uint  qrsize,
        uint256[] memory rows
    ) private pure {
        uint idx   = 0;
        uint right = qrsize - 1;
        while (right >= 1) {
            if (right == 6) right = 5;
            for (uint vert = 0; vert < qrsize; vert++) {
                for (uint j = 0; j < 2; j++) {
                    uint x      = right - j;
                    bool upward = ((right + 1) & 2) == 0;
                    uint y      = upward ? qrsize - 1 - vert : vert;
                    if (!_getMod(rows, x, y) && idx < dataLen * 8) {
                        bool dark = _getBit(uint8(data[idx >> 3]), 7 - (idx & 7));
                        _setMod(rows, x, y, dark);
                        idx++;
                    }
                }
            }
            if (right < 2) break;
            right -= 2;
        }
    }

    /*
     * XORs every non-function module with the given mask pattern.
     *
     * For each row y a 256-bit column-pattern is computed analytically from the
     * precomputed constants (O(1) per row for masks 0-4; same for masks 5-7 using
     * six (y%2, y%3) cases).  The pattern is ANDed with ~frows[y] to skip function
     * modules, then XORed into the row in a single word operation.
     */
    function _applyMask(
        uint256[] memory frows,
        uint256[] memory rows,
        uint qrsize,
        uint8 mask
    ) private pure {
        uint256 colMask = (uint256(1) << qrsize) - 1;
        for (uint y = 0; y < qrsize; y++) {
            uint256 pat = _maskRowPattern(mask, y);
            rows[y] ^= (pat & ~frows[y]) & colMask;
        }
    }

    /*
     * Returns the 256-bit column-inversion pattern for row y of the given mask.
     * Bit x is 1 iff the mask formula would invert module (x, y).
     */
    function _maskRowPattern(uint8 mask, uint y) private pure returns (uint256) {
        if (mask == 0) return (y & 1) == 0 ? _MASK0_EVEN : _MASK0_ODD;   // (x+y)%2==0
        if (mask == 1) return (y & 1) == 0 ? type(uint256).max : 0;       // y%2==0
        if (mask == 2) return _MP0;                                        // x%3==0
        if (mask == 3) {                                                   // (x+y)%3==0
            uint yr3 = y % 3;
            return yr3 == 0 ? _MP0 : yr3 == 1 ? _MP2 : _MP1;
        }
        if (mask == 4) return ((y >> 1) & 1) == 0 ? _MPA : _MPB;         // (x/3+y/2)%2==0

        // Masks 5-7: six (y%2, y%3) cases analytically derived.
        uint ym2 = y & 1;
        uint ym3 = y % 3;
        if (mask == 5) {  // x*y%2 + x*y%3 == 0  (i.e. x*y divisible by 6)
            if (ym2 == 0 && ym3 == 0) return type(uint256).max;
            if (ym2 == 0)             return _MP0;
            if (ym3 == 0)             return _MASK0_EVEN;
            return _MP6;
        }
        if (mask == 6) {  // (x*y%2 + x*y%3) % 2 == 0
            if (ym2 == 0 && ym3 == 0) return type(uint256).max;
            if (ym2 == 0 && ym3 == 1) return _MP0 | _MP2;
            if (ym2 == 0 && ym3 == 2) return _MP0 | _MP1;
            if (ym2 == 1 && ym3 == 0) return _MASK0_EVEN;
            if (ym2 == 1 && ym3 == 1) return _MPA;
            return _MPC;
        }
        // mask == 7: ((x+y)%2 + x*y%3) % 2 == 0
        if (ym2 == 0 && ym3 == 0) return _MASK0_EVEN;
        if (ym2 == 0 && ym3 == 1) return _MPA;
        if (ym2 == 0 && ym3 == 2) return _MPC;
        if (ym2 == 1 && ym3 == 0) return _MASK0_ODD;
        if (ym2 == 1 && ym3 == 1) return _MPB;
        return _MPD;
    }

    function _chooseBestMask(
        uint256[] memory frows,
        uint256[] memory rows,
        uint qrsize,
        uint8 ecl
    ) private pure returns (uint8 bestMask) {
        uint minPenalty = type(uint).max;
        for (uint8 i = 0; i < 8; i++) {
            _applyMask(frows, rows, qrsize, i);
            _drawFormatBits(ecl, i, qrsize, rows);
            uint penalty = _getPenaltyScore(rows, qrsize);
            if (penalty < minPenalty) {
                bestMask   = i;
                minPenalty = penalty;
            }
            _applyMask(frows, rows, qrsize, i);  // undo via XOR
        }
    }

    /*
     * Computes the QR Code penalty score (lower is better).
     *
     * N2 (2x2 same-colour blocks) and N4 (dark/light balance) use Yul popcount
     * on 256-bit row words, reducing O(n^2) module reads to O(n) word operations.
     * N1/N3 (run-length and finder patterns) use a per-module scan that reads from
     * a pre-loaded uint256 row word, eliminating the y*size multiplication.
     */
    function _getPenaltyScore(uint256[] memory rows, uint qrsize) private pure returns (uint result) {
        uint256 colMask = (uint256(1) << qrsize) - 1;
        uint256 blkMask = qrsize > 1 ? (uint256(1) << (qrsize - 1)) - 1 : 0;
        result = 0;

        // N1 + N3: row scans
        for (uint y = 0; y < qrsize; y++)
            result += _penaltyLine(rows[y] & colMask, qrsize);
        // N1 + N3: column scans
        for (uint x = 0; x < qrsize; x++)
            result += _penaltyCol(rows, x, qrsize);

        // N2 and N4 computed in Yul with vectorised 256-bit row operations.
        assembly {
            function popcnt64(u) -> c {
                u := sub(u, and(shr(1, u), 0x5555555555555555))
                u := add(and(u, 0x3333333333333333),
                         and(shr(2, u), 0x3333333333333333))
                u := and(add(u, shr(4, u)), 0x0f0f0f0f0f0f0f0f)
                c := shr(56, mul(u, 0x0101010101010101))
            }
            function popcnt256(v) -> cnt {
                cnt := add(
                    add(popcnt64(and(v, 0xffffffffffffffff)),
                        popcnt64(and(shr(64,  v), 0xffffffffffffffff))),
                    add(popcnt64(and(shr(128, v), 0xffffffffffffffff)),
                        popcnt64(shr(192, v))))
            }

            let rowsData  := add(rows, 0x20)
            let qrs       := qrsize
            let cm        := colMask
            let bm        := blkMask
            let darkTotal := 0

            // N4: popcount all rows to get total dark module count.
            for { let y := 0 } lt(y, qrs) { y := add(y, 1) } {
                let row := mload(add(rowsData, mul(y, 0x20)))
                darkTotal := add(darkTotal, popcnt256(and(row, cm)))
            }

            // N2: count 2x2 same-colour blocks over consecutive row pairs.
            //   For rows r0, r1:
            //     dark squares:  (r0 & (r0>>1)) & (r1 & (r1>>1))
            //     light squares: (~r0 & (~r0>>1)) & (~r1 & (~r1>>1))  [masked to colMask]
            let n2count := 0
            for { let y := 0 } lt(y, sub(qrs, 1)) { y := add(y, 1) } {
                let r0  := and(mload(add(rowsData, mul(y,           0x20))), cm)
                let r1  := and(mload(add(rowsData, mul(add(y, 1),   0x20))), cm)
                let d   := and(and(r0, shr(1, r0)), and(r1, shr(1, r1)))
                let nr0 := and(not(r0), cm)
                let nr1 := and(not(r1), cm)
                let l   := and(and(nr0, shr(1, nr0)), and(nr1, shr(1, nr1)))
                n2count := add(n2count, popcnt256(and(or(d, l), bm)))
            }

            // N4 penalty calculation
            let total    := mul(qrs, qrs)
            let darkDiff := 0
            let t20      := mul(darkTotal, 20)
            let base10   := mul(total, 10)
            switch gt(t20, base10)
            case 1 { darkDiff := sub(t20, base10) }
            default { darkDiff := sub(base10, t20) }
            let c_val := div(add(darkDiff, sub(total, 1)), total)
            let k_val := 0
            if gt(c_val, 0) { k_val := sub(c_val, 1) }

            result := add(result, add(mul(n2count, 3), mul(k_val, 10)))
        }
    }

    // N1+N3 penalty for one row (passed as a pre-loaded uint256 word).
    function _penaltyLine(uint256 rowBits, uint qrsize)
        private pure returns (uint score)
    {
        bool runColor = false;
        uint runLen   = 0;
        uint[7] memory history;
        score = 0;
        for (uint x = 0; x < qrsize; x++) {
            bool cur = ((rowBits >> x) & 1) != 0;
            if (cur == runColor) {
                runLen++;
                if (runLen == 5)     score += PENALTY_N1;
                else if (runLen > 5) score++;
            } else {
                _finderPenaltyAddHistory(runLen, history, qrsize);
                if (!runColor) score += _finderPenaltyCountPatterns(history) * PENALTY_N3;
                runColor = cur;
                runLen   = 1;
            }
        }
        score += _finderPenaltyTerminateAndCount(runColor, runLen, history, qrsize) * PENALTY_N3;
    }

    // N1+N3 penalty for column x (reads rows[y] bit x for each y).
    function _penaltyCol(uint256[] memory rows, uint x, uint qrsize)
        private pure returns (uint score)
    {
        bool runColor = false;
        uint runLen   = 0;
        uint[7] memory history;
        score = 0;
        uint256 xBit = uint256(1) << x;
        for (uint y = 0; y < qrsize; y++) {
            bool cur = (rows[y] & xBit) != 0;
            if (cur == runColor) {
                runLen++;
                if (runLen == 5)     score += PENALTY_N1;
                else if (runLen > 5) score++;
            } else {
                _finderPenaltyAddHistory(runLen, history, qrsize);
                if (!runColor) score += _finderPenaltyCountPatterns(history) * PENALTY_N3;
                runColor = cur;
                runLen   = 1;
            }
        }
        score += _finderPenaltyTerminateAndCount(runColor, runLen, history, qrsize) * PENALTY_N3;
    }

    function _finderPenaltyCountPatterns(uint[7] memory h) private pure returns (uint) {
        uint n    = h[1];
        bool core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
        uint cnt  = 0;
        if (core && h[0] >= n * 4 && h[6] >= n) cnt++;
        if (core && h[6] >= n * 4 && h[0] >= n) cnt++;
        return cnt;
    }

    function _finderPenaltyTerminateAndCount(
        bool  runColor,
        uint  runLen,
        uint[7] memory history,
        uint  qrsize
    ) private pure returns (uint) {
        if (runColor) {
            _finderPenaltyAddHistory(runLen, history, qrsize);
            runLen = 0;
        }
        runLen += qrsize;
        _finderPenaltyAddHistory(runLen, history, qrsize);
        return _finderPenaltyCountPatterns(history);
    }

    function _finderPenaltyAddHistory(uint runLen, uint[7] memory h, uint qrsize) private pure {
        if (h[0] == 0) runLen += qrsize;
        h[6] = h[5];  h[5] = h[4];  h[4] = h[3];
        h[3] = h[2];  h[2] = h[1];  h[1] = h[0];
        h[0] = runLen;
    }


    /*======== Private: Grid-to-bytes conversion ========*/

    /*
     * Converts the uint256[] row grid to the standard packed-bytes output format:
     *   out[0]   = qrsize
     *   out[1..] = module bits packed row-major, LSB-first within each byte.
     *
     * The Yul loop scans each row word once; only dark-module bits call mstore8.
     */
    function _gridToBytes(uint256[] memory rows, uint qrsize)
        private pure returns (bytes memory out)
    {
        uint bufLen = (qrsize * qrsize + 7) / 8 + 1;
        out = new bytes(bufLen);
        out[0] = bytes1(uint8(qrsize));
        assembly {
            // out[1] is the first module-data byte.
            // Memory layout: out -> length (32 bytes) -> out[0] (size) -> out[1..] (modules)
            let outModBase := add(out, 0x21)   // skip length word and size byte
            let rowsData   := add(rows, 0x20)
            let qrs        := qrsize

            for { let y := 0 } lt(y, qrs) { y := add(y, 1) } {
                let row      := mload(add(rowsData, mul(y, 0x20)))
                let bitStart := mul(y, qrs)

                for { let x := 0 } lt(x, qrs) { x := add(x, 1) } {
                    if and(shr(x, row), 1) {
                        let bi      := add(bitStart, x)
                        let byteIdx := shr(3, bi)
                        let bitOff  := and(bi, 7)
                        let addr    := add(outModBase, byteIdx)
                        mstore8(addr, or(byte(0, mload(addr)), shl(bitOff, 1)))
                    }
                }
            }
        }
    }


    /*======== Private: uint256 grid module helpers ========*/

    function _setMod(uint256[] memory rows, uint x, uint y, bool dark) private pure {
        if (dark)
            rows[y] |=  (uint256(1) << x);
        else
            rows[y] &= ~(uint256(1) << x);
    }

    function _clearMod(uint256[] memory rows, uint x, uint y) private pure {
        rows[y] &= ~(uint256(1) << x);
    }

    function _getMod(uint256[] memory rows, uint x, uint y) private pure returns (bool) {
        return (rows[y] >> x) & 1 != 0;
    }

    // Bounded set: silently ignores out-of-range coordinates.
    function _setModU(uint256[] memory rows, uint qrsize, int x, int y, bool dark) private pure {
        if (x >= 0 && x < int(qrsize) && y >= 0 && y < int(qrsize))
            _setMod(rows, uint(x), uint(y), dark);
    }


    /*======== Private: Packed-bytes module access (used by getModule only) ========*/

    function _getModuleBounded(bytes memory qrcode, uint x, uint y) private pure returns (bool) {
        uint qrsize = uint8(qrcode[0]);
        uint index  = y * qrsize + x;
        return ((uint8(qrcode[(index >> 3) + 1]) >> (index & 7)) & 1) != 0;
    }

    function _getBit(uint x, uint i) private pure returns (bool) {
        return ((x >> i) & 1) != 0;
    }


    /*======== Private: Segment bit-length calculations ========*/

    function _calcSegmentBitLength(uint8 mode, uint numChars) private pure returns (int) {
        if (numChars > 32767) return LENGTH_OVERFLOW;
        int result = int(numChars);
        if      (mode == MODE_NUMERIC)              result = (result * 10 + 2) / 3;
        else if (mode == MODE_ALPHANUMERIC)         result = (result * 11 + 1) / 2;
        else if (mode == MODE_BYTE)                 result *= 8;
        else if (mode == MODE_KANJI)                result *= 13;
        else if (mode == MODE_ECI && numChars == 0) result = 3 * 8;
        else                                        return LENGTH_OVERFLOW;
        if (result > 32767) return LENGTH_OVERFLOW;
        return result;
    }

    function _getTotalBits(Segment[] memory segs, uint8 version) private pure returns (int) {
        int result = 0;
        for (uint i = 0; i < segs.length; i++) {
            uint ccbits = _numCharCountBits(segs[i].mode, version);
            if (segs[i].numChars >= (1 << ccbits)) return LENGTH_OVERFLOW;
            result += int(4 + ccbits + segs[i].bitLength);
            if (result > 32767) return LENGTH_OVERFLOW;
        }
        return result;
    }

    function _numCharCountBits(uint8 mode, uint8 version) private pure returns (uint) {
        uint i = (uint(version) + 7) / 17;  // 0 for v1–9, 1 for v10–26, 2 for v27–40
        if (mode == MODE_NUMERIC)      { if (i == 0) return 10; if (i == 1) return 12; return 14; }
        if (mode == MODE_ALPHANUMERIC) { if (i == 0) return 9;  if (i == 1) return 11; return 13; }
        if (mode == MODE_BYTE)         { if (i == 0) return 8;  return 16; }
        if (mode == MODE_KANJI)        { if (i == 0) return 8;  if (i == 1) return 10; return 12; }
        if (mode == MODE_ECI)          return 0;
        revert("QRCode: invalid mode");
    }


    /*======== Private: Bit buffer ========*/

    function _appendBitsToBuffer(uint val, uint numBits, bytes memory buffer, uint bitLen)
        private pure returns (uint)
    {
        for (int i = int(numBits) - 1; i >= 0; i--) {
            if (((val >> uint(i)) & 1) != 0) {
                uint byteIdx = bitLen >> 3;
                uint bitIdx  = 7 - (bitLen & 7);
                buffer[byteIdx] = bytes1(uint8(buffer[byteIdx]) | uint8(1 << bitIdx));
            }
            bitLen++;
        }
        return bitLen;
    }


    /*======== Private: Alphanumeric character lookup ========*/

    /*
     * Returns (true, index) if c is in the QR alphanumeric charset, else (false, 0).
     * Uses the pre-computed ALPHA_MAP constant: two range checks + one table lookup,
     * replacing the original 11-branch if-else chain.
     */
    function _alphanumericCharIndex(uint8 c) private pure returns (bool, uint) {
        if (c < 0x20 || c > 0x5A) return (false, 0);
        uint8 v = uint8(ALPHA_MAP[c - 0x20]);
        if (v == 0) return (false, 0);
        return (true, uint(v) - 1);
    }


    /*======== Private: ECC codeword lookup tables ========*/

    function _eccCodewordsPerBlock(uint8 ecl, uint8 version) private pure returns (uint8) {
        if (ecl == ECC_LOW)      return uint8(_ECPB_LOW[version]);
        if (ecl == ECC_MEDIUM)   return uint8(_ECPB_MED[version]);
        if (ecl == ECC_QUARTILE) return uint8(_ECPB_QRT[version]);
        return uint8(_ECPB_HIGH[version]);
    }

    function _numErrCorrBlocks(uint8 ecl, uint8 version) private pure returns (uint8) {
        if (ecl == ECC_LOW)      return uint8(_NECB_LOW[version]);
        if (ecl == ECC_MEDIUM)   return uint8(_NECB_MED[version]);
        if (ecl == ECC_QUARTILE) return uint8(_NECB_QRT[version]);
        return uint8(_NECB_HIGH[version]);
    }

}
