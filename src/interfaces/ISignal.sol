// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolId} from "v4-core/types/PoolId.sol";

interface ISignal {
    // Returns the current normalized signal value for a pool
    // value Normalized between 0 and 1e18
    function compute(PoolId poolId) external view returns (uint256 value);

    // Triggers recomputation and writes the result into SignalState
    // Called from the hook's afterSwap (or similar), not from beforeSwap
    function update(PoolId poolId, uint256 newPrice) external;
}
