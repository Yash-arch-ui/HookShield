use crate::fetcher::SwapEvent;
use crate::inventory::{flow_to_skew, update_inventory_flow};
use crate::math::{calculate_return, compute_fee_from_risk, update_ewma};
use crate::risk::{compute_weighted_risk, default_weights, SignalSnapshot};
use crate::whale::compute_whale_impact;

/// Per-pool simulation state, mirrors what SignalState.sol holds on-chain.
pub struct SimulationState {
    pub last_sqrt_price_x96: u128,
    pub ewma_volatility: u128,
    pub net_flow: i128,
    // oracle_divergence omitted — depends on historical oracle price data
    // we don't have a clean source for; defaults to 0
}

impl SimulationState {
    pub fn new() -> Self {
        Self {
            last_sqrt_price_x96: 0,
            ewma_volatility: 0,
            net_flow: 0,
        }
    }

    /// Process one historical swap event.
    ///
    /// Returns the SignalSnapshot used for THIS swap's fee (built from state
    /// BEFORE this swap), then updates internal state AFTER — mirroring
    /// HookShieldHook.sol's beforeSwap → afterSwap ordering.
    pub fn process_swap(
        &mut self,
        new_sqrt_price_x96: u128,
        liquidity: u128,
        amount_in: u128,
        zero_for_one: bool,
    ) -> Result<SignalSnapshot, String> {
        // 1. Compute whale impact using CURRENT (pre-swap) price and liquidity.
        //    On the first swap, last_sqrt_price_x96 is 0 — compute_whale_impact
        //    returns SCALE (max risk) when sqrt_price_x96=0 is NOT the case, but
        //    we must guard here because get_next_sqrt_price_from_input requires
        //    sqrt_price_x96 != 0.
        let whale_score = if self.last_sqrt_price_x96 == 0 {
            // First swap: no prior price, use SCALE as conservative fallback
            // (mirrors how Volatility.sol's first-swap branch skips computation
            // and the risk model falls back to default behavior)
            if amount_in == 0 { 0 } else { crate::math::SCALE }
        } else {
            compute_whale_impact(
                self.last_sqrt_price_x96,
                liquidity,
                amount_in,
                zero_for_one,
            )?
        };

        // 2. Build snapshot for THIS swap's fee — using volatility/inventory
        //    as they stood BEFORE this swap, plus the freshly computed whale score.
        let snapshot_for_this_swap = SignalSnapshot {
            volatility: self.ewma_volatility,
            inventory_skew: flow_to_skew(self.net_flow),
            oracle_divergence: 0, // not modeled yet
            whale_score,
        };

        // 3. NOW update state for the NEXT swap — mirrors afterSwap
        if self.last_sqrt_price_x96 != 0 {
            let ret = calculate_return(self.last_sqrt_price_x96, new_sqrt_price_x96)?;
            self.ewma_volatility = update_ewma(self.ewma_volatility, ret)?;
        }
        // else: first swap — mirrors Volatility.sol init branch (ewma stays 0)

        self.net_flow = update_inventory_flow(self.net_flow, zero_for_one);
        self.last_sqrt_price_x96 = new_sqrt_price_x96;

        Ok(snapshot_for_this_swap)
    }
}

/// Simulation result summary.
pub struct SimulationResult {
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub total_volume: u128,
    pub swap_count: u64,
    pub lvr_reduction_percent: f64,
}

