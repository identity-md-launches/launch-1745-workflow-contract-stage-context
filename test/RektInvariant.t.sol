// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektSwapRouter} from "../src/RektSwapRouter.sol";
import {RektToken} from "../src/RektToken.sol";
import {MockQuote} from "./helpers/MockQuote.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract JackpotHandler is Test {
    RektJackpotHook private immutable hook;
    RektSwapRouter private immutable router;
    RektToken private immutable token;
    MockQuote private immutable quote;
    address private immutable alice;
    address private immutable bob;

    constructor(RektJackpotHook h, RektSwapRouter r, RektToken t, MockQuote q, address a, address b) {
        hook = h;
        router = r;
        token = t;
        quote = q;
        alice = a;
        bob = b;
    }

    function trade(uint256 seed, uint96 amountSeed, bool buy, bool exactInput) external {
        address user = seed % 2 == 0 ? alice : bob;
        uint256 amount = bound(uint256(amountSeed), 0.01 ether, 200 ether);
        uint256 maximum = exactInput ? amount : amount * 3;
        uint256 beforeFees = hook.totalFeesCollected();
        uint256 beforeId = hook.roundId();
        uint256 beforeEnd = hook.roundEndTime();
        address beforeLeader = hook.currentLeader();
        uint256 beforePot = hook.jackpotPool();
        bool expires = hook.canSettle();
        if (expires) {
            // Eligibility uses rollover after the previous round is settled, before this fee is added.
            beforePot -= beforePot * 6000 / 10_000 + beforePot * 2000 / 10_000;
            beforeLeader = address(0);
        }
        uint256 ticket = (beforePot + 19) / 20;
        if (ticket < 1 ether) ticket = 1 ether;
        vm.startPrank(user);
        if (buy) quote.approve(address(router), maximum);
        else token.approve(address(router), maximum);
        (uint256 spent, uint256 received) = router.swap(
            buy,
            exactInput ? -int256(amount) : int256(amount),
            exactInput ? 1 : maximum,
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        vm.stopPrank();
        uint256 fee = hook.totalFeesCollected() - beforeFees;
        assertEq(fee, (buy ? spent : received + fee) / 100);
        assertEq(hook.roundId(), beforeId + (expires ? 1 : 0));
        if (buy && spent >= ticket) {
            assertEq(hook.currentLeader(), user);
            uint256 cap = block.timestamp + 600;
            uint256 expectedEnd = beforeLeader == address(0) ? cap : beforeEnd + 120;
            assertEq(hook.roundEndTime(), expectedEnd < cap ? expectedEnd : cap);
        } else {
            assertEq(hook.currentLeader(), beforeLeader);
        }
    }

    function elapse(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(uint256(secondsSeed), 0, 900));
    }

    function settle() external {
        if (!hook.canSettle()) return;
        uint256 pot = hook.jackpotPool();
        uint256 balance = quote.balanceOf(hook.currentLeader());
        address winner = hook.currentLeader();
        hook.settleRound();
        assertEq(quote.balanceOf(winner) - balance, pot * 6000 / 10_000);
        assertEq(hook.jackpotPool(), pot - pot * 6000 / 10_000 - pot * 2000 / 10_000);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
    }
}

contract RektInvariantTest is HookFixture {
    JackpotHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new JackpotHandler(hook, router, token, quote, alice, bob);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = JackpotHandler.trade.selector;
        selectors[1] = JackpotHandler.elapse.selector;
        selectors[2] = JackpotHandler.settle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_allFeesAccountedForAndBackedByClaims() public view {
        _assertConservation();
        assertEq(hook.pendingCreatorFees(), 0, "creator paid inside every completed swap");
    }

    function invariant_timerNeverExceedsTenMinutes() public view {
        assertLe(hook.roundEndTime(), block.timestamp + 600);
        if (hook.currentLeader() == address(0)) assertEq(hook.roundEndTime(), 0);
        else assertGt(hook.roundEndTime(), 0);
    }
}
