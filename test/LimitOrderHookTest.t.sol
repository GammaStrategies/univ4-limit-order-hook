// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LimitOrderHook} from "src/LimitOrderHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

interface ILimitOrderHook {
    struct LimitOrder {
        address owner;      
        bool isToken0;      
        bool isRange;         
        int24 bottomTick;   
        int24 topTick;      
        uint128 liquidity;
        BalanceDelta delta; // Keep only main delta
        PoolKey key;        // Add PoolKey for claiming
    }

    function limitOrders(bytes32 orderId) external view returns (LimitOrder memory);
}


contract LimitOrderHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderHook hook;
    address public treasury;  
    // Track created orders for testing
    bytes32[] public orderIds;

    struct ModifyLiquidityCallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
        uint256 amount0;
        uint256 amount1;
}
    
    // Events for testing
    event LimitOrderExecuted(bytes32 indexed orderId, address indexed owner, uint256 amount0, uint256 amount1);

    function setUp() public {
        // Deploy core V4 contracts
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Set up treasury address
        treasury = makeAddr("treasury");


        // Deploy hook with proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // Deploy the hook
        deployCodeTo(
            "LimitOrderHook.sol",
            abi.encode(manager, treasury), // Pass both manager and treasury to constructor
            hookAddress
        );
        hook = LimitOrderHook(hookAddress);

        // Initialize pool with 1:1 price
        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Approve tokens to hook
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Add initial liquidity for testing
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_treasury_setup() public {
        assertEq(hook.treasury(), treasury, "Treasury not set correctly");
    }
    
    function test_hookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
    }

function test_createLimitOrder_validation() public {
    // Test zero amount
    vm.expectRevert(LimitOrderHook.AmountTooLow.selector);
    hook.createLimitOrder(true, false, 1.02e18, 0, key);

    // Test zero price
    vm.expectRevert(LimitOrderHook.PriceMustBeGreaterThanZero.selector);
    hook.createLimitOrder(true, false, 0, 1 ether, key);

    // Test invalid execution direction (try to place token0 order below current price)
    uint160 targetSqrtPriceX96 = hook.getSqrtPriceFromPrice(0.98e18); // Price below current
    int24 rawTargetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
    int24 expectedTargetTick = (rawTargetTick / key.tickSpacing) * key.tickSpacing;
    
    bytes32 poolId = hook.getPoolId(key);
    (uint160 currentSqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
    
    vm.expectRevert(abi.encodeWithSelector(
        LimitOrderHook.InvalidExecutionDirection.selector,
        true,
        rawTargetTick,
        currentTick
    ));
    hook.createLimitOrder(true, false, 0.98e18, 1 ether, key); // Should fail - trying to sell token0 below current price
}
function test_calculateLiquidity() public {
    uint256 amount = 1 ether;
    bool isToken0 = true;
    
    bytes32 poolId = hook.getPoolId(key);
    (uint160 currentSqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
    
    // Calculate ticks for 1.02 price (above current for token0)
    uint160 targetSqrtPriceX96 = hook.getSqrtPriceFromPrice(1.02e18);
    int24 rawTargetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
    int24 targetTick = (rawTargetTick / key.tickSpacing) * key.tickSpacing;
    
    // For token0, bottomTick is at target, topTick is target + spacing
    int24 bottomTick = targetTick;
    int24 topTick = targetTick + key.tickSpacing;
    
    console.log("Current SqrtPrice:", currentSqrtPriceX96);
    console.log("Bottom Tick SqrtPrice:", TickMath.getSqrtPriceAtTick(bottomTick));
    console.log("Top Tick SqrtPrice:", TickMath.getSqrtPriceAtTick(topTick));
    console.log("Bottom Tick:", bottomTick);
    console.log("Top Tick:", topTick);   
    console.log("Current Tick:", currentTick);  
    console.log("Amount:", amount);
    
    uint128 liquidity = hook._calculateLiquidity(
        isToken0,
        amount,
        bottomTick,
        topTick
    );
    
    console.log("Calculated Liquidity:", liquidity);
}


    function test_createLimitOrder_storage() public {
        uint256 amount = 1 ether;
        bool isToken0 = true;
        bool isRange = false;

        bytes32 poolId = hook.getPoolId(key);
        (uint160 currentSqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
   
        console.log("Target Price:");
        console.logInt(1.02e18);
        console.log("Current Tick:");
        console.logInt(currentTick);
        console.log("Current SqrtPriceX96:");
        console.logUint(currentSqrtPriceX96);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), amount);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), amount);

        bytes32 orderId = hook.createLimitOrder(
            isToken0,
            isRange,
            1.02e18,
            amount,
            key
        );

        {
            ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderId);
            assertEq(order.owner, address(this), "Wrong owner");
            assertEq(order.isToken0, isToken0, "Wrong token direction");
            assertEq(order.isRange, isRange, "Wrong range flag");
        }

        {
            ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderId);
            assertTrue(order.bottomTick < order.topTick, "Invalid tick range");
            assertTrue(order.bottomTick > currentTick, "Token0 order must be above current tick");
        }

        {
            ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderId);
            assertFalse(order.delta != BalanceDelta.wrap(0), "Already executed");
            assertTrue(order.liquidity > 0, "No liquidity");
        }
    }

