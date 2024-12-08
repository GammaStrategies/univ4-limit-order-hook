# LimitOrderHook

A Uniswap v4 Hook implementation for limit orders and range limit orders on Uniswap v4 pools.

## Overview

The LimitOrderHook contract enables users to place limit orders and range limit orders on Uniswap v4 pools. It supports both token0→token1 and token1→token0 orders, with the ability to specify exact price points or price ranges for order execution.

## Features

- Traditional limit orders at specific price points
- Range limit orders across a price range
- Automatic order execution during swaps
- Fee accrual for limit orders that collect fees while active
- Treasury fee collection (20% of fees)
- Order claiming system for executed orders

## Key Components

### Order Types

1. **Single-Price Limit Orders**
   - Execute at a specific price point
   - Use a single tick spacing for the order

2. **Range Limit Orders**
   - Execute across a range of prices
   - Collect fees while active in the range
   - Automatically execute when price moves through the range

### State Management

- Orders are tracked using a bitmap system for efficient traversal
- Each order is stored with its full state, including:
  - Owner address
  - Token direction (token0 or token1)
  - Price range (bottom and top ticks)
  - Liquidity amount
  - Execution status

## Main Functions

### External Functions

```solidity
function createLimitOrder(
    bool isToken0,
    bool isRange,
    uint256 price,
    uint256 amount,
    PoolKey calldata key
) external returns (bytes32 orderId)
```
Creates a new limit order with the specified parameters.

```solidity
function claimOrder(bytes32 orderId, PoolKey calldata key) external
```
Claims an executed order, distributing tokens and fees to the order owner.

### View Functions

```solidity
function getHookPermissions() public pure returns (Hooks.Permissions memory)
```
Returns the hook's permissions for the Uniswap v4 pool.

## System Architecture

1. **Order Creation**
   - Validates input parameters
   - Calculates appropriate ticks based on price
   - Handles token transfers
   - Creates liquidity position
   - Stores order data

2. **Order Execution**
   - Triggered by swaps
   - Scans relevant tick range
   - Executes eligible orders
   - Updates order state

3. **Order Claiming**
   - Verifies order execution
   - Calculates principal and fees
   - Distributes tokens to owner and treasury
   - Cleans up order data

## Fee Structure

- Original swap amount is returned as principal
- Additional tokens received are considered fees
- 20% of fees go to treasury
- 80% of fees go to order owner

## Usage Example

```solidity
// Create a limit order
bytes32 orderId = hook.createLimitOrder(
    true,                // isToken0
    false,              // not a range order
    parsePrice("1000"), // price
    parseAmount("1"),   // amount
    poolKey             // pool key
);

// After execution, claim the order
hook.claimOrder(orderId, poolKey);
```

## Security Considerations

- Implements checks for price and amount validity
- Validates tick ranges
- Ensures proper order execution direction
- Prevents duplicate order execution
- Uses safe math operations
- Implements ownership checks for claiming

## Dependencies

- Uniswap v4 core contracts
- OpenZeppelin contracts for utility functions
- Safe math libraries for calculations

## Development and Testing

Built using Forge/Foundry for Solidity development.

