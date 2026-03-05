# Step 3: Maximizing the Profit (The 120+ ETH Strategy)

## The Problem
After liquidating the user, we have their WBTC, but we owe Uniswap ~`2,925,127 USDT` (our original `2,916,378` loan **plus** the 0.3% flash loan fee).

A basic strategy would just swap all the WBTC back to USDT on the same Uniswap V2 pool. But because of *slippage* and poor liquidity on the WBTC/USDT pair at block `12489619`, you would only earn ~21 ETH in profit.

## The 120+ ETH Solution
To get incredible profits, we need to route our WBTC through more liquid decentralised exchanges (DEXs) like **SushiSwap** and **Curve**.

Here is our optimized routing path:

### 1. SushiSwap: WBTC -> WETH
We sell all our WBTC for Wrapped Ethereum (WETH) on SushiSwap, which has deeper liquidity for WBTC.
```solidity
// Transfer WBTC to SushiSwap pair and execute the swap for WETH
IERC20(WBTC).transfer(SushiSwapWBTCWETH, wbtcBalance);
IUniswapV2Pair(SushiSwapWBTCWETH).swap(0, wethOut, address(this), "");
```

### 2. SushiSwap: WETH -> USDC
Now we have tens of thousands of dollars worth of WETH. We only need to sell *a portion* of this WETH to get exactly enough stablecoins to repay our flash loan debt. 
Wait, why USDC instead of USDT? Because the SushiSwap WETH/USDC pair is much better than their WETH/USDT pair!
```solidity
// Swap just enough WETH to get exactly 2,930,000 USDC on SushiSwap
IERC20(WETH).transfer(SushiSwapUSDCWETH, wethIn);
IUniswapV2Pair(SushiSwapUSDCWETH).swap(amountUSDC, 0, address(this), "");
```

### 3. Curve Finance: USDC -> USDT
We now have 2.93M USDC, but we owe Uniswap USDT. Curve is a DEX specialized entirely on cheap, 1-to-1 stablecoin swaps. We use Curve's `3pool` to perfectly swap our USDC to the exact amount of USDT we owe Uniswap.
```solidity
// We swap USDC to exactly `repayUSDT` on the Curve 3pool
Curve3pool.call(abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", 1, 2, amountUSDC, repayUSDT));
```

### 4. Repay the Loan & Claim Profit
Finally, we send the USDT back to Uniswap to resolve the Flash Loan condition. 
Because we were so efficient with our swaps, we have a **large amount of WETH left over**. 

When the `uniswapV2Call` ends, our main `operate()` function resumes, un-wraps the WETH into raw ETH, and sends it directly to your wallet account.
```solidity
// Convert the profit into ETH and send back to sender
uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
IWETH(WETH).withdraw(wethBalance);
payable(msg.sender).transfer(address(this).balance);
```
**Boom! 120+ ETH profit achieved.**
