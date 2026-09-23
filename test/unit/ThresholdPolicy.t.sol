// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ThresholdPolicy} from "../../src/policy/ThresholdPolicy.sol";
import {PolicyAction} from "../../src/policy/IPolicy.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract ThresholdPolicyTest is Test {
    ThresholdPolicy policy;
    PoolId poolId;

    function setUp() public {
        policy = new ThresholdPolicy();
        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    /// @dev Quadratic fee helper mirroring ThresholdPolicy's curve:
    ///      fee = 3000 + (12000 - 3000) * risk^2 / 1e36
    function _expectedFee(uint256 riskE18) internal pure returns (uint256) {
        return 3000 + (9000 * riskE18 * riskE18) / (1e18 * 1e18);
    }

    // ── Quadratic fee curve (P1) ────────────────────────────────────────

    function test_Action_QuadraticFeeBelowFirstThreshold() public {
        PolicyAction memory act = policy.action(poolId, 0.1e18, true, 0); // below 0.20e18
        // 3000 + 9000 * 0.01 = 3090 (was a flat 3000 under the old ladder)
        assertEq(act.fee, 3090);
        assertEq(act.fee, _expectedFee(0.1e18));
        assertEq(act.tier, 0);
    }

    function test_Action_QuadraticFeeNearMax() public {
        PolicyAction memory act = policy.action(poolId, 0.9e18, true, 0); // above 0.80e18
        // 3000 + 9000 * 0.81 = 10290 (ladder would have charged the flat 12000)
        assertEq(act.fee, 10290);
        assertEq(act.fee, _expectedFee(0.9e18));
        assertEq(act.tier, 4);
    }

    function test_Action_QuadraticFeeAtExactMaxRisk() public {
        PolicyAction memory act = policy.action(poolId, 1e18, true, 0);
        assertEq(act.fee, 12000); // equals tier4Fee at risk = SCALE
        assertEq(act.tier, 4);
    }

    function test_Action_ZeroRiskChargesBaseFee() public {
        PolicyAction memory act = policy.action(poolId, 0, true, 0);
        assertEq(act.fee, 3000);
        assertEq(act.tier, 0);
    }

    function test_Action_BoundaryValueAtExactThreshold() public {
        // riskE18 exactly equal to tier1Threshold (0.20e18): `<` puts it in tier 1.
        PolicyAction memory act = policy.action(poolId, 0.2e18, true, 0);
        assertEq(act.tier, 1);
        assertEq(act.fee, _expectedFee(0.2e18)); // 3360
    }

    function test_Action_FeeIsMonotonicInRisk() public {
        uint256 prevFee;
        for (uint256 r; r <= 10; r++) {
            uint256 risk = (r * 1e18) / 10;
            PolicyAction memory act = policy.action(poolId, risk, true, 0);
            if (r > 0) {
                assertGe(act.fee, prevFee, "fee must never decrease as risk rises");
            }
            prevFee = act.fee;
        }
    }

    // ── Direction-aware inventory fee (P2) ──────────────────────────────

    function test_Action_SurchargeWhenSwapWorsensSkew() public {
        // netFlow > 0 (previously skewed zeroForOne); this swap is also zeroForOne -> worsens.
        PolicyAction memory act = policy.action(poolId, 0.1e18, true, 1e18);
        assertEq(act.fee, _expectedFee(0.1e18) + 500);
    }

    function test_Action_DiscountWhenSwapRebalances() public {
        // netFlow > 0; this swap is oneForZero -> rebalances.
        PolicyAction memory act = policy.action(poolId, 0.1e18, false, 1e18);
        assertEq(act.fee, _expectedFee(0.1e18) - 200);
    }

    function test_Action_NoAdjustmentWhenInventoryBalanced() public {
        PolicyAction memory act = policy.action(poolId, 0.1e18, true, 0);
        assertEq(act.fee, _expectedFee(0.1e18));
    }

    function test_Action_SurchargeSymmetricForNegativeNetFlow() public {
        // netFlow < 0 (skewed oneForZero); oneForZero swap worsens it.
        PolicyAction memory act = policy.action(poolId, 0.1e18, false, -1e18);
        assertEq(act.fee, _expectedFee(0.1e18) + 500);
    }

    function test_Action_FeeCappedAtMaxPlusSurcharge() public {
        PolicyAction memory act = policy.action(poolId, 1e18, true, 1e18);
        assertEq(act.fee, 12000 + 500);
    }

    // ── Circuit breaker + dead-band (P3) ────────────────────────────────

    function test_Action_LatchesPauseAboveHaltThreshold() public {
        PolicyAction memory act = policy.action(poolId, 0.96e18, true, 0);
        assertTrue(act.pauseSwaps, "risk >= haltThreshold should pause swaps");
        assertTrue(policy.pausedSwaps(poolId));
    }

    function test_Action_KeepsPausedInsideDeadBand() public {
        // Latch at 0.96e18.
        policy.action(poolId, 0.96e18, true, 0);

        // Still paused anywhere above haltThreshold - unpauseBand (0.85e18).
        PolicyAction memory act = policy.action(poolId, 0.90e18, true, 0);
        assertTrue(act.pauseSwaps, "0.90e18 is inside the dead-band - must stay paused");

        act = policy.action(poolId, 0.86e18, true, 0);
        assertTrue(act.pauseSwaps, "0.86e18 is still above the unpause line");
    }

    function test_Action_UnpausesOnlyBelowDeadBand() public {
        policy.action(poolId, 0.96e18, true, 0); // latch
        PolicyAction memory act = policy.action(poolId, 0.85e18, true, 0); // exactly at unpause line
        assertFalse(act.pauseSwaps, "risk <= haltThreshold - unpauseBand must resume swaps");
        assertFalse(policy.pausedSwaps(poolId));
    }

    function test_Action_NoPauseAtOrdinaryRisk() public {
        PolicyAction memory act = policy.action(poolId, 0.9e18, true, 0);
        assertFalse(act.pauseSwaps, "0.9e18 is below haltThreshold (0.95e18)");
    }

    function test_SetHaltParams_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        policy.setHaltParams(0.9e18, 0.05e18);
    }

    function test_SetHaltParams_RevertsIfBandTooWide() public {
        vm.expectRevert("invalid halt params");
        policy.setHaltParams(0.05e18, 0.1e18); // band >= threshold
    }

    // ── Config access control (legacy) ──────────────────────────────────

    function test_SetThresholds_RevertsIfNotOrdered() public {
        vm.expectRevert("invalid thresholds");
        policy.setThresholds(0.5e18, 0.4e18, 0.6e18, 0.8e18); // tier1 > tier2, invalid
    }

    function test_SetThresholds_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        policy.setThresholds(0.1e18, 0.2e18, 0.3e18, 0.4e18);
    }

    function test_SetFees_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        policy.setFees(1000, 2000, 3000, 4000, 5000);
    }
}
