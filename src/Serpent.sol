// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@solady/auth/Ownable.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

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
 *                                     ROUTER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/**
 * @title   Serpent Router
 * @dev     A modular and gas-efficient router that facilitates token and ether swaps through multiple protocols via swappers.
 * @dev     Specifically designed for dex aggregators to perform multi-route swaps.
 * @dev     Allows implementing custom swappers.
 * @dev     Emits events for each swap operation.
 * @dev     Uses custom errors for specific failure scenarios.
 * @dev     Uses Ownable for ownership and SafeTransferLib for transfer operations.
 * @notice  Can perform swaps directly or with permit signatures, and sweep stuck tokens or ETH.
 * @notice  Initialized with an owner and manages swappers for different protocols.
 * @author  Eren <https://twitter.com/notereneth>
 */
contract Serpent is Ownable {
    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                      STATE VARIABLES                       */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    // @note Storing and loading structs aren't gas efficient, it is currently being kept for ease of testing.
    // Ideally, will move to a system utilizing hashes.

    /// @notice RouteParam is a struct that contains route parameters.
    struct RouteParam {
        address token_in;
        address token_out;
        uint256 amount_in;
        uint256 min_received;
        address destination;
        bytes1 swap_type; // 0x01: ethToToken, 0x02: tokenToEth, 0x03: tokenToToken
    }

    /// @notice SwapParams is a struct that contains swap parameters.
    struct SwapParams {
        address token_in;
        address token_out;
        uint32 rate;
        uint256 protocol_id;
        address pool_address;
        bytes1 swap_type;
    }

    /// @notice The mapping of protocol IDs to swap handler addresses.
    mapping(uint256 => address) public swappers;

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                           EVENTS                           */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    event Swap(
        address sender, uint256 amount_in, uint256 amount_out, address token_in, address token_out, address destination
    );

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    error AddressZero();
    error AlreadySet();
    error TokenAddressesAreSame();
    error NoSwapsProvided();
    error AmountInZero();
    error MinReceivedZero();
    error DestinationZero();
    error MinReceivedAmountNotReached();
    error SwapFailed();
    error ArrayLengthsMismatching();

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     SPECIAL FUNCTIONS                      */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    constructor(address owner) payable {
        _initializeOwner(owner);
    }

    receive() external payable {}

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     EXTERNAL FUNCTIONS                     */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    /**
     * @dev  Performs a swap using the provided route and swap parameters.
     * @param   route  The route parameters for the swap.
     * @param   swap_parameters  The parameters for the swaps to perform.
     * @return  The amount of the output token received.
     */
    function swap(RouteParam calldata route, SwapParams[] calldata swap_parameters)
        external
        payable
        returns (uint256)
    {
        if (route.swap_type != 0x01) {
            SafeTransferLib.safeTransferFrom(route.token_in, msg.sender, address(this), route.amount_in);
        }
        return _orchestrate(route, swap_parameters);
    }

    /**
     * @dev  Performs a swap using the provided route and swap parameters with permit signatures.
     * @param   route  The route parameters for the swap.
     * @param   swap_parameters  The parameters for the swaps to perform.
     * @param   deadline  The deadline for the permit signature.
     * @param   v  The v value of the permit signature.
     * @param   r  The r value of the permit signature.
     * @param   s  The s value of the permit signature.
     * @return  The amount of the output token received.
     */
    function swapWithPermit(
        RouteParam calldata route,
        SwapParams[] calldata swap_parameters,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint256) {
        SafeTransferLib.permit2(route.token_in, msg.sender, address(this), route.amount_in, deadline, v, r, s);
        return _orchestrate(route, swap_parameters);
    }

    /**
     * @dev  Adds a new swap handler for the specified protocol ID.
     * @dev     Reverts if the new address is the zero address or if a handler is already set for the protocol ID.
     * @param   protocol_id  The protocol ID to set the handler for.
     * @param   swapper  The address of the new swap handler.
     */

    /*    function addSwapper(uint256 protocol_id, address swapper) external payable onlyOwner {
        assembly {
            if iszero(swapper) {
                mstore(0x00, 0x4e487b71) // `AddressZero()`
                revert(0x1c, 0x04)
            }
            let slot := add(swappers.slot, protocol_id)
            if sload(slot) {
                mstore(0x00, 0x582ef2b8) // `AlreadySet()`
                revert(0x1c, 0x04)
            }
            sstore(slot, swapper)
        }
    }
    */

    function addSwapper(uint256 protocol_id, address swapper) external payable onlyOwner {
        if (swapper == address(0)) {
            revert AddressZero();
        }
        if (swappers[protocol_id] != address(0)) {
            revert AlreadySet();
        }
        swappers[protocol_id] = swapper;
    }

    /**
     * @dev   Removes the swapper for the specified protocol ID.
     * @param   protocol_id  The protocol ID to remove the swap handler for.
     */
    function removeSwapper(uint256 protocol_id) external payable onlyOwner {
        assembly {
            let slot := add(swappers.slot, protocol_id)
            sstore(slot, 0)
        }
    }

    /**
     * @dev  Sweeps stuck tokens from the contract.
     * @param   token  The address of the token to sweep.
     * @param   amount  The amount of the token to sweep.
     * @param   receiver  The address to receive the tokens.
     */
    function sweepStuckToken(address token, uint256 amount, address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransfer(token, receiver, amount);
    }

    /**
     * @dev  Sweeps stuck multiple tokens from the contract.
     * @param   tokens  The addresses of the tokens to sweep.
     * @param   amounts  The amounts of the tokens to sweep.
     * @param   receiver  The address to receive the tokens.
     */
    function sweepStuckTokens(address[] calldata tokens, uint256[] calldata amounts, address receiver)
        external
        payable
        onlyOwner
    {
        assembly {
            let tokensLength := calldataload(tokens.offset)
            let amountsLength := calldataload(amounts.offset)

            if iszero(eq(tokensLength, amountsLength)) {
                mstore(0x00, 0x78e87335) // `ArrayLengthsMismatching()`
                revert(0x1c, 0x04)
            }
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            SafeTransferLib.safeTransfer(tokens[i], receiver, amounts[i]);
        }
    }

    /**
     * @dev  Sweeps stuck ether from the contract.
     * @param   receiver  The address to receive the ether.
     */
    function sweepStuckEther(address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransferAllETH(receiver);
    }

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     INTERNAL FUNCTIONS                     */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    /**
     * @dev Performs the whole swap using the provided route and swap parameters.
     * @param route The route parameters for the swap.
     * @param swap_parameters The parameters for the swaps to perform.
     * @return output_amount The amount of the output token received.
     */
    function _orchestrate(RouteParam memory route, SwapParams[] memory swap_parameters) internal returns (uint256) {
        assembly {
            // Check if token_in is equal to token_out
            if eq(mload(route), mload(add(route, 32))) {
                mstore(0x00, 0x41c0e1b5) // `TokenAddressesAreSame()`
                revert(0x1c, 0x04)
            }

            // Check if swap_parameters length is zero
            if iszero(mload(swap_parameters)) {
                mstore(0x00, 0x2f4c5ea3) // `NoSwapsProvided()`
                revert(0x1c, 0x04)
            }

            // Check if amount_in is zero
            if iszero(mload(add(route, 64))) {
                mstore(0x00, 0x03d7d16c) // `AmountInZero()`
                revert(0x1c, 0x04)
            }

            // Check if min_received is zero
            if iszero(mload(add(route, 96))) {
                mstore(0x00, 0x174d1b78) // `MinReceivedZero()`
                revert(0x1c, 0x04)
            }

            // Check if destination address is zero
            if iszero(mload(add(route, 128))) {
                mstore(0x00, 0x4e487b71) // `DestinationZero()`
                revert(0x1c, 0x04)
            }
        }

        _swap(swap_parameters, route);

        uint256 output_amount;

        if (route.swap_type == 0x02) {
            assembly {
                output_amount := selfbalance()
                if lt(output_amount, mload(add(route, 0x60))) {
                    mstore(0x00, 0x1f3b3b3b) // `MinReceivedAmountNotReached()`
                    revert(0x1c, 0x04)
                }
            }
            SafeTransferLib.safeTransferETH(route.destination, address(this).balance);
        } else {
            output_amount = IERC20(route.token_out).balanceOf(address(this)); // @todo 1
            SafeTransferLib.safeTransfer(route.token_out, route.destination, output_amount);
        }
        emit Swap(msg.sender, route.amount_in, output_amount, route.token_in, route.token_out, route.destination);
        return output_amount;
    }

    /**
     * @dev Performs the swaps specified in the swap parameters.
     * @param swap_parameters The parameters for the swaps to perform.
     * @param route The route parameters for the swap.
     */
    function _swap(SwapParams[] memory swap_parameters, RouteParam memory route) internal {
        uint256 bln;
        uint256 index;

        while (index < swap_parameters.length) {
            SwapParams memory swap_p = swap_parameters[index];
            uint256 amount_in;

            if (route.token_in == swap_p.token_in) {
                amount_in = route.amount_in * swap_p.rate / 1000000;
            } else {
                // @todo not checked yet, probably not working well
                assembly {
                    let j := index
                    for {} gt(j, 0) { j := sub(j, 1) } {
                        let prevSwapOffset := mul(sub(j, 1), 0x20)
                        let prevTokenIn := mload(add(swap_parameters, add(prevSwapOffset, 0x00)))

                        if eq(prevTokenIn, mload(add(swap_p, 0x00))) { break }

                        mstore(0x00, 0x70a08231)
                        mstore(0x04, address())

                        let success := staticcall(gas(), mload(add(swap_p, 0x00)), 0x00, 0x24, 0x00, 0x20)

                        if iszero(success) { revert(0, 0) }

                        bln := mload(0x00)
                    }

                    amount_in := div(mul(bln, mload(add(swap_p, 0x40))), 1000000)
                }
            }

            _delegatecall_swapper(swap_p, swappers[swap_p.protocol_id], amount_in);
            unchecked {
                ++index;
            }
        }
    }

    /**
     * @dev Calls the relevant swapper to perform the swap operation.
     * @param swap_parameter The parameters for the swap to perform.
     * @param swapper_address The address of the proxy to perform the swap.
     * @param amount_in The amount of input tokens for the swap.
     */
    function _delegatecall_swapper(SwapParams memory swap_parameter, address swapper_address, uint256 amount_in)
        internal
    {
        bytes4 selector;

        if (swap_parameter.swap_type == 0x01) {
            selector = bytes4(keccak256("swapEthToToken(address,address,uint256,address,address)"));
        } else if (swap_parameter.swap_type == 0x02) {
            selector = bytes4(keccak256("swapTokenToEth(address,address,uint256,address,address)"));
        } else {
            selector = bytes4(keccak256("swapTokenToToken(address,address,uint256,address,address)"));
        }

        assembly {
            let ptr := mload(0x40)

            mstore(ptr, selector)
            mstore(add(ptr, 4), mload(swap_parameter)) // token_in
            mstore(add(ptr, 36), mload(add(swap_parameter, 32))) // token_out
            mstore(add(ptr, 68), amount_in) // amount_in
            mstore(add(ptr, 100), address()) // address(this)
            mstore(add(ptr, 132), mload(add(swap_parameter, 64))) // pool_address

            let success :=
                delegatecall(
                    gas(),
                    swapper_address,
                    ptr,
                    164, // (4 + 5 * 32 bytes)
                    0,
                    0
                )

            if iszero(success) {
                mstore(0x00, 0x9e2b49c6) // `SwapFailed()`
                revert(0x1c, 0x04)
            }
        }
    }
}
