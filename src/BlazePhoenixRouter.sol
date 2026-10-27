// SPDX-License-Identifier: BUSL-1.1
// =============================================================================
//  BlazePhoenix Protocol — BlazePhoenixRouter
//  Version    : 2.0.0
//  Copyright  : (c) June 2026 – June 2030 BlazePhoenix Protocol
//  License    : Business Source License 1.1 (BUSL-1.1)
//               Change Date    : 2030-06-01
//               Change License : GPL-2.0-or-later
//
//  SINGLE RESPONSIBILITY
//      Execute a route that has already been decided. The Router does not choose
//      paths: it receives a plan, fulfils it leg by leg, and refuses to deliver
//      less than the floor — even if whoever submitted the plan would rather it
//      did not refuse.
//
//  WHAT THIS CONTRACT GUARANTEES
//      R1  IT HOLDS NOTHING. At the end of any call the Router's balance in any
//          token that moves the amount it is asked to move, and in native, is
//          zero. Four stateful invariants asserted in the suite defend this; it
//          is invariant M2 of the meta-equation. The one stated bound: a token
//          that keeps balances as shares and rounds each transfer down to whole
//          shares leaves fewer than k + d/n shares after k outbound transfers of
//          it in one settlement (d/n = shares per unit of balance), so at most
//          one share per outbound transfer while a share is worth at least one
//          unit. Every payout is measured against the balance at entry, so such
//          a crumb is never paid to a later swap. Register row: "Router balance
//          after settlement" in SHARED_QUANTITIES.md.
//      R2  IT GRANTS NO ALLOWANCE. No `approve` anywhere. The venues that
//          required one left the protocol — and with them left the only class
//          of residual-allowance bug this contract has ever had.
//      R3  THE FLOOR IS NOT OPTIONAL. The caller's attestation never RELAXES a
//          limit: where there is in-frame measurement, the floor is
//          `max(attested, measured)`. MAX and not MIN — on a floor, the minimum
//          against a deflated value returns the deflated value, which is exactly
//          the attack. An earlier design stated "measurement wins" and chose the
//          operator that guarantees the opposite.
//      R4  Authorisation is single-use. Classic and Permit2 enter through
//          separate doors (an EIP-7702 account uses the classic one) and none of
//          them leaves power behind.
//
//  WHAT THIS CONTRACT DELIBERATELY DOES NOT DO
//      It does not trust the `route.totalOut` that reaches it in calldata — it
//      treats it as a stranger's claim, because that is what it is. It does not
//      write to the registry when the floor rejects. And it has no execution
//      branch for kinds it does not know: it falls into the `else` and reverts
//      before touching a pool.
//
//  The Router executes a route leg by leg. A leg's kind selects the AMM
//  interaction shape, and the calldata is built by a single dispatcher
//  rather than per-DEX functions. The Router consists of:
//
//      • four entries: classic pull, Permit2, native ETH (wrapped once at
//        entry), and swapBestExactIn, which plans on-chain and pulls like the
//        classic entry
//      • one swap-callback fallback that handles every V3-shaped DEX
//      • one V4 unlock-and-settle sequence for PoolManager singletons
//      • a 0.28% protocol fee, charged once per route on the first registered
//        bridge coin the Router holds: the measured input of the first hop
//        whose input is a bridge, or the realised output of a direct swap into
//        a bridge. A route with no bridge input pays on every hop's measured
//        input. The fee is split 30/70 between two treasuries.
//
//  Each leg's output is computed via the Core quote dispatcher before the
//  on-chain swap, and the received amount is checked against the output
//  floor. Registry feedback (Hub.recordSwap) is sent only on the success
//  path, so no storage is written when the floor rejects.
// =============================================================================
pragma solidity 0.8.36;

import {
    BlazePhoenixCore as BPC,
    Route, Hop, Leg, RoutePlan
} from "./BlazePhoenixCore.sol";

interface ISolverR {
    function findBestRoutePlan(address tIn, address tOut, uint256 amountIn)
        external view returns (RoutePlan memory);
}

interface IHubW {
    function isBridgeToken(address t) external view returns (bool);
    function recordSwap(
        address pool, uint8 kind, uint24 fee, address hooks,
        address tA, address tB, uint256 amtIn, uint256 amtOut, uint256 depthWad
    ) external;
    function v4PoolManager() external view returns (address);
    function isHookLive(address hook) external view returns (bool);
    function hookPaused(address h) external view returns (bool);
    function bridge(uint8 i) external view returns (address);
}

