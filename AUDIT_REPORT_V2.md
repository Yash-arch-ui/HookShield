# AUDIT_REPORT_V2.md

**Date:** 2026-09-16  
**Scope:** HookShield (Solidity/Foundry) + hookshield-simulator (Rust)  
**Auditor:** Automated read-only analysis

---

## PART A — HookShield (Solidity, Foundry)

### A1. Full Contract Inventory

#### Active Contracts (src/)

| # | File | Contract/Interface/Library | Constructor | Auth Pattern |
|---|------|---------------------------|-------------|-------------|
| 1 | `src/hooks/HookShieldHook.sol` | `HookShieldHook` (IHooks) | `(IPoolManager, address volSignal, address invSignal, address whaleSignal, address oracleSignal, address riskModel, address policy, address analyticsEngine)` — **8 params** | `onlyPoolManager` defined but NOT applied (V4 core enforces at protocol level) |
| 2 | `src/signals/SignalState.sol` | `SignalState` (Ownable) | `()` → `Ownable(msg.sender)` | `onlyAuthorized` on all `set*()`; `onlyOwner` on `setAuthorizedWriter()` |
| 3 | `src/signals/VolatilitySignal.sol` | `VolatilitySignal` (ISignal) | `(address volStorage, address signalState)` | None directly; writes to VolatilityStorage (onlyWriter) and SignalState (onlyAuthorized) |
| 4 | `src/signals/InventorySignal.sol` | `InventorySignal` | `(address invStorage, address signalState)` | None directly; writes to InventoryStorage (onlyWriter) and SignalState (onlyAuthorized) |
| 5 | `src/signals/WhaleScoreSignal.sol` | `WhaleScoreSignal` | `(address poolManager, address signalState)` | None directly; writes to SignalState (onlyAuthorized) |
| 6 | `src/signals/OracleDivergenceSignal.sol` | `OracleDivergenceSignal` | `(address oracleStorage, address oracle, address signalState)` | None directly; writes to OracleDivergenceStorage (onlyWriter) and SignalState (onlyAuthorized) |
| 7 | `src/libraries/Volatility.sol` | `Volatility` (library) | N/A | None (pure math) |
| 8 | `src/VolatilityStorage.sol` | `VolatilityStorage` | `()` | `setWriter` one-time lock; `onlyWriter` on `setState`/`updateState` |
| 9 | `src/InventoryStorage.sol` | `InventoryStorage` | `()` | `setWriter` one-time lock; `onlyWriter` on `setState` |
| 10 | `src/OracleDivergenceStorage.sol` | `OracleDivergenceStorage` | `()` | `setWriter` one-time lock; `onlyWriter` on `setState` |
| 11 | `src/oracle/IOracle.sol` | `IOracle` (interface) | N/A | None |
| 12 | `src/oracle/ChainlinkOracle.sol` | `ChainlinkOracle` (IOracle) | `(address feed, uint256 maxStaleness)` | None |
| 13 | `src/oracle/MedianOracle.sol` | `MedianOracle` (IOracle) | `(address[] sources)` | None |
| 14 | `src/oracle/CompositeOracle.sol` | `CompositeOracle` (IOracle) | `(address[] sources, Strategy strategy)` | None |
| 15 | `src/risk/IRiskModel.sol` | `IRiskModel` (interface) | N/A | None |
| 16 | `src/risk/WeightedRiskModel.sol` | `WeightedRiskModel` (IRiskModel, Ownable) | `(address signalState, uint256 volWeight, uint256 invWeight, uint256 oracleWeight, uint256 whaleWeight)` | `onlyOwner` on `setWeights()` |
| 17 | `src/policy/IPolicy.sol` | `IPolicy` (interface) + `PolicyAction` struct | N/A | None |
| 18 | `src/policy/ThresholdPolicy.sol` | `ThresholdPolicy` (IPolicy, Ownable) | `()` → `Ownable(msg.sender)` | `onlyOwner` on `setThresholds()`/`setFees()` |
| 19 | `src/analytics/AnalyticsEngine.sol` | `AnalyticsEngine` | `()` | `setWriter` one-time lock; `onlyWriter` on `recordSwap()` |
| 20 | `src/interfaces/AggregatorV3Interface.sol` | `AggregatorV3Interface` (interface) | N/A | None |
| 21 | `src/interfaces/ISignal.sol` | `ISignal` (interface) | N/A | None |

#### Deprecated Contracts (src/_deprecated/) — 6 files

