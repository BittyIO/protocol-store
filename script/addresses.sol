// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/// @dev Ethereum mainnet addresses used by fork tests in `test/fork/`.
library mainnet {
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant AAVE_V3 = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant POOL_DATA_PROVIDER = 0x0a16f2FCC0D44FaE41cc54e079281D84A363bECD;

    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant UNISWAP_V3_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address public constant UNISWAP_V3_NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant UNSTETH = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
}
