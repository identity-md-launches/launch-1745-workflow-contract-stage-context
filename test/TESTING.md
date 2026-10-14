# Contributor test coverage

These tests extend the accepted suite without changing production contracts or configuration.
They use the vendored, real Uniswap v4 `PoolManager`, the production REKTD token, hook and router,
and the existing mintable 18-decimal IMD stand-in. No RPC, environment mutation, extra dependency,
FFI or skipped test is required.

`RektAdversarial.t.sol` adds:

- Invalid constructor dependencies, invalid initialization with rollback and retry, use before
  initialization, and every disabled callback's manager/outsider access boundary.
- Malformed buyer encodings, zero/burn buyers, noncanonical addresses, signed amount limits and
  the exact-output quote fee's `int128` limit.
- Full transaction rollback when an expired round is settled but the following swap, final
  output transfer or refund fails. Snapshots include history, player balances, creator/burn
  payments, claims, allowances and pool price.
- Explicit one-wei output and 98/99/100/199/200-wei input examples, fee-rounding inequalities
  across all four swap modes, and buy/sell round trips that cannot profit before settlement.
- Multiple swaps, and permissionless settlement followed by swaps, inside one wallet call.
  This exercises reuse of the hook/router unlock guards within one transaction.

The three new stateless fuzz properties each run 1,000 examples using inline Foundry settings.

`RektStatefulAccounting.t.sol` runs the same four-actor handler with IMD as currency0 and as
currency1. Each campaign uses 256 sequences of 64 actions, with unexpected reverts treated as
failures. Inline configuration is placed on the concrete test contracts because inherited
function annotations are not applied to the derived suites by the installed Foundry runner.

The seven actions are all four swap modes, buys immediately below/at/above the dynamic ticket,
time advancement including the exact deadline, successful/rejected settlement, raw token
donations, liquidity additions/removals/fee collection, and invalid swaps. Trade inputs include
dust, ticket-floor edges and values up to 1,000 IMD/REKTD. There are no per-action balance top-ups.
Liquidity stays at least 500,000 during trading so the maximum input budget is feasible. Every
sequence finishes by withdrawing the entire LP position and settling any remaining round.

The handler and invariants check:

- Each player's actual balances match a ledger updated from returned swap amounts, donations
  and the specified 60% prize. Fees are measured from changes in actual creator balances and
  manager claims, independently of the hook's total-fee counter.
- All quote tokens and the fixed billion-token REKTD supply remain accounted for across the
  complete holder set. Claims match jackpot liabilities and have actual IMD backing, including
  after the LP position is fully withdrawn.
- Creator and burn transfers agree with accounting totals. Donated router balances cannot be
  spent as refunds, and direct donations cannot inflate the pot or minimum ticket.
- Each closed round has the prior leader/deadline, closes strictly after its deadline, allocates
  its entire pot, pays only once, and keeps its history unchanged. An active round has no result.
- The timer never exceeds ten minutes and only authenticated actors can become leader.
- Manager locks and all hook/router/factory transient currency debts are cleared **inside the
  handler transaction**, before end-of-transaction cleanup could hide a debt.

Each invariant suite also has a deterministic scenario exercising every handler action and all
four swap modes, then the full liquidity withdrawal. This checks that the harness reaches its
intended paths independently of random selection.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7333f157973dce0dd8def152b8d90debda18f6f0c8bd66b146f6434424469af4 forge test
```

Local build output/cache can be directed to `test/scratch/` with `--out test/scratch/out
--cache-path test/scratch/cache`; delivered tests have no dependency on that directory.

Live Robinhood Chain IMD behavior and the deployed launch factory still require the separate
fork rehearsal. These offline tests do not claim to validate live token code or deployment
services. No reproducible production defect was found by this added suite.
