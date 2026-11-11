// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  The Core's dispatcher holds the doors somebody calls, and no other.
//
//  The Core is a DELEGATECALL-linked library: a `public` function is a row in
//  its dispatcher, an ABI wrapper in its runtime, and gas on the doors the
//  dispatcher reaches past it (measured with the five below gone: 22 to 88 less
//  on a call to a door that stayed). Those are worth paying for a function
//  another contract reaches through the dispatcher. They buy nothing for one
//  the Core reaches with a jump, or that only the suite calls - and at cb1d7d9
//  five such functions were doors all the same (`solidlyGetAmountOut`,
//  `outSolidly`, `solidlyCurveOut`, `readDynamicFee`, `impactV3FromOut`): 418
//  bytes of a contract 926 bytes under its gate. `internal` serves the suite as
//  well; the library is inlined into the harness that calls it.
//
//  THE MEASUREMENT - on the artefacts, not on the source. A grep for
//  `BPC.name(` reads comments as calls and says nothing of what was compiled.
//  The build already holds both facts:
//
//    doors    the Core artefact's `methodIdentifiers`;
//    callers  every artefact compiled from src/ whose runtime carries the
//             Core's link placeholder - that placeholder IS "this contract
//             delegatecalls the Core", so nobody keeps a list of who does;
//    a call   the selector as the compiler writes it at a call site: the
//             shortest push of the selector without its trailing zero bits,
//             then the shift that puts it back at the top of the word
//             (PUSHn sel>>z, PUSH1 224+z, SHL). Calibrated at cb1d7d9: all 20
//             doors that src/ calls are found this way, in at least one
//             linker, and none of the 6 that it does not.
//
//  The instrument checks itself before it is believed: every door must sit in
//  the Core's own dispatcher (so the selector derived from the signature is the
//  real one), and every linker must be seen calling at least one door (so a
//  compiler that starts writing call sites another way reads as "the
//  instrument moved", loudly, and never as "nothing is called").
//
//  AND IT READS WHAT WAS BUILT FROM THIS TREE. An artefact is a file: a build
//  that compiles only the tests it was asked for (`--match-test`, which is how
//  the mutation guard runs every mutant) leaves every other artefact as the
//  last build wrote it. So the Core and the four contracts that link it are
//  imported below - whatever compiles this test compiles them - and each
//  artefact read is checked against the disk: every source its metadata names
//  must hash, now, to the hash it was compiled from. A fifth contract that
//  links the Core and is not imported here fails that check by name on the
//  first partial build, and does not pass on an old binary.
//
//  ONE DOOR IS NAMED AS UNCALLED: `v4WalkRank`. No contract calls it; the suite
//  measures the walk's rank and its gas through it, and what it measures is the
//  dispatcher's own figure, which an inlined copy would not give. It is named
//  here so the exception is one visible line. If it gains a caller or stops
//  being a door, the line is dead and should go.
//
//  RED BEFORE GREEN. Red at cb1d7d9: five doors nobody calls. Green once they
//  are internal. The five mutants beside it in .github/scripts/mutants.py put
//  each one back as `public`, alone, and each turns this red.
// =============================================================================
import {Test, Vm} from "forge-std/Test.sol";
// Not called: imported so that a build of this test is a build of the artefacts it reads.
import {BlazePhoenixCore} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";

