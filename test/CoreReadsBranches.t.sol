// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// =============================================================================
//  The read layer's three cases — answered / codeless / REFUSED.
//
//  Every external read in BlazePhoenixCore is an assembly staticcall wrapper,
//  and every wrapper separates exactly three outcomes:
//
//    1. the call SUCCEEDED WITH DATA        -> the value is a measurement
//    2. the call succeeded WITH NO DATA     -> codeless target, deliberate zero
//    3. the call FAILED                     -> NOT a value. Value-moving
//       wrappers revert ("BPC:transfer" / "BPC:transferFrom" / "BPC:approve" /
//       "BPC:balanceOf"); quote-side probes return the 0 that downstream
//       guards refuse to price (outV2/outV3 return 0, quoteV3Fee returns the
//       0xFFFFFF unquotable sentinel).
//
//  The 2026-09-01 coverage run showed these wrappers' FAILURE arms almost
//  never taken: the suite feeds them healthy mocks and walks arm 1. But
//  "a failed read treated as a value" is the exact defect class fixed in
//  balanceOf on 2026-08-31 (test/BalanceOfFailReadsAsZero.t.sol), and the
//  governing law names the family: absence = permission. Each test below
//  constructs the token/pool/factory/manager behaviour that forces one
//  specific untaken arm — revert, empty answer, short answer, oversized
//  answer, non-view implementation, malformed ABI — and pins what the caller
//  MUST then see. Core line numbers cited per test are from the coverage run.
//
//  Deliberate asymmetries this file pins (they look like bugs; they are
//  policy, and each side has a reason stated at its test):
//    * transfers REFUSE an odd-sized answer (Core:580 default arm) while
//      balanceOf tolerates >= 32 bytes and reads word 0 (Core:698) — moving
//      value demands a well-formed bool; measuring a balance only needs
//      word 0, and the >= policy is written into balanceOf's own comment.
//    * decimals is STRICT (== 32, Core:750) and fails OPEN to 18 — its
//      consumer normalises amounts, and 18 is the documented safe default.
//    * v4 extsload words are STRICT (== 32, Core:1598/1603) — a slot read is
//      a word or it is nothing.
//
//  Every test states what breaks it: deleting the guarded branch body it
//  targets flips a pinned observable (a revert that stops happening, a zero
//  that becomes junk read from stale memory, a fallback origin that stops
//  being consulted). The two exceptions are marked GAS-ONLY where the early
//  return is defense-in-depth whose observable equals the refusal path.
//
//  forge test --match-contract CoreExternalReads -vv
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixCore as BPC} from "../src/BlazePhoenixCore.sol";
import {CoreHarness} from "./mocks/CoreHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV2Pair} from "./mocks/MockV2Pair.sol";
import {MockV2Factory} from "./mocks/MockV2Factory.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

// ─── one-off shapes (house idiom: inline what mocks/ does not have) ──────────

/// @dev Answers ANY selector with `size` bytes of a fixed nonzero pattern.
///      The pattern is nonzero ON PURPOSE: if a returndatasize guard is
///      deleted, the junk lands in the decoded value and the test goes red —
///      an all-zero pattern would let a broken guard pass by luck.
contract ShortAnswerer {
    uint16 internal immutable size;
    constructor(uint16 s) { size = s; }
    fallback() external {
        uint256 s = size;
        assembly {
            mstore(0x00, 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF)
            mstore(0x20, 0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF)
            return(0x00, s)
        }
    }
}

/// @dev Refuses every probe. The "token paused / pool bricked" shape.
contract RevertingProbe {
    fallback() external { revert("PROBE_DOWN"); }
}

/// @dev ERC-20 whose transfer answers with TWO words. Not a valid bool
///      encoding — Core:580's `default { ok := 0 }` must refuse it even
///      though the state change actually happened.
contract OddTransferToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool, bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return (true, true);
    }
}

/// @dev approve() always reverts — Core:627's require arm.
contract RevertingApproveToken {
    function approve(address, uint256) external pure returns (bool) {
        revert("APPROVE_DOWN");
    }
}

/// @dev balanceOf answers THREE words, balance in word 0, junk after — the
///      `>= 32, NOT == 32` policy written into Core:698's own comment.
contract OversizedBalanceToken {
    uint256 internal immutable bal;
    constructor(uint256 b) { bal = b; }
    function balanceOf(address) external view returns (uint256, uint256, uint256) {
        return (bal, type(uint256).max, type(uint256).max);
    }
}

/// @dev balanceOf/decimals that WRITE state: every staticcall to them fails.
///      A non-view balanceOf is named in Core's own comment as a reachable
///      shape of the failed-read defect.
contract NonViewProbeToken {
    uint256 public pokes;
    function balanceOf(address) external returns (uint256) { pokes++; return 1_000e18; }
    function decimals() external returns (uint8) { pokes++; return 6; }
}

