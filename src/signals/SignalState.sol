// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Snapshot of all published signals for one pool.
/// @dev The four core signals consumed by WeightedRiskModel each carry their own
///      `*ValidUntil` timestamp so a single shared deadline cannot mask staleness
///      in a different field (P0 research finding). Reporter scores now also
///      carry per-field deadlines (H-3) because WeightedRiskModel consumes them
///      (H-2): a single shared `validUntil` would let a fresh JIT report mask an
///      expired sandwich report (and vice versa). The shared `validUntil` is
///      still written by every reporter setter for backwards compatibility.
struct SignalSnapshot {
    uint256 volatility;
    uint256 inventorySkew;
    uint256 oracleDivergence;
    uint256 whaleScore;
    uint256 jitScore;
    uint256 sandwichScore;
    uint256 flashloanScore;
    uint256 toxicFlowScore;
    uint256 mevScore;
    uint256 updatedAt;
    uint256 validUntil;
    // Per-field staleness deadlines for the four risk-model signals.
    uint256 volatilityValidUntil;
    uint256 inventoryValidUntil;
    uint256 oracleValidUntil;
    uint256 whaleValidUntil;
    // Per-field staleness deadlines for the five reporter scores (H-3).
    uint256 jitValidUntil;
    uint256 sandwichValidUntil;
    uint256 flashloanValidUntil;
    uint256 toxicFlowValidUntil;
    uint256 mevValidUntil;
}

contract SignalState is Ownable {
    /// @notice Default freshness window for a published signal value.
    /// @dev Reduced from the original 60 minutes: a long window lets an attacker
    ///      pin a low-risk reading and coast on it (P0 research finding). 5 minutes
    ///      forces frequent re-observation while staying above one block time.
    uint256 public constant DEFAULT_STALENESS_WINDOW = 5 minutes;

    /// @notice Current freshness window applied to each per-field write.
    uint256 public stalenessWindow = DEFAULT_STALENESS_WINDOW;

    mapping(PoolId => SignalSnapshot) private snapshots;
    mapping(address => bool) public authorizedWriters;

    constructor() Ownable(msg.sender) {}

    modifier onlyAuthorized() {
        require(authorizedWriters[msg.sender], "not authorized");
        _;
    }

    /// @notice Updates the owner-tunable freshness window.
    /// @dev Bounded to [30 seconds, 60 minutes] so it cannot be set to zero
    ///      (which would make every signal instantly stale) or to a multi-hour
    ///      value that reintroduces the original staleness attack.
    function setStalenessWindow(uint256 window) external onlyOwner {
        require(window >= 30 seconds && window <= 60 minutes, "window out of bounds");
        stalenessWindow = window;
    }

    // --- Core risk-model signals (per-field deadline) ---

    function setVolatility(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.volatility = value;
        s.volatilityValidUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setInventorySkew(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.inventorySkew = value;
        s.inventoryValidUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setOracleDivergence(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.oracleDivergence = value;
        s.oracleValidUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setWhaleScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.whaleScore = value;
        s.whaleValidUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    // --- Reporter scores (per-field deadline, H-3) ---
    // Each setter stamps its OWN `*ValidUntil` so an expired sandwich report
    // cannot be masked by a fresh JIT report sharing one deadline. The shared
    // `validUntil` is still refreshed for backwards compatibility with any
    // reader that predates the per-field deadlines.

    function setJitScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.jitScore = value;
        s.jitValidUntil = block.timestamp + stalenessWindow;
        s.validUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setSandwichScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.sandwichScore = value;
        s.sandwichValidUntil = block.timestamp + stalenessWindow;
        s.validUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setFlashloanScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.flashloanScore = value;
        s.flashloanValidUntil = block.timestamp + stalenessWindow;
        s.validUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setToxicFlowScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.toxicFlowScore = value;
        s.toxicFlowValidUntil = block.timestamp + stalenessWindow;
        s.validUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    function setMevScore(PoolId poolId, uint256 value) external onlyAuthorized {
        require(value <= 1e18, "out of bounds");
        SignalSnapshot storage s = snapshots[poolId];
        s.mevScore = value;
        s.mevValidUntil = block.timestamp + stalenessWindow;
        s.validUntil = block.timestamp + stalenessWindow;
        s.updatedAt = block.timestamp;
    }

    // --- READ FUNCTION (used by RiskModel) ---

    function getSnapshot(PoolId poolId) external view returns (SignalSnapshot memory) {
        return snapshots[poolId];
    }

    /// @notice True when ANY of the four core risk-model signals has expired.
    /// @dev A field that has never been written (validUntil == 0) is NOT stale:
    ///      it simply has its default value of 0 (no observed risk). Staleness
    ///      means "was written but is now too old to trust."
    function isStale(PoolId poolId) external view returns (bool) {
        SignalSnapshot storage s = snapshots[poolId];
        return _isExpired(s.volatilityValidUntil) || _isExpired(s.inventoryValidUntil) || _isExpired(s.oracleValidUntil)
            || _isExpired(s.whaleValidUntil);
    }

    function isVolatilityStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].volatilityValidUntil);
    }

    function isInventoryStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].inventoryValidUntil);
    }

    function isOracleStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].oracleValidUntil);
    }

    function isWhaleStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].whaleValidUntil);
    }

    // --- Per-field reporter staleness (H-3) ---
    // Each reporter score has its own deadline so an expired sandwich report
    // cannot hide behind a fresh JIT report. Semantics match the core fields:
    // never-written (validUntil == 0) is NOT stale — it simply has no value.
    // These views do NOT feed the pool-level `isStale()` gate; WeightedRiskModel
    // reads the snapshot deadlines directly and contributes 0 for fields that
    // are expired or never written (reporter downtime must not push risk to
    // SCALE — unlike core signals, which the hook re-publishes every swap).

    function isJitStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].jitValidUntil);
    }

    function isSandwichStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].sandwichValidUntil);
    }

    function isFlashloanStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].flashloanValidUntil);
    }

    function isToxicFlowStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].toxicFlowValidUntil);
    }

    function isMevStale(PoolId poolId) external view returns (bool) {
        return _isExpired(snapshots[poolId].mevValidUntil);
    }

    function _isExpired(uint256 validUntil) internal view returns (bool) {
        return validUntil != 0 && block.timestamp > validUntil;
    }

    // --- ADMIN ---

    function setAuthorizedWriter(address writer, bool allowed) external onlyOwner {
        authorizedWriters[writer] = allowed;
    }
}
