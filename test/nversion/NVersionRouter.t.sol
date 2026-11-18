// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;
// =============================================================================
//  N-version testing of the Router across compiler settings.
//
//  The release Yul step sequence leaves out solc's FunctionSpecializer (F);
//  nver3 is the built-in sequence WITH it, so the lane holds the shipped Router
//  beside the one the release built before F was dropped, and nver1/nver2 beside
//  it at optimizer_runs 1 and 20000. NVersionCore.t.sol compares the Core's quote
//  maths and the Math library; the Router is where the floors, the fee split and
//  the per-leg arithmetic run, and it was the contract the dropped F shrank most
//  in absolute need (24774 -> 23642 B on the stacked fixes). Each alternate Router
//  is deployed from its own artefact, linked to a Core library from the SAME
//  artefact directory, beside the Hub, Solver and pools compiled with the suite:
//  only the Router binary differs. For every input the whole outcome is compared:
//  success flag, return or revert bytes, what the recipient received, what each
//  pool and the Router hold afterwards.
//
//  Axes: amountIn from 1 wei to type(uint128).max (the door's bound) and one
//  past it; 1 hop and 2 hops; a fee-on-transfer input token (0..10%); the
//  user's floor at the delivered amount and one wei above it. Missing artefacts
//  SKIP (a lane), NVERSION_LANE=1 turns the skip into a failure. An alternate
//  may pass 24576 B (nver2: 26769 B): the lane compares answers and forge test
//  does not apply EIP-170; the release Router's size is guarded by .sizes-snapshot.
//
//  Mutant: nver3 given the release's step sequence (nver3 == the suite's Router)
//  turns test_NVersionRouter_LaneComparesAnotherBinary red: the lane would then
//  compare the shipped Router against itself.
// =============================================================================
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixCore as BPC, RoutePlan} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV2Pair} from "../mocks/MockV2Pair.sol";

