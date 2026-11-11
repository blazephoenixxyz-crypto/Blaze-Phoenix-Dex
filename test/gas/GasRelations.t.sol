// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// GAS RELATIONS. Each test pins a relation between gas figures measured in the same test, never a
// ceiling. The relation is derived in the comment above its assert, by counting first touches and
// pricing them with surcharges measured in the test itself. Each relation also names the mutant in
// `.github/scripts/mutants.py` (`gas-1106 G6-n`) that turns it red. Every relation here was run red
// under its mutant and green on the unmutated tree, and each mutant leaves its test's fixture
// checks green.
//
// Instrument. `GasMeter.measure` runs its calls inside one transaction and reads `gas()` around each
// inner CALL. A figure is therefore the callee's execution plus the CALL's own access cost; the 21000
// intrinsic gas and the calldata price fall outside every window. The suite runs in isolation mode
// (`isolate = true` in foundry.toml, asserted by `_instruments`), where each top-level call is its
// own transaction: every `measure` starts from a cold access list, and warmth carries only between
// the calls of one `measure`.
//
// Surcharges. `sAcct` and `sSload` are the cold-minus-warm prices of an account and of a storage
// word, measured with `SlotProbe`; no fee schedule is typed in. A relation that counts k first
// touches asks for at least k surcharges, at whatever price the fork sets.
//
// Snapshots. Every series is recorded with `vm.snapshotValue(<test name>, "<series>_<n>", gas)`, so a
// moved figure shows in `snapshots/<test name>.json`. The fixture checks that make a figure
// meaningful run before the relations, so a mutant that fails with a relation's message has passed
// every fixture check: the relation, not the fixture, is what catches it.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo, RoutePlan} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";
import {MockV2Factory} from "../mocks/MockV2Factory.sol";
import {MockV3BookPool} from "../mocks/MockV3BookPool.sol";
import {QuoteWorld} from "../QuoteWorld.sol";
import {SolveWorld} from "../SolveBuildsEachPairOnce.t.sol";

/// Runs calls inside one transaction and measures each inner CALL with `gas()`.
contract GasMeter {
    function exec(address to, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
    }

    /// `used[i]` is the gas of call i alone; `last` is the return data of the last call.
    function measure(address[] calldata to, bytes[] calldata data)
        external returns (uint256[] memory used, bytes memory last)
    {
        used = new uint256[](data.length);
        for (uint256 i; i < data.length; ++i) {
            address t = to[i];
            bytes memory d = data[i];
            uint256 g;
            bool ok;
            assembly ("memory-safe") {
                g := gas()
                ok := call(gas(), t, 0, add(d, 32), mload(d), 0, 0)
                g := sub(g, gas())
            }
            used[i] = g;
            uint256 n;
            assembly ("memory-safe") { n := returndatasize() }
            last = new bytes(n);
            assembly ("memory-safe") { returndatacopy(add(last, 32), 0, n) }
            if (!ok) assembly ("memory-safe") { revert(add(last, 32), n) }
        }
    }
}

/// Two stored words, read through one function, to price a cold account and a cold word.
contract SlotProbe {
    mapping(uint256 => uint256) public word;

    constructor() {
        word[1] = 1;
        word[2] = 2;
    }

    function read(uint256 k) external view returns (uint256) {
        return word[k];
    }
}

/// The library walk over a tick book, behind one external call so the meter can window it.
contract BookWalkProbe {
    function walk(address pool, uint256 amountIn, bool zeroForOne) external view returns (uint256) {
        return BPC.v4WalkOut(pool, bytes32(0), amountIn, 0, 0, zeroForOne);
    }
}

