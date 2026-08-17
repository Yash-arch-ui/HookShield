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

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Update_FirstCall_IntializesWithoutPublishing() public {
        volatilitySignal.update(poolId, 1000);
        assertEq(volatilitySignal.compute(poolId), 0);
    }

    function test_Update_PublishesToSignalState() public {
        volatilitySignal.update(poolId, 1000);
        volatilitySignal.update(poolId, 1100);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertGt(snap.volatility, 0);
        assertEq(snap.volatility, volatilitySignal.compute(poolId));
    }

    function test_update_revertsIfCalledByUnauthorizedContract() public {
        VolatilitySignal rogueSignal = new VolatilitySignal(address(volStorage), address(signalState));
        vm.expectRevert(); // will revert since rogueSignal isn't the authorized writer
        rogueSignal.update(poolId, 1200);
    }
}
