    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.24;

    import "forge-std/console.sol";
    import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
    import {PoolKey} from "v4-core/types/PoolKey.sol";
    import {SafeCast} from "v4-core/libraries/SafeCast.sol";
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
        using SafeCast for *;
        using TickBitmap for mapping(int16 => uint256);


        // Struct to represent a limit order
        // Need to handle locking when creating limit order, burning limit order, and claiming 


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

        struct AddLiquidityParams {
            PoolKey key;
            int24 bottomTick;
            int24 topTick;
            uint128 liquidity;
            bool isToken0;
            uint256 amount;
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
            address sender;
            PoolKey key;
            IPoolManager.ModifyLiquidityParams params;
            bytes hookData;
            bool settleUsingBurn;  // Existing fields
            bool takeClaims;       // Existing fields
            uint256 amount0;       // Add amount0
            uint256 amount1;       // Add amount1
        }


        enum CallbackType {
            MODIFY_LIQUIDITY,
            CLAIM_ORDER
        }

        struct UnlockCallbackData {
            CallbackType callbackType;
            bytes data;
        }

        struct ClaimOrderCallbackData {
            bytes32 orderId;
            PoolKey key;
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

        address public treasury;




        constructor(IPoolManager poolManager, address _treasury) BaseHook(poolManager) {
            if (_treasury == address(0)) revert("Invalid treasury");
            treasury = _treasury;
            }



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
        (, int24 currentTick,,) = StateLibrary.getSlot0(
            poolManager, PoolId.wrap(getPoolId(key))
        );

        // Get the ticks
        (int24 bottomTick, int24 topTick) = _calculateTicks(
            isToken0,
            isRange,
            price,
            currentTick,
            key.tickSpacing
        );

        // Prepare OrderParams
        OrderParams memory params = OrderParams({
            isToken0: isToken0,
            isRange: isRange,
            bottomTick: bottomTick,
            topTick: topTick,
            liquidity: 0, // placeholder
            tickSpacing: key.tickSpacing
        });

        // Handle token transfers
        {
            _handleTokenTransfer(isToken0, amount, key);
        }

        // Calculate liquidity
        {
            params.liquidity = _calculateLiquidity(
                isToken0,
                amount,
                params.bottomTick,
                params.topTick
            );
        }

        // Add liquidity and store order
        {
            AddLiquidityParams memory addLiquidityParams = AddLiquidityParams({
                key: key,
                bottomTick: params.bottomTick,
                topTick: params.topTick,
                liquidity: params.liquidity,
                isToken0: isToken0,
                amount: amount
            });

            (BalanceDelta delta) = _addLiquidity(addLiquidityParams);

            orderId = _storeOrder(params, delta, key);
        }

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
        // Round target tick based on token direction
        if (isToken0) {
            // For token0 orders, round down to nearest valid tick spacing
            if (targetTick <= currentTick) {
                revert InvalidExecutionDirection(true, targetTick, currentTick);
            }
            targetTick = (targetTick / tickSpacing) * tickSpacing;
        } else {
            if (targetTick >= currentTick) {
                revert InvalidExecutionDirection(false, targetTick, currentTick);
            }
            // For token1 orders, round down to the nearest valid tick spacing greater than or equal to targetTick
            targetTick = (targetTick / tickSpacing) * tickSpacing;
            if (targetTick > (targetTick / tickSpacing) * tickSpacing) {
                targetTick = ((targetTick / tickSpacing) + 1) * tickSpacing;
            }
        }
        
        if (isToken0) {
            if (isRange) {
                // From smallest tickSpacing > currentTick up to target
                bottomTick = ((currentTick / tickSpacing) + 1) * tickSpacing;
                topTick = targetTick;
            } else {
                // Single tick order: [target-spacing, target]
                bottomTick = targetTick - tickSpacing;
                topTick = targetTick;
            }
            // Validate bottomTick > currentTick for token0
            if (bottomTick <= currentTick) {
                revert InvalidExecutionDirection(true, targetTick, currentTick);
            }
        } else {
            if (isRange) {
                // From target up to largest tickSpacing <= currentTick
                bottomTick = targetTick;
                topTick = (currentTick / tickSpacing) * tickSpacing;
            } else {
                // Single tick order spans exactly one tick spacing
                bottomTick = targetTick;
                topTick = targetTick + tickSpacing;
            }
            // Validate topTick <= currentTick for token1
            if (topTick > currentTick) {
                revert InvalidExecutionDirection(false, targetTick, currentTick);
            }
        }
        // Ensure `topTick - bottomTick` is at least one `tickSpacing` for `isRange`
        if (isRange && (topTick - bottomTick) < tickSpacing) {
            if (isToken0) {
                topTick += tickSpacing;
            } else {
                bottomTick -= tickSpacing;
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
        ) public view returns (uint128) {
            uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(bottomTick);
            uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(topTick);
            
            return isToken0 
                ? LiquidityAmounts.getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount)
                : LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount);
        }

    function _addLiquidity(
        AddLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        // Wrap callback data with type enum
        bytes memory result = poolManager.unlock(
            abi.encode(
                UnlockCallbackData({
                    callbackType: CallbackType.MODIFY_LIQUIDITY,
                    data: abi.encode(
                        ModifyLiquidityCallbackData({
                            key: params.key,
                            params: IPoolManager.ModifyLiquidityParams({
                                tickLower: params.bottomTick,
                                tickUpper: params.topTick,
                                liquidityDelta: params.liquidity.toInt256(),
                                salt: 0
                            }),
                            amount0: params.isToken0 ? params.amount : 0,
                            amount1: params.isToken0 ? 0 : params.amount,
                            sender: address(this),
                            hookData: "",
                            settleUsingBurn: true,
                            takeClaims: true
                        })
                    )
                })
            )
        );

        return abi.decode(result, (BalanceDelta));
    }




        // Update _unlockCallback for claiming
        function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
            UnlockCallbackData memory cbd = abi.decode(data, (UnlockCallbackData));
            
            if (cbd.callbackType == CallbackType.MODIFY_LIQUIDITY) {
                ModifyLiquidityCallbackData memory callbackData = abi.decode(cbd.data, (ModifyLiquidityCallbackData));
                
                if (callbackData.amount0 > 0) {
                    callbackData.key.currency0.settle(poolManager, address(this), callbackData.amount0, false);
                }
                if (callbackData.amount1 > 0) {
                    callbackData.key.currency1.settle(poolManager, address(this), callbackData.amount1, false);
                }

                (BalanceDelta delta, ) = poolManager.modifyLiquidity(
                    callbackData.key,
                    callbackData.params,
                    callbackData.hookData
                );

                return abi.encode(delta);
            } else if (cbd.callbackType == CallbackType.CLAIM_ORDER) {
                ClaimOrderCallbackData memory claimData = abi.decode(cbd.data, (ClaimOrderCallbackData));
                LimitOrder storage order = limitOrders[claimData.orderId];
                
                uint256 principalAmount;
                uint256 fees0;
                uint256 fees1;
                
                // Calculate principal and fees based on order direction
                if (order.isToken0) {
                    // For token0->token1 orders, calculate expected token1 from liquidity
                    principalAmount = LiquidityAmounts.getAmount1ForLiquidity(
                        TickMath.getSqrtPriceAtTick(order.bottomTick),
                        TickMath.getSqrtPriceAtTick(order.topTick),
                        order.liquidity
                    );
                    
                    // All token0 received is fees, excess token1 is fees
                    fees0 = uint256(int256(order.delta.amount0()));
                    fees1 = uint256(int256(order.delta.amount1())) - principalAmount;
                } else {
                    // For token1->token0 orders, calculate expected token0 from liquidity
                    principalAmount = LiquidityAmounts.getAmount0ForLiquidity(
                        TickMath.getSqrtPriceAtTick(order.bottomTick),
                        TickMath.getSqrtPriceAtTick(order.topTick),
                        order.liquidity
                    );
                    
                    // All token1 received is fees, excess token0 is fees
                    fees1 = uint256(int256(order.delta.amount1()));
                    fees0 = uint256(int256(order.delta.amount0())) - principalAmount;
                }

                // Calculate treasury's share
                uint256 treasuryFee0 = (fees0 * 20) / 100;
                uint256 treasuryFee1 = (fees1 * 20) / 100;
                uint256 ownerFee0 = fees0 - treasuryFee0;
                uint256 ownerFee1 = fees1 - treasuryFee1;

                // Handle token0 transfers
                if (ownerFee0 > 0 || (!order.isToken0 && principalAmount > 0)) {
                    uint256 currency0Id = uint256(uint160(Currency.unwrap(order.key.currency0)));
                    uint256 ownerAmount0 = !order.isToken0 ? (principalAmount + ownerFee0) : ownerFee0;
                    
                    if (ownerAmount0 > 0) {
                        poolManager.burn(address(this), currency0Id, ownerAmount0);
                        poolManager.take(order.key.currency0, order.owner, ownerAmount0);
                    }
                    if (treasuryFee0 > 0) {
                        poolManager.burn(address(this), currency0Id, treasuryFee0);
                        poolManager.take(order.key.currency0, treasury, treasuryFee0);
                    }
                }

                // Handle token1 transfers
                if (ownerFee1 > 0 || (order.isToken0 && principalAmount > 0)) {
                    uint256 currency1Id = uint256(uint160(Currency.unwrap(order.key.currency1)));
                    uint256 ownerAmount1 = order.isToken0 ? (principalAmount + ownerFee1) : ownerFee1;
                    
                    if (ownerAmount1 > 0) {
                        poolManager.burn(address(this), currency1Id, ownerAmount1);
                        poolManager.take(order.key.currency1, order.owner, ownerAmount1);
                    }
                    if (treasuryFee1 > 0) {
                        poolManager.burn(address(this), currency1Id, treasuryFee1);
                        poolManager.take(order.key.currency1, treasury, treasuryFee1);
                    }
                }

                // Clean up storage
                delete limitOrders[claimData.orderId];
                
                return abi.encode(0);
            }
        }

    // Add at contract level
    uint256 private orderNonce;


    function _storeOrder(
        OrderParams memory params,
        BalanceDelta delta,
        PoolKey calldata key
    ) internal returns (bytes32) {
        bytes32 poolId = getPoolId(key);
        bytes32 orderId = keccak256(abi.encode(poolId, msg.sender, block.timestamp, orderNonce++));
        
        limitOrders[orderId] = LimitOrder({
            owner: msg.sender,
            isToken0: params.isToken0,
            isRange: params.isRange,
            bottomTick: params.bottomTick,
            topTick: params.topTick,
            liquidity: params.liquidity,
            delta: BalanceDelta.wrap(0),    // Initialize with zero delta
            key: key                        // Store the PoolKey
        });

        int24 storeTick = params.isToken0 ? params.topTick : params.bottomTick;

        // Only flip the bit if this is the first order at this tick
        bytes32[] storage ordersAtTick = tickToOrders[poolId][storeTick];
        if (ordersAtTick.length == 0) {
            
            _addTickToPool(poolId, storeTick, key.tickSpacing);
        }


        ordersAtTick.push(orderId);

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
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        bytes32 poolId = getPoolId(key);
        int24 oldTick = int24(TransientSlot.tload(TransientSlot.asInt256(PREVIOUS_TICK_SLOT)));
        (,int24 newTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        
        _executeValidOrders(poolId, key, oldTick, newTick, params.zeroForOne);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _executeValidOrders(
        bytes32 poolId,
        PoolKey memory key,
        int24 oldTick,
        int24 newTick,
        bool zeroForOne
    ) internal {
        OrderExecutionData memory execData = _getValidOrdersData(
            poolId,
            oldTick,
            newTick,
            key.tickSpacing,
            zeroForOne
        );
        
        if (execData.totalOrders > 0) {
            _executeOrders(key, execData.orders, execData.orderIds);
        }
    }

    struct OrderExecutionData {
        uint256 totalOrders;
        LimitOrder[] orders;
        bytes32[] orderIds;
    }

    function _getValidOrdersData(
        bytes32 poolId,
        int24 oldTick,
        int24 newTick,
        int24 tickSpacing,
        bool zeroForOne
    ) internal view returns (OrderExecutionData memory execData) {
        execData.totalOrders = _countValidOrders(
            poolId,
            oldTick,
            newTick,
            tickSpacing,
            zeroForOne
        );

        if (execData.totalOrders > 0) {
            (execData.orders, execData.orderIds) = _collectOrders(
                poolId,
                oldTick,
                newTick,
                tickSpacing,
                zeroForOne,
                execData.totalOrders
            );
        }
    }

    function _executeOrders(
        PoolKey memory key,
        LimitOrder[] memory orders,
        bytes32[] memory orderIds
    ) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            _processOrder(key, limitOrders[orderIds[i]], orderIds[i]);
        }
    }


    function _shouldProcessOrder(LimitOrder storage order, int24 newTick, bool zeroForOne) internal view returns (bool) {
        console.log("=== _shouldProcessOrder ===");
        console.log("newTick:");
        console.logInt(newTick);
        console.log("zeroForOne:");
        console.log(zeroForOne);
        console.log("Order isToken0:");
        console.log(order.isToken0);
        console.log("bottomTick:");
        console.logInt(order.bottomTick);
        console.log("topTick:");
        console.logInt(order.topTick);  
        
        if (order.delta != BalanceDelta.wrap(0)) {
            console.log("Order already executed");
            // Already executed
            return false;
        }
        // If zeroForOne is true, we're moving price downwards (token0->token1 scenario reversed).
        // That means token1->token0 orders (order.isToken0 == false) execute if the final price is below their bottomTick.
        // If zeroForOne is false, we're moving price upwards, so token0->token1 orders (order.isToken0 == true) execute
        // if the final price is above their topTick.

        // if (zeroForOne) {
        //     // Moving downward: trigger token1->token0 orders
        //     return (!order.isToken0 && newTick < order.bottomTick);
        // } else {
        //     // Moving upward: trigger token0->token1 orders
        //     return (order.isToken0 && order.topTick <= newTick);
        bool shouldProc = zeroForOne ? (!order.isToken0 && newTick < order.bottomTick) : (order.isToken0 && order.topTick <= newTick);
        console.log("shouldProc:");
        console.log(shouldProc);

        console.log("=== _shouldProcessOrder END ===");
        return shouldProc;

        }


        // function _countValidOrders(
        //     bytes32 poolId,
        //     int24 oldTick,
        //     int24 newTick,
        //     int24 tickSpacing,
        //     bool zeroForOne
        // ) internal view returns (uint256 totalOrders) {
        //     int24 countTick = oldTick;
        //     while (zeroForOne ? countTick >= newTick : countTick <= newTick) {
        //         (int24 nextTick, bool hasOrders) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
        //             countTick,
        //             tickSpacing,
        //             zeroForOne
        //         );
                
        //         if (hasOrders) {
        //             bytes32[] storage tickOrders = tickToOrders[poolId][nextTick];
        //             for(uint256 j = 0; j < tickOrders.length; j++) {
        //                 LimitOrder storage order = limitOrders[tickOrders[j]];
        //                 if (order.delta == BalanceDelta.wrap(0) && order.isToken0 == !zeroForOne) {
        //                     totalOrders++;
        //                 }
        //             }
        //         }
        //         countTick = nextTick;
        //     }
        //     console.log("totalOrders: ",totalOrders);
        //     return totalOrders;
        // }
    // function _countValidOrders(
    //     bytes32 poolId,
    //     int24 oldTick,
    //     int24 newTick,
    //     int24 tickSpacing,
    //     bool zeroForOne
    // ) internal view returns (uint256 totalOrders) {

    //     console.log("=== _countValidOrders START ===");
    //     console.log("oldTick:", oldTick);
    //     console.log("newTick:", newTick);
    //     console.log("tickSpacing:", tickSpacing);
    //     console.log("zeroForOne:", zeroForOne);
    //     int24 countTick = oldTick;

    //     while (true) {
    //         // Check if we've crossed the newTick boundary based on direction
    //         if (zeroForOne ? (countTick < newTick) : (countTick > newTick)) {
    //             console.log("Crossed boundary, breaking loop");
    //             break;
    //         }

    //         (int24 nextTick, bool initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
    //             countTick,
    //             tickSpacing,
    //             zeroForOne
    //         );
    //         console.log("Found nextTick:");
    //         console.logInt(nextTick);
    //         console.log("initialized:");
    //         console.log(initialized);

    //         // If no more initialized ticks or we've passed newTick, stop
    //         if (!initialized || (zeroForOne ? nextTick < newTick : nextTick > newTick)) {
    //             console.log("No valid next tick or out of range");
    //             break;
    //         }

    //         console.log("Checking tickOrders at:");
    //         console.logInt(nextTick);
    //         bytes32[] storage tickOrders = tickToOrders[poolId][nextTick];
    //         console.log("tickOrders length:");
    //         console.log(tickOrders.length);

    //         for (uint256 j = 0; j < tickOrders.length; j++) {
    //             LimitOrder storage order = limitOrders[tickOrders[j]];
    //             bool sp = _shouldProcessOrder(order, newTick, zeroForOne);
    //             console.log("Checking order at tick");
    //             console.logInt(order.bottomTick);
    //             console.logInt(order.topTick);
    //             console.log(order.isToken0);
    //             console.log("shouldProcess:");
    //             console.log(sp);
    //             if (sp) {
    //                 totalOrders++;
    //             }
    //         }


    //         // Move countTick past this tick in the correct direction
    //         countTick = zeroForOne ? (nextTick - tickSpacing) : (nextTick + tickSpacing);
    //         console.log("Moving to countTick:");
    //         console.logInt(countTick);
    //     }
    //     console.log("totalOrders:");
    //     console.log(totalOrders);
    //     console.log("=== _countValidOrders END ===");
    //     return totalOrders;
    // }
    // function _countValidOrders(
    //     bytes32 poolId,
    //     int24 oldTick,
    //     int24 newTick,
    //     int24 tickSpacing,
    //     bool zeroForOne
    // ) internal view returns (uint256 totalOrders) {
    //     console.log("=== _countValidOrders START ===");
    //     console.log("oldTick:", oldTick);
    //     console.log("newTick:", newTick);
    //     console.log("tickSpacing:", tickSpacing);
    //     console.log("zeroForOne:", zeroForOne);
        
    //     int24 tick = oldTick;
        
    //     while (true) {
    //         // Check if we've moved past newTick
    //         if (zeroForOne ? tick < newTick : tick > newTick) {
    //             break;
    //         }

    //         (int24 nextTick, bool initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
    //             tick,
    //             tickSpacing,
    //             zeroForOne
    //         );

    //         console.log("Checking from tick:", tick);
    //         console.log("Found nextTick:", nextTick);
    //         console.log("initialized:", initialized);

    //         if (initialized) {
    //             // Only process if nextTick is in our target range
    //             if (!(zeroForOne ? nextTick < newTick : nextTick > newTick)) {
    //                 bytes32[] storage tickOrders = tickToOrders[poolId][nextTick];
    //                 for (uint256 j = 0; j < tickOrders.length; j++) {
    //                     LimitOrder storage order = limitOrders[tickOrders[j]];
    //                     bool sp = _shouldProcessOrder(order, newTick, zeroForOne);
    //                     if (sp) {
    //                         totalOrders++;
    //                     }
    //                 }
    //             }
    //         }

    //         // Move to next word boundary if no initialized tick found
    //         if (!initialized) {
    //             int24 wordShift = int24(256) * tickSpacing;
    //             tick = zeroForOne ? tick - wordShift : tick + wordShift;
                
    //             // Check boundaries
    //             if (zeroForOne && tick < TickMath.minUsableTick(tickSpacing)) {
    //                 break;
    //             }
    //             if (!zeroForOne && tick > TickMath.maxUsableTick(tickSpacing)) {
    //                 break;
    //             }
    //         } else {
    //             // Move one tick past the found tick
    //             tick = zeroForOne ? nextTick - tickSpacing : nextTick + tickSpacing;
    //         }
    //     }

    //     console.log("totalOrders:", totalOrders);
    //     console.log("=== _countValidOrders END ===");
    //     return totalOrders;
    // }

