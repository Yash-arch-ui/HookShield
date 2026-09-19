use crate::inventory::{flow_to_skew, update_inventory_flow};
use crate::math::{calculate_return, update_ewma};
use crate::risk::SignalSnapshot;
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

#[cfg(test)]
mod tests {
    use super::*;

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
