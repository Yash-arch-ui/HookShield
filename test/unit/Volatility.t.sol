// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {Volatility} from "../../src/libraries/Volatility.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";

contract VolatilityFuzzTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant ALPHA = 0.1e18;
    uint256 internal constant ONE_MINUS_ALPHA = SCALE - ALPHA;
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
    function testFuzz_ComputeInitializesWhenNoPriorPrice(uint160 newSqrtPriceX96) public view {
        VolatilityStorage.VolatilityState memory emptyState;
        VolatilityStorage.VolatilityState memory updatedState = Volatility.compute(emptyState, newSqrtPriceX96);
        assertEq(updatedState.lastSqrtPriceX96, newSqrtPriceX96);
        assertEq(updatedState.ewmaVolatility, 0);
        assertEq(updatedState.lastUpdateBlock, block.number);
    }
    function testFuzz_ComputeMatchesManualPipeline(uint160 oldPrice, uint160 newPrice, uint256 ewma) public view {
        vm.assume(oldPrice != 0);
        vm.assume(uint256(newPrice) <= 2 * uint256(oldPrice));
        ewma = bound(ewma, 0, MAX_EWMA_INPUT);

        VolatilityStorage.VolatilityState memory state = VolatilityStorage.VolatilityState({
            lastSqrtPriceX96: oldPrice,
            ewmaVolatility: ewma,
            lastUpdateBlock: block.number - 1
        });

        VolatilityStorage.VolatilityState memory updatedState = Volatility.compute(state, newPrice);

        assertEq(updatedState.lastSqrtPriceX96, newPrice);
        assertEq(updatedState.lastUpdateBlock, block.number);
        assertEq(
            updatedState.ewmaVolatility,
            Volatility.updateEwma(ewma, Volatility.calculateReturn(oldPrice, newPrice))
        );
    }
}
