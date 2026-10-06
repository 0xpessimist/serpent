// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {Serpent} from "../src/Serpent.sol";
import {ISerpent} from "../src/interfaces/ISerpent.sol";
import {V2Wrapper, ISwapRouterV2} from "../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../src/wrappers/V3Wrapper.sol";
import {BaseWrapper} from "../src/wrappers/BaseWrapper.sol";
import {
    MockERC20,
    MockWETH,
    MockV2Router,
    MockV3Router,
    MockV3Pool,
    IOriginalV3Router,
    ResetApprovalToken,
    NoReturnToken,
    NoPermitToken,
    StoredDomainToken,
    MockERC1967Proxy,
    MockPermit2,
    TransferTaxToken
} from "./mocks/MockDex.sol";

abstract contract RouterTestBase is Test {
    uint256 internal constant USER_PK = 0xA11CE;
    uint256 internal constant AMOUNT = 10 ether;
    address internal owner;
    address internal user;
    address internal destination;
    Serpent internal serpent;
    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockERC20 internal intermediate;
    MockWETH internal weth;
    MockV2Router internal v2Router;
    MockV3Router internal v3Router;
    MockV3Pool internal v3Pool;
    V2Wrapper internal v2;
    V3Wrapper internal v3;

    function setUp() public virtual {
        owner = makeAddr("owner");
        user = vm.addr(USER_PK);
        destination = makeAddr("destination");
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        intermediate = new MockERC20();
        weth = new MockWETH();
        v2Router = new MockV2Router(address(weth));
        v3Router = new MockV3Router(address(weth));
        v3Pool = new MockV3Pool(3000);
        v2 = new V2Wrapper(address(v2Router));
        v3 = new V3Wrapper(address(v3Router), address(weth));
        serpent = new Serpent(owner);
        vm.startPrank(owner);
        serpent.addSwapper(1, address(v2));
        serpent.addSwapper(2, address(v3));
        vm.stopPrank();
        tokenIn.mint(user, 1_000 ether);
        vm.prank(user);
        tokenIn.approve(address(serpent), type(uint256).max);
        vm.deal(user, 1_000 ether);
        vm.deal(address(v2Router), 1_000_000 ether);
        vm.deal(address(weth), 1_000_000 ether);
        vm.warp(1_800_000_000);
    }

    function _single(bytes1 kind, uint256 protocol, uint256 amount)
        internal
        view
        returns (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps)
    {
        address input = kind == 0x01 ? address(weth) : address(tokenIn);
        address output = kind == 0x02 ? address(weth) : address(tokenOut);
        route = Serpent.RouteParam(input, output, amount, amount, destination, kind);
        steps = new Serpent.SwapParams[](1);
        steps[0] = _step(input, output, 1_000_000, protocol, kind);
    }

    function _step(address input, address output, uint32 rate, uint256 protocol, bytes1 kind)
        internal
        view
        returns (Serpent.SwapParams memory)
    {
        return Serpent.SwapParams(input, output, rate, protocol, protocol == 2 ? address(v3Pool) : address(0), kind);
    }

    function _run(Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) internal returns (uint256) {
        vm.prank(user);
        return serpent.swap{value: route.swap_type == 0x01 ? route.amount_in : 0}(route, steps);
    }

    function _expectV2(Serpent.SwapParams memory step, uint256 amount) internal {
        _expectV2(step, amount, 1);
    }

    function _expectV2(Serpent.SwapParams memory step, uint256 amount, uint64 expectedCalls) internal {
        address[] memory path = new address[](2);
        path[0] = step.token_in;
        path[1] = step.token_out;
        bytes memory payload;
        uint256 value;
        if (step.swap_type == 0x01) {
            payload = abi.encodeCall(ISwapRouterV2.swapExactETHForTokens, (0, path, address(serpent), block.timestamp));
            value = amount;
        } else if (step.swap_type == 0x02) {
            payload = abi.encodeCall(
                ISwapRouterV2.swapExactTokensForETH, (amount, 0, path, address(serpent), block.timestamp)
            );
        } else {
            payload = abi.encodeCall(
                ISwapRouterV2.swapExactTokensForTokens, (amount, 0, path, address(serpent), block.timestamp)
            );
        }
        vm.expectCall(address(v2Router), value, payload, expectedCalls);
    }

    function _expectV3(Serpent.SwapParams memory step, uint256 amount) internal {
        IOriginalV3Router.ExactInputSingleParams memory params = IOriginalV3Router.ExactInputSingleParams({
            tokenIn: step.token_in,
            tokenOut: step.token_out,
            fee: 3000,
            recipient: address(serpent),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        vm.expectCall(
            address(v3Router),
            step.swap_type == 0x01 ? amount : 0,
            abi.encodeCall(IOriginalV3Router.exactInputSingle, (params)),
            1
        );
    }

    function _signPermit(uint256 amount, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(serpent),
                amount,
                tokenIn.nonces(user),
                deadline
            )
        );
        return vm.sign(USER_PK, keccak256(abi.encodePacked("\x19\x01", tokenIn.DOMAIN_SEPARATOR(), permitHash)));
    }
}

