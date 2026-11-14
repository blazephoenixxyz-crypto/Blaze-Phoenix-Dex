// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../../src/BlazePhoenixCore.sol";
import {BlazePhoenixMath, IHubMath} from "../../src/BlazePhoenixMath.sol";
import {RouteQualityMathTap} from "./RouteQualityMathTap.sol";

/// @notice DIAGNOSIS, NOT A GUARD. Records one solve, then replays every hop's
///         `BlazePhoenixMath.select` from the exact calldata the Solver sent it (the
///         figures that reached the band through the ABI), into the real library and
///         into `RouteQualityMathTap` (the same arithmetic with a log per band pass:
///         prices, votes w, base and kept bits). Every probe the Solver asked of
///         `BPC.universalProbe` is replayed too, so the row the band never named is
///         seen. It asserts nothing: every reading is a log line starting with "RQ".
abstract contract RouteQualityRecorder {
    Vm private constant RQ_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    bytes4 internal constant RQ_SELECT = 0x05517f17;   // BlazePhoenixMath.select, same trace

    /// The calldata of `select`, one tuple (decoded behind a 0x20 head).
    struct RqSelect {
        uint256[] rates;
        uint256[] depths;
        uint256[] balsOut;
        uint256[] fe;
        PoolInfo[] cands;
        address tIn;
        address hub;
        uint256 budget;
    }

    function _rqStart() internal {
        RQ_VM.startStateDiffRecording();
    }

    function _rqStopAndReplay(string memory tag) internal {
        VmSafe.AccountAccess[] memory acc = RQ_VM.stopAndReturnStateDiff();
        RouteQualityMathTap tap = new RouteQualityMathTap();
        uint256 nSel;
        uint256 nProbe;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].kind != VmSafe.AccountAccessKind.DelegateCall || acc[i].data.length < 4) continue;
            if (acc[i].account == address(BlazePhoenixMath) || bytes4(acc[i].data) == RQ_SELECT) {
                ++nSel;
                _rqSelect(tag, nSel, acc[i].data, tap);
            } else if (bytes4(acc[i].data) == BPC.universalProbe.selector) {
                ++nProbe;
                _rqProbe(nProbe, acc[i].data);
            }
        }
        console2.log(string.concat("RQ ", tag, " selects / probes recorded:"), nSel, nProbe);
    }

    function _rqProbe(uint256 k, bytes memory data) private {
        (bool ok, bytes memory r) = address(BPC).delegatecall(data);
        if (!ok || r.length < 128) {
            console2.log("RQ probe / replay failed, return bytes:", k, r.length);
            return;
        }
        (uint256 mass, uint256 rank, uint256 fee, uint256 err) = abi.decode(r, (uint256, uint256, uint256, uint256));
        console2.log("RQ probe k / mass / rank:", k, mass, rank);
        console2.log("RQ probe k / fee / err:", k, fee, err);
        if (k == 15) {
            console2.log("RQ probe 15 (the row the trace headers missed): calldata follows");
            console2.logBytes(data);
        }
    }

    function _rqSelect(string memory tag, uint256 k, bytes memory data, RouteQualityMathTap tap) private {
        bytes memory body = new bytes(data.length - 4);
        for (uint256 j; j < body.length; ++j) body[j] = data[j + 4];
        RqSelect memory s = abi.decode(bytes.concat(bytes32(uint256(0x20)), body), (RqSelect));
        console2.log(string.concat("RQ ", tag, " select k / rows / budget:"), k, s.cands.length, s.budget);
        console2.log("RQ select tIn:", s.tIn);
        for (uint256 i; i < s.cands.length; ++i) {
            PoolInfo memory c = s.cands[i];
            console2.log("RQ   row / kind / fee:", i, c.kind, c.fee);
            console2.log("RQ   row / active / tickSpacing + 2^30:", i, c.active ? 1 : 0, uint256(int256(c.tickSpacing) + (1 << 30)));
            console2.log("RQ   row venue:", i, _rqVenue(c));
            console2.log("RQ   row / rate / depth:", i, s.rates[i], s.depths[i]);
            console2.log("RQ   row / balOut / fe:", i, s.balsOut[i], s.fe[i]);
            console2.log("RQ   row / fe fee pips / fe err:", i, s.fe[i] & 0xFFFFFF, s.fe[i] >> 24);
        }
        (uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis) =
            BlazePhoenixMath.select(s.rates, s.depths, s.balsOut, s.fe, s.cands, s.tIn, IHubMath(s.hub), s.budget);
        _rqOut("RQ real", nBand, n, sumPsi, map, psis);
        bytes32 h = keccak256(abi.encode(nBand, n, sumPsi, map, psis));
        (nBand, n, sumPsi, map, psis) =
            tap.select(s.rates, s.depths, s.balsOut, s.fe, s.cands, s.tIn, IHubMath(s.hub), s.budget);
        _rqOut("RQ tap ", nBand, n, sumPsi, map, psis);
        console2.log(h == keccak256(abi.encode(nBand, n, sumPsi, map, psis))
            ? "RQ tap and real select answer the SAME"
            : "RQ tap and real select DIFFER: read the tap logs with care");
    }

    function _rqOut(string memory who, uint256 nBand, uint256 n, uint256 sumPsi, uint256[] memory map, uint256[] memory psis)
        private pure
    {
        console2.log(string.concat(who, " nBand / n / sumPsi:"), nBand, n, sumPsi);
        for (uint256 i; i < map.length; ++i) {
            console2.log(string.concat(who, "   slot / map / psi:"), i, map[i], i < psis.length ? psis[i] : 0);
        }
    }

    /// The candidate's address field (word 7 of the struct in memory).
    function _rqVenue(PoolInfo memory c) private pure returns (address a) {
        assembly ("memory-safe") { a := mload(add(c, 0xe0)) }
    }
}
