//SPDX-License-Identifier:MIT
pragma solidity ^0.8.26;
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SignalState} from "./signals/SignalState.sol";

contract WhaleScoreSignal {
    using StateLibrary for IPoolManager;
    uint256 public constant SCALE = 1e18;
    IPoolManager public immutable poolManager;
    SignalState public immutable signalState;

    constructor(address _poolManager, address _signalState) {
        require(_poolManager != address(0), "zero poolManager");
        require(_signalState != address(0), "zero signalState");
        poolManager = IPoolManager(_poolManager);
        signalState = SignalState(_signalState);
    }

    function update(PoolId poolId, uint256 amountIn, bool zeroForOne) external returns (uint256 impactE18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0 || amountIn == 0) {
            impactE18 = liquidity == 0 ? SCALE : 0;
            signalState.setWhaleScore(poolId, impactE18);
            return impactE18;
        }

        uint160 sqrtPriceNextX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, zeroForOne);

        uint256 oldSqrt = uint256(sqrtPriceX96);
        uint256 newSqrt = uint256(sqrtPriceNextX96);
        uint256 diff = oldSqrt > newSqrt ? oldSqrt - newSqrt : newSqrt - oldSqrt;
        impactE18 = (diff * 2 * SCALE) / oldSqrt;
        if (impactE18 > SCALE) {
            impactE18 = SCALE;
        }
        signalState.setWhaleScore(poolId, impactE18);
    }

    function compute(PoolId poolId, uint256 amountIn, bool zeroForOne) external view returns (uint256 impactE18) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        if (liquidity == 0) return SCALE;
        if (amountIn == 0) return 0;

        uint160 sqrtPriceNextX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, zeroForOne);
        uint256 oldSqrt = uint256(sqrtPriceX96);
        uint256 newSqrt = uint256(sqrtPriceNextX96);
        uint256 diff = oldSqrt > newSqrt ? oldSqrt - newSqrt : newSqrt - oldSqrt;
        impactE18 = (diff * 2 * SCALE) / oldSqrt;
        if (impactE18 > SCALE) impactE18 = SCALE;
    }
}
