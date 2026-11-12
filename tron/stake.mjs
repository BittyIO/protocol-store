#!/usr/bin/env node
// TRON staking adapter: deploy it, register it with the guard, and drive it from a vault.
//
//   node stake.mjs probe    --network nile [--from T…]          simulate the staking opcodes; no key, no cost
//   node stake.mjs deploy   --network nile [--register] [--dry-run]
//   node stake.mjs status   --network nile --vault T…
//   node stake.mjs allow    --network nile --vault T…            only if the vault's own allow list is on
//   node stake.mjs fund     --network nile --vault T… --trx 100  wrap TRX into WTRX and send it to the vault
//   node stake.mjs stake    --network nile --vault T… --trx 100
//   node stake.mjs unstake  --network nile --vault T… --trx 40   or --all
//   node stake.mjs claim    --network nile --vault T…
//
// Build first: FOUNDRY_PROFILE=tron forge build (in protocol-store). `deploy` does it unless --no-build.
//
// Keys (hex, never committed):
//   TRON_PRIVATE_KEY  deploy/register: the deployer, holding the guard's PROTOCOL_MANAGER_ROLE.
//                     fund/allow/stake/unstake/claim: the VAULT OWNER's key (the vault takes these
//                     calls from its owner only).
//   TRON_PRO_API_KEY  optional, TronGrid rate limits.

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
const PROTOCOL_STAKING = 1;
// The deployer: a funded account on both networks, used as the probe's default simulating account.
const DEPLOYER = "0x12EE2de7BF086388B1D560eb95e7191Edfab9823";
const LINEAGE = keccak256(toUtf8Bytes("bitty.adapter.tron.stake"));

const NETWORKS = {
  nile: {
    fullHost: "https://nile.trongrid.io",
    chainId: 3448148188,
    wtrx: "TYsbWxNnyTgsZaTFaue9hqpxkU3Fkco94a",
    guard: "0xb609AAAEbB9775Ea3037C4D3dde427498c457AD1", // TSZjZdPbDToDMZQMzKLhYbJh35rD8C5Em7
    feeLimitTrx: 1_000,
  },
  mainnet: {
    fullHost: "https://api.trongrid.io",
    chainId: 728126428,
    wtrx: "TNUC9Qb1rRpS5CbWLmNMxXBjyFoydXjWFR",
    guard: "TODO", // the guard repo's tron/deploy.mjs has not run on mainnet yet
    feeLimitTrx: 1_000,
  },
};

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    network: { type: "string", default: "nile" },
    vault: { type: "string" },
    trx: { type: "string" },
    all: { type: "boolean", default: false },
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

function guardAddress() {
  if (network.guard === "TODO") throw new Error(`${values.network}: the guard address is still TODO`);
  return toEvm(network.guard);
}

const both = (a) => `${toBase58(a)} (${toEvm(a)})`;
const trxOf = (sun) => `${(Number(sun) / 1e6).toLocaleString("en-US", { maximumFractionDigits: 6 })} TRX`;

