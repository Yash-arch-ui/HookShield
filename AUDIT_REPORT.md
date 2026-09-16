# HookShield — Complete Codebase Audit Report

**Date:** 2026-09-16
**Scope:** All contracts under `src/`, `script/`, `test/`
**Toolchain:** Foundry (forge 0.8.26, cancun EVM)

---

## Step 1: Contract Inventory

### 1.1 Active Source Contracts

#### `src/hooks/HookShieldHook.sol`
- **Contract:** `HookShieldHook is IHooks`
- **Constructor:** `constructor(IPoolManager, address _volatilitySignal, address _inventorySignal, address _whaleSignal, address _riskModel, address _policy)`
- **External/Public functions:**
  - `beforeSwap(address, PoolKey, SwapParams, bytes)` → `(bytes4, BeforeSwapDelta, uint24)`
  - `afterSwap(address, PoolKey, SwapParams, BalanceDelta, bytes)` → `(bytes4, int128)`
  - `afterAddLiquidity(...)` → `(bytes4, BalanceDelta)` (pure)
  - `afterRemoveLiquidity(...)` → `(bytes4, BalanceDelta)` (pure)
  - `beforeInitialize(...)` → `bytes4` (pure)
  - `afterInitialize(...)` → `bytes4` (pure)
  - `beforeAddLiquidity(...)` → `bytes4` (pure)
  - `beforeRemoveLiquidity(...)` → `bytes4` (pure)
  - `beforeDonate(...)` → `bytes4` (pure)
  - `afterDonate(...)` → `bytes4` (pure)
  - `getHookPermissions()` → `Hooks.Permissions`
  - `poolManager()` (public state)
  - `volatilitySignal()` (public state)
  - `inventorySignal()` (public state)
  - `whaleSignal()` (public state)
  - `riskModel()` (public state)
  - `policy()` (public state)
  - `latestFee()` (public state)
  - `lastSwapTriggered()` (public state)
- **Imports:** `IHooks`, `Hooks`, `PoolKey`, `BalanceDelta`, `IPoolManager`, `SwapParams`, `ModifyLiquidityParams`, `LPFeeLibrary`, `BeforeSwapDelta`, `PoolId`, `PoolIdLibrary`, `StateLibrary`, `VolatilitySignal`, `InventorySignal`, `WhaleScoreSignal`, `IRiskModel`, `IPolicy`, `PolicyAction`
- **Imported by:** `test/integration/HookShieldFullSwap.t.sol`, `script/Deploy.s.sol`
- **Authorization:** `onlyPoolManager()` modifier (defined but NOT used on any function — the `beforeSwap`/`afterSwap` functions are unprotected. This is standard for Uniswap V4 hooks since the PoolManager is the sole caller, enforced by the core protocol.)
- **No setWriter/setAuthorizedWriter pattern.**

---

#### `src/signals/SignalState.sol`
- **Contract:** `SignalState is Ownable`
- **Struct:** `SignalSnapshot { volatility, inventorySkew, oracleDivergence, whaleScore, updatedAt, validUntil }`
- **Constructor:** `constructor() Ownable(msg.sender)`
- **External/Public functions:**
  - `setVolatility(PoolId, uint256)` (onlyAuthorized)
  - `setInventorySkew(PoolId, uint256)` (onlyAuthorized)
  - `setOracleDivergence(PoolId, uint256)` (onlyAuthorized)
  - `setWhaleScore(PoolId, uint256)` (onlyAuthorized)
  - `getSnapshot(PoolId)` → `SignalSnapshot` (view)
  - `isStale(PoolId)` → `bool` (view)
  - `setAuthorizedWriter(address, bool)` (onlyOwner)
  - `authorizedWriters(address)` → `bool` (public state)
- **Imports:** `PoolId`, `Ownable`
- **Imported by:** `VolatilitySignal`, `WhaleScoreSignal`, `InventorySignal`, `WeightedRiskModel`, test files
- **Authorization:** `onlyAuthorized` modifier + `authorizedWriters` mapping. Owner calls `setAuthorizedWriter`.
- **Call sites for setAuthorizedWriter:**
  - `script/Deploy.s.sol:31` — authorizes VolatilitySignal
  - `script/Deploy.s.sol:36` — authorizes InventorySignal
  - `script/Deploy.s.sol:39` — authorizes WhaleScoreSignal
  - `test/integration/HookShieldFullSwap.t.sol:76,82,87` — same pattern in test

---

#### `src/signals/VolatilitySignal.sol`
- **Contract:** `VolatilitySignal is ISignal`
- **Constructor:** `constructor(address _volatilityStorage, address _signalState)`
- **External/Public functions:**
  - `update(PoolId, uint160 newSqrtPriceX96)` — writes to VolatilityStorage + SignalState
  - `compute(PoolId)` → `uint256` (view)
  - `volatilityStorage()` (immutable public)
  - `signalState()` (immutable public)
