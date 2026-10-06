// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper} from "../../src/wrappers/V2Wrapper.sol";
import {V3Wrapper02} from "../../src/wrappers/V3Wrapper02.sol";
import {SlipstreamWrapper} from "../../src/wrappers/SlipstreamWrapper.sol";

interface IArcToken {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Requires Arc Foundry (--network arc). USDC funding uses its real native/ERC-20 shared balance.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract ArcProviderForkTest is Test {
    address private constant USDC = 0x3600000000000000000000000000000000000000;
    address private constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address private constant PLACEHOLDER = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address private constant ARCHERY_ROUTER = 0x3b37e67c973683f7FE8a0F304DEdfAf475fEc138;
    address private constant ARCHERY_POOL = 0xb88C08E31C1bC7d41f2cFc4FbAfAD5B3B0a5eAe9;
    address private constant EURC_HOLDER = 0x539F15Eb6108a749C04F33c5D2BD23AcB6a6801A;
    address private constant RECIPIENT = address(0xbeef);
    address private user;
    Serpent private serpent;
    string private fixture;
    string private gasGroup;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_ARC_FORK", false), "Arc route fork requires Arc Foundry and explicit opt-in");
        fixture = vm.readFile("test/fixtures/provider-routes-arc.json");
        assertEq(vm.parseJsonUint(fixture, ".schemaVersion"), 1);
        assertEq(vm.parseJsonUint(fixture, ".chainId"), 5042);
        uint256 forkBlock = vm.parseJsonUint(fixture, ".blockNumber");
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.mainnet.arc.io")), forkBlock);
        assertEq(block.chainid, 5042);
        assertEq(block.number, forkBlock);
        gasGroup = string.concat("ProviderRoutes_5042_", vm.toString(forkBlock));
        user = makeAddr("serpent-arc-provider-fork-user");
        assertEq(user.code.length, 0);
        vm.deal(user, 10_000 ether + 17);
        assertEq(IArcToken(USDC).balanceOf(user), user.balance / 1e12, "Arc execution semantics required");
        serpent = new Serpent(address(this));
        serpent.addSwapper(1, address(new V2Wrapper(0x1f7d7550B1b028f7571E69A784071F0205FD2EfA)));
        serpent.addSwapper(2, address(new V3Wrapper02(0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77, PLACEHOLDER)));
        serpent.addSwapper(3, address(new SlipstreamWrapper(ARCHERY_ROUTER, PLACEHOLDER)));
        vm.deal(address(serpent), 2 ether + 123);
        assertEq(EURC_HOLDER.code.length, 0);
        assertGe(IArcToken(EURC).balanceOf(EURC_HOLDER), 101e6);
        // An ordinary transfer on the local fork funds EURC without changing any quoted pool.
        vm.prank(EURC_HOLDER);
        SafeTransferLib.safeTransfer(EURC, user, 101e6);
        vm.startPrank(user, user);
        SafeTransferLib.safeApprove(USDC, address(serpent), type(uint256).max);
        SafeTransferLib.safeApprove(EURC, address(serpent), type(uint256).max);
        // Preserve an unrelated token baseline and sub-micro-USDC native dust through both directions.
        SafeTransferLib.safeTransfer(EURC, address(serpent), 1e6);
        vm.stopPrank();
    }

    function _step(address input, address output, bytes1 kind)
        private
        pure
        returns (Serpent.SwapParams[] memory steps)
    {
        steps = new Serpent.SwapParams[](1);
        steps[0] = Serpent.SwapParams(input, output, 1_000_000, 3, ARCHERY_POOL, kind);
    }

    function _run(uint256 caseIndex) private {
        string memory prefix = string.concat(".cases[", vm.toString(caseIndex), "]");
        uint256 count = vm.parseJsonUint(fixture, string.concat(prefix, ".candidateCount"));
        assertGt(count, 0);
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < count; ++i) {
            if (i != 0) assertTrue(vm.revertToState(snapshot));
            string memory candidate = string.concat(prefix, ".candidates[", vm.toString(i), "]");
            bytes memory data = vm.parseJsonBytes(fixture, string.concat(candidate, ".data"));
            uint256 expected = vm.parseUint(vm.parseJsonString(fixture, string.concat(candidate, ".amountOut")));
            uint256 amount = vm.parseUint(vm.parseJsonString(fixture, string.concat(prefix, ".amountIn")));
            address input = vm.parseJsonAddress(fixture, string.concat(prefix, ".tokenIn"));
            address output = vm.parseJsonAddress(fixture, string.concat(prefix, ".tokenOut"));
            uint256 inputBefore = IArcToken(input).balanceOf(user);
            uint256 outputBefore = IArcToken(output).balanceOf(RECIPIENT);
            uint256 userNative = user.balance;
            uint256 recipientNative = RECIPIENT.balance;
            uint256 routerNative = address(serpent).balance;
            uint256 routerUsdc = IArcToken(USDC).balanceOf(address(serpent));
            uint256 routerEurc = IArcToken(EURC).balanceOf(address(serpent));
            assertEq(vm.parseUint(vm.parseJsonString(fixture, string.concat(candidate, ".value"))), 0);
            assertEq(bytes4(data), Serpent.swap.selector);
            vm.prank(user, user);
            (bool success, bytes memory result) = address(serpent).call(data);
            vm.snapshotGasLastCall(
                gasGroup, string.concat("case_", vm.toString(caseIndex), "_candidate_", vm.toString(i))
            );
            assertTrue(success, "provider plan executes through Serpent under Arc rules");
            assertEq(abi.decode(result, (uint256)), expected, "exact re-quote/execution parity");
            assertEq(inputBefore - IArcToken(input).balanceOf(user), amount);
            assertEq(IArcToken(output).balanceOf(RECIPIENT) - outputBefore, expected);
            assertEq(IArcToken(USDC).balanceOf(address(serpent)), routerUsdc);
            assertEq(IArcToken(EURC).balanceOf(address(serpent)), routerEurc);
            assertEq(address(serpent).balance, routerNative, "shared native baseline and dust preserved");
            if (input == USDC) assertEq(userNative - user.balance, amount * 1e12);
            if (output == USDC) assertEq(RECIPIENT.balance - recipientNative, expected * 1e12);
        }
    }

    function test_providerUsdcToEurc() public {
        _run(0);
    }

    function test_providerEurcToUsdc() public {
        _run(1);
    }

    function test_nativeWrappingPathsRejectAndPreserveBalances() public {
        uint256 beforeNative = address(serpent).balance;
        uint256 beforeUsdc = IArcToken(USDC).balanceOf(user);
        uint256 beforeEurc = IArcToken(EURC).balanceOf(user);
        Serpent.RouteParam memory input = Serpent.RouteParam(USDC, EURC, 1 ether, 1, user, 0x01);
        vm.expectRevert();
        vm.prank(user, user);
        serpent.swap{value: 1 ether}(input, _step(USDC, EURC, 0x01));
        Serpent.RouteParam memory output = Serpent.RouteParam(EURC, USDC, 1e6, 1, user, 0x02);
        vm.expectRevert();
        vm.prank(user, user);
        serpent.swap(output, _step(EURC, USDC, 0x02));
        assertEq(address(serpent).balance, beforeNative);
        assertEq(IArcToken(USDC).balanceOf(user), beforeUsdc);
        assertEq(IArcToken(EURC).balanceOf(user), beforeEurc);
    }
}
