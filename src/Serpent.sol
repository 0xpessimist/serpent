// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Ownable} from "@solady/auth/Ownable.sol";
//import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
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
 *                                     ROUTER *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/**
 * @title   Serpent Router
 * @dev     A modular and gas-efficient router that facilitates token and ether swaps through multiple protocols via swappers.
 * @dev     Specifically designed for dex aggregators to perform multi-route swaps.
 * @dev     Allows implementing custom swappers.
 * @dev     Only the owner can set/remove swap handlers and adjust fees.
 * @dev     Ensures minimum received amount and proper fee handling in swaps.
 * @dev     Emits events for each swap operation.
 * @dev     Uses custom errors for specific failure scenarios.
 * @dev     Uses Ownable for ownership and SafeTransferLib for transfer operations.
 * @notice  Can perform swaps directly or with permit signatures, and sweep stuck tokens or ETH.
 * @notice  Initialized with an owner and manages swappers for different protocols.
 * @author  Eren <https://twitter.com/notereneth>
 */
contract Serpent is Ownable {
    /*

    @todo

    - Add permit
    - V3Wrapper

    */

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                      STATE VARIABLES                       */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    /// @notice The fee extension.
    uint256 private constant FEE_EXTENSION = 1000000;

    /// @notice The rate extension.
    uint256 private constant RATE_EXTENSION = 1000000;

    /// @notice The router fee for multi-route swaps.
    uint256 public router_fee;
    /// @notice The fee handler address.
    address public fee_handler;

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
    error CallFailed();

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     SPECIAL FUNCTIONS                      */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    constructor(address _owner) payable {
        _initializeOwner(_owner);
    }

    receive() external payable {}

    /*´:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/
    /*                     EXTERNAL FUNCTIONS                     */
    /*.:°•𓆗°+.𓆚•´:˚.°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°.°+𓆗*•´.*:*/

    /**
     * @notice  Sets a new router fee.
     * @param   new_fee  The new fee to set for multi-route swaps.
     *
     * @dev     IMPORTANT: Fee extension should be considered. If a fee of 0.02% is desired, new_fee should be set to 200.
     */
    function setRouterFee(uint256 new_fee) external payable onlyOwner {
        assembly {
            sstore(router_fee.slot, new_fee)
        }
    }

    /**
     * @dev  Sets a new fee handler address.
     * @param   new_fee_handler  The new fee handler address.
     */
    function setFeeHandler(address new_fee_handler) external payable onlyOwner {
        assembly {
            if iszero(new_fee_handler) {
                mstore(0x00, 0x4e487b71) // `AddressZero()`
                revert(0x1c, 0x04)
            }
            sstore(fee_handler.slot, new_fee_handler)
        }
    }

    /**
     * @dev  Adds a new swap handler for the specified protocol ID.
     * @dev     Reverts if the new address is the zero address or if a handler is already set for the protocol ID.
     * @param   protocol_id  The protocol ID to set the handler for.
     * @param   handler  The address of the new handler.
     */
    function addSwapper(uint256 protocol_id, address handler) external payable onlyOwner {
        assembly {
            if iszero(handler) {
                mstore(0x00, 0x4e487b71) // `AddressZero()`
                revert(0x1c, 0x04)
            }
            let slot := add(swappers.slot, protocol_id)
            if sload(slot) {
                mstore(0x00, 0x582ef2b8) // `AlreadySet()`
                revert(0x1c, 0x04)
            }
            sstore(slot, handler)
        }
    }

    /**
     * @dev  Removes the swap handler for the specified protocol ID.
     * @param   protocol_id  The protocol ID to remove the handler for.
     */
    function removeSwapper(uint256 protocol_id) external payable onlyOwner {
        assembly {
            let slot := add(swappers.slot, protocol_id)
            sstore(slot, 0)
        }
    }

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
        return _swap_operation(route, swap_parameters);
    }

    // @todo permit swap

    function sweepStuckToken(address _token, uint256 _amount, address _receiver) external payable onlyOwner {
        SafeTransferLib.safeTransfer(_token, _receiver, _amount);
    }

    function sweepStuckTokens(address[] calldata _tokens, uint256[] calldata _amounts, address _receiver)
        external
        payable
        onlyOwner
    {
        assembly {
            let tokensLength := calldataload(_tokens.offset)
            let amountsLength := calldataload(_amounts.offset)

            if iszero(eq(tokensLength, amountsLength)) {
                mstore(0x00, 0x78e87335) // `ArrayLengthsMismatching()`
                revert(0x1c, 0x04)
            }
        }

        for (uint256 i = 0; i < _tokens.length; i++) {
            SafeTransferLib.safeTransfer(_tokens[i], _receiver, _amounts[i]);
        }
    }

    // :°•𓆗°+.𓆚•´.𓆚:˚.°*𓆓˚•´.°:°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:°•.°+𓆗*•´.*:

    function sweepStuckEther(address _receiver) external payable onlyOwner {
        SafeTransferLib.safeTransferAllETH(_receiver);
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
    function _swap_operation(RouteParam memory route, SwapParams[] memory swap_parameters) internal returns (uint256) {
        //emit Swap(msg.sender, route.amount_in, output_amount, route.token_in, route.token_out, route.destination);
        //return output_amount;
    }

    /**
     * @dev Performs the swaps specified in the swap parameters.
     * @param swap_parameters The parameters for the swaps to perform.
     * @param route The route parameters for the swap.
     */
    function _swap(SwapParams[] memory swap_parameters, RouteParam memory route) internal {}

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

    /**
     * @dev Calculates the output amount and fee based on the input amount and fee percentage.
     * @param amount The input amount to calculate the output for.
     * @param fee The fee percentage to apply.
     * @return output_amount The output amount after the fee is applied.
     */
    function _calculate_output_with_fee(uint256 amount, uint256 fee)
        internal
        pure
        returns (uint256 output_amount, uint256 output_fee)
    {
        assembly {
            output_fee := div(mul(amount, fee), FEE_EXTENSION)
            output_amount := sub(amount, output_fee)
        }
    }

    /**
     * @dev Multiplies the amount by the rate and divides by 100 to get the percentage.
     * @param amount The input amount to calculate the percentage for.
     * @param rate The rate to apply. 1-100
     * @return result The calculated percentage of the amount.
     */
    function _calculate_percentage_of_amount(uint256 amount, uint256 rate) internal pure returns (uint256 result) {
        assembly {
            result := div(mul(amount, rate), RATE_EXTENSION)
        }
    }
}
