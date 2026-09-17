use alloy::primitives::{Address, I256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::Filter;
use alloy::sol;
use alloy::sol_types::SolEvent;
use eyre::{eyre, Result};

sol! {
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
}

#[derive(Debug, Clone)]
pub struct SwapEvent {
    pub pool_id: Address,
    pub block_number: u64,
    pub sqrt_price_x96_before: u128,
    pub sqrt_price_x96_after: u128,
    pub amount_in: u128,
    pub zero_for_one: bool,
    pub timestamp: u64,
}

pub async fn fetch_swap_events(
    rpc_url: &str,
    pool_address: Address,
    from_block: u64,
    to_block: u64,
) -> Result<Vec<SwapEvent>> {
    let url = rpc_url.parse()?;
    let provider = ProviderBuilder::new().connect_http(url);

    let filter = Filter::new()
        .address(pool_address)
        .from_block(from_block)
        .to_block(to_block)
        .event_signature(Swap::SIGNATURE_HASH);

    let logs = provider.get_logs(&filter).await?;

    let mut swap_events = Vec::new();
    let mut last_sqrt_price: u128 = 0;

    for log in logs {
        let block_number = log
            .block_number
            .ok_or_else(|| eyre!("Log is missing block number"))?;

        let decoded = log.log_decode::<Swap>()?;
        let swap_data = decoded.inner.data;

        let sqrt_price_after: u128 = swap_data.sqrtPriceX96.to::<u128>();
        let amount_0: I256 = swap_data.amount0;

        let zero_for_one = amount_0 > I256::ZERO;
        let amount_in: u128 = if zero_for_one {
            amount_0.unsigned_abs().to::<u128>()
        } else {
            swap_data.amount1.unsigned_abs().to::<u128>()
        };

        let sqrt_price_before = if last_sqrt_price == 0 {
            sqrt_price_after
        } else {
            last_sqrt_price
        };
        last_sqrt_price = sqrt_price_after;

        swap_events.push(SwapEvent {
            pool_id: pool_address,
            block_number,
            sqrt_price_x96_before: sqrt_price_before,
            sqrt_price_x96_after: sqrt_price_after,
            amount_in,
            zero_for_one,
            timestamp: 0,
        });
    }

    Ok(swap_events)
}
