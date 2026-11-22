#!/usr/bin/env node
// Across bridge adapter on TRON: deploy it, register it with the guard, and turn on its routes.
//
//   node across.mjs deploy  --network mainnet [--guard T…] [--fee-recipient T…]
//                           [--vault-factory T…] [--vault-initcode-hash 0x…] [--register] [--dry-run]
//   node across.mjs routes  --network mainnet [--guard T…] [--set] [--dry-run]
//                                       show the guard's Across routes out of TRON; --set marks USDT
//                                       bridgeable and writes the missing routes
//   node across.mjs status  --network mainnet
//
// Mainnet only: Across has no SpokePool on Nile (docs.across.to/chains-and-contracts lists none).
// Build first: FOUNDRY_PROFILE=tron forge build (in protocol-store). deploy does it unless --no-build.
//
// Keys (hex, never committed):
//   TRON_PRIVATE_KEY  deploy --register: holds the guard's PROTOCOL_MANAGER_ROLE.
//                     routes --set: holds its ASSET_MANAGER_ROLE and CONFIG_MANAGER_ROLE.
//   TRON_PRO_API_KEY  optional, TronGrid rate limits.
//
// The SpokePool is Across's Tron_SpokePool (an ERC-1967 proxy). Read on 2026-11-17: its `deposit` is
// the bytes32 one the adapter calls, wrappedNativeToken() is WTRX and chainId() is 728126428. The
// routes are the ones app.across.to/api/available-routes lists from TRON to the chains Bitty runs on,
// USDT only, each to that chain's USDT, as in the guard repo's script/AcrossRoutes.s.sol.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { AbiCoder, keccak256, toUtf8Bytes } from "ethers";
import { toBase58, toEvm } from "./lib/address.mjs";
import { Chain } from "./lib/chain.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");
const abi = AbiCoder.defaultAbiCoder();
const PROTOCOL_BRIDGE = 5;
const ASSET_BRIDGEABLE = 8;
// 1%, as on the EVM chains (AcrossRoutes.s.sol's MAX_COST_BPS); the adapter caps it at 3%.
const MAX_COST_BPS = 100;
const LINEAGE = keccak256(toUtf8Bytes("bitty.adapter.across.bridge"));
const ROUTE_KEY = keccak256(toUtf8Bytes("bitty.bridge.across.route"));
const NAME = "TronAcrossBridgeProtocol";

const NETWORKS = {
  mainnet: {
    fullHost: "https://api.trongrid.io",
    chainId: 728126428,
    spokePool: "TTbCVPfUZmPhrB9sYC8GKgGBQQEdZovkmS",
    wtrx: "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR",
    usdt: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    guard: "0xf022C72D48c2E3B81731dbA6649BF780302c0035", // TXrvqX2YMe7N7Muiaxuu2Fs1smTB4sSR3n, deployed 2026-11-22
    feeRecipient: "TBhJVW1mRTVyyNVbhpCyVVgSAVrP5vaS2o", // decided 2026-11-22: the deployer, as SunSwap's
    // The TRON vault factory and its proxy init-code hash: the adapter checks a vault is the factory's
    // CREATE2 of the creation owner a bridge names (vault repo tron/, mainnet plan 2026-11-22; the
    // factory's own vaultAddress() matches this hash on chain).
    vaultFactory: "TH9QaqjfK9Yutk2suGzoE9sFXzYGj6y5dk", // 0x4eB6…291F, deployed 2026-11-22
    vaultInitCodeHash: "0xa2268803d8f227cb4a2a12b068deee34869044ce8ceb1d3d6bbfdcca0a33a151",
    feeLimitTrx: 1_000,
    // TRON USDT (6 decimals) to each chain's USDT.
    routes: [
      { chainId: 1, name: "Ethereum", token: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6 },
      { chainId: 8453, name: "Base", token: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2", decimals: 6 },
      { chainId: 42161, name: "Arbitrum", token: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6 },
      { chainId: 56, name: "BNB Chain", token: "0x55d398326f99059fF775485246999027B3197955", decimals: 18 },
    ],
  },
};

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    rpc: { type: "string" }, // a node URL instead of the network's fullHost (e.g. Alchemy's, key in the path)
    network: { type: "string", default: "mainnet" },
    "fee-recipient": { type: "string" },
    register: { type: "boolean", default: false },
    set: { type: "boolean", default: false },
    guard: { type: "string" }, // the guard's address, until it is recorded below
    "vault-factory": { type: "string" },
    "vault-initcode-hash": { type: "string" },
    "dry-run": { type: "boolean", default: false },
    "no-build": { type: "boolean", default: false },
  },
});
const command = positionals[0];
const network = NETWORKS[values.network];
if (!network) throw new Error(`unknown network ${values.network}: Across runs on TRON mainnet only`);
const statePath = join(repo, "deployments", `tron-${values.network}.json`);
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};

