// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {ProviderRouteForkBase, IERC20ProviderFork} from "./ProviderRoutes.t.sol";

interface ISlipstreamForkRouter {
    struct Params {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(Params calldata) external payable returns (uint256);
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
    function unwrapWETH9(uint256, address) external payable;
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface ISlipstreamForkQuoter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        int24 tickSpacing;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(Params calldata) external returns (uint256, uint160, uint32, uint256);
    function factory() external view returns (address);
}

interface ISlipstreamForkFactory {
    function getPool(address, address, int24) external view returns (address);
}

interface ISlipstreamForkPool {
    function factory() external view returns (address);
    function tickSpacing() external view returns (int24);
}

interface IRouter02SlipstreamFunding {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(Params calldata) external payable returns (uint256);
}

/// @dev Real Base pools, compiler-encoded direct calls and externally chosen Serpent plans.
/// Funding buys USDC on Uniswap, leaving every quoted Slipstream pool untouched.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract SlipstreamForkTest is ProviderRouteForkBase {
    struct Deployment {
        string name;
        address factory;
        address router;
        address quoter;
        address pool;
        int24 spacing;
        uint256 id;
    }

    function _chain() internal pure override returns (uint256) {
        return 8453;
    }

    function _enabled() internal view override returns (bool) {
        return vm.envOr("RUN_SLIPSTREAM_FORK", false);
    }

    function _fixtureFile() internal pure override returns (string memory) {
        return "test/fixtures/slipstream-base.json";
    }

    function setUp() public override {
        super.setUp();
        gasGroup = string.concat("Slipstream_", vm.toString(block.number));
        vm.startPrank(user);
        uint256 bought = IRouter02SlipstreamFunding(0x2626664c2603336E57B271c5C0b26F421741e481)
        .exactInputSingle{value: 1 ether}(
            IRouter02SlipstreamFunding.Params(weth, usdc, 100, user, 1 ether, 1, 0)
        );
        assertGt(bought, 100e6);
        SafeTransferLib.safeApprove(usdc, address(serpent), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            address router = _deployment(i).router;
            SafeTransferLib.safeApprove(usdc, router, type(uint256).max);
            SafeTransferLib.safeApprove(weth, router, type(uint256).max);
        }
        vm.stopPrank();
    }

    function _deployment(uint256 i) private pure returns (Deployment memory) {
        if (i == 0) {
            return Deployment(
                "initial",
                0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A,
                0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5,
                0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0,
                0xdbc6998296caA1652A810dc8D3BaF4A8294330f1,
                1,
                3
            );
        }
        if (i == 1) {
            return Deployment(
                "caps",
                0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a,
                0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D,
                0x3d4C22254F86f64B7eC90ab8F7aeC1FBFD271c6C,
                0xc758d81B9b81A6FCDAd075bD471874A2c46B54e0,
                50,
                4
            );
        }
        return Deployment(
            "gauges_v3",
            0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef,
            0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F,
            0x514c8B5f54112481E28028F1166Bd78501089259,
            0x4e392fBfE4D0557C82D2F97F02ec39daA31516dd,
            1,
            5
        );
    }

