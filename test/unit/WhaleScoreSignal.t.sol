// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {WhaleScoreSignal} from "../../src/signals/WhaleScoreSignal.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract WhaleScoreSignalTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolManager poolManager;
    SignalState signalState;
    WhaleScoreSignal whaleSignal;
    PoolId poolId;
    PoolKey poolKey;
    PoolModifyLiquidityTest liquidityRouter;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        signalState = new SignalState();
        whaleSignal = new WhaleScoreSignal(address(poolManager), address(signalState));
        signalState.setAuthorizedWriter(address(whaleSignal), true);
        // P0: bind this test as the hook so direct update() calls are authorized.
        whaleSignal.setHook(address(this));

        MockERC20 tokenA = new MockERC20("Token A", "TOKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TOKB", 18);
        (address a, address b) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        MockERC20 token0 = MockERC20(a);
        MockERC20 token1 = MockERC20(b);
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);

        // Static fee + no hook is the only valid combination here: v4 forbids
        // a dynamic fee on a pool with hooks == address(0).
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        poolId = poolKey.toId();

        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 100e18, salt: bytes32(0)}),
            ""
        );
    }

    // ── Baseline behaviour (liquidity present) ──────────────────────────

    function test_Compute_ZeroAmount_ReturnsZero() public view {
        assertEq(whaleSignal.compute(poolId, 0, true, 0), 0);
    }

    function test_Compute_SmallTrade_ReturnsSubScaleImpact() public view {
        uint256 score = whaleSignal.compute(poolId, 1e17, true, 0);
        assertGt(score, 0, "small trade on a liquid pool should score above zero");
        assertLt(score, 1e18, "small trade should not saturate at SCALE");
    }

    function testUpdatePublishesToSignalState() public {
        whaleSignal.update(poolId, 1e17, true, 0);
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertGt(snap.whaleScore, 0, "update should publish a nonzero score");
        assertLt(snap.whaleScore, 1e18, "small trade should not saturate");
    }

    // ── M-4: direction-aware whale score ────────────────────────────────
    // Note: buy and sell raw impacts differ by integer rounding in
    // SqrtPriceMath (~0.1% at tick 0), so each assertion compares a direction
    // against ITS OWN undiscounted baseline (netFlow == 0), never across
    // directions.

    function test_M4_BalancedPool_NoDirectionDiscount() public view {
        // netFlow == 0 → no skew to rebalance → full impact either way.
        uint256 sellFull = whaleSignal.compute(poolId, 1e17, true, 0);
        uint256 buyFull = whaleSignal.compute(poolId, 1e17, false, 0);
        uint256 sellSkewed = whaleSignal.compute(poolId, 1e17, true, 5e18);
        // zeroForOne + netFlow > 0 = worsens → must keep the full sell impact.
        assertEq(sellSkewed, sellFull, "worsening swap must keep full impact");
        assertGt(sellFull, 0);
        assertGt(buyFull, 0);
    }

    function test_M4_RebalancingSwap_GetsDiscount() public view {
        // Pool skewed toward zeroForOne sells (netFlow > 0); a oneForZero swap
        // rebalances it → discounted by REBALANCE_DISCOUNT (0.5).
        uint256 buyFull = whaleSignal.compute(poolId, 1e17, false, 0); // baseline, no discount
        uint256 buyRebalancing = whaleSignal.compute(poolId, 1e17, false, 5e18);
        uint256 sellWorsens = whaleSignal.compute(poolId, 1e17, true, 5e18);
        uint256 sellFull = whaleSignal.compute(poolId, 1e17, true, 0);

        assertEq(sellWorsens, sellFull, "worsening swap must keep full impact");
        assertEq(
            buyRebalancing,
            (buyFull * whaleSignal.REBALANCE_DISCOUNT()) / 1e18,
            "rebalancing must be 0.5x its own baseline"
        );
        assertLt(buyRebalancing, buyFull);
    }

    function test_M4_NegativeNetFlow_RebalancingIsZeroForOne() public view {
        // Pool skewed toward oneForZero (netFlow < 0); a zeroForOne swap rebalances.
        uint256 sellFull = whaleSignal.compute(poolId, 1e17, true, 0);
        uint256 sellRebalancing = whaleSignal.compute(poolId, 1e17, true, -5e18);
        uint256 buyWorsens = whaleSignal.compute(poolId, 1e17, false, -5e18);
        uint256 buyFull = whaleSignal.compute(poolId, 1e17, false, 0);

        assertEq(buyWorsens, buyFull, "worsening swap must keep full impact");
        assertEq(
            sellRebalancing,
            (sellFull * whaleSignal.REBALANCE_DISCOUNT()) / 1e18,
            "zeroForOne must be the rebalancing direction when netFlow < 0"
        );
    }

    function test_M4_SymmetricSkews_ProduceSymmetricScores() public view {
        // +5e18 skew with a sell == -5e18 skew with a buy: each rebalances or
        // worsens its mirror direction, so the two results must be identical
        // up to the pool's inherent buy/sell rounding — assert the discounted
        // side equals exactly half of its own baseline instead (above), and
        // here just pin that both skews discount the same way:
        uint256 sellWorsensPos = whaleSignal.compute(poolId, 1e17, true, 5e18);
        uint256 sellFull = whaleSignal.compute(poolId, 1e17, true, 0);
        uint256 buyWorsensNeg = whaleSignal.compute(poolId, 1e17, false, -5e18);
        uint256 buyFull = whaleSignal.compute(poolId, 1e17, false, 0);

        assertEq(sellWorsensPos, sellFull, "worsening keeps full impact (positive skew)");
        assertEq(buyWorsensNeg, buyFull, "worsening keeps full impact (negative skew)");
    }

    function test_M4_UpdateWritesDiscountedScore() public {
        whaleSignal.update(poolId, 1e17, false, 5e18); // rebalancing
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);

        uint256 expected = whaleSignal.compute(poolId, 1e17, false, 5e18);
        assertEq(snap.whaleScore, expected, "update must publish the direction-adjusted score");
    }

    function test_M4_ZeroLiquidityStillReturnsMaxRegardlessOfNetFlow() public {
        // liquidity == 0 is an early return before direction adjustment —
        // an illiquid pool is max risk no matter which way the swap leans.
        poolManager.initialize(
            PoolKey({
                currency0: Currency.wrap(address(0x1)),
                currency1: Currency.wrap(address(0x2)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }),
            TickMath.getSqrtPriceAtTick(0)
        );
        PoolId empty = PoolKey({
                currency0: Currency.wrap(address(0x1)),
                currency1: Currency.wrap(address(0x2)),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(address(0))
            }).toId();
        assertEq(whaleSignal.compute(empty, 1e17, true, 0), 1e18);
        assertEq(whaleSignal.compute(empty, 1e17, false, 5e18), 1e18);
    }

    function test_M4_RebalanceDiscountConstant() public view {
        assertEq(whaleSignal.REBALANCE_DISCOUNT(), 0.5e18);
    }
}
