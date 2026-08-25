# Bitty Protocol Store

Solidity adapters that connect [Bitty Vault](https://github.com/bitty-ecosystem) to external DeFi protocols. Each adapter is a **cloneable implementation**: the vault deploys a minimal proxy per strategy, calls `initialize(vault)`, and routes asset-manager actions through a small, typed interface.

Adapters are **curated** — only addresses registered in the Bitty Guard may be used. Each adapter declares its category (lending, staking, AMM, or intent) via ERC-165 so the vault and guard stay in sync without maintaining four parallel allow-lists.

## Protocol adapters

| Adapter | Category | Underlying | Chains |
|---|---|---|---|
| `AaveV3Protocol` | Lending | Aave V3 supply / withdraw | Mainnet, Sepolia, Base |
| `LidoV2Protocol` | Staking | WETH → stETH, async withdrawal queue | Mainnet, Sepolia |
| `SkyV1Protocol` | Staking | USDC → sUSDS via Sky PSM + ERC-4626 vault | Mainnet |
| `SkyV1BaseProtocol` | Staking | USDC → sUSDS via PSM3 (single-hop) | Base |
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
  InterfaceIds.t.sol   # Pinned ERC-165 interface IDs (cross-repo contract)
  Erc165Conformance.t.sol
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

## Interface IDs

Category interface selectors are **pinned** in `test/InterfaceIds.t.sol`. The guard checks one ID at registration; the vault checks it on every call. Changing an interface without redeploying all adapters in that category would silently disable them — the pinned test turns that into a build failure.

| Category | Interface | ID |
|---|---|---|
| Lending | `IBittyV1LendingProtocol` | `0xb9f16a0c` |
| Staking | `IBittyV1StakingProtocol` | `0xc8ada217` |
| AMM | `IBittyV1AMMProtocol` | `0x932722bd` |
| Intent | `IBittyV1IntentProtocol` | `0x1626ba7e` |

`Erc165Conformance.t.sol` verifies every adapter answers its category probe the way OpenZeppelin's `ERC165Checker` expects.

## Related repos

This repo is consumed as `protocol-contracts/` (see `foundry.toml` remapping). The vault and guard repos depend on these interfaces and deployed adapter addresses staying aligned.

## License

AGPL-3.0-only