interface IPermit2 {
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct TokenPermissions { address token; uint256 amount; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner, bytes calldata signature
    ) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IUniswapV3PoolMin {
    function swap(
        address recipient, bool zeroForOne, int256 amountSpecified,
        uint160 sqrtPriceLimitX96, bytes calldata data
    ) external returns (int256, int256);
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    struct V4PoolKey {
        address currency0; address currency1; uint24 fee;
        int24 tickSpacing; address hooks;
    }
    struct SwapParams {
        bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96;
    }
    function swap(
        V4PoolKey calldata key, SwapParams calldata params, bytes calldata hookData
    ) external returns (int256 balanceDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

contract BlazePhoenixRouter {

    string  public constant VERSION             = "2.0.0";

    /// @dev Treasury 1 takes 30% of the fee; treasury 2 takes the remainder (70%), computed as
    ///      `fee - t1` so the two always sum to exactly `fee` with no rounding dust left behind.
    ///      Deliberately NOT paired with a TREASURY2_SHARE constant: a second constant would be
    ///      dead (nothing could read it) and would silently drift into a lie the moment this one
    ///      changed.
    uint16  internal constant TREASURY1_SHARE   = 3_000;
    uint8   internal constant MAX_LEGS_PER_HOP  = 5;
    /// @dev The hop count had no producer at all (review 2026-09-02): legs were
    ///      bounded per hop and per route, hops were not. Three consequences,
    ///      none of them theft — `executedMask` silently stops crediting past
    ///      leg 255, the exhaustion-regime fee compounds once per hop with no
    ///      ceiling, and `bridgeBase` is sized by the caller. Three is the
    ///      deepest topology the Solver builds (`_planViaBridges`, two bridges).
    uint8   internal constant MAX_HOPS          = 3;
    /// @dev The gas `swapBestExactIn` hands the Solver for the in-transaction
    ///      search (review 2026-10-12). The search's cost is set by third
    ///      parties: one-wei V4 positions are permissionless, every fragmented
    ///      pool on the plan's reach costs at least one deep walk, and how many
    ///      are fragmented is the attacker's choice. No estimate made before
    ///      the search bounds that; a fixed budget that fails closed does.
    ///      Past it the door reverts RouterE(17): no funds move, and
    ///      `swapExactIn` with a plan quoted off-chain is unaffected. The
    ///      budget is not meant to choose the plan: no gas the caller brings
    ///      decides it. The Solver's capacity walk runs on its own fixed budget
    ///      (Solver.WALK_GAS) and a solve that cannot hand it that budget stops,
    ///      and a quote starved inside an exhausted search leaves its frame at
    ///      most 1/64 of the gas, so finishing on a thinner plan would need the
    ///      rest of the search to fit in what the parent frames kept; the fuzz
    ///      at and below the threshold (EntryBSolveBudget) finds no such budget.
    ///      12M for the search, as before the walk, plus WALK_GAS and the 1/64
    ///      the self-call keeps: what the search settled before, it settles
    ///      with the walk (test/CapacityWalkBudget.t.sol). 2^24 (EIP-7825) less
    ///      ~2.08M for the pull, the execution and the self-call.
    uint256 internal constant SOLVE_GAS         = 14_700_000;

    /// @notice Per-leg output floor, in BPS of the leg's pro-rata attested
    ///         quote. Bounds the damage any single manipulated / sandwiched
    ///         pool can inflict REGARDLESS of how loose the caller's aggregate
    ///         userMinOut is: each leg must deliver at least this fraction of
    ///         its own quote, rescaled to the input it actually spent. Raised
    ///         to 80% to match the aggregate hard floor (BlazePhoenixCore.
    ///         FLOOR_HARD_MAX_LOSS_BPS): the protocol runs across Ethereum L1
    ///         and multiple L2s where public mempools make single-pool
    ///         manipulation a live threat, so the per-leg guard is tightened
    ///         rather than left looser than the aggregate.

    /// @notice A1/MP-1: minimum fraction (BPS) of the MEASURED delivered output the
    ///         in-frame on-chain quote must cover to be trusted as the fee base.
    ///         Below this the quote is implausible (a forged V3 leg.fee near 1e6, or
    ///         a dead V4 leg, drives the quote toward 0), so the fee is charged
    ///         on the delivered amount instead — a low quote can never make the
    ///         protocol fee ~0 while real output is delivered. Honest swaps quote
    ///         ~= delivered (coverage ~100%).
    uint16  internal constant MIN_QUOTE_COVERAGE_BPS = 5_000;

    /// @notice LAYER 1 — AGGREGATE floor per hop, over the sum of the attested
    ///         quotes of the legs that carry one. It exists because the per-leg
    ///         floor is local while composition is global: an attacker holding
    ///         ONE leg out of L extracts ~20%·(L-1)/L without failing any floor,
    ///         and the legitimate guarantee of an H-hop route degrades to 0.8^H.
    ///         This is a composition defect — it exists with no hooks at all.
    ///         It does NOT replace or tighten BPC.LEG_FLOOR_BPS: a thin pool can
    ///         still fail 20% on its own (no new rigidity). It bounds only what
    ///         the WHOLE hop may bleed, and puts the attacker's leg INSIDE the
    ///         same sum — either it reverts, or it subsidises what it stole.
    /// The budget is NOT a fixed percentage: that would be rigid for small hops
    /// (a 1-leg hop delivering 85% passes the per-leg floor and would fail a 95%
    /// floor) and useless for large ones. It is derived — the hop may lose
    /// exactly what ONE AVERAGE leg could legitimately lose:
    ///     Σ got  ≥  Σ attested − (BPS − BPC.LEG_FLOOR_BPS)·(Σ attested / n)
    /// For L=1 it collapses EXACTLY onto the per-leg floor → zero new rigidity,
    /// by construction and not by calibration. The MEAN and not the MAX: under a
    /// max the attacker inflates their OWN leg to inflate the shared budget and
    /// drains the others — the derivation is at the guard itself.

    /// @notice Transient storage slots — used to pass per-swap context to
    ///         the universal callback fallback without dirtying state.
    uint256 private constant TSLOT_POOL  = uint256(keccak256("blaze.r.pool"));
    uint256 private constant TSLOT_TOKEN = uint256(keccak256("blaze.r.token"));
    uint256 private constant TSLOT_AMT   = uint256(keccak256("blaze.r.amt"));
    uint256 private constant TSLOT_V4IN  = uint256(keccak256("blaze.r.v4in"));
    uint256 private constant TSLOT_V4OUT = uint256(keccak256("blaze.r.v4out"));
    uint256 private constant TSLOT_LOCK  = uint256(keccak256("blaze.r.lock"));
    uint256 private constant TSLOT_FOT   = uint256(keccak256("blaze.r.fot"));
    // FEE LEDGER (2026-09-05). Counted by the one function that pays the protocol fee, read once
    // at the end of every settlement: a swap that delivers and did not pay is refused (15); in the
    // anchored regime a swap that paid twice is refused (16). The fee rule has one home; this is
    // the contract asserting it at run time, on every path, including paths that do not exist yet.
    uint256 private constant TSLOT_FEE   = uint256(keccak256("blaze.r.fee"));
    /// @dev Native-ETH receive() gate: holds the ONE address allowed to send
    ///      raw ETH to the Router at this instant (the canonical WETH during a
    ///      JIT unwrap, the V4 PoolManager during a native take), zero at
    ///      every other moment. Set/cleared around exactly one external call
    ///      each time — see unlockCallback's native seam and receive().
    uint256 private constant TSLOT_ETHOK = uint256(keccak256("blaze.r.ethok"));
    /// @dev Seed of the per-token transient counter of fee shares BOOKED AS OWED in this
    ///      transaction (`_push`). They stay in the Router, so every swap-path read of its own
    ///      balance (`_bal`) subtracts them: they are neither this call's input nor its output.
    uint256 private constant TSLOT_KEPT  = uint256(keccak256("blaze.r.kept"));
    /// @dev Gas a fee push may burn. A token that refuses the treasury (blacklist, `false`,
    ///      revert) or eats the gas costs the swap at most this, never the swap itself.
    uint256 private constant FEE_GAS     = 150_000;

    IHubW public immutable hub;
    address public immutable solver;
    /// @dev The address this code was deployed at. Immutables live in the code, so an EOA that
    ///      delegates to the Router (EIP-7702) reads the Router's address here while
    ///      address(this) is the EOA; `_execute` refuses that frame (RouterE(18)).
    address private immutable SELF = address(this);

    address public admin;
    address public treasury1;
    address public treasury2;
    /// @notice Fee shares a treasury slot could not take when its swap paid them
    ///         (`owed[token][0]` treasury1, `[1]` treasury2); the slot's CURRENT holder
    ///         pulls them with `claimFee`.
    mapping(address => uint256[2]) public owed;
    address public permit2;
    /// @notice The chain's canonical wrapped-native token (WETH9-shaped).
    ///         Zero until set by control: native-ETH entry is DISABLED by
    ///         default and fail-closed, so a chain where it was never wired
    ///         simply cannot take native input. Frozen by renounceControl like
    ///         every other control-set value.
    address public weth;
    bool    public paused;
    bool    public controlRenounced;

    event Swap(
        address indexed user, address indexed tokenIn, address indexed tokenOut,
        uint256 amountIn, uint256 amountOut, uint256 legs
    );
    /// @notice Verifiable proof of execution quality, emitted per swap.
    ///
    /// @dev    WHAT IT IS, and why it probably exists in no other aggregator: the REFERENCE quote
    ///         is produced by consensus IN THE SAME FRAME as the execution, and published as an
    ///         on-chain series. In every other one the quote is an off-chain artefact — what
    ///         survives on chain is the `minOut`, and execution quality is reconstructed by third
    ///         parties from external data. Here the benchmark is ENDOGENOUS: anyone re-runs
    ///         `findBestRoutePlan` (view) by eth_call at that block and gets the same number. It
    ///         was the economic constraint (zero servers, zero paid RPC) that pushed the solver
    ///         on chain; the proof fell out as a by-product.
    ///
    ///         WHAT EACH FIELD IS, WITHOUT OVER-CLAIMING — and the three caveats stay glued to
    ///         the claim above, otherwise it turns into propaganda:
    ///         · `user` is the PAYER, not the `msg.sender`. In `swapBestExactIn` this is reached
    ///           by a self-call and `msg.sender` is the Router itself; until 2026-08-21 the series
    ///           was emitted with no owner at exactly the door that makes it unique.
    ///         · `quoted` is the `finalHopQuote` — the quote of the LAST hop, not of the route. On
    ///           a multi-hop route the comparison with `realized` is in the right units but does
    ///           NOT measure the quality of the earlier hops. This proves the last leg; it does
    ///           not prove the route.
    ///         · `realized` is what was delivered, MEASURED at the recipient, after anything cut
    ///           on the way out (the output-side fee where it applies, a transfer tax).
    ///         · `floorUsed` is the floor that had to be beaten, checked before those cuts and
    ///           published net of a transfer tax on tokenOut (scaled by realized / amount sent).
    ///           With no output-side fee it never exceeds `realized` on a settled swap; where
    ///           that fee applies it stays in the units the Solver attests the floor in.
    event ExecutionProof(
        address indexed user, address indexed tokenOut,
        uint256 quoted, uint256 realized, uint256 floorUsed, uint256 blockNumber
    );
    event Fee(address indexed token, uint256 amount, uint256 toT1, uint256 toT2);
    event Cfg(uint8 id, address who);
    /// @notice The emergency switch changed. Its own event, and not a `Cfg` carrying an address
    ///         fabricated from a bool: a flag is not an address, and stuffing it into an address
    ///         field to save bytes would force every indexer to know about the lie.
    event PausedSet(bool paused);

    error RouterE(uint16 code);
    // 1 = unauthorized, 2 = paused, 3 = bad input, 4 = deadline,
    // 5 = slippage, 6 = callback auth, 7 = reentrancy, 8 = swap failed,
    // 9 = disallowed V4 hook, 10 = userMinOut == 0 with amountIn > 0 (BP-04),
    // 11 = a V4 leg's fields disagree: its direction is not the direction of its tokens, or the pool it names (leg.pool) is not the pool its key derives to (BPX-2026-009),
    // 13 = FoT token on a V3-only route (route-where-natural), 14 = rescue
    // not queued or still inside the 48h timelock, 15 = a swap settled without
    // paying the protocol fee, 16 = the fee was paid twice on an anchored route,
    // 17 = the in-transaction search of swapBestExactIn ran out of SOLVE_GAS,
    // 18 = the swap executes at an address other than the Router's own (an EIP-7702 delegation)
    // 20 = a leg's measured delta exceeds what its venue declared it paid (DEX-11)

    // Every privileged door in this contract is gated by onlyControl, so all
    // administrative power ends permanently at renounceControl(). Keep it that
    // way: a door added under any weaker modifier would outlive renunciation.
    // Control powers (treasuries, permit2, pause, admin transfer) are disabled
    // forever once renounceControl() is called.
    modifier onlyControl() { if (msg.sender != admin || controlRenounced) revert RouterE(1); _; }
    modifier whenLive()  { if (paused) revert RouterE(2); _; }
    modifier nrEntrant() {
        uint256 s = TSLOT_LOCK;
        uint256 v; assembly { v := tload(s) }
        if (v != 0) revert RouterE(7);
        assembly { tstore(s, 1) }
        _;
        assembly { tstore(s, 0) }
    }

    constructor(address hub_, address solver_, address admin_, address t1, address t2) {
        if (hub_ == address(0) || solver_ == address(0) || admin_ == address(0)) revert RouterE(3);
        hub      = IHubW(hub_);
        solver   = solver_;
        admin    = admin_;
        treasury1 = t1 == address(0) ? admin_ : t1;
        treasury2 = t2 == address(0) ? admin_ : t2;
        permit2   = BPC.PERMIT2_DEFAULT;
    }

    // ─── Admin (compacted) ────────────────────────────────────────────

    function setAdmin(address a)            external onlyControl { if(a==address(0))revert RouterE(3); admin=a; emit Cfg(0,a); }
    function setTreasuries(address t1, address t2) external onlyControl {
        if (t1==address(0)||t2==address(0)) revert RouterE(3);
        treasury1=t1; treasury2=t2; emit Cfg(1,t1); emit Cfg(2,t2);
    }
    /// @dev A treasury moves its own slot, also after renounceControl. Every swap whose
    ///      fee token blacklists a treasury reverts in `_payFee`, and with control
    ///      renounced nobody else could move it (bounty #55, mastermindran). The payee
    ///      only ever redirects its own share; one address in both slots moves t1 first.
    function moveTreasury(address to) external {
        if (to==address(0)) revert RouterE(3);
        if (msg.sender==treasury1) { treasury1=to; emit Cfg(1,to); }
        else if (msg.sender==treasury2) { treasury2=to; emit Cfg(2,to); }
        else revert RouterE(1);
    }
    /// @notice A slot's holder pulls the fees its slot was owed (seal 2026-10-21). The fee is
    ///         pushed in the swap; a push the token refuses is booked here instead of reverting
    ///         the swap, so neither a treasury nor an issuer's blacklist can stop a fee token
    ///         from trading. The slot, not the address, is owed: a moved slot claims it all.
    function claimFee(address token) external nrEntrant {
        uint256 a;
        if (msg.sender == treasury1) { a = owed[token][0]; owed[token][0] = 0; }
        if (msg.sender == treasury2) { a += owed[token][1]; owed[token][1] = 0; }
        if (a == 0) revert RouterE(1);
        // What leaves is no longer kept: a later swap of this transaction must not subtract it.
        uint256 s = _keptSlot(token);
        assembly { let k := tload(s) tstore(s, mul(gt(k, a), sub(k, a))) }
        BPC.safeTransfer(token, msg.sender, a);
    }
    function setPermit2(address p)          external onlyControl { permit2=p; emit Cfg(3,p); }
    function setWeth(address w)             external onlyControl { weth=w; emit Cfg(4,w); }
    function setPaused(bool b)              external onlyControl { paused=b; emit PausedSet(b); }

    /// @notice Permanently surrender every control power. Treasuries, the
    ///         Permit2 address, the pause flag and admin transfer are frozen at
    ///         their current values forever. The Router keeps executing swaps
    ///         under that fixed configuration. Irreversible.
    function renounceControl() external onlyControl {
        // REFUSED WHILE PAUSED, and the reason is that the resulting state is
        // one nobody wants and nobody can leave. `whenLive` gates all four
        // doors, and every thaw path is `onlyControl` — which this call is
        // about to kill. Paused-then-renounced is therefore terminal: no swap
        // ever settles again and no key can undo it.
        // There is no legitimate use for it either. Ossifying a LIVE protocol
        // leaves users able to trade through it forever, which is the point.
        // Pausing during an incident is worth doing precisely because control
        // is retained to migrate; renouncing at that moment discards the
        // capability the pause was bought to use.
        if (paused) revert RouterE(2);
        controlRenounced = true;
        emit Cfg(0, address(0));
    }

    // ─── Rescue (48h timelock) ────────────────────────────────────────
    // The Router holds no user funds at rest (every swap settles or reverts in
    // its own frame; fees stream to the treasuries), so rescue only ever moves
    // accidental direct sends. It grants the admin NO new power (setTreasuries
    // already redirects value) — the 48h delay + events exist so any rescue is
    // publicly observable before it can execute. Dies with renounceControl,
    // like every other control power: renounce means renounce.

    uint256 private constant RESCUE_DELAY = 48 hours;
    mapping(bytes32 => uint256) public rescueEta;

    event RescueQueued(address indexed token, address indexed to, uint256 eta);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    function queueRescue(address token, address to) external onlyControl {
        if (to == address(0)) revert RouterE(3);
        uint256 eta = block.timestamp + RESCUE_DELAY;
        rescueEta[keccak256(abi.encodePacked(token, to))] = eta;
        emit RescueQueued(token, to, eta);
    }

    function cancelRescue(address token, address to) external onlyControl {
        delete rescueEta[keccak256(abi.encodePacked(token, to))];
        emit RescueQueued(token, to, 0);
    }

    function executeRescue(address token, address to) external onlyControl {
        bytes32 k = keccak256(abi.encodePacked(token, to));
        uint256 eta = rescueEta[k];
        if (eta == 0 || block.timestamp < eta) revert RouterE(14);
        delete rescueEta[k];
        // Owed fees are the treasuries', not a stray balance: the rescue returns the rest.
        uint256 amt = BPC.balanceOf(token, address(this));
        uint256 o = owed[token][0] + owed[token][1];
        amt = amt > o ? amt - o : 0;
        if (amt > 0) BPC.safeTransfer(token, to, amt);
        emit Rescued(token, to, amt);
    }

    // =========================================================================
    //  ENTRY POINTS — three auth schemes, one execution core
    // =========================================================================

    /// @notice Classic exact-input swap. User pre-approves the Router.
    /// @dev    userMinOut is the PRIMARY slippage guard — derive it from a
    ///         fresh quote (Quoter.previewPlanExact) on every call. BP-04:
    ///         passing 0 with a non-zero amountIn REVERTS (RouterE(10)) in
    ///         all three entry points — the protocol floors alone (hard-
    ///         capped at 25% below the attested quote per leg, 20% below
    ///         the realised total in aggregate) only BOUND sandwich loss,
    ///         they do not eliminate it, so a real bound is mandatory.
    ///         I8 (idempotence) is preserved: the guard is conditioned on
    ///         amountIn > 0, so a zero-amount call never reverts solely
    ///         because userMinOut is 0.
    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) external whenLive nrEntrant returns (uint256) {
        return _checkedSwap(route, amountIn, userMinOut, recipient, deadline);
    }

    /// @dev Shared entry checks + core swap for the classic entry, which an
    ///      EIP-7702 account also uses (the former 7702 alias was folded into it
    ///      to keep the Router inside the EIP-170 safety margin).
    function _checkedSwap(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) private returns (uint256) {
        if (amountIn > type(uint128).max) revert RouterE(3);
        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        return _swap(route, amountIn, userMinOut, recipient, deadline);
    }

    /// @notice Permit2 SignatureTransfer — zero standing allowance.
    function swapExactInWithPermit2(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline,
        IPermit2.PermitTransferFrom calldata permit, bytes calldata signature
    ) external whenLive nrEntrant returns (uint256) {
        if (amountIn > type(uint128).max) revert RouterE(3);
        if (amountIn > 0 && userMinOut == 0) revert RouterE(10);
        if (permit.permitted.amount < amountIn) revert RouterE(3);
        // Measure the actual receive around the Permit2 pull, exactly like the
        // classic path does around safeTransferFrom: fee-on-transfer tokens
        // deliver less than requested, and executing on the nominal amountIn
        // would make hop-0 push more than the Router holds. Work with what was
        // actually received. (The hops-length check moves up so an empty route
        // still reverts RouterE(3) — now BEFORE tokens move, not after.)
        if (route.hops.length == 0) revert RouterE(3);
        address tokenIn = route.hops[0].tokenIn;
        // The signed token IS the route's input, by construction. The pull below is measured on
        // `tokenIn`, so a permit for any other token already credits nothing and reverts
        // (RouterE(8)); this binds the signature to the route before anything moves, instead of
        // through a balance side effect (hardening prompted by Karan Rathod, bug bounty).
        if (permit.permitted.token != tokenIn) revert RouterE(3);
        uint256 balBefore = BPC.balanceOf(tokenIn, address(this));
        IPermit2(permit2).permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({ to: address(this), requestedAmount: amountIn }),
            msg.sender, signature
        );
        uint256 received = BPC.balanceOf(tokenIn, address(this)) - balBefore;
        if (received == 0) revert RouterE(8);
        // FOT-01: THE PULL IS A MEASURED TRANSFER TOO. The leg loop marks
        // TSLOT_FOT when the Router->pool transfer delivers less (see
        // `_execPairAmt`), but the INPUT pull measured here never marked it. On
        // an ASYMMETRICALLY taxed token — taxes transferFrom, exempts transfer,
        // or exempts the pool — no leg sees a discrepancy, `fotSeen` stays at
        // zero, and the floor block applies `route.singleOutFloor` exactly as it
        // came from the plan: sized for the NOMINAL amountIn, against an output
        // produced from `received`. The honest swap died in RouterE(5).
        // (On a token that taxes EVERY transfer the loop already caught it —
        // which is why the defect is of this subclass, not of all FoT.)
        // #45 (babayagaleet): a pull never delivers more than was asked. A surplus is a token
        // restating balances the Router already held (rebase/reflection inside transferFrom),
        // and counting it as received would sweep that foreign balance to the payer.
        if (received > amountIn) received = amountIn;
        else if (received != amountIn) _noteFot(BPC.mulDiv(received, BPC.BPS, amountIn));
        // Tokens are now on the Router; skip the user-pull in the core path.
        return _swapPrePulled(route, received, userMinOut, recipient, deadline, msg.sender);
    }

    // EIP-7702 needs no dedicated entry point: under 7702 the EOA delegates
    // code to itself, so `msg.sender` is still the EOA and `swapExactIn`'s
    // classic pull path already works unchanged. The former swapExactInWith7702
    // was a byte-identical alias that saved nothing on its own (the 7702 gain
    // is the tx structure — bundling approve+swap — not the function); it was
    // removed to reclaim EIP-170 headroom. 7702 integrators call swapExactIn.

    /// @notice Native-ETH entry: wraps `msg.value` into the chain's canonical
    ///         WETH and routes it, so a user never has to pre-wrap.
    ///
    /// @dev    Why this does NOT reopen the msg.value double-spend a closed ETH
    ///         surface guards against: the value is wrapped EXACTLY ONCE, at
    ///         entry, into a measured WETH balance, and everything downstream
    ///         works on that ERC20 amount — msg.value is never read again, and
    ///         this Router exposes no multicall/batch surface that could replay
    ///         a single msg.value across several swaps. The fallback rejects
    ///         bare ETH (RouterE(3)), and receive() accepts ETH only from the
    ///         one address a native-V4 unlock arms for that instant (see
    ///         receive()), so a user's ETH can only ever enter through this one
    ///         accounted path.
    ///         Fail-closed when `weth` was never wired (RouterE(3)).
    ///         Native OUTPUT is deliberately not implemented: the recipient
    ///         receives WETH, which no swap path can silently trap.
    function swapExactInNative(
        Route calldata route, uint256 userMinOut, address recipient, uint256 deadline
    ) external payable whenLive nrEntrant returns (uint256) {
        address w = weth;
        if (w == address(0)) revert RouterE(3);              // native entry not wired
        uint256 amountIn = msg.value;
        if (amountIn == 0 || amountIn > type(uint128).max) revert RouterE(3);
        if (userMinOut == 0) revert RouterE(10);
        if (route.hops.length == 0) revert RouterE(3);
        if (route.hops[0].tokenIn != w) revert RouterE(3);   // route must start in WETH

        // Wrap once and work with the MEASURED balance delta, the same
        // discipline the ERC20 paths use around their pulls.
        uint256 balBefore = BPC.balanceOf(w, address(this));
        IWETH(w).deposit{value: amountIn}();
        uint256 received = BPC.balanceOf(w, address(this)) - balBefore;
        if (received == 0) revert RouterE(8);

        return _swapPrePulled(route, received, userMinOut, recipient, deadline, msg.sender);
    }

    // ─── Fully-on-chain route: solve + execute in ONE transaction ─────────

    /// @notice Self-contained exact-input swap — the philosophy entry point:
    ///         the route is found by the on-chain Solver INSIDE this same
    ///         transaction. The caller supplies only (tokenIn, tokenOut,
    ///         amountIn, userMinOut, recipient, deadline); no plan enters
    ///         from outside, so there is no quote-vs-execution seam at all —
    ///         solve and execution read the same block state, atomically.
    /// @dev    Costs the solve on top of execution (L2-cheap; the calldata-
    ///         plan entry points remain the gas-lean path). userMinOut stays
    ///         MANDATORY (BP-04): in-tx solving removes plan staleness, not
    ///         sandwich exposure — the tx can still be ordered behind an
    ///         attacker's. The Solver returns `Route memory` while the
    ///         execution core is calldata-typed for the hot path, so the plan
    ///         crosses via an external SELF-call (`selfExecutePrePulled`),
    ///         which re-encodes memory→calldata. The pull happens HERE, in
    ///         the caller's own context, because inside the self-call
    ///         msg.sender is the Router, not the user.
    function swapBestExactIn(
        address tokenIn, address tokenOut, uint256 amountIn,
        uint256 userMinOut, address recipient, uint256 deadline
    ) external whenLive nrEntrant returns (uint256) {
        if (amountIn == 0 || amountIn > type(uint128).max) revert RouterE(3);
        if (userMinOut == 0) revert RouterE(10);
        // deadline + empty-route re-checked inside _swapPrePulled — not here
        // (dedupe law: same tx, same state, never pay twice — in bytecode too).
        RoutePlan memory plan = _solve(tokenIn, tokenOut, amountIn);
        // Both ends of the plan are checked (review 2026-09-02): the input end
        // guarded the pull; the OUTPUT end guards what the recipient receives
        // and the units `userMinOut` is compared in. The Solver is immutable
        // and this is the one door where the route is not the caller's, so
        // the belt is cheap and the sibling asymmetry was the only reason it
        // was missing.
        if (
            plan.best.hops.length == 0 || plan.best.hops[0].tokenIn != tokenIn
                || plan.best.hops[plan.best.hops.length - 1].tokenOut != tokenOut
        ) revert RouterE(3); // fail-closed
        uint256 balBefore = BPC.balanceOf(tokenIn, address(this));
        BPC.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 received = BPC.balanceOf(tokenIn, address(this)) - balBefore;
        if (received == 0) revert RouterE(8);
        // FOT-01: THE PULL IS A MEASURED TRANSFER TOO. The leg loop marks
        // TSLOT_FOT when the Router->pool transfer delivers less (see
        // `_execPairAmt`), but the INPUT pull measured here never marked it. On
        // an ASYMMETRICALLY taxed token — taxes transferFrom, exempts transfer,
        // or exempts the pool — no leg sees a discrepancy, `fotSeen` stays at
        // zero, and the floor block applies `route.singleOutFloor` exactly as it
        // came from the plan: sized for the NOMINAL amountIn, against an output
        // produced from `received`. The honest swap died in RouterE(5).
        // (On a token that taxes EVERY transfer the loop already caught it —
        // which is why the defect is of this subclass, not of all FoT.)
        // #45 (babayagaleet): a pull never delivers more than was asked. A surplus is a token
        // restating balances the Router already held (rebase/reflection inside transferFrom),
        // and counting it as received would sweep that foreign balance to the payer.
        if (received > amountIn) received = amountIn;
        else if (received != amountIn) _noteFot(BPC.mulDiv(received, BPC.BPS, amountIn));
        // TSLOT_FOT is TRANSIENT storage on the Router's account, so it survives
        // the external self-call below (same transaction, same account).
        return this.selfExecutePrePulled(plan.best, received, userMinOut, recipient, deadline, msg.sender);
    }

    /// @dev The search of `swapBestExactIn`, on a fixed budget (SOLVE_GAS).
    ///      Empty revert data is the out-of-gas signature: the Solver, Core
    ///      and Hub never revert without data, so it reads as RouterE(17).
    ///      Every other revert passes through with its bytes unchanged.
    function _solve(address tokenIn, address tokenOut, uint256 amountIn)
        private view returns (RoutePlan memory plan)
    {
        try ISolverR(solver).findBestRoutePlan{gas: SOLVE_GAS}(tokenIn, tokenOut, amountIn) returns (RoutePlan memory p) {
            plan = p;
        } catch (bytes memory e) {
            if (e.length == 0) revert RouterE(17);
            // memory-safe: only reads the revert data Solidity just copied
            // into `e`, then leaves the frame. Without the annotation the
            // compiler drops its memory guard for the whole contract.
            assembly ("memory-safe") { revert(add(e, 32), mload(e)) }
        }
    }

    /// @notice memory→calldata bridge for `swapBestExactIn`. Self-only
    ///         (RouterE(1)) and deliberately NOT nrEntrant — the outer entry
    ///         already holds the transient lock, so a guarded inner would
    ///         always trip RouterE(7).
    function selfExecutePrePulled(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline, address payer
    ) external returns (uint256) {
        if (msg.sender != address(this)) revert RouterE(1);
        return _swapPrePulled(route, amountIn, userMinOut, recipient, deadline, payer);
    }

    // =========================================================================
    //  CORE EXECUTION
    // =========================================================================

    function _swap(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline
    ) private returns (uint256) {
        if (block.timestamp > deadline) revert RouterE(4);
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn  = route.hops[0].tokenIn;
        // Measure the actual receive against the requested pull. Fee-on-
        // transfer / deflationary tokens deliver less than they advertise; we
        // work with what was actually received.
        uint256 balBefore = BPC.balanceOf(tokenIn, address(this));
        BPC.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        uint256 received = BPC.balanceOf(tokenIn, address(this)) - balBefore;
        if (received == 0) revert RouterE(8);
        // FOT-01: THE PULL IS A MEASURED TRANSFER TOO. The leg loop marks
        // TSLOT_FOT when the Router->pool transfer delivers less (see
        // `_execPairAmt`), but the INPUT pull measured here never marked it. On
        // an ASYMMETRICALLY taxed token — taxes transferFrom, exempts transfer,
        // or exempts the pool — no leg sees a discrepancy, `fotSeen` stays at
        // zero, and the floor block applies `route.singleOutFloor` exactly as it
        // came from the plan: sized for the NOMINAL amountIn, against an output
        // produced from `received`. The honest swap died in RouterE(5).
        // (On a token that taxes EVERY transfer the loop already caught it —
        // which is why the defect is of this subclass, not of all FoT.)
        // #45 (babayagaleet): a pull never delivers more than was asked. A surplus is a token
        // restating balances the Router already held (rebase/reflection inside transferFrom),
        // and counting it as received would sweep that foreign balance to the payer.
        if (received > amountIn) received = amountIn;
        else if (received != amountIn) _noteFot(BPC.mulDiv(received, BPC.BPS, amountIn));
        return _execute(route, received, userMinOut, recipient, tokenIn, msg.sender);
    }

    function _swapPrePulled(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, uint256 deadline, address payer
    ) private returns (uint256) {
        if (block.timestamp > deadline) revert RouterE(4);
        if (route.hops.length == 0 || amountIn == 0) revert RouterE(3);
        address tokenIn = route.hops[0].tokenIn;
        return _execute(route, amountIn, userMinOut, recipient, tokenIn, payer);
    }

    /// @notice The fee for hop `h`, charged in THAT hop's token.
    ///
    /// @dev WHY IN THE MIDDLE AND NOT AT AN END — and this is the result that cost two attempts.
    ///      A route is a path with TWO ends, and both are coordinates written by the caller.
    ///      Any fee anchored at ONE end is evaded by extending the route past that end with a
    ///      worthless token:
    ///        · anchored at the OUTPUT -> dust suffix. MEASURED: 996 tokens moved, zero fee.
    ///        · anchored at the INPUT  -> dust prefix. MEASURED: the attacker prefixes with a token
    ///          they minted, pays 0.028 of junk, and receives MORE than the honest user.
    ///        · anchored at hop k      -> insert k hops of dust before it.
    ///      And "the route as its own oracle" does not save it: converting each hop to final units
    ///      by the route's own quotes TELESCOPES (in_{j+1} == q_j), so every hop maps to the SAME
    ///      number — which is precisely what the dust hop controls.
    ///      PROVEN NEGATIVE RESULT: with no external price, NO single anchor is immune. And an
    ///      external price is out by the owner's decision (zero oracles).
    ///
    ///      WHY THIS WAS CALLED IMMUNE, by exhaustion: the attacker can fabricate worthless
    ///      tokens and can append hops, but CANNOT stop the route from crossing the REAL liquidity
    ///      pool they want to use — and on that hop they pay the full rate, in that hop's real
    ///      token. The dust hops start COSTING them (junk rate to the treasury, plus gas) instead
    ///      of saving them. The incentive inverts.
    ///
    ///      THE RESIDUAL THAT SENTENCE MISSED (review 2026-09-02, measured in
    ///      test/FeeAnchorValueInjectingPrefix.t.sol): the exhaustion above only considered prefixes
    ///      WITHOUT value. The anchor is "the first hop whose INPUT is a bridge coin" (see the fee
    ///      block in `_execute`). A hop-0 that spends 2 wei of WETH through a pair the attacker
    ///      wrote — one that pays out USDC the attacker funded it with — IS that hop: the fee is
    ///      charged on 2 wei, and the real pool on hop 1 is crossed with the attacker's own USDC
    ///      fee-free. No user is harmed; the treasury loses the rate on that trade. The cost to the
    ///      evader is one contract and one extra hop of gas per trade, against the alternative they
    ///      already have of calling the pool directly and paying nothing — so the leak is bounded
    ///      by the value of the Router's own guarantees to them. There is no anchor immune to it
    ///      without a price (the negative result above stands); the only immune rule is
    ///      charge-on-every-hop, which the owner rejected on 2026-08-22 for doubling the honest
    ///      two-hop cost. The rate rule is therefore the owner's decision; until it changes, the
    ///      leak is an ACCEPTED, MEASURED residual, and the test that measures it must flip the day
    ///      the rule does.
    ///
    ///      AND IT IS THE SAME MOVE THETA MADE ON THE KINDS: what was an attribute of an END chosen
    ///      by the caller becomes an invariant of TRANSIT, traversed by the execution. The fee stops
    ///      being a coordinate and becomes a property of the path.
    ///
    ///      THE BASE IS MEASURED, NOT DECLARED. On hop 0 it is the minimum of what the Router
    ///      received and what the route COMMITS (declaring smaller legs routes less — `scaleNum` is
    ///      capped at `scaleDen`, so there is no gain in under-declaring). On later hops it is the
    ///      REAL balance of that token minus the foreign baseline — the same number the scaling
    ///      already uses. Zero new staticcalls: both quantities were already read.
    ///
    ///      THE COST, stated where it is decided: an honest H-hop route pays ~H times the rate.
    ///      With this design's 2-hop budget, the honest worst case is double. The minimum charged
    ///      is ALWAYS the full rate on the value moved — never less, which was the condition.
    /// @dev THE ONE PRODUCER of "how much does this hop commit?" — the sum of its legs' declared
    ///      inputs. The fee base at hop 0 and the scale denominator read this same function; before
    ///      2026-09-05 each summed the legs in its own loop, which is two producers of one number
    ///      and the defect signature this codebase names first.
    function _legSum(Hop calldata hop) private pure returns (uint256 c) {
        for (uint256 i; i < hop.legs.length; ) { c += hop.legs[i].amountIn; unchecked { ++i; } }
    }

    function _chargeHopFee(Hop calldata hop, uint256 h, uint256 amountIn, uint256 foreignBase)
        private returns (uint256)
    {
        uint256 baseH;
        if (h == 0) {
            // `amountIn` here is the MEASURED pull (every door hands `_execute` its balance
            // delta), capped by what the route commits — the same cap the scale applies.
            baseH = amountIn;
            uint256 c = _legSum(hop);
            if (c < baseH) baseH = c;
        } else {
            uint256 bal = _bal(hop.tokenIn);
            baseH = bal > foreignBase ? bal - foreignBase : 0;
        }
        // ROUND UP, NEVER DOWN. With floor division mulDiv(b, 28, 10_000) is 0
        // for every b <= 357, and the early return below then waved the swap
        // through fee-free: a delivered swap that paid the protocol nothing.
        // The threshold is in WEI, so its real size is set by the token's
        // decimals (3.58 tokens at 2 decimals, 358 at 0) — refusing those
        // trades was the wrong cure. Rounding up makes a zero fee unreachable
        // for any non-zero base instead, so nothing legitimate is refused.
        // The guard below now means only "there is no base to charge".
        uint256 feeH = BPC.mulDivUp(baseH, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
        if (feeH == 0) return amountIn;
        _payFee(hop.tokenIn, feeH);
        // Only hop 0 spends the `amountIn` travelling in the frame; the later ones read the
        // balance, which the fee transfer has already reduced.
        if (h != 0) return amountIn;
        if (feeH >= amountIn) revert RouterE(8);
        unchecked { return amountIn - feeH; }
    }

    /// @dev The 30/70 split in its own frame: under via_ir `_execute` sits at the stack limit,
    ///      and two locals (t1, t2) declared inside it are enough to blow it.
    function _payFee(address token, uint256 fee) private {
        uint256 sFee = TSLOT_FEE;
        uint256 paid; assembly { paid := tload(sFee) }
        assembly { tstore(sFee, add(paid, 1)) }
        uint256 t1 = BPC.mulDiv(fee, TREASURY1_SHARE, BPC.BPS);
        uint256 t2 = fee - t1;
        if (t1 > 0) _push(token, 0, treasury1, t1);
        if (t2 > 0) _push(token, 1, treasury2, t2);
        emit Fee(token, fee, t1, t2);
    }

    /// @dev One slot's share, pushed with capped gas. A push the token refuses (blacklisted
    ///      payee, `false`, revert, gas burnt) does not revert the swap (the fee DoS a slot
    ///      holder or an issuer could cause): the share is booked to the slot (`owed`) and
    ///      stays in the Router, counted in TSLOT_KEPT so no read of this transaction sees it
    ///      as a swap's balance. The fee is charged either way: every rule that counts it
    ///      (amountIn - fee, TSLOT_FEE) is unchanged.
    ///      BOOKED BY THE DELTA, NOT BY THE ANSWER: a token may move the share and still answer
    ///      in a shape Core reads as a refusal (`false`, an oversized word). Only what did not
    ///      leave the Router is booked, so a claim never pays a share twice.
    function _push(address token, uint256 i, address to, uint256 amt) private {
        uint256 b0 = BPC.balanceOf(token, address(this));
        if (BPC.tryTransfer(token, to, amt, FEE_GAS)) return;
        uint256 b1 = BPC.balanceOf(token, address(this));
        uint256 gone = b0 > b1 ? b0 - b1 : 0;
        if (gone >= amt) return;
        unchecked { amt -= gone; }
        owed[token][i] += amt;
        uint256 s = _keptSlot(token);
        assembly { tstore(s, add(tload(s), amt)) }
    }

    function _keptSlot(address token) private pure returns (uint256 s) {
        s = TSLOT_KEPT;
        assembly ("memory-safe") { mstore(0, token) mstore(32, s) s := keccak256(0, 64) } // scratch space only
    }

    /// @dev The Router's own balance of `t` as a swap may see it: the raw balance less the fee
    ///      shares booked as owed in this transaction. Every swap-path self-balance read goes
    ///      through here - the entry baselines too, so a second swap in the same transaction
    ///      measures against the same coordinate. Owed fees from earlier transactions are part
    ///      of the entry baseline like any balance the Router held before the call.
    function _bal(address t) private view returns (uint256 b) {
        b = BPC.balanceOf(t, address(this));
        uint256 s = _keptSlot(t);
        assembly { let k := tload(s) b := mul(gt(b, k), sub(b, k)) }
    }

    /// @notice Per-hop real-balance-ratio scaling AND price impact (BPS) AND
    ///         the on-chain quote for the legs as actually executed, all
    ///         computed in one pass so V2/Solidly reserves and V3/Algebra
    ///         sqrtPrice+liquidity are read once and reused — zero extra
    ///         staticcalls for the two dominant leg kinds. Merged with the
    ///         scale computation (rather than two separate functions) so the
    ///         intermediate realIn/quotedIn values never need to live in
    ///         _execute's own frame between two calls — via-IR inlines small
    ///         private functions back into their single call site, and two
    ///         separate calls each pushed the combined stack 1 slot too deep.
    ///
    ///         Scaling: every leg's planned share is rescaled against how
    ///         much of hop.tokenIn the Router ACTUALLY has available
    ///         (scaleNum) versus how much the Solver's plan assumed it would
    ///         have (scaleDen = sum of this hop's leg.amountIn). For hop 0,
    ///         scaleNum is the amountIn parameter itself — already measured
    ///         via one balance-delta in _swap (covers a fee-on-transfer
    ///         tokenIn without a second staticcall). For hop 1+, scaleNum is
    ///         a fresh balanceOf() of the bridge token actually received
    ///         from the previous hop (covers that hop's own slippage).
    ///
    ///         The quote return feeds the fee-base re-derivation in _execute
    ///         (see "Fee base" below): it replaces the caller-supplied,
    ///         unverified route.totalOut, so a crafted Route can no longer
    ///         understate its own quote to shrink the protocol's fee base.
    ///         The V4 branch reads the PoolManager using the exact same key
    ///         construction execution uses, so it cannot diverge from what
    ///         actually settles — if auxId is wrong
    ///         the leg fails identically in both places.
    /// @dev `legQuotes` comes back filled with each leg's quote MEASURED in-frame, at the
    ///      `legAmt` amount this function used to price it. Until now these quotes were summed
    ///      into `quoteAcc` and the per-leg value THROWN AWAY — the gas to measure them was
    ///      already paid and the measurement served as nobody's floor. It is what feeds the
    ///      coverage gate in `_execScaled`. Length = the hop's leg count; zero means "no
    ///      measurement", and the gate fails OPEN in that case.
    /// @dev A leg's impact, weighted by its SHARE of the hop.
    ///
    ///      Impact is a RATIO — amountIn/(reserveIn+amountIn) — so it is blind to
    ///      how much value a leg actually carries. A one-wei leg against a
    ///      dust-reserve pool scores near 100%. The route's floor then averaged
    ///      those ratios UNWEIGHTED, and `ironFloorBps` SUBTRACTS impact, so
    ///      padding a route with such legs walked the floor down from 96% toward
    ///      its 80% clamp while the real trade sat in one honest deep leg. The
    ///      caller writes the Route, so that lever was theirs.
    ///
    ///      Weighting by `leg.amountIn / scaleDen` (the leg's share of the hop's
    ///      declared input) is self-consistent: the same field decides how much
    ///      the leg actually spends, so a caller cannot buy weight without
    ///      routing the value. The `* legs` normalisation makes equal-sized legs
    ///      reproduce the previous unweighted sum EXACTLY — the shares are then
    ///      1/legs each — so honest routes do not move, and the division by
    ///      `totalLegs` downstream is left untouched.
    ///
    ///      The clamp mirrors `ironFloorBps`, which caps impact at BPS anyway;
    ///      doing it here keeps `imp * legs` small enough that only `mulDiv`'s
    ///      512-bit intermediate has to carry the amount.
    function _wImp(uint256 imp, uint256 legAmountIn, uint256 legs, uint256 scaleDen)
        private pure returns (uint256)
    {
        if (imp > BPC.BPS) imp = BPC.BPS;
        return BPC.mulDiv(imp * legs, legAmountIn, scaleDen);
    }

    function _hopScaleImpactAndQuote(
        Hop calldata hop, uint256 h, uint256 amountIn, uint256 foreignBase,
        uint256[] memory legQuotes
    ) private view returns (uint256 scaleNum, uint256 scaleDen, uint256 impactAcc, uint256 quoteAcc) {
        uint256 legs = hop.legs.length;
        {
            // R3 / BP-15 (invariant I1 — holds-nothing on the INPUT side): hop 0
            // uses the measured amountIn; hop 1+ uses the bridge received from the
            // previous hop MINUS foreignBase (= bridgeBase[h-1], the Router's
            // pre-swap balance of that bridge token). Without the subtraction a
            // crafted route sized leg.amountIn to the Router's stranded/mis-sent
            // balance of the bridge, so scaling spent funds the 48h rescue exists
            // to return. Capping scaleNum to scaleDen does NOT close it (the
            // attacker sizes scaleDen to that balance); only excluding the pre-swap
            // balance does. Mirrors the bridge residual sweep, which baselines the
            // same amount.
            uint256 realIn = amountIn;
            if (h != 0) {
                uint256 bal = _bal(hop.tokenIn);
                realIn = bal > foreignBase ? bal - foreignBase : 0;
            }
            uint256 quotedIn = _legSum(hop);
            // SECURITY (issue #1 cap × BP-02 floor seam): the hop-0 cap is
            // applied HERE, BEFORE the quote loop below, so hopQuote/hopImpact
            // are priced on the SAME legAmt _execute later spends. Capping
            // only in _execute (as before) let the quote scale UP past the
            // plan's committed Σ leg.amountIn while execution stayed capped —
            // quote > realised on every input-surplus swap, so the 96%
            // protocol floor rejected legitimate fills (CI 2026-08-09).
            // Single source of truth: do NOT re-add a cap in _execute.
            // The cap mutates existing named returns only — no new locals —
            // so the razor-thin via-IR stack budget is untouched. If a future
            // edit still trips stack-too-deep here, fold it into the
            // assignment: scaleNum = (h == 0 && realIn > scaleDen) ? scaleDen : realIn;
            scaleNum = realIn;
            scaleDen = quotedIn == 0 ? 1 : quotedIn;
            if (h == 0 && scaleNum > scaleDen) scaleNum = scaleDen;
        }
        address v4mgr;
        for (uint256 l; l < legs; ) {
            Leg calldata leg = hop.legs[l];
            uint256 legAmt = BPC.mulDiv(leg.amountIn, scaleNum, scaleDen);

            if (BPC.kindHasAny(leg.kind, BPC.A_RESERVES | BPC.A_CONC_POOL)) {
                // K2 (2026-10-21): the pair-shaped and concentrated arms are ONE Core call
                // (`legQuoteImpact`), same reads and numbers; their history is written there.
                (uint256 q_, uint256 imp, bool held) = BPC.legQuoteImpact(leg, hop.tokenIn, hop.tokenOut, legAmt);
                if (!held) revert RouterE(8);
                impactAcc += _wImp(imp, leg.amountIn, legs, scaleDen);
                legQuotes[l] = q_; quoteAcc += q_;
            } else if (BPC.kindHas(leg.kind, BPC.A_CONC_SING)) {
                if (v4mgr == address(0)) v4mgr = hub.v4PoolManager();
                uint256 q_ = _v4LegQuote(leg, hop.tokenIn, legAmt, v4mgr);
                legQuotes[l] = q_; quoteAcc += q_;
                impactAcc += _wImp(BPC.DEFAULT_IMPACT_BPS, leg.amountIn, legs, scaleDen);
            } else { impactAcc += _wImp(BPC.DEFAULT_IMPACT_BPS, leg.amountIn, legs, scaleDen); }
            unchecked { ++l; }
        }
    }

    /// @dev Extracted from _hopScaleImpactAndQuote for the same stack-depth reason
    ///      as _stableLegQuote — the V4 branch's locals (tokenOther, t0, t1,
    ///      pid, sp4, lq4) were the other major contributor.
    function _v4LegQuote(Leg calldata leg, address tokenIn, uint256 legAmt, address v4mgr)
        private view returns (uint256 quote)
    {
        address tokenOther = address(uint160(uint256(leg.auxId)));
        if (tokenOther == address(0)) return 0;
        if (leg.kind == BPC.KIND_V4_NATIVE) {
            // Native pool: the side equal to the canonical WETH maps to
            // currency address(0) — the SAME substitution _execV4Amt applies,
            // so quote and execution derive the poolId from one key
            // construction and cannot diverge. A malformed native leg (weth
            // unwired, or neither side the real WETH) is 0-quoted here and
            // reverts RouterE(8) there — consistent with the auxId==0 case.
            // `weth` is read direct (no local) to keep this frame stack-lean.
            (tokenIn, tokenOther) = BPC.nativeMapVerified(tokenIn, tokenOther, weth);
            if (tokenIn == address(0) && tokenOther == address(0)) return 0;
        }
        (address t0, address t1) = BPC.sortTokens(tokenIn, tokenOther);
        bytes32 pid = BPC.computeV4PoolId(t0, t1, leg.fee, leg.tickSpacing, leg.hooks);
        // The promise, bounded at the current range's edge and fee-resolved in the
        // swap's direction — one linked-library call (BlazePhoenixCore.v4LegOut).
        quote = BPC.v4LegOut(v4mgr, pid, legAmt, leg.fee, leg.tickSpacing, leg.zeroForOne);
    }

    /// @dev `payer` is who funded this swap and therefore who the unspent
    ///      input belongs to. It is passed explicitly rather than read from
    ///      `msg.sender`, because `swapBestExactIn` reaches this function
    ///      through an external SELF-call, where `msg.sender` is the Router.
    ///      Inferring the payer there refunded the residual to the Router
    ///      itself and stranded it.
    function _execute(
        Route calldata route, uint256 amountIn, uint256 userMinOut,
        address recipient, address tokenIn, address payer
    ) private returns (uint256 amountOut) {
        // Every door reaches here (including swapBestExactIn's self-call). Under an EIP-7702
        // delegation address(this) is the EOA and every balance below would be the EOA's;
        // nothing in this contract needs to run there (7702 accounts CALL the Router).
        if (address(this) != SELF) revert RouterE(18);
        if (route.hops.length > MAX_HOPS) revert RouterE(3);
        address tokenOut = route.hops[route.hops.length - 1].tokenOut;
        // Input-token balance at entry (the input is already in the Router).
        // Every unit pulled for this swap MUST be consumed by the legs; the
        // holds-nothing check after the hop loop enforces it.
        uint256 tinStart = _bal(tokenIn);
        // Output-token baseline — the exact mirror of tinStart/baseIn, and for
        // the same reason: the post-hop measurement must be a DELTA, never a
        // raw balance. Any tokenOut the Router already holds is mis-sent or
        // airdropped money that the 48h timelocked rescue (queueRescue /
        // executeRescue) exists to return to its owner; measured as a raw
        // balance it is handed to the first swapper as fee-exempt surplus, so
        // no rescue could ever be executed on a token anyone routes through.
        // The delta also restores the RouterE(8) zero-output check, which a
        // stray balance would satisfy for a swap that produced nothing.
        // Degenerate tokenIn == tokenOut: the entry balance ALREADY contains
        // this swap's amountIn, so the baseline is the same pre-existing
        // remainder the input sweep uses (tinStart - amountIn) — taking the
        // raw balance here would count amountIn on both sides and underflow
        // the delta whenever output < input. That case also skips the tokenIn
        // sweep below, so the remainder is subtracted exactly once; and
        // reusing tinStart avoids a second staticcall for the same token.
        // THE tokenIn BASELINE IS BORN ONCE, HERE. It used to be recomputed in three places as
        // `tinStart - amountIn`, and that stopped being correct when the fee moved to coming out
        // from inside the loop: `amountIn` shrinks at each hop, so recomputing AFTERWARDS gave an
        // INFLATED baseline, the sweep returned too little, and the Router was left holding the
        // difference — the holds-nothing invariants caught it. Three reads of the same quantity at
        // different moments: the house defect signature, now against TIME instead of against
        // space.
        uint256 baseIn = tinStart > amountIn ? tinStart - amountIn : 0;
        uint256 toutStart = tokenIn == tokenOut ? baseIn : _bal(tokenOut);
        // Floor re-derivation: sum of per-leg real impact (BPS), averaged later.
        uint256 impactAcc;
        // On-chain quote for the legs as actually executed — replaces the
        // caller-supplied route.totalOut as the fee-base reference (see the
        // "Fee base" section below).
        // Quote of the FINAL hop only, denominated in tokenOut — the correct
        // reference for the protocol floor. onchainQuoteAcc SUMS the per-hop
        // quotes, whose units differ across a multi-hop route, so it cannot
        // serve as a tokenOut-denominated floor; the last hop's quote can.
        uint256 finalHopQuote;

        // Pre-swap balance of every intermediate (bridge) token, so the residual
        // sweep below returns only what THIS swap produced — never a balance the
        // Router happened to hold at entry. Mirrors the tokenIn sweep's baseIn
        // guard, making both sweeps symmetric (finding: NetGakarot-class review —
        // the bridge sweep otherwise handed a crafted route the Router's
        // dust/mis-sent balance of any caller-named intermediate token).
        uint256[] memory bridgeBase = new uint256[](route.hops.length);
        // WHAT EACH HOP ACTUALLY SPENT, as a ratio of what it declared (VOL_01).
        // `_recordHits` runs after the loop and only ever saw `leg.amountIn` - the figure the
        // CALLER wrote - so the volume the registry published was the caller's declaration and
        // not the flow. It overstated every honest swap by the protocol fee alone, because the
        // fee comes out of hop 0's input before the leg executes, and by the capacity clamp
        // wherever that cut a leg. One word per hop is enough: `scaleNum/scaleDen` IS
        // measured-over-declared, uniform across the legs of a hop, so the ratio reconstructs
        // each leg's real spend exactly. Storing the ratio rather than the two terms keeps this
        // to a single array in a frame the via-ir stack limit already constrains.
        uint256[] memory hopScale = new uint256[](route.hops.length);
        for (uint256 bh; bh + 1 < route.hops.length; ) {
            address bt = route.hops[bh].tokenOut;
            if (bt != tokenIn && bt != tokenOut) bridgeBase[bh] = _bal(bt);
            unchecked { ++bh; }
        }

        // ─── WHERE THE FEE LANDS ───────────────────────────────────────
        // ANCHOR BY VALUE, NOT BY INDEX. The previous version anchored on the
        // literal `h == 1` and ASSUMED — never checked — that `hops[1].tokenIn`
        // was a bridge. `_chargeHopFee`'s own docstring had already named the
        // attack that opens ("anchored at hop k -> insert k hops of dust before
        // it"); the new rule put k=1 and reopened it mid-route.
        //
        // MEASURED LEAK (PoC, canonical 30 bps CPMM pool): route
        // tU->tX->tU->tW with `tX` minted by the attacker and the (tU,tX) pool
        // theirs. The fee left entirely in `tX` — dust they printed themselves —
        // and the `tU` stayed trapped in their pool, which they recover by
        // burning LP. Net balance: +280 tU, that is 100% of the fee, for ~130k
        // of gas.
        //
        // The cure is to look for the FIRST hop whose input really is a bridge.
        // And the degenerate case — a route that touches no bridge at all — goes
        // back to the PRE-DIFF behaviour (charge on EVERY hop), which is the only
        // one immune by EXHAUSTION: there is no index at which to insert dust
        // that escapes them all. Anchoring that case at the entry (h==0) would
        // reopen the dust prefix, and that is why the first version of this fix
        // turned `test_JUIZ_PrefixoSemValorEscapaAFee` red.
        //
        // The Solver builds ALL multi-hop routes through registered bridges, so
        // the honest path still pays 28 bps exactly once, in the bridge coin —
        // the owner's decision stays intact.
        uint256 feeHop = type(uint256).max;
        for (uint256 fi; fi < route.hops.length; ) {
            if (hub.isBridgeToken(route.hops[fi].tokenIn)) { feeHop = fi; break; }
            unchecked { ++fi; }
        }
        // Read ONCE: the predicate used here and in the block at the end has to be
        // the same value, and between the two the whole route runs (hooks included).
        bool feeOnOut = route.hops.length == 1 && hub.isBridgeToken(tokenOut);
        // TWO REGIMES, BOTH NAMED (2026-09-05). ANCHORED: a bridge coin is an input somewhere, and
        // the fee is charged exactly once, there. EXHAUSTION: no bridge coin is an input anywhere
        // (a hand-built route through pools the registry would not hold) — `feeHop` stays at max
        // and the predicate below is true for EVERY hop, so each hop pays on its own measured
        // input. That is immunity by exhaustion, not an oversight: charging such a route once, on
        // hop 0, was tried on this date and reopened the junk-prefix escape inside the suite
        // (a value-less first hop moves the fee spot onto dust; `FeeEscapeViaJunkPrefix.t.sol`).
        // The policy is pinned by `ExhaustionRegimePreviewParity.t.sol` and modelled by
        // `Quoter._pack`; the ledger at the end of this function enforces the count per regime.

        // Bit i is set when the i-th leg of the route actually executed. Beyond
        // 255 legs the shift yields 0, so the bit stays clear and the leg is not
        // credited — the fail-CLOSED direction, and unreachable by construction:
        // MAX_HOPS x MAX_LEGS_PER_HOP = 15 legs (a per-route bound, not the
        // per-hop constant standing in for one).
        uint256 executedMask;
        uint256 legIdx;
        // LAYER 2 IS ROUTE-WIDE (review 2026-09-02). This flag used to be born
        // inside the hop loop, so the rule "no hookless leg after a hooked one"
        // closed the intra-hop vector and left the cross-hop one open — while
        // its own justification names "the pool of a leg of this same route
        // that has not executed yet", which every leg of a later hop is. Hoisted
        // here, a hooked leg may only sit in the LAST hop; the Solver builds
        // nothing else (`_assembleRouteMulti`).
        bool sawHooked;
        for (uint256 h; h < route.hops.length; ) {
            Hop calldata hop = route.hops[h];
            uint256 legs = hop.legs.length;
            // A hop trades two DIFFERENT tokens (H3, oc-1018). A self-hop passes the pair guard
            // only through a pool answering token0() == token1(), whose leg the per-leg floor
            // reads as `legOut == tokenIn` and fails open. No factory pool and no Solver route
            // has that shape.
            if (legs == 0 || legs > MAX_LEGS_PER_HOP || hop.tokenIn == hop.tokenOut) revert RouterE(3);

            // Real-balance-ratio scaling for EVERY hop, not just h>0, AND
            // this hop's real impact/on-chain quote — all in one call (see
            // _hopScaleImpactAndQuote's docs) to keep this loop's via-IR
            // stack frame shallow.
            // R3/BP-15 (I1, holds-nothing): hops MUST chain — hop.tokenIn ==
            // previous hop.tokenOut — so the pre-swap ("foreign") balance of the
            // token being scaled is known and excluded. Without continuity a crafted
            // route named an arbitrary STRANDED token as hop.tokenIn and scaled the
            // Router's whole balance of it into the swap; bridgeBase[h-1] baselines
            // route.hops[h-1].tokenOut, which is that same token ONLY under
            // continuity. tokenIn/tokenOut-typed bridges carry bridgeBase==0, so use
            // their own entry baselines (baseIn / toutStart) instead.
            // A ROUTE VISITS ITS INPUT ONCE. Hop 0's fee base is capped by what hop 0 commits
            // (`_legSum`), and the part it does not commit waits in the Router for the sweep
            // after the loop; that cap is the measured pull only while no later hop takes the
            // route's input token again (INV-15; Seavia Resources, bug bounty). No honest route
            // visits its input twice - the Solver's bridges are distinct from `tIn` - so the
            // shape is refused rather than re-priced.
            uint256 foreignBase;
            if (h != 0) {
                if (hop.tokenIn != route.hops[h - 1].tokenOut || hop.tokenIn == tokenIn) revert RouterE(3);
                foreignBase = hop.tokenIn == tokenOut ? toutStart : bridgeBase[h - 1];
                // A CYCLIC ROUTE (tokenIn == tokenOut) RETURNS HOP 0'S UNSPENT INPUT HERE, to the
                // payer the docstring above names as its owner (H9, oc-1018). After the loop the
                // residual and the output are the same token and can no longer be told apart, so
                // the sweep there skips this shape - and the residual rode out to the RECIPIENT as
                // output, counted towards userMinOut. Here the split is exact: hop 0 cannot deliver
                // into tokenIn (hop 1 would re-enter it, refused just above) and its fee has already
                // left the Router, so the balance above baseIn IS hop 0's residual.
                if (h == 1 && tokenIn == tokenOut) {
                    uint256 resid0 = _bal(tokenIn);
                    if (resid0 > baseIn) BPC.safeTransfer(tokenIn, payer, resid0 - baseIn);
                }
            }
            // One allocation per hop (MAX_LEGS_PER_HOP entries, memory, no storage). It carries
            // each leg's MEASURED quote through to the coverage gate in `_execScaled` — before,
            // these measurements were summed and the per-leg value thrown away.
            // ─── THE FEE IS CHARGED ONCE, ON THE FIRST BRIDGE COIN ───
            //
            // OWNER'S DECISION 2026-08-22. It used to be charged on EVERY hop, in
            // that hop's token: a 2-hop route paid ~56 effective bps and a 3-hop
            // one would pay ~84, when the constant says 28. The `(1-fee)^H`
            // composition was even written in the Quoter's header — the number
            // said one thing and the route charged another, and H only grew with
            // this session.
            //
            // THE NEW RULE, and there is only one: charge on the INPUT of hop 1,
            // which is the route's first BRIDGE coin. On a direct route there is
            // no hop 1, so it is charged on hop 0 (behaviour unchanged).
            //
            // WHY ON THE BRIDGE AND NOT ON THE DESTINATION: the bridges are WETH
            // and USDC. The treasury receives a liquid token it wants to hold,
            // instead of dust of whatever tail token happens to be the
            // destination.
            //
            // WHY ON HOP 1'S INPUT AND NOT HOP 0'S OUTPUT: they are the SAME
            // token and the SAME amount — hop 0's output is what hop 1 will
            // spend — but hop 1's input is measured by the REAL BALANCE
            // (`bal - foreignBase`), which is already resistant to fee-on-transfer
            // and to stray balances. Choosing the formulation that reuses the
            // existing measurement avoids a second producer of "how much does
            // this hop have".
            // On a DIRECT route whose destination IS already a bridge, the fee
            // comes out of the output (see the block at the end of this function)
            // — nothing is charged here, otherwise it would be charged twice.
            if (!feeOnOut && (feeHop == type(uint256).max || h == feeHop)) {
                amountIn = _chargeHopFee(hop, h, amountIn, foreignBase);
            }

            uint256[] memory legQuotes = new uint256[](hop.legs.length);
            (uint256 scaleNum, uint256 scaleDen, uint256 hopImpact, uint256 hopQuote) =
                _hopScaleImpactAndQuote(hop, h, amountIn, foreignBase, legQuotes);
            // `scaleDen` cannot be zero: `_hopScaleImpactAndQuote` assigns it unconditionally,
            // in a plain scope block with no early return above it, as
            // `quotedIn == 0 ? 1 : quotedIn`. The guard that used to stand here tested for a
            // state its own producer forbids, and the comment beneath it described that state as
            // if it happened - a branch the compiler kept (measured live at 25,798 executions,
            // its zero arm never once taken) and a sentence in the source that was not true.
            hopScale[h] = BPC.mulDiv(scaleNum, 1e18, scaleDen);
            // SECURITY (issue #1, reported by NetGakarot): on hop 0 the Router
            // may hold MORE input than the plan committed (the phantom-tier
            // capacity clamp cuts leg.amountIn on purpose); spending past
            // Σ leg.amountIn would force-feed the pre-cut order into a thin
            // pool (a revert with the per-leg floor, or a ~20–27% one-way
            // loss without it). The cap (scaleNum = min(scaleNum, scaleDen)
            // for h == 0) lives INSIDE _hopScaleImpactAndQuote, applied
            // BEFORE its quote loop, so the scaleNum returned above is
            // already capped and hopQuote/hopImpact price the SAME legAmt
            // the loop below executes — the BP-02 floor compares realised
            // output with a quote of the amounts actually spent, never a
            // scaled-up phantom. Single source of truth: do NOT re-cap here —
            // a second cap site is exactly the seam that broke on 2026-08-09.
            // Fee-on-transfer is unaffected: there scaleNum (received) < scaleDen,
            // so the cap never fires and the existing scale-DOWN still applies.
            // Hop 1+ spends the bridge received from the previous hop MINUS the
            // Router's pre-swap balance of that bridge (bridgeBase[h-1]) — see
            // R3/BP-15 in _hopScaleImpactAndQuote: foreign/stranded bridge balances
            // are never scaled into the swap (invariant I1, holds-nothing).
            impactAcc += hopImpact;

            uint256 hopGot;
            uint256 hopAttested;
            uint256 hopQuoted;
            // NM-002's RESIDUAL. The fallback at the end of this loop fires only
            // when the WHOLE hop went unquoted. A hop where ONE leg spends input
            // without being measured still has `hopQuote != 0`, so the floor is
            // built on the legs that could be priced and the blind leg's share is
            // bounded by nothing - it is absent from both sides of the Layer 1
            // comparison, which therefore compares the measured legs with their
            // own attestations. This flag is what tells the two cases apart.
            bool hopBlind;
            // ─── LAYER 2: canonical order — hookless BEFORE hooked ───
            // A hook gains EVM control during the swap and can touch ANY
            // contract — including the pool of a leg of this same route that has
            // not executed yet (normal EVM composability, not a V4 flaw). If the
            // hookless legs run first, they settle and are verified by
            // balance-delta (immediately, before `l` advances) BEFORE any
            // third-party code runs: the past cannot be manipulated. It closes
            // the intra-hop vector by ORDER, not by tolerance — no slack
            // tightened, nothing rejected.
            // Imposed HERE and not in the Solver: swapExactIn receives the Route
            // from calldata and iterates in the order received, so ordering in
            // the planner is bypassable by whoever assembles the route by hand.
            // It is not a list nor an admission: every route is re-expressible in
            // the canonical order — an encoding rule, like token ordering.
            // `sawHooked` lives OUTSIDE the hop loop: see its declaration.
            for (uint256 l; l < legs; ) {
                Leg calldata leg = hop.legs[l];
                if (leg.hooks == address(0)) {
                    if (sawHooked) revert RouterE(3);
                } else {
                    sawHooked = true;
                }
                (address legIn, address legOutRaw) = _legTokens(leg);
                // V4 legs return address(0) as legIn (their pool field
                // holds the *other* token, not a Uniswap-style pair). Resolve
                // the real tokenIn from the hop context so _execV4Amt writes the
                // correct token into transient storage for the unlock callback.
                if (legIn == address(0)) legIn = hop.tokenIn;
                // THE LEG MUST TRADE THE HOP'S PAIR. Without this, `_legTokens`
                // derives both tokens from the CALLDATA POOL and the executor
                // spends a token this swap never received: a single hop A->B
                // whose only leg names the pool T/B makes `legIn = T`, and the
                // clamp below hands the attacker the ENTIRE balance of T sitting
                // in the Router (measured: 100e18 -> 0 for 0.28e18 of fee; see
                // test/LegDivergentStrandedDrain.t.sol). It is the shape of
                // R3/BP-15 one level down: R3's continuity guard lives between
                // HOPS and does not even apply when h == 0.
                //
                // `legOut` is closed for the same reason and in the same place:
                // `_execScaled` measures `got` as the change in the `legOut`
                // balance, so a leg producing a token that is not the hop's makes
                // `hopGot` count the wrong units — and drains the stranded
                // balance on the OUTPUT side instead of the input one.
                //
                // IT DOES NOT KILL `bridge collapsing`. That justification (the
                // `_legTokens` docstring) rests on the claim "the Solver collapses
                // bridge routes into a single hop", which `Quoter._classify`
                // already documents as FALSE since 2026-08-22: `_planViaBridges`
                // has always returned one hop per stage (two over one bridge). And the Solver builds each
                // leg from `getActivePools(tIn, tOut)` with
                // `zeroForOne: cands[i].token0 == tIn` — every leg the planner
                // produces trades the hop's exact pair. The guard is a no-op for
                // everything the system generates.
                //
                // And it is the invariant LAYER 1 below already assumed with
                // nobody enforcing it: "the legs of a hop are homogeneous (same
                // pair), so the attested quotes add up DIRECTLY".
                if (legIn != hop.tokenIn || legOutRaw != hop.tokenOut) revert RouterE(3);
                // TWO VALUES, ONE COMPUTATION. The quoting `legAmt` is mulDiv(leg.amountIn,
                // scaleNum, scaleDen) — exactly the `scaledAmt` BEFORE the last leg's clamp.
                // The gate inside `_execScaled` rescales by amt/legAmt, so the clamp is handled,
                // and in the conservative direction.
                //
                // It used to be written with the expression REPEATED in the argument, because the
                // clamp below MUTATES `scaledAmt` and recomputing was the way to recover the
                // pre-clamp value. It cost one 512-bit mulDiv per leg, at every swap door. Holding
                // the pre-clamp in a local costs a stack slot — `_execute` was documented as
                // sitting at the via_ir limit, which is why this went undone until there was
                // measured headroom. If it ever blows up here again, this is the first local to
                // undo (just put the expression back in the argument).
                uint256 legAmt = BPC.mulDiv(leg.amountIn, scaleNum, scaleDen);
                uint256 scaledAmt = legAmt;
                if (l == legs - 1) {
                    uint256 remaining = _bal(legIn);
                    if (remaining < scaledAmt) scaledAmt = remaining;
                }
                // A leg with a zero scaled input never reaches the pool:
                // `_execScaled` returns (0,0) before any transfer or swap. Record
                // WHICH legs actually ran, so the registry credits execution and
                // not calldata. The index runs across the whole route and both
                // loops walk the same calldata in the same order.
                if (scaledAmt != 0) executedMask |= (uint256(1) << legIdx);
                unchecked { ++legIdx; }
                (uint256 legGot, uint256 legAtt) = _execScaled(
                    leg, legIn, legOutRaw, scaledAmt, legQuotes[l], legAmt
                );
                hopGot += legGot;
                hopAttested += legAtt;
                if (legAtt != 0) { unchecked { ++hopQuoted; } }
                // THE FLOOR'S BASE SPEAKS FOR EVERY LEG: a leg the frame could not price enters
                // `hopQuote` with its attested figure (a Gate leg, a native leg with no in-frame
                // quote), so a priced leg beside it never shrinks the base to its own share.
                if (legQuotes[l] == 0) hopQuote += legAtt;
                // A leg that spent input and came back with no attestation was not
                // measured at all.
                //
                // BLINDNESS IS "NOT MEASURED", NOT "NOT ATTESTED", and the two part
                // company: a leg the caller left unattested is still measured when
                // the frame could price it, and its delivery does reach the
                // comparison. The condition below is the exact negation of the
                // measurement guard in `_execScaled` - no attestation AND no in-frame
                // quote - so it names the only leg that leaves no trace. A leg
                // scaled to zero moved nothing and is not blindness.
                //
                // OFF THE LAST HOP, A BLIND LEG IS REFUSED. The hop-level takeover below bounds
                // a blind leg through the protocol floor, and the floor's base is the last hop's:
                // an earlier hop's base is overwritten even when that hop also makes the route's
                // output token, so on any earlier hop nothing would bound it, with or without a
                // hop-level figure (Seavia Resources, bug bounty). The Solver never emits an
                // unattested leg, and an attested leg is never blind.
                if (scaledAmt != 0 && leg.expectedOut == 0 && legQuotes[l] == 0) {
                    if (h + 1 != route.hops.length) revert RouterE(5);
                    hopBlind = true;
                }
                unchecked { ++l; }
            }
            // ─── LAYER 1: shared per-hop budget (aggregate) ───
            // The per-leg floor is LOCAL, but composition is GLOBAL: in a hop of L
            // legs, whoever controls ONE leg extracts ~20%·(L-1)/L without any leg
            // failing its own floor — and across H hops the legitimate guarantee
            // degrades to 0.8^H (41% at 4 hops). This exists WITHOUT hooks.
            // The legs of a hop are homogeneous (same pair), so the attested quotes
            // add up DIRECTLY, with no oracle.
            // Only legs WITH an attested quote enter — on BOTH sides of the sum, so
            // a leg without a quote cannot mask another's shortfall.
            // It does not tighten the per-leg floor: a thin pool can still fail 20%
            // on its own. It bounds what the WHOLE hop may bleed.
            // Reuses measurements already taken in _execScaled — zero new reads.
            if (hopAttested != 0) {
                // Slack = what ONE AVERAGE leg could legitimately lose.
                // AVERAGE (Σ/n), not MAXIMUM: with the maximum, an attacker inflated
                // their OWN leg to inflate the shared budget and drained the others —
                // with their leg at 83% of the hop they extracted 16.67% and passed,
                // inverting the incentive (under the old rule holding the big leg was
                // bad for them). The average is not manipulable by them: increasing n
                // SHRINKS the slack, and they do not write the victim's route.
                uint256 slack = BPC.mulDiv(hopAttested / hopQuoted, BPC.BPS - BPC.LEG_FLOOR_BPS, BPC.BPS);
                if (hopGot + slack < hopAttested) revert RouterE(5);
            }
            // ─── NM-002 (external report, BoyD; review 2026-09-02) ───
            // When the LAST hop could not be quoted in-frame (finalHopQuote == 0:
            // a liquidity gap at the current tick, a fee sentinel, a dynamic-fee
            // V4 key under a protocol fee) the protocol floor below was inert —
            // `mulDivUp(0, floorBps, BPS)` — and the block that computes it
            // said so in writing: absence read as permission, the second axis.
            // A JIT liquidity gap on a thin concentrated pool is attacker-
            // triggerable and turned the advertised ~96% floor into the 80%
            // per-leg floor for that swap. Floor on the hop's ATTESTED quote
            // instead: it is already coverage-gated against the measurement
            // where one exists and FoT-repriced, the caller can only push it UP
            // (R3), and nobody else can touch it. NEVER revert here: two of the
            // zero-quote paths are legitimately executable pools (a 0-fee CL
            // pool, a dynamic-fee V4 pool once a protocol fee is on). On these
            // swaps `ExecutionProof.quoted` therefore carries the attested
            // figure, not a measured one.
            // THE FLOOR'S ANCHOR IS A HOP THAT MOVED VALUE AND PRODUCES THE ROUTE'S OUTPUT.
            // `hopGot` is a balance delta, so a hop that spent nothing cannot become the anchor,
            // and the output-token clause keeps the anchor in the currency the floor is compared
            // against - a floor read in one token against a delivery in another is not
            // conservative. NM-002 lives inside the same expression: a hop that could not be
            // quoted in-frame but did execute falls back to its attested figure, and nothing
            // reverts here, because two of the zero-quote paths are legitimately executable
            // pools (a 0-fee CL pool, a dynamic-fee V4 pool under a protocol fee).
            //
            // THE RESIDUAL, CLOSED. `hopQuote != 0` was read as "this hop was
            // quoted", and it only means "at least one leg of it was". Where a leg
            // spent input unmeasured, the hop's own attested figure is used when it
            // is the larger of the two: it is the only number in scope that speaks
            // for the WHOLE hop, the caller can only push it UP (R3), and a floor
            // that moves up is the conservative direction. Still never reverts here
            // - the two legitimately executable zero-quote paths above are
            // unaffected, because neither of them leaves a leg unmeasured.
            //
            // A MIXED HOP, CLOSED (2026-10-23). `hopQuote` already carries every unpriced leg's
            // attested figure (the leg loop above), so a hop with no priced leg anchors on
            // `hopAttested` as before, and a priced leg beside an attested one no longer drops
            // the attested leg out of the base: it used to anchor on the priced share alone, and
            // a Gate leg delivering 82 % of its attestation settled beside a V2 leg while the
            // same leg alone was refused (test/GateBaseCoherence.t.sol). The base only rises.
            uint256 hopBase = hopQuote;
            if (hopBlind && route.hops[h].expectedOut > hopBase) {
                hopBase = route.hops[h].expectedOut;
            }
            // A last hop with no measured leg still anchors the floor: `hopBase` is then the
            // hop's own declared figure, the only one in scope for it. Leaving `finalHopQuote`
            // at zero there armed no protocol floor at all on a route the caller had priced.
            // On such a hop the anchor only rises: a declared figure never replaces a larger
            // anchor an earlier hop already set in the output token, so it cannot lower a floor.
            if (route.hops[h].tokenOut == tokenOut && (hopGot != 0 || (hopBlind && hopBase > finalHopQuote)))
                finalHopQuote = hopBase;
            unchecked { ++h; }
        }

        // ─── Holds-nothing enforcement (sweep, don't revert) ───
        // Real routes leave residual input / bridge tokens: a V3/V4 leg that
        // partial-fills at its price limit, mulDiv rounding across split legs,
        // or a non-conforming pool that declined to collect what it was handed.
        // Return every such residual to the caller instead of stranding it
        // (sweepable by a later crafted route) or reverting a legitimate swap.
        // The Router is left holding nothing, and the user gets their unused
        // funds back. Only this swap's residual is swept — the pre-swap balance
        // (baseIn, normally zero since the Router holds nothing at rest) is
        // left untouched so a caller can never sweep prior funds. tokenOut is
        // excluded (it is paid out below), as is the degenerate
        // tokenIn == tokenOut case, whose residual left at the start of hop 1.
        if (tokenIn != tokenOut) {
            uint256 residIn = _bal(tokenIn);
            if (residIn > baseIn) BPC.safeTransfer(tokenIn, payer, residIn - baseIn);
        }
        for (uint256 h; h + 1 < route.hops.length; ) {
            address bridge = route.hops[h].tokenOut;
            if (bridge != tokenIn && bridge != tokenOut) {
                uint256 rb = _bal(bridge);
                uint256 bb = bridgeBase[h];
                if (rb > bb) BPC.safeTransfer(bridge, payer, rb - bb);
            }
            unchecked { ++h; }
        }

        // Measure what THIS swap produced: the balance DELTA against the entry
        // baseline (see toutStart), so the pre-existing balance stays in the
        // Router for the rescue path instead of being paid out below. Checked
        // arithmetic is the guard of last resort: a route that spent part of
        // that baseline (an intermediate hop whose tokenIn is tokenOut) leaves
        // the balance under the baseline and reverts here — the safe outcome,
        // since those funds were never this swap's to spend.
        uint256 totalReceived = _bal(tokenOut) - toutStart;
        if (totalReceived == 0) revert RouterE(8);
        amountOut = totalReceived;

        // ─── Floor re-derivation ───
        // The floor is NOT read from the caller-supplied route. It is computed
        // on-chain from the real impact measured above and the real leg count,
        // exactly as the Solver would, then applied to the measured output.
        // This makes the protocol floor an enforced invariant regardless of
        // what the caller put in route.singleOutFloor.
        //
        // IMPORTANT: the protocol floor is a fraction of the REALISED output —
        // it is a secondary safety net against pathological execution, not the
        // primary slippage guard. The primary guard is userMinOut, which the
        // user sets from the quote they saw. A caller can no longer RELAX
        // protection via route fields, but users must still pass a real
        // userMinOut to be protected against a bad quote-to-fill gap.
        // `totalLegs` is counted HERE and not inside the execution loop, on purpose: accumulated
        // there it stayed live across the whole loop body and via_ir had no slot for it. Here it is
        // its own loop over CALLDATA (cheap, no storage, no external calls) and the value is born
        // exactly where it is consumed. Readability improves too: the loop above executes, this
        // one counts.
        // THE FLOOR'S TWO INPUTS, each from the object that decides it. The impact term is the
        // share-weighted mean over the route's legs: `_wImp` pre-multiplies each leg's impact by
        // its hop's leg count so that dividing by the route's leg count here yields the weighted
        // mean, and a leg with no share carries no weight. The leg shave is computed from the
        // CONCENTRATION of the trade across legs - `(Σa)² / Σa²` per hop, the effective number
        // of legs - so a split earns loosening in proportion to how genuinely it is split, and a
        // leg carrying a vanishing share of its hop earns a vanishing amount. The Solver computes
        // the same figure from the same amounts when it attests `singleOutFloor`, so the attested
        // floor and the enforced floor agree by construction.
        uint256 declaredLegs;
        uint256 legShv;
        for (uint256 th; th < route.hops.length; ) {
            Leg[] calldata ls = route.hops[th].legs;
            declaredLegs += ls.length;
            uint256 sA;
            uint256 sA2;
            for (uint256 i; i < ls.length; ) {
                uint256 a = ls[i].amountIn;
                sA += a;
                sA2 += a * a;
                unchecked { ++i; }
            }
            legShv += BPC.legShaveBps(sA, sA2);
            unchecked { ++th; }
        }
        uint256 avgImpact = declaredLegs > 0 ? impactAcc / declaredLegs : 0;
        uint256 floorBps  = BPC.ironFloorBpsShv(avgImpact, legShv, 0);

        // The caller's singleOutFloor and userMinOut may TIGHTEN the floor
        // (user wants more protection) but can never RELAX the protocol floor.
        // protocolFloorOut is a fraction of the in-frame on-chain quote of the
        // final hop (denominated in tokenOut, unforgeable by calldata), NOT of
        // the realised output. Anchoring it to the realised output made it
        // mathematically inert: with floorBps <= BPS it could never exceed the
        // realised amount, so the guard below never fired. Deriving it from the
        // measured final-hop quote lets a fill that lands far below the quote
        // revert. userMinOut is an absolute amount; effMin is the strictest of
        // all three. If the final-hop quote is unavailable (finalHopQuote == 0)
        // the protocol floor is inert for this swap and userMinOut, which the
        // entrypoints force to be non-zero, remains the backstop.
        // R-C: round the protective floor UP. Rounding it down hands the
        // executor a free wei on every swap and, at tiny quotes, a free floor.
        uint256 protocolFloorOut = BPC.mulDivUp(finalHopQuote, floorBps, BPC.BPS);
        uint256 effMin = userMinOut;
        // Fee-on-transfer (MEASURED during execution, unforgeable by a crafted
        // Route): the quote-derived singleOutFloor assumed no transfer fee and
        // is inflated, so it would reject a correct fill. Drop it for this
        // swap only; the user stays protected by userMinOut (their own bound)
        // and by protocolFloorOut re-priced below onto the measured NET —
        // finalHopQuote prices GROSS amounts, so an un-re-priced floor would
        // falsely reject a correct FoT fill once the transfer fee exceeds
        // ~(BPS − floorBps)/BPS (≈ >4%). The slot holds the compounded
        // measured net ratio in bps (see _noteFot); honest tokens never set
        // it — behaviour unchanged for them.
        //
        // SCOPING (known, bounded, deliberately deferred): the slot compounds
        // ONE ratio for the whole route, while finalHopQuote is priced on the
        // measured bridge input of the final hop — upstream input-side taxes
        // are therefore already absorbed in the quote, and multiplying by the
        // fully-compounded ratio can only OVER-discount this secondary floor
        // (more permissive, never a false reject). The user remains protected
        // by the mandatory non-zero userMinOut (primary bound, enforced on
        // the delivered amount) and by the per-leg BPC.LEG_FLOOR_BPS guard at
        // every pool seam. Per-hop scoping would need a second transient flag
        // (the singleOutFloor drop above must still trigger on FoT seen in
        // ANY hop) — a floor-semantics rewrite not worth the risk for a
        // safety net that only backs up two harder bounds.
        uint256 sF = TSLOT_FOT;
        uint256 fotSeen; assembly { fotSeen := tload(sF) }
        if (fotSeen == 0) {
            if (route.singleOutFloor > effMin) effMin = route.singleOutFloor;
        } else {
            assembly { tstore(sF, 0) }
            if (fotSeen > BPC.BPS) fotSeen = BPC.BPS; // belt; writers clamp
            // R-C: this SHRINKS the floor by the measured tax, so rounding up
            // shrinks it LESS — the conservative direction.
            protocolFloorOut = BPC.mulDivUp(protocolFloorOut, fotSeen, BPC.BPS);
        }
        if (protocolFloorOut    > effMin) effMin = protocolFloorOut;
        if (amountOut < effMin) revert RouterE(5);

        // ─── THE FEE, WHEN IT COMES OUT OF THE OUTPUT ─────────────────────
        // A DIRECT route whose destination is already a bridge coin (TOKEN -> WETH):
        // the fee comes out here, and not out of the input. It is the same rule as
        // multi-hop — "charge on the first bridge coin the Router holds" — applied
        // to the case where that coin is the destination itself.
        //
        // AFTER THE FLOOR, AND THE ORDER MATTERS. The floor validates SWAP QUALITY
        // ("did the pools deliver what they quoted?"), which is a question about the
        // market and not about the protocol. The protocol's cut comes next, out of
        // the already-validated amount. Charging first would make the floor reject
        // perfectly good swaps because of our own fee.
        //
        // And the `delivered` measured below is already the net value, so the user's
        // `userMinOut` is compared against what they ACTUALLY receive.
        uint256 net = amountOut;
        if (feeOnOut) {
            // Same round-up as the input-side anchor: the two producers of
            // this fee must round the same way or preview and execution
            // diverge again.
            uint256 fOut = BPC.mulDivUp(amountOut, BPC.PROTOCOL_FEE_BPS, BPC.BPS);
            if (fOut != 0) {
                if (fOut >= amountOut) revert RouterE(8);
                _payFee(tokenOut, fOut);
                unchecked { net = amountOut - fOut; }
            }
        }

        // Everything left over goes to the recipient.
        // Measure the recipient's ACTUAL balance delta: fee-on-transfer tokens
        // deliver less than the nominal `net`, so we must report and protect on
        // what the user truly receives, not the nominal figure. For normal
        // tokens this delta equals `net` exactly (no behaviour change).
        uint256 recipBefore = BPC.balanceOf(tokenOut, recipient);
        BPC.safeTransfer(tokenOut, recipient, net);
        uint256 delivered = BPC.balanceOf(tokenOut, recipient) - recipBefore;

        // Slippage protection is enforced on the DELIVERED amount: a fee-on-
        // transfer token cannot be used to slip the user below their userMinOut.
        if (delivered < userMinOut) revert RouterE(5);

        // THE FEE LEDGER, read once per settlement: a delivery that paid nothing is refused; in
        // the anchored regime a second payment is refused; the slot is cleared for the next swap
        // in the same transaction.
        {
            uint256 sFee = TSLOT_FEE;
            uint256 paid; assembly { paid := tload(sFee) }
            if (paid == 0) revert RouterE(15);
            if (paid > 1 && feeHop != type(uint256).max) revert RouterE(16);
            assembly { tstore(sFee, 0) }
        }

        // The floor was checked against `amountOut`, before the transfer to the recipient; a
        // token that taxes that transfer delivers less than `net`. The floor is published net
        // of that tax, by the ratio measured at the recipient, so a taxed tokenOut never shows
        // a met floor the tax already took. Identity on an untaxed token, so the published floor
        // stays the floor the Solver attests (the output-side fee is a known cut and is not
        // re-expressed); rounds down. `net` is non-zero: amountOut >= effMin > 0 and fOut < amountOut.
        protocolFloorOut = BPC.mulDiv(protocolFloorOut, delivered, net);
        amountOut = delivered;
        _recordHits(route, executedMask, hopScale);
        // ─── ATTRIBUTION: `payer`, NEVER `msg.sender` ───
        // This function's docstring already explains why `payer` exists as a parameter: in
        // `swapBestExactIn` this is reached by an external SELF-CALL, and on that path the
        // `msg.sender` IS THE ROUTER ITSELF. Both events were indexed to the contract's address
        // instead of the user — and precisely at the door the docstrings call the entry point of
        // the philosophy, the only one where the route is decided 100% on chain.
        // The `ExecutionProof` series is this protocol's only genuinely new asset (the reference
        // quote produced by consensus in the SAME frame as the execution, reproducible by anyone
        // with an eth_call at that block). It was being emitted WITH NO OWNER at exactly the door
        // that makes it unique. House defect signature: a behaviour applied to N-1 of N channels —
        // here, to every door but the flagship.
        //
        // AND THE AMOUNT IS THE GROSS ONE. `amountIn` already arrives net of hop 0's fee (the fee
        // comes out from inside the loop), so emitting it under-reported what the user handed over.
        // `tinStart` minus the baseline gives the ORIGINAL amount with not one new local: the
        // tokens are pre-pulled, so tinStart >= amountIn0 and baseIn == tinStart - amountIn0 by
        // construction.
        // The count published here is the MEASURED one for the same reason the volume is
        // (VOL_01): an event that reports the caller's declaration reports the caller.
        emit Swap(payer, tokenIn, tokenOut, tinStart - baseIn, delivered, declaredLegs);
        emit ExecutionProof(payer, tokenOut, finalHopQuote, delivered, protocolFloorOut, block.number);
        return delivered;
    }

    // =========================================================================
    //  LEG DISPATCH
    // =========================================================================
    //
    //  One function selects the AMM shape for any kind:
    //    V2           → push-then-swap with computed amountOut
    //    V3 / Algebra → callback-style with transient pool + token
    //    Solidly      → push-then-swap with stable-aware amountOut
    //    V4           → unlock → swap → sync → settle → take
    //
    //  There is no default branch that EXECUTES: any other kind falls into the `else`
    //  and reverts RouterE(8) before touching a pool. It is that revert which makes
    //  tombstones 2, 3 and 7 unreachable from the only producer of kinds.

    /// @notice Execute a leg with an explicit input amount that may differ
    ///         from leg.amountIn. Every hop rescales against the REAL
    ///         balance available to it (see the realIn/quotedIn scaling in
    ///         _execute) — hop 0 against the measured post-pull amountIn
    ///         (covers a fee-on-transfer tokenIn), hop 1+ against the
    ///         measured bridge balance. When nothing shrank the input,
    ///         amt == leg.amountIn exactly (mulDiv with equal num/den).
    function _execScaled(
        Leg calldata leg, address tokenIn, address legOutRaw, uint256 amt, uint256 legQuote, uint256 legAmt
    ) private returns (uint256 got, uint256 attested) {
        // A zero-input leg is a no-op: skip it entirely. A leg scaled to zero
        // input (for example the last leg when the Router holds no remaining
        // input) must never reach pool.swap(): the budget cap in _v3Callback
        // is now UNCONDITIONAL, so a zero cap would revert the whole swap
        // (RouterE 8) instead of no-oping. The residual sweep returns unspent
        // input.
        if (amt == 0) return (0, 0);
        // ─── Per-leg iron floor (see BPC.LEG_FLOOR_BPS) ───
        // Measure THIS leg's real contribution to the Router's tokenOut
        // balance and require >= BPC.LEG_FLOOR_BPS (8.000 = 80%) of its bound. The
        // aggregate floors run only once, at the end of _execute; bounding
        // each leg means a single sandwiched or manipulated pool reverts the
        // swap immediately instead of hiding its loss inside an otherwise
        // healthy total. Purely additive: it can only revert, never relax.
        // Legs without an attested quote (expectedOut == 0) fail open to the
        // aggregate floors — a caller weakening its own crafted route gains
        // nothing that userMinOut and the protocol floor don't already bound.
        address legOut = legOutRaw == tokenIn ? address(0) : legOutRaw;
        // The guard runs if there is ANY floor basis: the caller's attestation OR the quote
        // measured in-frame. It used to require `leg.expectedOut != 0`, and that made it a
        // CALLDATA OPT-OUT — whoever submitted the route switched off their own floor by writing
        // zero, and with it switched off Layer 1 too (which sums these `attested`).
        bool guard = legOut != address(0) && amt != 0
            && ((leg.expectedOut != 0 && leg.amountIn != 0) || (legQuote != 0 && legAmt != 0));
        uint256 balBefore;
        uint256 fotBefore;
        if (guard) {
            balBefore = BPC.balanceOf(legOut, address(this));
            uint256 s0 = TSLOT_FOT;
            assembly { fotBefore := tload(s0) }
        }

        uint8 k = leg.kind;
        // What the venue declares it paid the Router for this leg (DEX-11, read after `got`).
        uint256 declared;
        // Tombstone 3 left this dispatch in the EIP-170 dead-code pass: the venue
        // that lived there did not expose getReserves(), so the old _execV2Amt path
        // always computed outAmt == 0 and reverted RouterE(8). The `else` below
        // reverts directly — same result, fewer bytes.
        if (BPC.kindHas(k, BPC.A_RESERVES)) {
            declared = _execPairAmt(leg, tokenIn, amt, k == BPC.KIND_V2);
        } else if (BPC.kindHas(k, BPC.A_CONC_POOL) || k == BPC.KIND_EXTERNAL) {
            // KIND_EXTERNAL is an IDENTITY, not an attribute: a Gate wrapper speaks the V3
            // swap/callback ABI, so it settles through the same callback and the same
            // measured delta. It has no theta bit, so no reader treats it as a V3 pool.
            // Every door, the best one included (owner's decision 2026-10-22: gated venues at the
            // automatic door; it reverses the explicit-doors-only rule of 2026-10-21): the Solver
            // seats the immutable Gate's wrappers. The calldata's kind is a claim, not an
            // identity: BPC.gateWrapperLive derives the wrapper from the Hub's Gate row and the
            // hop's own tokens and fee.
            if (k == BPC.KIND_EXTERNAL && !BPC.gateWrapperLive(address(hub), leg.pool, tokenIn, legOutRaw, leg.fee))
                revert RouterE(19);
            declared = _execV3Amt(leg, tokenIn, amt);
        } else if (BPC.kindHas(k, BPC.A_CONC_SING)) {
            declared = _execV4Amt(leg, tokenIn, amt);
        } else {
            revert RouterE(8);
        }

        if (guard) {
            got = BPC.balanceOf(legOut, address(this)) - balBefore;
            // DEX-11 (Penpie class). The window above also spans the transfer of the leg input,
            // the venue's callback and the venue's own code: tokenOut that lands on the Router
            // there counted as this leg's output, carried an over-attested leg past the floor
            // below and its attestation into the Hub (_recordHits). The delta may not exceed what
            // the venue declares it paid; less is fine (a fee-on-transfer tokenOut).
            if (got > declared) revert RouterE(20);

            // Base attested by the caller, pro-rata to the amount ACTUALLY spent.
            uint256 bound = (leg.expectedOut != 0 && leg.amountIn != 0)
                ? BPC.mulDiv(leg.expectedOut, amt, leg.amountIn)
                : 0;

            // THE ATTESTATION IS NEVER CAPPED BY THE FRAME. What a leg can pay is
            // settled in the PLAN: a V4 leg's figure is the walk of its pool's own
            // book (Core.v4WalkOut), the same number this frame quotes. Capping the
            // bound here by `legQuote` instead was tried
            // on 2026-09-22 and turned the attestation into a self-consistency
            // check - the in-frame quote is of the pool that EXECUTES, so a
            // substituted pool, or one moved before this call, sets its own
            // floor. test_SubstitutedHook_HonestAttestation_IsRefusedByTheGate
            // went green-to-red on it. The frame may only push this bound UP.

            // ─── COVERAGE GATE ───
            // Measurement does not REPLACE the attestation — it joins it as the second element of
            // a max. If the attestation plausibly covers the quote measured in-frame, the
            // attestation is used and behaviour is byte-for-byte what it is today on honest routes
            // (coverage ~100%). If it does not cover it, the caller deflated itself and the floor
            // comes to rest on the covered share of the measurement: the bound is
            // max(attested, qs * MIN_QUOTE_COVERAGE_BPS / BPS).
            //
            // MONOTONE IN THE ATTESTATION. The gate used to lift a deflated bound to the WHOLE
            // measurement, so an attestation just below the threshold read a floor of `qs` and
            // one just above it a floor of half of that: attesting more lowered the floor. With
            // the bound lifted to the threshold itself, attesting more never lowers it, and the
            // lowest floor a caller can reach is unchanged - attesting exactly at the threshold
            // reached it before.
            //
            // MAX, NOT MIN. On a FLOOR, `min(claimed, measured)` with a deflated claim returns the
            // deflated one — that is, it RELAXES, exactly the attack this is meant to close. For
            // measurement to win on a floor it has to push up, not down. (An earlier design stated
            // I4 correctly and chose the operator that guarantees the opposite.)
            //
            // THE RESCALE IS EXACT where it matters and CONSERVATIVE where it is not. Both loops
            // compute the amount the same way (`mulDiv(leg.amountIn, scaleNum, scaleDen)`), so
            // `amt` and `legAmt` coincide — except when the last leg's clamp fired (the execution
            // loop caps `scaledAmt` to the remaining balance, the quoting one does not). In that
            // case `amt < legAmt` and the pro-rata UNDERSTATES the true quote at the smaller
            // amount, because the quote curve is concave. Understating the floor fails OPEN: it
            // never invents a limit that honest execution cannot meet.
            //
            // FAILS OPEN when THERE IS NO MEASUREMENT — never when the caller asks for it. A venue
            // with no quote (dead pool, unreadable fee) gives `legQuote == 0` and the gate does not
            // run; the absence of a measurement does not become a value.
            //
            // THE THRESHOLD is the one that already exists: MIN_QUOTE_COVERAGE_BPS = 5,000. An
            // honest route would have to quote below HALF of what was measured to trip it — that
            // is not a precision drift, it is deliberate deflation. Zero new constants.
            if (legQuote != 0 && legAmt != 0) {
                uint256 qs = BPC.mulDiv(legQuote, amt, legAmt);
                uint256 covered = BPC.mulDiv(qs, MIN_QUOTE_COVERAGE_BPS, BPC.BPS);
                if (bound < covered) bound = covered;
            }

            // ─── RE-PRICE BY THE FoT MEASUREMENT ───
            // `bound` is GROSS: it comes out of `outV2(legAmt)` or `leg.expectedOut`, and both
            // price what was INTENDED to be sent. `got` is NET — a balanceOf delta. With an INPUT
            // tax of t, the pool only receives (1-t) and delivers ~(1-t) of the gross quote.
            // Comparing the two rejects a PERFECTLY CORRECT settlement as soon as t passes 20%.
            //
            // THE PROOF WAS ALREADY WRITTEN IN THE SIBLING CHANNEL. The aggregate floor (see
            // `protocolFloorOut`) already documents the same defect and already fixed it with this
            // same ratio, threshold included. It was a fix applied to ONE of THREE symmetric
            // channels — and the third, Layer 1, is cured here for free because it sums this
            // `attested`. Worse, the two reasoned about each other inconsistently: the aggregate
            // floor invokes "the per-leg BPC.LEG_FLOOR_BPS guard at every pool seam" as one of the
            // barriers that cover it, and that guard did not know FoT existed.
            //
            // THE MEASUREMENT IS UNFORGEABLE, and that is why THIS is the right remedy. `_noteFot`
            // records a ratio observed INSIDE this transaction (what the pool received / what was
            // sent to it). Nobody writes it by calldata. The tempting alternative — not running the
            // gate when the caller asks — would restore the calldata opt-out this gate exists to
            // close: at the decision point, the honest caller of a taxed token and the attacker
            // deflating itself present the SAME calldata. No predicate separates them. A
            // measurement separates them. The measurement is what is used.
            //
            // RATIO LOCAL TO THE LEG, not the compound one. `_noteFot` COMPOSES multiplicatively
            // along the route (each tax applies to what survived the previous one), but this leg's
            // `bound` was skewed only by THIS leg's tax. It is recovered by difference from the
            // snapshot: if `prev != 0`, then `after = prev * local / BPS`, hence
            // `local = after * BPS / prev`. mulDiv rounds down, so the recovered local is <= the
            // true one: it understates the discount, tightens the floor, fails OPEN.
            //
            // HONEST SCOPE: `_noteFot` is only called on the V2 and SOLIDLY arms, and measures only
            // the INPUT side. A V3/V4 leg with a FoT token records nothing, and an OUTPUT-side tax
            // is not measured anywhere. This closes what is measurable.
            {
                uint256 s1 = TSLOT_FOT;
                uint256 fotAfter; assembly { fotAfter := tload(s1) }
                if (fotAfter != fotBefore && bound != 0) {
                    uint256 legNet = fotBefore == 0
                        ? fotAfter
                        : BPC.mulDiv(fotAfter, BPC.BPS, fotBefore);
                    if (legNet < BPC.BPS) bound = BPC.mulDiv(bound, legNet, BPC.BPS);
                }
            }

            attested = bound;
            // R-C: a protective threshold never rounds DOWN. floor(1 * 0.8) is 0,
            // and `got < 0` cannot fire, so a one-wei bound demanded zero delivery.
            // The executor's own zero-output refusal dominates that window today,
            // so this is defence in depth rather than a live hole — but a guard
            // whose threshold can be zero is a guard that switches itself off, and
            // reachability is not something to rely on staying closed.
            if (bound != 0 && got < BPC.mulDivUp(bound, BPC.LEG_FLOOR_BPS, BPC.BPS)) revert RouterE(5);
        }
    }

    /// @notice Resolves BOTH tokens of a leg in a SINGLE read of the pair: a pair read for the
    ///         pool-shaped kinds, `auxId` for V4 (whose `pool` field is not a pair). The caller
    ///         converts `legOut == tokenIn` into address(0) — in that case the leg fails OPEN for
    ///         the aggregate floors (the per-leg guard is an extra limit, never an execution
    ///         gate).
    ///
    /// @dev    THERE WERE TWO FUNCTIONS, `_legTokenIn` and `_legTokenOut`, and each one read
    ///         `token0()` and `token1()` OF THE SAME POOL, in the SAME frame, to keep one of the
    ///         two and throw the other away. Two hot staticcalls per non-V4 leg, ~740 gas each.
    ///         Measured end to end: −1,498 (1 leg) up to −7,355 (5 legs, −1.65% of the tx), and
    ///         the Router shrinks by 58 bytes. It applies to BOTH entry points.
    ///
    ///         AND IT IS NOT ONLY GAS — the merge CLOSES A CRACK. With two separate reads, a
    ///         malicious pool can answer DIFFERENT `token0()/token1()` on the second call and
    ///         fabricate `legOut == tokenIn`, which set the per-leg floor itself to address(0),
    ///         i.e. switched it off. An atomic snapshot makes that inexpressible: both tokens
    ///         come from the same pair of reads or from neither. House doctrine says MEASURE and
    ///         do not derive; here the two reads were the SAME measurement taken twice, and
    ///         repeating a measurement the adversary controls is not prudence — it is surface.
    function _legTokens(Leg calldata leg) private view returns (address legIn, address legOut) {
        if (BPC.kindHas(leg.kind, BPC.A_CONC_SING)) {
            return (address(0), address(uint160(uint256(leg.auxId))));
        }
        address t0 = BPC.token0Of(leg.pool);
        address t1 = BPC.token1Of(leg.pool);
        legIn  = leg.zeroForOne ? t0 : t1;
        legOut = leg.zeroForOne ? t1 : t0;
    }

    /// @notice Resolve the actual tokenIn for a leg by inspecting its pool.
    ///         This is robust against bridge collapsing where two stages with
    ///         different token pairs share a single hop wrapper.

    /// @notice Record a measured fee-on-transfer NET ratio (bps) for this
    ///         swap in transient storage. TSLOT_FOT == 0 means "no FoT seen";
    ///         otherwise it holds the compounded measured net ratio, clamped
    ///         to [1, BPS] so a nonzero write always keeps the flag set and
    ///         can never inflate the floor. Multiple FoT hops compound
    ///         multiplicatively (each hop's fee applies to what survived the
    ///         previous one).
    function _noteFot(uint256 netBps) private {
        if (netBps == 0) netBps = 1;
        if (netBps > BPC.BPS) netBps = BPC.BPS;
        uint256 sF = TSLOT_FOT;
        uint256 prev; assembly { prev := tload(sF) }
        if (prev != 0) netBps = BPC.mulDiv(prev, netBps, BPC.BPS);
        if (netBps == 0) netBps = 1;
        assembly { tstore(sF, netBps) }
    }

    /// @dev EXPERIMENT: fused push-then-swap engine (V2 + Solidly). Same
    ///      liquidation ABI (IUniswapV2Pair.swap), same FoT measurement block,
    ///      differing only in outAmt derivation, selected by isV2.
    /// @return outAmt the output the Router asks of the pair: what the pair declares it pays (DEX-11).
    function _execPairAmt(Leg calldata leg, address tokenIn, uint256 amt, bool isV2)
        private returns (uint256 outAmt)
    {
        uint256 rIn; uint256 rOut;
        if (isV2) {
            (uint256 r0, uint256 r1) = BPC.getReserves(leg.pool);
            rIn  = leg.zeroForOne ? r0 : r1;
            rOut = leg.zeroForOne ? r1 : r0;
        }
        uint256 balBefore = BPC.balanceOf(tokenIn, leg.pool);
        BPC.safeTransfer(tokenIn, leg.pool, amt);
        uint256 askIn = amt;
        // ONE read of the post-transfer balance, used twice. The two subtractions are different
        // (`balBefore` says how much ARRIVED; `rInB` says how much has not yet been synced into
        // reserves), but the MINUEND is the same, and it used to be read twice.
        //
        // PROOF THAT THE CACHE IS LEGITIMATE, and not doctrine violated: the house says MEASURE
        // and do not derive, which is why nothing is cached across a transfer (FoT/rebasing change
        // the balance). Here there is no transfer between the two reads — there is a
        // `getReserves`, and both it and the `balanceOf` are STATICCALLs (see the assembly in
        // Core). The EVM forbids state mutation inside a staticcall, so the second value was EQUAL
        // to the first by rule of the machine, not by an assumption of ours.
        uint256 balAfter = BPC.balanceOf(tokenIn, leg.pool);
        if (balAfter - balBefore != amt) {
            (uint256 r0b, uint256 r1b) = BPC.getReserves(leg.pool);
            uint256 rInB = leg.zeroForOne ? r0b : r1b;
            uint256 realIn = balAfter - rInB;
            if (realIn == 0) revert RouterE(8);
            askIn = realIn;
            if (isV2) { rIn = rInB; rOut = leg.zeroForOne ? r1b : r0b; }
            _noteFot(BPC.mulDiv(realIn, BPC.BPS, amt));
        }
        if (isV2) {
            outAmt = BPC.outV2(askIn, rIn, rOut, BPC.effV2Fee(leg.fee));
        } else {
            // The same producer the quote channel promises (Core.solidlyAskOut).
            outAmt = BPC.solidlyAskOut(leg.pool, askIn, tokenIn, leg.zeroForOne, leg.stable, leg.fee);
        }
        if (outAmt == 0) revert RouterE(8);
        uint256 a0 = leg.zeroForOne ? 0 : outAmt;
        uint256 a1 = leg.zeroForOne ? outAmt : 0;
        IUniswapV2Pair(leg.pool).swap(a0, a1, address(this), "");
    }

    /// @return declared the out side the pool (or Gate wrapper) returns from swap, negated (DEX-11).
    function _execV3Amt(Leg calldata leg, address tokenIn, uint256 amt) private returns (uint256 declared) {
        uint256 sP = TSLOT_POOL;
        uint256 sT = TSLOT_TOKEN;
        uint256 sA = TSLOT_AMT;
        address pool = leg.pool;
        // Record the max input the callback is allowed to pull. A V3-shaped
        // pool that demands more than `amt` is rejected.
        assembly { tstore(sP, pool) tstore(sT, tokenIn) tstore(sA, amt) }
        uint160 limit = leg.zeroForOne
            ? BPC.MIN_SQRT_PRICE_PLUS_ONE
            : BPC.MAX_SQRT_PRICE_MINUS_ONE;
        (int256 a0, int256 a1) = IUniswapV3PoolMin(pool).swap(
            address(this), leg.zeroForOne, int256(amt), limit, ""
        );
        assembly { tstore(sP, 0) tstore(sT, 0) tstore(sA, 0) }
        // The pool pays the out side, so it comes back negative; a non-negative one declares nothing.
        int256 o = leg.zeroForOne ? a1 : a0;
        unchecked { if (o < 0) declared = uint256(-o); }
    }

    /// @return declared the amount unlockCallback took from the PoolManager (DEX-11).
    function _execV4Amt(Leg calldata leg, address tokenIn, uint256 amt) private returns (uint256 declared) {
        address mgr = hub.v4PoolManager();
        if (mgr == address(0)) revert RouterE(8);
        if (leg.hooks != address(0)) {
            // Delta-hooks stay blocked: the vanilla V4 quote cannot price custom
            // accounting, so quote would diverge from execution.
            if (BPC.hookAltersDeltas(leg.hooks)) revert RouterE(9);
            // Layer 2/3 for a hook that RUNS IN THE SWAP (beforeSwap or afterSwap
            // bit): refused while PAUSED — revoked by the curator, or listed and
            // its own runtime moved since the pin (redeploy; a delegate proxy's
            // implementation swap is not visible, see Hub.isHookLive). A hook nobody
            // listed is the caller's signed choice on this door, bounded like every
            // venue by the in-frame promise, the attestation gate and userMinOut;
            // the automatic door never proposes it (registry reads filter by
            // isHookLive). A hook with no swap bit is never entered by ITS pool's
            // swap and needs neither list nor pin. It can still run inside this
            // unlock through a nested PoolManager call made by a hook that does
            // run here - a donate, a swap or a liquidity change on any pool reaches
            // that pool's hooks. What bounds it is the manager's own flash
            // accounting (a delta left unsettled reverts the whole unlock, measured
            // on Base: test/fork/NestedHookSettlementFork.t.sol), the same floors,
            // and the admission of the hook that makes the call.
            if (BPC.hookRunsInSwap(leg.hooks) && hub.hookPaused(leg.hooks)) revert RouterE(9);
        }
        // V4 has no pool address — leg.pool holds the truncated poolId, not a
        // token. The counterpart currency travels in auxId (low 160 bits).
        address tokenOther = address(uint160(uint256(leg.auxId)));
        if (tokenOther == address(0)) revert RouterE(8);
        uint256 sI = TSLOT_V4IN;
        uint256 sO = TSLOT_V4OUT;
        // Transient context FIRST, with the ERC20 (WETH-canonical) addresses:
        // the callback settles/wraps through these, never through the mapped
        // currencies. Stored before the native checks below on purpose — a
        // revert rolls tstores back (EIP-1153 revert semantics), and mutating
        // tokenIn/tokenOther in place after the store spends zero extra stack
        // slots in a frame the via-IR pipeline keeps razor-thin.
        assembly { tstore(sI, tokenIn) tstore(sO, tokenOther) }
        if (leg.kind == BPC.KIND_V4_NATIVE) {
            // Native pool: the side equal to the canonical WETH maps to
            // currency address(0) in the pool key. Fail-closed (8) when weth
            // is unwired or NEITHER side is the real WETH — auxId is caller
            // calldata, and the callback's unwrap/wrap must only ever touch
            // the canonical WETH contract, never an attacker-named token.
            (tokenIn, tokenOther) = BPC.nativeMapVerified(tokenIn, tokenOther, weth);
            if (tokenIn == address(0) && tokenOther == address(0)) revert RouterE(8);
        }
        (address c0, address c1) = BPC.sortTokens(tokenIn, tokenOther);
        // ROUTE SELF-CONSISTENCY (BPX-2026-009): a V4 leg's fields must agree with
        // each other. Its direction is the direction of its tokens (zeroForOne
        // is true exactly when the input is currency0), so a flipped direction is
        // refused here rather than left to the manager's settlement accounting;
        // and the pool a V4 leg NAMES must be the pool its key EXECUTES. leg.pool carries the truncated poolId the
        // Solver and Quoter derive from (c0, c1, fee, tickSpacing, hooks); a
        // route whose hooks (or fee, spacing, counterpart) were swapped after
        // the quote no longer derives to that id and is refused before any
        // token moves. A route that lies consistently in every field is the
        // caller's signed intent and is bounded, as every route is, by the
        // in-frame promise, the attestation gate and userMinOut.
        if (leg.zeroForOne != (tokenIn == c0)) revert RouterE(11);
        if (leg.pool != address(uint160(uint256(BPC.computeV4PoolId(c0, c1, leg.fee, leg.tickSpacing, leg.hooks))))) revert RouterE(11);
        IV4PoolManager.V4PoolKey memory key = IV4PoolManager.V4PoolKey({
            currency0: c0, currency1: c1, fee: leg.fee,
            tickSpacing: leg.tickSpacing, hooks: leg.hooks
        });
        // The PoolManager returns unlockCallback's bytes unchanged (v4-core PoolManager.unlock).
        declared = abi.decode(
            IV4PoolManager(mgr).unlock(abi.encode(key, leg.zeroForOne, amt, bytes(""))), (uint256)
        );
        assembly { tstore(sI, 0) tstore(sO, 0) }
    }

    // =========================================================================
    //  UNIVERSAL CALLBACK FALLBACK
    //
    //  Any V3-shaped callback (Uniswap V3, PancakeSwap V3, SushiSwap V3,
    //  Algebra, DackieSwap V3, SolidV3, …) hits this fallback. The callback's
    //  selector is irrelevant — what matters is that the calldata layout is
    //  (int256, int256, bytes) and the caller is the committed pool.
    // =========================================================================

    fallback() external payable {
        if (msg.value > 0) revert RouterE(3);
        if (msg.data.length < 4 + 64) revert RouterE(3);
        int256 a0;
        int256 a1;
        assembly {
            a0 := calldataload(4)
            a1 := calldataload(36)
        }
        _v3Callback(a0, a1);
    }

    // receive(): the ONE narrow surface through which the Router can be paid
    // raw ETH — and only mid-flight inside a native-V4 unlock. TSLOT_ETHOK
    // holds the exact address allowed to send at this instant (the canonical
    // WETH during the JIT unwrap, the V4 PoolManager during a native take —
    // see unlockCallback) and is zero at every other moment, so a bare
    // transfer from ANYONE else — mid-unlock strangers included — reverts
    // RouterE(3) exactly as the receive()-less Router did. The "no silently
    // trapped ETH" property is preserved: outside the two flag windows the
    // Router cannot be paid ETH at all, and inside them the same callback
    // frame immediately settles or wraps the exact amount, leaving nothing at
    // rest. A zero-value empty-calldata call also reverts (flag is 0), which
    // matches the old fall-through-to-fallback behaviour bit for bit. Kept to
    // one tload + compare so it runs inside the 2300-gas stipend of WETH9's
    // transfer()-based withdraw. (Supersedes the "deliberately no receive()"
    // doctrine of vault note "053 - Primitiva de ETH Nativo como WETH": the
    // guarded window is the sealed native-V4 design, not an open door.)
    receive() external payable {
        uint256 sE = TSLOT_ETHOK;
        uint256 ok; assembly { ok := tload(sE) }
        if (ok == 0 || msg.sender != address(uint160(ok))) revert RouterE(3);
    }

    function _v3Callback(int256 a0, int256 a1) private {
        uint256 sP = TSLOT_POOL;
        uint256 sT = TSLOT_TOKEN;
        uint256 sA = TSLOT_AMT;
        address expected;
        address tIn;
        uint256 maxAmt;
        assembly { expected := tload(sP) tIn := tload(sT) maxAmt := tload(sA) }
        if (msg.sender != expected || expected == address(0)) revert RouterE(6);
        // Two callback forms: a delta pair (V3 / Algebra: owed = the positive delta), or a
        // token-named one (first word = the context's tokenIn, owed = the second word). A
        // negative delta never equals an address; a negative named amount reads as a uint above
        // maxAmt and is refused below.
        uint256 owed = uint256(a0) == uint256(uint160(tIn)) ? uint256(a1)
            : (a0 > 0 ? uint256(a0) : (a1 > 0 ? uint256(a1) : 0));
        if (owed == 0) revert RouterE(8);
        // The pool can never demand more than the input this leg was given.
        // A zero-input leg never reaches swap() (see _execScaled), so a zero
        // maxAmt is a forged/stale context and owed > 0 reverts (fail-closed).
        if (owed > maxAmt) revert RouterE(8);
        // Single-shot (checks-effects-interactions): clear the transient auth
        // context BEFORE paying, so a pool that re-enters this callback reads
        // expected == 0 on the second entry and reverts(6) — no multi-pull.
        assembly { tstore(sP, 0) tstore(sT, 0) tstore(sA, 0) }
        // Pay exactly what the pool demands, then verify it MEASURABLY received
        // it. V3 pools cannot absorb fee-on-transfer tokenIn (their own pre/post
        // balance check reverts opaquely), so fail closed with a distinct,
        // actionable error: RouterE(13) = V3 does not support FoT tokenIn --
        // route via V2/Solidly, which handle FoT natively (owner decision
        // 2026-08-10: FoT = route-where-natural). Meta-law: trust the measured
        // balance delta at the seam of action, not the nominal transfer.
        uint256 bal0 = BPC.balanceOf(tIn, msg.sender);
        BPC.safeTransfer(tIn, msg.sender, owed);
        if (BPC.balanceOf(tIn, msg.sender) - bal0 < owed) revert RouterE(13);
    }

    /// @notice V4 unlockCallback — invoked by the PoolManager after unlock().
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        address mgr = hub.v4PoolManager();
        if (msg.sender != mgr) revert RouterE(6);
        (IV4PoolManager.V4PoolKey memory key, bool zfo, uint256 amt, bytes memory hookData)
            = abi.decode(data, (IV4PoolManager.V4PoolKey, bool, uint256, bytes));
        uint256 sI = TSLOT_V4IN;
        uint256 sO = TSLOT_V4OUT;
        address tIn;
        address tOut;
        assembly { tIn := tload(sI) tOut := tload(sO) }
        if (tIn == address(0) || tOut == address(0)) revert RouterE(6);
        IV4PoolManager.SwapParams memory p = IV4PoolManager.SwapParams({
            zeroForOne:        zfo,
            amountSpecified:   -int256(amt),
            sqrtPriceLimitX96: zfo ? BPC.MIN_SQRT_PRICE_PLUS_ONE : BPC.MAX_SQRT_PRICE_MINUS_ONE
        });
        int256 bd = IV4PoolManager(mgr).swap(key, p, hookData);
        // V4 returns a packed BalanceDelta: amount0 high 128 bits, amount1 low
        // 128 bits, each int128. The mock returned two int256s; the real
        // PoolManager packs them. This was only visible on a real fork.
        int256 d0 = int256(int128(bd >> 128));
        int256 d1 = int256(int128(bd));
        int256 owedDelta     = zfo ? d0 : d1;
        int256 receivedDelta = zfo ? d1 : d0;
        if (owedDelta > 0 || receivedDelta < 0) revert RouterE(8);
        uint256 owe  = uint256(-owedDelta);
        uint256 recv = uint256(receivedDelta);
        // The pool cannot demand more input than the amount committed to this
        // leg — mirrors the V3 callback's maxAmt cap. Bounds a malicious pool
        // or hook to the current leg's budget so it cannot pull the input
        // budgeted to sibling legs.
        if (owe > amt) revert RouterE(8);
        // Single-shot (checks-effects-interactions): clear the transient unlock
        // context before settling, so any re-entry into this callback reads
        // tIn == 0 and reverts(6).
        assembly { tstore(sI, 0) tstore(sO, 0) }
        // ─── Native-ETH JIT seam (KIND_V4_NATIVE) ───
        // key.currency0 == address(0) marks a native pool (currency1 can never
        // be native: address(0) sorts first and currencies are distinct). The
        // route still speaks WETH — tIn/tOut above are the ERC20 addresses,
        // and _execV4Amt has already proven the mapped side IS the canonical
        // WETH. Input native (zfo): unwrap exactly `owe` and settle with
        // value — native settle takes NO sync. Output native (!zfo): take raw
        // ETH and wrap it back into WETH inside this same frame, so outside
        // this seam the pipeline sees only WETH balances and every existing
        // balance-delta measurement (per-leg floor, toutStart, sweeps) keeps
        // working unchanged. TSLOT_ETHOK opens receive() to exactly one
        // sender for exactly one call, closed again before anything else runs.
        uint256 sE = TSLOT_ETHOK;
        if (key.currency0 == address(0) && zfo) {
            assembly { tstore(sE, tIn) }
            IWETH(tIn).withdraw(owe);
            assembly { tstore(sE, 0) }
            IV4PoolManager(mgr).settle{value: owe}();
        } else {
            IV4PoolManager(mgr).sync(tIn);
            BPC.safeTransfer(tIn, mgr, owe);
            IV4PoolManager(mgr).settle();
        }
        if (key.currency0 == address(0) && !zfo) {
            assembly { tstore(sE, mgr) }
            IV4PoolManager(mgr).take(address(0), address(this), recv);
            assembly { tstore(sE, 0) }
            IWETH(tOut).deposit{value: recv}();
        } else {
            IV4PoolManager(mgr).take(tOut, address(this), recv);
        }
        return abi.encode(recv);
    }

    // =========================================================================
    //  HUB FEEDBACK
    // =========================================================================

    /// @param executedMask bit i set iff the i-th leg of the route reached its
    ///        pool. This walk used to credit EVERY leg declared in calldata,
    ///        with no check that any of them ran. Hop scaling can round a leg's
    ///        input to zero, `_execScaled` then skips the pool call entirely,
    ///        and the Hub still bumped the swap counter, refreshed the
    ///        timestamp and rewrote the depth bucket for a pool that never
    ///        moved a token. Those fields feed psi, and psi decides which pools
    ///        the Solver may quote — so two ordinary swaps carrying one-wei
    ///        phantom declarations could fabricate fitness and push a fair pool
    ///        out of the funnel. `Hub.recordSwap` only ever guarded `amtIn == 0`
    ///        on the RAW calldata amount, which a one-wei declaration passes.
    ///        Reported by Thomas.
    function _recordHits(Route calldata route, uint256 executedMask,
                         uint256[] memory hopScale) private {
        address v4mgr;
        uint256 legIdx;
        for (uint256 h; h < route.hops.length; ) {
            Hop calldata hop = route.hops[h];
            for (uint256 l; l < hop.legs.length; ) {
                bool ran = executedMask & (uint256(1) << legIdx) != 0;
                unchecked { ++legIdx; }
                Leg calldata leg = hop.legs[l];
                // A kind-9 leg has one vitality producer, its wrapper (`swap` ticks `vitalSlot`,
                // read by Gate.vitalOf), and Hub.recordSwap discards kind 9 (KINDS_EXECUTABLE):
                // the depth read and the call were gas with no effect.
                if (!ran || leg.kind == BPC.KIND_EXTERNAL) { unchecked { ++l; } continue; }
                // t0/t1 are always derivable from the hop's own tokenIn/
                // tokenOut via zeroForOne — every leg in a hop trades the
                // same pair by construction, so no staticcall is needed here
                // for ANY kind (a prior version re-derived this via
                // token0Of/token1Of for non-V4 legs: redundant, since
                // calldata already determines it).
                address t0 = leg.zeroForOne ? hop.tokenIn  : hop.tokenOut;
                address t1 = leg.zeroForOne ? hop.tokenOut : hop.tokenIn;
                // THE ROW THIS SWAP TICKS IS THE POOL THAT EXECUTED. For the pair and
                // concentrated-pool families that is `leg.pool` itself - execution swaps against
                // it, so the identity is confirmed by the swap. A V4 pool has no address:
                // `_execV4Amt` keys it by (tokenIn, auxId, fee, tickSpacing, hooks), so the row is
                // keyed on the DERIVED poolId, the same identity the quote and the swap used.
                // `regPool` starts as the leg's field and is replaced by the derivation on that
                // family. The depth handed with it is measured from that same poolId, so the
                // registry receives a measurement under the identity it was measured on -
                // which is what `_topKPools` ranks by and `_canInsert` evicts by.
                address regPool = leg.pool;
                bytes32 pid;
                if (BPC.kindHas(leg.kind, BPC.A_CONC_SING)) {
                    // leg.pool is the truncated poolId-as-address (no bytecode). Recompute the
                    // real bytes32 poolId from (t0, t1, fee, tickSpacing, hooks) - t0/t1 above are
                    // already the pool's real (currency0, currency1) ordering by construction of
                    // zeroForOne. For a native pool t0 is the WETH side by that same construction
                    // (the leg executed, so _execV4Amt proved it), and the pool's real currency0
                    // is address(0) - substitute it, keeping this pid identical to the one quote
                    // and execution used.
                    if (v4mgr == address(0)) v4mgr = hub.v4PoolManager();
                    pid = leg.kind == BPC.KIND_V4_NATIVE
                        ? BPC.computeV4PoolId(address(0), t1, leg.fee, leg.tickSpacing, leg.hooks)
                        : BPC.computeV4PoolId(t0, t1, leg.fee, leg.tickSpacing, leg.hooks);
                    // The pool that executed, not the pool that was named. Same `pid`
                    // the quote and the swap used, truncated the way the registry
                    // stores a V4 row everywhere else (`Hub.claimV4`, `_admitV4`).
                    regPool = address(uint160(uint256(pid)));
                }
                // ONE PRODUCER of the depth every registry door seals (Core.registryDepth18):
                // the operator's door measures with it too since the ninth wave (dex-17). The
                // per-family rules, and the defects that shaped them, live with the code there.
                uint256 depth = BPC.registryDepth18(leg.pool, leg.kind, t0, t1, v4mgr, pid);
                // MEASURED, NOT DECLARED (VOL_01). `leg.amountIn` is what the caller
                // asked for; `leg.amountIn x hopScale[h]` is what the hop was able to spend
                // after the protocol fee and after any capacity clamp. The quote is scaled by
                // the same ratio so the pair stays dimensionally consistent: the input is a
                // measurement, and the output is that measurement priced by the plan.
                uint256 sc  = hopScale[h];
                uint256 inM = BPC.mulDiv(leg.amountIn,    sc, 1e18);
                uint256 outM = BPC.mulDiv(leg.expectedOut, sc, 1e18);
                try hub.recordSwap(
                    regPool, leg.kind, leg.fee, leg.hooks,
                    t0, t1, inM, outM, depth
                ) {} catch {}
                unchecked { ++l; }
            }
            unchecked { ++h; }
        }
    }
}
