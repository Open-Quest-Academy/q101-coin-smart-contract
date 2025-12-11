// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101AirdropVesting.sol";
import "../src/Q101Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Q101AirdropVesting V3.2 Extended Test Suite
 * @notice Extended tests for commit-reveal, withdraw, pause, and edge cases
 */
contract Q101AirdropVestingV32ExtendedTest is Test {
    Q101Token public token;
    Q101AirdropVesting public vesting;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public gelatoRelay = address(0x4);

    bytes32 public merkleRoot;
    uint64 public startTime;

    // Test vouchers
    bytes32 constant VOUCHER_ID_1 = keccak256("VOUCHER_1");
    bytes32 constant VOUCHER_ID_2 = keccak256("VOUCHER_2");
    uint256 constant AMOUNT_1 = 1000 * 10**18;
    uint256 constant AMOUNT_2 = 2000 * 10**18;

    // Test configuration
    uint256 constant VESTING_DURATION = 30 * 30 days; // 30 months
    uint256 constant CLIFF_DURATION = 6 * 30 days;    // 6 months
    uint256 constant IMMEDIATE_RATIO = 1000;           // 10%
    uint256 constant CLIFF_RATIO = 2000;               // 20%
    uint256 constant MIN_WITHDRAW_INTERVAL = 30 days;
    uint256 constant MIN_WITHDRAW_AMOUNT = 100 * 10**18;

    function setUp() public {
        // Deploy token
        Q101Token tokenImpl = new Q101Token();
        bytes memory tokenInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Q101 Token",
            "Q101",
            owner
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = Q101Token(address(tokenProxy));

        // Deploy vesting
        Q101AirdropVesting vestingImpl = new Q101AirdropVesting(gelatoRelay);
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

        // Generate merkle root
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AMOUNT_1))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AMOUNT_2))));
        merkleRoot = leaf1 < leaf2
            ? keccak256(abi.encodePacked(leaf1, leaf2))
            : keccak256(abi.encodePacked(leaf2, leaf1));

        startTime = uint64(block.timestamp);

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
    }

    // ============ Commit Tests ============

    function testCommit() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        vm.expectEmit(true, true, false, false);
        emit Q101AirdropVesting.Committed(user1, commitHash);

        vm.prank(user1);
        vesting.commit(commitHash);

        // Verify commitment stored
        (address committer, uint256 blockNumber, bool revealed) = vesting.commitments(commitHash);
        assertEq(committer, user1);
        assertEq(blockNumber, block.number);
        assertFalse(revealed);
    }

    function testCommitRevertWhenPaused() public {
        // Pause contract
        vm.prank(owner);
        vesting.pause();

        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        vm.expectRevert();
        vm.prank(user1);
        vesting.commit(commitHash);
    }

    function testCommitRevertWhenMerkleRootNotSet() public {
        // Deploy new vesting without configuring
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

        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        vm.expectRevert("Airdrop not started: merkle root not set");
        vm.prank(user1);
        vesting2.commit(commitHash);
    }

    function testCommitRevertWhenAlreadyCommitted() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        vm.prank(user1);
        vesting.commit(commitHash);

        vm.expectRevert("Commit: Already committed");
        vm.prank(user1);
        vesting.commit(commitHash);
    }

    // ============ Reveal Tests ============

    function testRevealSuccess() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        // Commit
        vm.prank(user1);
        vesting.commit(commitHash);

        // Wait for reveal delay
        vm.roll(4);  // Advance 3 blocks from initial block 1

        // Generate merkle proof
        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);

        // Reveal
        vm.expectEmit(true, true, false, false);
        emit Q101AirdropVesting.Revealed(user1, VOUCHER_ID_1, AMOUNT_1);

        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);

        // Verify vesting schedule created
        (
            uint64 scheduleStartTime,
            uint64 duration,
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 releasedAmount,
        ) = vesting.vestingSchedules(user1);

        assertEq(scheduleStartTime, startTime);
        assertEq(duration, uint64(VESTING_DURATION));
        assertEq(totalAmount, AMOUNT_1);
        assertEq(immediateAmount, AMOUNT_1 * IMMEDIATE_RATIO / 10000);
        assertEq(releasedAmount, immediateAmount); // Immediate amount released

        // Verify voucher claimed
        assertTrue(vesting.claimedVouchers(VOUCHER_ID_1));
    }

    function testRevealRevertWhenNoCommitment() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);

        vm.expectRevert("Reveal: No commitment found");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);
    }

    function testRevealRevertWhenAlreadyRevealed() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        // Commit
        vm.prank(user1);
        vesting.commit(commitHash);

        // Wait and reveal
        vm.roll(4);  // Advance 3 blocks from initial block 1
        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);

        // Try to reveal again
        vm.expectRevert("Reveal: Already revealed");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);
    }

    function testRevealRevertWhenTooEarly() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        // Commit
        vm.prank(user1);
        vesting.commit(commitHash);

        // Try to reveal immediately (too early)
        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);

        vm.expectRevert("Reveal: Too early");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);
    }

    function testRevealRevertWhenTooLate() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        // Commit
        vm.prank(user1);
        vesting.commit(commitHash);

        // Wait too long (> maxRevealDelay)
        vm.roll(block.number + 300);

        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);

        vm.expectRevert("Reveal: Too late");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);
    }

    function testRevealRevertWhenVoucherAlreadyClaimed() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        // First user commits and reveals
        vm.prank(user1);
        vesting.commit(commitHash);
        vm.roll(4);  // Advance 3 blocks from initial block 1
        bytes32[] memory proof = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, proof);

        // Second user tries to use same voucher
        vm.roll(5);  // Advance to block 5 for second commit
        bytes32 salt2 = keccak256("SALT_2");
        bytes32 commitHash2 = keccak256(abi.encode(VOUCHER_ID_1, user2, AMOUNT_1, salt2));
        vm.prank(user2);
        vesting.commit(commitHash2);
        vm.roll(8);  // Advance 3 more blocks from block 5

        vm.expectRevert("Reveal: Voucher already claimed");
        vm.prank(user2);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt2, proof);
    }

    function testRevealRevertWhenUserHasVestingSchedule() public {
        // User1 claims first voucher
        bytes32 salt1 = keccak256("SALT_1");
        bytes32 commitHash1 = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt1));
        vm.prank(user1);
        vesting.commit(commitHash1);
        vm.roll(4);  // Advance 3 blocks from initial block 1
        bytes32[] memory proof1 = _generateMerkleProof(VOUCHER_ID_1, AMOUNT_1);
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt1, proof1);

        // User1 tries to claim second voucher
        vm.roll(5);  // Advance to block 5 for second commit
        bytes32 salt2 = keccak256("SALT_2");
        bytes32 commitHash2 = keccak256(abi.encode(VOUCHER_ID_2, user1, AMOUNT_2, salt2));
        vm.prank(user1);
        vesting.commit(commitHash2);
        vm.roll(8);  // Advance 3 more blocks from block 5
        bytes32[] memory proof2 = _generateMerkleProof(VOUCHER_ID_2, AMOUNT_2);

        vm.expectRevert("Reveal: User already has vesting schedule");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_2, AMOUNT_2, salt2, proof2);
    }

    function testRevealRevertWhenInvalidMerkleProof() public {
        bytes32 salt = keccak256("SALT_1");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT_1, salt));

        vm.prank(user1);
        vesting.commit(commitHash);
        vm.roll(4);  // Advance 3 blocks from initial block 1

        // Invalid proof
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(uint256(0x1234));

        vm.expectRevert("Reveal: Invalid Merkle proof");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT_1, salt, invalidProof);
    }

    // ============ Withdraw Tests ============

    function testWithdrawSuccess() public {
        // Setup: User reveals and gets vesting schedule
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT_1);

        // Fast forward past cliff
        vm.warp(startTime + CLIFF_DURATION + 30 days);

        uint256 releasableBefore = vesting.getReleasableAmount(user1);
        assertGt(releasableBefore, 0);

        uint256 balanceBefore = token.balanceOf(user1);

        vm.expectEmit(true, false, false, false);
        emit Q101AirdropVesting.Withdrawn(user1, releasableBefore, startTime + CLIFF_DURATION + 30 days);

        vm.prank(user1);
        vesting.withdraw();

        uint256 balanceAfter = token.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, releasableBefore);
    }

    function testWithdrawRevertWhenNoVestingSchedule() public {
        vm.expectRevert("Withdraw: No vesting schedule");
        vm.prank(user1);
        vesting.withdraw();
    }

    function testWithdrawRevertWhenNoTokensAvailable() public {
        // Setup: User reveals
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT_1);

        // Immediate amount already released, no more available yet
        vm.expectRevert("Withdraw: No tokens available");
        vm.prank(user1);
        vesting.withdraw();
    }

    function testWithdrawRevertWhenRestrictionsNotMet() public {
        // Setup: User reveals
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT_1);

        // Fast forward past cliff
        vm.warp(startTime + CLIFF_DURATION);

        // First withdrawal (cliff release)
        vm.prank(user1);
        vesting.withdraw();

        // Try to withdraw again immediately (restrictions not met)
        vm.warp(block.timestamp + 1 days); // Less than 30 days interval

        vm.expectRevert("Withdraw: Restrictions not met");
        vm.prank(user1);
        vesting.withdraw();
    }

    function testWithdrawAfterVestingComplete() public {
        // Setup: User reveals
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT_1);

        // Fast forward to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        // Should be able to withdraw all remaining tokens
        uint256 releasable = vesting.getReleasableAmount(user1);
        assertGt(releasable, 0);

        vm.prank(user1);
        vesting.withdraw();

        // All tokens should be released
        (, , uint256 totalAmount, , uint256 releasedAmount, ) = vesting.vestingSchedules(user1);
        assertEq(totalAmount, releasedAmount);
    }

    // ============ Pause/Unpause Tests ============

    function testPause() public {
        vm.prank(owner);
        vesting.pause();

        assertTrue(vesting.paused());
    }

    function testPauseRevertWhenNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.pause();
    }

    function testUnpause() public {
        vm.prank(owner);
        vesting.pause();

        vm.prank(owner);
        vesting.unpause();

        assertFalse(vesting.paused());
    }

    function testUnpauseRevertWhenNotOwner() public {
        vm.prank(owner);
        vesting.pause();

        vm.expectRevert();
        vm.prank(user1);
        vesting.unpause();
    }

    // ============ Emergency Withdraw Tests ============

    function testEmergencyWithdraw() public {
        uint256 contractBalance = token.balanceOf(address(vesting));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.expectEmit(true, false, false, false);
        emit Q101AirdropVesting.EmergencyWithdrawn(owner, contractBalance);

        vm.prank(owner);
        vesting.emergencyWithdraw(contractBalance);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + contractBalance);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testEmergencyWithdrawRevertWhenNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.emergencyWithdraw(1000);
    }

    // ============ Update Reveal Delay Tests ============

    function testUpdateRevealDelay() public {
        vm.expectEmit(false, false, false, true);
        emit Q101AirdropVesting.RevealDelayUpdated(5, 300);

        vm.prank(owner);
        vesting.updateRevealDelay(5, 300);

        assertEq(vesting.minRevealDelay(), 5);
        assertEq(vesting.maxRevealDelay(), 300);
    }

    function testUpdateRevealDelayRevertWhenNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.updateRevealDelay(5, 300);
    }

    function testUpdateRevealDelayRevertWhenInvalidMin() public {
        vm.expectRevert("Invalid min reveal delay");
        vm.prank(owner);
        vesting.updateRevealDelay(0, 300);
    }

    function testUpdateRevealDelayRevertWhenInvalidMax() public {
        vm.expectRevert("Invalid max reveal delay");
        vm.prank(owner);
        vesting.updateRevealDelay(300, 100);
    }

    // ============ Helper Functions ============

    function _commitAndReveal(address user, bytes32 voucherId, uint256 amount) internal {
        bytes32 salt = keccak256(abi.encodePacked("SALT", user, voucherId));
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        vm.prank(user);
        vesting.commit(commitHash);

        vm.roll(4);  // Advance 3 blocks from initial block 1

        bytes32[] memory proof = _generateMerkleProof(voucherId, amount);
        vm.prank(user);
        vesting.reveal(voucherId, amount, salt, proof);
    }

    function _generateMerkleProof(bytes32 voucherId, uint256 amount) internal view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AMOUNT_1))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AMOUNT_2))));

        bytes32[] memory proof = new bytes32[](1);
        if (leaf == leaf1) {
            proof[0] = leaf2;
        } else {
            proof[0] = leaf1;
        }

        return proof;
    }

    // ============ Events (for testing) ============
    // These would normally be imported from the contract, but defining here for clarity
    event Committed(address indexed user, bytes32 indexed commitHash);
    event Revealed(address indexed user, bytes32 indexed voucherId, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 lastWithdrawTime);
    event EmergencyWithdrawn(address indexed owner, uint256 amount);
    event RevealDelayUpdated(uint256 minDelay, uint256 maxDelay);
}
