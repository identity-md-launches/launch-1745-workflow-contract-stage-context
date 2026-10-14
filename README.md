# REKTD Blitz contracts

This is the contract-stage contribution for REKTD on Robinhood Chain (4663): a fixed-supply token, an IMD-denominated last-buyer jackpot hook, a dedicated swap router the hook deploys itself, tests, and ABI exports. The dashboard/IPFS publication and independently authored `launch.json` belong to subsequent stages. Nothing here broadcasts transactions or requires a private key, oracle, keeper, backend signer, or other outside service.

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7333f157973dce0dd8def152b8d90debda18f6f0c8bd66b146f6434424469af4 forge test
forge fmt --check
python3 tools/export_abis.py
```

The compiler is pinned to Solidity **0.8.26**, Cancun, optimizer 200 runs, IR compilation, and `bytecode_hash = "none"`. Dependencies are ordinary files in `lib/`; no network, submodules, FFI, environment access in tests, or filesystem permissions are needed for the default build/test suite. Upstream commits and licenses are recorded in [dependencies.json](docs/dependencies.json). `CheckedHook` is a local, minimal IHooks adapter; production code uses v4-core and OpenZeppelin, with Solmate required by the test PoolManager. Forge Standard Library is test-only.

The optional [Robinhood fork test](integration/RobinhoodFork.t.sol) uses a separate profile so offline verification never needs RPC:

```sh
FOUNDRY_PROFILE=fork forge test \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --fork-block-number 88403666
```

It passed using the real IMD token, a fresh locally deployed PoolManager, REKTD-only liquidity, the actual creator recipient, buys, sells, prize payment, and the burn-address transfer. It is not a rehearsal against the launch factory's deployed position logic. See [verification and review notes](docs/security.md).

## Contracts and deployment parameters

| Contract | Constructor, in order | Purpose |
|---|---|---|
| `RektToken` | None | REKTD / REKTD, 18 decimals, exactly `1000000000000000000000000000` units minted once to its deployer (the launch factory). |
| `RektJackpotHook` | `IPoolManager manager`, `address initialOwner`, `address launchFactory`, `address pairedToken`, `address token` | One-pool fee accounting, authenticated leader tracking, timer, round settlement and history. Its constructor also deploys and binds `RektSwapRouter`. |
| `RektSwapRouter` | `IPoolManager manager`, `RektJackpotHook jackpotHook` | Deployed by the hook constructor, never by the manifest. Pulls only the caller's input, executes one swap, enforces slippage/deadline, pays creator fees, and refunds unused input. |

Hook constructor resolution for the manifest contribution:

| Argument | Required value |
|---|---|
| `manager` | `$poolManager`, supplied by the launch service; never a hardcoded PoolManager. |
| `initialOwner` | `$owner` = `0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2`. This is also the immutable creator fee recipient. |
| `launchFactory` | `$factory`, supplied by the launch service. Only this address may initialize the pool. |
| `pairedToken` | IMD: `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` on chain 4663, 18 decimals. |
| `token` | `$token`, the freshly deployed `RektToken`. |

The manifest names only `RektToken` and `RektJackpotHook`. The hook constructor runs `new RektSwapRouter(manager, this)` itself, so the router's creation code is part of the hook's attested creation code, the router exists at the end of the launch transaction, and `swapRouter()` is never zero: the pool trades as soon as the factory seeds it, with no owner action. Read the router's address from `swapRouter()` or the `SwapRouterConfigured` event in the hook's deployment receipt. All constructors are free of external calls and code-existence checks (creating a new contract is not a call to an existing one, and the launch simulation with empty manager/factory/token addresses is in `test/Deployment.t.sol`). The hook constructor checks its own permission bits. All library calls are internal/inlined, with no bytecode link references. All three runtime sizes are below EIP-170 and the hook's creation code (14,473 bytes, router included) is below the 49,152-byte initcode limit.

The hook's lower 14 address bits must be **`0x20cc` (8396)**. Mine CREATE2 using the actual deployer, complete compiled creation bytecode and encoded constructor arguments. The enabled callbacks are `beforeInitialize`, `beforeSwap`, and `afterSwap`, plus both swap return-delta permissions. Permission flags are immutable. A real CREATE2 deployment is exercised in `test/Deployment.t.sol`.

`beforeInitialize` requires the supplied factory, the exact sorted REKTD/IMD pair, this hook, static LP fee **12500 (1.25%)**, and tick spacing **60**. It binds the pool once. The factory may supply any valid opening price: it computes the opening market-cap price with the actual token ordering. The manifest's `79228162514264337593543950336` reference value is not an enforced opening price.

The initialization callback was added for the launch's initialization protection. Both swap callbacks and return-delta permissions are necessary to charge IMD for all four buy/sell and exact-input/output cases. No liquidity or donation callbacks are enabled. The factory can always collect its LP fees with a zero liquidity change and can withdraw liquidity; there is no administrative switch affecting this.

The token has no owner, extra mint, transfer tax, pause, blocklist, proxy or upgrade path. Allocations are performed by the launch factory under policy: 80% pool, 10% swarm distributor, 10% payer/treasury. The workflow's wording about allocating the requester's share does not introduce another allocation in these contracts. Neither the hook nor router receives any launch allocation; the jackpot starts at zero.

## Swap fees and solvency

Every successful swap in this pool pays **1% of gross IMD**, in addition to the pool's 1.25% LP fee. Half the hook fee (50 bps) goes to the original creator and half (50 bps) funds `jackpotPool`. The approved brief explicitly requires IMD for fees, prizes and burning, so there is no ETH conversion market or ETH fee settlement.

Gross IMD means the buyer's total actual IMD input, including the hook fee, or the seller's IMD output before the hook fee. Let `F` be the total hook fee:

| Mode | Fee and execution |
|---|---|
| Buy, exact input `G` IMD | `F = floor(G / 100)`; the AMM uses `G - F` IMD. |
| Buy, exact output REKTD | The AMM costs `N` IMD; `F = floor(N / 99)`; buyer pays `N + F`. |
| Sell, exact input REKTD | AMM produces `G` IMD; `F = floor(G / 100)`; seller receives `G - F`. |
| Sell, exact output `N` IMD | `F = floor(N / 99)`; the AMM produces `N + F`, so the seller receives exactly `N`. |

The creator receives `floor(F / 2)` and the pot gets the remainder. Thus rounding dust, at most one minor unit per fee split, stays in the pot. Sub-100-wei gross swaps may round to zero fee. No fee is ever extracted in REKTD. IMD can sort as either currency0 or currency1.

The hook mints IMD ERC-6909 claims on the PoolManager for the fee. The router then settles its input from its own prefunded balance, burns the creator's claims and transfers that IMD to the creator **within the same swap transaction**. This avoids attempting to withdraw IMD before the first buyer has supplied it. Jackpot claims remain on the manager until settlement; `jackpotPool` is an amount of IMD, not the hook's ERC-20 balance. Claims have no separate user share token.

At transaction boundaries:

```text
hook IMD claims = jackpotPool + pendingCreatorFees + totalUnclaimedPayouts
pendingCreatorFees = 0
totalFeesCollected = jackpotPool + totalCreatorFeesPaid + totalPrizesPaid + totalIMDBurned
totalCreatorFeesPaid, totalPrizesPaid, totalIMDBurned count IMD allocated: delivered or parked
every PoolManager transient delta = 0
```

Partial execution is supported for exact-input **sells**, charged on actual IMD output, with unused REKTD refunded. Exact-output trades must fill fully. An exact-input **buy** that hits its price limit before using all its requested IMD reverts atomically: the IMD fee is a specified-side delta fixed before the swap, and charging unexecuted volume is forbidden. Use a smaller order or a deliberately chosen wider price bound when appropriate. Empty/no-output trades cannot pay a fee or take leadership.

## Blitz rounds

This is a deterministic last-qualifying-buyer game, not a random lottery. There is no oracle, random seed, or promised resistance to transaction ordering.

1. Before a swap, an expired active round is settled using only its existing pot. The new swap's fee belongs to the next round.
2. Eligibility is evaluated against the pot **before that swap adds its fee**, after any expiry settlement: `max(1e18, ceil(pot / 20))` IMD minor units, where `pot` is `jackpotPool`, or its 20% rollover while `canSettle()` is true. This is the 1 IMD floor or 5% of the pot. `minimumTicket()` applies the same rule, so the view always equals what the next buy must spend, including in the window between a round's expiry and its settlement. The actual gross IMD spent must meet this ticket, and the buyer must receive nonzero REKTD.
3. The first qualifying buy starts a 600-second timer and sets the caller of the dedicated router as leader. Later qualifying buys replace the leader and set `roundEndTime = min(oldEnd + 120, now + 600)`. Multiple buys in one block cannot exceed the cap. Sells and sub-ticket buys fund the pot but do not extend the timer or become leader.
4. At `timestamp == roundEndTime`, a qualifying buy is still valid; expiry is strictly **`timestamp > roundEndTime`**, as in the approved brief. A displayed countdown of zero can therefore need the next second before settlement is callable.
5. Once expired, anyone calls `settleRound()`, or the next swap settles automatically. The last leader receives `floor(pot * 6000 / 10000)` IMD; `floor(pot * 2000 / 10000)` is transferred to `0x000000000000000000000000000000000000dEaD`; the remainder stays as rollover (20% plus rounding dust).
6. Settlement clears the leader and timer, increments the round ID, stores the result, and emits `RoundSettled`. The next qualifying buy starts another full 600 seconds. Fees may accumulate without an active leader; such a pot has no settlement deadline until someone qualifies.

Burning means the specified permanent sink transfer; it does not call an IMD mint/burn administrator or reduce IMD's `totalSupply`. Direct token transfers to the hook/router do not enter the pot and have no rescue mechanism. Fund the jackpot by trading in its bound pool.

### Payouts IMD refuses

IMD on Robinhood Chain is not a plain ERC-20: it has an owner-controlled blocklist (`blocked(address)`), so a winner, the burn sink or the creator can be refused at any time. A payout therefore never sits in the trading or settlement path. Every creator, winner and burn payment first tries the direct transfer (`redeemClaim`, a self-call the hook makes inside `try`/`catch`; it reverts `OnlySelf` for anyone else). If IMD refuses it, the amount stays backed by the hook's ERC-6909 claim and is recorded in `unclaimedPayout(recipient)` and `totalUnclaimedPayouts`, with a `PayoutParked` event. Round accounting is unchanged: the round still closes, the leader and timer clear, the rollover stays in the pot, the swap that triggered settlement still executes, and the next round starts normally. **No refusal by IMD can freeze settlement or trading.**

`claimPayout(address recipient)` is permissionless: anyone may retry delivery of a parked amount to its fixed recipient (needed for the burn sink, which cannot call anything). It burns the claim and transfers the IMD, emits `PayoutClaimed`, and reverts `NothingToClaim` when nothing is parked or with IMD's own error while the recipient is still refused, changing nothing. Parked amounts accumulate per recipient across rounds and are included in the claim-backing invariant above. The hook has no power to bypass token restrictions, redirect a payout or choose an alternative winner. A settlement call sent with just too little gas can also land in the parked path (the inner transfer runs out of gas); that costs the recipient one `claimPayout` later, nothing more. Standard ERC-20 transfers do not invoke recipient callbacks, so a recipient contract rejecting ETH does not affect this IMD-only design.

## After launch

**No owner action is required for trading.** The launch transaction deploys the token and the hook, and the hook constructor deploys and binds its own `RektSwapRouter`; `swapRouter()` is set from the first block. There are no settings or missing deployment values for the requester to supply.

Only the bound router can swap in this pool. This deliberate restriction authenticates the payer as the jackpot buyer and guarantees same-transaction creator payment. Generic Universal Routers, arbitrary hook data, and standard swap quoters are not supported directly. Contracts and smart-account wallets can use `RektSwapRouter` normally: attribution uses their immediate call, never `tx.origin`. A second router deployed from the same source is not accepted until the owner binds it.

The one owner power over routing is **`configureRouter(address)`**, kept as a recovery path: the router briefly holds each buyer's IMD, so if IMD's owner ever blocklists the router's address every buy would fail. The owner may then deploy a fresh `RektSwapRouter(manager, hook)` and bind it. The hook accepts a replacement only if its runtime code hash equals the constructor-deployed router's (`router.codehash == swapRouter.codehash`). Immutables are part of runtime code, so an accepted router necessarily runs the reviewed logic against this PoolManager and this hook; a different build, a different target or any other contract is rejected `InvalidRouter`, as is rebinding the current router. The replaced router stops being accepted, and `SwapRouterConfigured` records the change. The owner cannot otherwise pause swaps, change fees/timers/recipients, or withdraw the pot.

Ownership uses two-step transfer, but changing owner does not change the original creator recipient. Renouncing ownership is disabled.

Services remain responsible for the independently generated manifest, source publication, attestation, admission, launch-factory execution, actual allocation/LP policy and final deployment rehearsal. The frontend stage uses the ABI exports and [integration guide](docs/abi/README.md), reads `swapRouter()` from the hook rather than a separately recorded address, displays the game/ordering risks, and publishes the approved dashboard. Anyone may settle an expired round or retry a parked payout; no automated offchain keeper is required. Independent adversarial review remains a separate stage.

## Implementation choices and risks

- [Canonical hook configuration](docs/hook-config.json): a BaseHook-style implementation on core `IHooks`; ownable, no shares, no pause. Explicit bounded casts replace a cast utility; direct claim mint/burn/take operations replace CurrencySettler. The hook does not add transient storage, while v4-core requires Cancun transient storage.
- All economics are named constants: `HOOK_FEE_BPS=100`, `CREATOR_FEE_BPS=50`, `TICKET_BPS=500`, `WINNER_BPS=6000`, `BURN_BPS=2000`, `ROUND_DURATION=600`, `EXTENSION=120`, `MIN_TICKET=1e18`, `LP_FEE=12500`, `TICK_SPACING=60`.
- IMD must remain a non-rebasing, non-taxed 18-decimal ERC-20. The router rejects taxed incoming transfers. Blocklisted recipients are handled by parking (above); a blocklisted router address is handled by `configureRouter`; a blocklisted *buyer* simply cannot sell, as with any IMD holder. The pinned fork tested the actual token's relevant transfer paths; it cannot guarantee future token behavior.
- The creator fee recipient is `initialOwner`, which the manifest writes as `$owner`. The brief names the creator as `0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2`, the same wallet that pays for and owns the launch, so `$owner` resolves to it; the manifest review must confirm that resolution because the recipient is immutable and `transferOwnership` does not move it.
- The 1% hook fee rounds down (`floor`), so gross IMD volume below 100 wei pays no fee and each swap under-collects by at most 1 wei. Splits conserve value exactly and a zero-fee swap cannot take leadership (1 IMD floor), so nothing is exploitable; this is the documented rounding, not a defect.
- Bots, profitable last-second entries, self-trading, wash volume, sequencer timing/censorship and transaction ordering can affect leadership. A last buyer may lose the lead before their transaction confirms. Slippage/deadline controls protect trade execution, not winning odds. No minimum guaranteed jackpot payout or refund of swap fees is promised.
- No proxy, upgrade, administrative pot withdrawal, or external-call loop exists. Immutable code cannot be repaired in place after launch; the only replaceable part is the router, and only by a bytecode-identical copy.
