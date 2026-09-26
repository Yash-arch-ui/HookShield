// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {InventoryStorage} from "../InventoryStorage.sol";
import {SignalState} from "./SignalState.sol";

contract InventorySignal {
    error InventorySignal__Unauthorized();

    uint256 public constant SCALE = 1e18;

    // How much a single swap shifts netFlow at the reference size, and the cap
    // before it's considered "max skew".
    int256 public constant FLOW_STEP = 1e18;
    int256 public constant MAX_FLOW = 10e18;
    /// @notice Trade size that earns the full FLOW_STEP (M-5).
    /// @dev A swap of REFERENCE_SIZE moves netFlow by exactly FLOW_STEP (legacy
    ///      behaviour, so pre- and post-change behaviour match at 1e18). Smaller
    ///      trades move it proportionally; larger trades move it proportionally
    ///      up to the overflow guard below.
    int256 public constant REFERENCE_SIZE = 1e18;

    InventoryStorage public immutable inventoryStorage;
    SignalState public immutable signalState;

    /// @notice The hook — the only account allowed to publish observations (P0).
    address public hook;
    bool private _hookSet;

    constructor(address _inventoryStorage, address _signalState) {
        require(_inventoryStorage != address(0), "zero inventoryStorage");
        require(_signalState != address(0), "zero signalState");
        inventoryStorage = InventoryStorage(_inventoryStorage);
        signalState = SignalState(_signalState);
    }

    /// @notice One-time binding of the publishing hook (mirrors setWriter pattern).
    function setHook(address _hook) external {
        require(!_hookSet, "hook already set");
        require(_hook != address(0), "zero hook");
        hook = _hook;
        _hookSet = true;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert InventorySignal__Unauthorized();
        _;
    }

    /// @notice Called from afterSwap. zeroForOne indicates swap direction;
    ///         tradeSize scales the flow step (M-5).
    /// @param tradeSize Absolute swap size in token units (same units as
    ///        REFERENCE_SIZE / FLOW_STEP).
    function update(PoolId poolId, bool zeroForOne, uint256 tradeSize) external onlyHook {
        InventoryStorage.InventoryState memory oldState = inventoryStorage.getState(poolId);

        int256 step = _stepFor(tradeSize);
        int256 newFlow = oldState.netFlow + (zeroForOne ? step : -step);

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

    /// @dev step = FLOW_STEP * tradeSize / REFERENCE_SIZE, with an overflow
    ///      guard: REFERENCE_SIZE-sized trades (or larger, up to 10x) scale
    ///      linearly; at tradeSize >= 10 * REFERENCE_SIZE the step saturates at
    ///      MAX_FLOW (the clamp below would clip it there anyway). The guard
    ///      keeps FLOW_STEP * tradeSize inside int256/uint256 for any uint256.
    function _stepFor(uint256 tradeSize) internal pure returns (int256) {
        // (MAX_FLOW / FLOW_STEP) * REFERENCE_SIZE == 10e18
        if (tradeSize >= uint256(MAX_FLOW) / uint256(FLOW_STEP) * uint256(REFERENCE_SIZE)) {
            return MAX_FLOW;
        }
        // tradeSize < 10e18 → FLOW_STEP * tradeSize < 1e38, no overflow.
        return FLOW_STEP * int256(tradeSize) / REFERENCE_SIZE;
    }

    function compute(PoolId poolId) external view returns (uint256 skewE18) {
        InventoryStorage.InventoryState memory state = inventoryStorage.getState(poolId);
        uint256 absFlow = state.netFlow >= 0 ? uint256(state.netFlow) : uint256(-state.netFlow);
        skewE18 = (absFlow * SCALE) / uint256(MAX_FLOW);
    }

    /// @notice Signed net flow: >0 means skew toward zeroForOne sells (P2).
    /// @dev The policy uses this to distinguish a swap that worsens the
    ///      imbalance (surcharge) from one that rebalances it (discount).
    function netFlow(PoolId poolId) external view returns (int256) {
        return inventoryStorage.getState(poolId).netFlow;
    }
}
