
// ──────────────────────── Constants ────────────────────────

pub const SCALE: u128 = 1_000_000_000_000_000_000; // 1e18
pub const ALPHA: u128 = 100_000_000_000_000_000; // 0.1e18 (slow variance EWMA)
pub const ONE_MINUS_ALPHA: u128 = SCALE - ALPHA; // 0.9e18
pub const ALPHA_FAST: u128 = 300_000_000_000_000_000; // 0.3e18 (fast return EWMA)

/// P1: per-observation return cap before it enters either EWMA.
pub const MAX_OBSERVATION_RETURN: u128 = 50_000_000_000_000_000; // 0.05e18

// ThresholdPolicy deployed defaults (from ThresholdPolicy.sol / Deploy.s.sol)
// Tier thresholds are analytics labels only — the fee itself is now quadratic (P1).
const TIER1_THRESHOLD: u128 = 200_000_000_000_000_000; // 0.2e18
const TIER2_THRESHOLD: u128 = 400_000_000_000_000_000; // 0.4e18
const TIER3_THRESHOLD: u128 = 600_000_000_000_000_000; // 0.6e18
const TIER4_THRESHOLD: u128 = 800_000_000_000_000_000; // 0.8e18

const TIER0_FEE: u32 = 3000; // base fee at risk = 0
const TIER4_FEE: u32 = 12000; // max fee at risk = 1e18

// P3: circuit-breaker band (ThresholdPolicy.sol defaults).
pub const HALT_THRESHOLD: u128 = 950_000_000_000_000_000; // 0.95e18
pub const UNPAUSE_BAND: u128 = 100_000_000_000_000_000; // 0.10e18 (unpause at <= 0.85e18)

// P2: direction-aware inventory adjustment (ThresholdPolicy.sol defaults).
const INVENTORY_SURCHARGE_FEE: u32 = 500; // +0.05% when the swap worsens the skew
const INVENTORY_DISCOUNT_FEE: u32 = 200; // -0.05% when the swap rebalances

// ──────────────────────── A) Return Calculation ────────────────────────

pub fn calculate_return(old_sqrt_price: u128, new_sqrt_price: u128) -> Result<u128, String> {
    if old_sqrt_price == 0 {
        return Err("Volatility__ZeroOldPrice".into());
    }

    let diff = if new_sqrt_price > old_sqrt_price {
        new_sqrt_price
            .checked_sub(old_sqrt_price)
            .ok_or("overflow in diff subtraction")?
    } else {
        old_sqrt_price
            .checked_sub(new_sqrt_price)
            .ok_or("overflow in diff subtraction")?
    };

    // Use U256 to avoid overflow: diff * SCALE can exceed u128 when
    // sqrt_price values are realistic (e.g. ~2^96 ≈ 7.9e28).
    let numerator = alloy::primitives::U256::from(diff)
        * alloy::primitives::U256::from(SCALE);

    let abs_return = numerator
        .checked_div(alloy::primitives::U256::from(old_sqrt_price))
        .ok_or("division by zero in return calculation")?;

    abs_return
        .try_into()
        .map_err(|_| "return overflows u128".into())
}

// ──────────────────────── B) EWMA Updates ────────────────────────

/// Legacy slow EWMA on raw returns (kept for API compatibility; the compute
/// pipeline now uses the variance channel below).
pub fn update_ewma(old_ewma: u128, current_return: u128) -> Result<u128, String> {
    ewma_step(ALPHA, ONE_MINUS_ALPHA, old_ewma, current_return)
}

/// P2: fast-horizon EWMA on |returns| (α = 0.3) — reacts within a few swaps.
pub fn update_ewma_fast(old_ewma: u128, current_return: u128) -> Result<u128, String> {
    ewma_step(ALPHA_FAST, SCALE - ALPHA_FAST, old_ewma, current_return)
}

/// P2: variance EWMA — newVar = α·r² + (1−α)·oldVar (all 1e18-scaled).
pub fn update_ewma_variance(old_variance: u128, current_return: u128) -> Result<u128, String> {
    let r2 = current_return
        .checked_mul(current_return)
        .ok_or("overflow in r * r")?
        / SCALE;
    ewma_step(ALPHA, ONE_MINUS_ALPHA, old_variance, r2)
}

fn ewma_step(alpha: u128, one_minus_alpha: u128, old: u128, input: u128) -> Result<u128, String> {
    let a = alpha.checked_mul(input).ok_or("overflow in alpha * input")?;
    let b = one_minus_alpha
        .checked_mul(old)
        .ok_or("overflow in (1-alpha) * old")?;
    let sum = a.checked_add(b).ok_or("overflow in EWMA sum")?;
    sum.checked_div(SCALE)
        .ok_or_else(|| "division by zero in EWMA update".to_string())
}

