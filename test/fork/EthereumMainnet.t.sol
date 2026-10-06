// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper, ISwapRouterV2} from "../../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../../src/wrappers/V3Wrapper.sol";

interface IERC20Mainnet {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
}

interface IWETHMainnet {
    function deposit() external payable;
}

interface IV3Mainnet {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
    function unwrapWETH9(uint256 minimum, address recipient) external payable;
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

interface IV3FactoryMainnet {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IV3PoolMainnet {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IPermit2Mainnet {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function allowance(address owner, address token, address spender) external view returns (uint160, uint48, uint48);
}

/// @dev Positive integration tests against deployed bytecode. No token, pool or router is mocked.
/// Funding is local ETH plus real WETH deposits and a real V2 swap on the fork.
contract EthereumMainnetForkTest is Test {
    uint256 internal constant PINNED_BLOCK = 26_128_515;
    uint256 internal constant USER_PK = 0xA11CE;
    uint256 internal constant ETH_AMOUNT = 0.01 ether;
    uint256 internal constant USDC_AMOUNT = 10e6;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address private user;
    address private destination;
    address private ethUsdcPool;
    address private usdcDaiPool;
    Serpent private serpent;
    string private gasGroup;

    function setUp() public {
        vm.skip(!vm.envOr("RUN_MAINNET_FORK", false), "Ethereum mainnet fork is opt-in");
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", PINNED_BLOCK);
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 1, "Ethereum chain");
        assertEq(block.number, forkBlock, "pinned block");
        gasGroup = string.concat("EthereumMainnet_", vm.toString(forkBlock));
        user = vm.addr(USER_PK);
        destination = makeAddr("mainnet-fork-recipient");
        serpent = new Serpent(address(this));
        serpent.addSwapper(1, address(new V2Wrapper(V2_ROUTER)));
        serpent.addSwapper(2, address(new V3Wrapper(V3_ROUTER, WETH)));
        ethUsdcPool = IV3FactoryMainnet(V3_FACTORY).getPool(WETH, USDC, 500);
        usdcDaiPool = IV3FactoryMainnet(V3_FACTORY).getPool(USDC, DAI, 100);
        assertGt(ethUsdcPool.code.length, 0, "WETH/USDC pool");
        assertGt(usdcDaiPool.code.length, 0, "USDC/DAI pool");

        vm.deal(user, 20 ether);
        vm.startPrank(user);
        IWETHMainnet(WETH).deposit{value: 2 ether}();
        // Buy the source USDC through the real router rather than patching token storage.
        ISwapRouterV2(V2_ROUTER).swapExactETHForTokens{value: 1 ether}(0, _path(WETH, USDC), user, block.timestamp);
        assertGe(IERC20Mainnet(USDC).balanceOf(user), USDC_AMOUNT);
        SafeTransferLib.safeApprove(WETH, address(serpent), type(uint256).max);
        SafeTransferLib.safeApprove(USDC, address(serpent), type(uint256).max);
        // Direct-call benchmarks use an already approved user, including setup's V2 allowance.
        SafeTransferLib.safeApprove(WETH, V2_ROUTER, type(uint256).max);
        SafeTransferLib.safeApprove(WETH, V3_ROUTER, type(uint256).max);
        SafeTransferLib.safeApprove(USDC, V2_ROUTER, type(uint256).max);
        SafeTransferLib.safeApprove(USDC, V3_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    function _path(address tokenIn, address tokenOut) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
    }

    function _step(address input, address output, uint32 rate, uint256 protocol, bytes1 kind)
        private
        view
        returns (Serpent.SwapParams memory)
    {
        address pool = protocol == 2 ? (input == DAI || output == DAI ? usdcDaiPool : ethUsdcPool) : address(0);
        return Serpent.SwapParams(input, output, rate, protocol, pool, kind);
    }

    function _single(bytes1 kind, uint256 protocol)
        private
        view
        returns (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps)
    {
        address input = kind == 0x02 ? USDC : WETH;
        address output = kind == 0x02 ? WETH : USDC;
        uint256 amount = kind == 0x02 ? USDC_AMOUNT : ETH_AMOUNT;
        route = Serpent.RouteParam(input, output, amount, 1, destination, kind);
        steps = new Serpent.SwapParams[](1);
        steps[0] = _step(input, output, 1_000_000, protocol, kind);
    }

    // Independently compiler-encoded calls to the deployed protocol routers.
    function _direct(Serpent.SwapParams memory step, uint256 amount, address recipient)
        private
        returns (uint256 output)
    {
        vm.startPrank(user);
        if (step.protocol_id == 1) {
            uint256[] memory amounts;
            if (step.swap_type == 0x01) {
                amounts = ISwapRouterV2(V2_ROUTER).swapExactETHForTokens{value: amount}(
                    0, _path(step.token_in, step.token_out), recipient, block.timestamp
                );
            } else if (step.swap_type == 0x02) {
                amounts = ISwapRouterV2(V2_ROUTER)
                    .swapExactTokensForETH(amount, 0, _path(step.token_in, step.token_out), recipient, block.timestamp);
            } else {
                amounts = ISwapRouterV2(V2_ROUTER)
                    .swapExactTokensForTokens(
                        amount, 0, _path(step.token_in, step.token_out), recipient, block.timestamp
                    );
            }
            output = amounts[1];
        } else {
            IV3Mainnet.ExactInputSingleParams memory params = IV3Mainnet.ExactInputSingleParams({
                tokenIn: step.token_in,
                tokenOut: step.token_out,
                fee: IV3PoolMainnet(step.pool_address).fee(),
                recipient: step.swap_type == 0x02 ? V3_ROUTER : recipient,
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            if (step.swap_type == 0x02) {
                // Match a complete native-output operation, including unwrap, in one external call.
                bytes[] memory calls = new bytes[](2);
                calls[0] = abi.encodeCall(IV3Mainnet.exactInputSingle, (params));
                calls[1] = abi.encodeCall(IV3Mainnet.unwrapWETH9, (0, recipient));
                bytes[] memory results = IV3Mainnet(V3_ROUTER).multicall(calls);
                output = abi.decode(results[0], (uint256));
            } else {
                output = IV3Mainnet(V3_ROUTER).exactInputSingle{value: step.swap_type == 0x01 ? amount : 0}(params);
            }
        }
        vm.stopPrank();
    }

    function _balance(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20Mainnet(token).balanceOf(account);
    }

    function _settle(
        Serpent.RouteParam memory route,
        Serpent.SwapParams[] memory steps,
        uint256 expected,
        string memory name
    ) private {
        address input = route.swap_type == 0x01 ? address(0) : route.token_in;
        address output = route.swap_type == 0x02 ? address(0) : route.token_out;
        uint256 beforeInput = _balance(input, user);
        uint256 beforeOutput = _balance(output, destination);
        uint256[4] memory baselines = [
            address(serpent).balance,
            IERC20Mainnet(WETH).balanceOf(address(serpent)),
            IERC20Mainnet(USDC).balanceOf(address(serpent)),
            IERC20Mainnet(DAI).balanceOf(address(serpent))
        ];
        route.min_received = expected;
        vm.prank(user);
        uint256 received = serpent.swap{value: route.swap_type == 0x01 ? route.amount_in : 0}(route, steps);
        vm.snapshotGasLastCall(gasGroup, string.concat(name, "_serpent"));
        assertGt(expected, 0);
        assertEq(received, expected, "same output as protocol reference");
        assertEq(_balance(output, destination) - beforeOutput, received, "credited output");
        assertEq(beforeInput - _balance(input, user), route.amount_in, "consumed input");
        assertEq(address(serpent).balance, baselines[0], "ETH baseline");
        assertEq(IERC20Mainnet(WETH).balanceOf(address(serpent)), baselines[1], "WETH baseline");
        assertEq(IERC20Mainnet(USDC).balanceOf(address(serpent)), baselines[2], "USDC baseline");
        assertEq(IERC20Mainnet(DAI).balanceOf(address(serpent)), baselines[3], "DAI baseline");
    }

    function _compareSingle(bytes1 kind, uint256 protocol, string memory name) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, protocol);
        address output = kind == 0x02 ? address(0) : route.token_out;
        uint256 beforeOutput = _balance(output, destination);
        uint256 state = vm.snapshotState();
        uint256 expected = _direct(steps[0], route.amount_in, destination);
        vm.snapshotGasLastCall(gasGroup, string.concat(name, "_direct"));
        assertEq(_balance(output, destination) - beforeOutput, expected, "reference credit");
        assertTrue(vm.revertToState(state));
        _settle(route, steps, expected, name);
    }

    function test_deploymentRelationships() public view {
        assertEq(ISwapRouterV2(V2_ROUTER).WETH(), WETH);
        assertEq(IV3Mainnet(V3_ROUTER).WETH9(), WETH);
        assertEq(IV3Mainnet(V3_ROUTER).factory(), V3_FACTORY);
        assertEq(IV3PoolMainnet(ethUsdcPool).fee(), 500);
        assertEq(IV3PoolMainnet(ethUsdcPool).token0(), USDC);
        assertEq(IV3PoolMainnet(ethUsdcPool).token1(), WETH);
        assertEq(IV3PoolMainnet(usdcDaiPool).fee(), 100);
        assertEq(IV3PoolMainnet(usdcDaiPool).token0(), DAI);
        assertEq(IV3PoolMainnet(usdcDaiPool).token1(), USDC);
    }

    function test_v2EthToToken() public {
        _compareSingle(0x01, 1, "v2_eth_to_usdc");
    }

    function test_v2TokenToEth() public {
        _compareSingle(0x02, 1, "v2_usdc_to_eth");
    }

    function test_v2TokenToToken() public {
        _compareSingle(0x03, 1, "v2_weth_to_usdc");
    }

    function test_v3EthToToken() public {
        _compareSingle(0x01, 2, "v3_eth_to_usdc");
    }

    function test_v3TokenToEth() public {
        _compareSingle(0x02, 2, "v3_usdc_to_eth");
    }

    function test_v3TokenToToken() public {
        _compareSingle(0x03, 2, "v3_weth_to_usdc");
    }

    function test_mixedNativeInputSplit() public {
        (Serpent.RouteParam memory route,) = _single(0x01, 1);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(WETH, USDC, 600_001, 1, 0x01);
        steps[1] = _step(WETH, USDC, 399_999, 2, 0x01);
        uint256 state = vm.snapshotState();
        uint256 firstAmount = route.amount_in * 600_001 / 1_000_000;
        uint256 expected = _direct(steps[0], firstAmount, destination);
        expected += _direct(steps[1], route.amount_in - firstAmount, destination);
        assertTrue(vm.revertToState(state));
        _settle(route, steps, expected, "mixed_native_split");
    }

    function test_mixedTwoHop() public {
        Serpent.RouteParam memory route = Serpent.RouteParam(WETH, DAI, ETH_AMOUNT, 1, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(WETH, USDC, 1_000_000, 1, 0x03);
        steps[1] = _step(USDC, DAI, 1_000_000, 2, 0x03);
        uint256 state = vm.snapshotState();
        uint256 intermediate = _direct(steps[0], route.amount_in, user);
        uint256 expected = _direct(steps[1], intermediate, destination);
        assertTrue(vm.revertToState(state));
        _settle(route, steps, expected, "mixed_weth_usdc_dai");
    }

    function test_nativeIntermediateIsDistinctFromWETH() public {
        vm.prank(user);
        SafeTransferLib.safeTransfer(WETH, address(serpent), 71);
        Serpent.RouteParam memory route = Serpent.RouteParam(USDC, DAI, USDC_AMOUNT, 1, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(USDC, WETH, 1_000_000, 2, 0x02);
        steps[1] = _step(WETH, DAI, 1_000_000, 1, 0x01);
        uint256 state = vm.snapshotState();
        uint256 intermediate = _direct(steps[0], route.amount_in, user);
        uint256 expected = _direct(steps[1], intermediate, destination);
        assertTrue(vm.revertToState(state));
        _settle(route, steps, expected, "mixed_usdc_eth_dai_with_weth_dust");
    }

    function _prefundRouter() private {
        vm.deal(address(serpent), 173);
        vm.startPrank(user);
        SafeTransferLib.safeTransfer(WETH, address(serpent), 179);
        SafeTransferLib.safeTransfer(USDC, address(serpent), 181);
        vm.stopPrank();
    }

    function test_existingBalancesPreservedOnNativeInput() public {
        _prefundRouter();
        _compareSingle(0x01, 2, "dust_v3_eth_to_usdc");
    }

    function test_existingBalancesPreservedOnNativeOutput() public {
        _prefundRouter();
        _compareSingle(0x02, 2, "dust_v3_usdc_to_eth");
    }

    function _quote(Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps)
        private
        returns (uint256 expected)
    {
        uint256 state = vm.snapshotState();
        expected = _direct(steps[0], route.amount_in, destination);
        assertTrue(vm.revertToState(state));
    }

    function test_usdcNativePermit() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x02, 2);
        route.min_received = _quote(route, steps);
        vm.prank(user);
        SafeTransferLib.safeApprove(USDC, address(serpent), 0);
        uint256 nonce = IERC20Mainnet(USDC).nonces(user);
        uint256 deadline = block.timestamp + 300;
        bytes32 dataHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(serpent),
                route.amount_in,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(USER_PK, keccak256(abi.encodePacked("\x19\x01", IERC20Mainnet(USDC).DOMAIN_SEPARATOR(), dataHash)));
        uint256 beforeInput = IERC20Mainnet(USDC).balanceOf(user);
        uint256 beforeOutput = destination.balance;
        vm.prank(user);
        uint256 received = serpent.swapWithPermit(route, steps, deadline, v, r, s);
        vm.snapshotGasLastCall(gasGroup, "usdc_eip2612_to_eth");
        assertEq(received, route.min_received);
        assertEq(destination.balance - beforeOutput, received);
        assertEq(beforeInput - IERC20Mainnet(USDC).balanceOf(user), route.amount_in);
        assertEq(IERC20Mainnet(USDC).nonces(user), nonce + 1);
        assertEq(IERC20Mainnet(USDC).allowance(user, address(serpent)), 0);
    }

    function test_canonicalPermit2SignatureAndTransfer() public {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(0x03, 2);
        route.min_received = _quote(route, steps);
        vm.startPrank(user);
        SafeTransferLib.safeApprove(WETH, address(serpent), 0);
        SafeTransferLib.safeApprove(WETH, PERMIT2, type(uint256).max);
        vm.stopPrank();
        (,, uint48 nonce) = IPermit2Mainnet(PERMIT2).allowance(user, WETH, address(serpent));
        uint256 deadline = block.timestamp + 300;
        bytes32 detailsHash = keccak256(
            abi.encode(
                keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"),
                WETH,
                uint160(route.amount_in),
                type(uint48).max,
                nonce
            )
        );
        bytes32 permitHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
                ),
                detailsHash,
                address(serpent),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            USER_PK, keccak256(abi.encodePacked("\x19\x01", IPermit2Mainnet(PERMIT2).DOMAIN_SEPARATOR(), permitHash))
        );
        uint256 beforeInput = IERC20Mainnet(WETH).balanceOf(user);
        uint256 beforeOutput = IERC20Mainnet(USDC).balanceOf(destination);
        vm.prank(user);
        uint256 received = serpent.swapWithPermit(route, steps, deadline, v, r, s);
        vm.snapshotGasLastCall(gasGroup, "weth_permit2_to_usdc");
        assertEq(received, route.min_received);
        assertEq(IERC20Mainnet(USDC).balanceOf(destination) - beforeOutput, received);
        assertEq(beforeInput - IERC20Mainnet(WETH).balanceOf(user), route.amount_in);
        assertEq(IERC20Mainnet(WETH).allowance(user, address(serpent)), 0, "Permit2 supplied the transfer");
        (uint160 remaining, uint48 expiry, uint48 nextNonce) =
            IPermit2Mainnet(PERMIT2).allowance(user, WETH, address(serpent));
        assertEq(remaining, 0);
        assertEq(expiry, type(uint48).max);
        assertEq(nextNonce, nonce + 1);
    }

    function _checkSlippage(bytes1 kind, uint256 protocol) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, protocol);
        uint256 expected = _quote(route, steps);
        route.min_received = expected + 1;
        address input = kind == 0x01 ? address(0) : route.token_in;
        uint256 beforeInput = _balance(input, user);
        vm.prank(user);
        vm.expectRevert(Serpent.MinReceivedAmountNotReached.selector);
        serpent.swap{value: kind == 0x01 ? route.amount_in : 0}(route, steps);
        assertEq(_balance(input, user), beforeInput);
        route.min_received = expected;
        vm.prank(user);
        assertEq(serpent.swap{value: kind == 0x01 ? route.amount_in : 0}(route, steps), expected);
    }

    function test_tokenSlippageAndRollback() public {
        _checkSlippage(0x03, 1);
    }

    function test_nativeSlippageAndRollback() public {
        _checkSlippage(0x02, 2);
    }
}
