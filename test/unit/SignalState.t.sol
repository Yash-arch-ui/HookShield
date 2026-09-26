// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract SignalStateTest is Test {
    SignalState signalState;
    PoolId poolId;

    function setUp() public {
        signalState = new SignalState();
        poolId = PoolId.wrap(bytes32(uint256(1)));

        // authorize this test contract as a writer, so most tests can just call setVolatility directly
        signalState.setAuthorizedWriter(address(this), true);
    }

    function testSetVolatilityRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF)); // NOT authorized
        vm.expectRevert("not authorized");
        signalState.setVolatility(poolId, 0.5e18);
    }

    function testSetVolatilitySucceedsWhenAuthorized() public {
        signalState.setVolatility(poolId, 0.5e18);

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.volatility, 0.5e18);
    }

    function testSetVolatilityRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setVolatility(poolId, 1e18 + 1);
    }

    function testIsStaleFalseImmediatelyAfterWrite() public {
        signalState.setVolatility(poolId, 0.5e18);
        assertFalse(signalState.isStale(poolId));
    }

    function test_IsStale_TrueAfterWarpingPastStalenessWindow() public {
        signalState.setVolatility(poolId, 0.5e18);
        vm.warp(block.timestamp + 61 minutes);
        assertTrue(signalState.isStale(poolId));
    }

    // ── P0: per-field staleness + configurable window ─────────────────────

    function test_FieldNeverWritten_IsNotStale() public {
        // Nothing has ever been written: validUntil == 0 means "no observation
        // yet", not "expired observation". The pool is NOT stale.
        assertFalse(signalState.isStale(poolId));
        assertFalse(signalState.isVolatilityStale(poolId));
        assertFalse(signalState.isInventoryStale(poolId));
        assertFalse(signalState.isOracleStale(poolId));
        assertFalse(signalState.isWhaleStale(poolId));
    }

    function test_Stale_IsTrueOnceAnyCoreFieldExpires() public {
        signalState.setVolatility(poolId, 0.5e18);
        signalState.setInventorySkew(poolId, 0.5e18);

        vm.warp(block.timestamp + 6 minutes); // past 5-minute default window

        assertTrue(signalState.isVolatilityStale(poolId));
        assertTrue(signalState.isInventoryStale(poolId));
        assertTrue(signalState.isStale(poolId));
        // Fields never written stay "not stale".
        assertFalse(signalState.isOracleStale(poolId));
        assertFalse(signalState.isWhaleStale(poolId));
    }

    function test_PerField_SurvivesIndependentRefresh() public {
        signalState.setVolatility(poolId, 0.5e18);
        signalState.setInventorySkew(poolId, 0.5e18);

        vm.warp(block.timestamp + 4 minutes);
        // Refresh only volatility — inventory keeps its original deadline.
        signalState.setVolatility(poolId, 0.6e18);

        vm.warp(block.timestamp + 2 minutes); // t+6: inventory (written at t+4? no — at t0) expired
        // volatility written at t+4, window 5m -> valid until t+9. now t+6: fresh.
        assertFalse(signalState.isVolatilityStale(poolId));
        assertTrue(signalState.isInventoryStale(poolId));
        assertTrue(signalState.isStale(poolId), "stale inventory alone must mark the pool stale");
    }

    function test_SetStalenessWindow_AffectsSubsequentWrites() public {
        signalState.setStalenessWindow(30 seconds);
        signalState.setVolatility(poolId, 0.5e18);

        vm.warp(block.timestamp + 31 seconds);
        assertTrue(signalState.isVolatilityStale(poolId), "31s > 30s window");
    }

    function test_SetStalenessWindow_RevertsOutOfBounds() public {
        vm.expectRevert("window out of bounds");
        signalState.setStalenessWindow(29 seconds);

        vm.expectRevert("window out of bounds");
        signalState.setStalenessWindow(61 minutes);
    }

    function test_SetStalenessWindow_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        signalState.setStalenessWindow(1 minutes);
    }

    function test_DefaultStalenessWindow_IsFiveMinutes() public view {
        assertEq(signalState.DEFAULT_STALENESS_WINDOW(), 5 minutes);
        assertEq(signalState.stalenessWindow(), 5 minutes);
    }

    function test_SetAuthorizedWriter_OnlyOwner() public {
        vm.prank(address(0xBEEF)); // not the owner (owner = whoever deployed, i.e. address(this))
        vm.expectRevert(); // Ownable's custom error — exact match not required unless you want it precise
        signalState.setAuthorizedWriter(address(0xCAFE), true);
    }

    function test_SetAuthorizedWriter_OwnerCanAuthorize() public {
        signalState.setAuthorizedWriter(address(0xCAFE), true);
        assertTrue(signalState.authorizedWriters(address(0xCAFE)));
    }

    // ── JIT SCORE ────────────────────────────────────────────────────────

    function testSetJitScoreRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        signalState.setJitScore(poolId, 0.5e18);
    }

    function testSetJitScoreSucceedsWhenAuthorized() public {
        signalState.setJitScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.jitScore, 0.5e18);
    }

    function testSetJitScoreRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setJitScore(poolId, 1e18 + 1);
    }

    // ── SANDWICH SCORE ───────────────────────────────────────────────────

    function testSetSandwichScoreRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        signalState.setSandwichScore(poolId, 0.5e18);
    }

    function testSetSandwichScoreSucceedsWhenAuthorized() public {
        signalState.setSandwichScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.sandwichScore, 0.5e18);
    }

    function testSetSandwichScoreRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setSandwichScore(poolId, 1e18 + 1);
    }

    // ── FLASHLOAN SCORE ──────────────────────────────────────────────────

    function testSetFlashloanScoreRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        signalState.setFlashloanScore(poolId, 0.5e18);
    }

    function testSetFlashloanScoreSucceedsWhenAuthorized() public {
        signalState.setFlashloanScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.flashloanScore, 0.5e18);
    }

    function testSetFlashloanScoreRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setFlashloanScore(poolId, 1e18 + 1);
    }

    // ── TOXIC FLOW SCORE ─────────────────────────────────────────────────

    function testSetToxicFlowScoreRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        signalState.setToxicFlowScore(poolId, 0.5e18);
    }

    function testSetToxicFlowScoreSucceedsWhenAuthorized() public {
        signalState.setToxicFlowScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.toxicFlowScore, 0.5e18);
    }

    function testSetToxicFlowScoreRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setToxicFlowScore(poolId, 1e18 + 1);
    }

    // ── MEV SCORE ────────────────────────────────────────────────────────

    function testSetMevScoreRevertsIfNotAuthorized() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert("not authorized");
        signalState.setMevScore(poolId, 0.5e18);
    }

    function testSetMevScoreSucceedsWhenAuthorized() public {
        signalState.setMevScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.mevScore, 0.5e18);
    }

    function testSetMevScoreRevertsAboveOneE18() public {
        vm.expectRevert("out of bounds");
        signalState.setMevScore(poolId, 1e18 + 1);
    }

    // ── H-3: per-field reporter staleness ───────────────────────────────

    function test_H3_ReportersHaveIndependentDeadlines() public {
        // NOTE: absolute warps — `vm.warp(block.timestamp + X)` repeated with an
        // identical expression gets CSE'd by the via-IR optimizer (the second
        // call receives the pre-warp value), so absolute timestamps are used.
        signalState.setJitScore(poolId, 0.5e18); // t=1, valid until t=301
        vm.warp(181); // t+3m: sandwich written, valid until t=481
        signalState.setSandwichScore(poolId, 0.7e18);

        vm.warp(361); // t+6m: JIT (deadline 301) expired, sandwich (481) fresh
        assertTrue(signalState.isJitStale(poolId), "JIT must be stale at t+6");
        assertFalse(signalState.isSandwichStale(poolId), "sandwich (written t+3) must still be fresh at t+6");
    }

    function test_H3_ReporterExpiry_DoesNotMarkPoolStale() public {
        // Reporter staleness must NOT feed the pool-level isStale() gate —
        // that gate escalates risk to SCALE and the hook treats it specially.
        // Only core signals gate staleness.
        signalState.setJitScore(poolId, 0.5e18);
        vm.warp(block.timestamp + 61 minutes);

        assertTrue(signalState.isJitStale(poolId), "reporter field itself is stale");
        assertFalse(signalState.isStale(poolId), "pool-level staleness must stay core-only");
    }

    function test_H3_AllReporters_FreshAfterWrite() public {
        signalState.setJitScore(poolId, 0.5e18);
        signalState.setSandwichScore(poolId, 0.5e18);
        signalState.setFlashloanScore(poolId, 0.5e18);
        signalState.setToxicFlowScore(poolId, 0.5e18);
        signalState.setMevScore(poolId, 0.5e18);

        assertFalse(signalState.isJitStale(poolId));
        assertFalse(signalState.isSandwichStale(poolId));
        assertFalse(signalState.isFlashloanStale(poolId));
        assertFalse(signalState.isToxicFlowStale(poolId));
        assertFalse(signalState.isMevStale(poolId));
    }

    function test_H3_NeverWrittenReporter_NotStale() public view {
        assertFalse(signalState.isJitStale(poolId));
        assertFalse(signalState.isSandwichStale(poolId));
        assertFalse(signalState.isFlashloanStale(poolId));
        assertFalse(signalState.isToxicFlowStale(poolId));
        assertFalse(signalState.isMevStale(poolId));
    }

    function test_H3_ReporterSetter_AlsoRefreshesSharedDeadline() public {
        // Backwards compat: the shared validUntil/updatedAt must still be
        // written by reporter setters (readers that predate per-field deadlines).
        signalState.setJitScore(poolId, 0.5e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.validUntil, block.timestamp + signalState.stalenessWindow());
        assertEq(snap.updatedAt, block.timestamp);
        assertEq(snap.jitValidUntil, block.timestamp + signalState.stalenessWindow());
    }

    function test_H3_PerFieldStalenessWindow_AppliesToReporters() public {
        signalState.setStalenessWindow(30 seconds);
        signalState.setMevScore(poolId, 0.5e18);

        vm.warp(block.timestamp + 31 seconds);
        assertTrue(signalState.isMevStale(poolId), "30s window must apply to reporter fields too");
    }
}