contract BatchCaller {
    function swapTwice(Serpent router, Serpent.RouteParam calldata route, Serpent.SwapParams[] calldata steps)
        external
        returns (uint256 first, uint256 second)
    {
        SafeTransferLib.safeApprove(route.token_in, address(router), route.amount_in * 2);
        first = router.swap(route, steps);
        second = router.swap(route, steps);
    }
}

contract SerpentTest is RouterTestBase {
    function test_v2EthToToken() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 1, AMOUNT);
        _expectV2(steps[0], AMOUNT);
        uint256 before = user.balance;
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
        assertEq(before - user.balance, AMOUNT);
        assertEq(weth.allowance(address(serpent), address(v2Router)), 0);
    }

    function test_v2TokenToEth() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 1, AMOUNT);
        _expectV2(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(destination.balance, AMOUNT);
        assertEq(tokenIn.balanceOf(address(serpent)), 0);
    }

    function test_v2TokenToToken() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        _expectV2(steps[0], AMOUNT);
        vm.expectEmit(address(serpent));
        emit ISerpent.Swap(user, AMOUNT, AMOUNT, route.token_in, route.token_out, destination);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
        assertEq(tokenIn.balanceOf(address(v2Router)), AMOUNT);
    }

    function test_v3EthToToken() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 2, AMOUNT);
        _expectV3(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
        assertEq(weth.allowance(address(serpent), address(v3Router)), 0);
    }

    function test_v3TokenToEth() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 2, AMOUNT);
        _expectV3(steps[0], AMOUNT);
        vm.expectCall(address(weth), abi.encodeWithSignature("withdraw(uint256)", AMOUNT), 1);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(destination.balance, AMOUNT);
        assertEq(weth.balanceOf(address(serpent)), 0);
        assertEq(address(serpent).balance, 0);
    }

    function test_v3TokenToToken() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        _expectV3(steps[0], AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_erc20OutputPreservesExistingBalances() public {
        tokenIn.mint(address(serpent), 11);
        tokenOut.mint(address(serpent), 17);
        tokenOut.mint(destination, 23);
        vm.deal(address(serpent), 29);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(tokenIn.balanceOf(address(serpent)), 11);
        assertEq(tokenOut.balanceOf(address(serpent)), 17);
        assertEq(tokenOut.balanceOf(destination), AMOUNT + 23);
        assertEq(address(serpent).balance, 29);
    }

    function test_nativeOutputPreservesExistingBalance() public {
        vm.deal(address(serpent), 37);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 2, AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(destination.balance, AMOUNT);
        assertEq(address(serpent).balance, 37);
    }

    function test_nativeInputPreservesExistingBalance() public {
        vm.deal(address(serpent), 41);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 1, AMOUNT);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(address(serpent).balance, 41);
    }

    function test_mixedProtocolMultiHopSplit() public {
        uint256 amount = 1_000_003;
        intermediate.mint(address(serpent), 101);
        tokenOut.mint(address(serpent), 103);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), amount, amount, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](3);
        steps[0] = _step(address(tokenIn), address(intermediate), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), 300_001, 1, 0x03);
        steps[2] = _step(address(intermediate), address(tokenOut), 699_999, 2, 0x03);
        uint256 firstSplit = amount * 300_001 / 1_000_000;
        _expectV2(steps[0], amount);
        _expectV2(steps[1], firstSplit);
        _expectV3(steps[2], amount - firstSplit);
        assertEq(_run(route, steps), amount);
        assertEq(tokenOut.balanceOf(destination), amount);
        assertEq(intermediate.balanceOf(address(serpent)), 101);
        assertEq(tokenOut.balanceOf(address(serpent)), 103);
    }

    function test_diamondRoute() public {
        uint256 amount = 1_000_003;
        MockERC20 secondIntermediate = new MockERC20();
        intermediate.mint(address(serpent), 107);
        secondIntermediate.mint(address(serpent), 109);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), amount, amount, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](4);
        steps[0] = _step(address(tokenIn), address(intermediate), 600_000, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(secondIntermediate), 400_000, 2, 0x03);
        steps[2] = _step(address(intermediate), address(tokenOut), 1_000_000, 2, 0x03);
        steps[3] = _step(address(secondIntermediate), address(tokenOut), 1_000_000, 1, 0x03);
        assertEq(_run(route, steps), amount);
        assertEq(intermediate.balanceOf(address(serpent)), 107);
        assertEq(secondIntermediate.balanceOf(address(serpent)), 109);
        assertEq(tokenOut.balanceOf(destination), amount);
    }

    function test_nativeIntermediateIsDistinctFromWeth() public {
        vm.deal(address(serpent), 113);
        weth.mint(address(serpent), 127);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), AMOUNT, AMOUNT, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(weth), 1_000_000, 2, 0x02);
        steps[1] = _step(address(weth), address(tokenOut), 1_000_000, 1, 0x01);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(address(serpent).balance, 113);
        assertEq(weth.balanceOf(address(serpent)), 127);
    }

    function test_unusedIntermediateIsRefunded() public {
        intermediate.mint(address(serpent), 131);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), 10, 6, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(intermediate), 400_000, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(tokenOut), 600_000, 1, 0x03);
        assertEq(_run(route, steps), 6);
        assertEq(intermediate.balanceOf(user), 4);
        assertEq(intermediate.balanceOf(address(serpent)), 131);
    }

    function test_zeroRoundedStepIsSkipped() public {
        (Serpent.RouteParam memory route,) = _single(0x03, 1, 1);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(tokenOut), 1, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(tokenOut), 999_999, 2, 0x03);
        _expectV3(steps[1], 1);
        assertEq(_run(route, steps), 1);
        assertEq(tokenIn.balanceOf(address(v2Router)), 0);
    }

    function test_uint256MaximumSplitDoesNotOverflow() public {
        MockERC20 source = new MockERC20();
        MockERC20 target = new MockERC20();
        uint256 amount = type(uint256).max;
        source.mint(user, amount);
        vm.prank(user);
        source.approve(address(serpent), amount);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(source), address(target), amount, amount, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(source), address(target), 500_001, 1, 0x03);
        steps[1] = _step(address(source), address(target), 499_999, 2, 0x03);
        uint256 firstSplit = FixedPointMathLib.fullMulDiv(amount, 500_001, 1_000_000);
        _expectV2(steps[0], firstSplit);
        _expectV3(steps[1], amount - firstSplit);
        assertEq(_run(route, steps), amount);
        assertEq(target.balanceOf(destination), amount);
        assertEq(source.balanceOf(address(serpent)), 0);
    }

    function testFuzz_threeLegSplitFullWidth(uint256 amountSeed, uint32 firstRateSeed, uint32 secondRateSeed) public {
        uint256 amount = amountSeed == 0 ? 1 : amountSeed;
        uint32 firstRate = uint32(bound(uint256(firstRateSeed), 1, 999_998));
        uint32 secondRate = uint32(bound(uint256(secondRateSeed), 1, 999_999 - firstRate));
        MockERC20 source = new MockERC20();
        MockERC20 target = new MockERC20();
        source.mint(user, amount);
        vm.prank(user);
        source.approve(address(serpent), amount);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(source), address(target), amount, amount, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](3);
        steps[0] = _step(address(source), address(target), firstRate, 1, 0x03);
        steps[1] = _step(address(source), address(target), secondRate, 2, 0x03);
        steps[2] = _step(address(source), address(target), 1_000_000 - firstRate - secondRate, 1, 0x03);
        // The independent 512-bit implementation checks the decomposition used by the Yul allocator.
        uint256 first = FixedPointMathLib.fullMulDiv(amount, firstRate, 1_000_000);
        uint256 second = FixedPointMathLib.fullMulDiv(amount, secondRate, 1_000_000);
        uint256 last = amount - first - second;
        // Foundry accepts one counted expectation per distinct payload; equal V2 legs share a count.
        if (first == last) {
            _expectV2(steps[0], first, 2);
        } else {
            if (first != 0) _expectV2(steps[0], first);
            _expectV2(steps[2], last);
        }
        if (second != 0) _expectV3(steps[1], second);
        assertEq(_run(route, steps), amount);
        assertEq(source.balanceOf(address(v2Router)), amount - second);
        assertEq(source.balanceOf(address(v3Router)), second);
        assertEq(source.balanceOf(user), 0);
        assertEq(source.balanceOf(address(serpent)), 0);
        assertEq(target.balanceOf(destination), amount);
    }

    function testFuzz_splitConservesInput(uint128 amountSeed, uint32 rateSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 1e30);
        uint32 rate = uint32(bound(uint256(rateSeed), 1, 999_999));
        tokenIn.mint(user, amount);
        (Serpent.RouteParam memory route,) = _single(0x03, 1, amount);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(tokenOut), rate, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(tokenOut), 1_000_000 - rate, 2, 0x03);
        uint256 firstSplit = amount * rate / 1_000_000;
        if (firstSplit != 0) _expectV2(steps[0], firstSplit);
        _expectV3(steps[1], amount - firstSplit);
        uint256 before = tokenIn.balanceOf(user);
        assertEq(_run(route, steps), amount);
        assertEq(before - tokenIn.balanceOf(user), amount);
        assertEq(tokenIn.balanceOf(address(serpent)), 0);
        assertEq(tokenOut.balanceOf(destination), amount);
    }

    function testFuzz_nativeSplitConservesValue(uint96 amountSeed, uint32 rateSeed, bool nativeInput) public {
        uint256 amount = bound(uint256(amountSeed), 1, 100 ether);
        uint32 rate = uint32(bound(uint256(rateSeed), 1, 999_999));
        bytes1 kind = nativeInput ? bytes1(0x01) : bytes1(0x02);
        vm.deal(address(serpent), 173);
        weth.mint(address(serpent), 179);
        (Serpent.RouteParam memory route,) = _single(kind, 1, amount);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(route.token_in, route.token_out, rate, 1, kind);
        steps[1] = _step(route.token_in, route.token_out, 1_000_000 - rate, 2, kind);
        uint256 firstSplit = amount * rate / 1_000_000;
        if (firstSplit != 0) _expectV2(steps[0], firstSplit);
        _expectV3(steps[1], amount - firstSplit);
        assertEq(_run(route, steps), amount);
        assertEq(address(serpent).balance, 173);
        assertEq(weth.balanceOf(address(serpent)), 179);
        if (nativeInput) assertEq(tokenOut.balanceOf(destination), amount);
        else assertEq(destination.balance, amount);
    }

    function testFuzz_multiHopPreservesBalances(uint128 amountSeed, uint32 rateSeed, uint64 dust) public {
        uint256 amount = bound(uint256(amountSeed), 1, 1e30);
        uint32 rate = uint32(bound(uint256(rateSeed), 1, 999_999));
        tokenIn.mint(user, amount);
        tokenIn.mint(address(serpent), dust);
        intermediate.mint(address(serpent), dust);
        tokenOut.mint(address(serpent), dust);
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), amount, amount, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](3);
        steps[0] = _step(address(tokenIn), address(intermediate), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), rate, 1, 0x03);
        steps[2] = _step(address(intermediate), address(tokenOut), 1_000_000 - rate, 2, 0x03);
        assertEq(_run(route, steps), amount);
        assertEq(tokenIn.balanceOf(address(serpent)), dust);
        assertEq(intermediate.balanceOf(address(serpent)), dust);
        assertEq(tokenOut.balanceOf(address(serpent)), dust);
        assertEq(tokenOut.balanceOf(destination), amount);
    }

    function test_nativePermitPullsInput() public {
        vm.prank(user);
        tokenIn.approve(address(serpent), 0);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(AMOUNT, deadline);
        uint256 before = tokenIn.balanceOf(user);
        vm.prank(user);
        assertEq(serpent.swapWithPermit(route, steps, deadline, v, r, s), AMOUNT);
        assertEq(before - tokenIn.balanceOf(user), AMOUNT);
        assertEq(tokenIn.nonces(user), 1);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_permit2FallbackPullsInput() public {
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        MockPermit2 implementation = new MockPermit2();
        vm.etch(permit2, address(implementation).code);
        NoPermitToken source = new NoPermitToken();
        source.mint(user, AMOUNT);
        vm.prank(user);
        source.approve(permit2, AMOUNT);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.token_in = address(source);
        steps[0].token_in = address(source);
        vm.prank(user);
        assertEq(serpent.swapWithPermit(route, steps, block.timestamp + 1, 27, bytes32(0), bytes32(0)), AMOUNT);
        assertEq(source.balanceOf(user), 0);
        assertEq(source.balanceOf(address(v2Router)), AMOUNT);
        (uint160 remaining,, uint48 nonce) = MockPermit2(permit2).allowance(user, address(source), address(serpent));
        assertEq(remaining, 0);
        assertEq(nonce, 1);
    }

    function test_coldProxyNativePermitPullsInput() public {
        StoredDomainToken implementation = new StoredDomainToken();
        StoredDomainToken source = StoredDomainToken(address(new MockERC1967Proxy(address(implementation))));
        source.initializeDomain();
        source.mint(user, AMOUNT);
        tokenIn = MockERC20(address(source));
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(AMOUNT, deadline);
        // Isolated calls keep the implementation slot and domain cold despite signing above.
        vm.prank(user);
        assertEq(serpent.swapWithPermit(route, steps, deadline, v, r, s), AMOUNT);
        assertEq(source.balanceOf(user), 0);
        assertEq(source.nonces(user), 1);
        assertEq(source.allowance(user, address(serpent)), 0);
        assertEq(tokenOut.balanceOf(destination), AMOUNT);
    }

    function test_approvalResetRetry() public {
        ResetApprovalToken source = new ResetApprovalToken();
        source.mint(user, AMOUNT);
        vm.prank(user);
        source.approve(address(serpent), AMOUNT);
        vm.prank(address(serpent));
        source.approve(address(v2Router), 7);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.token_in = address(source);
        steps[0].token_in = address(source);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(source.allowance(address(serpent), address(v2Router)), 0);
    }

    function test_tokensWithNoReturnData() public {
        NoReturnToken source = new NoReturnToken();
        source.mint(user, AMOUNT);
        vm.prank(user);
        SafeTransferLib.safeApprove(address(source), address(serpent), AMOUNT);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.token_in = address(source);
        steps[0].token_in = address(source);
        assertEq(_run(route, steps), AMOUNT);
        assertEq(source.balanceOf(address(v2Router)), AMOUNT);
    }

    function test_transferTaxInputRejected() public {
        TransferTaxToken source = new TransferTaxToken();
        source.mint(user, AMOUNT);
        vm.prank(user);
        source.approve(address(serpent), AMOUNT);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.token_in = address(source);
        steps[0].token_in = address(source);
        vm.expectRevert(Serpent.InputAmountMismatch.selector);
        _run(route, steps);
    }

    function test_swapDoesNotWritePersistentStorage() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        vm.record();
        assertEq(_run(route, steps), AMOUNT);
        (, bytes32[] memory writes) = vm.accesses(address(serpent));
        assertEq(writes.length, 0);
    }

    function test_transientLockAllowsSequentialSwapsInOneTransaction() public {
        BatchCaller batch = new BatchCaller();
        tokenIn.mint(address(batch), AMOUNT * 2);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        (uint256 first, uint256 second) = batch.swapTwice(serpent, route, steps);
        assertEq(first, AMOUNT);
        assertEq(second, AMOUNT);
        assertEq(tokenOut.balanceOf(destination), AMOUNT * 2);
    }

    function test_slippageForTokenOutput() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        route.min_received = AMOUNT + 1;
        vm.expectRevert(Serpent.MinReceivedAmountNotReached.selector);
        _run(route, steps);
    }

    function test_slippageForNativeOutput() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 2, AMOUNT);
        route.min_received = AMOUNT + 1;
        vm.expectRevert(Serpent.MinReceivedAmountNotReached.selector);
        _run(route, steps);
    }

    function test_protocolRevertIsPreservedAndLockRollsBack() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        bytes memory reason = abi.encodeWithSignature("DexUnavailable()");
        vm.mockCallRevert(
            address(v2Router), abi.encodeWithSelector(ISwapRouterV2.swapExactTokensForTokens.selector), reason
        );
        vm.expectRevert(reason);
        _run(route, steps);
        vm.clearMockedCalls();
        assertEq(_run(route, steps), AMOUNT);
    }

    function testFuzz_revertDataPreserved(uint16 lengthSeed) public {
        uint256 length = bound(uint256(lengthSeed), 1, 300);
        bytes memory reason = new bytes(length);
        reason[length - 1] = 0x01;
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 1, AMOUNT);
        vm.mockCallRevert(
            address(v2Router), abi.encodeWithSelector(ISwapRouterV2.swapExactTokensForTokens.selector), reason
        );
        vm.expectRevert(reason);
        _run(route, steps);
    }

    function test_v3ShortReturnDataRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        vm.mockCall(address(v3Router), abi.encodeWithSelector(IOriginalV3Router.exactInputSingle.selector), hex"01");
        vm.expectRevert(BaseWrapper.ExternalCallFailed.selector);
        _run(route, steps);
    }

    function test_invalidPoolRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        steps[0].pool_address = address(0);
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
    }

    function test_invalidPoolFeeRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2, AMOUNT);
        vm.mockCall(address(v3Pool), abi.encodeWithSignature("fee()"), abi.encode(uint256(type(uint24).max) + 1));
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
    }

    function test_wrongWrappedNativeRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 1, AMOUNT);
        route.token_in = address(tokenIn);
        steps[0].token_in = address(tokenIn);
        vm.expectRevert(BaseWrapper.InvalidWrappedNative.selector);
        _run(route, steps);
    }

    function test_wrappersRequireDelegateCall() public {
        vm.expectRevert(BaseWrapper.OnlyDelegateCall.selector);
        v2.swapTokenToToken(address(tokenIn), address(tokenOut), AMOUNT, destination, address(0));
        vm.expectRevert(BaseWrapper.OnlyDelegateCall.selector);
        v3.swapTokenToToken(address(tokenIn), address(tokenOut), AMOUNT, destination, address(v3Pool));
    }

    function test_removeSwapperUsesMappingSlot() public {
        vm.prank(owner);
        serpent.removeSwapper(1);
        assertEq(serpent.swappers(1), address(0));
        assertEq(serpent.swappers(2), address(v3));
        assertEq(serpent.owner(), owner);
        vm.prank(owner);
        serpent.addSwapper(1, address(v2));
        assertEq(serpent.swappers(1), address(v2));
    }

    function test_registryOnlyOwner() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        serpent.addSwapper(7, address(v2));
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        serpent.removeSwapper(1);
    }

    function test_registryRejectsZeroDuplicateAndNoCode() public {
        vm.startPrank(owner);
        vm.expectRevert(Serpent.AddressZero.selector);
        serpent.addSwapper(3, address(0));
        vm.expectRevert(Serpent.AlreadySet.selector);
        serpent.addSwapper(1, address(v3));
        vm.expectRevert(Serpent.SwapperHasNoCode.selector);
        serpent.addSwapper(3, user);
        vm.stopPrank();
    }

    function test_sweepDifferentTokensWithEqualLengths() public {
        tokenIn.mint(address(serpent), 19);
        tokenOut.mint(address(serpent), 23);
        address[] memory tokens = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        tokens[0] = address(tokenIn);
        tokens[1] = address(tokenOut);
        amounts[0] = 19;
        amounts[1] = 23;
        vm.prank(owner);
        serpent.sweepStuckTokens(tokens, amounts, destination);
        assertEq(tokenIn.balanceOf(destination), 19);
        assertEq(tokenOut.balanceOf(destination), 23);
    }

    function test_sweepLengthsMismatch() public {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](0);
        tokens[0] = address(tokenIn);
        vm.prank(owner);
        vm.expectRevert(Serpent.ArrayLengthsMismatching.selector);
        serpent.sweepStuckTokens(tokens, amounts, destination);
    }

    function test_sweepTokenAndEther() public {
        tokenIn.mint(address(serpent), 31);
        vm.deal(address(serpent), 37);
        vm.startPrank(owner);
        serpent.sweepStuckToken(address(tokenIn), 31, destination);
        serpent.sweepStuckEther(destination);
        vm.stopPrank();
        assertEq(tokenIn.balanceOf(destination), 31);
        assertEq(destination.balance, 37);
    }
}