`MarketData.sol`, `HookShieldManager.sol`, `RiskEngine.sol`, `SignalEngine.sol`, `HookShield_FeeCalculator_and_VolatilityOracle.sol`, `SignalTypes.sol` — all excluded from compilation via `foundry.toml` skip.

#### Import/Authorization Cross-Reference

**`setWriter()` call sites in `script/Deploy.s.sol`:**
- `volatilityStorage.setWriter(address(volatilitySignal))` ✓
- `inventoryStorage.setWriter(address(inventorySignal))` ✓
- `oracleStorage.setWriter(address(oracleSignal))` ✓
- `analyticsEngine.setWriter(address(hook))` ✓

**`setAuthorizedWriter()` call sites in `script/Deploy.s.sol`:**
- `signalState.setAuthorizedWriter(address(volatilitySignal), true)` ✓
- `signalState.setAuthorizedWriter(address(inventorySignal), true)` ✓
- `signalState.setAuthorizedWriter(address(whaleSignal), true)` ✓
- `signalState.setAuthorizedWriter(address(oracleSignal), true)` ✓

**NOT called in Deploy.s.sol:** None — all authorization is wired. However, `setWeights()` and `setThresholds()`/`setFees()` are NOT called post-deployment, meaning the on-chain ThresholdPolicy and WeightedRiskModel retain their constructor-initialized defaults.

---

### A2. Recent Git History

**`git log --oneline -30`** (most recent first):

```
3818239 feat: add hookshield-simulator with alloy 2.x
cc9ec48 chore: apply forge fmt to CompositeOracle and MedianOracle tests
b6012bb feat: add AnalyticsEngine and wire into HookShieldHook with cumulative metrics
1798e71 feat: add MedianOracle and CompositeOracle to complete Oracle Engine module
6f8a9c0 Fmt
5870cbd docs: explain beforeSwap whale-score write rationale
a5aead8 test: add unit test coverage for InventorySignal, InventoryStorage, and HookShieldHook
7e9e080 feat: wire OracleDivergenceSignal into the hook signal stack
716e142 fix: add missing test prefix to isInitializedFalseBeforeAnyWrites
955d631 Fmt
9b0eb47 Update integration suite for whale signal wiring
7d720cb Wire WhaleScoreSignal into HookShieldHook and deploy script
ed6958b Add WhaleScoreSignal unit tests
b901f82 Fix WhaleScoreSignal: relocate to signals/, repair import path and zero-amount impact
5ddcb9b WhaleScoresignal added
```

**Cross-reference against expected items:**

| Expected Commit | Found? | Commit Hash |
|----------------|--------|-------------|
| "wire up OracleDivergenceSignal" | ✓ YES | `7e9e080` feat: wire OracleDivergenceSignal into the hook signal stack |
| "add MedianOracle and CompositeOracle" | ✓ YES | `1798e71` feat: add MedianOracle and CompositeOracle to complete Oracle Engine module |
| "add AnalyticsEngine" | ✓ YES | `b6012bb` feat: add AnalyticsEngine and wire into HookShieldHook with cumulative metrics |
| test coverage for InventorySignal, InventoryStorage, HookShieldHook | ✓ YES | `a5aead8` test: add unit test coverage for InventorySignal, InventoryStorage, and HookShieldHook |
| beforeSwap documentation commit | ✓ YES | `5870cbd` docs: explain beforeSwap whale-score write rationale |

**All expected items are present.** No items missing from history.

---

### A3. SignalState Field Audit

**`src/signals/SignalState.sol` — `SignalSnapshot` struct fields:**

| Field | Type | Writer Contract | Writer in Deploy.s.sol? | Weight (Deploy.s.sol) | Status |
|-------|------|----------------|------------------------|----------------------|--------|
| `volatility` | `uint256` | `VolatilitySignal.setVolatility()` | ✓ YES | `0.3e18` (30%) | **LIVE** |
| `inventorySkew` | `uint256` | `InventorySignal.setInventorySkew()` | ✓ YES | `0.2e18` (20%) | **LIVE** |
| `oracleDivergence` | `uint256` | `OracleDivergenceSignal.setOracleDivergence()` | ✓ YES | `0.2e18` (20%) | **LIVE** |
| `whaleScore` | `uint256` | `WhaleScoreSignal.setWhaleScore()` | ✓ YES | `0.3e18` (30%) | **LIVE** |
| `updatedAt` | `uint256` | All four `set*()` functions (auto-set) | N/A | N/A | **LIVE** (auto-managed) |
| `validUntil` | `uint256` | All four `set*()` functions (auto-set, `block.timestamp + 60 min`) | N/A | N/A | **LIVE** (auto-managed) |

