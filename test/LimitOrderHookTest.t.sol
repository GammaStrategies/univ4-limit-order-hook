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


interface ILimitOrderHook {
    struct LimitOrder {
        address owner;      
        bool isToken0;      
        bool isRange;       
        bool executed;      
        int24 bottomTick;   
        int24 topTick;      
        uint128 liquidity;  
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
        expectedTargetTick,
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
            assertFalse(order.executed, "Already executed");
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
        
        // Get initial token balances
        uint256 token0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));

        // Approve tokens for swap
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), 2 ether);
        
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

        // Verify order executed
        ILimitOrderHook.LimitOrder memory order = ILimitOrderHook(address(hook)).limitOrders(orderId);
        assertTrue(order.executed, "Order not executed");

        // Get token balances in PoolManager
        uint256 currency0Id = uint256(uint160(Currency.unwrap(currency0)));
        uint256 currency1Id = uint256(uint160(Currency.unwrap(currency1)));
        
        uint256 balance0 = manager.balanceOf(address(this), currency0Id);
        uint256 balance1 = manager.balanceOf(address(this), currency1Id);

        // Claim tokens through PoolManager with unlock
        if (balance0 > 0 || balance1 > 0) {
            bytes memory unlockData = abi.encode(
                currency0Id,
                currency1Id,
                balance0,
                balance1
            );
            manager.unlock(unlockData);
        }

        // Just verify we received token1
        uint256 token1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(this));
        console.log("Token1 Before:", token1Before);
        console.log("Token1 After:", token1After);
        console.log("Balance1 from PoolManager:", balance1);
        console.log("Raw difference:", token1After - (token1Before - 2 ether + balance1));

        // Check that we're within 0.5 ETH of our expected value (to account for fees and price impact)
        uint256 expectedApprox = token1Before - 2 ether + balance1;
        assertApproxEqRel(
            token1After,
            expectedApprox,
            0.005e18,  // 0.5% tolerance
            "Token1 balance outside acceptable range"
        );
    }


    function unlockCallback(bytes calldata data) external returns (bytes memory) {
    (
        uint256 currency0Id,
        uint256 currency1Id,
        uint256 balance0,
        uint256 balance1
    ) = abi.decode(data, (uint256, uint256, uint256, uint256));

    // Claim token0 if any
    if (balance0 > 0) {
        manager.burn(address(this), currency0Id, balance0);
        manager.take(currency0, address(this), balance0);
    }
    
    // Claim token1 if any
    if (balance1 > 0) {
        manager.burn(address(this), currency1Id, balance1);
        manager.take(currency1, address(this), balance1);
    }

    return "";
}


    //     function test_limitOrder_execution_oneForZero() public {
//         // Create order selling token1 for token0
//         uint256 sellAmount = 1 ether;
//         uint256 limitPrice = 1.02e18; // Price above current
//         bytes32 orderId = hook.createLimitOrder(false, false, limitPrice, sellAmount, key);

//         uint256 token0Before = currency0.balanceOfSelf();
//         uint256 token1Before = currency1.balanceOfSelf();

//         // Execute large swap that should trigger the limit order
//         vm.expectEmit(true, true, false, false);
//         emit LimitOrderExecuted(orderId, address(this), 0, 0);
        
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: true,
//                 amountSpecified: -2 ether,
//                 sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
//             }),
//             PoolSwapTest.TestSettings({
//                 takeClaims: false,
//                 settleUsingBurn: false
//             }),
//             ZERO_BYTES
//         );

//         // Verify order executed
//         (,,,,,,bool executed,,,,,) = hook.limitOrders(orderId);
//         assertTrue(executed, "Order not executed");

//         // Claim and verify balances
//         hook.claimLimitOrder(orderId, key);
        
//         uint256 token0After = currency0.balanceOfSelf();
//         uint256 token1After = currency1.balanceOfSelf();

//         assertTrue(token0After > token0Before, "No token0 received");
//         assertEq(token1Before - token1After, sellAmount, "Incorrect token1 amount");
//     }

