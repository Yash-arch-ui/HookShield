use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::providers::{DynProvider, Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use alloy::signers::Signer;
use alloy::sol;
use alloy::sol_types::{eip712_domain, Eip712Domain, SolStruct};
use eyre::Result;
use std::str::FromStr;

sol! {
    #[derive(Debug, PartialEq, Eq)]
    #[sol(rpc)]
    interface IReporterSignalStore {
        struct SignalReport {
            bytes32 poolId;
            uint8 signalType;
            uint256 score;
            uint256 nonce;
            uint256 validUntil;
        }

        function lastNonce(address reporter) external view returns (uint256);
        function submitScore(SignalReport calldata report, bytes calldata signature) external;
    }
}

pub use IReporterSignalStore::SignalReport;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SignalType {
    Sandwich = 0,
    Flashloan = 1,
    ToxicFlow = 2,
    Jit = 3,
    Mev = 4,
}

impl SignalType {
    pub fn as_u8(self) -> u8 {
        self as u8
    }

    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(Self::Sandwich),
            1 => Some(Self::Flashloan),
            2 => Some(Self::ToxicFlow),
            3 => Some(Self::Jit),
            4 => Some(Self::Mev),
            _ => None,
        }
    }
}

pub struct ReporterClient {
    provider: DynProvider,
    signer: PrivateKeySigner,
    contract_address: Address,
    domain: Eip712Domain,
}

impl ReporterClient {
    pub fn new(rpc_url: &str, private_key: &str, reporter_address: Address) -> Result<Self> {
        let provider = ProviderBuilder::new()
            .connect_http(rpc_url.parse()?)
            .erased();

        let signer = PrivateKeySigner::from_str(private_key.trim_start_matches("0x"))?;

        let domain = eip712_domain! {
            name: "HookShieldReporter",
            version: "1",
            chain_id: 11155111u64,
            verifying_contract: reporter_address,
        };

        Ok(Self {
            provider,
            signer,
            contract_address: reporter_address,
            domain,
        })
    }

    pub async fn submit_score(
        &self,
        pool_id: [u8; 32],
        signal_type: SignalType,
        score: u128,
        valid_for_seconds: u64,
    ) -> Result<B256> {
        let contract = IReporterSignalStore::new(self.contract_address, &self.provider);

        let current_nonce = contract
            .lastNonce(self.signer.address())
            .call()
            .await?;

        let new_nonce = current_nonce + U256::from(1);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let valid_until = U256::from(now + valid_for_seconds);

        let report = SignalReport {
            poolId: pool_id.into(),
            signalType: signal_type.as_u8(),
            score: U256::from(score),
            nonce: new_nonce,
            validUntil: valid_until,
        };

        let signing_hash = report.eip712_signing_hash(&self.domain);

        let signature = self.signer.sign_hash(&signing_hash).await?;
        let sig_bytes = Bytes::from(signature.as_bytes().to_vec());

        let pending = contract.submitScore(report, sig_bytes).send().await?;

        let receipt = pending.get_receipt().await?;
        Ok(receipt.transaction_hash)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore]
    async fn test_submit_score_e2e() -> Result<()> {
        dotenvy::dotenv().ok();

        let rpc_url =
            std::env::var("SEPOLIA_RPC_URL").expect("SEPOLIA_RPC_URL must be set");
        let private_key =
            std::env::var("REPORTER_PRIVATE_KEY").expect("REPORTER_PRIVATE_KEY must be set");
        let contract_address: Address = std::env::var("REPORTER_SIGNAL_STORE_ADDRESS")
            .expect("REPORTER_SIGNAL_STORE_ADDRESS must be set")
            .parse()?;

        let client = ReporterClient::new(&rpc_url, &private_key, contract_address)?;

        let pool_id = [1u8; 32];
        let tx_hash = client
            .submit_score(pool_id, SignalType::Sandwich, 1000, 3600)
            .await?;

        println!("Transaction submitted: {:?}", tx_hash);
        assert!(!tx_hash.is_zero());

        Ok(())
    }
}
