// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// The one classifier of a refusal, shared by every generated or matrix harness: a revert is
// OURS when it carries RouterE / SolverE / HubE / QuoterE or a "BPC:" string, and a third way
// otherwise (a panic, an empty revert, a foreign selector). Two copies of this rule would be
// the defect the shared-quantity register exists to forbid, in the test tree.

import {Vm} from "forge-std/Vm.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixSolver} from "../../src/BlazePhoenixSolver.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixQuoter} from "../../src/BlazePhoenixQuoter.sol";

library Outcomes {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @return ours  the revert carries one of this system's selectors (or a "BPC:" string)
    /// @return what  a printable name: `RouterE(5)`, `BPC: ...`, `Panic(17)`, `0xdeadbeef`, `empty revert`
    function classify(bytes memory err) internal pure returns (bool ours, string memory what) {
        if (err.length < 4) return (false, err.length == 0 ? "empty revert" : "short revert");
        bytes4 sel;
        assembly { sel := mload(add(err, 32)) }
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
        if (sel == BlazePhoenixRouter.RouterE.selector) return (true, string.concat("RouterE(", vm.toString(uint256(abi.decode(body, (uint16)))), ")"));
        if (sel == BlazePhoenixSolver.SolverE.selector) return (true, string.concat("SolverE(", vm.toString(uint256(abi.decode(body, (uint16)))), ")"));
        if (sel == BlazePhoenixHub.HubE.selector)       return (true, string.concat("HubE(", vm.toString(uint256(abi.decode(body, (uint16)))), ")"));
        if (sel == BlazePhoenixQuoter.QuoterE.selector) return (true, string.concat("QuoterE(", vm.toString(uint256(abi.decode(body, (uint16)))), ")"));
        if (sel == bytes4(keccak256("Error(string)"))) {
            if (body.length < 64) return (false, "malformed Error(string)");
            string memory m = abi.decode(body, (string));
            bytes memory mb = bytes(m);
            bool bpc = mb.length >= 4 && mb[0] == "B" && mb[1] == "P" && mb[2] == "C" && mb[3] == ":";
            return (bpc, m);
        }
        if (sel == bytes4(keccak256("Panic(uint256)"))) return (false, string.concat("Panic(", vm.toString(abi.decode(body, (uint256))), ")"));
        return (false, vm.toString(sel));
    }
}