// struct OrderCount {
//    int24 tick;
//    int24 nextTick; 
//    bool initialized;
//    uint256 totalOrders;
//    int24 wordShift;
// }

// function _countValidOrders(
//    bytes32 poolId,
//    int24 oldTick,
//    int24 newTick,
//    int24 tickSpacing,
//    bool zeroForOne
// ) internal view returns (uint256) {
//    OrderCount memory count;
   
//    // Start at the word boundary for oldTick
//    int24 compressedTick = oldTick / tickSpacing;
//    int16 wordPos = int16(compressedTick >> 8);
//    count.tick = wordPos * 256 * tickSpacing;  // Start at full word boundary
//    count.wordShift = 256 * tickSpacing;       // Jump full words


//     if (zeroForOne) {
//        // For negative direction, ensure we start at the beginning of the word
//        count.tick = ((count.tick / count.wordShift) * count.wordShift);
//    }


//    console.log("=== _countValidOrders START ===");
//    console.log("oldTick:", oldTick);
//    console.log("newTick:", newTick);
//    console.log("tickSpacing:", tickSpacing);
//    console.log("zeroForOne:", zeroForOne);
   



//    while (true) {
//        if (zeroForOne ? count.tick < newTick : count.tick > newTick) {
//            break;
//        }

//        (count.nextTick, count.initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
//            count.tick,
//            tickSpacing,
//            zeroForOne
//        );

