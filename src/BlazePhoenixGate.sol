// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {BlazePhoenixCore as BPC} from "./BlazePhoenixCore.sol";

// =============================================================================
//  BlazePhoenixGate — one Hub factory row (KIND_EXTERNAL, MODE_CREATE2_V3) in
//  front of venues the Core cannot read natively.
//
//  WHAT IT IS. A CREATE2 factory of thin wrappers. Each wrapper looks like a
//  Uniswap-V3 pool to the Router (`swap` + `uniswapV3SwapCallback`, exact-in,
//  token0/token1/fee getters) and forwards the input it was paid to the
//  adapter of its family, which trades on the real venue. Immutable, no proxy.
//
//  THE THREE PROPERTIES, and where each lives.
//    1. IDENTITY IS DERIVED. A wrapper's address is CREATE2(gate,
//       Core.v3Salt(t0, t1, venueKey), WRAPPER_INIT_HASH): the Hub's derive
//       finds it by the SAME formula it uses for every V3 factory, so a wrapper
//       is discovered because the Gate made it, never because calldata named
//       it. Its venue pool is the adapter's `resolve` answer, asked once, at
//       creation, and immutable afterwards.
//    2. CUSTODY IS THE DELTA OF THIS CALL. The wrapper forwards exactly what it
//       measured arriving, and after the adapter runs it requires that the
//       adapter holds no more of either token than before. The output is the
//       delta measured at the recipient, never a value the adapter returns.
//    3. EXECUTION NEVER TRUSTS THE QUOTE. `swap` never reads `quote`; the floors
//       are the Router's (per-leg 80 %, hop budget, userMinOut).
//
//  ADAPTER REGISTRY. `adapterOf[family]` changes only by propose -> 48 h ->
//  accept, with the code scanned for DELEGATECALL / CALLCODE / SELFDESTRUCT and
//  its codehash pinned; every swap re-checks the pin. `clearAdapter` is
//  instant. After `renounceControl` the curator may still ADD (a new family, a
//  new wrapper), never replace or clear.
// =============================================================================

interface IExtAdapter {
    /// Asked once, by the Gate, at `create`. Must prove from the VENUE (registry, factory,
    /// vault) that `hint` is its pool for (t0, t1) and return what `exec` needs.
    function resolve(address t0, address t1, uint24 venueKey, bytes calldata hint)
        external view returns (address venuePool, bytes32 aux0, bytes32 aux1);
    /// Called only by a Gate wrapper, with `amtIn` of the input already in the adapter.
    /// Delivers the output to `recipient`. The return value is advisory and never read.
    function exec(address venuePool, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn, address recipient)
        external returns (uint256 out);
    /// View quote; 0 means "not quotable on-chain".
    function quote(address venuePool, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external view returns (uint256 out, uint256 depth18);
    /// Non-view quote for venues that only price by simulation, read off-chain by eth_call.
    /// Rule: when `quote` is non-zero, `quoteCall` returns the same `out`.
    function quoteCall(address venuePool, bytes32 aux0, bytes32 aux1, bool zeroForOne, uint256 amtIn)
        external returns (uint256 out);
}

interface IGateV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract BlazePhoenixGate {
    /// 1 not the curator | 2 control renounced or not the admin | 3 bad argument |
    /// 4 no live adapter (none, or its code moved from the pin) | 5 resolve gave no pool |
    /// 6 adapter code refused by the scan | 7 timelock running | 8 nothing pending |
    /// 9 adapter code moved since the proposal | 10 replacing a family after renounce
    error GateE(uint8 code);

    event AdapterProposed(uint8 indexed family, address adapter, bytes32 codehash, uint256 eta);
    event AdapterAccepted(uint8 indexed family, address adapter, bytes32 codehash);
    event AdapterCleared(uint8 indexed family);
    event WrapperCreated(address indexed wrapper, address token0, address token1, uint24 venueKey, address venuePool);
    event AdminSet(address admin);
    event ControlRenounced();

    uint256 public constant ADAPTER_DELAY = 48 hours;
    /// keccak256 of the wrapper's creation code: the init hash the Hub's factory row carries.
    bytes32 public immutable WRAPPER_INIT_HASH;

    struct Pending { address adapter; uint64 eta; bytes32 codehash; }

    address public admin;
    bool public controlRenounced;
    /// Bit f set = family f has had an accepted adapter. Never cleared: after renounce a
    /// family that was ever live cannot be refilled, so its wrappers cannot change hands.
    uint256 public familiesUsed;
    mapping(uint8 => address) public adapterOf;
    mapping(uint8 => bytes32) public pinOf;
    mapping(uint8 => Pending) public pendingOf;
    mapping(address => bool) public isWrapper;

    // Parameters of the wrapper under construction, read back by its constructor.
    address transient private _pT0;
    address transient private _pT1;
    uint24  transient private _pKey;
    address transient private _pVenue;
    bytes32 transient private _pAux0;
    bytes32 transient private _pAux1;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert GateE(1);
        _;
    }

