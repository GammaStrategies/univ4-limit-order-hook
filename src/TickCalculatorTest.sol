// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

contract TickCalculatorTest {
    error InvalidPrice(uint256 price);
    error PriceMustBeGreaterThanZero();
    error TickNotDivisibleBySpacing(int24 tick, int24 spacing);
    error InvalidExecutionDirection(bool isToken0, int24 targetTick, int24 currentTick);
    error TickOutOfBounds(int24 tick);

    function calculateTicks(
        bool isToken0,
        bool isRange,
        uint256 price,
        int24 currentTick,
        int24 tickSpacing
    ) public pure returns (
        int24 bottomTick,
        int24 topTick,
        uint160 targetSqrtPriceX96,
        int24 rawTargetTick
    ) {
        targetSqrtPriceX96 = getSqrtPriceFromPrice(price);
        rawTargetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
        (bottomTick, topTick) = _getValidTickRange(
            currentTick,
            rawTargetTick,
            tickSpacing,
            isToken0,
            isRange
        );
    }

    function _getValidTickRange(
        int24 currentTick,
        int24 targetTick,
        int24 tickSpacing,
        bool isToken0,
        bool isRange
    ) internal pure returns (int24 bottomTick, int24 topTick) {
        // Round target tick based on isToken0
        if (isToken0) {
            // For token0 orders, round down to nearest valid tick spacing
            targetTick = (targetTick / tickSpacing) * tickSpacing;
        } else {
            // For token1 orders, round up to next valid tick spacing
            targetTick = ((targetTick / tickSpacing) + 1) * tickSpacing;
        }
        
        if (isToken0) {
            // Selling token0, executes on price decrease
            if (isRange) {
                bottomTick = targetTick;
                // Find largest valid tick spacing <= currentTick
                topTick = (currentTick / tickSpacing) * tickSpacing;
            } else {
                // Single tick order spans exactly one tick spacing
                bottomTick = targetTick;
                topTick = targetTick + tickSpacing;
            }
            // Validate that target is below current price for token0 orders
            if (bottomTick >= currentTick) {
                revert InvalidExecutionDirection(true, targetTick, currentTick);
            }
        } else {
            // Selling token1, executes on price increase
            if (isRange) {
                // Find smallest valid tick spacing > currentTick
                bottomTick = ((currentTick / tickSpacing) + 1) * tickSpacing;
                topTick = targetTick;
            } else {
                // Single tick order spans exactly one tick spacing
                bottomTick = targetTick - tickSpacing;
                topTick = targetTick;
            }
            // Validate that target is above current price for token1 orders
            if (topTick <= currentTick) {
                revert InvalidExecutionDirection(false, targetTick, currentTick);
            }
        }
        
        // Ensure ticks are within valid range for the pool
        if (bottomTick < TickMath.minUsableTick(tickSpacing) || 
            topTick > TickMath.maxUsableTick(tickSpacing)) {
            revert TickOutOfBounds(targetTick);
        }
    }

    // Helper functions from the original contract
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function getSqrtPriceFromPrice(uint256 price) internal pure returns (uint160) {
        if (price == 0) revert PriceMustBeGreaterThanZero();
        
        // price = token1/token0
        // Convert price to Q96 format first
        uint256 priceQ96 = FullMath.mulDiv(price, FixedPoint96.Q96, 1 ether); // Since input price is in 1e18 format
    
        // Take square root using our sqrt function
        uint256 sqrtPriceX96 = sqrt(priceQ96) << 48;
        
        if (sqrtPriceX96 > type(uint160).max) revert InvalidPrice(price);
        
        return uint160(sqrtPriceX96);
    }

    // Additional helper functions for testing
    function getPriceFromTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function getTickFromPrice(uint160 sqrtPriceX96) public pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }
}