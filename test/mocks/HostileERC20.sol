// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IPermit2} from "../../src/BlazePhoenixRouter.sol";

/// @notice A token whose misbehaviour is chosen PER COUNTERPARTY, so one cell can aim a
///         single transfer of a swap (the pull, one fee push, the pool payment, the
///         delivery) and leave every other transfer honest.
///
///         Balances are SHARES (display = shares * num / den), so a rebase moves every
///         holder at once and a test can tell "the Router kept its shares" from "the
///         Router shows the same number".
///
///         The mode of a transfer is `modeTo[to]`; when that is NONE and `to` is not
///         exempt, `modeFrom[from]`. HOOK and the two REBASE modes are one-shot.
contract HostileERC20 {
    enum Mode {
        NONE,
        TRUE_NO_MOVE,     // answers true, moves nothing
        FALSE_NO_MOVE,    // answers false, moves nothing
        FALSE_BUT_MOVES,  // moves, answers false
        OVERSIZED_TRUE,   // moves, answers 64 bytes (1, 1)
        REVERT,           // blocklist
        GAS_BURN,         // burns every unit of gas it was given
        HOOK,             // moves, then calls `hookTarget` (ERC-777 style), one-shot
        REBASE_UP,        // moves, then restates every balance x 11/10, one-shot
        REBASE_DN,        // moves, then restates every balance x 9/10, one-shot
        SHORT,            // delivers `shortBy` wei less than asked; the dust stays with the sender
        OVERSIZED_NO_MOVE // answers 64 bytes (1, 1), moves nothing
    }

    string public constant name = "Hostile";
    string public constant symbol = "HST";
    uint8 public immutable decimals;

    mapping(address => uint256) internal shares;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public num = 1;
    uint256 public den = 1;

    uint16 public taxBps;
    bool public revertOnZero;
    uint256 public shortBy = 1;
    uint256 public depositBps = 10_000;
    bool public depositRebasesUp;

    mapping(address => Mode) public modeTo;
    mapping(address => Mode) public modeFrom;
    mapping(address => bool) public exemptTo;
    /// @dev callers that get NO returndata on success (the USDT shape). Per caller, because
    ///      the mock venues call `transfer` through a typed interface that needs the word.
    mapping(address => bool) public bareFor;

    // One slot, and a hash for the answer: the call-back must fit the gas a capped transfer
    // is given (a real ERC-777 hook does no bookkeeping at all).
    address public hookTarget;
    uint64 public hookCalls;
    bool public hookOk;
    bytes32 public hookRetHash;
    bytes public hookData;

    constructor(uint8 d) { decimals = d; }

    // --- views ---
    function balanceOf(address who) public view returns (uint256) { return shares[who] * num / den; }
    function sharesOf(address who) external view returns (uint256) { return shares[who]; }
    function _toShares(uint256 amt) internal view returns (uint256) { return amt * den / num; }

    // --- switches ---
    function mint(address to, uint256 amt) external { shares[to] += _toShares(amt); }
    function setModeTo(address who, Mode m) external { modeTo[who] = m; }
    function setModeFrom(address who, Mode m) external { modeFrom[who] = m; }
    function setExemptTo(address who, bool b) external { exemptTo[who] = b; }
    function setBareFor(address who, bool b) external { bareFor[who] = b; }
    function setTaxBps(uint16 b) external { taxBps = b; }
    function setRevertOnZero(bool b) external { revertOnZero = b; }
    function setShortBy(uint256 w) external { shortBy = w; }
    function setDepositBps(uint256 b) external { depositBps = b; }
    function setDepositRebasesUp(bool b) external { depositRebasesUp = b; }
    function setHook(address target, bytes calldata data) external { hookTarget = target; hookData = data; }
    /// @dev restate every balance by n/d, between two calls.
    function restate(uint256 n, uint256 d) external { num *= n; den *= d; }

    // --- WETH surface ---
    function deposit() external payable {
        shares[msg.sender] += _toShares(msg.value * depositBps / 10_000);
        if (depositRebasesUp) { depositRebasesUp = false; num *= 11; den *= 10; }
    }

    // --- ERC20 ---
    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        _answer(Mode.NONE);
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) {
                require(a >= amt, "Hostile: allowance");
                allowance[from][msg.sender] = a - amt;
            }
        }
        _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) private {
        if (revertOnZero && amt == 0) revert("Hostile: zero amount");
        Mode m = modeTo[to];
        bool keyedTo = m != Mode.NONE;
        if (!keyedTo && !exemptTo[to]) m = modeFrom[from];
        if (m == Mode.REVERT) revert("Hostile: blocked");
        if (m == Mode.GAS_BURN) { assembly { invalid() } }
        if (m != Mode.TRUE_NO_MOVE && m != Mode.FALSE_NO_MOVE && m != Mode.OVERSIZED_NO_MOVE) {
            uint256 send = amt;
            if (m == Mode.SHORT) send = amt > shortBy ? amt - shortBy : 0;
            uint256 s = _toShares(send);
            require(shares[from] >= s, "Hostile: balance");
            shares[from] -= s;
            shares[to] += _toShares(send - send * taxBps / 10_000);
            if (m == Mode.HOOK || m == Mode.REBASE_UP || m == Mode.REBASE_DN) {
                if (keyedTo) modeTo[to] = Mode.NONE; else modeFrom[from] = Mode.NONE;
                if (m == Mode.REBASE_UP) { num *= 11; den *= 10; }
                else if (m == Mode.REBASE_DN) { num *= 9; den *= 10; }
                else {
                    (bool ok, bytes memory ret) = hookTarget.call(hookData);
                    (hookCalls, hookOk, hookRetHash) = (hookCalls + 1, ok, keccak256(ret));
                }
            }
        }
        _answer(m);
    }

    /// @dev Never returns to Solidity: writes the answer's shape and leaves the call.
    function _answer(Mode m) private view {
        if (m == Mode.FALSE_NO_MOVE || m == Mode.FALSE_BUT_MOVES) { assembly { mstore(0, 0) return(0, 32) } }
        if (m == Mode.OVERSIZED_TRUE || m == Mode.OVERSIZED_NO_MOVE) { assembly { mstore(0, 1) mstore(32, 1) return(0, 64) } }
        if (bareFor[msg.sender]) { assembly { return(0, 0) } }
        assembly { mstore(0, 1) return(0, 32) }
    }
}

/// @notice Permit2 stand-in that pulls the way the real one does (solmate
///         safeTransferFrom): no returndata is a success, a word must be true.
///         MockPermit2 decodes a bool and so cannot carry a USDT-shaped token.
contract TolerantPermit2 {
    function permitTransferFrom(
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    ) external {
        require(details.requestedAmount <= permit.permitted.amount, "P2: over-request");
        (bool ok, bytes memory ret) = permit.permitted.token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, details.to, details.requestedAmount)
        );
        require(ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) == 1)), "TRANSFER_FROM_FAILED");
    }
}
