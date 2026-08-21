// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixHub} from "../../src/BlazePhoenixHub.sol";
import {BlazePhoenixRouter} from "../../src/BlazePhoenixRouter.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../../src/BlazePhoenixCore.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IERC20Min {
    function transfer(address to, uint256 amt) external returns (bool);
    function transferFrom(address from, address to, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @notice A "Curve-shaped" pool that satisfies every check `_execCurveAmt`
///         performs, while NEVER consuming the allowance the Router grants it.
///
///         `_execCurveAmt` verifies the RESULT (a tokenOut balance delta), not
///         that the pool pulled its input. So a pool that simply hands over
///         tokenOut from its own stock completes the swap successfully — and
///         the `forceApprove(tokenIn, leg.pool, amt)` issued moments earlier is
///         never spent, never reset.
///
///         This is the shape of the Dexible / LI.FI / Kame class: an
///         attacker-supplied address that the router treats as a venue.
contract PassiveCurvePool {
    address public immutable t0;
    address public immutable t1;
    uint256 public payout;

    constructor(address a, address b) { (t0, t1) = (a, b); }

    function setPayout(uint256 p) external { payout = p; }

    /// @dev `curveResolveIndices` walks coins(0..7) to map tokens to indices.
    function coins(uint256 k) external view returns (address) {
        if (k == 0) return t0;
        if (k == 1) return t1;
        return address(0);
    }

    /// @dev The int128 signature the Router tries first. Pays tokenOut out of
    ///      our own stock and pulls NOTHING — the approval survives untouched.
    function exchange(int128, int128 j, uint256, uint256) external returns (uint256) {
        address out = j == int128(0) ? t0 : t1;
        IERC20Min(out).transfer(msg.sender, payout);
        return payout;
    }
}

/// @notice HUNT / ALVO #1 — does an arbitrary, caller-supplied `leg.pool`
///         retain a standing ERC-20 allowance from the Router after the swap?
///
///         Chain under test (verified by reading the source, 2026-08-19):
///           1. `BlazePhoenixRouter._execCurveAmt` calls
///              `BPC.forceApprove(tokenIn, leg.pool, amt)` — and `leg.pool`
///              comes straight from the caller's `Route`, never validated
///              against the Hub registry anywhere in the execution path.
///           2. `BlazePhoenixCore.forceApprove` SETS the allowance and never
///              restores it to zero; `_execCurveAmt` never zeroes it either.
///           3. The raw `.call` tolerates failure by design (success is judged
///              by the tokenOut delta), so a pool that pays out without pulling
///              still completes the transaction.
///
///         If the allowance survives, any balance that later sits in the Router
///         — FoT dust, rounding residue, an accidental transfer, or funds
///         awaiting the 48h `executeRescue` timelock — is drainable by the
///         attacker's contract at leisure.
contract ResidualApprovalTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    PassiveCurvePool evil;

    address treasury1 = address(0xFEE1);
    address treasury2 = address(0xFEE2);
    address user      = address(0xBEEF);
    address attacker  = address(0xBAD);

    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant PAYOUT    = 900e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tokenIn  = new MockERC20("In",  "IN");
        tokenOut = new MockERC20("Out", "OUT");
        evil = new PassiveCurvePool(address(tokenIn), address(tokenOut));

        router = new BlazePhoenixRouter(
            address(hub), address(0xCAFE), address(this), treasury1, treasury2
        );

        // The attacker's "pool" is stocked with tokenOut so it can pay the
        // Router without ever touching the allowance it was granted.
        tokenOut.mint(address(evil), 10_000e18);
        evil.setPayout(PAYOUT);

        tokenIn.mint(user, 10_000e18);
        vm.prank(user);
        tokenIn.approve(address(router), type(uint256).max);
    }

    function _route(uint8 kind) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(evil), hooks: address(0), kind: kind, fee: 0,
            tickSpacing: 0, zeroForOne: address(tokenIn) < address(tokenOut),
            stable: true, amountIn: AMOUNT_IN, expectedOut: PAYOUT,
            auxId: bytes32(uint256(uint160(address(tokenOut))))   // tokenOut carried in auxId
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tokenIn), tokenOut: address(tokenOut),
            amountIn: AMOUNT_IN, expectedOut: PAYOUT, legs: legs
        });
        r = Route({
            hops: hops, totalOut: PAYOUT, singleOut: PAYOUT,
            singleOutFloor: 0, expectedImpactBps: 0, confidenceWad: 0,
            estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// @notice THE RED TEST. After a swap routed through an attacker-supplied
    ///         address, the Router must hold no standing allowance to it.
    // ═══════════════════════════════════════════════════════════════════════════════════
    //  REESCRITO EM 2026-08-20 — A SUPERFICIE FOI EXCISADA, A PROPRIEDADE FICA
    //
    //  O HUNT-001 vivia em `Router._execCurveAmt`, o UNICO sitio de todo o Router/Hub/Solver que
    //  concedia uma allowance. Com a excisao do Curve/Balancer (decisao do dono: quase nenhuma L2
    //  os tem) essa funcao deixou de existir, e com ela o vetor inteiro.
    //
    //  O PERIGO NAO E O CORTE — E O QUE SE PERDE NELE. Sem estes testes, "o Router nao deixa
    //  allowances de pe" passaria de FACTO TESTADO a ACIDENTE de ninguem chamar approve. O
    //  primeiro integrador que reintroduzisse um (um adaptador, um permit2 de saida) recuperava a
    //  vulnerabilidade sem ninguem ficar vermelho.
    //
    //  A PROPRIEDADE FICA GUARDADA EM DOIS SITIOS, e ambos sao mais fortes que o teste original:
    //    1. a guarda estatica do CI ("Router grants no allowance") — proibe o SIMBOLO, nao o bug;
    //       passa de "esta allowance e segura" para "nao existem allowances".
    //    2. estes testes, que agora provam que a rota do ataque REVERTE em vez de executar.
    //  O mock PassiveCurvePool fica de proposito: e a testemunha de que o ataque era real.
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_ResidualApproval_MustNotSurvive() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(2 /* lapide */), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 residual = IERC20Min(address(tokenIn)).allowance(address(router), address(evil));
        emit log_named_uint("residual allowance (wei)", residual);
        assertEq(residual, 0, "ACHADO: allowance residual do Router para endereco arbitrario");
    }

    /// @notice Severity probe: IF the allowance survives, is it drainable?
    ///         Funds do land in the Router — the existence of the
    ///         queueRescue/executeRescue 48h timelock is the protocol's own
    ///         admission of it.
    function test_ResidualApproval_IsDrainable() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(2 /* lapide */), AMOUNT_IN, 1, user, block.timestamp + 1);

        uint256 residual = IERC20Min(address(tokenIn)).allowance(address(router), address(evil));
        if (residual == 0) return;   // no residual => nothing to drain; the test above is the verdict

        // Simulate funds sitting in the Router (dust / stuck / awaiting rescue).
        uint256 stuck = 500e18;
        tokenIn.mint(address(router), stuck);

        uint256 before = tokenIn.balanceOf(attacker);
        vm.prank(address(evil));
        IERC20Min(address(tokenIn)).transferFrom(address(router), attacker, stuck);
        uint256 stolen = tokenIn.balanceOf(attacker) - before;

        emit log_named_uint("DRENADO pelo atacante (wei)", stolen);
        assertEq(stolen, 0, "CRITICAL: fundos do Router drenados via allowance residual");
    }

    /// @notice Same question through KIND_CURVE_CRYPTO, the sibling arm of the
    ///         very same dispatch (`k == KIND_STABLE || k == KIND_CURVE_CRYPTO`).
    ///         Lei III: a defect on one arm is a defect on its twin.
    function test_ResidualApproval_CurveCryptoArm() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(BlazePhoenixRouter.RouterE.selector, uint16(8)));
        router.swapExactIn(_route(7 /* lapide */), AMOUNT_IN, 1, user, block.timestamp + 1);

        assertEq(
            IERC20Min(address(tokenIn)).allowance(address(router), address(evil)), 0,
            "ACHADO: allowance residual tambem no arm KIND_CURVE_CRYPTO"
        );
    }
}
