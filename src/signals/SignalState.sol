// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

struct SignalSnapshot {
    uint256 volatility;
    uint256 inventorySkew;
    uint256 oracleDivergence;
    uint256 whaleScore;
    uint256 updatedAt;
    uint256 validUntil;
}

contract SignalState is Ownable {
    uint256 constant _STALENESS_WINDOW = 60 minutes;

    mapping(PoolId => SignalSnapshot) private snapshots;
    mapping(address => bool) public authorizedWriters;

    constructor() Ownable(msg.sender) {}

    modifier onlyAuthorized() {
        require(authorizedWriters[msg.sender], "not authorized");
        _;
    }

    function setVolatility(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        snapshots[poolId].volatility = value;
        snapshots[poolId].updatedAt = uint64(block.timestamp);
        snapshots[poolId].validUntil = block.timestamp + _STALENESS_WINDOW;
    }

    function setInventorySkew(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        snapshots[poolId].inventorySkew = value;
        snapshots[poolId].updatedAt = uint64(block.timestamp);
        snapshots[poolId].validUntil = block.timestamp + _STALENESS_WINDOW;
    }

    function setOracleDivergence(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        snapshots[poolId].oracleDivergence = value;
        snapshots[poolId].updatedAt = uint64(block.timestamp);
        snapshots[poolId].validUntil = block.timestamp + _STALENESS_WINDOW;
    }

    function setWhaleScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        snapshots[poolId].whaleScore = value;
        snapshots[poolId].updatedAt = uint64(block.timestamp);
        snapshots[poolId].validUntil = block.timestamp + _STALENESS_WINDOW;
    }

    // --- READ FUNCTION (used by RiskModel) ---

    function getSnapshot(PoolId poolId) external view returns (SignalSnapshot memory) {
        return snapshots[poolId];
    }

    function isStale(PoolId poolId) external view returns (bool) {
        return block.timestamp > snapshots[poolId].validUntil;
    }

    // --- ADMIN ---

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
    }
}
