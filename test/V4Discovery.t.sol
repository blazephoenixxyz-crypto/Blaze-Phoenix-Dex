// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Unit test for BPC.discoverV4 — the deterministic, deployer-blind, allowlist-free
// discovery of hookless V4 pools. A mock singleton returns the packed slot0/liquidity
// words for the derived PoolIds, so the test runs in CI with no RPC. The slot layout
// (base = keccak256(abi.encode(poolId, 6)); slot0 low160 = sqrtPriceX96; +3 low128 =
// liquidity) is the one verified live on Base against the canonical StateView.
//
//   forge test --match-contract V4Discovery -vv
import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC, PoolInfo} from "../src/BlazePhoenixCore.sol";

/// Minimal V4 PoolManager stand-in: only the extsload(bytes32) surface discoverV4 uses.
contract MockV4Manager {
    mapping(bytes32 => bytes32) internal store;
    function set(bytes32 slot, bytes32 val) external { store[slot] = val; }
    function extsload(bytes32 slot) external view returns (bytes32) { return store[slot]; }
}

contract V4DiscoveryTest is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    MockV4Manager mgr;

    function setUp() public { mgr = new MockV4Manager(); }

    // Seed the mock so the pool for (fee, tickSpacing) with hooks=0 reads as existing.
    function _seed(uint24 fee, int24 ts, uint160 sqrtP, uint128 liq) internal {
        (address c0, address c1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        bytes32 pid  = keccak256(abi.encode(c0, c1, fee, ts, address(0)));
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        mgr.set(base, bytes32(uint256(sqrtP)));                       // slot0: low160 = sqrtPriceX96
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(liq)));   // +3:    low128 = liquidity
    }

    function test_findsExactlySeededTiers() public {
        _seed(500, 10, 3460964161776092427580885, 1e18);   // exists
        _seed(3000, 60, 3463208568752477257616415, 5e17);  // exists
        // (100,1) and (10000,200) left empty → must be excluded

        PoolInfo[] memory found = BPC.discoverV4(address(mgr), WETH, USDC);
        assertEq(found.length, 2, "must find exactly the two seeded tiers");

        (address c0, address c1) = WETH < USDC ? (WETH, USDC) : (USDC, WETH);
        bool saw500;
        bool saw3000;
        for (uint256 i; i < found.length; ++i) {
            assertTrue(found[i].kind == BPC.KIND_V4, "kind must be V4");
            assertEq(found[i].hooks, address(0), "discovered pools are hookless");
            assertEq(found[i].pool, address(mgr), "pool == singleton manager");
            assertEq(found[i].token0, c0);
            assertEq(found[i].token1, c1);
            assertTrue(found[i].active, "active");
            if (found[i].fee == 500)  { assertEq(found[i].tickSpacing, int24(10)); saw500  = true; }
            if (found[i].fee == 3000) { assertEq(found[i].tickSpacing, int24(60)); saw3000 = true; }
        }
        assertTrue(saw500 && saw3000, "both seeded tiers present");
    }

    function test_orderIndependentOfTokenArgs() public {
        _seed(500, 10, 3460964161776092427580885, 1e18);
        PoolInfo[] memory a = BPC.discoverV4(address(mgr), WETH, USDC);
        PoolInfo[] memory b = BPC.discoverV4(address(mgr), USDC, WETH);   // reversed args
        assertEq(a.length, 1);
        assertEq(b.length, 1);
        assertEq(a[0].token0, b[0].token0, "sorting makes arg order irrelevant");
        assertEq(a[0].fee, b[0].fee);
    }

    function test_excludesZeroLiquidity() public {
        _seed(500, 10, 3460964161776092427580885, 0);   // price set, liquidity 0 → excluded
        PoolInfo[] memory found = BPC.discoverV4(address(mgr), WETH, USDC);
        assertEq(found.length, 0, "a price without liquidity is not a routable pool");
    }

    function test_emptyWhenNoManager() public {
        PoolInfo[] memory found = BPC.discoverV4(address(0), WETH, USDC);
        assertEq(found.length, 0, "no manager on this chain -> nothing to discover");
    }

    function test_emptyWhenNoPools() public {
        PoolInfo[] memory found = BPC.discoverV4(address(mgr), WETH, USDC);
        assertEq(found.length, 0, "unseeded manager -> no pools");
    }
}
