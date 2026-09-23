// SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VolatilityStorage} from "../VolatilityStorage.sol";
import {Volatility} from "../libraries/Volatility.sol";
import {ISignal} from "../interfaces/ISignal.sol";
import {SignalState} from "./SignalState.sol";

contract VolatilitySignal is ISignal, Ownable {
    error VolatilitySignal__Unauthorized();

    VolatilityStorage public immutable volatilityStorage;
    SignalState public immutable signalState;

    /// @notice Minimum swap size (token units) for an observation to count (P1).
    /// @dev Dust trades are skipped entirely — state is not advanced and the
    ///      published signal is not refreshed, so the old reading ages out
    ///      naturally instead of being kept alive by junk observations.
    uint256 public minObservationSize;

    /// @notice The hook — the only account allowed to publish observations (P0).
    address public hook;
    bool private _hookSet;

    constructor(address _volatilityStorage, address _signalState) Ownable(msg.sender) {
        require(_volatilityStorage != address(0), "zero volStorage");
        require(_signalState != address(0), "zero signalState");
        volatilityStorage = VolatilityStorage(_volatilityStorage);
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
        if (msg.sender != hook) revert VolatilitySignal__Unauthorized();
        _;
    }

    /// @notice Owner-tunable dust threshold; default 0 keeps legacy behaviour.
    function setMinObservationSize(uint256 size) external onlyOwner {
        minObservationSize = size;
    }

    function update(PoolId poolId, uint160 newSqrtPriceX96, uint256 tradeSize)
        external
        override
        onlyHook
    {
        // P1 dust filter: below threshold, not an observation at all.
        if (tradeSize < minObservationSize) {
            return;
        }

        VolatilityStorage.VolatilityState memory oldState = volatilityStorage.getState(poolId);
        VolatilityStorage.VolatilityState memory newState = Volatility.compute(oldState, newSqrtPriceX96);
        volatilityStorage.setState(poolId, newState);
        signalState.setVolatility(poolId, newState.ewmaVolatility);
    }

    function compute(PoolId poolId) external view override returns (uint256 value) {
        return volatilityStorage.getState(poolId).ewmaVolatility;
    }
}
