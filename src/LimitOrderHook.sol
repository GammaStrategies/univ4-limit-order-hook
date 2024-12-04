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
        address owner;      // 20 bytes
        bool isToken0;      // 1 byte
        bool isRange;       // 1 byte (added back)
        bool executed;      // 1 byte
        int24 bottomTick;   // 3 bytes
        int24 topTick;      // 3 bytes
        uint128 liquidity;  // 16 bytes
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

        (BalanceDelta delta,) = _addLiquidity(addLiquidityParams);

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
        targetTick = (targetTick / tickSpacing) * tickSpacing;
    } else {
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
) internal returns (BalanceDelta delta, BalanceDelta feeDelta) {
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
                        settleUsingBurn: false,
                        takeClaims: false
                    })
                )
            })
        )
    );

    return abi.decode(result, (BalanceDelta, BalanceDelta));
}



function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
    UnlockCallbackData memory cbd = abi.decode(data, (UnlockCallbackData));
    
    if (cbd.callbackType == CallbackType.MODIFY_LIQUIDITY) {
        ModifyLiquidityCallbackData memory callbackData = abi.decode(cbd.data, (ModifyLiquidityCallbackData));
        
        // Existing modify liquidity logic
        if (callbackData.amount0 > 0) {
            callbackData.key.currency0.settle(poolManager, address(this), callbackData.amount0, false);
        }
        if (callbackData.amount1 > 0) {
            callbackData.key.currency1.settle(poolManager, address(this), callbackData.amount1, false);
        }

        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
            callbackData.key,
            callbackData.params,
            callbackData.hookData
        );

        return abi.encode(delta, feeDelta);
    } else if (cbd.callbackType == CallbackType.CLAIM_ORDER) {
        ClaimOrderCallbackData memory claimData = abi.decode(cbd.data, (ClaimOrderCallbackData));
        
        LimitOrder storage order = limitOrders[claimData.orderId];
        require(order.executed, "Order not executed");
        // require(tx.origin == order.owner, "Not owner");

        uint256 currency0Id = uint256(uint160(Currency.unwrap(claimData.key.currency0)));
        uint256 currency1Id = uint256(uint160(Currency.unwrap(claimData.key.currency1)));
        
        uint256 balance0 = poolManager.balanceOf(order.owner, currency0Id);
        uint256 balance1 = poolManager.balanceOf(order.owner, currency1Id);

        if (balance0 > 0) {
            poolManager.burn(order.owner, currency0Id, balance0);
            poolManager.take(claimData.key.currency0, order.owner, balance0);
        }
        
        if (balance1 > 0) {
            poolManager.burn(order.owner, currency1Id, balance1);
            poolManager.take(claimData.key.currency1, order.owner, balance1);
        }

        return abi.encode(0);
    }
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
        bytes32 poolId = getPoolId(key);
        bytes32 orderId = keccak256(abi.encode(poolId, msg.sender, block.timestamp));
        
        limitOrders[orderId] = LimitOrder({
            owner: msg.sender,
            isToken0: params.isToken0,
            isRange: params.isRange,
            executed: false,
            bottomTick: params.bottomTick,
            topTick: params.topTick,
            liquidity: params.liquidity
        });

        int24 storeTick = params.isToken0 ? params.topTick : params.bottomTick;
        _addTickToPool(poolId, storeTick, key.tickSpacing);
        tickToOrders[poolId][storeTick].push(orderId);

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
            LimitOrder storage order = limitOrders[tickOrders[j]];
            // Add tick validation
            bool validTick = zeroForOne ? 
                (tick <= (order.isToken0 ? order.topTick : order.bottomTick)) :  
                (tick >= (order.isToken0 ? order.topTick : order.bottomTick));
                
            if (!order.executed && order.isToken0 == !zeroForOne && validTick) {
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

    function _processOrder(
    PoolKey memory key,
    LimitOrder storage order,
    bytes32 orderId
    ) internal {
    (BalanceDelta delta, BalanceDelta feeDelta) = _burnLimitOrder(key, order, orderId);
    
    uint256 amount0;
    uint256 amount1;
    uint256 fee0;
    uint256 fee1;
    
    {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        int128 fee0Delta = feeDelta.amount0();
        int128 fee1Delta = feeDelta.amount1();
        
        if (delta0 > 0) amount0 = uint256(int256(delta0));
        if (delta1 > 0) amount1 = uint256(int256(delta1));
        if (fee0Delta > 0) fee0 = uint256(int256(fee0Delta));
        if (fee1Delta > 0) fee1 = uint256(int256(fee1Delta));
    }

    if (amount0 > 0 || fee0 > 0) {
        uint256 currency0Id = uint256(uint160(Currency.unwrap(key.currency0)));
        
        // Simple arithmetic for treasury portion
        uint256 treasuryAmount = (fee0 * 20) / 100;
        // Owner gets the main amount plus remaining fees
        uint256 ownerAmount = amount0 + (fee0 - treasuryAmount);
        
        if (ownerAmount > 0) {
            poolManager.mint(order.owner, currency0Id, ownerAmount);
        }
        if (treasuryAmount > 0) {
            poolManager.mint(treasury, currency0Id, treasuryAmount);
        }
    }
    
    if (amount1 > 0 || fee1 > 0) {
        uint256 currency1Id = uint256(uint160(Currency.unwrap(key.currency1)));
        
        uint256 treasuryAmount = (fee1 * 20) / 100;
        uint256 ownerAmount = amount1 + (fee1 - treasuryAmount);
        
        if (ownerAmount > 0) {
            poolManager.mint(order.owner, currency1Id, ownerAmount);
        }
        if (treasuryAmount > 0) {
            poolManager.mint(treasury, currency1Id, treasuryAmount);
        }
    }

    emit LimitOrderExecuted(orderId, order.owner, amount0 + fee0, amount1 + fee1);
    order.executed = true;
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

    function _burnLimitOrder(
        PoolKey memory key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal returns (BalanceDelta delta, BalanceDelta feeDelta) {
        (delta, feeDelta) = poolManager.modifyLiquidity(
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


    // Optional: Add ability to update treasury
    function setTreasury(address _treasury) external {
        if (_treasury == address(0)) revert("Invalid treasury");
        if (msg.sender != treasury) revert("Not authorized"); 
        treasury = _treasury;
    }
}





