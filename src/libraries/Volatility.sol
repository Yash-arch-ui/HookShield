// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VolatilityStorage} from "../VolatilityStorage.sol";
library Volatility {
    // ──────────────────────── Constants ────────────────────────
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant ALPHA = 0.1e18;
    uint256 internal constant ONE_MINUS_ALPHA = SCALE - ALPHA; // 0.9e18

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
    function calculateReturn(
        uint160 oldSqrtPriceX96,
        uint160 newSqrtPriceX96
    ) internal pure returns (uint256 absReturn) {
        if (oldSqrtPriceX96 == 0) revert Volatility__ZeroOldPrice();

        uint256 oldPrice = uint256(oldSqrtPriceX96);
        uint256 newPrice = uint256(newSqrtPriceX96);
        uint256 diff = newPrice > oldPrice
            ? newPrice - oldPrice
            : oldPrice - newPrice;
        absReturn = (diff * SCALE) / oldPrice;
    }

    // ──────────────────────── B) EWMA Update ────────────────────────

    ///  Updates the EWMA volatility estimate with a new return observation.
    ///     newEWMA = α * currentReturn + (1 - α) * oldEWMA
    ///  oldEwma       The previous EWMA volatility (scaled 1e18).
    ///  currentReturn The latest absolute return   (scaled 1e18).
    ///  newEwma      The updated EWMA volatility  (scaled 1e18).
    function updateEwma(
        uint256 oldEwma,
        uint256 currentReturn
    ) internal pure returns (uint256 newEwma) {
        // α · currentReturn  +  (1 − α) · oldEwma
        newEwma = (ALPHA * currentReturn + ONE_MINUS_ALPHA * oldEwma) / SCALE;
    }

    // ──────────────────────── C) Main compute() ────────────────────────

    ///  Full volatility computation pipeline.
    ///         Reads old state → calculates return → updates EWMA → returns new state.
    ///         Does NOT write to storage — the caller is responsible for persisting.
    ///  oldState        The previous VolatilityState from storage.
    ///  newSqrtPriceX96 The current sqrtPriceX96 after the swap.
    ///  updatedState   The new VolatilityState to be written back by the caller.
    function compute(
        VolatilityStorage.VolatilityState memory oldState,
        uint160 newSqrtPriceX96
    ) internal view returns (VolatilityStorage.VolatilityState memory updatedState) {
        // ── First-time initialization (no prior price) ──
        if (oldState.lastSqrtPriceX96 == 0) {
            updatedState = VolatilityStorage.VolatilityState({
                lastSqrtPriceX96: newSqrtPriceX96,
                ewmaVolatility: 0,
                lastUpdateBlock: block.number
            });
            return updatedState;
        }

        // ── Step 1: Calculate return ──
        uint256 absReturn = calculateReturn(oldState.lastSqrtPriceX96, newSqrtPriceX96);

        // ── Step 2: Update EWMA ──
        uint256 newEwma = updateEwma(oldState.ewmaVolatility, absReturn);

        // ── Step 3: Build updated state ──
        updatedState = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: newSqrtPriceX96,
            ewmaVolatility: newEwma,
            lastUpdateBlock: block.number
        });
    }
}
