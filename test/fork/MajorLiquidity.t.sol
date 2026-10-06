// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V3Wrapper} from "../../src/wrappers/V3Wrapper.sol";
import {SolidlyWrapper} from "../../src/wrappers/SolidlyWrapper.sol";
import {CurveStableNGWrapper} from "../../src/wrappers/CurveStableNGWrapper.sol";
import {ILiquidityToken, ILiquidityQuoter, ILiquidityFactory} from "./LiquidityForks.t.sol";

interface IStableForkPool {
    function get_dy(int128, int128, uint256) external view returns (uint256);
    function coins(uint256) external view returns (address);
    function stable() external view returns (bool);
}

interface ISolidlyForkRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    function getAmountsOut(uint256, Route[] calldata) external view returns (uint256[] memory);
}

/// @dev Real deployed venues, compiled provider graphs and exact output parity at pinned state.
/// Funding is native currency, real wrapping and real swaps; token storage is never overridden.
/// @author 0xpessimist (https://github.com/0xpessimist)
abstract contract MajorLiquidityForkBase is Test {
    string internal json;
    string internal root;
    Serpent internal serpent;
    address internal wrapped;
    address internal user;
    address internal recipient;
    Serpent.RouteParam internal route;
    Serpent.SwapParams[] internal steps;
    address[] internal targets;
    uint256[] internal families; // 1 = Curve NG, 2 = Solidly, 3 = original V3.
    uint256 internal count;

    function _chain() internal pure virtual returns (uint256);

    function setUp() public {
        vm.skip(!vm.envOr("RUN_MAJOR_LIQUIDITY_FORK", false), "Major liquidity forks are opt-in");
        json = vm.readFile("test/fixtures/major-liquidity.json");
        root = string.concat(".chains.", vm.toString(_chain()));
        count = _chain() == 8453 || _chain() == 999 ? 2 : 1;
    }

    function _load(uint256 index) internal {
        string memory prefix = string.concat(root, ".routes[", vm.toString(index), "]");
        string memory rpc = _chain() == 1
            ? vm.envOr("MAINNET_RPC_URL", string("https://eth.drpc.org"))
            : _chain() == 8453
                ? vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"))
                : _chain() == 137
                    ? vm.envOr("POLYGON_RPC_URL", string("https://polygon.drpc.org"))
                    : vm.envOr("HYPEREVM_RPC_URL", string("https://hyperliquid.drpc.org"));
        vm.createSelectFork(rpc, _integer(string.concat(prefix, ".blockNumber")));
        assertEq(block.chainid, _chain());
        wrapped = vm.parseJsonAddress(json, string.concat(root, ".wrappedNative"));
        user = makeAddr("major-liquidity-user");
        recipient = makeAddr("major-liquidity-recipient");
        assertEq(user.code.length, 0);
        assertEq(recipient.code.length, 0);
        serpent = new Serpent(address(this));
        route = Serpent.RouteParam(
            vm.parseJsonAddress(json, string.concat(prefix, ".compiled.route.token_in")),
            vm.parseJsonAddress(json, string.concat(prefix, ".compiled.route.token_out")),
            _integer(string.concat(prefix, ".compiled.route.amount_in")),
            _integer(string.concat(prefix, ".amountOut")),
            recipient,
            0x03
        );
        delete steps;
        delete targets;
        delete families;
        uint256 length = vm.parseJsonUint(json, string.concat(prefix, ".stepCount"));
        for (uint256 i; i < length; ++i) {
            string memory p = string.concat(prefix, ".compiled.steps[", vm.toString(i), "]");
            steps.push(
                Serpent.SwapParams(
                    vm.parseJsonAddress(json, string.concat(p, ".token_in")),
                    vm.parseJsonAddress(json, string.concat(p, ".token_out")),
                    uint32(vm.parseJsonUint(json, string.concat(p, ".rate"))),
                    _integer(string.concat(p, ".protocol_id")),
                    vm.parseJsonAddress(json, string.concat(p, ".pool_address")),
                    0x03
                )
            );
            string memory pool = string.concat(prefix, ".pools[", vm.toString(i), "]");
            address target = vm.parseJsonAddress(json, string.concat(pool, ".router"));
            uint256 family = keccak256(bytes(vm.parseJsonString(json, string.concat(pool, ".kind"))))
                == keccak256("curve-stable-ng")
                ? 1
                : keccak256(bytes(vm.parseJsonString(json, string.concat(pool, ".kind")))) == keccak256("solidly")
                    ? 2
                    : 3;
            targets.push(target);
            families.push(family);
            if (serpent.swappers(steps[i].protocol_id) == address(0)) {
                address adapter = family == 1
                    ? address(new CurveStableNGWrapper(target, wrapped))
                    : family == 2 ? address(new SolidlyWrapper(target)) : address(new V3Wrapper(target, wrapped));
                serpent.addSwapper(steps[i].protocol_id, adapter);
            }
        }
        vm.deal(user, 10_000 ether);
        if (route.token_in == wrapped) {
            vm.prank(user);
            ILiquidityToken(wrapped).deposit{value: route.amount_in}();
        } else {
            _fundInput();
        }
        vm.prank(user);
        SafeTransferLib.safeApprove(route.token_in, address(serpent), route.amount_in);
    }

    function _fundInput() private {
        address factory = _chain() == 1 || _chain() == 137
            ? 0x1F98431c8aD98523631AE4a59f267346ea31F984
            : 0xf0db7b58379503491d857dB50AC9ece64c653918;
        address quoter = _chain() == 1 || _chain() == 137
            ? 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
            : 0x7DfD4F31be6814D2906BDE155c3e1B146EAc1468;
        address router = _chain() == 1 || _chain() == 137
            ? 0xE592427A0AEce92De3Edee1F18E0157C05861564
            : 0x7AdF4701AbCDBc5Dcf5Cb58B526f897e048F0D11;
        if (_chain() == 999) {
            factory = 0xFf7B3e8C00e57ea31477c32A5B52a58Eea47b072;
            quoter = 0x239F11a7A3E08f2B8110D4CA9F6B95d4c8865258;
            router = 0x1EbDFC75FfE3ba3de61E7138a3E8706aC841Af9B;
        }
        uint24[4] memory fees = [uint24(500), 3000, 10000, 100];
        uint256 amount = _chain() == 137 ? 100 ether : _chain() == 999 ? 1 ether : 0.05 ether;
        address pool;
        uint256 expected;
        for (uint256 i; i < fees.length; ++i) {
            address candidate = ILiquidityFactory(factory).getPool(wrapped, route.token_in, fees[i]);
            if (candidate == address(0)) continue;
            try ILiquidityQuoter(quoter)
                .quoteExactInputSingle(ILiquidityQuoter.Params(wrapped, route.token_in, amount, fees[i], 0)) returns (
                uint256 output, uint160 sqrt, uint32, uint256
            ) {
                if (
                    output < route.amount_in || sqrt <= 4295128740
                        || sqrt >= 1461446703485210103287273052203988822378723970341
                ) continue;
                pool = candidate;
                expected = output;
                break;
            } catch {}
        }
        assertTrue(pool != address(0), "real funding pool is required");
        serpent.addSwapper(100, address(new V3Wrapper(router, wrapped)));
        Serpent.RouteParam memory funding = Serpent.RouteParam(wrapped, route.token_in, amount, expected, user, 0x01);
        Serpent.SwapParams[] memory fundingSteps = new Serpent.SwapParams[](1);
        fundingSteps[0] = Serpent.SwapParams(wrapped, route.token_in, 1_000_000, 100, pool, 0x01);
        vm.prank(user);
        assertEq(serpent.swap{value: amount}(funding, fundingSteps), expected);
    }

    function test_allAddedVenuesExecuteCompiledERC20Graphs() public {
        for (uint256 i; i < count; ++i) {
            _load(i);
            _execute(false);
        }
    }

    function test_nativeBoundariesAndReverseGraphs() public {
        for (uint256 i; i < count; ++i) {
            _load(i);
            if (route.token_in != wrapped) continue;
            _execute(true);
            // Reverse the authenticated path and quote each hop against the state after acquisition.
            Serpent.SwapParams[] memory reverse = new Serpent.SwapParams[](steps.length);
            uint256 amount = route.min_received;
            for (uint256 j; j < steps.length; ++j) {
                uint256 k = steps.length - 1 - j;
                assertEq(steps[k].rate, 1_000_000, "fixture is a sequential path");
                reverse[j] = Serpent.SwapParams(
                    steps[k].token_out,
                    steps[k].token_in,
                    1_000_000,
                    steps[k].protocol_id,
                    steps[k].pool_address,
                    j + 1 == steps.length ? bytes1(0x02) : bytes1(0x03)
                );
                amount = _quote(k, reverse[j].token_in, reverse[j].token_out, amount);
            }
            Serpent.RouteParam memory back =
                Serpent.RouteParam(route.token_out, wrapped, route.min_received, amount, user, 0x02);
            vm.prank(recipient);
            SafeTransferLib.safeApprove(route.token_out, address(serpent), back.amount_in);
            uint256 beforeNative = user.balance;
            uint256 baseline = address(serpent).balance;
            vm.prank(recipient);
            assertEq(serpent.swap(back, reverse), amount);
            assertEq(user.balance - beforeNative, amount);
            assertEq(address(serpent).balance, baseline);
        }
    }

    function _execute(bool nativeIn) private {
        Serpent.RouteParam memory trade = route;
        Serpent.SwapParams[] memory graph = steps;
        uint256 beforeInput = nativeIn ? user.balance : ILiquidityToken(trade.token_in).balanceOf(user);
        uint256 beforeOutput = ILiquidityToken(trade.token_out).balanceOf(recipient);
        uint256 nativeBaseline = address(serpent).balance;
        uint256[] memory baselines = new uint256[](steps.length + 1);
        baselines[0] = ILiquidityToken(trade.token_in).balanceOf(address(serpent));
        for (uint256 i; i < steps.length; ++i) {
            baselines[i + 1] = ILiquidityToken(steps[i].token_out).balanceOf(address(serpent));
        }
        if (nativeIn) {
            trade.swap_type = 0x01;
            graph[0].swap_type = 0x01;
        }
        vm.prank(user);
        assertEq(serpent.swap{value: nativeIn ? trade.amount_in : 0}(trade, graph), trade.min_received);
        assertEq(ILiquidityToken(trade.token_out).balanceOf(recipient) - beforeOutput, trade.min_received);
        assertEq(
            beforeInput - (nativeIn ? user.balance : ILiquidityToken(trade.token_in).balanceOf(user)), trade.amount_in
        );
        assertEq(address(serpent).balance, nativeBaseline);
        assertEq(ILiquidityToken(trade.token_in).balanceOf(address(serpent)), baselines[0]);
        for (uint256 i; i < steps.length; ++i) {
            assertEq(ILiquidityToken(steps[i].token_out).balanceOf(address(serpent)), baselines[i + 1]);
        }
    }

    function _quote(uint256 index, address input, address output, uint256 amount) private returns (uint256) {
        if (families[index] == 1) {
            uint256 i;
            uint256 j;
            bool foundI;
            bool foundJ;
            for (uint256 k; k < 8; ++k) {
                try IStableForkPool(steps[index].pool_address).coins(k) returns (address coin) {
                    if (coin == input) {
                        i = k;
                        foundI = true;
                    }
                    if (coin == output) {
                        j = k;
                        foundJ = true;
                    }
                } catch {
                    break;
                }
            }
            assertTrue(foundI && foundJ);
            return IStableForkPool(steps[index].pool_address).get_dy(int128(uint128(i)), int128(uint128(j)), amount);
        }
        if (families[index] == 2) {
            ISolidlyForkRouter.Route[] memory path = new ISolidlyForkRouter.Route[](1);
            path[0] = ISolidlyForkRouter.Route(
                input,
                output,
                IStableForkPool(steps[index].pool_address).stable(),
                0x420DD381b31aEf6683db6B902084cB0FFECe40Da
            );
            return ISolidlyForkRouter(targets[index]).getAmountsOut(amount, path)[1];
        }
        (uint256 out,,,) = ILiquidityQuoter(0x239F11a7A3E08f2B8110D4CA9F6B95d4c8865258)
            .quoteExactInputSingle(ILiquidityQuoter.Params(input, output, amount, 500, 0));
        return out;
    }

    function _integer(string memory key) private view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, key));
    }
}

contract EthereumMajorLiquidityForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseMajorLiquidityForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }
}

contract PolygonMajorLiquidityForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 137;
    }
}

contract HyperEvmMajorLiquidityForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 999;
    }
}
