// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {VolatilitySignal} from "../signals/VolatilitySignal.sol";
import {InventorySignal} from "../signals/InventorySignal.sol";
import {WhaleScoreSignal} from "../signals/WhaleScoreSignal.sol";
import {IRiskModel} from "../risk/IRiskModel.sol";
import {IPolicy, PolicyAction} from "../policy/IPolicy.sol";

contract HookShieldHook is IHooks {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event DynamicFeeComputed(uint256 tradeSize, uint256 riskE18, uint24 fee, uint8 tier);

    IPoolManager public poolManager;
    VolatilitySignal public volatilitySignal;
    InventorySignal public inventorySignal;
    WhaleScoreSignal public whaleSignal;
    IRiskModel public riskModel;
    IPolicy public policy;

    uint24 public latestFee;
    bool public lastSwapTriggered;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "NOT_MANAGER");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _volatilitySignal,
        address _inventorySignal,
        address _whaleSignal,
        address _riskModel,
        address _policy
    ) {
        poolManager = _poolManager;
        volatilitySignal = VolatilitySignal(_volatilitySignal);
        inventorySignal = InventorySignal(_inventorySignal);
        whaleSignal = WhaleScoreSignal(_whaleSignal);
        riskModel = IRiskModel(_riskModel);
        policy = IPolicy(_policy);
    }

    // ---------------- BEFORE SWAP ----------------
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSwapTriggered = true;

        PoolId poolId = key.toId();

        uint256 tradeSize =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        // Publish the fresh whale score BEFORE reading risk, so this swap's own
        // price impact is included in the fee charged for it.
        whaleSignal.update(poolId, tradeSize, params.zeroForOne);

        uint256 riskE18 = riskModel.risk(poolId, tradeSize);
        PolicyAction memory act = policy.action(poolId, riskE18);

        latestFee = act.fee;

        emit DynamicFeeComputed(tradeSize, riskE18, act.fee, act.tier);

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), act.fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------- AFTER SWAP ----------------
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        volatilitySignal.update(poolId, currentSqrtPriceX96);
        inventorySignal.update(poolId, params.zeroForOne);

        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