- **Imports:** `PoolId`, `VolatilityStorage`, `Volatility`, `ISignal`, `SignalState`
- **Imported by:** `HookShieldHook`, `Deploy.s.sol`, test files
- **Authorization:** Requires being an authorized writer on both `VolatilityStorage` (via `setWriter`) and `SignalState` (via `setAuthorizedWriter`).

---

#### `src/signals/WhaleScoreSignal.sol`
- **Contract:** `WhaleScoreSignal`
- **Constructor:** `constructor(address _poolManager, address _signalState)`
- **External/Public functions:**
  - `update(PoolId, uint256 amountIn, bool zeroForOne)` → `uint256 impactE18` — writes to SignalState
  - `compute(PoolId, uint256, bool)` → `uint256` (view)
  - `SCALE()` (constant public)
  - `poolManager()` (immutable public)
  - `signalState()` (immutable public)
- **Imports:** `PoolId`, `IPoolManager`, `StateLibrary`, `SqrtPriceMath`, `SignalState`
- **Imported by:** `HookShieldHook`, `Deploy.s.sol`, test files
- **Authorization:** Requires being an authorized writer on `SignalState`.

---

#### `src/signals/InventorySignal.sol`
- **Contract:** `InventorySignal`
- **Constructor:** `constructor(address _inventoryStorage, address _signalState)`
- **External/Public functions:**
  - `update(PoolId, bool zeroForOne)` — writes to InventoryStorage + SignalState
  - `compute(PoolId)` → `uint256` (view)
  - `SCALE()` (constant)
  - `FLOW_STEP()` (constant)
  - `MAX_FLOW()` (constant)
  - `inventoryStorage()` (immutable public)
  - `signalState()` (immutable public)
- **Imports:** `PoolId`, `InventoryStorage`, `SignalState`
- **Imported by:** `HookShieldHook`, `Deploy.s.sol`, test files
- **Authorization:** Requires being an authorized writer on both `InventoryStorage` and `SignalState`.

---

#### `src/risk/IRiskModel.sol`
- **Interface:** `IRiskModel`
- **Functions:** `risk(PoolId, uint256)` → `uint256`
- **Imported by:** `WeightedRiskModel`, `HookShieldHook`

---

#### `src/risk/WeightedRiskModel.sol`
- **Contract:** `WeightedRiskModel is IRiskModel, Ownable`
- **Constructor:** `constructor(address _signalState, uint256 _volatilityWeight, uint256 _inventorySkewWeight, uint256 _oracleDivergenceWeight, uint256 _whaleScoreWeight)`
- **External/Public functions:**
  - `risk(PoolId, uint256)` → `uint256` (view)
  - `setWeights(uint256, uint256, uint256, uint256)` (onlyOwner)
  - `signalState()` (immutable public)
  - `volatilityWeight()` (public state)
  - `inventorySkewWeight()` (public state)
  - `oracleDivergenceWeight()` (public state)
  - `whaleScoreWeight()` (public state)
  - `SCALE()` (constant)
  - `STALE_FALLBACK_RISK()` (constant)
- **Imports:** `PoolId`, `Ownable`, `IRiskModel`, `SignalState`, `SignalSnapshot`
- **Imported by:** `HookShieldHook`, `Deploy.s.sol`, test files

---

#### `src/policy/IPolicy.sol`
- **Interface:** `IPolicy`
- **Struct:** `PolicyAction { fee, pauseSwaps, tier }`
- **Functions:** `action(PoolId, uint256)` → `PolicyAction`
- **Imported by:** `ThresholdPolicy`, `HookShieldHook`

---

#### `src/policy/ThresholdPolicy.sol`
- **Contract:** `ThresholdPolicy is IPolicy, Ownable`
- **Constructor:** `constructor() Ownable(msg.sender)`
- **External/Public functions:**
  - `action(PoolId, uint256)` → `PolicyAction` (view)
  - `setThresholds(uint256, uint256, uint256, uint256)` (onlyOwner)
  - `setFees(uint24, uint24, uint24, uint24, uint24)` (onlyOwner)
  - `tier1Threshold..tier4Threshold` (public state)
  - `tier0Fee..tier4Fee` (public state)
  - `SCALE()` (constant)
- **Imports:** `PoolId`, `Ownable`, `IPolicy`, `PolicyAction`
- **Imported by:** `HookShieldHook`, `Deploy.s.sol`, test files

---

#### `src/libraries/Volatility.sol`
- **Library:** `Volatility`
- **Functions:**
  - `calculateReturn(uint160, uint160)` → `uint256` (public pure)
  - `updateEwma(uint256, uint256)` → `uint256` (internal pure)
  - `compute(VolatilityStorage.VolatilityState, uint160)` → `VolatilityStorage.VolatilityState` (internal view)
- **Imports:** `VolatilityStorage`
- **Imported by:** `VolatilitySignal`, test files

---