/// @dev decimals() answers two words with a PLAUSIBLE value in word 0.
///      Core:750 is strict (== 32): the 6 must NOT be read. If someone
///      relaxes the guard to >= 32, this test reads 6 and goes red.
contract OversizedDecimalsToken {
    function decimals() external pure returns (uint256, uint256) {
        return (6, type(uint256).max);
    }
}

/// @dev Algebra-shaped pool, FULL payload: no slot0(), 7-word globalState()
///      with the dynamic fee in word 2 (Core:947's true arm).
contract AlgebraFullStatePool {
    uint160 internal immutable sp;
    uint16  internal immutable f;
    constructor(uint160 _sp, uint16 _f) { sp = _sp; f = _f; }
    function globalState() external view returns (uint160, int24, uint16, uint16, uint8, uint8, bool) {
        return (sp, 0, f, 0, 0, 0, true);
    }
}

/// @dev Algebra-shaped pool, PARTIAL payload: globalState() answers only two
///      words (64 bytes). Price is readable (Core:946), the fee claim is not
///      (Core:947 false arm) — the split-guard fix this file pins.
contract AlgebraPartialStatePool {
    uint160 internal immutable sp;
    constructor(uint160 _sp) { sp = _sp; }
    function globalState() external view returns (uint160, int24) {
        return (sp, 0);
    }
}

/// @dev Word-store V4 singleton: extsload(bytes32) from a seeded mapping.
contract ReadsV4Manager {
    mapping(bytes32 => bytes32) public slotWord;
    function set(bytes32 s, bytes32 v) external { slotWord[s] = v; }
    function extsload(bytes32 s) external view returns (bytes32) { return slotWord[s]; }
}

/// @dev Word-store V4 singleton, BATCH shape: extsload(bytes32[]) — the
///      selector (0xdbd035ff) and exact ABI the Hub's derive-scan consumes.
contract BatchAnswerV4Manager {
    mapping(bytes32 => bytes32) public slotWord;
    function set(bytes32 s, bytes32 v) external { slotWord[s] = v; }
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) out[i] = slotWord[slots[i]];
    }
}

/// @dev Hostile V4 singleton: answers the batch selector with a payload that
///      is wrong in exactly one way per mode. Core:1669 must discard ALL of
///      it — no partial acceptance.
///        mode 1: abi offset 0x40 instead of 0x20 (size otherwise perfect)
///        mode 2: length field claims n+1 words
///        mode 3: one word short
///        mode 4: one word over
contract HostileBatchV4Manager {
    uint256 internal immutable mode;
    constructor(uint256 m) { mode = m; }
    fallback() external {
        uint256 m_ = mode;
        assembly {
            let n := calldataload(36)
            let off := 0x20
            let len := n
            let cnt := n
            switch m_
            case 1 { off := 0x40 }
            case 2 { len := add(n, 1) }
            case 3 { cnt := sub(n, 1) }
            case 4 { cnt := add(n, 1) }
            mstore(0x00, off)
            mstore(0x20, len)
            for { let i := 0 } lt(i, cnt) { i := add(i, 1) } {
                mstore(add(0x40, shl(5, i)),
                    0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF)
            }
            return(0x00, add(0x40, shl(5, cnt)))
        }
    }
}

/// @dev Algebra factory: exposes poolDeployer() (0x3119049a), the separate
///      CREATE2 origin Core:484 resolves.
contract AlgebraDeployerFactory {
    address internal immutable dep;
    constructor(address d) { dep = d; }
    function poolDeployer() external view returns (address) { return dep; }
}

/// @dev A factory with code but WITHOUT poolDeployer() and without a
///      fallback: the probe reverts and Core must fall back to the factory.
contract NoDeployerFactory {
    function ping() external pure returns (bool) { return true; }
}

/// @dev Factory speaking canonical AND dialect lookups, each settable, so the
///      try-then-fallback order of Core:516/525 is observable: canonical
///      answered -> dialect must NOT win; canonical zero -> dialect must.
contract DialectFactory {
    address public v3Pool;       // getPool(address,address,uint24)  0x1698ee82
    address public algebraPool;  // poolByPair(address,address)      0xd9a641e1
    address public solidlyPool;  // getPool(address,address,bool)    0x79bc57d5
    address public veloPool;     // getPair(address,address,bool)    0x6801cc30
    address public slipPool;     // getPool(address,address,int24)   0x28af8d0b

    function setV3(address p)      external { v3Pool = p; }
    function setAlgebra(address p) external { algebraPool = p; }
    function setSolidly(address p) external { solidlyPool = p; }
    function setVelo(address p)    external { veloPool = p; }
    function setSlip(address p)    external { slipPool = p; }

    function getPool(address, address, uint24) external view returns (address) { return v3Pool; }
    function poolByPair(address, address) external view returns (address) { return algebraPool; }
    function getPool(address, address, bool) external view returns (address) { return solidlyPool; }
    function getPair(address, address, bool) external view returns (address) { return veloPool; }
    function getPool(address, address, int24) external view returns (address) { return slipPool; }
}

// ═════════════════════════════════════════════════════════════════════════════

