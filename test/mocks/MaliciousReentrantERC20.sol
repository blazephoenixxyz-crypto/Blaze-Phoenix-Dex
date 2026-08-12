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
            (bool ok, ) = attackTarget.call(attackCalldata);
            lastReentryReverted = !ok;
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