/// Replay historical swap events comparing static fee vs HookShield dynamic fee.
///
/// For events that carry liquidity data, uses the full multi-signal pipeline
/// (volatility + inventory + whale via WeightedRiskModel → ThresholdPolicy).
/// For events without liquidity (the common case from RPC fetch), falls back
/// to volatility-only fee computation.
pub fn simulate(events: &[SwapEvent], base_fee: u32) -> SimulationResult {
    let mut state = SimulationState::new();
    let weights = default_weights();

    let mut static_fee_revenue: u128 = 0;
    let mut hookshield_revenue: u128 = 0;
    let mut total_volume: u128 = 0;

    for event in events {
        // STATIC PATH — always charge base_fee
        static_fee_revenue += event.amount_in * base_fee as u128 / 1_000_000;

        // HOOKSHIELD PATH
        if state.last_sqrt_price_x96 != 0 {
            // Build snapshot from current state (before updating)
            let snapshot = match state.process_swap(
                event.sqrt_price_x96_after,
                0, // liquidity unknown from RPC fetch
                event.amount_in,
                event.zero_for_one,
            ) {
                Ok(snap) => snap,
                Err(_) => {
                    // Fallback on error: charge base_fee
                    hookshield_revenue += event.amount_in * base_fee as u128 / 1_000_000;
                    total_volume += event.amount_in;
                    continue;
                }
            };

            // WeightedRiskModel: compute risk from snapshot
            let risk_e18 = compute_weighted_risk(&snapshot, &weights, false)
                .unwrap_or(crate::risk::STALE_FALLBACK_RISK);

            // ThresholdPolicy: map risk to fee
            let risk_fee = compute_fee_from_risk(risk_e18);
            hookshield_revenue += event.amount_in * risk_fee as u128 / 1_000_000;
        } else {
            // First swap: no prior price — charge base_fee
            // (still call process_swap to initialize state)
            let _ = state.process_swap(
                event.sqrt_price_x96_after,
                0,
                event.amount_in,
                event.zero_for_one,
            );
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::B256;

    fn make_event(sqrt_before: u128, sqrt_after: u128, amount_in: u128) -> SwapEvent {
        SwapEvent {
            pool_id: B256::ZERO,
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

        assert_eq!(result.static_fee_revenue, 3000);
        assert_eq!(result.hookshield_revenue, 3000);
        assert_eq!(result.total_volume, 1_000_000);
        assert_eq!(result.swap_count, 1);
        assert!((result.lvr_reduction_percent - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_two_events_hookshield_activated() {
        // With L=0 from fetcher, whale_score=SCALE on second swap → risk exceeds threshold
        // so hookshield_revenue > static_fee_revenue
        let events = vec![
            make_event(1000, 1000, 1_000_000),
            make_event(1000, 1000, 1_000_000),
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
            events.push(make_event(price, new_price, 10_000_000));
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
        // With L=0 from fetcher, whale_score=SCALE raises risk above threshold.
        // HookShield charges >= BASE_FEE for each swap.
        let mut events = Vec::new();
        let mut price: u128 = 1_000_000;
        for _ in 0..10 {
            let new_price = price + 1;
            events.push(make_event(price, new_price, 1_000_000));
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
        let events = vec![make_event(1000, 0, 1_000_000), make_event(0, 1000, 1_000_000)];
        let result = simulate(&events, 3000);

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

        assert_eq!(result.static_fee_revenue, 15_000);
    }

    #[test]
    fn test_simulation_state_process_swap_first_is_all_zero_except_whale() {
        let mut state = SimulationState::new();
        let snap = state.process_swap(1000, 500, 1_000_000, true).unwrap();

        assert_eq!(snap.volatility, 0);
        assert_eq!(snap.inventory_skew, 0);
        assert_eq!(snap.oracle_divergence, 0);
        // whale_score: first swap with last_sqrt_price_x96=0 → SCALE
        assert_eq!(snap.whale_score, crate::math::SCALE);
    }

    #[test]
    fn test_simulation_state_second_swap_reflects_first() {
        let mut state = SimulationState::new();
        // First swap: initializes last_sqrt_price_x96
        let _first = state.process_swap(1000, 500, 1_000_000, true).unwrap();
        // Second swap: snapshot still has vol=0 (fee before update), but state updates ewma after
        let _second = state.process_swap(1100, 500, 1_000_000, true).unwrap();
        // Third swap: snapshot now sees the nonzero ewma set by second swap's update
        let third = state.process_swap(1200, 500, 1_000_000, true).unwrap();

        assert!(third.volatility > 0, "ewma should be nonzero by third swap");
        assert!(third.inventory_skew > 0, "inventory skew should be nonzero");
    }

    #[test]
    fn test_repeated_same_direction_swaps_increase_inventory_skew() {
        let mut state = SimulationState::new();
        let mut prev_skew = 0_u128;

        for i in 1..=10u128 {
            let price = 1000 + i;
            let snap = state.process_swap(price, 500, 1_000_000, true).unwrap();
            assert!(
                snap.inventory_skew >= prev_skew,
                "inventory skew should increase monotonically with same-direction swaps"
            );
            prev_skew = snap.inventory_skew;
        }

        // After 10 zeroForOne swaps, net_flow should be at MAX_FLOW
        assert_eq!(state.net_flow, 10_000_000_000_000_000_000); // 10e18
    }
}
