// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IFeeCalculator {
    function calculateFee(uint256 tradeSize, uint256 volatility) external pure returns (uint24);
}

contract VolatilityOracle {
    AggregatorV3Interface public immutable volatilityFeed;
    IFeeCalculator public immutable feeCalculator;
    uint256 public immutable maxStaleness;
    uint256 public constant MIN_VOLATILITY = 1; // must be > 0
    uint256 public constant MAX_VOLATILITY = 500_000; // 500% hard ceiling

    error StalePrice(uint256 updatedAt, uint256 nowTs);
    error IncompleteRound(uint80 answeredInRound, uint80 roundId);
    error NonPositiveAnswer(int256 answer);
    error VolatilityOutOfBounds(uint256 volatility);
    error ZeroTradeSize();

    constructor(address _feed, address _feeCalculator, uint256 _maxStaleness) {
        require(_feed != address(0) && _feeCalculator != address(0), "zero addr");
        require(_maxStaleness > 0, "bad staleness");
        volatilityFeed = AggregatorV3Interface(_feed);
        feeCalculator = IFeeCalculator(_feeCalculator);
        maxStaleness = _maxStaleness;
    }

    function getValidatedVolatility() public view returns (uint256 volatility) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = volatilityFeed.latestRoundData();
        if (answer <= 0) revert NonPositiveAnswer(answer);
        if (answeredInRound < roundId) revert IncompleteRound(answeredInRound, roundId);

        if (updatedAt == 0 || block.timestamp - updatedAt > maxStaleness) {
            revert StalePrice(updatedAt, block.timestamp);
        }

        volatility = uint256(answer);
        if (volatility < MIN_VOLATILITY || volatility > MAX_VOLATILITY) {
            revert VolatilityOutOfBounds(volatility);
        }
    }

    function getFee(uint256 tradeSize) external view returns (uint24) {
        if (tradeSize == 0) revert ZeroTradeSize();
        uint256 volatility = getValidatedVolatility();
        return feeCalculator.calculateFee(tradeSize, volatility);
    }
}

contract FeeCalculator {
    error FeeCalculator__InvalidTradeSize();
    error FeeCalculator__InvalidVolatility();
    uint256 public constant MAX_VOLATILITY = 500_000; // 500 % sanity cap
    uint256 public constant SCALE = 1e18;

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
        if (tradeSize == 0) revert FeeCalculator__InvalidTradeSize();
        if (volatility == 0 || volatility > MAX_VOLATILITY) revert FeeCalculator__InvalidVolatility();
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
        require(fee <= type(uint24).max, "fee overflow");
        return uint24(fee);
    }
}

