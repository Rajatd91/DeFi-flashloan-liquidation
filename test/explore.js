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

    console.log("Total Collateral ETH:", ethers.utils.formatEther(accountData.totalCollateralETH || 0));
    console.log("Total Debt ETH:", ethers.utils.formatEther(accountData.totalDebtETH || 0));
}

main().catch(console.error);
