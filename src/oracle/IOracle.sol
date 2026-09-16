// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IOracle {
    /// @notice Returns the current price from the oracle, scaled to 1e18.
    function getPrice() external view returns (uint256 priceE18);

    /// @notice Returns true if the oracle price is stale or unavailable.
    function isStale() external view returns (bool);
}