#### `src/VolatilityStorage.sol`
- **Contract:** `VolatilityStorage`
- **Struct:** `VolatilityState { lastSqrtPriceX96, ewmaVolatility, lastUpdateBlock }`
- **Constructor:** (none — uses `setWriter` one-time pattern)
- **External/Public functions:**
  - `setWriter(address)` — one-time, callable by anyone
  - `getState(PoolId)` → `VolatilityState` (view)
  - `getLastSqrtPriceX96(PoolId)` → `uint160` (view)
  - `getEwmaVolatility(PoolId)` → `uint256` (view)
  - `getLastUpdateBlock(PoolId)` → `uint256` (view)
  - `isInitialized(PoolId)` → `bool` (view)
  - `setState(PoolId, VolatilityState)` (onlyWriter)
  - `updateState(PoolId, uint160, uint256, uint256)` (onlyWriter)
  - `writer()` (public state)
- **Imports:** `PoolId`
- **Imported by:** `VolatilitySignal`, `Volatility` library, test files
- **Authorization:** `onlyWriter` modifier + `setWriter` one-time pattern.
- **Call sites for setWriter:**
  - `script/Deploy.s.sol:30` — sets writer to VolatilitySignal
  - `test/integration/HookShieldFullSwap.t.sol:75` — same

---

#### `src/InventoryStorage.sol`
- **Contract:** `InventoryStorage`
- **Struct:** `InventoryState { netFlow, lastUpdateBlock }`
- **Constructor:** (none — uses `setWriter` one-time pattern)
- **External/Public functions:**
  - `setWriter(address)` — one-time, callable by anyone
  - `getState(PoolId)` → `InventoryState` (view)
  - `setState(PoolId, InventoryState)` (onlyWriter)
  - `writer()` (public state)
- **Imports:** `PoolId`
- **Imported by:** `InventorySignal`, test files
- **Authorization:** `onlyWriter` modifier + `setWriter` one-time pattern.
- **Call sites for setWriter:**
  - `script/Deploy.s.sol:35` — sets writer to InventorySignal
  - `test/integration/HookShieldFullSwap.t.sol:81` — same

---

#### `src/interfaces/ISignal.sol`
- **Interface:** `ISignal`
- **Functions:** `compute(PoolId)` → `uint256`, `update(PoolId, uint160)`
- **Imported by:** `VolatilitySignal`

---

#### `src/interfaces/AggregatorV3Interface.sol`
- **Interface:** `AggregatorV3Interface`
- **Functions:** `decimals()`, `description()`, `version()`, `latestRoundData()`
- **Imported by:** `src/_deprecated/MarketData.sol` (deprecated, not used in active code)

---

### 1.2 Deprecated Contracts (`src/_deprecated/`)

All excluded from compilation via `foundry.toml` `skip` directive.

| File | Contracts | Notes |
|---|---|---|
| `MarketData.sol` | `MarketData` | Chainlink oracle reader, not wired into hook |
| `HookShieldManager.sol` | `HookShieldManager` | Old orchestrator, imports missing `FeeCalculator.sol` |
| `RiskEngine.sol` | `RiskEngine` | Simplified risk scorer, replaced by `WeightedRiskModel` |
| `SignalEngine.sol` | `SignalEngine` | Stub/placeholder, body commented out |
| `HookShield_FeeCalculator_and_VolatilityOracle.sol` | `VolatilityOracle`, `FeeCalculator` | Chainlink-based oracle + fee calc, replaced by signal stack |
| `SignalTypes.sol` | `SignalTypes` library | Old struct definitions, replaced by `SignalState` |

---

## Step 2: Live Data Flow Trace

### `beforeSwap()` Call Sequence

```
beforeSwap(address sender, PoolKey key, SwapParams params, bytes)
│
├─ 1. lastSwapTriggered = true                          [WRITE — hook state]
│
├─ 2. poolId = key.toId()                               [PURE — PoolIdLibrary]
│
├─ 3. tradeSize = |params.amountSpecified|              [PURE — math]
│
├─ 4. whaleSignal.update(poolId, tradeSize, params.zeroForOne)
│     │
│     ├─ 4a. poolManager.getSlot0(poolId)               [READ — PoolManager]
│     ├─ 4b. poolManager.getLiquidity(poolId)           [READ — PoolManager]
│     ├─ 4c. SqrtPriceMath.getNextSqrtPriceFromInput()  [PURE — math]
│     └─ 4d. signalState.setWhaleScore(poolId, impact)  [WRITE — SignalState]
│
├─ 5. riskModel.risk(poolId, tradeSize)
│     │
│     ├─ 5a. signalState.isStale(poolId)                [READ — SignalState]
│     ├─ 5b. signalState.getSnapshot(poolId)            [READ — SignalState]
│     └─ 5c. weight computation                         [PURE — math]
│
├─ 6. policy.action(poolId, riskE18)                    [READ — ThresholdPolicy]
│
├─ 7. latestFee = act.fee                               [WRITE — hook state]
│
├─ 8. emit DynamicFeeComputed(...)                      [EMIT]
│
└─ 9. return (selector, delta, fee | OVERRIDE_FEE_FLAG)
```

