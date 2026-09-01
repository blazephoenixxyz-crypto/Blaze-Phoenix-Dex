// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice MockERC20's pathological sibling. Same external surface (name,
///         symbol, decimals, totalSupply, balanceOf, allowance, mint, approve,
///         transfer, transferFrom, setFeeOnTransferBps, setNoReturnData,
///         setReturnFalseOnFail) so existing fixtures can adopt it, plus the
///         token-behaviour classes MockERC20 cannot express:
///
///           · constructor-set `decimals` (MockERC20 hardcodes 18);
///           · REBASING in both directions: balances are stored as SHARES and
///             `balanceOf` applies a settable scale factor (the AMPL model), so
///             every holder's balance moves at once, outside any transfer;
///           · BLOCKLIST (USDC/USDT style): transfers to or from a blocked
///             address revert;
///           · PAUSABLE: `setPaused(true)` reverts every transfer;
///           · fee-on-transfer is KEPT, so the pathologies can combine with a
///             tax.
///
///         Mid-transaction injection: a test cannot call setRebase/setPaused
///         between two hops of one swap, so the token carries ONE-SHOT triggers
///         that fire inside `_transfer`, after balances have moved, when the
///         delivery lands on a chosen address (e.g. a treasury, or the Router
///         itself). Each trigger clears itself on firing.
///
///         Accounting model: `shares` is the ground truth;
///         display = shares * rebaseNum / rebaseDen. `transfer(amt)` takes
///         DISPLAY units and converts to shares at the current factor, rounding
///         down — exactly how real rebasing tokens behave, so conservation
///         holds in shares while display balances jump with the factor.
contract PathologicalERC20 {
    string public name;
    string public symbol;
    uint8  public immutable decimals;

    mapping(address => uint256) internal shares;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 internal totalShares;

    // ─── MockERC20-compatible switches ───
    uint16 public feeOnTransferBps;
    bool   public noReturnData;
    bool   public returnFalseOnFail;

    // ─── rebase ───
    uint256 public rebaseNum = 1;
    uint256 public rebaseDen = 1;

    // ─── blocklist / pause ───
    mapping(address => bool) public blocked;
    bool public paused;

    // ─── one-shot mid-transaction triggers ───
    address public rebaseTriggerTarget;
    uint256 internal trigNum;
    uint256 internal trigDen;
    address public pauseTriggerTarget;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals; // MockERC20's default is 18; pass 18 for parity
    }

    // ─── views (display units) ───

    function totalSupply() external view returns (uint256) { return _toDisplay(totalShares); }
    function balanceOf(address who) public view returns (uint256) { return _toDisplay(shares[who]); }
    function sharesOf(address who) external view returns (uint256) { return shares[who]; }

    function _toDisplay(uint256 s) internal view returns (uint256) { return s * rebaseNum / rebaseDen; }
    function _toShares(uint256 amt) internal view returns (uint256) { return amt * rebaseDen / rebaseNum; }

    // ─── switches ───

    /// @dev Mints `amt` DISPLAY units at the current factor.
    function mint(address to, uint256 amt) external {
        uint256 s = _toShares(amt);
        totalShares += s;
        shares[to] += s;
    }

    function setFeeOnTransferBps(uint16 bps) external { feeOnTransferBps = bps; }
    function setNoReturnData(bool b) external { noReturnData = b; }
    function setReturnFalseOnFail(bool b) external { returnFalseOnFail = b; }

    /// @notice Set the rebase factor: display = shares * num / den.
    ///         num > den is a positive rebase, num < den a negative one.
    function setRebase(uint256 num, uint256 den) public {
        require(num > 0 && den > 0, "PathologicalERC20: zero factor");
        rebaseNum = num;
        rebaseDen = den;
    }

    function setBlocked(address who, bool b) external { blocked[who] = b; }
    function setPaused(bool b) external { paused = b; }

    /// @notice One-shot: the next transfer that DELIVERS to `target` applies
    ///         setRebase(num, den) after the balances have moved.
    function setRebaseOnTransferTo(address target, uint256 num, uint256 den) external {
        require(num > 0 && den > 0, "PathologicalERC20: zero factor");
        rebaseTriggerTarget = target;
        trigNum = num;
        trigDen = den;
    }

    /// @notice One-shot: the next transfer that DELIVERS to `target` pauses
    ///         the token after the balances have moved.
    function setPauseOnTransferTo(address target) external {
        pauseTriggerTarget = target;
    }

    // ─── ERC20 ───

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        if (noReturnData) { assembly { return(0, 0) } }
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _transfer(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            if (a != type(uint256).max) {
                if (a < amt) {
                    if (returnFalseOnFail) {
                        if (noReturnData) { assembly { return(0, 0) } }
                        return false;
                    }
                    revert("PathologicalERC20: allowance");
                }
                allowance[from][msg.sender] = a - amt;
            }
        }
        return _transfer(from, to, amt);
    }

    function _transfer(address from, address to, uint256 amt) private returns (bool) {
        if (paused) revert("PathologicalERC20: paused");
        if (blocked[from] || blocked[to]) revert("PathologicalERC20: blocked");
        uint256 sAmt = _toShares(amt);
        if (shares[from] < sAmt) {
            if (returnFalseOnFail) {
                if (noReturnData) { assembly { return(0, 0) } }
                return false;
            }
            revert("PathologicalERC20: balance");
        }
        shares[from] -= sAmt;
        uint256 delivered = amt;
        if (feeOnTransferBps > 0) {
            delivered = amt - (amt * feeOnTransferBps) / 10_000;
        }
        shares[to] += _toShares(delivered);
        // One-shot pathologies fire AFTER the balances moved — the delivery
        // itself is honest; the world changes right underneath the caller's
        // just-taken measurement.
        if (to == rebaseTriggerTarget && to != address(0)) {
            rebaseTriggerTarget = address(0);
            setRebase(trigNum, trigDen);
        }
        if (to == pauseTriggerTarget && to != address(0)) {
            pauseTriggerTarget = address(0);
            paused = true;
        }
        if (noReturnData) { assembly { return(0, 0) } }
        return true;
    }
}
