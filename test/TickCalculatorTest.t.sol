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

    function testToken0Orders() public {
        console.log("\nTesting Token0 Orders (must be ABOVE current tick)");
        int24 currentTick = 100;
        console.log("Current Tick:", currentTick);
        
        // These should succeed because target is above current tick
        uint256[] memory validPrices = new uint256[](2);
        validPrices[0] = 1.5e18;  // Price of 1.5 (positive tick)
        validPrices[1] = 2.0e18;  // Price of 2.0 (positive tick)

        for (uint i = 0; i < validPrices.length; i++) {
            console.log("\nTesting with price:", validPrices[i]);
            
            (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
                calculator.calculateTicks(true, false, validPrices[i], currentTick, 60);

            console.log("Bottom Tick:", bottomTick);
            console.log("Top Tick:", topTick);
            console.log("Raw Target Tick:", rawTargetTick);
        }

        // These should revert because target is below current tick
        uint256[] memory invalidPrices = new uint256[](2);
        invalidPrices[0] = 0.5e18;  // Price of 0.5 (negative tick)
        invalidPrices[1] = 0.8e18;  // Price of 0.8 (negative tick)

        for (uint i = 0; i < invalidPrices.length; i++) {
            console.log("\nTesting with price expected to revert:", invalidPrices[i]);
            
            uint160 targetSqrtPriceX96 = calculator.getSqrtPriceFromPrice(invalidPrices[i]);
            int24 rawTargetTick = calculator.getTickFromPrice(targetSqrtPriceX96);
            int24 expectedTargetTick = (rawTargetTick / 60) * 60;
            
            console.log("Expected to revert with target tick:", expectedTargetTick);
            vm.expectRevert(abi.encodeWithSelector(
                TickCalculatorTest.InvalidExecutionDirection.selector,
                true,
                rawTargetTick,  // use raw instead of rounded
                currentTick
            ));
            calculator.calculateTicks(true, false, invalidPrices[i], currentTick, 60);
        }
    }

    function testToken1Orders() public {
        console.log("\nTesting Token1 Orders (must be BELOW current tick)");
        int24 currentTick = 100;
        console.log("Current Tick:", currentTick);
        
        // These should succeed because target is below current tick
        uint256[] memory validPrices = new uint256[](2);
        validPrices[0] = 0.5e18;  // Price of 0.5 (negative tick)
        validPrices[1] = 0.8e18;  // Price of 0.8 (negative tick)

        for (uint i = 0; i < validPrices.length; i++) {
            console.log("\nTesting with price:", validPrices[i]);
            
            (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
                calculator.calculateTicks(false, false, validPrices[i], currentTick, 60);

            console.log("Bottom Tick:", bottomTick);
            console.log("Top Tick:", topTick);
            console.log("Raw Target Tick:", rawTargetTick);
        }

        // These should revert because target is above current tick
        uint256[] memory invalidPrices = new uint256[](2);
        invalidPrices[0] = 1.5e18;  // Price of 1.5 (positive tick)
        invalidPrices[1] = 2.0e18;  // Price of 2.0 (positive tick)

        for (uint i = 0; i < invalidPrices.length; i++) {
            console.log("\nTesting with price expected to revert:", invalidPrices[i]);
            
            uint160 targetSqrtPriceX96 = calculator.getSqrtPriceFromPrice(invalidPrices[i]);
            int24 rawTargetTick = calculator.getTickFromPrice(targetSqrtPriceX96);
            int24 expectedTargetTick = ((rawTargetTick / 60)) * 60;
            
            console.log("Expected to revert with target tick:", expectedTargetTick);
            vm.expectRevert(abi.encodeWithSelector(
                TickCalculatorTest.InvalidExecutionDirection.selector,
                false,
                rawTargetTick,  // use raw instead of rounded
                currentTick
            ));
            calculator.calculateTicks(false, false, invalidPrices[i], currentTick, 60);
        }
    }

    function testToken0RangeOrders() public {
        console.log("\nTesting Token0 Range Orders (target must be ABOVE current tick)");
        int24 currentTick = 100;
        console.log("Current Tick:", currentTick);
        
        // These should succeed because target is above current tick
        uint256[] memory validPrices = new uint256[](3);
        validPrices[0] = 1.5e18;   // Price of 1.5
        validPrices[1] = 2.0e18;   // Price of 2.0
        validPrices[2] = 2.5e18;   // Price of 2.5

        for (uint i = 0; i < validPrices.length; i++) {
            console.log("\nTesting range order with price:", validPrices[i]);
            
            (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
                calculator.calculateTicks(true, true, validPrices[i], currentTick, 60);

            console.log("Bottom Tick (current):", bottomTick);
            console.log("Top Tick (target):", topTick);
            console.log("Raw Target Tick:", rawTargetTick);
            console.log("Range Size in Ticks:", topTick - bottomTick);
        }
    }

    function testToken1RangeOrders() public {
        console.log("\nTesting Token1 Range Orders (target must be BELOW current tick)");
        int24 currentTick = 100;
        console.log("Current Tick:", currentTick);
        
        // These should succeed because target is below current tick
        uint256[] memory validPrices = new uint256[](3);
        validPrices[0] = 0.5e18;   // Price of 0.5
        validPrices[1] = 0.7e18;   // Price of 0.7
        validPrices[2] = 0.9e18;   // Price of 0.9

        for (uint i = 0; i < validPrices.length; i++) {
            console.log("\nTesting range order with price:", validPrices[i]);
            
            (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
                calculator.calculateTicks(false, true, validPrices[i], currentTick, 60);

            console.log("Bottom Tick (target):", bottomTick);
            console.log("Top Tick (current):", topTick);
            console.log("Raw Target Tick:", rawTargetTick);
            console.log("Range Size in Ticks:", topTick - bottomTick);
        }
    }

    function testRangeOrderEdgeCases() public {
        console.log("\nTesting Range Order Edge Cases");
        int24 currentTick = 0;
        console.log("Current Tick:", currentTick);
        
        // Test token0 range order just above current tick
        uint256 price = 1.01e18; // Price just above 1.0
        console.log("\nTesting token0 range order with price just above current:", price);
        (int24 bottomTick, int24 topTick, uint160 targetSqrtPriceX96, int24 rawTargetTick) = 
            calculator.calculateTicks(true, true, price, currentTick, 60);
        console.log("Bottom Tick (current):", bottomTick);
        console.log("Top Tick (target):", topTick);
        console.log("Range Size in Ticks:", topTick - bottomTick);

        // Test token1 range order just below current tick
        price = 0.99e18; // Price just below 1.0
        console.log("\nTesting token1 range order with price just below current:", price);
        (bottomTick, topTick, targetSqrtPriceX96, rawTargetTick) = 
            calculator.calculateTicks(false, true, price, currentTick, 60);
        console.log("Bottom Tick (target):", bottomTick);
        console.log("Top Tick (current):", topTick);
        console.log("Range Size in Ticks:", topTick - bottomTick);
    }

function testSpecificToken1RangeCase() public {
    console.log("\nTesting Specific Token1 Range Case");
    
    uint160 targetSqrtPrice = calculator.getPriceFromTick(60);
    uint256 targetPrice = uint256(targetSqrtPrice) * uint256(targetSqrtPrice) * 1e18 / (1 << 192);
    
    console.log("Current Tick: 1");
    console.log("Target Price (derived from tick 60):", targetPrice);
    
    // Expect revert with the raw target tick of 59
    vm.expectRevert(abi.encodeWithSelector(
        TickCalculatorTest.InvalidExecutionDirection.selector,
        false,
        59,  // raw target tick
        1    // current tick
    ));
    
    calculator.calculateTicks(
        false,  // isToken0
        true,   // isRange
        targetPrice,
        1,      // currentTick
        60      // tickSpacing
    );
}
}