const chain = new Chain({
  fullHost: values.rpc || network.fullHost,
  privateKey: process.env.TRON_PRIVATE_KEY,
  apiKey: process.env.TRON_PRO_API_KEY,
  feeLimitTrx: network.feeLimitTrx,
  dryRun: values["dry-run"],
});

function configured(key) {
  if (key === "guard" && values.guard) return toEvm(values.guard);
  if (network[key] === "TODO") throw new Error(`${values.network}: ${key} is still TODO`);
  return toEvm(network[key]);
}

function vaultFactory() {
  if (values["vault-factory"]) return toEvm(values["vault-factory"]);
  return configured("vaultFactory");
}

function vaultInitCodeHash() {
  const h = values["vault-initcode-hash"] ?? network.vaultInitCodeHash;
  if (!/^0x[0-9a-fA-F]{64}$/.test(h)) throw new Error(`${values.network}: vault init-code hash is ${h}, not a bytes32`);
  return h.toLowerCase();
}

function feeRecipient() {
  if (values["fee-recipient"]) return toEvm(values["fee-recipient"]);
  return configured("feeRecipient");
}

const both = (a) => `${toBase58(a)} (${toEvm(a)})`;

function build() {
  if (!values["no-build"]) {
    execFileSync("forge", ["build"], { cwd: repo, stdio: "inherit", env: { ...process.env, FOUNDRY_PROFILE: "tron" } });
  }
}

