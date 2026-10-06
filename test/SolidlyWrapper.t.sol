// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "./Serpent.t.sol";
import {MockERC20} from "./mocks/MockDex.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../src/Serpent.sol";
import {BaseWrapper} from "../src/wrappers/BaseWrapper.sol";
import {SolidlyWrapper} from "../src/wrappers/SolidlyWrapper.sol";

contract SolidlyTestPool {
    bool public stable;

    function setStable(bool value) external {
        stable = value;
    }
}

interface ISolidlyTestRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    function swapExactETHForTokens(uint256, Route[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory);
    function swapExactTokensForETH(uint256, uint256, Route[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function swapExactTokensForTokens(uint256, uint256, Route[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

/// @dev Solidity ABI decoding independently validates the dynamic four-field route encoded in Yul.
contract SolidlyTestRouter is ISolidlyTestRouter {
    address public immutable weth;
    address public immutable defaultFactory;

    constructor(address wrapped, address factory) {
        weth = wrapped;
        defaultFactory = factory;
    }
    receive() external payable {}

    function swapExactETHForTokens(uint256 min, Route[] calldata routes, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        require(routes[0].from == weth && msg.data.length == 0x124, "native ABI");
        amounts = _check(routes, min, deadline, msg.value);
        MockERC20(routes[0].to).mint(to, msg.value);
    }

    function swapExactTokensForETH(uint256 amount, uint256 min, Route[] calldata routes, address to, uint256 deadline)
        external
        returns (uint256[] memory amounts)
    {
        require(routes[0].to == weth && msg.data.length == 0x144, "native output ABI");
        amounts = _check(routes, min, deadline, amount);
        SafeTransferLib.safeTransferFrom(routes[0].from, msg.sender, address(this), amount);
        SafeTransferLib.safeTransferETH(to, amount);
    }

    function swapExactTokensForTokens(
        uint256 amount,
        uint256 min,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(msg.data.length == 0x144, "token ABI");
        amounts = _check(routes, min, deadline, amount);
        SafeTransferLib.safeTransferFrom(routes[0].from, msg.sender, address(this), amount);
        MockERC20(routes[0].to).mint(to, amount);
    }

    function _check(Route[] calldata routes, uint256 min, uint256 deadline, uint256 amount)
        private
        view
        returns (uint256[] memory amounts)
    {
        require(routes.length == 1 && routes[0].factory == defaultFactory, "factory tuple");
        require(min == 0 && deadline == block.timestamp, "limits");
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract SolidlyWrapperTest is RouterTestBase {
    SolidlyTestPool private pool;
    SolidlyTestRouter private router;
    SolidlyWrapper private adapter;

    function setUp() public override {
        super.setUp();
        pool = new SolidlyTestPool();
        router = new SolidlyTestRouter(address(weth), address(pool));
        adapter = new SolidlyWrapper(address(router));
        vm.prank(owner);
        serpent.addSwapper(3, address(adapter));
        vm.deal(address(router), 1000 ether);
    }

    function test_allDirectionsAndBothPoolTypes() public {
        uint256 state = vm.snapshotState();
        for (uint256 stable; stable < 2; ++stable) {
            for (uint256 kind = 1; kind <= 3; ++kind) {
                assertTrue(vm.revertToState(state));
                pool.setStable(stable == 1);
                (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) =
                    _single(bytes1(uint8(kind)), 3, AMOUNT);
                steps[0].pool_address = address(pool);
                ISolidlyTestRouter.Route[] memory routes = new ISolidlyTestRouter.Route[](1);
                routes[0] = ISolidlyTestRouter.Route(route.token_in, route.token_out, stable == 1, address(pool));
                bytes memory callData = kind == 1
                    ? abi.encodeCall(
                        ISolidlyTestRouter.swapExactETHForTokens, (0, routes, address(serpent), block.timestamp)
                    )
                    : kind == 2
                        ? abi.encodeCall(
                            ISolidlyTestRouter.swapExactTokensForETH,
                            (AMOUNT, 0, routes, address(serpent), block.timestamp)
                        )
                        : abi.encodeCall(
                            ISolidlyTestRouter.swapExactTokensForTokens,
                            (AMOUNT, 0, routes, address(serpent), block.timestamp)
                        );
                vm.expectCall(address(router), kind == 1 ? AMOUNT : 0, callData);
                vm.deal(address(serpent), 2 ether);
                tokenOut.mint(address(serpent), 3 ether);
                weth.mint(address(serpent), 4 ether);
                assertEq(_run(route, steps), AMOUNT);
                assertEq(kind == 2 ? destination.balance : tokenOut.balanceOf(destination), AMOUNT);
                assertEq(address(serpent).balance, 2 ether);
                assertEq(tokenOut.balanceOf(address(serpent)), 3 ether);
                assertEq(weth.balanceOf(address(serpent)), 4 ether);
            }
        }
    }

    function test_mixedFamilySplitAndRemainder() public {
        (Serpent.RouteParam memory route,) = _single(0x01, 3, 101);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(weth), address(tokenOut), 333_333, 1, 0x01);
        steps[1] = _step(address(weth), address(tokenOut), 666_667, 3, 0x01);
        steps[1].pool_address = address(pool);
        assertEq(_run(route, steps), 101);
        assertEq(tokenOut.balanceOf(destination), 101);
    }

    function test_invalidStableResponsesRevert() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 3, AMOUNT);
        steps[0].pool_address = address(pool);
        vm.mockCall(address(pool), abi.encodeWithSignature("stable()"), abi.encode(uint256(2)));
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
        vm.mockCall(address(pool), abi.encodeWithSignature("stable()"), hex"01");
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
    }

    function test_routerRevertBubblesAndRollsBackApproval() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 3, AMOUNT);
        steps[0].pool_address = address(pool);
        vm.mockCallRevert(
            address(router), bytes(hex"cac88ea9"), abi.encodeWithSignature("Error(string)", "pool unavailable")
        );
        vm.expectRevert("pool unavailable");
        _run(route, steps);
        assertEq(tokenIn.allowance(address(serpent), address(router)), 0);
        assertEq(tokenIn.balanceOf(user), 1000 ether);
    }

    function test_slippageStillEnforcedBySerpent() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x01, 3, AMOUNT);
        steps[0].pool_address = address(pool);
        route.min_received = AMOUNT + 1;
        vm.expectRevert();
        _run(route, steps);
        assertEq(tokenOut.balanceOf(destination), 0);
    }

    function test_requiresDelegatecall() public {
        vm.expectRevert(BaseWrapper.OnlyDelegateCall.selector);
        adapter.swapTokenToToken(address(tokenIn), address(tokenOut), AMOUNT, destination, address(pool));
    }
}
