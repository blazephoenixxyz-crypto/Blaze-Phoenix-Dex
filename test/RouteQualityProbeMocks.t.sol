// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {BlazePhoenixCore as BPC} from "src/BlazePhoenixCore.sol";
import {BlazePhoenixHub} from "src/BlazePhoenixHub.sol";
import {BlazePhoenixSolver} from "src/BlazePhoenixSolver.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";
import {MockSolidlyPair} from "./mocks/MockSolidlyPair.sol";
import {MockV4TickManager} from "./mocks/MockV4TickManager.sol";
import {RouteQualityRecorder} from "./tools/RouteQualityRecorder.sol";

/// A bare token whose decimals are set after deployment, so the 18-decimal side can be token0.
contract RqToken {
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setDecimals(uint8 d) external { decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// @notice DIAGNOSIS, NOT A GUARD: the twin of test/fork/RouteQualityProbe.t.sol on mocks. Six
///         rows carry the states the trace of run 43410379085 read on Base at block 49800000
///         (DAI 18 decimals is token0, USDC 6 is token1, USDC->DAI is oneForZero):
///           A    V3 fee 100  sqrtP 79185792417581389711186  L 1376307593244183901  DAI 16259.66
///           B    V3 fee 100  sqrtP 79191704618123726716570  L 9220770078581457352  DAI 7225.73
///           P    V3 fee 100  sqrtP 72985406416730663360560  L 12042830150006831    DAI 6796.44 (1631 ticks off)
///           S    Solidly stable, reserves 3320.82 DAI / 1719.39 USDC, fee 5 bps (its fee read is redacted)
///           V4a  fee 500 ts 10 sqrtP 79181864006564978336977 L 30972097471148909 tick -276336
///           V4b  fee 100 ts 1  sqrtP 79196073533347128081182 L 1167826278346632  tick -276333
///         Not modelled: P's protocol-fee word and its LM ticks, the V3 rows' tick books (one range
///         each), the V4 rows' ranges (full range here: 30990 and 1168 DAI above the price), the
///         other eleven rows (dust and dead). One solve of 1e10 USDC is recorded and every select is
///         replayed into the real library and the tap (`test/tools/RouteQualityRecorder.sol`):
///         the rows as they reached the band, prices, votes w and base per pass, kept bits. It
///         asserts nothing and must pass.
contract RouteQualityProbeMocksTest is Test, RouteQualityRecorder {
    MockV4TickManager mgr;
    BlazePhoenixHub hub;
    BlazePhoenixSolver solver;
    address dai;
    address usdc;

    function setUp() public {
        mgr = new MockV4TickManager();
        hub = new BlazePhoenixHub(address(this));
        hub.initialize(address(this), address(mgr));
        solver = new BlazePhoenixSolver(address(hub), address(0));
        RqToken a = new RqToken();
        RqToken b = new RqToken();
        (dai, usdc) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        RqToken(dai).setDecimals(18);
        RqToken(usdc).setDecimals(6);
        RqToken(dai).mint(address(mgr), 1e30);
        RqToken(usdc).mint(address(mgr), 1e30);

        _v3("A", 79185792417581389711186, 1376307593244183901, 16259664565792390887740);
        _v3("B", 79191704618123726716570, 9220770078581457352, 7225725473850309160694);
        _v3("P", 72985406416730663360560, 12042830150006831, 6796439021971914790759);

        MockSolidlyPair s = new MockSolidlyPair(dai, usdc, true);
        s.setReserves(3320817780718848270037, 1719393377);
        s.setFeeBps(5);
        RqToken(dai).mint(address(s), 3320817780718848270037);
        RqToken(usdc).mint(address(s), 1719393377);
        hub.seedPool(address(s), BPC.KIND_SOLIDLY, 500, address(0), dai, usdc);
        console2.log("RQ mock S", address(s));

        _v4("V4a", 500, 10, 79181864006564978336977, -276336, 30972097471148909);
        _v4("V4b", 100, 1, 79196073533347128081182, -276333, 1167826278346632);
    }

    function _v3(string memory label, uint160 sqrtP, uint128 liq, uint256 held) internal {
        MockV3Pool p = new MockV3Pool(dai, usdc, 100);
        p.setState(sqrtP, liq);
        RqToken(dai).mint(address(p), held);
        hub.seedPool(address(p), BPC.KIND_V3, 100, address(0), dai, usdc);
        console2.log(string.concat("RQ mock ", label), address(p));
    }

    function _v4(string memory label, uint24 fee, int24 ts, uint160 sqrtP, int24 tick, uint128 liq) internal {
        bytes32 pid = BPC.computeV4PoolId(dai, usdc, fee, ts, address(0));
        mgr.initialize(pid, sqrtP, tick, fee);
        int24 edge = (887272 / ts) * ts;
        mgr.addPosition(pid, -edge, edge, ts, liq);
        hub.seedPool(address(uint160(uint256(pid))), BPC.KIND_V4, fee, address(0), dai, usdc);
        console2.log(string.concat("RQ mock ", label), address(uint160(uint256(pid))));
    }

    function test_RouteQuality_SixTraceRows_logsTheBand() public {
        _rqStart();
        (bool ok, ) = address(solver).call(abi.encodeCall(solver.findBestRoutePlan, (usdc, dai, 1e10)));
        _rqStopAndReplay("mocks USDC->DAI 1e10");
        console2.log("RQ findBestRoutePlan ok:", ok ? 1 : 0);
    }
}
