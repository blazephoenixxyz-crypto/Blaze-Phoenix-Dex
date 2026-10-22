// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  rizki-3107 (Rizki Armando, bug bounty) - ADMISSION REQUIRES PROOF OF ORIGIN.
//
//  On 2.0.0 (a591f97) the swap door's first registration (`Hub.recordSwap`) asked
//  the pool about itself only: token0()/token1(), its shape, its reserves against
//  its balances. A pair the attacker wrote answers all of them truthfully - reserves
//  ARE its live balances, capital it withdraws at will - while its swap() refuses
//  everyone but its owner. One dust swap through the caller-route door seated it; the
//  Solver routed a split of the pair to it (capacity share, up to 100 % with equal
//  depth and a better price); every `swapBestExactIn` on the pair reverted, for at
//  least 120 days, with no removal path; with a short payment instead of a revert it
//  kept up to 305 bps of the order, bounded only by userMinOut. Measured red on
//  a591f97 by the three trap tests below.
//
//  The fix (Hub.recordSwap, `_derivedByFactory`): a pair-shaped or concentrated pool
//  takes a seat through the swap door only if `discoverFor` - the derivation from the
//  wired factories - lists it. The pool's own token0()/token1() check stays beside it:
//  `test_RightTokensButNotDerived_IsRefused` pins that the right tokens without an origin
//  are refused (red on a591f97), and `test_Create2HitOnOtherTokens_IsRefusedByThePairCheck`
//  that an origin without the right tokens is refused too (red with the check deleted, so
//  the derivation does not subsume it). The trap tests assert the safe property: no seat, the
//  Solver door settles at exactly what the same order gets with no trap deployed, and
//  a short-paying trap takes nothing. Two positive controls show an honest pool still
//  registers through the swap door when a wired factory derives it, by factory call
//  (mode 0) and by CREATE2 (mode 4).
//
//  Second part (Hub._register): when every row of a full pair had aged to psi 0 the
//  strict `<` evicted the lowest index, whatever its depth - a 3M pool left before
//  fifteen 1k rows. Ties now break by the depth bucket. Red on a591f97:
//  `test_EvictionTieAtPsiZero_EvictsTheShallowestRow`. The control
//  `test_EvictionUnequalPsi_PsiStillDecidesAlone` pins that the bucket only breaks ties.
//
//  Fixtures are written from the report; the researcher's archive was not used.
//    forge test --match-path test/Rizki3107FakePairSeat.t.sol -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, RoutePlan, PoolInfo} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";

interface IERC20T {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IPairT {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IRouterT {
    function swapExactIn(
        Route calldata route, uint256 amountIn, uint256 userMinOut, address to, uint256 deadline
    ) external returns (uint256);
}

/// @notice The attacker's pair. Honest in every view: token0/token1 are the pair's, the
///         reserves ARE its live balances (so reservesHeld/heldBy hold). Its swap() pays its
///         owner (tx.origin) honestly and anyone else either reverts (mode 1) or pays payBps
///         of what was asked (mode 2).
contract TrapPair {
    address public immutable token0;
    address public immutable token1;
    address public immutable owner;
    uint8   public mode;
    uint256 public payBps;

    constructor(address a, address b, address o) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        owner = o;
    }

    function setMode(uint8 m, uint256 p) external { require(msg.sender == owner, "own"); mode = m; payBps = p; }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (uint112(IERC20T(token0).balanceOf(address(this))),
                uint112(IERC20T(token1).balanceOf(address(this))), uint32(block.timestamp));
    }

    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        if (tx.origin != owner) {
            if (mode == 1) revert("trap");
            if (mode == 2) { a0 = a0 * payBps / 10_000; a1 = a1 * payBps / 10_000; }
        }
        if (a0 > 0) IERC20T(token0).transfer(to, a0);
        if (a1 > 0) IERC20T(token1).transfer(to, a1);
    }
}

