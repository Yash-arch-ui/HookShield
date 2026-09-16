// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

contract OracleDivergenceStorage {
    struct OracleState {
        uint256 lastOraclePrice; // last Chainlink price, scaled 1e18
        uint256 lastPoolPrice;   // last observed pool price, scaled 1e18
        uint256 lastUpdateBlock;
    }

    mapping(PoolId => OracleState) private _states;

    event OracleStateUpdated(PoolId indexed poolId, uint256 lastOraclePrice, uint256 lastPoolPrice, uint256 lastUpdateBlock);

    error OracleDivergenceStorage__Unauthorized();

    address public writer;
    bool private _writerSet;

    modifier onlyWriter() {
        if (msg.sender != writer) revert OracleDivergenceStorage__Unauthorized();
        _;
    }

    function setWriter(address _writer) external {
        require(!_writerSet, "writer already set");
        require(_writer != address(0), "zero writer");
        writer = _writer;
        _writerSet = true;
    }

    function getState(PoolId poolId) external view returns (OracleState memory) {
        return _states[poolId];
    }

    function setState(PoolId poolId, OracleState calldata state) external onlyWriter {
        _states[poolId] = state;
        emit OracleStateUpdated(poolId, state.lastOraclePrice, state.lastPoolPrice, state.lastUpdateBlock);
    }
}
