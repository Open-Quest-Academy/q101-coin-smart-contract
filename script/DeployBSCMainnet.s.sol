// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/Q101Token.sol";
import "../src/Q101AirdropVesting.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployBSCMainnet
 * @notice Script to deploy Q101Token and 2 Q101AirdropVesting contracts to BSC Mainnet
 * @dev All contracts are deployed as upgradeable proxies (UUPS pattern)
 *      This is a reference deployment script for audit purposes
 */
contract DeployBSCMainnet is Script {
    // BSC Mainnet Configuration
    // IMPORTANT: Replace with your actual Gnosis Safe multi-sig address before deployment
    address constant GNOSIS_SAFE = 0x0000000000000000000000000000000000000000; // Multi-sig wallet (REPLACE THIS)

    // Gelato Relay ERC2771 Trusted Forwarder (BSC Mainnet)
    // Official address: https://docs.gelato.network/web3-services/relay/erc-2771-recommended
    address constant GELATO_RELAY_ERC2771 = 0xd8253782c45a12053594b9deB72d8e8aB2Fca54c;

    // Token configuration (configurable at deployment)
    string constant TOKEN_NAME = "Education Token";
    string constant TOKEN_SYMBOL = "EDU";

    // Vesting configurations
    struct VestingConfig {
        string name;
        uint64 startTime;
        uint256 vestingMonths;
        uint256 minWithdrawInterval;
        uint256 minWithdrawAmount;
        uint256 immediateReleaseRatio; // in basis points (10000 = 100%)
        uint256 minRevealDelay;
        uint256 maxRevealDelay;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== BSC Mainnet Dual Vesting Deployment Configuration ===");
        console.log("Deployer:", deployer);
        console.log("Multi-sig Wallet (Owner):", GNOSIS_SAFE);
        console.log("Network: BSC Mainnet (Chain ID: 56)");
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy Token ============

        console.log("=== Deploying Q101Token ===");

        // 1. Deploy implementation
        Q101Token tokenImplementation = new Q101Token();
        console.log("Token Implementation:", address(tokenImplementation));

        // 2. Prepare initialization data
        bytes memory tokenInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            GNOSIS_SAFE
        );

        // 3. Deploy proxy
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImplementation),
            tokenInitData
        );
        console.log("Token Proxy (USE THIS):", address(tokenProxy));

        Q101Token token = Q101Token(address(tokenProxy));
        console.log("  Name:", token.name());
        console.log("  Symbol:", token.symbol());
        console.log("  Total Supply (tokens):", token.totalSupply() / 10**18);
        console.log("  Owner:", token.owner());
        console.log("");

        // ============ Deploy Shareholder Vesting ============

        VestingConfig memory shareholderConfig = VestingConfig({
            name: "Shareholder",
            startTime: uint64(block.timestamp + 0 days),  // Start immediately
            vestingMonths: 36,                             // 36 months (3 years)
            minWithdrawInterval: 30 days,                  // 30 days minimum withdrawal interval
            minWithdrawAmount: 100 * 10**18,               // 100 tokens minimum
            immediateReleaseRatio: 1000,                   // 10% immediate release
            minRevealDelay: 3,                             // 3 blocks (~9 seconds on BSC)
            maxRevealDelay: 255                            // 255 blocks (~12.75 minutes on BSC)
        });

        address shareholderVesting = _deployVesting(
            address(tokenProxy),
            shareholderConfig,
            "SHAREHOLDER"
        );

        // ============ Deploy Team Vesting ============

        VestingConfig memory teamConfig = VestingConfig({
            name: "Team",
            startTime: uint64(block.timestamp + 0 days),  // Start immediately
            vestingMonths: 48,                             // 48 months (4 years)
            minWithdrawInterval: 30 days,                  // 30 days minimum withdrawal interval
            minWithdrawAmount: 200 * 10**18,               // 200 tokens minimum
            immediateReleaseRatio: 500,                    // 5% immediate release
            minRevealDelay: 3,                             // 3 blocks
            maxRevealDelay: 255                            // 255 blocks
        });

        address teamVesting = _deployVesting(
            address(tokenProxy),
            teamConfig,
            "TEAM"
        );

        vm.stopBroadcast();

        // ============ Deployment Summary ============

        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("Network: BSC Mainnet");
        console.log("Chain ID: 56");
        console.log("");
        console.log("Token Implementation:", address(tokenImplementation));
        console.log("Token Proxy (USE THIS):", address(tokenProxy));
        console.log("");
        console.log("Shareholder Vesting Proxy:", shareholderVesting);
        console.log("Team Vesting Proxy:", teamVesting);
        console.log("");
        console.log("Owner (Multi-sig):", GNOSIS_SAFE);
        console.log("");

        // ============ Post-Deployment Instructions ============

        console.log("=== POST-DEPLOYMENT STEPS ===");
        console.log("");
        console.log("1. VERIFY CONTRACTS on BSCScan:");
        console.log("   forge verify-contract <ADDRESS> src/Q101Token.sol:Q101Token --chain bsc");
        console.log("");
        console.log("2. SET MERKLE ROOTS (via Multi-sig wallet):");
        console.log("   - Shareholder Contract:", shareholderVesting);
        console.log("     Function: updateMerkleRoot(bytes32 _merkleRoot)");
        console.log("   - Team Contract:", teamVesting);
        console.log("     Function: updateMerkleRoot(bytes32 _merkleRoot)");
        console.log("   NOTE: Merkle roots can only be set ONCE per contract!");
        console.log("");
        console.log("3. CONFIGURE AIRDROP (via Multi-sig wallet):");
        console.log("   Call configureAirdrop() on each vesting contract with:");
        console.log("   - Shareholder: 36 months, 10% immediate (1000 basis points)");
        console.log("   - Team: 48 months, 5% immediate (500 basis points)");
        console.log("");
        console.log("4. TRANSFER TOKENS to Vesting Contracts:");
        console.log("   - From: Multi-sig wallet (", GNOSIS_SAFE, ")");
        console.log("   - To Shareholder Vesting:", shareholderVesting);
        console.log("   - To Team Vesting:", teamVesting);
        console.log("");
        console.log("=== SECURITY REMINDERS ===");
        console.log("- All admin operations require multi-sig approval");
        console.log("- Merkle roots are immutable after being set");
        console.log("- Test thoroughly on BSC Testnet before mainnet deployment");
        console.log("- Ensure sufficient BNB balance for gas fees");
    }

    function _deployVesting(
        address tokenAddress,
        VestingConfig memory config,
        string memory label
    ) internal returns (address) {
        console.log("=== Deploying", config.name, "Vesting Contract ===");

        // 1. Deploy implementation
        Q101AirdropVesting vestingImplementation = new Q101AirdropVesting(GELATO_RELAY_ERC2771);
        console.log(label, "Vesting Implementation:", address(vestingImplementation));
        console.log("Gelato Relay ERC2771:", GELATO_RELAY_ERC2771);

        // 2. Prepare initialization data (basic parameters only)
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            tokenAddress,
            config.minRevealDelay,
            config.maxRevealDelay,
            GNOSIS_SAFE
        );

        // 3. Deploy proxy
        ERC1967Proxy vestingProxy = new ERC1967Proxy(
            address(vestingImplementation),
            vestingInitData
        );
        console.log(label, "Vesting Proxy (USE THIS):", address(vestingProxy));

        Q101AirdropVesting vesting = Q101AirdropVesting(address(vestingProxy));
        console.log("  Token:", address(vesting.token()));
        console.log("  Owner:", vesting.owner());
        console.log("  Configured:", vesting.isAirdropConfigured() ? "Yes" : "No");
        console.log("  Min Reveal Delay:", vesting.minRevealDelay(), "blocks");
        console.log("  Max Reveal Delay:", vesting.maxRevealDelay(), "blocks");
        console.log("");
        console.log("  IMPORTANT: Must call configureAirdrop() after deployment with:");
        console.log("    - startTime:", config.startTime);
        console.log("    - vestingMonths:", config.vestingMonths);
        console.log("    - immediateReleaseRatio:", config.immediateReleaseRatio, "(basis points)");
        console.log("    - minWithdrawInterval:", config.minWithdrawInterval, "seconds");
        console.log("    - minWithdrawAmount:", config.minWithdrawAmount, "wei");
        console.log("");

        return address(vestingProxy);
    }
}