function test_limitOrder_execution_zeroForOne() public {
    // Set up initial balances using Currency.unwrap()
    deal(Currency.unwrap(currency0), address(this), 100 ether);
    deal(Currency.unwrap(currency1), address(this), 100 ether);
    
    // Create order selling token0 for token1 at higher price
    uint256 sellAmount = 1 ether;
    uint256 limitPrice = 1.02e18; // Price ABOVE current (1.0) for token0 orders
    bytes32 orderId = hook.createLimitOrder(true, false, limitPrice, sellAmount, key);
    
    // Execute large swap that should trigger the limit order
    vm.expectEmit(true, true, false, false);
    emit LimitOrderExecuted(orderId, address(this), sellAmount, 0);
    
    uint160 maxSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK/key.tickSpacing * key.tickSpacing);
    
    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -2 ether,
            sqrtPriceLimitX96: maxSqrtPriceX96
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );

    // Verify order executed and has balance deltas
    ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderId);
    assertTrue(order.delta != BalanceDelta.wrap(0), "Order not executed");

    // Check ERC-6909 balances minted to hook contract
    uint256 currency0Id = uint256(uint160(Currency.unwrap(currency0)));
    uint256 currency1Id = uint256(uint160(Currency.unwrap(currency1)));
    
    uint256 hookBalance0 = manager.balanceOf(address(hook), currency0Id);
    uint256 hookBalance1 = manager.balanceOf(address(hook), currency1Id);

    // Log balances for debugging
    console.log("Hook balance token0:", hookBalance0);
    console.log("Hook balance token1:", hookBalance1);
    
    // Verify some tokens were minted to the hook contract
    assertTrue(hookBalance0 > 0 || hookBalance1 > 0, "No tokens minted to hook");

    // Verify BalanceDelta fields were updated
    int256 delta0 = int256(uint256(uint128(order.delta.amount0())));
    int256 delta1 = int256(uint256(uint128(order.delta.amount1())));


    console.log("Delta token0:", uint256(delta0));
    console.log("Delta token1:", uint256(delta1));


    // Verify that at least one of the deltas is non-zero
    assertTrue(
        delta0 != 0 || delta1 != 0,
        "No balance deltas recorded"
    );
}

function test_claim_limit_order() public {
    // Set up initial balances
    deal(Currency.unwrap(currency0), address(this), 100 ether);
    deal(Currency.unwrap(currency1), address(this), 100 ether);
    
    // Create order selling token0 for token1 at higher price
    uint256 sellAmount = 1 ether;
    uint256 limitPrice = 1.02e18; // Price ABOVE current (1.0) for token0 orders
    bytes32 orderId = hook.createLimitOrder(true, false, limitPrice, sellAmount, key);
    
    // DEBUG: Check the order owner immediately after creation
    ILimitOrderHook.LimitOrder memory orderAfterCreation = ILimitOrderHook(address(hook)).limitOrders(orderId);
    console.log("Order owner:", orderAfterCreation.owner);
    console.log("Test contract address:", address(this));
    
    // Execute large swap that should trigger the limit order
    uint160 maxSqrtPriceX96 = TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK/key.tickSpacing * key.tickSpacing);
    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -2 ether,
            sqrtPriceLimitX96: maxSqrtPriceX96
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );

    // DEBUG: Check the order owner before claiming
    ILimitOrderHook.LimitOrder memory orderBeforeClaim = ILimitOrderHook(address(hook)).limitOrders(orderId);
    console.log("Order owner before claim:", orderBeforeClaim.owner);
    console.log("Order executed status:", orderBeforeClaim.delta != BalanceDelta.wrap(0));
    
    // Try to claim
    hook.claimOrder(orderId, key);
}

