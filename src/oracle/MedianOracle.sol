// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IOracle} from "./IOracle.sol";

/// @title MedianOracle
/// @notice Aggregates prices from multiple IOracle sources and returns the median.
///         Sources that revert (e.g. stale price) are excluded from the calculation.
///         Requires at least 2 valid sources (quorum).
contract MedianOracle is IOracle {
    IOracle[] public sources;

    error InsufficientValidSources();

    constructor(address[] memory _sources) {
        require(_sources.length >= 2, "need >= 2 sources");
        for (uint256 i; i < _sources.length; i++) {
            require(_sources[i] != address(0), "zero source");
            sources.push(IOracle(_sources[i]));
        }
    }

    function getPrice() external view override returns (uint256 priceE18) {
        uint256[] memory valid = _getValidPrices();
        if (valid.length < 2) revert InsufficientValidSources();
        priceE18 = _median(valid);
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
        return validCount < 2;
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

        // Trim the array to the actual count
        assembly {
            mstore(prices, count)
        }
    }

    function _median(uint256[] memory values) internal pure returns (uint256) {
        _sort(values);

        uint256 len = values.length;
        if (len % 2 == 1) {
            return values[len / 2];
        }
        // Even count: average of two middle values
        uint256 mid1 = values[len / 2 - 1];
        uint256 mid2 = values[len / 2];
        return (mid1 + mid2) / 2;
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
