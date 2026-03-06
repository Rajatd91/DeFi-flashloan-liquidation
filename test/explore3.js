const { ethers, network } = require("hardhat");

async function main() {
    await network.provider.request({
        method: "hardhat_reset",
        params: [{ forking: { jsonRpcUrl: process.env.ALCHE_API, blockNumber: 12489619 } }]
    });

    const pairABI = ["function getReserves() view returns (uint112, uint112, uint32)", "function token0() view returns (address)", "function token1() view returns (address)"];
    const factoryABI = ["function getPair(address, address) view returns (address)"];

    const USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
    const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const WBTC = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
    const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

    const uniFactory = new ethers.Contract("0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f", factoryABI, ethers.provider);
    const sushiFactory = new ethers.Contract("0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac", factoryABI, ethers.provider);

    // Check all WBTC pairs
    console.log("=== WBTC Pairs ===");

    // UniV2 WBTC/WETH
    const uniWBTCWETH = await uniFactory.getPair(WBTC, WETH);
    console.log("UniV2 WBTC/WETH:", uniWBTCWETH);
    if (uniWBTCWETH != ethers.constants.AddressZero) {
        const p = new ethers.Contract(uniWBTCWETH, pairABI, ethers.provider);
        const [r0, r1] = await p.getReserves();
        console.log("  token0:", await p.token0(), "| token1:", await p.token1());
        console.log("  reserves:", ethers.utils.formatUnits(r0, 8), "WBTC |", ethers.utils.formatEther(r1), "WETH");
    }

    // SushiSwap WBTC/WETH
    const sushiWBTCWETH = new ethers.Contract("0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58", pairABI, ethers.provider);
    const [sr0, sr1] = await sushiWBTCWETH.getReserves();
    console.log("Sushi WBTC/WETH:");
    console.log("  reserves:", ethers.utils.formatUnits(sr0, 8), "WBTC |", ethers.utils.formatEther(sr1), "WETH");

    console.log("\n=== USDT Pairs ===");

    // UniV2 USDT/WETH
    const uniUSDTWETH = new ethers.Contract("0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852", pairABI, ethers.provider);
    const [ur0, ur1] = await uniUSDTWETH.getReserves();
    console.log("UniV2 USDT/WETH:");
    console.log("  token0:", await uniUSDTWETH.token0(), "| token1:", await uniUSDTWETH.token1());
    console.log("  reserves:", ethers.utils.formatEther(ur0), "WETH |", ethers.utils.formatUnits(ur1, 6), "USDT");

    // SushiSwap USDT/WETH
    const sushiUSDTWETH = await sushiFactory.getPair(USDT, WETH);
    console.log("Sushi USDT/WETH:", sushiUSDTWETH);
    if (sushiUSDTWETH != ethers.constants.AddressZero) {
        const p = new ethers.Contract(sushiUSDTWETH, pairABI, ethers.provider);
        const [r0, r1] = await p.getReserves();
        console.log("  token0:", await p.token0(), "| token1:", await p.token1());
        console.log("  reserves:", r0.toString(), "|", r1.toString());
    }

    console.log("\n=== USDC Pairs ===");

    // SushiSwap USDC/WETH
    const sushiUSDCWETH = new ethers.Contract("0x397FF1542f962076d0BFE58eA045FfA2d347ACa0", pairABI, ethers.provider);
    const [scr0, scr1] = await sushiUSDCWETH.getReserves();
    console.log("Sushi USDC/WETH:");
    console.log("  reserves:", ethers.utils.formatUnits(scr0, 6), "USDC |", ethers.utils.formatEther(scr1), "WETH");

    // UniV2 USDC/WETH
    const uniUSDCWETH = await uniFactory.getPair(USDC, WETH);
    if (uniUSDCWETH != ethers.constants.AddressZero) {
        const p = new ethers.Contract(uniUSDCWETH, pairABI, ethers.provider);
        const [r0, r1] = await p.getReserves();
        console.log("UniV2 USDC/WETH:", uniUSDCWETH);
        console.log("  token0:", await p.token0(), "| token1:", await p.token1());
        console.log("  reserves:", r0.toString(), "|", r1.toString());
    }

    // Calculate: how much WETH to get 2925 billion USDT (the repay amount)
    const repayUSDT = ethers.BigNumber.from("2925152811218"); // approx repay
    console.log("\n=== Cost Analysis ===");
    console.log("Repay USDT needed:", ethers.utils.formatUnits(repayUSDT, 6));

    // SushiSwap WBTC/WETH: what's the WETH output for the full WBTC we get?
    // Liquidation gives us about 7827 WBTC (assuming ~50% of their position)
    // The original tx shows liquidation of 2916378221146 USDT worth
    // At ~$38k WBTC at that block, we get about 7600+ WBTC satoshis? No...
    // Let me check what the actual WBTC bonus is

    // Check the Aave oracle price
    const oracleABI = ["function getAssetPrice(address) view returns (uint256)"];
    const protocolDataABI = ["function getReserveConfigurationData(address) view returns (uint256, uint256, uint256, uint256, uint256, bool, bool, bool, bool, bool)"];

    // Check liquidation bonus
    const protocolData = new ethers.Contract("0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d", protocolDataABI, ethers.provider);
    const wbtcConfig = await protocolData.getReserveConfigurationData(WBTC);
    console.log("WBTC liquidation bonus:", wbtcConfig[1].toString(), "basis points (10000=100%)");

    // Price oracle
    const oracle = new ethers.Contract("0xA50ba011c48153De246E5192C8f9258A2ba79Ca9", oracleABI, ethers.provider);
    const wbtcPrice = await oracle.getAssetPrice(WBTC);
    const usdtPrice = await oracle.getAssetPrice(USDT);
    const wethPrice = await oracle.getAssetPrice(WETH);
    console.log("WBTC price (ETH):", ethers.utils.formatEther(wbtcPrice));
    console.log("USDT price (ETH):", ethers.utils.formatEther(usdtPrice));
    console.log("WETH price (ETH):", ethers.utils.formatEther(wethPrice));

    // Calculate expected WBTC from liquidation
    // debtToCover (in USDT) * USDT_price / WBTC_price * (1 + bonus)
    const debtToCover = ethers.BigNumber.from("2916378221146");
    const expectedWBTC = debtToCover.mul(usdtPrice).mul(11000).div(wbtcPrice).div(10000);
    console.log("Expected WBTC from liquidation:", ethers.utils.formatUnits(expectedWBTC, 6), "(in 6-decimal units, WBTC has 8)");
    // Actually WBTC uses 8 decimals and USDT uses 6 decimals
    // Need to adjust: debtToCover is in 6 decimals, WBTC is in 8 decimals
    // WBTC_amount = debtToCover * usdtPrice * 10 * 100 / wbtcPrice * 11000 / 10000
    // Hmm this is getting complex. Let me just calculate:
    // USDT amount in ETH = debtToCover * usdtPrice / 1e6  (since USDT has 6 decimals and price in 18 decimals)
    // WBTC amount = ETH_value * 1e8 / wbtcPrice * bonus
    const debtETH = debtToCover.mul(usdtPrice).div(ethers.BigNumber.from("1000000"));
    console.log("Debt covered in ETH:", ethers.utils.formatEther(debtETH));
    const wbtcReceived = debtETH.mul(ethers.BigNumber.from("100000000")).mul(11000).div(wbtcPrice.mul(10000));
    console.log("Expected WBTC received:", ethers.utils.formatUnits(wbtcReceived, 8), "WBTC");
}
main().catch(console.error);