### `afterSwap()` Call Sequence

```
afterSwap(address sender, PoolKey key, SwapParams params, BalanceDelta delta, bytes)
│
├─ 1. poolId = key.toId()                               [PURE — PoolIdLibrary]
│
├─ 2. poolManager.getSlot0(poolId)                      [READ — PoolManager]
│     └─ returns currentSqrtPriceX96
│
├─ 3. volatilitySignal.update(poolId, currentSqrtPriceX96)
│     │
│     ├─ 3a. volatilityStorage.getState(poolId)         [READ — VolatilityStorage]
│     ├─ 3b. Volatility.compute(oldState, newPrice)     [PURE — math]
│     ├─ 3c. volatilityStorage.setState(poolId, newState)  [WRITE — VolatilityStorage]
│     └─ 3d. signalState.setVolatility(poolId, ewma)    [WRITE — SignalState]
│
├─ 4. inventorySignal.update(poolId, params.zeroForOne)
│     │
│     ├─ 4a. inventoryStorage.getState(poolId)          [READ — InventoryStorage]
│     ├─ 4b. flow computation                           [PURE — math]
│     ├─ 4c. inventoryStorage.setState(poolId, newState) [WRITE — InventoryStorage]
│     └─ 4d. signalState.setInventorySkew(poolId, skew) [WRITE — SignalState]
│
└─ 5. return (selector, 0)
```

### Architectural Violations Flagged

| Issue | Location | Severity | Description |
|---|---|---|---|
| **WRITE in beforeSwap** | `beforeSwap()` → `whaleSignal.update()` → `signalState.setWhaleScore()` | **Medium** | `beforeSwap` writes to `SignalState` via `whaleSignal.update()`. The comment in code says "Publish the fresh whale score BEFORE reading risk, so this swap's own price impact is included in the fee charged for it." This is intentional by design — the hook wants THIS swap's whale impact reflected in its own fee. However, this means a swap's fee depends on its own state write, which is a deliberate architectural choice rather than a violation. The write happens before `riskModel.risk()` reads, so the fee calculation is based on the updated whale score. |
| **No architectural violation in afterSwap** | `afterSwap()` | **None** | All writes in `afterSwap` are for FUTURE swaps' fee calculations (updating volatility and inventory skew). This swap's fee was already computed in `beforeSwap`. Correct pattern. |

**Summary:** The `beforeSwap` write is intentional and documented. The `afterSwap` writes are correctly post-fee for future swaps. No violations of the read-then-write pattern relative to the swap's own fee calculation.

---

## Step 3: SignalState Schema Cross-Reference

### SignalSnapshot Fields

| Field | Setter in SignalState | Writer Contract | Deployed & Wired? | Weight in RiskModel (Deploy.s.sol) | Status |
|---|---|---|---|---|---|
| `volatility` | `setVolatility()` | `VolatilitySignal` | Yes — `VolatilitySignal` deployed, wired to `SignalState` | `0.4e18` (40%) | **ACTIVE** |
| `inventorySkew` | `setInventorySkew()` | `InventorySignal` | Yes — `InventorySignal` deployed, wired to `SignalState` | `0.3e18` (30%) | **ACTIVE** |
| `oracleDivergence` | `setOracleDivergence()` | **NO WRITER** | **NO** — No oracle signal contract exists | `0` (0%) | **DEAD SCHEMA** |
| `whaleScore` | `setWhaleScore()` | `WhaleScoreSignal` | Yes — `WhaleScoreSignal` deployed, wired to `SignalState` | `0.3e18` (30%) | **ACTIVE** |
| `updatedAt` | Set internally by each `set*()` | N/A (set by all writers) | Yes | N/A | **ACTIVE** (metadata) |
| `validUntil` | Set internally by each `set*()` | N/A (set by all writers) | Yes | N/A | **ACTIVE** (metadata) |

### Dead Schema Fields
- **`oracleDivergence`** — Has a setter (`setOracleDivergence`) and a field in `SignalSnapshot`, but NO signal contract calls it. The `oracleDivergenceWeight` in `WeightedRiskModel` is set to `0` in both `Deploy.s.sol` and the integration test. This is dead code.

### Wired-But-Inert Fields
- None beyond `oracleDivergence` (which is both dead and zero-weight).

---

## Step 4: Test Coverage Audit

### Unit Tests

