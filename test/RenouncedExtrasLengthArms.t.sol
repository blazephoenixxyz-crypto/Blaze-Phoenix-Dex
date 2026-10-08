// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The two length arms of `Hub._sameExtras`, each decisive on its own.
//
//      if (n != fees.length || f.spacings.length != spacings.length) return false;
//
//  `addFactory` requires `fees.length == spacings.length` only in the derive
//  mode (9); for the other modes the extras are stored as given. A renounced
//  row in mode 4 admitted with UNPAIRED extras is therefore reachable, and it
//  is the one state in which the two arms disagree: the calldata is paired
//  (2, 2) while the stored row is not (3, 2) or (2, 3). After renunciation a
//  re-add must match the stored row exactly, so both re-adds below are refused
//  with HubE(1); the identical re-add stays a no-op refresh. The mismatch has
//  to live in the STORED row: unpaired calldata in the derive mode is refused
//  earlier, with HubE(5).
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";

contract ExtrasArmsFactory {
    function getPair(address, address) external pure returns (address) { return address(0); }
}

contract RenouncedExtrasLengthArmsTest is Test {
    BlazePhoenixHub internal hub;

    uint8 internal constant MODE_CREATE2_V2 = 4;
    uint16 internal constant HUB_REFUSED = 1;

    bytes32 internal constant INIT_A =
        0x96e8ac4279504d8dd2f6b71f7a2f2d1bdcbeb63f3a9b4acdbbe8b4cbdef5f5f5;

    function _fees(uint256 n) private pure returns (uint24[] memory f) {
        f = new uint24[](n);
        uint24[3] memory v = [uint24(3000), 500, 100];
        for (uint256 i; i < n; ++i) f[i] = v[i];
    }

    function _spacings(uint256 n) private pure returns (int24[] memory s) {
        s = new int24[](n);
        int24[3] memory v = [int24(60), 10, 1];
        for (uint256 i; i < n; ++i) s[i] = v[i];
    }

    /// @dev A renounced mode-4 row whose stored extras are (nf fees, ns spacings).
    function _renouncedRow(uint256 nf, uint256 ns) private returns (address fac) {
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(0));
        fac = address(new ExtrasArmsFactory());
        hub.addFactory(fac, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A, _fees(nf), _spacings(ns));
        hub.renounceControl();
    }

    /// @notice Stored (3 fees, 2 spacings), re-add (2, 2): only the fee-length
    ///         arm sees the difference.
    function test_RenouncedRow_StoredFeesLonger_PairedReAddIsRefused() public {
        address fac = _renouncedRow(3, 2);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(fac, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A, _fees(2), _spacings(2));
    }

    /// @notice Stored (2 fees, 3 spacings), re-add (2, 2): only the
    ///         spacing-length arm sees the difference.
    function test_RenouncedRow_StoredSpacingsLonger_PairedReAddIsRefused() public {
        address fac = _renouncedRow(2, 3);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixHub.HubE.selector, HUB_REFUSED));
        hub.addFactory(fac, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A, _fees(2), _spacings(2));
    }

    /// @notice Control: the identical re-add is still a no-op refresh.
    function test_Control_RenouncedRow_IdenticalReAddStillRefreshes() public {
        address fac = _renouncedRow(2, 2);
        hub.addFactory(fac, BPC.KIND_V2, MODE_CREATE2_V2, INIT_A, _fees(2), _spacings(2));
        assertEq(hub.factoryCount(), 1, "an identical re-add remains a no-op refresh");
    }
}
