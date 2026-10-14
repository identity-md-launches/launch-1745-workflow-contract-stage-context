// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {RektSwapRouter} from "../src/RektSwapRouter.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RektSwapRouterTest is HookFixture {
    function test_deadlineAndInvalidAmountsFailBeforeSpending() public {
        vm.startPrank(alice);
        quote.approve(address(router), 100 ether);
        uint256 balance = quote.balanceOf(alice);
        vm.expectRevert(RektSwapRouter.DeadlineExpired.selector);
        router.swap(true, -100 ether, 1, _priceLimit(true), block.timestamp - 1);
        vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
        router.swap(true, 0, 1, _priceLimit(true), block.timestamp);
        vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
        router.swap(true, -100 ether, 0, _priceLimit(true), block.timestamp);
        vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
        router.swap(true, type(int256).min, 1, _priceLimit(true), block.timestamp);
        vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
        router.swap(true, type(int256).max, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(quote.balanceOf(alice), balance);
        _assertConservation();
    }

    function test_slippageAndMaxInputViolationsRevertAtomically() public {
        vm.startPrank(alice);
        quote.approve(address(router), 100 ether);
        uint256 balance = quote.balanceOf(alice);
        vm.expectRevert(RektSwapRouter.SlippageExceeded.selector);
        router.swap(true, -100 ether, 100 ether, _priceLimit(true), block.timestamp);
        vm.expectRevert(RektSwapRouter.SlippageExceeded.selector);
        router.swap(true, 100 ether, 100 ether, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(quote.balanceOf(alice), balance);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.totalFeesCollected(), 0);
        _assertConservation();
    }

    function test_exactOutputUnusedMaximumIsRefundedToPayer() public {
        uint256 beforeQuote = quote.balanceOf(alice);
        uint256 beforeToken = token.balanceOf(alice);
        (uint256 amountIn, uint256 amountOut) = _trade(alice, true, 10 ether, 100 ether, _priceLimit(true));
        assertLt(amountIn, 100 ether);
        assertEq(beforeQuote - quote.balanceOf(alice), amountIn);
        assertEq(token.balanceOf(alice) - beforeToken, amountOut);
        assertEq(amountOut, 10 ether);
        assertEq(hook.currentLeader(), alice);
        _assertConservation();
    }

    function test_revertsIfSpecifiedIMDHitsPriceLimitInsteadOfChargingUnfilledInput() public {
        vm.startPrank(alice);
        quote.approve(address(router), 10_000 ether);
        vm.expectRevert();
        router.swap(true, -10_000 ether, 1, TickMath.getSqrtPriceAtTick(-1), block.timestamp);
        vm.stopPrank();
        assertEq(hook.totalFeesCollected(), 0);
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    function test_partialExactInputSellRefundsUnspentTokensAndFeesOnlyExecutedQuote() public {
        uint256 beforeToken = token.balanceOf(alice);
        (uint256 spent, uint256 received) = _trade(alice, false, -10_000 ether, 1, TickMath.getSqrtPriceAtTick(1));
        assertLt(spent, 10_000 ether);
        assertEq(beforeToken - token.balanceOf(alice), spent);
        assertEq(hook.totalFeesCollected(), (received + hook.totalFeesCollected()) / 100);
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    function test_partialExactOutputBuyRevertsAndLeavesNoLeader() public {
        vm.startPrank(alice);
        quote.approve(address(router), 20_000 ether);
        vm.expectRevert(RektSwapRouter.SlippageExceeded.selector);
        router.swap(true, 10_000 ether, 20_000 ether, TickMath.getSqrtPriceAtTick(-1), block.timestamp);
        vm.stopPrank();
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    function test_partialExactOutputSellReverts() public {
        vm.startPrank(alice);
        token.approve(address(router), 20_000 ether);
        vm.expectRevert();
        router.swap(false, 10_000 ether, 20_000 ether, TickMath.getSqrtPriceAtTick(1), block.timestamp);
        vm.stopPrank();
        _assertConservation();
    }

    function test_emptyPoolCannotChargeOrElectLeader() public {
        _deploy(true, false, true);
        vm.startPrank(alice);
        quote.approve(address(router), 100 ether);
        vm.expectRevert();
        router.swap(true, -100 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(hook.totalFeesCollected(), 0);
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    function test_routerUnlockRequiresManagerAndAnActiveRequest() public {
        vm.expectRevert(RektSwapRouter.OnlyPoolManager.selector);
        router.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(RektSwapRouter.UnexpectedUnlock.selector);
        router.unlockCallback("");
    }

    function test_reentrantSwapCannotSpendAnotherAllowance() public {
        quote.setReentry(
            address(router), abi.encodeCall(router.swap, (true, -1 ether, 1, _priceLimit(true), block.timestamp))
        );
        _buy(alice, 100 ether);
        assertTrue(quote.reentryAttempted());
        assertFalse(quote.reentrySucceeded());
        assertEq(hook.totalFeesCollected(), 1 ether);
        assertEq(hook.currentLeader(), alice);
        _assertConservation();
    }

    function test_feeOnTransferInputIsRejectedBeforeItCanUnderfundManager() public {
        quote.setTax(true);
        vm.startPrank(alice);
        quote.approve(address(router), 100 ether);
        vm.expectRevert(RektSwapRouter.UnsupportedToken.selector);
        router.swap(true, -100 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        _assertConservation();
    }

    function test_prefundedRouterBalancesCannotBeSweptAsRefunds() public {
        quote.mint(address(router), 10 ether);
        uint256 beforeBalance = quote.balanceOf(alice);
        (uint256 spent,) = _trade(alice, true, 10 ether, 100 ether, _priceLimit(true));
        assertEq(beforeBalance - quote.balanceOf(alice), spent);
        assertEq(quote.balanceOf(address(router)), 10 ether);
    }

    function test_smartContractWalletBecomesLeaderInsteadOfTransactionOrigin() public {
        // alice may be a smart account; the immediate router caller remains the authenticated buyer.
        vm.etch(alice, hex"60006000f3");
        vm.startPrank(alice, bob);
        quote.approve(address(router), 10 ether);
        router.swap(true, -10 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(hook.currentLeader(), alice);
        _assertConservation();
    }
}