contract CoreExternalReadsTest is Test {
    CoreHarness harness;

    // Pinned from the house corpus — never magic numbers.
    uint160 constant SQRT_P_1 = 79228162514264337593543950336; // price 1.0
    uint128 constant LIQ      = 1_000_000e18;
    uint24  constant POOL_FEE = 3000;

    /// quoteV3Fee's fail-closed sentinel (Core:1027): any fee >= 1e6 makes
    /// outV3 quote 0, so "unmeasurable" can never price as "free". The value
    /// is a literal in the source; this constant must track it.
    uint24 constant UNQUOTABLE = 0xFFFFFF;

    address constant CODELESS = address(0xC0DE1E55); // provably no code in tests
    address constant HOLDER   = address(0xBEEF);

    function setUp() public {
        harness = new CoreHarness();
    }

    function _create2(address origin, bytes32 salt, bytes32 initHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", origin, salt, initHash)))));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §A  safeTransfer / safeTransferFrom / safeApprove — value moves, so
    //      every ambiguous answer is REFUSED (Core:576-583, 595-602, 627).
    //      All routed through CoreHarness: the library functions inline, and
    //      vm.expectRevert cannot see an inlined revert.
    // ─────────────────────────────────────────────────────────────────────────

    /// Core:578 case 0 with extcodesize == 0. A call to a codeless address
    /// SUCCEEDS with no returndata — the EVM's own absence-is-permission — and
    /// the extcodesize check is the only thing standing between "token never
    /// existed" and "transfer reported fine". Delete it and this stops
    /// reverting: red.
    function test_SafeTransfer_CodelessTokenIsRefused() public {
        vm.expectRevert(bytes("BPC:transfer"));
        harness.safeTransfer(CODELESS, HOLDER, 1e18);
    }

    /// Core:579 case 32 with a zero word. A compliant-but-failing token says
    /// `false` instead of reverting; treating that as success loses the funds
    /// silently. Delete the `gt(mload(0), 0)` arm and this stops reverting.
    function test_SafeTransfer_FalseReturnIsRefused() public {
        MockERC20 t = new MockERC20("F", "F");
        t.setReturnFalseOnFail(true);
        // harness holds nothing, so the transfer fails INSIDE the token and
        // answers false (32 bytes, zero word).
        vm.expectRevert(bytes("BPC:transfer"));
        harness.safeTransfer(address(t), HOLDER, 1e18);
    }

    /// Core:580 default arm. A 64-byte answer is not a bool; for VALUE moves
    /// the policy is strict (contrast balanceOf, §B, which tolerates >= 32 for
    /// a read). The mock even performs the transfer — the refusal is about the
    /// ANSWER being unparseable, not about the state. Delete `default {ok:=0}`
    /// and the call is reported ok: red.
    function test_SafeTransfer_OddSizedAnswerIsRefused() public {
        OddTransferToken t = new OddTransferToken();
        t.mint(address(harness), 10e18);
        vm.expectRevert(bytes("BPC:transfer"));
        harness.safeTransfer(address(t), HOLDER, 1e18);
    }

    /// Core:578 case 0 with code present — the USDT shape, and the one arm in
    /// this family that must SUCCEED: no returndata plus real code is a
    /// well-known compliant-enough token. Deleting the case-0 arm sends the
    /// empty answer into `default` and refuses every USDT-style token: red.
    function test_SafeTransfer_NoReturnDataWithCodeSucceeds() public {
        MockERC20 t = new MockERC20("U", "U");
        t.setNoReturnData(true);
        t.mint(address(harness), 10e18);
        harness.safeTransfer(address(t), HOLDER, 3e18);
        assertEq(t.balanceOf(HOLDER), 3e18, "USDT-shape transfer must deliver");
        assertEq(t.balanceOf(address(harness)), 7e18, "and debit the sender");
    }

    /// Core:597/598 — same three-case discipline on the pull side. Codeless
    /// target and false-return each must revert with the wrapper's own
    /// selector-specific reason, never pass.
    function test_SafeTransferFrom_CodelessAndFalseReturnAreRefused() public {
        vm.expectRevert(bytes("BPC:transferFrom"));
        harness.safeTransferFrom(CODELESS, HOLDER, address(this), 1e18);

        MockERC20 t = new MockERC20("F", "F");
        t.setReturnFalseOnFail(true);
        t.mint(HOLDER, 10e18);
        // no allowance granted to the harness -> token answers false.
        vm.expectRevert(bytes("BPC:transferFrom"));
        harness.safeTransferFrom(address(t), HOLDER, address(this), 1e18);
    }

    /// Core:627 — safeApprove's require arm. An approve that reverts must
    /// surface as "BPC:approve", not be swallowed. Delete the require and the
    /// failed approve is reported fine: red.
    function test_SafeApprove_RevertingTokenIsRefused() public {
        RevertingApproveToken t = new RevertingApproveToken();
        vm.expectRevert(bytes("BPC:approve"));
        harness.safeApprove(address(t), HOLDER, 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §B  balanceOf — the read that feeds every measured delta (Core:689-701).
    //      The revert arm is pinned by BalanceOfFailReadsAsZero.t.sol; these
    //      pin the three arms that file does not touch.
    // ─────────────────────────────────────────────────────────────────────────

    /// Codeless target: staticcall succeeds with NO data -> deliberate zero,
    /// NOT a refusal (Core:698 false arm; the wrapper's comment states the
    /// policy). If someone "hardens" balanceOf to demand returndata, this
    /// goes red — and that would break unset-token probes across the Hub.
    function test_BalanceOf_CodelessIsDeliberateZero_NotARefusal() public view {
        assertEq(harness.balanceOf(CODELESS, HOLDER), 0,
            "codeless target must read as an intentional zero, without reverting");
    }

    /// Core:698's `>= 32, NOT == 32` policy: a token answering three words
    /// still has its balance in word 0, and this reader feeds the measured
    /// floor. Tightening to == 32 (or deleting the read body) returns 0 here:
    /// red either way.
    function test_BalanceOf_OversizedAnswerReadsWordZero() public {
        OversizedBalanceToken t = new OversizedBalanceToken(1_234e18);
        assertEq(harness.balanceOf(address(t), HOLDER), 1_234e18,
            "balance must be read from word 0 of an oversized answer");
    }

    /// A 16-byte answer: succeeded, but not a word. The guard must yield 0 —
    /// NOT the stale memory under the out-buffer. This is the exact stale-mem
    /// hazard the wrapper documents: delete `iszero(lt(returndatasize(), 32))`
    /// and mload(m) reads the 16 junk bytes in the word's high half — a
    /// nonzero garbage balance: red.
    function test_BalanceOf_ShortAnswerReadsZero_NotStaleMemory() public {
        ShortAnswerer t = new ShortAnswerer(16);
        assertEq(harness.balanceOf(address(t), HOLDER), 0,
            "a sub-word answer is not a balance");
    }

    /// A balanceOf that WRITES (fee-collecting, upgrade-counting, hostile)
    /// fails EVERY staticcall — Core's own comment names this shape. It must
    /// surface as a refused read ("BPC:balanceOf"), never as a zero balance:
    /// a zero here turns every Router delta into an absolute balance.
    function test_BalanceOf_NonViewTokenIsARefusedRead() public {
        NonViewProbeToken t = new NonViewProbeToken();
        vm.expectRevert(bytes("BPC:balanceOf"));
        harness.balanceOf(address(t), HOLDER);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §C  getReserves — quote-side read; failure is the (0,0) that downstream
    //      REFUSES to price (Core:717-718).
    // ─────────────────────────────────────────────────────────────────────────

    /// The healthy arm: a real pair's 96-byte answer (uint112,uint112,uint32)
    /// passes the `>= 64` guard and both reserves decode. Delete the read
    /// body and this returns (0,0): red.
    function test_GetReserves_HealthyPairReadsBothWords() public {
        MockV2Pair pair = new MockV2Pair(address(0xA11CE), address(0xB0B));
        pair.setReserves(1_000e18, 2_000e18);
        (uint256 r0, uint256 r1) = BPC.getReserves(address(pair));
        assertEq(r0, 1_000e18, "reserve0");
        assertEq(r1, 2_000e18, "reserve1");
    }

    /// The three failure shapes all read as (0,0), and the zero is a REFUSAL
    /// in quote space, not a price: outV2 with zero reserves quotes 0, so no
    /// swap can be built on a failed reserves read. The short-answer case is
    /// the load-bearing one: delete the `>= 64` guard and the 32 junk bytes
    /// decode as a nonzero reserve0 — red.
    function test_GetReserves_DeadShortOrRevertingPoolIsUnquotable() public {
        (uint256 r0, uint256 r1) = BPC.getReserves(CODELESS);
        assertEq(r0 | r1, 0, "codeless pool has no reserves");

        (r0, r1) = BPC.getReserves(address(new RevertingProbe()));
        assertEq(r0 | r1, 0, "a reverting pool is a failed read, not a value");

        (r0, r1) = BPC.getReserves(address(new ShortAnswerer(32)));
        assertEq(r0 | r1, 0, "one word is not two reserves; junk must not decode");

        // The zero propagates to a refusal, not a trade.
        assertEq(BPC.outV2(1e18, 0, 0, 30), 0,
            "zero reserves must be unquotable downstream");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §D  decimalsOf — strict word, fail-OPEN to 18 (Core:749-765).
    //      The 77/78 boundary and absurd values are pinned by
    //      DecimalsGuardOverflow.t.sol; these are the unreadable SHAPES.
    // ─────────────────────────────────────────────────────────────────────────

    /// Codeless, reverting, and non-view tokens all fall to the documented
    /// default of 18. The oversized case is the sharp one: word 0 carries a
    /// PLAUSIBLE 6, and the strict `eq(returndatasize(), 32)` must refuse to
    /// read it — relax the guard to >= 32 and this reads 6: red. (Contrast
    /// balanceOf's deliberate >= 32 in §B: a balance feeds a delta that
    /// self-checks by underflow; a wrong decimals silently rescales amounts
    /// by orders of magnitude, so only an exact answer counts.)
    function test_Decimals_UnreadableShapesFallToEighteen() public {
        assertEq(BPC.decimalsOf(CODELESS), 18, "codeless: default 18");
        assertEq(BPC.decimalsOf(address(new RevertingProbe())), 18, "reverting: default 18");
        assertEq(BPC.decimalsOf(address(new NonViewProbeToken())), 18,
            "non-view decimals fails every staticcall: default 18");
        assertEq(BPC.decimalsOf(address(new OversizedDecimalsToken())), 18,
            "a 64-byte answer must NOT have its word 0 believed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §E  getLiquidity / getV3Fee / token0Of / token1Of — pool probes
    //      (Core:776-777, 791-792, 1033-1034, 1043-1044).
    // ─────────────────────────────────────────────────────────────────────────

    /// Healthy arms, all four probes against one V3-shaped pool. Deleting any
    /// read body zeroes its assertion: red.
    function test_PoolProbes_HealthyReads() public {
        MockV3Pool pool = new MockV3Pool(address(0xA11CE), address(0xB0B), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        assertEq(BPC.getLiquidity(address(pool)), LIQ, "liquidity()");
        assertEq(BPC.getV3Fee(address(pool)), POOL_FEE, "fee()");
        assertEq(BPC.token0Of(address(pool)), pool.token0(), "token0()");
        assertEq(BPC.token1Of(address(pool)), pool.token1(), "token1()");
    }

    /// Failure arms read 0 — and the fee-zero is NOT free: quoteV3Fee turns
    /// an unmeasurable static fee into the UNQUOTABLE sentinel, and outV3
    /// refuses any fee >= 1e6. This is the chain that stops "absent fee" from
    /// pricing as "no fee" (the night's feeH == 0 class, on the read side).
    /// Short-answer cases go red if the returndata guards are deleted (junk
    /// decodes); the sentinel line goes red if quoteV3Fee's fail-closed arm
    /// is replaced by a pass-through.
    function test_PoolProbes_FailedReadsAreZero_AndFeeFailsClosed() public {
        address dead = address(new RevertingProbe());
        address shorty = address(new ShortAnswerer(16));

        assertEq(BPC.getLiquidity(CODELESS), 0);
        assertEq(BPC.getLiquidity(dead), 0);
        assertEq(BPC.getLiquidity(shorty), 0, "sub-word junk is not liquidity");

        assertEq(BPC.getV3Fee(CODELESS), 0);
        assertEq(BPC.getV3Fee(dead), 0);
        assertEq(BPC.getV3Fee(shorty), 0, "sub-word junk is not a fee");

        assertEq(BPC.token0Of(CODELESS), address(0));
        assertEq(BPC.token0Of(dead), address(0));
        assertEq(BPC.token1Of(CODELESS), address(0));

        // fee unreadable (0) + not dynamic -> UNQUOTABLE, and UNQUOTABLE
        // quotes zero. Absence of a fee is a refusal, never a discount.
        assertEq(BPC.quoteV3Fee(CODELESS, 0, 0, false), UNQUOTABLE,
            "unmeasurable static fee must fail closed to the sentinel");
        assertEq(BPC.outV3(1e18, SQRT_P_1, LIQ, UNQUOTABLE, true, 0), 0,
            "the sentinel must be unquotable in outV3");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §F  v3StateAndDynFee — the two-probe reader whose SPLIT guards are the
    //      fix for a measured divergence (Core:926-947): price needs word 0,
    //      the dyn-fee CLAIM needs the full 96-byte payload.
    // ─────────────────────────────────────────────────────────────────────────

    /// Uniswap shape: slot0 answers, price decodes, dyn stays false and the
    /// fee word stays 0 (the fee lives in fee(), not here). Deleting the
    /// slot0 read body zeroes sp: red.
    function test_V3State_UniswapShape_PricesWithoutDynFlag() public {
        MockV3Pool pool = new MockV3Pool(address(0xA11CE), address(0xB0B), POOL_FEE);
        pool.setState(SQRT_P_1, LIQ);
        (uint160 sp, uint24 f, bool dyn) = BPC.v3StateAndDynFee(address(pool));
        assertEq(sp, SQRT_P_1, "slot0 word 0 is the price");
        assertEq(f, 0, "no dynamic fee was measured");
        assertFalse(dyn, "a slot0 answer is not Algebra");
    }

    /// Algebra shape, full payload: no slot0, globalState answers 7 words ->
    /// price from word 0, fee from word 2, dyn asserted. Deleting the
    /// globalState arm (Core:942-949) zeroes all three: red.
    function test_V3State_AlgebraFullPayload_MeasuresFeeAndAssertsDyn() public {
        AlgebraFullStatePool pool = new AlgebraFullStatePool(SQRT_P_1, 507);
        (uint160 sp, uint24 f, bool dyn) = BPC.v3StateAndDynFee(address(pool));
        assertEq(sp, SQRT_P_1, "globalState word 0 is the price");
        assertEq(f, 507, "globalState word 2 is the measured dynamic fee");
        assertTrue(dyn, "a globalState answer is Algebra-shaped");
    }

    /// Algebra shape, PARTIAL payload (64 bytes): the price is readable and
    /// MUST price (Core:946 — before the split-guard fix this pool read as
    /// dead and the quote/depth registers diverged), but the fee claim MUST
    /// NOT be asserted on a truncated payload (Core:947 false arm) — it falls
    /// through to quoteV3Fee's fail-closed sentinel. Re-merging the guards to
    /// a single >= 96 check zeroes sp: red. Relaxing 947 to assert dyn on 64
    /// bytes flips dyn: red.
    function test_V3State_AlgebraPartialPayload_PricesButNeverAssertsDyn() public {
        AlgebraPartialStatePool pool = new AlgebraPartialStatePool(SQRT_P_1);
        (uint160 sp, uint24 f, bool dyn) = BPC.v3StateAndDynFee(address(pool));
        assertEq(sp, SQRT_P_1, "a partial payload still carries the price in word 0");
        assertEq(f, 0, "no fee word arrived, so none was measured");
        assertFalse(dyn, "dyn must never be asserted on a truncated payload");

        // and the fee side fails closed, exactly as the doc promises:
        assertEq(BPC.quoteV3Fee(address(pool), 0, f, dyn), UNQUOTABLE,
            "partial Algebra answer: price yes, free swap no");
    }

    /// Dead shapes: codeless and reverting pools read all-zero — sp == 0 is
    /// the "not concentrated / unreadable" signal every caller branches on.
    function test_V3State_DeadOrRevertingPoolIsAllZero() public {
        (uint160 sp, uint24 f, bool dyn) = BPC.v3StateAndDynFee(CODELESS);
        assertEq(sp, 0); assertEq(f, 0); assertFalse(dyn);

        (sp, f, dyn) = BPC.v3StateAndDynFee(address(new RevertingProbe()));
        assertEq(sp, 0, "a revert is a failed read, not a price");
        assertEq(f, 0); assertFalse(dyn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §G  v4SqrtAndLiq — direct decode of the two extsload words
    //      (Core:1586, 1597-1598, 1602-1603). The failure arms' DOWNSTREAM
    //      effect (quote 0) is pinned by V4DynamicFeeQuote.t.sol; here the
    //      decode itself is pinned, including tick sign-extension.
    // ─────────────────────────────────────────────────────────────────────────

    function test_V4SqrtAndLiq_DecodesAllFiveFields_NegativeTick() public {
        ReadsV4Manager mgr = new ReadsV4Manager();
        bytes32 pid = keccak256("core-reads:pid-1");
        bytes32 base = keccak256(abi.encode(pid, uint256(6)));

        int24  tickIn  = -887272;
        uint24 lpIn    = 3000;
        uint24 protoIn = 0x123;
        bytes32 word0 = bytes32(
            uint256(SQRT_P_1)
            | (uint256(uint24(tickIn))  << 160)
            | (uint256(protoIn)         << 184)
            | (uint256(lpIn)            << 208)
        );
        mgr.set(base, word0);
        mgr.set(bytes32(uint256(base) + 3), bytes32(uint256(LIQ)));

        (uint160 sp, uint128 lq, uint24 lp, uint24 pf, int24 tk) =
            BPC.v4SqrtAndLiq(address(mgr), pid);
        assertEq(sp, SQRT_P_1, "sqrtPriceX96 = word0 bits [0,160)");
        assertEq(lq, LIQ, "liquidity = word3 low bits");
        assertEq(lp, lpIn, "lpFee = word0 bits [208,232)");
        assertEq(pf, protoIn, "protocolFee = word0 bits [184,208)");
        assertEq(tk, tickIn, "tick decodes SIGNED: 0xF27618 is -887272, not 15889944");

        // Strict word policy (== 32): a sub-word answer is nothing. Delete
        // the eq guard and 16 junk bytes glue to the stale slot-key bytes in
        // the buffer -> nonzero sp: red.
        (sp, lq, lp, pf, tk) = BPC.v4SqrtAndLiq(address(new ShortAnswerer(16)), pid);
        assertEq(sp, 0, "sub-word extsload answer must read as uninitialized");
        assertEq(lq, 0);

        // GAS-ONLY GUARD, stated honestly: the manager == 0 early return
        // (Core:1586) has the same observable as the codeless-refusal path,
        // so this assertion does NOT go red if that branch is deleted — it
        // pins the contract's shape, the branch saves two staticcalls.
        (sp, lq, lp, pf, tk) = BPC.v4SqrtAndLiq(address(0), pid);
        assertEq(sp, 0); assertEq(lq, 0); assertEq(lp, 0); assertEq(pf, 0); assertEq(tk, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §H  v4Slot0Batch — the ONLY consumer-facing reader with NO local test
    //      anywhere in the suite (fork-only until now). Core:1645, 1668-1676.
    //      The Hub's derive-scan admits candidate tiers on these words: a
    //      malformed answer accepted here would make junk look like an
    //      initialized pool.
    // ─────────────────────────────────────────────────────────────────────────

    function _pids3() internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](3);
        ids[0] = keccak256("core-reads:batch-0");
        ids[1] = keccak256("core-reads:batch-1");
        ids[2] = keccak256("core-reads:batch-2");
    }

    /// Healthy batch: each pid's word comes back in order; an unseeded pid
    /// reads zero (uninitialized — the filter signal the scan relies on).
    /// Deleting the guarded copy loop zeroes everything: red.
    function test_V4Batch_HealthyBatchMatchesSeededWords() public {
        BatchAnswerV4Manager mgr = new BatchAnswerV4Manager();
        bytes32[] memory ids = _pids3();
        bytes32 w0 = bytes32(uint256(SQRT_P_1));
        bytes32 w2 = bytes32(uint256(12345));
        mgr.set(keccak256(abi.encode(ids[0], uint256(6))), w0);
        // ids[1] left unseeded on purpose.
        mgr.set(keccak256(abi.encode(ids[2], uint256(6))), w2);

        bytes32[] memory out = BPC.v4Slot0Batch(address(mgr), ids);
        assertEq(out.length, 3);
        assertEq(out[0], w0, "seeded word must round-trip in position");
        assertEq(out[1], bytes32(0), "unseeded pid reads uninitialized");
        assertEq(out[2], w2, "order is preserved");
    }

    /// Core:1669 — the three-way ABI check (exact size, offset 0x20, length
    /// == n) must discard a malformed answer WHOLESALE. Four hostile shapes,
    /// each wrong in exactly one way; each must yield the all-zero array.
    /// Delete any leg of the check and its mode copies junk words out: red.
    function test_V4Batch_MalformedAnswersAreDiscardedWholesale() public {
        bytes32[] memory ids = _pids3();
        string[4] memory why = [
            "wrong abi offset (0x40) must be refused even at the perfect size",
            "a length field claiming n+1 words must be refused",
            "an answer one word short must be refused",
            "an answer one word over must be refused"
        ];
        for (uint256 mode = 1; mode <= 4; ++mode) {
            HostileBatchV4Manager mgr = new HostileBatchV4Manager(mode);
            bytes32[] memory out = BPC.v4Slot0Batch(address(mgr), ids);
            assertEq(out.length, 3);
            for (uint256 i; i < 3; ++i) {
                assertEq(out[i], bytes32(0), why[mode - 1]);
            }
        }
    }

    /// Edges: empty id set and zero manager. GAS-ONLY GUARD, stated honestly:
    /// Core:1645's early return has the same observable as letting the
    /// assembly refuse (a zero/codeless manager answers nothing), so these
    /// assertions do not go red if that branch is deleted — they pin the
    /// shape (length preserved, all zeros), the branch saves the call.
    function test_V4Batch_EmptyAndZeroManagerYieldZeros() public {
        BatchAnswerV4Manager mgr = new BatchAnswerV4Manager();
        bytes32[] memory none = new bytes32[](0);
        assertEq(BPC.v4Slot0Batch(address(mgr), none).length, 0, "empty in, empty out");

        bytes32[] memory ids = _pids3();
        bytes32[] memory out = BPC.v4Slot0Batch(address(0), ids);
        assertEq(out.length, 3, "length is preserved even with no manager");
        for (uint256 i; i < 3; ++i) assertEq(out[i], bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  §I  deriveAddress's reads — poolDeployer resolution (Core:466-484) and
    //      the factory-lookup dialects (Core:497-539). These are the reads
    //      that decide WHICH ADDRESS the protocol treats as the pool.
    // ─────────────────────────────────────────────────────────────────────────

    address constant TA = address(0xAAA1);
    address constant TB = address(0xBBB1); // TA < TB, so t0 = TA
    bytes32 constant INIT_HASH = keccak256("core-reads:init-code-hash");

    /// Algebra (mode 5, fee == 0): the factory's poolDeployer() answer BECOMES
    /// the CREATE2 origin — delete Core:468 or the read at 484 and the derived
    /// address silently reverts to the factory origin: red. And the gate is
    /// exactly `fee == 0`: the SAME factory with a static fee must NOT have
    /// its deployer consulted (Core:466 false arm) — widen the gate and the
    /// static-fee expectation breaks: red.
    function test_DeriveAlgebra_DeployerBecomesOrigin_StaticFeeDoesNot() public {
        address dep = address(0xDE9107E4);
        AlgebraDeployerFactory fac = new AlgebraDeployerFactory(dep);

        address got = BPC.deriveAddress(address(fac), TA, TB, 0, false, 0, 5, INIT_HASH);
        assertEq(got, _create2(dep, keccak256(abi.encode(TA, TB)), INIT_HASH),
            "algebra derive must originate from poolDeployer(), not the factory");

        uint24 fee_ = POOL_FEE;
        got = BPC.deriveAddress(address(fac), TA, TB, fee_, false, 0, 5, INIT_HASH);
        assertEq(got, _create2(address(fac), keccak256(abi.encode(TA, TB, fee_)), INIT_HASH),
            "a static-fee V3 in the same slot derives from the factory itself");
    }

    /// The refusal arms of the poolDeployer probe: a factory WITHOUT the
    /// selector (probe reverts) and a factory answering a NON-WORD (20 junk
    /// bytes) must both fall back to the factory origin. The 20-byte case is
    /// the guard test: delete `eq(returndatasize(), 32)` at Core:484 and the
    /// junk bytes land inside the masked address -> a garbage origin -> a
    /// different derived address: red.
    function test_DeriveAlgebra_UnreadableDeployerFallsBackToFactory() public {
        bytes32 saltAlg = keccak256(abi.encode(TA, TB));

        NoDeployerFactory plain = new NoDeployerFactory();
        assertEq(
            BPC.deriveAddress(address(plain), TA, TB, 0, false, 0, 5, INIT_HASH),
            _create2(address(plain), saltAlg, INIT_HASH),
            "no poolDeployer() -> the factory is the origin"
        );

        ShortAnswerer odd = new ShortAnswerer(20);
        assertEq(
            BPC.deriveAddress(address(odd), TA, TB, 0, false, 0, 5, INIT_HASH),
            _create2(address(odd), saltAlg, INIT_HASH),
            "a 20-byte poolDeployer answer is not an address -> factory origin"
        );
    }

    /// The dialect fallbacks are ordered reads: canonical first, dialect only
    /// on a zero answer (Core:516/525). Both directions pinned per mode —
    /// delete a fallback and its zero-canonical case returns address(0): red;
    /// delete the `pool == address(0)` condition and the dialect OVERWRITES a
    /// canonical answer: red.
    function test_FactoryLookup_CanonicalFirstDialectSecond() public {
        DialectFactory fac = new DialectFactory();
        address P0 = address(0xF00D01);
        address P1 = address(0xF00D02);
        address P2 = address(0xF00D03);

        // mode 1 (V3 family): canonical silent -> Algebra's poolByPair wins.
        fac.setAlgebra(P1);
        assertEq(BPC.deriveAddress(address(fac), TA, TB, POOL_FEE, false, 0, 1, bytes32(0)), P1,
            "poolByPair fallback must be consulted when getPool answers zero");

        // canonical answers -> the dialect must NOT win.
        fac.setV3(P0);
        assertEq(BPC.deriveAddress(address(fac), TA, TB, POOL_FEE, false, 0, 1, bytes32(0)), P0,
            "a canonical answer must never be overwritten by the dialect");

        // mode 2 (Solidly family): canonical silent -> Velodrome V1's
        // getPair(a,b,bool) wins — the shape the OP census MEASURED
        // (getPool reverts, getPair answers the live pair).
        fac.setVelo(P2);
        assertEq(BPC.deriveAddress(address(fac), TA, TB, 0, true, 0, 2, bytes32(0)), P2,
            "getPair(bool) fallback must be consulted when getPool answers zero");

        fac.setSolidly(P0);
        assertEq(BPC.deriveAddress(address(fac), TA, TB, 0, true, 0, 2, bytes32(0)), P0,
            "canonical Solidly answer wins over the V1 dialect");

        // modes 0 and 3 dispatch (Core:498/508): one healthy lookup each.
        MockV2Factory v2fac = new MockV2Factory();
        v2fac.setPair(TA, TB, P1);
        assertEq(BPC.deriveAddress(address(v2fac), TA, TB, 0, false, 0, 0, bytes32(0)), P1,
            "mode 0 asks getPair(address,address)");

        fac.setSlip(P2);
        assertEq(BPC.deriveAddress(address(fac), TA, TB, 0, false, 60, 3, bytes32(0)), P2,
            "mode 3 asks getPool(address,address,int24)");
    }

    /// _askPool's refusal arms (Core:538): a codeless factory and a factory
    /// answering 20 raw bytes must both yield address(0) — the zero the Hub's
    /// hasCode guard then discards. Delete the `eq(returndatasize(), 32)`
    /// guard and the 20 junk bytes decode into a nonzero "pool": red.
    function test_FactoryLookup_DeadOrShortFactoryYieldsZeroPool() public {
        for (uint8 mode = 0; mode < 4; ++mode) {
            assertEq(
                BPC.deriveAddress(CODELESS, TA, TB, POOL_FEE, false, 60, mode, bytes32(0)),
                address(0),
                "a codeless factory answers no lookup in any mode"
            );
        }
        ShortAnswerer odd = new ShortAnswerer(20);
        assertEq(
            BPC.deriveAddress(address(odd), TA, TB, 0, false, 0, 0, bytes32(0)),
            address(0),
            "20 raw bytes are not a pool address"
        );
    }
}
