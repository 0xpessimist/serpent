// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @dev Adapters execute in Serpent's context and contain no mutable storage.
abstract contract BaseWrapper {
    address public immutable PROTOCOL_ROUTER_ADDRESS;
    address private immutable _SELF = address(this);

    error SameToken();
    error InvalidToken();
    error InvalidPool();
    error InvalidRouter();
    error InvalidWrappedNative();
    error ExternalCallFailed();
    error OnlyDelegateCall();

    constructor(address router) payable {
        if (router.code.length == 0) revert InvalidRouter();
        PROTOCOL_ROUTER_ADDRESS = router;
    }

    modifier onlyDelegateCall() {
        if (address(this) == _SELF) revert OnlyDelegateCall();
        _;
    }

    function _validateTokens(address tokenIn, address tokenOut) internal pure {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidToken();
        if (tokenIn == tokenOut) revert SameToken();
    }
}
