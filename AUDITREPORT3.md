# AUDIT_REPORT3.md — HookShield Complete Codebase Audit

**Date:** 2026-09-21
**Scope:** All Solidity contracts, Rust crates, deployment scripts, tests, configuration
**Toolchain:** Foundry (solc 0.8.26, cancun EVM), Rust 1.98 (alloy 2.4.2)
**Previous Reports:** AUDIT_REPORT.md (V1), AUDIT_REPORT_V2.md

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Architecture Overview](#2-architecture-overview)
3. [File-by-File Audit — Solidity Contracts](#3-file-by-file-audit--solidity-contracts)
4. [File-by-File Audit — Rust Crates](#4-file-by-file-audit--rust-crates)
5. [File-by-File Audit — Deployment Scripts](#5-file-by-file-audit--deployment-scripts)
6. [File-by-File Audit — Test Suite](#6-file-by-file-audit--test-suite)
7. [File-by-File Audit — Configuration](#7-file-by-file-audit--configuration)
8. [Cross-Module Data Flow Trace](#8-cross-module-data-flow-trace)
9. [Security Findings](#9-security-findings)
10. [Functional Correctness Analysis](#10-functional-correctness-analysis)
11. [Test Coverage Matrix](#11-test-coverage-matrix)
12. [Rust ↔ Solidity Constant Cross-Check](#12-rust--solidity-constant-cross-check)
13. [Open Issues and Recommendations](#13-open-issues-and-recommendations)

---

## 1. Executive Summary

HookShield is a **Uniswap v4 hook** that replaces the static swap fee with an **adaptive, risk-weighted fee** computed from live on-chain market signals (volatility, inventory skew, oracle divergence, whale activity). Off-chain signal reporters (sandwich, flashloan, JIT, toxic flow, MEV) submit EIP-712 signed scores via a Rust client.

**Codebase stats:**
- 22 active Solidity source files
- 1 Rust library crate (reporter-common), 1 Rust binary crate (hookshield-simulator)
- 149 total tests (108 Solidity unit, 6 Solidity integration, 35 Rust unit)
- All tests passing

**Overall assessment:** The codebase is well-structured with strong separation of concerns, comprehensive test coverage, and consistent patterns. Key risks are in deployment staleness, the `.env` secrets leak, and several low-severity design considerations.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Uniswap V4 PoolManager                       │
│                              │                                      │
│                     ┌────────▼────────┐                             │
│                     │ HookShieldHook  │                             │
│                     │  (beforeSwap)   │                             │
│                     └───┬─────┬───┬───┘                             │
│                         │     │   │                                 │
│          ┌──────────────┘     │   └──────────────┐                  │
│          ▼                    ▼                   ▼                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │WhaleScoreSig │  │WeightedRisk  │  │Threshold     │              │
│  │ (beforeSwap) │  │  Model       │  │  Policy      │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                  │                       │
│         └────────┬────────┘                  │                      │
│                  ▼                           ▼                      │
│          ┌──────────────┐           Fee Override (OVERRIDE_FEE)     │
│          │ SignalState  │                                           │
│          └──────┬───────┘                                           │
│                 │                                                   │
│  ┌──────────────┼──────────────────────────┐                        │
│  │afterSwap:    │                          │                        │
│  ▼              ▼                          ▼                        │
│ VolatilitySignal  InventorySignal  OracleDivergenceSignal           │
│      │                   │                   │                      │
│  VolatilityStorage  InventoryStorage  OracleDivergenceStorage       │
│                                                              │      │
│                                                     AnalyticsEngine │
└─────────────────────────────────────────────────────────────────────┘

Off-chain:
  ReporterCommon (Rust) ──EIP-712──▶ ReporterSignalStore ──▶ SignalState
```

---

## 3. File-by-File Audit — Solidity Contracts

### 3.1 Core Hook

#### `src/hooks/HookShieldHook.sol` (202 lines)

**Purpose:** Main Uniswap v4 hook. Orchestrates the entire fee computation pipeline.

**Constructor:** Takes 8 addresses — `_poolManager`, `_volatilitySignal`, `_inventorySignal`, `_whaleSignal`, `_oracleSignal`, `_riskModel`, `_policy`, `_analyticsEngine`. All stored as immutable.

**Functionality:**

| Function | Trigger | Behavior |
|----------|---------|----------|
| `beforeSwap()` | Every swap | 1) Writes whale score to SignalState 2) Computes weighted risk via `riskModel.risk()` 3) Gets fee via `policy.action()` 4) Emits `DynamicFeeComputed` event 5) Returns fee with `OVERRIDE_FEE_FLAG` |
| `afterSwap()` | Every swap | 1) Reads `getSlot0()` for current price 2) Updates volatility signal 3) Updates inventory signal 4) Updates oracle divergence signal 5) Records to analytics engine |
| `getHookPermissions()` | View | Returns `beforeSwap=true, afterSwap=true`, all others false |
| `latestFee()` | View | Last fee charged (for off-chain monitoring) |
| `lastSwapTriggered()` | View | Block number of last swap |
| `_lastRiskE18()` | View | Last risk score (for off-chain monitoring) |

**Key design decisions:**
- Whale score is computed in `beforeSwap` (before the swap executes), so THIS swap's own impact affects its own fee — this is intentional and documented.
- `onlyPoolManager` modifier is defined but NOT applied; V4 core enforces caller authorization at the protocol level.

**Auth pattern:** Relies entirely on V4 core's `msg.sender == poolManager` enforcement. No custom authorization needed.

**State:**
- `poolManager`, `volatilitySignal`, `inventorySignal`, `whaleSignal`, `oracleSignal`, `riskModel`, `policy`, `analyticsEngine` — all `immutable`
- `latestFee` — last fee in LP units
- `lastSwapTriggered` — block number
- `_lastRiskE18` — last risk score

**Events emitted:** `DynamicFeeComputed(PoolId indexed, uint24 fee, uint256 riskE18, uint24 tier, uint256 timestamp)`

---

### 3.2 Signal Contracts

#### `src/signals/SignalState.sol` (112 lines)

**Purpose:** Central per-pool snapshot store. Single source of truth for all signal values. Ownable with authorized writer pattern.

**Struct `SignalSnapshot`:**
```solidity
struct SignalSnapshot {
    uint256 volatility;         // 0..1e18
    uint256 inventorySkew;      // 0..1e18
    uint256 oracleDivergence;   // 0..1e18
    uint256 whaleScore;         // 0..1e18
    uint256 jitScore;           // 0..1e18 (off-chain reporter)
    uint256 sandwichScore;      // 0..1e18 (off-chain reporter)
    uint256 flashloanScore;     // 0..1e18 (off-chain reporter)
    uint256 toxicFlowScore;     // 0..1e18 (off-chain reporter)
    uint256 mevScore;           // 0..1e18 (off-chain reporter)
    uint256 updatedAt;          // timestamp
    uint256 validUntil;         // staleness window
}
```

**9 setter functions** — each with `onlyAuthorized` modifier and `value <= 1e18` bounds check:
- `setVolatility`, `setInventorySkew`, `setOracleDivergence`, `setWhaleScore`
- `setJitScore`, `setSandwichScore`, `setFlashloanScore`, `setToxicFlowScore`, `setMevScore`

**Staleness:** `_STALENESS_WINDOW = 60 minutes`. `isStale()` checks `block.timestamp > updatedAt + _STALENESS_WINDOW`.

**Auth:** `authorizedWriters` mapping managed by owner via `setAuthorizedWriter()`.

**Observation:** 5 fields (jit through mev) are reserved for off-chain reporters via `ReporterSignalStore`. They are fully wired but currently unused in the fee computation pipeline.

---

#### `src/signals/VolatilitySignal.sol` (29 lines)

**Purpose:** EWMA (Exponentially Weighted Moving Average) volatility signal.

**Flow:**
1. `update(poolId, sqrtPriceX96)`: Reads old state from `VolatilityStorage`, calls `Volatility.compute()`, writes new state back, publishes EWMA to `SignalState`.
2. `compute(poolId)`: Returns stored EWMA volatility.

**First-call behavior:** When `lastSqrtPriceX96 == 0`, the signal stores the current price but publishes volatility = 0 (one-price-seed). This prevents false volatility spikes from a single data point.

**Storage dependency:** `VolatilityStorage` (one-time writer lock).

---

#### `src/signals/InventorySignal.sol` (51 lines)

**Purpose:** Tracks net directional flow (buy vs sell pressure) per pool.

**Constants:**
- `SCALE = 1e18`
- `FLOW_STEP = 1e18` (each swap increments/decrements by 1 unit)
- `MAX_FLOW = 10e18` (saturation threshold)

**Flow:**
1. `update(poolId, sqrtPriceX96, zeroForOne)`: Increments `netFlow` by `FLOW_STEP` if `zeroForOne`, decrements otherwise. Clamps to `[-MAX_FLOW, MAX_FLOW]`. Computes normalized skew = `|netFlow| * SCALE / MAX_FLOW`. Writes to both `InventoryStorage` and `SignalState`.
2. `compute(poolId)`: Returns normalized skew from storage.

**Normalization:** Skew is always in range `[0, 1e18]` regardless of `netFlow` sign. Saturation at ±10 swaps produces skew = 1e18.

**Observation:** The `sqrtPriceX96` parameter is accepted but not used — flow direction is determined solely by `zeroForOne`. This is correct for the inventory tracking model.

---

#### `src/signals/WhaleScoreSignal.sol` (72 lines)

**Purpose:** Stateless price-impact signal for the current swap. Measures how much this specific trade moves the pool price.

**Called in `beforeSwap`** (not `afterSwap`), so this swap's own impact is included in its fee.

**Computation:**
1. Read `getSlot0()` (current price) and `getLiquidity()`
2. Compute hypothetical next price via `SqrtPriceMath.getNextSqrtPriceFromInput()`
3. `impactE18 = |old - new| * 2 * SCALE / old`
4. Cap at `SCALE` (1e18)

**Edge cases:**
- `liquidity == 0` → returns `SCALE` (maximum risk) — empty pool = maximum price impact
- `amountIn == 0` → returns 0 — no trade = no impact
- Zero old price → reverts (via Solidity division) — should never happen in practice

---

#### `src/signals/OracleDivergenceSignal.sol` (85 lines)

**Purpose:** Measures divergence between Chainlink oracle price and on-chain pool price.

**Flow:**
1. `update(poolId, sqrtPriceX96)`: Fetches oracle price (try/catch), converts `sqrtPriceX96` to priceE18, computes `|oracle - pool| / max(oracle, pool)`, writes to `OracleDivergenceStorage` and `SignalState`.
2. `_sqrtPriceToPriceE18(sqrtPriceX96)`: Overflow-safe conversion splitting into 128-bit halves.
3. `_computeDivergence(oraclePrice, poolPrice)`: Returns 0 if oracle unavailable, otherwise normalized divergence capped at `SCALE`.

**Oracle failure handling:** If Chainlink call reverts or returns stale data, `_getOraclePrice()` returns 0, and divergence is computed as 0 (conservative fallback).

---

### 3.3 Storage Contracts

#### `src/VolatilityStorage.sol` (104 lines)

**Struct `VolatilityState`:**
```solidity
struct VolatilityState {
    uint160 lastSqrtPriceX96;
    uint256 ewmaVolatility;
    uint256 lastUpdateBlock;
}
```

**Auth pattern:** `setWriter(address)` — one-time lock. Once set, cannot be changed. `onlyWriter` modifier on `setState()` and `updateState()`.

**Key functions:**
- `getState(PoolId)` → full struct
- `getLastSqrtPriceX96(PoolId)` → uint160
- `getEwmaVolatility(PoolId)` → uint256
- `isInitialized(PoolId)` → bool (`lastSqrtPriceX96 != 0`)
- `setState(PoolId, VolatilityState)` — direct write (writer only)
- `updateState(PoolId, uint160, uint256)` — incremental update (writer only)

---

#### `src/InventoryStorage.sol` (43 lines)

**Struct `InventoryState`:**
```solidity
struct InventoryState {
    int256 netFlow;
    uint256 lastUpdateBlock;
}
```

**Same auth pattern:** One-time `setWriter` + `onlyWriter`.

---

#### `src/OracleDivergenceStorage.sol` (44 lines)

**Struct `OracleState`:**
```solidity
struct OracleState {
    uint256 lastOraclePrice;
    uint256 lastPoolPrice;
    uint256 lastUpdateBlock;
}
```

**Same auth pattern:** One-time `setWriter` + `onlyWriter`.

---

### 3.4 Risk Model

#### `src/risk/IRiskModel.sol` (8 lines)

**Interface:** `risk(PoolId, uint256 tradeSize) → uint256 riskE18`

**Note:** `tradeSize` parameter is accepted but currently ignored by the implementation. Kept for future size-aware risk.

---

#### `src/risk/WeightedRiskModel.sol` (92 lines)

**Purpose:** Computes composite risk as weighted sum of 4 signals.

**Constructor:** Takes `_signalState` + 4 weights (`_volatilityWeight`, `_inventorySkewWeight`, `_oracleDivergenceWeight`, `_whaleScoreWeight`).

**`risk()` computation:**
1. Read `getSnapshot()` from `SignalState`
2. If stale (`isStale()`) → return `STALE_FALLBACK_RISK = 0.5e18`
3. `risk = (vol * w1 + inv * w2 + oracle * w3 + whale * w4) / SCALE`
4. Cap at `SCALE`

**Default weights:** vol=0.3e18, inv=0.2e18, oracle=0.2e18, whale=0.3e18 (sum = 1.0e18).

**`setWeights()` (onlyOwner):** Requires weights to sum to exactly `SCALE`. No partial updates.

---

### 3.5 Policy

#### `src/policy/IPolicy.sol` (14 lines)

**Interface + struct:**
```solidity
struct PolicyAction {
    uint24 fee;
    bool pauseSwaps;
    uint8 tier;
}
```

---

#### `src/policy/ThresholdPolicy.sol` (54 lines)

**Purpose:** Maps risk score to fee tier via 5 thresholds.

**Default tiers:**

| Risk Range | Tier | Fee |
|-----------|------|-----|
| < 0.2e18 | 0 | 3000 (0.30%) |
| 0.2e18 – 0.4e18 | 1 | 4000 (0.40%) |
| 0.4e18 – 0.6e18 | 2 | 6000 (0.60%) |
| 0.6e18 – 0.8e18 | 3 | 9000 (0.90%) |
| ≥ 0.8e18 | 4 | 12000 (1.20%) |

**Boundary behavior:** Uses `<` (not `<=`) for threshold comparison. Risk = exactly 0.2e18 → tier 1 (not tier 0).

**`pauseSwaps`:** Reserved but always `false` in v1.

---

### 3.6 Oracle

#### `src/oracle/IOracle.sol` (10 lines)

**Interface:** `getPrice() → uint256 priceE18`, `isStale() → bool`

---

#### `src/oracle/ChainlinkOracle.sol` (35 lines)

**Purpose:** Wraps a Chainlink `AggregatorV3Interface` feed.

**`getPrice()`:**
1. Call `latestRoundData()` on feed
2. Validate `answer > 0` and `updatedAt + maxStaleness >= block.timestamp`
3. Scale to 1e18: `answer * 10^(18 - feed.decimals())`

**`isStale()`:** Returns `true` if answer ≤ 0 or timestamp is stale.

**Errors:** `StalePrice`, `NonPositiveAnswer`.

---

#### `src/oracle/MedianOracle.sol` (88 lines)

**Purpose:** Median of N ≥ 2 oracle sources with try/catch fault tolerance.

**`getPrice()`:**
1. Collect valid prices (try/catch each source)
2. Require ≥ 2 valid sources (quorum)
3. Sort valid prices (insertion sort)
4. Return median (middle or average of two middle values)

**`isStale()`:** True if < 2 sources are fresh.

---

#### `src/oracle/CompositeOracle.sol` (131 lines)

**Purpose:** Configurable aggregation across N oracle sources.

**Strategies:** `Median`, `Average`, `Min`, `Max`.

**`minQuorum`:** `max(sources.length / 2, 2)` — majority quorum with minimum of 2.

**Same try/catch pattern** for partial failure tolerance. Uses assembly to trim the valid-prices array in-place.

---

### 3.7 Analytics

#### `src/analytics/AnalyticsEngine.sol` (73 lines)

**Purpose:** Records per-swap metrics for monitoring and analysis.

**One-time writer lock** pattern (same as storage contracts).

**`recordSwap(poolId, tradeSize, riskE18, fee)`:** Increments `totalSwaps`, `totalTradeSize`, `totalRiskE18`, `totalFeesCharged`. Emits `SwapRecorded` event.

**View helpers:** `avgRiskE18()` → totalRiskE18/totalSwaps, `avgFeesCharged()` → totalFeesCharged/totalSwaps.

---

### 3.8 Reporter

#### `src/reporter/ReporterSignalStore.sol` (90 lines)

**Purpose:** Bridges off-chain signal reporters to on-chain via EIP-712 signatures.

**Enum `SignalType`:** `Sandwich=0, Flashloan=1, ToxicFlow=2, Jit=3, Mev=4`

**Struct `SignalReport`:**
```solidity
struct SignalReport {
    bytes32 poolId;
    uint8 signalType;
    uint256 score;
    uint256 nonce;
    uint256 validUntil;
}
```

**EIP-712 domain:** `name="HookShieldReporter"`, `version="1"`, chain_id from deployment, verifying_contract = ReporterSignalStore address.

**`submitScore(report, signature)`:**
1. Compute EIP-712 digest (`_hashTypedDataV4`)
2. Recover signer via `ECDSA.recover()`
3. Verify `authorizedReporters[signer]`
4. Verify `report.nonce > lastNonce[signer]`
5. Verify `block.timestamp < report.validUntil`
6. Update `lastNonce[signer] = report.nonce`
7. Dispatch to appropriate `SignalState.set*Score()` based on `signalType`

**Auth:** Owner manages `authorizedReporters` mapping.

---

### 3.9 Library

#### `src/libraries/Volatility.sol` (78 lines)

**Constants:**
- `SCALE = 1e18`
- `ALPHA = 0.1e18` (smoothing factor)
- `ONE_MINUS_ALPHA = 0.9e18`

**Functions:**
- `calculateReturn(old, new)`: `|new - old| * SCALE / old` — reverts on `old == 0`
- `updateEwma(old, ret)`: `(ALPHA * ret + ONE_MINUS_ALPHA * old) / SCALE`
- `compute(state, newPrice)`: Full pipeline — first-time init → calculate return → update EWMA → build new state

---

### 3.10 Interfaces

#### `src/interfaces/ISignal.sol` (14 lines)
**Interface:** `compute(PoolId) → uint256`, `update(PoolId, uint160 sqrtPriceX96)`

#### `src/interfaces/AggregatorV3Interface.sol` (15 lines)
**Standard Chainlink interface:** `decimals()`, `description()`, `version()`, `latestRoundData()`

---

## 4. File-by-File Audit — Rust Crates

### 4.1 reporter-common

#### `reporter-common/Cargo.toml`
**Dependencies:** alloy 2 (full), eyre 0.6, tokio 1 (full), dotenvy 0.15, url 2
**Edition:** 2024

#### `reporter-common/src/lib.rs` (184 lines)

**Purpose:** Off-chain Rust client for submitting EIP-712 signed signal scores to `ReporterSignalStore`.

**Key types:**

```rust
pub enum SignalType {
    Sandwich = 0,   // matches Solidity enum exactly
    Flashloan = 1,
    ToxicFlow = 2,
    Jit = 3,
    Mev = 4,
}
```

```rust
pub struct ReporterClient {
    rpc_url: String,
    signer: PrivateKeySigner,
    contract_address: Address,
    domain: Eip712Domain,  // name="HookShieldReporter", version="1", chain_id=11155111
}
```

**Functions:**

| Function | Purpose |
|----------|---------|
| `new(rpc_url, private_key, contract_address)` | Constructs client, builds EIP-712 domain matching Solidity exactly |
| `submit_score(pool_id, signal_type, score, valid_for_seconds)` | Full pipeline: fetch nonce → build report → EIP-712 sign → send tx |

**`submit_score` detailed flow:**
1. Create read-only provider (no fillers)
2. Call `lastNonce(reporterAddress)` on contract
3. Build `SignalReport` with `nonce = current + 1`, `validUntil = now + valid_for_seconds`
4. Compute `eip712_hash_struct()` on the report
5. Compute domain separator via `domain.separator()`
6. Build digest: `keccak256("\x19\x01" || domainSeparator || structHash)`
7. Sign with `PrivateKeySigner::sign_hash()`
8. Encode `submitScoreCall` with report + signature
9. Send via wallet-filled provider

**Test:** One `#[tokio::test] #[ignore]` end-to-end test reading from env vars (SEPOLIA_RPC_URL, REPORTER_PRIVATE_KEY, REPORTER_SIGNAL_STORE_ADDRESS).

---

### 4.2 hookshield-simulator

#### `hookshield-simulator/Cargo.toml`
**Dependencies:** alloy 2 (full), tokio 1 (full), serde/serde_json, clap 4 (derive), eyre 0.6, reqwest 0.12 (json)
**Edition:** 2024

#### `hookshield-simulator/src/main.rs` (68 lines)

**Purpose:** CLI entry point. Parses args, fetches events, runs simulation, prints report.

**CLI args (clap):**
- `--rpc_url` (required)
- `--pool_manager` (required, Address)
- `--pool_id` (required, B256)
- `--from_block`, `--to_block` (u64)
- `--base_fee` (u64, default 3000)
- `--format` (text|json, default text)

---

#### `hookshield-simulator/src/fetcher.rs` (223 lines)

**Purpose:** Fetches Uniswap V4 Swap events from the PoolManager via paginated `eth_getLogs`.

**Key struct:**
```rust
pub struct SwapEvent {
    pub pool_id: B256,
    pub block_number: u64,
    pub sqrt_price_x96_before: u128,
    pub sqrt_price_x96_after: u128,
    pub liquidity: u128,
    pub amount_in: u128,
    pub zero_for_one: bool,
    pub timestamp: u64,
}
```

**V4 Swap event ABI:** `Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)`

**Pagination:** Processes 10 blocks per chunk (Alchemy free tier limit). `sqrt_price_x96_before` is approximated from previous swap's `sqrt_price_x96_after`.

**⚠️ Known limitation:** `sqrt_price_x96_before` is an approximation — if multiple swaps occur in the same block, only the last one is captured.

---

#### `hookshield-simulator/src/math.rs` (246 lines)

**Purpose:** EWMA math and fee tier computation — Rust port of `Volatility.sol` and `ThresholdPolicy.sol`.

**Constants (matching Solidity exactly):**
```rust
pub const SCALE: u128 = 1_000_000_000_000_000_000;        // 1e18
pub const ALPHA: u128 = 100_000_000_000_000_000;           // 0.1e18
pub const ONE_MINUS_ALPHA: u128 = 900_000_000_000_000_000; // 0.9e18
```

**Threshold constants (matching ThresholdPolicy.sol):**
```rust
pub const THRESHOLDS: [(u128, u24); 5] = [
    (200_000_000_000_000_000, 4000),   // 0.2e18 → 4000
    (400_000_000_000_000_000, 6000),   // 0.4e18 → 6000
    (600_000_000_000_000_000, 9000),   // 0.6e18 → 9000
    (800_000_000_000_000_000, 12000),  // 0.8e18 → 12000
    (u128::MAX, 12000),                // overflow → 12000
];
```

**Functions:**
- `calculate_return(old, new)` → `Result<u128>` (uses U256 for overflow safety)
- `update_ewma(old_ewma, current_return)` → `Result<u128>`
- `compute_fee_from_risk(risk_e18)` → `u24`

---

#### `hookshield-simulator/src/whale.rs` (145 lines)

**Purpose:** Whale impact score computation — Rust port of `WhaleScoreSignal.sol`.

**`get_next_sqrt_price_from_input()`:** Direct port of Uniswap's `SqrtPriceMath.getNextSqrtPriceFromInput` using U256 for overflow safety.

**`compute_whale_impact()`:**
```
impact = |old - new| * 2 * SCALE / old
capped at SCALE
```

---

#### `hookshield-simulator/src/inventory.rs` (91 lines)

**Purpose:** Inventory flow tracking — Rust port of `InventorySignal.sol`.

**Constants:** `FLOW_STEP = 1e18`, `MAX_FLOW = 10e18`, `SCALE = 1e18`.

**Functions:**
- `update_inventory_flow(net_flow, zero_for_one)` → `i128` (clamped to ±MAX_FLOW)
- `flow_to_skew(net_flow)` → `u128` (normalized to 0..SCALE)

---

#### `hookshield-simulator/src/risk.rs` (128 lines)

**Purpose:** Weighted risk model — Rust port of `WeightedRiskModel.sol`.

**Default weights:** `vol=0.3, inv=0.2, oracle=0.2, whale=0.3` (matching deployment).

**`compute_weighted_risk()`:**
- If stale → returns `STALE_FALLBACK_RISK = 0.5e18`
- Otherwise → weighted sum, capped at SCALE

---

#### `hookshield-simulator/src/snapshot.rs` (126 lines)

**Purpose:** Per-swap simulation state. Builds signal snapshots BEFORE state updates (mirroring beforeSwap→afterSwap ordering).

**`process_swap()`:**
1. Build snapshot from CURRENT state (before update)
2. Update volatility (EWMA)
3. Update inventory (net flow)

---

#### `hookshield-simulator/src/simulator.rs` (330 lines)

**Purpose:** Full simulation engine. Replays historical swaps and compares static vs dynamic fee revenue.

**Key struct:**
```rust
pub struct SimulationResult {
    pub static_fee_revenue: u128,
    pub hookshield_revenue: u128,
    pub total_volume: u128,
    pub swap_count: usize,
    pub lvr_reduction_percent: f64,
    pub whale_scores: Vec<(u64, u128)>,
}
```

**Pipeline per swap:**
1. Compute whale impact
2. Build snapshot (signals before state update)
3. Compute weighted risk
4. Get fee from threshold policy
5. Accumulate revenue

**`simulate()` returns:** `SimulationResult` with static vs hookshield revenue comparison.

---

#### `hookshield-simulator/src/report.rs` (75 lines)

**Purpose:** Report output formatting.

**Functions:**
- `print_text_report()`: Formatted table with per-swap whale scores, min/max/avg summary
- `print_json_report()`: JSON serialization of report data

---

## 5. File-by-File Audit — Deployment Scripts

### `script/Deploy.s.sol` (116 lines)

**Purpose:** Deploys all 13 contracts and wires authorization.

**Deployment order:**
1. `SignalState` → 2. `VolatilityStorage` → 3. `VolatilitySignal` → 4. `InventoryStorage` → 5. `InventorySignal` → 6. `WhaleScoreSignal` → 7. `OracleDivergenceStorage` → 8. `ChainlinkOracle` → 9. `OracleDivergenceSignal` → 10. `WeightedRiskModel` → 11. `ThresholdPolicy` → 12. `AnalyticsEngine` → 13. `HookShieldHook` (CREATE2-mined)

**Wiring:**
- `volatilityStorage.setWriter(address(volatilitySignal))` ✓
- `inventoryStorage.setWriter(address(inventorySignal))` ✓
- `oracleStorage.setWriter(address(oracleSignal))` ✓
- `analyticsEngine.setWriter(address(hook))` ✓
- `signalState.setAuthorizedWriter(address(volatilitySignal))` ✓
- `signalState.setAuthorizedWriter(address(inventorySignal))` ✓
- `signalState.setAuthorizedWriter(address(whaleSignal))` ✓
- `signalState.setAuthorizedWriter(address(oracleSignal))` ✓

**CREATE2 mining:** Uses `HookMiner.find()` to mine a salt that produces an address with the required permission bits (beforeSwap + afterSwap).

### `script/DeployPoolManager.s.sol` (16 lines)
Deploys `PoolManager(deployer)`.

### `script/InitializePool.s.sol` (78 lines)
Deploys 2 MockERC20 tokens, creates pool with `DYNAMIC_FEE_FLAG`, tick spacing 60, seeds 1e18 liquidity in [-600, 600] range.

### `script/TestSwap.s.sol` (52 lines)
Executes a single 0.1-token swap through the live pool.

---

## 6. File-by-File Audit — Test Suite

### 6.1 Solidity Tests (108 unit + 6 integration = 114)

| Test File | Tests | What It Covers |
|-----------|-------|----------------|
| `Volatility.t.sol` | 10 fuzz | EWMA math: return calculation, convex combination, convergence, boundary, zero-price revert |
| `VolatilityStorage.t.sol` | 6 | Writer lock, access control, state read/write |
| `VolatilitySignal.t.sol` | 3 | First-call init, publish to SignalState, unauthorized revert |
| `InventorySignal.t.sol` | 9 | Direction, skew normalization, max flow saturation, opposite direction, unauthorized, fresh pool |
| `InventoryStorage.t.sol` | 7 | Writer lock, access control, event emission, default values |
| `WhaleScoreSignal.t.sol` | 3 | Zero liquidity (max score), zero amount, publish to SignalState |
| `OracleDivergenceSignal.t.sol` | 7 | Publish, compute, bounds, stale fallback, direction, unauthorized |
| `SignalState.t.sol` | 22 | All 9 setters (auth + bounds), staleness, authorizedWriter, 60-min window |
| `WeightedRiskModel.t.sol` | 7 | Constructor validation, stale fallback, weight reflection, owner-only |
| `ThresholdPolicy.t.sol` | 6 | Tier boundaries, threshold ordering, owner-only |
| `AnalyticsEngine.t.sol` | 11 | Writer lock, recordSwap, accumulators, averages, events |
| `CompositeOracle.t.sol` | 14 | All 4 strategies, partial failure, constructor validation |
| `MedianOracle.t.sol` | 12 | Odd/even median, partial failure, staleness, constructor |
| `HookShieldHook.t.sol` | 5 | Permissions, latestFee, state accessors, non-manager call |
| `HookShieldFullSwap.t.sol` | 6 | Full swap lifecycle, volatility increase, fee tier escalation, inventory skew, max flow saturation, counter-swap |
| `ReporterSignalStore.t.sol` | 8 | EIP-712 signature verification, all 5 signal types, nonce replay, expiry, auth |

### 6.2 Rust Tests (35)

| Module | Tests | What It Covers |
|--------|-------|----------------|
| `math` | 9 | Return calculation (increase/decrease/realistic), EWMA convergence, fee tier boundaries, zero-price error |
| `whale` | 4 | Zero liquidity, zero amount, small trade, large trade |
| `inventory` | 9 | Direction, max flow clamp, skew normalization, cancellation |
| `risk` | 4 | Stale fallback, zero baseline, hand-verified calculation, cap |
| `simulator` | 11 | Empty events, single/multiple swaps, high/low volatility, volume accumulation, LVR reduction, fallback error, liquidity impact, regression |
| `snapshot` | 3 | First swap, second swap, repeated direction |
| `fetcher` | 2 | Pool ID computation, live Sepolia fetch (ignored) |

---

## 7. File-by-File Audit — Configuration

### `foundry.toml`
- Compiler: solc 0.8.26, cancun EVM
- Optimizer: enabled, 44,444,444 runs, via-ir
- Skip: `src/_deprecated/**/*.sol`
- Remappings: `@uniswap/v4-core/`, `@uniswap/v4-periphery/`, `forge-std/`

### `.env`
- Contains Sepolia RPC URL, deployer private key, Etherscan API key
- All deployed contract addresses (multi-signal v2 deployment)
- Chainlink oracle feed address, max staleness (3600s)

### `DEPLOYMENTS.md`
- Documents current Sepolia v2 deployment addresses
- Notes: "multi-signal: volatility + inventory"

### `README.md` (321 lines)
- Project overview, architecture diagrams (mermaid), component descriptions
- Default parameters, project structure, getting started guide
- Deployment instructions, security considerations, roadmap

---

## 8. Cross-Module Data Flow Trace

### Trace 1: Full Swap Lifecycle (Happy Path)

```
1. User calls PoolManager.swap()
2. PoolManager calls HookShieldHook.beforeSwap()
3.   ├── WhaleScoreSignal.update(poolId, sqrtPriceX96, amountIn, zeroForOne)
4.   │     ├── Reads PoolManager.getSlot0(), getLiquidity()
5.   │     ├── Computes whale impact (price impact ratio)
6.   │     └── Writes whaleScore to SignalState
7.   ├── WeightedRiskModel.risk(poolId, tradeSize)
8.   │     ├── Reads SignalState.getSnapshot()
9.   │     ├── Checks staleness → fallback if stale
10.  │     └── Computes weighted sum of 4 signals
11.  ├── ThresholdPolicy.action(poolId, riskE18)
12.  │     └── Maps risk to fee tier (5 tiers)
13.  └── Returns (OVERRIDE_FEE_FLAG, fee, delta)
14. PoolManager executes swap
15. PoolManager calls HookShieldHook.afterSwap()
16.   ├── Reads PoolManager.getSlot0()
17.   ├── VolatilitySignal.update(poolId, sqrtPriceX96)
18.   │     ├── VolatilityStorage.getState()
19.   │     ├── Volatility.compute() (EWMA)
20.   │     ├── VolatilityStorage.updateState()
21.   │     └── SignalState.setVolatility()
22.   ├── InventorySignal.update(poolId, sqrtPriceX96, zeroForOne)
23.   │     ├── InventoryStorage.getState()
24.   │     ├── Clamps netFlow
25.   │     ├── InventoryStorage.setState()
26.   │     └── SignalState.setInventorySkew()
27.   ├── OracleDivergenceSignal.update(poolId, sqrtPriceX96)
28.   │     ├── ChainlinkOracle.getPrice()
29.   │     ├── OracleDivergenceStorage.setState()
30.   │     └── SignalState.setOracleDivergence()
31.   └── AnalyticsEngine.recordSwap(poolId, tradeSize, riskE18, fee)
```

### Trace 2: Off-Chain Reporter Flow

```
1. Rust ReporterClient.submit_score()
2.   ├── Reads lastNonce() from ReporterSignalStore
3.   ├── Builds SignalReport { poolId, signalType, score, nonce+1, validUntil }
4.   ├── Computes EIP-712 digest (domain + struct hash)
5.   ├── Signs with PrivateKeySigner
6.   └── Sends submitScore(report, signature) transaction
7. ReporterSignalStore.submitScore()
8.   ├── ECDSA.recover(digest, signature) → signer address
9.   ├── Checks authorizedReporters[signer]
10.  ├── Checks nonce > lastNonce[signer]
11.  ├── Checks block.timestamp < validUntil
12.  ├── Updates lastNonce[signer]
13.  └── Dispatches to SignalState.set*Score()
```

---

## 9. Security Findings

### CRITICAL

| # | Finding | File | Status |
|---|---------|------|--------|
| C-1 | **Private key committed in `.env`** | `.env` | OPEN — The deployer private key and Etherscan API key are committed in plaintext. Must be rotated and removed from git history. |

### HIGH

| # | Finding | File | Status |
|---|---------|------|--------|
| H-1 | **Deployment is stale — constructor arity mismatch** | `script/Deploy.s.sol` | OPEN — On-chain hook was deployed with 7 constructor params but current source requires 8 (added `AnalyticsEngine`). The deployed contract lacks analytics recording. |
| H-2 | **Reporter off-chain signals not used in risk computation** | `WeightedRiskModel.sol` | FIXED — `risk()` now adds `maxFreshReporterScore × reporterWeight / 1e18` before the final SCALE clamp. `reporterWeight` is owner-tunable via `setReporterWeight` (default `0.3e18`, emits `ReporterWeightUpdated`). Uses `max()` over the five reporter scores, each gated by its own H-3 deadline. |
| H-3 | **No mechanism to prevent stale reporter scores from influencing future risk** | `SignalState.sol` | FIXED — Each reporter setter stamps its own `...ValidUntil` deadline; `SignalState` exposes `isJitStale/isSandwichStale/isFlashloanStale/isToxicFlowStale/isMevStale` and `WeightedRiskModel` includes a reporter score only while fresh (never-written ⇒ treated as 0, not stale). Reporter staleness does not feed the pool-level `isStale()`, so expired reports decay instead of escalating fees; core-signal staleness still returns `STALE_FALLBACK_RISK = 1e18`. |

### MEDIUM

| # | Finding | File | Status |
|---|---------|------|--------|
| M-1 | **`tradeSize` parameter ignored in risk computation** | `WeightedRiskModel.sol` | FIXED — `risk(poolId, tradeSize, liquidity)` adds `min(tradeSize × 1e18 / liquidity, 0.3e18)` as a size/liquidity pressure term before the SCALE clamp. |
| M-2 | **`pauseSwaps` in PolicyAction is always false** | `ThresholdPolicy.sol` | FIXED — Circuit breaker sets `pauseSwaps` when risk exceeds the halt threshold (0.95e18), with dead-band hysteresis (0.10e18) to prevent flicker. |
| M-3 | **No rate limiting on ReporterSignalStore** | `ReporterSignalStore.sol` | OPEN — Any authorized reporter can submit unlimited reports as long as nonce increases. No cooldown between submissions for the same pool. |
| M-4 | **Whale score uses absolute price impact, not direction** | `WhaleScoreSignal.sol` | FIXED — `update`/`compute` now take the pool's signed `netFlow`; `adjust_for_direction` halves the raw impact when the swap rebalances inventory (`netFlow > 0 && !zeroForOne` or `netFlow < 0 && zeroForOne`), while worsening swaps keep full impact. Liquidity-0 early-return applies the discount before the SCALE clamp. |
| M-5 | **Inventory flow step is coarse (1e18 per swap)** | `InventorySignal.sol` | FIXED — `update(poolId, zeroForOne, tradeSize)` scales the step as `FLOW_STEP × tradeSize / REFERENCE_SIZE` (`REFERENCE_SIZE = 1e18`), saturating at `MAX_FLOW` for trades ≥ `10 × REFERENCE_SIZE`. A reference-size swap reproduces the legacy full step; dust trades move flow negligibly. |
| M-6 | **Oracle fallback silently returns 0 divergence** | `OracleDivergenceSignal.sol` | FIXED — When the oracle price is unavailable (`0`), the signal publishes divergence `1e18` (max risk) and emits `OracleUnavailable(poolId, timestamp)` instead of silently reporting 0. A never-observed pool still publishes `0` (no observation ≠ failure). |

### LOW

| # | Finding | File | Status |
|---|---------|------|--------|
| L-1 | **`sqrt_price_x96_before` approximation in Rust fetcher** | `fetcher.rs` | OPEN — When multiple swaps occur in the same block, only the last swap's `sqrtPriceX96` is captured. Intermediate swaps use the previous block's closing price as their "before" price. |
| L-2 | **Rust simulator doesn't model off-chain reporter signals** | `simulator.rs` | OPEN — The Rust simulator computes the 4 on-chain signals plus the H-2 reporter slot (default `0`, no reporter feed simulated off-chain). Reporter submissions are not replayed. |
| L-3 | **No event for WeightedRiskModel weight changes** | `WeightedRiskModel.sol` | FIXED — `setWeights()` emits `WeightsUpdated`; `setReporterWeight()` emits `ReporterWeightUpdated`. |
| L-4 | **ThresholdPolicy has no event for threshold/fee changes** | `ThresholdPolicy.sol` | OPEN — `setThresholds()` and `setFees()` have no event emissions. |
| L-5 | **MedianOracle gas cost scales quadratically** | `MedianOracle.sol` | OPEN — Insertion sort on N sources is O(N²). With many oracle sources, gas cost increases rapidly. Current deployment uses ≤3 sources so this is acceptable. |
| L-6 | **`computeFeeFromRisk` in Rust uses `u128::MAX` as final threshold** | `math.rs` | INFO — The final threshold entry `(u128::MAX, 12000)` means any risk ≥ 0.8e18 returns tier 4 (12000). This matches Solidity but could theoretically overflow on very large risk values. In practice, risk is capped at SCALE=1e18 so this is safe. |

---

## 10. Functional Correctness Analysis

### 10.1 EWMA Volatility (Solidity ↔ Rust cross-check)

| Component | Solidity | Rust | Match |
|-----------|----------|------|-------|
| SCALE | 1e18 | 1e18 | ✅ |
| ALPHA | 0.1e18 | 0.1e18 | ✅ |
| ONE_MINUS_ALPHA | 0.9e18 | 0.9e18 | ✅ |
| Return formula | \|new-old\| * SCALE / old | same | ✅ |
| EWMA formula | (ALPHA * ret + ONE_MINUS_ALPHA * old) / SCALE | same | ✅ |
| U256 overflow protection | No (uses Solidity 256-bit natively) | Yes (explicit U256) | ✅ Equivalent |

### 10.2 Threshold Policy (Solidity ↔ Rust cross-check)

| Threshold | Solidity Fee | Rust Fee | Match |
|-----------|-------------|----------|-------|
| < 0.2e18 | 3000 | 3000 (default base_fee) | ✅ |
| 0.2e18 – 0.4e18 | 4000 | 4000 | ✅ |
| 0.4e18 – 0.6e18 | 6000 | 6000 | ✅ |
| 0.6e18 – 0.8e18 | 9000 | 9000 | ✅ |
| ≥ 0.8e18 | 12000 | 12000 | ✅ |
| Boundary (0.2e18) | Tier 1 (`<` not `<=`) | Tier 1 | ✅ |

### 10.3 Inventory Flow (Solidity ↔ Rust cross-check)

| Component | Solidity | Rust | Match |
|-----------|----------|------|-------|
| FLOW_STEP | 1e18 | 1e18 | ✅ |
| MAX_FLOW | 10e18 | 10e18 | ✅ |
| SCALE | 1e18 | 1e18 | ✅ |
| Clamp direction | `min(netFlow, MAX_FLOW)` | `min(net_flow, MAX_FLOW)` | ✅ |
| Skew formula | \|netFlow\| * SCALE / MAX_FLOW | same | ✅ |

### 10.4 Whale Impact (Solidity ↔ Rust cross-check)

| Component | Solidity | Rust | Match |
|-----------|----------|------|-------|
| Formula | \|old - new\| * 2 * SCALE / old | same | ✅ |
| Cap | SCALE | SCALE | ✅ |
| SqrtPriceMath port | Uniswap v4-core | Direct port with U256 | ✅ |

### 10.5 Weighted Risk (Solidity ↔ Rust cross-check)

| Component | Solidity | Rust | Match |
|-----------|----------|------|-------|
| STALE_FALLBACK_RISK | 0.5e18 | 0.5e18 | ✅ |
| Default weights | vol=0.3, inv=0.2, oracle=0.2, whale=0.3 | same | ✅ |
| Sum check | Requires sum == SCALE | Not enforced (caller responsibility) | ⚠️ |
| Cap | risk = min(risk, SCALE) | same | ✅ |

### 10.6 EIP-712 Domain (Solidity ↔ Rust cross-check)

| Component | Solidity | Rust | Match |
|-----------|----------|------|-------|
| name | "HookShieldReporter" | "HookShieldReporter" | ✅ |
| version | "1" | "1" | ✅ |
| chain_id | 11155111 (Sepolia) | 11155111 | ✅ |
| verifying_contract | ReporterSignalStore address | contract_address param | ✅ |
| Typehash | keccak256("SignalReport(bytes32 poolId,uint8 signalType,uint256 score,uint256 nonce,uint256 validUntil)") | Generated by `sol!` macro | ✅ |

---

## 11. Test Coverage Matrix

### 11.1 Signal Coverage

| Signal | Unit Tests | Integration Tests | Edge Cases Covered |
|--------|-----------|-------------------|-------------------|
| Volatility (EWMA) | 10 fuzz | 2 | Zero price, first observation, convergence, overflow |
| Inventory Flow | 9 | 2 | Direction, saturation, opposite direction, unauthorized |
| Whale Score | 3 | 2 | Zero liquidity, zero amount, large trade |
| Oracle Divergence | 7 | 0 | Stale oracle, bounds, direction, unauthorized |
| Composite Oracle | 14 | 0 | All 4 strategies, partial failure, constructor |
| Median Oracle | 12 | 0 | Odd/even count, partial failure, staleness |

### 11.2 System Coverage

| Component | Unit Tests | Integration Tests |
|-----------|-----------|-------------------|
| HookShieldHook | 5 | 6 |
| SignalState | 22 | 0 |
| WeightedRiskModel | 7 | 1 |
| ThresholdPolicy | 6 | 1 |
| AnalyticsEngine | 11 | 0 |
| VolatilityStorage | 6 | 0 |
| InventoryStorage | 7 | 0 |
| ReporterSignalStore | 8 | 0 |

### 11.3 Rust Coverage

| Module | Tests | Coverage Quality |
|--------|-------|-----------------|
| math | 9 | Strong — fuzz-like with realistic values |
| whale | 4 | Good — boundary cases |
| inventory | 9 | Strong — direction, clamp, normalization |
| risk | 4 | Good — stale, zero, hand-verified, cap |
| simulator | 11 | Strong — end-to-end, edge cases, regression |
| snapshot | 3 | Adequate — ordering verification |
| fetcher | 1 | Weak — only 1 real test (ignored) |

### 11.4 Notable Test Gaps

| Gap | Risk | Recommendation |
|-----|------|----------------|
| No fuzz tests for WeightedRiskModel | Medium | Add fuzz tests for weight combinations and signal values |
| No fuzz tests for ThresholdPolicy boundaries | Low | Add fuzz tests around threshold edges |
| No integration test for ReporterSignalStore → RiskModel pipeline | Medium | Add test verifying reporter scores affect fees (when wired) |
| No stress test for CompositeOracle with many sources | Low | Add test with 10+ sources |
| No test for hook upgradeability/redeployment | Medium | Add deployment test |
| Rust fetcher has only 1 ignored test | Low | Add unit test with mock data |

---

## 12. Rust ↔ Solidity Constant Cross-Check

| Constant | Solidity | Rust | Status |
|----------|----------|------|--------|
| SCALE | 1e18 | 1_000_000_000_000_000_000 | ✅ |
| ALPHA | 0.1e18 | 100_000_000_000_000_000 | ✅ |
| ONE_MINUS_ALPHA | 0.9e18 | 900_000_000_000_000_000 | ✅ |
| FLOW_STEP | 1e18 | 1_000_000_000_000_000_000 | ✅ |
| MAX_FLOW | 10e18 | 10_000_000_000_000_000_000 | ✅ |
| STALE_FALLBACK_RISK | 1e18 | 1_000_000_000_000_000_000 | ✅ |
| STALENESS_WINDOW (default) | 5 minutes | Not implemented | N/A (Rust is offline) |
| Threshold 1 | 0.2e18 → 4000 | 200_000_000_000_000_000 → 4000 | ✅ |
| Threshold 2 | 0.4e18 → 6000 | 400_000_000_000_000_000 → 6000 | ✅ |
| Threshold 3 | 0.6e18 → 9000 | 600_000_000_000_000_000 → 9000 | ✅ |
| Threshold 4 | 0.8e18 → 12000 | 800_000_000_000_000_000 → 12000 | ✅ |
| WeightedRisk default weights | vol=0.3e18, inv=0.2e18, oracle=0.2e18, whale=0.3e18 | Same | ✅ |
| REPORTER_WEIGHT (H-2) | 0.3e18 | 300_000_000_000_000_000 | ✅ |
| REFERENCE_SIZE (M-5) | 1e18 | 1_000_000_000_000_000_000 | ✅ |
| REBALANCE_DISCOUNT (M-4) | 0.5e18 | 500_000_000_000_000_000 | ✅ |
| MAX_PRESSURE | 0.3e18 | 300_000_000_000_000_000 | ✅ |

---

## 13. Open Issues and Recommendations

### Priority 1 (Critical/High — Must Fix)

1. **Rotate committed private key** (C-1): Remove `.env` from git tracking, rotate the deployer key and Etherscan API key, add `.env` to `.gitignore`.

2. **Redeploy hook with 8-param constructor** (H-1): The deployed hook lacks `AnalyticsEngine` integration. Redeploy with the updated `Deploy.s.sol`.

3. ~~**Wire off-chain reporter signals into risk computation** (H-2)~~ — **RESOLVED**: `WeightedRiskModel.risk()` now reads the 5 off-chain fields via `maxFreshReporterScore` and weights them with the owner-tunable `reporterWeight` (default `0.3e18`), gated per-field by H-3 deadlines.

### Priority 2 (Medium — Should Fix)

4. ~~**Add emergency pause mechanism** (M-2)~~ — **RESOLVED**: circuit breaker sets `pauseSwaps` above 0.95e18 with 0.10e18 dead-band hysteresis.

5. **Add rate limiting or cooldown for reporter submissions** (M-3): Consider a minimum block delay between submissions for the same pool/signal type.

6. **Emit events on parameter changes** (L-4): Add events to `ThresholdPolicy.setThresholds()` and `ThresholdPolicy.setFees()` (`WeightedRiskModel` events are done: `WeightsUpdated`, `ReporterWeightUpdated`).

7. ~~**Consider trade-size-aware risk** (M-1)~~ — **RESOLVED**: trade size now feeds the size/liquidity pressure term in `WeightedRiskModel.risk()`.

### Priority 3 (Low — Nice to Have)

8. ~~**Improve oracle failure handling** (M-6)~~ — **RESOLVED**: oracle price `0` now yields divergence `1e18` plus an `OracleUnavailable(poolId, timestamp)` event instead of a silent 0.

9. **Reduce MedianOracle gas cost** (L-5): Consider using a more efficient sorting algorithm for large source counts.

10. **Add comprehensive Rust fetcher tests** (L-1): Create unit tests with mock swap event data.

---

**End of Audit Report 3**
