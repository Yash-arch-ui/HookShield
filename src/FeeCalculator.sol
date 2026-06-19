// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FeeCalculator {
    uint256 private constant SCALE = 1e18;

    uint256 public constant NORMAL_TRADE_SIZE = 150 ether;

    // Chainlink volatility feed:
    // 60000 = 60%
    uint256 public constant NORMAL_VOLATILITY = 60_000;

    uint24 public constant MIN_FEE = 500; // 0.05%
    uint24 public constant BASE_FEE = 3000; // 0.30%
    uint24 public constant MAX_FEE = 10000; // 1.00%

    function calculateFee(uint256 tradeSize, uint256 volatility) public pure returns (uint24) {
        // Trade ratio
        // 150 ETH => 1.0
        uint256 tradeRatio = (tradeSize * SCALE) / NORMAL_TRADE_SIZE;

        uint256 volRatio = (volatility * SCALE) / NORMAL_VOLATILITY;

        uint256 volSquared = (volRatio * volRatio) / SCALE;

        uint256 riskScore = (tradeRatio * volSquared) / SCALE;

        /*
         * Calibration:
         *
         * Low Risk:
         * 10 ETH, 20%
         * -> ~3003
         *
         * Normal:
         * 150 ETH, 60%
         * -> ~3500
         *
         * High:
         * 500 ETH, 120%
         * -> ~9666
         */
        uint256 fee = BASE_FEE + ((riskScore * 500) / SCALE);

        if (fee > MAX_FEE) {
            fee = MAX_FEE;
        }

        if (fee < MIN_FEE) {
            fee = MIN_FEE;
        }

        return uint24(fee);
    }
}