contract Rizki3107FakePairSeatTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixSolver solver;
    BlazePhoenixRouter router;
    MockERC20  tokenA;
    MockERC20  tokenB;
    MockV2Pair honest;
    MockV2Factory factory;

    address constant USER     = address(0xBEEF);
    address constant ATTACKER = address(0xA77AC);

    uint112 constant DEEP  = uint112(3_000_000e18);
    uint256 constant DUST  = 1e15;
    uint256 constant ORDER = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(this));

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");

        honest = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(honest), DEEP);
        tokenB.mint(address(honest), DEEP);
        honest.setReserves(DEEP, DEEP);
        hub.seedPool(address(honest), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));

        // A wired factory exists and derives the honest pool: the trap is refused because
        // no factory derives IT, not because the Hub has no factory at all.
        factory = new MockV2Factory();
        hub.addFactory(address(factory), BPC.KIND_V2, 0, bytes32(0), new uint24[](0), new int24[](0));
        factory.setPair(address(tokenA), address(tokenB), address(honest));

        tokenA.mint(USER, 1_000_000e18);
        vm.prank(USER);
        tokenA.approve(address(router), type(uint256).max);
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    function _key(address p) internal view returns (bytes32) {
        return hub.keyOf(p, address(tokenA), address(tokenB));
    }

    function _seated(address p) internal view returns (bool) {
        return hub.getPool(_key(p)) == p;
    }

    /// The attacker deploys a trap holding `hold` of A and hold*(1+skew) of B (a better
    /// price than the market for A -> B) and tries to seat it with ONE dust swap through
    /// the caller-route door, from its own EOA.
    function _seatTrapSkew(uint256 hold, uint256 skewBps) internal returns (TrapPair t) {
        vm.prank(ATTACKER);
        t = new TrapPair(address(tokenA), address(tokenB), ATTACKER);
        tokenA.mint(address(t), hold);
        tokenB.mint(address(t), hold * (10_000 + skewBps) / 10_000);
        _dustThrough(address(t), ATTACKER);
    }

    /// One dust swap A -> B through `pool` on the caller-route door (swapExactIn), sent by
    /// `who` as both msg.sender and tx.origin. The route is built before any cheatcode.
    function _dustThrough(address pool, address who) internal {
        tokenA.mint(who, DUST);
        bool zf1 = IPairT(pool).token0() == address(tokenA);
        (uint112 r0, uint112 r1, ) = IPairT(pool).getReserves();
        uint256 exp = BPC.outV2(DUST, zf1 ? r0 : r1, zf1 ? r1 : r0, BPC.effV2Fee(0));
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: pool, hooks: address(0), kind: BPC.KIND_V2,
            fee: 0, tickSpacing: 0, zeroForOne: zf1, stable: false,
            amountIn: DUST, expectedOut: exp, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(tokenA), tokenOut: address(tokenB), amountIn: DUST, expectedOut: exp, legs: legs});
        Route memory r = Route({
            hops: hops, totalOut: exp, singleOut: exp, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0,
            hasSurplus: false, isV4Bundle: false
        });
        vm.startPrank(who, who);
        tokenA.approve(address(router), type(uint256).max);
        IRouterT(address(router)).swapExactIn(r, DUST, 1, who, block.timestamp + 1);
        vm.stopPrank();
    }

    function _swapAmt(uint256 amt, uint256 minOut) internal returns (bool ok, uint256 got, bytes memory err) {
        uint256 before = tokenB.balanceOf(USER);
        vm.prank(USER, USER);
        try router.swapBestExactIn(address(tokenA), address(tokenB), amt, minOut, USER, block.timestamp + 1) {
            ok = true;
            got = tokenB.balanceOf(USER) - before;
        } catch (bytes memory e) { err = e; }
    }

    /// What the Solver door delivers for `amt` with no trap deployed: the oracle, measured on
    /// a snapshot of the same block and reverted, so the real run starts from the same state.
    function _honestOnly(uint256 amt) internal returns (uint256 got) {
        uint256 snap = vm.snapshotState();
        bool ok;
        (ok, got, ) = _swapAmt(amt, 1);
        vm.revertToState(snap);
        assertTrue(ok, "oracle: the honest-only swap must settle");
        assertGt(got, 0, "oracle: the honest-only swap must deliver");
    }

    function _inPlan(address t, uint256 amt) internal view returns (bool inPlan) {
        RoutePlan memory plan = solver.findBestRoutePlan(address(tokenA), address(tokenB), amt);
        for (uint256 h; h < plan.best.hops.length; ++h)
            for (uint256 i; i < plan.best.hops[h].legs.length; ++i)
                if (plan.best.hops[h].legs[i].pool == t) inPlan = true;
    }

    // ── the trap: no seat, no plan share, no leak ───────────────────────────

    /// Red on a591f97: the trap was registered by its own dust swap.
    function test_TrapPairWithoutFactoryOrigin_TakesNoSeat() public {
        TrapPair t = _seatTrapSkew(30_000e18, 0);   // 1 % of the honest pool's depth
        assertFalse(_seated(address(t)), "a pool no wired factory derives took a seat through the swap door");
        assertEq(hub.getSlot(_key(address(t))), 0, "the trap left a slot behind");
        assertTrue(_seated(address(honest)), "the honest seed must stay seated");
    }

    /// Red on a591f97 (`Error("trap")`): the Solver gave the trap 0.99 % of the order and the
    /// whole swapBestExactIn reverted.
    function test_TrapPairWithoutFactoryOrigin_SolverDoorSettles() public {
        uint256 oracle = _honestOnly(ORDER);
        TrapPair t = _seatTrapSkew(30_000e18, 200);
        vm.prank(ATTACKER); t.setMode(1, 0);
        assertFalse(_inPlan(address(t), ORDER), "the Solver planned a leg through the trap");
        (bool ok, uint256 got, bytes memory err) = _swapAmt(ORDER, 1);
        emit log_named_bytes("revert data", err);
        assertTrue(ok, "the honest user's swapBestExactIn reverted on the trap leg");
        assertEq(got, oracle, "the Solver door must deliver what it delivers with no trap deployed");
    }

    /// Red on a591f97: a 750k trap paying 80 % took 20 % of a 100k order and kept 305 bps of it
    /// at userMinOut = 1.
    function test_TrapPairWithoutFactoryOrigin_ShortPayLeaksNothing() public {
        uint256 amt = 100_000e18;
        uint256 oracle = _honestOnly(amt);
        TrapPair t = _seatTrapSkew(750_000e18, 200);
        vm.prank(ATTACKER); t.setMode(2, 8_000);
        (bool ok, uint256 got, ) = _swapAmt(amt, 1);
        assertTrue(ok, "the honest-only route must settle");
        assertEq(got, oracle, "a short-paying trap took value from the order");
    }

    /// The right tokens are not an origin: an ordinary pair with the RIGHT token0()/token1(),
    /// holding what it reports, that no wired factory derives, is refused a seat - and the swap
    /// through it still settles (a registry decision never reverts). On a591f97 this pool was
    /// seated on the pair check alone.
    function test_RightTokensButNotDerived_IsRefused() public {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), 30_000e18);
        tokenB.mint(address(p), 30_000e18);
        p.setReserves(uint112(30_000e18), uint112(30_000e18));
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        assertEq(p.token0(), t0, "fixture: right token0");
        assertEq(p.token1(), t1, "fixture: right token1");
        uint256 before = tokenB.balanceOf(USER);
        _dustThrough(address(p), USER);
        assertGt(tokenB.balanceOf(USER), before, "the swap through an underived pool must still settle");
        assertFalse(_seated(address(p)), "a pool with the right tokens but no factory origin took a seat");
    }

    /// Why the pool's own token0()/token1() check is KEPT beside the derivation: a CREATE2
    /// derivation proves WHO deployed the pool and with which salt, not which tokens the deployed
    /// code trades. A wired CREATE2 factory whose init code does not bind the salt's tokens (here
    /// the test contract, deploying an A/C pair at the A/B salt) yields a hit `discoverFor` lists
    /// for A/B. It holds what it reports in A and B and is V2-shaped, so only the pair check
    /// refuses it. Measured red with the check deleted; so the check stays.
    function test_Create2HitOnOtherTokens_IsRefusedByThePairCheck() public {
        MockERC20 tokenC = new MockERC20("C", "C");
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bytes32 initHash = keccak256(abi.encodePacked(
            type(MockV2Pair).creationCode, abi.encode(address(tokenA), address(tokenC))));
        hub.addFactory(address(this), BPC.KIND_V2, 4, initHash, new uint24[](0), new int24[](0));
        MockV2Pair p = new MockV2Pair{salt: keccak256(abi.encodePacked(t0, t1))}(address(tokenA), address(tokenC));
        tokenA.mint(address(p), 30_000e18);
        tokenB.mint(address(p), 30_000e18);
        tokenC.mint(address(p), 30_000e18);
        p.setReserves(uint112(30_000e18), uint112(30_000e18));
        bool listed;
        PoolInfo[] memory hits = hub.discoverFor(address(tokenA), address(tokenB));
        for (uint256 i; i < hits.length; ++i) if (hits[i].pool == address(p)) listed = true;
        assertTrue(listed, "non-vacuity: the derivation lists the A/C pool for A/B");
        assertTrue(p.token0() != t0 || p.token1() != t1, "non-vacuity: the pool trades other tokens");
        assertTrue(BPC.reservesHeld(address(p), BPC.KIND_V2, t0, t1), "non-vacuity: holdings do not refuse it");
        vm.prank(address(router));
        hub.recordSwap(address(p), BPC.KIND_V2, 0, address(0), address(tokenA), address(tokenB), 1e15, 1e15, 30_000e18);
        assertFalse(_seated(address(p)), "a derived pool trading other tokens took a seat: the derivation does not subsume the pair check");
        assertEq(hub.getSlot(_key(address(p))), 0, "the wrong-token pool left a slot behind");
    }

    // ── positive controls: a factory-derived pool still registers by swap ───

    /// Mode 0 (the factory is asked, codehash-pinned): a fresh honest pair the wired factory
    /// lists is seated by an ordinary swap through it, as before the fix.
    function test_FactoryCallPool_StillRegistersThroughTheSwapDoor() public {
        MockV2Pair p = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(p), 30_000e18);
        tokenB.mint(address(p), 30_000e18);
        p.setReserves(uint112(30_000e18), uint112(30_000e18));
        factory.setPair(address(tokenA), address(tokenB), address(p));   // replaces honest in getPair
        assertFalse(_seated(address(p)), "precondition: not registered before the swap");
        uint256 g = gasleft();
        hub.discoverFor(address(tokenA), address(tokenB));
        emit log_named_uint("gas of the origin proof (discoverFor, 1 factory)", g - gasleft());
        _dustThrough(address(p), USER);
        assertTrue(_seated(address(p)), "a factory-derived pool must still register through the swap door");
        assertEq(BPC.decodeKind(hub.getSlot(_key(address(p)))), BPC.KIND_V2, "kind");
    }

    /// Mode 4 (CREATE2 over the V2 salt and the init-code hash): the derivation, not an
    /// answer, is the proof. This test contract is the CREATE2 deployer and the wired factory.
    function test_Create2DerivedPool_StillRegistersThroughTheSwapDoor() public {
        (address t0, address t1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
        bytes32 initHash = keccak256(abi.encodePacked(
            type(MockV2Pair).creationCode, abi.encode(address(tokenA), address(tokenB))));
        hub.addFactory(address(this), BPC.KIND_V2, 4, initHash, new uint24[](0), new int24[](0));
        MockV2Pair p = new MockV2Pair{salt: keccak256(abi.encodePacked(t0, t1))}(address(tokenA), address(tokenB));
        assertEq(BPC.deriveAddress(address(this), t0, t1, 0, false, 0, 4, initHash), address(p), "fixture: CREATE2 derivation");
        tokenA.mint(address(p), 30_000e18);
        tokenB.mint(address(p), 30_000e18);
        p.setReserves(uint112(30_000e18), uint112(30_000e18));
        assertFalse(_seated(address(p)), "precondition: not registered before the swap");
        _dustThrough(address(p), USER);
        assertTrue(_seated(address(p)), "a CREATE2-derived pool must still register through the swap door");
    }

    // ── eviction: ties break by depth, psi still decides alone ───────────────

    function _fill(uint256 n, uint256 base) internal returns (MockV2Pair[] memory fill) {
        fill = new MockV2Pair[](n);
        for (uint256 i; i < n; ++i) {
            uint256 d = base * (i + 1);
            fill[i] = new MockV2Pair(address(tokenA), address(tokenB));
            tokenA.mint(address(fill[i]), d);
            tokenB.mint(address(fill[i]), d);
            fill[i].setReserves(uint112(d), uint112(d));
            hub.seedPool(address(fill[i]), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        }
    }

    function _seedFresh() internal returns (MockV2Pair fresh) {
        fresh = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(fresh), DEEP);
        tokenB.mint(address(fresh), DEEP);
        fresh.setReserves(DEEP, DEEP);
        hub.seedPool(address(fresh), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
    }

    function _age(uint256 d) internal {
        vm.warp(block.timestamp + d * 1 days);
        vm.roll(block.number + d * 43_200);
    }

    /// Red on a591f97: with all 16 rows at psi 0 the newcomer evicted index 0, the 3M seed
    /// (bucket 9), and kept fifteen 1k-15k rows (buckets 6-7).
    function test_EvictionTieAtPsiZero_EvictsTheShallowestRow() public {
        MockV2Pair[] memory fill = _fill(15, 1_000e18);      // honest is index 0; 16 rows
        _age(60);
        assertEq(hub.getPsi(address(honest), address(tokenA), address(tokenB)), 0, "non-vacuity: the tie is at psi 0");
        assertEq(hub.getPsi(address(fill[0]), address(tokenA), address(tokenB)), 0, "non-vacuity: psi 0");
        MockV2Pair fresh = _seedFresh();
        assertTrue(_seated(address(fresh)), "the newcomer must take a seat");
        assertTrue(_seated(address(honest)), "the deepest row was evicted on a psi tie");
        assertFalse(_seated(address(fill[0])), "the shallowest, lowest-index row must be the one evicted");
    }

    /// Control: the bucket breaks ties only. A shallow row that is still warm (psi > 0) outranks
    /// every deeper row at psi 0, so a psi-0 row leaves and the warm one stays.
    function test_EvictionUnequalPsi_PsiStillDecidesAlone() public {
        MockV2Pair warm = new MockV2Pair(address(tokenA), address(tokenB));
        tokenA.mint(address(warm), 100e18);
        tokenB.mint(address(warm), 100e18);
        warm.setReserves(uint112(100e18), uint112(100e18));   // bucket 5, below every other row
        hub.seedPool(address(warm), BPC.KIND_V2, 30, address(0), address(tokenA), address(tokenB));
        MockV2Pair[] memory fill = _fill(14, 1_000e18);       // honest + warm + 14 = 16 rows
        _age(60);
        uint256 d = BPC.registryDepth18(address(warm), BPC.KIND_V2, address(tokenA), address(tokenB), address(0), bytes32(0));
        vm.prank(address(router));
        hub.recordSwap(address(warm), BPC.KIND_V2, 0, address(0), address(tokenA), address(tokenB), 1e15, 1e15, d);
        assertGt(hub.getPsi(address(warm), address(tokenA), address(tokenB)), 0, "non-vacuity: the shallow row is warm");
        assertEq(hub.getPsi(address(fill[0]), address(tokenA), address(tokenB)), 0, "non-vacuity: the rest are at psi 0");
        _seedFresh();
        assertTrue(_seated(address(warm)), "a warm row was evicted for a colder deeper one: psi no longer decides");
        uint256 gone;
        for (uint256 i; i < fill.length; ++i) if (!_seated(address(fill[i]))) ++gone;
        if (!_seated(address(honest))) ++gone;
        assertEq(gone, 1, "exactly one psi-0 row leaves");
    }
}
