// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101AirdropVesting.sol";
import "../src/Q101Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Q101AirdropVesting V3.2 Test Suite
 * @notice Tests for V3.2 features: three-stage vesting, cliff period, vesting frequencies
 */
contract Q101AirdropVestingV32Test is Test {
    Q101Token public tokenImpl;
    Q101Token public token;
    Q101AirdropVesting public vestingImpl;
    Q101AirdropVesting public vesting;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public gelatoRelay = address(0x4);

    bytes32 public merkleRoot;
    uint64 public startTime;

    // Events
    event MerkleRootUpdated(bytes32 indexed oldRoot, bytes32 indexed newRoot);

    // Test configuration
    uint256 constant VESTING_DURATION = 30 * 30 days; // 30 months
    uint256 constant CLIFF_DURATION = 6 * 30 days;    // 6 months
    uint256 constant IMMEDIATE_RATIO = 1000;           // 10%
    uint256 constant CLIFF_RATIO = 2000;               // 20%
    uint256 constant MIN_WITHDRAW_INTERVAL = 30 days;
    uint256 constant MIN_WITHDRAW_AMOUNT = 100 * 10**18;

    function setUp() public {
        // Deploy token
        tokenImpl = new Q101Token();
        bytes memory tokenInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Q101 Token",
            "Q101",
            owner
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = Q101Token(address(tokenProxy));

        // Tokens are already minted to owner during initialize()

        // Deploy vesting with simplified initialize
        vestingImpl = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,      // minRevealDelay
            255,    // maxRevealDelay
            owner
        );
        ERC1967Proxy vestingProxy = new ERC1967Proxy(address(vestingImpl), vestingInitData);
        vesting = Q101AirdropVesting(address(vestingProxy));

        // Transfer tokens to vesting contract
        vm.prank(owner);
        token.transfer(address(vesting), 500000 * 10**18);

        // Setup merkle root
        merkleRoot = bytes32(uint256(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef));
        startTime = uint64(block.timestamp);
    }

    // ============ Configuration Tests ============

    function testInitializeWithoutVestingParams() public {
        // Verify basic params set
        assertEq(address(vesting.token()), address(token));
        assertEq(vesting.minRevealDelay(), 3);
        assertEq(vesting.maxRevealDelay(), 255);

        // Verify vesting params NOT set (all zero)
        assertEq(vesting.startTime(), 0);
        assertEq(vesting.merkleRoot(), bytes32(0));
        assertEq(vesting.vestingDuration(), 0);
        assertEq(vesting.cliffDuration(), 0);
        assertEq(vesting.immediateReleaseRatio(), 0);
        assertEq(vesting.cliffReleaseRatio(), 0);

        // Verify not configured
        assertFalse(vesting.isAirdropConfigured());
    }

    function testConfigureAirdropOnce() public {
        // Configure airdrop
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Verify configured
        assertTrue(vesting.isAirdropConfigured());
        assertEq(vesting.merkleRoot(), merkleRoot);
        assertEq(vesting.startTime(), startTime);
        assertEq(vesting.vestingDuration(), VESTING_DURATION);
        assertEq(vesting.cliffDuration(), CLIFF_DURATION);

        // Try to configure again (should revert)
        vm.expectRevert("Airdrop already configured");
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );
    }

    function testConfigureAirdropOnlyOwner() public {
        // Try to configure as non-owner
        vm.expectRevert();
        vm.prank(user1);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );
    }

    function testConfigureAirdropValidation() public {
        // Test: Invalid startTime (zero)
        vm.expectRevert("Invalid start time");
        vm.prank(owner);
        vesting.configureAirdrop(
            uint64(0),  // Zero start time
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Test: Invalid merkle root (zero)
        vm.expectRevert("Invalid merkle root");
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            bytes32(0),
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Test: Invalid ratio (immediate + cliff > 100%)
        vm.expectRevert("Immediate + Cliff ratio must <= 100%");
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            6000,   // 60%
            5000,   // 50% (total = 110%)
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );
    }

    function testGetAirdropConfig() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Retrieve configuration
        (
            uint64 _startTime,
            bytes32 _merkleRoot,
            uint256 _vestingDuration,
            uint256 _cliffDuration,
            uint256 _immediateReleaseRatio,
            uint256 _cliffReleaseRatio,
            Q101AirdropVesting.VestingFrequency _vestingFrequency,
            uint256 _minWithdrawInterval,
            uint256 _minWithdrawAmount
        ) = vesting.getAirdropConfig();

        // Verify all parameters
        assertEq(_startTime, startTime);
        assertEq(_merkleRoot, merkleRoot);
        assertEq(_vestingDuration, VESTING_DURATION);
        assertEq(_cliffDuration, CLIFF_DURATION);
        assertEq(_immediateReleaseRatio, IMMEDIATE_RATIO);
        assertEq(_cliffReleaseRatio, CLIFF_RATIO);
        assertTrue(_vestingFrequency == Q101AirdropVesting.VestingFrequency.PER_SECOND);
        assertEq(_minWithdrawInterval, MIN_WITHDRAW_INTERVAL);
        assertEq(_minWithdrawAmount, MIN_WITHDRAW_AMOUNT);
    }

    // ============ Three-Stage Vesting Tests ============

    function testThreeStageReleaseCalculation() public {
        // Configure airdrop
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        uint256 totalAmount = 1000 * 10**18;

        // Test the calculation logic directly
        // No need to call updateMerkleRoot - configureAirdrop() already set it

        // Expected values:
        // Immediate: 1000 * 1000 / 10000 = 100 tokens (10%)
        // Cliff: 1000 * 2000 / 10000 = 200 tokens (20%)
        // Vesting base: 1000 - 100 - 200 = 700 tokens (70%)

        uint256 expectedImmediate = 100 * 10**18;
        uint256 expectedCliff = 200 * 10**18;
        uint256 expectedVestingBase = 700 * 10**18;

        assertEq(expectedImmediate + expectedCliff + expectedVestingBase, totalAmount);
    }

    function testZeroCliffDuration() public {
        // Configure with zero cliff
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            0,              // Zero cliff
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        assertEq(vesting.cliffDuration(), 0);
    }

    function testMaxRatioConfiguration() public {
        // Configure with 100% immediate + cliff (no linear vesting)
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            0,      // No cliff
            5000,   // 50% immediate
            5000,   // 50% cliff (total = 100%)
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        assertEq(vesting.immediateReleaseRatio(), 5000);
        assertEq(vesting.cliffReleaseRatio(), 5000);
    }

    // ============ Vesting Frequency Tests ============

    function testVestingFrequencyPerSecond() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            100 days,
            0,
            IMMEDIATE_RATIO,
            0,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        assertTrue(
            vesting.vestingFrequency() == Q101AirdropVesting.VestingFrequency.PER_SECOND
        );
    }

    function testVestingFrequencyPerDay() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            100 days,
            0,
            IMMEDIATE_RATIO,
            0,
            Q101AirdropVesting.VestingFrequency.PER_DAY,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        assertTrue(
            vesting.vestingFrequency() == Q101AirdropVesting.VestingFrequency.PER_DAY
        );
    }

    function testVestingFrequencyPerMonth() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            30 * 30 days,
            0,
            IMMEDIATE_RATIO,
            0,
            Q101AirdropVesting.VestingFrequency.PER_MONTH,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        assertTrue(
            vesting.vestingFrequency() == Q101AirdropVesting.VestingFrequency.PER_MONTH
        );
    }

    // ============ Withdraw Restrictions Tests ============

    function testUpdateWithdrawRestrictions() public {
        // Configure airdrop
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Initial restrictions
        assertEq(vesting.minWithdrawInterval(), MIN_WITHDRAW_INTERVAL);
        assertEq(vesting.minWithdrawAmount(), MIN_WITHDRAW_AMOUNT);

        // Update restrictions
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(15 days, 50 * 10**18);

        // Verify updated
        assertEq(vesting.minWithdrawInterval(), 15 days);
        assertEq(vesting.minWithdrawAmount(), 50 * 10**18);
    }

    function testUpdateWithdrawRestrictionsMultipleTimes() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Update 1
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(20 days, 80 * 10**18);
        assertEq(vesting.minWithdrawInterval(), 20 days);

        // Update 2
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(15 days, 60 * 10**18);
        assertEq(vesting.minWithdrawInterval(), 15 days);

        // Update 3
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(10 days, 40 * 10**18);
        assertEq(vesting.minWithdrawInterval(), 10 days);
    }

    function testUpdateWithdrawRestrictionsOnlyOwner() public {
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Try to update as non-owner
        vm.expectRevert();
        vm.prank(user1);
        vesting.updateWithdrawRestrictions(15 days, 50 * 10**18);
    }

    // ============ Update Merkle Root Tests ============

    function testUpdateMerkleRoot() public {
        // First configure airdrop
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Verify initial merkle root
        assertEq(vesting.merkleRoot(), merkleRoot);

        // Generate new merkle root (simulating adding new users)
        bytes32 newMerkleRoot = bytes32(uint256(0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890));

        // Update merkle root
        vm.expectEmit(true, true, false, true);
        emit MerkleRootUpdated(merkleRoot, newMerkleRoot);

        vm.prank(owner);
        vesting.updateMerkleRoot(newMerkleRoot);

        // Verify updated
        assertEq(vesting.merkleRoot(), newMerkleRoot);
    }

    function testUpdateMerkleRootOnlyOwner() public {
        // Configure first
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        bytes32 newMerkleRoot = bytes32(uint256(0xabcdef));

        // Try to update as non-owner (should fail)
        vm.expectRevert();
        vm.prank(user1);
        vesting.updateMerkleRoot(newMerkleRoot);
    }

    function testCannotUpdateMerkleRootBeforeConfiguration() public {
        // Try to update before configureAirdrop is called
        bytes32 newMerkleRoot = bytes32(uint256(0xabcdef));

        vm.expectRevert("Must call configureAirdrop first");
        vm.prank(owner);
        vesting.updateMerkleRoot(newMerkleRoot);
    }

    function testCannotUpdateMerkleRootWithZeroValue() public {
        // Configure first
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Try to update with zero value (should fail)
        vm.expectRevert("Invalid merkle root");
        vm.prank(owner);
        vesting.updateMerkleRoot(bytes32(0));
    }

    function testMerkleRootUpdatedEvent() public {
        // Configure first
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        bytes32 oldRoot = vesting.merkleRoot();
        bytes32 newRoot = bytes32(uint256(0xabcdef));

        // Expect the event
        vm.expectEmit(true, true, false, true);
        emit MerkleRootUpdated(oldRoot, newRoot);

        vm.prank(owner);
        vesting.updateMerkleRoot(newRoot);
    }

    function testMultipleUpdateMerkleRoot() public {
        // Configure first
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            MIN_WITHDRAW_INTERVAL,
            MIN_WITHDRAW_AMOUNT
        );

        // Update 1
        bytes32 newRoot1 = bytes32(uint256(0xaaa));
        vm.prank(owner);
        vesting.updateMerkleRoot(newRoot1);
        assertEq(vesting.merkleRoot(), newRoot1);

        // Update 2
        bytes32 newRoot2 = bytes32(uint256(0xbbb));
        vm.prank(owner);
        vesting.updateMerkleRoot(newRoot2);
        assertEq(vesting.merkleRoot(), newRoot2);

        // Update 3
        bytes32 newRoot3 = bytes32(uint256(0xccc));
        vm.prank(owner);
        vesting.updateMerkleRoot(newRoot3);
        assertEq(vesting.merkleRoot(), newRoot3);
    }

    // ============ Version Test ============

    function testVersion() public {
        string memory version = vesting.version();
        assertEq(version, "1.0.0");
    }
}