//        console.log("Checking from tick:", count.tick);
//        console.log("Found nextTick:", count.nextTick);
//        console.log("initialized:", count.initialized);

//        if (count.initialized) {
//            if (!(zeroForOne ? count.nextTick < newTick : count.nextTick > newTick)) {
//                bytes32[] storage tickOrders = tickToOrders[poolId][count.nextTick];
//                for (uint256 j = 0; j < tickOrders.length; j++) {
//                    LimitOrder storage order = limitOrders[tickOrders[j]];
//                    if (_shouldProcessOrder(order, newTick, zeroForOne)) {
//                        count.totalOrders++;
//                    }
//                }
//            }
//        }

//        if (!count.initialized) {
//            if (zeroForOne) {
//                count.tick = ((count.tick - count.wordShift) / count.wordShift) * count.wordShift;
//            } else {
//                count.tick = ((count.tick / count.wordShift + 1) * count.wordShift);
//            }
           
//            if (zeroForOne && count.tick < TickMath.minUsableTick(tickSpacing)) {
//                break;
//            }
//            if (!zeroForOne && count.tick > TickMath.maxUsableTick(tickSpacing)) {
//                break;
//            }
//        } else {
//            count.tick = zeroForOne ? count.nextTick - tickSpacing : count.nextTick + tickSpacing;
//        }
//    }

