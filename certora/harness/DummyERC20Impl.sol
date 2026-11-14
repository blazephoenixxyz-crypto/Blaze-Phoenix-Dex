// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Minimal, well-behaved ERC20 for the Certora scene (no fee, no hooks). It stands
///         in for tokenIn / tokenOut so the Prover can resolve the Router's balance reads
///         and transfers instead of havocking them.
contract DummyERC20Impl {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        return true;
    }
}
