import fs from "node:fs/promises";
import { logger } from "../logger.js";
import { loadConfig } from "../config.js";
import { createPublicClient, createWalletClient, http } from "viem";
import { arbitrum } from "viem/chains";
import { privateKeyToAccount } from "viem/accounts";
import { dataPath } from "../lib/data_dir";

function truthyEnv(name: string, def = "0"): boolean {
  return ["1", "true", "yes", "y", "on"].includes(String(process.env[name] ?? def).toLowerCase());
}

function parseAddr(name: string): `0x${string}` {
  const v = String(process.env[name] ?? "").trim();
  if (!/^0x[a-fA-F0-9]{40}$/.test(v)) throw new Error(`exec: invalid ${name}=${v}`);
  return v as `0x${string}`;
}

type ExecutorOrder = {
  market: {
    loanToken: `0x${string}`;
    collateralToken: `0x${string}`;
    oracle: `0x${string}`;
    irm: `0x${string}`;
    lltv: bigint;
  };
  borrower: `0x${string}`;
  repayAssets: bigint;
  repaidShares: bigint;
  seizedAssets: bigint;
  uniPath: `0x${string}`;
  amountOutMin: bigint;
  minProfit: bigint;
  deadline: bigint;
  maxTxGasPrice: bigint;
  referralCode: number;
  nonce: bigint;
};

type PlanItem = {
  ts?: string;
  candidateId?: string;
  marketId: string;
  borrower: string;
  netProfitUsd: number;
  proximity: number | null;
  action: "WATCH" | "EXEC" | "SKIP";
  pass: boolean;
  note?: string;
  order?: ExecutorOrder;
};

type TxPlan = { items: PlanItem[]; generatedAt?: string };

const EXECUTOR_ABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "order",
        type: "tuple",
        components: [
          {
            name: "market",
            type: "tuple",
            components: [
              { name: "loanToken", type: "address" },
              { name: "collateralToken", type: "address" },
              { name: "oracle", type: "address" },
              { name: "irm", type: "address" },
              { name: "lltv", type: "uint256" },
            ],
          },
          { name: "borrower", type: "address" },
          { name: "repayAssets", type: "uint256" },
          { name: "repaidShares", type: "uint256" },
          { name: "seizedAssets", type: "uint256" },
          { name: "uniPath", type: "bytes" },
          { name: "amountOutMin", type: "uint256" },
          { name: "minProfit", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "maxTxGasPrice", type: "uint256" },
          { name: "referralCode", type: "uint16" },
          { name: "nonce", type: "uint256" },
        ],
      },
    ],
    outputs: [],
  },
] as const;

function classifyErr(e: any): { kind: "SKIP_HEALTHY" | "FAIL"; msg: string } {
  const msg = String(e?.shortMessage ?? e?.message ?? e ?? "");
  const m = msg.toLowerCase();
  if (m.includes("position is healthy")) return { kind: "SKIP_HEALTHY", msg };
  return { kind: "FAIL", msg };
}

