// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "./Serpent.t.sol";
import {MockERC20} from "./mocks/MockDex.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../src/Serpent.sol";
import {BaseWrapper} from "../src/wrappers/BaseWrapper.sol";
import {CurveStableNGWrapper} from "../src/wrappers/CurveStableNGWrapper.sol";

contract CurveTestFactory {
    mapping(address => address[]) private tokens;

    function register(address pool, address[] memory coins) external {
        tokens[pool] = coins;
    }

    function get_coins(address pool) external view returns (address[] memory) {
        return tokens[pool];
    }
}

contract CurveTestPool {
    address[] public coins;

    constructor(address[] memory tokens) {
        coins = tokens;
    }

    function exchange(int128 i, int128 j, uint256 amount, uint256 min, address to) external returns (uint256) {
        require(msg.data.length == 0xa4 && min == 0 && i >= 0 && j >= 0 && i != j, "Curve ABI");
        SafeTransferLib.safeTransferFrom(coins[uint128(i)], msg.sender, address(this), amount);
        MockERC20(coins[uint128(j)]).mint(to, amount);
        return amount;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract CurveStableNGWrapperTest is RouterTestBase {
    CurveTestFactory private factory;
    CurveTestPool private pool;
    CurveStableNGWrapper private adapter;

    function setUp() public override {
        super.setUp();
        factory = new CurveTestFactory();
        address[] memory coins = new address[](4);
        coins[0] = address(intermediate);
        coins[1] = address(tokenOut);
        coins[2] = address(weth);
        coins[3] = address(tokenIn);
        pool = new CurveTestPool(coins);
        factory.register(address(pool), coins);
        adapter = new CurveStableNGWrapper(address(factory), address(weth));
        vm.prank(owner);
        serpent.addSwapper(3, address(adapter));
    }

    function test_allDirectionsResolveActualCoinIndicesAndPreserveDust() public {
        uint256 state = vm.snapshotState();
        for (uint256 kind = 1; kind <= 3; ++kind) {
            assertTrue(vm.revertToState(state));
            (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) =
                _single(bytes1(uint8(kind)), 3, AMOUNT);
            steps[0].pool_address = address(pool);
            int128 i = kind == 1 ? int128(2) : int128(3);
            int128 j = kind == 2 ? int128(2) : int128(1);
            vm.expectCall(address(pool), abi.encodeCall(CurveTestPool.exchange, (i, j, AMOUNT, 0, address(serpent))));
            tokenOut.mint(address(serpent), 2 ether);
            weth.mint(address(serpent), 3 ether);
            vm.deal(address(serpent), 4 ether);
            assertEq(_run(route, steps), AMOUNT);
            assertEq(kind == 2 ? destination.balance : tokenOut.balanceOf(destination), AMOUNT);
            assertEq(tokenOut.balanceOf(address(serpent)), 2 ether);
            assertEq(weth.balanceOf(address(serpent)), 3 ether);
            assertEq(address(serpent).balance, 4 ether);
            assertEq(MockERC20(route.token_in).allowance(address(serpent), address(pool)), 0);
        }
    }

    function test_eightCoinPoolUsesLastIndex() public {
        address[] memory coins = new address[](8);
        for (uint256 k; k < 7; ++k) {
            coins[k] = address(new MockERC20());
        }
        coins[6] = address(tokenIn);
        coins[7] = address(tokenOut);
        CurveTestPool lastPool = new CurveTestPool(coins);
        factory.register(address(lastPool), coins);
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 3, AMOUNT);
        steps[0].pool_address = address(lastPool);
        vm.expectCall(address(lastPool), abi.encodeCall(CurveTestPool.exchange, (6, 7, AMOUNT, 0, address(serpent))));
        assertEq(_run(route, steps), AMOUNT);
    }

    function test_unknownPoolAndWrongCoinCannotReceiveApproval() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 3, AMOUNT);
        steps[0].pool_address = address(0x1234);
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
        assertEq(tokenIn.allowance(address(serpent), address(0x1234)), 0);
        address[] memory coins = new address[](2);
        coins[0] = address(weth);
        coins[1] = address(tokenOut);
        factory.register(address(pool), coins);
        steps[0].pool_address = address(pool);
        vm.expectRevert(BaseWrapper.InvalidPool.selector);
        _run(route, steps);
        assertEq(tokenIn.allowance(address(serpent), address(pool)), 0);
    }

    function test_malformedFactoryArraysAreRejected() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 3, AMOUNT);
        steps[0].pool_address = address(pool);
        bytes memory getter = abi.encodeCall(CurveTestFactory.get_coins, (address(pool)));
        bytes[] memory malformed = new bytes[](4);
        malformed[0] = hex"00";
        malformed[1] = abi.encode(uint256(64), uint256(2), address(tokenIn), address(tokenOut));
        malformed[2] = abi.encode(uint256(32), uint256(9));
        malformed[3] = abi.encode(uint256(32), uint256(2), address(tokenIn));
        for (uint256 k; k < malformed.length; ++k) {
            vm.mockCall(address(factory), getter, malformed[k]);
            vm.expectRevert(BaseWrapper.InvalidPool.selector);
            _run(route, steps);
        }
    }

    function test_poolRevertBubblesAndMalformedOutputRollsBack() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 3, AMOUNT);
        steps[0].pool_address = address(pool);
        vm.mockCallRevert(
            address(pool), bytes(hex"ddc1f59d"), abi.encodeWithSignature("Error(string)", "pool unavailable")
        );
        vm.expectRevert("pool unavailable");
        _run(route, steps);
        vm.clearMockedCalls();
        vm.mockCall(address(pool), bytes(hex"ddc1f59d"), bytes(hex"01"));
        vm.expectRevert(BaseWrapper.ExternalCallFailed.selector);
        _run(route, steps);
        assertEq(tokenIn.balanceOf(user), 1000 ether);
        assertEq(tokenIn.allowance(address(serpent), address(pool)), 0);
    }

    function test_minimumStillEnforcedBySerpent() public {
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
