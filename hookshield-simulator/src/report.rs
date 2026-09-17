use crate::simulator::SimulationResult;
use serde::Serialize;

#[derive(Serialize)]
pub struct ReportOutput{
    pub swap_count: u64,
    pub total_volume: u128,
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub lvr_reduction_percent: f64,
}

pub fn print_text_report(result: &SimulationResult) {
    println!("\n=== HookShield Historical Simulation ===");
    println!("Swaps replayed:        {}", result.swap_count);
    println!("Total volume:          {}", result.total_volume);
    println!("Static fee revenue:    {}", result.static_fee_revenue);
    println!("HookShield revenue:    {}", result.hookshield_revenue);
    println!("LVR reduction:         {:.2}%", result.lvr_reduction_percent);
    println!("========================================");
}

pub fn print_json_report(result: &SimulationResult) -> eyre::Result<()> {
    let output = ReportOutput {
        swap_count: result.swap_count,
        total_volume: result.total_volume,
        static_fee_revenue: result.static_fee_revenue,
        hookshield_revenue: result.hookshield_revenue,
        lvr_reduction_percent: result.lvr_reduction_percent,
    };

    let json_str = serde_json::to_string_pretty(&output)?;
    println!("{}", json_str);
    Ok(())
}
