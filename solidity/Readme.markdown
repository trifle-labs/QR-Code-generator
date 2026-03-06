QR Code generator library — Solidity
=====================================


Introduction
------------

This is the Solidity port of the QR Code generator library, modeled after the
C implementation in this repository.  It provides on-chain QR Code generation
as a pure Solidity library — no external calls, no oracles, entirely self-contained.

Home page with live JavaScript demo, extensive descriptions, and competitor comparisons:
https://www.nayuki.io/page/qr-code-generator-library


Features
--------

Core features:

* Supports all 40 QR Code versions (sizes 21×21 to 177×177)
* All 4 error correction levels: Low, Medium, Quartile, High
* All 4 encoding modes: Numeric, Alphanumeric, Byte, Kanji/ECI
* Automatic mask selection (evaluates all 8 patterns, picks the lowest-penalty one)
* Manual mask pattern override (MASK_0 … MASK_7)
* ECC level boosting (upgrades ECC level when the version number doesn't increase)
* Low-level segment API for mixed-mode encoding
* On-chain SVG renderer (QRCodeDemo.toSvgString)
* Open source under the MIT License


Output format
-------------

Every successful encoding returns a `bytes` value:

```
qrcode[0]    — side length in modules (21 for version 1, 177 for version 40)
qrcode[1..]  — packed module bits, row-major order
               Module (x, y) is at bit index  y * size + x
               stored in byte  (y * size + x) / 8 + 1
               at bit position (y * size + x) % 8  (LSB = bit 0)
               A set bit (1) means a dark / black module.
```

A failed encoding (data too long for the requested version range) returns
`bytes` of length 1 where `qrcode[0] == 0`.


Examples
--------

```solidity
import "./QRCode.sol";

// Simple — encode "Hello, world!" with Low ECC, auto mask
bytes memory qr = QRCode.encodeText(
    "Hello, world!",
    QRCode.ECC_LOW,
    QRCode.VERSION_MIN,   // 1
    QRCode.VERSION_MAX,   // 40
    QRCode.MASK_AUTO,
    true                  // boost ECC level if possible
);
uint size = QRCode.getSize(qr);  // 21 for version 1

// Read a module
bool dark = QRCode.getModule(qr, x, y);

// Manual — force version 5, mask pattern 2, no ECC boost
bytes memory qr2 = QRCode.encodeText(
    "3141592653589793238462643383",
    QRCode.ECC_HIGH,
    5, 5,
    QRCode.MASK_2,
    false
);

// Low-level — mix numeric and alphanumeric segments
QRCode.Segment[] memory segs = new QRCode.Segment[](2);
segs[0] = QRCode.makeAlphanumeric(bytes("THE SQUARE ROOT OF 2 IS 1."));
segs[1] = QRCode.makeNumeric(bytes("41421356237309504880168872420969807856967187537694"));
bytes memory qr3 = QRCode.encodeSegments(segs, QRCode.ECC_LOW);

// On-chain SVG (4 module quiet zone)
string memory svg = QRCodeDemo(demoAddress).toSvgString(qr, 4);
```


Gas usage
---------

QR Code generation is compute-intensive on-chain.  The tables below show gas
estimates (measured on Hardhat's in-process EVM with the optimizer enabled at
200 runs) for a range of typical inputs.

The current implementation applies three EVM-native optimisations over the
original C-port baseline: pre-computed `bytes constant` lookup tables for
GF(256) exp/log and ECC block data; `uint256` row packing for the internal
module grid (whole-row XOR/OR instead of per-module bit manipulation); and
Yul inline assembly for the Reed-Solomon inner loop and penalty-scoring hot
paths.  The result is roughly a **55–62% reduction** in gas across all inputs.

### Fixed mask (recommended for on-chain transactions)

| Input | ECC | Mask | QR version | Gas |
|---|---|---|---|---|
| `"Hello, world!"` (13 B, byte mode) | Low | 2 | 1 (21×21) | ~930,000 |
| Binary payload 13 bytes | Medium | 0 | 1 (21×21) | ~928,000 |
| ECI(26) + 6-byte UTF-8 | Medium | 0 | 1 (21×21) | ~1,227,000 |
| 50-digit numeric string | Medium | 3 | 2 (25×25) | ~1,728,000 |
| 22-char URL (alphanumeric mode) | High | — | 3 (29×29) | ~2,397,000 |
| 26-char mixed segments | Low | 0 | 3 (29×29) | ~3,276,000 |
| 28-digit numeric string | High | 2 | 5 (37×37) | ~3,337,000 |
| 55-char alphanumeric string | High | — | 5 (37×37) | ~3,594,000 |

### Automatic mask selection (`MASK_AUTO`)

`MASK_AUTO` runs the full encoding pipeline 8 times to score each mask and
pick the lowest-penalty one.  Gas is roughly 5–6× the fixed-mask cost:

| Input | QR version | Gas |
|---|---|---|
| `"Hello, world!"` (byte mode) | 1 (21×21) | ~5,291,000 |
| Binary payload 13 bytes | 1 (21×21) | ~5,290,000 |
| ECI(26) + 6-byte UTF-8 | 1 (21×21) | ~5,591,000 |
| 50-digit numeric string | 2 (25×25) | ~7,698,000 |
| 26-char mixed segments | 3 (29×29) | ~11,121,000 |
| 55-char alphanumeric string | 5 (37×37) | ~15,741,000 |

All `MASK_AUTO` cases now fit comfortably within Ethereum mainnet's 30 M gas
block limit (previously they exceeded it for versions ≥ 2).

### SVG rendering

`QRCodeDemo.toSvgString(qr, border)` costs approximately **2,356,000 gas**
for a version-1 QR Code with a 4-module quiet-zone border.

### Gas scaling by version

Gas scales with the number of modules (size²) of the QR Code:

* Version 1 (21×21 =   441 modules): ~930 k gas (fixed mask)
* Version 2 (25×25 =   625 modules): ~1.7 M gas
* Version 3 (29×29 =   841 modules): ~2.4–3.3 M gas
* Version 5 (37×37 = 1 369 modules): ~3.3–3.6 M gas
* Higher versions scale proportionally

Practical considerations:

* Use a **fixed mask** (`MASK_0`…`MASK_7`) whenever calling from a transaction
  or when operating near the block gas limit.  Mask quality varies little in
  practice; `MASK_0` or `MASK_2` are reasonable defaults.
* `MASK_AUTO` is now feasible for on-chain transactions through version 5
  (all cases are below 30 M gas), and is always suitable for off-chain
  `eth_call` simulation with an unlimited gas allowance.
* The QR Code library itself is a pure Solidity function (no storage, no
  events); all the gas is spent on computation, not on state writes.


Building and testing
--------------------

Prerequisites: Node.js ≥ 18 and npm.

```bash
cd solidity
npm install
npm run compile    # compiles with the bundled solc (no internet required)
npm test           # runs the Hardhat test suite against a local network
```

The `npm run compile` script uses the bundled `solc` npm package so no
network access is needed.  `npm test` runs Hardhat which spins up an
in-process EVM for the tests.

Note: the contracts use `viaIR: true` (Yul IR pipeline) to avoid the EVM's
16-slot stack-depth limit, which the QR Code algorithm would otherwise exceed.


License
-------

Solidity port and EVM optimizations copyright © trifle-labs contributors. (MIT License)
Based on the C implementation by Project Nayuki.
https://www.nayuki.io/page/qr-code-generator-library

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

* The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

* The Software is provided "as is", without warranty of any kind, express or
  implied, including but not limited to the warranties of merchantability,
  fitness for a particular purpose and noninfringement. In no event shall the
  authors or copyright holders be liable for any claim, damages or other
  liability, whether in an action of contract, tort or otherwise, arising from,
  out of or in connection with the Software or the use or other dealings in the
  Software.
