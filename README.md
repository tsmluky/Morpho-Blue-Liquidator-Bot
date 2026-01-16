# MORPHO BLUE LIQUIDATOR

![License](https://img.shields.io/badge/license-MIT-000000?style=flat-square)
![Network](https://img.shields.io/badge/network-Arbitrum_One-000000?style=flat-square)
![Stack](https://img.shields.io/badge/stack-TypeScript_|_Viem-000000?style=flat-square)

## SYSTEM OVERVIEW

A high-frequency MEV liquidation engine engineered for the Morpho Blue protocol on Arbitrum.
This system leverages **Multicall** aggregation and **Atomic Execution** strategies to compete in high-congestion environments with minimal latency overhead.

Designed for operational efficiency, it outperforms standard liquidation bots by aggregating state-reads and utilizing aggressive gas-bidding logic.

---

## CORE ARCHITECTURE

### 1. Multicall Aggregation Engine
Traditional bots make sequential RPC calls (N+1 problem). This system refactors the entire data-fetching layer into a two-stage Multicall process:
*   **Stage 1:** Aggregates market data, oracle prices, and user positions into a single batch.
*   **Stage 2:** Atomically quotes swap routes via Uniswap V3 Quoter.

**Impact:** Reduces cycle time from ~50s to **<10s**, enabling near-real-time block inclusion.

### 2. Probabilistic Gas War Logic
To ensure transaction inclusion during volatility events, the bot employs a dynamic gas strategy:
*   **Priority Fee Injection:** Configurable `TX_PRIORITY_FEE_WEI` (default 5 gwei) to bypass the standard mempool queue.
*   **Volatility Multiplier:** Automatic `1.35x` gas price scaling to prevent "Transaction Underpriced" errors during block congestion.

### 3. Forensic Safety Layer
Execution safety is paramount. Before any transaction is broadcast to the network:
*   **State Simulation:** The exact transaction payload is simulated against the latest block state via `eth_call`.
*   **Health Verification:** A final, atomic check of the target's `Health Factor` prevents execution on solvent positions, eliminating failed transaction costs.

### 4. Zero-Capital Execution in Aave/Morpho
The bot utilizes Flash Loans to fund operations, requiring zero persistent capital for collateral.
*   **Source:** Balancer Vault / Aave Pool.
*   **Mechanism:** Borrow -> Liquidate -> Swap Collateral -> Repay Loan -> Keep Profit.

---

## DEPLOYMENT

### Prerequisites
*   Node.js v20 (LTS)
*   Enterprise-grade RPC Endpoint (Alchemy/Infura/QuickNode)

### Configuration
Configure the runtime environment via `.env`:

```ini
# NETWORK CONFIGURATION
CHAIN_ID=42161
ARB_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# OPERATIONAL WALLET
PRIVATE_KEY=0x...

# EXECUTION STRATEGY
MAX_MARKETS=300                  # Market Scanning Scope
EXEC_PROX_THRESHOLD=1.0003       # Liquidation Trigger Threshold (< 1.0003)

# GAS STRATEGY (MONETIZATION)
TX_PRIORITY_FEE_WEI=5000000000   # 5 Gwei Miner Tip
GAS_PRICE_MULTIPLIER=1.35        # 35% Buffer
```

### Execution

**Dashboard Mode (Visualization)**
Launches a real-time command-line interface with rolling metrics and forensic logs.
```bash
./scripts/run_visual.ps1
```

**Headless Mode (Production)**
Optimized for Docker/Systemd environments.
```bash
npx tsx src/cli.ts cycle --loop
```

---

## DISCLAIMER

This codebase is provided for **educational and research purposes only**.
Running MEV infrastructure involves significant financial risk, including but not limited to smart contract vulnerabilities, gas volatility, and execution failures. The author assumes no liability for financial losses associated with the use of this software.

---

* Engineered by Lukx *
