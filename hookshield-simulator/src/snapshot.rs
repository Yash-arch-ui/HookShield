use crate::inventory::{flow_to_skew, update_inventory_flow};
use crate::math::{compute_vol_update, SCALE};
use crate::risk::SignalSnapshot;
use crate::whale::compute_whale_impact;

/// Per-pool simulation state, mirrors what SignalState.sol / VolatilityStorage.sol
/// hold on-chain (P1 dust filter + P2 variance/momentum channels included).
pub struct SimulationState {
    pub last_sqrt_price_x96: u128,
    pub ewma_volatility: u128,
    pub ewma_volatility_fast: u128,
    pub ewma_variance: u128,
    pub net_flow: i128,
    /// P1: dust filter — trades below this size do not advance volatility state.
    pub min_observation_size: u128,
    // oracle_divergence omitted — depends on historical oracle price data
    // we don't have a clean source for; defaults to 0
}

/// Staged result of one swap: pre-swap snapshot + signed net flow (for the
/// direction-aware policy fee) plus the next state to commit only if the swap
/// is not blocked by the P3 circuit breaker.
pub struct PendingSwap {
    pub snapshot: SignalSnapshot,
    /// Pre-swap signed net flow — ThresholdPolicy compares it against the
    /// incoming swap's direction to apply surcharge/discount (P2).
    pub net_flow: i128,
    next_last_sqrt_price_x96: u128,
    next_ewma_volatility: u128,
    next_ewma_volatility_fast: u128,
    next_ewma_variance: u128,
    next_net_flow: i128,
}

impl SimulationState {
    pub fn new() -> Self {
        Self {
            last_sqrt_price_x96: 0,
            ewma_volatility: 0,
            ewma_volatility_fast: 0,
            ewma_variance: 0,
            net_flow: 0,
            min_observation_size: 0,
        }
    }

    /// Plan one historical swap WITHOUT mutating state — mirrors HookShieldHook's
    /// beforeSwap computation. Call `commit()` only if the swap is allowed
    /// (P3 circuit breaker not latched), matching on-chain revert semantics
    /// where a blocked swap leaves all state untouched.
    ///
    /// Returns the SignalSnapshot used for THIS swap's fee (volatility/inventory
    /// as they stood BEFORE this swap, plus the freshly computed whale score)
    /// together with the pre-swap signed net flow.
    pub fn plan_swap(
        &self,
        new_sqrt_price_x96: u128,
        liquidity: u128,
        amount_in: u128,
        zero_for_one: bool,
    ) -> Result<PendingSwap, String> {
        // 1. Whale impact uses CURRENT (pre-swap) price and liquidity — written
        //    in beforeSwap so THIS swap's fee reflects its own impact.
        //    M-4: pre-swap net_flow drives the direction adjustment (the hook
        //    reads it once in beforeSwap and passes it to whaleSignal.update).
        let whale_score = if self.last_sqrt_price_x96 == 0 {
            // First swap: no prior price — conservative SCALE fallback.
            if amount_in == 0 { 0 } else { SCALE }
        } else {
            compute_whale_impact(
                self.last_sqrt_price_x96,
                liquidity,
                amount_in,
                zero_for_one,
                self.net_flow,
            )?
        };

        // 2. Snapshot for THIS swap's fee — pre-swap volatility/inventory + whale.
        let snapshot = SignalSnapshot {
            volatility: self.ewma_volatility,
            inventory_skew: flow_to_skew(self.net_flow),
            oracle_divergence: 0, // not modeled yet
            whale_score,
            // H-2: the sim has no reporter feed (off-chain submissions), so the
            // reporter term contributes 0 — same as a pool with no reports.
            reporter_max_score: 0,
        };

        // 3. Stage next volatility state — P1 dust filter: trades below
        //    min_observation_size are not observations at all; state (including
        //    last price) does not advance, so the old reading ages out naturally.
        let is_observation = amount_in >= self.min_observation_size;
        let (next_vol, next_fast, next_var, next_last_sqrt) = if !is_observation {
            (
                self.ewma_volatility,
                self.ewma_volatility_fast,
                self.ewma_variance,
                self.last_sqrt_price_x96,
            )
        } else if let Some(update) =
            compute_vol_update(self.ewma_volatility_fast, self.ewma_variance, self.last_sqrt_price_x96, new_sqrt_price_x96)?
        {
            (update.published, update.fast, update.variance, new_sqrt_price_x96)
        } else {
            // First-time init branch (old price == 0): seed the price, vol stays 0.
            (0, 0, 0, new_sqrt_price_x96)
        };

        // Inventory updates regardless of the dust filter (it has no size filter
        // on-chain — only VolatilitySignal does). M-5: the flow step scales with
        // the trade size (afterSwap passes tradeSize to inventorySignal.update).
        let next_net_flow = update_inventory_flow(self.net_flow, zero_for_one, amount_in);

        Ok(PendingSwap {
            snapshot,
            net_flow: self.net_flow,
            next_last_sqrt_price_x96: next_last_sqrt,
            next_ewma_volatility: next_vol,
            next_ewma_volatility_fast: next_fast,
            next_ewma_variance: next_var,
            next_net_flow,
        })
    }

