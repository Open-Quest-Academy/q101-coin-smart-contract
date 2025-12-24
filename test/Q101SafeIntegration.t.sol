// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101AirdropVesting.sol";
import "../src/Q101Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title MockGnosisSafe
 * @notice Simplified Gnosis Safe contract for testing multisig functionality
 */
contract MockGnosisSafe {
    address[] public owners;
    uint256 public threshold;
    uint256 public nonce;

    event ExecutionSuccess(bytes32 txHash);
    event ExecutionFailure(bytes32 txHash);

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_threshold <= _owners.length, "Invalid threshold");
        require(_threshold >= 1, "Threshold must be at least 1");
        owners = _owners;
        threshold = _threshold;
    }

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        address[] memory signers
    ) public returns (bool success) {
        require(signers.length >= threshold, "Not enough signatures");

        for (uint i = 0; i < signers.length; i++) {
            require(isOwner(signers[i]), "Invalid signer");
        }

        nonce++;
        (success, ) = to.call{value: value}(data);

        bytes32 txHash = keccak256(abi.encodePacked(to, value, data, nonce));

        if (success) {
            emit ExecutionSuccess(txHash);
        } else {
            emit ExecutionFailure(txHash);
        }
    }

    function isOwner(address owner) public view returns (bool) {
        for (uint i = 0; i < owners.length; i++) {
            if (owners[i] == owner) return true;
        }
        return false;
    }

    function getOwners() public view returns (address[] memory) {
        return owners;
    }

    function getThreshold() public view returns (uint256) {
        return threshold;
    }
}

/**
 * @title Q101SafeIntegrationV32Test
 * @notice Test Gnosis Safe integration with V3.2 Q101 contracts
 */
