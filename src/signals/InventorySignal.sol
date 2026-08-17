// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {InventoryStorage} from "../InventoryStorage.sol";
import {SignalState} from "./SignalState.sol";

contract InventorySignal {
    uint256 public constant SCALE = 1e18;

    // How much a single swap shifts netFlow, and the cap before it's considered "max skew"
    int256 public constant FLOW_STEP = 1e18;
    int256 public constant MAX_FLOW = 10e18;

    InventoryStorage public immutable inventoryStorage;
    SignalState public immutable signalState;

    constructor(address _inventoryStorage, address _signalState) {
        require(_inventoryStorage != address(0), "zero inventoryStorage");
        require(_signalState != address(0), "zero signalState");
        inventoryStorage = InventoryStorage(_inventoryStorage);
        signalState = SignalState(_signalState);
    }

    /// @notice Called from afterSwap. zeroForOne indicates swap direction.
    function update(PoolId poolId, bool zeroForOne) external {
        InventoryStorage.InventoryState memory oldState = inventoryStorage.getState(poolId);

        int256 newFlow = oldState.netFlow + (zeroForOne ? FLOW_STEP : -FLOW_STEP);

        if (newFlow > MAX_FLOW) newFlow = MAX_FLOW;
        if (newFlow < -MAX_FLOW) newFlow = -MAX_FLOW;

        InventoryStorage.InventoryState memory newState =
            InventoryStorage.InventoryState({netFlow: newFlow, lastUpdateBlock: block.number});

        inventoryStorage.setState(poolId, newState);

        // Normalize |netFlow| / MAX_FLOW to 0..1e18
        uint256 absFlow = newFlow >= 0 ? uint256(newFlow) : uint256(-newFlow);
        uint256 skewE18 = (absFlow * SCALE) / uint256(MAX_FLOW);

        signalState.setInventorySkew(poolId, skewE18);
    }

    function compute(PoolId poolId) external view returns (uint256 skewE18) {
        InventoryStorage.InventoryState memory state = inventoryStorage.getState(poolId);
        uint256 absFlow = state.netFlow >= 0 ? uint256(state.netFlow) : uint256(-state.netFlow);
        skewE18 = (absFlow * SCALE) / uint256(MAX_FLOW);
    }
}
