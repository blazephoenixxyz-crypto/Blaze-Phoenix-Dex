// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Minimal probe: isolates whether the archive RPC (the ALCHEMY_KEY secret)
// actually works, separate from the router integration or any stale pool
// assumptions in the other fork tests. If this passes, the RPC is good and any
// other fork failure is a test/pool problem; if this fails, the ALCHEMY_KEY
// secret (name or value) is the problem.

import {Test} from "forge-std/Test.sol";

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

contract RpcProbeTest is Test {
    // WETH on Ethereum mainnet.
    address constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // WETH on Base.
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    function test_MainnetForkAndReadWETH() public {
        vm.createSelectFork("mainnet");
        assertGt(block.number, 18_000_000, "mainnet fork is not recent");
        assertGt(IERC20Supply(ETH_WETH).totalSupply(), 0, "mainnet WETH totalSupply is zero");
    }

    function test_BaseForkAndReadWETH() public {
        vm.createSelectFork("base");
        assertGt(block.number, 10_000_000, "base fork is not recent");
        assertGt(IERC20Supply(BASE_WETH).totalSupply(), 0, "base WETH totalSupply is zero");
    }
}
