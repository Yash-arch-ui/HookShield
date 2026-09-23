// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IRiskModel {
    /// @param tradeSize Absolute size of the incoming swap.
    /// @param liquidity  Current in-range pool liquidity.
    function risk(PoolId poolId, uint256 tradeSize, uint256 liquidity) external view returns (uint256 riskE18);

    /// @notice True when any core signal for the pool is stale (P0).
    /// @dev The hook uses this to skip pause enforcement while signals are
    ///      expired: when stale, risk escalates to SCALE which would otherwise
    ///      latch the circuit breaker permanently (no swaps -> no signal
    ///      refreshes -> still stale). Skipping enforcement lets one swap
    ///      through, which refreshes signals in afterSwap and clears the
    ///      condition.
    function isStale(PoolId poolId) external view returns (bool);
}
