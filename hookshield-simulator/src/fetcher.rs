use alloy::primitives::{Address, B256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::Filter;
use alloy::sol;
use alloy::sol_types::SolEvent;
use eyre::{eyre, Result};

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
/// `zero_for_one` convention (V4): amount0 > 0 means the pool's currency0 balance
/// increased, meaning the swapper paid currency0 (zero_for_one = true).
pub async fn fetch_swap_events(
    rpc_url: &str,
    pool_manager: Address,
    pool_id: B256,
    from_block: u64,
    to_block: u64,
) -> Result<Vec<SwapEvent>> {
    let url = rpc_url.parse()?;
    let provider = ProviderBuilder::new().connect_http(url);

    let filter = Filter::new()
        .address(pool_manager)
        .from_block(from_block)
        .to_block(to_block)
        .event_signature(Swap::SIGNATURE_HASH)
        .topic1(pool_id);

    let logs = provider.get_logs(&filter).await?;

    let mut swap_events = Vec::new();
    let mut last_sqrt_price: u128 = 0;

    for log in logs {
        let block_number = log
            .block_number
            .ok_or_else(|| eyre!("Log is missing block number"))?;

        let decoded = log.log_decode::<Swap>()?;
        let swap_data = decoded.inner.data;

        let pool_id_topic = B256::from(log.topics()[1]);
        let sqrt_price_after: u128 = swap_data.sqrtPriceX96.to::<u128>();
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
        use alloy::rlp::Encodable;

        let currency0 = Address::from([0x0b, 0xA9, 0x07, 0x3a, 0xf8, 0xA7, 0x2c, 0x07, 0x34, 0x33, 0x9c, 0x35, 0x03, 0xA3, 0x9e, 0xF1, 0x1f, 0x2b, 0xcf, 0x95]);
        let currency1 = Address::from([0x0f, 0xaf, 0x34, 0x8f, 0x03, 0xE4, 0xD5, 0xA3, 0xc3, 0x94, 0xf3, 0x89, 0xDE, 0x52, 0x48, 0xaE, 0xfF, 0x15, 0x27, 0x91]);
        let fee: u32 = 0x800000;
        let tick_spacing: i32 = 60;
        let hooks = Address::from([0x0b, 0xb2, 0xA4, 0xf7, 0x15, 0xf8, 0x1F, 0x39, 0xe9, 0x01, 0x07, 0xf4, 0xe4, 0x47, 0xFD, 0xDA, 0x48, 0xAB, 0x80, 0xC0]);

        let encoded = alloy::sol_types::SolValue::abi_encode_params(
            &(currency0, currency1, fee, tick_spacing, hooks),
        );
        keccak256(&encoded)
    }

    #[tokio::test]
    #[ignore]
    async fn test_fetch_real_v4_swap_events_from_sepolia() {
        let pool_manager = Address::from([0xCf, 0x5e, 0xC7, 0x91, 0x1E, 0xbE, 0xE0, 0xfE, 0x45, 0x37, 0x30, 0x86, 0xd6, 0xf5, 0x08, 0x0B, 0xB8, 0x86, 0x3a, 0x08]);
        let pool_id = compute_pool_id();

        let events = fetch_swap_events(
            SEPOLIA_RPC,
            pool_manager,
            pool_id,
            0,
            8_000_000,
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
