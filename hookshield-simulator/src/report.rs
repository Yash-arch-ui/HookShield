use crate::simulator::SimulationResult;
use serde::Serialize;

#[derive(Serialize)]
pub struct ReportOutput {
    pub swap_count: u64,
    pub total_volume: u128,
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub lvr_reduction_percent: f64,
    /// Whale score (0..1e18) per swap as decimal strings (u128 exceeds f64 precision).
    pub whale_scores: Vec<String>,
}

/// Max rows shown in the per-swap text table before truncating to a summary.
const MAX_TABLE_ROWS: usize = 25;

fn format_e18(v: u128) -> String {
    if v >= crate::math::SCALE {
        let whole = v / crate::math::SCALE;
        let frac = v % crate::math::SCALE;
        format!("{whole}.{frac:018}")
    } else {
        format!("0.{v:018}")
    }
}

pub fn print_text_report(result: &SimulationResult) {
    println!("\n=== HookShield Historical Simulation ===");
    println!("Swaps replayed:        {}", result.swap_count);
    println!("Total volume:          {}", result.total_volume);
    println!("Static fee revenue:    {}", result.static_fee_revenue);
    println!("HookShield revenue:    {}", result.hookshield_revenue);
    println!("LVR reduction:         {:.2}%", result.lvr_reduction_percent);
    println!("========================================");

    // Per-swap whale score breakdown
    println!("\n--- Whale scores per swap (0..1e18) ---");
    println!("{:>6}  {:>24}  {}", "swap", "whale_score", "as 0..1");
    for (i, score) in result.whale_scores.iter().enumerate() {
        if i >= MAX_TABLE_ROWS {
            let remaining = result.whale_scores.len() - MAX_TABLE_ROWS;
            println!("  … {remaining} more swaps (use --format json for full output)");
            break;
        }
        println!("{:>6}  {:>24}  {}", i + 1, score, format_e18(*score));
    }
    if !result.whale_scores.is_empty() {
        let min = *result.whale_scores.iter().min().unwrap();
        let max = *result.whale_scores.iter().max().unwrap();
        let sum: u128 = result.whale_scores.iter().sum();
        let avg = sum / result.whale_scores.len() as u128;
        println!();
        println!("min: {}  max: {}  avg: {}", min, max, avg);
    }
}

pub fn print_json_report(result: &SimulationResult) -> eyre::Result<()> {
    let output = ReportOutput {
        swap_count: result.swap_count,
        total_volume: result.total_volume,
        static_fee_revenue: result.static_fee_revenue,
        hookshield_revenue: result.hookshield_revenue,
        lvr_reduction_percent: result.lvr_reduction_percent,
        whale_scores: result
            .whale_scores
            .iter()
            .map(|s| s.to_string())
            .collect(),
    };

    let json_str = serde_json::to_string_pretty(&output)?;
    println!("{}", json_str);
    Ok(())
}
