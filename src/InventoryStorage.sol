// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title InventoryStorage
/// @notice Tracks net directional swap flow per pool as a proxy for inventory imbalance.
contract InventoryStorage {
    struct InventoryState {
        int256 netFlow;          // positive = more zeroForOne swaps, negative = more oneForZero
        uint256 lastUpdateBlock;
    }

    mapping(PoolId => InventoryState) private _states;

    event InventoryUpdated(PoolId indexed poolId, int256 netFlow, uint256 lastUpdateBlock);

    error InventoryStorage__Unauthorized();

    address public writer;
    bool private _writerSet;

    modifier onlyWriter() {
        if (msg.sender != writer) revert InventoryStorage__Unauthorized();
        _;
    }

    function setWriter(address _writer) external {
        require(!_writerSet, "writer already set");
        require(_writer != address(0), "zero writer");
        writer = _writer;
        _writerSet = true;
    }

    function getState(PoolId poolId) external view returns (InventoryState memory) {
        return _states[poolId];
    }

    function setState(PoolId poolId, InventoryState calldata state) external onlyWriter {
        _states[poolId] = state;
        emit InventoryUpdated(poolId, state.netFlow, state.lastUpdateBlock);
    }
}
