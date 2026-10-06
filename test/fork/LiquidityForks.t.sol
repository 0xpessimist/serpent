// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper} from "../../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../../src/wrappers/V3Wrapper.sol";
import {V3Wrapper02} from "../../src/wrappers/V3Wrapper02.sol";

interface ILiquidityToken {
    function balanceOf(address) external view returns (uint256);
    function deposit() external payable;
}

interface ILiquidityFactory {
    function getPair(address, address) external view returns (address);
    function getPool(address, address, uint24) external view returns (address);
}

interface ILiquidityRouter {
    function factory() external view returns (address);
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}

interface ILiquidityQuoter {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);
    function quoteExactInputSingle(Params calldata) external returns (uint256, uint160, uint32, uint256);
}

/// @dev Real pool/router/token code and storage; funding uses native currency and actual deposits.
/// @author 0xpessimist (https://github.com/0xpessimist)
abstract contract LiquidityForkBase is Test {
    struct Deployment {
        uint256 protocol;
        address factory;
        address router;
        address quoter;
        address pool;
        address token;
        uint24 fee;
        uint256 amount;
        uint256 expected;
        bool v2;
    }

    Deployment[] internal deployments;
    address internal wrapped;
    address internal user;
    address internal recipient;
    Serpent internal serpent;

    function _chain() internal pure virtual returns (uint256);

    function setUp() public {
        vm.skip(!vm.envOr("RUN_LIQUIDITY_FORK", false), "Liquidity forks are opt-in");
        string memory json = vm.readFile("test/fixtures/liquidity-forks.json");
        assertEq(vm.parseJsonUint(json, ".schemaVersion"), 1);
        string memory root = string.concat(".chains.", vm.toString(_chain()));
        string memory rpc = _chain() == 1
            ? vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org"))
            : _chain() == 8453
                ? vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"))
                : vm.envOr("POLYGON_RPC_URL", string("https://polygon.drpc.org"));
        uint256 forkBlock = _integer(json, string.concat(root, ".blockNumber"));
        vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, _chain());
        assertEq(block.number, forkBlock);
        wrapped = vm.parseJsonAddress(json, string.concat(root, ".wrappedNative"));
        user = makeAddr("serpent-liquidity-fork-user");
        recipient = makeAddr("serpent-liquidity-fork-recipient");
        assertEq(user.code.length, 0);
        assertEq(recipient.code.length, 0);
        serpent = new Serpent(address(this));
        uint256 count = vm.parseJsonUint(json, string.concat(root, ".deploymentCount"));
        assertEq(count, _chain() == 1 ? 4 : _chain() == 8453 ? 7 : 2);
        for (uint256 i; i < count; ++i) {
            string memory prefix = string.concat(root, ".deployments[", vm.toString(i), "]");
            Deployment memory d;
            d.protocol = _integer(json, string.concat(prefix, ".protocolId"));
            d.factory = vm.parseJsonAddress(json, string.concat(prefix, ".factory"));
            d.router = vm.parseJsonAddress(json, string.concat(prefix, ".router"));
            d.quoter = vm.parseJsonAddress(json, string.concat(prefix, ".quoter"));
            d.pool = vm.parseJsonAddress(json, string.concat(prefix, ".pool"));
            d.token = vm.parseJsonAddress(json, string.concat(prefix, ".tokenOut"));
            d.fee = uint24(vm.parseJsonUint(json, string.concat(prefix, ".fee")));
            d.amount = _integer(json, string.concat(prefix, ".amountIn"));
            d.expected = _integer(json, string.concat(prefix, ".amountOut"));
            d.v2 = keccak256(bytes(vm.parseJsonString(json, string.concat(prefix, ".kind")))) == keccak256("v2");
            assertEq(ILiquidityRouter(d.router).factory(), d.factory);
            assertEq(ILiquidityRouter(d.pool).factory(), d.factory);
            if (d.v2) {
                assertEq(ILiquidityFactory(d.factory).getPair(wrapped, d.token), d.pool);
                serpent.addSwapper(d.protocol, address(new V2Wrapper(d.router)));
            } else {
                assertEq(ILiquidityFactory(d.factory).getPool(wrapped, d.token, d.fee), d.pool);
                assertEq(ILiquidityQuoter(d.quoter).factory(), d.factory);
                bool original = keccak256(bytes(vm.parseJsonString(json, string.concat(prefix, ".routerAbi"))))
                    == keccak256("original");
                serpent.addSwapper(
                    d.protocol,
                    original ? address(new V3Wrapper(d.router, wrapped)) : address(new V3Wrapper02(d.router, wrapped))
                );
            }
            assertEq(_quote(d, wrapped, d.token, d.amount), d.expected);
            deployments.push(d);
        }
        vm.deal(user, 100 ether);
        vm.startPrank(user);
        ILiquidityToken(wrapped).deposit{value: 10 ether}();
        SafeTransferLib.safeApprove(wrapped, address(serpent), type(uint256).max);
        vm.stopPrank();
    }

    function test_nativeInputAcrossEveryAddedFork() public {
        _run(0x01);
    }

    function test_wrappedInputAcrossEveryAddedFork() public {
        _run(0x03);
    }

    function test_tokenToNativeAcrossEveryAddedFork() public {
        _run(0x02);
    }

    function _run(bytes1 kind) private {
        uint256 state = vm.snapshotState();
        for (uint256 i; i < deployments.length; ++i) {
            if (i != 0) assertTrue(vm.revertToState(state));
            Deployment memory d = deployments[i];
            uint256 nativeBaseline = address(serpent).balance;
            uint256 wrappedBaseline = ILiquidityToken(wrapped).balanceOf(address(serpent));
            uint256 tokenBaseline = ILiquidityToken(d.token).balanceOf(address(serpent));
            if (kind == 0x02) {
                // Acquire the real output token first, then quote the reverse trade at the updated state.
                _swap(d, wrapped, d.token, d.amount, d.expected, user, 0x01);
                vm.prank(user);
                SafeTransferLib.safeApprove(d.token, address(serpent), d.expected);
                uint256 output = _quote(d, d.token, wrapped, d.expected);
                uint256 beforeOutput = recipient.balance;
                uint256 beforeInput = ILiquidityToken(d.token).balanceOf(user);
                assertEq(_swap(d, d.token, wrapped, d.expected, output, recipient, 0x02), output);
                assertEq(recipient.balance - beforeOutput, output);
                assertEq(beforeInput - ILiquidityToken(d.token).balanceOf(user), d.expected);
            } else {
                uint256 beforeOutput = ILiquidityToken(d.token).balanceOf(recipient);
                uint256 beforeInput = kind == 0x01 ? user.balance : ILiquidityToken(wrapped).balanceOf(user);
                assertEq(_swap(d, wrapped, d.token, d.amount, d.expected, recipient, kind), d.expected);
                assertEq(ILiquidityToken(d.token).balanceOf(recipient) - beforeOutput, d.expected);
                assertEq(
                    beforeInput - (kind == 0x01 ? user.balance : ILiquidityToken(wrapped).balanceOf(user)), d.amount
                );
            }
            assertEq(address(serpent).balance, nativeBaseline);
            assertEq(ILiquidityToken(wrapped).balanceOf(address(serpent)), wrappedBaseline);
            assertEq(ILiquidityToken(d.token).balanceOf(address(serpent)), tokenBaseline);
        }
    }

    function _swap(
        Deployment memory d,
        address input,
        address output,
        uint256 amount,
        uint256 minimum,
        address receiver,
        bytes1 kind
    ) private returns (uint256) {
        Serpent.RouteParam memory route = Serpent.RouteParam(input, output, amount, minimum, receiver, kind);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](1);
        steps[0] = Serpent.SwapParams(input, output, 1_000_000, d.protocol, d.pool, kind);
        vm.prank(user);
        return serpent.swap{value: kind == 0x01 ? amount : 0}(route, steps);
    }

    function _quote(Deployment memory d, address input, address output, uint256 amount) private returns (uint256) {
        if (d.v2) {
            address[] memory path = new address[](2);
            path[0] = input;
            path[1] = output;
            return ILiquidityRouter(d.router).getAmountsOut(amount, path)[1];
        }
        (uint256 result,,,) =
            ILiquidityQuoter(d.quoter).quoteExactInputSingle(ILiquidityQuoter.Params(input, output, amount, d.fee, 0));
        return result;
    }

    function _integer(string memory json, string memory key) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }
}

contract EthereumLiquidityForkTest is LiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseLiquidityForkTest is LiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }
}

contract PolygonLiquidityForkTest is LiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 137;
    }
}
