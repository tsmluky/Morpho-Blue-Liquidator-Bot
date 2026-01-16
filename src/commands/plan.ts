import fs from "node:fs";
import path from "node:path";
import { parseUnits } from "viem";
import { loadConfig } from "../config.js";
import { logger } from "../logger.js";
import { assetsToSharesUp, readMarketTotals } from "../services/morphoBlue.js";

type PlanAction = "EXEC" | "WATCH" | "SKIP";

type TxPlanItem = {
  ts: string;
  candidateId: string;
  marketId: `0x${string}`;
  borrower: `0x${string}`;

  // IMPORTANT: keep these for exec.ts ranking + debugging
  netProfitUsd: number;
  proximity: number | null;

  action: PlanAction;
  pass: boolean;
  note: string;

  order?: any;
};

type Candidate = {
  candidateId: string;
  marketId: `0x${string}`;
  borrower: `0x${string}`;
  collateralToken: `0x${string}`;
  loanToken: `0x${string}`;
  oracle: `0x${string}` | null;
  irm: `0x${string}` | null;

  collateralSymbol: string;
  loanSymbol: string;
  collateralDecimals: number;
  loanDecimals: number;
  collateralPriceUsd?: number | null;
  loanPriceUsd?: number | null;

  // From scan.ts jsonl
  lltvWad?: string | null;
};

function dataPath(rel: string): string {
  return path.join(process.cwd(), "data", rel);
}

function nowIso(): string {
  return new Date().toISOString();
}

function bigintReplacer(_key: string, value: unknown) {
  return typeof value === "bigint" ? value.toString() : value;
}

function isTruthy(v: unknown): boolean {
  const s = String(v ?? "").trim().toLowerCase();
  return s === "1" || s === "true" || s === "yes" || s === "y" || s === "on";
}

function allowExecNoModel(): boolean {
  // OFF by default, ON only if explicitly enabled
  return isTruthy(process.env.ALLOW_EXEC_NO_MODEL ?? "0");
}

function num(s: string): number | null {
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

function ageSecIso(iso: string | undefined | null): number | null {
  const s = (iso ?? "").trim();
  if (!s) return null;
  const t = Date.parse(s);
  if (!Number.isFinite(t)) return null;
  return (Date.now() - t) / 1000;
}

function readCsv(file: string): { header: string[]; rows: Record<string, string>[] } {
  const raw = fs.readFileSync(file, "utf-8").trim();
  if (!raw) return { header: [], rows: [] };
  const lines = raw.split(/\r?\n/);
  const header = lines[0].split(",").map((x) => x.trim());
  const rows: Record<string, string>[] = [];
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(",");
    const r: Record<string, string> = {};
    for (let j = 0; j < header.length; j++) r[header[j]] = (cols[j] ?? "").trim();
    rows.push(r);
  }
  return { header, rows };
}

function readCandidatesJsonl(file: string): Map<string, Candidate> {
  const m = new Map<string, Candidate>();
  if (!fs.existsSync(file)) return m;
  const raw = fs.readFileSync(file, "utf-8").trim();
  if (!raw) return m;
  const lines = raw.split(/\r?\n/);
  for (const ln of lines) {
    try {
      const o = JSON.parse(ln);
      if (o?.candidateId) m.set(String(o.candidateId), o as Candidate);
    } catch {
      // ignore bad line
    }
  }
  return m;
}

function toUnitsApprox(amount: number, decimals: number): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n;
  const places = Math.min(6, Math.max(0, decimals));
  const s = amount.toFixed(places);
  return parseUnits(s, decimals);
}

function isUsdStable(sym: string): boolean {
  const s = (sym ?? "").toUpperCase();
  return ["USDC", "USDT", "DAI", "USDBC"].includes(s);
}

function parseFeeFromQuoteMode(mode: string): number | null {
  const m = (mode ?? "").match(/fee_(\d+)/i);
  if (!m) return null;
  const n = Number(m[1]);
  return Number.isFinite(n) ? Math.trunc(n) : null;
}

function hexNo0x(h: string): string {
  return h.startsWith("0x") ? h.slice(2) : h;
}

function padFee3Bytes(fee: number): string {
  const f = Math.trunc(Number(fee));
  if (!Number.isFinite(f) || f < 0 || f > 1_000_000) throw new Error(`Invalid fee tier: ${fee}`);
  return f.toString(16).padStart(6, "0");
}

