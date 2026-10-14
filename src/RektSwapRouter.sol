// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {RektJackpotHook} from "./RektJackpotHook.sol";

/// @notice Single-pool router: input payer, output recipient and jackpot entrant are always msg.sender.
contract RektSwapRouter is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error OnlyPoolManager();
    error UnexpectedUnlock();
    error DeadlineExpired();
    error InvalidAmount();
    error SlippageExceeded();
    error ExactOutputNotFilled();
    error UnsupportedToken();
    error WrongHookManager();

    IPoolManager public immutable poolManager;
    RektJackpotHook public immutable hook;
    bool private unlocking;

    struct Request {
        address buyer;
        PoolKey key;
        SwapParams params;
        uint256 maximumInput;
        uint256 minimumOutput;
    }

    event SwapExecuted(address indexed buyer, bool zeroForOne, int256 specified, uint256 amountIn, uint256 amountOut);

    constructor(IPoolManager manager, RektJackpotHook jackpotHook) {
        if (address(manager) == address(0) || address(jackpotHook) == address(0)) revert InvalidAddress();
        poolManager = manager;
        hook = jackpotHook;
    }

    /// @param amountSpecified Negative = exact input, positive = exact output, including the hook fee.
    /// @param limit Minimum output for exact input, maximum input for exact output (both must be nonzero).
    /// @param sqrtPriceLimitX96 Explicit AMM price limit in the swap direction.
    function swap(bool zeroForOne, int256 amountSpecified, uint256 limit, uint160 sqrtPriceLimitX96, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (
            amountSpecified == 0 || amountSpecified < -int256(type(int128).max)
                || amountSpecified > int256(type(int128).max) || limit == 0
                || limit > uint256(uint128(type(int128).max))
        ) revert InvalidAmount();
        if (address(hook.poolManager()) != address(poolManager)) revert WrongHookManager();
        bool exactInput = amountSpecified < 0;
        uint256 maximumInput = exactInput ? uint256(-amountSpecified) : limit;
        uint256 minimumOutput = exactInput ? limit : uint256(amountSpecified);
        PoolKey memory key = hook.poolKey();
        IERC20 input = IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1));
        uint256 previousBalance = input.balanceOf(address(this));
        // Never pull from a payer decoded from callback data. Only the entry-point caller authorizes spending.
        input.safeTransferFrom(msg.sender, address(this), maximumInput);
        if (input.balanceOf(address(this)) - previousBalance != maximumInput) revert UnsupportedToken();
        unlocking = true;
        bytes memory result = poolManager.unlock(
            abi.encode(
                Request(
                    msg.sender,
                    key,
                    SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96),
                    maximumInput,
                    minimumOutput
                )
            )
        );
        if (unlocking) revert UnexpectedUnlock();
        (amountIn, amountOut) = abi.decode(result, (uint256, uint256));
        if (maximumInput > amountIn) input.safeTransfer(msg.sender, maximumInput - amountIn);
        emit SwapExecuted(msg.sender, zeroForOne, amountSpecified, amountIn, amountOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!unlocking) revert UnexpectedUnlock();
        unlocking = false;
        Request memory request = abi.decode(data, (Request));
        BalanceDelta delta = poolManager.swap(request.key, request.params, abi.encode(request.buyer));
        int128 inputDelta = request.params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = request.params.zeroForOne ? delta.amount1() : delta.amount0();
        if (inputDelta >= 0 || outputDelta <= 0) revert SlippageExceeded();
        uint256 amountIn = uint256(-int256(inputDelta));
        uint256 amountOut = uint256(int256(outputDelta));
        if (amountIn > request.maximumInput || amountOut < request.minimumOutput) revert SlippageExceeded();
        if (request.params.amountSpecified > 0 && amountOut != uint256(request.params.amountSpecified)) {
            revert ExactOutputNotFilled();
        }
        Currency input = request.params.zeroForOne ? request.key.currency0 : request.key.currency1;
        Currency output = request.params.zeroForOne ? request.key.currency1 : request.key.currency0;
        poolManager.sync(input);
        IERC20(Currency.unwrap(input)).safeTransfer(address(poolManager), amountIn);
        if (poolManager.settle() != amountIn) revert UnsupportedToken();
        // The manager now holds the swap input, even for the first buy against token-only liquidity.
        hook.payCreatorFee();
        poolManager.take(output, request.buyer, amountOut);
        return abi.encode(amountIn, amountOut);
    }
}
