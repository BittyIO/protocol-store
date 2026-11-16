// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {BittyV1ProtocolBase} from "../BittyV1ProtocolBase.sol";
import {BittyV1YieldFee} from "../BittyV1YieldFee.sol";
import {IBittyV1Protocol, InvalidAsset} from "../interfaces/IBittyV1Protocol.sol";
import {IBittyV1Yield, WithdrawToNotSupported} from "../interfaces/IBittyV1Yield.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStETH, IUnstETH} from "../libs/lido/v2/Lido.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

error WETHBalanceNotEnough();

/**
 * @notice Stakes the vault's WETH with Lido: the vault holds the stETH, this clone moves it, and a
 *         withdrawal goes through Lido's queue, paid out in WETH when claimed.
 *         From 1.1.0 it takes Bitty's yield fee (see {BittyV1YieldFee}). A withdrawal puts the fee owed into the same Lido request as the amount, and the request's
 *         share of the fee is paid in ETH (as WETH) when it is claimed, in proportion to what Lido
 *         pays out for it. Requests made before 1.1.0 carry no fee.
 */
contract LidoV2Protocol is IBittyV1Yield, BittyV1ProtocolBase, BittyV1YieldFee {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.UintSet private _unstakeRequests;
    IStETH public immutable stETH;
    IUnstETH public immutable unstETH;
    WETH public immutable weth;

    mapping(address => address) public receiptTokenOf;

    constructor(address stETH_, address unstETH_, address weth_) {
        stETH = IStETH(stETH_);
        unstETH = IUnstETH(unstETH_);
        weth = WETH(payable(weth_));
    }

    function protocolLineage() external pure override returns (bytes32) {
        return keccak256("bitty.adapter.lido.v2");
    }

    function protocolVersion() external pure override returns (uint256) {
        return 1_001_000; // 1.1.0: the yield fee
    }

    receive() external payable {}

    /**
     * @dev 0.1 WETH.
     */
    function _minFee(address) internal pure override returns (uint256) {
        return 0.1 ether;
    }

    function _gross(address) internal view override returns (uint256) {
        return stETH.balanceOf(owner());
    }

    function deposit(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        if (weth.balanceOf(msg.sender) < amount) {
            revert WETHBalanceNotEnough();
        }
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        (uint256 gross,) = _openBooks(asset);

        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = address(stETH);
        }
        weth.withdraw(amount);
        uint256 stETHBefore = stETH.balanceOf(address(this));
        stETH.submit{value: amount}(address(this));
        uint256 stETHReceived = stETH.balanceOf(address(this)) - stETHBefore;
        if (stETHReceived > 0) {
            IERC20(address(stETH)).safeTransfer(msg.sender, stETHReceived);
        }
        _closeDeposit(asset, gross);
    }

    /**
     * What the vault can take out: its stETH less the yield fee it owes.
     */
    function getBalance(address asset) external view override returns (uint256) {
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        return _net(asset);
    }

    function getPendingWithdrawalIds() external view override returns (uint256[] memory) {
        return _unstakeRequests.values();
    }

    /**
     * @dev Requests `amount` plus the fee owed (all of it for the maximum), and records the request's
     *      share of the fee for {claimWithdrawals}.
     */
    function withdraw(address asset, uint256 amount, address recipient)
        external
        override
        onlyOwner
        returns (uint256 delivered)
    {
        if (recipient != owner()) revert WithdrawToNotSupported();
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        (uint256 gross, uint256 owed) = _openBooks(asset);
        uint256 due = _feeDue(asset, amount, owed);
        if (amount == type(uint256).max) {
            amount = IERC20(address(stETH)).balanceOf(msg.sender);
        } else {
            amount += due;
        }
        uint256 balanceBefore = IERC20(address(stETH)).balanceOf(address(this));
        IERC20(address(stETH)).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(address(stETH)).balanceOf(address(this)) - balanceBefore;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = received;
        if (IERC20(address(stETH)).allowance(address(this), address(unstETH)) < received) {
            IERC20(address(stETH)).forceApprove(address(unstETH), type(uint256).max);
        }
        uint256[] memory requestIds = unstETH.requestWithdrawals(amounts, address(this));
        _unstakeRequests.add(requestIds[0]);
        if (due != 0) {
            _yieldFee().pending[requestIds[0]] =
                PendingFee({fee: uint128(due < received ? due : received), requested: uint128(received)});
        }
        _closeWithdrawal(asset, gross, due != owed);
        return 0;
    }

    function claimWithdrawals(uint256[] memory requestIds) external override onlyOwner {
        uint256[] memory oneIds = new uint256[](1);
        uint256 ethBefore = address(this).balance;
        uint256 fee;
        for (uint256 i = 0; i < requestIds.length; i++) {
            oneIds[0] = requestIds[i];
            IUnstETH.WithdrawalRequestStatus[] memory statuses = unstETH.getWithdrawalStatus(oneIds);
            if (statuses[0].isFinalized && !statuses[0].isClaimed) {
                uint256 before = address(this).balance;
                unstETH.claimWithdrawal(requestIds[i]);
                _unstakeRequests.remove(requestIds[i]);
                PendingFee memory p = _yieldFee().pending[requestIds[i]];
                if (p.requested != 0) {
                    fee += (address(this).balance - before) * p.fee / p.requested;
                    delete _yieldFee().pending[requestIds[i]];
                }
            }
        }
        uint256 ethClaimed = address(this).balance - ethBefore;
        if (ethClaimed > 0) {
            weth.deposit{value: ethClaimed}();
            _payYieldFee(address(weth), fee);
            IERC20(address(weth)).safeTransfer(msg.sender, ethClaimed - fee);
        }
    }
}
