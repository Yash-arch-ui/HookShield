// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {MarketData} from "../src/MarketData.sol";

contract MarketDataTest is Test {
    MarketData public marketData;

    function setUp() public {
        string memory rpcUrl = vm.envString("SEPOLIA_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        marketData = new MarketData();
    }

    function test_GetEthUsdPrice() public view {
        int256 price = marketData.getEthUsdPrice();

        console2.log("ETH/USD Price:");
        console2.logInt(price);

        assertGt(price, 0);
    }

    function test_GetEthUsdVolatility() public view {
        int256 volatility = marketData.getEthUsdVol();

        console2.log("ETH/USD Volatility:");
        console2.logInt(volatility);

        assertGt(volatility, 0);
    }

    function test_GetLatestMarketData() public view {
        (int256 price, int256 volatility, uint8 priceDecimals, uint8 volDecimals) = marketData.getLatestMarketData();

        console2.log("Price:", uint256(price));
        console2.log("Volatility:", uint256(volatility));
        console2.log("Price Decimals:", uint256(priceDecimals));
        console2.log("Vol Decimals:", uint256(volDecimals));

        assertGt(price, 0);
        assertGt(volatility, 0);
    }
}
