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
 *                                 V2 WRAPPER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

interface ISwapRouterV2 {
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
}

/**
 * @title   Serpent V2Wrapper
 * @dev     Acts as a wrapper for routers of protocols using UniswapV2Router interfaces to be used in Serpent.
 * @author  Eren <https://twitter.com/notereneth>
 */
contract V2Wrapper {
    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                      STATE VARIABLES                       */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    address public immutable PROTOCOL_ROUTER_ADDRESS;

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    error SameToken();
    error InvalidToken();
    error InvalidPool();
    error ExternalCallFailed();

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     SPECIAL FUNCTIONS                      */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    constructor(address _protocol_router_address) payable {
        PROTOCOL_ROUTER_ADDRESS = _protocol_router_address;
    }

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     EXTERNAL FUNCTIONS                     */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    // @todo NOT WORKING WELL IN YUL RN - NEEDS TO BE FIXED

    function swapEthToToken(address _tokenIn, address _tokenOut, uint256 _amountIn, address _to, address _pair)
        external
        payable
    {
        assembly {
            if iszero(_pair) {
                mstore(0x00, 0x646f01ed) // InvalidPool()
                revert(0x1c, 0x04)
            }

            if or(iszero(_tokenIn), iszero(_tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // InvalidToken()
                revert(0x1c, 0x04)
            }

            if eq(_tokenIn, _tokenOut) {
                mstore(0x00, 0x5f0c29ff) // SameToken()
                revert(0x1c, 0x04)
            }
        }

        address router = PROTOCOL_ROUTER_ADDRESS;

        SafeTransferLib.safeApproveWithRetry(_tokenIn, router, _amountIn);

        // @todo path encoding and call in assembly needs to be implemented, below functions won't work well.

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        ISwapRouterV2(router).swapExactETHForTokens{value: _amountIn}(0, path, _to, block.timestamp);
    }

    function swapTokenToEth(address _tokenIn, address _tokenOut, uint256 _amountIn, address _to, address _pair)
        external
        payable
    {
        assembly {
            if iszero(_pair) {
                mstore(0x00, 0x646f01ed) // `InvalidPool()`
                revert(0x1c, 0x04)
            }

            if or(iszero(_tokenIn), iszero(_tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // `InvalidToken()`
                revert(0x1c, 0x04)
            }

            if eq(_tokenIn, _tokenOut) {
                mstore(0x00, 0x5f0c29ff) // `SameToken()`
                revert(0x1c, 0x04)
            }
        }

        address router = PROTOCOL_ROUTER_ADDRESS;

        SafeTransferLib.safeApproveWithRetry(_tokenIn, router, _amountIn);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        assembly {
            let ptr := mload(0x40) // Free memory pointer
            mstore(ptr, shl(224, 0x18cbafe5)) // swapExactTokensForETH selector
            mstore(add(ptr, 4), _amountIn) // amountIn
            mstore(add(ptr, 36), 0) // amountOutMin
            mstore(add(ptr, 68), path) // path array pointer
            mstore(add(ptr, 100), _to) // recipient address
            mstore(add(ptr, 132), timestamp()) // deadline

            let success :=
                call(
                    gas(), // Forward all gas
                    router, // Router address
                    0, // No ETH value
                    ptr, // Input data location
                    164, // Input data size
                    0, // No output
                    0 // No output size
                )

            if iszero(success) {
                mstore(0x00, 0x4e487b71) // Error selector for ExternalCallFailed()
                revert(0x00, 0x04)
            }
        }
    }

    function swapTokenToToken(address _tokenIn, address _tokenOut, uint256 _amountIn, address _to, address _pair)
        external
        payable
    {
        assembly {
            if iszero(_pair) {
                mstore(0x00, 0x646f01ed) // `InvalidPool()`
                revert(0x1c, 0x04)
            }

            if or(iszero(_tokenIn), iszero(_tokenOut)) {
                mstore(0x00, 0x2c2a42d6) // `InvalidToken()`
                revert(0x1c, 0x04)
            }

            if eq(_tokenIn, _tokenOut) {
                mstore(0x00, 0x5f0c29ff) // `SameToken()`
                revert(0x1c, 0x04)
            }
        }

        address router = PROTOCOL_ROUTER_ADDRESS;

        SafeTransferLib.safeApproveWithRetry(_tokenIn, router, _amountIn);

        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;

        assembly {
            let ptr := mload(0x40) // Free memory pointer
            mstore(ptr, shl(224, 0x38ed1739)) // swapExactTokensForTokens selector
            mstore(add(ptr, 4), _amountIn) // amountIn
            mstore(add(ptr, 36), 0) // amountOutMin
            mstore(add(ptr, 68), path) // path array pointer
            mstore(add(ptr, 100), _to) // recipient address
            mstore(add(ptr, 132), timestamp()) // deadline

            let success :=
                call(
                    gas(), // Forward all gas
                    router, // Router address
                    0, // No ETH value
                    ptr, // Input data location
                    164, // Input data size
                    0, // No output
                    0 // No output size
                )

            if iszero(success) {
                mstore(0x00, 0x4e487b71) // Error selector for ExternalCallFailed()
                revert(0x1c, 0x04)
            }
        }
    }
}