//     function test_range_orders() public {
//         // Test range order creation and execution
//         uint256 amount = 1 ether;
//         uint256 price = 0.98e18;
//         bool isToken0 = true;
//         bool isRange = true;

//         bytes32 orderId = hook.createLimitOrder(
//             isToken0,
//             isRange,
//             price,
//             amount,
//             key
//         );

//         // Verify range order specific parameters
//         (,, bool orderIsRange,,int24 bottomTick, int24 topTick,,,,,, uint128 liquidity) = hook.limitOrders(orderId);
//         assertTrue(orderIsRange, "Not marked as range order");
//         assertTrue(bottomTick < topTick, "Invalid range");
//         assertTrue(liquidity > 0, "No liquidity");

//         // Execute range order
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: false,
//                 amountSpecified: -2 ether,
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );

//         // Verify execution
//         (,,,,,,bool executed,,,,,) = hook.limitOrders(orderId);
//         assertTrue(executed, "Range order not executed");
//     }

//     function test_multiple_orders_execution() public {
//         // Create multiple orders at different price points
//         bytes32[] memory orders = new bytes32[](3);
//         orders[0] = hook.createLimitOrder(true, false, 0.98e18, 1 ether, key);
//         orders[1] = hook.createLimitOrder(true, false, 0.97e18, 1 ether, key);
//         orders[2] = hook.createLimitOrder(true, false, 0.96e18, 1 ether, key);

//         // Large swap to trigger all orders
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: false,
//                 amountSpecified: -5 ether,
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );

//         // Verify all orders executed
//         for(uint i = 0; i < orders.length; i++) {
//             (,,,,,,bool executed,,,,,) = hook.limitOrders(orders[i]);
//             assertTrue(executed, string.concat("Order ", vm.toString(i), " not executed"));
            
//             // Claim each order
//             hook.claimLimitOrder(orders[i], key);
//         }
//     }

//     function test_transient_storage() public {
//         // Test that transient storage is working correctly for tick tracking
//         bytes32 orderId = hook.createLimitOrder(true, false, 0.98e18, 1 ether, key);
        
//         // Record starting tick
//         bytes32 poolId = getPoolId(key);
//         (,int24 startTick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
        
//         // Execute swap
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: false,
//                 amountSpecified: -2 ether,
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );
        
//         // Verify order executed
//         (,,,,,,bool executed,,,,,) = hook.limitOrders(orderId);
//         assertTrue(executed, "Order should execute if transient storage working");
//     }

//     function test_claiming() public {
//         // Test claim restrictions and token transfers
//         bytes32 orderId = hook.createLimitOrder(true, false, 0.98e18, 1 ether, key);
        
//         // Should not be able to claim unexecuted order
//         vm.expectRevert("Order not executed");
//         hook.claimLimitOrder(orderId, key);
        
//         // Execute order
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: false,
//                 amountSpecified: -2 ether,
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
//             ZERO_BYTES
//         );
        
//         // Test claiming as non-owner
//         address nonOwner = address(0xdead);
//         vm.prank(nonOwner);
//         vm.expectRevert("Not owner");
//         hook.claimLimitOrder(orderId, key);
        
//         // Successful claim
//         uint256 token0Before = currency0.balanceOfSelf();
//         uint256 token1Before = currency1.balanceOfSelf();
        
//         hook.claimLimitOrder(orderId, key);
        
//         uint256 token0After = currency0.balanceOfSelf();
//         uint256 token1After = currency1.balanceOfSelf();
        
//         assertTrue(token0After != token0Before || token1After != token1Before, "No tokens transferred");
//     }

//     function getPoolId(PoolKey memory _key) internal pure returns (bytes32) {
//         return keccak256(abi.encode(
//             _key.currency0,
//             _key.currency1,
//             _key.fee,
//             _key.tickSpacing,
//             _key.hooks
//         ));
//     }
}