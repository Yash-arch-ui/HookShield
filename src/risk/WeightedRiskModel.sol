// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRiskModel} from "./IRiskModel.sol";
import {SignalState, SignalSnapshot} from "../signals/SignalState.sol";

/// @title WeightedRiskModel
/// @notice Combines the four published risk signals into a single 0..1e18 risk score.
/// @dev P0: when any core signal has expired the model returns SCALE (max risk), so
///      the policy charges the maximum fee instead of the old, far-too-lenient 0.5
///      fallback. An attacker can no longer pin a low reading, wait out a stale
///      window, and coast on a mid-tier fee.
///      P2: a trade-size / pool-liquidity pressure term is folded in so a swap that
///      is large relative to available liquidity is scored as riskier, independent
///      of the historical whale-score signal.
contract WeightedRiskModel is IRiskModel, Ownable {
    uint256 public constant SCALE = 1e18;

    /// @notice Risk returned when any core signal is stale (P0).
    /// @dev Was 0.5e18 (mid-tier fee). Now SCALE so stale data escalates to the
    ///      maximum fee rather than a comfortable middle ground.
    uint256 public constant STALE_FALLBACK_RISK = 1e18;

    /// @notice Cap on the size/liquidity pressure term (P2).
    /// @dev A trade whose notional equals the pool's active liquidity produces
    ///      pressure == SCALE; anything larger is clamped so a single whale swap
    ///      cannot overflow the weighted sum.
    uint256 public constant MAX_PRESSURE = 0.3e18;

    SignalState public immutable signalState;
    uint256 public volatilityWeight;
    uint256 public inventorySkewWeight;
    uint256 public oracleDivergenceWeight;
    uint256 public whaleScoreWeight;

    event WeightsUpdated(
        uint256 volatilityWeight, uint256 inventorySkewWeight, uint256 oracleDivergenceWeight, uint256 whaleScoreWeight
    );

    constructor(
        address _signalState,
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) Ownable(msg.sender) {
        require(_signalState != address(0), "zero signalState");
        _setWeights(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
        signalState = SignalState(_signalState);
    }

    /// @param tradeSize Absolute size of the incoming swap (token units).
    /// @param liquidity Current in-range pool liquidity for the pool.
    function risk(PoolId poolId, uint256 tradeSize, uint256 liquidity)
        external
        view
        override
        returns (uint256 riskE18)
    {
        // P0: any expired core signal -> max risk -> max fee.
        if (signalState.isStale(poolId)) {
            return STALE_FALLBACK_RISK;
        }

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);

        riskE18 =
            (snap.volatility
                    * volatilityWeight
                    + snap.inventorySkew
                    * inventorySkewWeight
                    + snap.oracleDivergence
                    * oracleDivergenceWeight
                    + snap.whaleScore
                    * whaleScoreWeight) / SCALE;

        // P2: size/liquidity pressure term. Scales with tradeSize relative to
        // available liquidity, capped at MAX_PRESSURE so it can lift a low-signal
        // score without ever being the dominant term on its own.
        if (liquidity > 0) {
            uint256 rawPressure = (tradeSize * SCALE) / liquidity;
            uint256 pressure = rawPressure > MAX_PRESSURE ? MAX_PRESSURE : rawPressure;
            riskE18 += pressure;
        }

        if (riskE18 > SCALE) {
            riskE18 = SCALE;
        }
    }

    /// @notice Passthrough so the hook can skip pause enforcement while stale.
    function isStale(PoolId poolId) external view override returns (bool) {
        return signalState.isStale(poolId);
    }

    function setWeights(
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) external onlyOwner {
        _setWeights(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
    }

    function _setWeights(
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) internal {
        require(
            _volatilityWeight + _inventorySkewWeight + _oracleDivergenceWeight + _whaleScoreWeight == SCALE,
            "weights must sum to 1e18"
        );

        volatilityWeight = _volatilityWeight;
        inventorySkewWeight = _inventorySkewWeight;
        oracleDivergenceWeight = _oracleDivergenceWeight;
        whaleScoreWeight = _whaleScoreWeight;

        emit WeightsUpdated(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
    }
}
