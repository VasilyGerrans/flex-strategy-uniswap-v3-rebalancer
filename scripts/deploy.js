const hre = require("hardhat");

async function main() {
  console.log("Deploying on Rinkeby");

  const pool_address = "0x6033Ed27652E1157D792A99CC77D3F6893B72fce";

  /* 
  const Flex = await hre.ethers.getContractFactory("FLEXUniswapV3");
  const flex = await Flex.deploy(pool_address, {gasLimit: 8000000});
  await flex.deployed();

  console.log("FLEXUniswapV3 deployed to:", flex.address); 
  */

  await hre.run("verify:verify", {
    address: "0xABF047BdCb576F2235AD2765A94559F0105326c3",
    constructorArguments: [
      pool_address
    ]
  });

  console.log("FLEXUniswapV3 has been verified");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
