// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title MockFailingToken
 * @notice Mock ERC20 token that can be configured to fail transfers for testing
 */
contract MockFailingToken is ERC20Upgradeable {
    bool public shouldFailTransfer;

    function initialize(string memory name, string memory symbol, address initialOwner, uint256 initialSupply)
        public
        initializer
    {
        __ERC20_init(name, symbol);
        _mint(initialOwner, initialSupply);
        shouldFailTransfer = false;
    }

    /**
     * @notice Set whether transfers should fail
     */
    function setShouldFailTransfer(bool _shouldFail) external {
        shouldFailTransfer = _shouldFail;
    }

    /**
     * @notice Override transfer to optionally return false instead of reverting
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (shouldFailTransfer) {
            return false;
        }
        return super.transfer(to, amount);
    }

    /**
     * @notice Override transferFrom to optionally return false
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        if (shouldFailTransfer) {
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}
