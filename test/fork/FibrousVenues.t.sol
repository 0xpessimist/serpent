// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MajorLiquidityForkBase} from "./MajorLiquidity.t.sol";

/// @dev Real Fibrous graphs, decoded and re-quoted by the private backend at each recorded block.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract BaseFibrousVenuesForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-venues.json";
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract HyperEvmFibrousVenuesForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 999;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-venues.json";
    }

    function _routeCount() internal pure override returns (uint256) {
        return 1;
    }
}