//    console.log("totalOrders:", count.totalOrders);
//    console.log("=== _countValidOrders END ===");
//    return count.totalOrders;
// }

    struct OrderCount {
       int24 tick;
       int24 nextTick; 
       bool initialized;
       uint256 totalOrders;
       int24 wordShift;
    }


function _countValidOrders(
    bytes32 poolId,
    int24 oldTick,
    int24 newTick,
    int24 tickSpacing,
    bool zeroForOne
) internal view returns (uint256) {

    OrderCount memory count;
   
    // Each word in the TickBitmap covers 256 ticks (each tickSpacing apart)
    count.wordShift = tickSpacing;
    count.tick = oldTick; // Start directly from oldTick, not a full word boundary

    console.log("=== _countValidOrders START ===");
    console.log("oldTick:", oldTick);
    console.log("newTick:", newTick);
    console.log("tickSpacing:", tickSpacing);
    console.log("zeroForOne:", zeroForOne);

    while (true) {
        // If we've already crossed the newTick boundary in the given direction, stop
        if (zeroForOne ? (count.tick < newTick) : (count.tick > newTick)) {
            break;
        }

        (count.nextTick, count.initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
            count.tick,
            tickSpacing,
            zeroForOne
        );

        console.log("Checking from tick:", count.tick);
        console.log("Found nextTick:", count.nextTick);
        console.log("initialized:", count.initialized);

        if (count.initialized) {
            // Check if this found tick is within our execution range
            bool inRange = zeroForOne ? (count.nextTick >= newTick) : (count.nextTick <= newTick);
            if (inRange) {
                bytes32[] storage tickOrders = tickToOrders[poolId][count.nextTick];
                for (uint256 j = 0; j < tickOrders.length; j++) {
                    LimitOrder storage order = limitOrders[tickOrders[j]];
                    if (_shouldProcessOrder(order, newTick, zeroForOne)) {
                        count.totalOrders++;
                    }
                }
            }

            // Move to the next tick based on the direction
            count.tick = zeroForOne ? count.nextTick - tickSpacing : count.nextTick + tickSpacing;
        } else {
            // No initialized ticks found in this 256-tick word. Move one full word.
            if (zeroForOne) {
                // Move one word backward
                count.tick -= count.wordShift;
                if (count.tick < TickMath.minUsableTick(tickSpacing)) break;
            } else {
                // Move one word forward
                count.tick += count.wordShift;
                if (count.tick > TickMath.maxUsableTick(tickSpacing)) break;
            }
        }
    }

    console.log("totalOrders:", count.totalOrders);
    console.log("=== _countValidOrders END ===");
    return count.totalOrders;
}


