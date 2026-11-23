# Known issues, out of scope and by design

This page lists behaviour of the DEX and of its off-chain surfaces (API, MCP server, SDK, website)
that is deliberate, bounded by a documented limit, or outside the programme's scope. It exists so
that nobody spends days proving something we already state. A report that only restates an entry
below is closed with a pointer to it; a report that shows impact **beyond** the bound an entry
states is in scope and is judged on its merits.

The policy, the scope table and the general out-of-scope list are in [`SECURITY.md`](../SECURITY.md);
how a report is reproduced and judged is in [`BOUNTY_METHOD.md`](BOUNTY_METHOD.md); the campaign
page is [blazephoenix.xyz/bounty](https://blazephoenix.xyz/bounty). The threat catalogue, with a test
for every class, is [`docs/assurance/threats.json`](assurance/threats.json).

## By design

- **A route the caller writes is the caller's intent.** The explicit entry point executes the route
  its caller authored, including a consistent venue the registry would not have chosen or a V4 hook
  nobody listed. The Router measures every leg and enforces the floors and the caller's
  `userMinOut`; it does not refuse a consistent venue for being a worse price. A loss confined to
  the author of the route, above their own minimum, is not a finding. Documented in
  `docs/assurance/threats.json` (`SOK-ROUTE-AUTHOR`) and `SECURITY.md` (Uniswap V4 hooks).
- **The caller's own request fields are the caller's choice.** The recipient, the slippage
  (`slippageBps`, 0 to 5000), the amount, the token pair and the deadline come from the request.
  The API, the MCP server and the SDK encode exactly what was asked, echo the recipient and the
  minimum back, and never sign: the calldata is reviewed and signed in the caller's own wallet.
  Paying another address, choosing a wide slippage, or asking for native ETH out and receiving WETH
  with the declared unwrap step are uses, not defects. In scope is calldata that differs from what
  the caller asked for. Documented in `SECURITY.md` (Scope, SDK and calldata) and the MCP server's
  README (every tool is read-only; the server never signs).
- **Administrative powers exist until they are renounced.** The Hub and the Router each have one
  admin address. Pausing, the role and configuration setters, removing a bridge, revoking a hook
  and the 48-hour rescue of tokens sent to the Router by mistake end permanently with
  `renounceControl`. Venue, hook and Gate-adapter admission is curated and only grows the registry;
  an admitted venue is still validated at quote and execution and bounded by the floors and the
  caller's minimum. Reports that need an admin, operator or curator to act against users are out of
  scope. Documented in `docs/assurance/threats.json` (`SOK-GOV`, `GATED-AUTO-HOSTILE-ADAPTER`) and
  `docs/WHITEPAPER.md` §5 (Ossification).
- **A fee-on-transfer or rebasing token's own cut is the token's.** Every amount that matters is a
  measured balance delta, and the caller's minimum is checked against what the recipient actually
  received, so a transfer tax cannot take a swap below it. A taxing token that delivers less than
  the quote but at least the signed minimum is not a finding. A rebasing bridge or input token
  whose restatement fires inside the swap, over a balance the Router already held, cuts that
  balance in the swapper's delivery: to the Router it is a short delivery, bounded by the same
  minimum, and the Router keeps the balance it held in the units it measures. Known residual: a
  restatement fired inside the legs' window of a hop split over two or more legs reaches the held
  balance by the cut on the later legs' amounts, which were sized before it; measuring every leg
  would cost one more balance read per leg on every swap. The route floors (the protocol
  floor and the caller's single-output floor) price gross output, so they are read against the
  gross the venues declared paying; a tax on the output token neither trips them nor relaxes them,
  and the net is checked against the caller's minimum where it lands. Documented in
  `docs/assurance/threats.json` (`SOK-FOT`, `BRIDGE-DELTA-NEGATIVE-RESTATEMENT`,
  `INPUT-DELTA-NEGATIVE-RESTATEMENT`),
  `docs/WHITEPAPER.md` §5 (Fee-on-transfer) and the `ExecutionProof` NatSpec in
  `src/BlazePhoenixRouter.sol`.
- **Token metadata is data, not instructions.** The MCP server strips invisible, control,
  bidirectional and tag characters from every string it returns, caps token names and symbols, and
  tells the agent the text is data to show. Plain-language text that survives that cleaning cannot
  be filtered by meaning; text injection without impact is out of scope. Documented in
  `SECURITY.md` (Out of scope) and the MCP server's `src/text.ts`.
- **LFJ's ignoredForRouting flag is not read.** The Liquidity Book adapter takes the pair from the
  factory's `getLBPairInformation` record at `resolve` and drops the record's fourth field,
  `ignoredForRouting`. `resolve` runs once, in the Gate's `create`, and `quote`, `quoteCall` and
  `exec` never ask the factory again. The flag is a discovery hint for LFJ's own quoter, which
  skips flagged pairs in its path search; LFJ's router and the pair never read it, and the
  factory's owner sets it at any time. It is not a safety property, so a flagged pair resolves and
  trades like any other. What holds without it: the pair's identity is the factory's record; the
  pair's hooks are read live on every `exec`, `quote` and `quoteCall` (`_hooksOk`); the Gate
  wrapper measures the output as the balance delta at the recipient, never the adapter's word; the
  floors are the Router's (per leg, per hop and the caller's `userMinOut`); and only the Gate's
  curator creates a wrapper, so whether a flagged pair gets one is the curator's decision. Pinned
  by `test_LB_Resolve_IgnoredForRoutingIsNotRead` (`test/adapters/AdapterLB.t.sol`) and mutant
  `LB-48` in `.github/scripts/mutants.py`; documented in the NatSpec of
  `src/adapters/BlazePhoenixAdapterLB.sol`.

## Accepted and documented limits

- **`canExecute` does not detect tokens that refuse contract recipients.** Some tokens revert any
  transfer whose recipient is a contract (for example a custom `ERC20InvalidReceiver` check), and
  the Router is a contract. The Quoter's preview checks the deadline, the funded output against
  the effective minimum and input taxes, and the encode doors also ask each leg's floor and its
  hop's budget as the Router sets them; it does not simulate the token's transfer to the Router,
  so such a route can preview `canExecute = true`. The swap then reverts as a whole and the caller
  keeps the input: no funds are lost. Detecting every hostile transfer rule at quote time would
  cost gas on every quote and could never be complete, so it is a documented limit.

- **Price movement, MEV and sandwiching above the signed minimum.** The iron floor is a bound, not a
  promise of the quoted amount: a fill between the floor (or the caller's tighter `userMinOut`) and
  the quote settles by design. Beating a bound the whitepaper states is in scope. Documented in
  `SECURITY.md` (Out of scope), `docs/WHITEPAPER.md` §5 (Iron floor) and
  `docs/assurance/threats.json` (`DASP-7`).
- **Dynamic-fee V4 keys under a non-zero protocol fee.** The Router cannot price such a key in the
  frame, so the leg carries no in-frame promise and is bounded by the caller's attestation and
  `userMinOut`; the registry does not claim these keys. Documented in
  `docs/assurance/threats.json` (`SOK-DYNFEE-PROTOFEE`).
- **Off-chain plan computation on fragmented liquidity.** Anyone can mint one-wei positions, and a
  deep search can exceed the call gas an RPC node allows. The effect is liveness only: no plan, no
  swap, no funds at risk. A caller can compute the plan on a node with a higher limit or pass an
  explicit route. Documented in `docs/assurance/threats.json` (`SOK-SOLVE-LIVENESS`).
- **A hook behind a delegate proxy.** The codehash pin pauses a hook whose own runtime changes, but
  the EVM gives no way to read another contract's storage, so an EIP-1967 implementation swap
  cannot be pinned on-chain. That case is bounded by curation of the allow-list, the immutable
  address bits and the floors on measured output. Documented in `SECURITY.md` (What the codehash
  pin covers).
- **The per-leg ceiling is the venue's own declaration.** A leg's measured delta may not exceed what
  the venue says it paid. A Gate wrapper declares the Router's delta across its adapter's execution,
  so a donation inside that execution raises the declaration with it; a Gate leg writes nothing to
  the registry, and the swap stays bounded by the floors and the caller's minimum. Documented in
  `docs/assurance/threats.json` (`SOK-LEG-DELTA-DONATION`, Limits).
- **A venue that declares more than it pays settles inside the per-leg band.** The route floors
  (the protocol floor and the caller's single-output floor) read the gross the venues declared
  paying, and to the Router a venue that declares more than it pays and a token that taxes the
  venue-to-Router transfer are the same observation. Such a venue is held on what the Router
  measured, on two checks. Each attested leg answers on its own: its measured delta against the
  per-leg floor, `LEG_FLOOR_BPS` (80%) of its attestation, and the hop budget its parallel legs
  share. The whole last hop answers together: the route's measured output against the same 80% of
  the hop's figure (the one the protocol floor is a fraction of: the in-frame quote, else the
  attested figure, else the hop's declared figure), re-priced by a measured input tax. The second
  check is what holds a leg priced in frame that attests nothing, whose own floor rests on the
  quote coverage share alone. The effect: a venue named in the calldata may deliver anywhere
  between 80% and 100% of that figure and the swap settles; under 80% it is refused with
  `RouterE(5)`. Two shapes read that band differently. On a last hop of several legs the hop is
  held on its measured sum, so one leg may deliver under 80% of its share where another delivers
  over it, as long as an attested leg clears its own floor. A last hop whose legs are all blind
  and that declares no figure has none to hold: the protocol floor is not armed and `userMinOut`
  is the only bound. `userMinOut` is read on what reaches the recipient and no declaration moves
  it, so it is the caller's bound inside the band as well. Where a leg of the last hop could not
  be quoted in frame, the figure the protocol floor is a fraction of carries that leg's attested
  figure, and where a leg is blind (neither quoted nor attested) the hop's declared figure when
  that is larger; `ExecutionProof.quoted` publishes the same figure, so that part of it is the
  caller's word, not a measurement, and is not reproducible by `eth_call` (the `ExecutionProof`
  NatSpec in `src/BlazePhoenixRouter.sol`).
  A leg of the last hop fed more than its plan (the bridge delivered more than hop 1 planned,
  and the Router keeps nothing) is held to its attested rate on all of it: when the rate it fills
  at falls more than a fifth below the attested one (a thin pool force-fed the surplus) it is
  refused with `RouterE(5)`, fail-closed; the caller keeps the input and a fresh quote sizes the
  leg on what arrives.
  Documented in `docs/assurance/threats.json` (`SOK-FOT`).
- **A buy of a token that taxes the venue-to-Router transfer settles only under the per-leg floor,
  the hop budget and the last hop's measured floor.** The first two take their base from the
  quote attestation, not from a venue, so they keep reading the measured delta: a tax and a venue
  shortfall are one observation to them. The last hop's measured floor reads the net the Router
  received against `LEG_FLOOR_BPS` (80%) of the hop's figure, so the tax and whatever the fill fell
  short of that figure share the same fifth. The tax settles while it stays inside the per-leg floor
  (`LEG_FLOOR_BPS`), the hop budget, which parallel legs share (less the slack the fill already
  used), and the last hop's measured floor; past them the Router refuses with `RouterE(5)`, which
  no quote preview can see in advance. Fail-closed: the caller keeps the
  input and pays the gas of a reverted transaction. Route such buys through one leg. A Gate leg's
  declaration is the Router's own measured delta, so on that leg the route floors read the net.
  Documented in `docs/assurance/threats.json` (`SOK-FOT`).
- **A token that taxes the Router-to-recipient transfer.** `userMinOut` is the caller's figure for
  what reaches the recipient and is never re-priced. A minimum derived from the quote's gross figure
  for such a token is refused; derive it from a simulated delivery instead (the swap entry points
  return the amount delivered, so an `eth_call` of the swap gives it). Documented in
  `docs/assurance/threats.json` (`SOK-FOT`).
- **The median band has two edges.** A venue priced above the base by more than the band's width
  (the fees and the probes' error bounds) is dropped like one priced below, even when it would pay
  more: that edge keeps a shallow venue with a marginal price that is too good out of the plan.
  Two honest venues away from rest (a stable pair skewed before arbitrage) therefore route
  through the deeper one alone. Pinned by `test_limit_ARowPricedAboveTheBandIsDropped`. The base
  is the depth-weighted median (`Math._wMedian`): moving it takes at least half of the rows' mass.
  A base that holds that mass and drops an honest venue h over the top leaves a round trip G open
  between h and itself, with 1 + G > 1 / (1 - f*) (f* the base's fee, counted twice at the upper
  edge), and the user's loss against h stays under 1 - (1 + G)^-3 <= 3G: hurting the user by L
  leaves at least L/3 to whoever closes the gap. A row dropped below loses nothing: its measured
  rate is under the base's. Derivation in `Math` (THE BAND); pinned by
  `testFuzz_ADropCostsTheUserUnderThreeTimesTheArbitrageAtTheBase`. Not bounded: the
  arbitrageur's gas.
- **A wrapper leg is priced only by its adapter's `quote` view** (`Core.gateQuote`). A wrapper
  without that view, or one whose walk cannot fill the whole input (the Liquidity Book and Algebra
  Integral adapters then answer 0), is quoted at 0 and gets no share of the order. This fails
  closed: a venue is never priced above what it fills.
- **A token's `balanceOf` is read as the token answers it** (`Core.heldBy`, the Router's
  concentrated-liquidity callback). A token that misreports its balances deceives the
  measurements of the legs that trade it; what it can take is from that token's own pairs.

## Out of scope

The full list is in [`SECURITY.md`](../SECURITY.md#out-of-scope). The entries most often reported:

- **Read-only figures that cannot change what a user signs:** statistics, the trade tape, the
  solvency badge, `/api/verify` (it returns what the chain answered), a preview without an
  executability verdict (`build_swap` refuses a route that cannot execute), and metadata or header
  consistency.
- **The victim's own device, wallet or RPC provider,** or a forged server answer delivered to a
  client: the SDK and the local MCP server run on the caller's own RPC.
- **Web and infrastructure hygiene without demonstrated impact:** CAA and other DNS records, headers
  and cookie flags, scanner notices. The site has no accounts, logins or passwords.
- **Gas optimisations, style and best-practice notes.**
- **Proofs of concept that do not exercise the real contracts.** Test on a fork of the deployed or
  published contracts; a PoC that re-implements them in mocks, and an unverified AI-generated
  report, are not reproductions.
