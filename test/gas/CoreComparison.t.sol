// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "../Serpent.t.sol";
import {Serpent} from "../../src/Serpent.sol";
import {ISerpent} from "../../src/interfaces/ISerpent.sol";
import {SolidityCoreReference} from "./reference/SolidityCore.sol";

/// @dev Identical adapters and token state; only the core implementation differs.
contract CoreGasTest is RouterTestBase {
    ISerpent private referenceRouter;

    function setUp() public override {
        super.setUp();
        referenceRouter = ISerpent(address(new SolidityCoreReference(owner)));
        vm.startPrank(owner);
        referenceRouter.addSwapper(1, address(v2));
        referenceRouter.addSwapper(2, address(v3));
        vm.stopPrank();
        vm.prank(user);
        tokenIn.approve(address(referenceRouter), type(uint256).max);
    }

    function _compare(Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps, string memory name) private {
        uint256 initialState = vm.snapshotState();
        uint256 yulOutput = _run(route, steps);
        uint256 yulGas = vm.snapshotGasLastCall("CoreGas", string.concat(name, "_yul"));
        // Restore token balances, allowances and supply; isolate=true gives both calls cold state.
        assertTrue(vm.revertToState(initialState));
        vm.prank(user);
        uint256 solidityOutput =
            referenceRouter.swap{value: route.swap_type == 0x01 ? route.amount_in : 0}(route, steps);
        uint256 solidityGas = vm.snapshotGasLastCall("CoreGas", string.concat(name, "_solidity"));
        assertEq(yulOutput, solidityOutput);
        assertEq(solidityOutput, route.amount_in);
        assertLt(yulGas, solidityGas);
        assertLt(address(serpent).code.length, address(referenceRouter).code.length);
    }

    function _singleComparison(bytes1 kind, uint256 protocol, string memory name) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, protocol, AMOUNT);
        _compare(route, steps, name);
    }

    function test_compareV2EthToTokenCore() public {
        _singleComparison(0x01, 1, "v2_eth_to_token");
    }

    function test_compareV2TokenToEthCore() public {
        _singleComparison(0x02, 1, "v2_token_to_eth");
    }

    function test_compareV2TokenToTokenCore() public {
        _singleComparison(0x03, 1, "v2_token_to_token");
    }

    function test_compareV3EthToTokenCore() public {
        _singleComparison(0x01, 2, "v3_eth_to_token");
    }

    function test_compareV3TokenToEthCore() public {
        _singleComparison(0x02, 2, "v3_token_to_eth");
    }

    function test_compareV3TokenToTokenCore() public {
        _singleComparison(0x03, 2, "v3_token_to_token");
    }

    function test_compareMixedTwoHopCore() public {
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), AMOUNT, AMOUNT, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(intermediate), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), 1_000_000, 2, 0x03);
        _compare(route, steps, "mixed_two_hop");
    }

    function test_compareMixedSplitCore() public {
        (Serpent.RouteParam memory route,) = _single(0x03, 1, AMOUNT);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(tokenOut), 600_000, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(tokenOut), 400_000, 2, 0x03);
        _compare(route, steps, "mixed_split");
    }
}
