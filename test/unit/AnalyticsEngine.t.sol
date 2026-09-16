// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AnalyticsEngine} from "../../src/analytics/AnalyticsEngine.sol";

contract AnalyticsEngineTest is Test {
    AnalyticsEngine analytics;

    address hook = address(0xBEEF);
    address random = address(0xDEAD);
    bytes32 poolId1 = keccak256("pool1");
    bytes32 poolId2 = keccak256("pool2");

    function setUp() public {
        analytics = new AnalyticsEngine();
        analytics.setWriter(hook);
    }

    // ── setWriter ──────────────────────────────────────────────────

    function test_SetWriter_SetsCorrectly() public {
        assertEq(analytics.writer(), hook);
        assertTrue(analytics.writerLocked());
    }

    function test_SetWriter_RevertsIfAlreadyLocked() public {
        vm.expectRevert(AnalyticsEngine.WriterLocked.selector);
        analytics.setWriter(random);
    }

    function test_SetWriter_RevertsIfZeroAddress() public {
        AnalyticsEngine fresh = new AnalyticsEngine();
        vm.expectRevert(AnalyticsEngine.ZeroAddress.selector);
        fresh.setWriter(address(0));
    }

    // ── recordSwap ─────────────────────────────────────────────────

    function test_RecordSwap_OnlyWriter() public {
        vm.prank(random);
        vm.expectRevert(AnalyticsEngine.NotWriter.selector);
        analytics.recordSwap(poolId1, 100e18, 0.5e18, 3000, true);
    }

    function test_RecordSwap_IncrementsTotalSwaps() public {
        vm.prank(hook);
        analytics.recordSwap(poolId1, 100e18, 0.5e18, 3000, true);
        assertEq(analytics.totalSwaps(), 1);
    }

    function test_RecordSwap_AccumulatesTotals() public {
        vm.prank(hook);
        analytics.recordSwap(poolId1, 100e18, 0.5e18, 3000, true);
        vm.prank(hook);
        analytics.recordSwap(poolId2, 200e18, 0.8e18, 5000, false);

        assertEq(analytics.totalSwaps(), 2);
        assertEq(analytics.totalTradeSize(), 300e18);
        assertEq(analytics.totalRiskE18(), 1.3e18);
        assertEq(analytics.totalFeesCharged(), 8000);
    }

    // ── View helpers ───────────────────────────────────────────────

    function test_AvgRiskE18_ZeroSwaps() public view {
        assertEq(analytics.avgRiskE18(), 0);
    }

    function test_AvgRiskE18_AfterSwaps() public {
        vm.prank(hook);
        analytics.recordSwap(poolId1, 100e18, 0.6e18, 3000, true);
        vm.prank(hook);
        analytics.recordSwap(poolId2, 200e18, 0.4e18, 5000, false);
        // (0.6 + 0.4) / 2 = 0.5e18
        assertEq(analytics.avgRiskE18(), 0.5e18);
    }

    function test_AvgFeesCharged_ZeroSwaps() public view {
        assertEq(analytics.avgFeesCharged(), 0);
    }

    function test_AvgFeesCharged_AfterSwaps() public {
        vm.prank(hook);
        analytics.recordSwap(poolId1, 100e18, 0.5e18, 3000, true);
        vm.prank(hook);
        analytics.recordSwap(poolId2, 200e18, 0.5e18, 5000, false);
        // (3000 + 5000) / 2 = 4000
        assertEq(analytics.avgFeesCharged(), 4000);
    }

    // ── Events ─────────────────────────────────────────────────────

    function test_RecordSwap_EmitsEvent() public {
        vm.prank(hook);
        vm.expectEmit(true, true, false, true);
        emit AnalyticsEngine.SwapRecorded(0, poolId1, 100e18, 0.5e18, 3000, true);
        analytics.recordSwap(poolId1, 100e18, 0.5e18, 3000, true);
    }
}