function artifact(file, contract) {
  const path = join(repo, "out-tron", file, `${contract}.json`);
  if (!existsSync(path)) throw new Error(`${path} missing: run FOUNDRY_PROFILE=tron forge build`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  return { abi: json.abi ?? [], bytecode: json.bytecode.object };
}

/** The adapter's routeKey and packRoute, so routes can be read and set before it is deployed. */
const routeKey = (inputToken, chainId) =>
  keccak256(abi.encode(["bytes32", "address", "uint256"], [ROUTE_KEY, inputToken, chainId]));
const packRoute = (token, decimals, maxCost) =>
  BigInt(token) | (BigInt(decimals) << 160n) | (BigInt(maxCost) << 168n);

async function requireRole(guard, role) {
  if (!chain.sender) throw new Error("TRON_PRIVATE_KEY is not set");
  const id = await chain.read(guard, `function ${role}() view returns (bytes32)`);
  if (!(await chain.read(guard, "function hasRole(bytes32,address) view returns (bool)", [id, chain.sender]))) {
    throw new Error(`${both(chain.sender)} does not hold the guard's ${role}`);
  }
}

async function checkSpokePool() {
  const spokePool = configured("spokePool");
  const [wrapped, id] = await Promise.all([
    chain.read(spokePool, "function wrappedNativeToken() view returns (address)"),
    chain.read(spokePool, "function chainId() view returns (uint256)"),
  ]);
  if (wrapped !== configured("wtrx") || BigInt(id) !== BigInt(network.chainId)) {
    throw new Error(`SpokePool ${both(spokePool)} reads back wrong: wrappedNativeToken ${wrapped}, chainId ${id}`);
  }
  return spokePool;
}

// ---------------------------------------------------------------- deploy

async function deploy() {
  const guard = configured("guard");
  const recipient = feeRecipient();
  const factory = vaultFactory();
  const initCodeHash = vaultInitCodeHash();
  if ((await chain.chainId()) !== network.chainId) throw new Error("connected to the wrong chain");
  const spokePool = await checkSpokePool();
  build();
  const impl = artifact(`${NAME}.sol`, NAME);

  let address = state[NAME];
  if (address && (await chain.hasCode(address))) {
    console.log(`${NAME} already at ${both(address)}`);
  } else {
    const args = abi
      .encode(["address", "address", "address", "address", "bytes32"], [spokePool, guard, recipient, factory, initCodeHash])
      .slice(2);
    address = await chain.deployContract({ abi: impl.abi, bytecode: impl.bytecode + args, name: NAME });
    if (chain.dryRun) return;
    state[NAME] = address;
    save();
    console.log(`${NAME} deployed at ${both(address)}`);
  }

  // What was deployed is what was meant.
  const [readSpoke, readGuard, readFee, readFactory, readHash, lineage] = await Promise.all([
    chain.read(address, "function spokePool() view returns (address)"),
    chain.read(address, "function bittyGuard() view returns (address)"),
    chain.read(address, "function feeRecipient() view returns (address)"),
    chain.read(address, "function tronVaultFactory() view returns (address)"),
    chain.read(address, "function tronVaultInitCodeHash() view returns (bytes32)"),
    chain.read(address, "function protocolLineage() view returns (bytes32)"),
  ]);
  if (
    readSpoke !== spokePool || readGuard !== guard || readFee !== recipient || readFactory !== factory ||
    readHash.toLowerCase() !== initCodeHash || lineage !== LINEAGE
  ) {
    throw new Error(`adapter reads back wrong: ${[readSpoke, readGuard, readFee, readFactory, readHash, lineage].join(", ")}`);
  }
  console.log(`  spoke pool       ${both(spokePool)}`);
  console.log(`  fee recipient    ${both(recipient)}`);
  console.log(`  vault factory    ${both(factory)}`);

  const category = Number(await chain.read(guard, "function protocolCategory(address) view returns (uint8)", [address]));
  if (category === PROTOCOL_BRIDGE) {
    console.log("guard               already lists it as a bridge");
  } else if (values.register) {
    await requireRole(guard, "PROTOCOL_MANAGER_ROLE");
    await chain.send(guard, "function addProtocols(address[],uint8[])", [[address], [PROTOCOL_BRIDGE]], {
      label: "guard.addProtocols",
    });
  } else {
    console.log("guard               NOT registered: rerun with --register (PROTOCOL_MANAGER_ROLE key), or submit");
    console.log(`                    addProtocols([${toEvm(address)}], [${PROTOCOL_BRIDGE}]) on ${both(guard)}`);
  }
}

// ---------------------------------------------------------------- routes

async function routes() {
  const guard = configured("guard");
  const usdt = configured("usdt");
  if ((await chain.chainId()) !== network.chainId) throw new Error("connected to the wrong chain");

  // The adapter, if deployed, must agree with the keys computed here.
  const adapter = state[NAME];
  if (adapter) {
    const key = await chain.read(adapter, "function routeKey(address,uint256) view returns (bytes32)", [usdt, 1]);
    if (key !== routeKey(usdt, 1)) throw new Error(`adapter's routeKey ${key} differs from ${routeKey(usdt, 1)}`);
  }

  const category = Number(await chain.read(guard, "function assetCategory(address) view returns (uint8)", [usdt]));
  if (category === 0) throw new Error(`USDT ${both(usdt)} is not a guard asset`);
  const bridgeable = (category & ASSET_BRIDGEABLE) !== 0;
  console.log(`USDT category      ${category}${bridgeable ? " (bridgeable)" : " (NOT bridgeable)"}`);

  const missing = [];
  for (const r of network.routes) {
    const key = routeKey(usdt, r.chainId);
    const want = packRoute(r.token, r.decimals, MAX_COST_BPS);
    const have = BigInt(await chain.read(guard, "function getUint(bytes32) view returns (uint256)", [key]));
    const ok = have === want;
    console.log(`${ok ? "set    " : "MISSING"}  USDT -> ${r.name.padEnd(10)} ${r.token} (${r.decimals} dec, max cost ${MAX_COST_BPS} bp)`);
    if (!ok) missing.push({ key, want, r });
  }

  if (bridgeable && missing.length === 0) return;
  if (!values.set) {
    console.log("\nrerun with --set (ASSET_MANAGER_ROLE and CONFIG_MANAGER_ROLE key), or submit on", both(guard));
    if (!bridgeable) console.log(`  addAssets([${usdt}], [${category | ASSET_BRIDGEABLE}])`);
    for (const m of missing) console.log(`  setUint(${m.key}, ${m.want})`);
    return;
  }
  if (!bridgeable) {
    await requireRole(guard, "ASSET_MANAGER_ROLE");
    await chain.send(guard, "function addAssets(address[],uint8[])", [[usdt], [category | ASSET_BRIDGEABLE]], {
      label: "guard.addAssets USDT bridgeable",
    });
  }
  if (missing.length) await requireRole(guard, "CONFIG_MANAGER_ROLE");
  for (const m of missing) {
    await chain.send(guard, "function setUint(bytes32,uint256)", [m.key, m.want], {
      label: `guard.setUint USDT -> ${m.r.name}`,
    });
  }
}

// ---------------------------------------------------------------- status

async function status() {
  const address = state[NAME];
  if (!address) throw new Error(`no ${NAME} recorded in ${statePath}: run deploy first`);
  const guard = configured("guard");
  const [spoke, fee, category] = await Promise.all([
    chain.read(address, "function spokePool() view returns (address)"),
    chain.read(address, "function feeRecipient() view returns (address)"),
    chain.read(guard, "function protocolCategory(address) view returns (uint8)", [address]),
  ]);
  console.log(`${NAME} ${both(address)}`);
  console.log(`  spoke pool      ${both(spoke)}`);
  console.log(`  fee recipient   ${both(fee)}`);
  console.log(`  guard category  ${category} ${Number(category) === PROTOCOL_BRIDGE ? "(bridge)" : "(NOT registered as bridge)"}`);
  await routes();
}

function save() {
  mkdirSync(dirname(statePath), { recursive: true });
  // Re-read so a stake.mjs or sunswap.mjs deploy recorded meanwhile is kept.
  const current = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};
  writeFileSync(statePath, JSON.stringify({ ...current, ...state }, null, 2) + "\n");
}

const commands = { deploy, routes, status };
if (!commands[command]) {
  console.error(`usage: node across.mjs <${Object.keys(commands).join("|")}> --network mainnet [...]`);
  process.exit(1);
}
await commands[command]();
