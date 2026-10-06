// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {RouterTestBase} from "../Serpent.t.sol";
import {Serpent} from "../../src/Serpent.sol";
import {V2Wrapper, ISwapRouterV2} from "../../src/wrappers/V2Wrapper.sol";

/// @dev Same adapter behavior and return-data handling; only calldata construction differs.
contract V2AbiWrapper is V2Wrapper {
    constructor(address router) V2Wrapper(router) {}

    function _callRouter(address tokenIn, address tokenOut, uint256 amountIn, address to, uint256 kind)
        internal
        override
    {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        bytes memory data;
        uint256 value;
        if (kind == 1) {
            data = abi.encodeCall(ISwapRouterV2.swapExactETHForTokens, (0, path, to, block.timestamp));
            value = amountIn;
        } else if (kind == 2) {
            data = abi.encodeCall(ISwapRouterV2.swapExactTokensForETH, (amountIn, 0, path, to, block.timestamp));
        } else {
            data = abi.encodeCall(ISwapRouterV2.swapExactTokensForTokens, (amountIn, 0, path, to, block.timestamp));
        }
        address router = PROTOCOL_ROUTER_ADDRESS;
        bool success;
        assembly ("memory-safe") {
            success := call(gas(), router, value, add(data, 0x20), mload(data), 0, 0)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (!success) revert ExternalCallFailed();
    }
}

contract V2EncodingGasTest is RouterTestBase {
    Serpent private referenceRouter;

    function setUp() public override {
        super.setUp();
        referenceRouter = new Serpent(owner);
        V2AbiWrapper adapter = new V2AbiWrapper(address(v2Router));
        vm.prank(owner);
        referenceRouter.addSwapper(1, address(adapter));
        vm.prank(user);
        tokenIn.approve(address(referenceRouter), type(uint256).max);
    }

    function _compare(bytes1 kind, string memory name) private {
        (Serpent.RouteParam memory route, Serpent.SwapParams[] memory steps) = _single(kind, 1, AMOUNT);
        uint256 initialState = vm.snapshotState();
        uint256 yulOutput = _run(route, steps);
        uint256 yulGas = vm.snapshotGasLastCall("V2EncodingGas", string.concat(name, "_yul"));
        // Restore balances, allowances and total supply: the reference gets identical starting state.
        assertTrue(vm.revertToState(initialState));
        vm.prank(user);
        uint256 abiOutput = referenceRouter.swap{value: kind == 0x01 ? AMOUNT : 0}(route, steps);
        uint256 abiGas = vm.snapshotGasLastCall("V2EncodingGas", string.concat(name, "_abi"));
        assertEq(yulOutput, abiOutput);
        assertEq(tokenOut.balanceOf(destination), kind == 0x02 ? 0 : AMOUNT);
        assertLt(yulGas, abiGas);
    }

    function test_compareEthToTokenEncoding() public {
        _compare(0x01, "eth_to_token");
    }

    function test_compareTokenToEthEncoding() public {
        _compare(0x02, "token_to_eth");
    }

    function test_compareTokenToTokenEncoding() public {
        _compare(0x03, "token_to_token");
    }
}
