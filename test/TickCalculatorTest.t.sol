// File: test/TickCalculator.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TickCalculatorTest.sol";

contract TickCalculatorTest_Test is Test {
    TickCalculatorTest public calculator;

    function setUp() public {
        calculator = new TickCalculatorTest();
    }

    function testBasicCalculation() public {
        // Test parameters
        bool isToken0 = true;
        bool isRange = false;
        uint256 price = 1e18; // Price of 1.0
        int24 currentTick = 100;
        int24 tickSpacing = 60;

        // Get results
        (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
            calculator.calculateTicks(isToken0, isRange, price, currentTick, tickSpacing);

        // Log results
        console.log("Bottom Tick:", bottomTick);
        console.log("Top Tick:", topTick);
        console.log("Target Sqrt Price X96:", targetSqrtPriceX96);
        console.log("Raw Target Tick:", rawTargetTick);
    }

    function testPriceRange() public {
        // Test with different prices
        uint256[] memory prices = new uint256[](3);
        prices[0] = 0.5e18;  // Price of 0.5
        prices[1] = 1e18;    // Price of 1.0
        prices[2] = 2e18;    // Price of 2.0

        for (uint i = 0; i < prices.length; i++) {
            console.log("\nTesting with price:", prices[i]);
            
            (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
                calculator.calculateTicks(true, false, prices[i], 100, 60);

            console.log("Bottom Tick:", bottomTick);
            console.log("Top Tick:", topTick);
            console.log("Target Sqrt Price X96:", targetSqrtPriceX96);
            console.log("Raw Target Tick:", rawTargetTick);
        }
    }

    function testRangeOrders() public {
        console.log("\nTesting Range Orders");
        
        (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
            calculator.calculateTicks(true, true, 0.8e18, 100, 60);

        console.log("Range Order Results:");
        console.log("Bottom Tick:", bottomTick);
        console.log("Top Tick:", topTick);
        console.log("Target Sqrt Price X96:", targetSqrtPriceX96);
        console.log("Raw Target Tick:", rawTargetTick);
    }
}