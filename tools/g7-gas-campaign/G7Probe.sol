// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IWETHG7 { function deposit() external payable; }
interface IERC20G7 { function balanceOf(address) external view returns (uint256); }

/// @notice The payer/recipient of a measured execution (as N1Probe in tools/n1-aged-quote).
///         Placed by code override; delivery is the balanceOf delta of tokenOut (the oracle is
///         the token, not the Router's return value, AGENTS.md rule 4).
contract G7Probe {
    function run(address router, address tIn, address tOut, uint256 amountIn, bool wrap, bytes calldata data)
        external
        returns (bool ok, bytes memory ret, uint256 delivered, uint256 gasUsed, uint256 routerReturn)
    {
        if (wrap) IWETHG7(tIn).deposit{value: amountIn}();
        // Low-level approve: some dollar tokens return nothing.
        (bool a,) = tIn.call(abi.encodeWithSelector(0x095ea7b3, router, amountIn));
        require(a, "G7Probe: approve");
        uint256 b0 = IERC20G7(tOut).balanceOf(address(this));
        uint256 g = gasleft();
        (ok, ret) = router.call(data);
        gasUsed = g - gasleft();
        uint256 b1 = IERC20G7(tOut).balanceOf(address(this));
        delivered = b1 > b0 ? b1 - b0 : 0;
        if (ok && ret.length >= 32) routerReturn = abi.decode(ret, (uint256));
    }

    /// Replays operator calls from the admin's address: the runner places this code at the admin
    /// (an EOA in the state) by code override and traces `batch(hub, [seedPool...])` at the block
    /// b - age, so the Hub sees msg.sender == admin. A refused call is reported, not fatal.
    function batch(address target, bytes[] calldata calls) external returns (bool[] memory oks) {
        oks = new bool[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (oks[i],) = target.call(calls[i]);
        }
    }
}
