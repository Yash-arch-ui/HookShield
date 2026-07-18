// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCalculator.sol";

contract FeeCalculatorTest is Test {
    FeeCalculator feeCalculator;
    uint256 constant PCT = 1_000; // 1% = 1_000 in this contract's volatility units
    function setUp() public {
        feeCalculator = new FeeCalculator();
    }

    // ---------------------------
    // BASIC BEHAVIOR TESTS
    // ---------------------------

    function test_LowRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(10 ether, 20*PCT);

        console2.log("LOW fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    function test_NormalRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(150 ether, 60*PCT);

        console2.log("MEDIUM fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    function test_HighRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(500 ether, 120*PCT);

        console2.log("HIGH fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    // ---------------------------
    // CRITICAL: ORDERING TEST
    // ---------------------------

    function test_FeeOrdering() public view {
        uint24 low = feeCalculator.calculateFee(10 ether, 20*PCT);
        uint24 medium = feeCalculator.calculateFee(150 ether, 60*PCT);
        uint24 high = feeCalculator.calculateFee(500 ether, 120*PCT);

        console2.log("LOW", low);
        console2.log("MEDIUM", medium);
        console2.log("HIGH", high);

        // STRICT monotonic increasing requirement
        assertLt(low, medium);
        assertLt(medium, high);
    }

    // ---------------------------
    // BOUNDARY TESTS
    // ---------------------------

    function test_FeeClampsToMax_WhenRiskIsExtreme() public view{
        uint24 fee = feeCalculator.calculateFee(1000 ether, 500*PCT);
        assertEq(fee, feeCalculator.MAX_FEE());  
    }
    function test_FeeClampsToMin_WhenRiskIsNegligible() public view {
        uint24 fee = feeCalculator.calculateFee(1,1);
        assertEq(fee, feeCalculator.BASE_FEE());
    }

    // ---------------------------
    // STRESS TEST
    // ---------------------------

    function test_Fuzz_FeeStability(uint256 size, uint256 vol) public view {
        size = bound(size, 1 ether, 1_000_000 ether);
        vol = bound(vol, 1, 500*PCT);

        uint24 fee = feeCalculator.calculateFee(size, vol);

        assertGe(fee, feeCalculator.BASE_FEE());
        assertLe(fee, feeCalculator.BASE_FEE());
    }
    function test_RevertsOnZeroTradeSize() public {
    vm.expectRevert(FeeCalculator.FeeCalculator__InvalidTradeSize.selector);
    feeCalculator.calculateFee(0, 60_000);
}

function test_RevertsOnVolatilityAboveMax() public {
    vm.expectRevert(FeeCalculator.FeeCalculator__InvalidVolatility.selector);
    feeCalculator.calculateFee(150 ether, 500_001);
}

function test_MaxVolatilityBoundaryAccepted() public view {
    // 500_000 itself should NOT revert
    feeCalculator.calculateFee(150 ether, 500_000);
}
}
