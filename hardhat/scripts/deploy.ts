import "dotenv/config";
import hre from "hardhat";
import { getAddress } from "viem";

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}

function addr(name: string): `0x${string}` {
  const v = env(name);
  if (!v) throw new Error(`Missing env var: ${name}`);
  // Normaliza: si viene en lower/upper/mixed incorrecto, getAddress lo convierte a checksum correcto
  return getAddress(v as `0x${string}`);
}

async function main() {
  // Nota: hre.viem SOLO existe cuando el script lo ejecuta Hardhat (pnpm hardhat run ...).
  const viem = (hre as any).viem;
  if (!viem) {
    throw new Error(
      "hre.viem undefined. Ejecuta este script con `pnpm hardhat run` (no con `node`)."
    );
  }

  const walletClients = await viem.getWalletClients();
  if (!walletClients?.length) {
    throw new Error("No wallet clients: revisa PRIVATE_KEY en .env y accounts en la red.");
  }

  const [deployer] = walletClients;
  const publicClient = await viem.getPublicClient();

  const AAVE_POOL = addr("AAVE_POOL");
  const MORPHO = addr("MORPHO");
  const SWAP_ROUTER = addr("SWAP_ROUTER");
  const TREASURY = addr("TREASURY");

  console.log("Network:", hre.network.name);
  console.log("Deployer:", deployer.account.address);
  console.log("AAVE_POOL:", AAVE_POOL);
  console.log("MORPHO:", MORPHO);
  console.log("SWAP_ROUTER:", SWAP_ROUTER);
  console.log("TREASURY:", TREASURY);

  const LiquidationExecutor = await viem.deployContract("LiquidationExecutor", [
    AAVE_POOL,
    MORPHO,
    SWAP_ROUTER,
    TREASURY,
  ]);

  console.log("LiquidationExecutor:", LiquidationExecutor.address);

  const txHash = LiquidationExecutor.deploymentTransaction?.hash;
  if (txHash) {
    console.log("Tx:", txHash);
    const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
    console.log("Block:", receipt.blockNumber);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