function test_multiple_limit_orders_same_tick() public {
    // Deal substantial tokens to test contract and approve
    deal(Currency.unwrap(currency0), address(this), 1000 ether);
    deal(Currency.unwrap(currency1), address(this), 1000 ether);

    // Add initial liquidity first (same as before)
    modifyLiquidityRouter.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        }),
        ZERO_BYTES
    );

    // Track orders for verification
    bytes32[] memory newOrderIds = new bytes32[](3);
    
    // Create just 3 limit orders at same price point
    uint256 limitPrice = 1.02e18;
    uint256 orderAmount = 0.5 ether;
    
    console.log("Creating 3 limit orders...");
    
    bytes32 poolId = hook.getPoolId(key);
    (,int24 currentTick,,) = StateLibrary.getSlot0(
        manager,
        PoolId.wrap(poolId)
    );
    console.log("Current tick before orders:", currentTick);
    
    for(uint i = 0; i < 3; i++) {
        newOrderIds[i] = hook.createLimitOrder(
            true,    // selling token0
            false,   // not range order
            limitPrice,
            orderAmount,
            key
        );
        
        // Log the order details
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[i]);
        console.log("Order", i, "created:");
        console.log(" - Bottom tick:", order.bottomTick);
        console.log(" - Top tick:", order.topTick);
        console.log(" - Liquidity:", order.liquidity);
    }

    // Execute large swap that should trigger all orders
    console.log("\nExecuting swap...");
    console.log("Current tick before swap:", currentTick);

    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -40 ether,  // Reduced amount for 3 orders
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );

    // Get tick after swap
    (,int24 newTick,,) = StateLibrary.getSlot0(
        manager,
        PoolId.wrap(poolId)
    );
    console.log("Current tick after swap:", newTick);

    // Check each order's execution status
    for(uint i = 0; i < 3; i++) {
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[i]);
        console.log("Order", i, "execution status:");
        console.log(" - Delta is non-zero:", order.delta != BalanceDelta.wrap(0));
        console.log(" - Delta amount0:", uint256(uint128(order.delta.amount0())));
        console.log(" - Delta amount1:", uint256(uint128(order.delta.amount1())));
    }
}
 
function test_multiple_limit_order_types() public {
    // Deal tokens
    deal(Currency.unwrap(currency0), address(this), 1000 ether);
    deal(Currency.unwrap(currency1), address(this), 1000 ether);

    // Add initial liquidity for price movement
    modifyLiquidityRouter.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            liquidityDelta: 100 ether,
            salt: bytes32(0)
        }),
        ZERO_BYTES
    );

    // Track orders
    bytes32[] memory newOrderIds = new bytes32[](3);

    bytes32 poolId = hook.getPoolId(key);
    (,int24 currentTick,,) = StateLibrary.getSlot0(
        manager,
        PoolId.wrap(poolId)
    );
    console.log("Current tick before orders:", currentTick);

    // Create and store orderId for first order at 1.5x
    console.log("\nCreating Order 0: Regular limit at 1.5x");
    newOrderIds[0] = hook.createLimitOrder(
        true,    // selling token0
        false,   // not range order
        1.5e18,  // price
        0.5 ether,
        key
    );
    {  
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[0]);
        console.log("Order 0 created:");
        console.log(" - Is Range:", order.isRange);
        console.log(" - Bottom tick:", order.bottomTick);
        console.log(" - Top tick:", order.topTick);
        console.log(" - Liquidity:", order.liquidity);
    }

    // Create and store orderId for second order at 2.0x
    console.log("\nCreating Order 1: Range order at 2.0x");
    newOrderIds[1] = hook.createLimitOrder(
        true,    // selling token0
        true,    // range order
        2e18,    // price
        0.5 ether,
        key
    );
    {  
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[1]);
        console.log("Order 1 created:");
        console.log(" - Is Range:", order.isRange);
        console.log(" - Bottom tick:", order.bottomTick);
        console.log(" - Top tick:", order.topTick);
        console.log(" - Liquidity:", order.liquidity);
    }

    // Create and store orderId for third order at 3.0x
    console.log("\nCreating Order 2: Regular limit at 3.0x");
    newOrderIds[2] = hook.createLimitOrder(
        true,     // selling token0
        false,    // not range order
        3e18,     // price
        0.5 ether,
        key
    );
    {  
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[2]);
        console.log("Order 2 created:");
        console.log(" - Is Range:", order.isRange);
        console.log(" - Bottom tick:", order.bottomTick);
        console.log(" - Top tick:", order.topTick);
        console.log(" - Liquidity:", order.liquidity);
    }
    // Execute large swap that should trigger all orders
    console.log("\nExecuting swap to trigger all orders...");
    console.log("Current tick before swap:", currentTick);

    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: false,  // Swapping token1 for token0
            amountSpecified: -80 ether,  // Large swap to cross all prices up to 3x
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );

    // Get tick after swap
    (,int24 newTick,,) = StateLibrary.getSlot0(
        manager,
        PoolId.wrap(poolId)
    );
    console.log("Current tick after swap:", newTick);
    
    // Calculate and display actual price after swap
    uint160 sqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(newTick));
    uint256 priceAfterX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
    uint256 priceAfter = FullMath.mulDiv(priceAfterX96, 1e18, FixedPoint96.Q96);
    console.log("Price after swap:", priceAfter);

