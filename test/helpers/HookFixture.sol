// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {RektToken} from "../../src/RektToken.sol";
import {RektJackpotHook} from "../../src/RektJackpotHook.sol";
import {RektSwapRouter} from "../../src/RektSwapRouter.sol";
import {MockQuote} from "./MockQuote.sol";
import {LiquidityProvider} from "./LiquidityProvider.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint160 internal constant FLAGS = 0x20cc;
    uint160 internal constant PRICE = 79228162514264337593543950336;
    uint256 internal constant LIQUIDITY = 1_000_000 ether;
    int24 internal constant LOWER = -60000;
    int24 internal constant UPPER = 60000;

    IPoolManager internal manager;
    RektToken internal token;
    MockQuote internal quote;
    RektJackpotHook internal hook;
    RektSwapRouter internal router;
    LiquidityProvider internal factory;
    PoolKey internal key;
    address internal alice;
    address internal bob;
    address internal owner;
    uint160 private deploymentNumber;

    function setUp() public virtual {
        _deploy(true, true);
    }

    function _deploy(bool quoteFirst, bool seed) internal {
        ++deploymentNumber;
        vm.warp(1_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        owner = makeAddr("creator-owner");
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new RektToken();
        address quoteAddress = quoteFirst
            ? address(uint160(0x10000) + deploymentNumber)
            : address(type(uint160).max - 0x10000 - deploymentNumber);
        deployCodeTo("MockQuote.sol:MockQuote", quoteAddress);
        quote = MockQuote(quoteAddress);
        factory = new LiquidityProvider(manager);
        address hookAddress = address((uint160(0x100000) + (deploymentNumber << 14)) | FLAGS);
        deployCodeTo(
            "RektJackpotHook.sol:RektJackpotHook",
            abi.encode(manager, owner, address(factory), address(quote), address(token)),
            hookAddress
        );
        hook = RektJackpotHook(hookAddress);
        // As the factory leaves it: the hook constructor deployed and bound its router, nothing else ran.
        router = RektSwapRouter(hook.swapRouter());
        key = PoolKey({
            currency0: Currency.wrap(quoteFirst ? address(quote) : address(token)),
            currency1: Currency.wrap(quoteFirst ? address(token) : address(quote)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        factory.initialize(key, PRICE);
        quote.mint(address(factory), 10_000_000 ether);
        token.transfer(address(factory), 10_000_000 ether);
        quote.mint(alice, 10_000_000 ether);
        quote.mint(bob, 10_000_000 ether);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        if (seed) factory.modify(key, LOWER, UPPER, int256(LIQUIDITY));
    }

    function _buy(address user, uint256 amount) internal returns (uint256 spent, uint256 received) {
        return _trade(user, true, -int256(amount), 1, _priceLimit(true));
    }

    function _sell(address user, uint256 amount) internal returns (uint256 spent, uint256 received) {
        return _trade(user, false, -int256(amount), 1, _priceLimit(false));
    }

    function _trade(address user, bool buy, int256 specified, uint256 limit, uint160 priceLimit)
        internal
        returns (uint256 spent, uint256 received)
    {
        bool direction = buy == (Currency.unwrap(key.currency0) == address(quote));
        uint256 approveAmount = specified < 0 ? uint256(-specified) : limit;
        vm.startPrank(user);
        if (buy) quote.approve(address(router), approveAmount);
        else token.approve(address(router), approveAmount);
        (spent, received) = router.swap(direction, specified, limit, priceLimit, block.timestamp);
        vm.stopPrank();
    }

    function _priceLimit(bool buy) internal view returns (uint160) {
        bool direction = buy == (Currency.unwrap(key.currency0) == address(quote));
        return direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _assertConservation() internal view {
        uint256 claim = manager.balanceOf(address(hook), hook.quoteCurrency().toId());
        assertEq(claim, hook.jackpotPool() + hook.pendingCreatorFees() + hook.totalUnclaimedPayouts(), "claim backing");
        assertEq(
            hook.totalFeesCollected(),
            hook.jackpotPool() + hook.totalCreatorFeesPaid() + hook.pendingCreatorFees() + hook.totalPrizesPaid()
                + hook.totalIMDBurned(),
            "fee conservation"
        );
        assertEq(quote.balanceOf(address(hook)), 0, "hook must keep claims only");
        assertEq(quote.balanceOf(address(router)), 0, "no stranded router IMD");
        assertEq(token.balanceOf(address(router)), 0, "no stranded router REKTD");
        assertEq(
            quote.balanceOf(owner) + hook.unclaimedPayout(owner), hook.totalCreatorFeesPaid(), "creator paid or parked"
        );
        assertEq(
            quote.balanceOf(hook.BURN_RECIPIENT()) + hook.unclaimedPayout(hook.BURN_RECIPIENT()),
            hook.totalIMDBurned(),
            "burn paid or parked"
        );
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(router), key.currency0), 0);
        assertEq(manager.currencyDelta(address(router), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
