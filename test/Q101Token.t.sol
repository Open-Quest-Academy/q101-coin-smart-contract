// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Q101Token.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract Q101TokenTest is Test {
    Q101Token public tokenImplementation;
    ERC1967Proxy public proxy;
    Q101Token public token;

    address public gnosisSafe;
    address public user1;
    address public user2;

    function setUp() public {
        gnosisSafe = makeAddr("gnosisSafe");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy implementation
        tokenImplementation = new Q101Token();

        // Prepare initialization data with name and symbol
        bytes memory initData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Open-Q Education Foundation 101 Token",
            "Q101",
            gnosisSafe
        );

        // Deploy proxy
        proxy = new ERC1967Proxy(address(tokenImplementation), initData);
        token = Q101Token(address(proxy));
    }

    function test_Initialization() public view {
        assertEq(token.name(), "Open-Q Education Foundation 101 Token");
        assertEq(token.symbol(), "Q101");
        assertEq(token.totalSupply(), 1_000_000_000 * 10**18);
        assertEq(token.owner(), gnosisSafe);
        assertEq(token.balanceOf(gnosisSafe), 1_000_000_000 * 10**18);
        assertEq(token.version(), "1.0.0");
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        token.initialize("Test Token", "TEST", user1);
    }

    function test_Pause() public {
        vm.prank(gnosisSafe);
        token.pause();

        assertTrue(token.paused());
    }

    function test_RevertWhen_PauseNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        token.pause();
    }

    function test_Unpause() public {
        // First pause
        vm.prank(gnosisSafe);
        token.pause();
        assertTrue(token.paused());

        // Then unpause
        vm.prank(gnosisSafe);
        token.unpause();
        assertFalse(token.paused());
    }

    function test_RevertWhen_UnpauseNotOwner() public {
        vm.prank(gnosisSafe);
        token.pause();

        vm.prank(user1);
        vm.expectRevert();
        token.unpause();
    }

    function test_TransferWhenNotPaused() public {
        uint256 amount = 1000 * 10**18;

        vm.prank(gnosisSafe);
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_RevertWhen_TransferWhenPaused() public {
        uint256 amount = 1000 * 10**18;

        // Pause the contract
        vm.prank(gnosisSafe);
        token.pause();

        // Try to transfer
        vm.prank(gnosisSafe);
        vm.expectRevert();
        token.transfer(user1, amount);
    }

    function test_TransferAfterUnpause() public {
        uint256 amount = 1000 * 10**18;

        // Pause
        vm.prank(gnosisSafe);
        token.pause();

        // Unpause
        vm.prank(gnosisSafe);
        token.unpause();

        // Transfer should work
        vm.prank(gnosisSafe);
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_Upgrade() public {
        // Deploy new implementation
        Q101Token newImplementation = new Q101Token();

        // Upgrade (must be called by owner)
        vm.prank(gnosisSafe);
        token.upgradeToAndCall(address(newImplementation), "");

        // Verify state is preserved
        assertEq(token.totalSupply(), 1_000_000_000 * 10**18);
        assertEq(token.balanceOf(gnosisSafe), 1_000_000_000 * 10**18);
        assertEq(token.owner(), gnosisSafe);
    }

    function test_RevertWhen_UpgradeNotOwner() public {
        Q101Token newImplementation = new Q101Token();

        vm.prank(user1);
        vm.expectRevert();
        token.upgradeToAndCall(address(newImplementation), "");
    }

    function test_FullWorkflow() public {
        uint256 amount = 1000 * 10**18;

        // 1. Normal transfer
        vm.prank(gnosisSafe);
        token.transfer(user1, amount);
        assertEq(token.balanceOf(user1), amount);

        // 2. Pause
        vm.prank(gnosisSafe);
        token.pause();

        // 3. Transfer should fail
        vm.prank(user1);
        vm.expectRevert();
        token.transfer(user2, amount);

        // 4. Unpause
        vm.prank(gnosisSafe);
        token.unpause();

        // 5. Transfer should work again
        vm.prank(user1);
        token.transfer(user2, amount);
        assertEq(token.balanceOf(user2), amount);

        // 6. Upgrade
        Q101Token newImpl = new Q101Token();
        vm.prank(gnosisSafe);
        token.upgradeToAndCall(address(newImpl), "");

        // 7. Verify state preserved
        assertEq(token.balanceOf(user2), amount);
    }

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(gnosisSafe));

        vm.prank(gnosisSafe);
        token.transfer(user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_CustomNameAndSymbol() public {
        // Deploy a new token with custom name and symbol
        Q101Token customTokenImpl = new Q101Token();

        bytes memory customInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "My Custom Token",
            "MCT",
            gnosisSafe
        );

        ERC1967Proxy customProxy = new ERC1967Proxy(address(customTokenImpl), customInitData);
        Q101Token customToken = Q101Token(address(customProxy));

        // Verify custom name and symbol
        assertEq(customToken.name(), "My Custom Token");
        assertEq(customToken.symbol(), "MCT");
        assertEq(customToken.totalSupply(), 1_000_000_000 * 10**18);
        assertEq(customToken.owner(), gnosisSafe);
        assertEq(customToken.balanceOf(gnosisSafe), 1_000_000_000 * 10**18);
    }

    function test_RevertWhen_InitializeWithEmptyName() public {
        Q101Token newImpl = new Q101Token();

        bytes memory invalidInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "",  // Empty name
            "TEST",
            gnosisSafe
        );

        vm.expectRevert("Q101Token: Invalid token name");
        new ERC1967Proxy(address(newImpl), invalidInitData);
    }

    function test_RevertWhen_InitializeWithEmptySymbol() public {
        Q101Token newImpl = new Q101Token();

        bytes memory invalidInitData = abi.encodeWithSelector(
            Q101Token.initialize.selector,
            "Test Token",
            "",  // Empty symbol
            gnosisSafe
        );

        vm.expectRevert("Q101Token: Invalid token symbol");
        new ERC1967Proxy(address(newImpl), invalidInitData);
    }
}
