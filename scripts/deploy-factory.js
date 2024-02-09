require("dotenv").config();
const hre = require("hardhat");
const ethers = hre.ethers;
const path = require("path");
const EthDeployUtils = require("eth-deploy-utils");
const { sleep } = require("../test/helpers");
let deployUtils;

const { expect } = require("chai");

async function main() {
  deployUtils = new EthDeployUtils(path.resolve(__dirname, ".."), console.log);

  const [deployer] = await ethers.getSigners();
  const vault = await deployUtils.attach("CrunaVaults");

  const factory = await deployUtils.deployProxy("VaultFactory", vault.address, deployer.address);

  const usdc = await deployUtils.attach("USDCoin");
  // await usdc.mint("0xF61101A3c7988725369ba481084227971aa55fc2", 100000000000000000000000n);
  const usdt = await deployUtils.attach("TetherUSD");
  // await usdt.mint("0xF61101A3c7988725369ba481084227971aa55fc2", 100000000000n);

  // return;

  await deployUtils.Tx(factory.setPrice(3000, { gasLimit: 60000 }), "Setting price");
  await deployUtils.Tx(factory.setStableCoin(usdc.address, true), "Set USDC as stable coin");
  await deployUtils.Tx(factory.setStableCoin(usdt.address, true), "Set USDT as stable coin");

  // discount campaign selling for $9.9
  await deployUtils.Tx(factory.setDiscount(2010), "Set discount");

  await deployUtils.Tx(vault.setFactory(factory.address, { gasLimit: 100000 }), "Set the factory");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
