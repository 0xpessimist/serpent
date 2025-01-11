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
    /// @notice Deploys a new wrapper contract using CREATE3.
    /// @param isV2 Boolean indicating whether the wrapper is for UniswapV2Router or SwapRouter(Uniswap V3).
    /// @param protocol_router_address Address of the protocol router.
    /// @return wrapper address of the deployed contract.
    function deployWrapper(bool isV2, address protocol_router_address, address weth, bytes32 salt) external returns (address) {
        address wrapper;
        
        if (isV2) {
            wrapper = CREATE3.deployDeterministic(
                abi.encodePacked(type(V2Wrapper).creationCode, abi.encode(protocol_router_address)), salt
            );
        } else {
            wrapper = CREATE3.deployDeterministic(
                abi.encodePacked(type(V3Wrapper).creationCode, abi.encode(protocol_router_address, weth)), salt
            );
        }

        return wrapper;
    }

    /// @notice Fetches the wrapper address associated with the protocol address.
    /// @param salt Salt used to deploy the wrapper.
    /// @return wrapper address of the deployed wrapper.
    function getWrapper(bytes32 salt) external view returns (address wrapper) {
        wrapper = CREATE3.predictDeterministicAddress(salt);
    }
}