// Verify order 0 (1.5x) was executed
ILimitOrderHook.LimitOrder memory order0 = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[0]);
assertTrue(order0.delta != BalanceDelta.wrap(0), "Order 0 (1.5x) not executed");

// Verify order 1 (2.0x range) was executed
ILimitOrderHook.LimitOrder memory order1 = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[1]);
assertTrue(order1.delta != BalanceDelta.wrap(0), "Order 1 (2.0x range) not executed");

// Verify order 2 (3.0x) was executed 
ILimitOrderHook.LimitOrder memory order2 = ILimitOrderHook(address(hook)).limitOrders(newOrderIds[2]);
assertTrue(order2.delta != BalanceDelta.wrap(0), "Order 2 (3.0x) not executed");
} 
 
function test_afterSwap_gas_limits() public {
    uint256 BATCH_SIZE = 1;
    
    deal(Currency.unwrap(currency0), address(this), 1000000 ether);
    deal(Currency.unwrap(currency1), address(this), 1000000 ether);

    bytes32[] memory orderIds = new bytes32[](BATCH_SIZE);
    uint256 orderCreationGas = 0;
    
    // Create orders
    for(uint256 i = 0; i < BATCH_SIZE; i++) {
        uint256 gasBefore = gasleft();
        orderIds[i] = hook.createLimitOrder(
            true,
            false,
            1.02e18,  // Fixed price point above 1.0
            0.1 ether,
            key
        );
        orderCreationGas += gasBefore - gasleft();
    }
    
    console.log("Total creation gas: %s", orderCreationGas);
    console.log("Average creation gas per order: %s", orderCreationGas / BATCH_SIZE);
    
    // Execute swap
    uint256 swapGasBefore = gasleft();
    
    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -120 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(60))
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
    
    uint256 swapGasUsed = swapGasBefore - gasleft();
    console.log("Swap gas used: %s", swapGasUsed);
    console.log("Average gas per order in swap: %s", swapGasUsed / BATCH_SIZE);
    
    // Verify executions
    uint256 executedOrders = 0;
    for(uint256 i = 0; i < BATCH_SIZE; i++) {
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderIds[i]);
        if(order.delta != BalanceDelta.wrap(0)) {
            executedOrders++;
        }
    }
    
    console.log("Orders executed: %s/%s", executedOrders, BATCH_SIZE);
    console.log("Total gas used: %s", orderCreationGas + swapGasUsed);
}

function test_afterSwap_gas_limits_isToken1() public {
    uint256 BATCH_SIZE = 1;
    
    deal(Currency.unwrap(currency0), address(this), 1000000 ether);
    deal(Currency.unwrap(currency1), address(this), 1000000 ether);

    bytes32[] memory orderIds = new bytes32[](BATCH_SIZE);
    uint256 orderCreationGas = 0;
    
    // Create orders with isToken0 = false (selling token1 at a higher price)
    for (uint256 i = 0; i < BATCH_SIZE; i++) {
        uint256 gasBefore = gasleft();
        orderIds[i] = hook.createLimitOrder(
            false,      // Selling token1
            false,      // Not range order
            0.95e18,    // Price above 1.0 means we expect token1 -> token0 at a higher price point
            0.1 ether,
            key
        );
        orderCreationGas += gasBefore - gasleft();
    }
    
    console.log("Total creation gas: %s", orderCreationGas);
    console.log("Average creation gas per order: %s", orderCreationGas / BATCH_SIZE);
    
    // Execute swap in the opposite direction to move the price down
    // Since isToken0 = false, we need zeroForOne = true to push price downwards, enabling token1-for-token0 execution.
    uint256 swapGasBefore = gasleft();
    swapRouter.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -120 ether,
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(60))
        }),
        PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        }),
        ""
    );
    
    uint256 swapGasUsed = swapGasBefore - gasleft();
    console.log("Swap gas used: %s", swapGasUsed);
    console.log("Average gas per order in swap: %s", swapGasUsed / BATCH_SIZE);
    
    // Verify executions
    uint256 executedOrders = 0;
    for (uint256 i = 0; i < BATCH_SIZE; i++) {
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderIds[i]);
        if (order.delta != BalanceDelta.wrap(0)) {
            executedOrders++;
        }
    }
    
    console.log("Orders executed: %s/%s", executedOrders, BATCH_SIZE);
    console.log("Total gas used: %s", orderCreationGas + swapGasUsed);
}


}