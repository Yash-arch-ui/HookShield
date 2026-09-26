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
///      H-2: the five off-chain reporter scores (JIT, sandwich, flashloan, toxic
///      flow, MEV) are folded in as an additive capped term — the maximum FRESH
///      reporter score times `reporterWeight`. Reporter staleness (H-3) is
///      asymmetric to core staleness by design:
///        - core stale  → STALE_FALLBACK_RISK (SCALE): the hook re-publishes core
///          signals on every swap, so expiry means something is broken → max fee;
///        - reporter stale/never-written → contributes 0: reporters are external
///          and may be silent for long stretches; expiring to SCALE would pin the
///          fee at maximum (or trip the halt path) purely because no reporter
///          submitted a report. Absence of a report is not evidence of risk.
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

    /// @notice Default weight of the reporter-score term (H-2).
    /// @dev Additive on top of the four core weights (which still sum to SCALE),
    ///      capped like MAX_PRESSURE so reporters can lift a low-signal score but
    ///      never dominate it alone.
    uint256 public constant DEFAULT_REPORTER_WEIGHT = 0.3e18;

    SignalState public immutable signalState;
    uint256 public volatilityWeight;
    uint256 public inventorySkewWeight;
    uint256 public oracleDivergenceWeight;
    uint256 public whaleScoreWeight;
    uint256 public reporterWeight;

    event WeightsUpdated(
        uint256 volatilityWeight, uint256 inventorySkewWeight, uint256 oracleDivergenceWeight, uint256 whaleScoreWeight
    );

    event ReporterWeightUpdated(uint256 reporterWeight);

    constructor(
        address _signalState,
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) Ownable(msg.sender) {
        require(_signalState != address(0), "zero signalState");
        _setWeights(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
        reporterWeight = DEFAULT_REPORTER_WEIGHT;
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

        // H-2: reporter term — the worst FRESH off-chain score, scaled by
        // reporterWeight. Stale/never-written reporters contribute 0 (see the
        // contract-level doc for why this is asymmetric to core staleness).
        if (reporterWeight > 0) {
            uint256 reporterMax = _maxFreshReporterScore(snap);
            riskE18 += (reporterMax * reporterWeight) / SCALE;
        }

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

    /// @dev Maximum of the reporter scores whose per-field deadline is still
    ///      valid at the current timestamp. Fields never written (deadline == 0)
    ///      or already expired are skipped, so they cannot contribute.
    function _maxFreshReporterScore(SignalSnapshot memory snap) internal view returns (uint256 maxScore) {
        maxScore = _freshScore(snap.jitScore, snap.jitValidUntil, maxScore);
        maxScore = _freshScore(snap.sandwichScore, snap.sandwichValidUntil, maxScore);
        maxScore = _freshScore(snap.flashloanScore, snap.flashloanValidUntil, maxScore);
        maxScore = _freshScore(snap.toxicFlowScore, snap.toxicFlowValidUntil, maxScore);
        maxScore = _freshScore(snap.mevScore, snap.mevValidUntil, maxScore);
    }

    function _freshScore(uint256 score, uint256 validUntil, uint256 currentMax) internal view returns (uint256) {
        if (validUntil == 0 || block.timestamp > validUntil) return currentMax;
        return score > currentMax ? score : currentMax;
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

    /// @notice Owner-tunable weight of the reporter-score term (H-2).
    /// @dev Bounded to <= SCALE so the additive term can never push a maxed-out
    ///      core score past SCALE on its own beyond the final clamp, and so it
    ///      can be set to 0 to disable reporter influence entirely (kill switch).
    function setReporterWeight(uint256 _reporterWeight) external onlyOwner {
        require(_reporterWeight <= SCALE, "reporter weight out of bounds");
        reporterWeight = _reporterWeight;
        emit ReporterWeightUpdated(_reporterWeight);
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
