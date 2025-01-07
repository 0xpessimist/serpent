// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {CREATE3} from "@solady/utils/CREATE3.sol";
import {V2Wrapper} from "src/wrappers/V2Wrapper.sol";
import {V3Wrapper} from "src/wrappers/V3Wrapper.sol";

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
    /// @param isV2 Boolean indicating whether the wrapper is for UniswapV2Router or SwapRouter(Uniswap V3).
    /// @param protocol_router_address Address of the protocol router.
    /// @param salt User-provided salt combined with msg.sender for uniqueness.
    /// @return wrapper address of the deployed contract.
    function deployWrapper(bool isV2, address protocol_router_address, address weth, bytes12 salt)
        external
        returns (address)
    {
        bytes32 packedSalt = bytes32(abi.encodePacked(msg.sender, salt));

        address wrapper;

        /*
        assembly {
            let wr := sload(add(wrappers.slot, packedSalt))
            if not(iszero(wr)) { revert(0, 0) }
        }
        */ 
        // @todo fix the above check, not working as expected

        if (isV2) {
            wrapper = CREATE3.deployDeterministic(
                abi.encodePacked(type(V2Wrapper).creationCode, abi.encode(protocol_router_address)), packedSalt
            );
        } else {
            wrapper = CREATE3.deployDeterministic(
                abi.encodePacked(type(V3Wrapper).creationCode, abi.encode(protocol_router_address, weth)), packedSalt
            );
        }

        wrappers[packedSalt] = wrapper;

        return wrapper;
    }

    /// @notice Fetches the wrapper address associated with the salt.
    /// @param salt The salt used to deploy the wrapper.
    /// @return wrapper address of the deployed wrapper.
    function getWrapper(bytes12 salt) external view returns (address wrapper) {
        wrapper = wrappers[bytes32(abi.encodePacked(msg.sender, salt))];
    }
}
