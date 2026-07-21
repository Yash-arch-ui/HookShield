// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title VolatilityStorage
/// @notice Pure state storage for per-pool volatility tracking.
///         Acts as a database — no math, no EWMA, no price calculations.
///         The Signal Engine reads state, computes externally, then writes back.
contract VolatilityStorage {
    // ──────────────────────── Types ────────────────────────

    struct VolatilityState {
        uint160 lastSqrtPriceX96;   // last observed sqrtPriceX96 from the pool
        uint256 ewmaVolatility;     // EWMA volatility (scaled 1e18)
        uint256 lastUpdateBlock;    // block.number of the last update
    }

    // ──────────────────────── State ────────────────────────

    /// @dev PoolId => VolatilityState
    mapping(PoolId => VolatilityState) private _states;

    // ──────────────────────── Events ────────────────────────

    event StateUpdated(
        PoolId indexed poolId,
        uint160 lastSqrtPriceX96,
        uint256 ewmaVolatility,
        uint256 lastUpdateBlock
    );

    // ──────────────────────── Errors ────────────────────────

    error VolatilityStorage__Unauthorized();

    // ──────────────────────── Access Control ────────────────────────

    /// @dev Address allowed to write state (set once in constructor).
    address public immutable writer;

    modifier onlyWriter() {
        if (msg.sender != writer) revert VolatilityStorage__Unauthorized();
        _;
    }

    constructor(address _writer) {
        require(_writer != address(0), "zero writer");
        writer = _writer;
    }

    // ──────────────────────── Read ────────────────────────

    /// @notice Returns the full volatility state for a pool.
    /// @param poolId The Uniswap v4 pool identifier.
    /// @return state The stored VolatilityState struct.
    function getState(PoolId poolId) external view returns (VolatilityState memory state) {
        state = _states[poolId];
    }

    /// @notice Convenience getter for individual fields.
    function getLastSqrtPriceX96(PoolId poolId) external view returns (uint160) {
        return _states[poolId].lastSqrtPriceX96;
    }

    function getEwmaVolatility(PoolId poolId) external view returns (uint256) {
        return _states[poolId].ewmaVolatility;
    }

    function getLastUpdateBlock(PoolId poolId) external view returns (uint256) {
        return _states[poolId].lastUpdateBlock;
    }

    /// @notice Returns true if a pool has been initialized in storage.
    function isInitialized(PoolId poolId) external view returns (bool) {
        return _states[poolId].lastUpdateBlock != 0;
    }

    // ──────────────────────── Write ────────────────────────

    /// @notice Overwrites the full volatility state for a pool.
    /// @dev Only callable by the designated writer (e.g. HookShield).
    /// @param poolId The Uniswap v4 pool identifier.
    /// @param state  The new VolatilityState to store.
    function setState(PoolId poolId, VolatilityState calldata state) external onlyWriter {
        _states[poolId] = state;

        emit StateUpdated(
            poolId,
            state.lastSqrtPriceX96,
            state.ewmaVolatility,
            state.lastUpdateBlock
        );
    }

    /// @notice Updates individual fields without replacing the entire struct.
    /// @dev Only callable by the designated writer.
    function updateState(
        PoolId poolId,
        uint160 lastSqrtPriceX96,
        uint256 ewmaVolatility,
        uint256 lastUpdateBlock
    ) external onlyWriter {
        VolatilityState storage s = _states[poolId];
        s.lastSqrtPriceX96 = lastSqrtPriceX96;
        s.ewmaVolatility = ewmaVolatility;
        s.lastUpdateBlock = lastUpdateBlock;

        emit StateUpdated(poolId, lastSqrtPriceX96, ewmaVolatility, lastUpdateBlock);
    }
}
