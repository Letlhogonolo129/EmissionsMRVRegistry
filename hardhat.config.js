require("@nomicfoundation/hardhat-ethers");
require("@nomicfoundation/hardhat-chai-matchers");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    // Local node for the MetaMask demo:
    //   npx hardhat node        (terminal 1)
    //   npx hardhat run scripts/deploy.js --network localhost   (terminal 2)
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
  },
};
