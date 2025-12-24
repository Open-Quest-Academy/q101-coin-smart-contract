// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title Q101Token
 * @notice Upgradeable ERC-20 token for Open-Q Education Foundation
 * @dev Upgradeable ERC-20 token with fixed supply of 1 billion tokens
 *      Token name and symbol are configurable during initialization
 *      Supports emergency pause/unpause and UUPS upgradeability
 *      All tokens are minted to Gnosis Safe multisig wallet at initialization
 */
contract Q101Token is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    /// @notice Total supply: 1 billion tokens (with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10**18;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (replaces constructor for upgradeable contracts)
     * @param name_ Token name (e.g., "Open-Q Education Foundation 101 Token")
     * @param symbol_ Token symbol (e.g., "Q101")
     * @param gnosisSafe Address of the Gnosis Safe multisig wallet
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address gnosisSafe
    ) public initializer {
        require(gnosisSafe != address(0), "Q101Token: Invalid Gnosis Safe address");
        require(bytes(name_).length > 0, "Q101Token: Invalid token name");
        require(bytes(symbol_).length > 0, "Q101Token: Invalid token symbol");

        __ERC20_init(name_, symbol_);
        __Ownable_init(gnosisSafe);
        __Pausable_init();

        _mint(gnosisSafe, TOTAL_SUPPLY);
    }

    /**
     * @notice Pause all token transfers
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause all token transfers
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Override transfer to add pause functionality
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override whenNotPaused {
        super._update(from, to, value);
    }

    /**
     * @notice Authorize upgrade (required by UUPSUpgradeable)
     * @dev Can only be called by owner (Gnosis Safe)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Get the version of the contract
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