function artifact(file, contract) {
  const path = join(repo, "out-tron", file, `${contract}.json`);
  if (!existsSync(path)) throw new Error(`${path} missing: run FOUNDRY_PROFILE=tron forge build`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  return { abi: json.abi ?? [], bytecode: json.bytecode.object };
}

function adapter() {
  if (!state.TronStakeProtocol) throw new Error(`no adapter recorded in ${statePath}: run deploy first`);
  return state.TronStakeProtocol;
}

function vaultArg() {
  if (!values.vault) throw new Error("--vault T… is required");
  return toEvm(values.vault);
}

function amountArg() {
  if (!values.trx) throw new Error("--trx <amount> is required");
  const [whole, frac = ""] = values.trx.split(".");
  return BigInt(whole) * SUN + BigInt((frac + "000000").slice(0, 6));
}

async function requireOwner(vault) {
  const owner = await chain.read(vault, "function owner() view returns (address)");
  if (!chain.dryRun && owner !== chain.sender) {
    throw new Error(`the vault's owner is ${both(owner)}; TRON_PRIVATE_KEY is ${chain.sender ? both(chain.sender) : "unset"}`);
  }
  return owner;
}

// ---------------------------------------------------------------- probe

/**
 * Runs test/tron/TronStakeProbe.sol as a SIMULATED deployment with 2 TRX attached: nothing is signed
 * or spent. The simulating account (--from, else the key's, else the deployer) must hold 2 TRX.
 */
async function probe() {
  if (!values["no-build"]) {
    execFileSync("forge", ["build"], { cwd: repo, stdio: "inherit", env: { ...process.env, FOUNDRY_PROFILE: "tron" } });
  }
  const from = toEvm(values.from ?? chain.sender ?? DEPLOYER);
  const ops = artifact("TronStakeOps.yul", "TronStakeOps").bytecode;
  const probeCode = artifact("TronStakeProbe.sol", "TronStakeProbe").bytecode;
  const data = probeCode + AbiCoder.defaultAbiCoder().encode(["bytes", "address"], [ops, from]).slice(2);
  const res = await fetch(`${network.fullHost}/wallet/triggerconstantcontract`, {
    method: "POST",
    headers: { "content-type": "application/json", ...chain.headers },
    body: JSON.stringify({ owner_address: toTronHex(from), contract_address: "", data: data.slice(2), call_value: 2_000_000 }),
  });
  const json = await res.json();
  if (json.result?.result !== true) {
    const message = json.result?.message ? Buffer.from(json.result.message, "hex").toString() : JSON.stringify(json);
    throw new Error(`simulation failed: ${message}`);
  }
  const out = json.constant_result?.[0] ?? "";
  const w = (i) => BigInt("0x" + (out.slice(i * 64, (i + 1) * 64) || "0"));
  const checks = [
    ["helper created", w(0) !== 0n, toEvm("0x" + w(0).toString(16).padStart(40, "0"))],
    ["freeze 1 TRX for energy", w(1) === 1n, w(1)],
    ["freeze acted on the delegatecalling account", w(2) === SUN, `${w(2)} sun left its balance`],
    ["delegatableResource answers", w(3) > 0n && w(3) <= SUN, `${w(3)} sun`],
    ["delegate 1 TRX of energy to an account", w(4) === 1n, w(4)],
    ["undelegate it", w(5) === 1n, w(5)],
    ["unfreeze 1 TRX", w(6) === 1n, w(6)],
    ["getChainParameter(unstake delay days)", w(7) > 0n && w(7) < 100n, `${w(7)} days`],
    ["withdrawExpireUnfreeze runs (nothing due)", w(8) === 0n, w(8)],
    ["a refused op returns 0, not a revert", w(9) === 0n, w(9)],
  ];
  for (const [name, pass, detail] of checks) console.log(`${pass ? "PASS" : "FAIL"}  ${name.padEnd(46)} ${detail}`);
  console.log(`energy (simulated): ${json.energy_used}`);
  if (checks.some(([, pass]) => !pass)) process.exit(1);
}

// ---------------------------------------------------------------- deploy

async function deploy() {
  guardAddress();
  if ((await chain.chainId()) !== network.chainId) throw new Error("connected to the wrong chain");
  if (!values["no-build"]) {
    execFileSync("forge", ["build"], { cwd: repo, stdio: "inherit", env: { ...process.env, FOUNDRY_PROFILE: "tron" } });
  }
  const ops = artifact("TronStakeOps.yul", "TronStakeOps");
  const impl = artifact("TronStakeProtocol.sol", "TronStakeProtocol");
  const wtrx = toEvm(network.wtrx);

  let opsAddress = state.TronStakeOps;
  if (opsAddress && (await chain.hasCode(opsAddress))) {
    console.log(`TronStakeOps        already at ${both(opsAddress)}`);
  } else {
    const opsAbi = [
      "freezeBalanceV2(uint256,uint256)",
      "unfreezeBalanceV2(uint256,uint256)",
      "withdrawExpireUnfreeze()",
      "delegateResource(address,uint256,uint256)",
      "unDelegateResource(address,uint256,uint256)",
    ].map((sig) => {
      const [name, args] = sig.split(/[()]/);
      return {
        type: "function",
        name,
        stateMutability: "nonpayable",
        inputs: args ? args.split(",").map((t, i) => ({ name: `a${i}`, type: t })) : [],
        outputs: [{ name: "", type: "uint256" }],
      };
    });
    opsAddress = await chain.deployContract({ abi: opsAbi, bytecode: ops.bytecode, name: "TronStakeOps" });
    if (chain.dryRun) return;
    state.TronStakeOps = opsAddress;
    save();
    console.log(`TronStakeOps        deployed at ${both(opsAddress)}`);
  }

  let adapterAddress = state.TronStakeProtocol;
  if (adapterAddress && (await chain.hasCode(adapterAddress))) {
    console.log(`TronStakeProtocol   already at ${both(adapterAddress)}`);
  } else {
    const args = AbiCoder.defaultAbiCoder().encode(["address", "address"], [wtrx, opsAddress]).slice(2);
    adapterAddress = await chain.deployContract({
      abi: impl.abi,
      bytecode: impl.bytecode + args,
      name: "TronStakeProtocol",
    });
    if (chain.dryRun) return;
    state.TronStakeProtocol = adapterAddress;
    save();
    console.log(`TronStakeProtocol   deployed at ${both(adapterAddress)}`);
  }

  // What was deployed is what was meant.
  const [readOps, readWtrx, lineage] = await Promise.all([
    chain.read(adapterAddress, "function stakeOps() view returns (address)"),
    chain.read(adapterAddress, "function wtrx() view returns (address)"),
    chain.read(adapterAddress, "function protocolLineage() view returns (bytes32)"),
  ]);
  if (readOps !== toEvm(opsAddress) || readWtrx !== wtrx || lineage !== LINEAGE) {
    throw new Error(`adapter reads back wrong: ops ${readOps}, wtrx ${readWtrx}, lineage ${lineage}`);
  }

  const guard = guardAddress();
  const category = Number(await chain.read(guard, "function protocolCategory(address) view returns (uint8)", [adapterAddress]));
  if (category === PROTOCOL_STAKING) {
    console.log("guard               already lists it as staking");
  } else if (values.register) {
    const role = await chain.read(guard, "function PROTOCOL_MANAGER_ROLE() view returns (bytes32)");
    if (!(await chain.read(guard, "function hasRole(bytes32,address) view returns (bool)", [role, chain.sender]))) {
      throw new Error(`${both(chain.sender)} does not hold the guard's PROTOCOL_MANAGER_ROLE`);
    }
    await chain.send(guard, "function addProtocols(address[],uint8[])", [[adapterAddress], [PROTOCOL_STAKING]], {
      label: "guard.addProtocols",
    });
  } else {
    console.log("guard               NOT registered: rerun with --register (PROTOCOL_MANAGER_ROLE key), or submit");
    console.log(`                    addProtocols([${toEvm(adapterAddress)}], [${PROTOCOL_STAKING}]) on ${both(guard)}`);
  }
}

function save() {
  mkdirSync(dirname(statePath), { recursive: true });
  writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n");
}

// ---------------------------------------------------------------- vault side

async function clone(vault) {
  return chain.read(vault, "function getClone(address) view returns (address)", [adapter()]);
}

async function status() {
  const vault = vaultArg();
  const protocol = adapter();
  const owner = await chain.read(vault, "function owner() view returns (address)");
  const wtrx = toEvm(network.wtrx);
  const [vaultWtrx, allowed, registered] = await Promise.all([
    chain.read(wtrx, "function balanceOf(address) view returns (uint256)", [vault]),
    chain.read(vault, "function isProtocolAllowed(address) view returns (bool)", [protocol]),
    chain.read(guardAddress(), "function isProtocolRegistered(address) view returns (bool)", [protocol]),
  ]);
  console.log(`vault               ${both(vault)}`);
  console.log(`owner               ${both(owner)}`);
  console.log(`adapter             ${both(protocol)} guard-registered ${registered}, usable by vault ${allowed}`);
  console.log(`vault WTRX          ${trxOf(vaultWtrx)}`);

  const instance = await clone(vault);
  if (instance === "0x0000000000000000000000000000000000000000") {
    console.log("adapter instance    none yet (the first stake creates it)");
  } else {
    const r = (sig, args = []) => chain.read(instance, sig, args);
    const [staked, pending, receiver, delegated, balance, ids] = await Promise.all([
      r("function staked() view returns (uint256)"),
      r("function pendingUnstake() view returns (uint256)"),
      r("function energyReceiver() view returns (address)"),
      r("function delegatedEnergyStake() view returns (uint256)"),
      r("function getBalance(address) view returns (uint256)", [wtrx]),
      r("function getPendingWithdrawalIds() view returns (uint256[])"),
    ]);
    console.log(`adapter instance    ${both(instance)}`);
    console.log(`  staked            ${trxOf(staked)}`);
    console.log(`  delegated stake   ${trxOf(delegated)}${delegated > 0n ? ` -> ${both(receiver)}` : ""}`);
    console.log(`  unstaking         ${trxOf(pending)}`);
    console.log(`  total (getBalance) ${trxOf(balance)}`);
    for (const id of ids) {
      const [amount, unlockAt] = await r("function unstakeRequest(uint256) view returns (uint256,uint256)", [id]);
      const due = Number(unlockAt) * 1000;
      console.log(`  request #${id}        ${trxOf(amount)}, unlocks ~${new Date(due).toISOString()}${due <= Date.now() ? " (due: claim)" : ""}`);
    }
    // TRON's own view of the instance account, to check the mirror against.
    const account = await chain.tronWeb.trx.getAccount(toTronHex(instance));
    const frozen = (account.frozenV2 ?? []).filter((f) => f.type === "ENERGY").reduce((s, f) => s + (f.amount ?? 0), 0);
    const unfreezing = (account.unfrozenV2 ?? []).reduce((s, u) => s + (u.unfreeze_amount ?? 0), 0);
    const delegatedOut = account.account_resource?.delegated_frozenV2_balance_for_energy ?? 0;
    console.log(`  TRON says         frozen ${trxOf(frozen + delegatedOut)} (delegated ${trxOf(delegatedOut)}), unfreezing ${trxOf(unfreezing)}, balance ${trxOf(account.balance ?? 0)}`);
  }
  const res = await chain.tronWeb.trx.getAccountResources(toTronHex(owner));
  console.log(`owner energy        ${(res.EnergyLimit ?? 0).toLocaleString("en-US")} / day (used ${(res.EnergyUsed ?? 0).toLocaleString("en-US")})`);
}

async function allow() {
  const vault = vaultArg();
  await requireOwner(vault);
  if (await chain.read(vault, "function isProtocolAllowed(address) view returns (bool)", [adapter()])) {
    return console.log("the vault already allows the adapter");
  }
  await chain.send(vault, "function updateProtocols(address[],address[])", [[adapter()], []], { label: "vault.updateProtocols" });
}

async function fund() {
  const vault = vaultArg();
  const amount = amountArg();
  const wtrx = toEvm(network.wtrx);
  await chain.send(wtrx, "function deposit() payable", [], { callValue: Number(amount), label: "WTRX.deposit" });
  await chain.send(wtrx, "function transfer(address,uint256) returns (bool)", [vault, amount], { label: "WTRX.transfer to vault" });
}

async function stake() {
  const vault = vaultArg();
  await requireOwner(vault);
  await chain.send(vault, "function deposit(address,address,uint256)", [adapter(), toEvm(network.wtrx), amountArg()], {
    label: "vault.deposit (stake)",
  });
  await status();
}

async function unstake() {
  const vault = vaultArg();
  await requireOwner(vault);
  const amount = values.all ? (1n << 256n) - 1n : amountArg();
  await chain.send(vault, "function withdraw(address,address,uint256)", [adapter(), toEvm(network.wtrx), amount], {
    label: "vault.withdraw (unstake)",
  });
  await status();
}

async function claim() {
  const vault = vaultArg();
  await requireOwner(vault);
  const ids = await chain.read(await clone(vault), "function getPendingWithdrawalIds() view returns (uint256[])");
  await chain.send(vault, "function claimWithdrawals(address,uint256[])", [adapter(), ids], { label: "vault.claimWithdrawals" });
  await status();
}

const commands = { probe, deploy, status, allow, fund, stake, unstake, claim };
if (!commands[command]) {
  console.error(`usage: node stake.mjs <${Object.keys(commands).join("|")}> --network nile [...]`);
  process.exit(1);
}
await commands[command]();