    function _reference(uint256 generation, bytes1 kind) private {
        Deployment memory d = _deployment(generation);
        assertEq(ISlipstreamForkRouter(d.router).factory(), d.factory);
        assertEq(ISlipstreamForkRouter(d.router).WETH9(), weth);
        assertEq(ISlipstreamForkQuoter(d.quoter).factory(), d.factory);
        assertEq(ISlipstreamForkFactory(d.factory).getPool(weth, usdc, d.spacing), d.pool);
        assertEq(ISlipstreamForkPool(d.pool).factory(), d.factory);
        assertEq(ISlipstreamForkPool(d.pool).tickSpacing(), d.spacing);
        address input = kind == 0x02 ? usdc : weth;
        address output = kind == 0x02 ? weth : usdc;
        uint256 amount = kind == 0x02 ? 100e6 : 0.01 ether;
        (uint256 expected,,,) = ISlipstreamForkQuoter(d.quoter)
            .quoteExactInputSingle(ISlipstreamForkQuoter.Params(input, output, amount, d.spacing, 0));
        assertGt(expected, 0);
        uint256 state = vm.snapshotState();
        uint256 beforeOutput = kind == 0x02 ? RECIPIENT.balance : IERC20ProviderFork(output).balanceOf(RECIPIENT);
        uint256 beforeInput = kind == 0x01 ? user.balance : IERC20ProviderFork(input).balanceOf(user);
        ISlipstreamForkRouter.Params memory params = ISlipstreamForkRouter.Params(
            input, output, d.spacing, kind == 0x02 ? address(0) : RECIPIENT, block.timestamp, amount, expected, 0
        );
        bytes memory direct;
        if (kind == 0x02) {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(ISlipstreamForkRouter.exactInputSingle, (params));
            calls[1] = abi.encodeCall(ISlipstreamForkRouter.unwrapWETH9, (expected, RECIPIENT));
            direct = abi.encodeCall(ISlipstreamForkRouter.multicall, (calls));
        } else {
            direct = abi.encodeCall(ISlipstreamForkRouter.exactInputSingle, (params));
        }
        string memory name =
            string.concat(d.name, kind == 0x01 ? "_native_in" : kind == 0x02 ? "_native_out" : "_token_in");
        vm.prank(user);
        (bool success, bytes memory result) = d.router.call{value: kind == 0x01 ? amount : 0}(direct);
        vm.snapshotGasLastCall(gasGroup, string.concat(name, "_direct"));
        assertTrue(success, "direct Slipstream call");
        if (kind == 0x02) {
            bytes[] memory callResults = abi.decode(result, (bytes[]));
            assertEq(abi.decode(callResults[0], (uint256)), expected);
        } else {
            assertEq(abi.decode(result, (uint256)), expected);
        }
        _assertSettlement(input, output, kind, beforeInput, beforeOutput, amount, expected);
        assertTrue(vm.revertToState(state));
        Serpent.RouteParam memory route = Serpent.RouteParam(input, output, amount, expected, RECIPIENT, kind);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](1);
        steps[0] = Serpent.SwapParams(input, output, 1_000_000, d.id, d.pool, kind);
        uint256 baselineWeth = IERC20ProviderFork(weth).balanceOf(address(serpent));
        uint256 baselineUsdc = IERC20ProviderFork(usdc).balanceOf(address(serpent));
        uint256 baselineEth = address(serpent).balance;
        vm.prank(user);
        uint256 actual = serpent.swap{value: kind == 0x01 ? amount : 0}(route, steps);
        vm.snapshotGasLastCall(gasGroup, string.concat(name, "_serpent"));
        assertEq(actual, expected, "direct / quoter / Serpent parity");
        _assertSettlement(input, output, kind, beforeInput, beforeOutput, amount, expected);
        assertEq(IERC20ProviderFork(weth).balanceOf(address(serpent)), baselineWeth);
        assertEq(IERC20ProviderFork(usdc).balanceOf(address(serpent)), baselineUsdc);
        assertEq(address(serpent).balance, baselineEth);
    }

    function _assertSettlement(
        address input,
        address output,
        bytes1 kind,
        uint256 beforeInput,
        uint256 beforeOutput,
        uint256 amount,
        uint256 expected
    ) private view {
        assertEq(beforeInput - (kind == 0x01 ? user.balance : IERC20ProviderFork(input).balanceOf(user)), amount);
        assertEq(
            (kind == 0x02 ? RECIPIENT.balance : IERC20ProviderFork(output).balanceOf(RECIPIENT)) - beforeOutput,
            expected
        );
    }

    function test_providerSmallNativeTrade() public {
        _run(0);
    }

    function test_providerLargeNativeTrade() public {
        _run(1);
    }

    function test_providerWethTrade() public {
        _run(2);
    }

    function test_providerUsdcToNative() public {
        _run(3);
    }

    function test_initialNativeIn() public {
        _reference(0, 0x01);
    }

    function test_initialTokenIn() public {
        _reference(0, 0x03);
    }

    function test_initialNativeOut() public {
        _reference(0, 0x02);
    }

    function test_capsNativeIn() public {
        _reference(1, 0x01);
    }

    function test_capsTokenIn() public {
        _reference(1, 0x03);
    }

    function test_capsNativeOut() public {
        _reference(1, 0x02);
    }

    function test_gaugesV3NativeIn() public {
        _reference(2, 0x01);
    }

    function test_gaugesV3TokenIn() public {
        _reference(2, 0x03);
    }

    function test_gaugesV3NativeOut() public {
        _reference(2, 0x02);
    }
}
