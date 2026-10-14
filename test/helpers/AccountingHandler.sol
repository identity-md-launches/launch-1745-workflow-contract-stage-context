// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RektJackpotHook} from "src/RektJackpotHook.sol";
import {RektSwapRouter} from "src/RektSwapRouter.sol";
import {RektToken} from "src/RektToken.sol";
import {MockQuote} from "./MockQuote.sol";
import {LiquidityProvider} from "./LiquidityProvider.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @dev Ledger based on router return values and actual claim/recipient balance changes.
/// No mock callbacks, direct storage writes, caught unexpected reverts, or balance top-ups.
/// IMD may refuse one recipient at a time (the stand-in's blocklist); the ledger then expects the
/// hook to park that recipient's payout and keeps it redeemable until a claim pays it out.
contract AccountingHandler is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    RektJackpotHook public immutable hook;
    RektSwapRouter public immutable router;
    RektToken public immutable token;
    MockQuote public immutable quote;
    IPoolManager public immutable manager;
    LiquidityProvider public immutable factory;
    address private immutable controller;
    address private immutable creator;
    address private immutable burnSink;
    PoolKey private key;
    address[4] public actors;
    mapping(address => uint256) public expectedQuote;
    mapping(address => uint256) public expectedToken;
    /// @dev What the hook owes each recipient after IMD refused the direct transfer.
    mapping(address => uint256) public expectedParked;
    mapping(uint256 => bytes32) public closedHistoryHash;
    uint256 public collected;
    uint256 public creatorPaid;
    uint256 public creatorDirect;
    uint256 public prizesPaid;
    uint256 public burned;
    uint256 public burnDirect;
    uint256 public closedRounds;
    uint256 public liquidity = 1_000_000 ether;
    uint256 public donatedHookQuote;
    uint256 public donatedHookToken;
    uint256 public donatedRouterQuote;
    uint256 public donatedRouterToken;
    uint256[4] public tradesByMode;
    uint256 public donations;
    uint256 public liquidityCalls;
    uint256 public rejectedCalls;
    uint256 public parkings;
    uint256 public claimsPaid;
    uint256 public blockChanges;

    struct RoundBefore {
        uint256 id;
        address leader;
        uint256 end;
        uint256 pot;
        bool expired;
    }

    constructor(
        RektJackpotHook h,
        RektSwapRouter r,
        RektToken t,
        MockQuote q,
        LiquidityProvider f,
        address[4] memory users
    ) {
        controller = msg.sender;
        hook = h;
        router = r;
        token = t;
        quote = q;
        manager = h.poolManager();
        factory = f;
        creator = h.creatorFeeRecipient();
        burnSink = h.BURN_RECIPIENT();
        key = h.poolKey();
        actors = users;
        for (uint256 i; i < users.length; ++i) {
            expectedQuote[users[i]] = q.balanceOf(users[i]);
            expectedToken[users[i]] = t.balanceOf(users[i]);
            vm.startPrank(users[i]);
            q.approve(address(r), type(uint256).max);
            t.approve(address(r), type(uint256).max);
            vm.stopPrank();
        }
    }

    function trade(uint256 actorSeed, uint256 amountSeed, bool buy, bool exactInput) public {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 10, 1_000 ether);
        // Includes dust and both sides of the ticket floor, which uniform large amounts rarely hit.
        if (amountSeed % 8 == 0) amount = 99;
        else if (amountSeed % 8 == 1) amount = 100;
        else if (amountSeed % 8 == 2) amount = 1 ether - 1;
        else if (amountSeed % 8 == 3) amount = 1 ether;
        _trade(actor, amount, buy, exactInput);
    }

    function buyNearTicket(uint256 actorSeed, uint8 side) external {
        RoundBefore memory beforeRound = _round();
        uint256 pot = beforeRound.pot;
        if (beforeRound.expired) pot -= pot * 3 / 5 + pot / 5;
        uint256 ticket = (pot + 19) / 20;
        if (ticket < 1 ether) ticket = 1 ether;
        uint256 amount = side % 3 == 0 ? ticket - 1 : side % 3 == 1 ? ticket : ticket + 1;
        _trade(actors[actorSeed % 4], amount, true, true);
    }

    function elapse(uint256 seed, uint8 mode) external {
        uint256 end = hook.roundEndTime();
        if (mode % 3 == 0 && end >= block.timestamp) vm.warp(end);
        else if (mode % 3 == 1 && end >= block.timestamp) vm.warp(end + 1);
        else vm.warp(block.timestamp + bound(seed, 0, 900));
    }

    function settle(uint256 actorSeed) public {
        RoundBefore memory beforeRound = _round();
        if (!beforeRound.expired) {
            bytes32 beforeState = fingerprint();
            vm.prank(actors[actorSeed % 4]);
            vm.expectRevert(
                beforeRound.leader == address(0)
                    ? RektJackpotHook.NoActiveRound.selector
                    : RektJackpotHook.RoundStillActive.selector
            );
            hook.settleRound();
            assertEq(fingerprint(), beforeState, "rejected settlement changed state");
            ++rejectedCalls;
        } else {
            vm.prank(actors[actorSeed % 4]);
            hook.settleRound();
            _recordSettlement(beforeRound);
            assertEq(hook.currentLeader(), address(0));
            assertEq(hook.roundEndTime(), 0);
        }
        assertManagerClosed();
    }

    /// @dev IMD refuses one recipient (an actor, the creator or the burn sink) or nobody.
    function setBlocked(uint8 who) external {
        bytes32 beforeState = fingerprint();
        address target = who % 7 == 6 ? address(0) : _recipient(who % 7);
        quote.blockRecipient(target);
        ++blockChanges;
        assertEq(fingerprint(), beforeState, "changing IMD's blocklist moved nothing by itself");
    }

    /// @dev Anyone may retry a parked payout; it pays exactly what the ledger parked, or nothing.
    function claim(uint8 who, uint256 callerSeed) external {
        address recipient = _recipient(who % 6);
        uint256 parked = expectedParked[recipient];
        assertEq(hook.unclaimedPayout(recipient), parked, "parked amount drifted from the ledger");
        bytes32 beforeState = fingerprint();
        address caller = actors[callerSeed % 4];
        if (parked == 0) {
            vm.prank(caller);
            vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
            hook.claimPayout(recipient);
        } else if (recipient == quote.blockedRecipient()) {
            vm.prank(caller);
            vm.expectPartialRevert(CustomRevert.WrappedError.selector);
            hook.claimPayout(recipient);
        } else {
            _claimSucceeds(caller, recipient, parked);
            assertManagerClosed();
            return;
        }
        ++rejectedCalls;
        assertEq(fingerprint(), beforeState, "a refused claim changed state");
        assertEq(hook.unclaimedPayout(recipient), parked);
        assertManagerClosed();
    }

    function donate(uint256 actorSeed, uint256 amountSeed, bool quoteAsset, uint8 destination) external {
        address actor = actors[actorSeed % 4];
        uint256 amount = bound(amountSeed, 0, 1 ether);
        uint256 pot = hook.jackpotPool();
        uint256 ticket = hook.minimumTicket();
        uint256 claims = _claims();
        address to = destination % 3 == 0 ? address(manager) : destination % 3 == 1 ? address(hook) : address(router);
        vm.prank(actor);
        if (quoteAsset) {
            quote.transfer(to, amount);
            expectedQuote[actor] -= amount;
            if (to == address(hook)) donatedHookQuote += amount;
            if (to == address(router)) donatedRouterQuote += amount;
        } else {
            token.transfer(to, amount);
            expectedToken[actor] -= amount;
            if (to == address(hook)) donatedHookToken += amount;
            if (to == address(router)) donatedRouterToken += amount;
        }
        ++donations;
        assertEq(hook.jackpotPool(), pot, "unsolicited tokens cannot inflate the game pot");
        assertEq(hook.minimumTicket(), ticket);
        assertEq(_claims(), claims, "raw tokens are not ERC-6909 claims");
        assertManagerClosed();
    }

    function modifyLiquidity(uint256 seed, uint8 mode) external {
        bytes32 game = _game();
        uint256 claims = _claims();
        uint256 amount = bound(seed, 1, 10_000 ether);
        int256 change;
        if (mode % 3 == 0) {
            change = int256(amount);
            liquidity += amount;
        } else if (mode % 3 == 1) {
            // Preserve enough depth for every requested exact output to fit its 4x input budget.
            // finish() separately proves the zero-liquidity redemption case after every sequence.
            amount = bound(seed, 0, liquidity > 500_000 ether ? liquidity - 500_000 ether : 0);
            change = -int256(amount);
            liquidity -= amount;
        }
        BalanceDelta delta = factory.modify(key, -60000, 60000, change);
        if (change == 0) {
            assertGe(delta.amount0(), 0, "factory fee collect cannot owe token0");
            assertGe(delta.amount1(), 0, "factory fee collect cannot owe token1");
        }
        ++liquidityCalls;
        assertEq(_game(), game, "LP operations cannot take jackpot fees or change leadership");
        assertEq(_claims(), claims);
        assertManagerClosed();
    }

    function rejectInvalidSwap(uint256 actorSeed, uint8 failure) external {
        bytes32 beforeState = fingerprint();
        vm.prank(actors[actorSeed % 4]);
        if (failure % 3 == 0) {
            vm.expectRevert(RektSwapRouter.DeadlineExpired.selector);
            router.swap(true, -1 ether, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp - 1);
        } else if (failure % 3 == 1) {
            vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
            router.swap(true, 0, 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        } else {
            vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
            router.swap(true, -1 ether, 0, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        }
        ++rejectedCalls;
        assertEq(fingerprint(), beforeState, "invalid swap mutated balances or game state");
        assertManagerClosed();
    }

    /// @dev Called only after a campaign: redemption must stay live after all LP assets leave,
    /// including every payout that was parked while its recipient was refused.
    function finish() external {
        require(msg.sender == controller, "only invariant test");
        factory.modify(key, -60000, 60000, -int256(liquidity));
        liquidity = 0;
        if (hook.currentLeader() != address(0)) {
            if (block.timestamp <= hook.roundEndTime()) vm.warp(hook.roundEndTime() + 1);
            settle(0);
        }
        quote.blockRecipient(address(0));
        for (uint256 i; i < 6; ++i) {
            address recipient = _recipient(i);
            uint256 parked = expectedParked[recipient];
            if (parked == 0) continue;
            _claimSucceeds(actors[i % 4], recipient, parked);
        }
        assertEq(hook.totalUnclaimedPayouts(), 0, "every parked payout must be redeemable with the pool empty");
        assertManagerClosed();
    }

    function assertManagerClosed() public view {
        // These execute inside the handler's transaction, before transient storage is cleared.
        assertFalse(manager.isUnlocked());
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.currencyDelta(address(factory), key.currency0), 0);
        assertEq(manager.currencyDelta(address(factory), key.currency1), 0);
    }

    function historyHash(uint256 id) public view returns (bytes32) {
        (bool ok, bytes memory result) = address(hook).staticcall(abi.encodeCall(hook.roundHistory, (id)));
        assertTrue(ok);
        return keccak256(result);
    }

    function fingerprint() public view returns (bytes32) {
        bytes32 balances;
        for (uint256 i; i < 4; ++i) {
            balances = keccak256(
                abi.encode(
                    balances, quote.balanceOf(actors[i]), token.balanceOf(actors[i]), hook.unclaimedPayout(actors[i])
                )
            );
        }
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        return keccak256(
            abi.encode(
                _game(),
                balances,
                _claims(),
                quote.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                quote.balanceOf(creator),
                quote.balanceOf(burnSink),
                hook.unclaimedPayout(creator),
                hook.unclaimedPayout(burnSink),
                price,
                tick,
                protocolFee,
                lpFee
            )
        );
    }

    function _trade(address actor, uint256 amount, bool buy, bool exactInput) private {
        RoundBefore memory beforeRound = _round();
        address blocked = quote.blockedRecipient();
        bool direction = buy == (Currency.unwrap(key.currency0) == address(quote));
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 limit = exactInput ? 1 : amount * 4;
        uint160 priceLimit = direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (actor == blocked && (!buy || !exactInput)) {
            // IMD would reach the actor as sell output or as the exact-output refund: the whole swap,
            // including any settlement it performed first, must roll back and park nothing.
            bytes32 beforeState = fingerprint();
            vm.prank(actor);
            if (buy) vm.expectRevert(abi.encodeWithSignature("Error(string)", "blocked recipient"));
            else vm.expectPartialRevert(CustomRevert.WrappedError.selector);
            router.swap(direction, specified, limit, priceLimit, block.timestamp);
            assertEq(fingerprint(), beforeState, "refused swap left a settlement or a parked payout behind");
            ++rejectedCalls;
            assertManagerClosed();
            return;
        }
        uint256 claimsBefore = _claims();
        uint256 creatorBefore = quote.balanceOf(creator) + hook.unclaimedPayout(creator);
        uint256 potForTicket = beforeRound.pot;
        if (beforeRound.expired) potForTicket -= potForTicket * 3 / 5 + potForTicket / 5;
        uint256 ticket = (potForTicket + 19) / 20;
        if (ticket < 1 ether) ticket = 1 ether;
        vm.prank(actor);
        (uint256 spent, uint256 received) = router.swap(direction, specified, limit, priceLimit, block.timestamp);
        if (buy) {
            expectedQuote[actor] -= spent;
            expectedToken[actor] += received;
        } else {
            expectedToken[actor] -= spent;
            expectedQuote[actor] += received;
        }
        uint256 disbursed;
        uint256 parkedNow;
        if (beforeRound.expired) {
            uint256 prize = beforeRound.pot * 3 / 5;
            uint256 burn = beforeRound.pot / 5;
            _recordSettlement(beforeRound);
            disbursed = prize + burn;
            if (blocked == beforeRound.leader) parkedNow += prize;
            if (blocked == burnSink) parkedNow += burn;
        }
        uint256 creatorFee = quote.balanceOf(creator) + hook.unclaimedPayout(creator) - creatorBefore;
        if (blocked == creator && creatorFee != 0) {
            expectedParked[creator] += creatorFee;
            parkedNow += creatorFee;
            ++parkings;
        } else {
            creatorDirect += creatorFee;
        }
        // Claims grow by the retained fee and by every parked payout, and shrink by what left directly.
        uint256 fee = _claims() + creatorFee + disbursed - parkedNow - claimsBefore;
        uint256 gross = buy ? spent : received + fee;
        assertLe(100 * fee, gross, "overcharged one-percent fee");
        assertLt(gross, 100 * (fee + 1), "undercharged one-percent fee");
        assertLe(200 * creatorFee, gross);
        assertLt(gross, 200 * (creatorFee + 1));
        assertEq(hook.jackpotPool(), potForTicket + fee - creatorFee);
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(hook.roundId(), beforeRound.id + (beforeRound.expired ? 1 : 0));
        if (buy && spent >= ticket) assertEq(hook.currentLeader(), actor);
        else assertEq(hook.currentLeader(), beforeRound.expired ? address(0) : beforeRound.leader);
        if (exactInput) assertEq(spent, amount, "unrestricted, sufficiently liquid trade should fill");
        else assertEq(received, amount);
        collected += fee;
        creatorPaid += creatorFee;
        ++tradesByMode[(buy ? 0 : 2) + (exactInput ? 0 : 1)];
        assertManagerClosed();
    }

    function _recordSettlement(RoundBefore memory previous) private {
        assertTrue(previous.expired, "cannot close a live round");
        uint256 prize = previous.pot * 3 / 5;
        uint256 burn = previous.pot / 5;
        (
            address winner,
            uint256 end,
            uint256 settledAt,
            uint256 pot,
            uint256 paid,
            uint256 destroyed,
            uint256 rollover
        ) = hook.roundHistory(previous.id);
        assertEq(winner, previous.leader);
        assertEq(end, previous.end);
        assertGt(settledAt, end);
        assertEq(settledAt, block.timestamp);
        assertEq(pot, previous.pot);
        assertEq(paid, prize);
        assertEq(destroyed, burn);
        assertEq(paid + destroyed + rollover, pot);
        assertEq(closedHistoryHash[previous.id], bytes32(0), "round was already paid");
        closedHistoryHash[previous.id] = historyHash(previous.id);
        _payout(previous.leader, prize);
        _payout(burnSink, burn);
        prizesPaid += prize;
        burned += burn;
        ++closedRounds;
    }

    /// @dev A payout the hook attempts now: direct when IMD allows it, parked when it refuses.
    function _payout(address to, uint256 amount) private {
        if (amount == 0) return;
        if (to == quote.blockedRecipient()) {
            expectedParked[to] += amount;
            ++parkings;
        } else {
            _creditDirect(to, amount);
        }
    }

    function _creditDirect(address to, uint256 amount) private {
        if (to == creator) creatorDirect += amount;
        else if (to == burnSink) burnDirect += amount;
        else expectedQuote[to] += amount;
    }

    function _claimSucceeds(address caller, address to, uint256 parked) private {
        uint256 before = quote.balanceOf(to);
        vm.prank(caller);
        hook.claimPayout(to);
        assertEq(quote.balanceOf(to) - before, parked, "claim paid a different amount than was parked");
        assertEq(hook.unclaimedPayout(to), 0, "claim left a balance behind");
        expectedParked[to] = 0;
        _creditDirect(to, parked);
        ++claimsPaid;
    }

    function _recipient(uint256 index) private view returns (address) {
        if (index < 4) return actors[index];
        return index == 4 ? creator : burnSink;
    }

    function _round() private view returns (RoundBefore memory result) {
        result = RoundBefore(hook.roundId(), hook.currentLeader(), hook.roundEndTime(), hook.jackpotPool(), false);
        result.expired = result.leader != address(0) && block.timestamp > result.end;
    }

    function _claims() private view returns (uint256) {
        return manager.balanceOf(address(hook), hook.quoteCurrency().toId());
    }

    function _game() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.roundId(),
                hook.currentLeader(),
                hook.roundEndTime(),
                hook.jackpotPool(),
                hook.totalFeesCollected(),
                hook.totalCreatorFeesPaid(),
                hook.totalPrizesPaid(),
                hook.totalIMDBurned(),
                hook.pendingCreatorFees(),
                hook.totalUnclaimedPayouts(),
                historyHash(hook.roundId())
            )
        );
    }
}
