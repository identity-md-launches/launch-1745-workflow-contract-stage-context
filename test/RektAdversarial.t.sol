// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {RektJackpotHook} from "src/RektJackpotHook.sol";
import {RektSwapRouter} from "src/RektSwapRouter.sol";
import {CheckedHook} from "src/base/CheckedHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Keeps calls inside one transaction, including reuse of both unlock callbacks.
contract RoundTripWallet {
    function settleThenRoundTrip(RektJackpotHook hook, RektSwapRouter router, IERC20 quote, IERC20 token, uint256 input)
        external
        returns (uint256 spent, uint256 recovered)
    {
        hook.settleRound();
        return this.roundTrip(router, quote, token, input);
    }

    function roundTrip(RektSwapRouter router, IERC20 quote, IERC20 token, uint256 input)
        external
        returns (uint256 spent, uint256 recovered)
    {
        quote.approve(address(router), input);
        uint256 bought;
        (spent, bought) = router.swap(true, -int256(input), 1, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        token.approve(address(router), bought);
        (, recovered) = router.swap(false, -int256(bought), 1, TickMath.MAX_SQRT_PRICE - 1, block.timestamp);
    }
}

contract RektAdversarialTest is HookFixture {
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_constructorRejectsInvalidDependenciesBeforePermissionValidation() public {
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(IPoolManager(address(0)), owner, address(factory), address(quote), address(token));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RektJackpotHook(manager, address(0), address(factory), address(quote), address(token));
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(manager, owner, address(0), address(quote), address(token));
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(manager, owner, address(factory), address(0), address(token));
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(manager, owner, address(factory), address(quote), address(0));
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(manager, owner, address(factory), address(token), address(token));
        address burn = hook.BURN_RECIPIENT();
        vm.expectRevert(CheckedHook.InvalidAddress.selector);
        new RektJackpotHook(manager, burn, address(factory), address(quote), address(token));
        vm.expectRevert(RektSwapRouter.InvalidAddress.selector);
        new RektSwapRouter(IPoolManager(address(0)), hook);
        vm.expectRevert(RektSwapRouter.InvalidAddress.selector);
        new RektSwapRouter(manager, RektJackpotHook(address(0)));
    }

    function test_failedPoolInitializationDoesNotPermanentlyBindHook() public {
        RektJackpotHook fresh = _freshHook();
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(fresh));
        // beforeInitialize runs before Pool.initialize rejects this price: all hook writes must roll back.
        vm.expectRevert();
        factory.initialize(candidate, 0);
        assertFalse(fresh.initialized());
        vm.expectRevert(RektJackpotHook.NotInitialized.selector);
        fresh.poolKey();
        factory.initialize(candidate, PRICE);
        assertTrue(fresh.initialized());
        assertEq(address(fresh.poolKey().hooks), address(fresh));
    }

    function test_uninitializedCallbacksAndRouterCannotMoveFunds() public {
        RektJackpotHook fresh = _freshHook();
        SwapParams memory params = SwapParams(true, -1 ether, _priceLimit(true));
        vm.startPrank(address(manager));
        vm.expectRevert(RektJackpotHook.NotInitialized.selector);
        fresh.beforeSwap(address(router), key, params, abi.encode(alice));
        vm.expectRevert(RektJackpotHook.NotInitialized.selector);
        fresh.afterSwap(address(router), key, params, BalanceDelta.wrap(0), abi.encode(alice));
        vm.stopPrank();
        RektSwapRouter freshRouter = new RektSwapRouter(manager, fresh);
        uint256 balance = quote.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(RektJackpotHook.NotInitialized.selector);
        freshRouter.swap(true, -1 ether, 1, _priceLimit(true), block.timestamp);
        assertEq(quote.balanceOf(alice), balance);
    }

    function test_disabledCallbacksRejectBothOutsidersAndManager() public {
        ModifyLiquidityParams memory change = ModifyLiquidityParams(-60, 60, 0, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(IHooks.afterInitialize, (alice, key, PRICE, 0));
        calls[1] = abi.encodeCall(IHooks.beforeAddLiquidity, (alice, key, change, ""));
        calls[2] = abi.encodeCall(IHooks.afterAddLiquidity, (alice, key, change, zero, zero, ""));
        calls[3] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (alice, key, change, ""));
        calls[4] = abi.encodeCall(IHooks.afterRemoveLiquidity, (alice, key, change, zero, zero, ""));
        calls[5] = abi.encodeCall(IHooks.beforeDonate, (alice, key, 1, 1, ""));
        calls[6] = abi.encodeCall(IHooks.afterDonate, (alice, key, 1, 1, ""));
        for (uint256 i; i < calls.length; ++i) {
            _refused(address(this), calls[i], CheckedHook.OnlyPoolManager.selector);
            _refused(address(manager), calls[i], CheckedHook.HookNotImplemented.selector);
        }
        _assertConservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_malformedBuyerDataRejectedByBothSwapCallbacks(uint256 lengthSeed) public {
        uint256 length = bound(lengthSeed, 0, 95);
        if (length >= 32) ++length;
        bytes memory data = new bytes(length);
        SwapParams memory params = SwapParams(true, -1 ether, _priceLimit(true));
        _refused(
            address(manager),
            abi.encodeCall(hook.beforeSwap, (address(router), key, params, data)),
            RektJackpotHook.InvalidBuyer.selector
        );
        _refused(
            address(manager),
            abi.encodeCall(hook.afterSwap, (address(router), key, params, BalanceDelta.wrap(0), data)),
            RektJackpotHook.InvalidBuyer.selector
        );
    }

    function test_zeroBurnAndNonCanonicalBuyersCannotEnterRound() public {
        SwapParams memory params = SwapParams(true, -1 ether, _priceLimit(true));
        address[2] memory invalid = [address(0), hook.BURN_RECIPIENT()];
        for (uint256 i; i < invalid.length; ++i) {
            bytes memory data = abi.encode(invalid[i]);
            _refused(
                address(manager),
                abi.encodeCall(hook.beforeSwap, (address(router), key, params, data)),
                RektJackpotHook.InvalidBuyer.selector
            );
            _refused(
                address(manager),
                abi.encodeCall(hook.afterSwap, (address(router), key, params, BalanceDelta.wrap(0), data)),
                RektJackpotHook.InvalidBuyer.selector
            );
        }
        vm.prank(address(manager));
        (bool accepted,) = address(hook)
            .call(abi.encodeCall(hook.beforeSwap, (address(router), key, params, abi.encode(type(uint256).max))));
        assertFalse(accepted, "dirty high address bits must not authenticate a buyer");
        _assertConservation();
    }

    function test_swapAmountBoundariesAndFeeCannotConsumeEntireSpecifiedInput() public {
        int256 maximum = int256(type(int128).max);
        int256[5] memory invalid = [int256(0), maximum + 1, -maximum - 1, type(int256).min, type(int256).max];
        vm.startPrank(address(manager));
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(RektJackpotHook.InvalidSwapAmount.selector);
            hook.beforeSwap(
                address(router), key, SwapParams(true, invalid[i], TickMath.MIN_SQRT_PRICE + 1), abi.encode(alice)
            );
        }
        // Exact-output IMD must fit together with its hook fee in the manager's int128 delta.
        vm.expectRevert(RektJackpotHook.InvalidSwapAmount.selector);
        hook.beforeSwap(
            address(router), key, SwapParams(false, maximum, TickMath.MAX_SQRT_PRICE - 1), abi.encode(alice)
        );
        (, BeforeSwapDelta delta, uint24 feeOverride) = hook.beforeSwap(
            address(router), key, SwapParams(true, -maximum, TickMath.MIN_SQRT_PRICE + 1), abi.encode(alice)
        );
        vm.stopPrank();
        assertGt(delta.getSpecifiedDelta(), 0);
        assertLt(delta.getSpecifiedDelta(), maximum, "hook cannot absorb the entire AMM input");
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(feeOverride, 0, "the launch LP fee must not be overridden");
        _assertConservation();
    }

    function test_maximumRouterLimitAndMismatchedManagerFailBeforeTransfer() public {
        vm.expectRevert(RektSwapRouter.InvalidAmount.selector);
        router.swap(true, 1, uint256(uint128(type(int128).max)) + 1, _priceLimit(true), block.timestamp);
        RektSwapRouter wrong = new RektSwapRouter(IPoolManager(address(factory)), hook);
        vm.prank(alice);
        vm.expectRevert(RektSwapRouter.WrongHookManager.selector);
        wrong.swap(true, -1 ether, 1, _priceLimit(true), block.timestamp);
        _assertConservation();
    }

    function test_expiredRoundSettlementRollsBackWhenNewSwapFailsSlippage() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        vm.prank(bob);
        quote.approve(address(router), 200 ether);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(RektSwapRouter.SlippageExceeded.selector);
        router.swap(true, -200 ether, 200 ether, _priceLimit(true), block.timestamp);
        assertEq(_snapshot(), beforeState, "failed swap must also undo the old round payout and burn");
        assertTrue(hook.canSettle());
        _buy(bob, 200 ether);
        assertEq(hook.roundId(), 2);
        assertEq(hook.totalPrizesPaid(), 0.3 ether);
        assertEq(hook.currentLeader(), bob);
        _assertConservation();
    }

    function test_failedRefundRollsBackAlreadySettledRoundAndCreatorPayment() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.blockRecipient(bob);
        vm.prank(bob);
        quote.approve(address(router), 200 ether);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "blocked recipient"));
        router.swap(true, 10 ether, 200 ether, _priceLimit(true), block.timestamp);
        assertEq(_snapshot(), beforeState, "refund is part of the swap's atomicity boundary");
        quote.blockRecipient(address(0));
        _trade(bob, true, 10 ether, 200 ether, _priceLimit(true));
        assertEq(hook.roundId(), 2);
        _assertConservation();
    }

    function test_failedSellOutputRollsBackCreatorPaymentAndExpiredRound() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        quote.blockRecipient(bob);
        vm.prank(bob);
        token.approve(address(router), 100 ether);
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert(); // PoolManager wraps ERC-20 transfer failure.
        router.swap(false, -100 ether, 1, _priceLimit(false), block.timestamp);
        assertEq(_snapshot(), beforeState);
        quote.blockRecipient(address(0));
        _sell(bob, 100 ether);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    function test_dustFeeBoundariesAccumulateWithoutElectingLeader() public {
        uint256[5] memory inputs = [uint256(98), 99, 100, 199, 200];
        uint256 fees;
        uint256 creator;
        for (uint256 i; i < inputs.length; ++i) {
            (uint256 spent, uint256 received) = _buy(alice, inputs[i]);
            assertEq(spent, inputs[i]);
            assertGt(received, 0);
            fees += inputs[i] / 100;
            creator += inputs[i] / 200;
            assertEq(hook.totalFeesCollected(), fees);
            assertEq(quote.balanceOf(owner), creator);
            assertEq(hook.jackpotPool(), fees - creator);
        }
        assertEq(fees, 4);
        assertEq(creator, 1);
        assertEq(hook.currentLeader(), address(0));
        vm.expectRevert(RektJackpotHook.NoActiveRound.selector);
        hook.settleRound();
        _assertConservation();
    }

    function test_oneWeiExactOutputTradesCannotCreateFreeValueOrLeadership() public {
        (uint256 spent, uint256 received) = _trade(alice, true, 1, 100, _priceLimit(true));
        assertGt(spent, 0);
        assertEq(received, 1);
        (spent, received) = _trade(bob, false, 1, 100, _priceLimit(false));
        assertGt(spent, 0);
        assertEq(received, 1);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.totalFeesCollected(), 0);
        _assertConservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_smallExecutedAmountsRespectFeeRounding(uint256 seed, bool buy, bool exactInput) public {
        uint256 amount = bound(seed, 10, 10_000);
        (uint256 spent, uint256 received) = _trade(
            alice, buy, exactInput ? -int256(amount) : int256(amount), exactInput ? 1 : amount * 4, _priceLimit(buy)
        );
        uint256 fee = hook.totalFeesCollected();
        uint256 gross = buy ? spent : received + fee;
        // Inequalities express rounding without duplicating the hook's /99 inverse calculation.
        assertLe(fee * 100, gross);
        assertLt(gross, (fee + 1) * 100);
        assertLe(quote.balanceOf(owner) * 200, gross);
        assertLt(gross, (quote.balanceOf(owner) + 1) * 200);
        assertEq(hook.currentLeader(), address(0));
        _assertConservation();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_buyThenSellCannotProfitBeforeRoundExpires(uint256 seed) public {
        uint256 amount = bound(seed, 1 ether, 50_000 ether);
        uint256 quoteBefore = quote.balanceOf(alice);
        uint256 tokenBefore = token.balanceOf(alice);
        (, uint256 bought) = _buy(alice, amount);
        _sell(alice, bought);
        assertLt(quote.balanceOf(alice), quoteBefore, "round trip must pay AMM and hook fees");
        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(hook.roundId(), 1);
        _assertConservation();
    }

    function test_twoSwapsInOneTransactionResetUnlockGuardsAndAuthenticateWallet() public {
        RoundTripWallet wallet = new RoundTripWallet();
        quote.mint(address(wallet), 100 ether);
        (uint256 spent, uint256 recovered) = wallet.roundTrip(router, quote, token, 100 ether);
        assertEq(spent, 100 ether);
        assertGt(recovered, 0);
        assertLt(recovered, spent);
        assertEq(token.balanceOf(address(wallet)), 0);
        assertEq(quote.balanceOf(address(wallet)), recovered);
        assertEq(hook.currentLeader(), address(wallet));
        _assertConservation();
    }

    function test_settleAndTradeInOneTransactionCanRedeemBothRoundsClaims() public {
        _buy(alice, 100 ether);
        vm.warp(hook.roundEndTime() + 1);
        RoundTripWallet wallet = new RoundTripWallet();
        quote.mint(address(wallet), 100 ether);
        uint256 winnerBalance = quote.balanceOf(alice);
        wallet.settleThenRoundTrip(hook, router, quote, token, 100 ether);
        assertEq(quote.balanceOf(alice) - winnerBalance, 0.3 ether);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), address(wallet));
        _assertConservation();
    }

    function _freshHook() private returns (RektJackpotHook fresh) {
        address at = address(uint160(0x800000) | FLAGS);
        deployCodeTo(
            "RektJackpotHook.sol:RektJackpotHook",
            abi.encode(manager, owner, address(factory), address(quote), address(token)),
            at
        );
        fresh = RektJackpotHook(at);
    }

    function _refused(address caller, bytes memory data, bytes4 expected) private {
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(hook).call(data);
        assertFalse(ok, "unauthorized or invalid callback succeeded");
        assertEq(reason, abi.encodeWithSelector(expected));
    }

    function _snapshot() private view returns (bytes32) {
        bytes32 game = keccak256(
            abi.encode(
                hook.jackpotPool(),
                hook.currentLeader(),
                hook.roundEndTime(),
                hook.roundId(),
                hook.totalFeesCollected(),
                hook.totalCreatorFeesPaid(),
                hook.totalPrizesPaid(),
                hook.totalIMDBurned(),
                hook.pendingCreatorFees()
            )
        );
        (bool ok, bytes memory history) = address(hook).staticcall(abi.encodeCall(hook.roundHistory, (1)));
        assertTrue(ok);
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        bytes32 balances = keccak256(
            abi.encode(
                quote.balanceOf(alice),
                quote.balanceOf(bob),
                quote.balanceOf(owner),
                quote.balanceOf(hook.BURN_RECIPIENT()),
                quote.balanceOf(address(manager)),
                token.balanceOf(address(manager)),
                quote.balanceOf(address(router)),
                token.balanceOf(address(router)),
                token.balanceOf(alice),
                token.balanceOf(bob),
                manager.balanceOf(address(hook), hook.quoteCurrency().toId()),
                quote.allowance(bob, address(router)),
                token.allowance(bob, address(router))
            )
        );
        return keccak256(abi.encode(game, history, balances, price, tick, protocolFee, lpFee));
    }
}
