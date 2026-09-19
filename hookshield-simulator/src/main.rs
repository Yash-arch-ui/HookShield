mod fetcher;
mod inventory;
mod math;
mod report;
mod risk;
mod snapshot;
mod simulator;
mod whale;

use alloy::primitives::{Address, B256};
use clap::Parser;
use std::str::FromStr;

#[derive(Parser)]
#[command(name = "hookshield-simulator", about = "HookShield historical swap simulator")]
struct Args {
    #[arg(long)]
    rpc_url: String,

    #[arg(long, help = "PoolManager contract address")]
    pool_manager: String,

    #[arg(long, help = "PoolId as hex (bytes32)")]
    pool_id: String,

    #[arg(long)]
    from_block: u64,

    #[arg(long)]
    to_block: u64,

    #[arg(long, default_value = "3000")]
    base_fee: u32,

    #[arg(long, default_value = "text")]
    format: String,
}

#[tokio::main]
async fn main() -> eyre::Result<()> {
    let args = Args::parse();

    let pool_manager =
        Address::from_str(&args.pool_manager).map_err(|e| eyre::eyre!("invalid pool_manager: {e}"))?;

    let pool_id =
        B256::from_str(&args.pool_id).map_err(|e| eyre::eyre!("invalid pool_id: {e}"))?;

    let events = fetcher::fetch_swap_events(
        &args.rpc_url,
        pool_manager,
        pool_id,
        args.from_block,
        args.to_block,
    )
    .await?;

    println!("Fetched {} swap events", events.len());

    let result = simulator::simulate(&events, args.base_fee);

    match args.format.as_str() {
        "json" => report::print_json_report(&result)?,
        _ => report::print_text_report(&result),
    }

    Ok(())
}
