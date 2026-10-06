// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper} from "../../src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "../../src/wrappers/V3Wrapper.sol";
import {V3Wrapper02} from "../../src/wrappers/V3Wrapper02.sol";
import {SlipstreamWrapper} from "../../src/wrappers/SlipstreamWrapper.sol";

interface IERC20ProviderFork {
    function balanceOf(address) external view returns (uint256);
}

interface IWETHProviderFork {
    function deposit() external payable;
}

interface IFactoryProviderFork {
    function getPool(address, address, uint24) external view returns (address);
}

interface IQuoterProviderFork {
    struct Params {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(Params calldata params) external returns (uint256, uint160, uint32, uint256);
}

/// @dev Fixtures contain Serpent calldata compiled from external provider plans, not provider-router calldata.
/// Tokens and pools retain their deployed code and storage. Funding uses ETH and real WETH deposits.
/// @author 0xpessimist (https://github.com/0xpessimist)
abstract contract ProviderRouteForkBase is Test {
    address internal constant RECIPIENT = address(0xbeef);
    address internal user;
    address internal weth;
    address internal usdc;
    Serpent internal serpent;
    string internal fixture;
    string internal gasGroup;
    address[] private tokens;

    function _chain() internal pure virtual returns (uint256);

    function _enabled() internal view virtual returns (bool) {
        return vm.envOr("RUN_PROVIDER_FORK", false);
    }

    function _fixtureFile() internal pure virtual returns (string memory) {
        return
            _chain() == 8453 ? "test/fixtures/provider-routes-base.json" : "test/fixtures/provider-routes-ethereum.json";
    }

    function setUp() public virtual {
        vm.skip(!_enabled(), "Provider route fork is opt-in");
        bool base = _chain() == 8453;
        fixture = vm.readFile(_fixtureFile());
        assertEq(vm.parseJsonUint(fixture, ".schemaVersion"), 1);
        assertEq(vm.parseJsonUint(fixture, ".chainId"), _chain());
        uint256 forkBlock = vm.parseJsonUint(fixture, ".blockNumber");
        vm.createSelectFork(
            base
                ? vm.envOr("BASE_RPC_URL", string("https://base-rpc.publicnode.com"))
                : vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")),
            forkBlock
        );
        assertEq(block.chainid, _chain());
        assertEq(block.number, forkBlock);
        gasGroup = string.concat("ProviderRoutes_", vm.toString(_chain()), "_", vm.toString(forkBlock));
        weth = base ? 0x4200000000000000000000000000000000000006 : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        usdc = base ? 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 : 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        user = vm.addr(0xa11ce);
        serpent = new Serpent(address(this));
        serpent.addSwapper(
            1,
            address(
                new V2Wrapper(
                    base ? 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24 : 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
                )
            )
        );
        if (base) {
            serpent.addSwapper(3, address(new SlipstreamWrapper(0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5, weth)));
            serpent.addSwapper(4, address(new SlipstreamWrapper(0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D, weth)));
            serpent.addSwapper(5, address(new SlipstreamWrapper(0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F, weth)));
        }
        serpent.addSwapper(
            2,
            base
                ? address(new V3Wrapper02(0x2626664c2603336E57B271c5C0b26F421741e481, weth))
                : address(new V3Wrapper(0xE592427A0AEce92De3Edee1F18E0157C05861564, weth))
        );
        tokens = vm.parseJsonAddressArray(fixture, ".tokens");
        vm.deal(user, 10_000 ether);
        vm.startPrank(user);
        IWETHProviderFork(weth).deposit{value: 1000 ether}();
        SafeTransferLib.safeApprove(weth, address(serpent), type(uint256).max);
        vm.stopPrank();
    }

    function _run(uint256 caseIndex) internal {
        string memory prefix = string.concat(".cases[", vm.toString(caseIndex), "]");
        uint256 count = vm.parseJsonUint(fixture, string.concat(prefix, ".candidateCount"));
        assertGt(count, 0);
        uint256[] memory baselines = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            baselines[i] = IERC20ProviderFork(tokens[i]).balanceOf(address(serpent));
        }
        uint256 ethBaseline = address(serpent).balance;
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
            uint256 beforeInput = input == address(0) ? user.balance : IERC20ProviderFork(input).balanceOf(user);
            uint256 beforeOutput =
                output == address(0) ? RECIPIENT.balance : IERC20ProviderFork(output).balanceOf(RECIPIENT);
            assertEq(bytes4(data), Serpent.swap.selector);
            vm.prank(user);
            (bool success, bytes memory result) = address(serpent).call{value: value}(data);
            vm.snapshotGasLastCall(
                gasGroup, string.concat("case_", vm.toString(caseIndex), "_candidate_", vm.toString(i))
            );
            assertTrue(success, "provider plan executes through Serpent");
            assertEq(abi.decode(result, (uint256)), expected, "exact re-quote/execution parity");
            assertEq(
                (output == address(0) ? RECIPIENT.balance : IERC20ProviderFork(output).balanceOf(RECIPIENT))
                    - beforeOutput,
                expected
            );
            assertEq(
                beforeInput - (input == address(0) ? user.balance : IERC20ProviderFork(input).balanceOf(user)), amount
            );
            for (uint256 j; j < tokens.length; ++j) {
                assertEq(
                    IERC20ProviderFork(tokens[j]).balanceOf(address(serpent)), baselines[j], "token baseline preserved"
                );
            }
            assertEq(address(serpent).balance, ethBaseline, "ETH baseline preserved");
        }
    }
}

contract EthereumProviderForkTest is ProviderRouteForkBase {
    function _chain() internal pure override returns (uint256) {
        return 1;
    }

    function test_providerSmallNativeTrade() public {
        _run(0);
    }

    function test_providerLargeNativeTrade() public {
        _run(1);
    }

    function test_providerWethTrade() public {
        _run(2);
    }
}

contract BaseProviderForkTest is ProviderRouteForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }

    function test_providerSmallNativeTrade() public {
        _run(0);
    }

    function test_providerWethTrade() public {
        _run(1);
    }

    function test_router02RealUsdcToNative() public {
        _run(0); // Acquires real USDC through a fixture swap; quote the reverse direction in that resulting state.
        uint256 amount = IERC20ProviderFork(usdc).balanceOf(RECIPIENT);
        address pool = IFactoryProviderFork(0x33128a8fC17869897dcE68Ed026d694621f6FDfD).getPool(usdc, weth, 100);
        assertTrue(pool != address(0));
        (uint256 expected,,,) = IQuoterProviderFork(0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a)
            .quoteExactInputSingle(IQuoterProviderFork.Params(usdc, weth, amount, 100, 0));
        Serpent.RouteParam memory route = Serpent.RouteParam(usdc, weth, amount, expected, user, 0x02);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](1);
        steps[0] = Serpent.SwapParams(usdc, weth, 1_000_000, 2, pool, 0x02);
        uint256 beforeEth = user.balance;
        uint256 beforeWeth = IERC20ProviderFork(weth).balanceOf(address(serpent));
        vm.startPrank(RECIPIENT);
        SafeTransferLib.safeApprove(usdc, address(serpent), amount);
        assertEq(serpent.swap(route, steps), expected);
        vm.stopPrank();
        assertEq(user.balance - beforeEth, expected);
        assertEq(IERC20ProviderFork(usdc).balanceOf(RECIPIENT), 0);
        assertEq(IERC20ProviderFork(weth).balanceOf(address(serpent)), beforeWeth);
    }
}