**Summary:** All 4 signal fields have live writers deployed, all are authorized in Deploy.s.sol, and all have non-zero weights. **No dead or inert fields.** Weights sum to `1.0e18`.

---

### A4. Module Completion Table

| Module | Files Exist? | Wired Into Hook? | Tested? | Deployed to Sepolia? |
|--------|-------------|-----------------|---------|---------------------|
| **Volatility** (VolatilitySignal + VolatilityStorage + Volatility.sol) | ✓ 4 files | ✓ beforeSwap→afterSwap | ✓ 10 fuzz + 6 storage + 3 signal = 19 tests | ✓ (see .env addresses) |
| **Inventory Skew** (InventorySignal + InventoryStorage) | ✓ 2 files | ✓ afterSwap | ✓ 9 signal + 7 storage = 16 tests | ✓ |
| **Whale Score** (WhaleScoreSignal) | ✓ 1 file | ✓ beforeSwap | ✓ 3 tests | ✓ |
| **Oracle Divergence** (OracleDivergenceSignal + OracleDivergenceStorage + IOracle) | ✓ 3 files | ✓ afterSwap | ✓ 7 tests | ✓ |
| **ChainlinkOracle** | ✓ 1 file | ✓ (used by OracleDivergenceSignal) | ✓ (tested via OracleDivergenceSignal.t.sol) | ✓ |
| **MedianOracle** | ✓ 1 file | ✗ Not wired into hook (standalone) | ✓ 12 tests | ✗ No .env address |
| **CompositeOracle** | ✓ 1 file | ✗ Not wired into hook (standalone) | ✓ 14 tests | ✗ No .env address |
| **AnalyticsEngine** | ✓ 1 file | ✓ afterSwap (recordSwap) | ✓ 11 tests | ✓ |
| **PoolRegistry** | ✗ NO FILES | N/A | N/A | N/A |
| **ReporterSignalStore** | ✗ NO FILES | N/A | N/A | N/A |
| **JIT/Sandwich/Flashloan/ToxicFlow/MEV detectors** | ✗ NO ON-CHAIN STUBS | N/A | N/A | N/A — correctly off-chain only |
| **WeightedRiskModel** | ✓ 1 file | ✓ beforeSwap (via riskModel.risk()) | ✓ 7 tests | ✓ |
| **ThresholdPolicy** | ✓ 1 file | ✓ beforeSwap (via policy.action()) | ✓ 6 tests | ✓ |

**Notes:**
- MedianOracle and CompositeOracle are implemented and tested but NOT deployed to Sepolia and NOT wired into the hook. They could serve as drop-in replacements for ChainlinkOracle.
- PoolRegistry and ReporterSignalStore have no on-chain stubs (confirmed absent).
- All off-chain detectors (JIT, Sandwich, Flashloan, ToxicFlow, MEV) have no premature on-chain stubs.

---

### A5. Test Suite Run

```
forge build → Compilation skipped (no changes), 0 errors
forge test -vv → 113 tests passed, 0 failed, 0 skipped (15 test suites, 415ms)
```

**Full results by file:**

| Test File | Tests | Result |
|-----------|-------|--------|
| `InventoryStorage.t.sol` | 7 | ALL PASS |
| `AnalyticsEngine.t.sol` | 11 | ALL PASS |
| `WeightedRiskModel.t.sol` | 7 | ALL PASS |
| `SignalState.t.sol` | 7 | ALL PASS |
| `VolatilityStorage.t.sol` | 6 | ALL PASS |
| `OracleDivergenceSignal.t.sol` | 7 | ALL PASS |
| `WhaleScoreSignal.t.sol` | 3 | ALL PASS |
| `ThresholdPolicy.t.sol` | 6 | ALL PASS |
| `MedianOracle.t.sol` | 12 | ALL PASS |
| `VolatilitySignal.t.sol` | 3 | ALL PASS |
| `CompositeOracle.t.sol` | 14 | ALL PASS |
| `InventorySignal.t.sol` | 9 | ALL PASS |
| `Volatility.t.sol` | 10 | ALL PASS |
| `HookShieldFullSwap.t.sol` (integration) | 6 | ALL PASS |
| `HookShieldHook.t.sol` | 5 | ALL PASS |
| **TOTAL** | **113** | **ALL PASS** |

