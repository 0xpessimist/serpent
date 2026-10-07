// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LiquidityForkBase} from "./LiquidityForks.t.sol";
import {MajorLiquidityForkBase} from "./MajorLiquidity.t.sol";

/// @author 0xpessimist (https://github.com/0xpessimist)
contract BaseFibrousSourceExpansionForkTest is LiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-source-expansion.json";
    }

    function _deploymentCount() internal pure override returns (uint256) {
        return 4;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract HyperEvmFibrousSourceExpansionForkTest is LiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 999;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-source-expansion.json";
    }

    function _deploymentCount() internal pure override returns (uint256) {
        return 1;
    }
}

/// @dev Entire authenticated Fibrous graphs, including weighted V2 splits and Router02 multihop paths.
/// @author 0xpessimist (https://github.com/0xpessimist)
contract BaseFibrousSourceGraphsForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 8453;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-source-routes.json";
    }

    function _routeCount() internal pure override returns (uint256) {
        return 4;
    }
}

/// @author 0xpessimist (https://github.com/0xpessimist)
contract HyperEvmFibrousSourceGraphsForkTest is MajorLiquidityForkBase {
    function _chain() internal pure override returns (uint256) {
        return 999;
    }

    function _fixture() internal pure override returns (string memory) {
        return "test/fixtures/fibrous-source-routes.json";
    }

    function _routeCount() internal pure override returns (uint256) {
        return 1;
    }
}
