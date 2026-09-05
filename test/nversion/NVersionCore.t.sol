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
//  runs = 1) and `nver2` (runs = 20000) emit test/nversion/CoreProbe.sol into
//  out-nver1/ and out-nver2/. This test deploys those binaries beside the one
//  compiled with the suite and asserts equality on fuzzed inputs. Missing
//  artefacts SKIP the test (this is a lane, like the fork suites), and
//  `NVERSION_LANE=1` turns that skip into a failure so the lane cannot pass by
//  never having built anything.
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {CoreProbe} from "./CoreProbe.sol";

contract NVersionCoreTest is Test {
    CoreProbe ref;
    CoreProbe[] alts;
    string[] names;

    function setUp() public {
        ref = new CoreProbe();
        _load("nver1", "out-nver1");
        _load("nver2", "out-nver2");
    }

    /// The Core library has PUBLIC functions (outSolidly), so the probe's artefact carries an
    /// unlinked placeholder for it. Under each profile the library is deployed from ITS OWN
    /// artefact (compiled with the same settings) and the placeholder is replaced by hand — the
    /// same link the compiler would perform, so the alternate binary is complete.
    function _load(string memory name, string memory dir) private {
        string memory probe = string.concat(dir, "/CoreProbe.sol/CoreProbe.json");
        string memory lib = string.concat(dir, "/BlazePhoenixCore.sol/BlazePhoenixCore.json");
        if (!vm.exists(probe) || !vm.exists(lib)) return;
        address libAddr = _deploy(vm.parseJsonString(vm.readFile(lib), ".bytecode.object"));
        string memory hex_ = vm.parseJsonString(vm.readFile(probe), ".bytecode.object");
        // placeholder = "__$" + first 34 hex chars of keccak256("src/BlazePhoenixCore.sol:BlazePhoenixCore") + "$__"
        bytes32 h = keccak256("src/BlazePhoenixCore.sol:BlazePhoenixCore");
        string memory hh = vm.toString(h);                         // "0x" + 64 hex
        bytes memory hb = bytes(hh);
        bytes memory key = new bytes(34);
        for (uint256 i; i < 34; ++i) key[i] = hb[2 + i];
        string memory placeholder = string.concat("__$", string(key), "$__");
        bytes memory ab = bytes(vm.toString(libAddr));             // "0x" + 40 hex
        bytes memory addrHex = new bytes(40);
        for (uint256 i; i < 40; ++i) addrHex[i] = ab[2 + i];
        hex_ = vm.replace(hex_, placeholder, string(addrHex));
        address a = _deploy(hex_);
        alts.push(CoreProbe(a));
        names.push(name);
    }

    function _deploy(string memory hex_) private returns (address a) {
        bytes memory code = vm.parseBytes(hex_);
        assembly { a := create(0, add(code, 32), mload(code)) }
        require(a != address(0), "n-version: deploy failed (unlinked or reverting init code)");
    }

    function _armed() private returns (bool) {
        if (alts.length != 0) return true;
        if (vm.envOr("NVERSION_LANE", false)) fail("n-version lane: no alternate artefacts found (build nver1/nver2 first)");
        vm.skip(true);
        return false;
    }

    function test_NVersion_LaneReportsWhatItCompares() public {
        if (!_armed()) return;
        for (uint256 i; i < alts.length; ++i) {
            assertTrue(address(alts[i]).code.length != 0, "alternate probe has no code");
            assertTrue(keccak256(address(alts[i]).code) != keccak256(address(ref).code), string.concat(names[i], ": identical bytecode - the profile changed nothing, so this compares a program with itself"));
        }
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
