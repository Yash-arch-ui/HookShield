// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @title MockAggregatorV3
/// @notice Minimal Chainlink AggregatorV3 mock for unit/integration tests.
contract MockAggregatorV3 is AggregatorV3Interface {
    int256 public answer;
    uint8 public decimals;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
        updatedAt = block.timestamp;
        roundId = 1;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setStale() external {
        updatedAt = block.timestamp - 2 hours;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function description() external pure override returns (string memory) {
        return "MockAggregatorV3";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }
}
