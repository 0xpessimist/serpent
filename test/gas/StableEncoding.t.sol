// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "../Serpent.t.sol";
import {Serpent} from "../../src/Serpent.sol";
import {SolidlyWrapper} from "../../src/wrappers/SolidlyWrapper.sol";
import {CurveStableNGWrapper} from "../../src/wrappers/CurveStableNGWrapper.sol";
import {SolidlyTestPool, SolidlyTestRouter, ISolidlyTestRouter} from "../SolidlyWrapper.t.sol";
import {CurveTestFactory, CurveTestPool} from "../CurveStableNGWrapper.t.sol";

/// @dev Identical validation, approvals and failure handling; only calldata construction differs.
contract SolidlyAbiWrapper is SolidlyWrapper {
    constructor(address router) SolidlyWrapper(router) {}

    function _callRouter(address input, address output, uint256 amount, address to, uint256 stable, uint256 kind)
        internal
        override
    {
        ISolidlyTestRouter.Route[] memory path = new ISolidlyTestRouter.Route[](1);
        path[0] = ISolidlyTestRouter.Route(input, output, stable == 1, FACTORY);
        bytes memory data = kind == 1
            ? abi.encodeCall(ISolidlyTestRouter.swapExactETHForTokens, (0, path, to, block.timestamp))
            : kind == 2
                ? abi.encodeCall(ISolidlyTestRouter.swapExactTokensForETH, (amount, 0, path, to, block.timestamp))
                : abi.encodeCall(ISolidlyTestRouter.swapExactTokensForTokens, (amount, 0, path, to, block.timestamp));
        address router = PROTOCOL_ROUTER_ADDRESS;
        uint256 value = kind == 1 ? amount : 0;
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), router, value, add(data, 0x20), mload(data), 0, 0)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (!success) revert ExternalCallFailed();
    }
}

contract CurveAbiWrapper is CurveStableNGWrapper {
    constructor(address factory, address weth) CurveStableNGWrapper(factory, weth) {}

    function _callPool(address pool, uint256 i, uint256 j, uint256 amount, address to)
        internal
        override
        returns (uint256 output)
    {
        bytes memory data =
            abi.encodeCall(CurveTestPool.exchange, (int128(uint128(i)), int128(uint128(j)), amount, 0, to));
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), pool, 0, add(data, 0x20), mload(data), add(data, 0x20), 0x20)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            success := and(success, eq(returndatasize(), 0x20))
            output := mload(add(data, 0x20))
        }
        if (!success) revert ExternalCallFailed();
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract StableEncodingGasTest is RouterTestBase {
    Serpent private referenceRouter;
    SolidlyTestPool private solidlyPool;
    CurveTestPool private curvePool;

    function setUp() public override {
        super.setUp();
        referenceRouter = new Serpent(owner);
        solidlyPool = new SolidlyTestPool();
        SolidlyTestRouter router = new SolidlyTestRouter(address(weth), address(solidlyPool));
        vm.deal(address(router), 1000 ether);
        CurveTestFactory factory = new CurveTestFactory();
        address[] memory coins = new address[](3);
        coins[0] = address(tokenIn);
        coins[1] = address(weth);
        coins[2] = address(tokenOut);
        curvePool = new CurveTestPool(coins);
        factory.register(address(curvePool), coins);
        SolidlyWrapper solidly = new SolidlyWrapper(address(router));
        SolidlyAbiWrapper solidlyAbi = new SolidlyAbiWrapper(address(router));
        CurveStableNGWrapper curve = new CurveStableNGWrapper(address(factory), address(weth));
        CurveAbiWrapper curveAbi = new CurveAbiWrapper(address(factory), address(weth));
        vm.startPrank(owner);
        serpent.addSwapper(3, address(solidly));
        serpent.addSwapper(4, address(curve));
        referenceRouter.addSwapper(3, address(solidlyAbi));
        referenceRouter.addSwapper(4, address(curveAbi));
        vm.stopPrank();
        vm.prank(user);
        tokenIn.approve(address(referenceRouter), type(uint256).max);
    }

    function _compare(uint256 protocol, bytes1 kind, string memory name) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, protocol, AMOUNT);
        steps[0].pool_address = protocol == 3 ? address(solidlyPool) : address(curvePool);
        uint256 state = vm.snapshotState();
        uint256 yulOutput = _run(route, steps);
        uint256 yulGas = vm.snapshotGasLastCall("StableEncodingGas", string.concat(name, "_yul"));
        assertTrue(vm.revertToState(state));
        vm.prank(user);
        uint256 abiOutput = referenceRouter.swap{value: kind == 0x01 ? AMOUNT : 0}(route, steps);
        uint256 abiGas = vm.snapshotGasLastCall("StableEncodingGas", string.concat(name, "_abi"));
        assertEq(yulOutput, abiOutput);
        assertLt(yulGas, abiGas);
        emit log_named_uint(string.concat(name, " gas saved"), abiGas - yulGas);
    }

    function test_solidlyNativeInput() public {
        _compare(3, 0x01, "solidly_native_in");
    }

    function test_solidlyNativeOutput() public {
        _compare(3, 0x02, "solidly_native_out");
    }

    function test_solidlyTokenInput() public {
        _compare(3, 0x03, "solidly_token");
    }

    function test_curveNativeInput() public {
        _compare(4, 0x01, "curve_native_in");
    }

    function test_curveNativeOutput() public {
        _compare(4, 0x02, "curve_native_out");
    }

    function test_curveTokenInput() public {
        _compare(4, 0x03, "curve_token");
    }
}
