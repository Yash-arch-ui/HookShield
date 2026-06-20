// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MarketData} from "./MarketData.sol";
import {FeeCalculator} from "./FeeCalculator.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

contract HookShield is IHooks {
    event DynamicFeeComputed(uint256 tradeSize, uint256 volatility, uint24 fee);

    MarketData public marketData;
    FeeCalculator public feeCalculator;
    IPoolManager public poolManager;

    uint24 public latestFee;
    bool public lastSwapTriggered;

    constructor(address _marketData, address _feeCalculator, IPoolManager _poolManager) {
        marketData = MarketData(_marketData);
        feeCalculator = FeeCalculator(_feeCalculator);
        poolManager = _poolManager;
    }

    // ---------------- BEFORE SWAP ----------------
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSwapTriggered = true;

        (int256 priceRaw, int256 volRaw,,) = marketData.getLatestMarketData();
        require(priceRaw > 0 && volRaw > 0, "BAD_ORACLE");

        uint256 volatility = uint256(volRaw);

        uint256 tradeSize =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        uint24 fee = feeCalculator.calculateFee(tradeSize, volatility);

        latestFee = fee;

        emit DynamicFeeComputed(tradeSize, volatility, fee);

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------- AFTER SWAP (FIXED) ----------------
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    // ---------------- AFTER ADD LIQUIDITY (FIXED) ----------------
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ---------------- AFTER REMOVE LIQUIDITY (FIXED) ----------------
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    // ---------------- REQUIRED SIMPLE HOOKS ----------------

    function beforeInitialize(address, PoolKey calldata, uint160) external returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // ---------------- PERMISSIONS ----------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
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
