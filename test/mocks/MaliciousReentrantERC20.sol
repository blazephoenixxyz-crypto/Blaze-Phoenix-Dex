// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice A minimally-functional ERC20 whose transferFrom() can, once
///         armed, attempt a nested call into an arbitrary target/calldata
///         (e.g. the Router's own swapExactIn) mid-transfer — used to prove
///         the Router's nrEntrant transient-storage lock actually blocks
///         reentrancy through the most realistic vector: the token pull
///         itself. The nested attempt's outcome is recorded rather than
///         propagated, so the OUTER swap can complete normally and the test
///         can inspect the result afterward.
contract MaliciousReentrantERC20 {
    string  public name = "EVIL";
    string  public symbol = "EVIL";
    uint8   public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public attackTarget;
    bytes   public attackCalldata;
    bool    public attacking;
    bool    public lastReentryReverted;
    bool    public lastReentryAttempted;
    /// Raw revert bytes of the nested call, so a test can assert WHICH guard
    /// refused rather than merely that a refusal happened.
    bytes   public lastReentryReturndata;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function setAttack(address target, bytes calldata cd) external {
        attackTarget = target;
        attackCalldata = cd;
        attacking = true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _transfer(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (from != msg.sender) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "EVIL: allowance");
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        if (attacking) {
            attacking = false; // one-shot: avoid runaway recursion
            lastReentryAttempted = true;
            // CAPTURE THE REASON, not just the fact. Discarding the returndata
            // here made every reentrancy assertion in the tree a claim that
            // SOMETHING reverted, never that the LOCK reverted -- and a nested
            // call mid-transferFrom reverts for several unrelated reasons. The
            // mutation guard proved it: a Router whose lock is never armed
            // still failed the nested call, and the test stayed green.
            (bool ok, bytes memory ret) = attackTarget.call(attackCalldata);
            lastReentryReverted = !ok;
            lastReentryReturndata = ret;
        }
        return _transfer(from, to, amt);
    }

    function _transfer(address from, address to, uint256 amt) private returns (bool) {
        require(balanceOf[from] >= amt, "EVIL: balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
