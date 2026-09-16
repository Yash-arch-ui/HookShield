// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {CompositeOracle} from "../../src/oracle/CompositeOracle.sol";

/// @dev Minimal mock IOracle for CompositeOracle tests.
contract MockOracleComp is IOracle {
    uint256 public price;
    bool public shouldRevert;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function getPrice() external view override returns (uint256) {
        require(!shouldRevert, "mock oracle reverted");
        return price;
    }

    function isStale() external view override returns (bool) {
        return false;
    }
}

contract CompositeOracleTest is Test {
    CompositeOracle compositeOracle;
    MockOracleComp o1;
    MockOracleComp o2;
    MockOracleComp o3;

    function _deploy(CompositeOracle.Strategy strategy, uint256 p1, uint256 p2, uint256 p3) internal {
        o1 = new MockOracleComp(p1);
        o2 = new MockOracleComp(p2);
        o3 = new MockOracleComp(p3);
        address[] memory sources = new address[](3);
        sources[0] = address(o1);
        sources[1] = address(o2);
        sources[2] = address(o3);
        compositeOracle = new CompositeOracle(sources, strategy);
    }

    // ── Median strategy ────────────────────────────────────────────

    function test_Median_3Sources() public {
        _deploy(CompositeOracle.Strategy.Median, 100e18, 300e18, 200e18);
        assertEq(compositeOracle.getPrice(), 200e18);
    }

    // ── Average strategy ───────────────────────────────────────────

    function test_Average_3Sources() public {
        _deploy(CompositeOracle.Strategy.Average, 100e18, 200e18, 300e18);
        // (100 + 200 + 300) / 3 = 200
        assertEq(compositeOracle.getPrice(), 200e18);
    }

    function test_Average_Uneven() public {
        _deploy(CompositeOracle.Strategy.Average, 100e18, 150e18, 200e18);
        // (100 + 150 + 200) / 3 = 150
        assertEq(compositeOracle.getPrice(), 150e18);
    }

    // ── Min strategy ───────────────────────────────────────────────

    function test_Min_3Sources() public {
        _deploy(CompositeOracle.Strategy.Min, 100e18, 300e18, 200e18);
        assertEq(compositeOracle.getPrice(), 100e18);
    }

    // ── Max strategy ───────────────────────────────────────────────

    function test_Max_3Sources() public {
        _deploy(CompositeOracle.Strategy.Max, 100e18, 300e18, 200e18);
        assertEq(compositeOracle.getPrice(), 300e18);
    }

    // ── Partial failure ────────────────────────────────────────────

    function test_Median_OneSourceReverts() public {
        _deploy(CompositeOracle.Strategy.Median, 100e18, 300e18, 500e18);
        o2.setShouldRevert(true);
        // Valid: [100, 500] -> median average = 300
        assertEq(compositeOracle.getPrice(), 300e18);
    }

    function test_Average_TwoSourcesRevert() public {
        _deploy(CompositeOracle.Strategy.Average, 100e18, 200e18, 300e18);
        o1.setShouldRevert(true);
        o3.setShouldRevert(true);
        // Only [200] valid -> 1 < minQuorum(2) -> revert
        vm.expectRevert(CompositeOracle.InsufficientValidSources.selector);
        compositeOracle.getPrice();
    }

    function test_Min_OneSourceReverts() public {
        _deploy(CompositeOracle.Strategy.Min, 100e18, 300e18, 500e18);
        o3.setShouldRevert(true);
        // Valid: [100, 300] -> min = 100
        assertEq(compositeOracle.getPrice(), 100e18);
    }

    function test_Max_OneSourceReverts() public {
        _deploy(CompositeOracle.Strategy.Max, 100e18, 300e18, 500e18);
        o1.setShouldRevert(true);
        // Valid: [300, 500] -> max = 500
        assertEq(compositeOracle.getPrice(), 500e18);
    }

    // ── Constructor validation ─────────────────────────────────────

    function test_Constructor_RevertsIfFewerThan2Sources() public {
        address[] memory sources = new address[](1);
        sources[0] = address(new MockOracleComp(100e18));
        vm.expectRevert("need >= 2 sources");
        new CompositeOracle(sources, CompositeOracle.Strategy.Median);
    }

    function test_Constructor_RevertsIfZeroSource() public {
        address[] memory sources = new address[](2);
        sources[0] = address(new MockOracleComp(100e18));
        sources[1] = address(0);
        vm.expectRevert("zero source");
        new CompositeOracle(sources, CompositeOracle.Strategy.Median);
    }

    // ── Strategy accessor ──────────────────────────────────────────

    function test_Strategy_Accessor() public {
        _deploy(CompositeOracle.Strategy.Average, 100e18, 200e18, 300e18);
        assertEq(uint256(compositeOracle.strategy()), uint256(CompositeOracle.Strategy.Average));
    }

    function test_SourceCount() public {
        _deploy(CompositeOracle.Strategy.Median, 100e18, 200e18, 300e18);
        assertEq(compositeOracle.sourceCount(), 3);
    }

    // ── Min quorum ─────────────────────────────────────────────────

    function test_MinQuorum_DefaultsToHalf() public {
        // 3 sources -> quorum = max(3/2, 2) = 2
        _deploy(CompositeOracle.Strategy.Median, 100e18, 200e18, 300e18);
        assertEq(compositeOracle.minQuorum(), 2);
    }
}
