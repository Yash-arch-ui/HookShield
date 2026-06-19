//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import "./FeeCalculator.sol";
import "./RiskEngine.sol";

contract HookShieldManager {
    RiskEngine public riskEngine;
    FeeCalculator public feeCalculator;

    constructor(address _risk, address _fee) {
        riskEngine = RiskEngine(_risk);
        feeCalculator = FeeCalculator(_fee);
    }

    function getFee(uint256 tradeSize, uint256 volatility) external view returns (uint24) {
        uint256 risk = riskEngine.getRiskScore(tradeSize, volatility);
        return feeCalculator.calculateFee(tradeSize, risk);
    }
}
