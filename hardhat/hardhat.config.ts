import { defineConfig, task } from "hardhat/config";
import hardhatViem from "@nomicfoundation/hardhat-viem";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import { executorTasks } from "./tasks/_executor.tasks.js";
import dotenv from "dotenv";
import path from "node:path";

dotenv.config({ path: path.resolve(__dirname, "../.env") });

function env(name: string): string {
  return (process.env[name] ?? "").trim();
}

const PRIVATE_KEY = env("PRIVATE_KEY");
const ARB_RPC_URL = env("ARB_RPC_URL");
const ARB_SEPOLIA_RPC_URL = env("ARB_SEPOLIA_RPC_URL");

const networks: any = {
  hardhat: { type: "edr-simulated" },
};

// Solo añade redes si hay URL (evita errores de config)
if (ARB_RPC_URL) {
  networks.arbitrumOne = {
    type: "http",
    url: ARB_RPC_URL,
    accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    chainId: 42161,
  };
}

if (ARB_SEPOLIA_RPC_URL) {
  networks.arbitrumSepolia = {
    type: "http",
    url: ARB_SEPOLIA_RPC_URL,
    accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    chainId: 421614,
  };
}

// Hardhat 3: task se registra vía .build() y luego se incluye en `tasks: [...]`
const deployExecutor = task("deploy-executor", "Deploy LiquidationExecutor")
  .setAction(() => import("./tasks/deploy-executor.js"))
  .build();

export default defineConfig({
  solidity: {
    version: "0.8.20",
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true },
  },
  networks,

  // IMPORTANT: en Hardhat 3 hay que registrar plugins como objetos en `plugins: [...]`
  // para que agreguen sus tasks (ej: `verify`).
  plugins: [hardhatViem, hardhatVerify],

  // Config del plugin hardhat-verify (usa Etherscan API v2, una sola key multi-chain)
  // Si está vacío, el task `verify` existirá igual, pero fallará al ejecutar por falta de key.
  verify: {
    etherscan: {
      apiKey: env("ETHERSCAN_API_KEY"),
    },
  },

  // IMPORTANT: aquí es donde se registran tus tasks custom
  tasks: [deployExecutor, ...executorTasks],
});

