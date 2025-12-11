// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101Token.sol";
import "../src/Q101AirdropVesting.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Q101Comprehensive V3.2 Test Suite
 * @notice Comprehensive tests migrated from V3.0 edge cases, branch coverage, and complete coverage tests
 * @dev Covers all remaining edge cases, boundary conditions, and branch logic not covered in other V3.2 test files
 */
contract Q101ComprehensiveV32Test is Test {
    Q101Token public token;
    Q101AirdropVesting public vesting;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public gelatoRelay = address(0x4);

    bytes32 public merkleRoot;
    uint64 public startTime;

    bytes32 constant VOUCHER_ID_1 = keccak256("VOUCHER_1");
    bytes32 constant VOUCHER_ID_2 = keccak256("VOUCHER_2");
    uint256 constant AMOUNT = 1000 * 10**18;

    uint256 constant VESTING_DURATION = 30 * 30 days;
    uint256 constant CLIFF_DURATION = 6 * 30 days;
    uint256 constant IMMEDIATE_RATIO = 1000; // 10%
    uint256 constant CLIFF_RATIO = 2000; // 20%

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
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy = new ERC1967Proxy(address(vestingImpl), vestingInitData);
        vesting = Q101AirdropVesting(address(vestingProxy));

        // Transfer tokens
        vm.prank(owner);
        token.transfer(address(vesting), 500000 * 10**18);

        // Generate merkle root
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AMOUNT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AMOUNT))));
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
            30 days,
            100 * 10**18
        );
    }

    // ============ Q101Token Edge Cases ============

    function testRevertTransferToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert();
        token.transfer(address(0), 100 * 10**18);
    }

    function testTransferZeroAmount() public {
        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(owner);
        token.transfer(user1, 0);

        assertEq(token.balanceOf(user1), balanceBefore);
    }

    function testApproveAndTransferFrom() public {
        uint256 amount = 1000 * 10**18;

        vm.prank(owner);
        token.approve(user1, amount);
        assertEq(token.allowance(owner, user1), amount);

        vm.prank(user1);
        token.transferFrom(owner, user2, amount);

        assertEq(token.balanceOf(user2), amount);
        assertEq(token.allowance(owner, user1), 0);
    }

    function testRevertTransferFromInsufficientAllowance() public {
        vm.prank(owner);
        token.approve(user1, 100 * 10**18);

        vm.expectRevert();
        vm.prank(user1);
        token.transferFrom(owner, user2, 200 * 10**18);
    }

    function testTokenVersion() public {
        string memory version = token.version();
        assertEq(version, "1.0.0"); // Token version is 1.0.0, both are 1.0.0 for initial release
    }

    // ============ Initialize Edge Cases ============

    function testRevertInitializeWithZeroToken() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);

        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(0), // Zero address
            3,
            255,
            owner
        );

        vm.expectRevert("Invalid token address");
        new ERC1967Proxy(address(vestingImpl2), initData);
    }

    function testRevertInitializeWithZeroMinRevealDelay() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);

        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            0, // Zero min reveal delay
            255,
            owner
        );

        vm.expectRevert("Invalid min reveal delay");
        new ERC1967Proxy(address(vestingImpl2), initData);
    }

    function testRevertInitializeWithInvalidMaxRevealDelay() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);

        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            100, // Min > Max
            50,
            owner
        );

        vm.expectRevert("Invalid max reveal delay");
        new ERC1967Proxy(address(vestingImpl2), initData);
    }

    function testRevertInitializeWithZeroOwner() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);

        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            address(0) // Zero owner
        );

        vm.expectRevert();
        new ERC1967Proxy(address(vestingImpl2), initData);
    }

    // ============ ConfigureAirdrop Edge Cases ============

    function testRevertConfigureAirdropWithInvalidRatios() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), initData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        vm.expectRevert("Immediate + Cliff ratio must <= 100%");
        vm.prank(owner);
        vesting2.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            6000, // 60%
            5000, // 50% - Total 110%
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );
    }

    function testRevertConfigureAirdropWithZeroMerkleRoot() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), initData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        vm.expectRevert("Invalid merkle root");
        vm.prank(owner);
        vesting2.configureAirdrop(
            startTime,
            bytes32(0), // Zero merkle root
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );
    }

    function testConfigureAirdropWithZeroImmediateRelease() public {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), initData);
        Q101AirdropVesting vesting2 = Q101AirdropVesting(address(vestingProxy2));

        vm.prank(owner);
        token.transfer(address(vesting2), 500000 * 10**18);

        vm.prank(owner);
        vesting2.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            0, // Zero immediate release
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );

        assertTrue(vesting2.isAirdropConfigured());
    }

    // ============ Pause/Unpause Tests ============

    function testRevertCommitWhenPaused() public {
        vm.prank(owner);
        vesting.pause();

        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT, "salt"));

        vm.expectRevert();
        vm.prank(user1);
        vesting.commit(commitHash);
    }

    function testRevertRevealWhenPaused() public {
        bytes32 salt = keccak256("SALT");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting.commit(commitHash);
        vm.roll(block.number + 3);

        vm.prank(owner);
        vesting.pause();

        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert();
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT, salt, proof);
    }

    function testRevertWithdrawWhenPaused() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT);

        vm.warp(startTime + CLIFF_DURATION);

        vm.prank(owner);
        vesting.pause();

        vm.expectRevert();
        vm.prank(user1);
        vesting.withdraw();
    }

    // ============ View Functions Tests ============

    function testGetReleasableAmountNoSchedule() public {
        uint256 releasable = vesting.getReleasableAmount(user1);
        assertEq(releasable, 0);
    }

    function testVestingVersion() public {
        string memory version = vesting.version();
        assertEq(version, "1.0.0");
    }

    function testIsAirdropConfigured() public {
        assertTrue(vesting.isAirdropConfigured());
    }

    function testTrustedForwarder() public {
        address forwarder = vesting.trustedForwarder();
        assertEq(forwarder, gelatoRelay);
    }

    function testIsTrustedForwarder() public {
        assertTrue(vesting.isTrustedForwarder(gelatoRelay));
        assertFalse(vesting.isTrustedForwarder(user1));
    }

    // ============ Emergency Withdraw Tests ============

    function testEmergencyWithdrawComplete() public {
        uint256 contractBalance = token.balanceOf(address(vesting));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.prank(owner);
        vesting.emergencyWithdraw(contractBalance);

        assertEq(token.balanceOf(owner), ownerBalanceBefore + contractBalance);
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function testRevertEmergencyWithdrawNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.emergencyWithdraw(1000 * 10**18);
    }

    function testEmergencyWithdrawAll() public {
        uint256 contractBalance = token.balanceOf(address(vesting));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        // Ensure contract has some balance
        assertGt(contractBalance, 0, "Contract should have balance");

        vm.prank(owner);
        vesting.emergencyWithdrawAll();

        // Verify owner received all tokens
        assertEq(token.balanceOf(owner), ownerBalanceBefore + contractBalance, "Owner should receive all tokens");
        // Verify contract balance is zero
        assertEq(token.balanceOf(address(vesting)), 0, "Contract balance should be zero");
    }

    function testEmergencyWithdrawAllWithPartialBalance() public {
        // First withdraw some tokens to create partial balance
        uint256 contractBalance = token.balanceOf(address(vesting));
        uint256 partialAmount = contractBalance / 2;

        vm.prank(owner);
        vesting.emergencyWithdraw(partialAmount);

        // Now withdraw all remaining
        uint256 remainingBalance = token.balanceOf(address(vesting));
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        assertGt(remainingBalance, 0, "Should have remaining balance");

        vm.prank(owner);
        vesting.emergencyWithdrawAll();

        assertEq(token.balanceOf(owner), ownerBalanceBefore + remainingBalance, "Owner should receive remaining tokens");
        assertEq(token.balanceOf(address(vesting)), 0, "Contract balance should be zero");
    }

    function testRevertEmergencyWithdrawAllNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        vesting.emergencyWithdrawAll();
    }

    function testRevertEmergencyWithdrawAllNoBalance() public {
        // First withdraw all tokens
        uint256 contractBalance = token.balanceOf(address(vesting));
        vm.prank(owner);
        vesting.emergencyWithdraw(contractBalance);

        // Try to withdraw all when balance is zero
        vm.expectRevert("No balance to withdraw");
        vm.prank(owner);
        vesting.emergencyWithdrawAll();
    }

    // ============ Upgrade Tests ============

    function testRevertAuthorizeUpgradeNotOwner() public {
        Q101AirdropVesting newImpl = new Q101AirdropVesting(gelatoRelay);

        vm.expectRevert();
        vm.prank(user1);
        vesting.upgradeToAndCall(address(newImpl), "");
    }

    function testUpgradeVesting() public {
        Q101AirdropVesting newImpl = new Q101AirdropVesting(gelatoRelay);

        vm.prank(owner);
        vesting.upgradeToAndCall(address(newImpl), "");

        // Contract should still work after upgrade
        assertTrue(vesting.isAirdropConfigured());
    }

    // ============ Reveal Edge Cases ============

    function testRevertRevealWithDifferentUser() public {
        bytes32 salt = keccak256("SALT");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = _generateProof(VOUCHER_ID_1, AMOUNT);

        // Different user tries to reveal
        vm.expectRevert("Reveal: No commitment found");
        vm.prank(user2);
        vesting.reveal(VOUCHER_ID_1, AMOUNT, salt, proof);
    }

    function testRevertRevealWithExistingVestingSchedule() public {
        // User1 reveals first voucher
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT);

        // User1 tries to reveal second voucher
        bytes32 salt2 = keccak256("SALT2");
        bytes32 commitHash2 = keccak256(abi.encode(VOUCHER_ID_2, user1, AMOUNT, salt2));

        vm.prank(user1);
        vesting.commit(commitHash2);
        vm.roll(block.number + 3);

        bytes32[] memory proof2 = _generateProof(VOUCHER_ID_2, AMOUNT);

        vm.expectRevert("Reveal: User already has vesting schedule");
        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_2, AMOUNT, salt2, proof2);
    }

    function testRevealAtMaximumDelay() public {
        bytes32 salt = keccak256("SALT");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting.commit(commitHash);

        // Wait exactly maxRevealDelay blocks
        vm.roll(block.number + 255);

        bytes32[] memory proof = _generateProof(VOUCHER_ID_1, AMOUNT);

        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT, salt, proof);

        // Should succeed
        (, , uint256 totalAmount, , , ) = vesting.vestingSchedules(user1);
        assertEq(totalAmount, AMOUNT);
    }

    function testRevealAtMaxRevealDelayBoundary() public {
        bytes32 salt = keccak256("SALT");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID_1, user1, AMOUNT, salt));

        uint256 commitBlock = block.number;
        vm.prank(user1);
        vesting.commit(commitHash);

        // Wait exactly maxRevealDelay blocks (boundary)
        vm.roll(commitBlock + 255);

        bytes32[] memory proof = _generateProof(VOUCHER_ID_1, AMOUNT);

        vm.prank(user1);
        vesting.reveal(VOUCHER_ID_1, AMOUNT, salt, proof);

        (, , uint256 totalAmount, , , ) = vesting.vestingSchedules(user1);
        assertEq(totalAmount, AMOUNT);
    }

    // ============ Withdraw Restrictions Tests ============

    function testWithdrawAfterVestingComplete() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT);

        // Fast forward to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        vesting.withdraw();

        uint256 balanceAfter = token.balanceOf(user1);

        // Should have received all tokens
        assertEq(balanceAfter - balanceBefore, AMOUNT - (AMOUNT * IMMEDIATE_RATIO / 10000));
    }

    function testWithdrawRestrictionsAllCombinations() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION);

        // First withdraw (cliff release)
        vm.prank(user1);
        vesting.withdraw();

        // Test 1: Time not met, amount not met -> should fail
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(30 days, 1000000 * 10**18);

        vm.expectRevert("Withdraw: Restrictions not met");
        vm.prank(user1);
        vesting.withdraw();

        // Test 2: Time met -> should succeed
        vm.warp(block.timestamp + 30 days);
        vm.prank(user1);
        vesting.withdraw();
    }

    function testLinearVestingCalculationPrecision() public {
        _commitAndReveal(user1, VOUCHER_ID_1, AMOUNT);

        // Move to halfway through vesting (after cliff)
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION / 2);

        // Withdraw cliff first
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Move to halfway
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 releasable = vesting.getReleasableAmount(user1);

        // Should be approximately 50% of vesting base
        uint256 immediateAmount = AMOUNT * IMMEDIATE_RATIO / 10000;
        uint256 cliffAmount = AMOUNT * CLIFF_RATIO / 10000;
        uint256 vestingBase = AMOUNT - immediateAmount - cliffAmount;
        uint256 expectedHalfway = vestingBase / 2;

        // Allow 1% tolerance
        assertApproxEqRel(releasable, expectedHalfway, 0.01e18);
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

    function _generateProof(bytes32 voucherId, uint256 amount) internal view returns (bytes32[] memory) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(voucherId, amount))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_1, AMOUNT))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID_2, AMOUNT))));

        bytes32[] memory proof = new bytes32[](1);
        if (leaf == leaf1) {
            proof[0] = leaf2;
        } else {
            proof[0] = leaf1;
        }

        return proof;
    }
}
