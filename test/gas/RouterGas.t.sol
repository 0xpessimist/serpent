// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "../Serpent.t.sol";
import {Serpent} from "../../src/Serpent.sol";

/// @dev Run with call isolation (enabled in foundry.toml). These are local mock costs.
contract RouterGasTest is RouterTestBase {
    function _measure(bytes1 kind, uint256 protocol, string memory name) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, protocol, AMOUNT);
        uint256 output = _run(route, steps);
        vm.snapshotGasLastCall("RouterGas", name);
        assertEq(output, AMOUNT);
    }

    function test_gasV2EthToToken() public {
        _measure(0x01, 1, "v2_eth_to_token");
    }

    function test_gasV2TokenToEth() public {
        _measure(0x02, 1, "v2_token_to_eth");
    }

    function test_gasV2TokenToToken() public {
        _measure(0x03, 1, "v2_token_to_token");
    }

    function test_gasV3EthToToken() public {
        _measure(0x01, 2, "v3_eth_to_token");
    }

    function test_gasV3TokenToEth() public {
        _measure(0x02, 2, "v3_token_to_eth");
    }

    function test_gasV3TokenToToken() public {
        _measure(0x03, 2, "v3_token_to_token");
    }

    function test_gasMixedTwoHop() public {
        Serpent.RouteParam memory route =
            Serpent.RouteParam(address(tokenIn), address(tokenOut), AMOUNT, AMOUNT, destination, 0x03);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(intermediate), 1_000_000, 1, 0x03);
        steps[1] = _step(address(intermediate), address(tokenOut), 1_000_000, 2, 0x03);
        uint256 output = _run(route, steps);
        vm.snapshotGasLastCall("RouterGas", "mixed_two_hop");
        assertEq(output, AMOUNT);
    }

    function test_gasMixedSplit() public {
        (Serpent.RouteParam memory route,) = _single(0x03, 1, AMOUNT);
        Serpent.SwapParams[] memory steps = new Serpent.SwapParams[](2);
        steps[0] = _step(address(tokenIn), address(tokenOut), 600_000, 1, 0x03);
        steps[1] = _step(address(tokenIn), address(tokenOut), 400_000, 2, 0x03);
        uint256 output = _run(route, steps);
        vm.snapshotGasLastCall("RouterGas", "mixed_split");
        assertEq(output, AMOUNT);
    }
}
