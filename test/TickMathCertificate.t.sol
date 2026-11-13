// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  THE TICKMATH TABLE IS CERTIFIED ON EVERY TICK, NOT SAMPLED.
//
//  `Core.sqrtPriceAtTick` is sqrt(1.0001)^tick * 2^96 computed from twenty Q128
//  constants. `test/tools/tickmath_certificate.py` derives each constant from its
//  definition - the integer nearest to 2^128 / sqrt(1.0001)^(2^i) - and walks all
//  1,774,545 ticks with exact interval arithmetic: the outputs are strictly
//  increasing, every tick at or below 0 is the true value rounded up, every tick up
//  to 132,821 is within one Q96 unit of it, and above that the error is below 2^-63
//  of the value. `docs/assurance/tickmath-certificate.tsv` holds the result.
//
//  This file ties that certificate to the compiled code. Each quarter of the range
//  recomputes, from the Core itself, the chain h = sha256(h || uint160 value) the
//  certificate wrote, and checks strict monotonicity on the way: one output that
//  differs anywhere, in any bit, is red. The oracle is the certificate (the
//  definition, bracketed in integers), not the code under test. Green at 2e4fdaa;
//  every constant moved to its other rounding, and every rounding step of the
//  pipeline, turns a test here red (.github/scripts/mutants.py, "TickMath cert").
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";

