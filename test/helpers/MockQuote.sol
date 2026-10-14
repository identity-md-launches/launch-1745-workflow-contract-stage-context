// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only IMD stand-in with configurable failures to exercise atomicity and reentrancy.
contract MockQuote is ERC20 {
    address public blockedRecipient;
    bool public taxed;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bool private entered;

    constructor() ERC20("Test IMD", "IMD") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function setTax(bool active) external {
        taxed = active;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            require(to != blockedRecipient, "blocked recipient");
            if (reentryTarget != address(0) && !entered) {
                entered = true;
                reentryAttempted = true;
                (reentrySucceeded,) = reentryTarget.call(reentryData);
                entered = false;
            }
            if (taxed) {
                uint256 tax = amount / 100;
                super._update(from, address(0xdead), tax);
                amount -= tax;
            }
        }
        super._update(from, to, amount);
    }
}
