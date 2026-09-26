// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPolicy, PolicyAction} from "./IPolicy.sol";

/// @title ThresholdPolicy
/// @notice Maps a 0..1e18 risk score to a dynamic LP fee, with an optional
///         circuit breaker and direction-aware inventory surcharge/discount.
contract ThresholdPolicy is IPolicy, Ownable {
    uint256 public constant SCALE = 1e18;

    // ── Analytics tier bands (fee itself is now continuous — P1) ──
    uint256 public tier1Threshold = 0.2e18;
    uint256 public tier2Threshold = 0.4e18;
    uint256 public tier3Threshold = 0.6e18;
    uint256 public tier4Threshold = 0.8e18;
    uint24 public tier0Fee = 3000; // < tier1: base fee
    uint24 public tier1Fee = 4000; // informational band label
    uint24 public tier2Fee = 6000; // informational band label
    uint24 public tier3Fee = 9000; // informational band label
    uint24 public tier4Fee = 12000; // max fee at risk == 1e18 (and surcharge ceiling base)

    // ── Quadratic fee curve (P1) ──
    // fee = tier0Fee + (tier4Fee - tier0Fee) * risk² / SCALE²
    // Low risk stays near the base fee; risk dominates only as it approaches 1.
    // (The old 5-step ladder had large cliffs at each threshold that LPs and
    //  swappers both found unpredictable.)

    // ── Circuit breaker (P3) ──
    /// @notice Risk at or above which swaps are paused for the pool.
    uint256 public haltThreshold = 0.95e18;
    /// @notice Dead-band width: while paused, risk must fall to
    ///         (haltThreshold - unpauseBand) before swaps resume. Prevents the
    ///         pause flag from flickering on/off every swap around the threshold.
    uint256 public unpauseBand = 0.1e18;

    /// @notice Per-pool pause latch. Set/cleared by action() with hysteresis.
    mapping(PoolId => bool) public pausedSwaps;

    // ── Direction-aware inventory fee (P2) ──
    /// @notice Extra fee (pips) when the swap worsens the inventory imbalance.
    uint24 public inventorySurchargeFee = 500; // +0.05%
    /// @notice Discount (pips) when the swap rebalances inventory.
    uint24 public inventoryDiscountFee = 200; // -0.05%

    constructor() Ownable(msg.sender) {}

    function action(PoolId poolId, uint256 riskE18, bool zeroForOne, int256 inventoryNetFlow)
        external
        override
        returns (PolicyAction memory)
    {
        // Quadratic curve: continuous, base fee at risk=0, tier4Fee at risk=1e18.
        uint256 fee =
            uint256(tier0Fee) + ((uint256(tier4Fee) - uint256(tier0Fee)) * riskE18 * riskE18) / (SCALE * SCALE);

        // Direction-aware inventory adjustment (P2).
        // netFlow > 0 = previous swaps skewed toward zeroForOne.
        //   • zeroForOne swap deepens that skew → surcharge.
        //   • oneForZero swap rebalances it      → discount.
        // Symmetric when netFlow < 0.
        bool worsensSkew = (inventoryNetFlow > 0 && zeroForOne) || (inventoryNetFlow < 0 && !zeroForOne);
        bool rebalances = (inventoryNetFlow > 0 && !zeroForOne) || (inventoryNetFlow < 0 && zeroForOne);
        if (worsensSkew) {
            fee += inventorySurchargeFee;
        } else if (rebalances) {
            fee = fee > inventoryDiscountFee ? fee - inventoryDiscountFee : uint256(tier0Fee);
        }
        // Cap: max fee can exceed tier4Fee only by the surcharge amount.
        uint256 maxFee = uint256(tier4Fee) + uint256(inventorySurchargeFee);
        if (fee > maxFee) {
            fee = maxFee;
        }

        // Analytics tier (labels only — the fee itself is continuous now).
        uint8 tier;
        if (riskE18 < tier1Threshold) {
            tier = 0;
        } else if (riskE18 < tier2Threshold) {
            tier = 1;
        } else if (riskE18 < tier3Threshold) {
            tier = 2;
        } else if (riskE18 < tier4Threshold) {
            tier = 3;
        } else {
            tier = 4;
        }

        // Circuit breaker with dead-band hysteresis (P3 anti-flicker).
        bool paused = pausedSwaps[poolId];
        if (!paused && riskE18 >= haltThreshold) {
            paused = true;
            pausedSwaps[poolId] = true;
        } else if (paused && riskE18 <= haltThreshold - unpauseBand) {
            paused = false;
            pausedSwaps[poolId] = false;
        }

        return PolicyAction({fee: uint24(fee), pauseSwaps: paused, tier: tier});
    }

    function setThresholds(uint256 _tier1, uint256 _tier2, uint256 _tier3, uint256 _tier4) external onlyOwner {
        require(_tier1 < _tier2 && _tier2 < _tier3 && _tier3 < _tier4 && _tier4 <= SCALE, "invalid thresholds");
        tier1Threshold = _tier1;
        tier2Threshold = _tier2;
        tier3Threshold = _tier3;
        tier4Threshold = _tier4;
    }

    function setFees(uint24 _tier0Fee, uint24 _tier1Fee, uint24 _tier2Fee, uint24 _tier3Fee, uint24 _tier4Fee)
        external
        onlyOwner
    {
        tier0Fee = _tier0Fee;
        tier1Fee = _tier1Fee;
        tier2Fee = _tier2Fee;
        tier3Fee = _tier3Fee;
        tier4Fee = _tier4Fee;
    }

    /// @notice Owner-tunable circuit-breaker band (P3).
    function setHaltParams(uint256 _haltThreshold, uint256 _unpauseBand) external onlyOwner {
        require(_unpauseBand < _haltThreshold && _haltThreshold <= SCALE, "invalid halt params");
        haltThreshold = _haltThreshold;
        unpauseBand = _unpauseBand;
    }

    /// @notice Owner-tunable inventory surcharge/discount (P2).
    function setInventoryFees(uint24 surcharge, uint24 discount) external onlyOwner {
        require(uint256(surcharge) + uint256(discount) <= uint256(tier4Fee), "fees too large");
        inventorySurchargeFee = surcharge;
        inventoryDiscountFee = discount;
    }
}
