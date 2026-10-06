// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {BaseWrapper} from "./BaseWrapper.sol";

interface ISolidlyRouter {
    function weth() external view returns (address);
    function defaultFactory() external view returns (address);
}

/// @notice Delegatecall adapter for Aerodrome/Velodrome V2 stable and volatile pools.
/// @dev Uses the four-field Route tuple. Older three-field Solidly routers need a different adapter.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract SolidlyWrapper is BaseWrapper {
    address public immutable WETH;
    address public immutable FACTORY;

    constructor(address router) payable BaseWrapper(router) {
        address weth = ISolidlyRouter(router).weth();
        address factory = ISolidlyRouter(router).defaultFactory();
        if (weth.code.length == 0) revert InvalidWrappedNative();
        if (factory.code.length == 0) revert InvalidPool();
        WETH = weth;
        FACTORY = factory;
    }

    function swapEthToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenIn != WETH) revert InvalidWrappedNative();
        _swap(tokenIn, tokenOut, amountIn, to, pool, 1);
    }

    function swapTokenToEth(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenOut != WETH) revert InvalidWrappedNative();
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        _swap(tokenIn, tokenOut, amountIn, to, pool, 2);
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        _swap(tokenIn, tokenOut, amountIn, to, pool, 3);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool, uint256 kind)
        private
    {
        bool success;
        uint256 stable;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0x22be3de1)) // stable()
            success := staticcall(gas(), pool, 0x00, 4, 0x00, 0x20)
            success := and(success, eq(returndatasize(), 0x20))
            stable := mload(0x00)
        }
        if (!success || stable > 1) revert InvalidPool();
        _callRouter(tokenIn, tokenOut, amountIn, to, stable, kind);
    }

    function _callRouter(address tokenIn, address tokenOut, uint256 amountIn, address to, uint256 stable, uint256 kind)
        internal
        virtual
    {
        address router = PROTOCOL_ROUTER_ADDRESS;
        address factory = FACTORY;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            switch kind
            case 1 {
                mstore(ptr, shl(224, 0x903638a4))
                mstore(add(ptr, 0x04), 0)
                mstore(add(ptr, 0x24), 0x80)
                mstore(add(ptr, 0x44), to)
                mstore(add(ptr, 0x64), timestamp())
                mstore(add(ptr, 0x84), 1)
                mstore(add(ptr, 0xa4), tokenIn)
                mstore(add(ptr, 0xc4), tokenOut)
                mstore(add(ptr, 0xe4), stable)
                mstore(add(ptr, 0x104), factory)
                success := call(gas(), router, amountIn, ptr, 0x124, 0, 0)
            }
            default {
                let selector := 0xcac88ea9
                if eq(kind, 2) { selector := 0xc6b7f1b6 }
                mstore(ptr, shl(224, selector))
                mstore(add(ptr, 0x04), amountIn)
                mstore(add(ptr, 0x24), 0)
                mstore(add(ptr, 0x44), 0xa0)
                mstore(add(ptr, 0x64), to)
                mstore(add(ptr, 0x84), timestamp())
                mstore(add(ptr, 0xa4), 1)
                mstore(add(ptr, 0xc4), tokenIn)
                mstore(add(ptr, 0xe4), tokenOut)
                mstore(add(ptr, 0x104), stable)
                mstore(add(ptr, 0x124), factory)
                success := call(gas(), router, 0, ptr, 0x144, 0, 0)
            }
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        // Serpent measures the recipient's balance delta, so no dynamic return-array decoding is needed.
        if (!success) revert ExternalCallFailed();
    }
}
