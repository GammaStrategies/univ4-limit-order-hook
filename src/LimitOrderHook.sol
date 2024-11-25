// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";



contract LimitOrderHook is BaseHook, IERC6909Claims {
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
        int256 token0Delta;   // Track exact amount of token0 to claim
        int256 token1Delta;   // Track exact amount of token1 to claim
        uint256 executionFees0; // Fees earned in token0
        uint256 executionFees1;  // Fees earned in token1
    }
    // Add slot constant 
    bytes32 constant PREVIOUS_TICK_SLOT = keccak256("uniswap.hooks.limitorder.previous-tick");
    
    // Add the new allowance mapping required by IERC6909Claims
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _allowances;



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
            tstore(PREVIOUS_TICK_SLOT, oldTick)
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
            oldTick := tload(PREVIOUS_TICK_SLOT)
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
        // Burn liquidity from pool and get exact token amounts
        (BalanceDelta delta, BalanceDelta feeDelta) = 
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

    // Add required function from IERC6909Claims
    function allowance(address owner, address spender, uint256 id) external view returns (uint256) {
        return _allowances[owner][spender][id];
    }

    // Add required function from IERC6909Claims
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    // Modify your setOperator to emit the correct event
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // Modify your existing transfer function to emit the correct event
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    // Modify your transferFrom to match IERC6909Claims
    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        if (sender != msg.sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = _allowances[sender][msg.sender][id];
            if (amount > allowed) revert("Transfer amount exceeds allowance");
            _allowances[sender][msg.sender][id] = allowed - amount;
        }
        
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }
    
    // Add required events from IERC6909Claims
    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

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

    event LimitOrderExecuted(
        bytes32 indexed orderId,
        address indexed owner,
        uint256 amount0,
        uint256 amount1
    );
    
}