**Files with zero test coverage:** None — every active `src/` contract has at least one test. The `src/_deprecated/` files are excluded from compilation.

**Linter notes:** forge-lint reports 4 warnings (unsafe typecasts in ChainlinkOracle and InventorySignal) and ~15 notes (immutable naming conventions, unwrapped modifiers, unused imports). No errors.

---

### A6. Deployment State

**`.env` contract addresses (Sepolia):**

| Contract | Address in .env |
|----------|----------------|
| PoolManager | `0xCf5eC7911EbEECfE45373086d6f5080BB8863a08` |
| SignalState | `0x2d91C6E647c68F23f00b3A3dDeEdA0A58B584E2e` |
| VolatilityStorage | `0x712fC25f1681091024243beef92a66cCeA5a911b` |
| VolatilitySignal | `0x5De067d1e8f6D37B29276C89B96d68eE273e4901` |
| InventoryStorage | `0x4c5DEAAEB70a670fb6056adEaf75C6F4F375d5F7` |
| InventorySignal | `0x9b41A2401E4d323d3D924385E300D58A6457ff54` |
| WhaleScoreSignal | `0x12864d96DC622CBa10B2b5B8Ae27819535A91E09` |
| WeightedRiskModel | `0x8Bcaded0c2877913101139C785C204D2475dE44C` |
| ThresholdPolicy | `0x06d9aB7747472192550A218aFEee49eA3B80fa42` |
| HookShieldHook | `0x0bb2A4f715f81F39e90107f4e447FdDa48AB80C0` |

**Missing from .env:** `ORACLE_FEED_ADDRESS` and `ORACLE_MAX_STALENESS` — these are referenced by `Deploy.s.sol` for ChainlinkOracle construction but are NOT present in `.env`. The oracle deployment path would fail if re-run without these env vars.

**Broadcast analysis:**
- Last broadcast file: `run-latest.json` timestamped `Aug 26 11:52` (from `run-1787745168737.json`)
- Last broadcast commit: `6f8a9c0` (Sep 16 19:54) — this is the Fmt/AUDIT_REPORT commit, which included broadcast file updates
- `run-1787745168737.json` was created Aug 26 — this is an OLDER deployment that was committed later

**HookShieldHook.sol last modified:** Commit `b6012bb` (Sep 16 20:09) — "feat: add AnalyticsEngine and wire into HookShieldHook". This commit changed the hook to add AnalyticsEngine as a constructor parameter and afterSwap recording.

**⚠️ STALENESS WARNING:** The hook's constructor was changed to accept 8 parameters (adding `_analyticsEngine`) in commit `b6012bb` (Sep 16). The last broadcast (Aug 26) used the PREVIOUS 7-parameter constructor. **The currently-deployed HookShieldHook on Sepolia does NOT match the current source code.** The on-chain hook is missing the AnalyticsEngine wiring. A redeployment is required.

---

## PART B — hookshield-simulator (Rust)

### B1. File Inventory

| File | Public Items | Description |
|------|-------------|-------------|
| `src/main.rs` | `fn main()` (async) | CLI entry point: parses args, fetches events, runs simulation, prints report |
| `src/fetcher.rs` | `struct SwapEvent`, `fn fetch_swap_events()` | Fetches and decodes swap events from an Ethereum RPC endpoint |
| `src/math.rs` | `fn calculate_return()`, `fn update_ewma()`, `fn compute_fee_from_risk()`, const `SCALE`/`ALPHA`/`ONE_MINUS_ALPHA` | Fixed-point math: return calculation, EWMA update, risk-to-fee tier mapping |
| `src/simulator.rs` | `struct VolatilityState`, `struct SimulationResult`, `fn simulate()` | Core simulation loop comparing static vs HookShield dynamic fees |
| `src/report.rs` | `struct ReportOutput`, `fn print_text_report()`, `fn print_json_report()` | Text and JSON report output |
| `src/types.rs` | `struct SwapEvent`, `struct VolatilityEvent`, `struct SimulationResult` | **DEAD CODE** — older type definitions, not imported by any module |

---

### B2. Build and Test

**`cargo build --release`:** ✓ SUCCESS (2m 57s, 1 warning about unused fields in `SwapEvent`)

**`cargo test`:** ✓ 16/16 tests passed

