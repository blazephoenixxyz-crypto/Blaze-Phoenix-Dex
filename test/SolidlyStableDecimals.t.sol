// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// E2 — A QUOTE SOLIDLY TEM TRES PRODUTORES COM TRES POLITICAS.
//
// A mesma grandeza — "quanto e que esta pool devolve por este input" — e produzida em tres
// sitios do protocolo, e os tres discordam:
//
//   sitio                          primario              decimais   haircut   gatilho fallback
//   Core.universalQuote            solidlyGetAmountOut      SIM        SIM      out == 0
//   Router._solidlyLegQuote        idem                     NAO        NAO      quote == 0
//   Router._execSolidlyAmt         idem                     NAO        SIM      outAmt <= 1
//
// No caminho PRIMARIO os tres fazem a MESMA chamada ao MESMO pool, portanto concordam por
// construcao. A divergencia vive toda no FALLBACK — a via que so corre em forks sem
// `getAmountOut`. E ai o Core normaliza decimais e os dois do Router nao.
//
// PORQUE ISTO IMPORTA. O invariante stable e k = x3y + xy3, homogeneo de grau 4: com reservas na
// MESMA escala o resultado e invariante a escala e nao e preciso normalizar nada — e o proprio
// `outSolidly` que o diz, e por isso passa (0,0). Com decimais DIFERENTES (18/6) as reservas
// cruas estao a 12 ordens de grandeza uma da outra e a curva devolve lixo.
//
// A SEVERIDADE HONESTA: falha FECHADA nos dois sentidos. Se a quote inflaciona, o pedido do exec
// rebenta no K-check do proprio par antes de qualquer piso importar; se deflaciona, entrega-se a
// menos. Nao e caminho de perda de fundos — e LIVENESS: um par legitimo fica sem porta.
// E e um caso de NICHO, porque todo o fork Solidly relevante (Velodrome, Aerodrome, Thena,
// Ramses) expoe `getAmountOut`. Entra por ser a assinatura de defeito da casa com N=3, nao por
// ser urgente.
//
// O QUE NAO SE UNIFICA, e e a parte subtil: o HAIRCUT de 200 bps NAO deve viajar para o canal de
// COTACAO do Router. O Core diz para que serve — "under-ask by 200 bps so the pool's K rounding,
// which we cannot observe, always has slack": e margem de um PEDIDO, nao de um PISO. Aplica-lo a
// cotacao deflacionaria `qs` no portao de cobertura, a base da fee e o `hopAttested`. Politica
// unica aqui significa uma unica CURVA, nao um unico conjunto de ajustes.

import {Test} from "forge-std/Test.sol";
import {BlazePhoenixRouter} from "../src/BlazePhoenixRouter.sol";
import {BlazePhoenixHub} from "../src/BlazePhoenixHub.sol";
import {BlazePhoenixCore as BPC, Route, Hop, Leg} from "../src/BlazePhoenixCore.sol";

/// @notice ERC20 com decimais configuraveis — o MockERC20 partilhado tem `decimals` constante.
contract DecToken {
    string public name; string public symbol; uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name=n; symbol=s; decimals=d; }
    function mint(address to, uint256 a) external { totalSupply += a; balanceOf[to] += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp]=a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { return _mv(msg.sender,to,a); }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        return _mv(f,to,a);
    }
    function _mv(address f, address t, uint256 a) private returns (bool) {
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @notice Par Solidly STABLE que impoe o K REAL — normalizado pelos decimais, como um
///         Velodrome/Aerodrome faz internamente. E essa normalizacao interna que torna a
///         ausencia dela no cotador do Router num erro observavel: o par sabe os decimais,
///         quem lhe pede nao.
contract StablePairK {
    address public token0; address public token1;
    uint112 public reserve0; uint112 public reserve1;
    uint256 public dec0; uint256 public dec1;
    bool public constant stable = true;
    uint256 public feeBps = 5;               // stables cobram pouco
    bool public hideGetAmountOut;            // simula um fork sem a funcao

    constructor(address a, address b, uint8 da, uint8 db) {
        if (a < b) { (token0, token1) = (a, b); (dec0, dec1) = (10**da, 10**db); }
        else       { (token0, token1) = (b, a); (dec0, dec1) = (10**db, 10**da); }
    }
    function setReserves(uint112 r0, uint112 r1) external { reserve0=r0; reserve1=r1; }
    function setHideGetAmountOut(bool b) external { hideGetAmountOut = b; }
    function getReserves() external view returns (uint112,uint112,uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    function _k(uint256 x, uint256 y) internal view returns (uint256) {
        uint256 _x = (x * 1e18) / dec0;
        uint256 _y = (y * 1e18) / dec1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18) + ((_y * _y) / 1e18);
        return (_a * _b) / 1e18;             // x3y + y3x
    }

    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256) {
        if (hideGetAmountOut) return 0;
        uint256 aIn = amountIn - (amountIn * feeBps) / 10_000;
        (uint256 rI, uint256 rO) = tokenIn == token0
            ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        return _getY(aIn, rI, rO, tokenIn == token0);
    }

    /// Newton sobre o invariante normalizado — a mesma forma do par real.
    function _getY(uint256 aIn, uint256 rI, uint256 rO, bool zfo) internal view returns (uint256) {
        uint256 dI = zfo ? dec0 : dec1;
        uint256 dO = zfo ? dec1 : dec0;
        uint256 xy = _kn((rI * 1e18) / dI, (rO * 1e18) / dO);
        uint256 x  = (rI * 1e18) / dI + (aIn * 1e18) / dI;
        uint256 y  = (rO * 1e18) / dO;
        uint256 yn = y;
        for (uint256 i; i < 255; i++) {
            uint256 k = _kn(x, yn);
            uint256 dy;
            if (k < xy) { dy = ((xy - k) * 1e18) / _dk(x, yn); yn += dy; }
            else        { dy = ((k - xy) * 1e18) / _dk(x, yn); if (dy > yn) break; yn -= dy; }
            if (dy <= 1) break;
        }
        if (yn >= y) return 0;
        return ((y - yn) * dO) / 1e18;
    }
    function _kn(uint256 x, uint256 y) internal pure returns (uint256) {
        uint256 a = (x * y) / 1e18;
        uint256 b = ((x * x) / 1e18) + ((y * y) / 1e18);
        return (a * b) / 1e18;
    }
    function _dk(uint256 x, uint256 y) internal pure returns (uint256) {
        return (3 * x * ((y * y) / 1e18)) / 1e18 + ((((x * x) / 1e18) * x) / 1e18);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        uint256 k0 = _k(reserve0, reserve1);
        if (amount0Out > 0) DecToken(token0).transfer(to, amount0Out);
        if (amount1Out > 0) DecToken(token1).transfer(to, amount1Out);
        uint256 b0 = DecToken(token0).balanceOf(address(this));
        uint256 b1 = DecToken(token1).balanceOf(address(this));
        require(_k(b0, b1) >= k0, "StablePairK: K");
        reserve0 = uint112(b0); reserve1 = uint112(b1);
    }
}

