//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave V2 Lending Pool
interface ILendingPool {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    function getUserAccountData(address user)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

// ERC20 standard interface
interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
}

// WETH (Wrapped Ether) - same as ERC20 but adds withdraw
interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

// Uniswap V2 flash loan callback interface
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// Uniswap V2 Pair interface
interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // --- Aave ---
    address constant AaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

    // --- Tokens ---
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // --- DEX Pairs ---
    // UniV2 USDT/WETH: token0=WETH, token1=USDT  → borrow USDT here
    address constant UniV2_USDT_WETH = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
    // SushiSwap WBTC/WETH: token0=WBTC, token1=WETH
    address constant Sushi_WBTC_WETH = 0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58;
    // UniV2 WBTC/WETH: token0=WBTC, token1=WETH
    address constant UniV2_WBTC_WETH = 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940;
    // SushiSwap USDC/WETH: token0=USDC, token1=WETH
    address constant Sushi_USDC_WETH = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0;
    // UniV2 USDC/WETH: token0=USDC, token1=WETH
    address constant UniV2_USDC_WETH = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    // Curve 3pool (low-fee stablecoin swap: USDC <-> USDT)
    address constant Curve3pool = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // --- Liquidation target ---
    address constant TargetUser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

    // Flash loan amount: full USDT debt of the target user
    uint256 constant amountUSDT = 2916378221146;

    // --- AMM Math Helpers ---

    // How many tokens out given tokens in (with 0.3% fee)
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal pure returns (uint256)
    {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    // How many tokens in needed to get exact tokens out (with 0.3% fee)
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal pure returns (uint256)
    {
        return (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
    }

    constructor() {}
    receive() external payable {}

    // Step 1: Sell all WBTC → WETH across two pools to reduce price impact
    function _sellWBTC() internal {
        uint256 wbtcBal = IERC20(WBTC).balanceOf(address(this));
        (uint112 sr0, uint112 sr1, ) = IUniswapV2Pair(Sushi_WBTC_WETH).getReserves();
        (uint112 ur0, uint112 ur1, ) = IUniswapV2Pair(UniV2_WBTC_WETH).getReserves();

        // Split proportionally: bigger pool gets more WBTC (less slippage per pool)
        uint256 sushiAmt = wbtcBal * uint256(sr0) / (uint256(sr0) + uint256(ur0));
        uint256 uniAmt = wbtcBal - sushiAmt;

        IERC20(WBTC).transfer(Sushi_WBTC_WETH, sushiAmt);
        IUniswapV2Pair(Sushi_WBTC_WETH).swap(0, getAmountOut(sushiAmt, sr0, sr1), address(this), "");

        IERC20(WBTC).transfer(UniV2_WBTC_WETH, uniAmt);
        IUniswapV2Pair(UniV2_WBTC_WETH).swap(0, getAmountOut(uniAmt, ur0, ur1), address(this), "");
    }

    // Step 2: Buy USDC with WETH across two pools, then convert USDC → USDT via Curve
    function _buyUSDTviaCurve(uint256 usdcNeeded) internal {
        (uint112 sr0, uint112 sr1, ) = IUniswapV2Pair(Sushi_USDC_WETH).getReserves();
        (uint112 ur0, uint112 ur1, ) = IUniswapV2Pair(UniV2_USDC_WETH).getReserves();

        // Split USDC purchase proportionally to pool size
        uint256 sushiUSDC = usdcNeeded * uint256(sr0) / (uint256(sr0) + uint256(ur0));
        uint256 uniUSDC = usdcNeeded - sushiUSDC;

        // SushiSwap: WETH → USDC
        IERC20(WETH).transfer(Sushi_USDC_WETH, getAmountIn(sushiUSDC, sr1, sr0));
        IUniswapV2Pair(Sushi_USDC_WETH).swap(sushiUSDC, 0, address(this), "");

        // UniV2: WETH → USDC
        IERC20(WETH).transfer(UniV2_USDC_WETH, getAmountIn(uniUSDC, ur1, ur0));
        IUniswapV2Pair(UniV2_USDC_WETH).swap(uniUSDC, 0, address(this), "");

        // Curve: USDC (index 1) → USDT (index 2), near-zero slippage (0.04% fee)
        IERC20(USDC).approve(Curve3pool, usdcNeeded);
        (bool ok, ) = Curve3pool.call(
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", 1, 2, usdcNeeded, 0)
        );
        require(ok, "Curve USDC->USDT failed");
    }

    // --- Main entry point ---
    function operate() external {
        // Borrow USDT via Uniswap V2 flash swap
        IUniswapV2Pair(UniV2_USDT_WETH).swap(0, amountUSDT, address(this), abi.encode("fl"));

        // Sweep any leftover USDT → WETH (profit from Curve buffer)
        uint256 leftUSDT = IERC20(USDT).balanceOf(address(this));
        if (leftUSDT > 0) {
            (bool ok, ) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", UniV2_USDT_WETH, leftUSDT));
            require(ok);
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(UniV2_USDT_WETH).getReserves();
            IUniswapV2Pair(UniV2_USDT_WETH).swap(getAmountOut(leftUSDT, r1, r0), 0, address(this), "");
        }

        // Convert all WETH → ETH and send to caller
        uint256 wethBal = IERC20(WETH).balanceOf(address(this));
        if (wethBal > 0) IWETH(WETH).withdraw(wethBal);
        (bool sent, ) = msg.sender.call{value: address(this).balance}("");
        require(sent, "ETH send failed");
    }

    // --- Flash loan callback ---
    function uniswapV2Call(address, uint256, uint256 amount1, bytes calldata) external override {
        // A: Liquidate target on Aave V2 (pay USDT → receive WBTC + 10% bonus)
        IERC20(USDT).approve(AaveLendingPool, amount1);
        ILendingPool(AaveLendingPool).liquidationCall(WBTC, USDT, TargetUser, amount1, false);

        // B: Sell all WBTC → WETH across two pools
        _sellWBTC();

        // C: Buy USDT to repay flash loan via USDC split + Curve
        // Flash loan repayment = amount borrowed + 0.3% fee
        uint256 repayUSDT = amount1 + (amount1 * 3) / 997 + 1;

        // Buy USDC with 0.15% buffer (Curve may give slightly less than 1:1)
        uint256 usdcNeeded = repayUSDT + (repayUSDT * 15) / 10000;
        _buyUSDTviaCurve(usdcNeeded);

        // D: Repay USDT to the Uniswap V2 pair
        (bool ok, ) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, repayUSDT));
        require(ok, "USDT repay failed");
    }
}
