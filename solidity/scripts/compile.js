#!/usr/bin/env node
/**
 * Compile script — uses the bundled solc npm package (no internet required).
 * Outputs compiled JSON artifacts to the artifacts/ directory.
 *
 * Usage:  node scripts/compile.js
 *    or:  npm run compile
 */

import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { createRequire } from "module";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

const require      = createRequire(import.meta.url);
const __dirname    = dirname(fileURLToPath(import.meta.url));
const solc         = require("solc");

const contractsDir = resolve(__dirname, "../contracts");
const artifactsDir = resolve(__dirname, "../artifacts");
mkdirSync(artifactsDir, { recursive: true });

const input = {
    language: "Solidity",
    sources: {
        "QRCode.sol":     { content: readFileSync(`${contractsDir}/QRCode.sol`,     "utf8") },
        "QRCodeDemo.sol": { content: readFileSync(`${contractsDir}/QRCodeDemo.sol`, "utf8") },
    },
    settings: {
        viaIR: true,
        optimizer: { enabled: true, runs: 200 },
        outputSelection: {
            "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] },
        },
    },
};

console.log(`Compiling with solc ${solc.version()} …`);
const output = JSON.parse(solc.compile(JSON.stringify(input)));

let hasError = false;
for (const e of output.errors || []) {
    const msg = `[${e.severity.toUpperCase()}] ${e.formattedMessage}`;
    if (e.severity === "error") { console.error(msg); hasError = true; }
    else                         { console.warn(msg);  }
}
if (hasError) process.exit(1);

for (const [, contracts] of Object.entries(output.contracts || {})) {
    for (const [name, data] of Object.entries(contracts)) {
        const artifact = {
            contractName:      name,
            abi:               data.abi,
            bytecode:          "0x" + data.evm.bytecode.object,
            deployedBytecode:  "0x" + data.evm.deployedBytecode.object,
        };
        const outPath = `${artifactsDir}/${name}.json`;
        writeFileSync(outPath, JSON.stringify(artifact, null, 2));
        console.log(`  ✓ ${name}  →  artifacts/${name}.json`);
    }
}
console.log("Compilation successful.");
