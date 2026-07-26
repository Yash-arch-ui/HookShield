// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

interface IRiskModel {
    function risk(PoolId poolId, uint256 tradeSize) external view returns (uint256 riskE18);
}
