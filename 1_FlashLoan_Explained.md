# Step 1: Understanding the Uniswap Flash Loan

## What is a Flash Loan?
A Flash Loan allows you to borrow millions of dollars of cryptocurrencies with **zero collateral**. The only catch? You must repay the loan (plus a tiny ~0.3% fee) *in the exact same transaction*. If you don't repay it by the end of your contract execution, the entire transaction reverts, and it's like nothing ever happened!

## How we do it in our Code
To execute the flash loan, we first look at our `operate()` function:

```solidity
// 1. We tell Uniswap: "Hey, give me 2,916,378 USDT right now!"
bytes memory data = abi.encode("flashloan");
IUniswapV2Pair(UniswapV2USDTWETH).swap(0, amountUSDT, address(this), data);
```

Because we pass `data` in the `swap()` function, Uniswap knows this is a Flash Loan. 
Uniswap immediately sends our smart contract the requested USDT, and then it automatically pauses its own `swap()` function to call **our** `uniswapV2Call()` function.

```solidity
function uniswapV2Call(
    address sender,
    uint256 amount0,
    uint256 amount1, // This is our 2,916,378 USDT!
    bytes calldata data
) external override {
    // This is where we hold the borrowed USDT and do our liquidation!
    // At the very end of this function, we MUST have enough USDT to repay the loan.
}
```

This is the magic part! Inside `uniswapV2Call`, we have temporary access to the 2.9M USDT. We will use this money in the next step to liquidate the Aave user!
