// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarketData} from "../src/MarketData.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {HookShield} from "../src/HookShield.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

// NOTE: RiskEngine removed — it wasn't deployed or wired into constructorArgs
// in the original script. If it's actually part of your architecture,
// re-add it: deploy it, and pass it into HookShield's constructor.

contract Deploy is Script {
    // Foundry's canonical deterministic CREATE2 deployer proxy.
    // Salts must be mined against THIS address, not msg.sender/tx signer,
    // since this is what actually performs the CREATE2 call.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // 1. DEPLOY DEPENDENCIES
        MarketData marketData = new MarketData();
        FeeCalculator feeCalculator = new FeeCalculator();

        // 2. POOLMANAGER — pull from env instead of hardcoding, so this
        // script works unchanged across local/testnet/mainnet fork runs.
        address poolManager = vm.envAddress("POOL_MANAGER");

        // 3. HOOK PERMISSION FLAGS — must exactly match HookShield's
        // getHookPermissions(). Only beforeSwap is enabled there.
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG);

        bytes memory bytecode = type(HookShield).creationCode;
        bytes memory constructorArgs = abi.encode(marketData, feeCalculator, IPoolManager(poolManager));

        // 4. MINE a salt so the deployed address encodes the right flags.
        (address hookAddress, bytes32 salt) = HookMiner.find(CREATE2_DEPLOYER, flags, bytecode, constructorArgs);

        // 5. ACTUALLY DEPLOY at that mined address using the salt.
        HookShield hook =
            new HookShield{salt: salt}(address(marketData), address(feeCalculator), IPoolManager(poolManager));

        require(address(hook) == hookAddress, "DeployScript: hook address mismatch");

        console.log("Hook deployed at:", address(hook));
        console.log("PoolManager:", poolManager);

        vm.stopBroadcast();
    }
}
