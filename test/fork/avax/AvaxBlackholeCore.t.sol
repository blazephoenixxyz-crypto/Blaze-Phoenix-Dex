// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../../../src/BlazePhoenixCore.sol";
import {AvaxForkBase} from "./AvaxForkBase.sol";

interface IErc20B {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev The Algebra Integral v1.2 getters and actions this file uses (IAlgebraPoolState,
///      IAlgebraPoolActions of the Blackhole CLMM sources).
interface IIntegralV {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool);
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256, int256);
    function mint(
        address leftoversRecipient, address recipient, int24 bottomTick, int24 topTick,
        uint128 liquidityDesired, bytes calldata data
    ) external returns (uint256, uint256, uint128);
}

interface IAlgebraFactoryB {
    function poolDeployer() external view returns (address);
    function poolByPair(address, address) external view returns (address);
    function customPoolByPair(address, address, address) external view returns (address);
}

/// @notice The oracle: a raw exact-input swap straight on the Integral venue, paid BY NAME in
///         algebraSwapCallback (the selector the venue calls), and a raw mint paid in
///         algebraMintCallback. It shares no code with the Router, the Quoter or the Core.
contract RawIntegralOracle {
    address private live;

    function swapIn(address amm, address tokenIn, bool zeroToOne, uint256 amtIn) external returns (uint256 out) {
        live = amm;
        (int256 a0, int256 a1) = IIntegralV(amm).swap(
            address(this), zeroToOne, int256(amtIn),
            zeroToOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341),
            abi.encode(tokenIn)
        );
        live = address(0);
        int256 o = zeroToOne ? a1 : a0;
        require(o < 0, "oracle: no output");
        out = uint256(-o);
    }

    function algebraSwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        require(msg.sender == live && live != address(0), "oracle: not the venue");
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        require(IErc20B(abi.decode(data, (address))).transfer(msg.sender, owed), "oracle: pay");
    }

    function mintIn(address amm, int24 lo, int24 hi, uint128 liq) external returns (uint256 a0, uint256 a1) {
        live = amm;
        (a0, a1, ) = IIntegralV(amm).mint(address(this), address(this), lo, hi, liq, "");
        live = address(0);
    }

    function algebraMintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        require(msg.sender == live && live != address(0), "minter: not the venue");
        if (owed0 != 0) require(IErc20B(IIntegralV(msg.sender).token0()).transfer(msg.sender, owed0), "minter: pay0");
        if (owed1 != 0) require(IErc20B(IIntegralV(msg.sender).token1()).transfer(msg.sender, owed1), "minter: pay1");
    }
}

