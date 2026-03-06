//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

interface ILendingPool {
    function liquidationCall(address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool receiveAToken) external;
    function getUserAccountData(address user) external view returns (uint256, uint256, uint256, uint256, uint256, uint256);
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWETH is IERC20 {
    function withdraw(uint256) external;
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    address constant AaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address constant UniV2_USDT_WETH  = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;  // t0=WETH, t1=USDT
    address constant Sushi_WBTC_WETH  = 0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58;  // t0=WBTC, t1=WETH
    address constant UniV2_WBTC_WETH  = 0xBb2b8038a1640196FbE3e38816F3e67Cba72D940;  // t0=WBTC, t1=WETH
    address constant Sushi_USDC_WETH  = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0;  // t0=USDC, t1=WETH
    address constant UniV2_USDC_WETH  = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;  // t0=USDC, t1=WETH
    address constant Sushi_USDT_WETH  = 0x06da0fd433C1A5d7a4faa01111c044910A184553;  // t0=WETH, t1=USDT
    address constant Curve3pool       = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    address constant TargetUser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    uint256 constant amountUSDT = 2916378221146;

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1;
    }

    constructor() {}
    receive() external payable {}

    // Helper: swap WBTC to WETH across two pools
    function _swapWBTCtoWETH() internal {
        uint256 wbtcBal = IERC20(WBTC).balanceOf(address(this));
        (uint112 sr0, uint112 sr1, ) = IUniswapV2Pair(Sushi_WBTC_WETH).getReserves();
        (uint112 ur0, uint112 ur1, ) = IUniswapV2Pair(UniV2_WBTC_WETH).getReserves();
        
        uint256 sushiAmt = wbtcBal * uint256(sr0) / (uint256(sr0) + uint256(ur0));
        uint256 uniAmt = wbtcBal - sushiAmt;
        
        IERC20(WBTC).transfer(Sushi_WBTC_WETH, sushiAmt);
        IUniswapV2Pair(Sushi_WBTC_WETH).swap(0, getAmountOut(sushiAmt, sr0, sr1), address(this), "");
        
        IERC20(WBTC).transfer(UniV2_WBTC_WETH, uniAmt);
        IUniswapV2Pair(UniV2_WBTC_WETH).swap(0, getAmountOut(uniAmt, ur0, ur1), address(this), "");
    }

    // Helper: get USDT for repayment via direct USDT swap
    function _getDirectUSDT(uint256 usdtAmount) internal {
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(Sushi_USDT_WETH).getReserves();
        uint256 wethNeeded = getAmountIn(usdtAmount, r0, r1);
        IERC20(WETH).transfer(Sushi_USDT_WETH, wethNeeded);
        IUniswapV2Pair(Sushi_USDT_WETH).swap(0, usdtAmount, address(this), "");
    }

    // Helper: get USDC via split across Sushi+UniV2, then convert to USDT via Curve
    function _getUSDTviaCurve(uint256 usdcAmount) internal {
        (uint112 scr0, uint112 scr1, ) = IUniswapV2Pair(Sushi_USDC_WETH).getReserves();
        (uint112 ucr0, uint112 ucr1, ) = IUniswapV2Pair(UniV2_USDC_WETH).getReserves();
        
        uint256 sushiUSDC = usdcAmount * uint256(scr0) / (uint256(scr0) + uint256(ucr0));
        uint256 uniUSDC = usdcAmount - sushiUSDC;
        
        IERC20(WETH).transfer(Sushi_USDC_WETH, getAmountIn(sushiUSDC, scr1, scr0));
        IUniswapV2Pair(Sushi_USDC_WETH).swap(sushiUSDC, 0, address(this), "");
        
        IERC20(WETH).transfer(UniV2_USDC_WETH, getAmountIn(uniUSDC, ucr1, ucr0));
        IUniswapV2Pair(UniV2_USDC_WETH).swap(uniUSDC, 0, address(this), "");

        IERC20(USDC).approve(Curve3pool, usdcAmount);
        (bool ok, ) = Curve3pool.call(abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", 1, 2, usdcAmount, 0));
        require(ok, "Curve failed");
    }

    function operate() external {
        bytes memory data = abi.encode("flashloan");
        IUniswapV2Pair(UniV2_USDT_WETH).swap(0, amountUSDT, address(this), data);

        // Sweep leftover USDT
        uint256 remaining = IERC20(USDT).balanceOf(address(this));
        if (remaining > 0) {
            (bool ok, ) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", UniV2_USDT_WETH, remaining));
            require(ok, "sweep failed");
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(UniV2_USDT_WETH).getReserves();
            uint256 extra = getAmountOut(remaining, r1, r0);
            IUniswapV2Pair(UniV2_USDT_WETH).swap(extra, 0, address(this), "");
        }

        // Convert WETH -> ETH
        uint256 wethBal = IERC20(WETH).balanceOf(address(this));
        if (wethBal > 0) IWETH(WETH).withdraw(wethBal);
        
        // Send ETH to the caller (using call instead of transfer to avoid deprecation warning)
        (bool okSent, ) = msg.sender.call{value: address(this).balance}("");
        require(okSent, "ETH transfer failed");
    }

    function uniswapV2Call(address, uint256, uint256 amount1, bytes calldata) external override {
        // A: Liquidate on Aave V2
        IERC20(USDT).approve(AaveLendingPool, amount1);
        ILendingPool(AaveLendingPool).liquidationCall(WBTC, USDT, TargetUser, amount1, false);

        // B: WBTC -> WETH (split across 2 pools)
        _swapWBTCtoWETH();

        // C: Get USDT for repayment (3-way: direct USDT + USDC->Curve->USDT)
        uint256 repayUSDT = amount1 + (amount1 * 3) / 997 + 1;
        
        // 30% direct from SushiSwap USDT/WETH
        uint256 directUSDT = repayUSDT * 30 / 100;
        _getDirectUSDT(directUSDT);
        
        // 70% via USDC->Curve (with 0.12% buffer)
        uint256 usdcNeeded = (repayUSDT - directUSDT) + ((repayUSDT - directUSDT) * 12) / 10000;
        _getUSDTviaCurve(usdcNeeded);

        // D: Repay Uniswap V2 flash loan
        (bool ok, ) = USDT.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, repayUSDT));
        require(ok, "repay failed");
    }
}
