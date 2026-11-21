# Bitty Protocol Store

Solidity adapters that connect [Bitty Vault](https://github.com/bitty-ecosystem) to external DeFi protocols. Each adapter is a **cloneable implementation**: the vault deploys a minimal proxy per strategy, calls `initialize(vault)`, and routes asset-manager actions through a small, typed interface.

Adapters are **curated** — only addresses registered in the Bitty Guard may be used. An adapter does **not** declare its own category. Whoever registers it tells the guard which category it is, and consumers read that back from `protocolCategory`; curation and classification are the same act by the same party, so an adapter is never asked to describe itself.

## Protocol adapters

| Adapter | Category | Underlying | Chains |
|---|---|---|---|
| `AaveV3Protocol` | Lending | Aave V3 deposit / withdraw | Mainnet, Sepolia, Base, BSC |
| `LidoV2Protocol` | Staking | WETH → stETH, async withdrawal queue | Mainnet, Sepolia |
| `SkyV1Protocol` | Staking | USDC → sUSDS via Sky PSM + ERC-4626 vault | Mainnet |
| `SkyV1EvmProtocol` | Staking | USDC → sUSDS via PSM3 (single-hop) | Base |
| `UniswapUniversalProtocol` | AMM | Market swaps through the Universal Router (v3 + v4 routes) or a plain v3 path; Uniswap V3 LP (mint, decrease, remove, fee claim) | Mainnet, Sepolia, Base, Robinhood |
| `PancakeSwapUniversalTradeProtocol` | AMM | Market swaps through PancakeSwap's Infinity Universal Router (v2, v3, StableSwap, Infinity routes); the Uniswap trade adapter under its own lineage | BSC |
| `CoWSwapV1Protocol` | Intent | CoW Swap off-chain orders (ERC-1271 validation) | Mainnet, Sepolia, Base, BSC |
| `AcrossBridgeProtocol` | Bridge | Across SpokePool deposit to this vault's counterpart on another chain | Mainnet, Base, Arbitrum, BSC, Robinhood, Sepolia, Base Sepolia |

### How adapters fit the vault

```
Vault (owner)
  └── clones adapter implementation
        ├── pulls receipt tokens / NFTs from vault
        ├── calls external protocol (Aave, Lido, Uniswap, …)
        └── returns assets or receipt tokens to vault
```

- **Lending / staking / AMM** — on-chain execution; the vault is `msg.sender` and usually holds receipt tokens (aTokens, stETH shares, Uniswap V3 position NFTs).
- **Bridge (Across)** — on-chain deposit into Across's SpokePool, with the vault as depositor (an unfilled deposit is refunded to it). The adapter decides the recipient and checks the quote against the guard's route; the vault charges what does not arrive to its daily loss allowance. See [Bridging](#bridging).
- **Intent (CoW Swap)** — no on-chain order registry. The owner or asset manager signs each order off-chain as a Bitty `VaultOrder` (EIP-712 domain "Bitty Vault Order", version "1"; the vault plus the CoW order nested whole — see `vaultOrderDigest`), never the bare CoW order digest, which CoW would also accept as an order from the signer's own wallet. Cancellations are signed the same way (`vaultCancellationDigest`); at settlement CoW calls the vault's `isValidSignature`, which delegates to the clone to validate shape, fees, and manager authorization.

### Fees

| Adapter | Fee | Recipient |
|---|---|---|
| `UniswapUniversalProtocol` | 0.2% on market swaps; 1% of collected LP trading fees | `0x12EE2de7BF086388B1D560eb95e7191Edfab9823` |
| `PancakeSwapUniversalTradeProtocol` | 0.2% on market swaps (same code as Uniswap's) | same |
| `CoWSwapV1Protocol` | 0.2% partner fee (enforced in order `appData`) | same |
| `AcrossBridgeProtocol` | Up to 0.2% of the amount (`MAX_FEE_BPS = 20`), taken before the deposit | The fee Safe's Bitty vault `0xF0E7f6998B362BD15CF819C7EBfcaCe8865FECA0` |

Principal returned from liquidity decreases is not subject to the Uniswap collect fee.

## Repository layout

```
src/
  interfaces/          # IBittyV1* category interfaces (+ IBittyVaultOffchainAuth)
  protocols/           # Adapter implementations
  libs/                # Minimal external-protocol bindings (Aave, Lido, Sky, Uniswap, CoW)
script/
  DeployMainnet.s.sol  # Aave, Uniswap, CoW, Lido, Sky, Across
  DeploySepolia.s.sol  # Aave, Uniswap, CoW, Lido, Across (no Sky on testnet)
  DeployBase.s.sol     # Aave, Uniswap, CoW, SkyV1Evm, Across (no Lido on Base)
  DeployBsc.s.sol      # Aave, PancakeSwap, CoW, Across (no Lido or Sky on BNB Chain)
  DeployArbitrum.s.sol # Aave, Uniswap, CoW, SkyV1Evm, Across
  DeployRobinhood.s.sol # Uniswap, Across
  DeployBaseSepolia.s.sol # Across (the other end of Sepolia's testnet routes)
  DeployProtocols.sol  # Shared deploy steps (re-runnable, skips existing code)
  addresses.sol        # Hardcoded addresses for fork tests
deployments/
  mainnet.toml         # RPC + external + deployed adapter addresses
  sepolia.toml
  base.toml
  bsc.toml
  arbitrum.toml
  robinhood.toml
  base-sepolia.toml
test/
  fork/                # Integration tests against live chain state
  local/               # Unit tests (CoW off-chain auth, etc.)
```

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git submodules initialized

## Setup

```bash
git submodule update --init --recursive
forge build
```

Create a `.env` in the repo root (gitignored):

```bash
ALCHEMY_KEY=...          # Used by foundry.toml RPC endpoints
ETHERSCAN_API_KEY=...    # Contract verification
```

Foundry reads these automatically when running scripts or fork tests.

## Testing

```bash
# All tests
forge test

# Mainnet fork tests (requires ALCHEMY_KEY)
forge test --match-path "test/fork/mainnet/*"

# Sepolia fork tests
forge test --match-path "test/fork/sepolia/*"

# Base fork tests
forge test --match-path "test/fork/base/*"

# BSC fork tests
forge test --match-path "test/fork/bsc/*"
```

Fork RPC URLs are configured in `foundry.toml` under `[rpc_endpoints]`. Test constants live in `script/addresses.sol` (`mainnet`, `sepolia`, and `base` libraries).

## Deployment

Each chain has a single entry-point script. Deploy steps are **re-runnable**: an adapter is skipped when the TOML already records an address with deployed bytecode, so partial runs can be retried without redeploying everything.

```bash
# Mainnet — Aave, Uniswap, CoW, Lido, Sky
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url mainnet --broadcast --verify

# Sepolia — Aave, Uniswap, CoW, Lido
forge script script/DeploySepolia.s.sol:DeploySepolia \
  --rpc-url sepolia --broadcast --verify

# Base — Aave, Uniswap, CoW, SkyV1Base
forge script script/DeployBase.s.sol:DeployBase \
  --rpc-url base --broadcast --verify

# BSC — Aave, PancakeSwap, CoW, Across (no Lido or Sky on BNB Chain)
forge script script/DeployBsc.s.sol:DeployBsc \
  --rpc-url bsc --broadcast --verify

# Arbitrum, Robinhood, Base Sepolia: DeployArbitrum, DeployRobinhood, DeployBaseSepolia, the same way
```

Every chain's script also deploys `AcrossBridgeProtocol` (`_deployAcrossBridge`), reading `ACROSS_SPOKE_POOL` from the chain's TOML. A new adapter build (a new version) is deployed next to the old one and registered as its replacement; routes are guard config and are not part of the deploy.

Chain-specific external protocol addresses and deployed adapter addresses are stored in `deployments/<chain>.toml`. Scripts load this file via `forge-std` Config (`script/BaseDeploy.sol`) and write new adapter addresses back after broadcast.

After deploying, register each new adapter address in the **Bitty Guard** and deprecate any superseded ones.

## Categories

A category is a `uint8` the guard stores at registration. It is not derived from the adapter and not
verified on chain, so the numbering is a convention this repo shares with the vault and the guard —
registering an adapter under the wrong number makes it unusable rather than merely mislabelled.

| Category | Interface | Value |
|---|---|---|
| Lending | `IBittyV1LendingProtocol` | `1` |
| Staking | `IBittyV1StakingProtocol` | `2` |
| AMM | `IBittyV1AMMProtocol` | `3` |
| Intent | `IBittyV1IntentProtocol` | `4` |
| Bridge | `IBittyV1BridgeProtocol` | `5` |

An asset a vault may bridge also carries the guard's `ASSET_BRIDGEABLE` (`8`) asset category.

These replace the ERC-165 interface IDs the guard used to probe for. Adapters no longer implement
`IERC165`, and the pinned-ID tests that guarded the old scheme are gone with it.

## Entering and exiting a position

Lending and staking extend the same two interfaces, because the vault does the same two things with
each — put an asset in, take an asset out:

```solidity
// IBittyV1Yield
function deposit(address asset, uint256 amount) external;

// IBittyV1Yield
function withdraw(address asset, uint256 amount, address recipient) external returns (uint256 delivered);
```

One name per direction. Lending's `supply`/`withdraw` and staking's `stake`/`unstake` were the same
two calls under four names, which forced the vault to branch by category to ask the same question.

`deposit` is **not** payable. Assets reach an adapter as ERC-20 transfers — native ETH is wrapped by
the vault before it gets there — so no adapter has ever read `msg.value` and the vault has never
attached any. Accepting value would only create a way for ETH to strand in an adapter with no path
back out.

On `withdraw`, `recipient` is normally the vault, or a payee to settle straight out of a position in
one step — asynchronous protocols (Lido) only support the vault itself and revert otherwise, since
there is nothing to deliver yet.

## Bridging

`AcrossBridgeProtocol` takes Across's quote as `data` and decides everything that says where the
money goes, so a quote cannot redirect it:

- **Recipient: this vault's counterpart on the destination chain** (from 1.1.0). Every EVM vault is
  the factory's CREATE2 of its creation owner (factory `0x3d7E…F120`, the same on every EVM chain),
  so the counterpart is the vault's own address. A handover on this chain (a quantum-safe key
  rotation, a sale) does not move it. `data` is `abi.encode(AcrossQuote)`, and
  `recipientFor(vault, chainId, address(0))` answers where a bridge will land, for apps to quote with.
- **Ownership is per chain.** The counterpart belongs to whoever owns it on that chain. After a
  vault is handed to a new key on one chain (including the recovery from a stolen key), the same
  address elsewhere stays the old key's until it is handed over there too, and a bridge still pays it.
- **Routes are guard config.** `getUint(routeKey(inputToken, destinationChainId))` packs the
  output token (bits 0–159), its decimals (160–167) and the most the bridge may cost in basis points
  (168–183, capped at `MAX_COST_BPS = 300`); `packRoute` builds the value. The native coin is keyed
  by Across's wrapped native token. No route, no bridge.
- **What arrives** must be at least the deposit (after Bitty's fee) less the route's cost, and
  `bridge` returns it in the sent token's units; the vault charges the difference to its daily
  loss allowance.

Version 1.0.0 paid the vault's *current owner's* vault (`vaultOn(chainId, owner())`) instead, so a
rotated vault bridged into a new address. Apps read `protocolVersion()` and ask 1.1.0 adapters
`recipientFor`, older ones `vaultOn`, so they quote correctly on either until every chain is upgraded.

## Related repos

This repo is consumed as `protocol-contracts/` (see `foundry.toml` remapping). The vault and guard repos depend on these interfaces and deployed adapter addresses staying aligned.

## License

AGPL-3.0-only