contract SolidlyStableDecimalsTest is Test {
    BlazePhoenixHub hub;
    BlazePhoenixRouter router;
    DecToken tA;    // 18 decimais
    DecToken tB;    //  6 decimais
    StablePairK pair;

    address user = address(0x5E4);
    uint256 constant AMOUNT_IN = 1_000e18;

    function setUp() public {
        hub = new BlazePhoenixHub(address(this));
        tA  = new DecToken("A18", "A18", 18);
        tB  = new DecToken("B6",  "B6",   6);
        pair = new StablePairK(address(tA), address(tB), 18, 6);
        router = new BlazePhoenixRouter(
            address(hub), address(0xBEEF), address(this), address(0x7451), address(0x7452)
        );
        tA.mint(address(pair), 1_000_000e18);
        tB.mint(address(pair), 1_000_000e6);
        pair.setReserves(
            address(tA) < address(tB) ? uint112(1_000_000e18) : uint112(1_000_000e6),
            address(tA) < address(tB) ? uint112(1_000_000e6)  : uint112(1_000_000e18)
        );
        tA.mint(user, 10_000e18);
        vm.prank(user);
        tA.approve(address(router), type(uint256).max);
    }

    function _route(uint256 expectedOut) private view returns (Route memory r) {
        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg({
            pool: address(pair), hooks: address(0), kind: BPC.KIND_SOLIDLY, fee: 5,
            tickSpacing: 0, zeroForOne: address(tA) < address(tB),
            stable: true, amountIn: AMOUNT_IN, expectedOut: expectedOut, auxId: bytes32(0)
        });
        Hop[] memory hops = new Hop[](1);
        hops[0] = Hop({
            tokenIn: address(tA), tokenOut: address(tB),
            amountIn: AMOUNT_IN, expectedOut: expectedOut, legs: legs
        });
        r = Route({
            hops: hops, totalOut: expectedOut, singleOut: expectedOut, singleOutFloor: 0,
            expectedImpactBps: 0, confidenceWad: 0, estGas: 0, hasSurplus: false, isV4Bundle: false
        });
    }

    /// ANTI-REGRESSAO: com `getAmountOut` disponivel os tres produtores fazem a MESMA chamada,
    /// logo concordam por construcao. Este e o caminho de TODO o fork relevante, e tem de
    /// continuar a liquidar antes e depois do fix. E tambem a prova de que o mock esta certo.
    function test_PrimaryPath_WithGetAmountOut_Settles() public {
        uint256 q = pair.getAmountOut(AMOUNT_IN, address(tA));
        assertGt(q, 900e6, "o mock tem de cotar ~1000 unidades de 6 decimais");
        vm.prank(user);
        uint256 out = router.swapExactIn(_route(q), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, 900e6, "o caminho primario tem de liquidar");
    }

    /// O QUE ESTA VERMELHO. Fork sem `getAmountOut`: os dois canais do Router caem no fallback e
    /// avaliam a curva stable com reservas CRUAS (1e24 contra 1e12). Uma rota perfeitamente
    /// legitima fica sem porta.
    function test_FallbackPath_UnequalDecimals_MustStillSettle() public {
        uint256 honest = pair.getAmountOut(AMOUNT_IN, address(tA));   // a verdade, antes de esconder
        pair.setHideGetAmountOut(true);
        vm.prank(user);
        uint256 out = router.swapExactIn(_route(honest), AMOUNT_IN, 1, user, block.timestamp + 1);
        assertGt(out, (honest * 8_000) / 10_000, "o fallback tem de ficar dentro do piso da perna");
    }
}
