// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {OracleDivergenceStorage} from "../OracleDivergenceStorage.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {SignalState} from "./SignalState.sol";

contract OracleDivergenceSignal {
    uint256 public constant SCALE = 1e18;

    OracleDivergenceStorage public immutable oracleStorage;
    IOracle public immutable oracle;
    SignalState public immutable signalState;

    constructor(address _oracleStorage, address _oracle, address _signalState) {
        require(_oracleStorage != address(0), "zero oracleStorage");
        require(_oracle != address(0), "zero oracle");
        require(_signalState != address(0), "zero signalState");
        oracleStorage = OracleDivergenceStorage(_oracleStorage);
        oracle = IOracle(_oracle);
        signalState = SignalState(_signalState);
    }

    /// @notice Called from afterSwap. Fetches the oracle price and computes divergence
    ///         against the pool's current on-chain price.
    function update(PoolId poolId, uint160 currentSqrtPriceX96) external {
        uint256 oraclePrice = _getOraclePrice();

        // pool price = sqrtPriceX96^2 / 2^192, scaled to 1e18
        uint256 poolPrice = _sqrtPriceToPriceE18(currentSqrtPriceX96);

        // Divergence = |oraclePrice - poolPrice| / max(oraclePrice, poolPrice)
        // If oracle is unavailable (price == 0), divergence is 0 (no signal).
        uint256 divergenceE18;
        if (oraclePrice > 0) {
            divergenceE18 = _computeDivergence(oraclePrice, poolPrice, oraclePrice);
        }

        OracleDivergenceStorage.OracleState memory newState = OracleDivergenceStorage.OracleState({
            lastOraclePrice: oraclePrice,
            lastPoolPrice: poolPrice,
            lastUpdateBlock: block.number
        });
        oracleStorage.setState(poolId, newState);

        signalState.setOracleDivergence(poolId, divergenceE18);
    }

    function compute(PoolId poolId) external view returns (uint256 divergenceE18) {
        OracleDivergenceStorage.OracleState memory state = oracleStorage.getState(poolId);
        if (state.lastOraclePrice == 0) return 0;
        divergenceE18 = _computeDivergence(state.lastOraclePrice, state.lastPoolPrice, state.lastOraclePrice);
    }

    function _getOraclePrice() internal view returns (uint256) {
        try oracle.getPrice() returns (uint256 price) {
            return price;
        } catch {
            return 0;
        }
    }

    function _sqrtPriceToPriceE18(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // price = (sqrtPriceX96)^2 / 2^192, scaled to 1e18
        // Split sqrtPriceX96 into 128-bit halves to avoid overflow in the square.
        uint256 a = uint256(sqrtPriceX96);
        uint256 aHi = a >> 128;
        uint256 aLo = a & ((1 << 128) - 1);
        // priceX192 = a^2 = aHi^2 * 2^256 + 2*aHi*aLo * 2^128 + aLo^2
        // priceRaw = priceX192 >> 192 = aHi^2 * 2^64 + (2*aHi*aLo) >> 64 + aLo^2 >> 128
        uint256 priceRaw = (aHi * aHi) << 64;
        priceRaw += (aHi * aLo) >> 63; // 2 * aHi * aLo >> 64 = aHi * aLo >> 63
        priceRaw += (aLo * aLo) >> 128;
        return priceRaw * 1e18;
    }

    function _computeDivergence(uint256 priceA, uint256 priceB, uint256 referencePrice) internal pure returns (uint256) {
        if (referencePrice == 0) return 0;
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        return (diff * SCALE) / referencePrice > SCALE ? SCALE : (diff * SCALE) / referencePrice;
    }
}
