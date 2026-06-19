// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {MarketData} from "./MarketData.sol";
import {FeeCalculator} from "./FeeCalculator.sol";

contract HookShield {
    event DynamicFeeComputed(uint256 tradeSize, uint256 volatility, uint24 fee);
    MarketData public marketData;
    FeeCalculator public feeCalculator;

    uint24 public latestFee;

    constructor(address _marketData, address _feeCalculator) {
        marketData = MarketData(_marketData);
        feeCalculator = FeeCalculator(_feeCalculator);
    }

    // =========================
    // BEFORE SWAP (CORE LOGIC)
    // =========================
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Get market data
        (int256 priceRaw, int256 volRaw,,) = marketData.getLatestMarketData();
        uint256 price = uint256(priceRaw);
        uint256 volatility = uint256(volRaw);
        // 2. Compute fee using your model
        uint24 fee = feeCalculator.calculateFee(
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified), volatility
        );
        uint256 tradeSize =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);
        emit DynamicFeeComputed(tradeSize, volatility, fee);

        latestFee = fee;

        // 3. Return fee to PoolManager
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee);
    }

    // =========================
    // REQUIRED HOOK FUNCTIONS
    // (MUST EXIST EVEN IF EMPTY)
    // =========================

    function beforeInitialize(address, PoolKey calldata, uint160) external returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160) external returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4)
    {
        return bytes4(0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
