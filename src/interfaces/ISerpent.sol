// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Serpent} from "../Serpent.sol";

/// @dev Uses the router's structs so existing Serpent.RouteParam callers retain source compatibility.
interface ISerpent {
    event Swap(
        address sender, uint256 amount_in, uint256 amount_out, address token_in, address token_out, address destination
    );

    function swappers(uint256 protocol_id) external view returns (address);
    function swap(Serpent.RouteParam calldata route, Serpent.SwapParams[] calldata swap_parameters)
        external
        payable
        returns (uint256);
    function swapWithPermit(
        Serpent.RouteParam calldata route,
        Serpent.SwapParams[] calldata swap_parameters,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (uint256);
    function addSwapper(uint256 protocol_id, address swapper) external payable;
    function removeSwapper(uint256 protocol_id) external payable;
    function sweepStuckToken(address token, uint256 amount, address receiver) external payable;
    function sweepStuckTokens(address[] calldata tokens, uint256[] calldata amounts, address receiver) external payable;
    function sweepStuckEther(address receiver) external payable;
}
