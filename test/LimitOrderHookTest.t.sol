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

        // Initialize pool
        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Approve tokens to hook
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Add initial liquidity
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

    function test_createLimitOrder_zeroForOne() public {
        uint256 amount = 1 ether;
        uint256 price = 0.98e18;  // Price below current for zeroForOne
        bool isToken0 = true;
        bool isRange = false;

        bytes32 orderId = hook.createLimitOrder(
            isToken0,
            isRange,
            price,
            amount,
            key
        );

        (
            address owner,
            bool orderIsToken0,
            bool orderIsRange,
            ,,,
            bool executed,
            ,,,, 
            uint128 liquidity
        ) = hook.limitOrders(orderId);

        assertEq(owner, address(this), "Wrong owner");
        assertEq(orderIsToken0, isToken0, "Wrong token direction");
        assertEq(orderIsRange, isRange, "Wrong range flag");
        assertTrue(liquidity > 0, "No liquidity");
        assertFalse(executed, "Already executed");
    }

    function test_orderExecution_zeroForOne() public {
        uint256 amount = 1 ether;
        uint256 price = 0.98e18;
        bool isToken0 = true;
        bool isRange = false;

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes32 orderId = hook.createLimitOrder(
            isToken0,
            isRange,
            price,
            amount,
            key
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        (, , , , , , bool executed, , , , , ) = hook.limitOrders(orderId);
        assertTrue(executed, "Order not executed");

        hook.claimLimitOrder(orderId, key);

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        assertTrue(token1BalanceAfter > token1BalanceBefore, "Should receive token1");
        assertTrue(token0BalanceAfter < token0BalanceBefore, "Should spend token0");
    }

    function test_orderExecution_oneForZero() public {
        // Get current tick to set appropriate price
        bytes32 poolId = getPoolId(key);
        (,int24 currentTick,,) = StateLibrary.getSlot0(manager, PoolId.wrap(poolId));
        
        uint256 amount = 1 ether;
        uint256 price = 1.02e18;  // Price above current for oneForZero
        bool isToken0 = false;
        bool isRange = false;

        uint256 token0BalanceBefore = currency0.balanceOfSelf();
        uint256 token1BalanceBefore = currency1.balanceOfSelf();

        bytes32 orderId = hook.createLimitOrder(
            isToken0,
            isRange,
            price,
            amount,
            key
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -2 ether,
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        (, , , , , , bool executed, , , , , ) = hook.limitOrders(orderId);
        assertTrue(executed, "Order not executed");

        hook.claimLimitOrder(orderId, key);

        uint256 token0BalanceAfter = currency0.balanceOfSelf();
        uint256 token1BalanceAfter = currency1.balanceOfSelf();

        assertTrue(token0BalanceAfter > token0BalanceBefore, "Should receive token0");
        assertTrue(token1BalanceAfter < token1BalanceBefore, "Should spend token1");
    }

    function test_multipleOrders_execution() public {
        bool isToken0 = true;
        bool isRange = false;
        uint256 amount = 1 ether;

        bytes32 orderId1 = hook.createLimitOrder(
            isToken0,
            isRange,
            0.98e18,
            amount,
            key
        );

        bytes32 orderId2 = hook.createLimitOrder(
            isToken0,
            isRange,
            0.96e18,
            amount,
            key
        );

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -4 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );

        (, , , , , , bool executed1, , , , , ) = hook.limitOrders(orderId1);
        (, , , , , , bool executed2, , , , , ) = hook.limitOrders(orderId2);
        assertTrue(executed1, "First order not executed");
        assertTrue(executed2, "Second order not executed");

        hook.claimLimitOrder(orderId1, key);
        hook.claimLimitOrder(orderId2, key);
    }

    function getPoolId(PoolKey memory _key) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            _key.currency0,
            _key.currency1,
            _key.fee,
            _key.tickSpacing,
            _key.hooks
        ));
    }
}