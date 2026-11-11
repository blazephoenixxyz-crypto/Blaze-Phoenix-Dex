// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  N-version testing of the Core's quote maths across compiler settings.
//
//  The suite executes ONE binary — the one the release profile emits (see
//  profile_parity.py). Every other optimiser setting is a different program
//  compiled from the same source, and the compiler is a component like any
//  other: a miscompile, or source that only means what we think it means under
//  one setting, is invisible to a suite that runs under that setting alone.
//
//  The lane: `FOUNDRY_PROFILE=nver1 forge build --skip '*.t.sol'` (optimizer
//  runs = 1), `nver2` (runs = 20000) and `nver3` (a Yul step sequence with no
//  FunctionSpecializer) emit test/nversion/CoreProbe.sol and MathProbe.sol into
//  out-nver1/ to out-nver3/. This test deploys those binaries beside the ones
//  compiled with the suite and asserts equality on fuzzed inputs: the Core's
//  quote maths value by value, the Math library's band selection byte for
//  byte (the whole return, or the whole revert). Missing
//  artefacts SKIP the test (this is a lane, like the fork suites), and
//  `NVERSION_LANE=1` turns that skip into a failure so the lane cannot pass by
//  never having built anything.
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {CoreProbe} from "./CoreProbe.sol";
import {MathProbe} from "./MathProbe.sol";

