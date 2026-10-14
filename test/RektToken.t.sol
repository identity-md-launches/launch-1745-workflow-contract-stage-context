// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RektToken} from "../src/RektToken.sol";

contract RektTokenTest is Test {
    RektToken token;

    function setUp() public {
        token = new RektToken();
    }

    function test_metadataAndFixedSupplyToDeployer() public view {
        assertEq(token.name(), "REKTD");
        assertEq(token.symbol(), "REKTD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transfersConserveSupply(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        address recipient = makeAddr("recipient");
        token.transfer(recipient, amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceIsRequiredAndSpent() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1 ether));
        token.transferFrom(address(this), recipient, 1 ether);
        token.approve(spender, 2 ether);
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1 ether);
        assertEq(token.allowance(address(this), spender), 1 ether);
        assertEq(token.balanceOf(recipient), 1 ether);
    }

    function test_transferFailuresAndNoMintOrAdminSurface() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert();
        token.transfer(makeAddr("recipient"), 1e27 + 1);
        string[6] memory methods = [
            "mint(address,uint256)",
            "setMinter(address)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < methods.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(methods[i], address(this), 1 ether));
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
