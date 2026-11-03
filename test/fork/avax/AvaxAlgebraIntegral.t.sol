// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg, PoolInfo} from "../../../src/BlazePhoenixCore.sol";
import {BlazePhoenixGate, BlazePhoenixGateWrapper} from "../../../src/BlazePhoenixGate.sol";
import {ExtAdapterBase} from "../../../src/adapters/ExtAdapterBase.sol";
import {BlazePhoenixAdapterAlgebraIntegral} from "../../../src/adapters/BlazePhoenixAdapterAlgebraIntegral.sol";
import {AvaxForkBase} from "./AvaxForkBase.sol";

interface IErc20AI {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/// @dev The Algebra Integral v1.2 getters and actions this file uses (IAlgebraPoolState,
///      IAlgebraPoolActions and IAlgebraPoolPermissionedActions of the Blackhole CLMM sources).
interface IAIVenue {
    function token0() external view returns (address);
    function plugin() external view returns (address);
    function globalState() external view returns (uint160, int24, uint16, uint8, uint16, bool);
    function swap(address recipient, bool zeroToOne, int256 amountRequired, uint160 limitSqrtPrice, bytes calldata data)
        external returns (int256, int256);
    function setPlugin(address newPluginAddress) external;
    function setPluginConfig(uint8 newConfig) external;
}

interface IAIFactory {
    function owner() external view returns (address);
    function poolDeployer() external view returns (address);
    function customPoolByPair(address, address, address) external view returns (address);
}

/// @dev The farming proxy plugin: its afterSwap moves the virtual venue of `incentive`.
interface IFarmingPluginAI {
    function incentive() external view returns (address);
}

/// @notice The oracle: a raw exact-input swap straight on the Integral venue, paid BY NAME in
///         algebraSwapCallback (the selector the venue calls). It returns what the venue took
///         and what it paid, from the venue's own return values (a community-vault transfer
///         inside the swap moves the venue's balances, never these). It shares no code with
///         the adapter, the Gate, the Router or the Quoter.
contract RawAIOracle {
    address private live;

    function swapIn(address amm, address tokenIn, bool zeroToOne, uint256 amtIn)
        external returns (uint256 took, uint256 out)
    {
        live = amm;
        (int256 a0, int256 a1) = IAIVenue(amm).swap(
            address(this), zeroToOne, int256(amtIn),
            zeroToOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341),
            abi.encode(tokenIn)
        );
        live = address(0);
        (int256 i, int256 o) = zeroToOne ? (a0, a1) : (a1, a0);
        require(i > 0 && o < 0, "oracle: no trade");
        (took, out) = (uint256(i), uint256(-o));
    }

    function algebraSwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        require(msg.sender == live && live != address(0), "oracle: not the venue");
        uint256 owed = a0 > 0 ? uint256(a0) : uint256(a1);
        require(IErc20AI(abi.decode(data, (address))).transfer(msg.sender, owed), "oracle: pay");
    }
}

/// @notice A plugin stand-in: it answers every call with that call's own selector, which is
///         all the venue checks of a hook's answer. Used as other code at the pinned plugin's
///         address, and as a new plugin the venue never calls (config 0).
contract PluginStubAI {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0x00, shl(224, shr(224, calldataload(0))))
            return(0x00, 0x20)
        }
    }
}

