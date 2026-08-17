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

    function test_Action_ReturnsTier0BelowFirstThreshold() public {
        PolicyAction memory act = policy.action(poolId, 0.1e18); // below 0.20e18
        assertEq(act.fee, 3000);
        assertEq(act.tier, 0);
    }

    function test_Action_ReturnsTier4AboveLastThreshold() public {
        PolicyAction memory act = policy.action(poolId, 0.9e18); // above 0.80e18
        assertEq(act.fee, 12000);
        assertEq(act.tier, 4);
    }

    function test_Action_BoundaryValueAtExactThreshold() public {
        // riskE18 exactly equal to tier1Threshold (0.20e18) — check which side it falls on
        PolicyAction memory act = policy.action(poolId, 0.20e18);
        // your code uses `<`, so exactly 0.20e18 does NOT count as "< tier1Threshold"
        // meaning it falls into tier1, not tier0 — confirm this matches your intent
        assertEq(act.tier, 1);
    }

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