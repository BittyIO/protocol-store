#!/usr/bin/env node
// SunSwap trade adapter on TRON: check it against the live router, deploy it, register it with the guard.
//
//   node sunswap.mjs probe   --network mainnet [--trx 10] [--from T…]   simulate a TRX->USDT->TRX round trip
//                                                                        through SunSwap; no key, no cost
//   node sunswap.mjs deploy  --network nile [--fee-recipient T…] [--register] [--dry-run]
//   node sunswap.mjs status  --network nile
//   node sunswap.mjs route   --network nile --route 0x… [--token-out 0x…] [--trx 10]
//                                       simulate a route from the web API's /trade/route (built for
//                                       --trx of WTRX) through the DEPLOYED adapter; no key, no cost
//
// Build first: FOUNDRY_PROFILE=tron forge build (in protocol-store). probe/deploy do it unless --no-build.
//
// Keys (hex, never committed):
//   TRON_PRIVATE_KEY  deploy/register: the deployer, holding the guard's PROTOCOL_MANAGER_ROLE.
//   TRON_PRO_API_KEY  optional, TronGrid rate limits.
//
// SunSwap's addresses below were read out of each network's Universal Router bytecode (its immutables),
// and the router addresses match github.com/sun-protocol/sunswap-universal-router's README.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { AbiCoder, keccak256, toUtf8Bytes } from "ethers";
import { toBase58, toEvm, toTronHex } from "./lib/address.mjs";
import { Chain } from "./lib/chain.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..");
const SUN = 1_000_000n;
const PROTOCOL_MARKET_TRADE = 3;
// The deployer: a funded account on both networks, used as the probe's default simulating account.
const DEPLOYER = "0x12EE2de7BF086388B1D560eb95e7191Edfab9823";
const LINEAGE = keccak256(toUtf8Bytes("bitty.adapter.sunswap.universal"));
const NAME = "SunSwapUniversalTradeProtocol";

const NETWORKS = {
  nile: {
    fullHost: "https://nile.trongrid.io",
    chainId: 3448148188,
    wtrx: "TYsbWxNnyTgsZaTFaue9hqpxkU3Fkco94a",
    usdt: "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
    router: "TLmHD2TJoGVEMkGiE1JzSwd6CEPa8jXumJ",
    permit2: "TYQuuhGbEMxF7nZxUHV3uHJxAVVAegNU9h",
    v2Factory: "THomLGMLhAjMecQf9FQjbZ8a1RtwsZLrGE",
    guard: "0xb609AAAEbB9775Ea3037C4D3dde427498c457AD1", // TSZjZdPbDToDMZQMzKLhYbJh35rD8C5Em7
    feeRecipient: DEPLOYER, // testnet: the deployer, as the Nile vault's feeCollector
    feeLimitTrx: 1_000,
  },
  mainnet: {
    fullHost: "https://api.trongrid.io",
    chainId: 728126428,
    wtrx: "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR",
    usdt: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
    router: "TQqgNg13s2DjvXhW1ky4v6TsR8wZGvb7Y4",
    permit2: "TTJxU3P8rHycAyFY4kVtGNfmnMH4ezcuM9",
    v2Factory: "TKWJdrQkqHisa1X8HUdHEfREvTzw4pMAaY",
    guard: "TODO", // the guard repo's tron/deploy.mjs has not run on mainnet yet
    feeRecipient: "TODO", // pass --fee-recipient: mainnet's fee collector is not decided
    feeLimitTrx: 1_000,
  },
};

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    network: { type: "string", default: "nile" },
    trx: { type: "string", default: "10" },
    "fee-recipient": { type: "string" },
    route: { type: "string" },
    "token-out": { type: "string" },
    register: { type: "boolean", default: false },
    "dry-run": { type: "boolean", default: false },
    "no-build": { type: "boolean", default: false },
    from: { type: "string" },
  },
});
const command = positionals[0];
const network = NETWORKS[values.network];
if (!network) throw new Error(`unknown network ${values.network}`);
const statePath = join(repo, "deployments", `tron-${values.network}.json`);
const state = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};

const chain = new Chain({
  fullHost: network.fullHost,
  privateKey: process.env.TRON_PRIVATE_KEY,
  apiKey: process.env.TRON_PRO_API_KEY,
  feeLimitTrx: network.feeLimitTrx,
  dryRun: values["dry-run"],
});

function configured(key) {
  if (network[key] === "TODO") throw new Error(`${values.network}: ${key} is still TODO`);
  return toEvm(network[key]);
}

function feeRecipient() {
  if (values["fee-recipient"]) return toEvm(values["fee-recipient"]);
  return configured("feeRecipient");
}

const both = (a) => `${toBase58(a)} (${toEvm(a)})`;
const fmt = (v, decimals, symbol) =>
  `${(Number(v) / 10 ** decimals).toLocaleString("en-US", { maximumFractionDigits: decimals })} ${symbol}`;

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

function amountArg() {
  const [whole, frac = ""] = values.trx.split(".");
  return BigInt(whole) * SUN + BigInt((frac + "000000").slice(0, 6));
}

