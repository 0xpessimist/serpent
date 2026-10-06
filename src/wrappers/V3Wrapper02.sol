// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {BaseWrapper} from "./BaseWrapper.sol";

/*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚*\
 * SERPENT                                    *
 *    _________         _________             *
 *   /         \       /         \            *
 *  /  /~~~~~\  \     /  /~~~~~\  \           *
 *  |  |     |  |     |  |     |  |           *
 *  |  |     |  |     |  |     |  |           *
 *  |  |     |  |     |  |     |  |         / *
 *  |  |     |  |     |  |     |  |       //  *
 * (o  o)    \  \_____/  /     \  \_____/ /   *
 *  \__/      \         /       \        /    *
 *   |         ~~~~~~~~~         ~~~~~~~~     *
 *   ^                                        *
 *                              V3 WRAPPER 02 *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/// @notice Delegatecall adapter for Uniswap V3 SwapRouter02, including canonical Base.
/// @dev Seven-field exactInputSingle tuple (0x04e45aaf); separate adapter avoids a per-hop ABI branch.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract V3Wrapper02 is BaseWrapper {
    address public immutable WETH;

    constructor(address router, address weth) payable BaseWrapper(router) {
        if (weth.code.length == 0) revert InvalidWrappedNative();
        WETH = weth;
    }

    function swapEthToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenIn != WETH) revert InvalidWrappedNative();
        amountOut = _exactInputSingle(tokenIn, tokenOut, amountIn, to, pair, amountIn);
    }

    function swapTokenToEth(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenOut != WETH) revert InvalidWrappedNative();
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        amountOut = _exactInputSingle(tokenIn, tokenOut, amountIn, address(this), pair, 0);
        address weth = WETH;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x2e1a7d4d))
            mstore(add(ptr, 0x04), amountOut)
            success := call(gas(), weth, 0, ptr, 0x24, 0, 0)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (!success) revert ExternalCallFailed();
        if (to != address(this)) SafeTransferLib.safeTransferETH(to, amountOut);
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        onlyDelegateCall
        returns (uint256 amountOut)
    {
        _validateTokens(tokenIn, tokenOut);
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        amountOut = _exactInputSingle(tokenIn, tokenOut, amountIn, to, pair, 0);
    }

    function _fee(address pair) private view returns (uint256 fee) {
        bool success;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0xddca3f43))
            success := staticcall(gas(), pair, 0x00, 0x04, 0x00, 0x20)
            success := and(success, eq(returndatasize(), 0x20))
            fee := mload(0x00)
        }
        if (!success || fee > type(uint24).max) revert InvalidPool();
    }

    function _exactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address to,
        address pair,
        uint256 value
    ) private returns (uint256 amountOut) {
        uint256 fee = _fee(pair);
        address router = PROTOCOL_ROUTER_ADDRESS;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x04e45aaf))
            mstore(add(ptr, 0x04), tokenIn)
            mstore(add(ptr, 0x24), tokenOut)
            mstore(add(ptr, 0x44), fee)
            mstore(add(ptr, 0x64), to)
            mstore(add(ptr, 0x84), amountIn)
            mstore(add(ptr, 0xa4), 0)
            mstore(add(ptr, 0xc4), 0)
            success := call(gas(), router, value, ptr, 0xe4, ptr, 0x20)
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            success := and(success, iszero(lt(returndatasize(), 0x20)))
            amountOut := mload(ptr)
        }
        if (!success) revert ExternalCallFailed();
    }
}
