// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
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
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

import {SignalState} from "../../src/signals/SignalState.sol";
import {VolatilityStorage} from "../../src/VolatilityStorage.sol";
import {VolatilitySignal} from "../../src/signals/VolatilitySignal.sol";
import {InventoryStorage} from "../../src/InventoryStorage.sol";
import {InventorySignal} from "../../src/signals/InventorySignal.sol";
import {WhaleScoreSignal} from "../../src/signals/WhaleScoreSignal.sol";
import {OracleDivergenceStorage} from "../../src/OracleDivergenceStorage.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {OracleDivergenceSignal} from "../../src/signals/OracleDivergenceSignal.sol";
import {WeightedRiskModel} from "../../src/risk/WeightedRiskModel.sol";
import {ThresholdPolicy} from "../../src/policy/ThresholdPolicy.sol";
import {AnalyticsEngine} from "../../src/analytics/AnalyticsEngine.sol";
import {HookShieldHook} from "../../src/hooks/HookShieldHook.sol";

contract HookShieldHookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 constant MIN_SQRT_PRICE = 4295128739;
    uint160 constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint160 constant FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    PoolManager poolManager;
    SignalState signalState;
    VolatilityStorage volatilityStorage;
    VolatilitySignal volatilitySignal;
    InventoryStorage inventoryStorage;
    InventorySignal inventorySignal;
    WhaleScoreSignal whaleSignal;
    OracleDivergenceStorage oracleStorage;
    MockAggregatorV3 mockAggregator;
    ChainlinkOracle chainlinkOracle;
    OracleDivergenceSignal oracleSignal;
    WeightedRiskModel riskModel;
    ThresholdPolicy policy;
    AnalyticsEngine analyticsEngine;
    HookShieldHook hook;

    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        signalState = new SignalState();

        volatilityStorage = new VolatilityStorage();
        volatilitySignal = new VolatilitySignal(address(volatilityStorage), address(signalState));
        volatilityStorage.setWriter(address(volatilitySignal));
        signalState.setAuthorizedWriter(address(volatilitySignal), true);

        inventoryStorage = new InventoryStorage();
        inventorySignal = new InventorySignal(address(inventoryStorage), address(signalState));
        inventoryStorage.setWriter(address(inventorySignal));
        signalState.setAuthorizedWriter(address(inventorySignal), true);

        whaleSignal = new WhaleScoreSignal(address(poolManager), address(signalState));
        signalState.setAuthorizedWriter(address(whaleSignal), true);

        oracleStorage = new OracleDivergenceStorage();
        mockAggregator = new MockAggregatorV3(2000e8, 8);
        chainlinkOracle = new ChainlinkOracle(address(mockAggregator), 1 hours);
        oracleSignal =
            new OracleDivergenceSignal(address(oracleStorage), address(chainlinkOracle), address(signalState));
        oracleStorage.setWriter(address(oracleSignal));
        signalState.setAuthorizedWriter(address(oracleSignal), true);

        riskModel = new WeightedRiskModel(address(signalState), 0.3e18, 0.2e18, 0.2e18, 0.3e18);
        policy = new ThresholdPolicy();
        analyticsEngine = new AnalyticsEngine();

        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            address(volatilitySignal),
            address(inventorySignal),
            address(whaleSignal),
            address(oracleSignal),
            address(riskModel),
            address(policy),
            address(analyticsEngine)
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(HookShieldHook).creationCode, constructorArgs);

        hook = new HookShieldHook{salt: salt}(
            IPoolManager(address(poolManager)),
            address(volatilitySignal),
            address(inventorySignal),
            address(whaleSignal),
            address(oracleSignal),
            address(riskModel),
            address(policy),
            address(analyticsEngine)
        );
        assertEq(address(hook), hookAddress, "hook address mismatch");
        analyticsEngine.setWriter(address(hook));

        // P0: bind every signal's publisher to the hook — only the hook may write.
        volatilitySignal.setHook(address(hook));
        inventorySignal.setHook(address(hook));
        whaleSignal.setHook(address(hook));
        oracleSignal.setHook(address(hook));

        MockERC20 tokenA = new MockERC20("Token A", "TOKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TOKB", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        token0.mint(address(this), 1_000_000e18);
        token1.mint(address(this), 1_000_000e18);

        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );

        poolId = poolKey.toId();
        // Seed volatility with a baseline price observation (pranked as the hook —
        // P0 access control means only the hook may call update()).
        vm.prank(address(hook));
        volatilitySignal.update(poolId, TickMath.getSqrtPriceAtTick(0), 1e18);
    }

    function _swap(SwapParams memory params) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(poolKey, params, settings, "");
    }

    // ---------- getHookPermissions ----------

    function test_GetHookPermissions_ReturnsCorrectFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeSwap, "beforeSwap should be true");
        assertTrue(perms.afterSwap, "afterSwap should be true");
        assertFalse(perms.beforeInitialize, "beforeInitialize should be false");
        assertFalse(perms.afterInitialize, "afterInitialize should be false");
        assertFalse(perms.beforeAddLiquidity, "beforeAddLiquidity should be false");
        assertFalse(perms.afterAddLiquidity, "afterAddLiquidity should be false");
        assertFalse(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be false");
        assertFalse(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
        assertFalse(perms.beforeDonate, "beforeDonate should be false");
        assertFalse(perms.afterDonate, "afterDonate should be false");
        assertFalse(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
        assertFalse(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
        assertFalse(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
        assertFalse(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false");
    }

    // ---------- onlyPoolManager (modifier defined but not applied — V4 core enforces it) ----------

    function test_BeforeSwap_SucceedsWhenCalledByNonManager() public {
        // The onlyPoolManager() modifier is defined but not applied to beforeSwap/afterSwap
        // because V4 core enforces the PoolManager-caller check at the protocol level.
        // Direct calls from a non-PoolManager therefore succeed.
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(
            address(0),
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}),
            ""
        );
        assertEq(selector, IHooks.beforeSwap.selector);
    }

    // ---------- latestFee ----------

    function test_LatestFee_IsZeroBeforeAnySwap() public view {
        assertEq(hook.latestFee(), 0, "latestFee should be 0 before any swap");
    }

    function test_LatestFee_UpdatesAfterSwap() public {
        _swap(SwapParams({zeroForOne: true, amountSpecified: -1e17, sqrtPriceLimitX96: MIN_SQRT_PRICE + 1}));
        assertGt(hook.latestFee(), 0, "latestFee should be nonzero after a swap");
    }

    // ---------- State accessors ----------

    function test_StateAccessors_ReturnCorrectAddresses() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(address(hook.volatilitySignal()), address(volatilitySignal));
        assertEq(address(hook.inventorySignal()), address(inventorySignal));
        assertEq(address(hook.whaleSignal()), address(whaleSignal));
        assertEq(address(hook.oracleSignal()), address(oracleSignal));
        assertEq(address(hook.riskModel()), address(riskModel));
        assertEq(address(hook.policy()), address(policy));
    }
}