    modifier onlyControl() {
        if (msg.sender != admin || controlRenounced) revert GateE(2);
        _;
    }

    constructor(address admin_) {
        if (admin_ == address(0)) revert GateE(3);
        admin = admin_;
        WRAPPER_INIT_HASH = keccak256(type(BlazePhoenixGateWrapper).creationCode);
    }

    // ─── roles (mirror of the Hub: control dies with renounce, the curator stays) ───

    function setAdmin(address a) external onlyControl {
        if (a == address(0)) revert GateE(3);
        admin = a;
        emit AdminSet(a);
    }

    function renounceControl() external onlyAdmin {
        controlRenounced = true;
        emit ControlRenounced();
    }

    // ─── adapter registry ───

    /// The ONE producer of "may family f be written now?": a family that was ever live is a
    /// replacement, and replacing dies with control. Asked at propose AND at accept, so a
    /// proposal made before the renounce cannot land after it.
    function _mayWrite(uint8 f) private view {
        if (controlRenounced && ((familiesUsed >> f) & 1) != 0) revert GateE(10);
    }

    /// The ONE producer of "is this code admissible as an adapter?". Walks the runtime code
    /// opcode by opcode, stepping over PUSH data, and refuses DELEGATECALL (0xF4), CALLCODE
    /// (0xF2) and SELFDESTRUCT (0xFF): code that can run foreign code in its own context, or
    /// vanish and be redeployed, would make the pin meaningless. Empty code and an EIP-7702
    /// delegation designator (0xEF prefix) are refused too. Conservative by construction: a
    /// banned byte in a data section that is not PUSH data refuses honest code; it never
    /// admits dishonest code.
    function codeIsClean(address a) public view returns (bool) {
        bytes memory c = a.code;
        uint256 n = c.length;
        if (n == 0 || uint8(c[0]) == 0xEF) return false;
        for (uint256 i; i < n; ) {
            uint8 op = uint8(c[i]);
            if (op == 0xF4 || op == 0xF2 || op == 0xFF) return false;
            if (op >= 0x60 && op <= 0x7F) i += op - 0x5F;
            unchecked { ++i; }
        }
        return true;
    }

    function proposeAdapter(uint8 f, address a) external onlyAdmin {
        _mayWrite(f);
        if (!codeIsClean(a)) revert GateE(6);
        uint64 eta = uint64(block.timestamp + ADAPTER_DELAY);
        pendingOf[f] = Pending({adapter: a, eta: eta, codehash: a.codehash});
        emit AdapterProposed(f, a, a.codehash, eta);
    }

    function acceptAdapter(uint8 f) external onlyAdmin {
        Pending memory p = pendingOf[f];
        if (p.adapter == address(0)) revert GateE(8);
        if (block.timestamp < p.eta) revert GateE(7);
        if (p.adapter.codehash != p.codehash) revert GateE(9);
        _mayWrite(f);
        delete pendingOf[f];
        adapterOf[f] = p.adapter;
        pinOf[f] = p.codehash;
        familiesUsed |= uint256(1) << f;
        emit AdapterAccepted(f, p.adapter, p.codehash);
    }

    /// Instant: the curator's brake when a venue or an adapter misbehaves. Every wrapper of
    /// the family reverts from the next block on; the other kinds are untouched.
    function clearAdapter(uint8 f) external onlyControl {
        // The pin is left as it was: with adapterOf zero, liveAdapter answers zero whatever
        // the pin holds, and a later accept overwrites it.
        delete adapterOf[f];
        delete pendingOf[f];
        emit AdapterCleared(f);
    }

    /// The ONE producer of "which adapter may run for family f": zero when none is set or
    /// when its code is no longer the code that was accepted.
    function liveAdapter(uint8 f) public view returns (address a) {
        a = adapterOf[f];
        if (a.codehash != pinOf[f]) a = address(0);
    }

    // ─── wrappers ───

    /// Curator only: the first create fixes the venue pool of (t0, t1, venueKey) for ever, so
    /// an open door would let anyone occupy every slot with a thin pool of a legitimate venue.
    /// Survives renounce (grow-only, like the Hub's addFactory).
    function create(address tA, address tB, uint24 venueKey, bytes calldata hint)
        external onlyAdmin returns (address w)
    {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        // venueKey 0 is the Hub's Algebra sentinel (fee 0 derives by algebraSalt), so a wrapper
        // under it would never be found.
        if (t0 == address(0) || t0 == t1 || venueKey == 0) revert GateE(3);
        address a = liveAdapter(uint8(venueKey >> 16));
        if (a == address(0)) revert GateE(4);
        (address vp, bytes32 x0, bytes32 x1) = IExtAdapter(a).resolve(t0, t1, venueKey, hint);
        if (vp == address(0)) revert GateE(5);
        (_pT0, _pT1, _pKey, _pVenue, _pAux0, _pAux1) = (t0, t1, venueKey, vp, x0, x1);
        w = address(new BlazePhoenixGateWrapper{salt: BPC.v3Salt(t0, t1, venueKey)}());
        isWrapper[w] = true;
        emit WrapperCreated(w, t0, t1, venueKey, vp);
    }