contract TickMathCertificateTest is Test {
    error NotIncreasing(int24 tick);

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    // The certificate's chains (docs/assurance/tickmath-certificate.tsv, kind "chain"); CI checks they are its.
    bytes32 internal constant CHAIN_Q0 = 0xa34aa7d187d57288a1d4407317d0963637f652325931e3ea9f1c6b62a268e365;
    bytes32 internal constant CHAIN_Q1 = 0x0a87c0864b883629b637c7bdf6f45ee3daff852f60740cb6c2a1f63cdab6e2df;
    bytes32 internal constant CHAIN_Q2 = 0x9d980d5263db316c104316a11c463613045f239959f7a5ba6cf123b5e3864f45;
    bytes32 internal constant CHAIN_Q3 = 0x26935c5692d82b9fbc531ab7632212a98af4c2cc160e011d90ae01fb00d1c3b9;

    /// sha256 chain of sqrtPriceAtTick over [lo, hi], each value strictly above the one before
    /// (the one before lo included, so the quarters join).
    function _chain(int24 lo, int24 hi) internal view returns (bytes32 h) {
        uint160 prev = lo == MIN_TICK ? 0 : BPC.sqrtPriceAtTick(lo - 1);
        for (int24 t = lo; ; ++t) {
            uint160 v = BPC.sqrtPriceAtTick(t);
            if (v <= prev) revert NotIncreasing(t);
            assembly ("memory-safe") {
                let m := mload(0x40)
                mstore(m, h)
                mstore(add(m, 0x20), shl(96, v))
                if iszero(staticcall(gas(), 0x02, m, 52, m, 0x20)) { revert(0, 0) }
                h := mload(m)
            }
            prev = v;
            if (t == hi) break;
        }
    }

    function test_TickMathCert_Q0_FromMinTickThroughMinus443637() public view {
        assertEq(_chain(MIN_TICK, -443637), CHAIN_Q0, "a tick in [-887272, -443637] is not the certificate's");
    }

    function test_TickMathCert_Q1_FromMinus443636ThroughZero() public view {
        assertEq(_chain(-443636, 0), CHAIN_Q1, "a tick in [-443636, 0] is not the certificate's");
    }

    function test_TickMathCert_Q2_FromOneThrough443636() public view {
        assertEq(_chain(1, 443636), CHAIN_Q2, "a tick in [1, 443636] is not the certificate's");
    }

    function test_TickMathCert_Q3_From443637ThroughMaxTick() public view {
        assertEq(_chain(443637, MAX_TICK), CHAIN_Q3, "a tick in [443637, 887272] is not the certificate's");
    }

    function _pin(int24 t, uint160 want) internal pure {
        assertEq(BPC.sqrtPriceAtTick(t), want, "a pinned tick is not the certificate's");
    }

    /// The certificate's values at the range ends, at every power of two and at 2^k - 1 for a few k:
    /// a cheap, readable subset of what the chains pin. For t <= 0 each is ceil(true) exactly.
    function test_TickMathCert_PinnedTicksAreTheCertificates() public pure {
        _pin(-887272, 4295128739);
        _pin(-887271, 4295343490);
        _pin(-524288, 327099227039063107);
        _pin(-524287, 327115581591561469);
        _pin(-262144, 160982827401375763736069);
        _pin(-131072, 112935262922445818024280874);
        _pin(-65536, 2991262837734375505310244437);
        _pin(-65535, 2991412397137370619161096369);
        _pin(-32768, 15394552875315951095595078918);
        _pin(-16384, 34923947901690145425342545399);
        _pin(-8192, 52601903197458624361810746400);
        _pin(-4096, 64556580881331167221767657720);
        _pin(-4095, 64559808629683542212613377072);
        _pin(-2048, 71517125791179246722882903168);
        _pin(-1024, 75273969370139069689486932538);
        _pin(-512, 77225761753129597550065289037);
        _pin(-256, 78220554859095770638340573244);
        _pin(-255, 78224465789067920332153814871);
        _pin(-128, 78722746600537056721934508530);
        _pin(-64, 78975050245229982702767995060);
        _pin(-32, 79101505139923049997807806615);
        _pin(-16, 79164808496886665658930780292);
        _pin(-15, 79168766638360446862420561987);
        _pin(-8, 79196479170490597288862688491);
        _pin(-4, 79212319258289487113226433917);
        _pin(-2, 79220240490215316061937756561);
        _pin(-1, 79224201403219477170569942574);
        _pin(0, 79228162514264337593543950336);
        _pin(1, 79232123823359799118286999568);
        _pin(2, 79236085330515764027303304732);
        _pin(4, 79244008939048815603706035062);
        _pin(8, 79259858533276714757314932306);
        _pin(15, 79287602951555555546117890672);
        _pin(16, 79291567232598584799939703905);
        _pin(32, 79355022692464371645785046467);
        _pin(64, 79482085999252804386437311142);
        _pin(128, 79736823300114093921829183327);
        _pin(255, 80244737654238127488718973609);
        _pin(256, 80248749790819932309965073893);
        _pin(512, 81282483887344747381513967012);
        _pin(1024, 83390072131320151908154831282);
        _pin(2048, 87770609709833776024991924139);
        _pin(4095, 97229249414171470058378025124);
        _pin(4096, 97234110755111693312479820774);
        _pin(8192, 119332217159966728226237229891);
        _pin(16384, 179736315981702064433883588728);
        _pin(32768, 407748233172238350107850275305);
        _pin(65535, 2098373912401228121358801911593);
        _pin(65536, 2098478828474011932436660412518);
        _pin(131072, 55581415166113811149459800483534);
        _pin(262144, 38992368544603139932233054999993536);
        _pin(524287, 19189247130466284822469633870301185392758);
        _pin(524288, 19190206568837448476620805525116361302670);
        _pin(887271, 1461373636630004318706518188784493106690254656249);
        _pin(887272, 1461446703485210103287273052203988822378723970342);
    }

    string internal src;

    function _table(string memory line) internal view {
        assertTrue(vm.indexOf(src, line) != type(uint256).max, line);
    }

    /// The table in the source is the definition's, line for line: each constant is the integer nearest
    /// to 2^128 / sqrt(1.0001)^(2^i), as test/tools/tickmath_certificate.py derives it (CI checks these
    /// lines are its). The chains cannot see this for every constant: moving bit 2, 4 or 12 to its other
    /// rounding leaves all 1,774,545 outputs unchanged (measured on every tick, 2026-11-13).
    function test_TickMathCert_TheTableInTheSourceIsTheDefinition() public {
        src = vm.readFile("src/BlazePhoenixCore.sol");
        _table("uint256 r = a & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;");
        _table("if (a & 0x2 != 0) r = (r * 0xfff97272373d413259a46990580e213a) >> 128;");
        _table("if (a & 0x4 != 0) r = (r * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;");
        _table("if (a & 0x8 != 0) r = (r * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;");
        _table("if (a & 0x10 != 0) r = (r * 0xffcb9843d60f6159c9db58835c926644) >> 128;");
        _table("if (a & 0x20 != 0) r = (r * 0xff973b41fa98c081472e6896dfb254c0) >> 128;");
        _table("if (a & 0x40 != 0) r = (r * 0xff2ea16466c96a3843ec78b326b52861) >> 128;");
        _table("if (a & 0x80 != 0) r = (r * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;");
        _table("if (a & 0x100 != 0) r = (r * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;");
        _table("if (a & 0x200 != 0) r = (r * 0xf987a7253ac413176f2b074cf7815e54) >> 128;");
        _table("if (a & 0x400 != 0) r = (r * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;");
        _table("if (a & 0x800 != 0) r = (r * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;");
        _table("if (a & 0x1000 != 0) r = (r * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;");
        _table("if (a & 0x2000 != 0) r = (r * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;");
        _table("if (a & 0x4000 != 0) r = (r * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;");
        _table("if (a & 0x8000 != 0) r = (r * 0x31be135f97d08fd981231505542fcfa6) >> 128;");
        _table("if (a & 0x10000 != 0) r = (r * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;");
        _table("if (a & 0x20000 != 0) r = (r * 0x5d6af8dedb81196699c329225ee604) >> 128;");
        _table("if (a & 0x40000 != 0) r = (r * 0x2216e584f5fa1ea926041bedfe98) >> 128;");
        _table("if (a & 0x80000 != 0) r = (r * 0x48a170391f7dc42444e8fa2) >> 128;");
    }

    function at(int24 t) external pure returns (uint160) {
        return BPC.sqrtPriceAtTick(t);
    }

    /// The domain is [MIN_TICK, MAX_TICK]: one tick past either end is refused by its own code.
    function test_TickMathCert_OutsideTheRangeIsRefusedByItsCode() public {
        vm.expectRevert(bytes("BPC:tick"));
        this.at(MAX_TICK + 1);
        vm.expectRevert(bytes("BPC:tick"));
        this.at(MIN_TICK - 1);
    }
}
