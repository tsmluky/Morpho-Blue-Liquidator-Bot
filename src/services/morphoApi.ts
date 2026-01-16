import { logger } from "../logger.js";

export type MorphoMarket = {
  uniqueKey: string;
  lltv: string;

  oracleAddress?: string | null;
  irmAddress?: string | null;

  loanAsset: { address: string; symbol: string; decimals: number; priceUsd?: number | null };
  collateralAsset: { address: string; symbol: string; decimals: number; priceUsd?: number | null };
  state?: {
    supplyAssetsUsd?: number | null;
    borrowAssetsUsd?: number | null;
    collateralAssetsUsd?: number | null;
    liquidityAssetsUsd?: number | null;
    fee?: string | number | null;
    utilization?: number | null;
  } | null;
};

export type MorphoPosition = {
  user: { address: string };
  market: {
    uniqueKey: string;
    lltv: string;

    oracleAddress?: string | null;
    irmAddress?: string | null;

    loanAsset: { address: string; symbol: string; decimals: number; priceUsd?: number | null };
    collateralAsset: { address: string; symbol: string; decimals: number; priceUsd?: number | null };
  };
  state: {
    collateral: string;
    borrowAssets: string;
    borrowAssetsUsd?: number | null;
    collateralUsd?: number | null;
  };
};

type GraphQLResp<T> = { data?: T; errors?: Array<{ message: string }> };

function envNum(name: string, def: number): number {
  const raw = process.env[name]?.trim();
  if (!raw) return def;
  const n = Number(raw);
  if (!Number.isFinite(n)) return def;
  return n;
}

async function mapLimit<T, R>(
  items: T[],
  limit: number,
  fn: (item: T, idx: number) => Promise<R>
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let i = 0;

  async function worker() {
    while (true) {
      const idx = i++;
      if (idx >= items.length) return;
      out[idx] = await fn(items[idx]!, idx);
    }
  }

  const n = Math.max(1, Math.min(limit, items.length));
  const workers = Array.from({ length: n }, () => worker());
  await Promise.all(workers);
  return out;
}

export async function morphoQuery<T>(
  url: string,
  query: string,
  variables: Record<string, unknown>,
  signal?: AbortSignal
): Promise<T> {
  const res = await fetch(resolveMorphoApiUrl(url), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, variables }),
    signal,
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`Morpho API HTTP ${res.status}: ${text.slice(0, 500)}`);
  }

  const json = (await res.json()) as GraphQLResp<T>;
  if (json.errors?.length) {
    throw new Error(`Morpho API GraphQL error: ${json.errors.map((e) => e.message).join(" | ")}`);
  }
  if (!json.data) throw new Error("Morpho API: missing data");
  return json.data;
}

export async function fetchTopMarkets(params: {
  url?: string;
  first: number;
  chainIds?: unknown;
  chainId?: unknown;
  signal?: AbortSignal;
}): Promise<MorphoMarket[]> {
  let chainIds = normalizeChainIds(
    (params as any)?.chainIds ??
      (params as any)?.chainId ??
      process.env.CHAIN_ID ??
      42161
  );
  if (chainIds.length === 0) chainIds.push(42161);

  let url =
    (params as any)?.url ??
    process.env.MORPHO_API_URL ??
    process.env.MORPHO_API ??
    "https://api.morpho.org/graphql";
  (params as any).url = url;

  chainIds = (() => {
    const ids = normalizeChainIds(
      (params as any)?.chainIds ??
        (params as any)?.chainId ??
        process.env.CHAIN_ID ??
        42161
    );
    return ids.length ? ids : [42161];
  })();

  url = (params as any)?.url ?? "https://api.morpho.org/graphql";

  const q = `
    query Markets($first: Int!, $chainIds: [Int!]!) {
      markets(
        first: $first
        orderBy: SupplyAssetsUsd
        orderDirection: Desc
        where: { chainId_in: $chainIds }
      ) {
        items {
          uniqueKey
          lltv
          oracleAddress
          irmAddress
          loanAsset { address symbol decimals priceUsd }
          collateralAsset { address symbol decimals priceUsd }
          state {
            supplyAssetsUsd
            borrowAssetsUsd
            collateralAssetsUsd
            liquidityAssetsUsd
            fee
            utilization
          }
        }
      }
    }
  `;

  const firstRaw = (params as any)?.first;
  const firstUnclamped = Number.isFinite(Number(firstRaw)) ? Number(firstRaw) : 25;

  // Mantén este max relativamente bajo para mercados (no suele romper complejidad)
  const maxFirstRaw = process.env.MORPHO_MAX_FIRST ?? 500;
  const maxFirst = Number.isFinite(Number(maxFirstRaw)) ? Number(maxFirstRaw) : 500;

  const first = Math.max(1, Math.min(firstUnclamped, maxFirst));

  const data = await morphoQuery<{ markets: { items: MorphoMarket[] } }>(url, q, { first, chainIds });

  logger.debug({ markets: data.markets.items.length }, "morpho: fetched markets");
  return data.markets.items;
}

