// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {RouterTestBase} from "./Serpent.t.sol";
import {MockERC20} from "./mocks/MockDex.sol";
import {SlipstreamWrapper} from "../src/wrappers/SlipstreamWrapper.sol";
import {BaseWrapper} from "../src/wrappers/BaseWrapper.sol";
import {Serpent} from "../src/Serpent.sol";

interface ISlipstreamRouterTest {
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

    function exactInputSingle(Params calldata params) external payable returns (uint256);
}

contract MockSlipstreamPool {
    int24 public immutable tickSpacing;

    constructor(int24 spacing) {
        tickSpacing = spacing;
    }
}

/// @dev Compiler-decoded signed tick-spacing ABI, independent of the adapter's Yul payload.
contract MockSlipstreamRouter is ISlipstreamRouterTest {
    address public immutable WETH;

    constructor(address weth) {
        WETH = weth;
    }

    function exactInputSingle(Params calldata params) external payable returns (uint256) {
        require(msg.data.length == 0x104 && params.tickSpacing == 100, "Slipstream ABI");
        require(params.deadline == block.timestamp, "Slipstream deadline");
        require(params.amountOutMinimum == 0 && params.sqrtPriceLimitX96 == 0, "Slipstream limits");
        if (msg.value != 0) {
            require(params.tokenIn == WETH && msg.value == params.amountIn, "Slipstream native input");
        } else {
            SafeTransferLib.safeTransferFrom(params.tokenIn, msg.sender, address(this), params.amountIn);
        }
        MockERC20(params.tokenOut).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract SlipstreamWrapperTest is RouterTestBase {
    MockSlipstreamRouter private slipstream;
    MockSlipstreamPool private pool;
    SlipstreamWrapper private adapter;

    function setUp() public override {
        super.setUp();
        pool = new MockSlipstreamPool(100);
        slipstream = new MockSlipstreamRouter(address(weth));
        adapter = new SlipstreamWrapper(address(slipstream), address(weth));
        vm.prank(owner);
        serpent.addSwapper(3, address(adapter));
    }

    function _singleSlipstream(bytes1 kind, uint256 amount)
        private
        view
        returns (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps)
    {
        (route, steps) = _single(kind, 3, amount);
        steps[0].pool_address = address(pool);
    }

    function _expectSwap(Serpent.SwapParams memory step, uint256 amount) private {
        assertEq(ISlipstreamRouterTest.exactInputSingle.selector, bytes4(0xa026383e));
        ISlipstreamRouterTest.Params memory params = ISlipstreamRouterTest.Params(
            step.token_in, step.token_out, 100, address(serpent), block.timestamp, amount, 0, 0
        );
        vm.expectCall(
            address(slipstream),
            step.swap_type == 0x01 ? amount : 0,
            abi.encodeCall(ISlipstreamRouterTest.exactInputSingle, (params))
        );
    }

    function test_slipstreamNativeToTokenUsesSignedSpacingABI() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _singleSlipstream(0x01, AMOUNT);
        _expectSwap(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_slipstreamTokenToTokenUsesSignedSpacingABI() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _singleSlipstream(0x03, AMOUNT);
        _expectSwap(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_slipstreamNativeOutputPreservesPriorWethAndEth() public {
        weth.mint(address(serpent), 3 ether);
        vm.deal(address(serpent), 2 ether);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _singleSlipstream(0x02, AMOUNT);
        _expectSwap(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(destination.balance, AMOUNT);
        assertEq(weth.balanceOf(address(serpent)), 3 ether);
        assertEq(address(serpent).balance, 2 ether);
    }

    function test_slipstreamMixedSplitPreservesLastLegRemainder() public {
        (Serpent.RouteParam memory route,) = _singleSlipstream(0x01, 101);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(weth), address(tokenOut), 333_333, 1, 0x01);
        steps[1] = _step(address(weth), address(tokenOut), 666_667, 3, 0x01);
        steps[1].pool_address = address(pool);
        _expectSwap(steps[1], 68);
        assertEq(_run(route, steps), 101);
    }

    function test_slipstreamRequiresDelegatecall() public {
        vm.expectRevert(BaseWrapper.OnlyDelegateCall.selector);
        adapter.swapTokenToToken(address(tokenIn), address(tokenOut), 1, destination, address(pool));
    }

    function test_slipstreamRejectsZeroAndNegativeSpacing() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _singleSlipstream(0x01, AMOUNT);
        for (uint256 i; i < 2; ++i) {
            steps[0].pool_address = address(new MockSlipstreamPool(i == 0 ? int24(0) : int24(-1)));
            vm.prank(user);
            vm.expectRevert(BaseWrapper.InvalidPool.selector);
            serpent.swap{value: AMOUNT}(route, steps);
        }
    }

    function test_slipstreamRejectsMalformedSpacingResponse() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _singleSlipstream(0x01, AMOUNT);
        vm.mockCall(address(pool), abi.encodeWithSignature("tickSpacing()"), hex"01");
        vm.prank(user);
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        serpent.swap{value: AMOUNT}(route, steps);
    }
}
