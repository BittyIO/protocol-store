// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1LendingProtocol} from "../interfaces/IBittyV1LendingProtocol.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "../libs/aave/v3/Aave.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

contract AaveV3Protocol is IBittyV1LendingProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;
    address public immutable aaveV3;
    address public immutable poolDataProvider;

    mapping(address => address) public receiptTokenOf;

    constructor(address aaveV3_, address poolDataProvider_) Ownable(msg.sender) {
        aaveV3 = aaveV3_;
        poolDataProvider = poolDataProvider_;
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    function _getAToken(address asset) private view returns (address) {
        (bool success, bytes memory data) =
            poolDataProvider.staticcall(abi.encodeWithSignature("getReserveTokensAddresses(address)", asset));
        require(success, "AaveV3: aToken lookup failed");
        (address aTokenAddr,,) = abi.decode(data, (address, address, address));
        return aTokenAddr;
    }

    function supply(address asset, uint256 amount) external payable override onlyOwner {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IAavePool pool = IAaveV3(aaveV3).getPool();
        IERC20(asset).safeIncreaseAllowance(address(pool), amount);
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

    function withdraw(address asset, uint256 amount) external override onlyOwner {
        address aToken = receiptTokenOf[asset];
        if (aToken == address(0)) {
            aToken = _getAToken(asset);
        }
        uint256 transferAmount = amount == type(uint256).max ? IERC20(aToken).balanceOf(msg.sender) : amount;
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), transferAmount);
        IAaveV3(aaveV3).getPool().withdraw(asset, amount, msg.sender);
    }

    function getSuppliedBalance(address asset) external view override returns (uint256) {
        (uint256 currentATokenBalance,,,,,,,,) = IPoolDataProvider(poolDataProvider).getUserReserveData(asset, owner());
        return currentATokenBalance;
    }
}
