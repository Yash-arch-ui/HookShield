// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracle} from "./IOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

contract ChainlinkOracle is IOracle {
    AggregatorV3Interface public immutable feed;
    uint256 public immutable maxStaleness;
    uint8 public immutable feedDecimals;

    error StalePrice(uint256 updatedAt, uint256 nowTs);
    error NonPositiveAnswer(int256 answer);

    constructor(address _feed, uint256 _maxStaleness) {
        require(_feed != address(0), "zero feed");
        require(_maxStaleness > 0, "bad staleness");
        feed = AggregatorV3Interface(_feed);
        maxStaleness = _maxStaleness;
        feedDecimals = AggregatorV3Interface(_feed).decimals();
    }

    function getPrice() external view override returns (uint256 priceE18) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert NonPositiveAnswer(answer);
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, block.timestamp);
        priceE18 = uint256(answer) * (1e18 / 10 ** feedDecimals);
    }

    function isStale() external view override returns (bool) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) return true;
        return block.timestamp - updatedAt > maxStaleness;
    }
}