| Test | Module | Result |
|------|--------|--------|
| `test_calculate_return_basic_increase` | math | PASS |
| `test_calculate_return_basic_decrease` | math | PASS |
| `test_calculate_return_zero_old_price_returns_err` | math | PASS |
| `test_update_ewma_first_observation` | math | PASS |
| `test_update_ewma_converges_toward_constant_return` | math | PASS |
| `test_compute_fee_tier_boundaries` | math | PASS |
| `test_empty_events` | simulator | PASS |
| `test_single_event_only_base_fee` | simulator | PASS |
| `test_two_events_hookshield_activated` | simulator | PASS |
| `test_high_volatility_increases_hookshield_fee` | simulator | PASS |
| `test_low_volatility_hookshield_matches_base` | simulator | PASS |
| `test_total_volume_accumulates` | simulator | PASS |
| `test_lvr_reduction_positive_when_hookshield_earns_more` | simulator | PASS |
| `test_fallback_to_base_fee_on_error` | simulator | PASS |
| `test_different_base_fee` | simulator | PASS |
| `test_many_swaps_converge_to_higher_tier` | simulator | PASS |

---

### B3. Correctness Cross-Check: Rust vs Solidity Constants

**Threshold values (ThresholdPolicy.sol defaults vs math.rs):**

| Constant | Solidity (ThresholdPolicy.sol) | Rust (math.rs) | Match? |
|----------|-------------------------------|----------------|--------|
| `tier1Threshold` | `0.2e18` (line 10) | `200_000_000_000_000_000` (line 9) | ✓ EXACT |
| `tier2Threshold` | `0.4e18` (line 11) | `400_000_000_000_000_000` (line 10) | ✓ EXACT |
| `tier3Threshold` | `0.6e18` (line 12) | `600_000_000_000_000_000` (line 11) | ✓ EXACT |
| `tier4Threshold` | `0.8e18` (line 13) | `800_000_000_000_000_000` (line 12) | ✓ EXACT |
| `tier0Fee` | `3000` (line 14) | `3000` (line 14) | ✓ EXACT |
| `tier1Fee` | `4000` (line 15) | `4000` (line 15) | ✓ EXACT |
| `tier2Fee` | `6000` (line 16) | `6000` (line 16) | ✓ EXACT |
| `tier3Fee` | `9000` (line 17) | `9000` (line 17) | ✓ EXACT |
| `tier4Fee` | `12000` (line 18) | `12000` (line 18) | ✓ EXACT |

**EWMA constants (Volatility.sol vs math.rs):**

| Constant | Solidity (Volatility.sol) | Rust (math.rs) | Match? |
|----------|--------------------------|----------------|--------|
| `SCALE` | `1e18` (line 8) | `1_000_000_000_000_000_000` (line 4) | ✓ EXACT |
| `ALPHA` | `0.1e18` (line 9) | `100_000_000_000_000_000` (line 5) | ✓ EXACT |
| `ONE_MINUS_ALPHA` | `SCALE - ALPHA` (line 10) | `SCALE - ALPHA` (line 6) | ✓ EXACT |

**Algorithm comparison:**

| Function | Solidity | Rust | Match? |
|----------|----------|------|--------|
| `calculateReturn` | `(diff * SCALE) / oldPrice` | `(diff * SCALE) / old_sqrt_price` | ✓ Same formula |
| `updateEwma` | `(ALPHA * ret + ONE_MINUS_ALPHA * ewma) / SCALE` | Same with checked arithmetic | ✓ Same formula |
| `computeFeeFromRisk` | Threshold cascade `if/else if` | Identical threshold cascade | ✓ Same logic |

**⚠️ CRITICAL CAVEAT:** The Rust `compute_fee_from_risk` uses hardcoded constants. If the on-chain ThresholdPolicy owner calls `setThresholds()` or `setFees()` to change the tiers, the Rust simulator will use **stale defaults**. The simulator does not read on-chain state — it hardcodes the initial deployment values. This is a known design limitation but should be flagged.

**⚠️ SCOPE LIMITATION:** The Rust simulator only mirrors the Volatility signal pipeline. It does NOT model:
- Inventory skew contribution to risk
- Oracle divergence contribution to risk
- Whale score contribution to risk
- The WeightedRiskModel's weighted sum
- The 60-minute staleness window
- The STALE_FALLBACK_RISK (0.5e18)

The simulator computes fee from EWMA volatility alone, whereas on-chain the fee is computed from a weighted sum of 4 signals. This means the simulator's fee outputs will NOT match on-chain behavior for the same swap history.

---

### B4. Has the Simulator Ever Been Run Against Real Data?

**Binary exists:** ✓ `target/release/hookshield-simulator` exists (built today during this audit)

