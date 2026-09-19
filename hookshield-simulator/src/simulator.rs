use crate::fetcher::SwapEvent;
use crate::risk::{compute_weighted_risk, default_weights};
use crate::snapshot::SimulationState;

/// Simulation result summary.
pub struct SimulationResult {
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub total_volume: u128,
    pub swap_count: u64,
    pub lvr_reduction_percent: f64,
    /// Whale score (0..1e18) for each replayed swap, in event order.
    /// Swap 1 has no prior price, so it falls back to SCALE by design.
    pub whale_scores: Vec<u128>,
}

/// Replay historical swap events comparing static fee vs HookShield dynamic fee.
///
/// Uses the full multi-signal pipeline (volatility + inventory + whale via
/// WeightedRiskModel → ThresholdPolicy) for each swap.
pub fn simulate(events: &[SwapEvent], base_fee: u32) -> SimulationResult {
    let mut state = SimulationState::new();
    let weights = default_weights();

    let mut static_fee_revenue: u128 = 0;
    let mut hookshield_revenue: u128 = 0;
    let mut total_volume: u128 = 0;
    let mut whale_scores: Vec<u128> = Vec::with_capacity(events.len());

    for event in events {
        // STATIC PATH — always charge base_fee
        static_fee_revenue += event.amount_in * base_fee as u128 / 1_000_000;

        // HOOKSHIELD PATH
        if state.last_sqrt_price_x96 != 0 {
            // Build snapshot from current state (before updating)
            let snapshot = match state.process_swap(
                event.sqrt_price_x96_after,
                event.liquidity,
                event.amount_in,
                event.zero_for_one,
            ) {
                Ok(snap) => snap,
                Err(_) => {
                    // Fallback on error: charge base_fee
                    whale_scores.push(0);
                    hookshield_revenue += event.amount_in * base_fee as u128 / 1_000_000;
                    total_volume += event.amount_in;
                    continue;
                }
            };

            whale_scores.push(snapshot.whale_score);

            // WeightedRiskModel: compute risk from snapshot
            let risk_e18 = compute_weighted_risk(&snapshot, &weights, false)
                .unwrap_or(crate::risk::STALE_FALLBACK_RISK);

            // ThresholdPolicy: map risk to fee
            let risk_fee = crate::math::compute_fee_from_risk(risk_e18);
            hookshield_revenue += event.amount_in * risk_fee as u128 / 1_000_000;
        } else {
            // First swap: no prior price — charge base_fee
            // (still call process_swap to initialize state)
            let snap = state.process_swap(
                event.sqrt_price_x96_after,
                event.liquidity,
                event.amount_in,
                event.zero_for_one,
            );
            whale_scores.push(snap.map(|s| s.whale_score).unwrap_or(0));
            hookshield_revenue += event.amount_in * base_fee as u128 / 1_000_000;
        }

        total_volume += event.amount_in;
    }

    let swap_count = events.len() as u64;

    let lvr_reduction_percent = if static_fee_revenue > 0 {
        ((hookshield_revenue as f64 - static_fee_revenue as f64) / static_fee_revenue as f64)
            * 100.0
    } else {
        0.0
    };

    SimulationResult {
        static_fee_revenue,
        hookshield_revenue,
        total_volume,
        swap_count,
        lvr_reduction_percent,
        whale_scores,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::B256;

    fn make_event(sqrt_before: u128, sqrt_after: u128, liquidity: u128, amount_in: u128) -> SwapEvent {
        SwapEvent {
            pool_id: B256::ZERO,
            block_number: 0,
            sqrt_price_x96_before: sqrt_before,
            sqrt_price_x96_after: sqrt_after,
            liquidity,
            amount_in,
            zero_for_one: true,
            timestamp: 0,
        }
    }

    /// Events with liquidity=0 (the old hardcoded-fetcher behavior) — used to
    /// pin down the pre-fix pathology where whale_score stuck at SCALE.
    fn make_event_liq0(sqrt_before: u128, sqrt_after: u128, amount_in: u128) -> SwapEvent {
        make_event(sqrt_before, sqrt_after, 0, amount_in)
    }

    #[test]
    fn test_empty_events() {
        let result = simulate(&[], 3000);
        assert_eq!(result.static_fee_revenue, 0);
        assert_eq!(result.hookshield_revenue, 0);
        assert_eq!(result.total_volume, 0);
        assert_eq!(result.swap_count, 0);
        assert_eq!(result.lvr_reduction_percent, 0.0);
    }

    #[test]
    fn test_single_event_only_base_fee() {
        let events = vec![make_event(1000, 1100, 1_000_000_000, 1_000_000)];
        let result = simulate(&events, 3000);

        assert_eq!(result.static_fee_revenue, 3000);
        assert_eq!(result.hookshield_revenue, 3000);
        assert_eq!(result.total_volume, 1_000_000);
        assert_eq!(result.swap_count, 1);
        assert!((result.lvr_reduction_percent - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_two_events_hookshield_activated() {
        // With liquidity=0 (make_event_liq0), whale_score=SCALE on second swap
        // → risk exceeds threshold → hookshield_revenue > static_fee_revenue
        let events = vec![
            make_event_liq0(1000, 1000, 1_000_000),
            make_event_liq0(1000, 1000, 1_000_000),
        ];
        let result = simulate(&events, 3000);

        assert_eq!(result.static_fee_revenue, 6000);
        assert!(
            result.hookshield_revenue >= result.static_fee_revenue,
            "hookshield {} should be >= static {}",
            result.hookshield_revenue,
            result.static_fee_revenue
        );
        assert_eq!(result.total_volume, 2_000_000);
        assert_eq!(result.swap_count, 2);
    }

    #[test]
    fn test_high_volatility_increases_hookshield_fee() {
        let mut events = Vec::new();
        let mut price: u128 = 1000;
        for _ in 0..20 {
            let new_price = price * 3 / 2;
            events.push(make_event(price, new_price, 1_000_000_000_000, 10_000_000));
            price = new_price;
        }
        let result = simulate(&events, 3000);

        assert!(
            result.hookshield_revenue > result.static_fee_revenue,
            "hookshield {} should exceed static {} at high volatility",
            result.hookshield_revenue,
            result.static_fee_revenue
        );
        assert!(result.lvr_reduction_percent > 0.0);
    }

    #[test]
    fn test_low_volatility_hookshield_at_least_base_fee() {
        // With liquidity=0 (make_event_liq0), whale_score=SCALE raises risk above
        // threshold. HookShield charges >= BASE_FEE for each swap.
        let mut events = Vec::new();
        let mut price: u128 = 1_000_000;
        for _ in 0..10 {
            let new_price = price + 1;
            events.push(make_event_liq0(price, new_price, 1_000_000));
            price = new_price;
        }
        let result = simulate(&events, 3000);

        assert_eq!(result.static_fee_revenue, 30_000);
        assert!(
            result.hookshield_revenue >= result.static_fee_revenue,
            "hookshield {} should be >= static {}",
            result.hookshield_revenue,
            result.static_fee_revenue
        );
    }

    #[test]
    fn test_total_volume_accumulates() {
        let events = vec![
            make_event(100, 200, 1_000, 500),
            make_event(200, 300, 1_000, 700),
            make_event(300, 400, 1_000, 1200),
        ];
        let result = simulate(&events, 3000);
        assert_eq!(result.total_volume, 2400);
        assert_eq!(result.swap_count, 3);
    }

    #[test]
    fn test_lvr_reduction_positive_when_hookshield_earns_more() {
        // Use realistic sqrt_price_x96 values (around 2^96) so that
        // compute_whale_impact doesn't underflow to 0 in integer division.
        // Q96 = 2^96 ≈ 7.9e28, so sqrtP must be comparable.
        //
        // Amounts are 50% of liquidity so whale impact is significant enough
        // to push the combined risk above TIER1_THRESHOLD (0.2e18), triggering
        // a higher dynamic fee.
        let s: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96 (price ≈ 1)
        let liq: u128 = 1_000_000_000_000_000_000; // 1e18
        let amt: u128 = 500_000_000_000_000_000; // 5e17 (50% of liquidity)
        let events = vec![
            // price swings ±30-100% in sqrt_price (large moves)
            make_event(s, s * 14 / 10, liq, amt),
            make_event(s * 14 / 10, s * 7 / 10, liq, amt),
            make_event(s * 7 / 10, s * 2, liq, amt),
            make_event(s * 2, s * 12 / 10, liq, amt),
        ];
        let result = simulate(&events, 3000);

        assert!(
            result.hookshield_revenue > result.static_fee_revenue,
            "hookshield {} should exceed static {} with volatile prices",
            result.hookshield_revenue,
            result.static_fee_revenue
        );
        assert!(result.lvr_reduction_percent > 0.0);
    }

    #[test]
    fn test_fallback_to_base_fee_on_error() {
        let events = vec![
            make_event_liq0(1000, 0, 1_000_000),
            make_event_liq0(0, 1000, 1_000_000),
        ];
        let result = simulate(&events, 3000);

        assert_eq!(result.static_fee_revenue, 6000);
        assert_eq!(result.hookshield_revenue, 6000);
    }

    #[test]
    fn test_different_base_fee() {
        let events = vec![
            make_event(1000, 1100, 1_000_000_000, 1_000_000),
            make_event(1100, 1200, 1_000_000_000, 2_000_000),
        ];
        let result = simulate(&events, 5000);

        assert_eq!(result.static_fee_revenue, 15_000);
    }

    #[test]
    fn test_real_liquidity_reduces_whale_score() {
        let low_liq = 1_000_000_000_000_000_000; // 1e18
        let high_liq = 1_000_000_000_000_000_000_000; // 1000e18
        let amount = 1_000_000_000_000_000; // 0.001e18

        let events_low = vec![
            make_event(1000, 1000, low_liq, amount),
            make_event(1000, 1100, low_liq, amount),
        ];
        let events_high = vec![
            make_event(1000, 1000, high_liq, amount),
            make_event(1000, 1100, high_liq, amount),
        ];

        let result_low = simulate(&events_low, 3000);
        let result_high = simulate(&events_high, 3000);

        // Higher liquidity → lower whale impact → lower HookShield fee
        assert!(
            result_low.hookshield_revenue >= result_high.hookshield_revenue,
            "low liquidity ({}) should earn >= high liquidity ({})",
            result_low.hookshield_revenue,
            result_high.hookshield_revenue
        );
    }

    #[test]
    fn test_whale_scores_vary_with_real_liquidity_not_pinned_at_scale() {
        // Regression test for the liquidity=0 bug: with a fixed nonzero
        // liquidity, whale scores must vary with trade size instead of being
        // pinned at SCALE for every swap after the first.
        //
        // Uses realistic sqrt_price_x96 values (around 2^96) so that
        // compute_whale_impact doesn't underflow to 0 in integer division.
        let s: u128 = 79_228_162_514_264_337_593_543_950_336; // 2^96
        let liquidity = 1_000_000_000_000_000_000_000; // 1000e18
        let small = 1_000_000_000_000_000; // 0.001e18
        let large = 100_000_000_000_000_000_000; // 100e18

        let events = vec![
            make_event(s, s, liquidity, small), // first swap → SCALE fallback
            make_event(s, s, liquidity, small),
            make_event(s, s, liquidity, large),
        ];

        let result = simulate(&events, 3000);

        assert_eq!(result.whale_scores.len(), 3);
        assert_eq!(result.whale_scores[0], crate::math::SCALE); // first-swap fallback
        assert!(
            result.whale_scores[1] < crate::math::SCALE,
            "small trade should not pin whale score at SCALE"
        );
        assert!(
            result.whale_scores[2] > result.whale_scores[1],
            "larger trade should have higher whale score"
        );
    }
}