abstract contract GasInstruments is Test {
    GasMeter internal meter;
    SlotProbe internal slotProbe;

    function _instruments() internal {
        assertTrue(vm.isIsolateMode(), "GasMeter windows need isolate: each top-level call is its own transaction");
        meter = new GasMeter();
        slotProbe = new SlotProbe();
    }

    /// In one transaction: read(1) pays a cold account and a cold word, read(1) again pays neither,
    /// read(2) pays the cold word only.
    function _surcharges(string memory g) internal returns (uint256 sAcct, uint256 sSload) {
        address[] memory to = new address[](3);
        bytes[] memory d = new bytes[](3);
        for (uint256 i; i < 3; ++i) to[i] = address(slotProbe);
        d[0] = abi.encodeCall(slotProbe.read, (1));
        d[1] = d[0];
        d[2] = abi.encodeCall(slotProbe.read, (2));
        (uint256[] memory u,) = meter.measure(to, d);
        sSload = u[2] - u[1];
        sAcct = u[0] - u[2];
        vm.snapshotValue(g, "s_acct", sAcct);
        vm.snapshotValue(g, "s_sload", sSload);
    }

    function _gas(address to, bytes memory data) internal returns (uint256 used, bytes memory ret) {
        address[] memory t = new address[](1);
        bytes[] memory d = new bytes[](1);
        t[0] = to;
        d[0] = data;
        uint256[] memory u;
        (u, ret) = meter.measure(t, d);
        used = u[0];
    }

    /// The same call twice in one transaction: first on a cold access list, then on the list the
    /// first call left warm. `ret` is what the second call returned.
    function _gas2(address to, bytes memory data) internal returns (uint256 cold, uint256 warm, bytes memory ret) {
        address[] memory t = new address[](2);
        bytes[] memory d = new bytes[](2);
        t[0] = to;
        t[1] = to;
        d[0] = data;
        d[1] = data;
        uint256[] memory u;
        (u, ret) = meter.measure(t, d);
        cold = u[0];
        warm = u[1];
    }

    function _record(string memory g, string memory series, uint256 i, uint256 v) internal {
        vm.snapshotValue(g, string.concat(series, "_", vm.toString(i)), v);
    }
}

