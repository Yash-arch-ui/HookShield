# HookShield

Dynamic Fee Hook for Uniswap v4

## Overview

HookShield is a Uniswap v4 hook that dynamically adjusts swap fees based on real-time market conditions.

Traditional AMMs use static fee tiers that remain fixed regardless of market volatility or trade conditions. HookShield introduces a dynamic fee mechanism that computes swap fees during execution using external market data and a customizable fee model.

By leveraging Uniswap v4 Hooks, HookShield enables adaptive fee pricing that can better reflect current market risk and trading conditions.

---

## Features

* Dynamic fee calculation during swaps
* Uniswap v4 Hook integration
* External market data support
* Pluggable fee calculation engine
* BeforeSwap and AfterSwap hook execution
* Full integration test coverage
* Modular architecture for future extensions

---

## Architecture

```text
User Swap
    │
    ▼
PoolManager
    │
    ▼
HookShield.beforeSwap()
    │
    ├── Fetch Market Data
    │
    ├── Calculate Volatility
    │
    ├── Compute Dynamic Fee
    │
    ▼
Return Fee Override
    │
    ▼
Swap Execution
    │
    ▼
HookShield.afterSwap()
```

### Components

#### HookShield

Core hook contract responsible for:

* Intercepting swap execution
* Fetching market data
* Computing dynamic fees
* Returning fee overrides to the PoolManager

#### MarketData Provider

Provides external market information such as:

* Asset price
* Market volatility
* Additional risk metrics

#### FeeCalculator

Computes the swap fee using:

* Trade size
* Volatility
* Custom fee logic

---

## Dynamic Fee Model

Current fee calculation:

```solidity
fee = (tradeSize / 1e15 + volatility) % 5000;
```

Inputs:

* Trade Size
* Market Volatility

Output:

* Dynamic LP Fee

The fee model is intentionally modular and can be replaced with more sophisticated risk models.

---

## Project Structure

```text
src/
 ├── HookShield.sol

test/
 ├── Integration/
 │    └── HookShieldFullSwap.test.t.sol

mocks/
 ├── MarketDataMock
 ├── FeeCalculatorMock
 └── MockERC20
```

---

## Testing

The integration test performs the complete lifecycle:

1. Deploy PoolManager
2. Deploy HookShield
3. Initialize Pool
4. Add Liquidity
5. Execute Swap
6. Trigger beforeSwap Hook
7. Compute Dynamic Fee
8. Complete Swap Successfully

Run tests:

```bash
forge test -vvvv
```

Build:

```bash
forge build
```

---

## Technologies Used

* Solidity 0.8.24
* Foundry
* Uniswap v4 Core
* Uniswap v4 Periphery
* OpenZeppelin Contracts

---

## Future Improvements

* Oracle integration
* Volatility-based fee curves
* Multi-asset support
* Dynamic liquidity incentives
* Risk-aware routing
* Machine learning fee strategies

---

## Learning Outcomes

This project explores several advanced Uniswap v4 concepts:

* Hook architecture
* PoolManager interactions
* Dynamic fee overrides
* Unlock callback flow
* Liquidity provisioning
* Swap settlement
* End-to-end integration testing

---

## License

MIT
