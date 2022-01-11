const { expect } = require("chai");
const { ethers } = require("hardhat");
const erc20_abi = require("../abi/erc20.json");
const pool_abi = require("../abi/pool.json");
const weth_abi = require("../abi/weth.json");
const router_abi = require("../abi/router.json");

async function logBalances(address, tokens) {
  for (let i = 0; i < tokens.length; i++) {
    const element = tokens[i];
    const balance = await element.balanceOf(address);
    const symbol = await element.symbol();

    console.log(symbol, "balance:", balance.toString());
  }
}

describe("FLEXUniswapV3", function () {
  this.timeout(0);

  let deployer, users, pool, dai, weth, router, flex;

  // Mainnet Addresses
  const pool_address = "0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8";
  const dai_address = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
  const weth_address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
  const router_address = "0xE592427A0AEce92De3Edee1F18E0157C05861564";

  before(async () => {
    [ deployer ] = await ethers.getSigners();
    users = await ethers.getSigners();
    users.shift();

    pool = new ethers.Contract(pool_address, pool_abi, ethers.provider);
    dai = new ethers.Contract(dai_address, erc20_abi, ethers.provider);
    weth = new ethers.Contract(weth_address, weth_abi, ethers.provider);
    router = new ethers.Contract(router_address, router_abi, ethers.provider);

    flex = await (await ethers.getContractFactory("FLEXUniswapV3")).connect(deployer).deploy(pool_address);
    await flex.deployed();

    // get test balances up
    await weth.connect(deployer).deposit({value: ethers.utils.parseEther("20")});
    await weth.connect(deployer).approve(router_address, ethers.utils.parseEther("10"));
    await router.connect(deployer).exactInputSingle([
      weth_address, dai_address, 3000, deployer.address, Date.now() + 120, ethers.utils.parseEther("10"), "0", "0"
    ]);
  });

  it("deploys correctly", async () => {
    expect(await flex.pool()).to.equal(pool_address);
    expect(await flex.token0()).to.equal(dai_address);
    expect(await flex.token1()).to.equal(weth_address);
    expect((await flex.SQRT_70_PERCENT()).toString()).to.equal("836660026534075547");
    expect((await flex.SQRT_130_PERCENT()).toString()).to.equal("1140175425099137979");
  });

  it("mints liquidity", async () => {
    const bal0 = await dai.balanceOf(deployer.address);
    const bal1 = await weth.balanceOf(deployer.address);

    console.log(
      bal0, "\n", 
      bal1
    );

    await dai.connect(deployer).approve(flex.address, bal0);
    await weth.connect(deployer).approve(flex.address, bal1);

    await flex.connect(deployer).mint(bal0, bal1);

    const positionID = await flex.getPositionID();
    const position = await pool.positions(positionID);

    console.log(position);

    await logBalances(deployer.address, [dai, weth]);
    await logBalances(flex.address, [dai, weth]);
  });

  it("rebalances with swap", async () => {
    await flex.connect(deployer).defaultExecutiveRebalance(5000, true);

    const positionID = await flex.getPositionID();
    const position = await pool.positions(positionID);

    console.log(position);

    await logBalances(deployer.address, [dai, weth]);
    await logBalances(flex.address, [dai, weth]);
  }); 

  it("accumulates fees", async () => {
    for (let i = 0; i < 3; i++) {
      const user = users[i];

      await weth.connect(user).deposit({value: ethers.utils.parseEther("10")});
      await weth.connect(user).approve(router_address, ethers.utils.parseEther("10"));
      await router.connect(user).exactInputSingle([
        weth_address, dai_address, 3000, deployer.address, Date.now() + 120, ethers.utils.parseEther("10"), "0", "0"
      ]);
    }

    await flex.rebalance(5000, true);

    const positionID = await flex.getPositionID();
    const position = await pool.positions(positionID);

    console.log(position);

    await logBalances(deployer.address, [dai, weth]);
    await logBalances(flex.address, [dai, weth]);
  });

  it("calculates underlying balances", async () => {
    const res = await flex.getUnderlyingBalances();

    console.log(res);
  });

  it("burns all", async () => {
    await flex.burnAll(deployer.address);

    const positionID = await flex.getPositionID();
    const position = await pool.positions(positionID);

    console.log(position);

    await logBalances(deployer.address, [dai, weth]);
    await logBalances(flex.address, [dai, weth]);
  });
});

// Example outputs:
// Before:
// DAI: 37729812250598454861277
// WETH: 10000000000000000000
// After:
// DAI: 150250528066751966817940  ~+398%
// WETH: 10103112499635811970     ~+1.03%