// function _countValidOrders(
//     bytes32 poolId,
//     int24 oldTick,
//     int24 newTick,
//     int24 tickSpacing,
//     bool zeroForOne
// ) internal view returns (uint256) {
//     OrderCount memory count;

//     // Decide the starting tick:
//     // If zeroForOne is true, start from newTick (we'll scan upwards towards oldTick).
//     // If zeroForOne is false, start from oldTick (scan upwards towards newTick).
//     count.tick = zeroForOne ? newTick : oldTick;

//     // Each word covers 256 ticks
//     count.wordShift = 256 * tickSpacing;

//     console.log("=== _countValidOrders START ===");
//     console.log("oldTick:", oldTick);
//     console.log("newTick:", newTick);
//     console.log("tickSpacing:", tickSpacing);
//     console.log("zeroForOne:", zeroForOne);

//     // Always search forward, so lte = false
//     bool alwaysForward = false;

//     while (true) {
//         // If we've already gone past newTick, stop.
//         // Note: This assumes we're always moving from a lower tick to a higher tick.
//         if ((zeroForOne && count.tick > oldTick) || (!zeroForOne && count.tick > newTick)) {
//             break;
//         }


//         (count.nextTick, count.initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
//             count.tick,
//             tickSpacing,
//             alwaysForward
//         );

