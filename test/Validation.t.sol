// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "./Serpent.t.sol";
import {Serpent} from "../src/Serpent.sol";
import {BaseWrapper} from "../src/wrappers/BaseWrapper.sol";

contract ValidationTest is RouterTestBase {
    function test_routeTokenAddressesMustBeNonzeroAndDistinct() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.token_in = address(0);
        vm.expectRevert(Serpent.AddressZero.selector);
        _run(route, steps);
        route.token_in = route.token_out;
        vm.expectRevert(Serpent.TokenAddressesAreSame.selector);
        _run(route, steps);
    }

    function test_stepTokenAddressesMustBeNonzeroAndDistinct() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        steps[0].token_out = address(0);
        vm.expectRevert(Serpent.AddressZero.selector);
        _run(route, steps);
        steps[0].token_out = steps[0].token_in;
        vm.expectRevert(Serpent.TokenAddressesAreSame.selector);
        _run(route, steps);
    }

    function test_routeInputMustMatchFirstStep() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        steps[0].token_in = address(intermediate);
        vm.expectRevert(Serpent.InvalidRoute.selector);
        _run(route, steps);
        steps[0].token_in = route.token_in;
        steps[0].swap_type = 0x01;
        vm.expectRevert(Serpent.InvalidRoute.selector);
        _run(route, steps);
    }

    function test_splitRateSumCannotExceedOneMillion() public {
        (Serpent.RouteParam memory route,) = _single(0x03, 1, AMOUNT);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(route.token_in, route.token_out, 600_000, 1, 0x03);
        steps[1] = _step(route.token_in, route.token_out, 400_001, 2, 0x03);
        vm.expectRevert(Serpent.InvalidRate.selector);
        _run(route, steps);
    }

    function test_nativeInputRequiresExactValue() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 1, AMOUNT);
        vm.startPrank(user);
        vm.expectRevert(Serpent.InvalidMsgValue.selector);
        serpent.swap{value: AMOUNT - 1}(route, steps);
        vm.expectRevert(Serpent.InvalidMsgValue.selector);
        serpent.swap{value: AMOUNT + 1}(route, steps);
        vm.stopPrank();
    }

    function test_tokenInputRejectsEther() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        vm.prank(user);
        vm.expectRevert(Serpent.InvalidMsgValue.selector);
        serpent.swap{value: 1}(route, steps);
    }

    function test_nativeInputCannotUsePermit() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 1, AMOUNT);
        vm.prank(user);
        vm.expectRevert(Serpent.InvalidPermitSwap.selector);
        serpent.swapWithPermit{value: AMOUNT}(route, steps, block.timestamp, 27, bytes32(0), bytes32(0));
    }

    function test_unknownProtocolRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 99, AMOUNT);
        vm.expectRevert(Serpent.UnknownProtocol.selector);
        _run(route, steps);
    }

    function test_splitRatesMustSumToOneMillion() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        steps[0].rate = 999_999;
        vm.expectRevert(Serpent.InvalidRate.selector);
        _run(route, steps);
        steps[0].rate = 1_000_001;
        vm.expectRevert(Serpent.InvalidRate.selector);
        _run(route, steps);
        steps[0].rate = 0;
        vm.expectRevert(Serpent.InvalidRate.selector);
        _run(route, steps);
    }

    function test_eachIntermediateGroupRequiresFullRates() public {
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), AMOUNT, AMOUNT, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(intermediate), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), 500_000, 2, 0x03);
        vm.expectRevert(Serpent.InvalidRate.selector);
        _run(route, steps);
        assertEq(intermediate.balanceOf(address(serpent)), 0);
    }

    function test_disconnectedInputRejected() public {
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), AMOUNT, AMOUNT, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(tokenOut), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), 1_000_000, 1, 0x03);
        vm.expectRevert(Serpent.InvalidRoute.selector);
        _run(route, steps);
    }

    function test_invalidSwapTypesRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.swap_type = 0x04;
        vm.expectRevert(Serpent.InvalidSwapType.selector);
        _run(route, steps);
        route.swap_type = 0x03;
        steps[0].swap_type = 0x00;
        vm.expectRevert(Serpent.InvalidSwapType.selector);
        _run(route, steps);
    }

    function test_destinationMustBeExternalAndNonzero() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.destination = address(0);
        vm.expectRevert(Serpent.DestinationZero.selector);
        _run(route, steps);
        route.destination = address(serpent);
        vm.expectRevert(Serpent.InvalidDestination.selector);
        _run(route, steps);
    }

    function test_emptyRouteAndZeroAmountsRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        Serpent.SwapParams[] memory empty = new Serpent.SwapParams[](0);
        vm.expectRevert(Serpent.NoSwapsProvided.selector);
        _run(route, empty);
        route.amount_in = 0;
        vm.expectRevert(Serpent.AmountInZero.selector);
        _run(route, steps);
        route.amount_in = AMOUNT;
        route.min_received = 0;
        vm.expectRevert(Serpent.MinReceivedZero.selector);
        _run(route, steps);
    }

    function test_balanceQueryFailsOnEmptyResponse() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        vm.mockCall(address(tokenOut), abi.encodeWithSignature("balanceOf(address)", address(serpent)), hex"");
        vm.expectRevert(Serpent.BalanceQueryFailed.selector);
        _run(route, steps);
    }

    function test_poolFeeQueryFailsOnShortResponse() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        vm.mockCall(address(v3Pool), abi.encodeWithSignature("fee()"), hex"010203");
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
    }
}