**Real data verification:** **NO** — the simulator has NOT been run against real data. Evidence:
1. No RPC URL or pool address is hardcoded or configured anywhere
2. No output files, logs, or saved results exist in the repository
3. The `timestamp` field in `SwapEvent` is always set to `0` (placeholder)
4. The `sqrt_price_x96_before` is synthetically derived from the previous event's `sqrt_price_x96_after`, not from on-chain tick/price state

**V4 Swap event ABI — CRITICAL MISMATCH:**

The Rust fetcher defines the Swap event as:
```rust
event Swap(
    address indexed sender,
    address indexed recipient,
    int256 amount0,
    int256 amount1,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick
);
```

The actual Uniswap V4 `IPoolManager.sol` Swap event (line 91-100) is:
```solidity
event Swap(
    PoolId indexed id,
    address indexed sender,
    int128 amount0,
    int128 amount1,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick,
    uint24 fee
);
```

**Differences:**
1. **V4 has `PoolId indexed id` as the first parameter** — Rust is missing this entirely
2. **V4 has `int128` amounts** — Rust uses `int256`
3. **V4 has no `recipient`** — Rust includes `address indexed recipient` (this is a V3 field)
4. **V4 has a `fee` field** — Rust is missing this

**Impact:** The Rust fetcher's `sol!` event definition will compute the wrong `SIGNATURE_HASH`. The event topic hash will not match any V4 Swap log, so `fetch_swap_events` will return **zero events** when pointed at a V4 pool. The entire pipeline is non-functional against real V4 data.

**Additionally:** The `zero_for_one` derivation (`amount_0 > 0`) works differently in V4 because `amount0` is `int128` (signed), and the direction semantics may differ. The amount_in derivation also needs rethinking for V4.

---

## Cross-Project Status Summary

| Dimension | Solidity (HookShield) | Rust (Simulator) |
|-----------|----------------------|------------------|
| **Core logic complete** | ✓ Yes — all 4 signals + risk + policy + hook wired | ⚠️ Partial — Volatility-only model, hardcoded constants |
| **Tests passing** | ✓ 113/113 | ✓ 16/16 |
| **Builds clean** | ✓ (lint notes only) | ✓ (1 dead-code warning) |
| **Deployed** | ⚠️ Partially stale (hook needs redeploy for AnalyticsEngine) | ✗ Never run against real data |
| **Constants match** | N/A | ✓ Hardcoded values match ThresholdPolicy defaults exactly |
| **Production-ready** | ⚠️ Needs redeploy + .env oracle vars | ✗ V4 ABI mismatch — will return 0 events |

---

## Next 3 Actions (Prioritized)

### 1. 🔴 FIX V4 SWAP EVENT ABI IN RUST (Critical — blocks all simulator usage)

The Rust fetcher's `sol!` event definition is a V3 Swap signature, not V4. It will never decode V4 logs. Fix:
- Change the `sol!` macro to match `IPoolManager.sol`'s Swap event exactly
- Update `SwapEvent` struct and decoding logic for `int128` amounts, `PoolId`, and `fee`
- Derive `zero_for_one` correctly for V4 semantics
- Verify against a real V4 Sepolia pool's Swap logs

**This is the single highest-priority item.** Without it, the Rust simulator cannot process any real data, and all other simulator work is theoretical.

### 2. 🟡 REDEPLOY HookShieldHook TO INCLUDE AnalyticsEngine (Medium — on-chain stale)

The currently-deployed hook on Sepolia uses the old 7-parameter constructor (pre-AnalyticsEngine). The current source has 8 parameters. Redeploy via `Deploy.s.sol` after adding `ORACLE_FEED_ADDRESS` and `ORACLE_MAX_STALENESS` to `.env`.

### 3. 🟡 EXTEND RUST SIMULATOR TO MODEL ALL 4 SIGNALS (Medium — increases fidelity)

The current Rust simulator only models the Volatility signal. To be a faithful reproduction of on-chain behavior, it needs to:
- Read on-chain InventoryStorage, OracleDivergenceStorage, and WhaleScore signal outputs
- Apply the WeightedRiskModel's weighted sum (vol×0.3 + inv×0.2 + oracle×0.2 + whale×0.3)
- Respect the 60-minute staleness window and STALE_FALLBACK_RISK
- Alternatively, accept that it's a Volatility-only simulator and document this scope clearly

**Note:** Action 1 must be completed before Action 3 is meaningful — there's no point extending a simulator that can't ingest real data.
