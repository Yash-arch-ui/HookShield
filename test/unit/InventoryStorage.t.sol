// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {InventoryStorage} from "../../src/InventoryStorage.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract InventoryStorageTest is Test {
    InventoryStorage invStorage;
    PoolId poolId;

    function setUp() public {
        invStorage = new InventoryStorage();
        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function testSetWriter() public {
        invStorage.setWriter(address(this));
        assertEq(invStorage.writer(), address(this));
    }

    function testSetWriterRevertsIfAlreadySet() public {
        invStorage.setWriter(address(this));
        vm.expectRevert("writer already set");
        invStorage.setWriter(address(this));
    }

    function testSetWriterRevertsIfZeroAddress() public {
        vm.expectRevert("zero writer");
        invStorage.setWriter(address(0));
    }

    function testSetStateRevertsIfNotWriter() public {
        invStorage.setWriter(address(this));
        vm.prank(address(0x1234));
        vm.expectRevert();
        invStorage.setState(poolId, InventoryStorage.InventoryState({netFlow: 1e18, lastUpdateBlock: 1}));
    }

    function testSetStateSucceedsFromWriter() public {
        invStorage.setWriter(address(this));
        invStorage.setState(poolId, InventoryStorage.InventoryState({netFlow: 5e18, lastUpdateBlock: 7}));
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, 5e18);
        assertEq(state.lastUpdateBlock, 7);
    }

    function testGetStateReturnsDefaultsBeforeAnyWrites() public {
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, 0);
        assertEq(state.lastUpdateBlock, 0);
    }

    function testSetStateEmitsEvent() public {
        invStorage.setWriter(address(this));
        vm.expectEmit(true, false, false, true);
        emit InventoryStorage.InventoryUpdated(poolId, 3e18, 42);
        invStorage.setState(poolId, InventoryStorage.InventoryState({netFlow: 3e18, lastUpdateBlock: 42}));
    }
}