contract NVersionCoreTest is Test {
    CoreProbe ref;
    CoreProbe[] alts;
    string[] names;
    string[] dirs;
    MathProbe mref;
    address[] mAlts;
    /// Where the suite's own binaries are: the artefacts the reference probes were deployed from.
    string constant REF_OUT = "out";
    string constant CORE_ID = "src/BlazePhoenixCore.sol:BlazePhoenixCore";
    string constant MATH_ID = "src/BlazePhoenixMath.sol:BlazePhoenixMath";

    function setUp() public {
        ref = new CoreProbe();
        mref = new MathProbe();
        _load("nver1", "out-nver1");
        _load("nver2", "out-nver2");
        _load("nver3", "out-nver3");
    }

    /// The Core library has PUBLIC functions, and so does the Math library (select); a probe that
    /// calls one carries an unlinked placeholder for its library. Under each profile every
    /// library is deployed from ITS OWN artefact (compiled with the same settings) and the
    /// placeholders are replaced by hand - the same link the compiler would perform, so the
    /// alternate binaries are complete. Today the Core probe calls none (`outSolidly`, the last
    /// one, is internal and inlined like the rest): it has no placeholder and its replace below
    /// changes nothing. The Math probe and the Math library still carry theirs.
    function _load(string memory name, string memory dir) private {
        string memory probe = string.concat(dir, "/CoreProbe.sol/CoreProbe.json");
        string memory lib = string.concat(dir, "/BlazePhoenixCore.sol/BlazePhoenixCore.json");
        if (!vm.exists(probe) || !vm.exists(lib)) return;
        address libAddr = _deploy(_code(lib));
        alts.push(CoreProbe(_deploy(_link(_code(probe), CORE_ID, libAddr))));
        names.push(name);
        dirs.push(dir);
        string memory mprobe = string.concat(dir, "/MathProbe.sol/MathProbe.json");
        string memory mlib = string.concat(dir, "/BlazePhoenixMath.sol/BlazePhoenixMath.json");
        require(vm.exists(mprobe) && vm.exists(mlib), string.concat("n-version: ", name, " built the Core probe but not the Math probe"));
        address mlibAddr = _deploy(_link(_code(mlib), CORE_ID, libAddr));
        mAlts.push(_deploy(_link(_link(_code(mprobe), MATH_ID, mlibAddr), CORE_ID, libAddr)));
    }

    function _code(string memory artefact) private view returns (string memory) {
        return vm.parseJsonString(vm.readFile(artefact), ".bytecode.object");
    }

    function _runtime(string memory artefact) private view returns (string memory) {
        return vm.parseJsonString(vm.readFile(artefact), ".deployedBytecode.object");
    }

    /// placeholder = "__$" + first 34 hex chars of keccak256(<file>:<library>) + "$__"
    function _link(string memory hex_, string memory id, address at) private pure returns (string memory) {
        bytes memory hb = bytes(vm.toString(keccak256(bytes(id))));      // "0x" + 64 hex
        bytes memory key = new bytes(34);
        for (uint256 i; i < 34; ++i) key[i] = hb[2 + i];
        bytes memory ab = bytes(vm.toString(at));                        // "0x" + 40 hex
        bytes memory addrHex = new bytes(40);
        for (uint256 i; i < 40; ++i) addrHex[i] = ab[2 + i];
        return vm.replace(hex_, string.concat("__$", string(key), "$__"), string(addrHex));
    }

    /// Compared UNLINKED, artefact against artefact. Deployed code embeds each library's address,
    /// so the same program linked to two library deployments differs by those 20 bytes alone: a
    /// comparison of deployed code would call a profile that changed nothing "different".
    function _sameAsSuite(string memory dir, string memory probe, string memory lib) private view returns (bool) {
        return keccak256(bytes(_runtime(string.concat(dir, "/", probe))))
                == keccak256(bytes(_runtime(string.concat(REF_OUT, "/", probe))))
            && keccak256(bytes(_runtime(string.concat(dir, "/", lib))))
                == keccak256(bytes(_runtime(string.concat(REF_OUT, "/", lib))));
    }

    function _deploy(string memory hex_) private returns (address a) {
        bytes memory code = vm.parseBytes(hex_);
        assembly { a := create(0, add(code, 32), mload(code)) }
        require(a != address(0), "n-version: deploy failed (unlinked or reverting init code)");
    }

    function _armed() private returns (bool) {
        if (alts.length != 0) return true;
        if (vm.envOr("NVERSION_LANE", false)) fail("n-version lane: no alternate artefacts found (build nver1/nver2/nver3 first)");
        vm.skip(true);
        return false;
    }

    function test_NVersion_LaneReportsWhatItCompares() public {
        if (!_armed()) return;
        for (uint256 i; i < alts.length; ++i) {
            assertTrue(address(alts[i]).code.length != 0, "alternate probe has no code");
            assertTrue(mAlts[i].code.length != 0, "alternate Math probe has no code");
            assertFalse(_sameAsSuite(dirs[i], "CoreProbe.sol/CoreProbe.json", "BlazePhoenixCore.sol/BlazePhoenixCore.json"),
                string.concat(names[i], ": the Core probe and library compiled exactly as the suite's - the profile changed nothing, so this compares a program with itself"));
            assertFalse(_sameAsSuite(dirs[i], "MathProbe.sol/MathProbe.json", "BlazePhoenixMath.sol/BlazePhoenixMath.json"),
                string.concat(names[i], ": the Math probe and library compiled exactly as the suite's - the profile changed nothing, so this compares a program with itself"));
        }
    }

    /// The whole answer of `select` (return or revert, byte for byte) under every binary.
    function _sameSelect(uint256[] memory rates, uint256[] memory depths, uint256[] memory bals, uint256[] memory fe,
        uint256 blind, uint256 budget) private view returns (bool ok0)
    {
        bytes memory cd = abi.encodeCall(MathProbe.select, (rates, depths, bals, fe, blind, budget));
        bytes memory r0;
        (ok0, r0) = address(mref).staticcall(cd);
        for (uint256 i; i < mAlts.length; ++i) {
            (bool ok, bytes memory r) = mAlts[i].staticcall(cd);
            assertEq(ok, ok0, string.concat("select reverts under one binary and not the other: ", names[i]));
            assertEq(r, r0, string.concat("select answers differently under ", names[i]));
        }
    }

    /// A band the suite's binary answers (so the comparison is on values, not on two reverts).
    function test_NVersion_MathSelect_AnswersAlike() public {
        if (!_armed()) return;
        uint256[] memory rates = new uint256[](4);
        uint256[] memory depths = new uint256[](4);
        uint256[] memory fe = new uint256[](4);
        (rates[0], rates[1], rates[2], rates[3]) = (997e15, 990e15, 1003e15, 700e15);
        (depths[0], depths[1], depths[2], depths[3]) = (5e21, 3e21, 1e21, 2e21);
        (fe[0], fe[1], fe[2], fe[3]) = (3000 | 1e14 << 24, 5000 | 1e14 << 24, 500 | 1e14 << 24, 3000 | 1e14 << 24);
        assertTrue(_sameSelect(rates, depths, depths, fe, 0, 8), "the suite's binary must answer this band");
    }

    function testFuzz_NVersion_MathSelect(uint256 seed, uint8 rows, uint8 blind, uint256 budget) public {
        if (!_armed()) return;
        uint256 n = bound(rows, 1, 8);
        uint256[] memory rates = new uint256[](n);
        uint256[] memory depths = new uint256[](n);
        uint256[] memory bals = new uint256[](n);
        uint256[] memory fe = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            rates[i] = 1e15 + r % 1e21;
            depths[i] = 1 + (r >> 72) % 1e30;
            bals[i] = (r >> 8) & 1 == 1 ? depths[i] : 1 + (r >> 120) % 1e30;
            fe[i] = (r >> 176) % 30_001 | ((r >> 200) % 1e17) << 24;
        }
        _sameSelect(rates, depths, bals, fe, blind, bound(budget, 0, 16));
    }

    function testFuzz_NVersion_OutV2(uint256 ain, uint256 rIn, uint256 rOut, uint16 fee) public {
        if (!_armed()) return;
        ain = bound(ain, 0, 1e30); rIn = bound(rIn, 0, 1e33); rOut = bound(rOut, 0, 1e33);
        uint256 f = bound(fee, 0, 10_000);
        uint256 want = ref.outV2(ain, rIn, rOut, f);
        for (uint256 i; i < alts.length; ++i) assertEq(alts[i].outV2(ain, rIn, rOut, f), want, string.concat("outV2 differs under ", names[i]));
    }

    function testFuzz_NVersion_OutV3(uint256 ain, uint256 liq, uint256 sqrtP, uint24 fee, bool zfo) public {
        if (!_armed()) return;
        ain = bound(ain, 0, 1e27); liq = bound(liq, 0, 1e30); sqrtP = bound(sqrtP, 0, 2 ** 120);
        uint256 want = ref.outV3(ain, uint160(sqrtP), uint128(liq), fee, zfo, 0);
        for (uint256 i; i < alts.length; ++i) assertEq(alts[i].outV3(ain, uint160(sqrtP), uint128(liq), fee, zfo, 0), want, string.concat("outV3 differs under ", names[i]));
    }

    function testFuzz_NVersion_OutSolidly(uint256 ain, uint256 rIn, uint256 rOut, uint16 fee, bool stable, uint8 dIn, uint8 dOut) public {
        if (!_armed()) return;
        rIn = bound(rIn, 0, 1e30); rOut = bound(rOut, 0, 1e30); ain = bound(ain, 0, 1e29);
        uint256 f = bound(fee, 0, 10_000);
        uint256 want = ref.outSolidly(ain, rIn, rOut, f, stable);
        for (uint256 i; i < alts.length; ++i) assertEq(alts[i].outSolidly(ain, rIn, rOut, f, stable), want, string.concat("outSolidly differs under ", names[i]));
        dIn = uint8(bound(dIn, 0, 18)); dOut = uint8(bound(dOut, 0, 18));
        uint256 wantD = ref.outSolidlyStable(ain, rIn, rOut, f, dIn, dOut);
        for (uint256 i; i < alts.length; ++i) assertEq(alts[i].outSolidlyStable(ain, rIn, rOut, f, dIn, dOut), wantD, string.concat("outSolidlyStable differs under ", names[i]));
    }

    function testFuzz_NVersion_MulDiv(uint256 a, uint256 b, uint256 d) public {
        if (!_armed()) return;
        d = bound(d, 1, type(uint256).max);
        // stay inside the domain where the 512-bit product fits the divisor (the library's own
        // overflow condition), so every binary returns and the comparison is on values
        uint256 prod1;
        unchecked {
            uint256 mm = mulmod(a, b, type(uint256).max);
            uint256 prod0 = a * b;
            prod1 = mm - prod0 - (mm < prod0 ? 1 : 0);
        }
        vm.assume(d > prod1);
        uint256 want = ref.mulDiv(a, b, d);
        vm.assume(want < type(uint256).max);
        uint256 wantUp = ref.mulDivUp(a, b, d);
        for (uint256 i; i < alts.length; ++i) {
            assertEq(alts[i].mulDiv(a, b, d), want, string.concat("mulDiv differs under ", names[i]));
            assertEq(alts[i].mulDivUp(a, b, d), wantUp, string.concat("mulDivUp differs under ", names[i]));
        }
    }
}