    /// Read by the wrapper's constructor, inside `create`. Zero outside it.
    function params()
        external view returns (address, address, uint24, address, bytes32, bytes32)
    {
        return (_pT0, _pT1, _pKey, _pVenue, _pAux0, _pAux1);
    }

    /// Where the wrapper of (tA, tB, venueKey) lives, created or not: the Hub's derive, by the
    /// same two producers (Core.v3Salt, Core.create2Address).
    function wrapperAddress(address tA, address tB, uint24 venueKey) external view returns (address) {
        (address t0, address t1) = BPC.sortTokens(tA, tB);
        return BPC.create2Address(address(this), BPC.v3Salt(t0, t1, venueKey), WRAPPER_INIT_HASH);
    }
}

/// @notice A V3-shaped facade for one venue pool. Holds nothing between calls.
contract BlazePhoenixGateWrapper {
    error GateE(uint8 code);

    address public immutable gate;
    address public immutable token0;
    address public immutable token1;
    /// The Hub's `fee`: the venue key, family << 16 | slot.
    uint24  public immutable fee;
    uint8   public immutable family;
    address public immutable venuePool;
    bytes32 public immutable aux0;
    bytes32 public immutable aux1;

    bool transient private _locked;

    constructor() {
        (address t0, address t1, uint24 k, address vp, bytes32 x0, bytes32 x1) = BlazePhoenixGate(msg.sender).params();
        gate = msg.sender;
        token0 = t0;
        token1 = t1;
        fee = k;
        family = uint8(k >> 16);
        venuePool = vp;
        aux0 = x0;
        aux1 = x1;
    }

    /// 11 re-entered | 12 not exact-in | 4 no live adapter | 13 paid less than asked |
    /// 14 the adapter kept part of the input or of the output
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external returns (int256 amount0, int256 amount1)
    {
        if (_locked) revert GateE(11);
        _locked = true;
        if (amountSpecified <= 0) revert GateE(12);
        address a = BlazePhoenixGate(gate).liveAdapter(family);
        if (a == address(0)) revert GateE(4);
        (address tIn, address tOut) = zeroForOne ? (token0, token1) : (token1, token0);

        // 1) Collect the input the V3 way: ask the caller, then measure what arrived.
        uint256 inBefore = BPC.balanceOf(tIn, address(this));
        (amount0, amount1) = zeroForOne ? (amountSpecified, int256(0)) : (int256(0), amountSpecified);
        IGateV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        uint256 paid = BPC.balanceOf(tIn, address(this)) - inBefore;
        if (paid < uint256(amountSpecified)) revert GateE(13);

        // 2) Forward exactly that delta and let the adapter trade it.
        uint256 adIn = BPC.balanceOf(tIn, a);
        uint256 adOut = BPC.balanceOf(tOut, a);
        uint256 outBefore = BPC.balanceOf(tOut, recipient);
        BPC.safeTransfer(tIn, a, paid);
        IExtAdapter(a).exec(venuePool, aux0, aux1, zeroForOne, paid, recipient);

        // 3) Custody: the adapter ends holding what it held before the push, of both tokens.
        if (BPC.balanceOf(tIn, a) > adIn) revert GateE(14);
        if (BPC.balanceOf(tOut, a) > adOut) revert GateE(14);

        // 4) The output is the measured delta at the recipient, in V3's sign convention.
        uint256 out = BPC.balanceOf(tOut, recipient) - outBefore;
        if (zeroForOne) amount1 = -int256(out);
        else amount0 = -int256(out);
        _locked = false;
    }

    /// View quote through the live adapter; 0 when there is none or it fails. Never read by
    /// `swap`.
    function quote(bool zeroForOne, uint256 amtIn) external view returns (uint256 out, uint256 depth18) {
        address a = BlazePhoenixGate(gate).liveAdapter(family);
        if (a == address(0)) return (0, 0);
        try IExtAdapter(a).quote(venuePool, aux0, aux1, zeroForOne, amtIn) returns (uint256 o, uint256 d) {
            (out, depth18) = (o, d);
        } catch {}
    }

    /// Non-view quote through the live adapter, for the Quoter's eth_call; 0 when there is
    /// none or it fails. Never read by `swap`, and the wrapper holds nothing it could move.
    function quoteCall(bool zeroForOne, uint256 amtIn) external returns (uint256 out) {
        address a = BlazePhoenixGate(gate).liveAdapter(family);
        if (a == address(0)) return 0;
        try IExtAdapter(a).quoteCall(venuePool, aux0, aux1, zeroForOne, amtIn) returns (uint256 o) {
            out = o;
        } catch {}
    }
}
