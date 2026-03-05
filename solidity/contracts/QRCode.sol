/*
 * QR Code generator library (Solidity)
 *
 * Copyright (c) Project Nayuki. (MIT License)
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
 * This implementation is modeled after the C port in the same repository.
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
     *
     *   text       : UTF-8 text to encode (no NUL bytes)
     *   ecl        : Error correction level (ECC_LOW .. ECC_HIGH)
     *   minVersion : Minimum QR version to try (1..40)
     *   maxVersion : Maximum QR version to try (minVersion..40)
     *   mask       : Mask pattern (MASK_0..MASK_7) or MASK_AUTO for automatic selection
     *   boostEcl   : When true, may upgrade the ECC level if the version doesn't increase
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
        // Find the minimal version and optionally boost ECC level.
        // Uses a nested scope so intermediate locals are freed before _buildQrCode,
        // keeping the EVM stack depth below 16.
        uint8 version;
        uint8 finalEcl;
        {
            bool found;
            uint dataUsedBits;
            (found, version, dataUsedBits) = _findMinVersion(segs, ecl, minVersion, maxVersion);
            if (!found) {
                bytes memory empty = new bytes(1);
                return empty;  // qrcode[0] == 0 signals failure
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
     * Every byte of `digits` must be an ASCII digit ('0'–'9').
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
     * Valid characters: 0–9, A–Z (uppercase only), space, $, %, *, +, -, ., /, :
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
     * Returns true iff every byte in text is an ASCII decimal digit (0x30–0x39).
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
     * (0–9, A–Z, space, $, %, *, +, -, ., /, :)
     */
    function isAlphanumericBytes(bytes memory text) internal pure returns (bool) {
        for (uint i = 0; i < text.length; i++) {
            (bool ok,) = _alphanumericCharIndex(uint8(text[i]));
            if (!ok) return false;
        }
        return true;
    }

    /*
     * Returns the number of bytes needed for a segment data buffer containing
     * numChars characters in the given mode. Returns type(uint).max on overflow.
     */
    function calcSegmentBufferSize(uint8 mode, uint numChars) internal pure returns (uint) {
        int temp = _calcSegmentBitLength(mode, numChars);
        if (temp == LENGTH_OVERFLOW) return type(uint).max;
        return (uint(temp) + 7) / 8;
    }


    /*======== Private: core encode pipeline ========*/

    // Builds the QR Code symbol from already-determined version and ECC level.
    // Split from encodeSegmentsAdvanced to keep stack depth within the EVM 16-slot limit.
    function _buildQrCode(
        Segment[] memory segs,
        uint8 version,
        uint8 ecl,
        uint8 mask
    ) private pure returns (bytes memory) {
        uint bufLen = bufferLenForVersion(version);
        bytes memory qrcode     = new bytes(bufLen);
        bytes memory tempBuffer = new bytes(bufLen);

        // 1. Encode all segment bits into qrcode (used as raw data buffer here)
        uint bitLen = _appendSegmentBits(segs, version, qrcode);

        // 2. Add terminator bits and padding bytes to reach data capacity
        bitLen = _addTerminatorAndPad(qrcode, bitLen, version, ecl);

        // 3. Compute ECC and interleave all codewords into tempBuffer
        _addEccAndInterleave(qrcode, version, ecl, tempBuffer);

        // 4. Re-initialise qrcode as a QR module grid (all function modules marked dark)
        _initializeFunctionModules(version, qrcode);

        // 5. Draw the interleaved codeword bits into the non-function modules
        _drawCodewords(tempBuffer, _getNumRawDataModules(version) / 8, qrcode);

        // 6. Draw the light (white) portions of the function modules
        _drawLightFunctionModules(qrcode, version);

        // 7. Re-initialise tempBuffer as the function-module mask for the masking step
        _initializeFunctionModules(version, tempBuffer);

        // 8. Select and apply the mask pattern; draw final format bits
        if (mask == MASK_AUTO)
            mask = _chooseBestMask(tempBuffer, qrcode, ecl);
        _applyMask(tempBuffer, qrcode, mask);
        _drawFormatBits(ecl, mask, qrcode);

        return qrcode;
    }

    // Finds the smallest version in [minVersion, maxVersion] that fits the segments
    // at the given ECC level.  Returns (false,0,0) if none fits.
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

    // Optionally boosts the ECC level to the highest that still fits in `version`.
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

    // Writes all segment header+data bits into `qrcode`. Returns total bits written.
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

    // Appends the terminator sequence, zero-pads to the next byte boundary, then
    // pads with alternating 0xEC/0x11 bytes to fill the data capacity.
    // Returns the new bitLen (always a multiple of 8).
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

    // Computes ECC for each data block and interleaves all blocks into `result`.
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

    // Computes ECC for one block and copies data + ECC bytes to the correct
    // interleaved positions in `result`.
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

    // Number of 8-bit data codewords for the given version and ECC level.
    function _getNumDataCodewords(uint8 version, uint8 ecl) private pure returns (uint) {
        return _getNumRawDataModules(version) / 8
            - _eccCodewordsPerBlock(ecl, version) * _numErrCorrBlocks(ecl, version);
    }

    // Total raw data module count (after excluding all function modules).
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

    // Returns the RS generator polynomial of the given degree.
    function _reedSolomonComputeDivisor(uint degree) private pure returns (bytes memory result) {
        require(degree >= 1 && degree <= 30, "QRCode: RS degree out of range");
        result = new bytes(degree);
        result[degree - 1] = 0x01;  // Start with the monomial x^0

        uint8 root = 1;
        for (uint i = 0; i < degree; i++) {
            for (uint j = 0; j < degree; j++) {
                result[j] = bytes1(_reedSolomonMultiply(uint8(result[j]), root));
                if (j + 1 < degree)
                    result[j] = bytes1(uint8(result[j]) ^ uint8(result[j + 1]));
            }
            root = _reedSolomonMultiply(root, 0x02);
        }
    }

    // Returns the RS remainder of data[offset..offset+dataLen-1] divided by the generator.
    function _reedSolomonComputeRemainder(
        bytes memory data,
        uint  dataOffset,
        uint  dataLen,
        bytes memory generator,
        uint  degree
    ) private pure returns (bytes memory result) {
        result = new bytes(degree);
        for (uint i = 0; i < dataLen; i++) {
            uint8 factor = uint8(data[dataOffset + i]) ^ uint8(result[0]);
            for (uint k = 0; k + 1 < degree; k++)
                result[k] = result[k + 1];
            result[degree - 1] = 0x00;
            for (uint j = 0; j < degree; j++)
                result[j] = bytes1(uint8(result[j]) ^ _reedSolomonMultiply(uint8(generator[j]), factor));
        }
    }

    // Returns the product of two GF(2^8) elements modulo the irreducible polynomial 0x11D.
    // Uses Russian-peasant multiplication — same algorithm as the C implementation.
    function _reedSolomonMultiply(uint8 x, uint8 y) private pure returns (uint8 z) {
        z = 0;
        for (int i = 7; i >= 0; i--) {
            z = uint8((uint(z) << 1) ^ ((uint(z) >> 7) * 0x11D));
            if (((y >> uint(i)) & 1) != 0) z ^= x;
        }
    }


    /*======== Private: Function module drawing ========*/

    // Zeros qrcode, sets qrcode[0] = size, then marks all function modules dark.
    function _initializeFunctionModules(uint8 version, bytes memory qrcode) private pure {
        uint qrsize = uint(version) * 4 + 17;
        for (uint i = 0; i < qrcode.length; i++) qrcode[i] = 0x00;
        qrcode[0] = bytes1(uint8(qrsize));

        // Timing patterns
        _fillRectangle(6, 0, 1, qrsize, qrcode);
        _fillRectangle(0, 6, qrsize, 1, qrcode);

        // Finder patterns and format bit areas (all three corners)
        _fillRectangle(0,          0,          9, 9, qrcode);
        _fillRectangle(qrsize - 8, 0,          8, 9, qrcode);
        _fillRectangle(0,          qrsize - 8, 9, 8, qrcode);

        // Alignment patterns
        {
            (bytes memory pos, uint n) = _getAlignmentPatternPositions(version);
            for (uint i = 0; i < n; i++) {
                for (uint j = 0; j < n; j++) {
                    // Skip the three finder-pattern corners
                    if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0))
                        continue;
                    _fillRectangle(uint8(pos[i]) - 2, uint8(pos[j]) - 2, 5, 5, qrcode);
                }
            }
        }

        // Version information blocks (only for version >= 7)
        if (version >= 7) {
            _fillRectangle(qrsize - 11, 0,          3, 6, qrcode);
            _fillRectangle(0,           qrsize - 11, 6, 3, qrcode);
        }
    }

    // Draws the light (white) function modules over the dark ones set by
    // _initializeFunctionModules: timing gap modules, finder separators,
    // alignment pattern interiors, and version information bits.
    function _drawLightFunctionModules(bytes memory qrcode, uint8 version) private pure {
        uint qrsize = uint(version) * 4 + 17;

        // Timing pattern: every other module starting at index 7
        {
            uint i = 7;
            while (i < qrsize - 7) {
                _setModuleBounded(qrcode, 6, i, false);
                _setModuleBounded(qrcode, i, 6, false);
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
                    _setModuleUnbounded(qrcode, int(3) + dx,           int(3) + dy,           false);
                    _setModuleUnbounded(qrcode, int(qrsize) - 4 + dx,  int(3) + dy,           false);
                    _setModuleUnbounded(qrcode, int(3) + dx,           int(qrsize) - 4 + dy,  false);
                }
            }
        }

        // Alignment pattern interiors (1-module rings around each centre)
        {
            (bytes memory ap, uint n) = _getAlignmentPatternPositions(version);
            for (uint i = 0; i < n; i++) {
                for (uint j = 0; j < n; j++) {
                    if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0))
                        continue;
                    for (int dy2 = -1; dy2 <= 1; dy2++) {
                        for (int dx2 = -1; dx2 <= 1; dx2++) {
                            _setModuleBounded(qrcode,
                                uint(int(uint(uint8(ap[i]))) + dx2),
                                uint(int(uint(uint8(ap[j]))) + dy2),
                                dx2 == 0 && dy2 == 0);
                        }
                    }
                }
            }
        }

        // Version information modules (only for version >= 7)
        if (version >= 7) {
            uint rem = version;
            for (uint i = 0; i < 12; i++)
                rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
            uint bits = (uint(version) << 12) | rem;

            for (uint i = 0; i < 6; i++) {
                for (uint j = 0; j < 3; j++) {
                    uint p = qrsize - 11 + j;
                    _setModuleBounded(qrcode, p, i, (bits & 1) != 0);
                    _setModuleBounded(qrcode, i, p, (bits & 1) != 0);
                    bits >>= 1;
                }
            }
        }
    }

    // Draws two copies of the 15-bit format information (including its own ECC).
    function _drawFormatBits(uint8 ecl, uint8 mask, bytes memory qrcode) private pure {
        // Remap ECC level: LOW→1, MEDIUM→0, QUARTILE→3, HIGH→2
        uint8[4] memory table;
        table[0] = 1;  table[1] = 0;  table[2] = 3;  table[3] = 2;
        uint data = (uint(table[ecl]) << 3) | uint(mask);
        uint rem  = data;
        for (uint i = 0; i < 10; i++)
            rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        uint bits = (data << 10 | rem) ^ 0x5412;

        // First copy (around the top-left finder)
        for (uint i = 0; i <= 5; i++) _setModuleBounded(qrcode, 8, i, _getBit(bits, i));
        _setModuleBounded(qrcode, 8, 7, _getBit(bits, 6));
        _setModuleBounded(qrcode, 8, 8, _getBit(bits, 7));
        _setModuleBounded(qrcode, 7, 8, _getBit(bits, 8));
        for (uint i = 9; i < 15; i++) _setModuleBounded(qrcode, 14 - i, 8, _getBit(bits, i));

        // Second copy (top-right and bottom-left finders)
        uint qrsize = uint8(qrcode[0]);
        for (uint i = 0; i < 8; i++)  _setModuleBounded(qrcode, qrsize - 1 - i, 8, _getBit(bits, i));
        for (uint i = 8; i < 15; i++) _setModuleBounded(qrcode, 8, qrsize - 15 + i, _getBit(bits, i));
        _setModuleBounded(qrcode, 8, qrsize - 8, true);  // Always dark
    }

    // Returns the sorted list of alignment pattern centre positions for `version`.
    // result[0..numAlign-1] are the positions; the same list is used for x and y.
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
        result[0] = 0x06;  // Always 6
    }

    // Sets all modules in [left, left+width) × [top, top+height) to dark.
    function _fillRectangle(uint left, uint top, uint width, uint height, bytes memory qrcode) private pure {
        for (uint dy = 0; dy < height; dy++)
            for (uint dx = 0; dx < width; dx++)
                _setModuleBounded(qrcode, left + dx, top + dy, true);
    }


    /*======== Private: Codeword drawing and masking ========*/

    // Writes packed codewords into the non-function modules using the QR zigzag scan.
    function _drawCodewords(bytes memory data, uint dataLen, bytes memory qrcode) private pure {
        uint qrsize = uint8(qrcode[0]);
        uint idx    = 0;

        uint right = qrsize - 1;
        while (right >= 1) {
            if (right == 6) right = 5;
            for (uint vert = 0; vert < qrsize; vert++) {
                for (uint j = 0; j < 2; j++) {
                    uint x      = right - j;
                    bool upward = ((right + 1) & 2) == 0;
                    uint y      = upward ? qrsize - 1 - vert : vert;
                    if (!_getModuleBounded(qrcode, x, y) && idx < dataLen * 8) {
                        bool dark = _getBit(uint8(data[idx >> 3]), 7 - (idx & 7));
                        _setModuleBounded(qrcode, x, y, dark);
                        idx++;
                    }
                }
            }
            if (right < 2) break;  // prevent uint underflow
            right -= 2;
        }
    }

    // XORs every non-function module with the given mask pattern.
    // Calling this twice with the same mask undoes the operation (XOR is self-inverse).
    function _applyMask(bytes memory functionModules, bytes memory qrcode, uint8 mask) private pure {
        uint qrsize = uint8(qrcode[0]);
        for (uint y = 0; y < qrsize; y++) {
            for (uint x = 0; x < qrsize; x++) {
                if (_getModuleBounded(functionModules, x, y)) continue;
                bool inv;
                if      (mask == 0) inv = (x + y) % 2 == 0;
                else if (mask == 1) inv = y % 2 == 0;
                else if (mask == 2) inv = x % 3 == 0;
                else if (mask == 3) inv = (x + y) % 3 == 0;
                else if (mask == 4) inv = (x / 3 + y / 2) % 2 == 0;
                else if (mask == 5) inv = x * y % 2 + x * y % 3 == 0;
                else if (mask == 6) inv = (x * y % 2 + x * y % 3) % 2 == 0;
                else                inv = ((x + y) % 2 + x * y % 3) % 2 == 0;
                _setModuleBounded(qrcode, x, y, _getModuleBounded(qrcode, x, y) != inv);
            }
        }
    }

    // Evaluates all 8 mask patterns and returns the index with the lowest penalty.
    function _chooseBestMask(
        bytes memory functionModules,
        bytes memory qrcode,
        uint8 ecl
    ) private pure returns (uint8 bestMask) {
        uint minPenalty = type(uint).max;
        for (uint8 i = 0; i < 8; i++) {
            _applyMask(functionModules, qrcode, i);
            _drawFormatBits(ecl, i, qrcode);
            uint penalty = _getPenaltyScore(qrcode);
            if (penalty < minPenalty) {
                bestMask   = i;
                minPenalty = penalty;
            }
            _applyMask(functionModules, qrcode, i);  // Undo via XOR
        }
    }

    // Computes the penalty score for the current QR Code state (lower is better).
    function _getPenaltyScore(bytes memory qrcode) private pure returns (uint result) {
        uint qrsize = uint8(qrcode[0]);
        result = 0;

        // N1 + N3: runs of same colour in rows, and finder-like patterns
        for (uint y = 0; y < qrsize; y++) result += _penaltyLine(qrcode, y, qrsize, false);
        // N1 + N3: same in columns
        for (uint x = 0; x < qrsize; x++) result += _penaltyLine(qrcode, x, qrsize, true);

        // N2: 2×2 blocks of same colour
        for (uint y = 0; y < qrsize - 1; y++) {
            for (uint x = 0; x < qrsize - 1; x++) {
                bool color = _getModuleBounded(qrcode, x, y);
                if (color == _getModuleBounded(qrcode, x + 1, y) &&
                    color == _getModuleBounded(qrcode, x,     y + 1) &&
                    color == _getModuleBounded(qrcode, x + 1, y + 1))
                    result += PENALTY_N2;
            }
        }

        // N4: dark/light balance
        uint dark = 0;
        for (uint y = 0; y < qrsize; y++)
            for (uint x = 0; x < qrsize; x++)
                if (_getModuleBounded(qrcode, x, y)) dark++;
        uint total    = qrsize * qrsize;
        uint darkDiff = dark * 20 >= total * 10 ? dark * 20 - total * 10 : total * 10 - dark * 20;
        uint c        = (darkDiff + total - 1) / total;
        uint k        = c > 0 ? c - 1 : 0;
        result += k * PENALTY_N4;
    }

    // Accumulates N1 + N3 penalty for one row (isCol=false) or column (isCol=true).
    function _penaltyLine(bytes memory qrcode, uint lineIdx, uint qrsize, bool isCol)
        private pure returns (uint score)
    {
        bool runColor = false;
        uint runLen   = 0;
        uint[7] memory history;
        score = 0;

        for (uint pos = 0; pos < qrsize; pos++) {
            bool cur = isCol
                ? _getModuleBounded(qrcode, lineIdx, pos)
                : _getModuleBounded(qrcode, pos, lineIdx);
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
        if (h[0] == 0) runLen += qrsize;  // virtual light border at line start
        h[6] = h[5];  h[5] = h[4];  h[4] = h[3];
        h[3] = h[2];  h[2] = h[1];  h[1] = h[0];
        h[0] = runLen;
    }


    /*======== Private: Module access ========*/

    // Returns the colour of module (x, y). Coordinates must be in bounds.
    function _getModuleBounded(bytes memory qrcode, uint x, uint y) private pure returns (bool) {
        uint qrsize = uint8(qrcode[0]);
        uint index  = y * qrsize + x;
        return ((uint8(qrcode[(index >> 3) + 1]) >> (index & 7)) & 1) != 0;
    }

    // Sets module (x, y) to dark or light. Coordinates must be in bounds.
    function _setModuleBounded(bytes memory qrcode, uint x, uint y, bool isDark) private pure {
        uint qrsize  = uint8(qrcode[0]);
        uint index   = y * qrsize + x;
        uint bitPos  = index & 7;
        uint bytePos = (index >> 3) + 1;
        if (isDark)
            qrcode[bytePos] = bytes1(uint8(qrcode[bytePos]) |  uint8(1 << bitPos));
        else
            qrcode[bytePos] = bytes1(uint8(qrcode[bytePos]) & uint8(0xFF ^ (1 << bitPos)));
    }

    // Sets module (x, y) if in bounds; does nothing if x or y is negative or out of range.
    function _setModuleUnbounded(bytes memory qrcode, int x, int y, bool isDark) private pure {
        uint qrsize = uint8(qrcode[0]);
        if (x >= 0 && x < int(qrsize) && y >= 0 && y < int(qrsize))
            _setModuleBounded(qrcode, uint(x), uint(y), isDark);
    }

    // Returns true iff bit i of x is set.
    function _getBit(uint x, uint i) private pure returns (bool) {
        return ((x >> i) & 1) != 0;
    }


    /*======== Private: Segment bit-length calculations ========*/

    // Returns the number of data bits for a segment, or LENGTH_OVERFLOW on failure.
    function _calcSegmentBitLength(uint8 mode, uint numChars) private pure returns (int) {
        if (numChars > 32767) return LENGTH_OVERFLOW;
        int result = int(numChars);
        if      (mode == MODE_NUMERIC)                 result = (result * 10 + 2) / 3;
        else if (mode == MODE_ALPHANUMERIC)            result = (result * 11 + 1) / 2;
        else if (mode == MODE_BYTE)                    result *= 8;
        else if (mode == MODE_KANJI)                   result *= 13;
        else if (mode == MODE_ECI && numChars == 0)    result = 3 * 8;
        else                                           return LENGTH_OVERFLOW;
        if (result > 32767) return LENGTH_OVERFLOW;
        return result;
    }

    // Returns the total encoded bit length of all segments at the given version,
    // or LENGTH_OVERFLOW if any segment overflows its character-count field or
    // the total exceeds 32767.
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

    // Returns the width (in bits) of the character-count field for the given mode and version.
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

    // Appends `numBits` bits from val (MSB first) to buffer starting at bit position bitLen.
    // Returns the updated bit length. Requires numBits <= 16 and val < 2^numBits.
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

    // Returns (true, index) if c is in the alphanumeric charset, else (false, 0).
    // Charset: 0–9 → 0–9, A–Z → 10–35, ' '→36, '$'→37, '%'→38, '*'→39,
    //          '+'→40, '-'→41, '.'→42, '/'→43, ':'→44
    function _alphanumericCharIndex(uint8 c) private pure returns (bool, uint) {
        if (c >= 0x30 && c <= 0x39) return (true, c - 0x30);       // '0'–'9'
        if (c >= 0x41 && c <= 0x5A) return (true, c - 0x41 + 10);  // 'A'–'Z'
        if (c == 0x20) return (true, 36);  // ' '
        if (c == 0x24) return (true, 37);  // '$'
        if (c == 0x25) return (true, 38);  // '%'
        if (c == 0x2A) return (true, 39);  // '*'
        if (c == 0x2B) return (true, 40);  // '+'
        if (c == 0x2D) return (true, 41);  // '-'
        if (c == 0x2E) return (true, 42);  // '.'
        if (c == 0x2F) return (true, 43);  // '/'
        if (c == 0x3A) return (true, 44);  // ':'
        return (false, 0);
    }


    /*======== Private: Lookup tables ========*/

    /*
     * ECC codewords per block, indexed by [ecl][version].
     * Index 0 of each row is unused (version 0 does not exist) and stored as 0xFF.
     * Hex literals encode the 41-byte table for each ECC level directly from the
     * QR Code specification.
     */
    function _eccCodewordsPerBlock(uint8 ecl, uint8 version) private pure returns (uint8) {
        // Low      : versions 0-40 (index 0 = 0xFF sentinel)
        bytes memory LOW      = hex"ff070a0f141a1214181e1214181a1e16181c1e1c1c1c1c1e1e1a1c1e1e1e1e1e1e1e1e1e1e1e1e1e1e";
        bytes memory MEDIUM   = hex"ff0a101a1218101216161a1e161618181c1c1a1a1a1a1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c";
        bytes memory QUARTILE = hex"ff0d16121a1218121614181c1a18141e181c1c1a1e1c1e1e1e1e1c1e1e1e1e1e1e1e1e1e1e1e1e1e1e";
        bytes memory HIGH     = hex"ff111c1610161c1a1a181c181c1618181e1c1c1a1c1e181e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e";
        if (ecl == ECC_LOW)      return uint8(LOW[version]);
        if (ecl == ECC_MEDIUM)   return uint8(MEDIUM[version]);
        if (ecl == ECC_QUARTILE) return uint8(QUARTILE[version]);
        return uint8(HIGH[version]);
    }

    /*
     * Number of error-correction blocks, indexed by [ecl][version].
     * Index 0 is unused and stored as 0xFF.
     */
    function _numErrCorrBlocks(uint8 ecl, uint8 version) private pure returns (uint8) {
        bytes memory LOW      = hex"ff01010101010202020204040404040606060607080809090a0c0c0c0d0e0f10111213131415161819";
        bytes memory MEDIUM   = hex"ff01010102020404040505050809090a0a0b0d0e10111112141517191a1c1d1f21232526282b2d2f31";
        bytes memory QUARTILE = hex"ff01010202040406060808080a0c100c11101215141717191b1d22222326282b2d303335383b3e4144";
        bytes memory HIGH     = hex"ff010102040404050608080b0b101012101315191919221e202325282a2d303336393c3f42464a4d51";
        if (ecl == ECC_LOW)      return uint8(LOW[version]);
        if (ecl == ECC_MEDIUM)   return uint8(MEDIUM[version]);
        if (ecl == ECC_QUARTILE) return uint8(QUARTILE[version]);
        return uint8(HIGH[version]);
    }

}
