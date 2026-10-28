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
  the quote but at least the signed minimum is not a finding. Documented in
  `docs/assurance/threats.json` (`SOK-FOT`), `docs/WHITEPAPER.md` §5 (Fee-on-transfer) and the
  `ExecutionProof` NatSpec in `src/BlazePhoenixRouter.sol`.
- **Token metadata is data, not instructions.** The MCP server strips invisible, control,
  bidirectional and tag characters from every string it returns, caps token names and symbols, and
  tells the agent the text is data to show. Plain-language text that survives that cleaning cannot
  be filtered by meaning; text injection without impact is out of scope. Documented in
  `SECURITY.md` (Out of scope) and the MCP server's `src/text.ts`.

## Accepted and documented limits

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
