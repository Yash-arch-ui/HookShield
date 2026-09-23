pragma solidity ^0.8.26;
import {Test, console} from "forge-std/Test.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {VolatilitySignal} from "../../src/signals/VolatilitySignal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract VolatilitySignalTest is Test {
    VolatilityStorage volStorage;
    SignalState signalState;
    VolatilitySignal volatilitySignal;
    PoolId poolId;

    function setUp() public {
        volStorage = new VolatilityStorage();
        signalState = new SignalState();
        volatilitySignal = new VolatilitySignal(address(volStorage), address(signalState));
        volStorage.setWriter(address(volatilitySignal));
        signalState.setAuthorizedWriter(address(volatilitySignal), true);
        // P0: bind this test as the hook so direct update() calls are authorized.
        volatilitySignal.setHook(address(this));

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Update_FirstCall_IntializesWithoutPublishing() public {
        volatilitySignal.update(poolId, 1000, 1e18);
        assertEq(volatilitySignal.compute(poolId), 0);
    }

    function test_Update_PublishesToSignalState() public {
        volatilitySignal.update(poolId, 1000, 1e18);
        volatilitySignal.update(poolId, 1100, 1e18);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertGt(snap.volatility, 0);
        assertEq(snap.volatility, volatilitySignal.compute(poolId));
    }

    function test_update_revertsIfCalledByUnauthorizedContract() public {
        VolatilitySignal rogueSignal = new VolatilitySignal(address(volStorage), address(signalState));
        vm.expectRevert(); // hook unset / caller not the hook — P0 access control
        rogueSignal.update(poolId, 1200, 1e18);
    }

    function test_update_revertsIfCallerIsNotBoundHook() public {
        // Bound to address(this); a different caller must be rejected.
        vm.prank(address(0xBEEF));
        vm.expectRevert(VolatilitySignal.VolatilitySignal__Unauthorized.selector);
        volatilitySignal.update(poolId, 1200, 1e18);
    }

    function test_setHook_OnlyOnce() public {
        vm.expectRevert("hook already set");
        volatilitySignal.setHook(address(0xBEEF));
    }

    // ── P1 dust filter ──────────────────────────────────────────────────

    function test_Update_DustTradeIsIgnored() public {
        volatilitySignal.setMinObservationSize(1e18);

        // Seed a real observation first.
        volatilitySignal.update(poolId, 1000, 1e18);
        uint256 volBefore = volatilitySignal.compute(poolId);
        uint160 priceBefore = volStorage.getLastSqrtPriceX96(poolId);

        // A dust trade must not advance state nor refresh the reading.
        volatilitySignal.update(poolId, 9999, 1e17); // tradeSize < 1e18
        assertEq(volatilitySignal.compute(poolId), volBefore, "dust must not change published vol");
        assertEq(volStorage.getLastSqrtPriceX96(poolId), priceBefore, "dust must not advance last price");

        // A trade at the threshold IS an observation.
        volatilitySignal.update(poolId, 9999, 1e18);
        assertEq(volStorage.getLastSqrtPriceX96(poolId), 9999, "observation at threshold must be accepted");
    }

    function test_setMinObservationSize_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        volatilitySignal.setMinObservationSize(1e18);
    }

    function test_setMinObservationSize_DefaultZeroAcceptsAnyTrade() public {
        assertEq(volatilitySignal.minObservationSize(), 0);
        volatilitySignal.update(poolId, 1000, 1); // tradeSize = 1 still counts
        assertEq(volStorage.getLastSqrtPriceX96(poolId), 1000);
    }
}
