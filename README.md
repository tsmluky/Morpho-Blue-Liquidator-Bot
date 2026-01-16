# Morpho Blue Liquidator Bot

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Network](https://img.shields.io/badge/network-Arbitrum_One-blue)
![Stack](https://img.shields.io/badge/stack-Viem_|_TypeScript-gray)

A high-performance, **Multicall-optimized** MEV bot designed to detect and execute liquidations on Morpho Blue markets (Arbitrum).
Built for speed, efficiency, and competitiveness without requiring expensive infrastructure.

---

## Key Features

*   **Multicall Engine:** Refactored `Scanner` and `Quoter` to aggregate 50+ RPC calls into a *single batch request*.
    *   *Result:* Cycle time reduced from ~55s to **<10s** on free RPCs.
*   **Gas War Strategy:**
    *   **Dynamic Bribery:** Configurable `TX_PRIORITY_FEE_WEI` to outbid standard transactions in the mempool.
    *   **Smart Multiplier:** `GAS_PRICE_MULTIPLIER` ensures transaction inclusion during volatility spikes.
*   **Forensic Safety:**
    *   **Zero-Risk Exec:** Simulates the exact liquidation transaction on-chain before broadcasting.
    *   **Health Check:** Verifies the position's `Health Factor` immediately before execution to prevent wasting gas on "healthy" positions.
*   **Flash Loan Powered:**
    *   Uses **Balancer Flashloans** (0 fee) or similar executing contracts to liquidate without operational capital.

---

## Architecture

The bot operates in a tight loop:
1.  **SCAN:** Fetches `MAX_MARKETS` (e.g. 300) from Morpho API.
2.  **FILTER:** Identifies positions with `Health Factor < 1.0003` (Aggressive Threshold).
3.  **QUOTE:** Uses **Multicall** to check Uniswap V3 execution paths for collateral swaps.
4.  **SIMULATE:** Dry-runs the liquidation contract call via `eth_call`.
5.  **EXECUTE:** Broadcasts the transaction with high priority fee if profitable.

---

## Setup & Configuration

### Prerequisites
- Node.js v20+
- An Orbitrum RPC URL (Alchemy/Infura)

### Installation
```bash
git clone https://github.com/yourusername/morpho-liquidator.git
cd morpho-liquidator
pnpm install
```

### Environment (.env)
Copy `.env.example` to `.env` and configure:
```ini
# Chain
CHAIN_ID=42161
ARB_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY

# Wallet (Private Key)
PRIVATE_KEY=0x...

# Strategy
MAX_MARKETS=300
EXEC_PROX_THRESHOLD=1.0003  # Aggressive (< 1.0003 HF triggers check)

# Gas War (Monetization)
TX_PRIORITY_FEE_WEI=5000000000 # 5 Gwei Priority Tip
GAS_PRICE_MULTIPLIER=1.35
```

---

## Running the Bot

**Visual Mode (Dashboard):**
```bash
./scripts/run_visual.ps1
```
Displays a real-time dashboard with rolling logs and cycle metrics.

**Headless Mode (Server/Docker):**
```bash
npx tsx src/cli.ts cycle --loop
```

---

## Disclaimer
This software is for educational purposes. Running MEV bots involves financial risk (gas costs, smart contract bugs). Use at your own risk.

---

*Built by [Lukx]*
