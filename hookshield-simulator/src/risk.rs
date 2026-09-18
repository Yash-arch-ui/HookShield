use crate::math::SCALE;

pub const STALE_FALLBACK_RISK: u128 = 500_000_000_000_000_000; // 0.5e18

pub struct SignalWeights {
    pub volatility: u128,
    pub inventory_skew: u128,
    pub oracle_divergence: u128,
    pub whale_score: u128,
}

pub struct SignalSnapshot {
    pub volatility: u128,
    pub inventory_skew: u128,
    pub oracle_divergence: u128,
    pub whale_score: u128,
}

pub fn compute_weighted_risk(
    snapshot: &SignalSnapshot,
    weights: &SignalWeights,
    is_stale: bool,
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

    let risk = sum / SCALE;

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

    #[test]
    fn test_stale_returns_fallback() {
        let snapshot = SignalSnapshot {
            volatility: 999_000_000_000_000_000,
            inventory_skew: 999_000_000_000_000_000,
            oracle_divergence: 999_000_000_000_000_000,
            whale_score: 999_000_000_000_000_000,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, true).unwrap();
        assert_eq!(result, STALE_FALLBACK_RISK);
    }

    #[test]
    fn test_weighted_sum_all_zero_signals() {
        let snapshot = SignalSnapshot {
            volatility: 0,
            inventory_skew: 0,
            oracle_divergence: 0,
            whale_score: 0,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, false).unwrap();
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
        let result = compute_weighted_risk(&snapshot, &weights, false).unwrap();
        assert_eq!(result, 150_000_000_000_000_000); // 0.15e18
    }

    #[test]
    fn test_weighted_sum_caps_at_scale() {
        // All signals at SCALE (1e18), weights sum to SCALE (1e18)
        // raw = (1e18 * 0.3e18 + 1e18 * 0.2e18 + 1e18 * 0.2e18 + 1e18 * 0.3e18) / 1e18
        //      = (0.3e36 + 0.2e36 + 0.2e36 + 0.3e36) / 1e18
        //      = 1e36 / 1e18 = 1e18 = SCALE
        let snapshot = SignalSnapshot {
            volatility: SCALE,
            inventory_skew: SCALE,
            oracle_divergence: SCALE,
            whale_score: SCALE,
        };
        let weights = default_weights();
        let result = compute_weighted_risk(&snapshot, &weights, false).unwrap();
        assert_eq!(result, SCALE);
    }
}