export async function execCmd() {
  const cfg = loadConfig();

  if (!truthyEnv("EXEC_ENABLED", "0")) {
    throw new Error("exec: blocked (set EXEC_ENABLED=1).");
  }
  if (!cfg.PRIVATE_KEY) {
    throw new Error("exec: PRIVATE_KEY missing in config/env.");
  }

  const EXECUTOR_ADDR = parseAddr("EXECUTOR_ADDR");

  const account = privateKeyToAccount(cfg.PRIVATE_KEY as `0x${string}`);

  const publicClient = createPublicClient({
    chain: arbitrum,
    transport: http(cfg.ARB_RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: arbitrum,
    transport: http(cfg.ARB_RPC_URL),
  });

  const planRaw = await fs.readFile(dataPath("tx_plan.json"), "utf8");
  const plan = JSON.parse(planRaw) as TxPlan;

  const execs = (plan.items ?? [])
    .filter((x) => x.action === "EXEC" && x.pass && x.order)
    .sort((a, b) => Number(b.netProfitUsd) - Number(a.netProfitUsd));

  if (execs.length === 0) {
    logger.info({ exec: 0 }, "exec: nothing to execute (no EXEC+pass items with order)");
    return;
  }

  const deadlineSec = Math.trunc(Number(process.env.ORDER_DEADLINE_SEC ?? "180"));
  const refreshedDeadline = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, deadlineSec));

  let tried = 0;
  let skippedHealthy = 0;
  let failed = 0;

  const maxAgeSec = 30; // 30s max staleness for premium safety
  const planAge = (Date.now() - Date.parse(plan.generatedAt ?? "")) / 1000;
  if (planAge > maxAgeSec) {
    logger.error({ planAge, maxAgeSec }, "exec: plan is STALE (safety abort)");
    return;
  }

  for (const selected of execs) {
    tried++;

    // Safety: Gas Price Cap
    const currentGasPrice = await publicClient.getGasPrice();
    if (currentGasPrice > cfg.MAX_TX_GAS_PRICE_WEI) {
      logger.warn({ currentGasPrice: currentGasPrice.toString(), cap: cfg.MAX_TX_GAS_PRICE_WEI.toString() }, "exec: gas price too high (safety abort)");
      continue;
    }


    const selectedOrder = selected.order!;
    // Refresh deadline/nonce to avoid expiry and nonce collisions
    const refreshedNonce = BigInt(Date.now() + tried);

    const order: ExecutorOrder = {
      ...selectedOrder,
      repayAssets: BigInt(selectedOrder.repayAssets),
      repaidShares: BigInt(selectedOrder.repaidShares),
      seizedAssets: BigInt(selectedOrder.seizedAssets),
      amountOutMin: BigInt(selectedOrder.amountOutMin),
      minProfit: BigInt(selectedOrder.minProfit),
      maxTxGasPrice: BigInt(selectedOrder.maxTxGasPrice),
      deadline: refreshedDeadline,
      nonce: refreshedNonce,
    };

    // Safety: Morpho requires exactly one of seizedAssets/repaidShares to be zero
    const rs = order.repaidShares ?? 0n;
    const sa = order.seizedAssets ?? 0n;
    const exactlyOneZero = (rs === 0n && sa !== 0n) || (rs !== 0n && sa === 0n);
    if (!exactlyOneZero) {
      failed++;
      logger.warn(
        { candidateId: selected.candidateId, repaidShares: rs.toString(), seizedAssets: sa.toString() },
        "exec: invalid liquidation params (exactly one of repaidShares/seizedAssets must be 0) - skipping"
      );
      continue;
    }

    try {
      // Re-Simulate (Double Check)
      // We simulate the EXACT payload we are about to send.
      const sim = await publicClient.simulateContract({
        account,
        address: EXECUTOR_ADDR,
        abi: EXECUTOR_ABI,
        functionName: "execute",
        args: [order],
      });

      // Profit Sanity Check (Optional: check if simulation output matches expectations if ABI allowed return values)
      // For now, we rely on the fact that the contract reverts if minProfit is not met.


      // Broadcast
      // Broadcast with AGGRESSIVE PRIORITY
      // We are in a competitive environment. We pay extra to the miner to get included ASAP.
      const hash = await walletClient.writeContract({
        address: EXECUTOR_ADDR,
        abi: EXECUTOR_ABI,
        functionName: "execute",
        args: [order],
        account,
        gas: sim.request.gas,
        maxPriorityFeePerGas: cfg.TX_PRIORITY_FEE_WEI,
        chain: arbitrum,
      });

      const outPath = dataPath("tx_exec.json");
      const out = {
        generatedAt: new Date().toISOString(),
        executor: EXECUTOR_ADDR,
        selected: {
          candidateId: selected.candidateId,
          marketId: selected.marketId,
          borrower: selected.borrower,
          proximity: selected.proximity,
          netProfitUsd: selected.netProfitUsd,
          note: selected.note,
        },
        from: account.address,
        txHash: hash,
        note: "LIQUIDATION_SENT (simulateContract passed)",
      };

      await fs.writeFile(outPath, JSON.stringify(out, null, 2), "utf8");
      logger.info({ ...out, out: outPath }, "exec: broadcasted liquidation and wrote tx_exec.json");
      return; // stop after first successful execution
    } catch (e: any) {
      const c = classifyErr(e);
      if (c.kind === "SKIP_HEALTHY") {
        skippedHealthy++;

        // --- FORENSIC ANALYSIS START ---
        try {
          // Dynamic import helpers to avoid cluttering top level if strictly needed only here
          // But better to expect imports at top. We will assume imports are added. 
          // (Wait, I need to add imports to the top of the file as well)
          // For now, I will add the logic block and assume imports are available or use direct calls if I can't double-edit.
          // Since I can't double-edit in one go effectively without risk, I will rely on the fact I can edit the whole file or just this block.
          // I will use a helper function defined inside or nearby if possible, but for this tool I must be precise.

          // Let's print the basic info first to confirm we are entering this block
          logger.warn(
            { candidateId: selected.candidateId, marketId: selected.marketId, borrower: selected.borrower },
            "exec: skip (position healthy) - Starting on-chain forensic check..."
          );

          // 1. Get Live Oracle Price
          const oraclePrice = await publicClient.readContract({
            address: selectedOrder.market.oracle,
            abi: [{ name: "price", inputs: [], outputs: [{ type: "uint256" }], type: "function", stateMutability: "view" }] as const,
            functionName: "price",
          });

          // 2. Get Live Position & Market Totals (using raw calls to avoid import mess if possible, or assume imports)
          // I will use the imports I'm about to add.
          // Note: The imports `readPosition`, `sharesToAssetsUp`, `readMarketTotals` need to be present.
          // I will add them in a separate `replace_file_content` if needed, or I can try to simply use the raw `readContract` here for safety.
          // To be safe and self-contained, I'll use raw `readContract` here for `position` and `market`.

          const positionRaw = await publicClient.readContract({
            address: parseAddr("MORPHO_ADDR"), // Using config env or default
            abi: [{ name: "position", inputs: [{ name: "id", type: "bytes32" }, { name: "u", type: "address" }], outputs: [{ name: "s", type: "uint256" }, { name: "b", type: "uint128" }, { name: "c", type: "uint128" }], type: "function", stateMutability: "view" }] as const,
            functionName: "position",
            args: [selected.marketId as `0x${string}`, selected.borrower as `0x${string}`],
          });
          const [supplyShares, borrowShares, collateral] = positionRaw as readonly [bigint, bigint, bigint];

          const marketRaw = await publicClient.readContract({
            address: parseAddr("MORPHO_ADDR"),
            abi: [{ name: "market", inputs: [{ name: "id", type: "bytes32" }], outputs: [{ name: "tsa", type: "uint128" }, { name: "tss", type: "uint128" }, { name: "tba", type: "uint128" }, { name: "tbs", type: "uint128" }, { name: "lu", type: "uint128" }, { name: "fee", type: "uint128" }], type: "function", stateMutability: "view" }] as const,
            functionName: "market",
            args: [selected.marketId as `0x${string}`],
          });
          const [tsa, tss, tba, tbs, lu, fee] = marketRaw as readonly [bigint, bigint, bigint, bigint, bigint, bigint];

          // 3. Calc Borrow Assets
          // sharesToAssetsUp
          let borrowAssets = 0n;
          if (borrowShares > 0n && tbs > 0n) {
            borrowAssets = (borrowShares * tba + tbs - 1n) / tbs;
          }

          // 4. Calc Max Borrow (Collateral Value * LLTV)
          // Output of price() is scale 10^36. 
          // MaxBorrow = (collateral * price * lltv) / 10^18 / 10^36 ?
          // LLTV is WAD (1e18).
          // Formula from Morpho: maxBorrow = mulDivDown(collateral, price, ORACLE_PRICE_SCALE) -> mulDivDown(..., lltv, WAD)
          // Actually simpler: Value = (collateral * price) / 10^36 (assuming 10^36 scale)
          // MaxBorrow = Value * LLTV / 1e18.

          // Let's use BigInt math carefully.
          // Collateral (units) * Price (10^36 per 1 unit) -> 10^36 units.
          // We need to divide by 10^36 to get Loan Units? No.
          // Morpho Blue Math:
          // maxBorrow = (collateral * price * lltv) / (10^36 * 10^18)

          const lltv = BigInt(selectedOrder.market.lltv);
          const ORACLE_SCALE = 10n ** 36n;
          const WAD = 10n ** 18n;

          const maxBorrow = (collateral * oraclePrice * lltv) / (ORACLE_SCALE * WAD);

          const isHealthy = maxBorrow >= borrowAssets;

          // Log it
          logger.error(
            {
              candidate: selected.candidateId,
              API_Proximity: selected.proximity,
              ONCHAIN: {
                borrowAssets: borrowAssets.toString(),
                maxBorrow: maxBorrow.toString(),
                oraclePrice: oraclePrice.toString(),
                collat: collateral.toString(),
                isHealthy
              }
            },
            "FORENSIC: Position Health Check"
          );

        } catch (err: any) {
          logger.error({ err: err.message }, "FORENSIC: Failed to run analysis");
        }
        // --- FORENSIC ANALYSIS END ---

        continue;
      }
      failed++;
      logger.warn(
        { candidateId: selected.candidateId, err: c.msg.slice(0, 500) },
        "exec: simulate failed (non-healthy revert) - trying next"
      );
      continue;
    }
  }

  logger.info({ tried, skippedHealthy, failed }, "exec: no executable order found this cycle");
}
