// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Shared fixture of the Diff*.t.sol files (atq-1111, front "dif"): the full stack, venues of three
// kinds on any pair, and one way to fire a Router call and MEASURE what the user received.
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixQuoter} from "../src/BlazePhoenixQuoter.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";

abstract contract DiffWorld is Test {
    BlazePhoenixHub internal hub;
    BlazePhoenixSolver internal solver;
    BlazePhoenixQuoter internal quoter;
    BlazePhoenixRouter internal router;
    address internal user = address(0xD1FF);

    uint8 internal constant K_V2 = 0;
    uint8 internal constant K_V3 = 1;
    uint8 internal constant K_SOLIDLY = 2;

    /// What one call to the Router did, as the user saw it.
    struct Shot {
        bool ok;
        uint256 delivered; // balance delta of the output token at the user
        uint256 returned;  // the call's own return value
        uint256 gasUsed;
        bytes4 sel;        // selector of the refusal, if refused
        uint256 code;      // its first word
    }

    function _stack() internal {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        quoter = new BlazePhoenixQuoter(address(hub), address(solver));
        router = new BlazePhoenixRouter(address(hub), address(solver), address(this), address(0xFEE1), address(0xFEE2));
        hub.setRoles(address(router), address(solver), address(quoter));
    }

    function _token(string memory s) internal returns (MockERC20) {
        return new MockERC20(s, s);
    }

    /// One venue on (x, y) holding rx of x and ry of y, registered in the Hub. A V3 venue is a
    /// single-tick pool at a price of one: rx is its liquidity and ry is ignored.
    function _venue(uint8 kind, MockERC20 x, MockERC20 y, uint256 rx, uint256 ry) internal returns (address p) {
        (address t0, address t1) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        (uint256 r0, uint256 r1) = address(x) == t0 ? (rx, ry) : (ry, rx);
        if (kind == K_V2) {
            MockV2Pair v = new MockV2Pair(t0, t1);
            v.setReserves(uint112(r0), uint112(r1));
            p = address(v);
            x.mint(p, rx); y.mint(p, ry);
            hub.seedPool(p, BPC.KIND_V2, 30, address(0), t0, t1);
        } else if (kind == K_V3) {
            MockV3Pool v = new MockV3Pool(t0, t1, 3000);
            v.setState(uint160(BPC.Q96), uint128(rx));
            p = address(v);
            x.mint(p, rx); y.mint(p, rx);
            hub.seedPool(p, BPC.KIND_V3, 3000, address(0), t0, t1);
        } else {
            MockSolidlyPair v = new MockSolidlyPair(t0, t1, false);
            v.setReserves(uint112(r0), uint112(r1));
            p = address(v);
            x.mint(p, rx); y.mint(p, ry);
            hub.seedPool(p, BPC.KIND_SOLIDLY, 0, address(0), t0, t1);
        }
    }

    /// The venue lattice: bit i of `mask` puts venue i on a fresh pair (x, y).
    ///   1  V2       1,000,000 : 1,000,000   price 1
    ///   2  V3       liquidity 1,000,000     price 1
    ///   4  Solidly    300,000 :   300,750   y is 0.25% cheaper than x
    ///   8  V2          50,000 :    49,875   y is 0.25% dearer than x
    /// Every venue charges 0.3%, and every two spots differ by less than the round trip between
    /// them, (1 - 0.003)^-2 - 1 = 0.60%: no venue is an open arbitrage against another, so each
    /// is an honest venue at rest, which the Solver's band never drops (src/BlazePhoenixMath.sol,
    /// THE BAND). No relation over this lattice is a relation about the filter; the pin is
    /// test_Lattice_EveryTwoVenuesLeaveNoRoundTripOpen. Until 11-14 venue 4 sat 1% and venue 8
    /// 2% off price 1: open round trips, which the band drops by design (WHAT THIS COSTS, 1).
    function _lattice(uint256 mask) internal returns (MockERC20 x, MockERC20 y) {
        x = _token("X");
        y = _token("Y");
        for (uint256 bit = 1; bit < 16; bit <<= 1) {
            if (mask & bit == 0) continue;
            (uint8 kind, uint256 rx, uint256 ry) = _latticeVenue(bit);
            _venue(kind, x, y, rx, ry);
        }
    }

    /// Venue `bit` of the lattice: its kind and what it holds of x and of y (a V3 venue's ry is
    /// its liquidity again: a single tick at price 1).
    function _latticeVenue(uint256 bit) internal pure returns (uint8 kind, uint256 rx, uint256 ry) {
        if (bit == 1) return (K_V2, 1_000_000e18, 1_000_000e18);
        if (bit == 2) return (K_V3, 1_000_000e18, 1_000_000e18);
        if (bit == 4) return (K_SOLIDLY, 300_000e18, 300_750e18);
        return (K_V2, 50_000e18, 49_875e18);
    }

    /// The order sizes of the grids: from dust to a fifth of the deepest venue.
    function _grid() internal pure returns (uint256[5] memory) {
        return [uint256(1e12), 1e18, 1_000e18, 30_000e18, 200_000e18];
    }

    /// One pair reachable two ways: bit 1 a direct Solidly venue (300,000 : 300,000), bit 2 a
    /// path over the bridge token M (V2 x-M 1,000,000 : 1,000,000, then V3 M-y, liquidity 1,000,000).
    function _hopWorld(uint256 mask) internal returns (MockERC20 x, MockERC20 y) {
        x = _token("X");
        MockERC20 m = _token("M");
        y = _token("Y");
        hub.addBridge(address(m));
        if (mask & 1 != 0) _venue(K_SOLIDLY, x, y, 300_000e18, 300_000e18);
        if (mask & 2 != 0) {
            _venue(K_V2, x, m, 1_000_000e18, 1_000_000e18);
            _venue(K_V3, m, y, 1_000_000e18, 0);
        }
    }

    /// A pair of tokens with its venues: one world of a grid.
    struct Pair {
        MockERC20 x;
        MockERC20 y;
    }

    function _latticePair(uint256 mask) internal returns (Pair memory w) {
        (w.x, w.y) = _lattice(mask);
    }

    function _hopPair(uint256 mask) internal returns (Pair memory w) {
        (w.x, w.y) = _hopWorld(mask);
    }

    /// The solve door on a snapshot, selling x (dir 0) or y (dir 1), the caller's floor at one unit.
    function _sell(Pair memory w, uint256 dir, uint256 amt) internal returns (Shot memory) {
        return dir == 0 ? _solveOnSnapshot(w.x, w.y, amt, 1) : _solveOnSnapshot(w.y, w.x, amt, 1);
    }

    /// The solve door on a snapshot: the world is left as it was found.
    function _solveOnSnapshot(MockERC20 tIn, MockERC20 tOut, uint256 amt, uint256 minOut) internal returns (Shot memory s) {
        uint256 snap = vm.snapshotState();
        s = _best(tIn, tOut, amt, minOut);
        vm.revertToState(snap);
    }

    /// The plan door on a snapshot: the Quoter's preview and bytes (a `minOut` of 0 asks the door
    /// without a caller floor), and what the bytes did when sent as they came.
    function _planOnSnapshot(MockERC20 tIn, MockERC20 tOut, uint256 amt, uint256 minOut)
        internal returns (BlazePhoenixQuoter.Preview memory pv, bytes memory cd, Shot memory s)
    {
        uint256 snap = vm.snapshotState();
        if (minOut == 0) {
            (pv, cd) = quoter.previewAndEncode(address(tIn), address(tOut), amt, user, block.timestamp + 20);
        } else {
            (pv, cd) = quoter.previewAndEncodeWithMinOut(address(tIn), address(tOut), amt, minOut, user, block.timestamp + 20);
        }
        if (cd.length != 0) s = _fire(tIn, tOut, amt, cd);
        vm.revertToState(snap);
    }

    /// d[mask][dir][i]: what the solve door delivers for order i of the grid in the lattice world
    /// of `mask` (dir 0 sells x, dir 1 sells y). Every order of the grid must execute.
    function _latticeTable() internal returns (uint256[5][2][16] memory d) {
        uint256[5] memory a = _grid();
        for (uint256 mask = 1; mask < 16; ++mask) {
            (MockERC20 x, MockERC20 y) = _lattice(mask);
            for (uint256 dir; dir < 2; ++dir) {
                for (uint256 i; i < 5; ++i) {
                    Shot memory s = dir == 0 ? _solveOnSnapshot(x, y, a[i], 1) : _solveOnSnapshot(y, x, a[i], 1);
                    assertTrue(s.ok, _at("the solve door refused an order of the grid", mask, dir, a[i]));
                    d[mask][dir][i] = s.delivered;
                }
            }
        }
    }

    function _at(string memory what, uint256 mask, uint256 dir, uint256 amt) internal pure returns (string memory) {
        return string.concat(what, " [venues ", vm.toString(mask), ", direction ", vm.toString(dir), ", order ", vm.toString(amt), "]");
    }

    /// The solve door: the Router finds the route on chain.
    function _best(MockERC20 tIn, MockERC20 tOut, uint256 amt, uint256 minOut) internal returns (Shot memory) {
        return _fire(tIn, tOut, amt, abi.encodeCall(
            router.swapBestExactIn, (address(tIn), address(tOut), amt, minOut, user, block.timestamp + 20)));
    }

    /// Fund the user with exactly `amt`, approve exactly `amt`, send `cd` to the Router as the user.
    function _fire(MockERC20 tIn, MockERC20 tOut, uint256 amt, bytes memory cd) internal returns (Shot memory s) {
        tIn.mint(user, amt);
        vm.prank(user);
        tIn.approve(address(router), amt);
        uint256 b0 = tOut.balanceOf(user);
        vm.prank(user);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(router).call(cd);
        s.gasUsed = g - gasleft();
        s.ok = ok;
        s.delivered = tOut.balanceOf(user) - b0;
        if (ok) {
            s.returned = abi.decode(ret, (uint256));
        } else if (ret.length >= 4) {
            s.sel = bytes4(ret);
            if (ret.length >= 36) {
                uint256 c;
                assembly ("memory-safe") { c := mload(add(ret, 36)) }
                s.code = c;
            }
        }
    }
}