/// @notice avax-1103 wave 3 (bh-core): does the Blackhole CLMM (Algebra Integral v1.2) pass
///         through the core contracts, and as V3 or as Algebra? Avalanche, block 99270000.
///         Verification only, no src change: there is no red commit, every test pins current
///         behaviour and each one has its own mutant on a src line it guards
///         (bh-core-mutantes.tsv).
///         Identity facts (factory registry, CREATE2 by the deployer, base salt
///         keccak(abi.encode(t0, t1)), custom salt keccak(abi.encode(deployer, t0, t1))) are
///         recomputed here from the venue's own formula and checked against the factory.
///         Oracle: RawIntegralOracle above, on the same pre-state (snapshot), fed the input the
///         venue was paid in the Router's run (order minus the treasuries' input share), and
///         the leg input the Quoter priced.
contract AvaxBlackholeCoreFork is AvaxForkBase {
    address internal constant BH_FACTORY  = 0x512eb749541B7cf294be882D636218c84a5e9E5F;
    address internal constant BH_DEPLOYER = 0x9B2441037E286d5Bf9456a3BE7b5273fe28DbA1e;
    bytes32 internal constant BH_INIT =
        0xeaa3eea3233916c82fe1281a51bd9cde844b7c4673c0714ca0028a57f5634752;
    address internal constant BLACK = 0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6;
    // Base WAVAX/BLACK (poolByPair) and the top custom WAVAX/USDC (customPoolByPair of its deployer).
    address internal constant BH_WB_BASE   = 0x61c48716F6e03229B1e250aeFddF429c48E75165;
    address internal constant BH_WU_CUSTOM = 0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7;
    address internal constant BH_WU_CUSTOM_DEPLOYER = 0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584;
    uint8 internal constant KIND_ALGEBRA = 6;

    struct Run {
        uint256 quote;      // Quoter exactOut (previewRouteExact or previewPlanExact)
        uint256 exec;       // what the recipient received from Router.swapExactIn
        uint256 venueIn;    // tokenIn the venue was paid: order - treasuries' tokenIn share
        uint256 venueOut;   // tokenOut the venue paid: recipient + treasuries' tokenOut share
        uint256 rawIn;      // the venue's own tokenIn balance delta (a vault sweep may move it)
        uint256 rawOut;     // the venue's own tokenOut balance delta
        uint256 feeIn;      // treasuries' tokenIn delta
        uint256 feeOut;     // treasuries' tokenOut delta
        uint256 kept;       // what the Router kept, both tokens summed (must be 0)
        uint256 legIn;      // the leg input the Quoter priced, read off the route it returned
        uint256 oracleLeg;  // RawIntegralOracle output for legIn, same pre-state
        uint256 oracle;     // RawIntegralOracle output for venueIn, same pre-state
        uint256 frameQuote; // BPC.legQuoteImpact (the Router's in-frame closed form), for venueIn
        uint128 liq0;
        uint128 liq1;
    }

    // ─── helpers ──────────────────────────────────────────────────────────

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20B(t).balanceOf(who);
    }

    function _c2(address origin, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), origin, salt, BH_INIT)))));
    }

    /// @dev PoolInfo's address word (its eighth member) and a Leg's first member, read by offset.
    function _venueOf(PoolInfo memory i) internal pure returns (address a) {
        assembly ("memory-safe") { a := mload(add(i, 0xe0)) }
    }

    function _legVenue(Leg memory l) internal pure returns (address a) {
        assembly ("memory-safe") { a := mload(l) }
    }

    /// @dev Mode 5 (V3 salt slot), the fee-0 dynamic sentinel R2 demands, this factory and hash.
    function _addAlgebraRow() internal returns (uint8) {
        return _addRow(BH_FACTORY, KIND_ALGEBRA, MODE_CREATE2_V3, BH_INIT, new uint24[](1), new int24[](0));
    }

    /// @dev Mode 5, kind V3, one tier, the same factory and hash.
    function _addV3Row(uint24 fee) internal returns (uint8) {
        uint24[] memory f = new uint24[](1);
        f[0] = fee;
        return _addRow(BH_FACTORY, KIND_V3, MODE_CREATE2_V3, BH_INIT, f, new int24[](0));
    }

    function _lists(address tA, address tB, address venue)
        internal view returns (bool found, PoolInfo memory info, uint256 n)
    {
        PoolInfo[] memory hits = hub.discoverFor(tA, tB);
        n = hits.length;
        for (uint256 i; i < n; ++i) {
            address v = _venueOf(hits[i]);
            console2.log("  hit", v, uint256(hits[i].kind), uint256(hits[i].fee));
            if (v == venue) (found, info) = (true, hits[i]);
        }
    }

    function _hand(address venue, uint8 kind, uint24 fee, address tIn, address tOut, uint256 amt)
        internal view returns (Route memory r)
    {
        bool zfo = IIntegralV(venue).token0() == tIn;
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg(venue, address(0), kind, fee, IIntegralV(venue).tickSpacing(), zfo, false, amt, 0, bytes32(0));
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: tIn, tokenOut: tOut, amountIn: amt, expectedOut: 0, legs: legs});
        r.hops = hops;
    }

    /// @dev tIn -> tOut through ONE venue: Quoter preview (a hand route, or the Solver's plan),
    ///      Router execution with the venue's and the treasuries' deltas, then (state reverted)
    ///      the Router's in-frame closed form and the raw oracle on the input the venue was paid.
    function _run(address venue, uint8 kind, uint24 fee, address tIn, address tOut, uint256 amt, bool viaPlan)
        internal returns (Run memory r)
    {
        bool zfo = IIntegralV(venue).token0() == tIn;
        Route memory route;
        uint256 q;
        if (viaPlan) {
            (route, q) = quoter.previewPlanExact(tIn, tOut, amt);
            assertEq(route.hops.length, 1, "direct route");
            assertEq(route.hops[0].legs.length, 1, "one leg");
            assertEq(_legVenue(route.hops[0].legs[0]), venue, "the plan's leg is this venue");
            assertEq(route.hops[0].legs[0].kind, kind, "the plan's kind");
        } else {
            (route, q) = quoter.previewRouteExact(_hand(venue, kind, fee, tIn, tOut, amt), amt);
        }
        r.quote = q;
        r.legIn = route.hops[0].legs[0].amountIn;
        assertGt(q, 0, "the Quoter prices the leg");
        address user = makeAddr("avax-user");
        deal(tIn, user, amt);
        vm.prank(user);
        IErc20B(tIn).approve(address(router), amt);

        uint256 snap = vm.snapshotState();
        uint256[7] memory b = [
            _bal(tIn, venue), _bal(tOut, venue), _bal(tIn, TEST_TREASURY_1) + _bal(tIn, TEST_TREASURY_2),
            _bal(tOut, TEST_TREASURY_1) + _bal(tOut, TEST_TREASURY_2), _bal(tOut, user), _bal(tIn, address(router)),
            _bal(tOut, address(router))
        ];
        r.liq0 = IIntegralV(venue).liquidity();
        vm.prank(user);
        uint256 got = router.swapExactIn(route, amt, q, user, block.timestamp + 600);
        r.liq1 = IIntegralV(venue).liquidity();
        r.rawIn = _bal(tIn, venue) - b[0];
        r.rawOut = b[1] - _bal(tOut, venue);
        r.feeIn = _bal(tIn, TEST_TREASURY_1) + _bal(tIn, TEST_TREASURY_2) - b[2];
        r.feeOut = _bal(tOut, TEST_TREASURY_1) + _bal(tOut, TEST_TREASURY_2) - b[3];
        r.exec = _bal(tOut, user) - b[4];
        r.kept = (_bal(tIn, address(router)) - b[5]) + (_bal(tOut, address(router)) - b[6]);
        r.venueIn = amt - r.feeIn;
        r.venueOut = r.exec + r.feeOut;
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(tIn, user), 0, "the user spent the whole order");
        vm.revertToState(snap);

        // Pre-state again: the Router's in-frame reader first (a view), then the oracle's swap.
        (uint256 fq, , bool held) = BPC.legQuoteImpact(
            Leg(venue, address(0), kind, fee, 0, zfo, false, r.venueIn, 0, bytes32(0)), tIn, tOut, r.venueIn
        );
        assertTrue(held, "the in-frame reader holds the leg");
        r.frameQuote = fq;
        uint256 pre = vm.snapshotState();
        RawIntegralOracle o = new RawIntegralOracle();
        deal(tIn, address(o), r.legIn);
        r.oracleLeg = o.swapIn(venue, tIn, zfo, r.legIn);
        vm.revertToState(pre);
        o = new RawIntegralOracle();
        deal(tIn, address(o), r.venueIn);
        r.oracle = o.swapIn(venue, tIn, zfo, r.venueIn);
        assertEq(_bal(tOut, address(o)), r.oracle, "the oracle received what the venue declared");

        console2.log("venue", venue);
        console2.log("  amountIn   ", amt);
        console2.log("  quote_wei  ", r.quote);
        console2.log("  exec_wei   ", r.exec);
        console2.log("  venue_in   ", r.venueIn);
        console2.log("  venue_out  ", r.venueOut);
        console2.log("  raw_in     ", r.rawIn);
        console2.log("  raw_out    ", r.rawOut);
        console2.log("  oracle_wei ", r.oracle);
        console2.log("  leg_in     ", r.legIn);
        console2.log("  oracle_leg ", r.oracleLeg);
        console2.log("  fee_in     ", r.feeIn);
        console2.log("  fee_out    ", r.feeOut);
        console2.log("  kept       ", r.kept);
        console2.log("  frame_quote", r.frameQuote);
        console2.log("  liq_before ", uint256(r.liq0));
        console2.log("  liq_after  ", uint256(r.liq1));
    }

    /// @dev The protocol fee rounded up (PROTOCOL_FEE_BPS over 10 000, src/BlazePhoenixCore.sol).
    function _feeUp(uint256 x) internal pure returns (uint256) {
        return (x * BPC.PROTOCOL_FEE_BPS + 9_999) / 10_000;
    }

    /// @dev The equalities every single-venue run must hold, to the wei. Where the Router takes
    ///      the fee decides the Quoter's scalar: off the output (a direct route into a bridge)
    ///      the scalar is the fill; off the input, the Quoter returns the lower of the output
    ///      deduction on the leg it priced and the funded fill (Quoter._exact), a floor, and the
    ///      raw venue reproduces both terms on the same pre-state.
    function _assertRun(Run memory r, uint256 amt) internal pure {
        assertGt(r.rawIn, 0, "the route used this venue (input side)");
        assertGt(r.rawOut, 0, "the route used this venue (output side)");
        assertEq(r.oracle, r.venueOut, "raw oracle == what the venue paid in the Router's run");
        assertEq(r.venueIn + r.feeIn, amt, "input: venue + fee == order");
        assertEq(r.kept, 0, "the Router keeps nothing");
        assertGt(r.frameQuote, 0, "the in-frame closed form prices the leg");
        if (r.feeIn == 0) {
            assertEq(r.feeOut, _feeUp(r.venueOut), "fee off the output, rounded up");
            assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        } else {
            assertEq(r.feeOut, 0, "fee off the input only");
            assertEq(r.feeIn, _feeUp(amt), "fee off the input, rounded up");
            uint256 deducted = r.oracleLeg - _feeUp(r.oracleLeg);
            uint256 floorOut = deducted < r.oracle ? deducted : r.oracle;
            console2.log("  deducted   ", deducted);
            assertEq(r.quote, floorOut, "Quoter == min(output deduction, funded fill), from the raw venue");
            assertLe(r.quote, r.exec, "the Quoter's scalar is a floor of the fill");
        }
    }

    // ─── 1. As Algebra (mode 5, kind 6, fee-0 sentinel) ───────────────────

    /// @notice The Algebra row derives the BASE WAVAX/BLACK venue from the deployer the Hub
    ///         attested at admission (the factory's poolDeployer() answer), never from the
    ///         factory itself. Three producers agree: the formula written here, the factory's
    ///         poolByPair, and the Hub's discovery.
    function test_AvaxBH_AlgebraRow_DerivesBaseFromAttestedDeployer() public {
        assertEq(IAlgebraFactoryB(BH_FACTORY).poolDeployer(), BH_DEPLOYER, "the factory names its deployer");
        _addAlgebraRow();
        assertEq(_c2(BH_DEPLOYER, keccak256(abi.encode(WAVAX, BLACK))), BH_WB_BASE, "CREATE2(deployer, keccak(t0, t1), init)");
        assertEq(IAlgebraFactoryB(BH_FACTORY).poolByPair(WAVAX, BLACK), BH_WB_BASE, "the factory registry agrees");
        assertTrue(_c2(BH_FACTORY, keccak256(abi.encode(WAVAX, BLACK))) != BH_WB_BASE, "the factory is not the origin");
        assertEq(
            BPC.deriveAddress(BH_FACTORY, BLACK, WAVAX, 0, false, 0, MODE_CREATE2_V3, BH_INIT), BH_WB_BASE,
            "Core live derive"
        );
        (bool found, PoolInfo memory info, ) = _lists(WAVAX, BLACK, BH_WB_BASE);
        assertTrue(found, "the Algebra row lists the base venue");
        assertEq(info.kind, KIND_ALGEBRA, "kind Algebra");
        assertEq(info.fee, 0, "listed at the dynamic-fee sentinel");
    }

    /// @notice The top custom venue (WAVAX/USDC) lives at CREATE2(deployer,
    ///         keccak(abi.encode(customDeployer, t0, t1)), init). The Core's Algebra salt has no
    ///         deployer word, so it derives the empty base slot: another address, codeless, and
    ///         the row lists nothing for the pair.
    function test_AvaxBH_AlgebraRow_CustomTopNeitherDerivedNorListed() public {
        _addAlgebraRow();
        assertEq(
            IAlgebraFactoryB(BH_FACTORY).customPoolByPair(BH_WU_CUSTOM_DEPLOYER, WAVAX, USDC), BH_WU_CUSTOM,
            "the factory registry names the custom venue"
        );
        assertEq(
            _c2(BH_DEPLOYER, keccak256(abi.encode(BH_WU_CUSTOM_DEPLOYER, WAVAX, USDC))), BH_WU_CUSTOM,
            "the custom salt reproduces it"
        );
        assertEq(IAlgebraFactoryB(BH_FACTORY).poolByPair(WAVAX, USDC), address(0), "no base WAVAX/USDC venue");
        address derived = BPC.deriveAddress(BH_FACTORY, USDC, WAVAX, 0, false, 0, MODE_CREATE2_V3, BH_INIT);
        console2.log("derived", derived);
        assertEq(derived, _c2(BH_DEPLOYER, BPC.algebraSalt(WAVAX, USDC)), "the Core derives the base slot");
        assertTrue(derived != BH_WU_CUSTOM, "derived != customPoolByPair");
        assertEq(derived.code.length, 0, "the derived address is codeless");
        (bool found, , uint256 n) = _lists(WAVAX, USDC, BH_WU_CUSTOM);
        assertFalse(found, "discovery does not list the custom venue");
        assertEq(n, 0, "the Algebra row lists nothing for WAVAX/USDC");
    }

    /// @notice A KIND_ALGEBRA leg declared by hand on the custom venue, at the explicit door.
    function test_AvaxBH_CustomTop_HandRouteAlgebra_QuoteExecOracle() public {
        _addAlgebraRow();
        uint256 amt = 1_000e6;
        Run memory r = _run(BH_WU_CUSTOM, KIND_ALGEBRA, 0, USDC, WAVAX, amt, false);
        _assertRun(r, amt);
    }

    // ─── 2. As V3 (mode 5, kind 1) ────────────────────────────────────────

    /// @notice A V3 row with a tier: the V3 salt carries the fee and the origin stays the
    ///         factory (no deployer ask), so neither the base nor the custom venue is derived,
    ///         and from the right origin the tier in the salt still misses both.
    function test_AvaxBH_V3RowFee500_SaltCarriesTheTier_ListsNothing() public {
        _addV3Row(500);
        address dWB = BPC.deriveAddress(BH_FACTORY, WAVAX, BLACK, 500, false, 0, MODE_CREATE2_V3, BH_INIT);
        assertEq(dWB, _c2(BH_FACTORY, keccak256(abi.encode(WAVAX, BLACK, uint24(500)))), "V3 salt, factory origin");
        assertEq(dWB.code.length, 0, "codeless");
        assertEq(_c2(BH_DEPLOYER, keccak256(abi.encode(WAVAX, BLACK, uint24(500)))).code.length, 0, "tiered salt, deployer origin: codeless");
        assertEq(_c2(BH_DEPLOYER, keccak256(abi.encode(WAVAX, USDC, uint24(500)))).code.length, 0, "the same for WAVAX/USDC");
        (bool f1, , uint256 n1) = _lists(WAVAX, BLACK, BH_WB_BASE);
        (bool f2, , uint256 n2) = _lists(WAVAX, USDC, BH_WU_CUSTOM);
        assertFalse(f1, "the V3 row does not list the base venue");
        assertFalse(f2, "the V3 row does not list the custom venue");
        assertEq(n1 + n2, 0, "the V3 row lists nothing");
    }

    /// @notice A V3 row with fee 0 takes the Algebra branch (the predicate reads the fee, not
    ///         the kind): it lists the base venue under kind V3, and still not the custom one.
    function test_AvaxBH_V3RowFee0_TakesTheAlgebraBranch_BaseOnly() public {
        _addV3Row(0);
        (bool fb, PoolInfo memory ib, ) = _lists(WAVAX, BLACK, BH_WB_BASE);
        assertTrue(fb, "a fee-0 V3 row lists the base venue");
        assertEq(ib.kind, KIND_V3, "under the row's kind");
        (bool fc, , uint256 nc) = _lists(WAVAX, USDC, BH_WU_CUSTOM);
        assertFalse(fc, "and not the custom venue");
        assertEq(nc, 0, "nothing for WAVAX/USDC");
    }

    /// @notice A KIND_V3 leg declared by hand on the custom venue, at the explicit door.
    function test_AvaxBH_CustomTop_HandRouteV3_QuoteExecOracle() public {
        _addV3Row(500);
        uint256 amt = 1_000e6;
        Run memory r = _run(BH_WU_CUSTOM, KIND_V3, 500, USDC, WAVAX, amt, false);
        _assertRun(r, amt);
    }

    // ─── 3. Q4: the Core's concentrated reader against the Integral layout ─

    /// @notice globalState() of Integral is (price, tick, lastFee, pluginConfig, communityFee,
    ///         a reentrancy flag), one word each in the answer: the Core reads word 0 as the
    ///         price and word 2 as the fee, which are the price and lastFee. The V3 book walk
    ///         asks slot0() and tickBitmap(), which an Integral venue does not answer.
    function test_AvaxBH_Q4_CoreReadsIntegralGlobalStateWords() public view {
        address[2] memory vs = [BH_WU_CUSTOM, BH_WB_BASE];
        for (uint256 i; i < 2; ++i) {
            (uint160 price, int24 tick, uint16 lastFee, uint8 cfg, uint16 comm, ) = IIntegralV(vs[i]).globalState();
            (uint160 sp, uint24 f, bool dyn) = BPC.v3StateAndDynFee(vs[i]);
            console2.log("venue", vs[i], uint256(lastFee), uint256(cfg));
            console2.log("  tick, communityFee", uint256(int256(tick) < 0 ? -int256(tick) : int256(tick)), uint256(comm));
            assertEq(sp, price, "word 0 is the price");
            assertEq(uint256(f), uint256(lastFee), "word 2 is lastFee");
            assertTrue(dyn, "read as dynamic-fee shaped");
        }
        uint256 w = BPC.v4WalkOut(BH_WU_CUSTOM, bytes32(0), 1_000e6, 0, 0, false);
        console2.log("  v3 walk on Integral", w);
        assertEq(w, 0, "the V3 walk reads nothing on an Integral venue");
    }

    /// @notice Liquidity minted by hand into the BASE WAVAX/BLACK venue (empty at the block):
    ///         the automatic door plans over the Algebra row alone and the Router fills it
    ///         across an initialized tick, to the wei of the raw oracle. WAVAX in, BLACK out:
    ///         the fee comes off the input, so the Quoter's scalar is its floor (measured under
    ///         the fill, by the concavity of the output deduction), reproduced from the venue.
    function test_AvaxBH_Q4_BaseMinted_AutoDoor_CrossesTick_QuoteExecOracle() public {
        _addAlgebraRow();
        RawIntegralOracle m = new RawIntegralOracle();
        deal(WAVAX, address(m), 100_000e18);
        deal(BLACK, address(m), 100_000e18);
        // A wide band around the price and a narrow one on the current spacing cell (150).
        (uint256 a0, uint256 a1) = m.mintIn(BH_WB_BASE, -89250, -83100, 1e20);
        (uint256 b0, uint256 b1) = m.mintIn(BH_WB_BASE, -86250, -86100, 1e20);
        console2.log("minted wide  ", a0, a1);
        console2.log("minted narrow", b0, b1);
        assertEq(uint256(IIntegralV(BH_WB_BASE).liquidity()), 2e20, "both bands are live at the price");
        uint256 amt = 100e18;
        Run memory r = _run(BH_WB_BASE, KIND_ALGEBRA, 0, WAVAX, BLACK, amt, true);
        assertTrue(r.liq1 != r.liq0, "the swap crossed an initialized tick");
        _assertRun(r, amt);
    }
}