function encodeV3Path(tokens: `0x${string}`[], fees: number[]): `0x${string}` {
  if (tokens.length < 2) throw new Error("encodeV3Path: need at least 2 tokens");
  if (fees.length !== tokens.length - 1) throw new Error("encodeV3Path: fees length mismatch");

  let out = "";
  for (let i = 0; i < tokens.length - 1; i++) {
    const a = hexNo0x(tokens[i]);
    const b = hexNo0x(tokens[i + 1]);
    if (a.length !== 40 || b.length !== 40) throw new Error("encodeV3Path: bad token address length");
    const feeHex = padFee3Bytes(fees[i]);
    if (i === 0) out += a;
    out += feeHex + b;
  }
  return ("0x" + out) as `0x${string}`;
}

export async function planCmd() {
  const cfg = loadConfig();

  const oppFile = dataPath("opportunities.csv");
  const candFile = dataPath("candidates.jsonl");

  if (!fs.existsSync(oppFile)) throw new Error(`Missing ${oppFile}`);
  if (!fs.existsSync(candFile)) throw new Error(`Missing ${candFile}`);

  const candMap = readCandidatesJsonl(candFile);
  const { rows } = readCsv(oppFile);

  const slippageBps = cfg.SLIPPAGE_BPS;
  const maxTxGasPriceWei = BigInt(process.env.MAX_TX_GAS_PRICE_WEI ?? "0");
  const referralCode = Number(process.env.AAVE_REFERRAL_CODE ?? "0");
  const morphoAddr = (process.env.MORPHO_ADDR ?? undefined) as any;

  const maxOppAgeSec = Number(process.env.PLAN_MAX_OPP_AGE_SEC ?? "60");

  const healthyCooldownSec = Number(process.env.HEALTHY_COOLDOWN_SEC ?? "900");
  const healthyCooldownPath = process.env.HEALTHY_COOLDOWN_PATH ??
    path.join(process.cwd(), "data", "healthy_cooldown.json");

  // Map: candidateId -> lastSeenHealthyMs
  function loadHealthyCooldown(): Record<string, number> {
    try {
      if (!Number.isFinite(healthyCooldownSec) || healthyCooldownSec <= 0) return {};
      if (!fs.existsSync(healthyCooldownPath)) return {};
      const raw = fs.readFileSync(healthyCooldownPath, "utf8");
      const obj = JSON.parse(raw || "{}");
      if (!obj || typeof obj !== "object") return {};
      const now = Date.now();
      const out: Record<string, number> = {};
      for (const [k, v] of Object.entries(obj as Record<string, any>)) {
        const n = Number(v);
        if (!Number.isFinite(n)) continue;
        if (now - n <= healthyCooldownSec * 1000) out[k] = n;
      }
      try { fs.writeFileSync(healthyCooldownPath, JSON.stringify(out, null, 2)); } catch { }
      return out;
    } catch {
      return {};
    }
  }

  const healthyCooldown = loadHealthyCooldown();

  // WATCH threshold (relajado) para construir lista "interesante"
  const minProximity = Number(process.env.PLAN_MIN_PROXIMITY ?? cfg.LIQ_PROX_THRESHOLD);

  // EXEC threshold (estricto) para intentar ejecutar. Usar config global.
  const minExecProximity = Number(process.env.PLAN_MIN_EXEC_PROXIMITY ?? cfg.EXEC_PROX_THRESHOLD);

  const maxExecOrders = Math.max(1, Math.min(200, Number(process.env.PLAN_MAX_EXEC_ORDERS ?? "25")));

  // First pass: decide which rows are eligible for order build
  type RowInfo = {
    r: Record<string, string>;
    candidateId: string;
    marketId: `0x${string}`;
    borrower: `0x${string}`;
    netProfitUsd: number;
    proximity: number | null;
    status: string; // from opportunities.csv: watch | exec_ready | below_watch...
    rowAgeSec: number | null;
    isStale: boolean;
    isQuoted: boolean;
    passExec: boolean;
    passModel: boolean;

    // eligible for consideration (quote + filters + freshness + model optional)
    eligible: boolean;
    reasonIfNot: string;

    // eligible to be EXEC (status exec_ready OR proximity>=minExecProximity)
    isExecCandidate: boolean;
    inHealthyCooldown: boolean;
    healthyCooldownRemSec: number | null;
  };

  const enriched: RowInfo[] = rows.map((r) => {
    const candidateId = r["candidateId"];
    const marketId = r["marketId"] as `0x${string}`;
    const borrower = r["borrower"] as `0x${string}`;

    const netProfitUsd = num(r["netProfitUsd"] ?? "") ?? 0;
    const proximity = num(r["proximity"] ?? "");

    const status = String(r["status"] ?? "").trim().toLowerCase();

    const isQuoted = String(r["isQuoted"] ?? r["passQuoted"] ?? "0").trim() === "1";
    const passExec = String(r["passExec"] ?? "0").trim() === "1";
    const passModelRaw = String(r["passModel"] ?? "").trim();
    // Si la columna no existe o viene vacía, no bloquear (neutral=true).
    // Si existe, respeta 0/1.
    const passModel = passModelRaw === "" ? true : passModelRaw === "1";
    const rowAgeSec = ageSecIso(r["ts"]);

    const candId = (r["candidateId"] ?? "").trim();
    const lastHealthy = candId && healthyCooldown[candId] ? healthyCooldown[candId] : null;
    const inHealthyCooldown =
      !!candId &&
      lastHealthy !== null &&
      Number.isFinite(healthyCooldownSec) &&
      healthyCooldownSec > 0 &&
      (Date.now() - Number(lastHealthy)) <= healthyCooldownSec * 1000;

    const healthyCooldownRemSec = inHealthyCooldown
      ? Math.max(0, healthyCooldownSec - (Date.now() - Number(lastHealthy)) / 1000)
      : null;
    const isStale = rowAgeSec !== null && Number.isFinite(maxOppAgeSec) && rowAgeSec > maxOppAgeSec;

    const proxOk =
      proximity !== null &&
      Number.isFinite(minProximity) &&
      proximity >= minProximity;

    const execProxOk =
      proximity !== null &&
      Number.isFinite(minExecProximity) &&
      proximity >= minExecProximity;

    // Eligibility for being considered at all (for WATCH list / ranking)
    let eligible = true;
    let reasonIfNot = "OK";
    if (passExec && inHealthyCooldown) {
      eligible = false;
      reasonIfNot = `HEALTHY_COOLDOWN remSec=${healthyCooldownRemSec?.toFixed(0)}`;
    }
    else if (isStale) { eligible = false; reasonIfNot = `STALE_OPPORTUNITY ageSec=${rowAgeSec?.toFixed(1)}`; }
    else if (!isQuoted) { eligible = false; reasonIfNot = "NO_QUOTE"; }
    else if (!passExec) { eligible = false; reasonIfNot = "EXEC_FILTER"; }
    else if (!proxOk) { eligible = false; reasonIfNot = `PROXIMITY_BELOW_MIN prox=${proximity} min=${minProximity}`; }


    // Critical: Only attempt EXEC if scan says exec_ready OR simulation passed, BUT MUST meet minExecProximity
    const isExecCandidate = ((status === "exec_ready") || passExec) && execProxOk;




    return {
      r,
      candidateId,
      marketId,
      borrower,
      netProfitUsd,
      proximity,
      status,
      rowAgeSec,
      inHealthyCooldown,
      healthyCooldownRemSec,
      isStale,
      isQuoted,
      passExec,
      passModel,
      eligible,
      reasonIfNot,
      isExecCandidate,
    };
  });

  // Pick Top N eligible EXEC candidates by netProfitUsd (desc)
  const chosen = enriched
    .filter((x) => x.eligible && x.isExecCandidate)
    .sort((a, b) => (b.netProfitUsd - a.netProfitUsd))
    .slice(0, maxExecOrders);

  const chosenSet = new Set(chosen.map((x) => x.candidateId));

  const items: TxPlanItem[] = [];
  let execBuilt = 0;
  let execDowngraded = 0;

  // Cache market totals to avoid repeated RPC calls per market
  const totalsCache = new Map<string, any>();

  for (const x of enriched) {
    const { r, candidateId, marketId, borrower, netProfitUsd, proximity } = x;

    let action: PlanAction = "WATCH";
    let note = x.reasonIfNot;
    let pass = false;

    // Mark EXEC only for chosen top N exec-candidates
    if (chosenSet.has(candidateId)) {
      action = "EXEC";
      note = "EXEC_READY";
      pass = true;
    } else {
      action = "WATCH";
      pass = false;

      // Useful note: why it's WATCH only (prevents dryrun spam)
      if (x.eligible && !x.isExecCandidate) {
        note = `WATCH_ONLY status=${x.status || "?"} prox=${proximity} < minExec=${minExecProximity}`;
      }
    }

    const base: TxPlanItem = {
      ts: nowIso(),
      candidateId,
      marketId,
      borrower,
      netProfitUsd,
      proximity,
      action,
      pass,
      note,
    };

    if (action !== "EXEC") {
      items.push(base);
      continue;
    }

    try {
      const c = candMap.get(candidateId);
      if (!c) throw new Error(`candidateId not found in candidates.jsonl`);

      const loanDecimals = Number(c.loanDecimals);
      if (!Number.isFinite(loanDecimals)) throw new Error(`bad loanDecimals`);

      const repayUsd = num(r["repayUsd"] ?? "");
      const requiredNetUsd = num(r["requiredNetUsd"] ?? "");
      const amountOutLoanStr = (r["amountOutLoan"] ?? "").trim();
      const uniPath = (r["uniPath"] ?? "").trim();
      const quoteMode = (r["quoteMode"] ?? "").trim();

      if (!repayUsd || repayUsd <= 0) throw new Error(`bad repayUsd=${r["repayUsd"]}`);
      if (requiredNetUsd === null || requiredNetUsd < 0) throw new Error(`bad requiredNetUsd=${r["requiredNetUsd"]}`);
      if (!amountOutLoanStr) throw new Error(`missing amountOutLoan`);

      const amountOutLoan = BigInt(amountOutLoanStr);

      let repayAssets: bigint;
      let minProfit: bigint;

      if (isUsdStable(c.loanSymbol)) {
        repayAssets = toUnitsApprox(repayUsd, loanDecimals);
        minProfit = toUnitsApprox(requiredNetUsd, loanDecimals);
      } else {
        const px = Number(c.loanPriceUsd ?? 0);
        if (!Number.isFinite(px) || px <= 0) throw new Error(`missing/invalid loanPriceUsd for non-stable loan`);
        repayAssets = toUnitsApprox(repayUsd / px, loanDecimals);
        minProfit = toUnitsApprox(requiredNetUsd / px, loanDecimals);
      }

      if (repayAssets <= 0n) throw new Error(`repayAssets=0`);

      const amountOutMin = (amountOutLoan * BigInt(10_000 - slippageBps)) / 10_000n;

      // On-chain totals (cached per market)
      let totals = totalsCache.get(marketId);
      if (!totals) {
        totals = await readMarketTotals(cfg.ARB_RPC_URL, marketId, morphoAddr);
        totalsCache.set(marketId, totals);
      }

      if (totals.totalBorrowAssets === 0n || totals.totalBorrowShares === 0n) {
        throw new Error(`market totals borrow==0 (cannot compute shares)`);
      }

      const repayAssetsCapped = repayAssets > totals.totalBorrowAssets ? totals.totalBorrowAssets : repayAssets;
      const repaidShares = assetsToSharesUp(repayAssetsCapped, totals.totalBorrowAssets, totals.totalBorrowShares);
      if (repaidShares <= 0n) throw new Error(`repaidShares=0`);

      let pathBytes = uniPath as `0x${string}`;
      if (!pathBytes || pathBytes === "0x") {
        const fee = parseFeeFromQuoteMode(quoteMode);
        if (!fee) throw new Error(`missing uniPath and cannot parse fee from quoteMode=${quoteMode}`);
        pathBytes = encodeV3Path([c.collateralToken, c.loanToken], [fee]);
      }

      if (!c.oracle || !c.irm) throw new Error("missing oracle/irm in candidates.jsonl");
      const lltvWad = (c as any).lltvWad ?? null;
      if (!lltvWad) throw new Error("missing lltvWad in candidates.jsonl");

      const market = {
        loanToken: c.loanToken,
        collateralToken: c.collateralToken,
        oracle: c.oracle,
        irm: c.irm,
        lltv: BigInt(lltvWad),
      };

      const deadlineSec = Math.trunc(Number(process.env.ORDER_DEADLINE_SEC ?? "180"));
      const deadline = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, deadlineSec));

      const nonce = BigInt(Date.now()); // refreshed again in exec.ts / dryrun

      base.order = {
        market,
        borrower,
        repayAssets: repayAssetsCapped,
        repaidShares,
        seizedAssets: 0n,
        uniPath: pathBytes,
        amountOutMin,
        minProfit,
        deadline,
        maxTxGasPrice: maxTxGasPriceWei,
        referralCode: Number.isFinite(referralCode) ? referralCode : 0,
        nonce,
      };

      base.pass = true;
      base.note = "EXEC_READY_WITH_ORDER";
      execBuilt++;
      items.push(base);
    } catch (e: any) {
      base.action = "WATCH";
      base.pass = false;
      base.note = "ORDER_BUILD_FAILED: " + (e?.message ?? String(e));
      execDowngraded++;
      items.push(base);
    }
  }

  const outFile = dataPath("tx_plan.json");
  fs.writeFileSync(
    outFile,
    JSON.stringify({ generatedAt: nowIso(), execBuilt, execDowngraded, items }, bigintReplacer, 2)
  );

  logger.info(
    `plan: wrote ${outFile} | execBuilt=${execBuilt} execDowngraded=${execDowngraded} rows=${items.length} maxExecOrders=${maxExecOrders} minProximity=${minProximity} minExecProximity=${minExecProximity}`
  );
}







