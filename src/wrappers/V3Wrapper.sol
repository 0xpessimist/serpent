// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

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
 *                                 V3 WRAPPER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/**
 * @title   Serpent V3Wrapper
 * @dev     Acts as a wrapper for routers of protocols using SwapRouter (Uniswap V3) interfaces to be used in Serpent.
 * @author  Eren <https://twitter.com/notereneth>
 */
contract V3Wrapper {
    address public immutable PROTOCOL_ROUTER_ADDRESS;
    address public immutable WETH;

    error SameToken();
    error InvalidToken();
    error InvalidPool();
    error ExternalCallFailed();

    constructor(address protocol_router_address, address weth) payable {
        PROTOCOL_ROUTER_ADDRESS = protocol_router_address;
        WETH = weth;
    }

    function swapEthToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        returns (uint256 amountOut)
    {
        assembly {
            if eq(tokenIn, tokenOut) {
                mstore(0x00, 0x5f0c29ff) // `SameToken()`
                revert(0x1c, 0x04)
            }

            if or(iszero(tokenIn), iszero(tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // `InvalidToken()`
                revert(0x1c, 0x04)
            }

            if iszero(pair) {
                mstore(0x00, 0x646f01ed) // `InvalidPool()`
                revert(0x1c, 0x04)
            }
        }

        uint24 poolFee;
        address router = PROTOCOL_ROUTER_ADDRESS;

        assembly {
            let success :=
                staticcall(
                    gas(), // Forward all remaining gas
                    pair, // Address of the pair contract
                    0x80, // Pointer to calldata in memory (arbitrary location)
                    0x04, // Size of the calldata (4 bytes for the selector)
                    0x80, // Write the return data to the same arbitrary location
                    0x20 // Expecting a 32-byte return value
                )

            if iszero(success) { revert(0, 0) }

            // mask to lower 24 bits for uint24
            poolFee := and(mload(0x80), 0xffffff)
        }

        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);

        bytes memory data = abi.encodeWithSelector(
            0x04e45aaf, // exactInputSingle selector
            tokenIn,
            tokenOut,
            poolFee,
            to,
            block.timestamp,
            amountIn,
            0,
            0
        );

        assembly {
            let success :=
                call(
                    gas(), // Forward all gas
                    router, // Router address
                    amountIn, // Pass ETH value
                    add(data, 0x20), // Input data pointer
                    mload(data), // Input data size
                    0, // No output
                    0 // No output size
                )

            if iszero(success) {
                mstore(0x00, 0x4e487b71) // `ExternalCallFailed()`
                revert(0x1c, 0x04)
            }

            amountOut := mload(0)
        }
    }

    function swapTokenToEth(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        returns (uint256 amountOut)
    {
        assembly {
            if eq(tokenIn, tokenOut) {
                mstore(0x00, 0x5f0c29ff) // `SameToken()`
                revert(0x1c, 0x04)
            }

            if or(iszero(tokenIn), iszero(tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // `InvalidToken()`
                revert(0x1c, 0x04)
            }

            if iszero(pair) {
                mstore(0x00, 0x646f01ed) // `InvalidPool()`
                revert(0x1c, 0x04)
            }
        }

        uint24 poolFee;
        address router = PROTOCOL_ROUTER_ADDRESS;
        address weth = WETH;

        assembly {
            let success :=
                staticcall(
                    gas(), // Forward all remaining gas
                    pair, // Address of the pair contract
                    0x80, // Pointer to calldata in memory (arbitrary location)
                    0x04, // Size of the calldata (4 bytes for the selector)
                    0x80, // Write the return data to the same arbitrary location
                    0x20 // Expecting a 32-byte return value
                )

            if iszero(success) { revert(0, 0) }

            // mask to lower 24 bits for uint24
            poolFee := and(mload(0x80), 0xffffff)
        }

        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);

        bytes memory data = abi.encodeWithSelector(
            0x04e45aaf, // exactInputSingle selector
            tokenIn,
            tokenOut,
            poolFee,
            address(this),
            block.timestamp,
            amountIn,
            0,
            0
        );

        assembly {
            let success :=
                call(
                    gas(), // Forward all gas
                    router, // Router address
                    0, // No ETH value
                    add(data, 0x20), // Input data pointer
                    mload(data), // Input data size
                    0, // No output
                    0 // No output size
                )

            if iszero(success) {
                mstore(0x00, 0x4e487b71) // `ExternalCallFailed()`
                revert(0x1c, 0x04)
            }

            amountOut := mload(0) // Load result

            let callData := mload(0x40) // Get free memory pointer
            mstore(callData, 0x2e1a7d4d) // Function selector for `withdraw(uint256)`
            mstore(add(callData, 0x04), amountOut) // Append `amountOut` as the argument

            let success2 :=
                call(
                    gas(), // Forward all available gas
                    weth, // Address of the WETH contract
                    0, // No ETH value to send
                    callData, // Pointer to the input data
                    0x24, // Size of the input data
                    0, // No memory output required
                    0 // No memory output size
                )

            if iszero(success2) {
                mstore(0x00, 0x4e487b71) // `ExternalCallFailed()`
                revert(0x01c, 0x04)
            }

            let success3 :=
                call(
                    gas(), // Forward all gas
                    to, // Recipient
                    amountOut, // Send amountOut as ETH
                    0, // No input
                    0, // No input size
                    0, // No output
                    0 // No output size
                )

            if iszero(success3) {
                mstore(0x00, 0x4e487b71) // `ExternalCallFailed()`
                revert(0x1c, 0x04)
            }
        }
    }

    function swapTokenToToken(address tokenIn, address tokenOut, uint256 amountIn, address to, address pair)
        external
        payable
        returns (uint256 amountOut)
    {
        assembly {
            if eq(tokenIn, tokenOut) {
                mstore(0x00, 0x5f0c29ff) // `SameToken()`
                revert(0x1c, 0x04)
            }

            if or(iszero(tokenIn), iszero(tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // `InvalidToken()`
                revert(0x1c, 0x04)
            }

            if iszero(pair) {
                mstore(0x00, 0x646f01ed) // `InvalidPool()`
                revert(0x1c, 0x04)
            }
        }

        uint24 poolFee;
        address router = PROTOCOL_ROUTER_ADDRESS;

        assembly {
            let success :=
                staticcall(
                    gas(), // Forward all remaining gas
                    pair, // Address of the pair contract
                    0x80, // Pointer to calldata in memory (arbitrary location)
                    0x04, // Size of the calldata (4 bytes for the selector)
                    0x80, // Write the return data to the same arbitrary location
                    0x20 // Expecting a 32-byte return value
                )

            if iszero(success) { revert(0, 0) }

            // mask to lower 24 bits for uint24
            poolFee := and(mload(0x80), 0xffffff)
        }

        SafeTransferLib.safeApproveWithRetry(tokenIn, PROTOCOL_ROUTER_ADDRESS, amountIn);

        bytes memory data = abi.encodeWithSelector(
            0x04e45aaf, // exactInputSingle selector
            tokenIn,
            tokenOut,
            poolFee,
            to,
            block.timestamp,
            amountIn,
            0,
            0
        );

        assembly {
            let success :=
                call(
                    gas(), // Forward all gas
                    router, // Router address
                    0, // No ETH value
                    add(data, 0x20), // Input data pointer
                    mload(data), // Input data size
                    0, // No output
                    0 // No output size
                )

            if iszero(success) {
                mstore(0x00, 0x4e487b71) // `ExternalCallFailed()`
                revert(0x01c, 0x04)
            }

            amountOut := mload(0)
        }
    }
}