export async function fetchTopPositionsForMarkets(params: {
  url: string;
  marketKeys: string[];
  first: number; // lo reinterpretamos como "per-market cap" (top N por market)
}): Promise<MorphoPosition[]> {
  const url =
    (params as any)?.url ??
    process.env.MORPHO_API_URL ??
    process.env.MORPHO_API ??
    "https://api.morpho.org/graphql";
  (params as any).url = url;

  if (!params.marketKeys.length) return [];

  // ---- NUEVO: límites anti-"Query is too complex" ----
  // topMarkets: cuántos markets vas a consultar posiciones (default 80)
  const marketsLimit = Math.max(1, Math.trunc(envNum("MORPHO_POS_MARKETS_LIMIT", 80)));

  // perMarketFirst: cuántas posiciones top pides por market (default 200, cap 1000)
  const perMarketFirstUnclamped =
    Number.isFinite(Number(params.first)) ? Number(params.first) :
    Number.isFinite(Number(process.env.POSITIONS_FIRST)) ? Number(process.env.POSITIONS_FIRST) :
    200;

  const perMarketFirst = Math.max(1, Math.min(Math.trunc(perMarketFirstUnclamped), 1000));

  // concurrencia (default 4)
  const conc = Math.max(1, Math.min(Math.trunc(envNum("MORPHO_POS_CONCURRENCY", 4)), 10));

  const keys = params.marketKeys.slice(0, marketsLimit);

  const q = `
    query PositionsOneMarket($key: String!, $first: Int!) {
      marketPositions(
        first: $first
        orderBy: BorrowShares
        orderDirection: Desc
        where: { marketUniqueKey_in: [$key] }
      ) {
        items {
          user { address }
          market {
            uniqueKey
            lltv
            oracleAddress
            irmAddress
            loanAsset { address symbol decimals priceUsd }
            collateralAsset { address symbol decimals priceUsd }
          }
          state {
            collateral
            borrowAssets
            borrowAssetsUsd
          }
        }
      }
    }
  `;

  const results = await mapLimit(keys, conc, async (key) => {
    try {
      const data = await morphoQuery<{ marketPositions: { items: MorphoPosition[] } }>(
        url,
        q,
        { key, first: perMarketFirst }
      );
      return data.marketPositions.items ?? [];
    } catch (e: any) {
      // si un market falla por validación, no tires todo el scan
      logger.warn({ key, err: String(e?.message ?? e) }, "morpho: positions fetch failed for market");
      return [];
    }
  });

  const flat = results.flat();
  logger.debug(
    { markets: keys.length, perMarketFirst, positions: flat.length, conc },
    "morpho: fetched positions (fan-out)"
  );
  return flat;
}

export function resolveChainId(input?: unknown): number {
  const n =
    typeof input === "number" ? input :
    typeof input === "string" ? Number(input) :
    Number.NaN;

  if (Number.isInteger(n) && n > 0) return n;

  const envRaw =
    process.env.CHAIN_ID ??
    process.env.CHAINID ??
    process.env.ARB_CHAIN_ID ??
    process.env.ARBITRUM_CHAIN_ID ??
    "";

  const envN = Number(envRaw);
  if (Number.isInteger(envN) && envN > 0) return envN;

  return 42161;
}

export function normalizeChainIds(input: unknown): number[] {
  if (Array.isArray(input)) {
    const out = input
      .map((x) => resolveChainId(x))
      .filter((n) => Number.isInteger(n) && n > 0);
    return out.length ? Array.from(new Set(out)) : [42161];
  }

  const one = resolveChainId(input);
  return [one];
}

export function resolveMorphoApiUrl(input?: unknown): string {
  if (typeof input === "string" && input.trim().length > 0) return input;

  const envUrl =
    process.env.MORPHO_API_URL ??
    process.env.MORPHO_API ??
    process.env.MORPHO_GRAPHQL_URL ??
    process.env.MORPHO_API_ENDPOINT ??
    "";

  if (typeof envUrl === "string" && envUrl.trim().length > 0) return envUrl;

  return "https://api.morpho.org/graphql";
}