    /// Commit a planned swap's state — mirrors afterSwap running to completion.
    pub fn commit(&mut self, pending: PendingSwap) {
        self.last_sqrt_price_x96 = pending.next_last_sqrt_price_x96;
        self.ewma_volatility = pending.next_ewma_volatility;
        self.ewma_volatility_fast = pending.next_ewma_volatility_fast;
        self.ewma_variance = pending.next_ewma_variance;
        self.net_flow = pending.next_net_flow;
    }

    /// Convenience: plan + commit in one step (used by unit tests).
    /// Returns the snapshot used for the swap's fee.
    pub fn process_swap(
        &mut self,
        new_sqrt_price_x96: u128,
        liquidity: u128,
        amount_in: u128,
        zero_for_one: bool,
    ) -> Result<SignalSnapshot, String> {
        let pending =
            self.plan_swap(new_sqrt_price_x96, liquidity, amount_in, zero_for_one)?;
        let snapshot = pending.snapshot;
        self.commit(pending);
        Ok(snapshot)
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

        // M-5: each 1e6-sized swap moves flow by 1e6 (scaled by trade size);
        // 10 swaps accumulate to 1e7 — nowhere near the 10e18 cap.
        assert_eq!(state.net_flow, 10_000_000); // 10 * 1e6
    }

    #[test]
    fn test_reference_size_swap_moves_full_flow_step() {
        // M-5: a REFERENCE_SIZE (1e18) trade reproduces the legacy full step.
        let mut state = SimulationState::new();
        let _ = state.process_swap(1000, 500, 1_000_000_000_000_000_000, true).unwrap();
        assert_eq!(state.net_flow, 1_000_000_000_000_000_000); // 1e18
    }

    #[test]
    fn test_dust_trade_does_not_advance_volatility_state() {
        let mut state = SimulationState::new();
        state.min_observation_size = 1_000_000; // 1e6

        // Seed a real observation.
        let _ = state.process_swap(1000, 500, 2_000_000, true).unwrap();
        let price_before = state.last_sqrt_price_x96;
        let vol_before = state.ewma_volatility;

        // Dust trade: no state advance at all for the vol channel.
        let _ = state.process_swap(9999, 500, 999_999, true).unwrap();
        assert_eq!(state.last_sqrt_price_x96, price_before, "dust must not advance price");
        assert_eq!(state.ewma_volatility, vol_before, "dust must not change vol");
        // Inventory still updates (no dust filter on-chain for inventory).
        // M-5: flow steps scale with size → 2e6 + 999_999.
        assert_eq!(state.net_flow, 2_999_999);

        // At threshold: accepted.
        let _ = state.process_swap(7777, 500, 1_000_000, true).unwrap();
        assert_eq!(state.last_sqrt_price_x96, 7777, "observation at threshold accepted");
    }

    #[test]
    fn test_plan_commit_can_be_skipped() {
        // P3: a blocked swap must leave state untouched.
        let mut state = SimulationState::new();
        let _ = state.process_swap(1000, 500, 1_000_000, true).unwrap();
        let price_before = state.last_sqrt_price_x96;
        let flow_before = state.net_flow;

        let pending = state.plan_swap(5000, 500, 1_000_000, true).unwrap();
        // …swap blocked → do NOT commit…
        assert_eq!(state.last_sqrt_price_x96, price_before);
        assert_eq!(state.net_flow, flow_before);

        // Committing applies it.
        state.commit(pending);
        assert_eq!(state.last_sqrt_price_x96, 5000);
        // M-5: 1e6-sized trade → 1e6 flow step (scaled by trade size).
        assert_eq!(state.net_flow, flow_before + 1_000_000);
    }

    #[test]
    fn test_pending_exposes_pre_swap_net_flow_for_policy() {
        let mut state = SimulationState::new();
        let _ = state.process_swap(1000, 500, 1_000_000, true).unwrap();
        let pending = state.plan_swap(1100, 500, 1_000_000, false).unwrap();
        // Pre-swap flow reflects the FIRST swap (+1e6 under M-5 scaling),
        // not yet the second.
        assert_eq!(pending.net_flow, 1_000_000);
    }
}
