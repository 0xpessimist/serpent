// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@solady/auth/Ownable.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {PermitLib} from "./libraries/PermitLib.sol";

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
 * @title Serpent Router
 * @notice Executes exact-input split and multi-hop swaps using owner-approved delegatecall adapters.
 * @dev Supports standard ERC20 tokens. Transfer-tax and rebasing tokens are unsupported.
 * @author 0xpessimist (https://github.com/0xpessimist)
 */
contract Serpent is Ownable {
    uint256 internal constant RATE_DENOMINATOR = 1_000_000;
    // Generated from these signatures with `cast sig` / `cast keccak`; assembly requires literal constants.
    uint256 private constant _ADDRESS_ZERO = 0x9fabe1c1; // AddressZero()
    uint256 private constant _SAME_TOKEN = 0xf1cf7d60; // TokenAddressesAreSame()
    uint256 private constant _NO_SWAPS = 0xb3f9702a; // NoSwapsProvided()
    uint256 private constant _AMOUNT_ZERO = 0x40561e0d; // AmountInZero()
    uint256 private constant _MIN_ZERO = 0xd16759a9; // MinReceivedZero()
    uint256 private constant _DESTINATION_ZERO = 0x06107fe5; // DestinationZero()
    uint256 private constant _INVALID_DESTINATION = 0xac6b05f5; // InvalidDestination()
    uint256 private constant _INVALID_KIND = 0xa44acb91; // InvalidSwapType()
    uint256 private constant _INVALID_VALUE = 0x1841b4e1; // InvalidMsgValue()
    uint256 private constant _INVALID_RATE = 0x6a43f8d1; // InvalidRate()
    uint256 private constant _INVALID_ROUTE = 0x84e505d2; // InvalidRoute()
    uint256 private constant _UNKNOWN_PROTOCOL = 0x464c2214; // UnknownProtocol()
    uint256 private constant _BALANCE_QUERY_FAILED = 0x971e17d6; // BalanceQueryFailed()
    uint256 private constant _BELOW_BASELINE = 0x8b27e0d2; // BalanceBelowBaseline()
    uint256 private constant _REENTRANCY = 0xab143c06; // Reentrancy()
    uint256 private constant _ETH_TO_TOKEN = 0x2360e652; // swapEthToToken(address,address,uint256,address,address)
    uint256 private constant _TOKEN_TO_ETH = 0xcc1b07b3; // swapTokenToEth(address,address,uint256,address,address)
    uint256 private constant _TOKEN_TO_TOKEN = 0x577e3d39; // swapTokenToToken(address,address,uint256,address,address)
    bytes32 private constant _SWAP_EVENT = 0x1621cb2414b25cfb014ed2e1e8051310c0f691ac8d2ed92928e804595df0553b; // Swap(address,uint256,uint256,address,address,address)
    mapping(uint256 => address) public swappers;

    /// @dev Native assets use their wrapped-token address in these parameters.
    /// swap_type: 0x01 = ETH to token, 0x02 = token to ETH, 0x03 = token to token.
    struct RouteParam {
        address token_in;
        address token_out;
        uint256 amount_in;
        uint256 min_received;
        address destination;
        bytes1 swap_type;
    }

    /// @dev Consecutive swaps with the same input asset form a split group.
    /// Rates in each group must sum to 1,000,000. The last swap receives the rounding remainder.
    struct SwapParams {
        address token_in;
        address token_out;
        uint32 rate;
        uint256 protocol_id;
        address pool_address;
        bytes1 swap_type;
    }

    event Swap(
        address sender, uint256 amount_in, uint256 amount_out, address token_in, address token_out, address destination
    );

    // Transient storage is separate from the persistent mapping at slot zero.
    // Clearing on return permits several sequential swaps in the same transaction.
    uint256 private transient _swapLock;

    error AddressZero();
    error AlreadySet();
    error SwapperHasNoCode();
    error UnknownProtocol();
    error TokenAddressesAreSame();
    error NoSwapsProvided();
    error AmountInZero();
    error MinReceivedZero();
    error DestinationZero();
    error InvalidDestination();
    error InvalidSwapType();
    error InvalidMsgValue();
    error InvalidPermitSwap();
    error InvalidRate();
    error InvalidRoute();
    error InputAmountMismatch();
    error BalanceQueryFailed();
    error BalanceBelowBaseline();
    error MinReceivedAmountNotReached();
    error ArrayLengthsMismatching();
    error Reentrancy();

    constructor(address owner) payable {
        if (owner == address(0)) revert AddressZero();
        _initializeOwner(owner);
    }

    receive() external payable {}

    modifier nonReentrant() {
        assembly ("memory-safe") {
            if tload(_swapLock.slot) {
                mstore(0x00, _REENTRANCY)
                revert(0x1c, 0x04)
            }
            tstore(_swapLock.slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(_swapLock.slot, 0)
        }
    }

    function swap(RouteParam calldata route, SwapParams[] calldata swap_parameters)
        external
        payable
        nonReentrant
        returns (uint256)
    {
        _validate(route, swap_parameters);
        return _orchestrate(route, swap_parameters, false);
    }

    /// @dev Uses native token permit where available, with Solady's Permit2 fallback.
    /// Native-input routes must use swap instead.
    function swapWithPermit(
        RouteParam calldata route,
        SwapParams[] calldata swap_parameters,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant returns (uint256) {
        _validate(route, swap_parameters);
        if (route.swap_type == 0x01) revert InvalidPermitSwap();
        PermitLib.permit2(route.token_in, msg.sender, address(this), route.amount_in, deadline, v, r, s);
        return _orchestrate(route, swap_parameters, true);
    }

    function addSwapper(uint256 protocol_id, address swapper) external payable onlyOwner {
        if (swapper == address(0)) revert AddressZero();
        if (swapper.code.length == 0) revert SwapperHasNoCode();
        if (swappers[protocol_id] != address(0)) revert AlreadySet();
        swappers[protocol_id] = swapper;
    }

    function removeSwapper(uint256 protocol_id) external payable onlyOwner {
        // Solidity hashes the mapping key and slot; adjacent slots are unrelated.
        delete swappers[protocol_id];
    }

    function sweepStuckToken(address token, uint256 amount, address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransfer(token, receiver, amount);
    }

    function sweepStuckTokens(address[] calldata tokens, uint256[] calldata amounts, address receiver)
        external
        payable
        onlyOwner
    {
        if (tokens.length != amounts.length) revert ArrayLengthsMismatching();
        for (uint256 i; i < tokens.length;) {
            SafeTransferLib.safeTransfer(tokens[i], receiver, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function sweepStuckEther(address receiver) external payable onlyOwner {
        SafeTransferLib.safeTransferAllETH(receiver);
    }

    function _validate(RouteParam calldata route, SwapParams[] calldata swap_parameters) private view {
        assembly ("memory-safe") {
            function fail(selector) {
                mstore(0x00, selector)
                revert(0x1c, 0x04)
            }
            function addressAt(offset) -> value {
                value := calldataload(offset)
                // Preserve the Solidity ABI decoder's rejection of noncanonical address words.
                if shr(160, value) { revert(0, 0) }
            }
            let tokenIn := addressAt(route)
            let tokenOut := addressAt(add(route, 0x20))
            if or(iszero(tokenIn), iszero(tokenOut)) { fail(_ADDRESS_ZERO) }
            if eq(tokenIn, tokenOut) { fail(_SAME_TOKEN) }
            if iszero(swap_parameters.length) { fail(_NO_SWAPS) }
            let amount := calldataload(add(route, 0x40))
            if iszero(amount) { fail(_AMOUNT_ZERO) }
            if iszero(calldataload(add(route, 0x60))) { fail(_MIN_ZERO) }
            let destination := addressAt(add(route, 0x80))
            if iszero(destination) { fail(_DESTINATION_ZERO) }
            if eq(destination, address()) { fail(_INVALID_DESTINATION) }
            // bytes1 is left-aligned, unlike the right-aligned address and integer fields.
            let kindWord := calldataload(add(route, 0xa0))
            let kind := byte(0, kindWord)
            if iszero(eq(kindWord, shl(248, kind))) { revert(0, 0) }
            if gt(sub(kind, 1), 2) { fail(_INVALID_KIND) }
            if iszero(eq(callvalue(), mul(eq(kind, 1), amount))) { fail(_INVALID_VALUE) }
            if or(
                iszero(eq(calldataload(swap_parameters.offset), tokenIn)),
                iszero(eq(eq(byte(0, calldataload(add(swap_parameters.offset, 0xa0))), 1), eq(kind, 1)))
            ) { fail(_INVALID_ROUTE) }
        }
    }

    function _orchestrate(RouteParam calldata route, SwapParams[] calldata swap_parameters, bool permitTransfer)
        private
        returns (uint256 output_amount)
    {
        address inputToken = route.swap_type == 0x01 ? address(0) : route.token_in;
        address outputToken = route.swap_type == 0x02 ? address(0) : route.token_out;
        uint256 inputBaseline = _balance(inputToken);
        if (inputToken == address(0)) inputBaseline -= msg.value;
        uint256 outputBaseline = _balance(outputToken);

        // Flat memory ledger: [asset key, pre-route balance] per 64-byte entry.
        // address(0) is ETH internally; ERC20 addresses identify wrapped tokens separately.
        // At most one new output key per swap, plus the two route endpoints.
        uint256 ledger;
        assembly ("memory-safe") {
            ledger := mload(0x40)
            // The compiler has already bounded the calldata array of 0xc0-byte static elements.
            mstore(0x40, add(ledger, shl(6, add(swap_parameters.length, 2))))
            mstore(ledger, inputToken)
            mstore(add(ledger, 0x20), inputBaseline)
            mstore(add(ledger, 0x40), outputToken)
            mstore(add(ledger, 0x60), outputBaseline)
        }

        if (inputToken != address(0)) {
            if (permitTransfer) {
                SafeTransferLib.safeTransferFrom2(inputToken, msg.sender, address(this), route.amount_in);
            } else {
                SafeTransferLib.safeTransferFrom(inputToken, msg.sender, address(this), route.amount_in);
            }
            if (_available(inputToken, inputBaseline) != route.amount_in) revert InputAmountMismatch();
        }

        uint256 count = _swap(swap_parameters, ledger, route.amount_in);
        output_amount = _available(outputToken, outputBaseline);
        if (output_amount < route.min_received) revert MinReceivedAmountNotReached();

        // Refund any unspent input or intermediate assets, preserving pre-route balances.
        // Exact-input V2/V3 routes normally have no remainder after the final group.
        _refund(ledger, count, outputToken);
        _transfer(outputToken, route.destination, output_amount);

        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, caller())
            mstore(add(ptr, 0x20), calldataload(add(route, 0x40)))
            mstore(add(ptr, 0x40), output_amount)
            calldatacopy(add(ptr, 0x60), route, 0x40)
            mstore(add(ptr, 0xa0), calldataload(add(route, 0x80)))
            log1(ptr, 0xc0, _SWAP_EVENT)
        }
    }

    function _swap(SwapParams[] calldata swap_parameters, uint256 ledger, uint256 initialAmount)
        private
        returns (uint256 count)
    {
        assembly ("memory-safe") {
            function fail(selector) {
                mstore(0x00, selector)
                revert(0x1c, 0x04)
            }
            function addressAt(offset) -> value {
                value := calldataload(offset)
                if shr(160, value) { revert(0, 0) }
            }
            function find(start, entries, token) -> entry {
                let end := add(start, shl(6, entries))
                for { let cursor := start } lt(cursor, end) { cursor := add(cursor, 0x40) } {
                    if eq(mload(cursor), token) {
                        entry := cursor
                        break
                    }
                }
            }
            function assetBalance(token) -> amount {
                switch token
                case 0 { amount := selfbalance() }
                default {
                    mstore(0x00, shl(224, 0x70a08231))
                    mstore(0x04, address())
                    let success := staticcall(gas(), token, 0x00, 0x24, 0x00, 0x20)
                    if or(iszero(success), lt(returndatasize(), 0x20)) { fail(_BALANCE_QUERY_FAILED) }
                    amount := mload(0x00)
                }
            }
            function available(token, baseline) -> amount {
                let current := assetBalance(token)
                if lt(current, baseline) { fail(_BELOW_BASELINE) }
                amount := sub(current, baseline)
            }

            count := 2
            // First-step input is validated against the route before taking funds.
            let groupToken := mload(ledger)
            let groupAmount := initialAmount
            let allocated := 0
            let groupRate := 0
            let end := add(swap_parameters.offset, mul(swap_parameters.length, 0xc0))
            // Static ABI elements are six words: in, out, rate, protocol, pool, bytes1 kind.
            for { let step := swap_parameters.offset } lt(step, end) { step := add(step, 0xc0) } {
                let kindWord := calldataload(add(step, 0xa0))
                let kind := byte(0, kindWord)
                if iszero(eq(kindWord, shl(248, kind))) { revert(0, 0) }
                if gt(sub(kind, 1), 2) { fail(_INVALID_KIND) }
                let tokenIn := addressAt(step)
                let tokenOut := addressAt(add(step, 0x20))
                if or(iszero(tokenIn), iszero(tokenOut)) { fail(_ADDRESS_ZERO) }
                if eq(tokenIn, tokenOut) { fail(_SAME_TOKEN) }
                let rate := calldataload(add(step, 0x40))
                if or(iszero(rate), gt(rate, RATE_DENOMINATOR)) { fail(_INVALID_RATE) }

                let input := mul(iszero(eq(kind, 1)), tokenIn)
                if iszero(eq(input, groupToken)) {
                    let entry := find(ledger, count, input)
                    if iszero(entry) { fail(_INVALID_ROUTE) }
                    groupToken := input
                    groupAmount := available(input, mload(add(entry, 0x20)))
                    if iszero(groupAmount) { fail(_AMOUNT_ZERO) }
                    allocated := 0
                    groupRate := 0
                }
                // Each rate is <= 1e6 and the prior sum is <= 1e6, so this addition cannot overflow.
                groupRate := add(groupRate, rate)
                if gt(groupRate, RATE_DENOMINATOR) { fail(_INVALID_RATE) }
                let last := eq(add(step, 0xc0), end)
                if iszero(last) {
                    let next := add(step, 0xc0)
                    let nextInput := mul(iszero(eq(byte(0, calldataload(add(next, 0xa0))), 1)), calldataload(next))
                    last := iszero(eq(input, nextInput))
                }
                let amount
                switch last
                case 1 {
                    if iszero(eq(groupRate, RATE_DENOMINATOR)) { fail(_INVALID_RATE) }
                    // All earlier floors sum to <= groupAmount. The last leg receives every remaining unit.
                    amount := sub(groupAmount, allocated)
                }
                default {
                    // floor(groupAmount * rate / 1e6), including uint256.max, without a 512-bit multiply.
                    amount := add(
                        mul(div(groupAmount, RATE_DENOMINATOR), rate),
                        div(mul(mod(groupAmount, RATE_DENOMINATOR), rate), RATE_DENOMINATOR)
                    )
                }
                allocated := add(allocated, amount)

                mstore(0x00, calldataload(add(step, 0x60)))
                mstore(0x20, swappers.slot)
                let swapper := and(sload(keccak256(0x00, 0x40)), 0xffffffffffffffffffffffffffffffffffffffff)
                if iszero(swapper) { fail(_UNKNOWN_PROTOCOL) }
                if amount {
                    let output := mul(iszero(eq(kind, 2)), tokenOut)
                    if iszero(find(ledger, count, output)) {
                        let baseline := assetBalance(output)
                        let entry := add(ledger, shl(6, count))
                        mstore(entry, output)
                        mstore(add(entry, 0x20), baseline)
                        count := add(count, 1)
                    }
                    let selector := _TOKEN_TO_TOKEN
                    switch kind
                    case 1 { selector := _ETH_TO_TOKEN }
                    case 2 { selector := _TOKEN_TO_ETH }
                    let pool := addressAt(add(step, 0x80))
                    let ptr := mload(0x40)
                    mstore(ptr, shl(224, selector))
                    calldatacopy(add(ptr, 0x04), step, 0x40)
                    mstore(add(ptr, 0x44), amount)
                    mstore(add(ptr, 0x64), address())
                    mstore(add(ptr, 0x84), pool)
                    // Scratch follows the reserved ledger and is dead after each call.
                    if iszero(delegatecall(gas(), swapper, ptr, 0xa4, 0, 0)) {
                        returndatacopy(ptr, 0, returndatasize())
                        revert(ptr, returndatasize())
                    }
                }
            }
        }
    }

    function _balance(address token) private view returns (uint256 amount) {
        if (token == address(0)) return address(this).balance;
        bool success;
        assembly ("memory-safe") {
            mstore(0x00, shl(224, 0x70a08231))
            mstore(0x04, address())
            success := staticcall(gas(), token, 0x00, 0x24, 0x00, 0x20)
            success := and(success, iszero(lt(returndatasize(), 0x20)))
            amount := mload(0x00)
        }
        if (!success) revert BalanceQueryFailed();
    }

    function _available(address token, uint256 baseline) private view returns (uint256 amount) {
        uint256 current = _balance(token);
        if (current < baseline) revert BalanceBelowBaseline();
        unchecked {
            amount = current - baseline;
        }
    }

    function _refund(uint256 ledger, uint256 count, address outputToken) private {
        for (uint256 i; i < count;) {
            address token;
            uint256 baseline;
            assembly ("memory-safe") {
                let entry := add(ledger, shl(6, i))
                token := mload(entry)
                baseline := mload(add(entry, 0x20))
            }
            if (token != outputToken) {
                uint256 remainder = _available(token, baseline);
                if (remainder != 0) _transfer(token, msg.sender, remainder);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _transfer(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            SafeTransferLib.safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }
}
