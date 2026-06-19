// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/AggregatorV3Interface.sol";

contract MarketData {
    AggregatorV3Interface internal constant ETH_USD_PRICE_FEED =
        AggregatorV3Interface(
            0x694AA1769357215DE4FAC081bf1f309aDC325306
        );

    AggregatorV3Interface internal constant ETH_USD_VOL_FEED =
        AggregatorV3Interface(
            0x31D04174D0e1643963b38d87f26b0675Bb7dC96e
        );

    function getEthUsdPrice() public view returns (int256) {
        (
            ,
            int256 answer,
            ,
            ,
            
        ) = ETH_USD_PRICE_FEED.latestRoundData();

        require(answer > 0, "Invalid price");

        return answer;
    }

    function getEthUsdPriceDecimals() public view returns (uint8) {
        return ETH_USD_PRICE_FEED.decimals();
    }

   

    function getEthUsdVol() public view returns (int256) {
        (
            ,
            int256 answer,
            ,
            ,
            
        ) = ETH_USD_VOL_FEED.latestRoundData();

        require(answer > 0, "Invalid volatility");

        return answer;
    }

    function getEthUsdVolDecimals() public view returns (uint8) {
        return ETH_USD_VOL_FEED.decimals();
    }


    function getLatestMarketData()
        external
        view
        returns (
            int256 price,
            int256 volatility,
            uint8 priceDecimals,
            uint8 volDecimals
        )
    {
        price = getEthUsdPrice();
        volatility = getEthUsdVol();
        priceDecimals = getEthUsdPriceDecimals();
        volDecimals = getEthUsdVolDecimals();
    }
}