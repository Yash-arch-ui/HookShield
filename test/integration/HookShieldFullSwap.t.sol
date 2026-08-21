// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";
import {VolatilitySignal} from "../../src/signals/VolatilitySignal.sol";
import {InventoryStorage} from "../../src/InventoryStorage.sol";
import {InventorySignal} from "../../src/signals/InventorySignal.sol";
import {WeightedRiskModel} from "../../src/risk/WeightedRiskModel.sol";
import {ThresholdPolicy} from "../../src/policy/ThresholdPolicy.sol";
import {HookShieldHook} from "../../src/hooks/HookShieldHook.sol";

/// @title HookShieldFullSwapTest
/// @notice Local integration test that wires the whole HookShield signal -> risk -> policy
///         stack into a real v4 PoolManager and drives swaps through the mined hook.
contract HookShieldFullSwapTest is Test {
    using PoolIdLibrary for PoolKey;

    // TickMath's MIN/MAX_SQRT_PRICE constants are `internal`, so they can't be referenced
    // from this test contract; use the literal values instead.
    uint160 constant MIN_SQRT_PRICE = 4295128739; // TickMath.MIN_SQRT_PRICE
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342; // TickMath.MAX_SQRT_PRICE

    // Permission flags the mined hook address must carry (bottom 14 bits of the address).
    uint160 constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    PoolManager poolManager;
    SignalState signalState;
    VolatilityStorage volatilityStorage;
    VolatilitySignal volatilitySignal;
    InventoryStorage inventoryStorage;
    InventorySignal inventorySignal;
    WeightedRiskModel riskModel;
    ThresholdPolicy policy;
    HookShieldHook hook;

    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // 1. Deploy a real local PoolManager, with this test contract as its owner/controller.
        poolManager = new PoolManager(address(this));

        // 2. Deploy the shared signal snapshot store, the per-pool volatility storage, and the
        //    VolatilitySignal, wiring their authorization so only the signal can write to both.
        signalState = new SignalState();
        volatilityStorage = new VolatilityStorage();
        volatilitySignal = new VolatilitySignal(address(volatilityStorage), address(signalState));
        volatilityStorage.setWriter(address(volatilitySignal)); // setWriter is one-time, callable by anyone
        signalState.setAuthorizedWriter(address(volatilitySignal), true);

        // 2b. Deploy the inventory storage + signal and wire the same authorization pattern.
        inventoryStorage = new InventoryStorage();
        inventorySignal = new InventorySignal(address(inventoryStorage), address(signalState));
        inventoryStorage.setWriter(address(inventorySignal));
        signalState.setAuthorizedWriter(address(inventorySignal), true);

        // 3. Deploy the risk model, volatility-only for now (vol weight = 1e18, others 0).
        riskModel = new WeightedRiskModel(address(signalState), 1e18, 0, 0, 0);

        // 4. Deploy the fee policy that maps risk to dynamic fee tiers.
        policy = new ThresholdPolicy();

        // 5. Mine a CREATE2 salt so the hook deploys to an address whose bottom 14 bits carry the
        //    BEFORE_SWAP | AFTER_SWAP permission flags. The deployer is this test contract.
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            address(volatilitySignal),
            address(inventorySignal),
            address(riskModel),
            address(policy)
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(HookShieldHook).creationCode, constructorArgs);

        // 6. Deploy the hook with the mined salt and assert it landed where HookMiner predicted.
        hook = new HookShieldHook{salt: salt}(
            IPoolManager(address(poolManager)),
            address(volatilitySignal),
            address(inventorySignal),
            address(riskModel),
            address(policy)
        );
        assertEq(address(hook), hookAddress, "hook did not deploy at the mined CREATE2 address");

        // 7. Deploy two mock ERC20s, mint 1,000,000e18 of each to this contract, then sort them
        //    into currency0 / currency1 by address (PoolManager requires currency0 < currency1).
        MockERC20 tokenA = new MockERC20("Token A", "TOKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TOKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);

        // 8. Deploy the swap and liquidity routers, both pointed at the PoolManager.
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        // 9. Approve both routers for the maximum allowance on both tokens.
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        // 10. Build the pool key: dynamic fee sentinel, tick spacing 60, our mined hook.
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 11. Initialize the pool at a 1:1 price (sqrt price at tick 0).
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        // 12. Add 1e18 liquidity in the [-600, 600] range via the liquidity router.
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );

        // 13. Store the pool id, then seed the volatility signal with the starting price.
        //     Without this seed the snapshot would be "stale" (validUntil == 0), which makes the
        //     risk model return its STALE_FALLBACK_RISK (0.5e18 -> tier 2, 6000 fee) instead of a
        //     clean zero volatility -> base tier. Seeding marks the pool fresh with volatility 0.
        poolId = poolKey.toId();
        volatilitySignal.update(poolId, TickMath.getSqrtPriceAtTick(0));
    }

    /// @notice Executes a swap through the PoolSwapTest router with default test settings.
    function _swap(SwapParams memory params) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, params, settings, "");
    }

    /// @notice A single swap on a fresh pool. Volatility was seeded to 0, so the risk model
    ///         returns 0 and the policy charges the base tier fee (3000, 0.30%).
    function test_FirstSwap_UsesBaseFee() public {
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));

        assertEq(hook.latestFee(), 3000, "first swap should use the base tier fee (volatility is 0)");
    }

    /// @notice Repeated swaps keep feeding returns into the EWMA so volatility ends up > 0.
    ///         The [-600, 600] range with 1e18 liquidity absorbs almost nothing, so a single
    ///         sell pins the price at the price limit. A second identical sell would revert with
    ///         PriceLimitAlreadyExceeded, so the loop alternates direction (sell, buy, ...) to
    ///         keep producing real ~100% sqrt-price returns on every iteration.
    function test_MultipleSwaps_IncreaseVolatility() public {
        for (uint256 i; i < 4; i++) {
            bool zeroForOne = i % 2 == 0; // even: sell token0, odd: buy it back
            _swap(
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -1e17,
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : 2 * MIN_SQRT_PRICE
                })
            );
        }

        assertGt(volatilityStorage.getEwmaVolatility(poolId), 0, "EWMA volatility should be greater than 0");
    }

    /// @notice Larger swaps eventually push the EWMA above the tier-1 threshold (0.2e18), so a
    ///         later swap is charged a higher fee than the first. Because the thin liquidity pins
    ///         the price at the limit after each large sell, we alternate direction to generate
    ///         the ~100%/50% sqrt-price returns that compound volatility past the threshold.
    function test_HighVolatility_EventuallyTriggersHigherFeeTier() public {
        // First swap: a large sell of token0. Volatility is 0 -> base fee (3000).
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));
        uint24 firstFee = hook.latestFee();
        assertEq(firstFee, 3000, "first swap should use the base tier fee");

        // Buy back up to 2 * MIN_SQRT_PRICE: another ~100% sqrt-price move -> EWMA ~0.19e18.
        _swap(SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 2 * MIN_SQRT_PRICE}));

        // Sell back down to the limit: ~50% sqrt-price move -> EWMA ~0.22e18, past tier 1.
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));

        // A later swap now observes the elevated volatility and is charged the tier-1 fee (4000).
        _swap(SwapParams({zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: 2 * MIN_SQRT_PRICE}));

        assertGt(hook.latestFee(), firstFee, "later swap should pay a higher fee than the first swap");
    }
    /// @notice A single zeroForOne swap moves netFlow by +1e18, so the normalised
    ///         inventorySkew (|netFlow|/MAX_FLOW * 1e18) becomes 0.1e18 (> 0).
    function test_Swap_UpdatesInventorySkew() public {
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertGt(snap.inventorySkew, 0, "inventory skew should be positive after a zeroForOne swap");
    }

    /// @notice Each zeroForOne swap adds FLOW_STEP (1e18) to netFlow; after 10 swaps
    ///         netFlow hits MAX_FLOW (10e18) and the normalised skew saturates at 1e18.
    ///         Deep liquidity is added first so the price doesn't pin at the limit.
    function test_RepeatedSameDirectionSwaps_IncreaseSkewTowardMax() public {
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );

        uint256 previousSkew;

        for (uint256 i; i < 10; i++) {
            _swap(SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));

            SignalSnapshot memory snap = signalState.getSnapshot(poolId);
            assertGt(snap.inventorySkew, previousSkew, "skew should increase each iteration");
            assertLe(snap.inventorySkew, 1e18, "skew must never exceed 1e18");
            previousSkew = snap.inventorySkew;
        }

        SignalSnapshot memory finalSnap = signalState.getSnapshot(poolId);
        assertEq(finalSnap.inventorySkew, 1e18, "skew should reach the cap after 10 same-direction swaps");
    }

    /// @notice Three zeroForOne swaps build netFlow to +3e18 (skew 0.3e18).
    ///         One opposite-direction swap brings netFlow to +2e18 (skew 0.2e18).
    ///         Deep liquidity is added first so consecutive same-direction swaps are possible.
    function test_OppositeDirectionSwap_ReducesSkew() public {
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000e18, salt: bytes32(0)}),
            ""
        );

        for (uint256 i; i < 3; i++) {
            _swap(SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));
        }

        SignalSnapshot memory peakSnap = signalState.getSnapshot(poolId);
        uint256 peakSkew = peakSnap.inventorySkew;
        assertEq(peakSkew, 3e17, "3 zeroForOne swaps -> skew = 0.3e18");

        _swap(SwapParams({zeroForOne: false, amountSpecified: -1e17, sqrtPriceLimitX96: MAX_SQRT_PRICE - 1}));

        SignalSnapshot memory afterSnap = signalState.getSnapshot(poolId);
        assertLt(afterSnap.inventorySkew, peakSkew, "opposite swap should reduce skew");
        assertEq(afterSnap.inventorySkew, 2e17, "skew should drop to 0.2e18 after one counter-swap");
    }
}
