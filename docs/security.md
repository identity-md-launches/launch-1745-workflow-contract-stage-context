# Verification and local security review

This records implementation checks, not an independent audit or a deployment attestation. Independent review and launch-service rehearsal remain separate stages.

## Evidence

- Compiler: Solidity 0.8.26, Cancun, optimizer 200, via IR, metadata hash disabled.
- Default tests exercise a real, freshly constructed Uniswap v4 PoolManager, with both IMD currency orders, funded pools and REKTD-only pools. They never use RPC, environment reads/writes, FFI or persistent filesystem state.
- All four swap modes are checked against actual token balances and manager claim balances. Partial-fill, output slippage, maximum-input, deadline, unbound router copies, router replacement, invalid pool, empty liquidity, spoofed buyer, refused winner/burn/creator transfers (parked and later claimed) and reentrancy paths are covered.
- The hook is deployed exactly as the factory leaves it in every fixture: constructor only, no owner transaction, and trading works from there. Both reviewer proofs (blocked winner, factory-only deployment) pass.
- Timer tests cover the 1 IMD floor, dynamic 5% threshold, pre-fee eligibility, same-block cap, two-minute extension, exact deadline, automatic settlement before new fees, rollover, history, and duplicate settlement.
- Stateful invariant tests run 64 sequences of 32 calls with randomized buys, sells, exact-input/output trades, time advances and settlement. They assert conservation, claim backing, creator delivery, cleared transient debts and timer bounds. Invariant handlers also check the expected leader and deadline transition for each trade.
- The supplied fuzz seed is `0x7333f157973dce0dd8def152b8d90debda18f6f0c8bd66b146f6434424469af4`.
- Deployment tests perform real CREATE2 salt mining with empty external addresses, verify all permission bits, inspect deployed runtime for SELFDESTRUCT/DELEGATECALL/CALLCODE, check EIP-170 sizes, and reject wrong factory/pool/router bindings. LP fee collection and full liquidity withdrawal leave jackpot settlement available.
- Optional Robinhood fork evidence: public source `https://rpc.mainnet.chain.robinhood.com`, chain 4663, block **88403666**. At the supplied IMD address, RPC returned 15,448 bytes of code, symbol `IMD`, and decimals 18. The fork test passed a buy and sell against REKTD-only local-manager liquidity, same-transaction creator payout, expired-round prize payment and transfer to the specified burn address using the actual IMD implementation. No transaction was broadcast.

The fork test is an integration profile in `integration/`, excluded from default tests. It uses a newly deployed local PoolManager, not an assumed address for the chain's live manager. The launch service must still verify its supplied manager/factory and exact opening price/position logic.

## Permission and accounting review

| Area | Implementation and evidence |
|---|---|
| Callback caller | Every IHooks entry point checks the immutable PoolManager; disabled callbacks revert. The unlock callback additionally requires an outstanding unlock initiated by the hook itself. |
| Buyer authentication | One router, deployed by the hook constructor from the attested creation code. It embeds only its own entry caller in hookData; no user-selected buyer/payer/recipient. Smart wallets work; tx.origin is unused. The owner can replace it only with a contract whose runtime code hash equals the original's, so no router with different logic, manager or hook can ever be bound. |
| NoOp exposure | Specified-side return delta is only the fixed IMD fee, never the full swap. Positive, bounded specified amounts and actual execution are checked. Empty and partial quote-specified swaps revert without collecting fees or electing a leader. |
| Return-delta mapping | The hook derives specified/unspecified currency from exact-input/output and direction, then applies fees only to IMD. Both orderings and all four combinations are tested. No LP-fee override is returned. |
| Claims | Minting the fee claim balances the hook's positive return delta. Redemption burns claims before take. Every completed unlock clears all currency debts. |
| Fresh manager | No direct fee take in a swap callback before input settles. The router settles its own input first, then pays the creator during the same unlock. No native balance is required. |
| Settlement | State/round history are committed before transfers, with a shared reentrancy guard. Each transfer is attempted in a self-call under try/catch: a refused one is parked for its recipient (claim kept, `unclaimedPayout` recorded) instead of reverting, so settlement and the swap that triggered it always complete. Duplicate settlement fails. `claimPayout` is permissionless but pays only the recorded recipient, and `redeemClaim` is self-call only. |
| Router settlement | Funds are pulled only from entry-point msg.sender before unlock. Callback is manager-only and one-use, pays from the router's own balance, checks actual settlement, and refunds only that request's unused input. No arbitrary-send-ERC20 path exists. |
| Slippage | Caller maximum/minimum, explicit AMM price limit, and deadline. Exact-output trades cannot silently return less. No output recipient can be selected by another caller. |
| Ownership | Explicit initialOwner, two-step transfer, fixed creator recipient, router replaceable only by a bytecode-identical copy. No withdrawal, fee setter, pause, upgrade, or liquidity-blocking switch. Constructor deployer/tx.origin never becomes hook owner implicitly. |
| External tokens | IMD is explicitly 18 decimals, checked on the target chain. Incoming fee-on-transfer tokens are rejected. Rebasing/taxed/blocklisted future token behavior remains an integration risk. |
| Loops and history | No production external-call loop or enumeration of past rounds. Settlement stores one result; clients page history. |

## Responsibilities and remaining limits

The independent reviewer should verify the complete compiled constructor arguments, mined hook bits, that the hook's creation code embeds the reviewed `RektSwapRouter`, IMD's current transfer behavior, exact launch-pool opening/LP interactions, economic game assumptions and service-generated manifest linkage. No owner step is needed for trading, and no router with other code can be bound.

This last-buyer game intentionally permits buyers to replace earlier leaders. It is vulnerable to the economic advantages of timing, bots, sequencer ordering/censorship and self-trading; no oracle or randomness removes these. No admission claim or audit claim should imply guaranteed fair ordering or profitability.

Transfers to recipients that the IMD contract blocks are parked for the recipient and never halt settlement or swaps; a blocked recipient collects with `claimPayout` once IMD allows it. A blocked router address is recoverable through `configureRouter` with an identical copy. There is no administrator redirecting prizes or withdrawing the pot. Direct deposits to the hook/router are unsupported and not recoverable. The configuration assumes the chosen IMD continues to be non-rebasing and non-taxed.

Slither and Mythril were not available in this environment and were not run. No formal verification, independent adversarial audit, explorer publication, deployment, or funded transaction was performed. These are not represented as completed by passing local tests.

The Foundry build's static lint warnings were reviewed separately: casts follow explicit signed bounds/sign checks; initialOwner's zero check is in OpenZeppelin Ownable; the router is created by the constructor and a replacement must match its code hash; callback sender and buyer checks are in `_checkSwap`; intentional timestamp comparisons implement the requested game; reentrancy warnings around manager calls/guard cleanup are covered by the active guards and one-use callback checks. The warning that `unclaimedPayout` is written after the `redeemClaim` self-call is by design: that call is made only from functions already holding the reentrancy guard (`beforeSwap`, `payCreatorFee`, `settleRound`/`claimPayout` via `unlockCallback`), so nothing can re-enter the hook during the IMD transfer, and the write happens only on the reverted branch. Strict input-balance equality deliberately rejects transfer-taxed tokens. Lint warnings are not suppressed globally or treated as proof of an exploit.