contract CoreSurfaceIsTheCalledSurfaceTest is Test {
    string constant OUT = "out/";
    string constant SRC = "src";
    string constant CORE_FILE = "BlazePhoenixCore.sol";
    string constant CORE_NAME = "BlazePhoenixCore";
    /// The one door no contract calls. See the header.
    string constant MEASUREMENT_DOOR = "v4WalkRank";

    /// The artefact (by path) of every contract that links the Core.
    string[] linkers;

    function test_EveryDoorOfTheCoreIsCalledByAContractThatLinksIt() public {
        (string[] memory doors, string[] memory sites) = _doors();
        _findLinkers();
        assertGt(doors.length, 0, "the Core artefact declares no door: nothing was measured");
        assertGt(linkers.length, 0, "no artefact of src/ links the Core: nothing was measured");

        bool[] memory called = new bool[](doors.length);
        for (uint256 l; l < linkers.length; ++l) {
            uint256 free = _mark();
            string memory art = vm.readFile(linkers[l]);
            _assertBuiltFromDisk(art);
            string memory code = vm.parseJsonString(art, ".deployedBytecode.object");
            bool any;
            for (uint256 d; d < doors.length; ++d) {
                if (_writes(code, sites[d])) (called[d], any) = (true, true);
            }
            // The instrument, before the claim: a contract that links the Core calls it.
            assertTrue(any, string.concat(
                "a contract links the Core and no call site was found in it - the instrument moved, not the surface: ", linkers[l]));
            _release(free);
        }

        string memory uncalled;
        for (uint256 d; d < doors.length; ++d) {
            if (!called[d] && !_isMeasurementDoor(doors[d])) uncalled = string.concat(uncalled, " ", doors[d]);
        }
        assertEq(uncalled, "", "the Core carries doors that no contract calls");
    }

    // ─── the doors, and who links the Core ───────────────────────────────────

    /// Every door of the Core, by signature, and the call site of each. A selector is derived from
    /// its signature and has to be one the Core's own dispatcher compares against.
    function _doors() private view returns (string[] memory doors, string[] memory sites) {
        string memory core = vm.readFile(string.concat(OUT, CORE_FILE, "/", CORE_NAME, ".json"));
        _assertBuiltFromDisk(core);
        string memory dispatcher = vm.parseJsonString(core, ".deployedBytecode.object");
        doors = vm.parseJsonKeys(core, ".methodIdentifiers");
        sites = new string[](doors.length);
        for (uint256 d; d < doors.length; ++d) {
            bytes4 sel = bytes4(keccak256(bytes(doors[d])));
            assertTrue(_writes(dispatcher, _push(uint32(sel))),
                string.concat("the selector derived for this door is not in the Core's dispatcher: ", doors[d]));
            sites[d] = _callSite(sel);
        }
    }

    /// Every contract compiled from a file of src/ whose runtime carries the Core's link placeholder.
    function _findLinkers() private {
        string memory placeholder = _placeholder();
        string[] memory files = _files(SRC, ".sol");
        for (uint256 f; f < files.length; ++f) {
            string memory dir = string.concat(OUT, files[f]);
            if (!vm.isDir(dir)) continue;
            string[] memory arts = _files(dir, ".json");
            for (uint256 a; a < arts.length; ++a) {
                string memory path = string.concat(dir, "/", arts[a]);
                uint256 free = _mark();
                string memory code = vm.parseJsonString(vm.readFile(path), ".deployedBytecode.object");
                bool links = vm.indexOf(code, placeholder) != type(uint256).max;
                _release(free);
                if (links) linkers.push(path);
            }
        }
    }

    /// The artefact was compiled from the sources that are on disk now.
    function _assertBuiltFromDisk(string memory art) private view {
        string[] memory paths = vm.parseJsonKeys(art, ".metadata.sources");
        assertGt(paths.length, 0, "an artefact names no source: nothing says what it was built from");
        for (uint256 i; i < paths.length; ++i) {
            assertEq(
                keccak256(bytes(vm.readFile(paths[i]))),
                vm.parseJsonBytes32(art, string.concat(".metadata.sources['", paths[i], "'].keccak256")),
                string.concat("an artefact read here is older than its source (is its contract imported above?): ", paths[i])
            );
        }
    }

    /// "__$" + the first 34 hex characters of keccak256("<source path>:<library>") + "$__": what
    /// solc leaves where a library's address goes (the derivation NVersionCore.t.sol links by).
    function _placeholder() private pure returns (string memory) {
        bytes memory h = bytes(vm.toString(keccak256(bytes(string.concat(SRC, "/", CORE_FILE, ":", CORE_NAME)))));
        bytes memory key = new bytes(34);
        for (uint256 i; i < 34; ++i) key[i] = h[2 + i];
        return string.concat("__$", string(key), "$__");
    }

    /// The files of `dir`, and of the directories under it, whose name ends in `suffix`: by name.
    function _files(string memory dir, string memory suffix) private view returns (string[] memory names) {
        Vm.DirEntry[] memory es = vm.readDir(dir, 8);
        string[] memory buf = new string[](es.length);
        uint256 n;
        for (uint256 i; i < es.length; ++i) {
            if (es[i].isDir) continue;
            string[] memory parts = vm.split(es[i].path, "/");
            string memory name = parts[parts.length - 1];
            bytes memory b = bytes(name);
            bytes memory s = bytes(suffix);
            if (b.length <= s.length) continue;
            bool ends = true;
            for (uint256 k; k < s.length && ends; ++k) ends = b[b.length - s.length + k] == s[k];
            if (ends) buf[n++] = name;
        }
        names = new string[](n);
        for (uint256 i; i < n; ++i) names[i] = buf[i];
    }

    // ─── a door, and a call to it ────────────────────────────────────────────

    function _isMeasurementDoor(string memory signature) private pure returns (bool) {
        return keccak256(bytes(vm.split(signature, "(")[0])) == keccak256(bytes(MEASUREMENT_DOOR));
    }

    /// PUSHn v, in hex: the shortest push that holds v.
    function _push(uint256 v) private pure returns (string memory) {
        uint256 n;
        for (uint256 t = v; t != 0; t >>= 8) ++n;
        require(n != 0, "a zero word has no push to look for");
        bytes memory code = new bytes(1 + n);
        code[0] = bytes1(uint8(0x5f + n));
        for (uint256 i; i < n; ++i) code[1 + i] = bytes1(uint8(v >> (8 * (n - 1 - i))));
        return _hex(code);
    }

    /// The selector at a call site: PUSHn (sel >> z), PUSH1 (224 + z), SHL - z its trailing zero bits.
    function _callSite(bytes4 sel) private pure returns (string memory) {
        uint256 v = uint32(sel);
        require(v != 0, "a zero selector has no call site to look for");
        uint256 z;
        while (v & 1 == 0) { v >>= 1; ++z; }
        return string.concat(_push(v), _hex(abi.encodePacked(bytes1(0x60), bytes1(uint8(224 + z)), bytes1(0x1b))));
    }

    /// Is `code` (the artefact's hex, "0x" first) carrying `pattern` on a byte boundary? ("0x" is two
    /// characters and a link placeholder forty, so a byte starts at every even one.)
    function _writes(string memory code, string memory pattern) private pure returns (bool hit) {
        uint256 free = _mark();
        uint256 off = vm.indexOf(code, pattern);
        if (off != type(uint256).max) {
            hit = off % 2 == 0;
            if (!hit) { // the first hit straddles two bytes: try them all
                string[] memory parts = vm.split(code, pattern);
                off = 0;
                for (uint256 i; i + 1 < parts.length && !hit; ++i) {
                    off += bytes(parts[i]).length;
                    hit = off % 2 == 0;
                    off += bytes(pattern).length;
                }
            }
        }
        _release(free);
    }

    function _hex(bytes memory b) private pure returns (string memory) {
        bytes memory digits = "0123456789abcdef";
        bytes memory s = new bytes(2 * b.length);
        for (uint256 i; i < b.length; ++i) {
            s[2 * i] = digits[uint8(b[i]) >> 4];
            s[2 * i + 1] = digits[uint8(b[i]) & 0x0f];
        }
        return string(s);
    }

    // ─── memory ──────────────────────────────────────────────────────────────
    // An artefact is a quarter of a megabyte of JSON, and every cheatcode call copies what it is
    // handed. What a step has finished reading is given back, or the test pays for it by the square.

    function _mark() private pure returns (uint256 free) {
        assembly ("memory-safe") { free := mload(0x40) }
    }

    function _release(uint256 free) private pure {
        assembly ("memory-safe") { mstore(0x40, free) }
    }
}
