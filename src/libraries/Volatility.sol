// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VolatilityStorage} from "../VolatilityStorage.sol";

library Volatility {
    // ──────────────────────── Constants ────────────────────────
    uint256 internal constant SCALE = 1e18;

    /// @dev Slow-horizon EWMA decay on squared returns (variance) — P2.
    uint256 internal constant ALPHA = 0.1e18;
    uint256 internal constant ONE_MINUS_ALPHA = SCALE - ALPHA; // 0.9e18

    /// @dev Fast-horizon EWMA decay on |returns| — P2 momentum channel.
    uint256 internal constant ALPHA_FAST = 0.3e18;
    uint256 internal constant ONE_MINUS_ALPHA_FAST = SCALE - ALPHA_FAST; // 0.7e18

    /// @dev Per-observation return cap before it enters either EWMA — P1.
    ///      A single anomalous print (oracle glitch, thin-liquidity wick)
    ///      cannot dominate the estimate for many subsequent periods.
    uint256 internal constant MAX_OBSERVATION_RETURN = 0.05e18;

    // ──────────────────────── Errors ────────────────────────

    error Volatility__ZeroOldPrice();

    // ──────────────────────── A) Return Calculation ────────────────────────

    ///  Calculates the absolute percentage return between two sqrtPriceX96 values.
    ///     return = | newPrice - oldPrice | / oldPrice   (scaled by 1e18)
    ///         Uses sqrtPriceX96 directly — since |sqrt(P_new) - sqrt(P_old)| / sqrt(P_old)
    ///         is a monotonic proxy for the true price change, this is a valid volatility signal.
    ///  oldSqrtPriceX96 The previous sqrtPriceX96.
    ///  newSqrtPriceX96 The current  sqrtPriceX96.
    ///  absReturn The absolute percentage return, scaled by 1e18.
    function calculateReturn(uint160 oldSqrtPriceX96, uint160 newSqrtPriceX96) public pure returns (uint256 absReturn) {
        if (oldSqrtPriceX96 == 0) revert Volatility__ZeroOldPrice();

        uint256 oldPrice = uint256(oldSqrtPriceX96);
        uint256 newPrice = uint256(newSqrtPriceX96);
        uint256 diff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        absReturn = (diff * SCALE) / oldPrice;
    }

    // ──────────────────────── B) EWMA Update ────────────────────────

    ///  Updates the fast EWMA volatility estimate with a new return observation.
    ///     newEWMA = α * currentReturn + (1 - α) * x
    function updateEwma(uint256 oldEwma, uint256 currentReturn) internal pure returns (uint256 newEwma) {
        newEwma = (ALPHA * currentReturn + ONE_MINUS_ALPHA * oldEwma) / SCALE;
    }

    ///  Updates the fast-horizon EWMA (α=0.3) — reacts within a few swaps. — P2
    function updateEwmaFast(uint256 oldEwma, uint256 currentReturn) internal pure returns (uint256 newEwma) {
        newEwma = (ALPHA_FAST * currentReturn + ONE_MINUS_ALPHA_FAST * oldEwma) / SCALE;
    }

    ///  Updates the variance EWMA: newVar = α·r² + (1−α)·oldVar. — P2
    ///  r is 1e18-scaled, so r² must be re-scaled by /SCALE to stay 1e18-scaled.
    function updateEwmaVariance(uint256 oldVariance, uint256 absReturn) internal pure returns (uint256 newVariance) {
        uint256 r2 = (absReturn * absReturn) / SCALE;
        newVariance = (ALPHA * r2 + ONE_MINUS_ALPHA * oldVariance) / SCALE;
    }

    ///  Integer square root (Babylonian method) for sqrt(variance · SCALE). — P2
    ///  variance V is stored 1e18-scaled such that std = sqrt(V · SCALE).
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    ///  Converts a 1e18-scaled variance into a 1e18-scaled standard deviation.
    function varianceToVolatility(uint256 variance) internal pure returns (uint256) {
        return sqrt(variance * SCALE);
    }

    // ──────────────────────── C) Main compute() ────────────────────────

    ///  Full volatility computation pipeline. — P1/P2
    ///         Reads old state → calculates return → clamps → updates variance
    ///         EWMA (slow) and return EWMA (fast) → publishes max(slow, fast)
    ///         so spikes react immediately (momentum boost) while calm periods
    ///         decay at the slow rate (anti-flicker).
    ///  oldState        The previous VolatilityState from storage.
    ///  newSqrtPriceX96 The current sqrtPriceX96 after the swap.
    ///  updatedState   The new VolatilityState to be written back by the caller.
    function compute(VolatilityStorage.VolatilityState memory oldState, uint160 newSqrtPriceX96)
        internal
        view
        returns (VolatilityStorage.VolatilityState memory updatedState)
    {
        // ── First-time initialization (no prior price) ──
        if (oldState.lastSqrtPriceX96 == 0) {
            updatedState = VolatilityStorage.VolatilityState({
                lastSqrtPriceX96: newSqrtPriceX96,
                ewmaVolatility: 0,
                ewmaVolatilityFast: 0,
                ewmaVariance: 0,
                lastUpdateBlock: block.number
            });
            return updatedState;
        }

        // ── Step 1: Calculate return, then clamp the per-observation outlier (P1) ──
        uint256 absReturn = calculateReturn(oldState.lastSqrtPriceX96, newSqrtPriceX96);
        if (absReturn > MAX_OBSERVATION_RETURN) {
            absReturn = MAX_OBSERVATION_RETURN;
        }

        // ── Step 2: Slow channel — EWMA of squared returns (variance), then √ (P2) ──
        uint256 newVariance = updateEwmaVariance(oldState.ewmaVariance, absReturn);
        uint256 volSlow = varianceToVolatility(newVariance);

        // ── Step 3: Fast channel — EWMA of |returns| (P2) ──
        uint256 volFast = updateEwmaFast(oldState.ewmaVolatilityFast, absReturn);

        // ── Step 4: Publish max(slow, fast), capped at SCALE ──
        //   • fast > slow (momentum / new spike): use fast → reacts immediately.
        //   • fast < slow (calming): hold slow → elevated risk decays gradually
        //     instead of flickering back to calm on a single quiet swap.
        uint256 published = volFast > volSlow ? volFast : volSlow;
        if (published > SCALE) {
            published = SCALE;
        }

        // ── Step 5: Build updated state ──
        updatedState = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: newSqrtPriceX96,
            ewmaVolatility: published,
            ewmaVolatilityFast: volFast,
            ewmaVariance: newVariance,
            lastUpdateBlock: block.number
        });
    }
}
