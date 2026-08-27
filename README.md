# Bitty Protocol Store

Solidity adapters that connect [Bitty Vault](https://github.com/bitty-ecosystem) to external DeFi protocols. Each adapter is a **cloneable implementation**: the vault deploys a minimal proxy per strategy, calls `initialize(vault)`, and routes asset-manager actions through a small, typed interface.

Adapters are **curated** — only addresses registered in the Bitty Guard may be used. An adapter does **not** declare its own category. Whoever registers it tells the guard which category it is, and consumers read that back from `protocolCategory`; curation and classification are the same act by the same party, so an adapter is never asked to describe itself.

## Protocol adapters

| Adapter | Category | Underlying | Chains |
|---|---|---|---|
| `AaveV3Protocol` | Lending | Aave V3 deposit / withdraw | Mainnet, Sepolia, Base |
| `LidoV2Protocol` | Staking | WETH → stETH, async withdrawal queue | Mainnet, Sepolia |
| `SkyV1Protocol` | Staking | USDC → sUSDS via Sky PSM + ERC-4626 vault | Mainnet |
| `SkyV1EvmProtocol` | Staking | USDC → sUSDS via PSM3 (single-hop) | Base |
| `UniswapV3Protocol` | AMM | Uniswap V3 LP (mint, decrease, remove, fee claim) | Mainnet, Sepolia, Base |
| `CoWSwapV1Protocol` | Intent | CoW Swap off-chain orders (ERC-1271 validation) | Mainnet, Sepolia, Base |

### How adapters fit the vault

```
Vault (owner)
  └── clones adapter implementation
        ├── pulls receipt tokens / NFTs from vault
        ├── calls external protocol (Aave, Lido, Uniswap, …)
        └── returns assets or receipt tokens to vault
```

- **Lending / staking / AMM** — on-chain execution; the vault is `msg.sender` and usually holds receipt tokens (aTokens, stETH shares, Uniswap V3 position NFTs).
- **Intent (CoW Swap)** — no on-chain order registry. The asset manager signs orders off-chain; at settlement CoW calls the vault's `isValidSignature`, which delegates to the clone to validate shape, fees, and manager authorization.

### Fees

| Adapter | Fee | Recipient |
|---|---|---|
| `UniswapV3Protocol` | 1% of collected LP trading fees | `0x12EE2de7BF086388B1D560eb95e7191Edfab9823` |
| `CoWSwapV1Protocol` | 0.2% partner fee (enforced in order `appData`) | same |

Principal returned from liquidity decreases is not subject to the Uniswap collect fee.

## Repository layout

```
src/
  interfaces/          # IBittyV1* category interfaces (+ IBittyVaultOffchainAuth)
  protocols/           # Adapter implementations
  libs/                # Minimal external-protocol bindings (Aave, Lido, Sky, Uniswap, CoW)
script/
  DeployMainnet.s.sol  # All five adapters
  DeploySepolia.s.sol  # Aave, Uniswap, CoW, Lido (no Sky on testnet)
  DeployBase.s.sol     # Aave, Uniswap, CoW, SkyV1Base (no Lido on Base)
  DeployProtocols.sol  # Shared deploy steps (re-runnable, skips existing code)
  addresses.sol        # Hardcoded addresses for fork tests
deployments/
  mainnet.toml         # RPC + external + deployed adapter addresses
  sepolia.toml
  base.toml
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
```

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

These replace the ERC-165 interface IDs the guard used to probe for. Adapters no longer implement
`IERC165`, and the pinned-ID tests that guarded the old scheme are gone with it.

## Entering and exiting a position

Lending and staking extend the same two interfaces, because the vault does the same two things with
each — put an asset in, take an asset out:

```solidity
// IBittyV1Depositable
function deposit(address asset, uint256 amount) external;

// IBittyV1Withdrawable
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

## Related repos

This repo is consumed as `protocol-contracts/` (see `foundry.toml` remapping). The vault and guard repos depend on these interfaces and deployed adapter addresses staying aligned.

## License

AGPL-3.0-only
