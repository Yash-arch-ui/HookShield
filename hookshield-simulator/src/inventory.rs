use crate::math::SCALE;

/// From InventorySignal.sol:
///   int256 constant FLOW_STEP      = 1e18;
///   int256 constant MAX_FLOW       = 10e18;
///   int256 constant REFERENCE_SIZE = 1e18;  (M-5)
const FLOW_STEP: i128 = 1_000_000_000_000_000_000; // 1e18
const MAX_FLOW: i128 = 10_000_000_000_000_000_000; // 10e18
const REFERENCE_SIZE: i128 = 1_000_000_000_000_000_000; // 1e18

/// Updates the net flow counter, mirroring InventorySignal.sol update() (M-5):
/// the step scales with trade size — `FLOW_STEP * tradeSize / REFERENCE_SIZE`.
///
/// zeroForOne = true  → swapper paid currency0 → netFlow += step
/// zeroForOne = false → swapper paid currency1 → netFlow -= step
///
/// Result is clamped to [-MAX_FLOW, MAX_FLOW].
pub fn update_inventory_flow(net_flow: i128, zero_for_one: bool, trade_size: u128) -> i128 {
    let step = flow_step_for(trade_size);
    let delta = if zero_for_one { step } else { -step };
    let new_flow = net_flow.saturating_add(delta);
    new_flow.clamp(-MAX_FLOW, MAX_FLOW)
}

/// Mirrors InventorySignal.sol _stepFor():
/// tradeSize >= (MAX_FLOW / FLOW_STEP) * REFERENCE_SIZE (= 10e18) saturates at
/// MAX_FLOW (overflow guard); below that the step scales linearly.
fn flow_step_for(trade_size: u128) -> i128 {
    // (MAX_FLOW / FLOW_STEP) * REFERENCE_SIZE == 10e18
    if trade_size >= (MAX_FLOW / FLOW_STEP) as u128 * REFERENCE_SIZE as u128 {
        MAX_FLOW
    } else {
        // trade_size < 10e18 → FLOW_STEP * trade_size < 1e38, fits i128.
        (FLOW_STEP * trade_size as i128) / REFERENCE_SIZE
    }
}

/// Converts |net_flow| / MAX_FLOW to a 0..1e18 skew value.
///
/// From InventorySignal.sol:
///   absFlow = newFlow >= 0 ? uint256(newFlow) : uint256(-newFlow);
///   skewE18 = (absFlow * SCALE) / uint256(MAX_FLOW);
pub fn flow_to_skew(net_flow: i128) -> u128 {
    let abs_flow = net_flow.unsigned_abs() as u128;
    (abs_flow * SCALE) / (MAX_FLOW as u128)
}

#[cfg(test)]
mod tests {
    use super::*;

    const REF: u128 = 1_000_000_000_000_000_000; // 1e18 (reference size)

    #[test]
    fn test_zero_for_one_increases_flow() {
        let result = update_inventory_flow(0, true, REF);
        assert_eq!(result, FLOW_STEP);
    }

    #[test]
    fn test_one_for_zero_decreases_flow() {
        let result = update_inventory_flow(0, false, REF);
        assert_eq!(result, -FLOW_STEP);
    }

    #[test]
    fn test_reference_size_matches_legacy_step() {
        // M-5: REFERENCE_SIZE trades must reproduce the legacy full FLOW_STEP.
        let result = update_inventory_flow(0, true, REF);
        assert_eq!(result, FLOW_STEP);
    }

    #[test]
    fn test_half_size_scales_proportionally() {
        assert_eq!(update_inventory_flow(0, true, REF / 2), FLOW_STEP / 2);
    }

    #[test]
    fn test_tenth_size_scales_proportionally() {
        assert_eq!(update_inventory_flow(0, true, REF / 10), FLOW_STEP / 10);
    }

    #[test]
    fn test_small_trades_accumulate_to_same_as_one_large() {
        // 10 × 0.1 REF == 1 × REF (linear scaling).
        let mut flow = 0_i128;
        for _ in 0..10 {
            flow = update_inventory_flow(flow, true, REF / 10);
        }
        assert_eq!(flow, FLOW_STEP);
    }

    #[test]
    fn test_oversized_trade_saturates_in_one_step() {
        // tradeSize >= 10 * REFERENCE_SIZE hits the overflow guard → MAX_FLOW.
        assert_eq!(update_inventory_flow(0, true, 1000 * REF), MAX_FLOW);
        // A huge size must clamp, not overflow.
        assert_eq!(update_inventory_flow(0, true, u128::MAX), MAX_FLOW);
    }

    #[test]
    fn test_single_counter_trade_step_capped_at_max_flow() {
        // From 0, a 5×REF trade builds +5e18; one huge counter-swap then
        // swings by at most MAX_FLOW (its own step cap) to -5e18; a second
        // one reaches -MAX_FLOW.
        let flow = update_inventory_flow(0, true, REF * 5);
        assert_eq!(flow, 5_000_000_000_000_000_000);
        let flow = update_inventory_flow(flow, false, u128::MAX);
        assert_eq!(flow, -5_000_000_000_000_000_000);
        let flow = update_inventory_flow(flow, false, u128::MAX);
        assert_eq!(flow, -MAX_FLOW);
    }

    #[test]
    fn test_zero_size_trade_leaves_flow_unchanged() {
        let flow = update_inventory_flow(FLOW_STEP, true, 0);
        assert_eq!(flow, FLOW_STEP);
    }

    #[test]
    fn test_clamps_at_max_flow() {
        let result = update_inventory_flow(MAX_FLOW, true, REF);
        assert_eq!(result, MAX_FLOW);
    }

    #[test]
    fn test_clamps_at_negative_max_flow() {
        let result = update_inventory_flow(-MAX_FLOW, false, REF);
        assert_eq!(result, -MAX_FLOW);
    }

    #[test]
    fn test_flow_to_skew_zero() {
        assert_eq!(flow_to_skew(0), 0);
    }

    #[test]
    fn test_flow_to_skew_max() {
        assert_eq!(flow_to_skew(MAX_FLOW), SCALE);
    }

    #[test]
    fn test_flow_to_skew_half() {
        let half_flow = MAX_FLOW / 2;
        let expected = SCALE / 2;
        assert_eq!(flow_to_skew(half_flow), expected);
    }

    #[test]
    fn test_repeated_same_direction_increases_skew() {
        let mut flow = 0_i128;
        for _ in 0..10 {
            flow = update_inventory_flow(flow, true, REF);
        }
        assert_eq!(flow, MAX_FLOW);
        assert_eq!(flow_to_skew(flow), SCALE);
    }

    #[test]
    fn test_opposite_directions_cancel() {
        let flow = update_inventory_flow(update_inventory_flow(0, true, REF), false, REF);
        assert_eq!(flow, 0);
    }
}
