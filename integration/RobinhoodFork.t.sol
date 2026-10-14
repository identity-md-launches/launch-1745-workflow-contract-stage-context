// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {RektToken} from "../src/RektToken.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektSwapRouter} from "../src/RektSwapRouter.sol";
import {LiquidityProvider} from "../test/helpers/LiquidityProvider.sol";

contract RobinhoodForkTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant CREATOR = 0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2;

    function test_realIMDFirstBuySellAndSettle() public {
        // Invoke with profile.fork and an explicit fork; the default suite is entirely offline.
        assertEq(block.chainid, 4663);
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));
        RektToken token = new RektToken();
        LiquidityProvider factory = new LiquidityProvider(manager);
        address at = address(uint160(0x200000) | 0x20cc);
        deployCodeTo(
            "RektJackpotHook.sol:RektJackpotHook",
            abi.encode(manager, CREATOR, address(factory), IMD, address(token)),
            at
        );
        RektJackpotHook hook = RektJackpotHook(at);
        RektSwapRouter router = RektSwapRouter(hook.swapRouter());
        bool quoteFirst = IMD < address(token);
        PoolKey memory key = PoolKey(
            Currency.wrap(quoteFirst ? IMD : address(token)),
            Currency.wrap(quoteFirst ? address(token) : IMD),
            12_500,
            60,
            IHooks(at)
        );
        factory.initialize(key, 79228162514264337593543950336);
        token.transfer(address(factory), 1_000_000 ether);
        factory.modify(key, quoteFirst ? int24(-600) : int24(0), quoteFirst ? int24(0) : int24(600), 1_000_000 ether);
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
        address user = makeAddr("fork-buyer");
        deal(IMD, user, 1000 ether);
        uint256 creatorBefore = IERC20(IMD).balanceOf(CREATOR);
        vm.startPrank(user);
        IERC20(IMD).approve(address(router), 100 ether);
        router.swap(
            quoteFirst,
            -100 ether,
            1,
            quoteFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        token.approve(address(router), 10 ether);
        router.swap(
            !quoteFirst,
            -10 ether,
            1,
            quoteFirst ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
            block.timestamp
        );
        vm.stopPrank();
        assertEq(IERC20(IMD).balanceOf(CREATOR) - creatorBefore, hook.totalCreatorFeesPaid());
        uint256 pot = hook.jackpotPool();
        uint256 before = IERC20(IMD).balanceOf(user);
        uint256 burnedBefore = IERC20(IMD).balanceOf(hook.BURN_RECIPIENT());
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        assertEq(IERC20(IMD).balanceOf(user) - before, pot * 6000 / 10_000);
        assertEq(IERC20(IMD).balanceOf(hook.BURN_RECIPIENT()) - burnedBefore, pot * 2000 / 10_000);
        assertEq(manager.balanceOf(at, uint160(IMD)), hook.jackpotPool());
    }
}
