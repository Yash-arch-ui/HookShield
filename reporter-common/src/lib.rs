use alloy::{
    network::EthereumWallet,
    primitives::{Address, FixedBytes, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::TransactionRequest,
    signers::{local::PrivateKeySigner, Signer},
    sol,
    sol_types::{eip712_domain, Eip712Domain, SolCall, SolStruct},
};
use eyre::Result;
use std::str::FromStr;

sol! {
    #[derive(Debug)]
    struct SignalReport {
        bytes32 poolId;
        uint8 signalType;
        uint256 score;
        uint256 nonce;
        uint256 validUntil;
    }

    #[sol(rpc)]
    interface IReporterSignalStore {
        function lastNonce(address reporter) external view returns (uint256);
        function submitScore(
            SignalReport calldata report,
            bytes calldata signature
        ) external;
    }
}

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
}

impl From<u8> for SignalType {
    fn from(value: u8) -> Self {
        match value {
            0 => Self::Sandwich,
            1 => Self::Flashloan,
            2 => Self::ToxicFlow,
            3 => Self::Jit,
            4 => Self::Mev,
            _ => panic!("invalid signal type: {value}"),
        }
    }
}

pub struct ReporterClient {
    rpc_url: String,
    signer: PrivateKeySigner,
    contract_address: Address,
    domain: Eip712Domain,
}

impl ReporterClient {
    pub fn new(rpc_url: &str, private_key: &str, contract_address: Address) -> Result<Self> {
        let signer = PrivateKeySigner::from_str(private_key)?;
        let domain = eip712_domain! {
            name: "HookShieldReporter",
            version: "1",
            chain_id: 11155111u64,
            verifying_contract: contract_address,
        };

        Ok(Self {
            rpc_url: rpc_url.to_string(),
            signer,
            contract_address,
            domain,
        })
    }

    pub async fn submit_score(
        &self,
        pool_id: [u8; 32],
        signal_type: SignalType,
        score: u128,
        valid_for_seconds: u64,
    ) -> Result<FixedBytes<32>> {
        let url: url::Url = self.rpc_url.parse()?;
        let read_provider = ProviderBuilder::new()
            .disable_recommended_fillers()
            .connect_http(url);

        let contract = IReporterSignalStore::new(self.contract_address, &read_provider);
        let last_nonce = contract
            .lastNonce(self.signer.address())
            .call()
            .await?;
        let nonce = last_nonce + U256::from(1);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs();
        let valid_until = U256::from(now + valid_for_seconds);

        let report = SignalReport {
            poolId: FixedBytes::from(pool_id),
            signalType: signal_type.as_u8(),
            score: U256::from(score),
            nonce,
            validUntil: valid_until,
        };

        let struct_hash = report.eip712_hash_struct();
        let domain_separator = self.domain.separator();
        let mut digest_data = Vec::with_capacity(66);
        digest_data.push(0x19);
        digest_data.push(0x01);
        digest_data.extend_from_slice(domain_separator.as_slice());
        digest_data.extend_from_slice(struct_hash.as_slice());
        let digest = alloy::primitives::keccak256(&digest_data);

        let sig = self.signer.sign_hash(&digest).await?;
        let sig_bytes: alloy::primitives::Bytes = sig.as_bytes().into();

        let call = IReporterSignalStore::submitScoreCall {
            report,
            signature: sig_bytes,
        };
        let call_data: Vec<u8> = call.abi_encode();

        let wallet = EthereumWallet::from(self.signer.clone());
        let write_url: url::Url = self.rpc_url.parse()?;
        let write_provider = ProviderBuilder::new()
            .wallet(wallet)
            .connect_http(write_url);

        let tx = TransactionRequest::default()
            .to(self.contract_address)
            .input(alloy::rpc::types::TransactionInput::new(call_data.into()));

        let receipt = write_provider
            .send_transaction(tx)
            .await?
            .get_receipt()
            .await?;

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

        let pool_id = [0u8; 32];
        let tx_hash = client
            .submit_score(pool_id, SignalType::Sandwich, 100, 3600)
            .await?;

        println!("Transaction submitted: {tx_hash}");
        Ok(())
    }
}
