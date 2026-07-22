/*
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";
import {HookShield} from "../../src/HookShield.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

contract HookShieldFullSwapTest is Test {
    PoolManager poolManager;
    HookShield hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liquidityRouter;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 token0;
    MockERC20 token1;

    address user = address(0xBEEF);

    event FeeObserved(uint256 fee);

    function setUp() public {
        poolManager = new PoolManager(address(this));

        tokenA = new MockERC20("T0", "T0");
        tokenB = new MockERC20("T1", "T1");
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
        token0.mint(user, 1e24);
        token1.mint(user, 1e24);

        MarketDataMock market = new MarketDataMock();
        FeeCalculatorMock fee = new FeeCalculatorMock();

        // -------------------------
        // 1. Hook flags
        // -------------------------
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        // -------------------------
        // 2. Constructor args MUST match HookShield
        // -------------------------
        bytes memory constructorArgs = abi.encode(address(market), address(fee), (address(poolManager)));

        bytes memory bytecode = type(HookShield).creationCode;

        // -------------------------
        // 3. HookMiner
        // -------------------------
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, bytecode, constructorArgs);

        hook = new HookShield{salt: salt}(address(market), address(fee), IPoolManager(address(poolManager)));
        require(address(hook) == hookAddress, "HOOK_ADDRESS_MISMATCH");
        // -------------------------
        // 4. VALIDATE HOOK ADDRESS
        // -------------------------
        Hooks.validateHookPermissions(
            IHooks(address(hook)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        // -------------------------
        // 5. Swap router
        // -------------------------
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        // -------------------------
        // 6. approvals
        // -------------------------
        vm.startPrank(user);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);

        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_full_swap_dynamic_fee_flow() public {
        // -------------------------
        // Pool setup
        // -------------------------
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, 79228162514264337593543950336);
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e12, salt: bytes32(0)});

        // -------------------------
        // Swap params
        // -------------------------
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.startPrank(user);
        liquidityRouter.modifyLiquidity(key, lpParams, "");

        vm.stopPrank();
        // Execute swap via unlock

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startPrank(user);

        swapRouter.swap(key, params, settings, "");

        vm.stopPrank();
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return super.totalSupply();
    }
}

contract MarketDataMock {
    function getLatestMarketData() external view returns (int256 price, int256 vol, int256, int256) {
        return (2000e18, 50e18, 0, int256(block.timestamp));
    }
}

contract FeeCalculatorMock {
    function calculateFee(uint256 tradeSize, uint256 volatility) external pure returns (uint24) {
        return uint24((tradeSize / 1e15 + volatility) % 5000);
    }
}
*/
