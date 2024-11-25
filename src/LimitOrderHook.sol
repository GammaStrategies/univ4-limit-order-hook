// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";



contract LimitOrderHook is BaseHook, IERC6909 {
    using EnumerableSet for EnumerableSet.Int24Set;
    using CurrencySettler for Currency;


    // Struct to represent a limit order
    struct LimitOrder {
        address owner;      // Who receives the filled order
        bool isToken0;         // Whether the input token is token0
        bool isRange;          // Whether this is a range order or single-tick limit order
        int24 targetTick;      // Target tick for single-tick limit orders
        uint256 amount;        // Amount of input token
        uint128 liquidity;     // Liquidity amount
        int24 bottomTick;      // Bottom tick for range orders
        int24 topTick;         // Top tick for range orders
        bool executed;         // Whether the order has been executed 
        uint256 executionFees0; // Fees earned in token0
        uint256 executionFees1;  // Fees earned in token1
    }

    // Mapping from poolId to tick to orderIds
    mapping(bytes32 => mapping(int24 => bytes32[])) public tickToOrders;
    
    // All limit orders
    mapping(bytes32 => LimitOrder) public limitOrders;
    
    // Track which ticks have limit orders
    mapping(bytes32 => EnumerableSet.Int24Set) private poolTicks;

    // ERC-6909 claim tokens
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isOperator;

    uint256 public constant CLAIM_TOKEN_ID = 1;

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

    // Store old tick in transient storage
    function beforeSwap(
        address,
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        (,int24 oldTick,,,,,) = poolManager.getSlot0(key.toId());
        assembly {
            tstore(0x4444000000000000000000000000000000000000000000000000000000000000, oldTick)
        }
        return BaseHook.beforeSwap.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        bytes32 poolId = key.toId();

        // Get old and new tick
        int24 oldTick;
        assembly {
            oldTick := tload(0x4444000000000000000000000000000000000000000000000000000000000000)
        }
        (,int24 newTick,,,,,)=poolManager.getSlot0(poolId);

        // Determine tick range to check

        int24 startTick = params.zeroForOne ? oldTick : newTick;
        int24 endTick = params.zeroForOne ? newTick : oldTick;

        // Check all ticks in range for limit orders
        uint256 length = poolTicks[poolId].length();
        for (uint256 i = 0; i < length;) {
            int24 tick = poolTicks[poolId].length();

            if (tick >= startTick && tick <= endTick) {
                // Execute orders at this tick
                bytes32[] storage orderIds = tickToOrders[poolId][tick];

                for(uint256 j = 0; j < orderIds.length; j++) {
                    LimitOrder storage order = limitOrders[orderIds[j]];

                    if (!order.executed && tick == order.targetTick) {
                        // Burn the liquidity
                        _burnLimitOrder(key, order, orderIds[j]);

                        // Calculate execution amounts and mint claim token
                        (uint256 amount0, uint256 amount1) = _calculateExecutionAmounts(order);
                        balanceOf[order.owner][CLAIM_TOKEN_ID] += amount0 + amount1;

                        emit LimitOrderExecuted(orderIds[j], order.owner, amount0, amount1);
                    }                
                }
            }
            unchecked { ++i;}
        }
        return BaseHook.afterSwap.selector;
    }

    function _burnLimitOrder(
        PoolKey calldata key,
        LimitOrder storage order,
        bytes32 orderId
    ) internal {
        // Burn liquidity from pool
        poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLIquidityParams({
                tickLower: order.bottomTick,
                tickUpper: order.topTick,
                liquidityDelta: -int128(order.liquidity)
            })
        );

        order.executed = true;
    }

    // ERC-6909 functions
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        return true;
    }

    function transfer(address to, uint256 id, uint256 amount) external returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[to][id] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to, 
        uint256 amount
    ) external returns (bool) {
        require(
            from == msg.sender || isOperator[from][msg.sender],
            "Not authorized"
        );
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        return true;
    }

    // Function to claim executed limit orders
    function claimLimitOrder(bytes32 orderId) external {
        LimitOrder storage order = limitOrders[orderId];
        require(order.executed, "Order not executed");
        require(msg.sender == order.owner, "Not owner");

        uint256 claimAmount = balanceOf[msg.sender][CLAIM_TOKEN_ID];
        require(claimAmount > 0, "Nothing to claim");

        balanceOf[msg.sender][CLAIM_TOKEN_ID] = 0;

        // Transfer tokens to owner
        // Implement actual token transfer logic
    } 

    event LimitOredrExecuted(
        bytes32 indexed orderId,
        address indexed owner,
        uint256 amount0,
        uint256 amount1
    );
    
}