/// n legs of one A -> B hop, each through its own twin pool, with registry feedback live and with
/// the Hub paused.
contract GasRelationsSwapTest is QuoteWorld, GasInstruments {
    uint256 constant TWINS = 5;
    uint256 constant LEG_IN = 1_000e18;
    MockV2Pair[] internal twins;

    function setUp() public {
        _world(false);
        _instruments();
        for (uint256 i; i < TWINS; ++i) {
            MockV2Pair p = _pool(A, B, 100_000e18, 160_000e18);
            hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(A), address(B));
            twins.push(p);
        }
        A.mint(address(meter), 1_000 * LEG_IN);
        meter.exec(address(A), abi.encodeCall(A.approve, (address(router), type(uint256).max)));
        // One swap through every twin writes every row and balance once, so each measured swap
        // rewrites words that already hold a value. The clock then moves, so every rewrite of a row
        // changes its word.
        meter.exec(
            address(router),
            abi.encodeCall(router.swapExactIn, (_legs(TWINS), TWINS * LEG_IN, 1, user, block.timestamp + 1))
        );
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
    }

    function _legs(uint256 n) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](n);
        uint256 q;
        for (uint256 i; i < n; ++i) {
            legs[i] = _handRoute(twins[i], address(A), address(B), LEG_IN).hops[0].legs[0];
            q += legs[i].expectedOut;
        }
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B), amountIn: n * LEG_IN, expectedOut: q, legs: legs});
        r = Route({hops: hops, totalOut: q, singleOut: 0, singleOutFloor: 0, expectedImpactBps: 0,
                   confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false});
    }

    function _swapGas(Route memory r, uint256 amt) internal returns (uint256 used, uint256 out) {
        address tOut = r.hops[r.hops.length - 1].tokenOut;
        uint256 s = vm.snapshotState();
        uint256 before = MockERC20(tOut).balanceOf(user);
        bytes memory ret;
        (used, ret) = _gas(address(router), abi.encodeCall(router.swapExactIn, (r, amt, 1, user, block.timestamp + 1)));
        out = abi.decode(ret, (uint256));
        assertEq(MockERC20(tOut).balanceOf(user) - before, out, "fixture: the door returns what the recipient received");
        vm.revertToState(s);
    }

    /// live(n) and paused(n): the same n-leg swap on the same state, with the Hub live and paused.
    function _feedbackSeries(string memory g)
        internal
        returns (uint256[] memory live, uint256[] memory paused, uint256[] memory outLive, uint256[] memory outPaused)
    {
        live = new uint256[](TWINS + 1);
        paused = new uint256[](TWINS + 1);
        outLive = new uint256[](TWINS + 1);
        outPaused = new uint256[](TWINS + 1);
        for (uint256 n = 1; n <= TWINS; ++n) {
            Route memory r = _legs(n);
            (live[n], outLive[n]) = _swapGas(r, n * LEG_IN);
            uint256 s = vm.snapshotState();
            hub.setPaused(true);
            (paused[n], outPaused[n]) = _swapGas(r, n * LEG_IN);
            vm.revertToState(s);
            _record(g, "live", n, live[n]);
            _record(g, "paused", n, paused[n]);
        }
    }

    function _sameDelivery(uint256[] memory outLive, uint256[] memory outPaused) internal pure {
        for (uint256 n = 1; n <= TWINS; ++n) {
            assertEq(outPaused[n], outLive[n], "fixture: a paused Hub changes no delivery");
        }
    }

    function test_GasRelation_SwapIsStrictlyMonotoneInLegs() public {
        string memory g = "test_GasRelation_SwapIsStrictlyMonotoneInLegs";
        (, uint256 sSload) = _surcharges(g);
        (uint256[] memory live, uint256[] memory paused, uint256[] memory outLive, uint256[] memory outPaused) =
            _feedbackSeries(g);
        _sameDelivery(outLive, outPaused);
        // Let F(n) = live(n) - paused(n). Both runs execute the same route on the same state: the
        // same fills, the same depth reads (the Router computes `tickDepth18` before its try), and the
        // same deliveries. They differ only inside each leg's `try hub.recordSwap(...) {} catch {}`:
        // the live run executes the body, while the paused run stops at `whenLive` with a 36-byte
        // HubE(2) that the empty catch drops. So F(n) is the sum over the n legs of (body - refusal),
        // and F(n+1) - F(n) is that difference for leg n+1. Its body reads and rewrites its own
        // registry row, and the refusal reads none. The twins have distinct keys, and recordSwap is
        // the Router's only Hub call on a V2 leg, so that word is cold. The write and the Volume log
        // outweigh the refusal's revert. Hence F(n+1) - F(n) >= sSload, written additively below.
        // Mutant G6-1 (the Router records only leg 0 of a hop) leaves F flat in n.
        for (uint256 n = 1; n < TWINS; ++n) {
            assertGe(
                live[n + 1] + paused[n],
                live[n] + paused[n + 1] + sSload,
                "each added leg pays at least its own registry word's first touch in feedback"
            );
        }
    }

    function test_GasRelation_PausedFeedbackNeverCostsMore() public {
        string memory g = "test_GasRelation_PausedFeedbackNeverCostsMore";
        (, uint256 sSload) = _surcharges(g);
        (uint256[] memory live, uint256[] memory paused, uint256[] memory outLive, uint256[] memory outPaused) =
            _feedbackSeries(g);
        _sameDelivery(outLive, outPaused);
        // Summing the per-leg count of SwapIsStrictlyMonotoneInLegs over the n legs: every live leg
        // reads its own cold registry row, which its refusal never reaches. Hence
        // live(n) >= paused(n) + n * sSload. Mutant G6-2 (`whenLive` runs the body first and refuses
        // after it) makes a paused leg read its row and run the whole body before it reverts: the two
        // runs then differ only in how each feedback call ends, well short of sSload per leg.
        for (uint256 n = 1; n <= TWINS; ++n) {
            assertGe(live[n], paused[n] + n * sSload, "a paused Hub refuses each leg's feedback before its row is read");
        }
    }
}

