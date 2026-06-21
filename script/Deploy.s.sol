// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarketData} from "../src/MarketData.sol";
import {RiskEngine} from "../src/RiskEngine.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {HookShield} from "../src/HookShield.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

contract Deploy is Script {
    function run() external {
        address deployer = msg.sender;
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // 1. DEPLOY DEPENDENCIES
        MarketData marketData = new MarketData();
        FeeCalculator feeCalculator = new FeeCalculator();

        // 2. USE EXISTING POOLMANAGER (FROM ANVIL / TESTS)
        address poolManager = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;

        // 3. HOOK BYTECODE
        bytes memory bytecode = type(HookShield).creationCode;

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(marketData, feeCalculator, IPoolManager(poolManager));

        (address hookAddress,) = HookMiner.find(deployer, flags, bytecode, constructorArgs);

        HookShield hook = HookShield(hookAddress);

        console.log("Hook deployed at:", address(hook));
        console.log("PoolManager:", poolManager);

        vm.stopBroadcast();
    }
}
