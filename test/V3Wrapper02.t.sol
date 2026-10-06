// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {RouterTestBase} from "./Serpent.t.sol";
import {MockERC20} from "./mocks/MockDex.sol";
import {V3Wrapper02} from "../src/wrappers/V3Wrapper02.sol";
import {Serpent} from "../src/Serpent.sol";

interface IV3Router02Test {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @dev Independent compiler-decoded seven-field ABI; the original V3 mock remains unchanged.
contract MockV3Router02 is IV3Router02Test {
    address public immutable WETH;

    constructor(address weth) {
        WETH = weth;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256) {
        require(msg.data.length == 0xe4 && params.fee == 3000, "Router02 ABI");
        require(params.amountOutMinimum == 0 && params.sqrtPriceLimitX96 == 0, "Router02 limits");
        if (msg.value != 0) {
            require(params.tokenIn == WETH && msg.value == params.amountIn, "Router02 native input");
        } else {
            SafeTransferLib.safeTransferFrom(params.tokenIn, msg.sender, address(this), params.amountIn);
        }
        MockERC20(params.tokenOut).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract V3Wrapper02Test is RouterTestBase {
    MockV3Router02 private router02;

    function setUp() public override {
        super.setUp();
        router02 = new MockV3Router02(address(weth));
        V3Wrapper02 adapter = new V3Wrapper02(address(router02), address(weth));
        vm.startPrank(owner);
        serpent.removeSwapper(2);
        serpent.addSwapper(2, address(adapter));
        vm.stopPrank();
    }

    function _expect02(Serpent.SwapParams memory step, uint256 amount) private {
        assertEq(IV3Router02Test.exactInputSingle.selector, bytes4(0x04e45aaf));
        IV3Router02Test.ExactInputSingleParams memory params =
            IV3Router02Test.ExactInputSingleParams(step.token_in, step.token_out, 3000, address(serpent), amount, 0, 0);
        vm.expectCall(
            address(router02),
            step.swap_type == 0x01 ? amount : 0,
            abi.encodeCall(IV3Router02Test.exactInputSingle, (params))
        );
    }

    function test_router02NativeToTokenUsesSevenFieldABI() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 2, AMOUNT);
        _expect02(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
        assertEq(address(serpent).balance, 0);
    }

    function test_router02TokenToTokenUsesSevenFieldABI() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        _expect02(steps[0], AMOUNT);
        uint256 beforeInput = tokenIn.balanceOf(user);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(beforeInput - tokenIn.balanceOf(user), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_router02TokenToNativeUnwrapsExactOutputAndPreservesBalances() public {
        weth.mint(address(serpent), 3 ether);
        vm.deal(address(serpent), 2 ether);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 2, AMOUNT);
        _expect02(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(destination.balance, AMOUNT);
        assertEq(weth.balanceOf(address(serpent)), 3 ether);
        assertEq(address(serpent).balance, 2 ether);
    }

    function test_router02SplitReceivesExactLastLegRemainder() public {
        (Serpent.RouteParam memory route,) = _single(0x01, 2, 101);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(weth), address(tokenOut), 333_333, 2, 0x01);
        steps[1] = _step(address(weth), address(tokenOut), 666_667, 2, 0x01);
        _expect02(steps[0], 33);
        _expect02(steps[1], 68);
        assertEq(_run(route, steps), 101);
        assertEq(tokenOut.balanceOf(destination), 101);
    }
}
