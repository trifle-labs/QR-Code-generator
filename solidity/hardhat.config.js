import "@nomicfoundation/hardhat-toolbox";

/** @type import('hardhat/config').HardhatUserConfig */
const config = {
  solidity: {
    version: "0.8.34",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    hardhat: {
      // QR Code generation requires significant gas.
      // blockGasLimit increases the cap for calls; gas is the default per-tx limit.
      blockGasLimit: 30_000_000,
      allowUnlimitedContractSize: true,
    },
  },
};

export default config;
