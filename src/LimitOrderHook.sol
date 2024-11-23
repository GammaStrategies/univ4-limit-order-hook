// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";



contract LimitOrderHook is BaseHook {
    using CurrencySettler for Currency;


    // Struct to represent a limit order
    struct LimitOrder {
        address recipient;      // Who receives the filled order
        bool isToken0;         // Whether the input token is token0
        bool isRange;          // Whether this is a range order or single-tick limit order
        int24 targetTick;      // Target tick for single-tick limit orders
        uint256 amount;        // Amount of input token
        uint128 liquidity;     // Liquidity amount
        int24 bottomTick;      // Bottom tick for range orders
        int24 topTick;         // Top tick for range orders
        bool executed;         // Whether the order has been executed 
    }

    struct VirtualPool {
        // Mirror of all pool liquidity
        mapping(int24 => uint128) liquidityPerTick;

        // Additional state for limit orders
        mapping(bytes32 => LimitOrder) limitOrders;

        // Track which ticks have limit orders using EnumerableSet
        EnumerableSet.Int24Set limitOrderTicks; 
        // Current virtual price (might differ from real pool after executions)
        int24 currentTick;
    }

    mapping(bytes32 => VirtualPool) public virtualPools;

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,  // We want to intercept all liquidity adds
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,  // Adjust swap outputs here
            afterAddLiquidityReturnDelta: false, 
            afterRemoveLiquidityReturnDelta: true // Adjust removal amounts based on execution state
        });
    }

    // Intercept all liquidity adds to mirror in virtual pool
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) external override returns (bytes4) {
        bytes32 poolId = keccak256(abi.encode(key));
        VirtualPool storage vPool = virtualPools[poolId];
        
        // Mirror liquidity in virtual pool
        vPool.totalLiquidityPerTick[params.tickLower] += uint128(params.liquidityDelta);
        vPool.totalLiquidityPerTick[params.tickUpper] += uint128(params.liquidityDelta);

        // If this is a limit order, track additional info
        if (data.length > 0) {
            (bool isLimitOrder, int24 targetTick, bool isRange, int24 bottomTick, int24 topTick) = 
                abi.decode(data, (bool, int24, bool, int24, int24));
            
            if (isLimitOrder) {
                bytes32 orderId = keccak256(abi.encode(sender, block.timestamp, params));
                vPool.limitOrders[orderId] = LimitOrder({
                    recipient: sender,
                    isToken0: params.tickLower < vPool.currentTick,
                    isRange: isRange,
                    targetTick: targetTick,
                    amount: 0, // Will be set after add liquidity
                    liquidity: uint128(params.liquidityDelta),
                    bottomTick: bottomTick,
                    topTick: topTick,
                    executed: false
                });

                if (isRange) {
                    vPool.isLimitOrderTick[bottomTick] = true;
                    vPool.isLimitOrderTick[topTick] = true;
                } else {
                    vPool.isLimitOrderTick[targetTick] = true;
                }
            }
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterSwapReturnDelta(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta realDelta,
        bytes calldata
    ) external override returns (BalanceDelta) {
        bytes32 poolId = keccak256(abi.encode(key));
        VirtualPool storage vPool = virtualPools[poolId];

        // Store old tick for checking crossed limit orders
        int24 oldTick = vPool.currentTick;
        
        // Execute swap in virtual pool and get virtual amounts
        (int256 virtualAmount0, int256 virtualAmount1) = executeVirtualSwap(
            vPool,
            params,
            oldTick,
            realDelta
        );

        // Return difference between virtual and real amounts
        return BalanceDelta.wrap(
            virtualAmount0 - realDelta.amount0(),
            virtualAmount1 - realDelta.amount1()
        );
    }

    function executeVirtualSwap(
        VirtualPool storage vPool,
        IPoolManager.SwapParams calldata params,
        int24 oldTick,
        BalanceDelta realDelta
    ) internal returns (int256 virtualAmount0, int256 virtualAmount1) {
        vPool.currentTick = computeNewTick(params, realDelta);
        
        // Get range of ticks to check
        int24 startTick = params.zeroForOne ? oldTick : vPool.currentTick;
        int24 endTick = params.zeroForOne ? vPool.currentTick : oldTick;
        
        // Use EnumerableSet to efficiently find relevant ticks
        uint256 length = vPool.limitOrderTicks.length();
        for (uint256 i = 0; i < length; ) {
            int24 tick = vPool.limitOrderTicks.at(i);
            
            // Check if tick is in our range
            if (tick >= startTick && tick <= endTick) {
                executeOrdersAtTick(vPool, tick);
                // Optional: remove tick if all orders executed
                if (allOrdersExecutedAtTick(vPool, tick)) {
                    vPool.limitOrderTicks.remove(tick);
                    // Don't increment i since we removed an element
                    continue;
                }
            }
            unchecked { ++i; }
        }
        
        return calculateVirtualSwapAmounts(vPool, params, realDelta);
    }

    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta realDelta,
        bytes calldata hookData
    ) external override returns (BalanceDelta) {
        bytes32 poolId = keccak256(abi.encode(key));
        VirtualPool storage vPool = virtualPools[poolId];
        
        // Update virtual pool total liquidity
        vPool.totalLiquidityPerTick[params.tickLower] -= uint128(params.liquidityDelta);
        vPool.totalLiquidityPerTick[params.tickUpper] -= uint128(params.liquidityDelta);

        // If this is a limit order, calculate based on execution state
        if (hookData.length > 0) {
            bytes32 orderId = abi.decode(hookData, (bytes32));
            LimitOrder storage order = vPool.limitOrders[orderId];
            
            if (order.executed) {
                // Calculate amounts as if executed at target price
                (int256 virtualAmount0, int256 virtualAmount1) = 
                    calculateExecutedAmounts(order, uint128(-params.liquidityDelta));
                
                return BalanceDelta.wrap(
                    virtualAmount0 - realDelta.amount0(),
                    virtualAmount1 - realDelta.amount1()
                );
            }
        }

        return BalanceDelta.wrap(0, 0);
    }

    function placeLimitOrder(...) {
        // ... other logic ...
        
        // Add to EnumerableSet instead of mapping
        if (isRange) {
            vPool.limitOrderTicks.add(bottomTick);
            vPool.limitOrderTicks.add(topTick);
        } else {
            vPool.limitOrderTicks.add(targetTick);
        }
    }
    // Helper functions to implement:
    // - computeNewTick()
    // - executeOrdersAtTick()
    // - calculateVirtualSwapAmounts()
    // - calculateExecutedAmounts()
}





