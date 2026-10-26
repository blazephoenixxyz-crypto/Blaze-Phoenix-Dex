// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../../src/BlazePhoenixCore.sol";

// =============================================================================
//  AERODROME 2026 ON BASE: THE NEW CL FACTORY'S fee() AGAINST THE CORE'S BUDGET
//
//  The new CL pools (factory 0x9CB2...7a76) answer fee() through
//  pool -> library -> factory.getPoolSwapHook -> hook.getBeforeSwapFee. The
//  first read in a block recomputes the dynamic part from a 600 s TWAP
//  (pool.observe, a binary search over the oracle ring), and the hook wraps
//  that observe in try/catch: an observe that runs out of gas makes fee()
//  answer the BASE fee, silently, instead of failing.
//
//  G0 measures, per sampled pool, cold (every touched account cooled) and in
//  a new block (blockFee == 0, the first-swap path):
//    gMin   the least gas forwarded to fee() that returns the true fee
//    gOk    the least gas forwarded to fee() that returns ANY answer
//           (gOk < gMin is a window where a starved read answers a wrong fee)
//    spent  the gas the read spends when given plenty
//  G1 swaps in the block first and re-measures (blockFee set), and checks
//  that the fee read by the swapping contract prices the swap to the wei.
//  G2 is the Core's own read: BPC.quoteV3Fee(pool, 0, 0, false) must be the
//  pool's fee, cold, in a new block.
//
//  Pinned: Base block 53_127_000 (469 pools; 381 at oracle cardinality 900,
//  the largest on the factory at that block). Sample: the two pools of the
//  first measurement plus 28 drawn at random (seed 42) from the 412 with
//  liquidity.
//
//  Runs only with a fork endpoint (DRPC_KEY set; the `base` alias of the
//  local foundry.toml).
// =============================================================================

interface IClPoolLike {
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function observations(uint256) external view returns (uint32, int56, uint160, bool);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256, int256);
}

interface IErc20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// The fee read as the Core issues it, with the forwarded gas chosen by the test.
contract ClFeeReader {
    function readAt(address pool, uint256 g) public view returns (bool ok, uint24 f, uint256 spent) {
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0xddca3f43))
            let g0 := gas()
            ok := staticcall(g, pool, 0x00, 0x04, 0x00, 0x20)
            spent := sub(g0, gas())
            ok := and(ok, iszero(lt(returndatasize(), 32)))
            if ok { f := and(mload(0x00), 0xffffff) }
        }
    }

    /// The planner's order: the price and the depth are read before the fee.
    function readAfterState(address pool, uint256 g) external view returns (bool ok, uint24 f, uint256 spent) {
        IClPoolLike(pool).slot0();
        IClPoolLike(pool).liquidity();
        return readAt(pool, g);
    }

    /// Two reads in ONE call: the first warms every account and slot the read touches, the
    /// second is the one measured (a later quote of the same pool in the same transaction).
    function readWarm(address pool, uint256 g) external view returns (bool ok, uint24 f, uint256 spent) {
        readAt(pool, 5_000_000);
        return readAt(pool, g);
    }

    function coreQuoteFee(address pool) external view returns (uint24) {
        return BPC.quoteV3Fee(pool, 0, 0, false);
    }
}

/// Swaps a CL pool directly and reads fee() as the same caller, in the same frame order
/// as the Router (read, then swap).
contract ClSwapper {
    uint160 internal constant MIN_SQRT = 4295128740;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970341;

    function readThenSwap(address pool, bool zeroForOne, uint256 amountIn)
        external returns (uint24 f, uint160 sp, uint128 liq, uint256 out)
    {
        f = IClPoolLike(pool).fee();
        (sp,,,,,) = IClPoolLike(pool).slot0();
        liq = IClPoolLike(pool).liquidity();
        (int256 a0, int256 a1) = IClPoolLike(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT : MAX_SQRT, ""
        );
        out = uint256(-(zeroForOne ? a1 : a0));
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        if (a0 > 0) IErc20Min(IClPoolLike(msg.sender).token0()).transfer(msg.sender, uint256(a0));
        if (a1 > 0) IErc20Min(IClPoolLike(msg.sender).token1()).transfer(msg.sender, uint256(a1));
    }
}

