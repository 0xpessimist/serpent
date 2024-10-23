// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {V2Wrapper} from "src/wrappers/V2Wrapper.sol";

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
 *                            WRAPPER FACTORY *
\*°*𓆓˚•´°•.𓆓•.*•𓆗⟡.𓆗*:˚.°*.𓆚•´.°:.+𓆗*•´.•.:*/

/**
 * @title   Serpent Wrapper Factory
 * @dev     Allows deployment of new wrappers for protocols using Uniswap V2 & V3 Router interfaces to be used in Serpent.
 * @notice  Uses CREATE3 to deploy new swapper contracts deterministically.
 * @author  Eren <https://twitter.com/notereneth>
 */
contract WrapperFactory {
    /// @dev Mapping of user-provided salt to the deployed wrapper address.
    mapping(bytes32 => address) private wrappers;

    /// @notice Deploys a new wrapper contract using CREATE3.
    /// @param _isV2 Boolean indicating whether the wrapper is for UniswapV2Router or SwapRouter(Uniswap V3).
    /// @param _protocol_router_address Address of the protocol router.
    /// @param _salt User-provided salt combined with msg.sender for uniqueness.
    /// @return wrapper address of the deployed contract.
    function deployWrapper(bool _isV2, address _protocol_router_address, bytes12 _salt)
        external
        returns (address wrapper)
    {
        if (_isV2) {
            bytes32 salt = bytes32(abi.encodePacked(msg.sender, _salt));

            wrapper = CREATE3.deployDeterministic(
                abi.encodePacked(type(V2Wrapper).creationCode, abi.encode(_protocol_router_address)), salt
            );

            wrappers[salt] = wrapper;
        } else {
            // @todo v3
        }
    }

    function getWrapper(bytes12 _salt) external view returns (address wrapper) {
        wrapper = wrappers[bytes32(abi.encodePacked(msg.sender, _salt))];
    }
}
