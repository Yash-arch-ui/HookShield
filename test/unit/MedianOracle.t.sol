// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IOracle} from "../../src/oracle/IOracle.sol";
import {MedianOracle} from "../../src/oracle/MedianOracle.sol";

/// @dev Minimal mock IOracle: returns a fixed price, or reverts if told to.
contract MockOracle is IOracle {
    uint256 public price;
    bool public shouldRevert;
    bool public stale;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function setStale(bool _stale) external {
        stale = _stale;
    }

    function getPrice() external view override returns (uint256) {
        require(!shouldRevert, "mock oracle reverted");
        return price;
    }

    function isStale() external view override returns (bool) {
        return stale;
    }
}

contract MedianOracleTest is Test {
    MedianOracle medianOracle;

    function _deploy3(uint256 p1, uint256 p2, uint256 p3) internal returns (MockOracle o1, MockOracle o2, MockOracle o3) {
        o1 = new MockOracle(p1);
        o2 = new MockOracle(p2);
        o3 = new MockOracle(p3);
        address[] memory sources = new address[](3);
        sources[0] = address(o1);
        sources[1] = address(o2);
        sources[2] = address(o3);
        medianOracle = new MedianOracle(sources);
    }

    function _deploy2(uint256 p1, uint256 p2) internal returns (MockOracle o1, MockOracle o2) {
        o1 = new MockOracle(p1);
        o2 = new MockOracle(p2);
        address[] memory sources = new address[](2);
        sources[0] = address(o1);
        sources[1] = address(o2);
        medianOracle = new MedianOracle(sources);
    }

    // ── Odd-count median ───────────────────────────────────────────

    function test_3Sources_OddCountMedian() public {
        (MockOracle o1, MockOracle o2, MockOracle o3) = _deploy3(100e18, 300e18, 200e18);
        // Sorted: [100, 200, 300] -> median = 200
        assertEq(medianOracle.getPrice(), 200e18);
    }

    function test_3Sources_AlreadySorted() public {
        _deploy3(100e18, 200e18, 300e18);
        assertEq(medianOracle.getPrice(), 200e18);
    }

    function test_3Sources_AllSame() public {
        _deploy3(500e18, 500e18, 500e18);
        assertEq(medianOracle.getPrice(), 500e18);
    }

    // ── Even-count average of middle two ───────────────────────────

    function test_2Sources_EvenCountAverage() public {
        _deploy2(100e18, 300e18);
        // Sorted: [100, 300] -> average = 200
        assertEq(medianOracle.getPrice(), 200e18);
    }

    function test_2Sources_CloseValues() public {
        _deploy2(150e18, 250e18);
        assertEq(medianOracle.getPrice(), 200e18);
    }

    // ── Partial failure tolerance ──────────────────────────────────

    function test_OneSourceReverts_MedianFromRemaining() public {
        (MockOracle o1, MockOracle o2, MockOracle o3) = _deploy3(100e18, 300e18, 500e18);
        o2.setShouldRevert(true);
        // Only [100, 500] valid -> average = 300
        assertEq(medianOracle.getPrice(), 300e18);
    }

    function test_TwoSourcesRevert_InsufficientQuorum() public {
        (MockOracle o1, MockOracle o2, MockOracle o3) = _deploy3(100e18, 200e18, 300e18);
        o1.setShouldRevert(true);
        o3.setShouldRevert(true);
        // Only [200] valid -> < 2 required
        vm.expectRevert(MedianOracle.InsufficientValidSources.selector);
        medianOracle.getPrice();
    }

    // ── Constructor validation ─────────────────────────────────────

    function test_Constructor_RevertsIfFewerThan2Sources() public {
        address[] memory sources = new address[](1);
        sources[0] = address(new MockOracle(100e18));
        vm.expectRevert("need >= 2 sources");
        new MedianOracle(sources);
    }

    function test_Constructor_RevertsIfZeroSource() public {
        address[] memory sources = new address[](2);
        sources[0] = address(new MockOracle(100e18));
        sources[1] = address(0);
        vm.expectRevert("zero source");
        new MedianOracle(sources);
    }

    // ── isStale ────────────────────────────────────────────────────

    function test_IsStale_ReturnsTrueWhenFewerThan2SourcesFresh() public {
        (MockOracle o1, MockOracle o2, MockOracle o3) = _deploy3(100e18, 200e18, 300e18);
        assertFalse(medianOracle.isStale());
        o1.setStale(true);
        o2.setStale(true);
        // Only 1 fresh source -> stale
        assertTrue(medianOracle.isStale());
    }

    function test_IsStale_ReturnsFalseWhen2SourcesFresh() public {
        (MockOracle o1, MockOracle o2, MockOracle o3) = _deploy3(100e18, 200e18, 300e18);
        o1.setStale(true);
        // 2 fresh sources -> not stale
        assertFalse(medianOracle.isStale());
    }

    // ── sourceCount ────────────────────────────────────────────────

    function test_SourceCount() public {
        _deploy3(100e18, 200e18, 300e18);
        assertEq(medianOracle.sourceCount(), 3);
    }
}
