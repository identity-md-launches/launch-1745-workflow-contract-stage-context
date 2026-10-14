// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektSwapRouter} from "../src/RektSwapRouter.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CheckedHook} from "../src/base/CheckedHook.sol";

contract RektJackpotHookTest is HookFixture {
    using PoolIdLibrary for PoolKey;

    function test_permissionsAndInitializationAndOwner() public view {
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, FLAGS);
        assertTrue(hook.initialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.owner(), owner);
        assertEq(hook.creatorFeeRecipient(), owner);
        assertTrue(hook.owner() != address(factory));
        assertEq(hook.minimumTicket(), 1 ether);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.secondsRemaining(), 0);
        _assertConservation();
    }

    function test_exactInputBuyPaysCreatorAndStartsTenMinutes() public {
        (uint256 spent, uint256 bought) = _buy(alice, 100 ether);
        assertEq(spent, 100 ether);
        assertGt(bought, 0);
        assertEq(hook.jackpotPool(), 0.5 ether);
        assertEq(hook.totalCreatorFeesPaid(), 0.5 ether);
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(hook.currentLeader(), alice);
        assertEq(hook.roundEndTime(), block.timestamp + 600);
        assertEq(hook.secondsRemaining(), 600);
        _assertConservation();
    }

    function test_exactInputSellOnlyChargesIMDAndDoesNotTakeLead() public {
        uint256 potBefore = hook.jackpotPool();
        (uint256 spent, uint256 received) = _sell(alice, 100 ether);
        assertEq(spent, 100 ether);
        uint256 fee = hook.totalFeesCollected();
        assertEq(fee, (received + fee) / 100);
        assertEq(hook.jackpotPool() - potBefore, fee - fee / 2);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
        _assertConservation();
    }

    function test_exactOutputBuyAndSellDeliverRequestedNetOutput() public {
        (uint256 spent, uint256 received) = _trade(alice, true, 100 ether, 200 ether, _priceLimit(true));
        assertEq(received, 100 ether);
        assertEq(hook.totalFeesCollected(), spent / 100);
        uint256 feesBefore = hook.totalFeesCollected();
        (spent, received) = _trade(bob, false, 100 ether, 200 ether, _priceLimit(false));
        assertGt(spent, 100 ether);
        assertEq(received, 100 ether);
        assertEq(hook.totalFeesCollected() - feesBefore, uint256(100 ether) / 99);
        assertEq(hook.currentLeader(), alice);
        _assertConservation();
    }

    function test_allFourSwapModesWithIMDAsCurrencyOne() public {
        _deploy(false, true, true);
        _buy(alice, 100 ether);
        assertEq(hook.totalFeesCollected(), 1 ether);
        (, uint256 received) = _sell(bob, 50 ether);
        uint256 feesBefore = hook.totalFeesCollected();
        assertEq(feesBefore - 1 ether, (received + feesBefore - 1 ether) / 100);
        (uint256 spent,) = _trade(bob, true, 100 ether, 200 ether, _priceLimit(true));
        assertEq(hook.totalFeesCollected() - feesBefore, spent / 100);
        feesBefore = hook.totalFeesCollected();
        _trade(alice, false, 50 ether, 200 ether, _priceLimit(false));
        assertEq(hook.totalFeesCollected() - feesBefore, uint256(50 ether) / 99);
        assertEq(hook.currentLeader(), bob);
        _assertConservation();
    }

    function test_freshTokenOnlyPoolPaysImmediatelyWithoutNativeBalance() public {
        _deploy(true, false, true);
        // With quote as currency0, liquidity below the current price is REKTD only.
        factory.modify(key, -600, 0, int256(LIQUIDITY));
        assertEq(quote.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        _buy(alice, 10 ether);
        assertEq(quote.balanceOf(owner), 0.05 ether);
        assertEq(hook.jackpotPool(), 0.05 ether);
        _sell(alice, 1 ether);
        _assertConservation();
    }

    function test_freshTokenOnlyPoolWithIMDAsCurrencyOne() public {
        _deploy(false, false, true);
        factory.modify(key, 0, 600, int256(LIQUIDITY));
        assertEq(quote.balanceOf(address(manager)), 0);
        _trade(alice, true, 10 ether, 20 ether, _priceLimit(true));
        assertGt(quote.balanceOf(owner), 0);
        _assertConservation();
    }

    function test_minimumTicketFloorThenDynamicAndMeasuredBeforeFee() public {
        _buy(alice, 1 ether - 1);
        assertEq(hook.currentLeader(), address(0));
        _buy(alice, 1 ether);
        assertEq(hook.currentLeader(), alice);
        _buy(alice, 10_000 ether);
        uint256 ticket = hook.minimumTicket();
        assertGt(ticket, 1 ether);
        assertEq(ticket, (hook.jackpotPool() + 19) / 20);
        _buy(bob, ticket - 1);
        assertEq(hook.currentLeader(), alice);
        ticket = hook.minimumTicket();
        _buy(bob, ticket);
        assertEq(hook.currentLeader(), bob);
        assertGt(hook.minimumTicket(), ticket, "current swap fee was excluded from eligibility threshold");
        _assertConservation();
    }

    function test_extensionAddsTwoMinutesAndCapsAtTenFromNow() public {
        _buy(alice, 10 ether);
        uint256 originalEnd = hook.roundEndTime();
        _buy(bob, 10 ether);
        assertEq(hook.roundEndTime(), originalEnd);
        vm.warp(block.timestamp + 200);
        _buy(alice, 10 ether);
        assertEq(hook.roundEndTime(), originalEnd + 120);
        _buy(bob, 10 ether);
        assertEq(hook.roundEndTime(), block.timestamp + 600);
        _assertConservation();
    }

    function test_exactDeadlineBuyAllowedButSettlementRequiresFollowingSecond() public {
        _buy(alice, 10 ether);
        vm.warp(hook.roundEndTime());
        vm.expectRevert(RektJackpotHook.RoundStillActive.selector);
        hook.settleRound();
        _buy(bob, 10 ether);
        assertEq(hook.currentLeader(), bob);
        assertEq(hook.roundEndTime(), block.timestamp + 120);
        assertEq(hook.roundId(), 1);
        _assertConservation();
    }

    function test_anyoneSettlesAndRecordsHistoryWithRollover() public {
        _buy(alice, 100 ether);
        uint256 end = hook.roundEndTime();
        vm.warp(end + 1);
        uint256 beforeBalance = quote.balanceOf(alice);
        vm.prank(bob);
        hook.settleRound();
        assertEq(quote.balanceOf(alice) - beforeBalance, 0.3 ether);
        assertEq(hook.jackpotPool(), 0.1 ether);
        assertEq(hook.totalIMDBurned(), 0.1 ether);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
        assertEq(hook.roundId(), 2);
        (address winner, uint256 ended, uint256 settled, uint256 pot, uint256 prize, uint256 burned, uint256 rollover) =
            hook.roundHistory(1);
        assertEq(winner, alice);
        assertEq(ended, end);
        assertEq(settled, block.timestamp);
        assertEq(pot, 0.5 ether);
        assertEq(prize + burned + rollover, pot);
        vm.expectRevert(RektJackpotHook.NoActiveRound.selector);
        hook.settleRound();
        _buy(bob, 10 ether);
        assertEq(hook.roundEndTime(), block.timestamp + 600);
        assertEq(hook.jackpotPool(), 0.15 ether);
        _assertConservation();
    }

    function test_nextSwapSettlesOldPotBeforeChargingOrSelectingNewLeader() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        uint256 balance = quote.balanceOf(alice);
        _buy(bob, 200 ether);
        assertEq(quote.balanceOf(alice) - balance, 0.3 ether);
        assertEq(hook.jackpotPool(), 1.1 ether);
        assertEq(hook.currentLeader(), bob);
        assertEq(hook.roundId(), 2);
        _assertConservation();
    }

    function test_nextSellSettlesButDoesNotStartANewTimer() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        _sell(bob, 10 ether);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
        assertEq(hook.roundId(), 2);
        _assertConservation();
    }

    function test_noLeaderAndTooEarlySettlementRevert() public {
        vm.expectRevert(RektJackpotHook.NoActiveRound.selector);
        hook.settleRound();
        _buy(alice, 10 ether);
        vm.expectRevert(RektJackpotHook.RoundStillActive.selector);
        hook.settleRound();
        _assertConservation();
    }

    function test_factoryCanCollectLPFeesWithZeroLiquidityAndWithdraw() public {
        _buy(alice, 100 ether);
        _sell(bob, 100 ether);
        BalanceDelta collected = factory.modify(key, LOWER, UPPER, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertGt(collected.amount0(), 0);
        assertGt(collected.amount1(), 0);
        factory.modify(key, LOWER, UPPER, -int256(LIQUIDITY));
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        _assertConservation();
    }

    function test_allEnabledCallbacksAndUnlockRejectUnauthorizedCalls() public {
        SwapParams memory params = SwapParams(true, -1 ether, _priceLimit(true));
        vm.expectRevert(CheckedHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(factory), key, PRICE);
        vm.expectRevert(CheckedHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(router), key, params, abi.encode(alice));
        vm.expectRevert(CheckedHook.OnlyPoolManager.selector);
        hook.afterSwap(address(router), key, params, BalanceDelta.wrap(0), abi.encode(alice));
        vm.expectRevert(CheckedHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(RektJackpotHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
        vm.expectRevert(RektJackpotHook.OnlySwapRouter.selector);
        hook.payCreatorFee();
    }

    function test_poolInitializationCannotBeHijackedOrReused() public {
        vm.prank(address(manager));
        vm.expectRevert(RektJackpotHook.OnlyFactory.selector);
        hook.beforeInitialize(alice, key, PRICE);
        vm.prank(address(manager));
        vm.expectRevert(RektJackpotHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(factory), key, PRICE);
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        factory.initialize(other, PRICE);
    }

    function test_spoofedBuyerAndOtherPoolsRejected() public {
        SwapParams memory params = SwapParams(true, -1 ether, _priceLimit(true));
        vm.startPrank(address(manager));
        vm.expectRevert(RektJackpotHook.OnlySwapRouter.selector);
        hook.beforeSwap(bob, key, params, abi.encode(alice));
        vm.expectRevert(RektJackpotHook.InvalidBuyer.selector);
        hook.beforeSwap(address(router), key, params, "");
        vm.expectRevert(RektJackpotHook.InvalidBuyer.selector);
        hook.beforeSwap(address(router), key, params, abi.encode(address(0)));
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert(RektJackpotHook.InvalidPool.selector);
        hook.beforeSwap(address(router), other, params, abi.encode(alice));
        vm.stopPrank();
    }

    function test_routerUnsetThenConfiguredOnlyByOwnerOnlyOnce() public {
        _deploy(true, true, false);
        vm.prank(address(manager));
        vm.expectRevert(RektJackpotHook.RouterNotConfigured.selector);
        hook.beforeSwap(address(router), key, SwapParams(true, -1 ether, _priceLimit(true)), abi.encode(alice));
        vm.prank(alice);
        vm.expectRevert();
        hook.configureRouter(address(router));
        vm.startPrank(owner);
        vm.expectRevert(RektJackpotHook.InvalidRouter.selector);
        hook.configureRouter(alice);
        hook.configureRouter(address(router));
        vm.expectRevert(RektJackpotHook.RouterAlreadyConfigured.selector);
        hook.configureRouter(address(router));
        vm.stopPrank();
        _buy(alice, 10 ether);
        _assertConservation();
    }

    function test_failedWinnerOrBurnTransferRollsBackEntireSettlement() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.blockRecipient(alice);
        vm.expectRevert();
        hook.settleRound();
        assertEq(hook.roundId(), 1);
        assertEq(hook.currentLeader(), alice);
        assertEq(hook.jackpotPool(), 0.5 ether);
        _assertConservation();
        quote.blockRecipient(hook.BURN_RECIPIENT());
        uint256 balance = quote.balanceOf(alice);
        vm.expectRevert();
        hook.settleRound();
        assertEq(quote.balanceOf(alice), balance, "winner payment must roll back when burn fails");
        assertEq(hook.roundId(), 1);
        quote.blockRecipient(address(0));
        hook.settleRound();
        _assertConservation();
    }

    function test_failedCreatorPaymentRollsBackSwapAndLeadership() public {
        quote.blockRecipient(owner);
        uint256 balance = quote.balanceOf(alice);
        vm.startPrank(alice);
        quote.approve(address(router), 100 ether);
        vm.expectRevert();
        router.swap(true, -100 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(quote.balanceOf(alice), balance);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.totalFeesCollected(), 0);
        _assertConservation();
    }

    function test_reentrantSettlementCannotPayTwice() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.setReentry(address(hook), abi.encodeCall(hook.settleRound, ()));
        hook.settleRound();
        assertTrue(quote.reentryAttempted());
        assertFalse(quote.reentrySucceeded());
        assertEq(hook.totalPrizesPaid(), 0.3 ether);
        assertEq(hook.roundId(), 2);
        _assertConservation();
    }

    function testFuzz_feeAndPayoutConservation(uint256 amount) public {
        amount = bound(amount, 1 ether, 100_000 ether);
        _buy(alice, amount);
        uint256 fee = amount / 100;
        assertEq(hook.totalCreatorFeesPaid(), fee / 2);
        assertEq(hook.jackpotPool(), fee - fee / 2);
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        _assertConservation();
    }

    function testFuzz_allModesChargeOnePercentOfExecutedGrossQuote(uint128 amount, bool buy, bool exactInput) public {
        uint256 value = bound(uint256(amount), 1e12, 10_000 ether);
        int256 specified = exactInput ? -int256(value) : int256(value);
        (uint256 spent, uint256 received) = _trade(alice, buy, specified, exactInput ? 1 : value * 3, _priceLimit(buy));
        uint256 fee = hook.totalFeesCollected();
        uint256 gross = buy ? spent : received + fee;
        assertEq(fee, gross / 100);
        _assertConservation();
    }
}
