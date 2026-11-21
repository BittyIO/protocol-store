// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {BittyV1YieldFee} from "../BittyV1YieldFee.sol";
import {IBittyV1Yield, ClaimNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {IAaveV3, IAavePool, IPoolDataProvider} from "../libs/aave/v3/Aave.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBittyV1Guard, ASSET_STABLE_COIN} from "../interfaces/IBittyV1Guard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Supplies to Aave V3 on the vault's behalf: the vault holds the aTokens, this clone moves them.
 *         From 1.1.0 it takes Bitty's yield fee (see {BittyV1YieldFee}) in the supplied asset.
 */
contract AaveV3Protocol is IBittyV1Yield, BittyV1ProtocolBase, BittyV1YieldFee {
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
        return 1_001_000; // 1.1.0: the yield fee
    }

    function _getAToken(address asset) private view returns (address) {
        (bool success, bytes memory data) =
            poolDataProvider.staticcall(abi.encodeWithSignature("getReserveTokensAddresses(address)", asset));
        require(success, "AaveV3: aToken lookup failed");
        (address aTokenAddr,,) = abi.decode(data, (address, address, address));
        return aTokenAddr;
    }

    function _aToken(address asset) private view returns (address aToken) {
        aToken = receiptTokenOf[asset];
        if (aToken == address(0)) aToken = _getAToken(asset);
    }

    /// The Bitty guard, at this address on every chain.
    address public constant BITTY_GUARD = 0x000000000F5fcD35885BfE4c700042cE7cb39554;

    /**
     * @dev 100 tokens of an asset the guard marks a stablecoin, 0.1 of any other.
     */
    function _minFee(address asset) internal view override returns (uint256) {
        uint256 unit = 10 ** IERC20Metadata(asset).decimals();
        return IBittyV1Guard(BITTY_GUARD).assetCategory(asset) & ASSET_STABLE_COIN != 0 ? 100 * unit : unit / 10;
    }

    function _gross(address asset) internal view override returns (uint256) {
        return IERC20(_aToken(asset)).balanceOf(owner());
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = _getAToken(asset);
        }
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        (uint256 gross,) = _openBooks(asset);
        IAavePool pool = IAaveV3(aaveV3).getPool();
        if (IERC20(asset).allowance(address(this), address(pool)) < amount) {
            IERC20(asset).forceApprove(address(pool), type(uint256).max);
        }
        pool.supply(asset, amount, msg.sender, 0);
        _closeDeposit(asset, gross);
    }

    /**
     * @dev With a fee owed, the clone takes `amount` plus the fee out of Aave to itself and splits it;
     *      with none, Aave pays `recipient` directly, as before the fee.
     */
    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        address aToken = _aToken(asset);
        (uint256 gross, uint256 owed) = _openBooks(asset);
        uint256 due = _feeDue(asset, amount, owed);
        IAavePool pool = IAaveV3(aaveV3).getPool();
        bool all = amount == type(uint256).max;
        uint256 transferAmount = all ? IERC20(aToken).balanceOf(msg.sender) : amount + due;
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), transferAmount);
        if (due == 0) {
            delivered = pool.withdraw(asset, amount, recipient);
        } else {
            uint256 out = pool.withdraw(asset, all ? type(uint256).max : transferAmount, address(this));
            uint256 fee = due < out ? due : out;
            _payYieldFee(asset, fee);
            delivered = out - fee;
            IERC20(asset).safeTransfer(recipient, delivered);
        }
        _closeWithdrawal(asset, gross, due != owed);
    }

    /**
     * What the vault can take out: its aTokens less the yield fee they owe.
     */
    function getBalance(address asset) external view override returns (uint256) {
        return _net(asset);
    }

    function getPendingWithdrawalIds() external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }

    function claimWithdrawals(uint256[] memory) external view override onlyOwner {
        revert ClaimNotSupported();
    }
}
