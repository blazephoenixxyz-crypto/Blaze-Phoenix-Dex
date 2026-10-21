// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// A token with chosen decimals, for the depth tests: a depth that skips the normalisation shows.
contract MockERC20Dec {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 d) { decimals = d; }

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