| Source Contract | Test File | Test Functions | Coverage Assessment |
|---|---|---|---|
| `WeightedRiskModel.sol` | `test/unit/WeightedRiskModel.t.sol` | `test_Constructor_RevertsIfWeightsDontSumToScale`, `test_Risk_ReturnsZeroWhenAllSignalsZero`, `test_Risk_ReturnsFallbackWhenStale`, `test_Risk_ReflectsVolatilityWeight`, `test_SetWeights_OnlyOwner`, `test_SetWeights_RevertsIfDontSumToScale`, `test_SetWeights_SucceedsAndAffectsRisk` | Good |
| `Volatility.sol` (library) | `test/unit/Volatility.t.sol` | 10 fuzz tests: `testFuzz_CalculateReturn*`, `testFuzz_UpdateEwma*`, `testFuzz_Compute*` | Excellent |
| `VolatilityStorage.sol` | `test/unit/VolatilityStorage.t.sol` | `testSetWriter`, `testSetWriteRevertsIfAlreadySet`, `testSetWriterRevertsIfZeroAddress`, `testSetStateRevertsIfNotWriter`, `testSetStateSucceedsFromWriter` (note: `isInitializedFalseBeforeAnyWrites` missing `test` prefix — NOT a test) | Good (one function missing prefix) |
| `SignalState.sol` | `test/unit/SignalState.t.sol` | `testSetVolatilityRevertsIfNotAuthorized`, `testSetVolatilitySucceedsWhenAuthorized`, `testSetVolatilityRevertsAboveOneE18`, `testIsStaleFalseImmediatelyAfterWrite`, `test_IsStale_TrueAfterWarpingPastStalenessWindow`, `test_SetAuthorizedWriter_OnlyOwner`, `test_SetAuthorizedWriter_OwnerCanAuthorize` | Good |
| `WhaleScoreSignal.sol` | `test/unit/WhaleScoreSignal.t.sol` | `test_Compute_ZeroLiquidity_ReturnsMaxScore`, `testComputeZeroAmountReturnsZero`, `testUpdatePublishesToSignalState` | Good |
| `ThresholdPolicy.sol` | `test/unit/ThresholdPolicy.t.sol` | `test_Action_ReturnsTier0BelowFirstThreshold`, `test_Action_ReturnsTier4AboveLastThreshold`, `test_Action_BoundaryValueAtExactThreshold`, `test_SetThresholds_RevertsIfNotOrdered`, `test_SetThresholds_OnlyOwner`, `test_SetFees_OnlyOwner` | Good |
| `VolatilitySignal.sol` | `test/unit/VolatilitySignal.t.sol` | `test_Update_FirstCall_IntializesWithoutPublishing`, `test_Update_PublishesToSignalState`, `test_update_revertsIfCalledByUnauthorizedContract` | Good |

### Integration Tests

| Test File | Test Functions |
|---|---|
| `test/integration/HookShieldFullSwap.t.sol` | `test_FirstSwap_UsesBaseFee`, `test_MultipleSwaps_IncreaseVolatility`, `test_HighVolatility_EventuallyTriggersHigherFeeTier`, `test_Swap_UpdatesInventorySkew`, `test_RepeatedSameDirectionSwaps_IncreaseSkewTowardMax`, `test_OppositeDirectionSwap_ReducesSkew` |

### Contracts with ZERO Test Coverage

| Contract | Status |
|---|---|
| `HookShieldHook.sol` | **NO dedicated unit test.** Only tested indirectly via the integration test. No isolated unit tests for `beforeSwap`, `afterSwap`, `getHookPermissions`, or the pure no-op hooks. |
| `InventorySignal.sol` | **NO dedicated unit test.** Only tested indirectly via the integration test. |
| `InventoryStorage.sol` | **NO dedicated unit test.** Only tested indirectly via the integration test (through InventorySignal). |
| `IPolicy.sol` | Interface only — no test needed. |
| `IRiskModel.sol` | Interface only — no test needed. |
| `ISignal.sol` | Interface only — no test needed. |
| `AggregatorV3Interface.sol` | Interface only — no test needed (deprecated). |

### Test Quirk
- `VolatilityStorage.t.sol:52` — function `isInitializedFalseBeforeAnyWrites` is missing the `test` prefix. It will **never be executed** by `forge test`. This is a silent test gap.

---

## Step 5: Deployment Script Audit

### `script/Deploy.s.sol`

#### Contracts Deployed vs Source Files

| Deployed Contract | Source File | Exists? |
|---|---|---|
| `SignalState` | `src/signals/SignalState.sol` | Yes |
| `VolatilityStorage` | `src/VolatilityStorage.sol` | Yes |
| `VolatilitySignal` | `src/signals/VolatilitySignal.sol` | Yes |
| `InventoryStorage` | `src/InventoryStorage.sol` | Yes |
| `InventorySignal` | `src/signals/InventorySignal.sol` | Yes |
| `WhaleScoreSignal` | `src/signals/WhaleScoreSignal.sol` | Yes |
| `WeightedRiskModel` | `src/risk/WeightedRiskModel.sol` | Yes |
| `ThresholdPolicy` | `src/policy/ThresholdPolicy.sol` | Yes |
| `HookShieldHook` | `src/hooks/HookShieldHook.sol` | Yes |

#### Constructor Argument Verification