contract AeroNovaClFeeGasFork is Test {
    uint256 internal constant FORK_BLOCK = 53_127_000;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    // WETH/USDC on the new CL factory (first measurement, report section 1.0b).
    address internal constant CL_SP100 = 0x2A430bEbD2082d8e05D56d64DEDE8944279bbC24;
    address internal constant CL_SP50 = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;

    ClFeeReader internal reader;
    ClSwapper internal swapper;
    address[] internal touched;

    function setUp() public {
        if (bytes(vm.envOr("DRPC_KEY", string(""))).length == 0) { vm.skip(true); return; }
        vm.createSelectFork("base", FORK_BLOCK);
        reader = new ClFeeReader();
        swapper = new ClSwapper();
        // A new block: no swap has stored a blockFee in it, so fee() takes the
        // first-swap path (the dynamic part from the TWAP).
        vm.roll(FORK_BLOCK + 1);
        vm.warp(block.timestamp + 2);
    }

    function _sample() internal pure returns (address[] memory s) {
        s = new address[](30);
        s[0] = CL_SP100; s[1] = CL_SP50;
        s[2] = 0x20f1454Cb204BE0F53C8D89d3eF6927DdB80d156; s[3] = 0xF668e21993f0ACd7ab00BB1cFbAeD0df28A3C8EC;
        s[4] = 0x73AC19fEf2909a0ab5040Fd2E1f0a930CD30B1A2; s[5] = 0xFEeC646A45A93156E68e0105e7C6494add82a69C;
        s[6] = 0xD9CA199152cCbE421b56414e30becC80baF5269E; s[7] = 0x775DAa0661492E95E81142C3527758DD55fd6754;
        s[8] = 0xa77e546efCC6BE9fC122aa56b89Fe6346a9e8c85; s[9] = 0xb9012FDA200ed4564be1a4427924ff885cF80F9b;
        s[10] = 0x8e1917c82D73d9B1f65C66Cc6Bf7f6e85F47Cf79; s[11] = 0xC66146AE2b4DEa2350A39a4f1fe661605B3fEA7F;
        s[12] = 0x0608117B480e9816dbD3a85109021c5944356644; s[13] = 0xC0CF5Ede24a9bA4c2f653cce9c8eA8a11e090903;
        s[14] = 0xDcecF5B45156E6789b107DFFB96e1126E15110b3; s[15] = 0x431Ba549B02F72fbe16Be5B823C3f1D0063F4d6D;
        s[16] = 0x047f55c69886b387Cc622Ed68aF58d53413F0342; s[17] = 0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3;
        s[18] = 0x042adAF267E0ddB89cd1b264a16ada127E0285Ce; s[19] = 0x63E2f44e2AAEfD747FF32bEC73035e7c35090099;
        s[20] = 0xF5FCB9CDAFcE67d50AfEf298F88E709d2B946BA6; s[21] = 0xE7030bE388b8E247aBe0C9fa876673e83fBcBD3C;
        s[22] = 0x3ECA1A7D881E12D2C7D8111269CEa0bcbF12192a; s[23] = 0x4879b73a865da9a98fB6b48c245EF0ed488B0047;
        s[24] = 0x4dbdcB087992404Ea9B14fA83cc695b02797F39a; s[25] = 0xe24512a5D1cA938ce6e6cE7F15ba46f18e369316;
        s[26] = 0x0BDeD53ad862AB9627Fe7feD9b2c380061F2C96D; s[27] = 0x652254c1E17a515e0867f82b36314F5f89477E8F;
        s[28] = 0x257F103Bfe3dD812eF753303F7739EBB922eEC66; s[29] = 0xb97b8b4076a703B36Be173cdb5177290bF6696Ae;
    }

    // -- instruments --------------------------------------------------------

    /// Every account one fee() read touches (code or storage), so each attempt below can
    /// start from the cold state the first read of a transaction meets.
    function _collect(address pool) internal returns (uint256 poolReads) {
        delete touched;
        vm.startStateDiffRecording();
        reader.readAt(pool, 5_000_000);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i; i < acc.length; ++i) {
            _addTouched(acc[i].account);
            for (uint256 j; j < acc[i].storageAccesses.length; ++j) {
                _addTouched(acc[i].storageAccesses[j].account);
                if (acc[i].storageAccesses[j].account == pool && !acc[i].storageAccesses[j].isWrite) ++poolReads;
            }
        }
    }

    function _addTouched(address a) internal {
        if (a == address(reader) || a == address(this) || a == address(swapper)) return;
        for (uint256 k; k < touched.length; ++k) if (touched[k] == a) return;
        touched.push(a);
    }

    function _coolAll() internal {
        for (uint256 k; k < touched.length; ++k) vm.cool(touched[k]);
    }

    /// Least forwarded gas whose read answers `want` (anyAnswer: answers at all).
    function _gMin(address pool, uint24 want, bool cold, bool anyAnswer, bool afterState)
        internal returns (uint256 hi)
    {
        uint256 lo = 1_000;
        hi = 1_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (cold) _coolAll();
            (bool ok, uint24 f,) = afterState ? reader.readAfterState(pool, mid) : reader.readAt(pool, mid);
            if (anyAnswer ? ok : (ok && f == want)) hi = mid;
            else lo = mid;
        }
    }

    // -- G0: the profile ----------------------------------------------------

    function test_G0_ClFee_ColdFirstInBlock_Profile() public {
        address[] memory s = _sample();
        uint256 worstMin;
        uint256 worstSpent;
        console2.log("pool | sp | card | fee | gMin | gOk | spent | gMinPlanner | gMinWarm | poolReads | accounts | wrongAtGMinMinus1");
        for (uint256 i; i < s.length; ++i) {
            address pool = s[i];
            (,,, uint16 card,,) = IClPoolLike(pool).slot0();
            int24 sp = IClPoolLike(pool).tickSpacing();
            uint256 poolReads = _collect(pool);
            (bool okRef, uint24 fRef,) = reader.readAt(pool, 5_000_000);
            assertTrue(okRef && fRef != 0, "the pool answers fee() with ample gas");
            uint256 gMin = _gMin(pool, fRef, true, false, false);
            uint256 gOk = _gMin(pool, fRef, true, true, false);
            _coolAll();
            (,, uint256 spent) = reader.readAt(pool, 5_000_000);
            uint256 gPlan = _gMin(pool, fRef, true, false, true);
            reader.readAt(pool, 5_000_000); // warm every account and slot the read touches
            uint256 gWarm = _gMin(pool, fRef, false, false, false);
            _coolAll();
            (bool okW, uint24 fW,) = reader.readAt(pool, gMin - 1);
            console2.log(
                string.concat(
                    vm.toString(pool), " | ", vm.toString(int256(sp)), " | ", vm.toString(uint256(card)), " | ",
                    vm.toString(uint256(fRef)), " | ", vm.toString(gMin), " | ", vm.toString(gOk), " | "
                ),
                string.concat(
                    vm.toString(spent), " | ", vm.toString(gPlan), " | ", vm.toString(gWarm), " | ",
                    vm.toString(poolReads), " | ", vm.toString(touched.length), " | ",
                    okW ? vm.toString(uint256(fW)) : "revert"
                )
            );
            if (gMin > worstMin) worstMin = gMin;
            if (spent > worstSpent) worstSpent = spent;
        }
        console2.log("worst gMin (cold, first in block):", worstMin);
        console2.log("worst spent (cold, first in block):", worstSpent);
    }

    // -- G1: after a swap in the same block ---------------------------------

    function test_G1_ClFee_AfterSwap_SameBlock_AndTheReadPricesTheSwap() public {
        address pool = CL_SP100;
        deal(WETH, address(swapper), 1 ether);
        bool zfo = IClPoolLike(pool).token0() == WETH;
        uint256 amt = 0.01 ether;
        (uint24 fSw, uint160 sp, uint128 liq, uint256 out) = swapper.readThenSwap(pool, zfo, amt);
        uint256 quoted = BPC.outV3(amt, sp, liq, fSw, zfo, 0);
        uint256 quotedOff = BPC.outV3(amt, sp, liq, fSw + 1, zfo, 0);
        console2.log("fee read by the swapper / quoted / out:", uint256(fSw), quoted, out);
        console2.log("quoted with fee + 1 pip:", quotedOff);
        assertApproxEqAbs(out, quoted, 2, "the fee read in the swapping frame prices the swap");
        // The check can fail: one pip of fee moves the quote by more than its tolerance.
        assertGt(quoted - quotedOff, 2, "control: one pip of fee is visible at this size");
        _collect(pool);
        (bool ok, uint24 f,) = reader.readAt(pool, 5_000_000);
        assertTrue(ok, "fee() answers after the swap");
        uint256 gMin = _gMin(pool, f, true, false, false);
        console2.log("after swap: fee / gMin cold:", uint256(f), gMin);
        // The next block is the first-swap path again.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        _collect(pool);
        (, uint24 f2,) = reader.readAt(pool, 5_000_000);
        console2.log("next block: fee / gMin cold:", uint256(f2), _gMin(pool, f2, true, false, false));
    }

    // -- G2: the Core's read ------------------------------------------------

    function test_G2_CoreReadsTheNewClFee_ColdFirstInBlock() public {
        address[] memory s = _sample();
        for (uint256 i; i < 2; ++i) {
            _collect(s[i]);
            (, uint24 fRef,) = reader.readAt(s[i], 5_000_000);
            _coolAll();
            assertEq(reader.coreQuoteFee(s[i]), fRef, "the Core reads the new CL fee cold, in a new block");
        }
    }

    // -- G3: the oracle at its structural maximum -----------------------------
    //  The cardinality is a uint16 any caller can grow (increaseObservationCardinalityNext), so
    //  the binary search fee() runs is bounded by 2^16 - 1 slots, not by the 900 the factory
    //  holds today. The heaviest sampled pool's slot0 is rewritten (vm.store) to a ring of
    //  65 535 and the ring is written lazily: only the slots the hook and the search read (a
    //  vm.store on a forked account fetches the slot over RPC first; 65 535 of them never end).
    //  Positions p are chronological (0 the oldest the search starts from). Full ring: index
    //  65 534, slot = p. One short of full (the ring right after a growth, filled up to the last
    //  slot): index 65 533, the last slot still uninitialized, so the hook's oldest-observation
    //  read misses and reads slot 0 too, one more call. The newest observation is the previous
    //  block's (a first read of the block). Above the leaf the observations are 2 s apart (one
    //  per block); the target falls in one gap, under the reachable leaf whose search reads the
    //  most distinct slots (16 iterations).
    //  G4: the MEV-tax branch (tx.gasprice above basefee + threshold) and a second read of the
    //  same pool in the same call (warm), on the three heaviest sampled pools as they are.

    address internal constant WORST = 0xD9CA199152cCbE421b56414e30becC80baF5269E;
    uint256 internal constant RING = 65_535;
    uint256 internal constant LAG = 2;

    struct Ring {
        address pool;
        uint256 obs0;
        int24 tick;
        uint256 t;
        uint256 leaf;
        uint256 ago;
        bool short;
    }

    function _slotOf(address pool, bytes memory call) internal returns (bytes32) {
        vm.record();
        (bool ok,) = pool.staticcall(call);
        assertTrue(ok, "getter answers");
        (bytes32[] memory reads,) = vm.accesses(pool);
        assertEq(reads.length, 1, "a public getter reads one slot");
        return reads[0];
    }

    function _toStructuralMax(address pool, bool short) internal {
        (uint256 leaf, uint256 distinct) = _deepestLeaf(_secondsAgoOf(pool), short);
        console2.log(short ? "one short of full: leaf" : "full ring: leaf", leaf, "distinct slots read", distinct);
        _toStructuralMaxAt(pool, short, leaf);
    }

    function _toStructuralMaxAt(address pool, bool short, uint256 leaf) internal {
        bytes32 s0 = _slotOf(pool, abi.encodeWithSignature("slot0()"));
        uint256 raw = uint256(vm.load(pool, s0));
        (uint160 sp, int24 tick, uint16 idx, uint16 card, uint16 cardNext,) = IClPoolLike(pool).slot0();
        assertEq(uint160(raw), sp, "slot0 layout: sqrtPriceX96");
        assertEq(uint16(raw >> 184), idx, "slot0 layout: observationIndex");
        assertEq(uint16(raw >> 200), card, "slot0 layout: observationCardinality");
        assertEq(uint16(raw >> 216), cardNext, "slot0 layout: observationCardinalityNext");
        uint256 obs0 = uint256(_slotOf(pool, abi.encodeWithSignature("observations(uint256)", uint256(idx)))) - idx;
        (uint32 ts0, int56 tc0, uint160 spl0, bool init0) = IClPoolLike(pool).observations(idx);
        uint256 o = uint256(vm.load(pool, bytes32(obs0 + idx)));
        assertEq(uint32(o), ts0, "observation layout: blockTimestamp");
        assertEq(int56(uint56(o >> 32)), tc0, "observation layout: tickCumulative");
        assertEq(uint160(o >> 88), spl0, "observation layout: secondsPerLiquidityCumulativeX128");
        assertEq((o >> 248) & 1 == 1, init0, "observation layout: initialized");
        uint256 n = RING;
        uint256 index = short ? n - 2 : n - 1;
        uint256 w = raw & ~(uint256(0xFFFFFFFFFFFF) << 184);
        vm.store(pool, s0, bytes32(w | (index << 184) | (n << 200) | (n << 216)));
        Ring memory g = Ring(pool, obs0, tick, block.timestamp, leaf, _secondsAgoOf(pool), short);
        _storeObs(g, 0);
        _storeObs(g, n - 1);
        if (short) _storeObs(g, 1);
        uint256 l;
        uint256 r = n - 1;
        uint256 iters;
        while (true) {
            uint256 i = (l + r) / 2;
            ++iters;
            _storeObs(g, i);
            _storeObs(g, (i + 1) % n);
            if (i == g.leaf) break;
            if (i < g.leaf) l = i + 1;
            else r = i - 1;
        }
        assertEq(iters, 16, "a ring of 2^16 - 1 is searched in 16 iterations at a leaf");
        (,, uint16 idx2, uint16 card2,,) = IClPoolLike(pool).slot0();
        assertEq(uint256(card2), n, "cardinality at its maximum");
        assertEq(uint256(idx2), index, "the newest where the ring says");
        (uint32 tsN,,, bool initN) = IClPoolLike(pool).observations(index);
        assertTrue(initN && tsN == uint32(g.t - LAG), "the newest observation is the previous block's");
        (,,, bool initU) = IClPoolLike(pool).observations((index + 1) % n);
        assertEq(initU, !short, "the slot after the newest is the oldest, or still uninitialized");
        uint32[] memory agos = new uint32[](2);
        agos[0] = uint32(g.ago);
        (int56[] memory tcs,) = IClPoolLike(pool).observe(agos);
        assertEq(int256(tcs[1] - tcs[0]), int256(tick) * int256(g.ago), "the oracle answers over the rewritten ring");
    }

    function _secondsAgoOf(address pool) internal view returns (uint256) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("factory()"));
        assertTrue(ok, "pool factory");
        address f = abi.decode(ret, (address));
        (ok, ret) = f.staticcall(abi.encodeWithSignature("getPoolSwapHook(address)", pool));
        assertTrue(ok, "pool swap hook");
        address hook = abi.decode(ret, (address));
        (ok, ret) = hook.staticcall(abi.encodeWithSignature("secondsAgo()"));
        assertTrue(ok, "the hook's TWAP window");
        return abi.decode(ret, (uint32));
    }

    /// Writes chronological position p: 2 s apart up to the previous block above the leaf, the
    /// leaf 1 s under the target; one short of full, p = 0 is the slot grow() left (timestamp 1).
    function _storeObs(Ring memory g, uint256 p) internal {
        uint256 n = RING;
        uint256 slot = g.short ? (p + n - 1) % n : p;
        if (g.short && p == 0) {
            vm.store(g.pool, bytes32(g.obs0 + slot), bytes32(uint256(1)));
            return;
        }
        uint256 ts = p > g.leaf ? g.t - LAG - 2 * (n - 1 - p) : g.t - g.ago - 1 - 2 * (g.leaf - p);
        int56 tc = int56(int256(g.tick) * int256(ts));
        vm.store(g.pool, bytes32(g.obs0 + slot),
            bytes32(ts | (uint256(uint56(tc)) << 32) | ((p + 1) << 152) | (uint256(1) << 248)));
    }

    /// Leaves reachable while one observation per 2 s block fits between the target and the
    /// previous block: ts(leaf + 1) - ts(leaf) >= 2. Among them, the one whose search reads the
    /// most distinct positions, with the ones read before the search (the newest, the oldest,
    /// and slot 0 when the oldest is uninitialized).
    function _deepestLeaf(uint256 ago, bool short) internal pure returns (uint256 best, uint256 most) {
        uint256 n = RING;
        for (uint256 leaf = n - 3; 2 * (n - 2 - leaf) + 1 + LAG <= ago; leaf -= 2) {
            uint256[40] memory seen;
            seen[1] = n - 1;
            uint256 c = 2;
            if (short) seen[c++] = 1;
            uint256 l;
            uint256 r = n - 1;
            while (true) {
                uint256 i = (l + r) / 2;
                c = _add(seen, c, i);
                c = _add(seen, c, (i + 1) % n);
                if (i == leaf) break;
                if (i < leaf) l = i + 1;
                else r = i - 1;
            }
            if (c > most) (best, most) = (leaf, c);
            if (leaf < 2) break;
        }
    }

    function _add(uint256[40] memory seen, uint256 c, uint256 k) internal pure returns (uint256) {
        for (uint256 j; j < c; ++j) if (seen[j] == k) return c;
        seen[c] = k;
        return c + 1;
    }

    function _gMinWarm(address pool, uint24 want) internal returns (uint256 hi) {
        uint256 lo = 1_000;
        hi = 1_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok, uint24 f,) = reader.readWarm(pool, mid);
            if (ok && f == want) hi = mid;
            else lo = mid;
        }
    }

    function _profile(string memory label, address pool) internal {
        uint256 reads = _collect(pool);
        (bool okRef, uint24 fRef,) = reader.readAt(pool, 5_000_000);
        assertTrue(okRef && fRef != 0, "fee() answers with ample gas");
        uint256 gMin = _gMin(pool, fRef, true, false, false);
        uint256 gOk = _gMin(pool, fRef, true, true, false);
        _coolAll();
        (,, uint256 spent) = reader.readAt(pool, 5_000_000);
        uint256 gWarm = _gMinWarm(pool, fRef);
        _coolAll();
        (bool okW, uint24 fW,) = reader.readAt(pool, gMin - 1);
        console2.log(
            string.concat(label, " | ", vm.toString(pool), " | fee ", vm.toString(uint256(fRef)), " | gMin ",
                vm.toString(gMin), " | gOk ", vm.toString(gOk)),
            string.concat(" | spent ", vm.toString(spent), " | gMinWarm ", vm.toString(gWarm), " | poolReads ",
                vm.toString(reads), " | accounts ", vm.toString(touched.length), " | at gMin-1 ",
                okW ? vm.toString(uint256(fW)) : "revert")
        );
    }

    function test_G3_ClFee_OracleAtItsStructuralMax_FullRing() public {
        _toStructuralMax(WORST, false);
        _profile("full ring", WORST);
        vm.txGasPrice(block.basefee + 1e15);
        _profile("full ring + MEV tax", WORST);
    }

    function test_G3_ClFee_OracleAtItsStructuralMax_OneShortOfFull() public {
        _toStructuralMax(WORST, true);
        _profile("one short", WORST);
        vm.txGasPrice(block.basefee + 1e15);
        _profile("one short + MEV tax", WORST);
    }

    // -- G3h: the heaviest caller branches on top of the oracle's maximum ---------------------
    //  The hook prices the caller: DiscountRegistry.getDiscount(pool, caller) reads the caller's
    //  entry and, when tx.origin differs, the origin's; an entry flagged for per-pool discounts
    //  reads one slot more (the pool's). Heaviest: both entries flagged, the pool's per-pool
    //  discount 0, the origin's chain-wide discount > 0 (the fee is then discounted, a mulDivUp
    //  more). The entries are governance-set; the layout is checked through the registry's own
    //  getters before anything is measured. The MEV tax runs on the transaction's own priority
    //  fee, so it is swept upward until the tax answers (or the config keeps it at 0).

    function _registryOf(address pool) internal view returns (address r) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("factory()"));
        assertTrue(ok, "pool factory");
        (ok, ret) = abi.decode(ret, (address)).staticcall(abi.encodeWithSignature("getPoolSwapHook(address)", pool));
        assertTrue(ok, "pool swap hook");
        (ok, ret) = abi.decode(ret, (address)).staticcall(abi.encodeWithSignature("FACTORY()"));
        assertTrue(ok, "the hook's factory");
        (ok, ret) = abi.decode(ret, (address)).staticcall(abi.encodeWithSignature("discountRegistry()"));
        assertTrue(ok, "the factory's discount registry");
        r = abi.decode(ret, (address));
    }

    /// Flags `acct` for per-pool discounts with a chain-wide discount `d`. Deployed layout (probed
    /// by eth_call with a state override at the fork block, then re-checked here through the
    /// getter): Ownable2Step owns slots 0-1, `discounts` is slot 2, packed low as
    /// {bool isPoolDiscountSet, uint24 discount}; the getter answers in that order.
    function _flagPerPool(address r, address acct, uint24 d) internal {
        vm.store(r, keccak256(abi.encode(acct, uint256(2))), bytes32((uint256(d) << 8) | 1));
        (bool ok, bytes memory ret) = r.staticcall(abi.encodeWithSignature("discounts(address)", acct));
        assertTrue(ok && ret.length >= 64, "discounts(address) getter");
        (bool perPool, uint24 got) = abi.decode(ret, (bool, uint24));
        assertTrue(got == d && perPool, "registry layout as probed (slot 2, {bool, uint24} packed low)");
    }

    /// Both registry entries flagged per pool (the origin's discount answers, a mulDivUp more).
    function _heavyCaller(address pool) internal {
        address r = _registryOf(pool);
        assertTrue(r != address(0), "a discount registry is set");
        _flagPerPool(r, address(reader), 0);
        _flagPerPool(r, tx.origin, 100_000);
        (bool ok, bytes memory ret) =
            r.staticcall(abi.encodeWithSignature("getDiscount(address,address)", pool, address(reader)));
        assertTrue(ok && abi.decode(ret, (uint24)) == 100_000, "both entries read, the origin's discount answers");
    }

    // The deployed MEV module (0x29F1...9a4a at the fork block) holds multiplier 0, minThreshold 0,
    // baseFeeFactor 0 (read by cast): any priority above basefee runs the whole taxed branch
    // (mulDivUp, min) and taxes 0. Priorities 1e15 and 1e18 measured the same (log
    // s3a-fork-heavy2.log); vm.txGasPrice refuses 2^64 and above.
    function test_G3h_ClFee_OracleAtItsStructuralMax_HeaviestCallerBranches() public {
        _toStructuralMax(WORST, true);
        _heavyCaller(WORST);
        _profile("one short + per-pool entries", WORST);
        vm.txGasPrice(block.basefee + 1e15);
        _profile("one short + per-pool entries + priority 1e15", WORST);
    }

    // -- G3all: every reachable leaf, measured -------------------------------------------------
    //  The leaf the model picks ties with others (same cold and warm reads); the arithmetic
    //  of the search can still differ by a few gas between them. Every even leaf (depth 16)
    //  reachable inside the TWAP window is written and read cold, under the heaviest caller
    //  branches: the budget is derived from the most any of them spends.
    function test_G3all_ClFee_EveryReachableLeaf_HeaviestCallerBranches() public {
        uint256 n = RING;
        uint256 ago = _secondsAgoOf(WORST);
        _toStructuralMaxAt(WORST, true, n - 3);
        _heavyCaller(WORST);
        vm.txGasPrice(block.basefee + 1e15);
        _collect(WORST);
        uint256 top;
        uint256 topLeaf;
        uint256 low = type(uint256).max;
        uint256 cnt;
        for (uint256 leaf = n - 3; 2 * (n - 2 - leaf) + 1 + LAG <= ago; leaf -= 2) {
            _toStructuralMaxAt(WORST, true, leaf);
            _coolAll();
            (bool ok, uint24 f, uint256 spent) = reader.readAt(WORST, 5_000_000);
            assertTrue(ok && f != 0, "fee() answers at every leaf");
            if (spent > top) (top, topLeaf) = (spent, leaf);
            if (spent < low) low = spent;
            ++cnt;
        }
        console2.log("leaves", cnt, "spent max", top);
        console2.log("argmax leaf", topLeaf, "spent min", low);
        _toStructuralMaxAt(WORST, true, topLeaf);
        _profile("argmax leaf + heaviest caller branches", WORST);
    }

    function test_G4_ClFee_MevTaxBranch_AndWarmRead_HeaviestSampled() public {
        address[3] memory ps = [WORST, 0x257F103Bfe3dD812eF753303F7739EBB922eEC66,
                                0x16c70F04C3080a127486Cdf5a4C33c066bBF47C3];
        for (uint256 i; i < 3; ++i) _profile("as is", ps[i]);
        vm.txGasPrice(block.basefee + 1e15);
        for (uint256 i; i < 3; ++i) _profile("MEV tax", ps[i]);
    }
}