/// @notice avax-1103 (ai-fork): BlazePhoenixAdapterAlgebraIntegral against the live Blackhole
///         CLMM factory on Avalanche (Algebra Integral v1.2), block 99270000, through the Gate,
///         the Gate's Hub row (KIND_EXTERNAL), the Quoter and the Router. The venue is the top
///         custom WAVAX/USDC (customPoolByPair of its deployer): discovery cannot derive it, the
///         Gate row lists it. No src change: every test pins current behaviour and has its own
///         mutant (ai-fork-mutantes.tsv).
///         Oracle: RawAIOracle above, on the same pre-state (snapshot), fed what the venue was
///         paid in the Router's run (the order less the treasuries' input share). With
///         communityFee 1000 the venue sends its pending fees to the community vault on the
///         first swap past the transfer period, so the venue's balance deltas are not the trade:
///         the venue's side is read off the recipient and the treasuries, and the raw swap's own
///         return values.
contract AvaxAIFork is AvaxForkBase {
    address internal constant BH_FACTORY  = 0x512eb749541B7cf294be882D636218c84a5e9E5F;
    address internal constant BH_DEPLOYER = 0x9B2441037E286d5Bf9456a3BE7b5273fe28DbA1e;
    bytes32 internal constant BH_INIT =
        0xeaa3eea3233916c82fe1281a51bd9cde844b7c4673c0714ca0028a57f5634752;
    // The top custom WAVAX/USDC and its custom deployer; its plugin at FORK_BLOCK (config 2,
    // AFTER_SWAP only): the farming proxy plugin.
    address internal constant BH_WU_CUSTOM = 0x41100C6D2c6920B10d12Cd8D59c8A9AA2eF56fC7;
    address internal constant BH_WU_CUSTOM_DEPLOYER = 0x5D433A94A4a2aA8f9AA34D8D15692Dc2E9960584;
    address internal constant PLUGIN = 0xdB2093a4DF635dcE499A0db0BBA9ABe39dB6594A;
    // Another custom WAVAX/USDC of the same factory, with BEFORE_SWAP on (config 87).
    address internal constant BH_WU_BS = 0x7789fA308147Eae364e3BCfa35351F2b9E0bd012;
    address internal constant BH_WU_BS_DEPLOYER = 0x43c4b7BD4C173992C6711c631859A2EAC84BF8Db;
    uint8 internal constant KIND_ALGEBRA = 6;

    // Plugins.sol
    uint8 internal constant BEFORE_SWAP = 1;
    uint8 internal constant AFTER_SWAP = 2;
    uint8 internal constant DYNAMIC_FEE = 128;

    uint8 internal constant FAMILY = 1;
    uint24 internal constant KEY = (uint24(1) << 16) | 1; // family 1, slot 1

    address internal constant USER = address(0xA11ce0000000000000000000000000000000a11c);

    BlazePhoenixAdapterAlgebraIntegral internal adapter;
    address internal wrapper;
    address internal incentive; // the plugin's virtual venue at FORK_BLOCK

    struct Run {
        uint256 amt;
        uint256 quote;    // Quoter.previewRouteExact
        uint256 exec;     // what the recipient received from Router.swapExactIn
        uint256 venueIn;  // tokenIn the venue was paid: order - treasuries' tokenIn share
        uint256 venueOut; // tokenOut the venue paid: recipient + treasuries' tokenOut share
        uint256 rawIn;    // the venue's tokenIn balance rise (a vault transfer may cut it)
        uint256 rawOut;   // the venue's tokenOut balance fall (a vault transfer may add to it)
        uint256 feeIn;    // the treasuries' tokenIn delta
        uint256 feeOut;   // the treasuries' tokenOut delta
        uint256 kept;     // Router, wrapper and adapter holdings after the run, both tokens
        uint256 oracleIn; // what the raw swap took, same pre-state
        uint256 oracle;   // what the raw swap paid, same pre-state
        uint256 gas;      // gasleft() around the Router call, main accounts cooled first
    }

    /// The instance exists from setUp; the Gate learns of it only in `_mount`, inside each
    /// test, so a refusal there fails the named test.
    function _afterDeploy() internal override {
        adapter = new BlazePhoenixAdapterAlgebraIntegral(address(gate), BH_FACTORY, BH_DEPLOYER, BH_INIT);
        incentive = IFarmingPluginAI(PLUGIN).incentive();
    }

    /// propose -> ADAPTER_DELAY -> accept.
    function _mountFamily() internal {
        gate.proposeAdapter(FAMILY, address(adapter));
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAMILY);
    }

    /// The family, one wrapper (hint = the custom deployer), then the Gate's Hub row.
    function _mount() internal {
        _mountFamily();
        wrapper = gate.create(WAVAX, USDC, KEY, abi.encode(BH_WU_CUSTOM_DEPLOYER));
        uint24[] memory keys = new uint24[](1);
        keys[0] = KEY;
        hub.addFactory(address(gate), BPC.KIND_EXTERNAL, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH(), keys, new int24[](0));
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return IErc20AI(t).balanceOf(who);
    }

    /// a - b, or 0 when b is above a.
    function _up(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _cfgOf(address v) internal view returns (uint8 c) {
        (, , , c, , ) = IAIVenue(v).globalState();
    }

    function _cfg() internal view returns (uint8) {
        return _cfgOf(BH_WU_CUSTOM);
    }

    function _c2(address origin, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), origin, salt, BH_INIT)))));
    }

    function _feeUp(uint256 x) internal pure returns (uint256) {
        return (x * BPC.PROTOCOL_FEE_BPS + 9_999) / 10_000;
    }

    function _held(address tA, address tB) internal view returns (uint256) {
        address a = address(adapter);
        return _bal(tA, address(router)) + _bal(tB, address(router)) + _bal(tA, wrapper) + _bal(tB, wrapper)
            + _bal(tA, a) + _bal(tB, a);
    }

    function _route(address tIn, address tOut, uint256 amt) internal view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg(wrapper, address(0), BPC.KIND_EXTERNAL, KEY, 0, tIn == WAVAX, false, amt, 0, bytes32(0));
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop(tIn, tOut, amt, 0, legs);
        r.hops = hops;
    }

    function _fund(address tIn, uint256 amt) internal {
        deal(tIn, USER, amt);
        vm.prank(USER);
        IErc20AI(tIn).approve(address(router), amt);
    }

    function _cool() internal {
        vm.cool(address(router));
        vm.cool(address(hub));
        vm.cool(address(gate));
        vm.cool(wrapper);
        vm.cool(address(adapter));
        vm.cool(BH_WU_CUSTOM);
        vm.cool(WAVAX);
        vm.cool(USDC);
        vm.cool(PLUGIN);
        vm.cool(incentive);
    }

    function _fees(address t) internal view returns (uint256) {
        return _bal(t, TEST_TREASURY_1) + _bal(t, TEST_TREASURY_2);
    }

    function _oracle(address tIn, uint256 amt) internal returns (uint256 took, uint256 out) {
        RawAIOracle o = new RawAIOracle();
        deal(tIn, address(o), amt);
        (took, out) = o.swapIn(BH_WU_CUSTOM, tIn, tIn == WAVAX, amt);
    }

    // ─── 1. mount, create, discovery ─────────────────────────────────────

    /// @notice The instance is bound to the live factory, its own deployer and init code hash,
    ///         and this Gate: propose -> ADAPTER_DELAY -> accept. The Gate's scan passes over the
    ///         real runtime code, an early accept is refused (GateE(7)), and the accept pins the
    ///         codehash.
    function test_AvaxAI_Mount_PinnedAndClean() public {
        address a = address(adapter);
        assertEq(address(adapter.FACTORY()), BH_FACTORY, "the Blackhole CLMM factory");
        assertEq(adapter.POOL_DEPLOYER(), IAIFactory(BH_FACTORY).poolDeployer(), "the factory's own deployer");
        assertEq(adapter.POOL_DEPLOYER(), BH_DEPLOYER, "the deployer at FORK_BLOCK");
        assertEq(adapter.POOL_INIT_CODE_HASH(), BH_INIT, "the venue init code hash");
        assertEq(address(adapter.GATE()), address(gate), "bound to this Gate");
        assertTrue(gate.codeIsClean(a), "the Gate's scan passes the real code");
        gate.proposeAdapter(FAMILY, a);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixGate.GateE.selector, uint8(7)));
        gate.acceptAdapter(FAMILY);
        vm.warp(block.timestamp + gate.ADAPTER_DELAY());
        gate.acceptAdapter(FAMILY);
        assertEq(gate.adapterOf(FAMILY), a, "its own family");
        assertEq(gate.pinOf(FAMILY), keccak256(a.code), "the accept pins the codehash");
        assertEq(gate.liveAdapter(FAMILY), a, "live");
        console2.log("adapter", a, a.code.length);
    }

    /// @notice create with hint = abi.encode(custom deployer): the wrapper's venue is the
    ///         factory's record of (deployer, WAVAX, USDC), at the custom CREATE2 address, and
    ///         what resolve pinned is the venue's plugin of FORK_BLOCK and its code hash. The
    ///         plugin passes the Gate's scan, and its afterSwap calls out (incentive set).
    function test_AvaxAI_Create_PinsTheRealVenueAndItsPlugin() public {
        _mount();
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(wrapper);
        assertEq(wrapper, gate.wrapperAddress(USDC, WAVAX, KEY), "the Gate's derive");
        assertEq(w.venuePool(), BH_WU_CUSTOM, "the custom venue");
        assertEq(
            IAIFactory(BH_FACTORY).customPoolByPair(BH_WU_CUSTOM_DEPLOYER, WAVAX, USDC), BH_WU_CUSTOM,
            "the factory's record of (deployer, WAVAX, USDC)"
        );
        assertEq(
            _c2(BH_DEPLOYER, keccak256(abi.encode(BH_WU_CUSTOM_DEPLOYER, WAVAX, USDC))), BH_WU_CUSTOM,
            "at the custom CREATE2 address"
        );
        assertEq(w.token0(), WAVAX, "sorted: WAVAX below USDC");
        assertEq(IAIVenue(BH_WU_CUSTOM).token0(), WAVAX, "the venue's token0");
        assertEq(uint256(_cfg()), uint256(AFTER_SWAP), "plugin config at FORK_BLOCK: AFTER_SWAP only");
        address p = IAIVenue(BH_WU_CUSTOM).plugin();
        assertEq(p, PLUGIN, "the farming proxy plugin");
        assertEq(w.aux0(), bytes32(uint256(uint160(p))), "aux0 = the plugin seen at create");
        assertEq(w.aux1(), p.codehash, "aux1 = its code hash");
        assertTrue(gate.codeIsClean(p), "the Gate's scan passes the plugin");
        assertTrue(incentive != address(0), "its afterSwap calls the incentive");
        console2.log("wrapper plugin incentive", wrapper, p, incentive);
        console2.log("plugin code size", p.code.length);
    }

    /// @notice The Gate's create refuses, with AdapterE(7), a custom venue whose plugin config
    ///         holds a refused flag: another custom WAVAX/USDC of the same factory with
    ///         BEFORE_SWAP on at FORK_BLOCK, and the top custom venue once its own plugin, which
    ///         passes the Gate's scan, turns BEFORE_SWAP or DYNAMIC_FEE on (so the flag alone
    ///         refuses). A deployer with no record is refused with AdapterE(2). No wrapper is made.
    function test_AvaxAI_Create_RefusesFlaggedVenuesAndUnknownDeployer() public {
        _mountFamily();
        assertEq(
            IAIFactory(BH_FACTORY).customPoolByPair(BH_WU_BS_DEPLOYER, WAVAX, USDC), BH_WU_BS,
            "the factory's record of the other deployer"
        );
        assertEq(uint256(_cfgOf(BH_WU_BS)), 87, "BEFORE_SWAP on at FORK_BLOCK");
        address bsPlugin = IAIVenue(BH_WU_BS).plugin();
        console2.log("other plugin, scan", bsPlugin, gate.codeIsClean(bsPlugin) ? 1 : 0);
        vm.expectRevert(abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, uint8(7)));
        gate.create(WAVAX, USDC, KEY, abi.encode(BH_WU_BS_DEPLOYER));
        vm.expectRevert(abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, uint8(2)));
        gate.create(WAVAX, USDC, KEY, abi.encode(BH_DEPLOYER));
        assertTrue(gate.codeIsClean(PLUGIN), "the top venue's plugin passes the scan");
        uint8[2] memory flags = [AFTER_SWAP | BEFORE_SWAP, AFTER_SWAP | DYNAMIC_FEE];
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(PLUGIN);
            IAIVenue(BH_WU_CUSTOM).setPluginConfig(flags[i]);
            assertEq(uint256(_cfg()), uint256(flags[i]), "the flag is on");
            vm.expectRevert(abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, uint8(7)));
            gate.create(WAVAX, USDC, KEY, abi.encode(BH_WU_CUSTOM_DEPLOYER));
            vm.revertToState(snap);
        }
        assertEq(gate.wrappersOf(USDC, WAVAX)[0], 0, "no wrapper made");
    }

    /// @notice Discovery: the Algebra row (mode 5, fee 0) lists nothing for WAVAX/USDC (the
    ///         custom salt carries the deployer); the Gate's Hub row lists the wrapper over the
    ///         custom venue. The record is read whole by its ABI layout and checked field by
    ///         field; the Core's derive and the Gate's own list agree with it.
    function test_AvaxAI_Hub_GateRowListsTheCustomVenueTheAlgebraRowCannot() public {
        _addRow(BH_FACTORY, KIND_ALGEBRA, MODE_CREATE2_V3, BH_INIT, new uint24[](1), new int24[](0));
        assertEq(hub.discoverFor(USDC, WAVAX).length, 0, "the Algebra row lists nothing for WAVAX/USDC");
        _mount();
        PoolInfo[] memory hits = hub.discoverFor(USDC, WAVAX);
        assertEq(hits.length, 1, "one record, the Gate's");
        (bool active, , uint8 kind, uint24 key, , address a0, address a1, address listed, address hk) = abi.decode(
            abi.encode(hits[0]), (bool, bool, uint8, uint24, int24, address, address, address, address)
        );
        assertTrue(active, "active");
        assertEq(kind, BPC.KIND_EXTERNAL, "kind 9");
        assertEq(key, KEY, "the venue key");
        assertEq(a0, WAVAX, "token0");
        assertEq(a1, USDC, "token1");
        assertEq(listed, wrapper, "the record lists the wrapper");
        assertEq(hk, address(0), "no hooks field");
        assertEq(BlazePhoenixGateWrapper(listed).venuePool(), BH_WU_CUSTOM, "over the custom venue");
        assertEq(
            BPC.deriveAddress(address(gate), USDC, WAVAX, KEY, false, 0, MODE_CREATE2_V3, gate.WRAPPER_INIT_HASH()),
            listed, "Core derive"
        );
        assertEq(gate.wrappersOf(USDC, WAVAX)[0], (uint256(KEY) << 160) | uint160(listed), "the Gate's list");
        console2.log("hit", listed, uint256(key));
    }

    // ─── 2. quote == exec == oracle, three sizes each way ────────────────

    /// @dev One order through the Router: Quoter preview, Router execution with the treasuries'
    ///      and the recipient's deltas, then (state reverted) the raw oracle on what the venue
    ///      was paid.
    function _fill(address tIn, address tOut, uint256 amt) internal returns (Run memory r) {
        r.amt = amt;
        Route memory route = _preview(tIn, tOut, r);
        assertGt(r.quote, 0, "the Quoter prices the leg");
        _fund(tIn, amt);
        uint256 snap = vm.snapshotState();
        _exec(route, tIn, tOut, r.quote, r);
        vm.revertToState(snap);
        (r.oracleIn, r.oracle) = _oracle(tIn, r.venueIn);
        _check(r);
    }

    function _preview(address tIn, address tOut, Run memory r) internal returns (Route memory route) {
        (route, r.quote) = quoter.previewRouteExact(_route(tIn, tOut, r.amt), r.amt);
    }

    /// @dev The Router's run with the floor `floor`, main accounts cooled first; every delta
    ///      lands in `r`.
    function _exec(Route memory route, address tIn, address tOut, uint256 floor, Run memory r) internal {
        uint256[5] memory b;
        b[0] = _bal(tIn, BH_WU_CUSTOM);
        b[1] = _bal(tOut, BH_WU_CUSTOM);
        b[2] = _fees(tIn);
        b[3] = _fees(tOut);
        b[4] = _bal(tOut, USER);
        _cool();
        vm.prank(USER);
        uint256 g = gasleft();
        uint256 got = router.swapExactIn(route, r.amt, floor, USER, block.timestamp + 600);
        r.gas = g - gasleft();
        r.rawIn = _up(_bal(tIn, BH_WU_CUSTOM), b[0]);
        r.rawOut = _up(b[1], _bal(tOut, BH_WU_CUSTOM));
        r.feeIn = _fees(tIn) - b[2];
        r.feeOut = _fees(tOut) - b[3];
        r.exec = _bal(tOut, USER) - b[4];
        r.venueIn = r.amt - r.feeIn;
        r.venueOut = r.exec + r.feeOut;
        r.kept = _held(tIn, tOut);
        assertEq(got, r.exec, "the Router returns what the recipient received");
        assertEq(_bal(tIn, USER), 0, "the user spent the whole order");
    }

    function _check(Run memory r) internal pure {
        assertEq(r.quote, r.exec, "Quoter == Router, to the wei");
        _settled(r);
    }

    /// @dev What every executed order owes, priced or not: the venue's balances moved both ways,
    ///      the protocol fee is on the output only, the raw swap of what the venue was paid takes
    ///      all of it and pays what the venue paid in the Router's run, and nothing stayed behind.
    function _settled(Run memory r) internal pure {
        assertGt(r.rawIn, 0, "the route used this venue (input side)");
        assertGt(r.rawOut, 0, "the route used this venue (output side)");
        assertEq(r.feeIn, 0, "no input share");
        assertEq(r.feeOut, _feeUp(r.venueOut), "the protocol fee on the output");
        assertEq(r.oracleIn, r.venueIn, "the raw swap takes the whole order");
        assertEq(r.oracle, r.venueOut, "raw oracle == what the venue paid in the Router's run");
        assertEq(r.kept, 0, "Router, wrapper and adapter keep nothing");
    }

    /// @dev The Router's run of a route (floor 1 wei) reverts with `err`.
    function _routerRefuses(Route memory route, uint256 amt, bytes memory err) internal {
        vm.prank(USER);
        (bool ok, bytes memory ret) =
            address(router).call(abi.encodeCall(router.swapExactIn, (route, amt, 1, USER, block.timestamp + 600)));
        assertFalse(ok, "the Router refuses");
        console2.logBytes(ret);
        assertEq(ret, err, "the refusal's error");
    }

    /// @dev An order the venue fills whole but the Quoter prices 0: the walk needs more gas than
    ///      GATE_QUOTE_GAS leaves the adapter. Pinned whole: the Quoter prices 0, the Core's
    ///      producer prices 0 with the wrapper live, the wrapper's own quote with all the gas
    ///      prices it, and the Router's run (floor 1 wei) settles like a priced one, to the
    ///      wrapper's own price and the raw oracle.
    function _unpriced(address tIn, address tOut, uint256 amt) internal returns (Run memory r) {
        r.amt = amt;
        Route memory route = _preview(tIn, tOut, r);
        assertEq(r.quote, 0, "the Quoter prices 0");
        _cappedZero(tIn, tOut, amt);
        vm.cool(BH_WU_CUSTOM);
        uint256 g = gasleft();
        (uint256 full, ) = BlazePhoenixGateWrapper(wrapper).quote(tIn == WAVAX, amt);
        g -= gasleft();
        console2.log("  wrapper quote gas (cold), GATE_QUOTE_GAS", g, BPC.GATE_QUOTE_GAS);
        assertGt(full, 0, "with all the gas, the wrapper prices it");
        _fund(tIn, amt);
        uint256 snap = vm.snapshotState();
        _exec(route, tIn, tOut, 1, r);
        vm.revertToState(snap);
        (r.oracleIn, r.oracle) = _oracle(tIn, r.venueIn);
        assertEq(r.venueOut, full, "the venue paid the wrapper's own price");
        _settled(r);
    }

    /// @dev The producer the Quoter prices a Gate leg with (BPC.gateQuote: the wrapper's view
    ///      quote under GATE_QUOTE_GAS), on the cooled venue: live, and 0.
    function _cappedZero(address tIn, address tOut, uint256 amt) internal {
        vm.cool(BH_WU_CUSTOM);
        (bool live, uint256 out, ) = BPC.gateQuote(address(hub), wrapper, tIn, tOut, KEY, tIn == WAVAX, amt, false);
        assertTrue(live, "the wrapper is live");
        assertEq(out, 0, "under GATE_QUOTE_GAS the producer prices 0");
    }

    function _log(bool usdcIn, Run memory r) internal pure {
        console2.log("run", usdcIn ? 1 : 0, r.amt);
        console2.log("  quote exec oracle", r.quote, r.exec, r.oracle);
        console2.log("  venueIn venueOut gas", r.venueIn, r.venueOut, r.gas);
        console2.log("  rawIn rawOut oracleIn", r.rawIn, r.rawOut, r.oracleIn);
        console2.log("  feeIn feeOut kept", r.feeIn, r.feeOut, r.kept);
    }

    uint8 internal constant FILLS = 0;    // quote == exec == oracle
    uint8 internal constant UNPRICED = 1; // the venue fills it, the Quoter prices 0 (gas)

    /// @dev 1 000, 10 000 and 100 000 USD each way, WAVAX sized at 1 WAVAX ~ 8.35 USDC at
    ///      FORK_BLOCK. Each size starts from the same state. The venue holds about 76 600 USDC
    ///      and 53 300 WAVAX at FORK_BLOCK.
    function _sizes(bool usdcIn, uint8[3] memory modes) internal {
        _mount();
        (address tIn, address tOut) = usdcIn ? (USDC, WAVAX) : (WAVAX, USDC);
        uint256[3] memory amts = usdcIn
            ? [uint256(1_000e6), 10_000e6, 100_000e6]
            : [uint256(120e18), 1_200e18, 12_000e18];
        for (uint256 k; k < 3; ++k) {
            uint256 base = vm.snapshotState();
            Run memory r;
            if (modes[k] == FILLS) r = _fill(tIn, tOut, amts[k]);
            else r = _unpriced(tIn, tOut, amts[k]);
            _log(usdcIn, r);
            vm.revertToState(base);
        }
    }

    function test_AvaxAI_UsdcToWavax_QuoteExecOracle() public {
        _sizes(true, [FILLS, FILLS, FILLS]);
    }

    /// @notice At 100 000 USD of WAVAX the venue still fills the order: a full-range band takes
    ///         what its listed ticks leave. The walk crosses every listed tick on the way, more
    ///         than GATE_QUOTE_GAS pays for, so the Quoter prices 0; the Router's run at floor
    ///         1 wei settles to the wrapper's own price and the raw oracle.
    function test_AvaxAI_WavaxToUsdc_QuoteExecOracle() public {
        _sizes(false, [FILLS, FILLS, UNPRICED]);
    }

    /// @notice An order past all the venue's liquidity: at FORK_BLOCK its lowest band is a
    ///         full-range one, down to tick -887200, which about 3.8e16 WAVAX would cross.
    ///         10^18 WAVAX walks every tick and reaches the price limit with input left. A
    ///         partial fill is no price: the wrapper's quote and quoteCall, with all the gas,
    ///         are 0.
    function test_AvaxAI_BeyondTheWholeRange_NoPrice() public {
        _mount();
        BlazePhoenixGateWrapper w = BlazePhoenixGateWrapper(wrapper);
        (uint256 q0, ) = w.quote(true, 12_000e18);
        assertGt(q0, 0, "an order inside the range is priced");
        uint256 amt = 1e36;
        (uint256 q, ) = w.quote(true, amt);
        assertEq(q, 0, "past the whole range: no price");
        assertEq(w.quoteCall(true, amt), 0, "quoteCall: no price");
    }

    // ─── 3. live plugin: changed after create, refused at once ───────────

    /// @dev Mounted and priced before the change.
    function _pricedThen() internal returns (BlazePhoenixGateWrapper w) {
        _mount();
        w = BlazePhoenixGateWrapper(wrapper);
        (uint256 q0, ) = w.quote(false, 1_000e6);
        assertGt(q0, 0, "priced before the change");
    }

    /// @dev After the change the wrapper's quote and quoteCall are 0, the Quoter prices 0, and
    ///      the Router's execution reverts with the adapter's AdapterE(7).
    function _refusedNow(BlazePhoenixGateWrapper w) internal {
        uint256 amt = 1_000e6;
        (uint256 q, uint256 d) = w.quote(false, amt);
        assertEq(q, 0, "quote 0");
        assertEq(d, 0, "no depth declared");
        assertEq(w.quoteCall(false, amt), 0, "quoteCall 0");
        Run memory r;
        r.amt = amt;
        Route memory route = _preview(USDC, WAVAX, r);
        assertEq(r.quote, 0, "the Quoter prices 0");
        _fund(USDC, amt);
        _routerRefuses(route, amt, abi.encodeWithSelector(ExtAdapterBase.AdapterE.selector, uint8(7)));
    }

    /// @notice The plugin moves to another address with the same code (the factory owner's
    ///         setPlugin, then the new plugin's setPluginConfig back to AFTER_SWAP): refused.
    function test_AvaxAI_PluginMovedSameCode_Refused() public {
        BlazePhoenixGateWrapper w = _pricedThen();
        address copy = makeAddr("plugin-copy");
        vm.etch(copy, PLUGIN.code);
        address own = IAIFactory(BH_FACTORY).owner();
        vm.prank(own);
        IAIVenue(BH_WU_CUSTOM).setPlugin(copy);
        assertEq(uint256(_cfg()), 0, "setPlugin clears the config");
        vm.prank(copy);
        IAIVenue(BH_WU_CUSTOM).setPluginConfig(AFTER_SWAP);
        assertEq(IAIVenue(BH_WU_CUSTOM).plugin(), copy, "moved");
        assertEq(copy.codehash, PLUGIN.codehash, "the same code");
        assertEq(uint256(_cfg()), uint256(AFTER_SWAP), "AFTER_SWAP on again");
        _refusedNow(w);
    }

    /// @notice Other code at the pinned plugin's address, the config unchanged: refused.
    function test_AvaxAI_PluginCodeChanged_Refused() public {
        BlazePhoenixGateWrapper w = _pricedThen();
        vm.etch(PLUGIN, address(new PluginStubAI()).code);
        assertEq(IAIVenue(BH_WU_CUSTOM).plugin(), PLUGIN, "the same plugin address");
        assertTrue(PLUGIN.codehash != w.aux1(), "other code");
        assertEq(uint256(_cfg()), uint256(AFTER_SWAP), "the config unchanged");
        _refusedNow(w);
    }

    /// @notice The plugin turns BEFORE_SWAP on after create: refused.
    function test_AvaxAI_BeforeSwapTurnedOn_Refused() public {
        BlazePhoenixGateWrapper w = _pricedThen();
        vm.prank(PLUGIN);
        IAIVenue(BH_WU_CUSTOM).setPluginConfig(AFTER_SWAP | BEFORE_SWAP);
        assertEq(uint256(_cfg()), 3, "BEFORE_SWAP on");
        _refusedNow(w);
    }

    /// @notice The plugin turns DYNAMIC_FEE on after create: refused.
    function test_AvaxAI_DynamicFeeTurnedOn_Refused() public {
        BlazePhoenixGateWrapper w = _pricedThen();
        vm.prank(PLUGIN);
        IAIVenue(BH_WU_CUSTOM).setPluginConfig(AFTER_SWAP | DYNAMIC_FEE);
        assertEq(uint256(_cfg()), 130, "DYNAMIC_FEE on");
        _refusedNow(w);
    }

    /// @notice The factory owner sets a new plugin after create: setPlugin clears the config,
    ///         so no hook runs and the adapter does not read the plugin. The venue is served,
    ///         quote == exec == oracle.
    function test_AvaxAI_AfterSwapOff_PluginNotRead_Served() public {
        _mount();
        address stub = address(new PluginStubAI());
        address own = IAIFactory(BH_FACTORY).owner();
        vm.prank(own);
        IAIVenue(BH_WU_CUSTOM).setPlugin(stub);
        assertEq(uint256(_cfg()), 0, "setPlugin clears the config: no hook runs");
        assertTrue(
            IAIVenue(BH_WU_CUSTOM).plugin() != address(uint160(uint256(BlazePhoenixGateWrapper(wrapper).aux0()))),
            "not the plugin pinned at create"
        );
        Run memory r = _fill(USDC, WAVAX, 1_000e6);
        _log(true, r);
    }
}