contract Q101SafeIntegrationV32Test is Test {
    Q101Token public token;
    Q101AirdropVesting public vesting;
    MockGnosisSafe public safe;

    address public deployer = address(0x1);
    address public owner1 = address(0x2);
    address public owner2 = address(0x3);
    address public owner3 = address(0x4);
    address public user = address(0x6);

    bytes32 public merkleRoot;
    uint64 public startTime;

    uint256 constant VESTING_DURATION = 24 * 30 days; // 24 months
    uint256 constant CLIFF_DURATION = 6 * 30 days; // 6 months
    uint256 constant IMMEDIATE_RATIO = 278; // 2.78%
    uint256 constant CLIFF_RATIO = 1000; // 10%

    function setUp() public {
        vm.startPrank(deployer);

        // 1. Create Mock Safe with 2/3 multisig
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        safe = new MockGnosisSafe(owners, 2);

        // 2. Deploy Q101Token with Safe as owner
        Q101Token tokenImpl = new Q101Token();
        bytes memory tokenInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Open-Q Education Foundation 101 Token",
            "Q101",
            address(safe)
        );
        ERC1967Proxy tokenProxy = new ERC1967Proxy(address(tokenImpl), tokenInitData);
        token = Q101Token(address(tokenProxy));

        // 3. Deploy Vesting contract (V3.2 simplified initialize)
        Q101AirdropVesting implementation = new Q101AirdropVesting(makeAddr("gelatoRelay"));

        bytes memory initData = abi.encodeWithSelector(
            Q101AirdropVesting.initialize.selector,
            address(token),
            5,                          // minRevealDelay
            255,                        // maxRevealDelay
            address(safe)               // Owner is Safe
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vesting = Q101AirdropVesting(address(proxy));

        startTime = uint64(block.timestamp + 7 days);
        merkleRoot = bytes32(uint256(1));

        vm.stopPrank();
    }

    // ============ Safe Owner Tests ============

    function testSafeIsOwner() public {
        assertEq(vesting.owner(), address(safe));
        assertEq(token.owner(), address(safe));
    }

    function testConfigureAirdropViaSafe() public {
        // Configure airdrop via Safe multisig
        bytes memory configData = abi.encodeWithSelector(
            Q101AirdropVesting.configureAirdrop.selector,
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

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bool success = safe.execTransaction(address(vesting), 0, configData, signers);
        assertTrue(success);
        assertTrue(vesting.isAirdropConfigured());
        assertEq(vesting.merkleRoot(), merkleRoot);
    }

    function testUpdateWithdrawRestrictionsViaSafe() public {
        // First configure airdrop
        _configureAirdropViaSafe();

        // Update restrictions via Safe
        bytes memory updateData = abi.encodeWithSelector(
            Q101AirdropVesting.updateWithdrawRestrictions.selector,
            15 days,
            50 * 10**18
        );

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner3;

        bool success = safe.execTransaction(address(vesting), 0, updateData, signers);
        assertTrue(success);
        assertEq(vesting.minWithdrawInterval(), 15 days);
        assertEq(vesting.minWithdrawAmount(), 50 * 10**18);
    }

    function testPauseViaSafe() public {
        _configureAirdropViaSafe();

        bytes memory pauseData = abi.encodeWithSelector(Q101AirdropVesting.pause.selector);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bool success = safe.execTransaction(address(vesting), 0, pauseData, signers);
        assertTrue(success);
        assertTrue(vesting.paused());
    }

    function testUnpauseViaSafe() public {
        _configureAirdropViaSafe();

        // Pause first
        bytes memory pauseData = abi.encodeWithSelector(Q101AirdropVesting.pause.selector);
        address[] memory signers1 = new address[](2);
        signers1[0] = owner1;
        signers1[1] = owner2;
        safe.execTransaction(address(vesting), 0, pauseData, signers1);

        // Unpause
        bytes memory unpauseData = abi.encodeWithSelector(Q101AirdropVesting.unpause.selector);
        address[] memory signers2 = new address[](2);
        signers2[0] = owner2;
        signers2[1] = owner3;

        bool success = safe.execTransaction(address(vesting), 0, unpauseData, signers2);
        assertTrue(success);
        assertFalse(vesting.paused());
    }

    function testEmergencyWithdrawViaSafe() public {
        _configureAirdropViaSafe();

        // Transfer tokens to vesting
        bytes memory transferData = abi.encodeWithSelector(
            token.transfer.selector,
            address(vesting),
            1000 * 10**18
        );
        address[] memory signers1 = new address[](2);
        signers1[0] = owner1;
        signers1[1] = owner2;
        safe.execTransaction(address(token), 0, transferData, signers1);

        uint256 amount = 500 * 10**18;
        bytes memory withdrawData = abi.encodeWithSelector(
            Q101AirdropVesting.emergencyWithdraw.selector,
            amount
        );

        address[] memory signers2 = new address[](2);
        signers2[0] = owner2;
        signers2[1] = owner3;

        uint256 safeBalanceBefore = token.balanceOf(address(safe));
        bool success = safe.execTransaction(address(vesting), 0, withdrawData, signers2);
        assertTrue(success);

        uint256 safeBalanceAfter = token.balanceOf(address(safe));
        assertEq(safeBalanceAfter - safeBalanceBefore, amount);
    }

    function testTransferTokensToVestingViaSafe() public {
        _configureAirdropViaSafe();

        uint256 amount = 10000 * 10**18;
        bytes memory transferData = abi.encodeWithSelector(
            token.transfer.selector,
            address(vesting),
            amount
        );

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner3;

        bool success = safe.execTransaction(address(token), 0, transferData, signers);
        assertTrue(success);
        assertEq(token.balanceOf(address(vesting)), amount);
    }

    function testRevertWhenInsufficientSignatures() public {
        bytes memory configData = abi.encodeWithSelector(
            Q101AirdropVesting.configureAirdrop.selector,
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

        // Only 1 signer (need 2)
        address[] memory signers = new address[](1);
        signers[0] = owner1;

        vm.expectRevert("Not enough signatures");
        safe.execTransaction(address(vesting), 0, configData, signers);
    }

    function testRevertWhenInvalidSigner() public {
        bytes memory configData = abi.encodeWithSelector(
            Q101AirdropVesting.configureAirdrop.selector,
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

        // Non-owner signer
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = address(0x999); // Not an owner

        vm.expectRevert("Invalid signer");
        safe.execTransaction(address(vesting), 0, configData, signers);
    }

    function testUpdateRevealDelayViaSafe() public {
        _configureAirdropViaSafe();

        bytes memory updateData = abi.encodeWithSelector(
            Q101AirdropVesting.updateRevealDelay.selector,
            10,
            300
        );

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bool success = safe.execTransaction(address(vesting), 0, updateData, signers);
        assertTrue(success);
        assertEq(vesting.minRevealDelay(), 10);
        assertEq(vesting.maxRevealDelay(), 300);
    }

    function testMultipleOperationsSequentially() public {
        // 1. Configure airdrop
        _configureAirdropViaSafe();

        // 2. Transfer tokens
        bytes memory transferData = abi.encodeWithSelector(
            token.transfer.selector,
            address(vesting),
            5000 * 10**18
        );
        address[] memory signers1 = new address[](2);
        signers1[0] = owner1;
        signers1[1] = owner2;
        safe.execTransaction(address(token), 0, transferData, signers1);

        // 3. Update restrictions
        bytes memory updateData = abi.encodeWithSelector(
            Q101AirdropVesting.updateWithdrawRestrictions.selector,
            20 days,
            75 * 10**18
        );
        address[] memory signers2 = new address[](2);
        signers2[0] = owner2;
        signers2[1] = owner3;
        safe.execTransaction(address(vesting), 0, updateData, signers2);

        // Verify all operations succeeded
        assertTrue(vesting.isAirdropConfigured());
        assertEq(token.balanceOf(address(vesting)), 5000 * 10**18);
        assertEq(vesting.minWithdrawInterval(), 20 days);
        assertEq(vesting.minWithdrawAmount(), 75 * 10**18);
    }

    // ============ Helper Functions ============

    function _configureAirdropViaSafe() internal {
        bytes memory configData = abi.encodeWithSelector(
            Q101AirdropVesting.configureAirdrop.selector,
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

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        safe.execTransaction(address(vesting), 0, configData, signers);
    }
}
