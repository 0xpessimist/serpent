// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {BaseWrapper} from "./BaseWrapper.sol";

/// @notice Delegatecall adapter for direct coin exchanges in registered Curve StableSwap NG pools.
/// @dev The immutable target is the NG factory. Underlying metapool trades require a separate adapter.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract CurveStableNGWrapper is BaseWrapper {
    address public immutable WETH;

    constructor(address factory, address weth) payable BaseWrapper(factory) {
        if (weth.code.length == 0) revert InvalidWrappedNative();
        WETH = weth;
    }

    function swapEthToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenIn != WETH) revert InvalidWrappedNative();
        _wrappedNative(amountIn, true);
        amountOut = _exchange(tokenIn, tokenOut, amountIn, to, pool);
    }

    function swapTokenToEth(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenOut != WETH) revert InvalidWrappedNative();
        amountOut = _exchange(tokenIn, tokenOut, amountIn, address(this), pool);
        _wrappedNative(amountOut, false);
        if (to != address(this)) SafeTransferLib.safeTransferETH(to, amountOut);
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        amountOut = _exchange(tokenIn, tokenOut, amountIn, to, pool);
    }

    function _indices(address pool, address tokenIn, address tokenOut) private view returns (uint256 i, uint256 j) {
        address factory = PROTOCOL_ROUTER_ADDRESS;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x9ac90d3d)) // get_coins(pool): an authenticated, bounded list.
            mstore(add(ptr, 4), pool)
            success := staticcall(gas(), factory, ptr, 0x24, ptr, 0x140)
            let n := mload(add(ptr, 0x20))
            success := and(success, and(eq(mload(ptr), 0x20), and(gt(n, 1), lt(n, 9))))
            success := and(success, eq(returndatasize(), add(0x40, mul(n, 0x20))))
            i := 8
            j := 8
            if success {
                for { let k := 0 } lt(k, n) { k := add(k, 1) } {
                    let coin := mload(add(add(ptr, 0x40), mul(k, 0x20)))
                    if eq(coin, tokenIn) { i := k }
                    if eq(coin, tokenOut) { j := k }
                }
            }
        }
        if (!success || i == 8 || j == 8) revert InvalidPool();
    }

    function _exchange(address tokenIn, address tokenOut, uint256 amountIn, address to, address pool)
        private
        returns (uint256 amountOut)
    {
        (uint256 i, uint256 j) = _indices(pool, tokenIn, tokenOut);
        // Exact approvals and exchange avoid attributing pre-existing pool donations to this swap.
        SafeTransferLib.safeApproveWithRetry(tokenIn, pool, amountIn);
        amountOut = _callPool(pool, i, j, amountIn, to);
    }

    function _callPool(address pool, uint256 i, uint256 j, uint256 amountIn, address to)
        internal
        virtual
        returns (uint256 amountOut)
    {
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0xddc1f59d)) // exchange(int128,int128,uint256,uint256,address)
            mstore(add(ptr, 0x04), i)
            mstore(add(ptr, 0x24), j)
            mstore(add(ptr, 0x44), amountIn)
            mstore(add(ptr, 0x64), 0)
            mstore(add(ptr, 0x84), to)
            success := call(gas(), pool, 0, ptr, 0xa4, ptr, 0x20)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            success := and(success, eq(returndatasize(), 0x20))
            amountOut := mload(ptr)
        }
        if (!success) revert ExternalCallFailed();
    }

    function _wrappedNative(uint256 amount, bool deposit) private {
        address weth = WETH;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            switch deposit
            case 1 {
                mstore(ptr, shl(224, 0xd0e30db0))
                success := call(gas(), weth, amount, ptr, 4, 0, 0)
            }
            default {
                mstore(ptr, shl(224, 0x2e1a7d4d))
                mstore(add(ptr, 4), amount)
                success := call(gas(), weth, 0, ptr, 0x24, 0, 0)
            }
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (!success) revert ExternalCallFailed();
    }
}
