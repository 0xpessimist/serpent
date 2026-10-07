// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper} from "../../src/wrappers/V2Wrapper.sol";
import {ILiquidityToken, ILiquidityFactory, ILiquidityRouter} from "./LiquidityForks.t.sol";

/// @dev A captured Velora PNK -> DAI -> USDC path, with real native funding and pool state.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract EthereumVeloraV2PathsForkTest is Test {
    address internal constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant WRAPPED = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    Serpent internal serpent;
    Serpent.RouteParam internal route;
    Serpent.SwapParams[] internal steps;
    address internal user;
    address internal recipient;
    uint256 internal nativeBaseline;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_LIQUIDITY_FORK", false), "Liquidity forks are opt-in");
        string memory json = vm.readFile("test/fixtures/velora-v2-paths.json");
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 1);
        uint256 forkBlock = vm.parseUint(vm.parseJsonString(json, ".blockNumber"));
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org")), forkBlock);
        assertEq(block.chainid, 1);
        assertEq(block.number, forkBlock);
        user = makeAddr("velora-v2-path-user");
        recipient = makeAddr("velora-v2-path-recipient");
        assertEq(user.code.length, 0);
        assertEq(recipient.code.length, 0);
        serpent = new Serpent(address(this));
        nativeBaseline = address(serpent).balance;
        serpent.addSwapper(1, address(new V2Wrapper(ROUTER)));
        route = Serpent.RouteParam(
            vm.parseJsonAddress(json, ".compiled.route.token_in"),
            vm.parseJsonAddress(json, ".compiled.route.token_out"),
            vm.parseUint(vm.parseJsonString(json, ".compiled.route.amount_in")),
            vm.parseUint(vm.parseJsonString(json, ".amountOut")),
            recipient,
            0x03
        );
        address factory = ILiquidityRouter(ROUTER).factory();
        for (uint256 i; i < 2; ++i) {
            string memory p = string.concat(".compiled.steps[", vm.toString(i), "]");
            steps.push(
                Serpent.SwapParams(
                    vm.parseJsonAddress(json, string.concat(p, ".token_in")),
                    vm.parseJsonAddress(json, string.concat(p, ".token_out")),
                    uint32(vm.parseJsonUint(json, string.concat(p, ".rate"))),
                    vm.parseUint(vm.parseJsonString(json, string.concat(p, ".protocol_id"))),
                    vm.parseJsonAddress(json, string.concat(p, ".pool_address")),
                    0x03
                )
            );
            assertEq(steps[i].rate, 1_000_000);
            assertEq(steps[i].protocol_id, 1);
            assertEq(ILiquidityRouter(steps[i].pool_address).factory(), factory);
            assertEq(ILiquidityFactory(factory).getPair(steps[i].token_in, steps[i].token_out), steps[i].pool_address);
        }
        assertEq(steps[0].token_in, route.token_in);
        assertEq(steps[0].token_out, steps[1].token_in);
        assertEq(steps[1].token_out, route.token_out);
        // Verify the recorded pinned output before real funding changes the small PNK/DAI pool.
        assertEq(_quote(route.amount_in, false), route.min_received);
        _fundInput(factory);
        vm.prank(user);
        SafeTransferLib.safeApprove(route.token_in, address(serpent), route.amount_in);
    }

    function _fundInput(address factory) private {
        uint256 amount = 0.0001 ether;
        address middle = steps[0].token_out;
        address[] memory path = new address[](3);
        path[0] = WRAPPED;
        path[1] = middle;
        path[2] = route.token_in;
        uint256[] memory amounts = ILiquidityRouter(ROUTER).getAmountsOut(amount, path);
        assertGe(amounts[2], route.amount_in);
        Serpent.SwapParams[] memory fundingSteps = new Serpent.SwapParams[](2);
        fundingSteps[0] = Serpent.SwapParams(
            WRAPPED, middle, 1_000_000, 1, ILiquidityFactory(factory).getPair(WRAPPED, middle), 0x01
        );
        fundingSteps[1] = Serpent.SwapParams(middle, route.token_in, 1_000_000, 1, steps[0].pool_address, 0x03);
        Serpent.RouteParam memory funding = Serpent.RouteParam(WRAPPED, route.token_in, amount, amounts[2], user, 0x01);
        vm.deal(user, 1 ether);
        vm.prank(user);
        assertEq(serpent.swap{value: amount}(funding, fundingSteps), amounts[2]);
        assertEq(ILiquidityToken(route.token_in).balanceOf(user), amounts[2]);
        _assertNoResidue();
    }

    function test_compiledMultiHopV2GraphExecutesWithActualPostFundingOutput() public {
        _forward();
    }

    function test_forwardAndReverseV2PathsKeepPayerRecipientAndIntermediateBalances() public {
        uint256 acquired = _forward();
        uint256 expected = _quote(acquired, true);
        Serpent.SwapParams[] memory reverse = new Serpent.SwapParams[](2);
        reverse[0] =
            Serpent.SwapParams(steps[1].token_out, steps[1].token_in, 1_000_000, 1, steps[1].pool_address, 0x03);
        reverse[1] =
            Serpent.SwapParams(steps[0].token_out, steps[0].token_in, 1_000_000, 1, steps[0].pool_address, 0x03);
        Serpent.RouteParam memory back =
            Serpent.RouteParam(route.token_out, route.token_in, acquired, expected, user, 0x03);
        uint256 beforeInput = ILiquidityToken(route.token_out).balanceOf(recipient);
        uint256 beforeOutput = ILiquidityToken(route.token_in).balanceOf(user);
        vm.prank(recipient);
        SafeTransferLib.safeApprove(route.token_out, address(serpent), acquired);
        vm.prank(recipient);
        assertEq(serpent.swap(back, reverse), expected);
        assertEq(beforeInput - ILiquidityToken(route.token_out).balanceOf(recipient), acquired);
        assertEq(ILiquidityToken(route.token_in).balanceOf(user) - beforeOutput, expected);
        _assertNoResidue();
    }

    function _forward() private returns (uint256 expected) {
        expected = _quote(route.amount_in, false);
        Serpent.RouteParam memory trade = route;
        trade.min_received = expected;
        uint256 beforeInput = ILiquidityToken(trade.token_in).balanceOf(user);
        uint256 beforeOutput = ILiquidityToken(trade.token_out).balanceOf(recipient);
        vm.prank(user);
        assertEq(serpent.swap(trade, steps), expected);
        assertEq(beforeInput - ILiquidityToken(trade.token_in).balanceOf(user), trade.amount_in);
        assertEq(ILiquidityToken(trade.token_out).balanceOf(recipient) - beforeOutput, expected);
        _assertNoResidue();
    }

    function _quote(uint256 amount, bool reverse) private view returns (uint256) {
        address[] memory path = new address[](3);
        path[0] = reverse ? route.token_out : route.token_in;
        path[1] = steps[0].token_out;
        path[2] = reverse ? route.token_in : route.token_out;
        return ILiquidityRouter(ROUTER).getAmountsOut(amount, path)[2];
    }

    function _assertNoResidue() private view {
        assertEq(address(serpent).balance, nativeBaseline);
        assertEq(ILiquidityToken(WRAPPED).balanceOf(address(serpent)), 0);
        assertEq(ILiquidityToken(route.token_in).balanceOf(address(serpent)), 0);
        assertEq(ILiquidityToken(steps[0].token_out).balanceOf(address(serpent)), 0);
        assertEq(ILiquidityToken(route.token_out).balanceOf(address(serpent)), 0);
    }
}
