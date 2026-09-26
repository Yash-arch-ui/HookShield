//SPDX-License-Identifier:MIT
pragma solidity ^0.8.26;
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SignalState} from "./SignalState.sol";

/// @title WhaleScoreSignal
/// @notice Stateless, beforeSwap-triggered signal that measures a single swap's
///         price impact relative to current pool liquidity.  Unlike the storage-backed,
///         afterSwap-triggered signals (VolatilitySignal, InventorySignal,
///         OracleDivergenceSignal), WhaleScoreSignal does not maintain its own
///         per-pool storage — it reads directly from PoolManager.getSlot0() and
///         getLiquidity(), computes the hypothetical next sqrtPrice, and writes the
///         resulting impact score into SignalState.setWhaleScore().
///
///         It is intentionally called inside beforeSwap (see HookShieldHook) so that
///         the fee for the CURRENT swap reflects its own whale-level impact.  All
///         other signals update in afterSwap because they only need to inform
///         FUTURE swaps.
contract WhaleScoreSignal {
    error WhaleScoreSignal__Unauthorized();

    using StateLibrary for IPoolManager;
    uint256 public constant SCALE = 1e18;

    /// @notice Discount applied to the whale score when this swap REBALANCES
    ///         the pool's existing inventory skew (M-4).
    /// @dev M-4: raw |price impact| is direction-agnostic — a large buy and a
    ///      large sell of equal size produce the same raw number. The pool does
    ///      care about direction: a swap that pushes netFlow further from zero
    ///      deepens the imbalance (full impact), while a swap that pushes it
    ///      back toward zero relieves it (discounted impact). With netFlow == 0
    ///      (balanced pool) every swap gets full impact.
    uint256 public constant REBALANCE_DISCOUNT = 0.5e18;

    IPoolManager public immutable poolManager;
    SignalState public immutable signalState;

    /// @notice The hook — the only account allowed to publish observations (P0).
    address public hook;
    bool private _hookSet;

    constructor(address _poolManager, address _signalState) {
        require(_poolManager != address(0), "zero poolManager");
        require(_signalState != address(0), "zero signalState");
        poolManager = IPoolManager(_poolManager);
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
        if (msg.sender != hook) revert WhaleScoreSignal__Unauthorized();
        _;
    }

    /// @param netFlow Pre-swap signed inventory flow from InventorySignal
    ///        (P2). Used only to decide whether this swap rebalances (discount)
    ///        or worsens (full impact) the existing skew — M-4.
    function update(PoolId poolId, uint256 amountIn, bool zeroForOne, int256 netFlow)
        external
        onlyHook
        returns (uint256 impactE18)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity == 0 || amountIn == 0) {
            impactE18 = amountIn == 0 ? 0 : SCALE;
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
        // M-4: direction-aware adjustment against the pool's current skew.
        impactE18 = _adjustForDirection(impactE18, zeroForOne, netFlow);
        signalState.setWhaleScore(poolId, impactE18);
    }

    function compute(PoolId poolId, uint256 amountIn, bool zeroForOne, int256 netFlow)
        external
        view
        returns (uint256 impactE18)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        if (amountIn == 0) return 0;
        if (liquidity == 0) return SCALE;

        uint160 sqrtPriceNextX96 =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountIn, zeroForOne);
        uint256 oldSqrt = uint256(sqrtPriceX96);
        uint256 newSqrt = uint256(sqrtPriceNextX96);
        uint256 diff = oldSqrt > newSqrt ? oldSqrt - newSqrt : newSqrt - oldSqrt;
        impactE18 = (diff * 2 * SCALE) / oldSqrt;
        if (impactE18 > SCALE) impactE18 = SCALE;
        impactE18 = _adjustForDirection(impactE18, zeroForOne, netFlow);
    }

    /// @dev netFlow > 0 → pool is skewed toward zeroForOne sells; a oneForZero
    ///      swap (zeroForOne == false) rebalances it. netFlow < 0 → symmetric.
    ///      netFlow == 0 → balanced, no discount. Same predicate as
    ///      ThresholdPolicy's rebalance check, so fee discount and whale-score
    ///      discount always agree on direction.
    function _adjustForDirection(uint256 impactE18, bool zeroForOne, int256 netFlow) internal pure returns (uint256) {
        bool rebalances;
        if (netFlow > 0) {
            rebalances = !zeroForOne;
        } else if (netFlow < 0) {
            rebalances = zeroForOne;
        } else {
            rebalances = false;
        }
        if (rebalances) {
            return (impactE18 * REBALANCE_DISCOUNT) / SCALE;
        }
        return impactE18;
    }
}
