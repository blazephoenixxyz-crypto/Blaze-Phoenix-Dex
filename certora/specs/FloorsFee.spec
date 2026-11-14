/*
 * Certora CVL - floors and the protocol fee (pure arithmetic the Router enforces).
 * Target: certora/harness/FloorsFeeHarness.sol (see its header for the cited Router lines).
 * Mirrors test/formal/CompositionFormalSpec.t.sol, CoreFormalGateSpec.t.sol and
 * SolverBandFeeDustFormalSpec.t.sol (Halmos), and adds the monotonicity of each floor.
 */

methods {
    function BPS() external returns (uint256) envfree;
    function PROTOCOL_FEE_BPS() external returns (uint256) envfree;
    function LEG_FLOOR_BPS() external returns (uint256) envfree;
    function FLOOR_BASE_BPS() external returns (uint256) envfree;
    function FLOOR_HARD_MAX_LOSS_BPS() external returns (uint256) envfree;
    function ironFloorBpsShv(uint256, uint256, uint256) external returns (uint256) envfree;
    function ironFloorBps(uint256, uint256, uint256) external returns (uint256) envfree;
    function legFloor(uint256) external returns (uint256) envfree;
    function hopSlack(uint256, uint256) external returns (uint256) envfree;
    function protocolFee(uint256) external returns (uint256) envfree;
}

// ---------------------------------------------------------------- constants (owner numbers)

/// The constants the predicates below are written against. Changing a NUMBER is the
/// owner's call; this rule makes the change visible instead of silent.
rule constantsArePinned() {
    assert BPS() == 10000;
    assert PROTOCOL_FEE_BPS() == 28;
    assert LEG_FLOOR_BPS() == 8000;
    assert FLOOR_BASE_BPS() == 9600;
    assert FLOOR_HARD_MAX_LOSS_BPS() == 2000;
}

// ---------------------------------------------------------------- protocol fee (28 bps)

/// The fee is the CEILING of base * 28 / 1e4: never under-charges, never exceeds the
/// ceiling by a wei, so no route pays more than 28 bps rounded up to one wei.
rule protocolFeeIsCeilOf28Bps(uint256 base) {
    require base <= max_uint128;
    mathint f = protocolFee(base);
    assert f * 10000 >= base * 28;
    assert f * 10000 < base * 28 + 10000;
}

/// A non-zero base always pays, and from 2 wei up the fee never swallows the base.
rule protocolFeePaysAndNeverSwallows(uint256 base) {
    require base <= max_uint128;
    mathint f = protocolFee(base);
    assert base > 0 => f > 0;
    assert base >= 2 => f < to_mathint(base);
}

/// More base never pays a smaller fee.
rule protocolFeeMonotone(uint256 a, uint256 b) {
    require a <= b && b <= max_uint128;
    assert protocolFee(a) <= protocolFee(b);
}

// ---------------------------------------------------------------- per-leg floor (80%, ceil)

/// The per-leg floor is the strict ceiling of 80% of the bound, and never above the bound.
rule legFloorIsCeil80(uint256 bound) {
    require bound <= max_uint128;
    mathint fl = legFloor(bound);
    assert fl * 10000 >= bound * 8000;
    assert (fl - 1) * 10000 < bound * 8000;
    assert fl <= to_mathint(bound);
}

/// A larger bound never lowers the leg floor (monotone against the caller: inflating
/// the attested bound only raises the bar the leg must clear).
rule legFloorMonotone(uint256 b1, uint256 b2) {
    require b1 <= b2 && b2 <= max_uint128;
    assert legFloor(b1) <= legFloor(b2);
}

// ---------------------------------------------------------------- hop slack (one average leg)

/// At n == 1 the hop rule is EQUIVALENT to the per-leg floor, over all inputs.
rule hopRuleCollapsesToLegFloorAtN1(uint256 got, uint256 hopBound) {
    require got <= max_uint128 && hopBound <= max_uint128;
    mathint slack = hopSlack(hopBound, 1);
    assert (got + slack >= to_mathint(hopBound)) <=> (to_mathint(got) >= to_mathint(legFloor(hopBound)));
}

/// The slack never exceeds what ONE average leg could legitimately lose.
rule hopSlackNeverExceedsOneAverageLeg(uint256 hopBound, uint256 n) {
    require hopBound <= max_uint128;
    require n >= 1 && n <= 255;
    mathint slack = hopSlack(hopBound, n);
    assert slack * 10000 <= hopBound * 2000;
    // per leg: n legs together never get more than (BPS - LEG_FLOOR_BPS) of the hop bound
    assert slack * 10000 * n <= hopBound * 2000;
}

/// Adding legs can only tighten the budget (an attacker who adds legs never loosens it).
rule moreLegsNeverLoosensHopSlack(uint256 hopBound, uint256 n1, uint256 n2) {
    require hopBound <= max_uint128;
    require n1 >= 1 && n1 <= n2 && n2 <= 255;
    assert hopSlack(hopBound, n2) <= hopSlack(hopBound, n1);
}

/// A larger hop bound never lowers the bar `hopBound - slack` the hop must clear.
rule hopBarMonotoneInBound(uint256 h1, uint256 h2, uint256 n) {
    require h1 <= h2 && h2 <= max_uint128;
    require n >= 1 && n <= 255;
    assert h1 - hopSlack(h1, n) <= h2 - hopSlack(h2, n);
}

// ---------------------------------------------------------------- iron floor (aggregate)

/// INV-1 bounds, unconditional over all inputs (the unchecked block included):
/// 80% <= floorBps <= 96%.
rule ironFloorBounds(uint256 impactBps, uint256 legShv, uint256 sigmaLn) {
    mathint f = ironFloorBpsShv(impactBps, legShv, sigmaLn);
    assert f >= 8000;
    assert f <= 9600;
}

/// More impact, more leg shave or more sigma never raises the floor: the floor (bps of
/// the measured bound the caller must receive) is monotone non-increasing in each shave. The producers keep each
/// shave far below 2^128 (bps-scaled mulDiv results; sigma / 1e14); the require states
/// that range so the unchecked sum cannot wrap.
rule ironFloorMonotoneInShaves(uint256 i1, uint256 i2, uint256 l1, uint256 l2, uint256 s1, uint256 s2) {
    require i1 <= i2 && l1 <= l2 && s1 <= s2;
    require l2 <= max_uint128 && s2 <= max_uint128;
    assert ironFloorBpsShv(i2, l2, s2) <= ironFloorBpsShv(i1, l1, s1);
}

/// The count form never sits outside the same bounds.
rule ironFloorCountFormBounds(uint256 impactBps, uint256 legCount, uint256 sigmaLn) {
    require legCount <= 255;
    mathint f = ironFloorBps(impactBps, legCount, sigmaLn);
    assert f >= 8000 && f <= 9600;
}
