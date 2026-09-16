// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracle} from "./IOracle.sol";

/// @title CompositeOracle
/// @notice Aggregates prices from multiple IOracle sources using a configurable
///         strategy: Median, Average, Min, or Max.
///         Sources that revert are excluded. Requires a minimum quorum of valid sources.
contract CompositeOracle is IOracle {
    enum Strategy { Median, Average, Min, Max }

    IOracle[] public sources;
    Strategy public strategy;
    uint256 public minQuorum;

    error InsufficientValidSources();

    constructor(address[] memory _sources, Strategy _strategy) {
        require(_sources.length >= 2, "need >= 2 sources");
        for (uint256 i; i < _sources.length; i++) {
            require(_sources[i] != address(0), "zero source");
            sources.push(IOracle(_sources[i]));
        }
        strategy = _strategy;
        // Default quorum: at least half the sources, minimum 2
        minQuorum = _sources.length / 2;
        if (minQuorum < 2) minQuorum = 2;
    }

    function getPrice() external view override returns (uint256 priceE18) {
        uint256[] memory valid = _getValidPrices();
        if (valid.length < minQuorum) revert InsufficientValidSources();

        if (strategy == Strategy.Median) {
            return _median(valid);
        } else if (strategy == Strategy.Average) {
            return _average(valid);
        } else if (strategy == Strategy.Min) {
            return _min(valid);
        } else {
            return _max(valid);
        }
    }

    function isStale() external view override returns (bool) {
        uint256 validCount;
        for (uint256 i; i < sources.length; i++) {
            try sources[i].isStale() returns (bool stale) {
                if (!stale) validCount++;
            } catch {
                // source unavailable — skip
            }
        }
        return validCount < minQuorum;
    }

    function sourceCount() external view returns (uint256) {
        return sources.length;
    }

    function _getValidPrices() internal view returns (uint256[] memory prices) {
        uint256 count;
        prices = new uint256[](sources.length);

        for (uint256 i; i < sources.length; i++) {
            try sources[i].getPrice() returns (uint256 p) {
                prices[count] = p;
                count++;
            } catch {
                // source reverted — skip
            }
        }

        assembly {
            mstore(prices, count)
        }
    }

    // ── Aggregation strategies ──────────────────────────────────────

    function _median(uint256[] memory values) internal pure returns (uint256) {
        _sort(values);
        uint256 len = values.length;
        if (len % 2 == 1) {
            return values[len / 2];
        }
        return (values[len / 2 - 1] + values[len / 2]) / 2;
    }

    function _average(uint256[] memory values) internal pure returns (uint256) {
        uint256 sum;
        for (uint256 i; i < values.length; i++) {
            sum += values[i];
        }
        return sum / values.length;
    }

    function _min(uint256[] memory values) internal pure returns (uint256) {
        uint256 result = values[0];
        for (uint256 i = 1; i < values.length; i++) {
            if (values[i] < result) result = values[i];
        }
        return result;
    }

    function _max(uint256[] memory values) internal pure returns (uint256) {
        uint256 result = values[0];
        for (uint256 i = 1; i < values.length; i++) {
            if (values[i] > result) result = values[i];
        }
        return result;
    }

    function _sort(uint256[] memory arr) internal pure {
        for (uint256 i = 1; i < arr.length; i++) {
            uint256 key = arr[i];
            uint256 j = i;
            while (j > 0 && arr[j - 1] > key) {
                arr[j] = arr[j - 1];
                j--;
            }
            arr[j] = key;
        }
    }
}
