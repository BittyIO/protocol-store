// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {
    IBittyV1StakingProtocol,
    UnstakeMoreThanStaked,
    InvalidAsset,
    UnstakeToNotSupported
} from "../interfaces/IBittyV1StakingProtocol.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {IStETH, IUnstETH} from "../libs/lido/v2/Lido.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {EnumerableSet} from "openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

error WETHBalanceNotEnough();

contract LidoV2Protocol is IBittyV1StakingProtocol, Ownable, Initializable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    EnumerableSet.UintSet private _unstakeRequests;
    IStETH public immutable stETH;
    IUnstETH public immutable unstETH;
    WETH public immutable weth;

    mapping(address => address) public receiptTokenOf;

    constructor(address stETH_, address unstETH_, address weth_) Ownable(msg.sender) {
        stETH = IStETH(stETH_);
        unstETH = IUnstETH(unstETH_);
        weth = WETH(payable(weth_));
    }

    function initialize(address newOwner) external override initializer {
        _transferOwnership(newOwner);
    }

    receive() external payable {}

    function stake(address asset, uint256 amount) external payable override onlyOwner {
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        if (weth.balanceOf(msg.sender) < amount) {
            revert WETHBalanceNotEnough();
        }
        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        weth.withdraw(amount);
        uint256 stETHBefore = stETH.balanceOf(address(this));
        stETH.submit{value: amount}(address(this));
        uint256 stETHReceived = stETH.balanceOf(address(this)) - stETHBefore;

        if (receiptTokenOf[asset] == address(0)) {
            receiptTokenOf[asset] = address(stETH);
        }
        if (stETHReceived > 0) {
            IERC20(address(stETH)).safeTransfer(msg.sender, stETHReceived);
        }
    }

    /**
     * @notice Get the staking balance of the WETH.
     * @dev Get the staking balance of the WETH.
     * @param asset The address of the WETH.
     * @return The staking balance of the WETH query from stETH.
     */
    function getStakedBalance(address asset) external view override returns (uint256) {
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        return stETH.balanceOf(owner());
    }

    function getUnstakeRequestIds() external view override returns (uint256[] memory) {
        return _unstakeRequests.values();
    }

    function unstake(address asset, uint256 amount) external override onlyOwner {
        if (asset != address(weth)) {
            revert InvalidAsset();
        }
        if (amount == type(uint256).max) {
            amount = IERC20(address(stETH)).balanceOf(msg.sender);
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
    }

    /**
     * @notice Not supported: Lido withdrawals settle asynchronously via a queue, so the
     * asset cannot be delivered to a recipient in the same transaction.
     * @dev Always reverts with {UnstakeToNotSupported}. Use {unstake} then {claimUnstaked}.
     */
    function unstakeTo(address, uint256, address) external view override onlyOwner returns (uint256) {
        revert UnstakeToNotSupported();
    }

    function claimUnstaked(uint256[] memory requestIds) external override onlyOwner {
        uint256[] memory oneIds = new uint256[](1);
        uint256 ethBefore = address(this).balance;
        for (uint256 i = 0; i < requestIds.length; i++) {
            oneIds[0] = requestIds[i];
            IUnstETH.WithdrawalRequestStatus[] memory statuses = unstETH.getWithdrawalStatus(oneIds);
            if (statuses[0].isFinalized && !statuses[0].isClaimed) {
                unstETH.claimWithdrawal(requestIds[i]);
                _unstakeRequests.remove(requestIds[i]);
            }
        }
        uint256 ethClaimed = address(this).balance - ethBefore;
        if (ethClaimed > 0) {
            weth.deposit{value: ethClaimed}();
            IERC20(address(weth)).safeTransfer(msg.sender, ethClaimed);
        }
    }
}