| Contract | Deploy.s.sol Call | Actual Constructor | Match? |
|---|---|---|---|
| `SignalState` | `new SignalState()` | `constructor() Ownable(msg.sender)` | **YES** |
| `VolatilityStorage` | `new VolatilityStorage()` | (none) | **YES** |
| `VolatilitySignal` | `new VolatilitySignal(address(volatilityStorage), address(signalState))` | `constructor(address _volatilityStorage, address _signalState)` | **YES** |
| `InventoryStorage` | `new InventoryStorage()` | (none) | **YES** |
| `InventorySignal` | `new InventorySignal(address(inventoryStorage), address(signalState))` | `constructor(address _inventoryStorage, address _signalState)` | **YES** |
| `WhaleScoreSignal` | `new WhaleScoreSignal(poolManagerAddr, address(signalState))` | `constructor(address _poolManager, address _signalState)` | **YES** |
| `WeightedRiskModel` | `new WeightedRiskModel(address(signalState), 0.4e18, 0.3e18, 0, 0.3e18)` | `constructor(address _signalState, uint256 _volatilityWeight, uint256 _inventorySkewWeight, uint256 _oracleDivergenceWeight, uint256 _whaleScoreWeight)` | **YES** |
| `ThresholdPolicy` | `new ThresholdPolicy()` | `constructor() Ownable(msg.sender)` | **YES** |
| `HookShieldHook` | `new HookShieldHook{salt: salt}(IPoolManager(poolManagerAddr), address(volatilitySignal), address(inventorySignal), address(whaleSignal), address(riskModel), address(policy))` | `constructor(IPoolManager _poolManager, address _volatilitySignal, address _inventorySignal, address _whaleSignal, address _riskModel, address _policy)` | **YES** |

#### HookMiner Constructor Args Encoding

Deploy.s.sol constructor args encoding:
```solidity
bytes memory constructorArgs = abi.encode(
    IPoolManager(poolManagerAddr),      // _poolManager
    address(volatilitySignal),          // _volatilitySignal
    address(inventorySignal),           // _inventorySignal
    address(whaleSignal),              // _whaleSignal
    address(riskModel),                // _riskModel
    address(policy)                    // _policy
);
```

Actual HookShieldHook constructor:
```solidity
constructor(
    IPoolManager _poolManager,
    address _volatilitySignal,
    address _inventorySignal,
    address _whaleSignal,
    address _riskModel,
    address _policy
)
```

**Order matches exactly.** The `HookMiner.find` uses the same `constructorArgs` encoding and the same `creationCode`, so the predicted address will match.

#### .env Variable References

| Variable | Referenced In | Present in .env? |
|---|---|---|
| `POOL_MANAGER_ADDRESS` | `Deploy.s.sol:21` | **YES** (line 4) |
| `PRIVATE_KEY` | `Deploy.s.sol:22` | **YES** (line 1) |
| `PRIVATE_KEY` | `DeployPoolManager.s.sol:9` | **YES** (line 1) |
| `PRIVATE_KEY` | `InitializePool.s.sol:19` | **YES** (line 1) |
| `POOL_MANAGER_ADDRESS` | `InitializePool.s.sol:21` | **YES** (line 4) |
| `HOOK_SHIELD_HOOK_ADDRESS` | `InitializePool.s.sol:22` | **YES** (line 13) |
| `PRIVATE_KEY` | `TestSwap.s.sol:16` | **YES** (line 1) |
| `POOL_MANAGER_ADDRESS` | `TestSwap.s.sol:18` | **YES** (line 4) |
| `HOOK_SHIELD_HOOK_ADDRESS` | `TestSwap.s.sol:19` | **YES** (line 13) |
| `CURRENCY0_ADDRESS` | `TestSwap.s.sol:20` | **YES** (line 16) |
| `CURRENCY1_ADDRESS` | `TestSwap.s.sol:21` | **YES** (line 17) |
| `SWAP_ROUTER_ADDRESS` | `TestSwap.s.sol:22` | **YES** (line 18) |

**All referenced .env variables are present. No missing variables.**

### `script/InitializePool.s.sol`

- Deploys `MockERC20` tokens (tokenA, tokenB) and sorts them.
- Creates `PoolSwapTest` and `PoolModifyLiquidityTest` routers.
- Initializes pool with `DYNAMIC_FEE_FLAG`, tick spacing 60, and the hook address from .env.
- Adds 1e18 liquidity in [-600, 600] range.
- **No issues found.**

### `script/DeployPoolManager.s.sol`

- Deploys `PoolManager(deployer)`.
- Uses `PRIVATE_KEY` from .env.
- **No issues found.**

### `script/TestSwap.s.sol`

- Reads addresses from .env, rebuilds PoolKey, executes a single swap.
- **No issues found.**

---

## Step 6: Architecture Scope Comparison

