// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/FeeCalculator.sol";

contract FeeCalculatorTest is Test {

    FeeCalculator feeCalculator;

    function setUp() public {
        feeCalculator = new FeeCalculator();
    }

    // ---------------------------
    // BASIC BEHAVIOR TESTS
    // ---------------------------

    function test_LowRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(
            10 ether,
            20
        );

        console2.log("LOW fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    function test_NormalRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(
            150 ether,
            60
        );

        console2.log("MEDIUM fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    function test_HighRiskTrade() public view {
        uint24 fee = feeCalculator.calculateFee(
            500 ether,
            120
        );

        console2.log("HIGH fee", fee);

        assertGt(fee, 0);
        assertLe(fee, 10000);
    }

    // ---------------------------
    // CRITICAL: ORDERING TEST
    // ---------------------------

    function test_FeeOrdering() public view {

        uint24 low = feeCalculator.calculateFee(10 ether, 20000);
        uint24 medium = feeCalculator.calculateFee(150 ether, 60000);
        uint24 high = feeCalculator.calculateFee(500 ether, 120000);

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

    function test_FeeBounds() public view {

        uint24 fee = feeCalculator.calculateFee(
            1 ether,
            1
        );

        assertGe(fee, 500);   // MIN_FEE
        assertLe(fee, 10000); // MAX_FEE
    }

    // ---------------------------
    // STRESS TEST
    // ---------------------------

    function test_Fuzz_FeeStability(uint256 size, uint256 vol) public view {

        size = bound(size, 1 ether, 1000 ether);
        vol  = bound(vol, 1, 200);

        uint24 fee = feeCalculator.calculateFee(size, vol);

        assertGe(fee, 500);
        assertLe(fee, 10000);
    }
}