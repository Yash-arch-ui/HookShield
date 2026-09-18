use crate::math::SCALE;

/// From InventorySignal.sol:
///   int256 constant FLOW_STEP = 1e18;
///   int256 constant MAX_FLOW  = 10e18;
const FLOW_STEP: i128 = 1_000_000_000_000_000_000; // 1e18
const MAX_FLOW: i128 = 10_000_000_000_000_000_000; // 10e18

/// Updates the net flow counter, mirroring InventorySignal.sol update().
///
/// zeroForOne = true  → swapper paid currency0 → netFlow += FLOW_STEP
/// zeroForOne = false → swapper paid currency1 → netFlow -= FLOW_STEP
///
/// Result is clamped to [-MAX_FLOW, MAX_FLOW].
pub fn update_inventory_flow(net_flow: i128, zero_for_one: bool) -> i128 {
    let delta = if zero_for_one { FLOW_STEP } else { -FLOW_STEP };
    let new_flow = net_flow.saturating_add(delta);
    new_flow.clamp(-MAX_FLOW, MAX_FLOW)
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

    #[test]
    fn test_zero_for_one_increases_flow() {
        let result = update_inventory_flow(0, true);
        assert_eq!(result, FLOW_STEP);
    }

    #[test]
    fn test_one_for_zero_decreases_flow() {
        let result = update_inventory_flow(0, false);
        assert_eq!(result, -FLOW_STEP);
    }

    #[test]
    fn test_clamps_at_max_flow() {
        let result = update_inventory_flow(MAX_FLOW, true);
        assert_eq!(result, MAX_FLOW);
    }

    #[test]
    fn test_clamps_at_negative_max_flow() {
        let result = update_inventory_flow(-MAX_FLOW, false);
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
            flow = update_inventory_flow(flow, true);
        }
        assert_eq!(flow, MAX_FLOW);
        assert_eq!(flow_to_skew(flow), SCALE);
    }

    #[test]
    fn test_opposite_directions_cancel() {
        let flow = update_inventory_flow(update_inventory_flow(0, true), false);
        assert_eq!(flow, 0);
    }
}