| Module | Exists in src/? | Wired into Hook? | Tested? | Notes |
|---|---|---|---|---|
| **Volatility Signal** | Yes (`VolatilitySignal.sol`, `VolatilityStorage.sol`, `Volatility.sol`) | Yes — called in `afterSwap` | Yes (unit + integration) | Fully wired, 40% weight |
| **Inventory Skew Signal** | Yes (`InventorySignal.sol`, `InventoryStorage.sol`) | Yes — called in `afterSwap` | **NO dedicated unit test** | Fully wired, 30% weight |
| **Oracle Divergence Signal** | **NO** (field exists in `SignalState` but no signal contract) | **NO** (zero weight, no writer) | N/A | Dead schema — field + setter exist but unused |
| **Whale Score Signal** | Yes (`WhaleScoreSignal.sol`) | Yes — called in `beforeSwap` | Yes (unit + integration) | Fully wired, 30% weight |
| **Liquidity Utilization Signal** | **NO** | **NO** | N/A | Entirely absent |
| **Volume Signal** | **NO** | **NO** | N/A | Entirely absent |
| **Flow Imbalance Signal** | **NO** (partially covered by `InventorySignal`) | Partially — `InventorySignal` tracks netFlow direction | Indirect via integration | `InventorySignal` is a simplified version; no separate "FlowImbalance" module |
| **JIT Score Signal** | **NO** | **NO** | N/A | Entirely absent |
| **Sandwich Score Signal** | **NO** | **NO** | N/A | Entirely absent |
| **LVR Score Signal** | **NO** | **NO** | N/A | Entirely absent |
| **Flashloan Score Signal** | **NO** | **NO** | N/A | Entirely absent |
| **MEV Score Signal** | **NO** | **NO** | N/A | Entirely absent |
| **Fee Engine (IFeeCurve)** | **NO** (replaced by `IPolicy`/`ThresholdPolicy`) | Yes — `ThresholdPolicy` serves this role | Yes | Architecture pivoted from curve-based to threshold-based fee policy |
| **Piecewise Curve** | **NO** | **NO** | N/A | Entirely absent |
| **Sigmoid Curve** | **NO** | **NO** | N/A | Entirely absent |
| **Exponential Curve** | **NO** | **NO** | N/A | Entirely absent |
| **Oracle Engine (IOracle)** | **NO** | **NO** | N/A | Entirely absent; `AggregatorV3Interface` exists but only used in deprecated `MarketData.sol` |
| **Analytics Engine** | **NO** | **NO** | N/A | Entirely absent |
| **PoolRegistry** | **NO** | **NO** | N/A | Entirely absent |
| **Off-chain ReporterSignalStore** | **NO** | **NO** | N/A | Entirely absent |
| **Risk Model** | Yes (`IRiskModel.sol`, `WeightedRiskModel.sol`) | Yes — called in `beforeSwap` | Yes | Fully wired |
| **Policy Engine** | Yes (`IPolicy.sol`, `ThresholdPolicy.sol`) | Yes — called in `beforeSwap` | Yes | Fully wired |
| **SignalState** | Yes (`SignalState.sol`) | Yes — central store for all signals | Yes | Fully wired |

### Summary

Of the 12+ planned signal modules, only **3 are implemented and wired** (Volatility, Inventory Skew, Whale Score). The original Fee Engine with Piecewise/Sigmoid/Exponential curves was replaced by a simpler `ThresholdPolicy`. The Oracle Engine, Analytics Engine, PoolRegistry, and ReporterSignalStore infrastructure are entirely absent.

---

## Step 7: Test Suite Results

