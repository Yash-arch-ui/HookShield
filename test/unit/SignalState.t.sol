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
        vm.prank(address(0xBEEF));  // NOT authorized
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
    function test_SetAuthorizedWriter_OnlyOwner() public {
        vm.prank(address(0xBEEF));  // not the owner (owner = whoever deployed, i.e. address(this))
        vm.expectRevert();  // Ownable's custom error — exact match not required unless you want it precise
        signalState.setAuthorizedWriter(address(0xCAFE), true);
    }
    function test_SetAuthorizedWriter_OwnerCanAuthorize() public {
        signalState.setAuthorizedWriter(address(0xCAFE), true);
        assertTrue(signalState.authorizedWriters(address(0xCAFE)));
    }
}