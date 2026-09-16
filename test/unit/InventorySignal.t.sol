// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {InventoryStorage} from "../../src/InventoryStorage.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {InventorySignal} from "../../src/signals/InventorySignal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract InventorySignalTest is Test {
    InventoryStorage invStorage;
    SignalState signalState;
    InventorySignal inventorySignal;
    PoolId poolId;

    function setUp() public {
        invStorage = new InventoryStorage();
        signalState = new SignalState();
        inventorySignal = new InventorySignal(address(invStorage), address(signalState));
        invStorage.setWriter(address(inventorySignal));
        signalState.setAuthorizedWriter(address(inventorySignal), true);

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Update_ZeroForOne_IncreasesNetFlow() public {
        inventorySignal.update(poolId, true); // zeroForOne
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(1e18), "netFlow should be +1e18 after one zeroForOne swap");
    }

    function test_Update_OneForZero_DecreasesNetFlow() public {
        inventorySignal.update(poolId, false); // oneForZero
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(-1e18), "netFlow should be -1e18 after one oneForZero swap");
    }

    function test_Update_PublishesSkewToSignalState() public {
        inventorySignal.update(poolId, true);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        // |1e18| / 10e18 * 1e18 = 0.1e18
        assertEq(snap.inventorySkew, 0.1e18, "skew should be 0.1e18 after one zeroForOne swap");
    }

    function test_Update_ComputeMatchesSignalState() public {
        inventorySignal.update(poolId, true);
        inventorySignal.update(poolId, true);
        uint256 skew = inventorySignal.compute(poolId);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.inventorySkew, skew, "SignalState skew should match compute()");
    }

    function test_Update_RepeatedSameDirectionApproachesMaxFlow() public {
        // FLOW_STEP = 1e18, MAX_FLOW = 10e18. After 10 swaps netFlow hits MAX_FLOW.
        for (uint256 i; i < 10; i++) {
            inventorySignal.update(poolId, true);
        }
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(10e18), "netFlow should saturate at MAX_FLOW");

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.inventorySkew, 1e18, "skew should saturate at 1e18");
    }

    function test_Update_SkewNeverExceedsMax() public {
        // Push past MAX_FLOW in one direction.
        for (uint256 i; i < 15; i++) {
            inventorySignal.update(poolId, true);
        }
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertLe(snap.inventorySkew, 1e18, "skew must never exceed 1e18");
    }

    function test_Update_OppositeDirectionDecreasesSkew() public {
        // Build up +3e18 netFlow.
        for (uint256 i; i < 3; i++) {
            inventorySignal.update(poolId, true);
        }
        SignalSnapshot memory peakSnap = signalState.getSnapshot(poolId);
        assertEq(peakSnap.inventorySkew, 3e17, "3 zeroForOne swaps -> skew 0.3e18");

        // One opposite swap.
        inventorySignal.update(poolId, false);
        SignalSnapshot memory afterSnap = signalState.getSnapshot(poolId);
        assertEq(afterSnap.inventorySkew, 2e17, "skew should drop to 0.2e18 after one counter-swap");
    }

    function test_Update_RevertsIfCalledByUnwiredInstance() public {
        InventorySignal rogueSignal = new InventorySignal(address(invStorage), address(signalState));
        vm.expectRevert();
        rogueSignal.update(poolId, true);
    }

    function test_Compute_ReturnsZeroOnFreshPool() public view {
        assertEq(inventorySignal.compute(poolId), 0, "compute on fresh pool should be 0");
    }
}