//         console.log("Checking from tick:", count.tick);
//         console.log("Found nextTick:", count.nextTick);
//         console.log("initialized:", count.initialized);

//         if (count.initialized) {
//             // Check if this found tick is within our execution range
//             bool inRange = zeroForOne
//                 ? (count.nextTick <= oldTick)
//                 : (count.nextTick <= newTick);
//             if (inRange) {
//                 bytes32[] storage tickOrders = tickToOrders[poolId][count.nextTick];
//                 for (uint256 j = 0; j < tickOrders.length; j++) {
//                     LimitOrder storage order = limitOrders[tickOrders[j]];
//                     if (_shouldProcessOrder(order, newTick, zeroForOne)) {
//                         count.totalOrders++;
//                     }
//                 }
//             }

//             // Move to the next tick forward
//             count.tick = count.nextTick + tickSpacing;
//         } else {
//             // No initialized ticks found, move one full word forward
//             count.tick += count.wordShift;
//             if (count.tick > TickMath.maxUsableTick(tickSpacing)) break;
//         }
//     }

//     console.log("totalOrders:", count.totalOrders);
//     console.log("=== _countValidOrders END ===");
//     return count.totalOrders;
// }

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
                LimitOrder storage order = limitOrders[tickOrders[j]];
                // Add tick validation
                bool validTick = zeroForOne ? 
                    (tick <= (order.isToken0 ? order.topTick : order.bottomTick)) :  
                    (tick >= (order.isToken0 ? order.topTick : order.bottomTick));
                    
                if (order.delta == BalanceDelta.wrap(0) && order.isToken0 == !zeroForOne && validTick) {
                    orders[index] = limitOrders[tickOrders[j]];
                    orderIds[index++] = tickOrders[j];
                }
                unchecked { ++j; }
            }
            return index;
        }
        // function _collectOrders(
        //     bytes32 poolId,
        //     int24 oldTick,
        //     int24 newTick,
        //     int24 tickSpacing,
        //     bool zeroForOne,
        //     uint256 totalOrders
        // ) internal view returns (LimitOrder[] memory orders, bytes32[] memory orderIds) {
        //     orders = new LimitOrder[](totalOrders);
        //     orderIds = new bytes32[](totalOrders);
        //     uint256 index;
        //     int24 tick = oldTick;
        //     bool hasOrders;

        //     while (zeroForOne ? tick > newTick : tick < newTick) {
        //         (tick, hasOrders) = _getNextTickInfo(poolId, tick, tickSpacing, zeroForOne);
        //         if (hasOrders) {
        //             index = _processTickOrders(poolId, tick, zeroForOne, index, orders, orderIds);
        //         }
        //     }
        // }
    function _getNextTickAndCheck(
        bytes32 poolId,
        int24 tick,
        int24 tickSpacing,
        bool zeroForOne,
        int24 newTick
    ) internal view returns (int24 nextTick, bool proceed) {
        bool initialized;
        (nextTick, initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
            tick,
            tickSpacing,
            zeroForOne
        );

        // If there's no initialized tick or it doesn't lie in the correct direction towards newTick, stop
        if (!initialized || (zeroForOne ? (nextTick < newTick) : (nextTick > newTick))) {
            proceed = false;
        } else {
            proceed = true;
        }
    }


    function _processTick(
        bytes32 poolId,
        int24 nextTick,
        int24 newTick,
        bool zeroForOne,
        LimitOrder[] memory orders,
        bytes32[] memory orderIds,
        uint256 index,
        uint256 totalOrders
    ) internal view returns (uint256) {
        console.log("=== _processTick ===");
        console.log("Processing tick:");
        console.logInt(nextTick);
        console.log("newTick:");
        console.logInt(newTick);
        console.log("zeroForOne:");
        console.log(zeroForOne);
        bytes32[] storage tickOrdersArr = tickToOrders[poolId][nextTick];

        console.log("tickOrdersArr length:");
        console.log(tickOrdersArr.length);
        for (uint256 j = 0; j < tickOrdersArr.length && index < totalOrders; j++) {
            LimitOrder storage order = limitOrders[tickOrdersArr[j]];
            // if (_shouldProcessOrder(order, newTick, zeroForOne)) {
            //     orders[index] = order;
            //     orderIds[index] = tickOrdersArr[j];
            //     index++;
            // }
            bool sp = _shouldProcessOrder(order, newTick, zeroForOne);
            console.log("Check order at _processTick");
            console.log("isToken0:");
            console.log(order.isToken0);
            console.log("bottomTick:");
            console.logInt(order.bottomTick);
            console.log("topTick:");
            console.logInt(order.topTick);
            console.log("shouldProcess:");
            console.log(sp);

            if (sp) {
                orders[index] = order;
                orderIds[index] = tickOrdersArr[j];
                index++;
                console.log("Added order to execution list. New index:");
                console.log(index);
            }
        }
            console.log("=== _processTick END ===");
        return index;
    }

    // function _collectOrders(
    //     bytes32 poolId,
    //     int24 oldTick,
    //     int24 newTick,
    //     int24 tickSpacing,
    //     bool zeroForOne,
    //     uint256 totalOrders
    // ) internal view returns (LimitOrder[] memory orders, bytes32[] memory orderIds) {
    //     console.log("=== _collectOrders START ===");
    //     orders = new LimitOrder[](totalOrders);
    //     orderIds = new bytes32[](totalOrders);

    //     uint256 index;
    //     int24 countTick = oldTick;

    //     while (index < totalOrders) {
    //         // If we've already crossed the boundary (depending on direction), break
    //         if (zeroForOne ? (countTick < newTick) : (countTick > newTick)) {
    //             console.log("Crossed boundary in _collectOrders, breaking");
    //             break;
    //         }

    //         (int24 nextTick, bool proceed) = _getNextTickAndCheck(poolId, countTick, tickSpacing, zeroForOne, newTick);
    //         console.log("In _collectOrders nextTick:");
    //         console.logInt(nextTick);
    //         console.log("proceed:");
    //         console.log(proceed);
    //         if (!proceed) {
    //             break;
    //         }

    //         index = _processTick(poolId, nextTick, newTick, zeroForOne, orders, orderIds, index, totalOrders);

    //         // Move to the next tick
    //         countTick = zeroForOne ? (nextTick - tickSpacing) : (nextTick + tickSpacing);
    //         console.log("Next countTick in _collectOrders:");
    //         console.logInt(countTick);
    //     }
    //     console.log("Collected orders count:");
    //     console.log(index);
    //     console.log("=== _collectOrders END ===");
    //     return (orders, orderIds);
    // }
