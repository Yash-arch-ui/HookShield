use crate::fetcher::SwapEvent;
use crate::math::{calculate_return, compute_fee_from_risk, update_ewma};

pub struct VolatilityState {
    pub last_sqrt_price_x96: u128,
    pub ewma_volatility: u128,
}

pub struct SimulationResult {
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub total_volume: u128,
    pub swap_count: u64,
    pub lvr_reduction_percent: f64,
}

pub fn simulate(events: &[SwapEvent], base_fee: u32) -> SimulationResult {
    let mut state = VolatilityState {
        last_sqrt_price_x96: 0,
        ewma_volatility: 0,
    };

    let mut static_fee_revenue: u128 = 0;
    let mut hookshield_revenue: u128 = 0;
    let mut total_volume: u128 = 0;

    for event in events {
        // STATIC PATH — always charge base_fee
        static_fee_revenue += event.amount_in * base_fee as u128 / 1_000_000;

        // HOOKSHIELD PATH — first swap has no prior price, charge base_fee
        if state.last_sqrt_price_x96 != 0 {
            match calculate_return(state.last_sqrt_price_x96, event.sqrt_price_x96_after) {
                Ok(ret) => {
                    state.ewma_volatility = update_ewma(state.ewma_volatility, ret)
                        .unwrap_or(state.ewma_volatility);
                    let risk_fee = compute_fee_from_risk(state.ewma_volatility);
                    hookshield_revenue += event.amount_in * risk_fee as u128 / 1_000_000;
                }
                Err(_) => {
                    hookshield_revenue += event.amount_in * base_fee as u128 / 1_000_000;
                }
            }
        } else {
            hookshield_revenue += event.amount_in * base_fee as u128 / 1_000_000;
        }

        // Always update tracked price
        state.last_sqrt_price_x96 = event.sqrt_price_x96_after;

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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Address;

    fn make_event(sqrt_before: u128, sqrt_after: u128, amount_in: u128) -> SwapEvent {
        SwapEvent {
            pool_id: Address::ZERO,
            block_number: 0,
            sqrt_price_x96_before: sqrt_before,
            sqrt_price_x96_after: sqrt_after,
            amount_in,
            zero_for_one: true,
            timestamp: 0,
        }
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
        let events = vec![make_event(1000, 1100, 1_000_000)];
        let result = simulate(&events, 3000);

        // static: 1_000_000 * 3000 / 1_000_000 = 3000
        assert_eq!(result.static_fee_revenue, 3000);
        // First event has no prior price — HookShield falls back to base_fee
        assert_eq!(result.hookshield_revenue, 3000);
        assert_eq!(result.total_volume, 1_000_000);
        assert_eq!(result.swap_count, 1);
        // Both equal → 0% reduction
        assert!((result.lvr_reduction_percent - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_two_events_hookshield_activated() {
        // Two identical-price swaps → return = 0 → ewma = 0 → tier0 fee = 3000
        let events = vec![
            make_event(1000, 1000, 1_000_000),
            make_event(1000, 1000, 1_000_000),
        ];
        let result = simulate(&events, 3000);

        // static: 2 * (1_000_000 * 3000 / 1_000_000) = 6000
        assert_eq!(result.static_fee_revenue, 6000);
        // hookshield: event1 base_fee(3000) + event2 tier0(3000) = 6000
        assert_eq!(result.hookshield_revenue, 6000);
        assert_eq!(result.total_volume, 2_000_000);
        assert_eq!(result.swap_count, 2);
        assert!((result.lvr_reduction_percent - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_high_volatility_increases_hookshield_fee() {
        // Price jumps 50% → return ≈ 0.5e18 → ewma ≈ 0.05e18 → tier0 (3000)
        // After many 50% jumps, ewma converges to 0.5e18 → tier4 (12000)
        let mut events = Vec::new();
        let mut price: u128 = 1000;
        for _ in 0..20 {
            let new_price = price * 3 / 2; // 50% increase
            events.push(make_event(price, new_price, 10_000_000));
            price = new_price;
        }
        let result = simulate(&events, 3000);

        // HookShield should earn significantly more than static due to high volatility
        assert!(
            result.hookshield_revenue > result.static_fee_revenue,
            "hookshield {} should exceed static {} at high volatility",
            result.hookshield_revenue,
            result.static_fee_revenue
        );
        assert!(result.lvr_reduction_percent > 0.0);
    }

    #[test]
    fn test_low_volatility_hookshield_matches_base() {
        // Tiny price moves → return near 0 → ewma near 0 → tier0 = 3000 = base_fee
        let mut events = Vec::new();
        let mut price: u128 = 1_000_000;
        for _ in 0..10 {
            let new_price = price + 1; // negligible move
            events.push(make_event(price, new_price, 1_000_000));
            price = new_price;
        }
        let result = simulate(&events, 3000);

        // Both should charge ~3000 per swap after the first
        // First swap: both 3000. Remaining 9: static=27000, hookshield≈27000
        assert_eq!(result.static_fee_revenue, 30_000);
        assert_eq!(result.hookshield_revenue, 30_000);
    }

    #[test]
    fn test_total_volume_accumulates() {
        let events = vec![
            make_event(100, 200, 500),
            make_event(200, 300, 700),
            make_event(300, 400, 1200),
        ];
        let result = simulate(&events, 3000);
        assert_eq!(result.total_volume, 2400);
        assert_eq!(result.swap_count, 3);
    }

    #[test]
    fn test_lvr_reduction_positive_when_hookshield_earns_more() {
        // Big volatile moves so HookShield charges higher tiers
        let events = vec![
            make_event(1000, 2000, 10_000_000),
            make_event(2000, 1000, 10_000_000),
            make_event(1000, 3000, 10_000_000),
            make_event(3000, 1500, 10_000_000),
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
        // create an event where calculate_return would fail (old price = 0 on second event)
        // We simulate this by having state.last_sqrt_price_x96 = 0 after first event
        // which happens if first event's sqrt_price_x96_after == 0
        let events = vec![
            make_event(1000, 0, 1_000_000), // after=0, so state.last becomes 0
            make_event(0, 1000, 1_000_000), // calculate_return(0, 1000) → Err
        ];
        let result = simulate(&events, 3000);

        // First event: static=3000, hookshield=3000 (first swap, no prior price)
        // Second event: static=3000, hookshield fallback=3000 (calculate_return errors)
        assert_eq!(result.static_fee_revenue, 6000);
        assert_eq!(result.hookshield_revenue, 6000);
    }

    #[test]
    fn test_different_base_fee() {
        let events = vec![
            make_event(1000, 1100, 1_000_000),
            make_event(1100, 1200, 2_000_000),
        ];
        let result = simulate(&events, 5000);

        // static: (1M * 5000 / 1M) + (2M * 5000 / 1M) = 5000 + 10000 = 15000
        assert_eq!(result.static_fee_revenue, 15_000);
    }

    #[test]
    fn test_many_swaps_converge_to_higher_tier() {
        // Repeated 100% price jumps → return = 1e18 each time
        // EWMA should converge to 1e18 → tier4 (12000)
        let mut events = Vec::new();
        let mut price: u128 = 1000;
        for _ in 0..50 {
            let new_price = price * 2;
            events.push(make_event(price, new_price, 1_000_000));
            price = new_price;
        }
        let result = simulate(&events, 3000);

        // static: 50 * (1M * 3000 / 1M) = 150_000
        assert_eq!(result.static_fee_revenue, 150_000);
        // hookshield: first swap = 3000 base_fee, rest ramp through tiers as ewma converges
        assert_eq!(result.hookshield_revenue, 512_000);
        assert!(result.lvr_reduction_percent > 200.0);
    }
}