/// One A -> B solve over n twin registry rows, every row past its discovery TTL.
contract GasRelationsSolveTest is SolveWorld, GasInstruments {
    uint256 constant POOLS = 8;
    /// Any age past the solver's one-hour discovery TTL works. Every row is stale at every n, so the
    /// solver discovers at every n and the series stays in one regime; with fresh rows, three
    /// curated venues would switch discovery off from n = 3 on.
    uint256 constant QUIET = 1 days;

    function setUp() public {
        _world();
        _instruments();
    }

    function test_GasRelation_SolveIsStrictlyMonotoneInCandidatePools() public {
        string memory g = "test_GasRelation_SolveIsStrictlyMonotoneInCandidatePools";
        (uint256 sAcct, uint256 sSload) = _surcharges(g);
        uint256[] memory solve = new uint256[](POOLS + 1);
        uint256[] memory reg = new uint256[](POOLS + 1);
        uint256[] memory rows = new uint256[](POOLS + 1);
        uint256[] memory hops = new uint256[](POOLS + 1);
        uint256[] memory legs = new uint256[](POOLS + 1);
        uint256 born = block.timestamp;
        for (uint256 n = 1; n <= POOLS; ++n) {
            vm.warp(born);
            _pool(tA, tB, 1e24, 1e24, 30);
            vm.warp(born + QUIET);
            bytes memory ret;
            (solve[n], ret) = _gas(address(solver), abi.encodeCall(solver.findBestRoutePlan, (address(tA), address(tB), AMT)));
            RoutePlan memory p = abi.decode(ret, (RoutePlan));
            hops[n] = p.best.hops.length;
            legs[n] = hops[n] == 0 ? 0 : p.best.hops[0].legs.length;
            (reg[n], ret) = _gas(address(hub), abi.encodeCall(hub.getActivePools, (address(tA), address(tB))));
            rows[n] = abi.decode(ret, (PoolInfo[])).length;
            _record(g, "solve", n, solve[n]);
            _record(g, "registry", n, reg[n]);
        }
        for (uint256 n = 1; n <= POOLS; ++n) {
            assertEq(rows[n], n, "fixture: every pool is an active registry row");
            assertEq(hops[n], 1, "fixture: the plan is one direct hop");
            assertGe(legs[n], 1, "fixture: the plan routes through the registry");
        }
        // Pool n adds to the solve:
        //  (i) its registry row, read by the solver's own `hub.getActivePools`. It is the first
        //      read in the solve, so the row costs what it costs standalone: reg(n) - reg(n-1).
        //  (ii) the first touch of the pool itself. For n > 1 the dust filter (`_dropDust`)
        //      measures every candidate's depth (`registryDepth18Dec`): the pool's reserves, then
        //      `heldBy`'s two balance words. That is one account and three words no other pool
        //      shares, paid cold once by whichever stage reads them first.
        //  (iii) everything else, >= 0: freshness, merge, psi, selection and the split visit at
        //      least the candidates they visited before.
        // Hence solve(n) - solve(n-1) >= reg(n) - reg(n-1) + sAcct + 3 sSload, written additively.
        // Mutant G6-3 (the solver keeps at most four registry rows) leaves pool 5 onwards only its
        // registry row and the freshness walk's `hub.getSlot` of that row (`_registryFresh` reads
        // every row): one call to an account already warm and one word, short of sAcct + 3 sSload.
        for (uint256 n = 2; n <= POOLS; ++n) {
            assertGe(
                solve[n] + reg[n - 1],
                solve[n - 1] + reg[n] + sAcct + 3 * sSload,
                "each added candidate pool is read by the solve beyond its registry row"
            );
        }
    }
}

