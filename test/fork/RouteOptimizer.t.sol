// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper} from "../../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../../src/wrappers/V3Wrapper.sol";

interface IERC20RouteFork {
    function balanceOf(address) external view returns (uint256);
}

interface IWETHRouteFork {
    function deposit() external payable;
}

/// @dev Reference fixtures quote unmodified pinned mainnet state. Funding uses only ETH and real WETH deposits.
/// Every candidate restores that same pool/token state before execution; no deployed code or storage is replaced.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract RouteOptimizerForkTest is Test {
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant RECIPIENT = address(0xbeef);
    address private user;
    Serpent private serpent;
    string private fixture;
    string private gasGroup;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_ROUTE_FORK", false), "Reference route fork is opt-in");
        fixture = vm.readFile("test/fixtures/ethereum-routes.json");
        assertEq(vm.parseJsonUint(fixture, ".schemaVersion"), 1);
        assertEq(vm.parseJsonUint(fixture, ".chainId"), 1);
        uint256 forkBlock = vm.parseJsonUint(fixture, ".blockNumber");
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), forkBlock);
        assertEq(block.chainid, 1);
        assertEq(block.number, forkBlock);
        gasGroup = string.concat("RouteOptimizer_", vm.toString(forkBlock));
        user = vm.addr(0xa11ce);
        serpent = new Serpent(address(this));
        serpent.addSwapper(1, address(new V2Wrapper(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)));
        serpent.addSwapper(2, address(new V3Wrapper(0xE592427A0AEce92De3Edee1F18E0157C05861564, WETH)));
        vm.deal(user, 10_000 ether);
        vm.startPrank(user);
        IWETHRouteFork(WETH).deposit{value: 1000 ether}();
        SafeTransferLib.safeApprove(WETH, address(serpent), type(uint256).max);
        vm.stopPrank();
    }

    function _run(uint256 caseIndex) private {
        string memory prefix = string.concat(".cases[", vm.toString(caseIndex), "]");
        uint256 count = vm.parseJsonUint(fixture, string.concat(prefix, ".candidateCount"));
        assertGt(count, 0);
        uint256[4] memory baselines = [
            address(serpent).balance,
            IERC20RouteFork(WETH).balanceOf(address(serpent)),
            IERC20RouteFork(USDC).balanceOf(address(serpent)),
            IERC20RouteFork(DAI).balanceOf(address(serpent))
        ];
        uint256 state = vm.snapshotState();
        for (uint256 i; i < count; ++i) {
            if (i != 0) assertTrue(vm.revertToState(state));
            string memory candidate = string.concat(prefix, ".candidates[", vm.toString(i), "]");
            bytes memory data = vm.parseJsonBytes(fixture, string.concat(candidate, ".data"));
            uint256 value = vm.parseUint(vm.parseJsonString(fixture, string.concat(candidate, ".value")));
            uint256 expected = vm.parseUint(vm.parseJsonString(fixture, string.concat(candidate, ".amountOut")));
            address output = vm.parseJsonAddress(fixture, string.concat(prefix, ".tokenOut"));
            address input = vm.parseJsonAddress(fixture, string.concat(prefix, ".tokenIn"));
            uint256 amount = vm.parseUint(vm.parseJsonString(fixture, string.concat(prefix, ".amountIn")));
            uint256 beforeInput = input == address(0) ? user.balance : IERC20RouteFork(input).balanceOf(user);
            uint256 beforeOutput = IERC20RouteFork(output).balanceOf(RECIPIENT);
            assertEq(bytes4(data), Serpent.swap.selector);
            vm.prank(user);
            (bool success, bytes memory result) = address(serpent).call{value: value}(data);
            vm.snapshotGasLastCall(
                gasGroup, string.concat("case_", vm.toString(caseIndex), "_candidate_", vm.toString(i))
            );
            assertTrue(success, "compiled reference route executes");
            assertEq(abi.decode(result, (uint256)), expected, "exact quote/execution parity");
            assertEq(IERC20RouteFork(output).balanceOf(RECIPIENT) - beforeOutput, expected, "recipient receives quote");
            uint256 afterInput = input == address(0) ? user.balance : IERC20RouteFork(input).balanceOf(user);
            assertEq(beforeInput - afterInput, amount, "exact full input consumed");
            assertEq(IERC20RouteFork(WETH).balanceOf(address(serpent)), baselines[1], "WETH baseline preserved");
            assertEq(IERC20RouteFork(USDC).balanceOf(address(serpent)), baselines[2], "USDC baseline preserved");
            assertEq(IERC20RouteFork(DAI).balanceOf(address(serpent)), baselines[3], "DAI baseline preserved");
            assertEq(address(serpent).balance, baselines[0], "ETH baseline preserved");
        }
    }

    function test_referenceSmallNativeTrade() public {
        _run(0);
    }

    function test_referenceLargeNativeTrade() public {
        _run(1);
    }

    function test_referenceLargeWethTrade() public {
        _run(2);
    }

    function test_referenceWethToDai() public {
        _run(3);
    }
}
