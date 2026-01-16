import { logger } from "../logger.js";
import { loadConfig } from "../config.js";
import { writeJson, writeJsonl } from "../utils/io.js";
import { fetchTopMarkets, fetchTopPositionsForMarkets } from "../services/morphoApi.js";
import { formatUnits } from "viem";
import { dataPath } from "../lib/data_dir";

function toNum(x: unknown): number | null {
  if (x === null || x === undefined) return null;
  const n = Number(x);
  return Number.isFinite(n) ? n : null;
}



function pickNum(obj: any, keys: string[]): number | null {
  for (const k of keys) {
    const v = obj?.[k];
    const n = toNum(v);
    if (n !== null) return n;
  }
  return null;
}

function toFloatFromUnits(raw: string, decimals: number): number | null {
  try {
    const v = formatUnits(BigInt(raw), decimals);
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  } catch {
    return null;
  }
}

function isAddr(x: unknown): x is string {
  return typeof x === "string" && /^0x[a-fA-F0-9]{40}$/.test(x);
}

// Robustly pick address across possible Morpho GraphQL shapes.
function pickAddr(...candidates: unknown[]): string | null {
  for (const c of candidates) {
    if (isAddr(c)) return c;
    if (c && typeof c === "object") {
      const any = c as any;
      if (isAddr(any.address)) return any.address;
      if (isAddr(any.id)) return any.id; // sometimes address stored as id
    }
  }
  return null;
}

function candidateId(parts: {
  chainId: number;
  marketId: string;
  borrower: string;
  collateralToken: string;
  loanToken: string;
}): string {
  return [
    parts.chainId,
    parts.marketId.toLowerCase(),
    parts.borrower.toLowerCase(),
    parts.collateralToken.toLowerCase(),
    parts.loanToken.toLowerCase(),
  ].join("|");
}

type CandidateStatus = "below_watch" | "watch" | "exec_ready";

type Candidate = {
  candidateId: string;

  marketId: string;
  borrower: string;

  collateralToken: string;
  loanToken: string;

  // NEW: needed for real executor orders
  oracle: string | null;
  irm: string | null;

  collateralSymbol: string;
  loanSymbol: string;

  collateralDecimals: number;
  loanDecimals: number;

  collateralPriceUsd: number | null;
  loanPriceUsd: number | null;

  borrowUsd: number | null;
  collateralUsdEst: number | null;

  // LLTV: keep both normalized and raw WAD
  lltv: number | null;        // normalized 0..1
  lltvWad: string | null;     // raw uint256 string (1e18)
  ltvEst: number | null;      // borrowUsd / collateralUsdEst
  proximity: number | null;   // RISK = (ltvEst / lltv). ~1 near liquidation

  reason: string;
  status: CandidateStatus;
  ts: string;
};