function _getNextTickAndInitialized(
    bytes32 poolId,
    int24 tick,
    int24 tickSpacing,
    bool zeroForOne,
    int24 newTick
) internal view returns (int24 nextTick, bool initialized) {
    // Mirror exactly how Pool.sol uses it
    (nextTick, initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
        tick,
        tickSpacing,
        zeroForOne
    );

    // Handle bounds like Pool.sol does
    if (nextTick <= TickMath.MIN_TICK) {
        nextTick = TickMath.MIN_TICK;
    }
    if (nextTick >= TickMath.MAX_TICK) {
        nextTick = TickMath.MAX_TICK;
    }

    // Don't traverse past our target
    if (zeroForOne ? nextTick < newTick : nextTick > newTick) {
        initialized = false;
    }
}
struct OrderCollectionState {
    int24 tick;
    int24 nextTick;
    bool initialized;
    uint256 index;
    LimitOrder[] orders;
    bytes32[] orderIds;
}

function _collectOrders(
    bytes32 poolId,
    int24 oldTick,
    int24 newTick,
    int24 tickSpacing,
    bool zeroForOne,
    uint256 totalOrders
) internal view returns (LimitOrder[] memory orders, bytes32[] memory orderIds) {
    OrderCollectionState memory state;
    state.orders = new LimitOrder[](totalOrders);
    state.orderIds = new bytes32[](totalOrders);
    state.tick = oldTick;
    
    while (state.index < totalOrders) {
        (state.nextTick, state.initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
            state.tick,
            tickSpacing,
            zeroForOne
        );

        if (state.nextTick <= TickMath.MIN_TICK) {
            state.nextTick = TickMath.MIN_TICK;
        }
        if (state.nextTick >= TickMath.MAX_TICK) {
            state.nextTick = TickMath.MAX_TICK;
        }

        if (zeroForOne ? state.nextTick < newTick : state.nextTick > newTick) {
            break;
        }

        if (state.initialized) {
            state.index = _processTick(
                poolId, 
                state.nextTick, 
                newTick, 
                zeroForOne, 
                state.orders, 
                state.orderIds, 
                state.index, 
                totalOrders
            );
        }

        state.tick = zeroForOne ? state.nextTick - tickSpacing : state.nextTick + tickSpacing;
    }
    
    return (state.orders, state.orderIds);
}

    function _processOrder(
        PoolKey memory key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal {
        (BalanceDelta delta, ) = _burnLimitOrder(key, order, orderId);
        
        // Store only main delta
        order.delta = delta;
        
        uint256 amount0;
        uint256 amount1;

        // console.log("delta0:",delta.amount0());
        // console.log("delta1:",delta.amount1());
        {
            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();
            if (delta0 > 0) amount0 = uint256(int256(delta0));
            if (delta1 > 0) amount1 = uint256(int256(delta1));
        }
        // console.log("amount0:",amount0);
        // console.log("amount1:",amount1);
        // Mint tokens to hook for settlement
        if (amount0 > 0) {
            uint256 currency0Id = uint256(uint160(Currency.unwrap(key.currency0)));
            poolManager.mint(address(this), currency0Id, amount0);
        }
        if (amount1 > 0) {
            uint256 currency1Id = uint256(uint160(Currency.unwrap(key.currency1)));
            poolManager.mint(address(this), currency1Id, amount1);
        }

        emit LimitOrderExecuted(orderId, order.owner, amount0, amount1);

    }


        function getPoolId(PoolKey memory key) public pure returns (bytes32) {
            return keccak256(abi.encode(
                key.currency0,
                key.currency1,
                key.fee,
                key.tickSpacing,
                key.hooks
            ));
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

        function getSqrtPriceFromPrice(uint256 price) public pure returns (uint160) {
            if (price == 0) revert PriceMustBeGreaterThanZero();
            
            // price = token1/token0
            // Convert price to Q96 format first
            uint256 priceQ96 = FullMath.mulDiv(price, FixedPoint96.Q96, 1 ether); // Since input price is in 1e18 format
        
            // Take square root using our sqrt function
            uint256 sqrtPriceX96 = sqrt(priceQ96) << 48;
            
            if (sqrtPriceX96 > type(uint160).max) revert InvalidPrice(price);
            
            return uint160(sqrtPriceX96);
        }

    // Update _burnLimitOrder to ignore feeDelta
    function _burnLimitOrder(
        PoolKey memory key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal returns (BalanceDelta delta, BalanceDelta) {  // Keep return sig but ignore second return
        (delta, ) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: order.bottomTick,
                tickUpper: order.topTick,
                liquidityDelta: -int128(order.liquidity),
                salt: bytes32(0)
            }),
            ""
        );

        bytes32 poolId = getPoolId(key);
        int24 tickToClean = order.isToken0 ? order.topTick : order.bottomTick;
        
        bytes32[] storage ordersAtTick = tickToOrders[poolId][tickToClean];
        for (uint256 i = 0; i < ordersAtTick.length; i++) {
            if (ordersAtTick[i] == orderId) {
                ordersAtTick[i] = ordersAtTick[ordersAtTick.length - 1];
                ordersAtTick.pop();
                break;
            }
        }
        
        // Check if there are any unexecuted orders remaining
        bool hasUnexecutedOrders = false;
        for (uint256 i = 0; i < ordersAtTick.length; i++) {
            if (limitOrders[ordersAtTick[i]].delta == BalanceDelta.wrap(0)) {
                hasUnexecutedOrders = true;
                break;
            }
        }

        // Only flip the bit back if no unexecuted orders remain
        if (!hasUnexecutedOrders) {
            _removeTickFromPool(poolId, tickToClean, key.tickSpacing);
        }

        return (delta, BalanceDelta.wrap(0));  // Return dummy second value
    }

        function _addTickToPool(bytes32 poolId, int24 tick, int24 tickSpacing) internal {
    // Add debug info before setting
    int24 compressed = tick / tickSpacing;
    int16 wordPos = int16(compressed >> 8);
    uint8 bitPos = uint8(uint24(compressed) & 0xff);
    console.log("Setting tick in word:", int256(wordPos));
    console.log("At bit position:", uint256(bitPos));
    console.log("Bitmap word before:", uint256(tickBitmap[poolId][wordPos]));

            tickBitmap[poolId].flipTick(tick, tickSpacing);
    console.log("Bitmap word after:", uint256(tickBitmap[poolId][wordPos]));
            console.log("Added tick to bitmap:");
            console.logInt(tick);
            // Verify the bit was set
            (int24 nextTick, bool initialized) = tickBitmap[poolId].nextInitializedTickWithinOneWord(
            tick,
            tickSpacing,
            true
        );
        console.log("Verification - found tick:");
        console.logInt(nextTick);
        console.log("Verification - initialized:");
        console.log(initialized);
        }

        function _removeTickFromPool(bytes32 poolId, int24 tick, int24 tickSpacing) internal {

            tickBitmap[poolId].flipTick(tick, tickSpacing);
        }

        // Add claim function
        function claimOrder(bytes32 orderId, PoolKey calldata key) external {
            LimitOrder storage order = limitOrders[orderId];
            require(order.delta != BalanceDelta.wrap(0), "Order not executed"); 
            require(msg.sender == order.owner, "Not owner");

            // Call unlock with CLAIM_ORDER
            poolManager.unlock(
                abi.encode(
                    UnlockCallbackData({
                        callbackType: CallbackType.CLAIM_ORDER,
                        data: abi.encode(
                            ClaimOrderCallbackData({
                                orderId: orderId,
                                key: key
                            })
                        )
                    })
                )
            );
        }

        // Optional: Add ability to update treasury
        function setTreasury(address _treasury) external {
            if (_treasury == address(0)) revert("Invalid treasury");
            if (msg.sender != treasury) revert("Not authorized"); 
            treasury = _treasury;
        }
    }





