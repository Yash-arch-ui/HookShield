// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract VolatilityStorageTest is Test {
    VolatilityStorage volStorage;
    PoolId poolId;

    function setUp() public {
        volStorage = new VolatilityStorage();
        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function testSetWriter() public {
        volStorage.setWriter(address(this));
        assertEq(volStorage.writer(), address(this));
    }

    function testSetWriteRevertsIfAlreadySet() public {
        volStorage.setWriter(address(this));
        vm.expectRevert("writer already set");
        volStorage.setWriter(address(this));
    }

    function testSetWriterRevertsIfZeroAddress() public {
        vm.expectRevert("zero writer");
        volStorage.setWriter(address(0));
    }

    function testSetStateRevertsIfNotWriter() public {
        volStorage.setWriter(address(this));
        vm.prank(address(0x1234));
        vm.expectRevert();
        volStorage.setState(
            poolId, VolatilityStorage.VolatilityState({lastSqrtPriceX96: 100, ewmaVolatility: 0, lastUpdateBlock: 1})
        );
    }

    function testSetStateSucceedsFromWriter() public {
        volStorage.setWriter(address(this));
        volStorage.setState(
            poolId, VolatilityStorage.VolatilityState({lastSqrtPriceX96: 100, ewmaVolatility: 0, lastUpdateBlock: 1})
        );
        VolatilityStorage.VolatilityState memory state = volStorage.getState(poolId);
        assertEq(state.lastSqrtPriceX96, 100);
        assertEq(state.ewmaVolatility, 0);
        assertEq(state.lastUpdateBlock, 1);
    }

    function isInitializedFalseBeforeAnyWrites() public {
        VolatilityStorage.VolatilityState memory state = volStorage.getState(poolId);
        assertEq(state.lastSqrtPriceX96, 0);
        assertEq(state.ewmaVolatility, 0);
        assertEq(state.lastUpdateBlock, 0);
    }
}
