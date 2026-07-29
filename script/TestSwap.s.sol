// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

contract TestSwap is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        address poolManagerAddress = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookShieldAddress = vm.envAddress("HOOK_SHIELD_HOOK_ADDRESS");
        address currency0Address = vm.envAddress("CURRENCY0_ADDRESS");
        address currency1Address = vm.envAddress("CURRENCY1_ADDRESS");
        address swapRouterAddress = vm.envAddress("SWAP_ROUTER_ADDRESS");

        // Rebuild the EXACT same PoolKey used in InitializePool.s.sol
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0Address),
            currency1: Currency.wrap(currency1Address),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookShieldAddress)
        });

        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e17, // exact input: 0.1 token
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.startBroadcast(pk);

        PoolSwapTest(swapRouterAddress).swap(poolKey, swapParams, testSettings, "");

        vm.stopBroadcast();

        console.log("Swap executed successfully");
        console.log("PoolManager:", poolManagerAddress);
        console.log("Hook:       ", hookShieldAddress);
    }
}
