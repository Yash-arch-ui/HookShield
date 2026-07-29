// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IRiskModel} from "./IRiskModel.sol";
import {SignalState, SignalSnapshot} from "../signals/SignalState.sol";

contract WeightedRiskModel is IRiskModel, Ownable {
    uint256 public constant SCALE = 1e18;
    uint256 public constant STALE_FALLBACK_RISK = 0.5e18;

    SignalState public immutable signalState;
    uint256 public volatilityWeight;
    uint256 public inventorySkewWeight;
    uint256 public oracleDivergenceWeight;
    uint256 public whaleScoreWeight;

    event WeightsUpdated(
        uint256 volatilityWeight, uint256 inventorySkewWeight, uint256 oracleDivergenceWeight, uint256 whaleScoreWeight
    );

    constructor(
        address _signalState,
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) Ownable(msg.sender) {
        require(_signalState != address(0), "zero signalState");
        _setWeights(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
        signalState = SignalState(_signalState);
    }

    function risk(
        PoolId poolId,
        uint256 /* tradeSize */
    )
        external
        view
        override
        returns (uint256 riskE18)
    {
        if (signalState.isStale(poolId)) {
            return STALE_FALLBACK_RISK;
        }

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);

        riskE18 =
            (snap.volatility
                    * volatilityWeight
                    + snap.inventorySkew
                    * inventorySkewWeight
                    + snap.oracleDivergence
                    * oracleDivergenceWeight
                    + snap.whaleScore
                    * whaleScoreWeight) / SCALE;

        if (riskE18 > SCALE) {
            riskE18 = SCALE;
        }
    }

    function setWeights(
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) external onlyOwner {
        _setWeights(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
    }

    function _setWeights(
        uint256 _volatilityWeight,
        uint256 _inventorySkewWeight,
        uint256 _oracleDivergenceWeight,
        uint256 _whaleScoreWeight
    ) internal {
        require(
            _volatilityWeight + _inventorySkewWeight + _oracleDivergenceWeight + _whaleScoreWeight == SCALE,
            "weights must sum to 1e18"
        );

        volatilityWeight = _volatilityWeight;
        inventorySkewWeight = _inventorySkewWeight;
        oracleDivergenceWeight = _oracleDivergenceWeight;
        whaleScoreWeight = _whaleScoreWeight;

        emit WeightsUpdated(_volatilityWeight, _inventorySkewWeight, _oracleDivergenceWeight, _whaleScoreWeight);
    }
}
