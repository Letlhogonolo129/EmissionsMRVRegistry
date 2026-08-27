// Deploys EmissionsMRVRegistry.
//
//   npx hardhat node                                        (terminal 1)
//   npx hardhat run scripts/deploy.js --network localhost   (terminal 2)
//
// The regulator address is passed to the constructor rather than defaulting to
// the deployer, so the account that pays for deployment does not silently
// inherit consortium governance authority. Set REGULATOR_ADDRESS to control it;
// otherwise the second local signer is used.

const { ethers } = require("hardhat");

async function main() {
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const regulator = process.env.REGULATOR_ADDRESS || signers[1].address;

  console.log("Deployer :", deployer.address);
  console.log("Regulator:", regulator);

  const Factory = await ethers.getContractFactory("EmissionsMRVRegistry");
  const registry = await Factory.deploy(regulator);
  const tx = registry.deploymentTransaction();

  await registry.waitForDeployment();
  const receipt = await tx.wait();

  console.log("");
  console.log("Contract address :", await registry.getAddress());
  console.log("Transaction hash :", tx.hash);
  console.log("Block number     :", receipt.blockNumber);
  console.log("Gas used         :", receipt.gasUsed.toString());
  console.log("");
  console.log("Record the contract address and transaction hash above — both are");
  console.log("required deliverables for the assignment.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
