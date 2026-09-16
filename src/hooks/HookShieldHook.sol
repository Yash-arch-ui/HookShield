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
import {OracleDivergenceSignal} from "../signals/OracleDivergenceSignal.sol";
import {IRiskModel} from "../risk/IRiskModel.sol";
import {IPolicy, PolicyAction} from "../policy/IPolicy.sol";
import {AnalyticsEngine} from "../analytics/AnalyticsEngine.sol";

contract HookShieldHook is IHooks {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event DynamicFeeComputed(uint256 tradeSize, uint256 riskE18, uint24 fee, uint8 tier);

    IPoolManager public poolManager;
    VolatilitySignal public volatilitySignal;
    InventorySignal public inventorySignal;
    WhaleScoreSignal public whaleSignal;
    OracleDivergenceSignal public oracleSignal;
    IRiskModel public riskModel;
    IPolicy public policy;
    AnalyticsEngine public analyticsEngine;

    uint24 public latestFee;
    bool public lastSwapTriggered;

    uint256 internal _lastRiskE18;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "NOT_MANAGER");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address _volatilitySignal,
        address _inventorySignal,
        address _whaleSignal,
        address _oracleSignal,
        address _riskModel,
        address _policy,
        address _analyticsEngine
    ) {
        poolManager = _poolManager;
        volatilitySignal = VolatilitySignal(_volatilitySignal);
        inventorySignal = InventorySignal(_inventorySignal);
        whaleSignal = WhaleScoreSignal(_whaleSignal);
        oracleSignal = OracleDivergenceSignal(_oracleSignal);
        riskModel = IRiskModel(_riskModel);
        policy = IPolicy(_policy);
        analyticsEngine = AnalyticsEngine(_analyticsEngine);
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

        // ── Whale score: written here in beforeSwap, not afterSwap ──────────────
        //
        // WhaleScoreSignal must react to THIS swap's own size relative to current
        // pool liquidity, because the whole point is to charge a fee that reflects
        // the price impact this specific swap will cause.  If we computed it in
        // afterSwap (like Volatility / Inventory / OracleDivergence), we would only
        // have the post-swap price — too late to influence the fee for THIS swap.
        //
        // This creates a same-transaction read-after-write: whaleSignal.update()
        // writes to SignalState, then riskModel.risk() reads it moments later in the
        // same beforeSwap call.  This is safe because:
        //   1. The entire beforeSwap is atomic — no external actor can observe or
        //      react to the intermediate state.
        //   2. The written whale score only affects THIS swap's own fee; it cannot
        //      be exploited by the swapper because the fee is deterministic given
        //      the trade size and current liquidity — both of which the swapper
        //      already controls via amountSpecified.
        whaleSignal.update(poolId, tradeSize, params.zeroForOne);

        uint256 riskE18 = riskModel.risk(poolId, tradeSize);
        _lastRiskE18 = riskE18;
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
        oracleSignal.update(poolId, currentSqrtPriceX96);

        uint256 tradeSize =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        analyticsEngine.recordSwap(PoolId.unwrap(poolId), tradeSize, _lastRiskE18, latestFee, params.zeroForOne);

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
