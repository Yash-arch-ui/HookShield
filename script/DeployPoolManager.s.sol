//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PoolManager} from "../lib/v4-core/src/PoolManager.sol";

contract DeployPoolManagerScript is Script {
    function run() external {

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);
        PoolManager manager = new PoolManager(deployer);
         console.log("PoolManager deployed at:", address(manager));
        vm.stopBroadcast();
    }
}
