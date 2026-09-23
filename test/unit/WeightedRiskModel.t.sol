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
}
