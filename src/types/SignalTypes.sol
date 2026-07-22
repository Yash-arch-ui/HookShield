//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";  

library SignalTypes {
 
 struct SignalContext{
    PoolId poolId;
    uint256 sqrtPriceX96;
    uint256 currentliquidity;
    uint256 swapAmount;
    uint256 swapDirection;
    uint256 oraclePrize;
    uint256 currentBlock;
    uint256 timestamp;
    }
    struct SignalResult{
        uint256 volatility;
        uint256 oracleDivergence;
        uint256 inventrySkew;
        uint256 jitScore;
        uint256 volumeScore;
        uint256 whaleScore;
        uint256 flashloanScore;
        uint256 sandWichScore;
        uint256 toxicFlowScore;
        uint256 mevScore;
    }
}