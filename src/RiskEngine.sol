//SPDX-License-Identifier:MIT
pragma solidity ^0.8.24
contract RiskEngine {
    function getRiskScore(uint256 tradeSize, uint256 volatility) external pure returns (uint256) {
        uint256 sizeFactor = (tradeSize * 100) / 150 ether;
        uint256 volFactor = volatility;

        return (sizeFactor + volFactor) / 2;
    }
}
