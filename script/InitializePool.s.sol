// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

contract InitializePool is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(pk);
        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookShieldAddress = vm.envAddress("HOOK_SHIELD_HOOK_ADDRESS");

        vm.startBroadcast(pk);

        MockERC20 tokenA = new MockERC20("TokenA", "TKA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKB", 18);

        tokenA.mint(deployerAddress, 1_000_000e18);
        tokenB.mint(deployerAddress, 1_000_000e18);

        Currency currency0;
        Currency currency1;

        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(poolManagerAddress));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(poolManagerAddress));

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityRouter), type(uint256).max);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookShieldAddress)
        });

        uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);

        IPoolManager(poolManagerAddress).initialize(poolKey, startingSqrtPriceX96);

        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );

        vm.stopBroadcast();

        console.log("TokenA:        ", address(tokenA));
        console.log("TokenB:        ", address(tokenB));
        console.log("Currency0:     ", Currency.unwrap(currency0));
        console.log("Currency1:     ", Currency.unwrap(currency1));
        console.log("SwapRouter:    ", address(swapRouter));
        console.log("LiquidityRouter:", address(liquidityRouter));
    }
}