```
Ran 7 tests for test/unit/WeightedRiskModel.t.sol:WeightedRiskModelTest
[PASS] test_Constructor_RevertsIfWeightsDontSumToScale()
[PASS] test_Risk_ReflectsVolatilityWeight()
[PASS] test_Risk_ReturnsFallbackWhenStale()
[PASS] test_Risk_ReturnsZeroWhenAllSignalsZero()
[PASS] test_SetWeights_OnlyOwner()
[PASS] test_SetWeights_RevertsIfDontSumToScale()
[PASS] test_SetWeights_SucceedsAndAffectsRisk()
Suite result: ok. 7 passed; 0 failed; 0 skipped

Ran 3 tests for test/unit/WhaleScoreSignal.t.sol:WhaleScoreSignalTest
[PASS] testComputeZeroAmountReturnsZero()
[PASS] testUpdatePublishesToSignalState()
[PASS] test_Compute_ZeroLiquidity_ReturnsMaxScore()
Suite result: ok. 3 passed; 0 failed; 0 skipped

Ran 7 tests for test/unit/SignalState.t.sol:SignalStateTest
[PASS] testIsStaleFalseImmediatelyAfterWrite()
[PASS] testSetVolatilityRevertsAboveOneE18()
[PASS] testSetVolatilityRevertsIfNotAuthorized()
[PASS] testSetVolatilitySucceedsWhenAuthorized()
[PASS] test_IsStale_TrueAfterWarpingPastStalenessWindow()
[PASS] test_SetAuthorizedWriter_OnlyOwner()
[PASS] test_SetAuthorizedWriter_OwnerCanAuthorize()
Suite result: ok. 7 passed; 0 failed; 0 skipped

Ran 3 tests for test/unit/VolatilitySignal.t.sol:VolatilitySignalTest
[PASS] test_Update_FirstCall_IntializesWithoutPublishing()
[PASS] test_Update_PublishesToSignalState()
[PASS] test_update_revertsIfCalledByUnauthorizedContract()
Suite result: ok. 3 passed; 0 failed; 0 skipped

Ran 6 tests for test/unit/ThresholdPolicy.t.sol:ThresholdPolicyTest
[PASS] test_Action_BoundaryValueAtExactThreshold()
[PASS] test_Action_ReturnsTier0BelowFirstThreshold()
[PASS] test_Action_ReturnsTier4AboveLastThreshold()
[PASS] test_SetFees_OnlyOwner()
[PASS] test_SetThresholds_OnlyOwner()
[PASS] test_SetThresholds_RevertsIfNotOrdered()
Suite result: ok. 6 passed; 0 failed; 0 skipped

Ran 5 tests for test/unit/VolatilityStorage.t.sol:VolatilityStorageTest
[PASS] testSetStateRevertsIfNotWriter()
[PASS] testSetStateSucceedsFromWriter()
[PASS] testSetWriteRevertsIfAlreadySet()
[PASS] testSetWriter()
[PASS] testSetWriterRevertsIfZeroAddress()
Suite result: ok. 5 passed; 0 failed; 0 skipped

Ran 10 tests for test/unit/Volatility.t.sol:VolatilityFuzzTest
[PASS] testFuzz_CalculateReturnBoundedByPriceRatio()
[PASS] testFuzz_CalculateReturnIsNormalizedByOldPrice()
[PASS] testFuzz_CalculateReturnMatchesFormula()
[PASS] testFuzz_CalculateReturnRevertsOnZeroOldPrice()
[PASS] testFuzz_CalculateReturnZeroForUnchangedPrice()
[PASS] testFuzz_ComputeInitializesWhenNoPriorPrice()
[PASS] testFuzz_ComputeMatchesManualPipeline()
[PASS] testFuzz_UpdateEwmaConvergesTowardsConstantReturn()
[PASS] testFuzz_UpdateEwmaFirstObservation()
[PASS] testFuzz_UpdateEwmaIsConvexCombination()
Suite result: ok. 10 passed; 0 failed; 0 skipped

Ran 6 tests for test/integration/HookShieldFullSwap.t.sol:HookShieldFullSwapTest
[PASS] test_FirstSwap_UsesBaseFee()
[PASS] test_HighVolatility_EventuallyTriggersHigherFeeTier()
[PASS] test_MultipleSwaps_IncreaseVolatility()
[PASS] test_OppositeDirectionSwap_ReducesSkew()
[PASS] test_RepeatedSameDirectionSwaps_IncreaseSkewTowardMax()
[PASS] test_Swap_UpdatesInventorySkew()
Suite result: ok. 6 passed; 0 failed; 0 skipped

Ran 8 test suites in 293.83ms: 47 tests passed, 0 failed, 0 skipped (47 total tests)
```

---

## Next 5 Actions (Prioritized)

1. **Add unit tests for `InventorySignal.sol` and `InventoryStorage.sol`** — These are wired into the live hook with a 30% weight in the risk model but have ZERO dedicated unit tests. The integration test exercises them indirectly, but isolated unit tests are needed for `update()`, `compute()`, `setState()` authorization, and edge cases (MAX_FLOW saturation, opposite-direction decrement).

2. **Add a unit test for `HookShieldHook.sol`** — The core hook contract has no dedicated tests. Add isolated tests for `beforeSwap` (fee computation, event emission, return values), `afterSwap` (signal updates), `getHookPermissions`, and the no-op hooks. The integration test covers the happy path but not edge cases like reverts, unauthorized callers, or zero-liquidity pools.

3. **Fix `VolatilityStorage.t.sol:isInitializedFalseBeforeAnyWrites`** — Rename to `test_IsInitialized_FalseBeforeAnyWrites` so Forge actually executes it. Currently a silent test gap.

4. **Remove or implement `oracleDivergence` field** — The `oracleDivergence` field in `SignalSnapshot` and its setter `setOracleDivergence()` are dead code. Either implement an oracle divergence signal contract (Chainlink-based or TWAP-based) and wire it, or remove the field and setter to reduce contract size and attack surface. The zero weight in `WeightedRiskModel` means it currently has no effect, but it still occupies storage slots and increases gas.

5. **Audit the `beforeSwap` write pattern** — `whaleSignal.update()` writes to `SignalState` inside `beforeSwap`, which means this swap's own whale impact affects its own fee. While intentional, this creates a circular dependency: the fee depends on the whale score, which depends on the trade size, which determines the fee. Consider whether this could be exploited (e.g., a swap that manipulates its own fee by choosing a specific `amountSpecified`). If the design is intentional, document the security rationale explicitly.
