// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {TransientSlot} from "../lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract LimitOrderHook is BaseHook {
    using EnumerableSet for EnumerableSet.UintSet;
    using CurrencySettler for Currency;
    using TransientSlot for *; 


    // Struct to represent a limit order
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
        uint128 liquidity;  // Add this field
    }

    // Add slot constant 
    bytes32 private constant PREVIOUS_TICK_SLOT = keccak256("xyz.hooks.limitorder.previous-tick");

    
    // Mapping from poolId to tick to orderIds
    mapping(bytes32 => mapping(int24 => bytes32[])) public tickToOrders;
    // All limit orders
    mapping(bytes32 => LimitOrder) public limitOrders;
    // Track which ticks have limit orders
    mapping(bytes32 => EnumerableSet.UintSet) private poolTicks;

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
    error PriceOutOfRange();
    error TickNotDivisibleBySpacing(int24 tick, int24 spacing);
    error InvalidExecutionDirection(bool isToken0, int24 targetTick, int24 currentTick);
    error TickOutOfBounds(int24 tick);
    error PriceMustBeGreaterThanZero();
    error AmountTooLow();
    error SlippageTooHigh();

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

        // Create and store the order
        orderId = _storeOrder(
            poolId,
            isToken0,
            isRange,
            bottomTick,
            topTick,
            liquidity,
            delta
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

    function _handleTokenTransfer(
        bool isToken0,
        uint256 amount,
        PoolKey calldata key
    ) internal {
        if (isToken0) {
            CurrencySettler.settle(key.currency0, poolManager, msg.sender, amount, false);
        } else {
            CurrencySettler.settle(key.currency1, poolManager, msg.sender, amount, false);
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

        return poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: bottomTick,
                tickUpper: topTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: salt
            }),
            ""
        );
    }

    function _storeOrder(
        bytes32 poolId,
        bool isToken0,
        bool isRange,
        int24 bottomTick,
        int24 topTick,
        uint128 liquidity,  // Add liquidity parameter
        BalanceDelta delta
    ) internal returns (bytes32) {
        bytes32 orderId = keccak256(abi.encode(poolId, msg.sender, block.timestamp));
        
        limitOrders[orderId] = LimitOrder({
            owner: msg.sender,
            isToken0: isToken0,
            isRange: isRange,
            targetTick: isToken0 ? bottomTick : topTick,
            bottomTick: bottomTick,
            topTick: topTick,
            executed: false,
            token0Delta: delta.amount0(),
            token1Delta: delta.amount1(),
            executionFees0: 0,
            executionFees1: 0,
            liquidity: liquidity
        });

        _addTickToPool(poolId, isToken0 ? bottomTick : topTick);
        tickToOrders[poolId][isToken0 ? bottomTick : topTick].push(orderId);

        return orderId;
    }
    // function createLimitOrder(
    //     bool isToken0,
    //     bool isRange,
    //     uint256 price,
    //     uint256 amount,
    //     PoolKey calldata key
    // ) external returns (bytes32 orderId) {
    //     // Basic input validation
    //     if (price == 0) revert PriceMustBeGreaterThanZero();
    //     if (amount == 0) revert AmountTooLow();

    //     // Get current pool state
    //     bytes32 poolId = getPoolId(key);
    //     (uint160 currentSqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));

    //     // Convert price to tick
    //     uint160 targetSqrtPriceX96 = getSqrtPriceFromPrice(price);
        
    //     // Get tick from sqrt price
    //     int24 rawTargetTick = TickMath.getTickAtSqrtPrice(targetSqrtPriceX96);

    //     // Get valid tick range based on order type
    //     (int24 bottomTick, int24 topTick) = _getValidTickRange(
    //         currentTick,
    //         rawTargetTick,
    //         key.tickSpacing,
    //         isToken0,
    //         isRange
    //     );

    //     // Transfer tokens to PoolManager
    //     if (isToken0) {
    //         CurrencySettler.settle(
    //             key.currency0, 
    //             poolManager,
    //             msg.sender, 
    //             amount,
    //             false  // use transfer instead of burn
    //         );
    //     } else {
    //         CurrencySettler.settle(
    //             key.currency1,
    //             poolManager,
    //             msg.sender,
    //             amount,
    //             false  // use transfer instead of burn
    //         );
    //     }

    //     // Calculate liquidity amount
    //     uint128 liquidity;
    //     if (isToken0) {
    //         liquidity = LiquidityAmounts.getLiquidityForAmount0(
    //             TickMath.getSqrtPriceAtTick(bottomTick),
    //             TickMath.getSqrtPriceAtTick(topTick),
    //             amount
    //         );
    //     } else {
    //         liquidity = LiquidityAmounts.getLiquidityForAmount1(
    //             TickMath.getSqrtPriceAtTick(bottomTick),
    //             TickMath.getSqrtPriceAtTick(topTick),
    //             amount
    //         );
    //     }

    //     // Add liquidity to pool
    //     bytes32 salt = keccak256(abi.encodePacked(
    //         msg.sender,
    //         isToken0,
    //         bottomTick,
    //         topTick,
    //         block.timestamp
    //     ));

    //     (BalanceDelta delta,) = poolManager.modifyLiquidity(
    //         key,
    //         IPoolManager.ModifyLiquidityParams({
    //             tickLower: bottomTick,
    //             tickUpper: topTick,
    //             liquidityDelta: int256(uint256(liquidity)),
    //             salt: salt
    //         }),
    //         ""
    //     );

    //     // Create and store the order
    //     orderId = keccak256(abi.encode(bytes32(poolId), msg.sender, block.timestamp));
    //     limitOrders[orderId] = LimitOrder({
    //         owner: msg.sender,
    //         isToken0: isToken0,
    //         isRange: isRange,
    //         targetTick: isToken0 ? bottomTick : topTick,
    //         bottomTick: bottomTick,
    //         topTick: topTick,
    //         executed: false,
    //         token0Delta: delta.amount0(),
    //         token1Delta: delta.amount1(),
    //         executionFees0: 0,
    //         executionFees1: 0,
    //         liquidity: liquidity  // Add this field
    //     });

    //     // Update tick tracking
    //     _addTickToPool(poolId, isToken0 ? bottomTick : topTick);
    //     tickToOrders[poolId][isToken0 ? bottomTick : topTick].push(orderId);

    //     return orderId;
    // }

    // Store old tick in transient storage
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
            // Load using type-safe transient storage
            TransientSlot.Int256Slot slot = TransientSlot.asInt256(PREVIOUS_TICK_SLOT);
            int24 oldTick = int24(TransientSlot.tload(slot));
            
            (,int24 newTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
            
            // Check orders based on swap direction
            uint256 length = poolTicks[poolId].length();
            for (uint256 i = 0; i < length;) {
                int24 tick = int24(int256(poolTicks[poolId].at(i)));
                
                // For 0->1 swaps, execute when reaching topTick
                if (params.zeroForOne && tick <= oldTick && tick > newTick) {
                    bytes32[] storage orderIds = tickToOrders[poolId][tick];
                    
                    for(uint256 j = 0; j < orderIds.length; j++) {
                        LimitOrder storage order = limitOrders[orderIds[j]];
                        if (!order.executed && !order.isToken0) {
                            _burnLimitOrder(key, order, orderIds[j]);
                            (uint256 amount0, uint256 amount1) = _calculateExecutionAmounts(order);
                            poolManager.mint(address(this), key.currency0.toId(), amount0);
                            poolManager.mint(address(this), key.currency1.toId(), amount1);
                            emit LimitOrderExecuted(orderIds[j], order.owner, amount0, amount1);
                        }
                    }
                }
                // For 1->0 swaps, execute when below bottomTick
                else if (!params.zeroForOne && tick >= oldTick && tick < newTick) {
                    bytes32[] storage orderIds = tickToOrders[poolId][tick];
                    
                    for(uint256 j = 0; j < orderIds.length; j++) {
                        LimitOrder storage order = limitOrders[orderIds[j]];
                        if (!order.executed && order.isToken0) {
                            _burnLimitOrder(key, order, orderIds[j]);
                            (uint256 amount0, uint256 amount1) = _calculateExecutionAmounts(order);
                            poolManager.mint(address(this), key.currency0.toId(), amount0);
                            poolManager.mint(address(this), key.currency1.toId(), amount1);
                            emit LimitOrderExecuted(orderIds[j], order.owner, amount0, amount1);
                        }
                    }
                }
                unchecked { ++i; }
            }
            return (BaseHook.afterSwap.selector, 0);
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
        if (price == 0) revert InvalidPrice(price);
        
        // price = token1/token0
        // Convert price to Q96 format first
        uint256 priceQ96 = FullMath.mulDiv(price, FixedPoint96.Q96, 1);
        
        // Take square root using our sqrt function
        uint256 sqrtPriceX96 = FullMath.mulDiv(
            sqrt(priceQ96),
            FixedPoint96.Q96,
            FixedPoint96.Q96
        );
        
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
                salt: bytes32(0)  // Add empty salt
            }),
            "" // Add empty hookData
        );

        order.executed = true;
    }

    function _addTickToPool(bytes32 poolId, int24 tick) internal returns (bool) {
        return poolTicks[poolId].add(uint256(int256(tick)));
    }

    function _removeTickFromPool(bytes32 poolId, int24 tick) internal returns (bool) {
        return poolTicks[poolId].remove(uint256(int256(tick)));
    }


    function claimLimitOrder(
        bytes32 orderId,
        PoolKey calldata key
    ) external {
        LimitOrder storage order = limitOrders[orderId];
        require(order.executed, "Order not executed");
        require(msg.sender == order.owner, "Not owner");
        
        // Fix the type mismatch by being explicit about the 0 being int256
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





