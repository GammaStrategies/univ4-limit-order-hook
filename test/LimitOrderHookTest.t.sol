// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
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

contract LimitOrderHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LimitOrderHook hook;
    
    // Track created orders for testing
    bytes32[] public orderIds;
    
    // Events for testing
    event LimitOrderExecuted(bytes32 indexed orderId, address indexed owner, uint256 amount0, uint256 amount1);

    function setUp() public {
        // Deploy core V4 contracts
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy hook with proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);

        // Deploy the hook
        deployCodeTo("LimitOrderHook.sol", abi.encode(manager), hookAddress);
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
        hook.createLimitOrder(true, false, 0.98e18, 0, key);

        // Test zero price
        vm.expectRevert(LimitOrderHook.PriceMustBeGreaterThanZero.selector);
        hook.createLimitOrder(true, false, 0, 1 ether, key);

        // Test invalid execution direction (try to place buy above current price)
        vm.expectRevert(abi.encodeWithSelector(LimitOrderHook.InvalidExecutionDirection.selector, true, 0, 0));
        hook.createLimitOrder(true, false, 1.02e18, 1 ether, key);
    }

// function test_createLimitOrder_storage() public {
//     uint256 amount = 1 ether;
//     bool isToken0 = true;
//     bool isRange = false;

//     // First approve tokens to the pool manager
//     IERC20Minimal(Currency.unwrap(currency0)).approve(address(manager), amount);
//     IERC20Minimal(Currency.unwrap(currency1)).approve(address(manager), amount);

//     // Then create order
//     bytes32 orderId = hook.createLimitOrder(
//         isToken0,
//         isRange,
//         0.98e18,
//         amount,
//         key
//     );

//     // Split struct into multiple calls to avoid stack depth issues
//     {
//         // Check basic order parameters
//         (
//             address owner,
//             bool orderIsToken0,
//             bool orderIsRange,
//             ,,,,,,,, // Skip remaining 8 parameters
//         ) = hook.limitOrders(orderId);
        
//         assertEq(owner, address(this), "Wrong owner");
//         assertEq(orderIsToken0, isToken0, "Wrong token direction");
//         assertEq(orderIsRange, isRange, "Wrong range flag");
//     }

//     {
//         // Check tick parameters
//         (
//             ,,, // Skip first 3 parameters
//             int24 targetTick,
//             int24 bottomTick,
//             int24 topTick,
//             ,,,,, // Skip remaining 4 parameters
//         ) = hook.limitOrders(orderId);
        
//         assertTrue(bottomTick < topTick, "Invalid tick range");
//     }

//     {
//         // Check execution and liquidity parameters
//         (
//             ,,,,,, // Skip first 6 parameters
//             bool executed,
//             int256 token0Delta,
//             int256 token1Delta,
//             uint256 fees0,
//             uint256 fees1,
//             uint128 liquidity
//         ) = hook.limitOrders(orderId);
        
//         assertFalse(executed, "Already executed");
//         assertTrue(liquidity > 0, "No liquidity");
//         assertTrue(token0Delta != 0 || token1Delta != 0, "No token delta");
//         assertEq(fees0, 0, "Initial fees should be 0");
//         assertEq(fees1, 0, "Initial fees should be 0");
//     }
// }

//     function test_limitOrder_execution_zeroForOne() public {
//         // Create order selling token0 for token1
//         uint256 sellAmount = 1 ether;
//         uint256 limitPrice = 0.98e18; // Price below current
//         bytes32 orderId = hook.createLimitOrder(true, false, limitPrice, sellAmount, key);
        
//         uint256 token0Before = currency0.balanceOfSelf();
//         uint256 token1Before = currency1.balanceOfSelf();

//         // Execute large swap that should trigger the limit order
//         vm.expectEmit(true, true, false, false);
//         emit LimitOrderExecuted(orderId, address(this), 0, 0);
        
//         swapRouter.swap(
//             key,
//             IPoolManager.SwapParams({
//                 zeroForOne: false,
//                 amountSpecified: -2 ether, // Large swap opposite direction
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
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

//         assertEq(token0Before - token0After, sellAmount, "Incorrect token0 amount");
//         assertTrue(token1After > token1Before, "No token1 received");
//     }

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