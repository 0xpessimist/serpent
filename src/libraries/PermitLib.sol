// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

/// @notice Native permit with a bounded probe that accommodates cold token proxies.
/// @author 0xpessimist (https://github.com/0xpessimist)
/// @dev Adapted from Solady v0.0.259 SafeTransferLib.permit2 (MIT, Copyright (c) 2022 Solady).
/// https://github.com/Vectorized/solady/blob/v0.0.259/src/utils/SafeTransferLib.sol
/// The native ABI and Permit2 fallback are retained; the domain probe receives 15K gas instead of 5K.
library PermitLib {
    function permit2(
        address token,
        address owner,
        address spender,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        bool success;
        address weth = SafeTransferLib.WETH9;
        bytes32 daiDomain = SafeTransferLib.DAI_DOMAIN_SEPARATOR;
        assembly ("memory-safe") {
            // Mainnet WETH9 has no native permit; avoid probing its fallback.
            for {} shl(96, xor(token, weth)) {} {
                mstore(0x00, 0x3644e515) // DOMAIN_SEPARATOR().
                // A cold USDC proxy needs more than 5K for its implementation and domain reads.
                if iszero(
                    and(
                        lt(iszero(mload(0x00)), eq(returndatasize(), 0x20)),
                        staticcall(15000, token, 0x1c, 0x04, 0x00, 0x20)
                    )
                ) { break }
                let m := mload(0x40)
                mstore(add(m, 0x34), spender)
                mstore(add(m, 0x20), shl(96, owner))
                mstore(add(m, 0x74), deadline)
                if eq(mload(0x00), daiDomain) {
                    mstore(0x14, owner)
                    mstore(0x00, 0x7ecebe00000000000000000000000000) // nonces(address).
                    mstore(add(m, 0x94), staticcall(gas(), token, 0x10, 0x24, add(m, 0x54), 0x20))
                    mstore(m, 0x8fcbaf0c000000000000000000000000) // DAI permit.
                    // The nonce is at m + 0x54 and allowed = true is at m + 0x94.
                    mstore(add(m, 0xb4), and(0xff, v))
                    mstore(add(m, 0xd4), r)
                    mstore(add(m, 0xf4), s)
                    success := call(gas(), token, 0, add(m, 0x10), 0x104, codesize(), 0x00)
                    break
                }
                mstore(m, 0xd505accf000000000000000000000000) // EIP-2612 permit.
                mstore(add(m, 0x54), amount)
                mstore(add(m, 0x94), and(0xff, v))
                mstore(add(m, 0xb4), r)
                mstore(add(m, 0xd4), s)
                success := call(gas(), token, 0, add(m, 0x10), 0xe4, codesize(), 0x00)
                break
            }
        }
        if (!success) SafeTransferLib.simplePermit2(token, owner, spender, amount, deadline, v, r, s);
    }
}