/// P1: clamp a single observation before it enters the EWMA.
pub fn clamp_return(abs_return: u128) -> u128 {
    if abs_return > MAX_OBSERVATION_RETURN {
        MAX_OBSERVATION_RETURN
    } else {
        abs_return
    }
}

/// Integer square root (Newton/Babylonian), matching Volatility.sol sqrt().
pub fn isqrt(x: u128) -> u128 {
    if x == 0 {
        return 0;
    }
    let mut z = (x.saturating_add(1)) / 2;
    let mut y = x;
    while z < y {
        y = z;
        z = (x / z + z) / 2;
    }
    y
}

/// P2: 1e18-scaled variance → 1e18-scaled standard deviation: sqrt(v · SCALE).
pub fn variance_to_volatility(variance: u128) -> u128 {
    isqrt(variance.saturating_mul(SCALE))
}

/// P1/P2 result of one volatility pipeline step.
pub struct VolUpdate {
    /// Published signal = max(slow std, fast EWMA), capped at SCALE.
    pub published: u128,
    pub fast: u128,
    pub variance: u128,
}

/// Full volatility pipeline mirroring Volatility.sol compute():
/// return → clamp (P1) → variance EWMA + √ (slow) → fast EWMA → publish max
/// (P2 momentum boost / anti-flicker). Returns `None` on the first-time
/// initialization branch (old price == 0).
pub fn compute_vol_update(
    old_fast: u128,
    old_variance: u128,
    old_sqrt_price: u128,
    new_sqrt_price: u128,
) -> Result<Option<VolUpdate>, String> {
    if old_sqrt_price == 0 {
        return Ok(None);
    }

    let ret = clamp_return(calculate_return(old_sqrt_price, new_sqrt_price)?);
    let variance = update_ewma_variance(old_variance, ret)?;
    let slow = variance_to_volatility(variance);
    let fast = update_ewma_fast(old_fast, ret)?;

    let mut published = if fast > slow { fast } else { slow };
    if published > SCALE {
        published = SCALE;
    }

    Ok(Some(VolUpdate {
        published,
        fast,
        variance,
    }))
}

// ──────────────────────── C) Threshold Fee ────────────────────────

/// P1: quadratic fee curve — fee = 3000 + (12000 - 3000) · risk² / 1e36.
/// Mirrors ThresholdPolicy.action(); no inventory adjustment here.
/// Risk is defensively capped at SCALE first (the hook always passes risk ≤ 1e18).
pub fn compute_fee_from_risk(risk_e18: u128) -> u32 {
    use alloy::primitives::U256;
    let r = U256::from(risk_e18.min(SCALE));
    let fee = U256::from(TIER0_FEE as u64)
        + U256::from((TIER4_FEE - TIER0_FEE) as u64) * r * r / (U256::from(SCALE) * U256::from(SCALE));
    let fee: u128 = fee.try_into().unwrap_or(u128::MAX);
    u32::try_from(fee).unwrap_or(u32::MAX)
}

/// P2: quadratic fee + direction-aware inventory surcharge/discount.
///
/// `net_flow > 0` means previous swaps skewed toward zeroForOne:
///   - zeroForOne swap deepens the skew → surcharge
///   - oneForZero swap rebalances it    → discount
/// Symmetric when `net_flow < 0`.
pub fn compute_fee_with_inventory(risk_e18: u128, zero_for_one: bool, net_flow: i128) -> u32 {
    let mut fee = compute_fee_from_risk(risk_e18);

    let worsens = (net_flow > 0 && zero_for_one) || (net_flow < 0 && !zero_for_one);
    let rebalances = (net_flow > 0 && !zero_for_one) || (net_flow < 0 && zero_for_one);
    if worsens {
        fee = fee.saturating_add(INVENTORY_SURCHARGE_FEE);
    } else if rebalances {
        // Mirrors Solidity: fee > discount ? fee - discount : tier0Fee
        // (the floor only applies when the discount alone exceeds the fee).
        fee = if fee > INVENTORY_DISCOUNT_FEE {
            fee - INVENTORY_DISCOUNT_FEE
        } else {
            TIER0_FEE
        };
    }

    let max_fee = TIER4_FEE + INVENTORY_SURCHARGE_FEE;
    if fee > max_fee {
        max_fee
    } else {
        fee
    }
}

