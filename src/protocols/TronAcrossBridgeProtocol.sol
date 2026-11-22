// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {AcrossBridgeProtocol, BridgeDestinationUnsupported} from "./AcrossBridgeProtocol.sol";
import {ZeroFeeRecipient} from "./SunSwapUniversalTradeProtocol.sol";
import {TRC20Transfer} from "../libs/tron/TRC20Transfer.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title TronAcrossBridgeProtocol
 * @notice Bridges out of a TRON vault through Across's TRON SpokePool (Tron_SpokePool, the same
 *         `deposit` as on every EVM chain). Everything {AcrossBridgeProtocol} enforces holds here
 *         unchanged: the recipient is this vault's counterpart on the destination chain, the route
 *         must be configured in the guard, and what arrives is bounded by the route's cost.
 *
 * @dev What differs from the EVM deployments:
 *      - DESTINATIONS are EVM chains, and a TRON vault's address is not its EVM counterpart's, so
 *        every request names the vault's creation owner: the adapter checks that this vault is the
 *        TRON factory's CREATE2 of that owner, then pays that owner's EVM vault (the same key is the
 *        same 20-byte owner). The TRON factory and its proxy init-code hash are constructor
 *        arguments for that check.
 *      - FEE RECIPIENT: the fee Safe's vault does not exist on TRON, so the recipient is a constructor
 *        argument and {feeRecipient} returns it. The inherited {FEE_RECIPIENT} constant still reads the
 *        EVM address; it is not used here.
 *      - TOKEN TRANSFERS go through {TRC20Transfer}: TRON USDT's `transfer` returns false on success.
 *        Its `transferFrom` and `approve` return true, so the pull from the vault and the SpokePool's
 *        allowance are unchanged.
 *      - THE NATIVE COIN is TRX, 6 decimals, wrapped by the SpokePool as WTRX.
 *      Same lineage as the EVM adapter: TRON's guard lists only this one.
 */
contract TronAcrossBridgeProtocol is AcrossBridgeProtocol {
    address private immutable _feeRecipient;

    constructor(
        address spokePool_,
        address bittyGuard_,
        address feeRecipient_,
        address tronVaultFactory_,
        bytes32 tronVaultInitCodeHash_
    ) AcrossBridgeProtocol(spokePool_, bittyGuard_, tronVaultFactory_, tronVaultInitCodeHash_) {
        if (feeRecipient_ == address(0)) revert ZeroFeeRecipient();
        if (tronVaultFactory_ == address(0) || tronVaultInitCodeHash_ == bytes32(0)) {
            revert BridgeDestinationUnsupported();
        }
        _feeRecipient = feeRecipient_;
    }

    function feeRecipient() public view override returns (address) {
        return _feeRecipient;
    }

    function _transferToken(address token, address to, uint256 amount) internal override {
        TRC20Transfer.safeTransfer(IERC20(token), to, amount);
    }

    function _onTron() internal pure override returns (bool) {
        return true;
    }

    function _nativeDecimals() internal pure override returns (uint8) {
        return 6;
    }
}
