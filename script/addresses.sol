// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @dev Ethereum mainnet addresses used by fork tests in `test/fork/`.
library mainnet {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Aave V3 Protocol
    address public constant AAVE_V3 = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant POOL_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    // Uniswap V3 Protocol
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant UNISWAP_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    // Lido V2 Protocol
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant UNSTETH = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    // Sky V1 Protocol
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant S_USDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // CoW Swap Protocol
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address public constant BITTY_GUARD = 0x00000000a63B8e2F5B96e3631953667A94e651dd;
}

/// @dev Sepolia addresses parallel to `mainnet` for fork tests on Sepolia.
library sepolia {
    /// @dev WETH used by Aave Sepolia markets (`deployments/sepolia.toml`).
    address public constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    /// @dev Canonical WETH9; Uniswap V3 WETH/USDT pools with liquidity use this token.
    address public constant WETH9 = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public constant USDT = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;
    address public constant USDC = 0x00000000100aaAF8Cff772A414b18168FA758af9;

    address public constant AAVE_V3 = 0x012bAC54348C0E635dCAc9D5FB99f06F24136C9A;
    address public constant POOL_DATA_PROVIDER = 0x3e9708d80f7B3e43118013075F7e95CE3AB31F31;
    /// @dev Aave V3 Sepolia uses its own WETH9Mock — not the canonical Sepolia WETH.
    address public constant AAVE_WETH = 0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c;

    address public constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;
    address public constant UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = 0x1238536071E1c677A632429e3655c799b22cDA52;

    address public constant STETH = 0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af;
    address public constant UNSTETH = 0x1583C7b3f4C3B008720E6BcE5726336b0aB25fdd;

    // CoW Swap Protocol — same address on all chains (deterministic deployment)
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address public constant BITTY_GUARD = 0x00000000a63B8e2F5B96e3631953667A94e651dd;
}

