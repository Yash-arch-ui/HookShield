use crate::math::SCALE;
use alloy::primitives::U256;

const Q96: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96
const Q96_U256: U256 = U256::from_limbs([0, 0x100000000, 0, 0]); // 2^96

/// Port of SqrtPriceMath.getNextSqrtPriceFromInput from v4-core.
///
/// Two branches:
///   - zeroForOne  (adding currency0 → price DECREASES):
///       result = ceil(L * sqrtP / (L + amount * sqrtP / Q96))
///   - !zeroForOne (adding currency1 → price INCREASES):
///       result = sqrtP + amount * Q96 / L
pub fn get_next_sqrt_price_from_input(
    sqrt_price_x96: u128,
    liquidity: u128,
    amount_in: u128,
    zero_for_one: bool,
) -> Result<u128, String> {
    if sqrt_price_x96 == 0 || liquidity == 0 {
        return Err("InvalidPriceOrLiquidity".into());
    }

    if zero_for_one {
        // Adding currency0 → price decreases.
        // result = ceil(L * sqrtP / (L + amount * sqrtP / Q96))
        // Use U256 to avoid overflow when L*sqrtP exceeds u128.
        let l = U256::from(liquidity);
        let sp = U256::from(sqrt_price_x96);
        let amt = U256::from(amount_in);

        let amount_times_sqrt_over_q96 = amt * sp / Q96_U256;
        let denominator = l + amount_times_sqrt_over_q96;

        if denominator.is_zero() {
            return Err("denominator underflow".into());
        }

        let numerator = l * sp;
        let result = (numerator + denominator - U256::from(1u128)) / denominator;

        result
            .try_into()
            .map_err(|_| "result overflows u128".into())
    } else {
        // Adding currency1 → price increases.
        // result = sqrtP + amount * Q96 / L
        let quotient = amount_in
            .checked_mul(Q96)
            .ok_or("overflow: amount * Q96")?
            / liquidity;

        sqrt_price_x96
            .checked_add(quotient)
            .ok_or_else(|| "overflow: sqrtP + quotient".to_string())
    }
}

/// Mirrors WhaleScoreSignal.sol's compute() — the ×2 linear approximation.
///
/// impact = |old_sqrt - new_sqrt| * 2 * SCALE / old_sqrt, capped at SCALE.
///
/// - liquidity == 0 → SCALE (max risk)
/// - amount_in == 0 → 0
pub fn compute_whale_impact(
    sqrt_price_x96: u128,
    liquidity: u128,
    amount_in: u128,
    zero_for_one: bool,
) -> Result<u128, String> {
    if liquidity == 0 {
        return Ok(SCALE);
    }
    if amount_in == 0 {
        return Ok(0);
    }

    let new_sqrt =
        get_next_sqrt_price_from_input(sqrt_price_x96, liquidity, amount_in, zero_for_one)?;

    let diff = if sqrt_price_x96 > new_sqrt {
        sqrt_price_x96 - new_sqrt
    } else {
        new_sqrt - sqrt_price_x96
    };

    // Use U256 to avoid overflow: diff * 2 * SCALE can exceed u128.
    // Cap inside U256 before narrowing — mirrors on-chain where the product is
    // computed in uint256 and only then clamped to SCALE.
    let impact_u256 = (U256::from(diff) * U256::from(2u128) * U256::from(SCALE)
        / U256::from(sqrt_price_x96))
        .min(U256::from(SCALE));

    Ok(impact_u256.to::<u128>())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SQRT_P_PRICE_1: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    #[test]
    fn test_zero_liquidity_returns_max_score() {
        let result = compute_whale_impact(SQRT_P_PRICE_1, 0, 100_000_000_000_000_000, true);
        assert_eq!(result.unwrap(), SCALE);
    }

    #[test]
    fn test_zero_amount_returns_zero() {
        let result =
            compute_whale_impact(SQRT_P_PRICE_1, 1_000_000_000_000_000_000_000, 0, true);
        assert_eq!(result.unwrap(), 0);
    }

    #[test]
    fn test_small_trade_low_impact() {
        let liquidity = 1_000_000_000_000_000_000_000; // 1000e18
        let amount_in = 100_000_000_000_000_000; // 0.1e18

        let impact = compute_whale_impact(SQRT_P_PRICE_1, liquidity, amount_in, true).unwrap();

        // Expected ≈ 0.0002e18
        let expected = 200_000_000_000_000_u128;
        let tolerance = expected / 100;
        assert!(
            (impact as i128 - expected as i128).unsigned_abs() < tolerance as u128,
            "impact {impact} too far from expected {expected}"
        );
    }

    #[test]
    fn test_large_trade_high_impact() {
        let liquidity = 1_000_000_000_000_000_000_000; // 1000e18
        let amount_in = 400_000_000_000_000_000_000; // 400e18

        let impact = compute_whale_impact(SQRT_P_PRICE_1, liquidity, amount_in, true).unwrap();

        // Expected ≈ 0.5714e18
        let expected = 571_428_571_428_571_428_u128;
        let tolerance = expected / 100;
        assert!(
            (impact as i128 - expected as i128).unsigned_abs() < tolerance as u128,
            "impact {impact} too far from expected {expected}"
        );
    }
}
