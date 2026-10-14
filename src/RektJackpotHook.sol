// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CheckedHook} from "./base/CheckedHook.sol";
import {RektSwapRouter} from "./RektSwapRouter.sol";

/// @notice A last-buyer blitz jackpot, denominated and paid entirely in IMD.
/// @dev Only the router this constructor deploys may trade: it authenticates buyers and pays creator
/// fees after settling input, including on a manager initially seeded with REKTD only. A payout that
/// IMD refuses is parked as a claimable balance so settlement and trading never depend on it.
contract RektJackpotHook is CheckedHook, Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    error OnlyFactory();
    error InvalidPool();
    error AlreadyInitialized();
    error NotInitialized();
    error OnlySwapRouter();
    error InvalidRouter();
    error OnlySelf();
    error InvalidBuyer();
    error InvalidSwapAmount();
    error PartialFillUnsupported();
    error NoActiveRound();
    error RoundStillActive();
    error NothingToClaim();
    error UnexpectedUnlock();
    error RenounceDisabled();

    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant HOOK_FEE_BPS = 100;
    uint256 public constant CREATOR_FEE_BPS = 50;
    uint256 public constant BPS = 10_000;
    uint256 public constant ROUND_DURATION = 600;
    uint256 public constant EXTENSION = 120;
    uint256 public constant MIN_TICKET = 1 ether;
    uint256 public constant TICKET_BPS = 500;
    uint256 public constant WINNER_BPS = 6_000;
    uint256 public constant BURN_BPS = 2_000;
    address public constant BURN_RECIPIENT = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable launchToken;
    Currency public immutable quoteCurrency;
    address public immutable creatorFeeRecipient;
    /// @notice The only contract that may swap in this pool. Deployed by the constructor; the owner may
    /// only ever replace it with a bytecode-identical copy (same code, same manager, same hook).
    address public swapRouter;
    bool public initialized;
    bool private unlocking;
    PoolId public poolId;
    PoolKey private key;

    uint256 public jackpotPool;
    address public currentLeader;
    uint256 public roundEndTime;
    uint256 public roundId = 1;
    uint256 public totalIMDBurned;
    uint256 public totalPrizesPaid;
    uint256 public totalCreatorFeesPaid;
    uint256 public totalFeesCollected;
    uint256 public pendingCreatorFees;
    /// @notice IMD allocated to a recipient that refused the direct transfer, still backed by claims.
    mapping(address => uint256) public unclaimedPayout;
    uint256 public totalUnclaimedPayouts;

    struct RoundResult {
        address winner;
        uint256 endTime;
        uint256 settledAt;
        uint256 pot;
        uint256 prize;
        uint256 burned;
        uint256 rollover;
    }

    mapping(uint256 => RoundResult) public roundHistory;

    event PoolBound(PoolId indexed poolId, address indexed launchToken);
    event SwapRouterConfigured(address indexed router);
    event HookFeeCollected(address indexed buyer, bool isBuy, uint256 grossQuote, uint256 creator, uint256 jackpot);
    event CreatorFeePaid(address indexed recipient, uint256 amount);
    event PayoutParked(address indexed recipient, uint256 amount);
    event PayoutClaimed(address indexed recipient, uint256 amount);
    event LeaderChanged(
        uint256 indexed roundId, address indexed leader, uint256 quoteSpent, uint256 ticket, uint256 endTime
    );
    event RoundSettled(
        uint256 indexed roundId,
        address indexed winner,
        uint256 pot,
        uint256 prize,
        uint256 burned,
        uint256 rollover,
        uint256 endTime,
        uint256 settledAt
    );

    /// @param manager Resolved by the launch as $poolManager; never a hardcoded deployment address.
    /// @param initialOwner Resolved as $owner, also the immutable named creator fee recipient.
    /// @param launchFactory Resolved as $factory, which alone may initialize this pool.
    /// @param pairedToken IMD, 18 decimals, on the launch chain.
    /// @param token Resolved as $token (RektToken).
    constructor(IPoolManager manager, address initialOwner, address launchFactory, address pairedToken, address token)
        CheckedHook(manager)
        Ownable(initialOwner)
    {
        if (
            launchFactory == address(0) || pairedToken == address(0) || token == address(0) || pairedToken == token
                || initialOwner == BURN_RECIPIENT
        ) revert InvalidAddress();
        factory = launchFactory;
        launchToken = token;
        quoteCurrency = Currency.wrap(pairedToken);
        creatorFeeRecipient = initialOwner;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // The router is part of this creation code, so the launch transaction yields a tradeable pool
        // and no later owner action can bind different routing code.
        address router = address(new RektSwapRouter(manager, this));
        swapRouter = router;
        emit SwapRouterConfigured(router);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Replace the router with a copy whose runtime code is identical to the one this constructor
    /// deployed. Immutables are part of that code, so the copy necessarily targets this manager and hook
    /// and runs the reviewed logic; no other contract is accepted. Recovery path for a router address
    /// that IMD later refuses to serve. The previous router stops being accepted.
    function configureRouter(address router) external onlyOwner {
        address current = swapRouter;
        if (router == current || router.codehash != current.codehash) revert InvalidRouter();
        swapRouter = router;
        emit SwapRouterConfigured(router);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function poolKey() external view returns (PoolKey memory) {
        if (!initialized) revert NotInitialized();
        return key;
    }

    /// @notice Ticket the next buy must meet, before that swap adds its fee. Rounded up to a wei.
    /// @dev An expired round is settled before the next swap is judged, so the pot used is the rollover.
    function minimumTicket() public view returns (uint256) {
        uint256 pot = jackpotPool;
        if (canSettle()) pot = pot - pot * WINNER_BPS / BPS - pot * BURN_BPS / BPS;
        uint256 proportional = pot / 20 + (pot % 20 == 0 ? 0 : 1);
        return proportional > MIN_TICKET ? proportional : MIN_TICKET;
    }

    function canSettle() public view returns (bool) {
        return currentLeader != address(0) && block.timestamp > roundEndTime;
    }

    function secondsRemaining() external view returns (uint256) {
        return roundEndTime > block.timestamp ? roundEndTime - block.timestamp : 0;
    }

    function beforeInitialize(address sender, PoolKey calldata pool, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        (address token0, address token1) = launchToken < Currency.unwrap(quoteCurrency)
            ? (launchToken, Currency.unwrap(quoteCurrency))
            : (Currency.unwrap(quoteCurrency), launchToken);
        if (
            Currency.unwrap(pool.currency0) != token0 || Currency.unwrap(pool.currency1) != token1 || pool.fee != LP_FEE
                || pool.tickSpacing != TICK_SPACING || address(pool.hooks) != address(this)
        ) revert InvalidPool();
        initialized = true;
        poolId = pool.toId();
        key = pool;
        emit PoolBound(poolId, launchToken);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata pool, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkSwap(sender, pool, hookData);
        _specifiedAmount(params.amountSpecified);
        if (canSettle()) _settleRound();

        // A specified IMD side must be adjusted before the AMM runs. Never consume the entire input.
        uint256 fee = 0;
        if (_quoteSpecified(pool, params)) {
            uint256 specified = _specifiedAmount(params.amountSpecified);
            fee = params.amountSpecified < 0 ? specified / 100 : specified / 99;
            if (params.amountSpecified > 0 && specified + fee > uint256(uint128(type(int128).max))) {
                revert InvalidSwapAmount();
            }
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata pool,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager nonReentrant returns (bytes4, int128) {
        address buyer = _checkSwap(sender, pool, hookData);
        bool buy = params.zeroForOne == (pool.currency0 == quoteCurrency);
        int128 quoteDelta = pool.currency0 == quoteCurrency ? delta.amount0() : delta.amount1();
        uint256 rawQuote = quoteDelta < 0 ? uint256(-int256(quoteDelta)) : uint256(int256(quoteDelta));
        uint256 specified = _specifiedAmount(params.amountSpecified);
        bool quoteSpecified = _quoteSpecified(pool, params);
        uint256 fee;
        uint256 grossQuote;
        if (quoteSpecified) {
            fee = buy ? specified / 100 : specified / 99;
            uint256 expected = buy ? specified - fee : specified + fee;
            // Otherwise a fee on an unfilled requested amount could buy leadership without a trade.
            if (rawQuote != expected) revert PartialFillUnsupported();
            grossQuote = buy ? specified : rawQuote;
        } else {
            fee = buy ? rawQuote / 99 : rawQuote / 100;
            grossQuote = buy ? rawQuote + fee : rawQuote;
        }
        uint256 ticket = minimumTicket();
        if (fee != 0) {
            uint256 creator = fee / 2;
            uint256 jackpot = fee - creator;
            pendingCreatorFees += creator;
            jackpotPool += jackpot;
            totalFeesCollected += fee;
            emit HookFeeCollected(buyer, buy, grossQuote, creator, jackpot);
        }
        int128 tokenDelta = pool.currency0 == quoteCurrency ? delta.amount1() : delta.amount0();
        if (buy && quoteDelta < 0 && tokenDelta > 0 && grossQuote >= ticket) {
            uint256 cap = block.timestamp + ROUND_DURATION;
            uint256 extended = currentLeader == address(0) ? cap : roundEndTime + EXTENSION;
            roundEndTime = extended < cap ? extended : cap;
            currentLeader = buyer;
            emit LeaderChanged(roundId, buyer, grossQuote, ticket, roundEndTime);
        }
        // All game accounting is complete before interacting with the manager.
        if (fee != 0) poolManager.mint(address(this), quoteCurrency.toId(), fee);
        return (IHooks.afterSwap.selector, quoteSpecified ? int128(0) : int128(uint128(fee)));
    }

    /// @notice Called by the router after it settles input, before the same unlock finishes.
    function payCreatorFee() external nonReentrant {
        if (msg.sender != swapRouter) revert OnlySwapRouter();
        uint256 amount = pendingCreatorFees;
        if (amount == 0) return;
        pendingCreatorFees = 0;
        totalCreatorFeesPaid += amount;
        emit CreatorFeePaid(creatorFeeRecipient, amount);
        _redeemTo(creatorFeeRecipient, amount);
    }

    /// @notice Permissionless settlement strictly after the deadline. No keeper is required.
    function settleRound() external nonReentrant {
        if (currentLeader == address(0)) revert NoActiveRound();
        if (block.timestamp <= roundEndTime) revert RoundStillActive();
        _unlock("");
    }

    /// @notice Pay out IMD parked for a recipient that refused it earlier. Anyone may retry; the
    /// recipient and amount are fixed by the hook, and a still-refused transfer reverts without change.
    function claimPayout(address recipient) external nonReentrant {
        if (unclaimedPayout[recipient] == 0) revert NothingToClaim();
        _unlock(abi.encode(recipient));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!unlocking) revert UnexpectedUnlock();
        unlocking = false;
        if (data.length == 0) {
            _settleRound();
        } else {
            address recipient = abi.decode(data, (address));
            uint256 amount = unclaimedPayout[recipient];
            unclaimedPayout[recipient] = 0;
            totalUnclaimedPayouts -= amount;
            emit PayoutClaimed(recipient, amount);
            _redeemClaim(recipient, amount);
        }
        return "";
    }

    /// @notice Burns the hook's IMD claim and transfers it. Only this hook may call it, inside its own
    /// try/catch: a refused transfer reverts here and is parked by the caller instead of blocking it.
    function redeemClaim(address recipient, uint256 amount) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _redeemClaim(recipient, amount);
    }

    function _redeemClaim(address recipient, uint256 amount) private {
        poolManager.burn(address(this), quoteCurrency.toId(), amount);
        poolManager.take(quoteCurrency, recipient, amount);
    }

    function _unlock(bytes memory data) private {
        unlocking = true;
        bytes memory result = poolManager.unlock(data);
        if (unlocking || result.length != 0) revert UnexpectedUnlock();
    }

    function _settleRound() private {
        uint256 pot = jackpotPool;
        uint256 prize = pot * WINNER_BPS / BPS;
        uint256 burned = pot * BURN_BPS / BPS;
        uint256 rollover = pot - prize - burned;
        uint256 id = roundId;
        address winner = currentLeader;
        uint256 ended = roundEndTime;
        jackpotPool = rollover;
        currentLeader = address(0);
        roundEndTime = 0;
        roundId = id + 1;
        totalIMDBurned += burned;
        totalPrizesPaid += prize;
        roundHistory[id] = RoundResult(winner, ended, block.timestamp, pot, prize, burned, rollover);
        emit RoundSettled(id, winner, pot, prize, burned, rollover, ended, block.timestamp);
        _redeemTo(winner, prize);
        _redeemTo(BURN_RECIPIENT, burned);
    }

    /// @dev Pays directly when IMD allows it. Otherwise the amount stays backed by the hook's claim and
    /// is recorded for `claimPayout`, so a blocked winner, burn sink or creator never freezes the pool.
    function _redeemTo(address recipient, uint256 amount) private {
        if (amount == 0) return;
        try this.redeemClaim(recipient, amount) {}
        catch {
            unclaimedPayout[recipient] += amount;
            totalUnclaimedPayouts += amount;
            emit PayoutParked(recipient, amount);
        }
    }

    function _checkSwap(address sender, PoolKey calldata pool, bytes calldata hookData)
        private
        view
        returns (address buyer)
    {
        if (!initialized) revert NotInitialized();
        if (PoolId.unwrap(pool.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
        if (sender != swapRouter) revert OnlySwapRouter();
        if (hookData.length != 32) revert InvalidBuyer();
        buyer = abi.decode(hookData, (address));
        if (buyer == address(0) || buyer == BURN_RECIPIENT) revert InvalidBuyer();
    }

    function _quoteSpecified(PoolKey calldata pool, SwapParams calldata params) private view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIs0 == (pool.currency0 == quoteCurrency);
    }

    function _specifiedAmount(int256 amount) private pure returns (uint256 absolute) {
        if (amount == 0 || amount < -int256(type(int128).max) || amount > int256(type(int128).max)) {
            revert InvalidSwapAmount();
        }
        absolute = uint256(amount < 0 ? -amount : amount);
    }
}