export async function scanCmd() {
  const cfg = loadConfig();
  const now = new Date().toISOString();

  logger.info(
    {
      chainId: cfg.CHAIN_ID,
      morphoApi: cfg.MORPHO_API_URL,
      maxMarkets: cfg.MAX_MARKETS,
      maxPosPerMarket: cfg.MAX_POSITIONS_PER_MARKET,
      watchTh: cfg.LIQ_PROX_THRESHOLD,
      execTh: cfg.EXEC_PROX_THRESHOLD,
      hotQueue: cfg.HOT_QUEUE_SIZE,
    },
    "🔍 [SCAN] Morpho radar sweeping markets..."
  );

  const markets = await fetchTopMarkets({
    url: cfg.MORPHO_API_URL,
    chainId: cfg.CHAIN_ID,
    first: cfg.MAX_MARKETS,
  });

  const marketKeys = markets.map((m) => m.uniqueKey);

  const positions = await fetchTopPositionsForMarkets({
    url: cfg.MORPHO_API_URL,
    marketKeys,
    first: cfg.MAX_POSITIONS_PER_MARKET,
  });

  const candidates: Candidate[] = positions.map((p: any) => {
    const lltvWadRaw = typeof p?.market?.lltv === "string" ? p.market.lltv : null;
    const lltv = lltvWadRaw ? toFloatFromUnits(lltvWadRaw, 18) : null;

    const borrowUsd = toNum(p?.state?.borrowAssetsUsd);

    const collateralToken = String(p?.market?.collateralAsset?.address ?? "");
    const loanToken = String(p?.market?.loanAsset?.address ?? "");

    const collateralSymbol = String(p?.market?.collateralAsset?.symbol ?? "");
    const loanSymbol = String(p?.market?.loanAsset?.symbol ?? "");

    const collateralPrice = toNum(p?.market?.collateralAsset?.priceUsd);
    const loanPrice = toNum(p?.market?.loanAsset?.priceUsd);

    const collateralDec = Number(p?.market?.collateralAsset?.decimals ?? 18);
    const loanDec = Number(p?.market?.loanAsset?.decimals ?? 18);

    // NEW: oracle/irm (must be returned by GraphQL query)
    const oracle = pickAddr(
      p?.market?.oracle?.address,
      p?.market?.oracleAddress,
      p?.market?.oracle
    );

    const irm = pickAddr(
      p?.market?.irm?.address,
      p?.market?.irmAddress,
      p?.market?.irm
    );

    // collateral raw -> normalize
    const collateral = toFloatFromUnits(String(p?.state?.collateral ?? "0"), collateralDec);

    // Prefer USD values computed by Morpho API (avoids unit/decimals mismatches for raw collateral)
    const collateralUsdFromApi =
      pickNum(p?.state, ["collateralAssetsUsd", "collateralAssetsUSD", "collateralUsd", "collateralUSD"]);

    const collateralUsdEst =
      collateralUsdFromApi !== null && Number.isFinite(collateralUsdFromApi) && collateralUsdFromApi > 0
        ? collateralUsdFromApi
        : (collateralPrice !== null && collateral !== null ? collateral * collateralPrice : null);

    // Prefer LTV already computed by API if present; otherwise derive from USD values
    const ltvFromApi = pickNum(p?.state, ["ltv", "loanToValue", "loanToValueRatio"]);
    const ltvEst =
      ltvFromApi !== null && Number.isFinite(ltvFromApi) && ltvFromApi > 0
        ? ltvFromApi
        : (borrowUsd !== null && collateralUsdEst !== null && collateralUsdEst > 0 ? borrowUsd / collateralUsdEst : null);

    // Proximity is RISK ratio: (LTV / LLTV). >=1 => liquidatable (in theory).
    const proxRaw = ltvEst !== null && lltv !== null && lltv > 0 ? ltvEst / lltv : null;

    let reason = "ok";
    if (
      !oracle ||
      !irm ||
      lltv === null ||
      borrowUsd === null ||
      collateralUsdEst === null ||
      ltvEst === null ||
      proxRaw === null
    ) {
      reason = "missing_fields"; // includes oracle/irm missing
    } else if (lltv > 2 || lltv <= 0) {
      reason = "lltv_out_of_range";
    } else if (ltvEst < 0 || ltvEst > 5) {
      reason = "ltv_out_of_range";
    } else {
      reason = "ok";
    }

    const proximity = reason === "ok" ? proxRaw : null;

    let status: CandidateStatus = "below_watch";
    if (proximity !== null && proximity >= cfg.EXEC_PROX_THRESHOLD) status = "exec_ready";
    else if (proximity !== null && proximity >= cfg.LIQ_PROX_THRESHOLD) status = "watch";

    const id = candidateId({
      chainId: cfg.CHAIN_ID,
      marketId: String(p?.market?.uniqueKey ?? ""),
      borrower: String(p?.user?.address ?? ""),
      collateralToken,
      loanToken,
    });

    return {
      candidateId: id,
      marketId: String(p?.market?.uniqueKey ?? ""),
      borrower: String(p?.user?.address ?? ""),

      collateralToken,
      loanToken,

      oracle,
      irm,

      collateralSymbol,
      loanSymbol,

      collateralDecimals: collateralDec,
      loanDecimals: loanDec,

      collateralPriceUsd: collateralPrice,
      loanPriceUsd: loanPrice,

      borrowUsd,
      collateralUsdEst,
      lltv,
      lltvWad: lltvWadRaw,

      ltvEst,
      proximity,

      reason,
      status,
      ts: now,
    };
  });

  const countsByReason: Record<string, number> = {};
  const countsByStatus: Record<string, number> = {};
  for (const c of candidates) {
    countsByReason[c.reason] = (countsByReason[c.reason] ?? 0) + 1;
    countsByStatus[c.status] = (countsByStatus[c.status] ?? 0) + 1;
  }

  const hotQueue = candidates
    .filter((c) => c.reason === "ok" && c.status !== "below_watch" && c.proximity !== null)
    .sort((a, b) => (b.proximity ?? -1) - (a.proximity ?? -1))
    .slice(0, cfg.HOT_QUEUE_SIZE)
    .map((c, idx) => ({ rank: idx + 1, ...c }));

  const top3 = hotQueue.slice(0, 3).map((x) => ({
    rank: x.rank,
    status: x.status,
    proximity: x.proximity,
    borrowUsd: x.borrowUsd,
    collateralUsdEst: x.collateralUsdEst,
    collateral: x.collateralSymbol,
    loan: x.loanSymbol,
    marketId: x.marketId,
    borrower: x.borrower,
    candidateId: x.candidateId,
    oracle: x.oracle,
    irm: x.irm,
  }));

  await writeJson(dataPath("markets.json"), { generatedAt: now, markets });
  await writeJsonl(dataPath("candidates.jsonl"), candidates);
  await writeJson(dataPath("hot_queue.json"), { generatedAt: now, hotQueue });

  await writeJson(dataPath("scan_stats.json"), {
    generatedAt: now,
    markets: markets.length,
    positions: positions.length,
    candidates: candidates.length,
    hotQueue: hotQueue.length,
    countsByReason,
    countsByStatus,
    top3,
    watchTh: cfg.LIQ_PROX_THRESHOLD,
    execTh: cfg.EXEC_PROX_THRESHOLD,
  });

  logger.info(
    {
      markets: markets.length,
      positions: positions.length,
      candidates: candidates.length,
      hotQueue: hotQueue.length,
      topProximity: hotQueue[0]?.proximity ?? null,
      topStatus: hotQueue[0]?.status ?? null,
      countsByReason,
      countsByStatus,
      watchTh: cfg.LIQ_PROX_THRESHOLD,
      execTh: cfg.EXEC_PROX_THRESHOLD,
    },
    hotQueue.length > 0 ? "✅ [SCAN] Targets acquired" : "⏸️  [SCAN] Markets quiet, standing by..."
  );
}


