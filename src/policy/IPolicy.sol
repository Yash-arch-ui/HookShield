// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

struct PolicyAction {
    uint24 fee; // Uniswap v4 fee units (1_000_000 = 100%)
    bool pauseSwaps; // extreme-risk circuit breaker (P3)
    uint8 tier; // which risk band this fell into (for logging/analytics)
}

interface IPolicy {
    /// @param riskE18           Combined risk score, 0..1e18.
    /// @param zeroForOne        Direction of the incoming swap (P2).
    /// @param inventoryNetFlow  Signed inventory flow of the pool (P2):
    ///                          >0 means previously skewed toward zeroForOne.
    ///                          Used to surcharge swaps that worsen the skew and
    ///                          discount swaps that rebalance it.
    /// @dev State-changing: may latch/unlatch the per-pool pause flag using a
    ///      dead-band (P3 anti-flicker).
    function action(PoolId poolId, uint256 riskE18, bool zeroForOne, int256 inventoryNetFlow)
        external
        returns (PolicyAction memory action);
}