contract NVersionRouterTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    BlazePhoenixQuoter quoter;
    address ref;
    address[] alts;
    string[] names;
    string[] dirs;
    MockERC20 tIn;
    MockERC20 tOut;
    MockERC20 tBr;
    address[] pools;
    address user = address(0xA11CE);
    string constant REF_OUT = "out";
    string constant CORE_ID = "src/BlazePhoenixCore.sol:BlazePhoenixCore";
    string constant ROUTER_ART = "BlazePhoenixRouter.sol/BlazePhoenixRouter.json";

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        ref = address(new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2)));
        tIn = new MockERC20("IN", "IN");
        tOut = new MockERC20("OUT", "OUT");
        tBr = new MockERC20("BR", "BR");
        _loadRouter("nver1", "out-nver1");
        _loadRouter("nver2", "out-nver2");
        _loadRouter("nver3", "out-nver3");
    }

    function _loadRouter(string memory name, string memory dir) private {
        string memory art = string.concat(dir, "/", ROUTER_ART);
        string memory lib = string.concat(dir, "/BlazePhoenixCore.sol/BlazePhoenixCore.json");
        if (!vm.exists(art) || !vm.exists(lib)) return;
        address libAddr = _deploy(vm.parseBytes(_code(lib)));
        bytes memory init = bytes.concat(
            vm.parseBytes(_link(_code(art), CORE_ID, libAddr)),
            abi.encode(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2))
        );
        alts.push(_deploy(init));
        names.push(name);
        dirs.push(dir);
    }

    function _code(string memory artefact) private view returns (string memory) {
        return vm.parseJsonString(vm.readFile(artefact), ".bytecode.object");
    }

    function _runtime(string memory artefact) private view returns (string memory) {
        return vm.parseJsonString(vm.readFile(artefact), ".deployedBytecode.object");
    }

    /// placeholder = "__$" + first 34 hex chars of keccak256(<file>:<library>) + "$__"
    function _link(string memory hex_, string memory id, address at) private pure returns (string memory) {
        bytes memory hb = bytes(vm.toString(keccak256(bytes(id))));
        bytes memory key = new bytes(34);
        for (uint256 i; i < 34; ++i) key[i] = hb[2 + i];
        bytes memory ab = bytes(vm.toString(at));
        bytes memory addrHex = new bytes(40);
        for (uint256 i; i < 40; ++i) addrHex[i] = ab[2 + i];
        return vm.replace(hex_, string.concat("__$", string(key), "$__"), string(addrHex));
    }

    function _deploy(bytes memory code) private returns (address a) {
        assembly { a := create(0, add(code, 32), mload(code)) }
        require(a != address(0), "n-version: deploy failed (unlinked or reverting init code)");
    }

    function _armed() private returns (bool) {
        if (alts.length != 0) return true;
        if (vm.envOr("NVERSION_LANE", false)) fail("n-version lane: no alternate Router artefacts (build nver1/nver2/nver3 first)");
        vm.skip(true);
        return false;
    }

    function _seed(MockERC20 a, MockERC20 b, uint256 ra, uint256 rb) private {
        MockV2Pair p = new MockV2Pair(address(a), address(b));
        a.mint(address(p), ra);
        b.mint(address(p), rb);
        bool aIs0 = address(a) < address(b);
        p.setReserves(uint112(aIs0 ? ra : rb), uint112(aIs0 ? rb : ra));
        hub.seedPool(address(p), BPC.KIND_V2, 30, address(0), address(a), address(b));
        pools.push(address(p));
    }

    /// 1 hop: one V2 pool tIn/tOut. 2 hops: tIn/tBr and tBr/tOut through a registered bridge,
    /// no direct pool, so the route has to take both hops.
    function _world(bool twoHops, uint16 fotBps) private {
        if (twoHops) {
            hub.addBridge(address(tBr));
            _seed(tIn, tBr, 1_000_000e18, 1_000_000e18);
            _seed(tBr, tOut, 1_000_000e18, 1_600_000e18);
        } else {
            _seed(tIn, tOut, 1_000_000e18, 1_600_000e18);
        }
        tIn.setFeeOnTransferBps(fotBps);
    }

    /// Everything one swap leaves behind that a binary could get wrong.
    function _outcome(address r, bytes memory cd, uint256 amountIn) private returns (bytes memory o) {
        uint256 snap = vm.snapshotState();
        hub.setRoles(r, address(solver), address(quoter));
        tIn.mint(user, amountIn);
        vm.prank(user);
        tIn.approve(r, amountIn);
        vm.prank(user);
        (bool ok, bytes memory ret) = r.call(cd);
        o = abi.encode(ok, ret, tOut.balanceOf(user), tIn.balanceOf(user),
            tIn.balanceOf(r), tOut.balanceOf(r), tBr.balanceOf(r));
        for (uint256 i; i < pools.length; ++i)
            o = bytes.concat(o, abi.encode(tIn.balanceOf(pools[i]), tOut.balanceOf(pools[i]), tBr.balanceOf(pools[i])));
        require(vm.revertToState(snap), "revert snap");
    }

    function _alike(bytes memory cd, uint256 amountIn, string memory what) private returns (bytes memory want) {
        want = _outcome(ref, cd, amountIn);
        for (uint256 i; i < alts.length; ++i)
            assertEq(keccak256(_outcome(alts[i], cd, amountIn)), keccak256(want),
                string.concat("n-version: the Router under ", names[i], " answers otherwise: ", what));
    }

    function _best(uint256 amountIn, uint256 minOut) private view returns (bytes memory) {
        return abi.encodeCall(BlazePhoenixRouter.swapBestExactIn,
            (address(tIn), address(tOut), amountIn, minOut, user, block.timestamp + 1));
    }

    /// Both doors at the floor and one wei above it: the delivered amount D of the reference is
    /// the floor that must pass, D + 1 the floor that must refuse, on every binary alike.
    function _bothDoors(uint256 amountIn) private {
        bytes memory got = _alike(_best(amountIn, 1), amountIn, "swapBestExactIn, floor 1");
        (bool ok, bytes memory ret) = abi.decode(got, (bool, bytes));
        if (ok) {
            uint256 d = abi.decode(ret, (uint256));
            _alike(_best(amountIn, d), amountIn, "swapBestExactIn, floor = delivered");
            _alike(_best(amountIn, d + 1), amountIn, "swapBestExactIn, floor = delivered + 1");
        }
        try solver.findBestRoutePlan(address(tIn), address(tOut), amountIn) returns (RoutePlan memory plan) {
            if (plan.best.hops.length == 0) return;
            bytes memory cd = abi.encodeCall(BlazePhoenixRouter.swapExactIn,
                (plan.best, amountIn, 1, user, block.timestamp + 1));
            _alike(cd, amountIn, "swapExactIn, floor 1");
        } catch {}
    }

    /// Quantity: the binary the lane compares is another one. Unlinked artefact against artefact;
    /// a lane whose alternate equals the suite's Router would pass every comparison by construction.
    function test_NVersionRouter_LaneComparesAnotherBinary() public {
        if (!_armed()) return;
        string memory mine = _runtime(string.concat(REF_OUT, "/", ROUTER_ART));
        for (uint256 i; i < dirs.length; ++i) {
            emit log_named_string("n-version Router against the suite's", names[i]);
            assertTrue(keccak256(bytes(_runtime(string.concat(dirs[i], "/", ROUTER_ART)))) != keccak256(bytes(mine)),
                string.concat("n-version: ", names[i], " built the same Router as the suite, so the lane compares nothing"));
        }
    }

    /// Edges named, not left to the fuzzer: 1 wei, the pools' depth, the door's bound and one past it.
    function test_NVersionRouter_EdgesAnswerAlike() public {
        if (!_armed()) return;
        uint256[5] memory amts = [uint256(1), 1e18, 1_000_000e18, uint256(type(uint128).max), uint256(type(uint128).max) + 1];
        for (uint256 h; h < 2; ++h) {
            uint256 snap = vm.snapshotState();
            _world(h == 1, 0);
            for (uint256 i; i < amts.length; ++i) _bothDoors(amts[i]);
            require(vm.revertToState(snap), "revert world");
        }
    }

    function testFuzz_NVersionRouter_SwapAnswersAlike(uint256 amountIn, bool twoHops, uint16 fotBps) public {
        if (!_armed()) return;
        amountIn = bound(amountIn, 1, 10_000_000e18);
        fotBps = uint16(bound(fotBps, 0, 1000));
        _world(twoHops, fotBps);
        _bothDoors(amountIn);
    }
}
