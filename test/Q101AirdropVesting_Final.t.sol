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

    // ============ Edge Case: Insufficient Token Balance (Staged Deposit Model) ============

    function testWithdrawRevertWhenInsufficientContractBalance() public {
        // Test the staged token deposit model:
        // Reveal succeeds even with insufficient total balance,
        // but withdraw will fail if contract balance is insufficient

        // Deploy new vesting with only immediate release tokens
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

        // Transfer only enough for immediate release (10% of AMOUNT = 100 tokens)
        vm.prank(owner);
        token.transfer(address(vesting2), 100 * 10**18);

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

        // Reveal should succeed (this is the staged deposit feature)
        bytes32 salt = keccak256(abi.encodePacked("SALT", user1));
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting2.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);

        // Reveal succeeds - creates vesting schedule
        vm.prank(user1);
        vesting2.reveal(VOUCHER_ID, AMOUNT, salt, proof);

        // Fast forward past cliff period
        vm.warp(startTime + CLIFF_DURATION + 1);

        // Now try to withdraw - should fail due to insufficient contract balance
        // At this point, user should be able to withdraw cliff amount (20%)
        // But contract balance is 0 (immediate 10% was already withdrawn during reveal)
        // Expect ERC20 standard error (transfer will fail with insufficient balance)
        vm.expectRevert(); // Will revert with "Transfer failed" due to ERC20 transfer failure
        vm.prank(user1);
        vesting2.withdraw();

        // Admin deposits more tokens (simulating staged deposit)
        vm.prank(owner);
        token.transfer(address(vesting2), 500 * 10**18);

        // Now withdraw should succeed
        vm.prank(user1);
        vesting2.withdraw();

        // Verify withdraw succeeded
        uint256 userBalance = token.balanceOf(user1);
        // Should have immediate (100) + cliff (200) = 300 tokens
        // Use approx check to account for 1 second of linear vesting (CLIFF_DURATION + 1)
        assertApproxEqAbs(userBalance, 300 * 10**18, 1 * 10**16, "Should have ~300 tokens");
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

    // ============ Staged Token Deposit Workflow Test ============

    function testStagedTokenDepositWorkflow() public {
        // Test complete workflow of staged token deposits
        // Simulates: 36 months total, deposit in 3 stages (0, 12, 24 months)

        // Deploy new vesting contract
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

        // Month 0: Transfer first batch (enough for first 12 months)
        // Calculation: 10% immediate + 20% cliff (at month 6) + ~28% linear (6-12 months)
        // For 1000 tokens: 100 + 200 + 280 = 580 tokens
        vm.prank(owner);
        token.transfer(address(vesting2), 580 * 10**18);

        // Configure airdrop
        uint64 vestingStartTime = uint64(block.timestamp);
        vm.prank(owner);
        vesting2.configureAirdrop(
            vestingStartTime,
            merkleRoot,
            VESTING_DURATION,
            CLIFF_DURATION,
            IMMEDIATE_RATIO,
            CLIFF_RATIO,
            Q101AirdropVesting.VestingFrequency.PER_SECOND,
            30 days,
            100 * 10**18
        );

        // User reveals (creates vesting schedule)
        bytes32 salt = keccak256(abi.encodePacked("SALT_STAGED", user1));
        bytes32 commitHash = keccak256(abi.encode(VOUCHER_ID, user1, AMOUNT, salt));

        vm.prank(user1);
        vesting2.commit(commitHash);
        vm.roll(block.number + 3);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user1);
        vesting2.reveal(VOUCHER_ID, AMOUNT, salt, proof);

        // Month 0-6: User gets immediate 10% during reveal
        uint256 balance0 = token.balanceOf(user1);
        assertEq(balance0, 100 * 10**18, "Should have immediate release");

        // Month 6: After cliff, user withdraws cliff amount (20%)
        vm.warp(vestingStartTime + CLIFF_DURATION + 1);
        vm.prank(user1);
        vesting2.withdraw();

        uint256 balance6 = token.balanceOf(user1);
        // Use approx check to account for 1 second of linear vesting (CLIFF_DURATION + 1)
        assertApproxEqAbs(balance6, 300 * 10**18, 1 * 10**16, "Should have ~300 tokens at month 6");

        // Month 12: User withdraws some linear vesting
        // Fast forward 6 more months (total 12 months from start)
        vm.warp(vestingStartTime + CLIFF_DURATION + 6 * 30 days);

        vm.prank(user1);
        vesting2.withdraw();

        uint256 balance12 = token.balanceOf(user1);
        // Should have: 100 (immediate) + 200 (cliff) + ~140 (half of linear vesting)
        // Linear base = 700, 6 months out of 30 months = 700 * 6/30 = 140
        assertApproxEqAbs(balance12, 440 * 10**18, 1 * 10**18, "Should have ~440 tokens at month 12");

        // Month 13: Admin deposits second batch (for months 13-24)
        // Need: ~280 tokens for next 12 months of linear vesting
        vm.prank(owner);
        token.transfer(address(vesting2), 280 * 10**18);

        // Month 18: User continues to withdraw
        vm.warp(vestingStartTime + CLIFF_DURATION + 12 * 30 days); // Now at month 18
        vm.prank(user1);
        vesting2.withdraw();

        uint256 balance18 = token.balanceOf(user1);
        // Should have: previous + ~140 more (6 more months of linear)
        assertApproxEqAbs(balance18, 580 * 10**18, 1 * 10**18, "Should have ~580 tokens at month 18");

        // Month 24: Admin deposits final batch
        vm.prank(owner);
        token.transfer(address(vesting2), 300 * 10**18); // Rest of the tokens

        // Month 36: User withdraws everything
        vm.warp(vestingStartTime + CLIFF_DURATION + VESTING_DURATION + 1); // Now at month 36
        vm.prank(user1);
        vesting2.withdraw();

        uint256 balanceFinal = token.balanceOf(user1);
        assertEq(balanceFinal, AMOUNT, "Should have all 1000 tokens at end");

        // Verify vesting schedule is fully claimed
        (, , uint256 totalAmount, , uint256 releasedAmount, ) = vesting2.vestingSchedules(user1);
        assertEq(releasedAmount, totalAmount, "All tokens should be released");
    }
}
