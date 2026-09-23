// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISignal {
    /// @notice Returns the current normalized signal value for a pool
    /// @return value Normalized between 0 and 1e18
    function compute(PoolId poolId) external view returns (uint256 value);

    /// @notice Triggers recomputation and writes the result into SignalState
    /// @dev Called from the hook's afterSwap, not beforeSwap.
    ///      `tradeSize` lets the signal apply a dust filter: swaps below
    ///      `minObservationSize` are skipped entirely so an attacker cannot
    ///      manufacture fake volatility with near-zero trades (P1).
    function update(PoolId poolId, uint160 newSqrtPriceX96, uint256 tradeSize) external;
}
