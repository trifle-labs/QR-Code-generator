/*
 * QR Code generator demo (Solidity)
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

import "./QRCode.sol";

/*
 * A demo contract that exercises the QRCode library.
 *
 * All public functions are pure (no state) and return the raw QR Code bytes.
 * Callers can inspect individual modules with QRCode.getModule() or render the
 * symbol off-chain.  See the Readme.markdown for the output format.
 *
 * toSvgString() shows how to render a QR Code to an inline SVG string entirely
 * on-chain — useful for NFT metadata or other on-chain display.
 */
contract QRCodeDemo {

    // -----------------------------------------------------------------------
    // Demo scenarios
    // -----------------------------------------------------------------------

    // Simple: encode "Hello, world!" with Low ECC, automatic mask.
    function doBasicDemo() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "Hello, world!",
            QRCode.ECC_LOW,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_AUTO,
            true
        );
    }

    // Same as doBasicDemo() but forces mask 2 (the mask AUTO selects for this input).
    // Useful for testing when on-chain gas limits prohibit the 8-pass auto-mask scan.
    function doBasicDemoFixedMask() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "Hello, world!",
            QRCode.ECC_LOW,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_2,
            true
        );
    }

    // Numeric mode: digits are encoded with 3.33 bits per digit.
    function doNumericDemo() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "314159265358979323846264338327950288419716939937510",
            QRCode.ECC_MEDIUM,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_AUTO,
            true
        );
    }

    // Same as doNumericDemo() but forces mask 3 (the mask AUTO selects for this input).
    // Useful for testing when on-chain gas limits prohibit the 8-pass auto-mask scan.
    function doNumericDemoFixedMask() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "314159265358979323846264338327950288419716939937510",
            QRCode.ECC_MEDIUM,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_3,
            true
        );
    }

    // Alphanumeric mode: uppercase + special chars at 5.5 bits per character.
    function doAlphanumericDemo() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "DOLLAR-AMOUNT:$39.87 PERCENTAGE:100.00% OPERATIONS:+-*/",
            QRCode.ECC_HIGH,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_AUTO,
            true
        );
    }

    // Same as doAlphanumericDemo() but forces mask 0.
    // Useful for testing when on-chain gas limits prohibit the 8-pass auto-mask scan.
    function doAlphanumericDemoFixedMask() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "DOLLAR-AMOUNT:$39.87 PERCENTAGE:100.00% OPERATIONS:+-*/",
            QRCode.ECC_HIGH,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_0,
            true
        );
    }

    // Binary / byte mode: arbitrary byte sequences.
    function doBinaryDemo() external pure returns (bytes memory) {
        bytes memory data = hex"48656c6c6f2c20776f726c6421";  // "Hello, world!"
        return QRCode.encodeBinary(
            data,
            QRCode.ECC_MEDIUM,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_AUTO,
            true
        );
    }

    // Same as doBinaryDemo() but forces mask 0.
    function doBinaryDemoFixedMask() external pure returns (bytes memory) {
        bytes memory data = hex"48656c6c6f2c20776f726c6421";  // "Hello, world!"
        return QRCode.encodeBinary(
            data,
            QRCode.ECC_MEDIUM,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_0,
            true
        );
    }

    // Fixed mask: forces mask pattern 3 instead of auto-selecting.
    function doFixedMaskDemo() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "https://www.nayuki.io/",
            QRCode.ECC_HIGH,
            QRCode.VERSION_MIN,
            QRCode.VERSION_MAX,
            QRCode.MASK_3,
            true
        );
    }

    // Segment API: mix alphanumeric + numeric segments for compact encoding.
    function doSegmentDemo() external pure returns (bytes memory) {
        QRCode.Segment[] memory segs = new QRCode.Segment[](2);
        segs[0] = QRCode.makeAlphanumeric(bytes("THE SQUARE ROOT OF 2 IS 1."));
        segs[1] = QRCode.makeNumeric(bytes("41421356237309504880168872420969807856967187537694"));
        return QRCode.encodeSegments(segs, QRCode.ECC_LOW);
    }

    // Same as doSegmentDemo() but forces mask 0 to stay within the gas cap.
    function doSegmentDemoFixedMask() external pure returns (bytes memory) {
        QRCode.Segment[] memory segs = new QRCode.Segment[](2);
        segs[0] = QRCode.makeAlphanumeric(bytes("THE SQUARE ROOT OF 2 IS 1."));
        segs[1] = QRCode.makeNumeric(bytes("41421356237309504880168872420969807856967187537694"));
        return QRCode.encodeSegmentsAdvanced(segs, QRCode.ECC_LOW,
            QRCode.VERSION_MIN, QRCode.VERSION_MAX, QRCode.MASK_0, true);
    }

    // ECI segment: marks the payload as UTF-8 (ECI assignment value 26).
    function doEciDemo() external pure returns (bytes memory) {
        QRCode.Segment[] memory segs = new QRCode.Segment[](2);
        segs[0] = QRCode.makeEci(26);
        segs[1] = QRCode.makeBytes(hex"e4b8ade69687");  // Chinese "zhongwen" in UTF-8
        return QRCode.encodeSegments(segs, QRCode.ECC_MEDIUM);
    }

    // Same as doEciDemo() but forces mask 0 to stay within the gas cap.
    function doEciDemoFixedMask() external pure returns (bytes memory) {
        QRCode.Segment[] memory segs = new QRCode.Segment[](2);
        segs[0] = QRCode.makeEci(26);
        segs[1] = QRCode.makeBytes(hex"e4b8ade69687");  // Chinese "zhongwen" in UTF-8
        return QRCode.encodeSegmentsAdvanced(segs, QRCode.ECC_MEDIUM,
            QRCode.VERSION_MIN, QRCode.VERSION_MAX, QRCode.MASK_0, true);
    }

    // Version-constrained: forces exactly version 5 (37×37 modules), mask 2, no ECC boost.
    function doVersionConstraintDemo() external pure returns (bytes memory) {
        return QRCode.encodeText(
            "3141592653589793238462643383",
            QRCode.ECC_HIGH,
            5, 5,
            QRCode.MASK_2,
            false
        );
    }

    // -----------------------------------------------------------------------
    // SVG renderer (on-chain)
    // -----------------------------------------------------------------------

    /*
     * Converts a QR Code to a minimal SVG string suitable for embedding in HTML
     * or returning as NFT metadata.
     *
     * `border` is the number of quiet-zone modules to add on each side (the QR
     * Code specification recommends at least 4).
     */
    function toSvgString(bytes memory qrcode, uint border)
        external pure returns (string memory)
    {
        uint sz    = QRCode.getSize(qrcode);
        uint total = sz + 2 * border;

        string memory svg = string(abi.encodePacked(
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<svg xmlns="http://www.w3.org/2000/svg" version="1.1"',
            ' viewBox="0 0 ', _uint2str(total), ' ', _uint2str(total), '"',
            ' stroke="none">',
            '<rect width="100%" height="100%" fill="#FFFFFF"/>',
            '<path fill="#000000" d="'
        ));

        for (uint y = 0; y < sz; y++) {
            for (uint x = 0; x < sz; x++) {
                if (QRCode.getModule(qrcode, x, y)) {
                    svg = string(abi.encodePacked(
                        svg,
                        'M', _uint2str(x + border), ',', _uint2str(y + border), 'h1v1h-1z'
                    ));
                }
            }
        }

        return string(abi.encodePacked(svg, '"/></svg>'));
    }

    // Internal helper: convert uint to its decimal string representation.
    function _uint2str(uint n) internal pure returns (string memory) {
        if (n == 0) return "0";
        uint temp   = n;
        uint digits = 0;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (n != 0) {
            digits--;
            buf[digits] = bytes1(uint8(48 + n % 10));
            n /= 10;
        }
        return string(buf);
    }
}
