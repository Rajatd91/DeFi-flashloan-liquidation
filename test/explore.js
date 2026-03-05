const { ethers, network } = require("hardhat");

async function main() {
    await network.provider.request({
        method: "hardhat_reset",
        params: [{
            forking: {
                jsonRpcUrl: process.env.ALCHE_API,
                blockNumber: 12489619,
            }
        }]
    });

    const targetUser = "0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F";
    const aavePool = await ethers.getContractAt("ILendingPool", "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9");
    const accountData = await aavePool.getUserAccountData(targetUser);

    console.log("Total Collateral ETH:", ethers.utils.formatEther(accountData.totalCollateralETH));
    console.log("Total Debt ETH:", ethers.utils.formatEther(accountData.totalDebtETH));

    // Check token0 and token1 for UniswapV2 USDT/WETH
    const pairInterface = ["function token0() view returns (address)", "function token1() view returns (address)"];
    const pair = await ethers.getContractAt(pairInterface, "0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852");
    console.log("UniswapV2 USDT/WETH token0:", await pair.token0());
    console.log("UniswapV2 USDT/WETH token1:", await pair.token1());

    const pairSushi1 = await ethers.getContractAt(pairInterface, "0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58");
    console.log("SushiSwap WBTC/WETH token0:", await pairSushi1.token0());
    console.log("SushiSwap WBTC/WETH token1:", await pairSushi1.token1());

    const pairSushi2 = await ethers.getContractAt(pairInterface, "0x397FF1542f962076d0BFE58eA045FfA2d347ACa0");
    console.log("SushiSwap USDC/WETH token0:", await pairSushi2.token0());
    console.log("SushiSwap USDC/WETH token1:", await pairSushi2.token1());
}

main().catch(console.error);
