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
 *
 * Three-Stage Vesting Model:
 * - Stage 1 (Immediate): Released immediately at claim time
 * - Stage 2 (Cliff): Released after cliff period ends
 * - Stage 3 (Linear Vesting): Remaining amount vests linearly over time
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
        bytes32 merkleRoot;             // Set to 0x0 for post-deployment configuration
        uint64 startTime;
        uint256 vestingMonths;          // Linear vesting duration in months (for display only, converted to seconds in configureAirdrop)
        uint256 cliffMonths;            // Cliff period duration in months (for display only, converted to seconds in configureAirdrop)
        uint256 immediateReleaseRatio;  // Immediate release % (basis points, 10000 = 100%)
        uint256 cliffReleaseRatio;      // Cliff release % (basis points)
        uint256 minWithdrawInterval;    // Minimum time between withdrawals
        uint256 minWithdrawAmount;      // Minimum withdrawal amount
        uint256 minRevealDelay;         // Minimum blocks between commit and reveal
        uint256 maxRevealDelay;         // Maximum blocks between commit and reveal
        uint8 vestingFrequency;         // 0=PER_SECOND, 1=PER_DAY, 2=PER_MONTH
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
        // Configuration: 36 months total (6 cliff + 30 linear)
        // Release model: 10% immediate, 20% at cliff (6 months), 70% linear (30 months)

        VestingConfig memory shareholderConfig = VestingConfig({
            name: "Shareholder",
            merkleRoot: bytes32(0),                        // Set via multi-sig after deployment
            startTime: uint64(block.timestamp),            // Start immediately
            vestingMonths: 30,                             // 30 months linear vesting (after cliff)
            cliffMonths: 6,                                // 6 months cliff period
            immediateReleaseRatio: 1000,                   // 10% immediate release (1000 basis points)
            cliffReleaseRatio: 2000,                       // 20% at cliff end (2000 basis points)
            minWithdrawInterval: 30 days,                  // 30 days minimum withdrawal interval
            minWithdrawAmount: 100 * 10**18,               // 100 tokens minimum
            minRevealDelay: 3,                             // 3 blocks (~9 seconds on BSC)
            maxRevealDelay: 255,                           // 255 blocks (~12.75 minutes on BSC)
            vestingFrequency: 0                            // PER_SECOND (most precise)
        });

        address shareholderVesting = _deployVesting(
            address(tokenProxy),
            shareholderConfig,
            "SHAREHOLDER"
        );

        // ============ Deploy Team Vesting ============
        // Configuration: 48 months total (12 cliff + 36 linear)
        // Release model: 5% immediate, 15% at cliff (12 months), 80% linear (36 months)

        VestingConfig memory teamConfig = VestingConfig({
            name: "Team",
            merkleRoot: bytes32(0),                        // Set via multi-sig after deployment
            startTime: uint64(block.timestamp),            // Start immediately
            vestingMonths: 36,                             // 36 months linear vesting (after cliff)
            cliffMonths: 12,                               // 12 months cliff period
            immediateReleaseRatio: 500,                    // 5% immediate release (500 basis points)
            cliffReleaseRatio: 1500,                       // 15% at cliff end (1500 basis points)
            minWithdrawInterval: 30 days,                  // 30 days minimum withdrawal interval
            minWithdrawAmount: 200 * 10**18,               // 200 tokens minimum
            minRevealDelay: 3,                             // 3 blocks
            maxRevealDelay: 255,                           // 255 blocks
            vestingFrequency: 0                            // PER_SECOND (most precise)
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
        console.log("  - Total Duration: 36 months (6 cliff + 30 linear)");
        console.log("  - Immediate: 10%, Cliff: 20%, Linear: 70%");
        console.log("");
        console.log("Team Vesting Proxy:", teamVesting);
        console.log("  - Total Duration: 48 months (12 cliff + 36 linear)");
        console.log("  - Immediate: 5%, Cliff: 15%, Linear: 80%");
        console.log("");
        console.log("Owner (Multi-sig):", GNOSIS_SAFE);
        console.log("");

        // ============ Post-Deployment Instructions ============

        console.log("=== POST-DEPLOYMENT STEPS (via Multi-sig) ===");
        console.log("");
        console.log("1. VERIFY CONTRACTS on BSCScan:");
        console.log("   forge verify-contract <ADDRESS> src/Q101Token.sol:Q101Token --chain bsc");
        console.log("");
        console.log("2. CONFIGURE AIRDROP (via Multi-sig wallet):");
        console.log("   Call configureAirdrop() on each vesting contract:");
        console.log("");
        console.log("   Shareholder Vesting - configureAirdrop Parameters:");
        console.log("   - startTime: block.timestamp (e.g., 1700000000)");
        console.log("   - merkleRoot: 0x... (from backend CSV upload)");
        console.log("   - vestingDuration: 77760000 (30 months in seconds)");
        console.log("   - cliffDuration: 15552000 (6 months in seconds)");
        console.log("   - immediateReleaseRatio: 1000 (10%)");
        console.log("   - cliffReleaseRatio: 2000 (20%)");
        console.log("   - vestingFrequency: 0 (PER_SECOND)");
        console.log("   - minWithdrawInterval: 2592000 (30 days)");
        console.log("   - minWithdrawAmount: 100000000000000000000 (100 tokens wei)");
        console.log("");
        console.log("   Team Vesting - configureAirdrop Parameters:");
        console.log("   - startTime: block.timestamp (e.g., 1700000000)");
        console.log("   - merkleRoot: 0x... (from backend CSV upload)");
        console.log("   - vestingDuration: 93312000 (36 months in seconds)");
        console.log("   - cliffDuration: 31104000 (12 months in seconds)");
        console.log("   - immediateReleaseRatio: 500 (5%)");
        console.log("   - cliffReleaseRatio: 1500 (15%)");
        console.log("   - vestingFrequency: 0 (PER_SECOND)");
        console.log("   - minWithdrawInterval: 2592000 (30 days)");
        console.log("   - minWithdrawAmount: 200000000000000000000 (200 tokens wei)");
        console.log("");
        console.log("3. TRANSFER TOKENS to Vesting Contracts:");
        console.log("   - From: Multi-sig wallet (", GNOSIS_SAFE, ")");
        console.log("   - To Shareholder Vesting:", shareholderVesting);
        console.log("   - To Team Vesting:", teamVesting);
        console.log("");
        console.log("=== SECURITY REMINDERS ===");
        console.log("- All admin operations require multi-sig approval");
        console.log("- Merkle roots are immutable after being set via configureAirdrop()");
        console.log("- Test thoroughly on BSC Testnet before mainnet deployment");
        console.log("- Ensure sufficient BNB balance for gas fees");
        console.log("- Verify all parameters match business requirements");
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
        console.log("  Configured:", vesting.isAirdropConfigured() ? "Yes" : "No (requires configureAirdrop)");
        console.log("  Min Reveal Delay:", vesting.minRevealDelay(), "blocks");
        console.log("  Max Reveal Delay:", vesting.maxRevealDelay(), "blocks");
        console.log("");
        console.log("  Configuration Summary:");
        console.log("    - Vesting Duration:", config.vestingMonths, "months");
        console.log("    - Cliff Duration:", config.cliffMonths, "months");
        console.log("    - Immediate Release:", config.immediateReleaseRatio / 100, "%");
        console.log("    - Cliff Release:", config.cliffReleaseRatio / 100, "%");
        console.log("    - Linear Vesting:", (10000 - config.immediateReleaseRatio - config.cliffReleaseRatio) / 100, "%");
        console.log("");

        return address(vestingProxy);
    }
}
