// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {WhaleScoreSignal} from "../../src/signals/WhaleScoreSignal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract WhaleScoreSignalTest is Test {
    PoolManager poolManager;
    SignalState signalState;
    WhaleScoreSignal whaleSignal;
    PoolId poolId;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        signalState = new SignalState();
        whaleSignal = new WhaleScoreSignal(address(poolManager), address(signalState));
        signalState.setAuthorizedWriter(address(whaleSignal), true);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        poolId = key.toId();
    }

    function test_Compute_ZeroLiquidity_ReturnsMaxScore() public view {
        // no liquidity rn ; should be at max risk
        uint256 score = whaleSignal.compute(poolId, 1e17, true);
        assertEq(score, 1e18);
    }

    function testComputeZeroAmountReturnsZero() public view {
        uint256 score = whaleSignal.compute(poolId, 0, true);
        assertEq(score, 0);
    }

    function testUpdatePublishesToSignalState() public {
        whaleSignal.update(poolId, 1e17, true);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.whaleScore, 1e18);
    }
}
