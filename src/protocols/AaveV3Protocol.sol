// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {IBittyV1Yield, ClaimNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "../libs/aave/v3/Aave.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract AaveV3Protocol is IBittyV1Yield, BittyV1ProtocolBase {
    using SafeERC20 for IERC20;
    address public immutable aaveV3;
    address public immutable poolDataProvider;

    mapping(address => address) public receiptTokenOf;

    constructor(address aaveV3_, address poolDataProvider_) {
        aaveV3 = aaveV3_;
        poolDataProvider = poolDataProvider_;
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.aave.v3");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_000_000; // 1.0.0
    }

    function _getAToken(address asset) private view returns (address) {
        (bool success, bytes memory data) =
            poolDataProvider.staticcall(abi.encodeWithSignature("getReserveTokensAddresses(address)", asset));
        require(success, "AaveV3: aToken lookup failed");
        (address aTokenAddr,,) = abi.decode(data, (address, address, address));
        return aTokenAddr;
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IAavePool pool = IAaveV3(aaveV3).getPool();
        if (IERC20(asset).allowance(address(this), address(pool)) < amount) {
            IERC20(asset).forceApprove(address(pool), type(uint256).max);
        }
        pool.supply(asset, amount, address(this), 0);

        address aToken = _getAToken(asset);
        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = aToken;
        }
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        if (aTokenBalance > 0) {
            IERC20(aToken).safeTransfer(msg.sender, aTokenBalance);
        }
    }

    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        address aToken = receiptTokenOf[asset];
        if (aToken == address(0)) {
            aToken = _getAToken(asset);
        }
        uint256 transferAmount = amount == type(uint256).max ? IERC20(aToken).balanceOf(msg.sender) : amount;
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), transferAmount);
        delivered = IAaveV3(aaveV3).getPool().withdraw(asset, amount, address(this));
        IERC20(asset).safeTransfer(recipient, delivered);
    }

    function getBalance(address asset) external view override returns (uint256) {
        (uint256 currentATokenBalance,,,,,,,,) = IPoolDataProvider(poolDataProvider).getUserReserveData(asset, owner());
        return currentATokenBalance;
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external view override onlyOwner {
        revert ClaimNotSupported();
    }
}
