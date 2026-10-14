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
        _deploy(false, true);
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
        _deploy(true, false);
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
        _deploy(false, false);
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
        vm.expectRevert(RektJackpotHook.OnlySelf.selector);
        hook.redeemClaim(alice, 1);
        vm.prank(address(manager));
        vm.expectRevert(RektJackpotHook.OnlySelf.selector);
        hook.redeemClaim(alice, 1);
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

    function test_routerIsBoundByTheConstructorAndCopiesAreNotAccepted() public {
        assertTrue(hook.swapRouter() != address(0));
        assertEq(hook.swapRouter(), address(router));
        assertEq(address(router.hook()), address(hook));
        assertEq(address(router.poolManager()), address(manager));
        // A bytecode-identical router that the owner did not bind is still not this pool's router.
        RektSwapRouter copy = new RektSwapRouter(manager, hook);
        assertEq(address(copy).codehash, address(router).codehash);
        vm.startPrank(alice);
        quote.approve(address(copy), 10 ether);
        vm.expectRevert();
        copy.swap(true, -10 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        vm.prank(address(copy));
        vm.expectRevert(RektJackpotHook.OnlySwapRouter.selector);
        hook.payCreatorFee();
        _buy(alice, 10 ether);
        assertEq(hook.currentLeader(), alice);
        _assertConservation();
    }

    function test_minimumTicketReflectsTheSettlementTheNextSwapPerformsFirst() public {
        for (uint256 i; i < 20; ++i) {
            _buy(alice, 10_000 ether);
        }
        assertEq(hook.jackpotPool(), 1_000 ether);
        assertEq(hook.minimumTicket(), 50 ether);
        vm.warp(hook.roundEndTime() + 1);
        assertTrue(hook.canSettle());
        // The next buy is judged against the rollover (20% of the pot), so the view says so.
        assertEq(hook.minimumTicket(), 10 ether);
        _buy(bob, 10 ether - 1);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.minimumTicket(), (hook.jackpotPool() + 19) / 20);
        _buy(bob, hook.minimumTicket());
        assertEq(hook.currentLeader(), bob);
        _assertConservation();
    }

    function test_blockedWinnerIsParkedAndTradingContinues() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.blockRecipient(alice);
        uint256 aliceBefore = quote.balanceOf(alice);
        vm.startPrank(bob);
        quote.approve(address(router), 100 ether);
        vm.expectEmit(true, false, false, true, address(hook));
        emit RektJackpotHook.PayoutParked(alice, 0.3 ether);
        (uint256 spent, uint256 received) = router.swap(true, -100 ether, 1, _priceLimit(true), block.timestamp);
        vm.stopPrank();
        assertEq(spent, 100 ether);
        assertGt(received, 0);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), bob);
        assertEq(hook.jackpotPool(), 0.6 ether);
        assertEq(hook.totalPrizesPaid(), 0.3 ether);
        assertEq(hook.totalIMDBurned(), 0.1 ether);
        assertEq(quote.balanceOf(hook.BURN_RECIPIENT()), 0.1 ether, "burn still paid directly");
        assertEq(hook.unclaimedPayout(alice), 0.3 ether);
        assertEq(hook.totalUnclaimedPayouts(), 0.3 ether);
        assertEq(quote.balanceOf(alice), aliceBefore);
        _assertConservation();
        // Still refused: the retry reverts and changes nothing.
        vm.expectRevert();
        hook.claimPayout(alice);
        assertEq(hook.unclaimedPayout(alice), 0.3 ether);
        // The blocked address can still buy (it receives REKTD) and others can sell; nothing is frozen.
        _buy(alice, 10 ether);
        assertEq(hook.currentLeader(), alice);
        _sell(bob, 1 ether);
        _assertConservation();
        // Once IMD allows it, anyone pays the parked prize out to alice, exactly once.
        quote.blockRecipient(address(0));
        aliceBefore = quote.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(hook));
        emit RektJackpotHook.PayoutClaimed(alice, 0.3 ether);
        vm.prank(bob);
        hook.claimPayout(alice);
        assertEq(quote.balanceOf(alice) - aliceBefore, 0.3 ether);
        assertEq(hook.unclaimedPayout(alice), 0);
        assertEq(hook.totalUnclaimedPayouts(), 0);
        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimPayout(alice);
        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimPayout(bob);
        _assertConservation();
    }

    function test_blockedBurnSinkIsParkedAndSettlementStillCloses() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.blockRecipient(hook.BURN_RECIPIENT());
        uint256 aliceBefore = quote.balanceOf(alice);
        hook.settleRound();
        assertEq(quote.balanceOf(alice) - aliceBefore, 0.3 ether, "winner paid directly");
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.unclaimedPayout(hook.BURN_RECIPIENT()), 0.1 ether);
        assertEq(quote.balanceOf(hook.BURN_RECIPIENT()), 0);
        _assertConservation();
        quote.blockRecipient(address(0));
        hook.claimPayout(hook.BURN_RECIPIENT());
        assertEq(quote.balanceOf(hook.BURN_RECIPIENT()), 0.1 ether);
        assertEq(hook.unclaimedPayout(hook.BURN_RECIPIENT()), 0);
        _assertConservation();
    }

    function test_blockedCreatorIsParkedAndSwapsStillSucceed() public {
        quote.blockRecipient(owner);
        (uint256 spent,) = _buy(alice, 100 ether);
        assertEq(spent, 100 ether);
        assertEq(hook.currentLeader(), alice);
        assertEq(hook.totalFeesCollected(), 1 ether);
        assertEq(hook.totalCreatorFeesPaid(), 0.5 ether);
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(hook.unclaimedPayout(owner), 0.5 ether);
        assertEq(quote.balanceOf(owner), 0);
        _assertConservation();
        _buy(bob, 100 ether);
        assertEq(hook.unclaimedPayout(owner), 1 ether);
        _assertConservation();
        quote.blockRecipient(address(0));
        hook.claimPayout(owner);
        assertEq(quote.balanceOf(owner), 1 ether);
        _buy(alice, 100 ether);
        assertEq(quote.balanceOf(owner), 1.5 ether, "direct payment resumes once allowed");
        assertEq(hook.unclaimedPayout(owner), 0);
        _assertConservation();
    }

    function test_parkedPayoutsAccumulateAcrossRoundsAndAreBackedByClaims() public {
        quote.blockRecipient(alice);
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        assertEq(hook.roundId(), 3);
        assertEq(hook.unclaimedPayout(alice), hook.totalPrizesPaid());
        assertEq(
            manager.balanceOf(address(hook), hook.quoteCurrency().toId()), hook.jackpotPool() + hook.totalPrizesPaid()
        );
        _assertConservation();
        quote.blockRecipient(address(0));
        uint256 before = quote.balanceOf(alice);
        hook.claimPayout(alice);
        assertEq(quote.balanceOf(alice) - before, hook.totalPrizesPaid());
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
