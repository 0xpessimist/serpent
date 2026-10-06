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
 *                                 V2 WRAPPER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

interface ISwapRouterV2 {
    function WETH() external view returns (address);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Delegatecall adapter for the Uniswap V2 Router interface.
/// @dev Pool addresses are ignored: the protocol router derives pairs from the path.
/// Serpent enforces aggregate slippage. Router return arrays need not be decoded.
contract V2Wrapper is BaseWrapper {
    address public immutable WETH;

    constructor(address router) payable BaseWrapper(router) {
        address weth = ISwapRouterV2(router).WETH();
        if (weth.code.length == 0) revert InvalidWrappedNative();
        WETH = weth;
    }

    function swapEthToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenIn != WETH) revert InvalidWrappedNative();
        _callRouter(tokenIn, tokenOut, amountIn, to, 1);
    }

    function swapTokenToEth(address tokenIn, address tokenOut, uint256 amountIn, address to, address)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        if (tokenOut != WETH) revert InvalidWrappedNative();
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        _callRouter(tokenIn, tokenOut, amountIn, to, 2);
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address)
        external
        payable
        onlyDelegateCall
    {
        _validateTokens(tokenIn, tokenOut);
        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);
        _callRouter(tokenIn, tokenOut, amountIn, to, 3);
    }

    function _callRouter(address tokenIn, address tokenOut, uint256 amountIn, address to, uint256 kind)
        internal
        virtual
    {
        address router = PROTOCOL_ROUTER_ADDRESS;
        bool success;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            switch kind
            case 1 {
                // Four-word head, then length and two path elements. Offsets exclude the selector.
                mstore(ptr, shl(224, 0x7ff36ab5))
                mstore(add(ptr, 0x04), 0)
                mstore(add(ptr, 0x24), 0x80)
                mstore(add(ptr, 0x44), to)
                mstore(add(ptr, 0x64), timestamp())
                mstore(add(ptr, 0x84), 2)
                mstore(add(ptr, 0xa4), tokenIn)
                mstore(add(ptr, 0xc4), tokenOut)
                success := call(gas(), router, amountIn, ptr, 0xe4, 0, 0)
            }
            default {
                let selector := 0x38ed1739
                if eq(kind, 2) { selector := 0x18cbafe5 }
                // Five-word head, then length and two path elements.
                mstore(ptr, shl(224, selector))
                mstore(add(ptr, 0x04), amountIn)
                mstore(add(ptr, 0x24), 0)
                mstore(add(ptr, 0x44), 0xa0)
                mstore(add(ptr, 0x64), to)
                mstore(add(ptr, 0x84), timestamp())
                mstore(add(ptr, 0xa4), 2)
                mstore(add(ptr, 0xc4), tokenIn)
                mstore(add(ptr, 0xe4), tokenOut)
                success := call(gas(), router, 0, ptr, 0x104, 0, 0)
            }
            if and(iszero(success), iszero(iszero(returndatasize()))) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
        if (!success) revert ExternalCallFailed();
    }
}
