# Contract ABI and dashboard integration

The adjacent JSON files are ABI arrays exported from Solidity 0.8.26 artifacts by `python3 tools/export_abis.py`. Regenerate after source changes; no third-party SDK is required for export.

| File | Contract |
|---|---|
| [RektToken.json](RektToken.json) | Standard ERC-20 reads, transfers and allowances. No constructor arguments. |
| [RektJackpotHook.json](RektJackpotHook.json) | Hook constructor, game state, settlement, parked payouts, history and events. |
| [RektSwapRouter.json](RektSwapRouter.json) | Dedicated swap entry point and results. Its address is `RektJackpotHook.swapRouter()`; it is deployed by the hook constructor, not listed in the manifest. |

The deployment service supplies the token and hook addresses after launch; read the router from the hook. Use chain ID **4663** and IMD at `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127`. Never substitute a guessed token, hook, manager or router address. REKTD and IMD both use 18 decimals. The creator is `0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2`.

## Read model

| Hook call | Interpretation |
|---|---|
| `poolKey()` | Exact initialized pool key, already sorted. Reverts before initialization. |
| `swapRouter()` | The only router the pool accepts, bound by the constructor and never zero. Re-read it after any `SwapRouterConfigured` event: the owner may replace it with a bytecode-identical copy. |
| `unclaimedPayout(address)` | IMD allocated to that address (prize, burn or creator fee) that IMD refused to deliver, retryable with `claimPayout`. |
| `totalUnclaimedPayouts()` | Sum of all parked amounts, backed by the hook's PoolManager claims. |
| `jackpotPool()` | IMD jackpot minor units backed by PoolManager claims. Do not substitute ERC-20 balanceOf(hook). |
| `currentLeader()` | Last qualifying router caller; zero means no active round. |
| `roundId()` | Current round, starting at 1. Completed rounds are `[1, roundId - 1]`. |
| `roundEndTime()` | Absolute block timestamp, zero when no active round. |
| `secondsRemaining()` | Nonnegative remaining seconds; consult `canSettle` at zero. |
| `minimumTicket()` | Exactly what the next buy must spend to take the lead: `max(1 IMD, ceil(pot / 20))` where `pot` is the current pot, or its 20% rollover while `canSettle()` is true (the next swap settles first). Display it as is. |
| `canSettle()` | Nonzero leader and latest block timestamp strictly greater than the deadline. |
| `totalIMDBurned()` | Cumulative IMD sent to the specified sink, not a supply reduction. |
| `totalPrizesPaid()`, `totalCreatorFeesPaid()` | Cumulative actual transfers. |
| `roundHistory(id)` | `(winner, endTime, settledAt, pot, prize, burned, rollover)`; all amounts are IMD minor units. An unused ID returns zero fields. |

Read `balanceOf(wallet)` from both token contracts for wallet balances. Use block timestamps as the clock reference, interpolate locally for the display, and refresh from new blocks. A zero countdown does not make the exact-deadline block settleable. For history, page bounded ID ranges or index `RoundSettled` logs starting at the service-provided deployment block; handle reorganizations and never request an unbounded history in one call.

When an old round is expired but unsettled, `jackpotPool()` still shows the pot about to be settled while `minimumTicket()` already reflects the rollover the next buy is judged against. A frontend can call `settleRound()` and refresh, or explain this transition when displaying the two.

`totalPrizesPaid()`, `totalCreatorFeesPaid()` and `totalIMDBurned()` count IMD allocated; if IMD refused a transfer, the difference is in `unclaimedPayout(recipient)`. Show a wallet its parked amount and offer `claimPayout(wallet)` when it is nonzero.

## Wallet actions

`RektSwapRouter.swap(bool zeroForOne, int256 amountSpecified, uint256 limit, uint160 sqrtPriceLimitX96, uint256 deadline)` returns `(amountIn, amountOut)`, the caller's final debited input and received output including the hook fee. There is no arbitrary payer or recipient field.

1. Confirm chain 4663, initialized pool, the router read from `swapRouter()`, and both balances.
2. Determine direction from `poolKey`: for a buy, `zeroForOne` is true when currency0 is IMD. For a sell, invert it. Never assume token ordering before deployment.
3. For exact input, set a **negative** specified input amount and set `limit` to the minimum output. Approve only that input amount to the router. For exact output, specify a **positive** desired net output amount and set `limit` to maximum input; approve at most that maximum.
4. Supply a user-approved price limit in Q64.96 square-root-price units and a deadline (seconds). The price limit must be strictly below the current price for zeroForOne, above it otherwise, and inside v4's TickMath bounds. Obtain current pool state with the chain's supplied state-reader integration or `PoolManager.extsload` using the vendored `StateLibrary` layout. The deployment pipeline owns any chain-specific state-reader address.
5. Simulate the **router's** call from the wallet before submission. Its input allowance and balance must exist for an `eth_call` simulation. After approval, an exact-input simulation with `limit=1` can return a quote; apply the user's slippage tolerance to the result and simulate the real protected call again. Never submit a trade with this deliberately permissive quoting minimum. Generic v4 quoters are rejected because they are not this pool's configured router.
6. Send the protected swap and confirm its receipt. Refresh all game and wallet reads. Output and unused input are returned only to the caller. A successful buy under the ticket still pays fees but does not take leadership.
7. When `canSettle()` is true, anyone can send `RektJackpotHook.settleRound()` without a token approval. Another transaction may settle first; refresh on a revert. There is no claim signature or backend authorization. Settlement never fails because of the winner: a refused prize is parked for them.
8. When `unclaimedPayout(wallet)` is nonzero, anyone can send `RektJackpotHook.claimPayout(wallet)`; it pays only that wallet and reverts, changing nothing, while IMD still refuses it. `redeemClaim` in the ABI is internal to the hook (self-call only) and is not a wallet action.

An exact-input buy or an exact-output order must fully fill, otherwise the transaction reverts. Exact-input sells can partially fill at the price limit and refund the rest. All failure paths revert allowances spent within the swap, transfers, fees and leadership updates together (the separate approval transaction remains).

## Events

- `PoolBound(poolId, launchToken)` identifies the sole accepted pool.
- `SwapRouterConfigured(router)` names the bound router: once in the hook's deployment receipt, and again only if the owner replaces it with an identical copy.
- `HookFeeCollected(buyer, isBuy, grossQuote, creator, jackpot)` reports the IMD fee split.
- `CreatorFeePaid(recipient, amount)` records the creator's allocation in the same transaction (delivered, or parked if a `PayoutParked` follows).
- `PayoutParked(recipient, amount)` and `PayoutClaimed(recipient, amount)` track payouts IMD refused and their later delivery.
- `LeaderChanged(roundId, leader, quoteSpent, ticket, endTime)` records a qualifying buy and deadline.
- `RoundSettled(roundId, winner, pot, prize, burned, rollover, endTime, settledAt)` supplies complete round history.
- Router `SwapExecuted(buyer, zeroForOne, specified, amountIn, amountOut)` reports the actual swap result.

Hook errors called through PoolManager may be wrapped in v4's `WrappedError`. Decode the nested error using the hook ABI. Expected user errors include expired deadline, insufficient allowance/balance, slippage exceeded, a price-bound partial fill, early/already-completed round settlement, nothing to claim, and a stale router address after a replacement (`OnlySwapRouter`). Do not treat a failed simulation as a completed trade.
