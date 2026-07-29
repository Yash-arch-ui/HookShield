// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

struct PolicyAction {
    uint24 fee; // Uniswap v4 fee units (1_000_000 = 100%)
    bool pauseSwaps; // reserved for future use, do not enable in v1
    uint8 tier; // which risk band this fell into (for logging/analytics)
}

interface IPolicy {
    function action(PoolId poolId, uint256 riskE18) external view returns (PolicyAction memory action);
}
