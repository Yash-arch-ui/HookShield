// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {OracleDivergenceStorage} from "../OracleDivergenceStorage.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {SignalState} from "./SignalState.sol";

contract OracleDivergenceSignal {
    error OracleDivergenceSignal__Unauthorized();

    uint256 public constant SCALE = 1e18;

    /// @notice Emitted when the external oracle cannot be read (M-6).
    /// @dev Previously an unavailable oracle silently produced divergence 0,
    ///      indistinguishable from "prices agree". Now the failure itself is
    ///      signalled: the published divergence becomes SCALE and this event
    ///      gives off-chain observers the reason.
    event OracleUnavailable(PoolId indexed poolId, uint256 timestamp);

    OracleDivergenceStorage public immutable oracleStorage;
    IOracle public immutable oracle;
    SignalState public immutable signalState;

    /// @notice The hook — the only account allowed to publish observations (P0).
    address public hook;
    bool private _hookSet;

    constructor(address _oracleStorage, address _oracle, address _signalState) {
        require(_oracleStorage != address(0), "zero oracleStorage");
        require(_oracle != address(0), "zero oracle");
        require(_signalState != address(0), "zero signalState");
        oracleStorage = OracleDivergenceStorage(_oracleStorage);
        oracle = IOracle(_oracle);
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
        if (msg.sender != hook) revert OracleDivergenceSignal__Unauthorized();
        _;
    }

    /// @notice Called from afterSwap. Fetches the oracle price and computes divergence
    ///         against the pool's current on-chain price.
    /// @dev M-6: an unavailable/stale oracle (price == 0) previously published
    ///      divergence = 0, masking the failure as "no divergence". It now
    ///      publishes SCALE (max divergence) and emits OracleUnavailable, so an
    ///      oracle outage raises fees instead of silently lowering them.
    function update(PoolId poolId, uint160 currentSqrtPriceX96) external onlyHook {
        uint256 oraclePrice = _getOraclePrice();

        // pool price = sqrtPriceX96^2 / 2^192, scaled to 1e18
        uint256 poolPrice = _sqrtPriceToPriceE18(currentSqrtPriceX96);

        // Divergence = |oraclePrice - poolPrice| / max(oraclePrice, poolPrice)
        uint256 divergenceE18;
        if (oraclePrice > 0) {
            divergenceE18 = _computeDivergence(oraclePrice, poolPrice, oraclePrice);
        } else {
            // Oracle unavailable → signal the failure as max divergence (M-6).
            divergenceE18 = SCALE;
            emit OracleUnavailable(poolId, block.timestamp);
        }

        OracleDivergenceStorage.OracleState memory newState = OracleDivergenceStorage.OracleState({
            lastOraclePrice: oraclePrice, lastPoolPrice: poolPrice, lastUpdateBlock: block.number
        });
        oracleStorage.setState(poolId, newState);

        signalState.setOracleDivergence(poolId, divergenceE18);
    }

    /// @dev Distinguishes "never observed" (no update yet → 0, matching the
    ///      never-written-is-not-stale convention) from "observation failed"
    ///      (lastOraclePrice == 0 with lastUpdateBlock != 0 → SCALE, M-6).
    function compute(PoolId poolId) external view returns (uint256 divergenceE18) {
        OracleDivergenceStorage.OracleState memory state = oracleStorage.getState(poolId);
        if (state.lastUpdateBlock == 0) return 0;
        if (state.lastOraclePrice == 0) return SCALE;
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

    function _computeDivergence(uint256 priceA, uint256 priceB, uint256 referencePrice)
        internal
        pure
        returns (uint256)
    {
        if (referencePrice == 0) return 0;
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        return (diff * SCALE) / referencePrice > SCALE ? SCALE : (diff * SCALE) / referencePrice;
    }
}
