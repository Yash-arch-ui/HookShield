// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MarketData} from "../src/MarketData.sol";
import {RiskEngine} from "../src/RiskEngine.sol";
import {FeeCalculator} from "../src/FeeCalculator.sol";
import {HookShield} from "../src/HookShield.sol";

contract Deploy is Script {
    function run() external {
         uint256 privateKey = vm.envUint("PRIVATE_KEY");

         vm.startBroadcast(privateKey);
        MarketData marketData = new MarketData();
        RiskEngine riskEngine =  new RiskEngine();
        FeeCalculator feeCalculator = new FeeCalculator();
        HookShield hookShield = new HookShield( address(marketData),address(feeCalculator)
            );

        console.log( "MarketData:",address(marketData)
        );

        console.log("RiskEngine:",address(riskEngine)
        );

        console.log("FeeCalculator:",address(feeCalculator)
        );

        console.log("HookShield:",address(hookShield)
        );

        vm.stopBroadcast();
    }
}