/// One `discoverFor` over n factories, each holding one pair of the queried tokens.
contract GasRelationsDiscoveryTest is GasInstruments {
    uint256 constant FACTORIES = 8;
    BlazePhoenixHub hub;
    address t0;
    address t1;

    function setUp() public {
        _instruments();
        address x = address(new MockERC20("X", "X"));
        address y = address(new MockERC20("Y", "Y"));
        (t0, t1) = x < y ? (x, y) : (y, x);
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
    }

    function _addFactory() internal {
        MockV2Factory f = new MockV2Factory();
        f.setPair(t0, t1, address(new MockV2Pair(t0, t1)));
        hub.addFactory(address(f), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
    }

    function test_GasRelation_DiscoveryIsAtLeastLinearInFactories() public {
        string memory g = "test_GasRelation_DiscoveryIsAtLeastLinearInFactories";
        (uint256 sAcct, uint256 sSload) = _surcharges(g);
        uint256[] memory cold = new uint256[](FACTORIES + 1);
        uint256[] memory warm = new uint256[](FACTORIES + 1);
        uint256[] memory hits = new uint256[](FACTORIES + 1);
        for (uint256 n; n <= FACTORIES; ++n) {
            if (n > 0) _addFactory();
            bytes memory ret;
            (cold[n], warm[n], ret) = _gas2(address(hub), abi.encodeCall(hub.discoverFor, (t0, t1)));
            hits[n] = abi.decode(ret, (PoolInfo[])).length;
            _record(g, "discover", n, cold[n]);
            _record(g, "discover_warm", n, warm[n]);
        }
        for (uint256 n; n <= FACTORIES; ++n) {
            assertEq(hits[n], n, "fixture: every factory's pair is found");
        }
        // Let D(n) = cold(n) - warm(n). `discoverFor` is a view run twice on the same state in one
        // transaction, so both runs execute the same instructions and D(n) is the price of the
        // first touches alone (EIP-2929); everything else factory n costs cancels.
        // Factory n adds first touches that no other factory shares:
        //  - its entry's words: factory|kind|mode, read by both loops; the fee-axis length and the
        //    spacing-axis length, read by `_axes`;
        //  - its codehash pin `factoryCodehash[f]` and the factory account (EXTCODEHASH), compared
        //    by `_scanFactory`;
        //  - the factory's pair word, read by the `getPair` lookup of modes 0-3;
        //  - the pair account (`hasCode`), and the pair's token0 and token1 words, compared by
        //    `_probe`.
        // That is two accounts and seven words, each paid cold once (the init-code hash word is
        // left out of the count). Hence D(n) - D(n-1) >= 2 sAcct + 7 sSload, written additively.
        // Mutant G6-4 (an asked pair is listed without its token0/token1 proof) still finds every
        // pair, and reads five of the seven words.
        for (uint256 n = 1; n <= FACTORIES; ++n) {
            assertGe(
                cold[n] + warm[n - 1],
                cold[n - 1] + warm[n] + 2 * sAcct + 7 * sSload,
                "each added factory is looked up, and its pair proves its own tokens"
            );
        }
    }
}

/// `batchQuote` over n identical entries against the seeded quote world.
contract GasRelationsBatchTest is QuoteWorld, GasInstruments {
    uint256 constant QUOTE_IN = 1_000e18;
    uint256 constant ENTRIES = 8;

    function setUp() public {
        _world(true);
        _instruments();
    }

    function _entries(uint256 n) internal view returns (BlazePhoenixQuoter.BatchEntry[] memory e) {
        e = new BlazePhoenixQuoter.BatchEntry[](n);
        for (uint256 i; i < n; ++i) {
            e[i] = BlazePhoenixQuoter.BatchEntry({tIn: address(A), tOut: address(B), amountIn: QUOTE_IN, userMinOut: 0});
        }
    }

    function test_GasRelation_BatchQuoteEntryCostsAtLeastItsSolve() public {
        string memory g = "test_GasRelation_BatchQuoteEntryCostsAtLeastItsSolve";
        (uint256 solveCold, uint256 solveWarm,) =
            _gas2(address(solver), abi.encodeCall(solver.findBestRoutePlan, (address(A), address(B), QUOTE_IN)));
        vm.snapshotValue(g, "solve_cold", solveCold);
        vm.snapshotValue(g, "solve_warm", solveWarm);
        uint256[] memory b = new uint256[](ENTRIES + 1);
        uint256[] memory quoted = new uint256[](ENTRIES + 1);
        for (uint256 n; n <= ENTRIES; ++n) {
            bytes memory ret;
            (b[n], ret) = _gas(address(quoter), abi.encodeCall(quoter.batchQuote, (_entries(n))));
            BlazePhoenixQuoter.Preview[] memory pv = abi.decode(ret, (BlazePhoenixQuoter.Preview[]));
            for (uint256 i; i < pv.length; ++i) if (pv[i].canExecute) ++quoted[n];
            _record(g, "batch", n, b[n]);
        }
        for (uint256 n; n <= ENTRIES; ++n) {
            assertEq(quoted[n], n, "fixture: every entry quotes an executable route");
        }
        // Per entry, `batchQuote` calls `solver.findBestRoutePlan(tIn, tOut, amountIn)` and packs the
        // plan. The solve is a view, and every entry gives it the same arguments on the same state,
        // so each entry runs the same instructions; only the access prices differ. Entry 1 runs on
        // the cold list `solveCold` saw: the Quoter reads no state before it (`solver` is
        // immutable). Every later entry runs on the list the first entry left warm, as `solveWarm`
        // does. The per-entry remainder (call encoding, plan decoding, `_pack`, memory) is >= 0.
        // Hence batch(1) >= batch(0) + solveCold and batch(k) >= batch(k-1) + solveWarm. Mutant G6-5
        // (every entry after the first reuses the first entry's plan) leaves entries 2 to 8 only a
        // copy, and the fixture cannot tell: the entries are identical, so every copy quotes.
        assertGe(b[1], b[0] + solveCold, "the first entry pays at least a cold solve");
        for (uint256 k = 2; k <= ENTRIES; ++k) {
            assertGe(b[k], b[k - 1] + solveWarm, "every later entry pays at least a warm solve");
        }
    }
}

/// The library walk over a concentrated book with n initialized ticks below the start price.
contract GasRelationsBookTest is GasInstruments {
    uint24 constant FEE = 3_000;
    int24 constant TS = 60;
    uint128 constant LIQ = 1e24;
    int128 constant NET = int128(LIQ / 1000);
    uint256 constant BOOK_IN = 15_000e18;
    uint256 constant TICKS = 4;
    BookWalkProbe probe;
    MockV3BookPool book;

    function setUp() public {
        _instruments();
        probe = new BookWalkProbe();
        book = new MockV3BookPool(address(new MockERC20("X", "X")), address(new MockERC20("Y", "Y")), FEE, TS);
        book.setState(uint160(BPC.Q96), LIQ);
    }

    function test_GasRelation_V3IsStrictlyMonotoneInTicksCrossed() public {
        string memory g = "test_GasRelation_V3IsStrictlyMonotoneInTicksCrossed";
        (, uint256 sSload) = _surcharges(g);
        uint256[] memory cold = new uint256[](TICKS + 1);
        uint256[] memory warm = new uint256[](TICKS + 1);
        uint256[] memory out = new uint256[](TICKS + 1);
        for (uint256 n; n <= TICKS; ++n) {
            if (n > 0) book.setTick(-TS * int24(int256(n)), NET);
            bytes memory ret;
            (cold[n], warm[n], ret) = _gas2(address(probe), abi.encodeCall(probe.walk, (address(book), BOOK_IN, true)));
            out[n] = abi.decode(ret, (uint256));
            _record(g, "walk", n, cold[n]);
            _record(g, "walk_warm", n, warm[n]);
        }
        for (uint256 n = 1; n <= TICKS; ++n) {
            assertLt(out[n], out[n - 1], "fixture: every added tick is crossed");
        }
        // Ticks 1..n sit one spacing apart below the start price, all in one bitmap word, and the
        // input crosses every one of them (the fixture above: each added tick lowers the output,
        // which a tick left uncrossed could not do). Let D(n) = cold(n) - warm(n): the walk is a
        // view run twice on the same state in one transaction, so both runs execute the same
        // instructions and D(n) is the price of the first touches alone (EIP-2929). Adding tick n
        // adds one crossing, and the crossing reads that tick's liquidityNet word, which no other
        // step reads; the bitmap word is shared. Hence D(n) - D(n-1) >= sSload, written
        // additively. Mutant G6-6 (every crossing reads the first tick's word) keeps every output,
        // since all ticks hold the same NET, and leaves D flat from n = 2 on.
        for (uint256 n = 1; n <= TICKS; ++n) {
            assertGe(cold[n] + warm[n - 1], cold[n - 1] + warm[n] + sSload, "each crossed tick reads its own word");
        }
    }
}
