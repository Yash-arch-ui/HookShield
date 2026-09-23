use crate::math::SCALE;
use alloy::primitives::U256;

/// P0: stale signals escalate to MAX risk (was 0.5e18 — far too lenient).
pub const STALE_FALLBACK_RISK: u128 = SCALE; // 1e18

/// P2: cap on the size/liquidity pressure term (WeightedRiskModel.sol).
pub const MAX_PRESSURE: u128 = 300_000_000_000_000_000; // 0.3e18

pub struct SignalWeights {
    pub volatility: u128,
    pub inventory_skew: u128,
    pub oracle_divergence: u128,
    pub whale_score: u128,
}

#[derive(Clone, Copy)]
pub struct SignalSnapshot {
    pub volatility: u128,
    pub inventory_skew: u128,
    pub oracle_divergence: u128,
    pub whale_score: u128,
}

/// Mirrors WeightedRiskModel.risk(poolId, tradeSize, liquidity):
///   1. stale → STALE_FALLBACK_RISK (SCALE)
///   2. weighted sum of the four signals
///   3. + size/liquidity pressure, clamped at MAX_PRESSURE (P2)
///   4. capped at SCALE
pub fn compute_weighted_risk(
    snapshot: &SignalSnapshot,
    weights: &SignalWeights,
    is_stale: bool,
    trade_size: u128,
    liquidity: u128,
) -> Result<u128, String> {
    if is_stale {
        return Ok(STALE_FALLBACK_RISK);
    }

    let vol_term = snapshot
        .volatility
        .checked_mul(weights.volatility)
        .ok_or("overflow in volatility term")?;
    let inv_term = snapshot
        .inventory_skew
        .checked_mul(weights.inventory_skew)
        .ok_or("overflow in inventory_skew term")?;
    let oracle_term = snapshot
        .oracle_divergence
        .checked_mul(weights.oracle_divergence)
        .ok_or("overflow in oracle_divergence term")?;
    let whale_term = snapshot
        .whale_score
        .checked_mul(weights.whale_score)
        .ok_or("overflow in whale_score term")?;

    let sum = vol_term
        .checked_add(inv_term)
        .ok_or("overflow in sum (vol+inv)")?
        .checked_add(oracle_term)
        .ok_or("overflow in sum (vol+inv+oracle)")?
        .checked_add(whale_term)
        .ok_or("overflow in sum (vol+inv+oracle+whale)")?;

    let mut risk = sum / SCALE;

    // P2: trade-size / liquidity pressure (U256: trade * SCALE can overflow u128).
    if liquidity > 0 {
        let raw = U256::from(trade_size) * U256::from(SCALE) / U256::from(liquidity);
        let raw: u128 = raw.try_into().unwrap_or(u128::MAX);
        let pressure = if raw > MAX_PRESSURE { MAX_PRESSURE } else { raw };
        risk = risk.saturating_add(pressure);
    }

    Ok(if risk > SCALE { SCALE } else { risk })
}

pub fn default_weights() -> SignalWeights {
    SignalWeights {
        volatility: 300_000_000_000_000_000,       // 0.3e18
        inventory_skew: 200_000_000_000_000_000,   // 0.2e18
        oracle_divergence: 200_000_000_000_000_000, // 0.2e18
        whale_score: 300_000_000_000_000_000,       // 0.3e18
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn zero_snapshot() -> SignalSnapshot {
        SignalSnapshot {
            volatility: 0,
            inventory_skew: 0,
            oracle_divergence: 0,
            whale_score: 0,
        }
    }

    #[test]
    fn test_stale_returns_max_fallback() {
        let snapshot = SignalSnapshot {
            volatility: 999_000_000_000_000_000,
            inventory_skew: 999_000_000_000_000_000,
            oracle_divergence: 999_000_000_000_000_000,
            whale_score: 999_000_000_000_000_000,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, true, 0, 0).unwrap();
        assert_eq!(result, STALE_FALLBACK_RISK);
        // P0: stale must escalate to MAX risk (old value was 0.5e18).
        assert_eq!(result, SCALE);
    }

    #[test]
    fn test_weighted_sum_all_zero_signals() {
        let weights = default_weights();
        let result = compute_weighted_risk(&zero_snapshot(), &weights, false, 0, 0).unwrap();
        assert_eq!(result, 0);
    }

    #[test]
    fn test_weighted_sum_matches_hand_calculation() {
        // volatility = 0.5e18, rest = 0, weights: vol=0.3e18
        // risk = (0.5e18 * 0.3e18 + 0 + 0 + 0) / 1e18 = 0.15e18
        let snapshot = SignalSnapshot {
            volatility: 500_000_000_000_000_000,
            inventory_skew: 0,
            oracle_divergence: 0,
            whale_score: 0,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, false, 0, 0).unwrap();
        assert_eq!(result, 150_000_000_000_000_000); // 0.15e18
    }

    #[test]
    fn test_weighted_sum_caps_at_scale() {
        // All signals at SCALE (1e18), weights sum to SCALE (1e18)
        // raw = 1e18; plus zero pressure → 1e18.
        let snapshot = SignalSnapshot {
            volatility: SCALE,
            inventory_skew: SCALE,
            oracle_divergence: SCALE,
            whale_score: SCALE,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, false, 0, 0).unwrap();
        assert_eq!(result, SCALE);
    }

    #[test]
    fn test_size_liquidity_pressure_added() {
        // All signals zero; tradeSize == liquidity → pressure = 1e18 → clamp 0.3e18.
        let weights = default_weights();
        let result = compute_weighted_risk(&zero_snapshot(), &weights, false, SCALE, SCALE).unwrap();
        assert_eq!(result, MAX_PRESSURE);
        assert_eq!(result, 300_000_000_000_000_000);
    }

    #[test]
    fn test_pressure_scales_below_cap() {
        // tradeSize = 0.25 × liquidity → pressure = 0.25e18 (below 0.3 cap).
        let weights = default_weights();
        let result =
            compute_weighted_risk(&zero_snapshot(), &weights, false, SCALE / 4, SCALE).unwrap();
        assert_eq!(result, SCALE / 4);
    }

    #[test]
    fn test_no_pressure_when_liquidity_zero() {
        let weights = default_weights();
        let result = compute_weighted_risk(&zero_snapshot(), &weights, false, SCALE, 0).unwrap();
        assert_eq!(result, 0);
    }

    #[test]
    fn test_pressure_and_signals_combine() {
        // vol 0.5e18 → 0.15e18 risk, plus pressure 0.25e18 → 0.40e18.
        let snapshot = SignalSnapshot {
            volatility: 500_000_000_000_000_000,
            inventory_skew: 0,
            oracle_divergence: 0,
            whale_score: 0,
        };
        let weights = default_weights();
        let result =
            compute_weighted_risk(&snapshot, &weights, false, SCALE / 4, SCALE).unwrap();
        assert_eq!(result, 400_000_000_000_000_000);
    }
}
