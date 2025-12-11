// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101AirdropVesting.sol";
import "../src/Q101Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Q101AirdropVesting V3.2 Final Coverage Tests
 * @notice Tests for remaining edge cases and branches to achieve >90% coverage
 */
contract Q101AirdropVestingV32FinalTest is Test {
    Q101Token public token;
    Q101AirdropVesting public vesting;

    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public gelatoRelay = address(0x4);

    bytes32 public merkleRoot;
    uint64 public startTime;

    bytes32 constant VOUCHER_ID = keccak256("VOUCHER_1");
    uint256 constant AMOUNT = 1000 * 10**18;

    uint256 constant VESTING_DURATION = 30 * 30 days;
    uint256 constant CLIFF_DURATION = 6 * 30 days;
    uint256 constant IMMEDIATE_RATIO = 1000;
    uint256 constant CLIFF_RATIO = 2000;

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
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(VOUCHER_ID, AMOUNT))));
        merkleRoot = leaf;
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

    // ============ getVestingInfo Tests ============

    function testGetVestingInfoBeforeVesting() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 cliffAmount,
            uint256 vestingBase,
            uint256 releasedAmount,
            uint256 releasableAmount
        ) = vesting.getVestingInfo(user1);

        assertEq(totalAmount, AMOUNT);
        assertEq(immediateAmount, AMOUNT * IMMEDIATE_RATIO / 10000);
        assertEq(cliffAmount, AMOUNT * CLIFF_RATIO / 10000);
        assertEq(vestingBase, AMOUNT - immediateAmount - cliffAmount);
        assertEq(releasedAmount, immediateAmount); // Already released
        assertEq(releasableAmount, 0); // No more releasable yet
    }

    function testGetVestingInfoDuringCliff() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move to middle of cliff period
        vm.warp(startTime + CLIFF_DURATION / 2);

        (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 cliffAmount,
            uint256 vestingBase,
            uint256 releasedAmount,
            uint256 releasableAmount
        ) = vesting.getVestingInfo(user1);

        assertEq(totalAmount, AMOUNT);
        assertEq(releasableAmount, 0); // Still in cliff period
    }

    function testGetVestingInfoAfterCliff() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION + 1);

        (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 cliffAmount,
            uint256 vestingBase,
            uint256 releasedAmount,
            uint256 releasableAmount
        ) = vesting.getVestingInfo(user1);

        assertEq(totalAmount, AMOUNT);
        assertGt(releasableAmount, 0); // Cliff amount should be releasable
    }

    function testGetVestingInfoForNonExistentUser() public {
        (
            uint256 totalAmount,
            uint256 immediateAmount,
            uint256 cliffAmount,
            uint256 vestingBase,
            uint256 releasedAmount,
            uint256 releasableAmount
        ) = vesting.getVestingInfo(user1);

        assertEq(totalAmount, 0);
        assertEq(immediateAmount, 0);
        assertEq(cliffAmount, 0);
        assertEq(vestingBase, 0);
        assertEq(releasedAmount, 0);
        assertEq(releasableAmount, 0);
    }

    // ============ getReleasableAmount Tests ============

    function testGetReleasableAmountBeforeStartTime() public {
        // Deploy with future start time
        vm.prank(owner);
        Q101AirdropVesting newVesting = _deployNewVesting(uint64(block.timestamp + 30 days));

        // Configure and reveal
        _configureNewVesting(newVesting);
        _commitAndRevealNew(newVesting, user1, VOUCHER_ID, AMOUNT);

        // Check releasable before start time
        uint256 releasable = newVesting.getReleasableAmount(user1);
        assertEq(releasable, 0); // Nothing releasable before start time
    }

    function testGetReleasableAmountAtStartTime() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // At start time, immediate amount already released
        uint256 releasable = vesting.getReleasableAmount(user1);
        assertEq(releasable, 0);
    }

    function testGetReleasableAmountDuringLinearVesting() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw(); // Withdraw cliff amount

        // Move to middle of linear vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION / 2);

        uint256 releasable = vesting.getReleasableAmount(user1);
        assertGt(releasable, 0);
    }

    function testGetReleasableAmountAfterVestingComplete() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        uint256 releasable = vesting.getReleasableAmount(user1);

        // Should equal total - already released
        (, , uint256 totalAmount, , uint256 releasedAmount, ) = vesting.vestingSchedules(user1);
        assertEq(releasable, totalAmount - releasedAmount);
    }

    // ============ Withdraw Restrictions Tests ============

    function testWithdrawWithAmountThreshold() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION);

        // Set high minimum interval, low minimum amount
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(365 days, 1 * 10**18); // Very high interval, low amount

        // Should be able to withdraw because amount > minWithdrawAmount
        vm.prank(user1);
        vesting.withdraw(); // Should succeed
    }

    function testWithdrawWithTimeThreshold() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move past cliff and withdraw
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Set low minimum interval, very high minimum amount
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(1 days, 1000000 * 10**18); // Low interval, very high amount

        // Move forward by minimum interval
        vm.warp(block.timestamp + 1 days + 1);

        // Should be able to withdraw because time interval met
        vm.prank(user1);
        vesting.withdraw(); // Should succeed
    }

    function testWithdrawAfterVestingEndNoRestrictions() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Withdraw immediate
        // Then wait for cliff and withdraw
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        vesting.withdraw();

        // Move to end of vesting
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION + 1);

        // Set very restrictive limits
        vm.prank(owner);
        vesting.updateWithdrawRestrictions(365 days, 1000000 * 10**18);

        // Should still be able to withdraw because vesting is complete
        vm.prank(user1);
        vesting.withdraw(); // Should succeed
    }

    // ============ Linear Vesting Calculation Edge Cases ============

    function testLinearVestingPerDayBoundary() public {
        // Deploy with PER_DAY frequency
        vm.prank(owner);
        Q101AirdropVesting dayVesting = _deployNewVestingWithFrequency(
            Q101AirdropVesting.VestingFrequency.PER_DAY
        );

        _configureNewVesting(dayVesting);
        _commitAndRevealNew(dayVesting, user1, VOUCHER_ID, AMOUNT);

        // Move past cliff exactly to boundary
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        dayVesting.withdraw();

        // Move exactly 1 day into vesting
        vm.warp(startTime + CLIFF_DURATION + 1 days);
        uint256 releasable = dayVesting.getReleasableAmount(user1);
        assertGt(releasable, 0);
    }

    function testLinearVestingPerMonthBoundary() public {
        // Deploy with PER_MONTH frequency
        vm.prank(owner);
        Q101AirdropVesting monthVesting = _deployNewVestingWithFrequency(
            Q101AirdropVesting.VestingFrequency.PER_MONTH
        );

        _configureNewVesting(monthVesting);
        _commitAndRevealNew(monthVesting, user1, VOUCHER_ID, AMOUNT);

        // Move past cliff
        vm.warp(startTime + CLIFF_DURATION);
        vm.prank(user1);
        monthVesting.withdraw();

        // Move exactly 30 days (1 month) into vesting
        vm.warp(startTime + CLIFF_DURATION + 30 days);
        uint256 releasable = monthVesting.getReleasableAmount(user1);
        assertGt(releasable, 0);
    }

    function testLinearVestingExactlyAtDuration() public {
        _commitAndReveal(user1, VOUCHER_ID, AMOUNT);

        // Move to exactly cliff + duration
        vm.warp(startTime + CLIFF_DURATION + VESTING_DURATION);

        uint256 releasable = vesting.getReleasableAmount(user1);

        // Should release all remaining tokens
        (, , uint256 totalAmount, , uint256 releasedAmount, ) = vesting.vestingSchedules(user1);
        assertEq(releasable, totalAmount - releasedAmount);
    }

    // ============ Edge Case: Insufficient Token Balance ============

    function testRevealRevertWhenInsufficientTokens() public {
        // Deploy new vesting with insufficient tokens
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

        // Transfer only small amount
        vm.prank(owner);
        token.transfer(address(vesting2), 100 * 10**18); // Less than AMOUNT

        // Configure
        vm.prank(owner);
        vesting2.configureAirdrop(
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

        // Try to reveal with amount > balance
        bytes32 salt = keccak256(abi.encodePacked("SALT", user1));
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting2.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert("Contract: Insufficient tokens");
        vm.prank(user1);
        vesting2.reveal(VOUCHER_ID, AMOUNT, salt, proof);
    }

    // ============ Edge Case: Wrong Committer ============

    function testRevealRevertWhenWrongCommitter() public {
        bytes32 salt = keccak256("SALT");
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID, user1, AMOUNT, salt));

        // user1 commits
        vm.prank(user1);
        vesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);

        // Different user tries to reveal - will reconstruct different hash and get "No commitment found"
        // This is expected behavior - the commitment hash includes the user address
        vm.expectRevert("Reveal: No commitment found");
        vm.prank(address(0x999));
        vesting.reveal(VOUCHER_ID, AMOUNT, salt, proof);
    }

    // ============ Helper Functions ============

    function _commitAndReveal(address user, bytes32 voucherId, uint256 amount) internal {
        bytes32 salt = keccak256(abi.encodePacked("SALT", user));
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        vm.prank(user);
        vesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        vesting.reveal(voucherId, amount, salt, proof);
    }

    function _commitAndRevealNew(
        Q101AirdropVesting newVesting,
        address user,
        bytes32 voucherId,
        uint256 amount
    ) internal {
        bytes32 salt = keccak256(abi.encodePacked("SALT", user));
        bytes32 commitHash = keccak256(abi.encode(voucherId, user, amount, salt));

        vm.prank(user);
        newVesting.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        newVesting.reveal(voucherId, amount, salt, proof);
    }

    function _deployNewVesting(uint64 _startTime) internal returns (Q101AirdropVesting) {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), vestingInitData);
        Q101AirdropVesting newVesting = Q101AirdropVesting(address(vestingProxy2));

        vm.prank(owner);
        token.transfer(address(newVesting), 500000 * 10**18);

        vm.prank(owner);
        newVesting.configureAirdrop(
            _startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );

        return newVesting;
    }

    function _deployNewVestingWithFrequency(
        Q101AirdropVesting.VestingFrequency frequency
    ) internal returns (Q101AirdropVesting) {
        Q101AirdropVesting vestingImpl2 = new Q101AirdropVesting(gelatoRelay);
        bytes memory vestingInitData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            3,
            255,
            owner
        );
        ERC1967Proxy vestingProxy2 = new ERC1967Proxy(address(vestingImpl2), vestingInitData);
        Q101AirdropVesting newVesting = Q101AirdropVesting(address(vestingProxy2));

        vm.prank(owner);
        token.transfer(address(newVesting), 500000 * 10**18);

        vm.prank(owner);
        newVesting.configureAirdrop(
            startTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            frequency,
            30 days,
            100 * 10**18
        );

        return newVesting;
    }

    function _configureNewVesting(Q101AirdropVesting newVesting) internal {
        // Already configured in deploy function
    }
}
