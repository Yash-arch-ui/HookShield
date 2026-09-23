// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {Volatility} from "../../src/libraries/Volatility.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";

contract VolatilityFuzzTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant ALPHA = 0.1e18;
    uint256 internal constant ONE_MINUS_ALPHA = SCALE - ALPHA;
    uint256 internal constant ALPHA_FAST = 0.3e18;
    uint256 internal constant MAX_OBSERVATION_RETURN = 0.05e18;
    uint256 internal constant MAX_EWMA_INPUT = type(uint256).max / SCALE;

    function testFuzz_CalculateReturnMatchesFormula(uint160 oldPrice, uint160 newPrice) public pure {
        vm.assume(oldPrice != 0);
        uint256 oldP = uint256(oldPrice);
        uint256 newP = uint256(newPrice);
        uint256 diff = newP > oldP ? newP - oldP : oldP - newP;
        assertEq(Volatility.calculateReturn(oldPrice, newPrice), (diff * SCALE) / oldP);
    }

    function testFuzz_CalculateReturnIsNormalizedByOldPrice(uint160 oldPrice, uint160 newPrice) public pure {
        vm.assume(oldPrice != 0 && newPrice != 0);
        if (newPrice > oldPrice) {
            assertGe(Volatility.calculateReturn(oldPrice, newPrice), Volatility.calculateReturn(newPrice, oldPrice));
        } else if (newPrice < oldPrice) {
            assertLe(Volatility.calculateReturn(oldPrice, newPrice), Volatility.calculateReturn(newPrice, oldPrice));
        }
    }

    function testFuzz_CalculateReturnZeroForUnchangedPrice(uint160 price) public pure {
        vm.assume(price != 0);
        assertEq(Volatility.calculateReturn(price, price), 0);
    }

    function testFuzz_CalculateReturnBoundedByPriceRatio(uint160 oldPrice, uint160 newPrice) public pure {
        vm.assume(oldPrice != 0);
        vm.assume(uint256(newPrice) <= 2 * uint256(oldPrice));
        assertLe(Volatility.calculateReturn(oldPrice, newPrice), SCALE);
    }

    function testFuzz_CalculateReturnRevertsOnZeroOldPrice(uint160 newPrice) public {
        vm.expectRevert(Volatility.Volatility__ZeroOldPrice.selector);
        Volatility.calculateReturn(0, newPrice);
    }

    function testFuzz_UpdateEwmaFirstObservation(uint256 returnAmount) public pure {
        returnAmount = bound(returnAmount, 0, MAX_EWMA_INPUT);
        assertEq(Volatility.updateEwma(0, returnAmount), (ALPHA * returnAmount) / SCALE);
    }

    function testFuzz_UpdateEwmaIsConvexCombination(uint256 oldEwma, uint256 currentReturn) public pure {
        oldEwma = bound(oldEwma, 0, MAX_EWMA_INPUT);
        currentReturn = bound(currentReturn, 0, MAX_EWMA_INPUT);
        uint256 newEwma = Volatility.updateEwma(oldEwma, currentReturn);
        assertGe(newEwma, oldEwma < currentReturn ? oldEwma : currentReturn);
        assertLe(newEwma, oldEwma > currentReturn ? oldEwma : currentReturn);
    }

    function testFuzz_UpdateEwmaConvergesTowardsConstantReturn(uint256 returnAmount) public pure {
        returnAmount = bound(returnAmount, 0, 100e18); // 0% .. 10,000% volatility
        uint256 newEwma = Volatility.updateEwma(0, returnAmount);
        for (uint256 i = 0; i < 200; i++) {
            newEwma = Volatility.updateEwma(newEwma, returnAmount);
        }
        assertApproxEqAbs(newEwma, returnAmount, 1e15);
    }

    // ── P2: variance EWMA + momentum helpers ────────────────────────────

    function testFuzz_UpdateEwmaVarianceIsConvexCombination(uint256 oldVar, uint256 ret) public pure {
        oldVar = bound(oldVar, 0, SCALE);
        ret = bound(ret, 0, 10e18);
        uint256 newVar = Volatility.updateEwmaVariance(oldVar, ret);
        uint256 r2 = (ret * ret) / SCALE;
        uint256 expected = (ALPHA * r2 + ONE_MINUS_ALPHA * oldVar) / SCALE;
        assertEq(newVar, expected);
    }

    function testFuzz_VarianceToVolatilityIsStdDev(uint256 variance) public pure {
        variance = bound(variance, 0, SCALE);
        uint256 vol = Volatility.varianceToVolatility(variance);
        // sqrt(variance * SCALE): re-squaring must recover variance * SCALE (± rounding).
        assertApproxEqRel(vol * vol, variance * SCALE, 1e12); // 0.0001%
    }

    function test_SqrtBasics() public pure {
        assertEq(Volatility.sqrt(0), 0);
        assertEq(Volatility.sqrt(1), 1);
        assertEq(Volatility.sqrt(4), 2);
        assertEq(Volatility.sqrt(9), 3);
        assertEq(Volatility.sqrt(1e18 * 1e18), 1e18);
    }

    function testFuzz_SqrtMatchesFloatishBound(uint256 x) public pure {
        x = bound(x, 0, type(uint128).max);
        uint256 r = Volatility.sqrt(x);
        assertLe(r * r, x);
        if (r > 0) assertGt((r + 1) * (r + 1), x);
    }

    // ── compute() pipeline (P1 clamp + P2 dual-horizon) ─────────────────

    function testFuzz_ComputeInitializesWhenNoPriorPrice(uint160 newSqrtPriceX96) public view {
        VolatilityStorage.VolatilityState memory emptyState;
        VolatilityStorage.VolatilityState memory updatedState = Volatility.compute(emptyState, newSqrtPriceX96);
        assertEq(updatedState.lastSqrtPriceX96, newSqrtPriceX96);
        assertEq(updatedState.ewmaVolatility, 0);
        assertEq(updatedState.ewmaVolatilityFast, 0);
        assertEq(updatedState.ewmaVariance, 0);
        assertEq(updatedState.lastUpdateBlock, block.number);
    }

    function testFuzz_ComputeMatchesManualPipeline(
        uint160 oldPrice,
        uint160 newPrice,
        uint256 ewma,
        uint256 ewmaFast,
        uint256 variance
    ) public view {
        vm.assume(oldPrice != 0);
        vm.assume(uint256(newPrice) <= 2 * uint256(oldPrice));
        ewma = bound(ewma, 0, SCALE);
        ewmaFast = bound(ewmaFast, 0, SCALE);
        variance = bound(variance, 0, SCALE);

        VolatilityStorage.VolatilityState memory state = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: oldPrice,
            ewmaVolatility: ewma,
            ewmaVolatilityFast: ewmaFast,
            ewmaVariance: variance,
            lastUpdateBlock: block.number - 1
        });

        VolatilityStorage.VolatilityState memory updatedState = Volatility.compute(state, newPrice);

        // Manual replication of the library pipeline:
        uint256 ret = Volatility.calculateReturn(oldPrice, newPrice);
        if (ret > MAX_OBSERVATION_RETURN) ret = MAX_OBSERVATION_RETURN; // P1 clamp
        uint256 expVar = (ALPHA * ((ret * ret) / SCALE) + ONE_MINUS_ALPHA * variance) / SCALE;
        uint256 expSlow = Volatility.varianceToVolatility(expVar);
        uint256 expFast = (ALPHA_FAST * ret + (SCALE - ALPHA_FAST) * ewmaFast) / SCALE;
        uint256 expPublished = expFast > expSlow ? expFast : expSlow;
        if (expPublished > SCALE) expPublished = SCALE;

        assertEq(updatedState.lastSqrtPriceX96, newPrice);
        assertEq(updatedState.lastUpdateBlock, block.number);
        assertEq(updatedState.ewmaVariance, expVar);
        assertEq(updatedState.ewmaVolatilityFast, expFast);
        assertEq(updatedState.ewmaVolatility, expPublished);
    }

    function test_Compute_ClampsHugeObservationToFivePercent() public view {
        // 100% sqrt-price move (old -> 2*old) — raw return is 1e18, clamped to 0.05e18.
        uint160 oldPrice = 1e9;
        uint160 newPrice = 2e9;

        VolatilityStorage.VolatilityState memory state = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: oldPrice,
            ewmaVolatility: 0,
            ewmaVolatilityFast: 0,
            ewmaVariance: 0,
            lastUpdateBlock: block.number - 1
        });

        VolatilityStorage.VolatilityState memory updated = Volatility.compute(state, newPrice);

        // Fast EWMA from cold start: 0.3 * 0.05e18 = 0.015e18 (NOT 0.3 * 1e18).
        assertEq(updated.ewmaVolatilityFast, 0.015e18, "fast EWMA must see the clamped 5% return");
        // Variance channel: 0.1 * (0.05e18)^2 / 1e18 = 2.5e14.
        assertEq(updated.ewmaVariance, 2.5e14);
        // Published = max(slow, fast).
        uint256 slow = Volatility.varianceToVolatility(2.5e14);
        assertEq(updated.ewmaVolatility, slow > 0.015e18 ? slow : 0.015e18);
    }

    function test_Compute_MomentumBoostUsesFastWhenFastExceedsSlow() public view {
        // Slow/variance channel elevated from history; fast channel jumps on a new spike.
        VolatilityStorage.VolatilityState memory state = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: 1e9,
            ewmaVolatility: 0.01e18,
            ewmaVolatilityFast: 0.01e18,
            ewmaVariance: (0.01e18 * 0.01e18) / SCALE, // slow std ≈ 0.01e18
            lastUpdateBlock: block.number - 1
        });

        // +5% move (at the clamp).
        VolatilityStorage.VolatilityState memory updated = Volatility.compute(state, 1.05e9);

        // fast = 0.3*0.05 + 0.7*0.01 = 0.022e18
        uint256 expectedFast = (ALPHA_FAST * 0.05e18 + (SCALE - ALPHA_FAST) * 0.01e18) / SCALE;
        assertEq(updated.ewmaVolatilityFast, expectedFast);
        assertEq(updated.ewmaVolatility, expectedFast, "spike must publish the fast reading (momentum boost)");
    }

    function test_Compute_HoldsSlowWhenCalming() public view {
        // Elevated slow channel, calm (zero-return) observation: published must
        // hold the slow reading instead of flickering down to the fast one.
        VolatilityStorage.VolatilityState memory state = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: 1e9,
            ewmaVolatility: 0.04e18,
            ewmaVolatilityFast: 0.04e18,
            ewmaVariance: (0.04e18 * 0.04e18) / SCALE, // slow std ≈ 0.04e18
            lastUpdateBlock: block.number - 1
        });

        // No price change -> return 0.
        VolatilityStorage.VolatilityState memory updated = Volatility.compute(state, 1e9);

        uint256 expVar = (ONE_MINUS_ALPHA * ((0.04e18 * 0.04e18) / SCALE)) / SCALE;
        uint256 slow = Volatility.varianceToVolatility(expVar);
        assertEq(updated.ewmaVolatility, slow, "published must hold the slow channel while calm");
        // Fast channel decays toward 0 but keeps 70% of the old reading this step.
        uint256 expFast = ((SCALE - ALPHA_FAST) * 0.04e18) / SCALE;
        assertEq(updated.ewmaVolatilityFast, expFast, "fast channel decays on a zero return");
        assertLt(expFast, 0.04e18, "fast must be below the held slow reading here");
        assertGt(slow, expFast, "slow channel dominates while calm (anti-flicker)");
    }
}
