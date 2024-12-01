// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {TransientSlot} from "../lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract LimitOrderHook is BaseHook {
    using CurrencySettler for Currency;
    using TransientSlot for *; 
    using TickBitmap for mapping(int16 => uint256);


    // Struct to represent a limit order
    // Need to handle locking when creating limit order, burning limit order, and claiming 


    struct LimitOrder {
        address owner;      // Who is eligible to claim the proceeds from the limit order upon execution
        bool isToken0;         // Whether the input token is token0
        bool isRange;          // Whether this is a range order or single-tick limit order
        int24 targetTick;      // Target tick for single-tick limit orders
        int24 bottomTick;      // Bottom tick for range orders
        int24 topTick;         // Top tick for range orders
        bool executed;         // Whether the order has been executed 
        int256 token0Delta;   // Track exact amount of token0 to claim
        int256 token1Delta;   // Track exact amount of token1 to claim
        uint256 executionFees0; // Fees earned in token0
        uint256 executionFees1;  // Fees earned in token1
        uint128 liquidity;  
    }
   
    struct OrderParams {
        bool isToken0;
        bool isRange;
        int24 bottomTick;
        int24 topTick;
        uint128 liquidity;
        int24 tickSpacing;  
    }

    struct ModifyLiquidityCallbackData {
        PoolKey key;
        int24 bottomTick;
        int24 topTick;
        int256 liquidityDelta;
        bytes32 salt;
    }

    struct BatchExecuteData {
        PoolKey key;
        LimitOrder[] ordersToProcess;
        bytes32[] orderIds;
        int256 totalToken0Delta;
        int256 totalToken1Delta;
    }


    // Add slot constant 
    bytes32 private constant PREVIOUS_TICK_SLOT = keccak256("xyz.hooks.limitorder.previous-tick");

    
    // Mapping from poolId to tick to orderIds
    mapping(bytes32 => mapping(int24 => bytes32[])) public tickToOrders;
    // All limit orders
    mapping(bytes32 => LimitOrder) public limitOrders;
    // Track which ticks have limit orders

    mapping(bytes32 => mapping(int16 => uint256)) public tickBitmap;
    
    event LimitOrderExecuted(bytes32 indexed orderId, address indexed owner, uint256 amount0, uint256 amount1);

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,  
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false, 
            afterRemoveLiquidity: false,
            beforeSwap: true,  // Need to record old tick
            afterSwap: true,  // Execute limit orders
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,  
            afterAddLiquidityReturnDelta: false, 
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Custom errors
    error InvalidPrice(uint256 price);
    error TickNotDivisibleBySpacing(int24 tick, int24 spacing);
    error InvalidExecutionDirection(bool isToken0, int24 targetTick, int24 currentTick);
    error TickOutOfBounds(int24 tick);
    error PriceMustBeGreaterThanZero();
    error AmountTooLow();


    function createLimitOrder(
            bool isToken0,
            bool isRange,
            uint256 price,
            uint256 amount,
            PoolKey calldata key
        ) external returns (bytes32 orderId) {
            orderId = _createOrder(isToken0, isRange, price, amount, key);
        }

    function _createOrder(
        bool isToken0,
        bool isRange,
        uint256 price,
        uint256 amount,
        PoolKey calldata key
    ) internal returns (bytes32 orderId) {
        if (price == 0) revert PriceMustBeGreaterThanZero();
        if (amount == 0) revert AmountTooLow();

        // Get current pool state
        bytes32 poolId = getPoolId(key);
        (uint160 currentSqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));

        // Get the ticks
        (int24 bottomTick, int24 topTick) = _calculateTicks(
            isToken0,
            isRange,
            price,
            currentTick,
            key.tickSpacing
        );

        // Handle token transfers
        _handleTokenTransfer(isToken0, amount, key);

        // Calculate and add liquidity
        uint128 liquidity = _calculateLiquidity(
            isToken0,
            amount,
            bottomTick,
            topTick
        );

        // Add liquidity to pool
        (BalanceDelta delta,) = _addLiquidity(
            key,
            bottomTick,
            topTick,
            liquidity
        );

        OrderParams memory params = OrderParams({
            isToken0: isToken0,
            isRange: isRange,
            bottomTick: bottomTick,
            topTick: topTick,
            liquidity: liquidity,
            tickSpacing: key.tickSpacing
        });

        orderId = _storeOrder(
            params,
            delta,
            key
        );

        return orderId;
    }
    function _calculateTicks(
        bool isToken0,
        bool isRange,
        uint256 price,
        int24 currentTick,
        int24 tickSpacing
    ) internal view returns (int24 bottomTick, int24 topTick) {
        uint160 targetSqrtPriceX96 = getSqrtPriceFromPrice(price);
        int24 rawTargetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);
        return _getValidTickRange(
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
            // Example: targetTick = 155, tickSpacing = 60 => targetTick = 120
            targetTick = (targetTick / tickSpacing) * tickSpacing;
        } else {
            // For token1 orders, round up to next valid tick spacing
            // Example: targetTick = 155, tickSpacing = 60 => targetTick = 180
            targetTick = ((targetTick / tickSpacing) + 1) * tickSpacing;
        }
        
        if (isToken0) {
            // Selling token0, executes on price decrease
            if (isRange) {
                bottomTick = targetTick;
                // Find largest valid tick spacing <= currentTick
                // Example: currentTick = 50, tickSpacing = 60 => topTick = 0
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
                // Example: currentTick = 50, tickSpacing = 60 => bottomTick = 60
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

    function _handleTokenTransfer(
        bool isToken0,
        uint256 amount,
        PoolKey calldata key
    ) internal {
        if (isToken0) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount);
        } else {
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount);
        }
    }

    function _calculateLiquidity(
        bool isToken0,
        uint256 amount,
        int24 bottomTick,
        int24 topTick
    ) internal pure returns (uint128) {
        return isToken0 
            ? LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(bottomTick),
                TickMath.getSqrtPriceAtTick(topTick),
                amount
            )
            : LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(bottomTick),
                TickMath.getSqrtPriceAtTick(topTick),
                amount
            );
    }

    function _addLiquidity(
        PoolKey memory key,
        int24 bottomTick,
        int24 topTick,
        uint128 liquidity
    ) internal returns (BalanceDelta delta, BalanceDelta feeDelta) {
        bytes32 salt = keccak256(abi.encodePacked(
            msg.sender,
            block.timestamp
        ));

        ModifyLiquidityCallbackData memory callbackData = ModifyLiquidityCallbackData({
            key: key,
            bottomTick: bottomTick,
            topTick: topTick,
            liquidityDelta: int256(uint256(liquidity)),
            salt: salt
        });

        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        (delta, feeDelta) = abi.decode(result, (BalanceDelta, BalanceDelta));
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        if (data.length > 0) {
            // Handle regular liquidity modification callback
            if (bytes4(data) == bytes4(keccak256("ModifyLiquidityCallbackData"))) {
                ModifyLiquidityCallbackData memory callbackData = abi.decode(data, (ModifyLiquidityCallbackData));
                
                (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
                    callbackData.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: callbackData.bottomTick,
                        tickUpper: callbackData.topTick,
                        liquidityDelta: callbackData.liquidityDelta,
                        salt: callbackData.salt
                    }),
                    ""
                );

                return abi.encode(delta, feeDelta);
            }
            // Handle batch execution callback
            else if (bytes4(data) == bytes4(keccak256("BatchExecuteData"))) {
                BatchExecuteData memory batchData = abi.decode(data, (BatchExecuteData));
                
                // First burn all liquidity positions
                for (uint256 i = 0; i < batchData.ordersToProcess.length; i++) {
                    if (address(batchData.ordersToProcess[i].owner) == address(0)) break; // End of valid orders
                    
                    (BalanceDelta delta,) = poolManager.modifyLiquidity(
                        batchData.key,
                        IPoolManager.ModifyLiquidityParams({
                            tickLower: batchData.ordersToProcess[i].bottomTick,
                            tickUpper: batchData.ordersToProcess[i].topTick,
                            liquidityDelta: -int128(batchData.ordersToProcess[i].liquidity),
                            salt: bytes32(0)
                        }),
                        ""
                    );

                    // Accumulate deltas
                    batchData.totalToken0Delta += delta.amount0();
                    batchData.totalToken1Delta += delta.amount1();
                    
                    // Update order state
                    bytes32 orderId = batchData.orderIds[i];
                    LimitOrder storage order = limitOrders[orderId];
                    order.executed = true;
                    
                    // Clean up tick bitmap and order tracking
                    bytes32 poolId = getPoolId(batchData.key);
                    int24 tickToClean = order.isToken0 ? order.bottomTick : order.topTick;
                    _cleanupOrderAtTick(poolId, tickToClean, orderId, batchData.key.tickSpacing);
                }

                // Finally mint total tokens in one go
                if (batchData.totalToken0Delta > 0) {
                    poolManager.mint(address(this), batchData.key.currency0.toId(), uint256(batchData.totalToken0Delta));
                }
                if (batchData.totalToken1Delta > 0) {
                    poolManager.mint(address(this), batchData.key.currency1.toId(), uint256(batchData.totalToken1Delta));
                }

                return "";
            }
            // Handle claim callback if added in future
            else {
                return "";
            }
        }
        return "";
    }

    function _cleanupOrderAtTick(bytes32 poolId, int24 tick, bytes32 orderId, int24 tickSpacing) internal {
        bytes32[] storage ordersAtTick = tickToOrders[poolId][tick];
        for (uint256 i = 0; i < ordersAtTick.length; i++) {
            if (ordersAtTick[i] == orderId) {
                ordersAtTick[i] = ordersAtTick[ordersAtTick.length - 1];
                ordersAtTick.pop();
                break;
            }
        }
        
        if (ordersAtTick.length == 0) {
            _removeTickFromPool(poolId, tick, tickSpacing);
        }
    }
    function _storeOrder(
        OrderParams memory params,
        BalanceDelta delta,
        PoolKey calldata key
    ) internal returns (bytes32) {
        bytes32 poolId = getPoolId(key);  // Get poolId from key
        bytes32 orderId = keccak256(abi.encode(poolId, msg.sender, block.timestamp));
        
        limitOrders[orderId] = LimitOrder({
            owner: msg.sender,
            isToken0: params.isToken0,
            isRange: params.isRange,
            targetTick: params.isToken0 ? params.bottomTick : params.topTick,
            bottomTick: params.bottomTick,
            topTick: params.topTick,
            executed: false,
            token0Delta: delta.amount0(),
            token1Delta: delta.amount1(),
            executionFees0: 0,
            executionFees1: 0,
            liquidity: params.liquidity
        });

        _addTickToPool(poolId, params.isToken0 ? params.bottomTick : params.topTick, key.tickSpacing);
        tickToOrders[poolId][params.isToken0 ? params.bottomTick : params.topTick].push(orderId);

        return orderId;
    }
    function beforeSwap(
        address sender,
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 poolId = getPoolId(key);
        (,int24 oldTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        
        // Use the type-safe transient storage
        TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
        TransientSlot.tstore(slot, oldTick);
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external override returns (bytes4, int128) {
        bytes32 poolId = getPoolId(key);
        int24 oldTick = int24(TransientSlot.tload(TransientSlot.asInt256(PREVIOUS_TICK_SLOT)));
        (,int24 newTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        
        _processAllTicks(poolId, key, oldTick, newTick, params.zeroForOne);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _countValidOrders(
        bytes32 poolId,
        int24 oldTick,
        int24 newTick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal view returns (uint256 totalOrders) {
        int24 countTick = oldTick;
        while (zeroForOne ? countTick > newTick : countTick < newTick) {
            (int24 nextTick, bool hasOrders) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
                countTick,
                tickSpacing,
                zeroForOne
            );
            
            if (hasOrders) {
                bytes32[] storage tickOrders = tickToOrders[poolId][nextTick];
                for(uint256 j = 0; j < tickOrders.length; j++) {
                    LimitOrder storage order = limitOrders[tickOrders[j]];
                    if (!order.executed && order.isToken0 == !zeroForOne) {
                        totalOrders++;
                    }
                }
            }
            countTick = nextTick;
        }
        return totalOrders;
    }

    function _getNextTickInfo(
        bytes32 poolId,
        int24 tick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal view returns (int24 nextTick, bool hasOrders) {
        return tickBitmap[poolId].nextInitializedTickWithinOneWord(
            tick,
            tickSpacing,
            zeroForOne
        );
    }

    function _processTickOrders(
        bytes32 poolId,
        int24 tick,
        bool zeroForOne,
        uint256 index,
        LimitOrder[] memory orders,
        bytes32[] memory orderIds
    ) internal view returns (uint256) {
        bytes32[] storage tickOrders = tickToOrders[poolId][tick];
        for(uint256 j; j < tickOrders.length;) {
            if (!limitOrders[tickOrders[j]].executed && limitOrders[tickOrders[j]].isToken0 == !zeroForOne) {
                orders[index] = limitOrders[tickOrders[j]];
                orderIds[index++] = tickOrders[j];
            }
            unchecked { ++j; }
        }
        return index;
    }

    function _collectOrders(
        bytes32 poolId,
        int24 oldTick,
        int24 newTick,
        int24 tickSpacing,
        bool zeroForOne,
        uint256 totalOrders
    ) internal view returns (LimitOrder[] memory orders, bytes32[] memory orderIds) {
        orders = new LimitOrder[](totalOrders);
        orderIds = new bytes32[](totalOrders);
        uint256 index;
        int24 tick = oldTick;
        bool hasOrders;

        while (zeroForOne ? tick > newTick : tick < newTick) {
            (tick, hasOrders) = _getNextTickInfo(poolId, tick, tickSpacing, zeroForOne);
            if (hasOrders) {
                index = _processTickOrders(poolId, tick, zeroForOne, index, orders, orderIds);
            }
        }
    }

    function _processAllTicks(
        bytes32 poolId,
        PoolKey calldata key,
        int24 oldTick,
        int24 newTick,
        bool zeroForOne
    ) internal {
        uint256 totalOrders = _countValidOrders(
            poolId,
            oldTick,
            newTick,
            key.tickSpacing,
            zeroForOne
        );

        if (totalOrders > 0) {
            (LimitOrder[] memory orders, bytes32[] memory orderIds) = _collectOrders(
                poolId,
                oldTick,
                newTick,
                key.tickSpacing,
                zeroForOne,
                totalOrders
            );

            BatchExecuteData memory batchData = BatchExecuteData({
                key: key,
                ordersToProcess: orders,
                orderIds: orderIds,
                totalToken0Delta: 0,
                totalToken1Delta: 0
            });

            poolManager.unlock(abi.encode(batchData));
        }
    }
    function _processOrder(
        PoolKey calldata key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal {
        _burnLimitOrder(key, order, orderId);
        (uint256 amount0, uint256 amount1) = _calculateExecutionAmounts(order);
        _mintAndEmit(key, order.owner, orderId, amount0, amount1);
    }

    function _mintAndEmit(
        PoolKey calldata key,
        address owner,
        bytes32 orderId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        poolManager.mint(address(this), key.currency0.toId(), amount0);
        poolManager.mint(address(this), key.currency1.toId(), amount1);
        emit LimitOrderExecuted(orderId, owner, amount0, amount1);
    }
    
    function getPoolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            key.currency0,
            key.currency1,
            key.fee,
            key.tickSpacing,
            key.hooks
        ));
    }

    function _calculateExecutionAmounts(LimitOrder storage order) internal view returns (uint256 amount0, uint256 amount1) {
        // Proper type conversion for int256 to uint256
        if (order.token0Delta > 0) {
            amount0 = uint256(uint256(order.token0Delta));
        }
        if (order.token1Delta > 0) {
            amount1 = uint256(uint256(order.token1Delta));
        }
        
        if (order.executionFees0 > 0) {
            amount0 += order.executionFees0;
        }
        if (order.executionFees1 > 0) {
            amount1 += order.executionFees1;
        }
    }

    // Implement our own sqrt function since FullMath doesn't have one
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

    function _burnLimitOrder(
        PoolKey calldata key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal {
        // Burn liquidity from pool and get exact token amounts
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: order.bottomTick,
                tickUpper: order.topTick,
                liquidityDelta: -int128(order.liquidity),
                salt: bytes32(0)
            }),
            ""
        );

        // Get the relevant tick for this order
        bytes32 poolId = getPoolId(key);
        int24 tickToClean = order.isToken0 ? order.bottomTick : order.topTick;
        
        // Remove the order from tickToOrders
        bytes32[] storage ordersAtTick = tickToOrders[poolId][tickToClean];
        for (uint256 i = 0; i < ordersAtTick.length; i++) {
            if (ordersAtTick[i] == orderId) {
                // Replace with last element and pop
                ordersAtTick[i] = ordersAtTick[ordersAtTick.length - 1];
                ordersAtTick.pop();
                break;
            }
        }
        
        // If no more orders at this tick, unflip the bit
        if (ordersAtTick.length == 0) {
            _removeTickFromPool(poolId, tickToClean, key.tickSpacing);
        }

        order.executed = true;
    }

    function _addTickToPool(bytes32 poolId, int24 tick, int24 tickSpacing) internal {
        tickBitmap[poolId].flipTick(tick, tickSpacing);
    }

    function _removeTickFromPool(bytes32 poolId, int24 tick, int24 tickSpacing) internal {
        tickBitmap[poolId].flipTick(tick, tickSpacing);
    }


    function claimLimitOrder(
        bytes32 orderId,
        PoolKey calldata key
    ) external {
        LimitOrder storage order = limitOrders[orderId];
        require(order.executed, "Order not executed");
        require(msg.sender == order.owner, "Not owner");
        
        uint256 amount0 = order.token0Delta > int256(0) ? uint256(order.token0Delta) : 0;
        uint256 amount1 = order.token1Delta > int256(0) ? uint256(order.token1Delta) : 0;
        
        // Transfer the ERC6909 tokens to the claimer
        if (amount0 > 0) {
            poolManager.transfer(msg.sender, key.currency0.toId(), amount0);
        }
        if (amount1 > 0) {
            poolManager.transfer(msg.sender, key.currency1.toId(), amount1);
        }
        
        // Burn and withdraw
        if (amount0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amount0);
            poolManager.take(key.currency0, msg.sender, amount0);
        }
        if (amount1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amount1);
            poolManager.take(key.currency1, msg.sender, amount1);
        }
    }

}





