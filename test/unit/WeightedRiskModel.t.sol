// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SignalState} from "../../src/signals/SignalState.sol";
import {WeightedRiskModel} from "../../src/risk/WeightedRiskModel.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract WeightedRiskModelTest is Test {
    SignalState signalState;
    WeightedRiskModel riskModel;
    PoolId poolId;

    function setUp() public {
        signalState = new SignalState();

        riskModel = new WeightedRiskModel(
            address(signalState),
            1e18, // volatilityWeight
            0, // inventorySkewWeight
            0, // oracleDivergenceWeight
            0 // whaleScoreWeight
        );

        // authorize this test contract to write signals directly (simulating VolatilitySignal)
        signalState.setAuthorizedWriter(address(this), true);

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Constructor_RevertsIfWeightsDontSumToScale() public {
        vm.expectRevert("weights must sum to 1e18");
        new WeightedRiskModel(address(signalState), 0.5e18, 0.3e18, 0, 0); // sums to 0.8e18, not 1e18
    }

    function test_Risk_ReturnsZeroWhenNoSignalEverWritten() public {
        // P0 semantics change: a field that was never written (validUntil == 0)
        // is NOT stale — it simply has its default value of 0 (no observed risk).
        // So an untouched pool scores a clean zero, not the stale fallback.
        // liquidity = 0 also disables the P2 pressure term for a pure signal read.
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0);
        assertFalse(riskModel.isStale(poolId));
    }

    function test_Risk_ReturnsMaxFallbackWhenStale() public {
        signalState.setVolatility(poolId, 0.8e18);

        vm.warp(block.timestamp + 61 minutes); // past the 5-minute staleness window

        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, riskModel.STALE_FALLBACK_RISK());
        assertEq(risk, 1e18); // P0: escalate to max risk -> max fee, not the old 0.5e18
        assertTrue(riskModel.isStale(poolId));
    }

    function test_Risk_ReflectsVolatilityWeight() public {
        signalState.setVolatility(poolId, 0.8e18);

        uint256 risk = riskModel.risk(poolId, 1e18, 0);

        // weight is 1e18 (100%), so risk should equal volatility exactly
        assertEq(risk, 0.8e18);
    }

    function test_Risk_AppliesSizeLiquidityPressure() public {
        // Signals all zero / never written (not stale) -> base risk 0.
        // P2: a trade equal in size to the pool's active liquidity produces
        // rawPressure = 1e18, clamped to MAX_PRESSURE (0.3e18).
        uint256 risk = riskModel.risk(poolId, 1e18, 1e18);
        assertEq(risk, riskModel.MAX_PRESSURE());
        assertEq(risk, 0.3e18);
    }

    function test_Risk_PressureScalesWithTradeSize() public {
        // Quarter-size trade against the same liquidity -> 0.25e18 pressure,
        // still below the 0.3e18 cap so it scales linearly.
        uint256 risk = riskModel.risk(poolId, 25e16, 1e18);
        assertEq(risk, 0.25e18);
    }

    function test_Risk_NoPressureWhenLiquidityZero() public {
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0);
    }

    function test_SetWeights_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        riskModel.setWeights(0.5e18, 0.5e18, 0, 0);
    }

    function test_SetWeights_RevertsIfDontSumToScale() public {
        vm.expectRevert("weights must sum to 1e18");
        riskModel.setWeights(0.5e18, 0.3e18, 0, 0);
    }

    function test_SetWeights_SucceedsAndAffectsRisk() public {
        riskModel.setWeights(0.5e18, 0.5e18, 0, 0);
        signalState.setVolatility(poolId, 0.8e18);
        // inventorySkew stays 0 since we never write it

        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        // only volatility contributes now, at 50% weight: 0.8e18 * 0.5e18 / 1e18 = 0.4e18
        assertEq(risk, 0.4e18);
    }

    // ── H-2: reporter scores wired into risk ────────────────────────────

    function test_H2_ReporterScore_IncreasesRisk() public {
        // Core weights are 100% volatility, all core signals 0 → base risk 0.
        // A fresh reporter score at 1.0 with reporterWeight 0.3e18 → 0.3e18.
        signalState.setJitScore(poolId, 1e18);
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0.3e18, "fresh reporter score must add reporterWeight * score");
    }

    function test_H2_ReporterTerm_CappedAtReporterWeight() public {
        // Five reporter scores all at SCALE → max is SCALE → term = reporterWeight.
        signalState.setJitScore(poolId, 1e18);
        signalState.setSandwichScore(poolId, 1e18);
        signalState.setFlashloanScore(poolId, 1e18);
        signalState.setToxicFlowScore(poolId, 1e18);
        signalState.setMevScore(poolId, 1e18);

        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, riskModel.DEFAULT_REPORTER_WEIGHT(), "five max scores must cap at reporterWeight");
        assertEq(risk, 0.3e18);
    }

    function test_H2_ReporterTerm_UsesMaxNotSum() public {
        // jit 0.6e18 and sandwich 0.9e18 → max 0.9e18 → term 0.9 * 0.3 = 0.27e18.
        // (Sum would be 0.45e18 — the model deliberately takes the worst threat.)
        signalState.setJitScore(poolId, 0.6e18);
        signalState.setSandwichScore(poolId, 0.9e18);
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0.27e18, "reporter term must use max fresh score, not sum");
    }

    function test_H2_StaleReporterScore_ContributesNothing() public {
        // H-3 asymmetry: expired reporter → contributes 0 (NOT SCALE).
        signalState.setJitScore(poolId, 1e18);
        vm.warp(block.timestamp + 61 minutes);

        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0, "expired reporter must contribute 0, not escalate");
        assertFalse(riskModel.isStale(poolId), "reporter expiry must not mark the pool stale");
    }

    function test_H2_FreshReporterBeatsExpiredOne() public {
        // MEV report fresh at 0.2e18, JIT expired at 1e18 → only MEV counts.
        // Absolute warps: identical `block.timestamp + X` expressions get CSE'd
        // by the via-IR optimizer across vm.warp calls (see SignalState.t.sol).
        signalState.setJitScore(poolId, 1e18); // t=1, deadline 301
        vm.warp(181); // t+3m
        signalState.setMevScore(poolId, 0.2e18); // fresh at 181, deadline 481
        vm.warp(361); // t+6m: JIT expired (301), MEV fresh (481)

        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, (0.2e18 * 0.3e18) / 1e18, "only the fresh reporter score may contribute");
        assertEq(risk, 0.06e18);
    }

    function test_H2_NeverWrittenReporter_ContributesNothing() public {
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0, "no reports ever written = no reporter contribution");
    }

    function test_H2_ReporterWeightZero_DisablesTerm() public {
        riskModel.setReporterWeight(0);
        signalState.setJitScore(poolId, 1e18);
        uint256 risk = riskModel.risk(poolId, 1e18, 0);
        assertEq(risk, 0, "reporterWeight = 0 must disable the reporter term");
    }

    function test_H2_SetReporterWeight_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        riskModel.setReporterWeight(0.5e18);
    }

    function test_H2_SetReporterWeight_RevertsAboveScale() public {
        vm.expectRevert("reporter weight out of bounds");
        riskModel.setReporterWeight(1e18 + 1);
    }

    function test_H2_ReporterTerm_StacksWithCoreAndPressure() public {
        // vol 0.5e18 * 1.0 weight = 0.5e18, reporter jit 1e18 → +0.3e18,
        // pressure trade==liq → +0.3e18 → sum 1.1e18 → clamped to 1e18.
        signalState.setVolatility(poolId, 0.5e18);
        signalState.setJitScore(poolId, 1e18);
        uint256 risk = riskModel.risk(poolId, 1e18, 1e18);
        assertEq(risk, 1e18, "combined terms must clamp at SCALE");
    }

    function test_H2_CoreStale_StillShortCircuitsToScale() public {
        // Even with fresh reporters, an expired CORE signal → SCALE.
        signalState.setVolatility(poolId, 0.5e18);
        signalState.setJitScore(poolId, 1e18); // fresh
        vm.warp(block.timestamp + 61 minutes);
        assertEq(riskModel.risk(poolId, 1e18, 0), 1e18, "stale core must win over fresh reporters");
    }
}
