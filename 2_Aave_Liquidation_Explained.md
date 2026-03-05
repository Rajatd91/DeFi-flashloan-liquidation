# Step 2: The Aave Liquidation process

## Liquidating the Undercollateralized Target
After Uniswap transfers the 2.9M USDT into our smart contract in `uniswapV2Call()`, we use that USDT immediately to perform the liquidation. Our target user borrowed USDT using WBTC as collateral, but the value of their WBTC dropped so much that their Aave "Health Factor" fell below 1.

```solidity
// First, we must "approve" the Aave Smart Contract to take our borrowed USDT
IERC20(USDT).approve(AaveLendingPool, amount1);

// Then, we call the Aave contract to trigger the liquidation on the target user
ILendingPool(AaveLendingPool).liquidationCall(
    WBTC,        // The collateral we want to claim from the user
    USDT,        // The crypto we are repaying the debt with
    TargetUser,  // The bad user whose position is getting liquidated
    amount1,     // The amount of USDT we are repaying (our whole flashloan)
    false        // 'false' means we want raw WBTC, not Aave's aWBTC token
);
```

### What happens when `liquidationCall` executes?
1. Aave takes the 2.9M USDT from our contract.
2. Aave checks if the `TargetUser` is actually liquidatable. If yes, it pays off their USDT debt.
3. Aave takes the Target User's WBTC collateral and transfers it **to us** plus a "liquidation penalty bonus" (typically 5-10% extra collateral).
4. Our contract now holds a massive amount of WBTC.

In the final step, we will sell this WBTC to pay back the Flash Loan and secure a profit!
