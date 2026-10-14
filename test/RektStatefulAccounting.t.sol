// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {AccountingHandler} from "./helpers/AccountingHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract StatefulAccountingBase is HookFixture {
    AccountingHandler internal handler;
    address[4] internal actors;

    function _setupAccounting(bool quoteFirst) internal {
        _deploy(quoteFirst, true, true);
        actors = [alice, bob, makeAddr("carol"), makeAddr("dave")];
        for (uint256 i = 2; i < 4; ++i) {
            quote.mint(actors[i], 10_000_000 ether);
            token.transfer(actors[i], 10_000_000 ether);
        }
        handler = new AccountingHandler(hook, router, token, quote, factory, actors);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = AccountingHandler.trade.selector;
        selectors[1] = AccountingHandler.buyNearTicket.selector;
        selectors[2] = AccountingHandler.elapse.selector;
        selectors[3] = AccountingHandler.settle.selector;
        selectors[4] = AccountingHandler.donate.selector;
        selectors[5] = AccountingHandler.modifyLiquidity.selector;
        selectors[6] = AccountingHandler.rejectInvalidSwap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_externalBalancesAndClaimsMatchIndependentLedger() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(quote.balanceOf(actors[i]), handler.expectedQuote(actors[i]), "actor quote balance");
            assertEq(token.balanceOf(actors[i]), handler.expectedToken(actors[i]), "actor token balance");
        }
        assertEq(quote.balanceOf(owner), handler.creatorPaid());
        assertEq(quote.balanceOf(hook.BURN_RECIPIENT()), handler.burned());
        assertEq(hook.totalFeesCollected(), handler.collected());
        assertEq(hook.totalCreatorFeesPaid(), handler.creatorPaid());
        assertEq(hook.totalPrizesPaid(), handler.prizesPaid());
        assertEq(hook.totalIMDBurned(), handler.burned());
        uint256 owed = handler.collected() - handler.creatorPaid() - handler.prizesPaid() - handler.burned();
        uint256 claims = manager.balanceOf(address(hook), hook.quoteCurrency().toId());
        assertEq(claims, owed, "every retained fee remains redeemable");
        assertEq(hook.jackpotPool(), owed);
        assertGe(quote.balanceOf(address(manager)), owed, "manager has actual backing for all game liabilities");
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(quote.balanceOf(address(router)), handler.donatedRouterQuote(), "refunds cannot spend donations");
        assertEq(token.balanceOf(address(router)), handler.donatedRouterToken());
        assertEq(quote.balanceOf(address(hook)), handler.donatedHookQuote());
        assertEq(token.balanceOf(address(hook)), handler.donatedHookToken());
        assertEq(_allBalances(IERC20(address(quote))), quote.totalSupply());
        assertEq(_allBalances(IERC20(address(token))), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether, "swaps cannot mint or burn REKTD");
        handler.assertManagerClosed();
    }

    function invariant_closedHistoryNeverChangesAndCurrentRoundIsUnpaid() public view {
        assertEq(hook.roundId(), handler.closedRounds() + 1);
        for (uint256 id = 1; id < hook.roundId(); ++id) {
            assertEq(handler.historyHash(id), handler.closedHistoryHash(id), "closed result was rewritten");
        }
        (address winner, uint256 end, uint256 settledAt, uint256 pot, uint256 paid, uint256 burn, uint256 rollover) =
            hook.roundHistory(hook.roundId());
        assertEq(winner, address(0));
        assertEq(end + settledAt + pot + paid + burn + rollover, 0, "current round already has a result");
        assertLe(hook.roundEndTime(), block.timestamp + 600);
        if (hook.currentLeader() == address(0)) {
            assertEq(hook.roundEndTime(), 0);
            assertFalse(hook.canSettle());
        } else {
            bool known;
            for (uint256 i; i < actors.length; ++i) {
                known = known || hook.currentLeader() == actors[i];
            }
            assertTrue(known, "only an authenticated buyer may lead");
            assertEq(hook.canSettle(), block.timestamp > hook.roundEndTime());
        }
    }

    function afterInvariant() public {
        handler.finish();
        invariant_externalBalancesAndClaimsMatchIndependentLedger();
        invariant_closedHistoryNeverChangesAndCurrentRoundIsUnpaid();
    }

    function test_handlerExercisesEveryOperationAndUnwinds() public {
        handler.trade(0, 100 ether + 4, true, true);
        handler.trade(1, 100 ether + 4, true, false);
        handler.trade(2, 100 ether + 4, false, true);
        handler.trade(3, 100 ether + 4, false, false);
        handler.donate(0, 1 ether, true, 1);
        handler.donate(1, 1 ether, true, 2);
        handler.donate(2, 1 ether, false, 1);
        handler.donate(3, 1 ether, false, 2);
        handler.donate(0, 1 ether, true, 0);
        handler.modifyLiquidity(1 ether, 0);
        handler.modifyLiquidity(1 ether, 2);
        handler.modifyLiquidity(1 ether, 1);
        handler.rejectInvalidSwap(0, 0);
        handler.rejectInvalidSwap(1, 1);
        handler.rejectInvalidSwap(2, 2);
        handler.settle(3); // A live round must reject this.
        handler.elapse(0, 1);
        handler.settle(3);
        handler.buyNearTicket(2, 1);
        handler.elapse(0, 1);
        handler.trade(1, 100 ether + 4, false, true); // Auto-settlement on a sell.
        assertEq(handler.closedRounds(), 2);
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.tradesByMode(i), 0);
        }
        assertEq(handler.donations(), 5);
        assertEq(handler.liquidityCalls(), 3);
        assertEq(handler.rejectedCalls(), 4);
        afterInvariant();
    }

    function _allBalances(IERC20 asset) private view returns (uint256 total) {
        total = asset.balanceOf(address(this)) + asset.balanceOf(address(factory)) + asset.balanceOf(address(manager))
            + asset.balanceOf(address(router)) + asset.balanceOf(address(hook)) + asset.balanceOf(owner)
            + asset.balanceOf(hook.BURN_RECIPIENT());
        for (uint256 i; i < actors.length; ++i) {
            total += asset.balanceOf(actors[i]);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RektQuoteZeroAccountingTest is StatefulAccountingBase {
    function setUp() public override {
        _setupAccounting(true);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RektQuoteOneAccountingTest is StatefulAccountingBase {
    function setUp() public override {
        _setupAccounting(false);
    }
}
