// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

/**
 * @dev A stand-in for TRON's Stake 2.0, for the EVM: anvil cannot run TRON's staking opcodes, so the
 *      adapter's local tests point it at {MockTronStakeOps} instead of src/libs/tron/TronStakeOps.yul.
 *      The rules mirror java-tron's validators (nativecontract/*Processor.java), every failure
 *      returning false instead of reverting, as the opcodes do:
 *      - freeze and delegate at least 1 TRX; freeze no more than the balance;
 *      - unfreeze only the undelegated stake, with at most 32 unstakes pending at once, and release
 *        every expired unstake to the balance as a side effect;
 *      - delegate only to an existing non-contract account other than oneself, and only the part of
 *        the stake the account's own usage leaves delegatable.
 *      The ledger holds the frozen TRX, so balances move the way they do on TRON.
 */
contract MockTronLedger {
    uint256 public constant MIN_TRX = 1e6;
    uint256 public constant MAX_UNFREEZING = 32;

    struct Entry {
        uint256 amount;
        uint256 expireAt;
    }

    uint256 public delayDays = 14;
    mapping(address => uint256) public frozen;
    mapping(address => uint256) public delegatedOut;
    mapping(address => uint256) public usageLocked;
    mapping(address => mapping(address => uint256)) public delegation;
    mapping(address => Entry[]) private _entries;

    function setDelayDays(uint256 d) external {
        delayDays = d;
    }

    /// @dev The share of `account`'s stake its own energy usage ties up, so it cannot be delegated.
    function setUsageLocked(address account, uint256 amount) external {
        usageLocked[account] = amount;
    }

    function freeze() external payable {
        frozen[msg.sender] += msg.value;
    }

    function unfreeze(uint256 amount) external returns (bool) {
        address a = msg.sender;
        if (amount == 0 || amount > frozen[a] - delegatedOut[a]) return false;
        if (_unexpired(a) >= MAX_UNFREEZING) return false;
        _withdrawExpired(a);
        frozen[a] -= amount;
        _entries[a].push(Entry(amount, block.timestamp + delayDays * 1 days));
        return true;
    }

    function withdrawExpired() external returns (uint256) {
        return _withdrawExpired(msg.sender);
    }

    function delegate(address receiver, uint256 amount) external returns (bool) {
        address a = msg.sender;
        if (amount < MIN_TRX || receiver == a || receiver == address(0) || receiver.code.length != 0) return false;
        if (amount > delegatable(a)) return false;
        delegatedOut[a] += amount;
        delegation[a][receiver] += amount;
        return true;
    }

    function undelegate(address receiver, uint256 amount) external returns (bool) {
        address a = msg.sender;
        if (amount == 0 || amount > delegation[a][receiver]) return false;
        delegatedOut[a] -= amount;
        delegation[a][receiver] -= amount;
        return true;
    }

    function delegatable(address a) public view returns (uint256) {
        uint256 free = frozen[a] - delegatedOut[a];
        return free > usageLocked[a] ? free - usageLocked[a] : 0;
    }

    function unfreezingCount(address a) external view returns (uint256) {
        return _entries[a].length;
    }

    function _unexpired(address a) private view returns (uint256 n) {
        Entry[] storage e = _entries[a];
        for (uint256 i; i < e.length; ++i) {
            if (e[i].expireAt > block.timestamp) ++n;
        }
    }

    function _withdrawExpired(address a) private returns (uint256 total) {
        Entry[] storage e = _entries[a];
        uint256 i;
        while (i < e.length) {
            if (e[i].expireAt <= block.timestamp) {
                total += e[i].amount;
                e[i] = e[e.length - 1];
                e.pop();
            } else {
                ++i;
            }
        }
        if (total != 0) {
            (bool ok,) = a.call{value: total}("");
            require(ok, "release");
        }
    }
}

/// @dev Same ABI as TronStakeOps.yul; delegatecalled, so `address(this)` is the staking account.
contract MockTronStakeOps {
    MockTronLedger public immutable ledger;

    constructor(MockTronLedger ledger_) {
        ledger = ledger_;
    }

    function freezeBalanceV2(uint256 amount, uint256 resource) external returns (bool) {
        if (resource != 1 || amount < ledger.MIN_TRX() || amount > address(this).balance) return false;
        ledger.freeze{value: amount}();
        return true;
    }

    function unfreezeBalanceV2(uint256 amount, uint256 resource) external returns (bool) {
        if (resource != 1) return false;
        return ledger.unfreeze(amount);
    }

    function withdrawExpireUnfreeze() external returns (uint256) {
        return ledger.withdrawExpired();
    }

    function delegateResource(address receiver, uint256 amount, uint256 resource) external returns (bool) {
        if (resource != 1) return false;
        return ledger.delegate(receiver, amount);
    }

    function unDelegateResource(address receiver, uint256 amount, uint256 resource) external returns (bool) {
        if (resource != 1) return false;
        return ledger.undelegate(receiver, amount);
    }
}

/// @dev Etched at 0x100000f, TRON's delegatableResource(address, type) precompile.
contract MockDelegatablePrecompile {
    MockTronLedger public immutable ledger;

    constructor(MockTronLedger ledger_) {
        ledger = ledger_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        (address account,) = abi.decode(data, (address, uint256));
        return abi.encode(ledger.delegatable(account));
    }
}

/// @dev Etched at 0x100000b, TRON's getChainParameter(key) precompile; answers key 5 (unstake delay).
contract MockChainParameterPrecompile {
    MockTronLedger public immutable ledger;

    constructor(MockTronLedger ledger_) {
        ledger = ledger_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 key = abi.decode(data, (uint256));
        return abi.encode(key == 5 ? ledger.delayDays() : 0);
    }
}
