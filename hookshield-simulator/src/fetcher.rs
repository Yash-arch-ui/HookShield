use alloy::primitives::{Address, B256};
use alloy::rpc::types::Log;
use alloy::sol;
use alloy::sol_types::SolEvent;
use eyre::{eyre, Result};

/// Maximum block range per `eth_getLogs` call.
/// Alchemy's free tier limits this to 10; adjust for providers with higher limits.
const MAX_BLOCK_RANGE: u64 = 10;

sol! {
    event Swap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );
}

#[derive(Debug, Clone)]
pub struct SwapEvent {
    pub pool_id: B256,
    pub block_number: u64,
    /// Approximation: uses the previous swap's ending sqrtPriceX96.
    /// This is acceptable because in V4, only Swap events change pool price —
    /// no other operation (modifyLiquidity, donate, etc.) modifies sqrtPriceX96
    /// between swaps, so the previous swap's ending price equals this swap's
    /// starting price. There is no historical getSlot0 RPC available.
    pub sqrt_price_x96_before: u128,
    pub sqrt_price_x96_after: u128,
    pub liquidity: u128,
    pub amount_in: u128,
    pub zero_for_one: bool,
    pub timestamp: u64,
}

/// Fetches and decodes V4 Swap events from the PoolManager contract.
///
/// In Uniswap V4, all Swap events are emitted by the PoolManager (not the hook
/// or pool contract). Pools are identified by a `PoolId` (bytes32 hash of PoolKey),
/// which is the first indexed topic in the event.
///
/// Internally paginates `eth_getLogs` calls in chunks of at most `MAX_BLOCK_RANGE`
/// blocks to stay within provider rate limits (e.g. Alchemy free tier = 10 blocks).
///
/// `zero_for_one` convention (V4): amount0 > 0 means the pool's currency0 balance
/// increased, meaning the swapper paid currency0 (zero_for_one = true).
pub async fn fetch_swap_events(
    rpc_url: &str,
    pool_manager: Address,
    pool_id: B256,
    from_block: u64,
    to_block: u64,
) -> Result<Vec<SwapEvent>> {
    // Use lowercase hex for address. Some RPC providers (e.g. Alchemy free tier)
    // compare address fields case-sensitively even though JSON-RPC spec says
    // case-insensitive.
    let pm_lower = format!("0x{:x}", pool_manager);
    let pool_id_hex = format!("0x{:x}", pool_id);
    let swap_sig = format!("0x{:x}", Swap::SIGNATURE_HASH);

    // Paginate eth_getLogs in chunks of MAX_BLOCK_RANGE blocks.
    let mut all_logs: Vec<Log> = Vec::new();
    let mut chunk_start = from_block;

    let http_client = reqwest::Client::new();

    while chunk_start <= to_block {
        let chunk_end = (chunk_start + MAX_BLOCK_RANGE - 1).min(to_block);

        let body = serde_json::json!({
            "jsonrpc": "2.0",
            "id": chunk_start,
            "method": "eth_getLogs",
            "params": [{
                "address": pm_lower,
                "fromBlock": format!("0x{:x}", chunk_start),
                "toBlock": format!("0x{:x}", chunk_end),
                "topics": [swap_sig, pool_id_hex]
            }]
        });

        let resp = http_client
            .post(rpc_url)
            .json(&body)
            .send()
            .await
            .map_err(|e| eyre!("HTTP error: {e}"))?;

        let json: serde_json::Value = resp
            .json()
            .await
            .map_err(|e| eyre!("JSON parse error: {e}"))?;

        if let Some(err) = json.get("error") {
            return Err(eyre!("eth_getLogs RPC error: {}", err));
        }

        let logs_value = json
            .get("result")
            .ok_or_else(|| eyre!("missing result in RPC response"))?;

        let logs: Vec<Log> = serde_json::from_value(logs_value.clone())
            .map_err(|e| eyre!("failed to deserialize logs: {e}"))?;
        let n = logs.len();
        println!(
            "Fetching blocks {} to {}... found {} events",
            chunk_start, chunk_end, n
        );
        all_logs.extend(logs);

        chunk_start = chunk_end + 1;
    }

    // Decode all collected logs into SwapEvents, maintaining chronological order
    // (logs within each chunk are already ordered by block; chunks are fetched
    // sequentially so concatenation preserves global order).
    let mut swap_events = Vec::new();
    let mut last_sqrt_price: u128 = 0;

    for log in all_logs {
        let block_number = log
            .block_number
            .ok_or_else(|| eyre!("Log is missing block number"))?;

        let decoded = log.log_decode::<Swap>()?;
        let swap_data = decoded.inner.data;

        let pool_id_topic = B256::from(log.topics()[1]);
        let sqrt_price_after: u128 = swap_data.sqrtPriceX96.to::<u128>();
        let liquidity: u128 = swap_data.liquidity;
        let amount_0: i128 = swap_data.amount0;
        let amount_1: i128 = swap_data.amount1;

        // V4 convention: amount0 > 0 means pool received currency0 = swapper paid currency0
        let zero_for_one = amount_0 > 0;
        let amount_in: u128 = if zero_for_one {
            amount_0.unsigned_abs() as u128
        } else {
            amount_1.unsigned_abs() as u128
        };

        let sqrt_price_before = if last_sqrt_price == 0 {
            sqrt_price_after
        } else {
            last_sqrt_price
        };
        last_sqrt_price = sqrt_price_after;

        swap_events.push(SwapEvent {
            pool_id: pool_id_topic,
            block_number,
            sqrt_price_x96_before: sqrt_price_before,
            sqrt_price_x96_after: sqrt_price_after,
            liquidity,
            amount_in,
            zero_for_one,
            timestamp: 0,
        });
    }

    Ok(swap_events)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::Address;

    const SEPOLIA_RPC: &str = "https://eth-sepolia.g.alchemy.com/v2/dSuXV1Qk6XnHZXF1AgkGr";

    fn compute_pool_id() -> B256 {
        use alloy::primitives::keccak256;
        let currency0 = Address::from([0x0b, 0xA9, 0x07, 0x3a, 0xf8, 0xA7, 0x2c, 0x07, 0x34, 0x33, 0x9c, 0x35, 0x03, 0xA3, 0x9e, 0xF1, 0x1f, 0x2b, 0xcf, 0x95]);
        let currency1 = Address::from([0x0f, 0xaf, 0x34, 0x8f, 0x03, 0xE4, 0xD5, 0xA3, 0xc3, 0x94, 0xf3, 0x89, 0xDE, 0x52, 0x48, 0xaE, 0xfF, 0x15, 0x27, 0x91]);
        let fee: u32 = 0x800000;
        let tick_spacing: i32 = 60;
        let hooks = Address::from([0x5F, 0xC0, 0x56, 0x55, 0x2C, 0xC1, 0xd8, 0xAb, 0xfe, 0x66, 0x03, 0xF3, 0xBe, 0x87, 0x6D, 0xF3, 0x6f, 0x3c, 0x00, 0xC0]);

        let encoded = alloy::sol_types::SolValue::abi_encode_params(
            &(currency0, currency1, fee, tick_spacing, hooks),
        );
        keccak256(&encoded)
    }

    #[test]
    fn print_computed_pool_id() {
        let pool_id = compute_pool_id();
        println!("Computed poolId: {pool_id}");
    }

    #[tokio::test]
    #[ignore]
    async fn test_fetch_real_v4_swap_events_from_sepolia() {
        let pool_manager = Address::from([0xCf, 0x5e, 0xC7, 0x91, 0x1E, 0xbE, 0xEc, 0xfE, 0x45, 0x37, 0x30, 0x86, 0xd6, 0xf5, 0x08, 0x0B, 0xB8, 0x86, 0x3a, 0x08]);
        let pool_id: B256 = "0x6fdad50feaafa2da44051018a33cc24590522b425c318d16d12a774349599cc0".parse().unwrap();

        let events = fetch_swap_events(
            SEPOLIA_RPC,
            pool_manager,
            pool_id,
            11373490,
            11373503,
        )
        .await
        .expect("fetch should succeed");

        assert!(!events.is_empty(), "expected at least 1 real V4 Swap event");

        let first = &events[0];
        assert_eq!(first.pool_id, pool_id, "pool_id should match expected");
        assert!(first.sqrt_price_x96_after > 0, "sqrtPriceX96 should be nonzero");
        assert!(first.amount_in > 0, "amount_in should be nonzero");
        assert!(first.block_number > 0, "block_number should be nonzero");

        println!("Fetched {} events", events.len());
        println!("First event: {:?}", first);
    }
}