// ---------------------------------------------------------------- probe

/**
 * Runs test/tron/SunSwapProbe.sol as a SIMULATED deployment with --trx attached (default 10): nothing
 * is signed or spent. The simulating account (--from, else the key's, else the deployer) must hold it.
 */
async function probe() {
  build();
  const from = toEvm(values.from ?? chain.sender ?? DEPLOYER);
  const [wtrx, usdt, router, permit2] = ["wtrx", "usdt", "router", "permit2"].map(configured);
  const feeTo = values["fee-recipient"] ? toEvm(values["fee-recipient"]) : DEPLOYER;

  const pair = await chain.read(configured("v2Factory"), "function getPair(address,address) view returns (address)", [wtrx, usdt]);
  if (/^0x0+$/.test(pair)) throw new Error(`no SunSwap V2 WTRX/USDT pair on ${values.network}`);
  console.log(`V2 WTRX/USDT pair  ${both(pair)}`);

  const trxIn = amountArg();
  const code = artifact("SunSwapProbe.sol", "SunSwapProbe").bytecode;
  const args = AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "address", "address"],
    [router, permit2, wtrx, usdt, feeTo],
  );
  const res = await fetch(`${network.fullHost}/wallet/triggerconstantcontract`, {
    method: "POST",
    headers: { "content-type": "application/json", ...chain.headers },
    body: JSON.stringify({
      owner_address: toTronHex(from),
      contract_address: "",
      data: code.slice(2) + args.slice(2),
      call_value: Number(trxIn),
    }),
  });
  const json = await res.json();
  if (json.result?.result !== true) {
    const message = json.result?.message ? Buffer.from(json.result.message, "hex").toString() : JSON.stringify(json);
    throw new Error(`simulation failed: ${message}${json.constant_result?.[0] ? ` (revert data 0x${json.constant_result[0]})` : ""}`);
  }
  const out = json.constant_result?.[0] ?? "";
  const w = (i) => BigInt("0x" + (out.slice(i * 64, (i + 1) * 64) || "0"));
  const [usdOut, usdFeeOut, trxBack, usdFeeIn, usdLeft, stuck, trxSent, lineage] = Array.from({ length: 8 }, (_, i) => w(i));
  const fee = (x) => (x * 20n) / 10_000n;
  // The output fee is 0.2% of the gross, and the vault got the other 99.8%: fee*499 <= net < (fee+1)*499.
  const outFeeOk = usdFeeOut > 0n && usdFeeOut * 499n <= usdOut && usdOut < (usdFeeOut + 1n) * 499n + 499n;
  const checks = [
    ["TRX -> USDT: the vault received USDT", usdOut > 0n, fmt(usdOut, 6, "USDT")],
    ["  fee 0.2% of the output, to the fee recipient", outFeeOk, fmt(usdFeeOut, 6, "USDT")],
    ["USDT -> TRX: the vault received TRX", trxBack > 0n, fmt(trxBack, 6, "TRX")],
    ["  fee 0.2% of the input, to the fee recipient", usdFeeIn === fee(usdOut), fmt(usdFeeIn, 6, "USDT")],
    ["  the route spent the rest of the input", usdLeft === 0n, fmt(usdLeft, 6, "USDT")],
    ["nothing left on the adapter", stuck === 0n, stuck],
    ["round trip lost only fees and pool spread", trxBack < trxSent && trxBack > (trxSent * 95n) / 100n,
      `${fmt(trxSent, 6, "TRX")} -> ${fmt(trxBack, 6, "TRX")}`],
    ["lineage", "0x" + lineage.toString(16).padStart(64, "0") === LINEAGE, "bitty.adapter.sunswap.universal"],
  ];
  for (const [name, pass, detail] of checks) console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(48)} ${detail}`);
  console.log(`energy (simulated, includes deploying the adapter and proxy): ${json.energy_used}`);
  if (checks.some(([, pass]) => !pass)) process.exit(1);
}

// ---------------------------------------------------------------- route

/**
 * Runs test/tron/SunSwapRouteProbe.sol as a SIMULATED deployment: a fresh clone of the deployed adapter,
 * owned by the probe, sells --trx of WTRX for --token-out (default USDT) through --route.
 */
async function route() {
  build();
  if (!values.route || !/^0x[0-9a-fA-F]+$/.test(values.route)) throw new Error("--route 0x… is required");
  const impl = state[NAME];
  if (!impl) throw new Error(`no ${NAME} recorded in ${statePath}: run deploy first`);
  const from = toEvm(values.from ?? chain.sender ?? DEPLOYER);
  const tokenOut = values["token-out"] ? toEvm(values["token-out"]) : configured("usdt");
  const code = artifact("SunSwapRouteProbe.sol", "SunSwapRouteProbe").bytecode;
  const args = AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "bytes"],
    [toEvm(impl), configured("wtrx"), tokenOut, values.route],
  );
  const res = await fetch(`${network.fullHost}/wallet/triggerconstantcontract`, {
    method: "POST",
    headers: { "content-type": "application/json", ...chain.headers },
    body: JSON.stringify({
      owner_address: toTronHex(from),
      contract_address: "",
      data: code.slice(2) + args.slice(2),
      call_value: Number(amountArg()),
    }),
  });
  const json = await res.json();
  if (json.result?.result !== true) {
    const message = json.result?.message ? Buffer.from(json.result.message, "hex").toString() : JSON.stringify(json);
    throw new Error(`route failed: ${message}`);
  }
  const out = json.constant_result?.[0] ?? "";
  const received = BigInt("0x" + out.slice(0, 64));
  const left = BigInt("0x" + out.slice(64, 128));
  console.log(`${left === 0n && received > 0n ? "PASS" : "FAIL"}  ${values.trx} WTRX -> ${received} (raw units of ${toBase58(tokenOut)}), left on adapter ${left}`);
  console.log(`energy (simulated, includes a fresh clone): ${json.energy_used}`);
  if (left !== 0n || received === 0n) process.exit(1);
}

// ---------------------------------------------------------------- deploy

async function deploy() {
  const guard = configured("guard");
  const recipient = feeRecipient();
  if ((await chain.chainId()) !== network.chainId) throw new Error("connected to the wrong chain");
  build();
  const impl = artifact(`${NAME}.sol`, NAME);
  const [router, permit2] = [configured("router"), configured("permit2")];

  let address = state[NAME];
  if (address && (await chain.hasCode(address))) {
    console.log(`${NAME} already at ${both(address)}`);
  } else {
    const args = AbiCoder.defaultAbiCoder()
      .encode(["address", "address", "address", "address"], [router, permit2, guard, recipient])
      .slice(2);
    address = await chain.deployContract({ abi: impl.abi, bytecode: impl.bytecode + args, name: NAME });
    if (chain.dryRun) return;
    state[NAME] = address;
    save();
    console.log(`${NAME} deployed at ${both(address)}`);
  }

  // What was deployed is what was meant.
  const [readRouter, readPermit2, readGuard, readFee, lineage] = await Promise.all([
    chain.read(address, "function universalRouter() view returns (address)"),
    chain.read(address, "function permit2() view returns (address)"),
    chain.read(address, "function bittyGuard() view returns (address)"),
    chain.read(address, "function feeRecipient() view returns (address)"),
    chain.read(address, "function protocolLineage() view returns (bytes32)"),
  ]);
  if (readRouter !== router || readPermit2 !== permit2 || readGuard !== guard || readFee !== recipient || lineage !== LINEAGE) {
    throw new Error(`adapter reads back wrong: ${[readRouter, readPermit2, readGuard, readFee, lineage].join(", ")}`);
  }
  console.log(`  fee recipient    ${both(recipient)}`);

  const category = Number(await chain.read(guard, "function protocolCategory(address) view returns (uint8)", [address]));
  if (category === PROTOCOL_MARKET_TRADE) {
    console.log("guard               already lists it as a market trade");
  } else if (values.register) {
    const role = await chain.read(guard, "function PROTOCOL_MANAGER_ROLE() view returns (bytes32)");
    if (!(await chain.read(guard, "function hasRole(bytes32,address) view returns (bool)", [role, chain.sender]))) {
      throw new Error(`${both(chain.sender)} does not hold the guard's PROTOCOL_MANAGER_ROLE`);
    }
    await chain.send(guard, "function addProtocols(address[],uint8[])", [[address], [PROTOCOL_MARKET_TRADE]], {
      label: "guard.addProtocols",
    });
  } else {
    console.log("guard               NOT registered: rerun with --register (PROTOCOL_MANAGER_ROLE key), or submit");
    console.log(`                    addProtocols([${toEvm(address)}], [${PROTOCOL_MARKET_TRADE}]) on ${both(guard)}`);
  }
}

async function status() {
  const address = state[NAME];
  if (!address) throw new Error(`no ${NAME} recorded in ${statePath}: run deploy first`);
  const guard = configured("guard");
  const [fee, category] = await Promise.all([
    chain.read(address, "function feeRecipient() view returns (address)"),
    chain.read(guard, "function protocolCategory(address) view returns (uint8)", [address]),
  ]);
  console.log(`${NAME} ${both(address)}`);
  console.log(`  fee recipient   ${both(fee)}`);
  console.log(`  guard category  ${category} ${Number(category) === PROTOCOL_MARKET_TRADE ? "(market trade)" : "(NOT registered as market trade)"}`);
}

function save() {
  mkdirSync(dirname(statePath), { recursive: true });
  // Re-read so a stake.mjs deploy recorded meanwhile is kept.
  const current = existsSync(statePath) ? JSON.parse(readFileSync(statePath, "utf8")) : {};
  writeFileSync(statePath, JSON.stringify({ ...current, ...state }, null, 2) + "\n");
}

const commands = { probe, route, deploy, status };
if (!commands[command]) {
  console.error(`usage: node sunswap.mjs <${Object.keys(commands).join("|")}> --network nile [...]`);
  process.exit(1);
}
await commands[command]();
