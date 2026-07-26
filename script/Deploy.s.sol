// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {SignalState} from "../src/signals/SignalState.sol";
import {VolatilityStorage} from "../src/VolatilityStorage.sol";
import {VolatilitySignal} from "../src/signals/VolatilitySignal.sol";
import {HookShieldHook} from "../src/hooks/HookShieldHook.sol";

contract Deploy is Script {
    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        vm.startBroadcast();
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(pk);
        SignalState signalState = new SignalState();
        VolatilityStorage volatilityStorage = new VolatilityStorage();
        VolatilitySignal volatilitySignal = new VolatilitySignal(
            address(volatilityStorage),
            address(signalState)
        );
        volatilityStorage.setWriter(address(volatilitySignal));
        signalState.setAuthorizedWriter(address(volatilitySignal), true);
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManagerAddr),
            address(volatilitySignal)
        );
        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C ;    
        (address predictedHookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,          // deployer (or CREATE2 factory address, depending on your setup)
            flags,
            type(HookShieldHook).creationCode,
            constructorArgs
        );

        HookShieldHook hook = new HookShieldHook{salt: salt}(
            IPoolManager(poolManagerAddr),
            address(volatilitySignal)
        );

        require(address(hook) == predictedHookAddr, "hook address mismatch");
        vm.stopBroadcast();
        console.log("SignalState:       ", address(signalState));
        console.log("VolatilityStorage: ", address(volatilityStorage));
        console.log("VolatilitySignal:  ", address(volatilitySignal));
        console.log("HookShieldHook:    ", address(hook));
    }
}
