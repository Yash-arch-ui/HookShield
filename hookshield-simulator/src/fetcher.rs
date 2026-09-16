use alloy::primitives::Address;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::Filter;
use alloy::sol;
use eyre::{eyre, Result};

// Define the Swap event signature matching standard pool swaps
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

/// Fetches and decodes swap events for a given pool and block range using Alloy.
pub async fn fetch_swap_events(
    rpc_url: &str,
    pool_address: Address,
    from_block: u64,
    to_block: u64,
) -> Result<Vec<SwapEvent>> {
    // 1. Create an alloy Provider from rpc_url
    let url = rpc_url.parse()?;
    let provider = ProviderBuilder::new().on_http(url);

    // 2. Build a Filter for the Swap event signature, address = pool_address, block range = from_block..=to_block
    let filter = Filter::new()
        .address(pool_address)
        .from_block(from_block)
        .to_block(to_block)
        .event_signature(Swap::SIGNATURE_HASH);

    // 3. Call provider.get_logs(&filter).await
    let logs = provider.get_logs(&filter).await?;

    let mut swap_events = Vec::new();
    let mut last_sqrt_price: u128 = 0;

    // 4. For each log, decode it into your SwapEvent struct
    for log in logs {
        let block_number = log
            .block_number
            .ok_or_else(|| eyre!("Log is missing block number"))?;

        // Decode raw log topics and data via the generated sol! macro
        let decoded = log.topics_and_data::<Swap>()?;
        let swap_data = decoded.inner;

        let sqrt_price_after = swap_data.sqrtPriceX96;
        let amount_0 = swap_data.amount0;

        // Determine trade direction and input amount
        let zero_for_one = amount_0 > 0;
        let amount_in = if zero_for_one {
            amount_0.unsigned_abs()
        } else {
            swap_data.amount1.unsigned_abs()
        };

        // Track price sequence state
        let sqrt_price_before = if last_sqrt_price == 0 {
            sqrt_price_after
        } else {
            last_sqrt_price
        };
        last_sqrt_price = sqrt_price_after;

        // Construct and push the decoded event
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

    // 5. Return the Vec<SwapEvent>
    Ok(swap_events)
}                                                                                                                 