// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101Token.sol";
import "../src/Q101AirdropVesting.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title VerifyVestingLogicV32Test
 * @notice Comprehensive test to verify V3.2 three-stage vesting logic
 */
contract VerifyVestingLogicV32Test is Test {
    Q101Token public token;
    Q101AirdropVesting public vesting;

    address public owner;
    address public user1;
    address public user2;
    address public gelatoRelay;

    bytes32 public merkleRoot;
    uint64 public startTime;

    uint256 constant AIRDROP_AMOUNT = 1_000_000 * 10**18; // 1M tokens
    bytes32 constant VOUCHER_ID_1 = keccak256("VOUCHER_1");
    bytes32 constant VOUCHER_ID_2 = keccak256("VOUCHER_2");

    // V3.2 Configuration
    uint256 constant VESTING_DURATION = 36 * 30 days; // 36 months
    uint256 constant CLIFF_DURATION = 6 * 30 days; // 6 months
    uint256 constant IMMEDIATE_RATIO = 1000; // 10%
    uint256 constant CLIFF_RATIO = 2000; // 20%

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        gelatoRelay = makeAddr("gelatoRelay");

        // Deploy token
        Q101Token tokenImpl = new Q101Token();
        bytes memory tokenInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Open-Q Education Foundation 101 Token",
            "Q101",
            owner
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = Q101Token(address(tokenProxy));

        // Deploy vesting (V3.2 simplified initialize)
        Q101AirdropVesting vestingImpl = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy = new ERC1967Proxy(address(vestingImpl), vestingInitData);
        vesting = Q101AirdropVesting(address(vestingProxy));

        // Setup merkle tree
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AIRDROP_AMOUNT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AIRDROP_AMOUNT))));
        merkleRoot = leaf1 < leaf2
            ? keccak256(abi.encodePacked(leaf1, leaf2))
            : keccak256(abi.encodePacked(leaf2, leaf1));

        startTime = uint64(block.timestamp);

        // Configure airdrop (V3.2)
        vm.prank(owner);
        vesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );

        // Transfer tokens to vesting
        vm.prank(owner);
        token.transfer(address(vesting), 10_000_000 * 10**18);

        // Warp to start time
        vm.warp(startTime);
    }

    // ============ Three-Stage Vesting Verification ============

    function testThreeStageVestingCalculation() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Stage 1: Immediate (10% = 100,000 tokens)
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;
        assertEq(expectedImmediate, 100_000 * 10**18);

        // Stage 2: Cliff (20% = 200,000 tokens)
        uint256 expectedCliff = (AIRDROP_AMOUNT * CLIFF_RATIO) / 10000;
        assertEq(expectedCliff, 200_000 * 10**18);

        // Stage 3: Linear vesting (70% = 700,000 tokens)
        uint256 expectedVesting = AIRDROP_AMOUNT - expectedImmediate - expectedCliff;
        assertEq(expectedVesting, 700_000 * 10**18);

        // Verify using getVestingInfo
        (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 cliffAmount,
            uint256 vestingBase,
            uint256 releasedAmount,
        ) = vesting.getVestingInfo(user1);

        assertEq(totalAmount, AIRDROP_AMOUNT);
        assertEq(immediateAmount, expectedImmediate);
        assertEq(cliffAmount, expectedCliff);
        assertEq(vestingBase, expectedVesting);
        assertEq(releasedAmount, expectedImmediate); // Immediate already released
    }

    function testImmediateReleaseAtReveal() public {
        uint256 userBalanceBefore = token.balanceOf(user1);

        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        uint256 userBalanceAfter = token.balanceOf(user1);
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;

        assertEq(userBalanceAfter - userBalanceBefore, expectedImmediate);
    }

    function testNoVestingDuringCliffPeriod() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move to middle of cliff period
        vm.warp(startTime + CLIFF_DURATION / 2);

        uint256 releasable = vesting.getReleasableAmount(user1);
        assertEq(releasable, 0, "No vesting during cliff");
    }

    function testCliffReleaseAtCliffEnd() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move to exactly cliff end
        vm.warp(startTime + CLIFF_DURATION);

        uint256 releasable = vesting.getReleasableAmount(user1);
        uint256 expectedCliff = (AIRDROP_AMOUNT * CLIFF_RATIO) / 10000;

        assertEq(releasable, expectedCliff);
    }

    function testLinearVestingAfterCliff() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Withdraw cliff release
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Move to halfway through linear vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 releasable = vesting.getReleasableAmount(user1);
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;
        uint256 expectedCliff = (AIRDROP_AMOUNT * CLIFF_RATIO) / 10000;
        uint256 vestingBase = AIRDROP_AMOUNT - expectedImmediate - expectedCliff;

        // Halfway through vesting = 50% of vesting base
        uint256 expectedHalfVested = vestingBase / 2;

        // Allow 1% tolerance for rounding
        assertApproxEqRel(releasable, expectedHalfVested, 0.01e18);
    }

    function testFullVestingScheduleCompletion() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        uint256 releasable = vesting.getReleasableAmount(user1);
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;

        // Should equal total - immediate (already released)
        assertEq(releasable, AIRDROP_AMOUNT - expectedImmediate);

        // Withdraw all
        vm.prank(user1);
        vesting.withdraw();

        // Check total received
        assertEq(token.balanceOf(user1), AIRDROP_AMOUNT);
    }

    // ============ Multiple User Scenarios ============

    function testTwoUsersIndependentVesting() public {
        // Both users reveal
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);
        _commitAndReveal(user2, VOUCHER_ID_2, AIRDROP_AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION + 30 days);

        uint256 releasable1 = vesting.getReleasableAmount(user1);
        uint256 releasable2 = vesting.getReleasableAmount(user2);

        // Both should have same releasable amount
        assertEq(releasable1, releasable2);

        // User1 withdraws
        vm.prank(user1);
        vesting.withdraw();

        // User2's releasable should not change
        assertEq(vesting.getReleasableAmount(user2), releasable2);
    }

    // ============ Vesting Frequency Tests ============

    function testPerDayVestingFrequency() public {
        // Deploy new vesting with PER_DAY frequency
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), vestingInitData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        vm.prank(owner);
        vesting2.configureAirdrop(
            startTime,
            merkleRoot,
            100 days, // Short duration for testing
            0, // No cliff
            IMMEDIATE_RATIO,
            0, // No cliff release
            Q101AirdropVesting.VestingFrequency.PER_DAY,
            1 days,
            1 * 10**18
        );

        vm.prank(owner);
        token.transfer(address(vesting2), 10_000_000 * 10**18);

        _commitAndRevealCustom(vesting2, user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move 50.5 days into vesting
        vm.warp(startTime + 50 days + 12 hours);

        uint256 releasable = vesting2.getReleasableAmount(user1);
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;
        uint256 vestingBase = AIRDROP_AMOUNT - expectedImmediate;

        // PER_DAY should only count 50 complete days (not 50.5)
        uint256 expected = (vestingBase * 50) / 100;
        assertEq(releasable, expected);
    }

    function testPerMonthVestingFrequency() public {
        // Deploy new vesting with PER_MONTH frequency
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), vestingInitData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        vm.prank(owner);
        vesting2.configureAirdrop(
            startTime,
            merkleRoot,
            30 * 30 days, // 30 months
            0, // No cliff
            IMMEDIATE_RATIO,
            0,
            Q101AirdropVesting.VestingFrequency.PER_MONTH,
            1 days,
            1 * 10**18
        );

        vm.prank(owner);
        token.transfer(address(vesting2), 10_000_000 * 10**18);

        _commitAndRevealCustom(vesting2, user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move 15.5 months into vesting
        vm.warp(startTime + 15 * 30 days + 15 days);

        uint256 releasable = vesting2.getReleasableAmount(user1);
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;
        uint256 vestingBase = AIRDROP_AMOUNT - expectedImmediate;

        // PER_MONTH should only count 15 complete months (not 15.5)
        uint256 expected = (vestingBase * 15) / 30;
        assertEq(releasable, expected);
    }

    // ============ Withdrawal Restrictions Tests ============

    function testWithdrawRestrictionsByTime() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move past cliff and withdraw
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Set very high minimum amount to force time-based restriction
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(30 days, 1000000 * 10**18);

        // Try to withdraw again after 15 days (< 30 days required)
        // Amount will be < 1M tokens, so time restriction applies
        vm.warp(block.timestamp + 15 days);

        // Should fail - not enough time passed AND amount < threshold
        vm.expectRevert("Withdraw: Restrictions not met");
        vm.prank(user1);
        vesting.withdraw();

        // Move to 31 days - now time interval met
        vm.warp(block.timestamp + 16 days);
        vm.prank(user1);
        vesting.withdraw(); // Should succeed due to time interval
    }

    function testWithdrawRestrictionsByAmount() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move past cliff and withdraw
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Update restrictions: high time interval, low amount
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(365 days, 1 * 10**18);

        // Move just 1 day (way less than 365 days)
        vm.warp(block.timestamp + 1 days + 1);

        // But releasable amount > 1 token, so should succeed
        uint256 releasable = vesting.getReleasableAmount(user1);
        if (releasable >= 1 * 10**18) {
            vm.prank(user1);
            vesting.withdraw(); // Should succeed due to amount threshold
        }
    }

    function testNoRestrictionsAfterVestingComplete() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // Move to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        // Withdraw all
        vm.prank(user1);
        vesting.withdraw();

        // Should have no more tokens to withdraw
        assertEq(vesting.getReleasableAmount(user1), 0);
    }

    // ============ Edge Cases ============

    function testVestingBeforeStartTime() public {
        // Deploy new vesting with future start time
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), vestingInitData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        uint64 futureStart = uint64(block.timestamp + 30 days);

        vm.prank(owner);
        vesting2.configureAirdrop(
            futureStart,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );

        vm.prank(owner);
        token.transfer(address(vesting2), 10_000_000 * 10**18);

        // Reveal NOW (before start time)
        _commitAndRevealCustom(vesting2, user1, VOUCHER_ID_1, AIRDROP_AMOUNT);

        // User gets immediate release even before start time
        uint256 expectedImmediate = (AIRDROP_AMOUNT * IMMEDIATE_RATIO) / 10000;
        assertEq(token.balanceOf(user1), expectedImmediate);

        // But no more vesting until start time
        assertEq(vesting2.getReleasableAmount(user1), 0);

        // After start time, vesting begins
        vm.warp(futureStart + 1);
        assertEq(vesting2.getReleasableAmount(user1), 0); // Still in cliff

        vm.warp(futureStart + CLIFF_DURATION);
        assertGt(vesting2.getReleasableAmount(user1), 0); // Cliff release available
    }

    // ============ Helper Functions ============

    function _commitAndReveal(address user, bytes32 voucherId, uint256 amount) internal {
        bytes32 salt = keccak256(abi.encodePacked("SALT", user, voucherId));
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        vm.prank(user);
        vesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = _generateProof(voucherId, amount);
        vm.prank(user);
        vesting.reveal(voucherId, amount, salt, proof);
    }

    function _commitAndRevealCustom(
        Q101AirdropVesting customVesting,
        address user,
        bytes32 voucherId,
        uint256 amount
    ) internal {
        bytes32 salt = keccak256(abi.encodePacked("SALT", user, voucherId));
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        vm.prank(user);
        customVesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = _generateProof(voucherId, amount);
        vm.prank(user);
        customVesting.reveal(voucherId, amount, salt, proof);
    }

    function _generateProof(bytes32 voucherId, uint256 amount) internal view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AIRDROP_AMOUNT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AIRDROP_AMOUNT))));

        bytes32[] memory proof = new bytes32[](1);
        if (leaf == leaf1) {
            proof[0] = leaf2;
        } else {
            proof[0] = leaf1;
        }

        return proof;
    }
}
