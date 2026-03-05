//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    // Aave
    address constant AaveLendingPool = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;

    // ERC20 Tokens
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Pairs and Exchanges
    address constant UniswapV2USDTWETH = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
    address constant SushiSwapWBTCWETH = 0xCEfF51756c56CeFFCA006cD410B03FFC46dd3a58;
    address constant SushiSwapUSDCWETH = 0x397FF1542f962076d0BFE58eA045FfA2d347ACa0;
    address constant Curve3pool = 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7;

    // Target User
    address constant TargetUser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

    // flashloan amount
    uint256 constant amountUSDT = 2916378221146;

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {}

    receive() external payable {}

    function operate() external {
        // 1. call flash swap to liquidate the target user
        // We borrow USDT from Uniswap V2 USDT/WETH pair
        // The token0 is WETH (0x...C02a), token1 is USDT (0x...dAC1)
        // We want amountUSDT of token1.
        bytes memory data = abi.encode("flashloan");
        IUniswapV2Pair(UniswapV2USDTWETH).swap(0, amountUSDT, address(this), data);

        // 3. Convert the profit into ETH and send back to sender
        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        if (wethBalance > 0) {
            IWETH(WETH).withdraw(wethBalance);
        }
        payable(msg.sender).transfer(address(this).balance);
    }

    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // 2.1 liquidate the target user
        IERC20(USDT).approve(AaveLendingPool, amount1);
        ILendingPool(AaveLendingPool).liquidationCall(WBTC, USDT, TargetUser, amount1, false);

        // 2.2 swap WBTC for other things or repay directly
        // We swap all WBTC for WETH on SushiSwap
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(this));
        IERC20(WBTC).transfer(SushiSwapWBTCWETH, wbtcBalance);
        
        // SushiSwap WBTC/WETH pair: WBTC is token0 (0x2260... < 0xC02a...)
        (uint112 reserve0_wbtc, uint112 reserve1_weth, ) = IUniswapV2Pair(SushiSwapWBTCWETH).getReserves();
        uint256 wethOut = getAmountOut(wbtcBalance, reserve0_wbtc, reserve1_weth);
        IUniswapV2Pair(SushiSwapWBTCWETH).swap(0, wethOut, address(this), "");

        // Determine repayment amount
        uint256 repayUSDT = amount1 + (amount1 * 3) / 997 + 1;

        // Ensure we swap enough USDC to get `repayUSDT` via Curve 3pool
        // Since 1 USDC ~ 1 USDT, we request `repayUSDT * 1.001` USDC to be safe.
        // Wait, I will just request 2930000000000 USDC.
        uint256 amountUSDC = 2930000000000;
        
        // SushiSwap USDC/WETH pair: USDC is token0 (0xA0b8... < 0xC02a...)
        (uint112 reserve0_usdc, uint112 reserve1_weth2, ) = IUniswapV2Pair(SushiSwapUSDCWETH).getReserves();
        uint256 wethIn = getAmountIn(amountUSDC, reserve1_weth2, reserve0_usdc);
        
        IERC20(WETH).transfer(SushiSwapUSDCWETH, wethIn);
        IUniswapV2Pair(SushiSwapUSDCWETH).swap(amountUSDC, 0, address(this), "");

        // Swap USDC to USDT on Curve
        IERC20(USDC).approve(Curve3pool, amountUSDC);
        
        // Call Curve directly
        // ICurveFi definition needed. I will use a low level call.
        // ICurveFi(Curve3pool).exchange(1, 2, amountUSDC, repayUSDT);
        (bool success, ) = Curve3pool.call(abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", 1, 2, amountUSDC, repayUSDT));
        require(success, "Curve exchange failed");

        // 2.3 repay Uniswap V2
        IERC20(USDT).transfer(msg.sender, repayUSDT);
    }
}

