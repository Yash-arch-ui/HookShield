
// ──────────────────────── Constants ────────────────────────

pub const SCALE: u128 = 1_000_000_000_000_000_000; // 1e18
pub const ALPHA: u128 = 100_000_000_000_000_000; // 0.1e18
pub const ONE_MINUS_ALPHA: u128 = SCALE - ALPHA; // 0.9e18

// ThresholdPolicy deployed defaults (from ThresholdPolicy.sol / Deploy.s.sol)
const TIER1_THRESHOLD: u128 = 200_000_000_000_000_000; // 0.2e18
const TIER2_THRESHOLD: u128 = 400_000_000_000_000_000; // 0.4e18
const TIER3_THRESHOLD: u128 = 600_000_000_000_000_000; // 0.6e18
const TIER4_THRESHOLD: u128 = 800_000_000_000_000_000; // 0.8e18

const TIER0_FEE: u32 = 3000;
const TIER1_FEE: u32 = 4000;
const TIER2_FEE: u32 = 6000;
const TIER3_FEE: u32 = 9000;
const TIER4_FEE: u32 = 12000;

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

    let numerator = diff
        .checked_mul(SCALE)
        .ok_or("overflow in diff * SCALE")?;

    let abs_return = numerator
        .checked_div(old_sqrt_price)
        .ok_or("division by zero in return calculation")?;

    Ok(abs_return)
}

// ──────────────────────── B) EWMA Update ────────────────────────

pub fn update_ewma(old_ewma: u128, current_return: u128) -> Result<u128, String> {
    let alpha_times_return = ALPHA
        .checked_mul(current_return)
        .ok_or("overflow in ALPHA * currentReturn")?;

    let one_minus_alpha_times_ewma = ONE_MINUS_ALPHA
        .checked_mul(old_ewma)
        .ok_or("overflow in ONE_MINUS_ALPHA * oldEwma")?;

    let sum = alpha_times_return
        .checked_add(one_minus_alpha_times_ewma)
        .ok_or("overflow in EWMA sum")?;

    let new_ewma = sum
        .checked_div(SCALE)
        .ok_or("division by zero in EWMA update")?;

    Ok(new_ewma)
}

// ──────────────────────── C) Threshold Fee ────────────────────────

pub fn compute_fee_from_risk(risk_e18: u128) -> u32 {
    if risk_e18 < TIER1_THRESHOLD {
        TIER0_FEE
    } else if risk_e18 < TIER2_THRESHOLD {
        TIER1_FEE
    } else if risk_e18 < TIER3_THRESHOLD {
        TIER2_FEE
    } else if risk_e18 < TIER4_THRESHOLD {
        TIER3_FEE
    } else {
        TIER4_FEE
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

    // ── computeFeeFromRisk ──

    #[test]
    fn test_compute_fee_tier_boundaries() {
        // Below tier1 (< 0.2e18) → 3000
        assert_eq!(compute_fee_from_risk(0), TIER0_FEE);
        assert_eq!(compute_fee_from_risk(200_000_000_000_000_000 - 1), TIER0_FEE);

        // At tier1 (0.2e18) → 4000
        assert_eq!(compute_fee_from_risk(200_000_000_000_000_000), TIER1_FEE);

        // Below tier2 (< 0.4e18) → 4000
        assert_eq!(compute_fee_from_risk(400_000_000_000_000_000 - 1), TIER1_FEE);

        // At tier2 (0.4e18) → 6000
        assert_eq!(compute_fee_from_risk(400_000_000_000_000_000), TIER2_FEE);

        // Below tier3 (< 0.6e18) → 6000
        assert_eq!(compute_fee_from_risk(600_000_000_000_000_000 - 1), TIER2_FEE);

        // At tier3 (0.6e18) → 9000
        assert_eq!(compute_fee_from_risk(600_000_000_000_000_000), TIER3_FEE);

        // Below tier4 (< 0.8e18) → 9000
        assert_eq!(compute_fee_from_risk(800_000_000_000_000_000 - 1), TIER3_FEE);

        // At tier4 (0.8e18) → 12000
        assert_eq!(compute_fee_from_risk(800_000_000_000_000_000), TIER4_FEE);

        // Well above tier4 → 12000
        assert_eq!(compute_fee_from_risk(u128::MAX), TIER4_FEE);
    }
}