/// Analytics tier label only (fee itself is continuous now).
pub fn tier_from_risk(risk_e18: u128) -> u8 {
    if risk_e18 < TIER1_THRESHOLD {
        0
    } else if risk_e18 < TIER2_THRESHOLD {
        1
    } else if risk_e18 < TIER3_THRESHOLD {
        2
    } else if risk_e18 < TIER4_THRESHOLD {
        3
    } else {
        4
    }
}

/// P3: pause-flag hysteresis (dead-band) — latch at >= HALT_THRESHOLD,
/// unlatch only at <= HALT_THRESHOLD - UNPAUSE_BAND (0.85e18).
pub fn update_pause_state(currently_paused: bool, risk_e18: u128) -> bool {
    if !currently_paused && risk_e18 >= HALT_THRESHOLD {
        true
    } else if currently_paused && risk_e18 <= HALT_THRESHOLD - UNPAUSE_BAND {
        false
    } else {
        currently_paused
    }
}

// ──────────────────────── Tests ────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── calculateReturn ──

    #[test]
    fn test_calculate_return_basic_increase() {
        // old=100, new=110: diff=10, result = 10 * 1e18 / 100 = 1e17
        let result = calculate_return(100, 110).unwrap();
        assert_eq!(result, 100_000_000_000_000_000); // 0.1e18
    }

    #[test]
    fn test_calculate_return_basic_decrease() {
        // old=110, new=100: diff=10, result = 10 * 1e18 / 110 = 90_909_090_909_090_909
        //
        // NOTE: This is NOT the same as the increase case because the Solidity
        // code divides by oldPrice, which differs (100 vs 110).
        let result = calculate_return(110, 100).unwrap();
        assert_eq!(result, 90_909_090_909_090_909); // 10e18 / 110
    }

    #[test]
    fn test_calculate_return_realistic_sqrt_prices_increase() {
        // Realistic sqrt_price_x96 values (~2^96 ≈ 7.9e28).
        // A 10% increase in sqrt_price (≈21% price increase):
        // old = 2^96, new = 2^96 * 11 / 10
        // diff = 2^96 / 10, return = diff * SCALE / old = SCALE / 10 = 0.1e18
        let s: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96
        let old = s;
        let new = s * 11 / 10;
        let result = calculate_return(old, new).unwrap();
        // Expected: (s/10) * 1e18 / s = 1e17 = 0.1e18
        // Actual may differ slightly due to integer truncation of s*11/10
        let expected = 100_000_000_000_000_000; // 0.1e18
        let tolerance = expected / 100; // 1%
        assert!(
            (result as i128 - expected as i128).unsigned_abs() < tolerance,
            "realistic increase: got {result}, expected ~{expected} (±{tolerance})"
        );
        println!("calculate_return({old}, {new}) = {result} ({:.6}e18)", result as f64 / 1e18);
    }

    #[test]
    fn test_calculate_return_realistic_sqrt_prices_decrease() {
        // A 10% decrease in sqrt_price:
        let s: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96
        let old = s * 11 / 10;
        let new = s;
        let result = calculate_return(old, new).unwrap();
        // diff = s*11/10 - s = s/10, return = (s/10) * 1e18 / (s*11/10) = 1e18/11 ≈ 9.09e16
        let expected = 90_909_909_090_909_090; // ~1e18/11
        let diff = if result > expected { result - expected } else { expected - result };
        assert!(
            diff < expected / 100,
            "realistic decrease: got {result}, expected ~{expected}"
        );
        println!("calculate_return({old}, {new}) = {result} ({:.6}e18)", result as f64 / 1e18);
    }

    #[test]
    fn test_calculate_return_realistic_sqrt_prices_large_move() {
        // A 50% increase in sqrt_price (≈125% price increase):
        let s: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96
        let old = s;
        let new = s * 3 / 2;
        let result = calculate_return(old, new).unwrap();
        // diff = s/2, return = (s/2) * 1e18 / s = 0.5e18
        let expected = 500_000_000_000_000_000; // 0.5e18
        let tolerance = expected / 100;
        assert!(
            (result as i128 - expected as i128).unsigned_abs() < tolerance,
            "realistic large move: got {result}, expected ~{expected} (±{tolerance})"
        );
        println!("calculate_return({old}, {new}) = {result} ({:.6}e18)", result as f64 / 1e18);
    }

    #[test]
    fn test_calculate_return_zero_old_price_returns_err() {
        let result = calculate_return(0, 100);
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Volatility__ZeroOldPrice");
    }

    // ── updateEwma ──

    #[test]
    fn test_update_ewma_first_observation() {
        // old_ewma=0, current_return=1e18:
        // result = (ALPHA * 1e18 + ONE_MINUS_ALPHA * 0) / SCALE
        //        = (1e17 * 1e18) / 1e18 = 1e17
        let result = update_ewma(0, 1_000_000_000_000_000_000).unwrap();
        assert_eq!(result, 100_000_000_000_000_000); // 0.1e18
    }

    #[test]
    fn test_update_ewma_converges_toward_constant_return() {
        // Feed the same return repeatedly; EWMA should converge to that value.
        //
        // Convergence rate is (1-α)^n = 0.9^n. After 500 iterations the residual
        // is ~1e-23 × currentReturn, which truncates to 0 in integer arithmetic.
        let current_return: u128 = 500_000_000_000_000_000; // 0.5e18
        let mut ewma: u128 = 0;

        for _ in 0..500 {
            ewma = update_ewma(ewma, current_return).unwrap();
        }

        // After 500 iterations with α=0.1, EWMA equals current_return exactly
        // (integer truncation means the residual rounds to 0).
        let tolerance: u128 = 100;
        let diff = if ewma > current_return {
            ewma - current_return
        } else {
            current_return - ewma
        };
        assert!(
            diff <= tolerance,
            "EWMA {ewma} did not converge to {current_return} (diff={diff})"
        );
    }

    // ── P1 clamp ──

    #[test]
    fn test_clamp_return_caps_at_five_percent() {
        assert_eq!(clamp_return(0), 0);
        assert_eq!(clamp_return(MAX_OBSERVATION_RETURN), MAX_OBSERVATION_RETURN);
        assert_eq!(clamp_return(1_000_000_000_000_000_000), MAX_OBSERVATION_RETURN); // 1e18 → 0.05e18
        assert_eq!(clamp_return(40_000_000_000_000_000), 40_000_000_000_000_000); // 0.04 unchanged
    }

    // ── P2 variance / momentum pipeline ──

    #[test]
    fn test_variance_to_volatility_roundtrip() {
        // variance of (0.05e18)^2 → vol = 0.05e18
        let r: u128 = MAX_OBSERVATION_RETURN;
        let var = (r * r) / SCALE;
        assert_eq!(variance_to_volatility(var), r);
    }

    #[test]
    fn test_isqrt_basics() {
        assert_eq!(isqrt(0), 0);
        assert_eq!(isqrt(1), 1);
        assert_eq!(isqrt(15), 3);
        assert_eq!(isqrt(16), 4);
        assert_eq!(isqrt(SCALE * SCALE), SCALE);
    }

    #[test]
    fn test_compute_vol_update_init_branch_returns_none() {
        assert!(compute_vol_update(0, 0, 0, 1000).unwrap().is_none());
    }

    #[test]
    fn test_compute_vol_update_clamps_huge_move() {
        // 100% sqrt-price move (1e9 → 2e9): raw return 1e18 clamped to 0.05e18.
        let update = compute_vol_update(0, 0, 1_000_000_000, 2_000_000_000)
            .unwrap()
            .unwrap();
        // fast = 0.3 * 0.05e18 = 0.015e18
        assert_eq!(update.fast, 15_000_000_000_000_000);
        // variance = 0.1 * (0.05e18)^2 / 1e18 = 2.5e14
        let expected_var: u128 = 250_000_000_000_000; // 2.5e14
        assert_eq!(update.variance, expected_var);
        // published = max(slow, fast); slow = sqrt(2.5e14 * 1e18) ≈ 1.58e16
        let slow = variance_to_volatility(expected_var);
        let expected = if update.fast > slow { update.fast } else { slow };
        assert_eq!(update.published, expected);
    }

    #[test]
    fn test_compute_vol_update_momentum_uses_fast_on_spike() {
        // Elevated slow channel, new +5% spike: published must equal fast.
        let old_var = (40_000_000_000_000_000u128 * 40_000_000_000_000_000) / SCALE;
        let update = compute_vol_update(40_000_000_000_000_000, old_var, 1_000_000_000, 1_050_000_000)
            .unwrap()
            .unwrap();
        // fast = 0.3*0.05e18 + 0.7*0.04e18 = 0.043e18
        assert_eq!(update.fast, 43_000_000_000_000_000);
        assert_eq!(update.published, update.fast, "spike must publish the fast reading");
    }

    #[test]
    fn test_compute_vol_update_holds_slow_when_calm() {
        // Zero return: fast decays to 0.7*old, slow holds ~old → published = slow.
        let old_fast = 40_000_000_000_000_000;
        let old_var = (old_fast * old_fast) / SCALE;
        let update = compute_vol_update(old_fast, old_var, 1_000_000_000, 1_000_000_000)
            .unwrap()
            .unwrap();
        let exp_fast = ((SCALE - ALPHA_FAST) * old_fast) / SCALE;
        assert_eq!(update.fast, exp_fast);
        assert!(update.published >= update.fast, "published holds the slow channel");
        assert!(update.published > update.fast, "slow dominates while calm (anti-flicker)");
    }

    // ── computeFeeFromRisk (P1 quadratic) ──

    #[test]
    fn test_compute_fee_quadratic_curve() {
        // risk = 0 → base fee
        assert_eq!(compute_fee_from_risk(0), 3000);
        // risk = 0.1e18 → 3000 + 9000 * 0.01 = 3090
        assert_eq!(compute_fee_from_risk(100_000_000_000_000_000), 3090);
        // risk = 0.2e18 → 3000 + 9000 * 0.04 = 3360
        assert_eq!(compute_fee_from_risk(200_000_000_000_000_000), 3360);
        // risk = 0.9e18 → 3000 + 9000 * 0.81 = 10290
        assert_eq!(compute_fee_from_risk(900_000_000_000_000_000), 10290);
        // risk = 1e18 → 12000 (tier4Fee)
        assert_eq!(compute_fee_from_risk(SCALE), 12000);
        // risk > SCALE still caps at 12000 (risk itself is capped at SCALE upstream)
        assert_eq!(compute_fee_from_risk(u128::MAX), 12000);
    }

    #[test]
    fn test_compute_fee_monotonic_in_risk() {
        let mut prev = 0u32;
        for step in 0..=10u128 {
            let risk = step * SCALE / 10;
            let fee = compute_fee_from_risk(risk);
            assert!(fee >= prev, "fee must never decrease as risk rises");
            prev = fee;
        }
    }

    // ── inventory adjustment (P2) ──

    #[test]
    fn test_fee_surcharge_when_worsening_skew() {
        // net_flow > 0, zeroForOne → +500
        let fee = compute_fee_with_inventory(100_000_000_000_000_000, true, 1_000_000_000_000_000_000);
        assert_eq!(fee, 3090 + 500);
    }

    #[test]
    fn test_fee_discount_when_rebalancing() {
        // net_flow > 0, oneForZero → -200
        let fee = compute_fee_with_inventory(100_000_000_000_000_000, false, 1_000_000_000_000_000_000);
        assert_eq!(fee, 3090 - 200);
    }

    #[test]
    fn test_fee_no_adjustment_when_balanced() {
        let fee = compute_fee_with_inventory(100_000_000_000_000_000, true, 0);
        assert_eq!(fee, 3090);
    }

    #[test]
    fn test_fee_capped_at_max_plus_surcharge() {
        let fee = compute_fee_with_inventory(SCALE, true, 1_000_000_000_000_000_000);
        assert_eq!(fee, 12000 + 500);
    }

    // ── pause hysteresis (P3) ──

    #[test]
    fn test_pause_latches_above_halt() {
        assert!(update_pause_state(false, HALT_THRESHOLD));
        assert!(update_pause_state(false, SCALE));
    }

    #[test]
    fn test_pause_stays_latched_inside_dead_band() {
        // Latched, risk drops to 0.90e18 (above 0.85e18 unpause line) → stays paused.
        assert!(update_pause_state(true, 900_000_000_000_000_000));
        assert!(update_pause_state(true, 860_000_000_000_000_000));
    }

    #[test]
    fn test_pause_unlatches_below_dead_band() {
        assert!(!update_pause_state(true, 850_000_000_000_000_000));
        assert!(!update_pause_state(true, 0));
    }

    #[test]
    fn test_no_pause_at_ordinary_risk() {
        assert!(!update_pause_state(false, 900_000_000_000_000_000));
        assert!(!update_pause_state(false, 0));
    }

    // ── tier labels ──

    #[test]
    fn test_tier_labels() {
        assert_eq!(tier_from_risk(0), 0);
        assert_eq!(tier_from_risk(199_000_000_000_000_000), 0);
        assert_eq!(tier_from_risk(200_000_000_000_000_000), 1);
        assert_eq!(tier_from_risk(400_000_000_000_000_000), 2);
        assert_eq!(tier_from_risk(600_000_000_000_000_000), 3);
        assert_eq!(tier_from_risk(800_000_000_000_000_000), 4);
        assert_eq!(tier_from_risk(SCALE), 4);
    }
}
