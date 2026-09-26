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
        // P0: bind this test as the hook so direct update() calls are authorized.
        inventorySignal.setHook(address(this));

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Update_ZeroForOne_IncreasesNetFlow() public {
        inventorySignal.update(poolId, true, 1e18); // zeroForOne
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(1e18), "netFlow should be +1e18 after one zeroForOne swap");
    }

    function test_Update_OneForZero_DecreasesNetFlow() public {
        inventorySignal.update(poolId, false, 1e18); // oneForZero
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(-1e18), "netFlow should be -1e18 after one oneForZero swap");
    }

    function test_Update_PublishesSkewToSignalState() public {
        inventorySignal.update(poolId, true, 1e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        // |1e18| / 10e18 * 1e18 = 0.1e18
        assertEq(snap.inventorySkew, 0.1e18, "skew should be 0.1e18 after one zeroForOne swap");
    }

    function test_Update_ComputeMatchesSignalState() public {
        inventorySignal.update(poolId, true, 1e18);
        inventorySignal.update(poolId, true, 1e18);
        uint256 skew = inventorySignal.compute(poolId);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.inventorySkew, skew, "SignalState skew should match compute()");
    }

    function test_Update_RepeatedSameDirectionApproachesMaxFlow() public {
        // FLOW_STEP = 1e18, MAX_FLOW = 10e18. After 10 swaps netFlow hits MAX_FLOW.
        for (uint256 i; i < 10; i++) {
            inventorySignal.update(poolId, true, 1e18);
        }
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(10e18), "netFlow should saturate at MAX_FLOW");

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.inventorySkew, 1e18, "skew should saturate at 1e18");
    }

    function test_Update_SkewNeverExceedsMax() public {
        // Push past MAX_FLOW in one direction.
        for (uint256 i; i < 15; i++) {
            inventorySignal.update(poolId, true, 1e18);
        }
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertLe(snap.inventorySkew, 1e18, "skew must never exceed 1e18");
    }

    function test_Update_OppositeDirectionDecreasesSkew() public {
        // Build up +3e18 netFlow.
        for (uint256 i; i < 3; i++) {
            inventorySignal.update(poolId, true, 1e18);
        }
        SignalSnapshot memory peakSnap = signalState.getSnapshot(poolId);
        assertEq(peakSnap.inventorySkew, 3e17, "3 zeroForOne swaps -> skew 0.3e18");

        // One opposite swap.
        inventorySignal.update(poolId, false, 1e18);
        SignalSnapshot memory afterSnap = signalState.getSnapshot(poolId);
        assertEq(afterSnap.inventorySkew, 2e17, "skew should drop to 0.2e18 after one counter-swap");
    }

    function test_Update_RevertsIfCalledByUnwiredInstance() public {
        InventorySignal rogueSignal = new InventorySignal(address(invStorage), address(signalState));
        vm.expectRevert();
        rogueSignal.update(poolId, true, 1e18);
    }

    function test_Compute_ReturnsZeroOnFreshPool() public view {
        assertEq(inventorySignal.compute(poolId), 0, "compute on fresh pool should be 0");
    }

    // ── M-5: size-scaled inventory flow ──────────────────────────────────

    function test_Update_ReferenceSize_MatchesLegacyStep() public {
        // REFERENCE_SIZE == 1e18 must produce the legacy full FLOW_STEP.
        inventorySignal.update(poolId, true, 1e18);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(1e18), "reference-size trade must move flow by exactly FLOW_STEP");
    }

    function test_Update_HalfSize_ScalesFlowProportionally() public {
        inventorySignal.update(poolId, true, 0.5e18);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(0.5e18), "half-size trade must move flow by half a step");
    }

    function test_Update_TenthSize_ScalesFlowProportionally() public {
        inventorySignal.update(poolId, true, 0.1e18);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(0.1e18), "0.1e18 trade must move flow by 0.1e18");
    }

    function test_Update_TwentyReferenceTrades_SaturatesAtMaxFlow() public {
        // 20 trades of 2 * REFERENCE_SIZE: step would be 2e18 each but the
        // clamp at MAX_FLOW (10e18) kicks in at the 5th trade.
        for (uint256 i; i < 20; i++) {
            inventorySignal.update(poolId, true, 2e18);
        }
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(10e18), "netFlow must saturate at MAX_FLOW");
    }

    function test_Update_OversizedTrade_SaturatesInOneStep() public {
        // tradeSize >= 10 * REFERENCE_SIZE hits the overflow guard → MAX_FLOW.
        inventorySignal.update(poolId, true, 1000e18);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(10e18), "oversized trade must clamp to MAX_FLOW");

        // And a huge uint256 must not overflow the step computation.
        inventorySignal.update(poolId, true, type(uint256).max);
        state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(10e18), "uint256 max trade must clamp, not overflow");
    }

    function test_Update_OppositeLargeTrade_SwingsToNegativeMax() public {
        // A single counter-trade's step is itself capped at MAX_FLOW, so from
        // +5e18 one huge counter-swap swings by -10e18 to -5e18; a second one
        // reaches -MAX_FLOW and the clamp holds it there.
        inventorySignal.update(poolId, true, 5e18);
        inventorySignal.update(poolId, false, type(uint128).max);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(-5e18), "one max-step counter-trade must swing by at most MAX_FLOW");

        inventorySignal.update(poolId, false, type(uint256).max);
        state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(-10e18), "second counter-trade must clamp at -MAX_FLOW");
    }

    function test_Update_ZeroSizeTrade_LeavesFlowUnchanged() public {
        inventorySignal.update(poolId, true, 1e18);
        inventorySignal.update(poolId, true, 0);
        InventoryStorage.InventoryState memory state = invStorage.getState(poolId);
        assertEq(state.netFlow, int256(1e18), "zero-size trade must not move netFlow");
    }

    function test_Update_SmallTrades_AccumulateToSameAsOneLargeTrade() public {
        // 10 trades of 0.1e18 == 1 trade of 1e18 (linear scaling).
        for (uint256 i; i < 10; i++) {
            inventorySignal.update(poolId, true, 0.1e18);
        }
        InventoryStorage.InventoryState memory smallState = invStorage.getState(poolId);
        assertEq(smallState.netFlow, int256(1e18), "ten 0.1e18 trades must sum to one FLOW_STEP");
    }
}
