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
    // Universal Router (v3 + v4) and v4 core, from developers.uniswap.org (v4 deployments).
    address public constant UNISWAP_UNIVERSAL_ROUTER = 0x23617e59A5925b2A4Bf75d73ff6711cD0b29De85; // 2.1.2
    address public constant UNISWAP_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant UNISWAP_V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    address public constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
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
    // Universal Router (v3 + v4) + canonical Permit2, mirroring deployments/sepolia.toml.
    address public constant UNISWAP_UNIVERSAL_ROUTER = 0x7E4f6c5e954Da5c61B3423D81E2277431Ac043f3;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public constant STETH = 0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af;
    address public constant UNSTETH = 0x1583C7b3f4C3B008720E6BcE5726336b0aB25fdd;

    // CoW Swap Protocol — same address on all chains (deterministic deployment)
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    address public constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
}

/// @dev Robinhood Chain (chain 4663) addresses. Uniswap (AMM) and UniswapX (intent) are the supported venues so far.
library robinhood {
    address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant USDC = 0x80e0e24718dbFcad49ECAA6F1e6C89A190586cA8;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // Uniswap V3 Protocol
    address public constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address public constant UNISWAP_V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address public constant UNISWAP_V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    // Universal Router (v3 + v4) and v4 core, from developers.uniswap.org (v4 deployments).
    address public constant UNISWAP_UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498; // 2.1.2
    address public constant UNISWAP_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant UNISWAP_V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // UniswapX V3DutchOrderReactor (deployed 2026-06-12; decay reads ArbSys.arbBlockNumber()).
    address public constant UNISWAPX_V3_DUTCH_REACTOR = 0x000000007A1C8e570011EeDF86A2A35593013cBA;

    address public constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
}

/// @dev Base (chain 8453) addresses used by fork tests in `test/fork/base/`.
library base {
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant USDT = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address public constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    // Aave V3 Protocol. POOL_DATA_PROVIDER derived on chain from
    // pool.ADDRESSES_PROVIDER().getPoolDataProvider().
    address public constant AAVE_V3 = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address public constant POOL_DATA_PROVIDER = 0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A;

    // Uniswap V3 Protocol
    address public constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    // CoW Swap. Deployed deterministically, so identical to mainnet.
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    // Sky. One PSM3 module rather than mainnet's PSM + ERC-4626 vault: sUSDS here is a plain ERC-20
    // and cannot be deposited into, so SKY_PSM3 is the only way in or out.
    address public constant USDS = 0x820C137fa70C8691f0e44Dc420a5e53c168921Dc;
    address public constant S_USDS = 0x5875eEE11Cf8398102FdAd704C9E96607675467a;
    address public constant SKY_PSM3 = 0x1601843c5E9bC251A3272907010AFa41Fa18347E;
}

/// @dev Arbitrum One (chain 42161) addresses used by fork tests in `test/fork/arbitrum/`.
library arbitrum {
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // native, not bridged USDC.e
    address public constant USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT0
    address public constant WBTC = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // Aave V3 Protocol. AAVE_V3 is the PoolAddressesProvider, which the adapter asks for the pool;
    // POOL_DATA_PROVIDER derived on chain from AAVE_V3.getPoolDataProvider().
    address public constant AAVE_V3 = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant POOL_DATA_PROVIDER = 0x243Aa95cAC2a25651eda86e80bEe66114413c43b;

    // Uniswap Universal Router v2.1.2: the build mainnet and Base also use.
    address public constant UNISWAP_UNIVERSAL_ROUTER = 0x2d01411773c8C24805306E89A41F7855C3c4Fe65;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // CoW Swap. Deployed deterministically, so identical to mainnet.
    address public constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    // Sky, through one PSM3 module as on Base: sUSDS is a plain ERC-20 here.
    address public constant USDS = 0x6491c05A82219b8D1479057361ff1654749b876b;
    address public constant S_USDS = 0xdDb46999F8891663a8F2828d25298f70416d7610;
    address public constant SKY_PSM3 = 0x2B05F8e1cACC6974fD79A673a341Fe1f58d27266;

    address public constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;
}
